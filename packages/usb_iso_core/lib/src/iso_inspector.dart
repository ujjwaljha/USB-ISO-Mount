import 'dart:io';

import 'package:path/path.dart' as p;

import 'bytes.dart';
import 'exceptions.dart';
import 'hybrid_iso.dart';
import 'iso9660.dart';
import 'models/iso_profile.dart';
import 'models/windows_iso_info.dart';

class IsoInspector {
  /// Inspects an already-mounted ISO directory.
  IsoProfile inspectMounted(String mountPath) {
    final root = Directory(mountPath);
    if (!root.existsSync()) {
      throw InvalidIsoException('Mount path does not exist: $mountPath');
    }

    final hasX64Efi =
        _firstExistingFile([
          p.join(mountPath, 'efi', 'boot', 'bootx64.efi'),
          p.join(mountPath, 'EFI', 'Boot', 'bootx64.efi'),
          p.join(mountPath, 'EFI', 'BOOT', 'BOOTX64.EFI'),
        ]) !=
        null;
    final hasArmEfi =
        _firstExistingFile([
          p.join(mountPath, 'efi', 'boot', 'bootaa64.efi'),
          p.join(mountPath, 'EFI', 'Boot', 'bootaa64.efi'),
          p.join(mountPath, 'EFI', 'BOOT', 'BOOTAA64.EFI'),
        ]) !=
        null;

    final wim = _firstExistingFile([
      p.join(mountPath, 'sources', 'install.wim'),
      p.join(mountPath, 'Sources', 'install.wim'),
    ]);
    final esd = _firstExistingFile([
      p.join(mountPath, 'sources', 'install.esd'),
      p.join(mountPath, 'Sources', 'install.esd'),
    ]);
    final bootWim = _firstExistingFile([
      p.join(mountPath, 'sources', 'boot.wim'),
      p.join(mountPath, 'Sources', 'boot.wim'),
    ]);

    final linuxMarkers = _linuxMarkers(mountPath);

    WindowsInstallImageKind installKind;
    String? installPath;
    var installSize = 0;
    if (wim != null) {
      installKind = WindowsInstallImageKind.wim;
      installPath = wim.path;
      installSize = wim.lengthSync();
    } else if (esd != null) {
      installKind = WindowsInstallImageKind.esd;
      installPath = esd.path;
      installSize = esd.lengthSync();
    } else if (bootWim != null) {
      installKind = WindowsInstallImageKind.bootWim;
      installPath = bootWim.path;
      installSize = bootWim.lengthSync();
    } else {
      installKind = WindowsInstallImageKind.none;
    }

    final kind = _kind(
      hasX64Efi: hasX64Efi,
      hasArmEfi: hasArmEfi,
      installKind: installKind,
      linuxMarkers: linuxMarkers,
    );

    return IsoProfile(
      mountPath: mountPath,
      kind: kind,
      hasX64Efi: hasX64Efi,
      hasArmEfi: hasArmEfi,
      installKind: installKind,
      installImagePath: installPath,
      installImageSize: installSize,
      bootWimPath: bootWim?.path,
      linuxMarkers: linuxMarkers,
      hasOversizedFat32File: _hasOversizedFat32File(mountPath),
    );
  }

  /// Classifies an ISO from the file when the OS cannot mount it as a volume.
  ///
  /// Used for hybrid Linux images on macOS (`hdiutil: no mountable file systems`).
  IsoProfile inspectIsoFile(String isoPath) {
    if (!File(isoPath).existsSync()) {
      throw InvalidIsoException('ISO not found: $isoPath');
    }
    final info = readIso9660Info(isoPath);
    if (info == null) {
      throw InvalidIsoException('Not a readable ISO 9660 image: $isoPath');
    }
    final hybrid = isoLooksLikeHybridDisk(isoPath);
    final linuxMarkers = info.rootNames
        .where(
          (name) =>
              name == 'casper' ||
              name == 'live' ||
              name == 'isolinux' ||
              name == '.disk',
        )
        .toList();
    final kind = info.hasWindowsSources
        ? IsoKind.unknown
        : (info.hasLinuxMarkers ||
              (hybrid && looksLikeLinuxVolumeId(info.volumeId)))
        ? IsoKind.linuxHybrid
        : hybrid
        ? IsoKind.genericUefi
        : IsoKind.unknown;
    return IsoProfile(
      mountPath: isoPath,
      kind: kind,
      hasX64Efi: info.rootNames.contains('efi'),
      hasArmEfi: false,
      installKind: WindowsInstallImageKind.none,
      installImagePath: null,
      installImageSize: 0,
      linuxMarkers: linuxMarkers.isEmpty && kind == IsoKind.linuxHybrid
          ? [info.volumeId]
          : linuxMarkers,
      hasOversizedFat32File: false,
    );
  }

  IsoKind _kind({
    required bool hasX64Efi,
    required bool hasArmEfi,
    required WindowsInstallImageKind installKind,
    required List<String> linuxMarkers,
  }) {
    final hasEfi = hasX64Efi || hasArmEfi;
    final isWindowsInstall =
        installKind == WindowsInstallImageKind.wim ||
        installKind == WindowsInstallImageKind.esd;

    if (isWindowsInstall && hasEfi) {
      if (hasArmEfi && !hasX64Efi) {
        return IsoKind.windowsArm;
      }
      return IsoKind.windowsX64;
    }
    if (installKind == WindowsInstallImageKind.bootWim && hasEfi) {
      return IsoKind.windowsPe;
    }
    if (linuxMarkers.isNotEmpty && !isWindowsInstall) {
      return IsoKind.linuxHybrid;
    }
    if (hasEfi) {
      return IsoKind.genericUefi;
    }
    return IsoKind.unknown;
  }

  List<String> _linuxMarkers(String mountPath) {
    const names = ['casper', 'live', 'isolinux', '.disk'];
    final found = <String>[];
    final root = Directory(mountPath);
    if (!root.existsSync()) {
      return found;
    }
    final entries = <String>{};
    for (final entity in root.listSync(followLinks: false)) {
      entries.add(p.basename(entity.path).toLowerCase());
    }
    for (final name in names) {
      if (entries.contains(name)) {
        found.add(name);
      }
    }
    return found;
  }

  bool _hasOversizedFat32File(String mountPath) {
    final root = Directory(mountPath);
    if (!root.existsSync()) {
      return false;
    }
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is File && entity.lengthSync() > fat32MaxFileBytes) {
        return true;
      }
    }
    return false;
  }

  File? _firstExistingFile(List<String> paths) {
    for (final path in paths) {
      final file = File(path);
      if (file.existsSync()) {
        return file;
      }
    }
    return null;
  }
}
