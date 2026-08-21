import '../bytes.dart';

enum WindowsInstallImageKind { wim, esd, none }

/// Result of inspecting a mounted Windows installer ISO.
class WindowsIsoInfo {
  const WindowsIsoInfo({
    required this.mountPath,
    required this.hasEfiBoot,
    required this.installKind,
    required this.installImagePath,
    required this.installImageSize,
  });

  final String mountPath;
  final bool hasEfiBoot;
  final WindowsInstallImageKind installKind;
  final String? installImagePath;
  final int installImageSize;

  bool get isValid =>
      hasEfiBoot &&
      installKind != WindowsInstallImageKind.none &&
      installImagePath != null;

  bool get needsSplit =>
      installKind == WindowsInstallImageKind.wim &&
      installImageSize > fat32MaxFileBytes;

  String get summary {
    final image = installKind == WindowsInstallImageKind.none
        ? 'missing install.wim/esd'
        : '${installKind.name.toUpperCase()} ${formatBytes(installImageSize)}';
    final efi = hasEfiBoot ? 'UEFI boot files present' : 'no EFI boot files';
    final split = needsSplit
        ? 'will split WIM for FAT32'
        : 'no WIM split needed';
    return '$image; $efi; $split';
  }
}
