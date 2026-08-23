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

/// Parses `diskutil info` JSON into a candidate USB disk, or null if unsafe.
UsbDisk? usbDiskFromMacosInfo(
  Map<String, dynamic> info, {
  required String bootWholeDisk,
  List<String> mountPoints = const [],
  bool includeAdvanced = false,
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

  if (disk.isSafeTarget) {
    return disk;
  }
  if (includeAdvanced && disk.isAdvancedTarget) {
    return disk;
  }
  return null;
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
  Future<List<UsbDisk>> listUsbDisks({bool includeAdvanced = false}) async {
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
          includeAdvanced: includeAdvanced,
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
  Future<void> verifyWritable(
    UsbDisk disk, {
    bool allowAdvancedTargets = false,
  }) async {
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
    final current = usbDiskFromMacosInfo(
      info,
      bootWholeDisk: bootWhole,
      includeAdvanced: allowAdvancedTargets,
    );
    if (current == null || current.id != disk.id) {
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
      throw UsbIsoException(
        'FAT32+NTFS dual partition is not available on macOS. '
        'The oversized installer image will be split for FAT32 instead.',
      );
    }
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
  Future<PreparedVolumes> waitForVolumeMount(
    UsbDisk disk, {
    DiskLayout layout = DiskLayout.fat32,
  }) async {
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
              return PreparedVolumes(bootMount: entry.path);
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
    var result = await _runner.run('diskutil', ['unmountDisk', disk.id]);
    if (result.success) {
      result = await _runner.run('diskutil', ['eject', disk.id]);
    }
    if (!result.success) {
      throw UsbIsoException(
        'Finder still has the USB open. Eject WINSETUP in Finder, then unplug it.',
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
    var source = sourceWim;
    Directory? temp;
    if (sourceWim.toLowerCase().endsWith('.esd')) {
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
          'wimlib ESD export failed: ${export.stderr.trim().isEmpty ? export.stdout.trim() : export.stderr.trim()}',
        );
      }
      source = converted;
    }
    try {
      final result = await _runner.run(toolPath, [
        'split',
        source,
        destinationSwm,
        '$wimSplitSizeMiB',
      ]);
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
    final unmount = await _runner.run('diskutil', ['unmountDisk', disk.id]);
    if (!unmount.success) {
      throw UsbIsoException(
        'Could not unmount ${disk.id} for raw write: ${unmount.stderr.trim()}',
      );
    }

    final rdisk = disk.devicePath.replaceFirst('/dev/disk', '/dev/rdisk');
    const authopen = '/usr/libexec/authopen';
    if (!File(authopen).existsSync()) {
      throw UsbIsoException(
        'macOS authopen is missing; cannot write a raw disk image.',
      );
    }

    if (!File(isoPath).existsSync()) {
      throw InvalidIsoException('ISO not found: $isoPath');
    }

    final python = _python3();
    if (python != null) {
      await _writeRawViaAuthopenFd(
        disk: disk,
        rdisk: rdisk,
        isoPath: isoPath,
        python: python,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    } else {
      await _writeRawViaAuthopenStdin(
        disk: disk,
        rdisk: rdisk,
        isoPath: isoPath,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    }

    // Hybrid images often auto-mount; unmount so flush/eject can finish.
    await _runner.run('diskutil', ['unmountDisk', disk.id]);
  }

  String? _python3() {
    const bundled = '/usr/bin/python3';
    if (File(bundled).existsSync()) {
      return bundled;
    }
    return null;
  }

  /// authopen -stdoutpipe hands back the disk fd so we can write 8 MiB blocks.
  /// Piping stdin through authopen is capped at its ~8 KiB copy loop.
  Future<void> _writeRawViaAuthopenFd({
    required UsbDisk disk,
    required String rdisk,
    required String isoPath,
    required String python,
    RawWriteProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    final work = Directory.systemTemp.createTempSync('usb_iso_raw_');
    final progressFile = File(p.join(work.path, 'progress'));
    final cancelFile = File(p.join(work.path, 'cancel'));
    final script = File(p.join(work.path, 'write.py'));
    await script.writeAsString(macosAuthopenRawWritePython(), flush: true);

    try {
      final process = await Process.start(python, [
        script.path,
        isoPath,
        rdisk,
        progressFile.path,
        cancelFile.path,
      ]);
      process.stdout.drain<void>();
      final errFuture = process.stderr.transform(utf8.decoder).join();
      final total = File(isoPath).lengthSync();
      onProgress?.call(0, total);
      var written = 0;
      while (true) {
        final done = await process.exitCode.timeout(
          const Duration(milliseconds: 250),
          onTimeout: () => -1,
        );
        if (cancellation?.isCancelled == true && !cancelFile.existsSync()) {
          cancelFile.writeAsStringSync('1');
        }
        if (progressFile.existsSync()) {
          written = int.tryParse(progressFile.readAsStringSync().trim()) ?? 0;
          onProgress?.call(written, total);
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
              macosAuthopenFailureMessage(
                diskId: disk.id,
                stderr: err,
                exitCode: done,
                writtenBytes: written,
              ),
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

  Future<void> _writeRawViaAuthopenStdin({
    required UsbDisk disk,
    required String rdisk,
    required String isoPath,
    RawWriteProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    const authopen = '/usr/libexec/authopen';
    final process = await Process.start(authopen, ['-w', rdisk]);
    process.stdout.drain<void>();
    final errFuture = process.stderr.transform(utf8.decoder).join();

    final total = File(isoPath).lengthSync();
    onProgress?.call(0, total);
    var written = 0;
    try {
      final raf = await File(isoPath).open();
      try {
        while (true) {
          cancellation?.throwIfCancelled(diskAlreadyErased: true);
          final chunk = await raf.read(rawWriteChunkBytes);
          if (chunk.isEmpty) {
            break;
          }
          process.stdin.add(chunk);
          written += chunk.length;
          onProgress?.call(written, total);
        }
      } finally {
        await raf.close();
      }
      await process.stdin.close();
    } catch (error) {
      process.kill();
      if (error is WriteCancelledException) {
        rethrow;
      }
      final code = await process.exitCode;
      final err = await errFuture;
      throw UsbIsoException(
        macosAuthopenFailureMessage(
          diskId: disk.id,
          stderr: err,
          exitCode: code,
          writtenBytes: written,
        ),
      );
    }

    final code = await process.exitCode;
    if (cancellation?.isCancelled == true) {
      throw WriteCancelledException(
        'Write cancelled. The USB was erased and may not be bootable.',
      );
    }
    if (code != 0) {
      final err = await errFuture;
      throw UsbIsoException(
        macosAuthopenFailureMessage(
          diskId: disk.id,
          stderr: err,
          exitCode: code,
          writtenBytes: written,
        ),
      );
    }
    onProgress?.call(total, total);
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

/// Python that receives the authopen disk fd and writes [rawWriteChunkBytes] blocks.
String macosAuthopenRawWritePython() {
  return '''
import array, fcntl, os, socket, subprocess, sys

iso, rdisk, progress_path, cancel_path = sys.argv[1:5]
chunk_size = $rawWriteChunkBytes

def fail(message, code=1):
    sys.stderr.write(message.rstrip() + "\\n")
    sys.exit(code)

parent, child = socket.socketpair()
try:
    proc = subprocess.Popen(
        ["/usr/libexec/authopen", "-stdoutpipe", "-w", rdisk],
        stdout=child,
        stderr=subprocess.PIPE,
    )
finally:
    child.close()

fd = None
try:
    while fd is None:
        try:
            _data, anc, _flags, _addr = parent.recvmsg(
                4096, socket.CMSG_SPACE(64)
            )
        except OSError as error:
            err = b""
            if proc.stderr is not None:
                err = proc.stderr.read()
            fail((err.decode("utf-8", "replace") or str(error)).strip())
        if not _data and not anc:
            break
        for level, typ, data in anc:
            if level == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
                fds = array.array("i")
                fds.frombytes(data[: len(data) - (len(data) % fds.itemsize)])
                if fds:
                    fd = int(fds[0])
                    for extra in fds[1:]:
                        os.close(int(extra))
                    break
finally:
    parent.close()

if fd is None:
    err = b""
    if proc.stderr is not None:
        err = proc.stderr.read()
    fail((err.decode("utf-8", "replace") or "Administrator approval was required to write the disk.").strip())

written = 0
total = os.path.getsize(iso)
out = os.fdopen(fd, "wb", buffering=0)
try:
    with open(iso, "rb", buffering=0) as inp:
        while True:
            if os.path.exists(cancel_path):
                sys.exit(75)
            chunk = inp.read(chunk_size)
            if not chunk:
                break
            pad = (-len(chunk)) % 512
            if pad:
                chunk += b"\\x00" * pad
            out.write(chunk)
            written += len(chunk) - pad
            with open(progress_path, "w") as progress:
                progress.write(str(min(written, total)))
    out.flush()
    if hasattr(fcntl, "F_FULLFSYNC"):
        fcntl.fcntl(out.fileno(), fcntl.F_FULLFSYNC)
    else:
        os.fsync(out.fileno())
finally:
    out.close()
    try:
        proc.wait(timeout=8)
    except Exception:
        proc.kill()
''';
}

const macosAuthopenDeniedMessage =
    'Administrator approval was required to write the disk.';

/// Maps authopen stderr/exit codes to a user-facing raw-write error.
String macosAuthopenFailureMessage({
  required String diskId,
  required String stderr,
  required int exitCode,
  int writtenBytes = 0,
}) {
  final err = stderr.trim();
  final lower = err.toLowerCase();
  final looksDenied =
      lower.contains('cancel') ||
      lower.contains('denied') ||
      lower.contains('authoriz') ||
      lower.contains('authentication') ||
      lower.contains('not permitted') ||
      (writtenBytes == 0 && exitCode != 0);
  if (looksDenied) {
    return macosAuthopenDeniedMessage;
  }
  return 'Raw ISO write failed on $diskId: '
      '${err.isEmpty ? 'authopen exited $exitCode' : err}';
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
