import '../bytes.dart';
import 'windows_iso_info.dart';

enum IsoKind {
  windowsX64,
  windowsArm,
  windowsPe,
  linuxHybrid,
  genericUefi,
  unknown,
}

enum WriteStrategy {
  windowsFileCopy,
  windowsDualPartition,
  rawHybrid,
  multiIso,
  unsupported,
}

/// Classification of a mounted installer / live ISO.
class IsoProfile {
  const IsoProfile({
    required this.mountPath,
    required this.kind,
    required this.hasX64Efi,
    required this.hasArmEfi,
    required this.installKind,
    required this.installImagePath,
    required this.installImageSize,
    this.bootWimPath,
    this.linuxMarkers = const [],
    this.hasOversizedFat32File = false,
  });

  final String mountPath;
  final IsoKind kind;
  final bool hasX64Efi;
  final bool hasArmEfi;
  final WindowsInstallImageKind installKind;
  final String? installImagePath;
  final int installImageSize;
  final String? bootWimPath;
  final List<String> linuxMarkers;
  final bool hasOversizedFat32File;

  bool get hasEfiBoot => hasX64Efi || hasArmEfi;

  bool get needsSplit =>
      (installKind == WindowsInstallImageKind.wim ||
          installKind == WindowsInstallImageKind.esd) &&
      installImageSize > fat32MaxFileBytes;

  bool get hasOversizedInstallImage =>
      installImageSize > fat32MaxFileBytes &&
      (installKind == WindowsInstallImageKind.wim ||
          installKind == WindowsInstallImageKind.esd);

  String get kindLabel {
    switch (kind) {
      case IsoKind.windowsX64:
        return 'Windows x64 installer';
      case IsoKind.windowsArm:
        return 'Windows ARM installer';
      case IsoKind.windowsPe:
        return 'Windows PE / recovery';
      case IsoKind.linuxHybrid:
        return 'Linux live ISO';
      case IsoKind.genericUefi:
        return 'UEFI boot image';
      case IsoKind.unknown:
        return 'Unknown ISO';
    }
  }

  String get summary {
    final efi = hasEfiBoot
        ? (hasX64Efi && hasArmEfi
              ? 'UEFI x64+ARM boot files'
              : hasArmEfi
              ? 'UEFI ARM boot files'
              : 'UEFI x64 boot files')
        : 'no EFI boot files';
    switch (kind) {
      case IsoKind.windowsX64:
      case IsoKind.windowsArm:
        final image = installKind == WindowsInstallImageKind.none
            ? 'missing install.wim/esd'
            : '${installKind.name.toUpperCase()} ${formatBytes(installImageSize)}';
        final split = needsSplit
            ? 'oversize image needs FAT32 split or NTFS data partition'
            : 'no WIM split needed';
        return '$kindLabel; $image; $efi; $split';
      case IsoKind.windowsPe:
        return '$kindLabel; $efi; file-copy write';
      case IsoKind.linuxHybrid:
        return '$kindLabel; raw disk write'
            '${linuxMarkers.isEmpty ? '' : ' (${linuxMarkers.join(', ')})'}';
      case IsoKind.genericUefi:
        return '$kindLabel; $efi; file-copy unless the ISO is a hybrid disk image';
      case IsoKind.unknown:
        return '$kindLabel; $efi; not a supported installer or live image';
    }
  }

  /// Dry-run style line for the chosen write strategy.
  String layoutSummary(WriteStrategy strategy) {
    switch (strategy) {
      case WriteStrategy.windowsDualPartition:
        return 'Layout: FAT32+NTFS';
      case WriteStrategy.windowsFileCopy:
        return needsSplit
            ? 'Layout: FAT32, will split WIM'
            : 'Layout: FAT32 file copy';
      case WriteStrategy.rawHybrid:
        return 'Layout: raw ISO write';
      case WriteStrategy.multiIso:
        return 'Layout: GRUB menu, FAT32 EFIBOOT + exFAT ISOBOOT';
      case WriteStrategy.unsupported:
        return 'Layout: unsupported';
    }
  }

  String get unsupportedMessage {
    if (!hasEfiBoot &&
        installKind == WindowsInstallImageKind.none &&
        linuxMarkers.isEmpty) {
      return 'This ISO is missing EFI boot files and installer sources. '
          'It does not look like a Windows, Windows PE, or Linux live image.';
    }
    if (!hasEfiBoot) {
      return 'This ISO is missing EFI boot files '
          '(efi/boot/bootx64.efi or bootaa64.efi).';
    }
    return 'This ISO is not a supported bootable image.';
  }

  WindowsIsoInfo toWindowsIsoInfo() {
    return WindowsIsoInfo(
      mountPath: mountPath,
      hasEfiBoot: hasEfiBoot,
      installKind: installKind,
      installImagePath: installImagePath,
      installImageSize: installImageSize,
    );
  }
}
