import 'dart:io';

import 'package:path/path.dart' as p;

import 'bytes.dart';
import 'disk_layout.dart';
import 'exceptions.dart';
import 'linux_boot_files.dart';
import 'models/iso_profile.dart';
import 'models/windows_iso_info.dart';
import 'multiboot_plan.dart';

/// Headroom so an add is not packed flush against the disk size.
const int multibootAddSlackBytes = 64 * 1024 * 1024;

/// Finds already-mounted EFIBOOT + ISOBOOT volumes from [mountPoints].
PreparedVolumes? detectMultibootMounts(Iterable<String> mountPoints) {
  String? boot;
  String? data;
  for (final mount in mountPoints) {
    if (mount.isEmpty) {
      continue;
    }
    if (_looksLikeEsp(mount)) {
      boot = mount;
    }
    if (_looksLikeIsoData(mount)) {
      data = mount;
    }
  }
  if (boot != null && data != null && !_samePath(boot, data)) {
    return PreparedVolumes(bootMount: boot, dataMount: data);
  }
  return null;
}

bool isMultibootDisk(Iterable<String> mountPoints) {
  return detectMultibootMounts(mountPoints) != null;
}

/// True when at least one mount looks like this app's GRUB ESP or `/isos`.
///
/// Used by the GUI so Add/Refresh stay visible when only ISOBOOT is mounted.
/// A regular Windows installer USB (sources, no `/isos`, no GRUB) is ignored.
bool looksLikeMultibootDisk(Iterable<String> mountPoints) {
  if (detectMultibootMounts(mountPoints) != null) {
    return true;
  }
  for (final mount in mountPoints) {
    if (mount.isEmpty) {
      continue;
    }
    if (_looksLikeEsp(mount) ||
        Directory(p.join(mount, multibootIsoFolder)).existsSync()) {
      return true;
    }
  }
  return false;
}

bool _looksLikeEsp(String mount) {
  // GRUB's config is unique to the EFI partition. Do not treat Windows
  // Setup's efi/boot/bootx64.efi on the data volume as the ESP.
  return File(p.join(mount, 'boot', 'grub', 'grub.cfg')).existsSync();
}

bool _looksLikeIsoData(String mount) {
  return Directory(p.join(mount, multibootIsoFolder)).existsSync() ||
      _windowsSourceFile(mount) != null;
}

bool _samePath(String a, String b) {
  return p.equals(p.normalize(a), p.normalize(b));
}

File? _firstExisting(List<String> paths) {
  for (final path in paths) {
    final file = File(path);
    if (file.existsSync()) {
      return file;
    }
  }
  return null;
}

File? _windowsSourceFile(String dataMount) {
  return _firstExisting([
    p.join(dataMount, 'sources', 'boot.wim'),
    p.join(dataMount, 'Sources', 'boot.wim'),
    p.join(dataMount, 'sources', 'install.wim'),
    p.join(dataMount, 'Sources', 'install.wim'),
    p.join(dataMount, 'sources', 'install.esd'),
    p.join(dataMount, 'Sources', 'install.esd'),
  ]);
}

IsoProfile? windowsProfileFromVolume(String dataMount) {
  final source = _windowsSourceFile(dataMount);
  if (source == null) {
    return null;
  }
  final name = p.basename(source.path).toLowerCase();
  final kind = name == 'install.esd'
      ? WindowsInstallImageKind.esd
      : name == 'install.wim'
      ? WindowsInstallImageKind.wim
      : WindowsInstallImageKind.bootWim;
  final bootWim = _firstExisting([
    p.join(dataMount, 'sources', 'boot.wim'),
    p.join(dataMount, 'Sources', 'boot.wim'),
  ]);
  final hasX64 =
      _firstExisting([
        p.join(dataMount, 'efi', 'boot', 'bootx64.efi'),
        p.join(dataMount, 'EFI', 'BOOT', 'BOOTX64.EFI'),
        p.join(dataMount, 'EFI', 'Boot', 'bootx64.efi'),
      ]) !=
      null;
  final hasArm =
      _firstExisting([
        p.join(dataMount, 'efi', 'boot', 'bootaa64.efi'),
        p.join(dataMount, 'EFI', 'BOOT', 'BOOTAA64.EFI'),
      ]) !=
      null;
  return IsoProfile(
    mountPath: dataMount,
    kind: kind == WindowsInstallImageKind.bootWim && name != 'install.wim'
        ? IsoKind.windowsPe
        : hasArm && !hasX64
        ? IsoKind.windowsArm
        : IsoKind.windowsX64,
    hasX64Efi: hasX64,
    hasArmEfi: hasArm,
    installKind: kind,
    installImagePath: source.path,
    installImageSize: source.lengthSync(),
    bootWimPath: bootWim?.path,
  );
}

/// Rebuilds a menu plan from what is already on the exFAT data volume.
MultiIsoPlan planFromMultibootVolume(String dataMount) {
  if (!Directory(dataMount).existsSync()) {
    throw UsbIsoException('Multiboot data volume is not mounted: $dataMount');
  }
  final items = <MultiIsoItem>[];
  final windows = windowsProfileFromVolume(dataMount);
  if (windows != null) {
    items.add(
      MultiIsoItem(
        isoPath: dataMount,
        profile: windows,
        role: MultiIsoRole.windows,
        menuTitle: windows.kindLabel,
        usbIsoFileName: 'windows',
        mountPath: dataMount,
      ),
    );
  }

  final skipped = <String>[];
  final isoDir = Directory(p.join(dataMount, multibootIsoFolder));
  if (isoDir.existsSync()) {
    final files = isoDir.listSync().whereType<File>().toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final file in files) {
      if (!file.path.toLowerCase().endsWith('.iso')) {
        continue;
      }
      final boot = probeLinuxBootFromIso(file.path);
      if (boot == null) {
        skipped.add(p.basename(file.path));
        continue;
      }
      items.add(
        MultiIsoItem(
          isoPath: file.path,
          profile: IsoProfile(
            mountPath: file.path,
            kind: IsoKind.linuxHybrid,
            hasX64Efi: true,
            hasArmEfi: false,
            installKind: WindowsInstallImageKind.none,
            installImagePath: null,
            installImageSize: 0,
            linuxMarkers: const [multibootIsoFolder],
          ),
          role: MultiIsoRole.linux,
          menuTitle: 'Linux live ISO: ${p.basenameWithoutExtension(file.path)}',
          usbIsoFileName: p.basename(file.path),
          linuxBoot: boot,
        ),
      );
    }
  }

  return MultiIsoPlan(
    items: items,
    requiredBytes: 0,
    skippedIsoFileNames: skipped,
  );
}

/// Sum of regular files under [root] (used to estimate free space on ISOBOOT).
int volumeUsedBytes(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) {
    return 0;
  }
  var total = 0;
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        total += entity.lengthSync();
      } catch (_) {
        // Skip files that disappear mid-walk.
      }
    }
  }
  return total;
}

/// Throws if [incomingBytes] will not fit on the multiboot data volume.
void ensureMultibootAddFits({
  required int diskSizeBytes,
  required String dataMount,
  required int incomingBytes,
}) {
  final used = volumeUsedBytes(dataMount);
  final usable = diskSizeBytes - efiSystemPartitionBytes;
  final free = usable - used;
  if (incomingBytes + multibootAddSlackBytes > free) {
    throw UsbIsoException(
      'This USB does not have enough free space for '
      '${formatBytes(incomingBytes)}. About '
      '${formatBytes(free < 0 ? 0 : free)} is left after the EFI partition '
      'and files already on the stick.',
    );
  }
}

void ensureMultibootPlanNotEmpty(MultiIsoPlan plan) {
  if (plan.items.isEmpty) {
    throw UsbIsoException(
      'No Windows Setup or Linux live ISOs were found on this USB. '
      'Copy an image into /$multibootIsoFolder or add one with `add --iso`.',
    );
  }
}
