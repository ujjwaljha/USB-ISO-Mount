import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../exceptions.dart';
import '../host_platform.dart';
import '../json_util.dart';
import '../models/iso_mount.dart';
import '../models/usb_disk.dart';
import '../process_runner.dart';

const _volumeLabel = 'WINSETUP';

/// Parses `diskutil info` JSON into a candidate USB disk, or null if unsafe.
UsbDisk? usbDiskFromMacosInfo(
  Map<String, dynamic> info, {
  required String bootWholeDisk,
  List<String> mountPoints = const [],
}) {
  final id = asString(info['DeviceIdentifier']);
  if (id.isEmpty) {
    return null;
  }

  final bus = asString(info['BusProtocol']);
  final virtual = asString(info['VirtualOrPhysical']);
  final internal = asBool(info['Internal']);
  final removable = asBool(info['Removable']) || asBool(info['RemovableMedia']);
  final isBoot = id == bootWholeDisk;

  final disk = UsbDisk(
    id: id,
    devicePath: asString(info['DeviceNode']).isEmpty
        ? '/dev/$id'
        : asString(info['DeviceNode']),
    name: _macosName(info),
    sizeBytes: asInt(info['TotalSize'] ?? info['IOKitSize'] ?? info['Size']),
    busProtocol: bus,
    isRemovable: removable,
    isInternal: internal,
    isBoot: isBoot,
    isVirtual:
        virtual.toLowerCase() == 'virtual' || bus.toLowerCase() == 'disk image',
    mountPoints: mountPoints,
  );

  if (!disk.isSafeTarget) {
    return null;
  }
  if (bus.toUpperCase() != 'USB') {
    return null;
  }
  return disk;
}

String _macosName(Map<String, dynamic> info) {
  final media = asString(info['MediaName']).trim();
  final volume = asString(info['VolumeName']).trim();
  if (media.isNotEmpty && volume.isNotEmpty && media != volume) {
    return '$media ($volume)';
  }
  if (media.isNotEmpty) {
    return media;
  }
  if (volume.isNotEmpty) {
    return volume;
  }
  return 'USB drive';
}

class MacosHost implements HostPlatform {
  MacosHost(this._runner);

  final ProcessRunner _runner;

  Future<Map<String, dynamic>> _infoJson(String diskOrPath) async {
    final plist = await _runner.run('diskutil', ['info', '-plist', diskOrPath]);
    if (!plist.success) {
      throw UsbIsoException(
        'diskutil info $diskOrPath failed: ${plist.stderr.trim()}',
      );
    }
    return _plistToJson(plist.stdout);
  }

  Future<Map<String, dynamic>> _plistToJson(String plistXml) async {
    final process = await Process.start('plutil', [
      '-convert',
      'json',
      '-o',
      '-',
      '-',
    ]);
    process.stdin.write(plistXml);
    await process.stdin.close();
    final stdout = await process.stdout.transform(utf8.decoder).join();
    final stderr = await process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    if (code != 0) {
      throw UsbIsoException('plutil failed: $stderr');
    }
    return decodeJsonObject(stdout);
  }

  @override
  Future<List<UsbDisk>> listUsbDisks() async {
    final listPlist = await _runner.run('diskutil', [
      'list',
      '-plist',
      'physical',
    ]);
    if (!listPlist.success) {
      throw UsbIsoException('diskutil list failed: ${listPlist.stderr.trim()}');
    }
    final listJson = await _plistToJson(listPlist.stdout);
    final wholeDisks = (listJson['WholeDisks'] as List<dynamic>? ?? [])
        .map((e) => '$e')
        .toList();
    final mountsByDisk = _mountsFromList(listJson);

    var bootWhole = '';
    try {
      final boot = await _infoJson('/');
      bootWhole = asString(boot['ParentWholeDisk']);
      if (bootWhole.isEmpty) {
        bootWhole = asString(boot['DeviceIdentifier']);
      }
    } on UsbIsoException {
      // Still list USB disks; boot-disk comparison will be empty.
    }

    final disks = <UsbDisk>[];
    for (final id in wholeDisks) {
      try {
        final info = await _infoJson(id);
        final mounts = mountsByDisk[id] ?? const <String>[];
        final disk = usbDiskFromMacosInfo(
          info,
          bootWholeDisk: bootWhole,
          mountPoints: mounts,
        );
        if (disk != null) {
          disks.add(disk);
        }
      } on UsbIsoException {
        continue;
      }
    }
    return disks;
  }

  Map<String, List<String>> _mountsFromList(Map<String, dynamic> listJson) {
    final mounts = <String, List<String>>{};
    final entries = listJson['AllDisksAndPartitions'] as List<dynamic>? ?? [];
    for (final entry in entries) {
      if (entry is! Map) {
        continue;
      }
      final whole = asString(entry['DeviceIdentifier']);
      final found = <String>[];
      final wholeMount = asString(entry['MountPoint']);
      if (wholeMount.isNotEmpty) {
        found.add(wholeMount);
      }
      final parts = entry['Partitions'] as List<dynamic>? ?? const [];
      for (final part in parts) {
        if (part is! Map) {
          continue;
        }
        final mount = asString(part['MountPoint']);
        if (mount.isNotEmpty) {
          found.add(mount);
        }
      }
      if (whole.isNotEmpty && found.isNotEmpty) {
        mounts[whole] = found;
      }
    }
    return mounts;
  }

  @override
  Future<IsoMount> mountIso(String isoPath) async {
    final file = File(isoPath);
    if (!file.existsSync()) {
      throw InvalidIsoException('ISO not found: $isoPath');
    }

    final already = await _existingIsoMount(isoPath);
    if (already != null) {
      return already;
    }

    final result = await _runner.run('hdiutil', [
      'attach',
      '-plist',
      '-nobrowse',
      '-readonly',
      '-noverify',
      isoPath,
    ]);
    if (!result.success) {
      final detail = result.stderr.trim().isEmpty
          ? result.stdout.trim()
          : result.stderr.trim();
      if (detail.toLowerCase().contains('resource busy')) {
        final existing = await _existingIsoMount(isoPath);
        if (existing != null) {
          return existing;
        }
      }
      throw UsbIsoException('Failed to mount ISO: $detail');
    }

    String? mountPath;
    String? deviceNode;
    try {
      final plist = await _plistToJson(result.stdout);
      mountPath = _firstStringByKeys(plist, const [
        'mount-point',
        'MountPoint',
      ]);
      deviceNode = _firstStringByKeys(plist, const ['dev-entry', 'DeviceNode']);
    } on Object {
      final parsed = _parseHdiutilAttach(result.stdout);
      mountPath = parsed.mountPath;
      deviceNode = parsed.deviceNode;
    }

    if (mountPath == null || mountPath.isEmpty) {
      final parsed = _parseHdiutilAttach(result.stdout);
      mountPath = parsed.mountPath;
      deviceNode ??= parsed.deviceNode;
    }
    if (mountPath == null || mountPath.isEmpty) {
      throw UsbIsoException(
        'Mounted the ISO but could not find a /Volumes path:\n${result.stdout}',
      );
    }
    return IsoMount(
      isoPath: isoPath,
      mountPath: mountPath,
      deviceNode: deviceNode,
    );
  }

  @override
  Future<void> unmountIso(IsoMount mount) async {
    final targets = <String>[];
    if (mount.deviceNode != null && mount.deviceNode!.isNotEmpty) {
      targets.add(mount.deviceNode!);
    }
    if (mount.mountPath.isNotEmpty) {
      targets.add(mount.mountPath);
    }
    if (targets.isEmpty && mount.isoPath.isNotEmpty) {
      final found = await _existingIsoMount(mount.isoPath);
      if (found != null) {
        if (found.deviceNode != null) {
          targets.add(found.deviceNode!);
        }
        if (found.mountPath.isNotEmpty) {
          targets.add(found.mountPath);
        }
      }
    }
    if (targets.isEmpty) {
      throw UsbIsoException(
        'Could not find a mounted image for ${mount.isoPath}.',
      );
    }

    CommandResult? last;
    for (final target in targets) {
      last = await _runner.run('hdiutil', ['detach', target, '-quiet']);
      if (last.success) {
        return;
      }
      last = await _runner.run('hdiutil', ['detach', target, '-force']);
      if (last.success) {
        return;
      }
    }
    throw UsbIsoException(
      'Failed to unmount ISO: ${last?.stderr.trim() ?? 'unknown error'}',
    );
  }

  Future<IsoMount?> _existingIsoMount(String isoPath) async {
    final info = await _runner.run('hdiutil', ['info', '-plist']);
    if (!info.success) {
      return isoMountFromHdiutilInfo(info.stdout, isoPath);
    }
    try {
      final plist = await _plistToJson(info.stdout);
      return isoMountFromInfoPlist(plist, isoPath) ??
          isoMountFromHdiutilInfo(info.stdout, isoPath);
    } on Object {
      return isoMountFromHdiutilInfo(info.stdout, isoPath);
    }
  }

  @override
  Future<void> verifyWritable(UsbDisk disk) async {
    var bootWhole = '';
    try {
      final boot = await _infoJson('/');
      bootWhole = asString(boot['ParentWholeDisk']);
      if (bootWhole.isEmpty) {
        bootWhole = asString(boot['DeviceIdentifier']);
      }
    } on UsbIsoException {
      // Compare against an empty boot id if this lookup fails.
    }

    final info = await _infoJson(disk.id);
    final current = usbDiskFromMacosInfo(info, bootWholeDisk: bootWhole);
    if (current == null || current.id != disk.id) {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: it is no longer a removable USB drive.',
      );
    }
  }

  @override
  Future<void> eraseAndFormat(UsbDisk disk) async {
    await verifyWritable(disk);
    final result = await _runner.run('diskutil', [
      'eraseDisk',
      'FAT32',
      _volumeLabel,
      'GPT',
      disk.id,
    ], elevated: true);
    if (!result.success) {
      throw UsbIsoException(
        'Failed to erase ${disk.id}: ${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
      );
    }
  }

  @override
  Future<String> waitForVolumeMount(UsbDisk disk) async {
    for (var i = 0; i < 40; i++) {
      final volumes = Directory('/Volumes');
      if (volumes.existsSync()) {
        for (final entry in volumes.listSync()) {
          if (entry is! Directory) {
            continue;
          }
          final name = p.basename(entry.path);
          if (!name.startsWith(_volumeLabel)) {
            continue;
          }
          try {
            final info = await _infoJson(entry.path);
            if (asString(info['ParentWholeDisk']) == disk.id) {
              return entry.path;
            }
          } on UsbIsoException {
            continue;
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw UsbIsoException(
      'Timed out waiting for $_volumeLabel to appear on ${disk.id}.',
    );
  }

  @override
  Future<void> eject(UsbDisk disk) async {
    var result = await _runner.run('diskutil', ['eject', disk.id]);
    if (!result.success) {
      result = await _runner.run('diskutil', [
        'eject',
        disk.id,
      ], elevated: true);
    }
    if (!result.success) {
      throw UsbIsoException(
        'Wrote the USB, but eject failed: ${result.stderr.trim()}',
      );
    }
  }

  @override
  Future<String?> findWimSplitTool() async {
    final candidates = [
      'wimlib-imagex',
      '/opt/homebrew/bin/wimlib-imagex',
      '/usr/local/bin/wimlib-imagex',
    ];
    for (final candidate in candidates) {
      if (candidate.startsWith('/') && !File(candidate).existsSync()) {
        continue;
      }
      final result = await _runner.run(candidate, ['--version']);
      if (result.success) {
        return candidate;
      }
    }
    return null;
  }

  @override
  Future<void> splitWim({
    required String sourceWim,
    required String destinationSwm,
    required String toolPath,
  }) async {
    final result = await _runner.run(toolPath, [
      'split',
      sourceWim,
      destinationSwm,
      '$wimSplitSizeMiB',
    ]);
    if (!result.success) {
      throw UsbIsoException(
        'wimlib split failed: ${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
      );
    }
  }
}

class _HdiutilAttach {
  const _HdiutilAttach({this.mountPath, this.deviceNode});

  final String? mountPath;
  final String? deviceNode;
}

_HdiutilAttach _parseHdiutilAttach(String stdout) {
  String? mount;
  String? device;
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final volumeMatch = RegExp(r'(/Volumes/.+)$').firstMatch(line);
    if (volumeMatch != null) {
      mount = volumeMatch.group(1)!.trim();
    }
    final diskMatch = RegExp(r'(/dev/disk\d+)\b').firstMatch(line);
    if (diskMatch != null && device == null) {
      device = diskMatch.group(1);
    }
  }
  return _HdiutilAttach(mountPath: mount, deviceNode: device);
}

// Re-export parser for tests without leaking the private class.
String? hdiutilMountPath(String stdout) =>
    _parseHdiutilAttach(stdout).mountPath;

String? hdiutilDeviceNode(String stdout) =>
    _parseHdiutilAttach(stdout).deviceNode;

/// Finds an already-attached ISO in `hdiutil info -plist` JSON.
IsoMount? isoMountFromInfoPlist(dynamic node, String isoPath) {
  if (node is Map) {
    final imagePath = asString(node['image-path'] ?? node['ImagePath']);
    if (imagePath.isNotEmpty &&
        p.equals(p.normalize(imagePath), p.normalize(isoPath))) {
      final mount = _firstStringByKeys(node, const [
        'mount-point',
        'MountPoint',
      ]);
      final device = _firstStringByKeys(node, const [
        'dev-entry',
        'DeviceNode',
      ]);
      if (mount != null && mount.startsWith('/Volumes/')) {
        return IsoMount(isoPath: isoPath, mountPath: mount, deviceNode: device);
      }
    }
    for (final value in node.values) {
      final found = isoMountFromInfoPlist(value, isoPath);
      if (found != null) {
        return found;
      }
    }
  } else if (node is List) {
    for (final value in node) {
      final found = isoMountFromInfoPlist(value, isoPath);
      if (found != null) {
        return found;
      }
    }
  }
  return null;
}

/// Text fallback for `hdiutil info` when the ISO is already attached.
IsoMount? isoMountFromHdiutilInfo(String stdout, String isoPath) {
  final wanted = p.normalize(isoPath);
  final blocks = stdout.split(RegExp(r'\n={5,}\n'));
  for (final block in blocks) {
    if (!block.contains(isoPath) && !block.contains(wanted)) {
      continue;
    }
    String? mount;
    String? device;
    for (final line in block.split(RegExp(r'\r?\n'))) {
      final volumeMatch = RegExp(r'(/Volumes/.+)$').firstMatch(line);
      if (volumeMatch != null) {
        mount = volumeMatch.group(1)!.trim();
      }
      final diskMatch = RegExp(r'(/dev/disk\d+)\b').firstMatch(line);
      if (diskMatch != null && device == null) {
        device = diskMatch.group(1);
      }
    }
    if (mount != null) {
      return IsoMount(isoPath: isoPath, mountPath: mount, deviceNode: device);
    }
  }
  return null;
}

String? _firstStringByKeys(dynamic node, List<String> keys) {
  if (node is Map) {
    for (final key in keys) {
      final value = node[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    for (final value in node.values) {
      final found = _firstStringByKeys(value, keys);
      if (found != null) {
        return found;
      }
    }
  } else if (node is List) {
    for (final value in node) {
      final found = _firstStringByKeys(value, keys);
      if (found != null) {
        return found;
      }
    }
  }
  return null;
}
