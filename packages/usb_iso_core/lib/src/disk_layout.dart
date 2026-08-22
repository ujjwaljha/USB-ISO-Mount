/// Partition layout used when preparing a USB for a file-copy write.
enum DiskLayout {
  /// Single GPT FAT32 volume (`WINSETUP`).
  fat32,

  /// Small FAT32 boot volume (`WINBOOT`) plus NTFS data (`WINSETUP`).
  fat32PlusNtfs,
}

/// Mount points after [DiskLayout] formatting.
class PreparedVolumes {
  const PreparedVolumes({required this.bootMount, this.dataMount});

  /// FAT32 volume that holds EFI boot files.
  final String bootMount;

  /// NTFS volume for oversized installer files, if [DiskLayout.fat32PlusNtfs].
  final String? dataMount;
}
