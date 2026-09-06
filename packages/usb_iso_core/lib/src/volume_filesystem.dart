import 'dart:io';

import 'exceptions.dart';

/// Filesystem used when formatting a USB as a data volume (not a bootable ISO).
enum VolumeFilesystem {
  /// Most compatible. Files cannot be 4 GiB or larger.
  fat32,

  /// Large files, widely supported on macOS, Windows, cameras, and TVs.
  exfat,

  /// Windows-native. Not formattable on macOS without extra tools.
  ntfs,
}

extension VolumeFilesystemX on VolumeFilesystem {
  String get displayName => switch (this) {
    VolumeFilesystem.fat32 => 'FAT32',
    VolumeFilesystem.exfat => 'exFAT',
    VolumeFilesystem.ntfs => 'NTFS',
  };

  /// CLI / API name (`fat32`, `exfat`, `ntfs`).
  String get cliName => name;

  int get maxLabelLength => switch (this) {
    VolumeFilesystem.fat32 => 11,
    VolumeFilesystem.exfat => 15,
    VolumeFilesystem.ntfs => 32,
  };

  /// `diskutil` filesystem name on macOS.
  String get macosDiskutilName => switch (this) {
    VolumeFilesystem.fat32 => 'FAT32',
    VolumeFilesystem.exfat => 'ExFAT',
    VolumeFilesystem.ntfs => 'NTFS',
  };

  /// `Format-Volume -FileSystem` name on Windows.
  String get windowsFormatName => switch (this) {
    VolumeFilesystem.fat32 => 'FAT32',
    VolumeFilesystem.exfat => 'exFAT',
    VolumeFilesystem.ntfs => 'NTFS',
  };

  bool get isSupportedOnThisHost => isSupportedOn(Platform.operatingSystem);

  bool isSupportedOn(String operatingSystem) {
    if (this == VolumeFilesystem.ntfs && operatingSystem == 'macos') {
      return false;
    }
    return true;
  }

  String get unsupportedHostMessage =>
      'macOS cannot format NTFS volumes. Choose FAT32 or exFAT.';
}

/// Parses `fat32`, `exfat`, `ntfs` (any case, with or without punctuation).
VolumeFilesystem parseVolumeFilesystem(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return switch (normalized) {
    'fat32' || 'fat' || 'vfat' || 'msdos' => VolumeFilesystem.fat32,
    'exfat' => VolumeFilesystem.exfat,
    'ntfs' => VolumeFilesystem.ntfs,
    _ => throw UsbIsoException(
      'Unknown filesystem "$value". Use fat32, exfat, or ntfs.',
    ),
  };
}

/// Default volume name when the user does not supply one.
const String defaultVolumeLabel = 'USB';

/// Strips illegal characters and truncates to the filesystem limit.
String sanitizeVolumeLabel(String raw, VolumeFilesystem filesystem) {
  var cleaned = raw.trim().replaceAll(RegExp(r'["*/:<>?\\|.,;+=\[\]]'), '');
  cleaned = cleaned.replaceAll(RegExp(r'[\x00-\x1f]'), '');
  if (filesystem == VolumeFilesystem.fat32) {
    cleaned = cleaned.toUpperCase();
  }
  if (cleaned.length > filesystem.maxLabelLength) {
    cleaned = cleaned.substring(0, filesystem.maxLabelLength).trimRight();
  }
  if (cleaned.isEmpty) {
    return defaultVolumeLabel;
  }
  return cleaned;
}
