import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bytes.dart';
import 'cancellation.dart';
import 'disk_layout.dart';
import 'exceptions.dart';
import 'file_copy.dart';
import 'host_factory.dart';
import 'host_platform.dart';
import 'hybrid_iso.dart';
import 'iso_inspector.dart';
import 'layout_chooser.dart';
import 'models/iso_mount.dart';
import 'models/iso_profile.dart';
import 'models/usb_disk.dart';
import 'models/write_progress.dart';
import 'paths.dart';
import 'process_runner.dart';
import 'safety.dart';

class WriteRequest {
  const WriteRequest({
    required this.isoPath,
    required this.disk,
    this.confirmed = false,
    this.dryRun = false,
    this.existingMount,
    this.allowAdvancedTargets = false,
    this.cancellation,
  });

  final String isoPath;
  final UsbDisk disk;
  final bool confirmed;
  final bool dryRun;
  final IsoMount? existingMount;
  final bool allowAdvancedTargets;
  final CancellationToken? cancellation;
}

class BootableWriter {
  BootableWriter({
    ProcessRunner? runner,
    HostPlatform? host,
    IsoInspector? inspector,
  }) : _host = host ?? createHostPlatform(runner),
       _inspector = inspector ?? IsoInspector();

  final HostPlatform _host;
  final IsoInspector _inspector;

  Stream<WriteProgress> write(WriteRequest request) async* {
    if (!request.dryRun && !request.confirmed) {
      throw ConfirmationRequiredException(
        'Refusing to erase ${request.disk.id} without explicit confirmation.',
      );
    }

    Safety.ensureWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    _ensureIsoNotOnTarget(request);
    await _host.verifyWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );

    yield const WriteProgress(
      step: WriteStep.validating,
      message: 'Checking the ISO…',
      percent: 0.02,
    );

    if (!File(request.isoPath).existsSync()) {
      throw InvalidIsoException('ISO not found: ${request.isoPath}');
    }
    _ensureDiskFitsIso(request, applyWindowsFat32Cap: false);
    request.cancellation?.throwIfCancelled();

    final existing = request.existingMount;
    final reuseMount =
        existing != null &&
        p.equals(p.normalize(existing.isoPath), p.normalize(request.isoPath));
    final mount = reuseMount ? existing : await _host.mountIso(request.isoPath);
    var shouldUnmount = !reuseMount;
    try {
      final profile = _inspector.inspectMounted(mount.mountPath);
      final strategy = LayoutChooser.strategyFor(
        profile: profile,
        windowsHost: Platform.isWindows,
        diskSizeBytes: request.disk.sizeBytes,
        isoLooksHybrid: isoLooksLikeHybridDisk(request.isoPath),
      );

      if (strategy == WriteStrategy.unsupported) {
        throw InvalidIsoException(profile.unsupportedMessage);
      }
      if (strategy == WriteStrategy.multiIso) {
        throw UsbIsoException('Multi-ISO sticks are not implemented yet.');
      }

      if (strategy == WriteStrategy.windowsFileCopy && Platform.isWindows) {
        _ensureDiskFitsIso(request, applyWindowsFat32Cap: true);
      }

      final needsSplit =
          profile.needsSplit && strategy == WriteStrategy.windowsFileCopy;
      String? splitTool;
      if (needsSplit) {
        splitTool = await _host.findWimSplitTool();
        if (splitTool == null) {
          throw DependencyMissingException(_missingSplitToolMessage());
        }
      }

      if (strategy == WriteStrategy.windowsFileCopy) {
        await _ensureFat32Compatible(mount.mountPath, skipWim: needsSplit);
      }

      if (request.dryRun) {
        yield WriteProgress(
          step: WriteStep.done,
          message: _dryRunSummary(request, profile, strategy, splitTool),
          percent: 1,
        );
        return;
      }

      request.cancellation?.throwIfCancelled();

      if (strategy == WriteStrategy.rawHybrid) {
        yield* _writeRaw(request, profile, mount);
        shouldUnmount = false;
        return;
      }

      yield WriteProgress(
        step: WriteStep.preparing,
        message:
            '${profile.kindLabel} (${profile.summary}). Erasing ${request.disk.label}…',
        percent: 0.08,
      );

      yield WriteProgress(
        step: WriteStep.erasing,
        message: strategy == WriteStrategy.windowsDualPartition
            ? 'Erasing ${request.disk.id} as FAT32+NTFS…'
            : 'Erasing and formatting ${request.disk.id} as FAT32…',
        percent: 0.12,
      );
      await _host.verifyWritable(
        request.disk,
        allowAdvancedTargets: request.allowAdvancedTargets,
      );
      request.cancellation?.throwIfCancelled();
      final layout = strategy == WriteStrategy.windowsDualPartition
          ? DiskLayout.fat32PlusNtfs
          : DiskLayout.fat32;
      await _host.eraseAndFormat(request.disk, layout: layout);
      request.cancellation?.throwIfCancelled(diskAlreadyErased: true);

      yield const WriteProgress(
        step: WriteStep.erasing,
        message: 'Waiting for the USB volume…',
        percent: 0.18,
      );
      final volumes = await _host.waitForVolumeMount(
        request.disk,
        layout: layout,
      );

      yield const WriteProgress(
        step: WriteStep.copying,
        message: 'Copying installer files…',
        percent: 0.2,
      );

      if (strategy == WriteStrategy.windowsDualPartition) {
        await for (final progress in _copyDualWithProgress(
          mount.mountPath,
          volumes.bootMount,
          volumes.dataMount!,
          cancellation: request.cancellation,
        )) {
          yield progress;
        }
      } else {
        await for (final progress in _copyWithProgress(
          mount.mountPath,
          volumes.bootMount,
          skipWim: needsSplit,
          cancellation: request.cancellation,
        )) {
          yield progress;
        }
      }

      if (needsSplit) {
        yield const WriteProgress(
          step: WriteStep.splitting,
          message: 'Splitting the installer image so it fits on FAT32…',
          percent: 0.82,
        );
        final destSources = p.join(volumes.bootMount, 'sources');
        await Directory(destSources).create(recursive: true);
        await _host.splitWim(
          sourceWim: profile.installImagePath!,
          destinationSwm: p.join(destSources, 'install.swm'),
          toolPath: splitTool!,
        );
      }

      request.cancellation?.throwIfCancelled(diskAlreadyErased: true);
      yield const WriteProgress(
        step: WriteStep.verifying,
        message: 'Verifying copied files…',
        percent: 0.9,
      );
      _verifyFileCopy(
        sourceRoot: mount.mountPath,
        volumes: volumes,
        profile: profile,
        strategy: strategy,
        needsSplit: needsSplit,
      );

      await _host.flushDisk(request.disk);
      yield* _eject(request);
    } finally {
      if (shouldUnmount) {
        try {
          await _host.unmountIso(mount);
        } catch (_) {
          // Unmount is best-effort after a successful or failed write.
        }
      }
    }
  }

  Stream<WriteProgress> _writeRaw(
    WriteRequest request,
    IsoProfile profile,
    IsoMount mount,
  ) async* {
    try {
      await _host.unmountIso(mount);
    } catch (_) {
      // The ISO file is read independently for the raw write.
    }

    yield WriteProgress(
      step: WriteStep.preparing,
      message:
          '${profile.kindLabel}. Writing the ISO image to ${request.disk.label}…',
      percent: 0.1,
    );
    await _host.verifyWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    request.cancellation?.throwIfCancelled();

    yield const WriteProgress(
      step: WriteStep.writing,
      message: 'Writing ISO image…',
      percent: 0.2,
    );

    var written = 0;
    var total = File(request.isoPath).lengthSync();
    late final StreamController<WriteProgress> controller;
    controller = StreamController<WriteProgress>();
    final write = _host.writeRawImage(
      disk: request.disk,
      isoPath: request.isoPath,
      cancellation: request.cancellation,
      onProgress: (copied, size) {
        written = copied;
        total = size;
        final fraction = size == 0 ? 1.0 : copied / size;
        if (!controller.isClosed) {
          controller.add(
            WriteProgress(
              step: WriteStep.writing,
              message: 'Writing ISO image… ${(fraction * 100).round()}%',
              percent: 0.2 + (0.65 * fraction),
            ),
          );
        }
      },
    );
    write
        .then((_) {
          if (!controller.isClosed) {
            controller.close();
          }
        })
        .catchError((Object error, StackTrace stack) {
          if (!controller.isClosed) {
            controller.addError(error, stack);
            controller.close();
          }
        });
    yield* controller.stream;

    yield const WriteProgress(
      step: WriteStep.verifying,
      message: 'Verifying the raw write…',
      percent: 0.9,
    );
    if (written < total) {
      throw UsbIsoException(
        'Raw write verified ${formatBytes(written)} of ${formatBytes(total)}. '
        'The USB may not be bootable.',
      );
    }

    await _host.flushDisk(request.disk);
    yield* _eject(request);
  }

  Stream<WriteProgress> _eject(WriteRequest request) async* {
    yield const WriteProgress(
      step: WriteStep.ejecting,
      message: 'Ejecting the USB drive…',
      percent: 0.95,
    );
    try {
      await _host.eject(request.disk);
      yield const WriteProgress(
        step: WriteStep.done,
        message: 'The USB is ready. Unplug it and boot the PC from this drive.',
        percent: 1,
      );
    } on UsbIsoException catch (error) {
      yield WriteProgress(
        step: WriteStep.done,
        message: 'The USB is ready, but eject failed: ${error.message}',
        percent: 1,
      );
    }
  }

  String _dryRunSummary(
    WriteRequest request,
    IsoProfile profile,
    WriteStrategy strategy,
    String? splitTool,
  ) {
    final layout = switch (strategy) {
      WriteStrategy.windowsDualPartition =>
        'erase FAT32+NTFS → copy boot files → copy large image to NTFS → eject',
      WriteStrategy.rawHybrid => 'raw-write ISO image → flush → eject',
      WriteStrategy.windowsFileCopy =>
        'erase FAT32 → copy files'
            '${profile.needsSplit ? ' → split installer image' : ''} → eject',
      WriteStrategy.multiIso => 'multi-ISO (not implemented)',
      WriteStrategy.unsupported => 'unsupported',
    };
    final buffer = StringBuffer()
      ..writeln('Dry run — no disks will be changed.')
      ..writeln('ISO: ${request.isoPath}')
      ..writeln('Target: ${request.disk.label}')
      ..writeln(profile.summary)
      ..writeln('Strategy: ${strategy.name}')
      ..writeln('Steps: $layout.');
    if (profile.needsSplit && strategy == WriteStrategy.windowsFileCopy) {
      buffer.writeln('Split tool: ${splitTool ?? 'MISSING'}');
    }
    return buffer.toString().trim();
  }

  void _ensureIsoNotOnTarget(WriteRequest request) {
    if (isoLivesOnAnyMount(request.isoPath, request.disk.mountPoints)) {
      throw UsbIsoException(
        'The ISO is on ${request.disk.id}. Copy it to the computer first '
        'so it is not erased with the USB drive.',
      );
    }
  }

  void _ensureDiskFitsIso(
    WriteRequest request, {
    required bool applyWindowsFat32Cap,
  }) {
    final isoBytes = File(request.isoPath).lengthSync();
    var usable = request.disk.sizeBytes;
    if (applyWindowsFat32Cap &&
        Platform.isWindows &&
        usable > windowsFat32PartitionMaxBytes) {
      usable = windowsFat32PartitionMaxBytes;
    }
    const slack = 64 * 1024 * 1024;
    if (usable < isoBytes + slack) {
      throw UsbIsoException(
        'This USB is ${formatBytes(request.disk.sizeBytes)} but the ISO is '
        '${formatBytes(isoBytes)}. Use a larger drive.',
      );
    }
  }

  Future<void> _ensureFat32Compatible(
    String mountPath, {
    required bool skipWim,
  }) async {
    final relative = await firstOversizedFat32File(mountPath, skipWim: skipWim);
    if (relative == null) {
      return;
    }
    final size = File(p.join(mountPath, relative)).lengthSync();
    throw UsbIsoException(
      'This ISO has $relative (${formatBytes(size)}), which cannot be '
      'stored on a FAT32 USB.',
    );
  }

  String _missingSplitToolMessage() {
    if (Platform.isMacOS) {
      return 'This Windows ISO has an installer image larger than 4 GB. '
          'Install wimlib to split it:\n\n  brew install wimlib';
    }
    if (Platform.isLinux) {
      return 'This Windows ISO has an installer image larger than 4 GB. '
          'Install wimlib (wimtools) to split it.';
    }
    return 'This Windows ISO has an installer image larger than 4 GB, '
        'but DISM was not found. DISM is required to split the image.';
  }

  void _verifyFileCopy({
    required String sourceRoot,
    required PreparedVolumes volumes,
    required IsoProfile profile,
    required WriteStrategy strategy,
    required bool needsSplit,
  }) {
    if (profile.hasX64Efi) {
      _assertSameSize(sourceRoot, volumes.bootMount, const [
        'efi/boot/bootx64.efi',
        'EFI/Boot/bootx64.efi',
        'EFI/BOOT/BOOTX64.EFI',
      ], label: 'bootx64.efi');
    }
    if (profile.hasArmEfi) {
      _assertSameSize(sourceRoot, volumes.bootMount, const [
        'efi/boot/bootaa64.efi',
        'EFI/Boot/bootaa64.efi',
        'EFI/BOOT/BOOTAA64.EFI',
      ], label: 'bootaa64.efi');
    }

    if (needsSplit) {
      final swm = File(p.join(volumes.bootMount, 'sources', 'install.swm'));
      if (!swm.existsSync() || swm.lengthSync() <= 0) {
        throw UsbIsoException(
          'Verification failed: sources/install.swm is missing after the split.',
        );
      }
      return;
    }

    if (profile.installImagePath == null) {
      return;
    }
    final destRoot = strategy == WriteStrategy.windowsDualPartition
        ? (volumes.dataMount ?? volumes.bootMount)
        : volumes.bootMount;
    final name = p.basename(profile.installImagePath!);
    _assertSameSize(sourceRoot, destRoot, [
      'sources/$name',
      'Sources/$name',
    ], label: name);
  }

  void _assertSameSize(
    String sourceRoot,
    String destRoot,
    List<String> relatives, {
    required String label,
  }) {
    File? source;
    File? dest;
    for (final relative in relatives) {
      final candidate = File(p.join(sourceRoot, relative));
      if (candidate.existsSync()) {
        source = candidate;
      }
      final copied = File(p.join(destRoot, relative));
      if (copied.existsSync()) {
        dest = copied;
      }
    }
    if (source == null) {
      return;
    }
    if (dest == null) {
      throw UsbIsoException(
        'Verification failed: $label is missing on the USB.',
      );
    }
    if (source.lengthSync() != dest.lengthSync()) {
      throw UsbIsoException(
        'Verification failed: $label is ${formatBytes(dest.lengthSync())} '
        'on the USB but ${formatBytes(source.lengthSync())} in the ISO.',
      );
    }
  }

  Stream<WriteProgress> _copyWithProgress(
    String source,
    String destination, {
    required bool skipWim,
    CancellationToken? cancellation,
  }) {
    return _copyStream(
      onProgress: _copyProgress,
      copy: (onProgress) => copyDirectory(
        source,
        destination,
        shouldSkip: skipWim ? (_, relative) => isInstallImage(relative) : null,
        cancellation: cancellation,
        onProgress: onProgress,
      ),
    );
  }

  Stream<WriteProgress> _copyDualWithProgress(
    String source,
    String bootMount,
    String dataMount, {
    CancellationToken? cancellation,
  }) {
    return _copyStream(
      onProgress: _copyProgress,
      copy: (onProgress) async {
        var smallTotal = 0;
        var largeTotal = 0;
        await for (final entity in Directory(
          source,
        ).list(recursive: true, followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          final size = await entity.length();
          if (isOversizedFat32File(entity)) {
            largeTotal += size;
          } else {
            smallTotal += size;
          }
        }
        final combined = smallTotal + largeTotal;
        var copiedSmall = 0;
        await copyDirectory(
          source,
          bootMount,
          shouldSkip: (file, _) => isOversizedFat32File(file),
          countSkippedInProgress: false,
          cancellation: cancellation,
          onProgress: (copied, _) {
            copiedSmall = copied;
            onProgress(copied, combined);
          },
        );
        await copyDirectory(
          source,
          dataMount,
          shouldSkip: (file, _) => !isOversizedFat32File(file),
          countSkippedInProgress: false,
          cancellation: cancellation,
          onProgress: (copied, _) {
            onProgress(copiedSmall + copied, combined);
          },
        );
      },
    );
  }

  WriteProgress _copyProgress(int copied, int total) {
    final fraction = total == 0 ? 1.0 : copied / total;
    return WriteProgress(
      step: WriteStep.copying,
      message: 'Copying installer files… ${(fraction * 100).round()}%',
      percent: 0.2 + (0.58 * fraction),
    );
  }

  Stream<WriteProgress> _copyStream({
    required WriteProgress Function(int copied, int total) onProgress,
    required Future<void> Function(void Function(int, int) report) copy,
  }) {
    late final StreamController<WriteProgress> controller;
    controller = StreamController<WriteProgress>(
      onListen: () async {
        try {
          await copy((copied, total) {
            if (!controller.isClosed) {
              controller.add(onProgress(copied, total));
            }
          });
          if (!controller.isClosed) {
            await controller.close();
          }
        } catch (error, stack) {
          if (!controller.isClosed) {
            controller.addError(error, stack);
            await controller.close();
          }
        }
      },
    );
    return controller.stream;
  }
}
