import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:usb_iso_core/usb_iso_core.dart';

void main() {
  group('Safety.ensureWritable', () {
    test('accepts a removable USB disk', () {
      expect(() => Safety.ensureWritable(_usb()), returnsNormally);
    });

    test('rejects an internal disk', () {
      expect(
        () => Safety.ensureWritable(_usb(isInternal: true, bus: 'SATA')),
        throwsA(isA<UnsafeDiskException>()),
      );
    });

    test('rejects a boot disk', () {
      expect(
        () => Safety.ensureWritable(_usb(isBoot: true)),
        throwsA(isA<UnsafeDiskException>()),
      );
    });

    test('rejects a virtual disk image', () {
      expect(
        () => Safety.ensureWritable(
          _usb(isVirtual: true, bus: 'Disk Image', removable: true),
        ),
        throwsA(isA<UnsafeDiskException>()),
      );
    });

    test('rejects a non-USB internal SATA disk', () {
      expect(
        () => Safety.ensureWritable(
          _usb(
            bus: 'SATA',
            removable: false,
            isInternal: true,
            isVirtual: false,
          ),
        ),
        throwsA(isA<UnsafeDiskException>()),
      );
    });

    test('rejects a removable non-USB disk', () {
      expect(
        () => Safety.ensureWritable(
          _usb(bus: 'Secure Digital', removable: true, isInternal: false),
        ),
        throwsA(isA<UnsafeDiskException>()),
      );
    });
  });

  group('DiskId.normalize', () {
    test('accepts macOS whole-disk forms', () {
      expect(DiskId.normalize('disk4', operatingSystem: 'macos'), 'disk4');
      expect(DiskId.normalize('/dev/disk4', operatingSystem: 'macos'), 'disk4');
      expect(
        DiskId.normalize('/dev/rdisk4', operatingSystem: 'macos'),
        'disk4',
      );
    });

    test('rejects macOS partitions', () {
      expect(
        () => DiskId.normalize('disk4s1', operatingSystem: 'macos'),
        throwsA(isA<UsbIsoException>()),
      );
    });

    test('accepts Windows disk numbers', () {
      expect(DiskId.normalize('1', operatingSystem: 'windows'), '1');
      expect(
        DiskId.normalize('PhysicalDrive2', operatingSystem: 'windows'),
        '2',
      );
      expect(DiskId.normalize('Disk 3', operatingSystem: 'windows'), '3');
    });
  });

  group('WindowsIsoValidator', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('usb_iso_test_');
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('accepts a Windows-like layout', () {
      _writeWindowsLayout(temp, wimBytes: 64);
      final info = WindowsIsoValidator().inspectMounted(temp.path);
      expect(info.isValid, isTrue);
      expect(info.hasEfiBoot, isTrue);
      expect(info.installKind, WindowsInstallImageKind.wim);
      expect(info.needsSplit, isFalse);
      expect(() => WindowsIsoValidator().ensureValid(info), returnsNormally);
    });

    test('rejects a folder without EFI boot files', () {
      Directory(p.join(temp.path, 'sources')).createSync(recursive: true);
      File(p.join(temp.path, 'sources', 'install.wim')).writeAsBytesSync([1]);
      final info = WindowsIsoValidator().inspectMounted(temp.path);
      expect(info.isValid, isFalse);
      expect(
        () => WindowsIsoValidator().ensureValid(info),
        throwsA(isA<InvalidIsoException>()),
      );
    });

    test('rejects a folder without install.wim or install.esd', () {
      Directory(p.join(temp.path, 'efi', 'boot')).createSync(recursive: true);
      File(
        p.join(temp.path, 'efi', 'boot', 'bootx64.efi'),
      ).writeAsBytesSync([1]);
      final info = WindowsIsoValidator().inspectMounted(temp.path);
      expect(info.installKind, WindowsInstallImageKind.none);
      expect(
        () => WindowsIsoValidator().ensureValid(info),
        throwsA(isA<InvalidIsoException>()),
      );
    });

    test('detects ESD images', () {
      Directory(p.join(temp.path, 'efi', 'boot')).createSync(recursive: true);
      File(
        p.join(temp.path, 'efi', 'boot', 'bootx64.efi'),
      ).writeAsBytesSync([1]);
      Directory(p.join(temp.path, 'sources')).createSync();
      File(
        p.join(temp.path, 'sources', 'install.esd'),
      ).writeAsBytesSync([1, 2]);
      final info = WindowsIsoValidator().inspectMounted(temp.path);
      expect(info.installKind, WindowsInstallImageKind.esd);
      expect(info.needsSplit, isFalse);
      expect(info.isValid, isTrue);
    });
  });

  group('WindowsIsoInfo.needsSplit', () {
    test('is true only for oversized WIM files', () {
      const small = WindowsIsoInfo(
        mountPath: '/mnt',
        hasEfiBoot: true,
        installKind: WindowsInstallImageKind.wim,
        installImagePath: '/mnt/sources/install.wim',
        installImageSize: 1024,
      );
      const huge = WindowsIsoInfo(
        mountPath: '/mnt',
        hasEfiBoot: true,
        installKind: WindowsInstallImageKind.wim,
        installImagePath: '/mnt/sources/install.wim',
        installImageSize: fat32MaxFileBytes + 1,
      );
      const hugeEsd = WindowsIsoInfo(
        mountPath: '/mnt',
        hasEfiBoot: true,
        installKind: WindowsInstallImageKind.esd,
        installImagePath: '/mnt/sources/install.esd',
        installImageSize: fat32MaxFileBytes + 1,
      );
      expect(small.needsSplit, isFalse);
      expect(huge.needsSplit, isTrue);
      expect(hugeEsd.needsSplit, isFalse);
    });
  });

  group('usbDiskFromMacosInfo', () {
    test('keeps a physical USB disk', () {
      final disk = usbDiskFromMacosInfo(
        {
          'DeviceIdentifier': 'disk70',
          'DeviceNode': '/dev/disk70',
          'BusProtocol': 'USB',
          'Removable': true,
          'RemovableMedia': true,
          'Internal': false,
          'TotalSize': 61530439680,
          'MediaName': 'SanDisk 3.2Gen1',
          'VirtualOrPhysical': 'Physical',
        },
        bootWholeDisk: 'disk3',
        mountPoints: ['/Volumes/UNTITLED'],
      );
      expect(disk, isNotNull);
      expect(disk!.id, 'disk70');
      expect(disk.isSafeTarget, isTrue);
      expect(disk.mountPoints, ['/Volumes/UNTITLED']);
    });

    test('drops the boot disk even if it were USB', () {
      expect(
        usbDiskFromMacosInfo({
          'DeviceIdentifier': 'disk3',
          'BusProtocol': 'USB',
          'Internal': false,
          'Removable': true,
          'TotalSize': 1000,
          'VirtualOrPhysical': 'Physical',
        }, bootWholeDisk: 'disk3'),
        isNull,
      );
    });

    test('drops disk images and internal SSDs', () {
      expect(
        usbDiskFromMacosInfo({
          'DeviceIdentifier': 'disk4',
          'BusProtocol': 'Disk Image',
          'Internal': false,
          'Removable': true,
          'TotalSize': 1000,
          'VirtualOrPhysical': 'Virtual',
        }, bootWholeDisk: 'disk3'),
        isNull,
      );
      expect(
        usbDiskFromMacosInfo({
          'DeviceIdentifier': 'disk0',
          'BusProtocol': 'Apple Fabric',
          'Internal': true,
          'Removable': false,
          'TotalSize': 1000000,
          'VirtualOrPhysical': 'Unknown',
        }, bootWholeDisk: 'disk3'),
        isNull,
      );
    });
  });

  group('usbDiskFromWindowsInfo', () {
    test('keeps a USB disk and drops boot disks', () {
      final usb = usbDiskFromWindowsInfo({
        'Number': 2,
        'FriendlyName': 'SanDisk',
        'Size': 16000000000,
        'BusType': 'USB',
        'IsBoot': false,
        'IsSystem': false,
        'DriveLetters': ['E:\\'],
      });
      expect(usb, isNotNull);
      expect(usb!.id, '2');
      expect(usb.devicePath, r'\\.\PhysicalDrive2');

      expect(
        usbDiskFromWindowsInfo({
          'Number': 0,
          'FriendlyName': 'NVMe',
          'Size': 512000000000,
          'BusType': 'NVMe',
          'IsBoot': true,
          'IsSystem': true,
          'DriveLetters': ['C:\\'],
        }),
        isNull,
      );
    });
  });

  group('hdiutil attach parsing', () {
    test('reads the volume path and device node', () {
      const stdout = '''
/dev/disk88          	GUID_partition_scheme          	
/dev/disk88s1        	Microsoft Basic Data           	/Volumes/CCCOMA_X64FRE_EN-US_DV9
''';
      expect(hdiutilMountPath(stdout), '/Volumes/CCCOMA_X64FRE_EN-US_DV9');
      expect(hdiutilDeviceNode(stdout), '/dev/disk88');
    });

    test('reuses an already-attached ISO from hdiutil info', () {
      const info = '''
image-path      : /Users/me/Downloads/Win11.iso
image-type      : read/write
/dev/disk71		/Volumes/CCCOMA_X64FRE_EN-US_DV9
''';
      final mount = isoMountFromHdiutilInfo(
        info,
        '/Users/me/Downloads/Win11.iso',
      );
      expect(mount, isNotNull);
      expect(mount!.mountPath, '/Volumes/CCCOMA_X64FRE_EN-US_DV9');
      expect(mount.deviceNode, '/dev/disk71');
    });

    test('keeps spaces in the volume name', () {
      const stdout = '''
/dev/disk88          	GUID_partition_scheme          	
/dev/disk88s1        	Microsoft Basic Data           	/Volumes/Win 11 Setup
''';
      expect(hdiutilMountPath(stdout), '/Volumes/Win 11 Setup');
    });
  });

  group('isoLivesOnMount', () {
    test('detects an ISO inside the USB mount', () {
      expect(
        isoLivesOnMount('/Volumes/UNTITLED/Win11.iso', '/Volumes/UNTITLED'),
        isTrue,
      );
    });

    test('does not match a similarly prefixed volume name', () {
      expect(
        isoLivesOnMount(
          '/Volumes/UNTITLED-BACKUP/Win11.iso',
          '/Volumes/UNTITLED',
        ),
        isFalse,
      );
    });
  });

  group('ProcessRunner', () {
    test('returns exit 127 when the executable is missing', () async {
      final result = await ProcessRunner().run(
        'usb_iso_definitely_missing_tool',
        ['--version'],
      );
      expect(result.success, isFalse);
      expect(result.exitCode, 127);
    });
  });

  group('formatBytes', () {
    test('formats common sizes', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(10 * 1024 * 1024), '10.0 MB');
      expect(formatBytes(61530439680), '57.3 GB');
    });
  });

  group('BootableWriter confirmation', () {
    test('refuses to write without confirmation', () async {
      final writer = BootableWriter();
      expect(
        () => writer
            .write(WriteRequest(isoPath: '/tmp/missing.iso', disk: _usb()))
            .toList(),
        throwsA(isA<ConfirmationRequiredException>()),
      );
    });

    test('refuses an ISO that lives on the target USB', () async {
      final writer = BootableWriter();
      expect(
        () => writer
            .write(
              WriteRequest(
                isoPath: '/Volumes/UNTITLED/Win11.iso',
                disk: _usb().copyWith(mountPoints: ['/Volumes/UNTITLED']),
                confirmed: true,
              ),
            )
            .toList(),
        throwsA(isA<UsbIsoException>()),
      );
    });

    test('allows an ISO on a similarly named volume', () async {
      expect(
        isoLivesOnAnyMount('/Volumes/UNTITLED-BACKUP/Win11.iso', [
          '/Volumes/UNTITLED',
        ]),
        isFalse,
      );
    });
  });

  group('firstOversizedFat32File', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('usb_iso_fat32_');
      _writeWindowsLayout(temp, wimBytes: 64);
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('ignores install.wim when skipWim is true', () async {
      expect(
        await firstOversizedFat32File(temp.path, skipWim: true, limit: 10),
        isNull,
      );
    });

    test('reports other oversized files', () async {
      File(p.join(temp.path, 'huge.bin')).writeAsBytesSync(List.filled(32, 1));
      expect(
        await firstOversizedFat32File(temp.path, skipWim: true, limit: 10),
        'huge.bin',
      );
    });
  });

  group('BootableWriter with FakeHost', () {
    late Directory temp;
    late File iso;
    late FakeHost host;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('usb_iso_write_');
      _writeWindowsLayout(temp, wimBytes: 64);
      iso = File(p.join(temp.path, 'Win11.iso'))
        ..writeAsBytesSync(List<int>.filled(1024, 9));
      host = FakeHost(
        mount: IsoMount(isoPath: iso.path, mountPath: temp.path),
      );
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('dry-run validates without erasing', () async {
      final events = await BootableWriter(host: host)
          .write(WriteRequest(isoPath: iso.path, disk: _usb(), dryRun: true))
          .toList();
      expect(host.eraseCalls, 0);
      expect(events.last.step, WriteStep.done);
      expect(events.last.message, contains('Dry run'));
    });

    test('reuses an already-mounted ISO', () async {
      await BootableWriter(host: host)
          .write(
            WriteRequest(
              isoPath: iso.path,
              disk: _usb(),
              dryRun: true,
              existingMount: IsoMount(isoPath: iso.path, mountPath: temp.path),
            ),
          )
          .toList();
      expect(host.mountCalls, 0);
      expect(host.unmountCalls, 0);
    });

    test('refuses a USB smaller than the ISO', () async {
      expect(
        () => BootableWriter(host: host)
            .write(
              WriteRequest(
                isoPath: iso.path,
                disk: UsbDisk(
                  id: 'disk70',
                  devicePath: '/dev/disk70',
                  name: 'Tiny',
                  sizeBytes: 100,
                  busProtocol: 'USB',
                  isRemovable: true,
                  isInternal: false,
                  isBoot: false,
                  isVirtual: false,
                ),
                dryRun: true,
              ),
            )
            .toList(),
        throwsA(
          isA<UsbIsoException>().having(
            (e) => e.message,
            'message',
            contains('Use a larger drive'),
          ),
        ),
      );
      expect(host.eraseCalls, 0);
    });

    test('treats eject failure as a warning', () async {
      final dest = Directory('${temp.path}_dest')..createSync();
      addTearDown(() {
        if (dest.existsSync()) {
          dest.deleteSync(recursive: true);
        }
      });
      host
        ..destination = dest
        ..ejectError = 'device busy';
      final events = await BootableWriter(host: host)
          .write(WriteRequest(isoPath: iso.path, disk: _usb(), confirmed: true))
          .toList();
      expect(host.eraseCalls, 1);
      expect(events.last.step, WriteStep.done);
      expect(events.last.message, contains('eject failed'));
    });
  });
}

class FakeHost implements HostPlatform {
  FakeHost({required this.mount});

  final IsoMount mount;
  int mountCalls = 0;
  int unmountCalls = 0;
  int eraseCalls = 0;
  Directory? destination;
  String? ejectError;

  @override
  Future<List<UsbDisk>> listUsbDisks() async => const [];

  @override
  Future<void> verifyWritable(UsbDisk disk) async {}

  @override
  Future<IsoMount> mountIso(String isoPath) async {
    mountCalls++;
    return mount;
  }

  @override
  Future<void> unmountIso(IsoMount mount) async {
    unmountCalls++;
  }

  @override
  Future<void> eraseAndFormat(UsbDisk disk) async {
    eraseCalls++;
  }

  @override
  Future<String> waitForVolumeMount(UsbDisk disk) async {
    final dir = destination ?? Directory.systemTemp.createTempSync('usb_dest_');
    dir.createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<void> eject(UsbDisk disk) async {
    if (ejectError != null) {
      throw UsbIsoException(ejectError!);
    }
  }

  @override
  Future<String?> findWimSplitTool() async => null;

  @override
  Future<void> splitWim({
    required String sourceWim,
    required String destinationSwm,
    required String toolPath,
  }) async {}
}

UsbDisk _usb({
  String bus = 'USB',
  bool removable = true,
  bool isInternal = false,
  bool isBoot = false,
  bool isVirtual = false,
}) {
  return UsbDisk(
    id: 'disk70',
    devicePath: '/dev/disk70',
    name: 'SanDisk',
    sizeBytes: 61530439680,
    busProtocol: bus,
    isRemovable: removable,
    isInternal: isInternal,
    isBoot: isBoot,
    isVirtual: isVirtual,
  );
}

void _writeWindowsLayout(Directory root, {required int wimBytes}) {
  Directory(p.join(root.path, 'efi', 'boot')).createSync(recursive: true);
  File(p.join(root.path, 'efi', 'boot', 'bootx64.efi')).writeAsBytesSync([1]);
  Directory(p.join(root.path, 'sources')).createSync();
  File(
    p.join(root.path, 'sources', 'install.wim'),
  ).writeAsBytesSync(List<int>.filled(wimBytes, 7));
}
