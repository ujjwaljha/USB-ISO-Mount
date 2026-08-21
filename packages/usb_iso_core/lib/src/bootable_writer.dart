import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bytes.dart';
import 'exceptions.dart';
import 'file_copy.dart';
import 'host_factory.dart';
import 'host_platform.dart';
import 'iso_validator.dart';
import 'models/iso_mount.dart';
import 'models/usb_disk.dart';
import 'models/windows_iso_info.dart';
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
  });

  final String isoPath;
  final UsbDisk disk;
  final bool confirmed;
  final bool dryRun;
  final IsoMount? existingMount;
}

class BootableWriter {
  BootableWriter({
    ProcessRunner? runner,
    HostPlatform? host,
    WindowsIsoValidator? validator,
  }) : _host = host ?? createHostPlatform(runner),
       _validator = validator ?? WindowsIsoValidator();

  final HostPlatform _host;
  final WindowsIsoValidator _validator;

  Stream<WriteProgress> write(WriteRequest request) async* {
    if (!request.dryRun && !request.confirmed) {
      throw ConfirmationRequiredException(
        'Refusing to erase ${request.disk.id} without explicit confirmation.',
      );
    }

    Safety.ensureWritable(request.disk);
    _ensureIsoNotOnTarget(request);
    await _host.verifyWritable(request.disk);

    yield const WriteProgress(
      step: WriteStep.validating,
      message: 'Checking the Windows ISO…',
      percent: 0.02,
    );

    if (!File(request.isoPath).existsSync()) {
      throw InvalidIsoException('ISO not found: ${request.isoPath}');
    }
    _ensureDiskFitsIso(request);

    final existing = request.existingMount;
    final reuseMount =
        existing != null &&
        p.equals(p.normalize(existing.isoPath), p.normalize(request.isoPath));
    final mount = reuseMount ? existing : await _host.mountIso(request.isoPath);
    try {
      final info = _validator.inspectMounted(mount.mountPath);
      _validator.ensureValid(info);
      await _ensureFat32Compatible(mount.mountPath, skipWim: info.needsSplit);

      String? splitTool;
      if (info.needsSplit) {
        splitTool = await _host.findWimSplitTool();
        if (splitTool == null) {
          throw DependencyMissingException(_missingSplitToolMessage());
        }
      }

      if (request.dryRun) {
        yield WriteProgress(
          step: WriteStep.done,
          message: _dryRunSummary(request, info, splitTool),
          percent: 1,
        );
        return;
      }

      yield WriteProgress(
        step: WriteStep.preparing,
        message:
            'ISO looks valid (${info.summary}). Erasing ${request.disk.label}…',
        percent: 0.08,
      );

      yield WriteProgress(
        step: WriteStep.erasing,
        message: 'Erasing and formatting ${request.disk.id} as FAT32…',
        percent: 0.12,
      );
      await _host.verifyWritable(request.disk);
      await _host.eraseAndFormat(request.disk);

      yield const WriteProgress(
        step: WriteStep.erasing,
        message: 'Waiting for the USB volume…',
        percent: 0.18,
      );
      final destination = await _host.waitForVolumeMount(request.disk);

      yield const WriteProgress(
        step: WriteStep.copying,
        message: 'Copying installer files…',
        percent: 0.2,
      );

      final skipWim = info.needsSplit;
      await for (final progress in _copyWithProgress(
        mount.mountPath,
        destination,
        skipWim: skipWim,
      )) {
        yield progress;
      }

      if (info.needsSplit) {
        yield const WriteProgress(
          step: WriteStep.splitting,
          message: 'Splitting install.wim so it fits on FAT32…',
          percent: 0.82,
        );
        final destSources = p.join(destination, 'sources');
        await Directory(destSources).create(recursive: true);
        await _host.splitWim(
          sourceWim: info.installImagePath!,
          destinationSwm: p.join(destSources, 'install.swm'),
          toolPath: splitTool!,
        );
      }

      yield const WriteProgress(
        step: WriteStep.ejecting,
        message: 'Ejecting the USB drive…',
        percent: 0.95,
      );
      try {
        await _host.eject(request.disk);
        yield const WriteProgress(
          step: WriteStep.done,
          message:
              'The USB is ready. Unplug it and boot the PC from this drive '
              'to install Windows.',
          percent: 1,
        );
      } on UsbIsoException catch (error) {
        yield WriteProgress(
          step: WriteStep.done,
          message:
              'The USB is ready. ${error.message}',
          percent: 1,
        );
      }
    } finally {
      if (!reuseMount) {
        try {
          await _host.unmountIso(mount);
        } catch (_) {
          // Unmount is best-effort after a successful or failed write.
        }
      }
    }
  }

  String _dryRunSummary(
    WriteRequest request,
    WindowsIsoInfo info,
    String? splitTool,
  ) {
    final buffer = StringBuffer()
      ..writeln('Dry run — no disks will be changed.')
      ..writeln('ISO: ${request.isoPath}')
      ..writeln('Target: ${request.disk.label}')
      ..writeln(info.summary)
      ..writeln(
        'Steps: erase FAT32 → copy files'
        '${info.needsSplit ? ' → split WIM' : ''} → eject.',
      );
    if (info.needsSplit) {
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

  void _ensureDiskFitsIso(WriteRequest request) {
    final isoBytes = File(request.isoPath).lengthSync();
    var usable = request.disk.sizeBytes;
    if (Platform.isWindows && usable > windowsFat32PartitionMaxBytes) {
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
      return 'This Windows ISO has an install.wim larger than 4 GB. '
          'Install wimlib to split it:\n\n  brew install wimlib';
    }
    return 'This Windows ISO has an install.wim larger than 4 GB, '
        'but DISM was not found. DISM is required to split the image.';
  }

  Stream<WriteProgress> _copyWithProgress(
    String source,
    String destination, {
    required bool skipWim,
  }) {
    late final StreamController<WriteProgress> controller;
    controller = StreamController<WriteProgress>(
      onListen: () async {
        try {
          await copyDirectory(
            source,
            destination,
            shouldSkip: skipWim
                ? (_, relative) => isInstallWim(relative)
                : null,
            onProgress: (copied, total) {
              final fraction = total == 0 ? 1.0 : copied / total;
              if (!controller.isClosed) {
                controller.add(
                  WriteProgress(
                    step: WriteStep.copying,
                    message:
                        'Copying installer files… ${(fraction * 100).round()}%',
                    percent: 0.2 + (0.58 * fraction),
                  ),
                );
              }
            },
          );
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
