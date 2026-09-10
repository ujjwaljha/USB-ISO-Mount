import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bytes.dart';
import 'cancellation.dart';
import 'disk_layout.dart';
import 'exceptions.dart';
import 'file_copy.dart';
import 'grub_config.dart';
import 'grub_installer.dart';
import 'host_factory.dart';
import 'host_platform.dart';
import 'hybrid_iso.dart';
import 'iso_inspector.dart';
import 'layout_chooser.dart';
import 'linux_boot_files.dart';
import 'models/iso_mount.dart';
import 'models/iso_profile.dart';
import 'models/usb_disk.dart';
import 'models/write_progress.dart';
import 'multiboot_disk.dart';
import 'multiboot_plan.dart';
import 'paths.dart';
import 'process_runner.dart';
import 'safety.dart';

/// Extra dry-run lines for the chosen strategy (split tool, Windows layout).
String dryRunStrategyNotes({
  required WriteStrategy strategy,
  required IsoProfile profile,
  required bool windowsHost,
  String? splitTool,
}) {
  final buffer = StringBuffer();
  if (strategy == WriteStrategy.windowsDualPartition) {
    buffer.writeln(
      'Windows layout: FAT32 WINBOOT + NTFS WINSETUP (installer copied intact).',
    );
  }
  if (strategy == WriteStrategy.multiIso) {
    buffer.writeln(
      'Multiboot layout: FAT32 $efiBootVolumeLabel (GRUB) + exFAT $isoBootVolumeLabel.',
    );
    buffer.writeln(
      'At boot, pick Windows Setup or a Linux live ISO from the GRUB menu.',
    );
  }
  if (profile.needsSplit && strategy == WriteStrategy.windowsFileCopy) {
    buffer.writeln('Split tool: ${splitTool ?? 'MISSING'}');
    if (windowsHost) {
      buffer.writeln(
        'DISM split is fallback only; a larger USB would use FAT32+NTFS instead.',
      );
    }
  }
  return buffer.toString().trim();
}

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

class MultiWriteRequest {
  const MultiWriteRequest({
    required this.isoPaths,
    required this.disk,
    this.confirmed = false,
    this.dryRun = false,
    this.allowAdvancedTargets = false,
    this.cancellation,
    this.existingMounts = const {},
  });

  final List<String> isoPaths;
  final UsbDisk disk;
  final bool confirmed;
  final bool dryRun;
  final bool allowAdvancedTargets;
  final CancellationToken? cancellation;
  final Map<String, IsoMount> existingMounts;
}

class MultiAddRequest {
  const MultiAddRequest({
    required this.isoPath,
    required this.disk,
    this.confirmed = false,
    this.dryRun = false,
    this.allowAdvancedTargets = false,
    this.cancellation,
    this.existingMount,
  });

  final String isoPath;
  final UsbDisk disk;
  final bool confirmed;
  final bool dryRun;
  final bool allowAdvancedTargets;
  final CancellationToken? cancellation;
  final IsoMount? existingMount;
}

class MultiRefreshRequest {
  const MultiRefreshRequest({
    required this.disk,
    this.dryRun = false,
    this.allowAdvancedTargets = false,
    this.cancellation,
  });

  final UsbDisk disk;
  final bool dryRun;
  final bool allowAdvancedTargets;
  final CancellationToken? cancellation;
}

class BootableWriter {
  BootableWriter({
    ProcessRunner? runner,
    HostPlatform? host,
    IsoInspector? inspector,
    GrubInstaller? grubInstaller,
  }) : _host = host ?? createHostPlatform(runner),
       _inspector = inspector ?? IsoInspector(),
       _grub = grubInstaller ?? GrubInstaller(runner: runner);

  final HostPlatform _host;
  final IsoInspector _inspector;
  final GrubInstaller _grub;

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
    IsoMount? mount;
    var shouldUnmount = false;
    late final IsoProfile profile;
    if (reuseMount) {
      mount = existing;
      profile = _inspector.inspectMounted(mount.mountPath);
    } else {
      try {
        mount = await _host.mountIso(request.isoPath);
        shouldUnmount = true;
        profile = _inspector.inspectMounted(mount.mountPath);
      } on UsbIsoException {
        final fromFile = _inspector.inspectIsoFile(request.isoPath);
        final fileStrategy = LayoutChooser.strategyFor(
          profile: fromFile,
          windowsHost: Platform.isWindows,
          diskSizeBytes: request.disk.sizeBytes,
          isoLooksHybrid: isoLooksLikeHybridDisk(request.isoPath),
        );
        if (fileStrategy != WriteStrategy.rawHybrid) {
          rethrow;
        }
        profile = fromFile;
      }
    }
    try {
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
        throw UsbIsoException(
          'Use writeMulti / make --iso a.iso --iso b.iso for a multiboot USB.',
        );
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
        final source = mount?.mountPath;
        if (source == null) {
          throw InvalidIsoException(
            'Could not mount this ISO to copy installer files.',
          );
        }
        await _ensureFat32Compatible(source, skipWim: needsSplit);
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

      final mounted = mount;
      if (mounted == null) {
        throw InvalidIsoException(
          'Could not mount this ISO to copy installer files.',
        );
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
          mounted.mountPath,
          volumes.bootMount,
          volumes.dataMount!,
          cancellation: request.cancellation,
        )) {
          yield progress;
        }
      } else {
        await for (final progress in _copyWithProgress(
          mounted.mountPath,
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
        sourceRoot: mounted.mountPath,
        volumes: volumes,
        profile: profile,
        strategy: strategy,
        needsSplit: needsSplit,
      );

      await _host.flushDisk(request.disk);
      yield* _eject(request);
    } finally {
      if (shouldUnmount && mount != null) {
        try {
          await _host.unmountIso(mount);
        } catch (_) {
          // Unmount is best-effort after a successful or failed write.
        }
      }
    }
  }

  /// Erases the USB and writes a GRUB menu plus Windows Setup and/or Linux ISOs.
  Stream<WriteProgress> writeMulti(MultiWriteRequest request) async* {
    if (!request.dryRun && !request.confirmed) {
      throw ConfirmationRequiredException(
        'Refusing to erase ${request.disk.id} without explicit confirmation.',
      );
    }

    Safety.ensureWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    for (final isoPath in request.isoPaths) {
      if (isoLivesOnAnyMount(isoPath, request.disk.mountPoints)) {
        throw UsbIsoException(
          'An ISO is on ${request.disk.id}. Copy the images to the computer '
          'first so they are not erased with the USB drive.',
        );
      }
    }
    await _host.verifyWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );

    yield const WriteProgress(
      step: WriteStep.validating,
      message: 'Checking the ISO images…',
      percent: 0.02,
    );

    final ownedMounts = <IsoMount>[];
    try {
      final drafts = <MultiIsoDraft>[];
      for (final isoPath in request.isoPaths) {
        request.cancellation?.throwIfCancelled();
        if (!File(isoPath).existsSync()) {
          throw InvalidIsoException('ISO not found: $isoPath');
        }
        drafts.add(await _inspectForMultiboot(request, isoPath, ownedMounts));
      }

      final plan = planMultiboot(
        drafts: drafts,
        diskSizeBytes: request.disk.sizeBytes,
      );

      if (request.dryRun) {
        yield WriteProgress(
          step: WriteStep.done,
          message: _multiDryRunSummary(request, plan),
          percent: 1,
        );
        return;
      }

      request.cancellation?.throwIfCancelled();
      yield WriteProgress(
        step: WriteStep.preparing,
        message:
            'Multiboot USB (${plan.items.length} images). Erasing ${request.disk.label}…',
        percent: 0.08,
      );
      yield WriteProgress(
        step: WriteStep.erasing,
        message:
            'Erasing ${request.disk.id} as FAT32 $efiBootVolumeLabel + exFAT $isoBootVolumeLabel…',
        percent: 0.12,
      );
      await _host.verifyWritable(
        request.disk,
        allowAdvancedTargets: request.allowAdvancedTargets,
      );
      request.cancellation?.throwIfCancelled();
      await _host.eraseAndFormat(request.disk, layout: DiskLayout.efiPlusExfat);
      request.cancellation?.throwIfCancelled(diskAlreadyErased: true);

      yield const WriteProgress(
        step: WriteStep.erasing,
        message: 'Waiting for the USB volumes…',
        percent: 0.18,
      );
      final volumes = await _host.waitForVolumeMount(
        request.disk,
        layout: DiskLayout.efiPlusExfat,
      );
      final dataMount = volumes.dataMount;
      if (dataMount == null) {
        throw UsbIsoException(
          'The exFAT $isoBootVolumeLabel volume did not appear after formatting.',
        );
      }

      yield const WriteProgress(
        step: WriteStep.copying,
        message: 'Installing the GRUB boot menu…',
        percent: 0.2,
      );
      final grubCfg = buildGrubConfig(plan);
      await _grub.install(
        espMount: volumes.bootMount,
        grubCfg: grubCfg,
        linuxMountPaths: [
          for (final item in plan.linux)
            if (item.mountPath != null) item.mountPath!,
        ],
        linuxIsoPaths: [for (final item in plan.linux) item.isoPath],
      );

      final isoDir = Directory(p.join(dataMount, multibootIsoFolder));
      await isoDir.create(recursive: true);

      yield* _copyStream(
        onProgress: (done, all) {
          final fraction = all == 0 ? 1.0 : done / all;
          return WriteProgress(
            step: WriteStep.copying,
            message: 'Copying installer files… ${(fraction * 100).round()}%',
            percent: 0.22 + (0.66 * fraction),
          );
        },
        copy: (onProgress) async {
          var done = 0;
          final windows = plan.windows;
          var payload = 0;
          for (final item in plan.linux) {
            payload += File(item.isoPath).lengthSync();
          }
          if (windows?.mountPath != null) {
            await for (final entity in Directory(
              windows!.mountPath!,
            ).list(recursive: true, followLinks: false)) {
              if (entity is File) {
                payload += await entity.length();
              }
            }
          }
          if (payload <= 0) {
            payload = 1;
          }

          for (final item in plan.linux) {
            request.cancellation?.throwIfCancelled(diskAlreadyErased: true);
            final dest = p.join(isoDir.path, item.usbIsoFileName);
            final before = done;
            await copyFileWithProgress(
              item.isoPath,
              dest,
              cancellation: request.cancellation,
              onProgress: (copiedBytes, _) {
                onProgress(before + copiedBytes, payload);
              },
            );
            done += File(item.isoPath).lengthSync();
            onProgress(done, payload);
          }

          if (windows?.mountPath != null) {
            request.cancellation?.throwIfCancelled(diskAlreadyErased: true);
            final before = done;
            await copyDirectory(
              windows!.mountPath!,
              dataMount,
              cancellation: request.cancellation,
              onProgress: (copiedBytes, _) {
                onProgress(before + copiedBytes, payload);
              },
            );
          }
        },
      );

      request.cancellation?.throwIfCancelled(diskAlreadyErased: true);
      yield const WriteProgress(
        step: WriteStep.verifying,
        message: 'Verifying the multiboot USB…',
        percent: 0.9,
      );
      _verifyMultiboot(volumes: volumes, plan: plan, grubCfg: grubCfg);

      await _host.flushDisk(request.disk);
      yield* _eject(requestAsWrite(request));
    } finally {
      for (final mount in ownedMounts) {
        try {
          await _host.unmountIso(mount);
        } catch (_) {
          // Best-effort.
        }
      }
    }
  }

  /// Copies one more ISO onto an existing multiboot USB without erasing it.
  Stream<WriteProgress> addIso(MultiAddRequest request) async* {
    if (!request.dryRun && !request.confirmed) {
      throw ConfirmationRequiredException(
        'Refusing to change ${request.disk.id} without explicit confirmation.',
      );
    }
    Safety.ensureWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    if (isoLivesOnAnyMount(request.isoPath, request.disk.mountPoints)) {
      throw UsbIsoException(
        'The ISO is on ${request.disk.id}. Copy it to the computer first.',
      );
    }
    await _host.verifyWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    if (!File(request.isoPath).existsSync()) {
      throw InvalidIsoException('ISO not found: ${request.isoPath}');
    }
    request.cancellation?.throwIfCancelled();

    yield const WriteProgress(
      step: WriteStep.validating,
      message: 'Checking the ISO and multiboot USB…',
      percent: 0.05,
    );

    final ownedMounts = <IsoMount>[];
    try {
      final draft = await _inspectForMultiboot(
        MultiWriteRequest(
          isoPaths: [request.isoPath],
          disk: request.disk,
          existingMounts: request.existingMount == null
              ? const {}
              : {request.isoPath: request.existingMount!},
        ),
        request.isoPath,
        ownedMounts,
      );
      final volumes = await _resolveMultibootVolumes(request.disk);
      final existing = planFromMultibootVolume(volumes.dataMount!);

      if (isWindowsInstallerKind(draft.profile.kind) &&
          existing.windows != null) {
        throw InvalidIsoException(
          'This USB already has a Windows installer. Only one Windows Setup '
          'can live at the volume root. Add a Linux live ISO instead.',
        );
      }
      if (!isWindowsInstallerKind(draft.profile.kind) &&
          draft.linuxBoot == null) {
        throw InvalidIsoException(
          '${p.basename(request.isoPath)} is not a Linux live image this app '
          'can add to the GRUB menu.',
        );
      }

      request.cancellation?.throwIfCancelled();
      ensureMultibootAddFits(
        diskSizeBytes: request.disk.sizeBytes,
        dataMount: volumes.dataMount!,
        incomingBytes: File(request.isoPath).lengthSync(),
      );

      if (request.dryRun) {
        yield WriteProgress(
          step: WriteStep.done,
          message:
              'Dry run — the USB will not be erased.\n'
              'Target: ${request.disk.label}\n'
              'Add: ${p.basename(request.isoPath)}\n'
              'Current menu:\n${existing.summary.isEmpty ? '  (empty)' : existing.summary}',
          percent: 1,
        );
        return;
      }

      request.cancellation?.throwIfCancelled();
      yield WriteProgress(
        step: WriteStep.copying,
        message: isWindowsInstallerKind(draft.profile.kind)
            ? 'Extracting Windows Setup onto the USB…'
            : 'Copying ${p.basename(request.isoPath)} to /isos…',
        percent: 0.2,
      );

      if (isWindowsInstallerKind(draft.profile.kind)) {
        if (draft.mountPath == null) {
          throw InvalidIsoException(
            'Could not mount ${p.basename(request.isoPath)} to copy Windows Setup.',
          );
        }
        await copyDirectory(
          draft.mountPath!,
          volumes.dataMount!,
          cancellation: request.cancellation,
        );
      } else {
        final isoDir = Directory(
          p.join(volumes.dataMount!, multibootIsoFolder),
        );
        await isoDir.create(recursive: true);
        final used = {
          for (final item in existing.linux) item.usbIsoFileName.toLowerCase(),
        };
        final name = uniqueIsoFileName(request.isoPath, used);
        await copyFileWithProgress(
          request.isoPath,
          p.join(isoDir.path, name),
          cancellation: request.cancellation,
        );
      }

      request.cancellation?.throwIfCancelled();
      yield const WriteProgress(
        step: WriteStep.verifying,
        message: 'Refreshing the GRUB menu…',
        percent: 0.85,
      );
      final plan = planFromMultibootVolume(volumes.dataMount!);
      ensureMultibootPlanNotEmpty(plan);
      await _writeGrubMenu(volumes, plan);
      _verifyMultiboot(
        volumes: volumes,
        plan: plan,
        grubCfg: buildGrubConfig(plan),
      );
      await _host.flushDisk(request.disk);
      yield const WriteProgress(
        step: WriteStep.done,
        message:
            'Added to the multiboot USB. Eject when you are done adding images, '
            'then boot the PC and pick an entry from the GRUB menu.',
        percent: 1,
      );
    } finally {
      for (final mount in ownedMounts) {
        try {
          await _host.unmountIso(mount);
        } catch (_) {}
      }
    }
  }

  /// Regenerates GRUB from the ISOs already on a multiboot USB (no erase).
  Stream<WriteProgress> refreshMenu(MultiRefreshRequest request) async* {
    Safety.ensureWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    await _host.verifyWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    yield const WriteProgress(
      step: WriteStep.validating,
      message: 'Reading the multiboot USB…',
      percent: 0.1,
    );
    request.cancellation?.throwIfCancelled();
    final volumes = await _resolveMultibootVolumes(request.disk);
    final plan = planFromMultibootVolume(volumes.dataMount!);
    ensureMultibootPlanNotEmpty(plan);
    if (request.dryRun) {
      yield WriteProgress(
        step: WriteStep.done,
        message:
            'Dry run — GRUB will not be rewritten.\n'
            'Target: ${request.disk.label}\n'
            'Menu:\n${plan.summary.isEmpty ? '  (empty)' : plan.summary}',
        percent: 1,
      );
      return;
    }
    request.cancellation?.throwIfCancelled();
    yield const WriteProgress(
      step: WriteStep.copying,
      message: 'Writing the GRUB menu…',
      percent: 0.5,
    );
    await _writeGrubMenu(volumes, plan);
    _verifyMultiboot(
      volumes: volumes,
      plan: plan,
      grubCfg: buildGrubConfig(plan),
    );
    await _host.flushDisk(request.disk);
    yield WriteProgress(
      step: WriteStep.done,
      message:
          'GRUB menu updated (${plan.items.length} ${plan.items.length == 1 ? 'entry' : 'entries'}).',
      percent: 1,
    );
  }

  Future<PreparedVolumes> _resolveMultibootVolumes(UsbDisk disk) async {
    final detected = detectMultibootMounts(disk.mountPoints);
    if (detected != null) {
      return detected;
    }
    try {
      return await _host.waitForVolumeMount(
        disk,
        layout: DiskLayout.efiPlusExfat,
      );
    } on UsbIsoException {
      throw UsbIsoException(
        'Disk ${disk.id} is not a multiboot USB (missing $efiBootVolumeLabel / '
        '$isoBootVolumeLabel). Create one first with '
        '`make --iso Windows.iso --iso ubuntu.iso`.',
      );
    }
  }

  Future<void> _writeGrubMenu(
    PreparedVolumes volumes,
    MultiIsoPlan plan,
  ) async {
    final cfg = buildGrubConfig(plan);
    await _grub.install(
      espMount: volumes.bootMount,
      grubCfg: cfg,
      linuxIsoPaths: [for (final item in plan.linux) item.isoPath],
    );
  }

  WriteRequest requestAsWrite(MultiWriteRequest request) {
    return WriteRequest(
      isoPath: request.isoPaths.first,
      disk: request.disk,
      confirmed: request.confirmed,
      dryRun: request.dryRun,
      allowAdvancedTargets: request.allowAdvancedTargets,
      cancellation: request.cancellation,
    );
  }

  Future<MultiIsoDraft> _inspectForMultiboot(
    MultiWriteRequest request,
    String isoPath,
    List<IsoMount> ownedMounts,
  ) async {
    final existing = request.existingMounts[isoPath];
    final reuse =
        existing != null &&
        p.equals(p.normalize(existing.isoPath), p.normalize(isoPath));
    if (reuse) {
      final profile = _inspector.inspectMounted(existing.mountPath);
      return MultiIsoDraft(
        isoPath: isoPath,
        profile: profile,
        linuxBoot: probeLinuxBootFromTree(existing.mountPath),
        mountPath: existing.mountPath,
      );
    }

    try {
      final mount = await _host.mountIso(isoPath);
      ownedMounts.add(mount);
      final profile = _inspector.inspectMounted(mount.mountPath);
      return MultiIsoDraft(
        isoPath: isoPath,
        profile: profile,
        linuxBoot: probeLinuxBootFromTree(mount.mountPath),
        mountPath: mount.mountPath,
      );
    } on UsbIsoException {
      final profile = _inspector.inspectIsoFile(isoPath);
      if (isWindowsInstallerKind(profile.kind)) {
        rethrow;
      }
      return MultiIsoDraft(
        isoPath: isoPath,
        profile: profile,
        linuxBoot: probeLinuxBootFromIso(isoPath),
      );
    }
  }

  String _multiDryRunSummary(MultiWriteRequest request, MultiIsoPlan plan) {
    final buffer = StringBuffer()
      ..writeln('Dry run — no disks will be changed.')
      ..writeln('Target: ${request.disk.label}')
      ..writeln('Strategy: multiIso')
      ..writeln(
        'Layout: FAT32 $efiBootVolumeLabel (GRUB) + exFAT $isoBootVolumeLabel',
      )
      ..writeln('Menu:')
      ..writeln(plan.summary)
      ..writeln(
        'Steps: erase EFI+exFAT → install GRUB → copy Linux ISOs → '
        '${plan.windows == null ? '' : 'extract Windows → '}'
        'write menu → eject.',
      );
    return buffer.toString().trim();
  }

  void _verifyMultiboot({
    required PreparedVolumes volumes,
    required MultiIsoPlan plan,
    required String grubCfg,
  }) {
    final efi = File(p.join(volumes.bootMount, 'EFI', 'BOOT', 'BOOTX64.EFI'));
    if (!efi.existsSync() || efi.lengthSync() <= 0) {
      throw UsbIsoException(
        'Verification failed: EFI/BOOT/BOOTX64.EFI is missing on the USB.',
      );
    }
    final cfg = File(p.join(volumes.bootMount, 'boot', 'grub', 'grub.cfg'));
    if (!cfg.existsSync() || !cfg.readAsStringSync().contains('menuentry')) {
      throw UsbIsoException(
        'Verification failed: boot/grub/grub.cfg is missing or empty.',
      );
    }
    if (!cfg.readAsStringSync().contains(
          plan.items.first.menuTitle.split('"').first,
        ) &&
        !grubCfg.contains('menuentry')) {
      throw UsbIsoException(
        'Verification failed: the GRUB menu is incomplete.',
      );
    }
    final data = volumes.dataMount;
    if (data == null) {
      throw UsbIsoException(
        'Verification failed: the ISO data volume is missing.',
      );
    }
    for (final item in plan.linux) {
      final iso = File(p.join(data, multibootIsoFolder, item.usbIsoFileName));
      if (!iso.existsSync() || iso.lengthSync() <= 0) {
        throw UsbIsoException(
          'Verification failed: ${item.usbIsoFileName} is missing on the USB.',
        );
      }
    }
    final windows = plan.windows;
    if (windows != null) {
      final sources = [
        File(p.join(data, 'sources', 'boot.wim')),
        File(p.join(data, 'Sources', 'boot.wim')),
        File(p.join(data, 'sources', 'install.wim')),
        File(p.join(data, 'Sources', 'install.wim')),
        File(p.join(data, 'sources', 'install.esd')),
        File(p.join(data, 'Sources', 'install.esd')),
      ];
      if (sources.every((file) => !file.existsSync())) {
        throw UsbIsoException(
          'Verification failed: Windows sources are missing on the USB.',
        );
      }
    }
  }

  Stream<WriteProgress> _writeRaw(
    WriteRequest request,
    IsoProfile profile,
    IsoMount? mount,
  ) async* {
    if (mount != null) {
      try {
        await _host.unmountIso(mount);
      } catch (_) {
        // The ISO file is read independently for the raw write.
      }
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

    if (Platform.isMacOS) {
      yield const WriteProgress(
        step: WriteStep.writing,
        message: 'Waiting for administrator approval to write the disk…',
        percent: 0.2,
      );
    } else {
      yield const WriteProgress(
        step: WriteStep.writing,
        message: 'Writing ISO image…',
        percent: 0.2,
      );
    }

    var written = 0;
    var total = File(request.isoPath).lengthSync();
    var lastPercent = -1;
    late final StreamController<WriteProgress> controller;
    controller = StreamController<WriteProgress>();
    final write = _host.writeRawImage(
      disk: request.disk,
      isoPath: request.isoPath,
      cancellation: request.cancellation,
      onProgress: (copied, size) {
        written = copied;
        total = size;
        if (!shouldEmitWritePercent(
          writtenBytes: copied,
          totalBytes: size,
          lastEmittedPercent: lastPercent,
        )) {
          return;
        }
        lastPercent = size == 0 ? 100 : ((copied * 100) ~/ size).clamp(0, 100);
        final fraction = size == 0 ? 1.0 : copied / size;
        if (!controller.isClosed) {
          controller.add(
            WriteProgress(
              step: WriteStep.writing,
              message: lastPercent == 0 && Platform.isMacOS
                  ? 'Waiting for administrator approval to write the disk…'
                  : 'Writing ISO image… $lastPercent%',
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
      WriteStrategy.multiIso =>
        'erase FAT32 EFI + exFAT → install GRUB → copy Linux ISOs → extract Windows → write menu → eject',
      WriteStrategy.unsupported => 'unsupported',
    };
    final buffer = StringBuffer()
      ..writeln('Dry run — no disks will be changed.')
      ..writeln('ISO: ${request.isoPath}')
      ..writeln('Target: ${request.disk.label}')
      ..writeln(profile.summary)
      ..writeln('Strategy: ${strategy.name}')
      ..writeln('Steps: $layout.');
    final notes = dryRunStrategyNotes(
      strategy: strategy,
      profile: profile,
      windowsHost: Platform.isWindows,
      splitTool: splitTool,
    );
    if (notes.isNotEmpty) {
      buffer.writeln(notes);
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
