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
import '../privilege.dart';
import '../process_runner.dart';

const _volumeLabel = 'WINSETUP';

/// PowerShell that takes the disk offline, streams the ISO, then onlines it.
String windowsRawWritePowerShell({
  required int diskNumber,
  required String isoPath,
  required String progressPath,
  required String cancelPath,
}) {
  final escapedIso = isoPath.replaceAll("'", "''");
  final escapedProgress = progressPath.replaceAll("'", "''");
  final escapedCancel = cancelPath.replaceAll("'", "''");
  return '''
\$ErrorActionPreference = 'Stop'
\$diskNumber = $diskNumber
\$isoPath = '$escapedIso'
\$progressPath = '$escapedProgress'
\$cancelPath = '$escapedCancel'
\$disk = Get-Disk -Number \$diskNumber
if (\$disk.IsBoot -or \$disk.IsSystem) { throw 'Refusing to erase a boot disk' }

Get-Disk -Number \$diskNumber | Get-Partition -ErrorAction SilentlyContinue |
  Get-Volume -ErrorAction SilentlyContinue |
  Dismount-Volume -Force -ErrorAction SilentlyContinue

Clear-Disk -Number \$diskNumber -RemoveData -RemoveOEM -Confirm:\$false

try {
  Set-Disk -Number \$diskNumber -IsReadOnly \$false -ErrorAction SilentlyContinue
  Set-Disk -Number \$diskNumber -IsOffline \$true
} catch {
  # Some USB controllers reject offline; volumes are already dismounted.
}

\$src = \$null
\$dst = \$null
try {
  \$src = [IO.File]::OpenRead(\$isoPath)
  \$dst = New-Object IO.FileStream(
    "\\\\.\\PhysicalDrive\$diskNumber",
    [IO.FileMode]::Open,
    [IO.FileAccess]::Write,
    [IO.FileShare]::None
  )
  \$buf = New-Object byte[] (8MB)
  \$written = 0
  while ((\$n = \$src.Read(\$buf, 0, \$buf.Length)) -gt 0) {
    if (Test-Path -LiteralPath \$cancelPath) { exit 75 }
    \$dst.Write(\$buf, 0, \$n)
    \$written += \$n
    Set-Content -LiteralPath \$progressPath -Value \$written
  }
  \$dst.Flush()
} finally {
  if (\$dst) { \$dst.Dispose() }
  if (\$src) { \$src.Dispose() }
  try { Set-Disk -Number \$diskNumber -IsOffline \$false } catch {}
}
''';
}

bool isAdvancedWindowsBus(String bus) {
  final value = bus.toUpperCase();
  return value == 'SD' ||
      value == 'MMC' ||
      value == 'SD/MMC' ||
      value == 'SECURE DIGITAL';
}

/// Parses a Get-Disk JSON object into a USB target, or null if unsafe.
UsbDisk? usbDiskFromWindowsInfo(
  Map<String, dynamic> info, {
  bool includeAdvanced = false,
}) {
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

  final isUsb = bus.toUpperCase() == 'USB';
  final isAdvanced = isAdvancedWindowsBus(bus);
  final disk = UsbDisk(
    id: id,
    devicePath: '\\\\.\\PhysicalDrive$id',
    name: asString(info['FriendlyName']).trim().isEmpty
        ? 'USB drive'
        : asString(info['FriendlyName']).trim(),
    sizeBytes: asInt(info['Size']),
    busProtocol: bus,
    isRemovable: isUsb || isAdvanced,
    isInternal: !isUsb && !isAdvanced,
    isBoot: isBoot,
    isVirtual: false,
    mountPoints: letters,
  );

  if (disk.isSafeTarget) {
    return disk;
  }
  if (includeAdvanced && disk.isAdvancedTarget) {
    return disk;
  }
  return null;
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
  Future<List<UsbDisk>> listUsbDisks({bool includeAdvanced = false}) async {
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
        final disk = usbDiskFromWindowsInfo(
          item,
          includeAdvanced: includeAdvanced,
        );
        if (disk != null) {
          disks.add(disk);
        }
      } else if (item is Map) {
        final disk = usbDiskFromWindowsInfo(
          Map<String, dynamic>.from(item),
          includeAdvanced: includeAdvanced,
        );
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
  Future<void> verifyWritable(
    UsbDisk disk, {
    bool allowAdvancedTargets = false,
  }) async {
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
    final current = usbDiskFromWindowsInfo(
      decodeJsonObject(result.stdout),
      includeAdvanced: allowAdvancedTargets,
    );
    if (current == null || current.id != disk.id) {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: it is no longer a removable USB drive.',
      );
    }
  }

  String _busGuard(bool allowAdvanced) {
    if (allowAdvanced) {
      return r"if ([string]$disk.BusType -notin @('USB','SD','MMC')) { throw 'Not a removable disk' }";
    }
    return r"if ([string]$disk.BusType -ne 'USB') { throw 'Not a USB disk' }";
  }

  @override
  Future<void> eraseAndFormat(
    UsbDisk disk, {
    DiskLayout layout = DiskLayout.fat32,
  }) async {
    await WindowsPrivilege.ensureAdministrator(runner: _runner);
    await verifyWritable(disk);
    final number = int.parse(disk.id);
    final busGuard = _busGuard(disk.isAdvancedTarget);
    final script = layout == DiskLayout.fat32PlusNtfs
        ? '''
\$ErrorActionPreference = 'Stop'
\$diskNumber = $number
\$disk = Get-Disk -Number \$diskNumber
$busGuard
if (\$disk.IsBoot -or \$disk.IsSystem) { throw 'Refusing to erase a boot disk' }

Get-Disk -Number \$diskNumber | Get-Partition -ErrorAction SilentlyContinue |
  Get-Volume -ErrorAction SilentlyContinue |
  Dismount-Volume -Force -ErrorAction SilentlyContinue

Clear-Disk -Number \$diskNumber -RemoveData -RemoveOEM -Confirm:\$false
Initialize-Disk -Number \$diskNumber -PartitionStyle GPT | Out-Null

\$bootSize = $windowsFat32BootPartitionBytes
\$boot = New-Partition -DiskNumber \$diskNumber -Size \$bootSize -AssignDriveLetter
Format-Volume -Partition \$boot -FileSystem FAT32 -NewFileSystemLabel 'WINBOOT' -Confirm:\$false | Out-Null
\$data = New-Partition -DiskNumber \$diskNumber -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition \$data -FileSystem NTFS -NewFileSystemLabel '$_volumeLabel' -Confirm:\$false | Out-Null
@{ Boot = [string]\$boot.DriveLetter; Data = [string]\$data.DriveLetter } | ConvertTo-Json -Compress
'''
        : '''
\$ErrorActionPreference = 'Stop'
\$diskNumber = $number
\$disk = Get-Disk -Number \$diskNumber
$busGuard
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
  Future<PreparedVolumes> waitForVolumeMount(
    UsbDisk disk, {
    DiskLayout layout = DiskLayout.fat32,
  }) async {
    final number = int.parse(disk.id);
    for (var i = 0; i < 40; i++) {
      if (layout == DiskLayout.fat32PlusNtfs) {
        final result = await _powershell('''
\$ErrorActionPreference = 'Stop'
Get-Partition -DiskNumber $number | ForEach-Object {
  \$vol = Get-Volume -Partition \$_ -ErrorAction SilentlyContinue
  if (-not \$vol -or -not \$_.DriveLetter) { return }
  [PSCustomObject]@{
    Letter = [string]\$_.DriveLetter
    Label = [string]\$vol.FileSystemLabel
    Fs = [string]\$vol.FileSystem
  }
} | ConvertTo-Json -Compress
''');
        if (result.success && result.stdout.trim().isNotEmpty) {
          String? boot;
          String? data;
          for (final item in decodeJsonList(result.stdout)) {
            if (item is! Map) {
              continue;
            }
            final map = Map<String, dynamic>.from(item);
            final letter = asString(map['Letter']);
            final label = asString(map['Label']).toUpperCase();
            if (letter.isEmpty) {
              continue;
            }
            final root = letter.endsWith(':') ? '$letter\\' : '$letter:\\';
            if (label == 'WINBOOT' && Directory(root).existsSync()) {
              boot = root;
            }
            if (label == _volumeLabel && Directory(root).existsSync()) {
              data = root;
            }
          }
          if (boot != null && data != null) {
            return PreparedVolumes(bootMount: boot, dataMount: data);
          }
        }
      } else {
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
            return PreparedVolumes(bootMount: root);
          }
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

  @override
  Future<void> writeRawImage({
    required UsbDisk disk,
    required String isoPath,
    RawWriteProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    await WindowsPrivilege.ensureAdministrator(runner: _runner);
    await verifyWritable(disk);
    cancellation?.throwIfCancelled();
    final number = int.parse(disk.id);
    final work = Directory.systemTemp.createTempSync('usb_iso_raw_');
    final progressFile = File(p.join(work.path, 'progress'));
    final cancelFile = File(p.join(work.path, 'cancel'));
    final script = windowsRawWritePowerShell(
      diskNumber: number,
      isoPath: isoPath,
      progressPath: progressFile.path,
      cancelPath: cancelFile.path,
    );
    try {
      final file = File(p.join(work.path, 'write.ps1'));
      await file.writeAsString(script, flush: true);
      final process = await _runner.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        file.path,
      ]);
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
              'Raw ISO write failed on disk ${disk.id}: ${err.trim()}',
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
    final result = await _powershell('''
\$ErrorActionPreference = 'SilentlyContinue'
Get-Partition -DiskNumber ${disk.id} |
  Where-Object { \$_.DriveLetter } |
  ForEach-Object {
    \$vol = Get-Volume -DriveLetter \$_.DriveLetter
    if (\$vol) { Write-VolumeCache -DriveLetter \$_.DriveLetter }
  }
''');
    if (!result.success) {
      throw UsbIsoException(
        'Failed to flush disk ${disk.id}: ${result.stderr.trim()}',
      );
    }
  }
}
