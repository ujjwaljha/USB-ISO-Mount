import 'dart:io';

import 'package:path/path.dart' as p;

import 'exceptions.dart';
import 'models/windows_iso_info.dart';

class WindowsIsoValidator {
  /// Inspects an already-mounted Windows ISO directory.
  WindowsIsoInfo inspectMounted(String mountPath) {
    final root = Directory(mountPath);
    if (!root.existsSync()) {
      throw InvalidIsoException('Mount path does not exist: $mountPath');
    }

    final efiCandidates = [
      p.join(mountPath, 'efi', 'boot', 'bootx64.efi'),
      p.join(mountPath, 'EFI', 'Boot', 'bootx64.efi'),
      p.join(mountPath, 'EFI', 'BOOT', 'BOOTX64.EFI'),
    ];
    final hasEfi = efiCandidates.any((path) => File(path).existsSync());

    final wim = _firstExistingFile([
      p.join(mountPath, 'sources', 'install.wim'),
      p.join(mountPath, 'Sources', 'install.wim'),
    ]);
    final esd = _firstExistingFile([
      p.join(mountPath, 'sources', 'install.esd'),
      p.join(mountPath, 'Sources', 'install.esd'),
    ]);

    if (wim != null) {
      return WindowsIsoInfo(
        mountPath: mountPath,
        hasEfiBoot: hasEfi,
        installKind: WindowsInstallImageKind.wim,
        installImagePath: wim.path,
        installImageSize: wim.lengthSync(),
      );
    }
    if (esd != null) {
      return WindowsIsoInfo(
        mountPath: mountPath,
        hasEfiBoot: hasEfi,
        installKind: WindowsInstallImageKind.esd,
        installImagePath: esd.path,
        installImageSize: esd.lengthSync(),
      );
    }

    return WindowsIsoInfo(
      mountPath: mountPath,
      hasEfiBoot: hasEfi,
      installKind: WindowsInstallImageKind.none,
      installImagePath: null,
      installImageSize: 0,
    );
  }

  void ensureValid(WindowsIsoInfo info) {
    if (!info.hasEfiBoot) {
      throw InvalidIsoException(
        'This ISO is missing EFI boot files (efi/boot/bootx64.efi). '
        'It does not look like a Windows 10/11 installer.',
      );
    }
    if (info.installKind == WindowsInstallImageKind.none) {
      throw InvalidIsoException(
        'This ISO is missing sources/install.wim and sources/install.esd. '
        'It does not look like a Windows 10/11 installer.',
      );
    }
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
