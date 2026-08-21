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

/// Parses a Get-Disk JSON object into a USB target, or null if unsafe.
UsbDisk? usbDiskFromWindowsInfo(Map<String, dynamic> info) {
  final id = asString(info['Number']);
  if (id.isEmpty) {
    return null;
  }

  final bus = asString(info['BusType']);
  final isBoot = asBool(info['IsBoot']) || asBool(info['IsSystem']);
  final letters = <String>[];
  final rawLetters = info['DriveLetters'];
  if (rawLetters is List) {
    letters.addAll(rawLetters.map((e) => '$e'));
  }

  final disk = UsbDisk(
    id: id,
    devicePath: '\\\\.\\PhysicalDrive$id',
    name: asString(info['FriendlyName']).trim().isEmpty
        ? 'USB drive'
        : asString(info['FriendlyName']).trim(),
    sizeBytes: asInt(info['Size']),
    busProtocol: bus,
    isRemovable: bus.toUpperCase() == 'USB',
    isInternal: bus.toUpperCase() != 'USB',
    isBoot: isBoot,
    isVirtual: false,
    mountPoints: letters,
  );

  if (bus.toUpperCase() != 'USB' || !disk.isSafeTarget) {
    return null;
  }
  return disk;
}

class WindowsHost implements HostPlatform {
  WindowsHost(this._runner);

  final ProcessRunner _runner;

  Future<CommandResult> _powershell(String script) {
    return _runner.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
  }

  Future<CommandResult> _powershellFile(String script) async {
    final file = File(
      p.join(
        Directory.systemTemp.path,
        'usb_iso_${DateTime.now().microsecondsSinceEpoch}.ps1',
      ),
    );
    await file.writeAsString(script, flush: true);
    try {
      return await _runner.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        file.path,
      ]);
    } finally {
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  @override
  Future<List<UsbDisk>> listUsbDisks() async {
    const script = r'''
$ErrorActionPreference = 'Stop'
Get-Disk | ForEach-Object {
  $letters = @()
  Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
    Where-Object { $_.DriveLetter } |
    ForEach-Object { $letters += "$($_.DriveLetter):\" }
  [PSCustomObject]@{
    Number = $_.Number
    FriendlyName = $_.FriendlyName
    Size = [int64]$_.Size
    BusType = [string]$_.BusType
    IsBoot = [bool]$_.IsBoot
    IsSystem = [bool]$_.IsSystem
    DriveLetters = $letters
  }
} | ConvertTo-Json -Compress
''';
    final result = await _powershell(script);
    if (!result.success) {
      throw UsbIsoException('Get-Disk failed: ${result.stderr.trim()}');
    }
    final disks = <UsbDisk>[];
    for (final item in decodeJsonList(result.stdout)) {
      if (item is Map<String, dynamic>) {
        final disk = usbDiskFromWindowsInfo(item);
        if (disk != null) {
          disks.add(disk);
        }
      } else if (item is Map) {
        final disk = usbDiskFromWindowsInfo(Map<String, dynamic>.from(item));
        if (disk != null) {
          disks.add(disk);
        }
      }
    }
    return disks;
  }

  @override
  Future<IsoMount> mountIso(String isoPath) async {
    if (!File(isoPath).existsSync()) {
      throw InvalidIsoException('ISO not found: $isoPath');
    }
    final escaped = isoPath.replaceAll("'", "''");
    final script =
        '''
\$ErrorActionPreference = 'Stop'
\$img = Mount-DiskImage -ImagePath '$escaped' -PassThru
\$vols = Get-Volume -DiskImage \$img
foreach (\$vol in @(\$vols)) {
  if (-not \$vol.DriveLetter) { continue }
  \$root = "\$(\$vol.DriveLetter):\\"
  [PSCustomObject]@{ DriveLetter = "\$(\$vol.DriveLetter)"; Root = \$root } |
    ConvertTo-Json -Compress
  break
}
''';
    final result = await _powershell(script);
    if (!result.success) {
      throw UsbIsoException('Failed to mount ISO: ${result.stderr.trim()}');
    }
    final obj = decodeJsonObject(result.stdout);
    final root = asString(obj['Root']);
    if (root.isEmpty) {
      throw UsbIsoException(
        'Mounted the ISO but no drive letter was assigned.',
      );
    }
    return IsoMount(isoPath: isoPath, mountPath: root);
  }

  @override
  Future<void> unmountIso(IsoMount mount) async {
    final escaped = mount.isoPath.replaceAll("'", "''");
    final result = await _powershell(
      "Dismount-DiskImage -ImagePath '$escaped'",
    );
    if (!result.success) {
      throw UsbIsoException('Failed to unmount ISO: ${result.stderr.trim()}');
    }
  }

  @override
  Future<void> verifyWritable(UsbDisk disk) async {
    final number = int.parse(disk.id);
    final result = await _powershell('''
\$ErrorActionPreference = 'Stop'
\$d = Get-Disk -Number $number
[PSCustomObject]@{
  Number = \$d.Number
  FriendlyName = \$d.FriendlyName
  Size = [int64]\$d.Size
  BusType = [string]\$d.BusType
  IsBoot = [bool]\$d.IsBoot
  IsSystem = [bool]\$d.IsSystem
  DriveLetters = @()
} | ConvertTo-Json -Compress
''');
    if (!result.success) {
      throw UnsafeDiskException(
        'Could not re-check disk ${disk.id}: ${result.stderr.trim()}',
      );
    }
    final current = usbDiskFromWindowsInfo(decodeJsonObject(result.stdout));
    if (current == null || current.id != disk.id) {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: it is no longer a removable USB drive.',
      );
    }
  }

  @override
  Future<void> eraseAndFormat(UsbDisk disk) async {
    await verifyWritable(disk);
    final number = int.parse(disk.id);
    final script =
        '''
\$ErrorActionPreference = 'Stop'
\$diskNumber = $number
\$disk = Get-Disk -Number \$diskNumber
if ([string]\$disk.BusType -ne 'USB') { throw 'Not a USB disk' }
if (\$disk.IsBoot -or \$disk.IsSystem) { throw 'Refusing to erase a boot disk' }

Get-Disk -Number \$diskNumber | Get-Partition -ErrorAction SilentlyContinue |
  Get-Volume -ErrorAction SilentlyContinue |
  Dismount-Volume -Force -ErrorAction SilentlyContinue

Clear-Disk -Number \$diskNumber -RemoveData -RemoveOEM -Confirm:\$false
Initialize-Disk -Number \$diskNumber -PartitionStyle GPT | Out-Null

\$maxFat32 = $windowsFat32PartitionMaxBytes
if (\$disk.Size -gt \$maxFat32) {
  \$part = New-Partition -DiskNumber \$diskNumber -Size \$maxFat32 -AssignDriveLetter
} else {
  \$part = New-Partition -DiskNumber \$diskNumber -UseMaximumSize -AssignDriveLetter
}
\$vol = Format-Volume -Partition \$part -FileSystem FAT32 -NewFileSystemLabel '$_volumeLabel' -Confirm:\$false
@{ DriveLetter = [string]\$vol.DriveLetter } | ConvertTo-Json -Compress
''';
    final result = await _powershellFile(script);
    if (!result.success) {
      throw UsbIsoException(
        'Failed to erase disk ${disk.id}: ${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
      );
    }
  }

  @override
  Future<String> waitForVolumeMount(UsbDisk disk) async {
    final number = int.parse(disk.id);
    for (var i = 0; i < 40; i++) {
      final result = await _powershell('''
\$ErrorActionPreference = 'Stop'
Get-Partition -DiskNumber $number |
  Where-Object { \$_.DriveLetter } |
  Select-Object -First 1 -ExpandProperty DriveLetter
''');
      final letter = result.stdout.trim();
      if (result.success && letter.isNotEmpty) {
        final root = letter.endsWith(':') ? '$letter\\' : '$letter:\\';
        if (Directory(root).existsSync()) {
          return root;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw UsbIsoException(
      'Formatted disk ${disk.id} but no drive letter was assigned.',
    );
  }

  @override
  Future<void> eject(UsbDisk disk) async {
    final result = await _powershell('''
\$ErrorActionPreference = 'SilentlyContinue'
Get-Partition -DiskNumber ${disk.id} |
  Where-Object { \$_.DriveLetter } |
  ForEach-Object { Dismount-Volume -DriveLetter \$_.DriveLetter -Force }
''');
    if (!result.success) {
      throw UsbIsoException(
        'Wrote the USB, but eject failed: ${result.stderr.trim()}',
      );
    }
  }

  @override
  Future<String?> findWimSplitTool() async {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final dism = p.join(systemRoot, 'System32', 'Dism.exe');
    if (File(dism).existsSync()) {
      return dism;
    }
    final result = await _runner.run('where.exe', ['dism']);
    if (result.success) {
      final path = result.stdout.trim().split(RegExp(r'\r?\n')).first.trim();
      if (path.isNotEmpty) {
        return path;
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
      '/Split-Image',
      '/ImageFile:$sourceWim',
      '/SWMFile:$destinationSwm',
      '/FileSize:$wimSplitSizeMiB',
    ]);
    if (!result.success) {
      throw UsbIsoException(
        'DISM split failed: ${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
      );
    }
  }
}
