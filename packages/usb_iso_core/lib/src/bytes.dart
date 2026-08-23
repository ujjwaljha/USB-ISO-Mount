/// FAT32 cannot store a file of 4 GiB or larger.
const int fat32MaxFileBytes = (4 * 1024 * 1024 * 1024) - 1;

/// Split size in MiB, kept safely under the FAT32 file limit.
const int wimSplitSizeMiB = 3800;

/// Windows `Format-Volume` FAT32 is unreliable above ~32 GB.
const int windowsFat32PartitionMaxBytes = 30 * 1024 * 1024 * 1024;

/// FAT32 boot partition for dual-layout Windows USBs (fits `boot.wim` + EFI).
const int windowsFat32BootPartitionBytes = 3584 * 1024 * 1024;

/// Raw ISO writes use large blocks so `/dev/rdisk` and PhysicalDrive stay sequential.
const int rawWriteChunkBytes = 8 * 1024 * 1024;

String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

bool asBool(dynamic value) {
  if (value == true || value == 1) {
    return true;
  }
  if (value is String) {
    final normalized = value.toLowerCase();
    return normalized == 'true' || normalized == 'yes' || normalized == '1';
  }
  return false;
}

int asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse('$value') ?? 0;
}

String asString(dynamic value) => value == null ? '' : '$value';
