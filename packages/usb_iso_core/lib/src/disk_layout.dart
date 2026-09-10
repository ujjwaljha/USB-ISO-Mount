/// Partition layout used when preparing a USB for a file-copy write.
enum DiskLayout {
  /// Single GPT FAT32 volume (`WINSETUP`).
  fat32,

  /// Small FAT32 boot volume (`WINBOOT`) plus NTFS data (`WINSETUP`).
  fat32PlusNtfs,

  /// FAT32 EFI System Partition (`EFIBOOT`) plus exFAT ISO/data (`ISOBOOT`).
  efiPlusExfat,
}

/// Mount points after [DiskLayout] formatting.
class PreparedVolumes {
  const PreparedVolumes({required this.bootMount, this.dataMount});

  /// FAT32 volume that holds EFI boot files.
  final String bootMount;

  /// Data volume for oversized installer files or multi-ISO payloads.
  ///
  /// Set for [DiskLayout.fat32PlusNtfs] (NTFS) and
  /// [DiskLayout.efiPlusExfat] (exFAT).
  final String? dataMount;
}

/// True when [layout] creates a FAT32 boot volume plus a separate data volume.
bool isDualVolumeLayout(DiskLayout layout) {
  return layout == DiskLayout.fat32PlusNtfs ||
      layout == DiskLayout.efiPlusExfat;
}

/// Boot-volume label written by [DiskLayout] formatting.
String bootVolumeLabelFor(DiskLayout layout) {
  return switch (layout) {
    DiskLayout.fat32PlusNtfs => 'WINBOOT',
    DiskLayout.efiPlusExfat => 'EFIBOOT',
    DiskLayout.fat32 => 'WINSETUP',
  };
}

/// Data-volume label written by dual-volume [DiskLayout] formatting.
String? dataVolumeLabelFor(DiskLayout layout) {
  return switch (layout) {
    DiskLayout.fat32PlusNtfs => 'WINSETUP',
    DiskLayout.efiPlusExfat => 'ISOBOOT',
    DiskLayout.fat32 => null,
  };
}
