import 'dart:io';

import 'exceptions.dart';

/// Normalizes user-supplied disk identifiers to the platform's whole-disk id.
class DiskId {
  DiskId._();

  /// macOS: `disk4`. Windows: `1`.
  static String normalize(String raw, {String? operatingSystem}) {
    final os = operatingSystem ?? Platform.operatingSystem;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw UsbIsoException('Disk id is empty.');
    }

    if (os == 'macos') {
      var id = trimmed.replaceFirst(RegExp(r'^/dev/r?'), '');
      if (RegExp(r'^disk\d+s\d+$').hasMatch(id)) {
        throw UsbIsoException(
          'Use the whole disk (for example disk4), not a partition ($id).',
        );
      }
      if (!RegExp(r'^disk\d+$').hasMatch(id)) {
        throw UsbIsoException('Expected a disk id like disk4, got "$raw".');
      }
      return id;
    }

    if (os == 'windows') {
      final match = RegExp(
        r'(?:\\\\\.\\)?(?:physicaldrive|disk)?\s*(\d+)$',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (match == null) {
        throw UsbIsoException(
          'Expected a disk number like 1 or PhysicalDrive1, got "$raw".',
        );
      }
      return match.group(1)!;
    }

    throw UnsupportedPlatformException('Disk ids are not supported on $os.');
  }
}
