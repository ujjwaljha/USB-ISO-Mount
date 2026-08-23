import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../cancellation.dart';
import '../disk_layout.dart';
import '../exceptions.dart';
import '../host_platform.dart';
import '../json_util.dart';
import '../models/iso_mount.dart';
import '../models/usb_disk.dart';
import '../process_runner.dart';

const _volumeLabel = 'WINSETUP';

bool isAdvancedLinuxTransport(String tran, String name) {
  final bus = tran.toUpperCase();
  if (bus == 'MMC' || bus == 'SD' || bus == 'SECURE DIGITAL') {
    return true;
  }
  return name.startsWith('mmcblk');
}

/// Parses one `lsblk -J` block device into a USB target, or null if unsafe.
UsbDisk? usbDiskFromLinuxInfo(
  Map<String, dynamic> info, {
  required String bootName,
  bool includeAdvanced = false,
}) {
  final name = asString(info['name']);
  if (name.isEmpty || name == bootName) {
    return null;
  }
  final type = asString(info['type']).toLowerCase();
  if (type.isNotEmpty && type != 'disk') {
    return null;
  }

  final tran = asString(info['tran']);
  final path = asString(info['path']).isEmpty
      ? '/dev/$name'
      : asString(info['path']);
  final mounts = <String>[];
  final ownMount = asString(info['mountpoint']);
  if (ownMount.isNotEmpty) {
    mounts.add(ownMount);
  }
  final children = info['children'];
  if (children is List) {
    for (final child in children) {
      if (child is Map) {
        final mount = asString(child['mountpoint']);
        if (mount.isNotEmpty) {
          mounts.add(mount);
        }
      }
    }
  }

  final isUsb = tran.toUpperCase() == 'USB';
  final isAdvanced = isAdvancedLinuxTransport(tran, name);
  final disk = UsbDisk(
    id: name,
    devicePath: path,
    name: asString(info['model']).trim().isEmpty
        ? 'USB drive'
        : asString(info['model']).trim(),
    sizeBytes: asInt(info['size']),
    busProtocol: isAdvanced && !isUsb
        ? (tran.isEmpty ? 'MMC' : tran)
        : (tran.isEmpty ? 'USB' : tran),
    isRemovable: asBool(info['rm']) || isUsb || isAdvanced,
    isInternal: !isUsb && !isAdvanced,
    isBoot: name == bootName,
    isVirtual: false,
    mountPoints: mounts,
  );

  if (disk.isSafeTarget) {
    return disk;
  }
  if (includeAdvanced && disk.isAdvancedTarget) {
    return disk;
  }
  return null;
}

String? linuxBootDiskName(List<dynamic> devices) {
  for (final device in devices) {
    if (device is! Map) {
      continue;
    }
    final map = Map<String, dynamic>.from(device);
    if (_hasRootMount(map)) {
      return asString(map['name']);
    }
  }
  return null;
}

bool _hasRootMount(Map<String, dynamic> node) {
  final mount = asString(node['mountpoint']);
  if (mount == '/' || mount == '/boot') {
    return true;
  }
  final children = node['children'];
  if (children is List) {
    for (final child in children) {
      if (child is Map && _hasRootMount(Map<String, dynamic>.from(child))) {
        return true;
      }
    }
  }
  return false;
}

class LinuxHost implements HostPlatform {
  LinuxHost(this._runner);

  final ProcessRunner _runner;

  @override
  Future<List<UsbDisk>> listUsbDisks({bool includeAdvanced = false}) async {
    final result = await _runner.run('lsblk', [
      '-J',
      '-b',
      '-o',
      'NAME,TRAN,TYPE,SIZE,RM,MODEL,PKNAME,MOUNTPOINT,PATH',
    ]);
    if (!result.success) {
      throw UsbIsoException('lsblk failed: ${result.stderr.trim()}');
    }
    final root = decodeJsonObject(result.stdout);
    final devices = root['blockdevices'];
    if (devices is! List) {
      return const [];
    }
    final boot = linuxBootDiskName(devices) ?? '';
    final disks = <UsbDisk>[];
    for (final item in devices) {
      if (item is! Map) {
        continue;
      }
      final disk = usbDiskFromLinuxInfo(
        Map<String, dynamic>.from(item),
        bootName: boot,
        includeAdvanced: includeAdvanced,
      );
      if (disk != null) {
        disks.add(disk);
      }
    }
    return disks;
  }

  Future<Map<String, dynamic>?> _lsblkDisk(String name) async {
    final result = await _runner.run('lsblk', [
      '-J',
      '-b',
      '-o',
      'NAME,TRAN,TYPE,SIZE,RM,MODEL,PKNAME,MOUNTPOINT,PATH',
      '/dev/$name',
    ]);
    if (!result.success) {
      return null;
    }
    final root = decodeJsonObject(result.stdout);
    final devices = root['blockdevices'];
    if (devices is! List || devices.isEmpty || devices.first is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(devices.first as Map);
  }

  @override
  Future<IsoMount> mountIso(String isoPath) async {
    if (!File(isoPath).existsSync()) {
      throw InvalidIsoException('ISO not found: $isoPath');
    }
    final existing = await _existingIsoMount(isoPath);
    if (existing != null) {
      return existing;
    }
    final dir = Directory.systemTemp.createTempSync('usb_iso_mnt_');
    final result = await _runner.run('mount', [
      '-o',
      'loop,ro',
      isoPath,
      dir.path,
    ], elevated: true);
    if (!result.success) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      throw UsbIsoException(
        'Failed to mount ISO: ${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
      );
    }
    return IsoMount(isoPath: isoPath, mountPath: dir.path);
  }

  Future<IsoMount?> _existingIsoMount(String isoPath) async {
    final wanted = p.normalize(isoPath);
    final mounts = File('/proc/mounts');
    if (!mounts.existsSync()) {
      return null;
    }
    for (final line in mounts.readAsLinesSync()) {
      final parts = line.split(' ');
      if (parts.length < 2) {
        continue;
      }
      if (p.normalize(parts[0]) == wanted || parts[0].contains(wanted)) {
        return IsoMount(isoPath: isoPath, mountPath: parts[1]);
      }
    }
    return null;
  }

  @override
  Future<void> unmountIso(IsoMount mount) async {
    final target = mount.mountPath.isNotEmpty ? mount.mountPath : mount.isoPath;
    final result = await _runner.run('umount', [target], elevated: true);
    if (!result.success) {
      throw UsbIsoException('Failed to unmount ISO: ${result.stderr.trim()}');
    }
    final dir = Directory(mount.mountPath);
    if (mount.mountPath.contains('usb_iso_mnt_') && dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }

  @override
  Future<void> verifyWritable(
    UsbDisk disk, {
    bool allowAdvancedTargets = false,
  }) async {
    final devices = await listUsbDisks(includeAdvanced: allowAdvancedTargets);
    final current = devices.where((item) => item.id == disk.id);
    if (current.isEmpty) {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: it is no longer a removable USB drive.',
      );
    }
  }

  @override
  Future<void> eraseAndFormat(
    UsbDisk disk, {
    DiskLayout layout = DiskLayout.fat32,
  }) async {
    await verifyWritable(disk);
    if (layout == DiskLayout.fat32PlusNtfs) {
      final ntfs = await _runner.run('sh', [
        '-c',
        'command -v mkfs.ntfs || command -v mkntfs',
      ]);
      if (!ntfs.success || ntfs.stdout.trim().isEmpty) {
        throw UsbIsoException(
          'FAT32+NTFS requires mkfs.ntfs on Linux. Install ntfs-3g or use '
          'FAT32 with a WIM split instead.',
        );
      }
    }

    await _unmountDisk(disk);
    final wipe = await _runner.run('wipefs', [
      '-a',
      disk.devicePath,
    ], elevated: true);
    if (!wipe.success) {
      throw UsbIsoException('Failed to wipe ${disk.id}: ${wipe.stderr.trim()}');
    }

    if (layout == DiskLayout.fat32PlusNtfs) {
      final parted = await _runner.run('parted', [
        '-s',
        disk.devicePath,
        'mklabel',
        'gpt',
        'mkpart',
        'WINBOOT',
        'fat32',
        '1MiB',
        '3585MiB',
        'mkpart',
        _volumeLabel,
        'ntfs',
        '3585MiB',
        '100%',
      ], elevated: true);
      if (!parted.success) {
        throw UsbIsoException(
          'Failed to partition ${disk.id}: ${parted.stderr.trim()}',
        );
      }
      final fat = await _runner.run('mkfs.vfat', [
        '-F',
        '32',
        '-n',
        'WINBOOT',
        '${disk.devicePath}1',
      ], elevated: true);
      if (!fat.success) {
        throw UsbIsoException(
          'Failed to format WINBOOT on ${disk.id}: ${fat.stderr.trim()}',
        );
      }
      final ntfsTool = (await _runner.run('sh', [
        '-c',
        'command -v mkfs.ntfs || command -v mkntfs',
      ])).stdout.trim().split('\n').first;
      final ntfs = await _runner.run(ntfsTool, [
        '-f',
        '-L',
        _volumeLabel,
        '${disk.devicePath}2',
      ], elevated: true);
      if (!ntfs.success) {
        throw UsbIsoException(
          'Failed to format WINSETUP on ${disk.id}: ${ntfs.stderr.trim()}',
        );
      }
      return;
    }

    final parted = await _runner.run('parted', [
      '-s',
      disk.devicePath,
      'mklabel',
      'gpt',
      'mkpart',
      _volumeLabel,
      'fat32',
      '1MiB',
      '100%',
    ], elevated: true);
    if (!parted.success) {
      throw UsbIsoException(
        'Failed to partition ${disk.id}: ${parted.stderr.trim()}',
      );
    }
    final fat = await _runner.run('mkfs.vfat', [
      '-F',
      '32',
      '-n',
      _volumeLabel,
      '${disk.devicePath}1',
    ], elevated: true);
    if (!fat.success) {
      throw UsbIsoException(
        'Failed to format ${disk.id}: ${fat.stderr.trim()}',
      );
    }
  }

  Future<void> _unmountDisk(UsbDisk disk) async {
    for (final mount in disk.mountPoints) {
      await _runner.run('umount', [mount], elevated: true);
    }
    final info = await _lsblkDisk(disk.id);
    final children = info?['children'];
    if (children is List) {
      for (final child in children) {
        if (child is! Map) {
          continue;
        }
        final mount = asString(child['mountpoint']);
        if (mount.isNotEmpty) {
          await _runner.run('umount', [mount], elevated: true);
        }
      }
    }
  }

  @override
  Future<PreparedVolumes> waitForVolumeMount(
    UsbDisk disk, {
    DiskLayout layout = DiskLayout.fat32,
  }) async {
    for (var i = 0; i < 40; i++) {
      await _runner.run('partprobe', [disk.devicePath], elevated: true);
      final bootDev = '${disk.devicePath}1';
      final dataDev = '${disk.devicePath}2';
      final boot = await _ensureMounted(
        bootDev,
        layout == DiskLayout.fat32PlusNtfs ? 'WINBOOT' : _volumeLabel,
      );
      if (layout == DiskLayout.fat32PlusNtfs) {
        final data = await _ensureMounted(dataDev, _volumeLabel);
        if (boot != null && data != null) {
          return PreparedVolumes(bootMount: boot, dataMount: data);
        }
      } else if (boot != null) {
        return PreparedVolumes(bootMount: boot);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw UsbIsoException(
      'Formatted ${disk.id} but could not mount the new volume.',
    );
  }

  Future<String?> _ensureMounted(String device, String label) async {
    final find = await _runner.run('findmnt', ['-n', '-o', 'TARGET', device]);
    if (find.success && find.stdout.trim().isNotEmpty) {
      return find.stdout.trim();
    }
    final dir = Directory(p.join('/tmp', 'usb_iso_$label'));
    dir.createSync(recursive: true);
    final mount = await _runner.run('mount', [
      device,
      dir.path,
    ], elevated: true);
    if (mount.success) {
      return dir.path;
    }
    return null;
  }

  @override
  Future<void> eject(UsbDisk disk) async {
    await _unmountDisk(disk);
    final result = await _runner.run('eject', [disk.devicePath]);
    if (!result.success) {
      throw UsbIsoException(
        'Wrote the USB, but eject failed: ${result.stderr.trim()}',
      );
    }
  }

  @override
  Future<String?> findWimSplitTool() async {
    for (final candidate in ['wimlib-imagex', 'wimsplit']) {
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
    var source = sourceWim;
    Directory? temp;
    if (sourceWim.toLowerCase().endsWith('.esd') &&
        !toolPath.endsWith('wimsplit')) {
      temp = Directory.systemTemp.createTempSync('usb_iso_esd_');
      final converted = p.join(temp.path, 'install.wim');
      final export = await _runner.run(toolPath, [
        'export',
        sourceWim,
        'all',
        converted,
      ]);
      if (!export.success) {
        temp.deleteSync(recursive: true);
        throw UsbIsoException(
          'wimlib ESD export failed: ${export.stderr.trim()}',
        );
      }
      source = converted;
    }
    try {
      final args = toolPath.endsWith('wimsplit')
          ? [source, destinationSwm, '$wimSplitSizeMiB']
          : ['split', source, destinationSwm, '$wimSplitSizeMiB'];
      final result = await _runner.run(toolPath, args);
      if (!result.success) {
        throw UsbIsoException(
          'wimlib split failed: ${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
        );
      }
    } finally {
      if (temp != null && temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    }
  }

  @override
  Future<void> writeRawImage({
    required UsbDisk disk,
    required String isoPath,
    RawWriteProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    await verifyWritable(disk);
    cancellation?.throwIfCancelled();
    await _unmountDisk(disk);

    final work = Directory.systemTemp.createTempSync('usb_iso_raw_');
    final progressFile = File(p.join(work.path, 'progress'));
    final cancelFile = File(p.join(work.path, 'cancel'));
    final script = File(p.join(work.path, 'write.py'));
    await script.writeAsString('''
import os, sys
src, dst, prog, cancel = sys.argv[1:5]
total = os.path.getsize(src)
written = 0
with open(src, 'rb') as inp, open(dst, 'wb') as out:
    while True:
        if os.path.exists(cancel):
            sys.exit(75)
        chunk = inp.read(8 * 1024 * 1024)
        if not chunk:
            break
        out.write(chunk)
        written += len(chunk)
        with open(prog, 'w') as p:
            p.write(str(written))
    out.flush()
    os.fsync(out.fileno())
''');

    try {
      final process = await _runner.start('python3', [
        script.path,
        isoPath,
        disk.devicePath,
        progressFile.path,
        cancelFile.path,
      ], elevated: true);
      process.stdout.drain<void>();
      final errFuture = process.stderr.transform(utf8.decoder).join();
      final total = File(isoPath).lengthSync();
      onProgress?.call(0, total);
      while (true) {
        final done = await process.exitCode.timeout(
          const Duration(milliseconds: 250),
          onTimeout: () => -1,
        );
        if (cancellation?.isCancelled == true && !cancelFile.existsSync()) {
          cancelFile.writeAsStringSync('1');
        }
        if (progressFile.existsSync()) {
          final last =
              int.tryParse(progressFile.readAsStringSync().trim()) ?? 0;
          onProgress?.call(last, total);
        }
        if (done != -1) {
          if (done == 75 || cancellation?.isCancelled == true) {
            throw WriteCancelledException(
              'Write cancelled. The USB was erased and may not be bootable.',
            );
          }
          if (done != 0) {
            final err = await errFuture;
            throw UsbIsoException(
              'Raw ISO write failed on ${disk.id}: ${err.trim()}',
            );
          }
          onProgress?.call(total, total);
          return;
        }
      }
    } finally {
      if (work.existsSync()) {
        work.deleteSync(recursive: true);
      }
    }
  }

  @override
  Future<void> flushDisk(UsbDisk disk) async {
    final result = await _runner.run('sync', const []);
    if (!result.success) {
      throw UsbIsoException(
        'Failed to flush ${disk.id}: ${result.stderr.trim()}',
      );
    }
  }
}
