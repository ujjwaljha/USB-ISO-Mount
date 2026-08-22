import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'exceptions.dart';
import 'hybrid_iso.dart';

const int iso9660SectorSize = 2048;
const int iso9660PvdOffset = 16 * iso9660SectorSize;

class Iso9660Info {
  const Iso9660Info({required this.volumeId, required this.rootNames});

  final String volumeId;
  final List<String> rootNames;

  bool get hasLinuxMarkers => rootNames.any(
    (name) =>
        name == 'casper' ||
        name == 'live' ||
        name == 'isolinux' ||
        name == '.disk',
  );

  bool get hasWindowsSources => rootNames.contains('sources');
}

/// Reads the ISO 9660 primary volume descriptor and root directory names.
Iso9660Info? readIso9660Info(String isoPath) {
  final file = File(isoPath);
  if (!file.existsSync() || file.lengthSync() < iso9660PvdOffset + 190) {
    return null;
  }
  final handle = file.openSync();
  try {
    handle.setPositionSync(iso9660PvdOffset);
    final pvd = handle.readSync(iso9660SectorSize);
    if (pvd.length < 190 ||
        pvd[0] != 1 ||
        ascii.decode(pvd.sublist(1, 6), allowInvalid: true) != 'CD001') {
      return null;
    }
    final volumeId = ascii
        .decode(pvd.sublist(40, 72), allowInvalid: true)
        .trim();
    final rootLength = pvd[156];
    if (rootLength < 34) {
      return Iso9660Info(volumeId: volumeId, rootNames: const []);
    }
    final lba = ByteData.sublistView(
      Uint8List.fromList(pvd),
      158,
      162,
    ).getUint32(0, Endian.little);
    final dataLength = ByteData.sublistView(
      Uint8List.fromList(pvd),
      166,
      170,
    ).getUint32(0, Endian.little);
    if (lba == 0 || dataLength == 0) {
      return Iso9660Info(volumeId: volumeId, rootNames: const []);
    }
    handle.setPositionSync(lba * iso9660SectorSize);
    final directory = handle.readSync(dataLength);
    return Iso9660Info(
      volumeId: volumeId,
      rootNames: _parseDirectoryNames(directory),
    );
  } finally {
    handle.closeSync();
  }
}

List<String> _parseDirectoryNames(List<int> directory) {
  final names = <String>[];
  var offset = 0;
  while (offset < directory.length) {
    final length = directory[offset];
    if (length == 0) {
      break;
    }
    if (offset + length > directory.length || length < 34) {
      break;
    }
    final idLength = directory[offset + 32];
    if (idLength > 0 && offset + 33 + idLength <= directory.length) {
      final raw = ascii
          .decode(
            directory.sublist(offset + 33, offset + 33 + idLength),
            allowInvalid: true,
          )
          .split(';')
          .first
          .trim()
          .toLowerCase();
      if (raw.isNotEmpty && raw != '.' && raw != '..' && raw != '\u0000') {
        names.add(raw);
      }
    }
    offset += length;
  }
  return names;
}

bool looksLikeLinuxVolumeId(String volumeId) {
  final id = volumeId.toLowerCase();
  const hints = [
    'ubuntu',
    'fedora',
    'debian',
    'mint',
    'arch',
    'kali',
    'manjaro',
    'opensuse',
    'centos',
    'rhel',
    'rocky',
    'alma',
    'pop-os',
    'pop_os',
    'elementary',
    'zorin',
    'tails',
    'gentoo',
    'slackware',
    'casper',
  ];
  return hints.any(id.contains);
}

/// True when a hybrid ISO that macOS cannot mount is still a Linux live image.
bool classifyUnmountedHybridAsLinux(String isoPath) {
  if (!isoLooksLikeHybridDisk(isoPath)) {
    return false;
  }
  final info = readIso9660Info(isoPath);
  if (info == null) {
    throw InvalidIsoException('Could not read ISO 9660 metadata: $isoPath');
  }
  if (info.hasWindowsSources) {
    return false;
  }
  return info.hasLinuxMarkers || looksLikeLinuxVolumeId(info.volumeId);
}
