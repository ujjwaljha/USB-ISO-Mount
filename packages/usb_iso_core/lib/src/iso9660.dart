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

class Iso9660FileEntry {
  const Iso9660FileEntry({
    required this.path,
    required this.lba,
    required this.size,
    required this.isDirectory,
  });

  /// Lowercase ISO path using `/` separators (`casper/vmlinuz`).
  final String path;
  final int lba;
  final int size;
  final bool isDirectory;
}

class _IsoDirRecord {
  const _IsoDirRecord({
    required this.name,
    required this.lba,
    required this.size,
    required this.isDirectory,
    required this.joliet,
  });

  final String name;
  final int lba;
  final int size;
  final bool isDirectory;
  final bool joliet;
}

/// Finds a file inside an ISO 9660 / Joliet image, or null if it is missing.
Iso9660FileEntry? findIso9660Path(String isoPath, String relativePath) {
  final parts = relativePath
      .replaceAll(r'\', '/')
      .toLowerCase()
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) {
    return null;
  }
  final handle = File(isoPath).openSync();
  try {
    final root = _isoRootRecord(handle);
    if (root == null) {
      return null;
    }
    var current = root;
    final walked = <String>[];
    for (var i = 0; i < parts.length; i++) {
      final name = parts[i];
      final last = i == parts.length - 1;
      _IsoDirRecord? child;
      for (final record in _readIsoDirectory(handle, current)) {
        if (record.name == name) {
          child = record;
          break;
        }
      }
      if (child == null) {
        return null;
      }
      walked.add(child.name);
      if (last) {
        return Iso9660FileEntry(
          path: walked.join('/'),
          lba: child.lba,
          size: child.size,
          isDirectory: child.isDirectory,
        );
      }
      if (!child.isDirectory) {
        return null;
      }
      current = child;
    }
    return null;
  } finally {
    handle.closeSync();
  }
}

/// Lists one directory inside an ISO 9660 / Joliet image.
List<Iso9660FileEntry> listIso9660Directory(
  String isoPath,
  String relativeDir,
) {
  final handle = File(isoPath).openSync();
  try {
    final root = _isoRootRecord(handle);
    if (root == null) {
      return const [];
    }
    var current = root;
    final prefix = relativeDir
        .replaceAll(r'\', '/')
        .toLowerCase()
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    for (final name in prefix) {
      _IsoDirRecord? child;
      for (final record in _readIsoDirectory(handle, current)) {
        if (record.name == name && record.isDirectory) {
          child = record;
          break;
        }
      }
      if (child == null) {
        return const [];
      }
      current = child;
    }
    final base = prefix.join('/');
    return [
      for (final record in _readIsoDirectory(handle, current))
        Iso9660FileEntry(
          path: base.isEmpty ? record.name : '$base/${record.name}',
          lba: record.lba,
          size: record.size,
          isDirectory: record.isDirectory,
        ),
    ];
  } finally {
    handle.closeSync();
  }
}

/// Writes one ISO file extent to [destination].
void extractIso9660File({
  required String isoPath,
  required Iso9660FileEntry entry,
  required String destination,
}) {
  if (entry.isDirectory) {
    throw InvalidIsoException('Cannot extract a directory: ${entry.path}');
  }
  final handle = File(isoPath).openSync();
  try {
    handle.setPositionSync(entry.lba * iso9660SectorSize);
    final bytes = handle.readSync(entry.size);
    if (bytes.length < entry.size) {
      throw InvalidIsoException(
        'ISO file ${entry.path} was truncated (${bytes.length} of ${entry.size}).',
      );
    }
    final out = File(destination);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(bytes);
  } finally {
    handle.closeSync();
  }
}

_IsoDirRecord? _isoRootRecord(RandomAccessFile handle) {
  final joliet = _readVolumeRoot(handle, startSector: 17, requireJoliet: true);
  if (joliet != null) {
    return joliet;
  }
  return _readVolumeRoot(handle, startSector: 16, requireJoliet: false);
}

_IsoDirRecord? _readVolumeRoot(
  RandomAccessFile handle, {
  required int startSector,
  required bool requireJoliet,
}) {
  for (var sector = startSector; sector < startSector + 8; sector++) {
    handle.setPositionSync(sector * iso9660SectorSize);
    final desc = handle.readSync(iso9660SectorSize);
    if (desc.length < 190) {
      return null;
    }
    final type = desc[0];
    if (type == 255) {
      return null;
    }
    if (ascii.decode(desc.sublist(1, 6), allowInvalid: true) != 'CD001') {
      continue;
    }
    if (requireJoliet) {
      if (type != 2) {
        continue;
      }
      final escape = ascii.decode(desc.sublist(88, 91), allowInvalid: true);
      if (escape != '%/@' && escape != '%/C' && escape != '%/E') {
        continue;
      }
    } else if (type != 1) {
      continue;
    }
    final rootLength = desc[156];
    if (rootLength < 34) {
      return null;
    }
    final record = desc.sublist(156, 156 + rootLength);
    final lba = ByteData.sublistView(
      Uint8List.fromList(record),
      2,
      6,
    ).getUint32(0, Endian.little);
    final size = ByteData.sublistView(
      Uint8List.fromList(record),
      10,
      14,
    ).getUint32(0, Endian.little);
    if (lba == 0 || size == 0) {
      return null;
    }
    return _IsoDirRecord(
      name: '',
      lba: lba,
      size: size,
      isDirectory: true,
      joliet: requireJoliet,
    );
  }
  return null;
}

List<_IsoDirRecord> _readIsoDirectory(
  RandomAccessFile handle,
  _IsoDirRecord directory,
) {
  handle.setPositionSync(directory.lba * iso9660SectorSize);
  final data = handle.readSync(directory.size);
  final records = <_IsoDirRecord>[];
  var offset = 0;
  while (offset < data.length) {
    final length = data[offset];
    if (length == 0) {
      final next = ((offset ~/ iso9660SectorSize) + 1) * iso9660SectorSize;
      if (next <= offset) {
        break;
      }
      offset = next;
      continue;
    }
    if (offset + length > data.length || length < 34) {
      break;
    }
    final record = _parseDirRecord(
      data.sublist(offset, offset + length),
      joliet: directory.joliet,
    );
    if (record != null && record.name.isNotEmpty) {
      records.add(record);
    }
    offset += length;
  }
  return records;
}

_IsoDirRecord? _parseDirRecord(List<int> record, {required bool joliet}) {
  if (record.length < 34) {
    return null;
  }
  final idLength = record[32];
  if (idLength <= 0 || 33 + idLength > record.length) {
    return null;
  }
  if (idLength == 1 && (record[33] == 0 || record[33] == 1)) {
    return null;
  }
  final name = joliet
      ? _decodeJolietName(record.sublist(33, 33 + idLength))
      : ascii
            .decode(record.sublist(33, 33 + idLength), allowInvalid: true)
            .split(';')
            .first
            .trim()
            .toLowerCase();
  if (name.isEmpty || name == '.' || name == '..') {
    return null;
  }
  final lba = ByteData.sublistView(
    Uint8List.fromList(record),
    2,
    6,
  ).getUint32(0, Endian.little);
  final size = ByteData.sublistView(
    Uint8List.fromList(record),
    10,
    14,
  ).getUint32(0, Endian.little);
  return _IsoDirRecord(
    name: name,
    lba: lba,
    size: size,
    isDirectory: (record[25] & 0x02) != 0,
    joliet: joliet,
  );
}

String _decodeJolietName(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units).split(';').first.trim().toLowerCase();
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
