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

    test('accepts SD when advanced targets are allowed', () {
      expect(
        () => Safety.ensureWritable(
          _usb(bus: 'Secure Digital', removable: true, isInternal: false),
          allowAdvancedTargets: true,
        ),
        returnsNormally,
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

    test('accepts Linux whole disks and rejects partitions', () {
      expect(DiskId.normalize('sda', operatingSystem: 'linux'), 'sda');
      expect(
        DiskId.normalize('/dev/nvme0n1', operatingSystem: 'linux'),
        'nvme0n1',
      );
      expect(
        () => DiskId.normalize('sda1', operatingSystem: 'linux'),
        throwsA(isA<UsbIsoException>()),
      );
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

    test('accepts ARM EFI plus install.wim', () {
      Directory(p.join(temp.path, 'efi', 'boot')).createSync(recursive: true);
      File(
        p.join(temp.path, 'efi', 'boot', 'bootaa64.efi'),
      ).writeAsBytesSync([1]);
      Directory(p.join(temp.path, 'sources')).createSync();
      File(p.join(temp.path, 'sources', 'install.wim')).writeAsBytesSync([1]);
      final info = WindowsIsoValidator().inspectMounted(temp.path);
      expect(info.isValid, isTrue);
      expect(info.hasEfiBoot, isTrue);
    });

    test('accepts WinPE boot.wim', () {
      Directory(p.join(temp.path, 'efi', 'boot')).createSync(recursive: true);
      File(
        p.join(temp.path, 'efi', 'boot', 'bootx64.efi'),
      ).writeAsBytesSync([1]);
      Directory(p.join(temp.path, 'sources')).createSync();
      File(
        p.join(temp.path, 'sources', 'boot.wim'),
      ).writeAsBytesSync([1, 2, 3]);
      final info = WindowsIsoValidator().inspectMounted(temp.path);
      expect(info.installKind, WindowsInstallImageKind.bootWim);
      expect(() => WindowsIsoValidator().ensureValid(info), returnsNormally);
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
    test('is true for oversized WIM and ESD files', () {
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
      expect(hugeEsd.needsSplit, isTrue);
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

    test('cancels before erase', () async {
      final token = CancellationToken()..cancel();
      expect(
        () => BootableWriter(host: host)
            .write(
              WriteRequest(
                isoPath: iso.path,
                disk: _usb(),
                confirmed: true,
                cancellation: token,
              ),
            )
            .toList(),
        throwsA(isA<WriteCancelledException>()),
      );
      expect(host.eraseCalls, 0);
    });

    test('raw-writes a Linux live ISO', () async {
      final linuxRoot = Directory('${temp.path}_linux')..createSync();
      addTearDown(() {
        if (linuxRoot.existsSync()) {
          linuxRoot.deleteSync(recursive: true);
        }
      });
      _writeLinuxLayout(linuxRoot);
      final linuxHost = FakeHost(
        mount: IsoMount(isoPath: iso.path, mountPath: linuxRoot.path),
      );
      final events = await BootableWriter(host: linuxHost)
          .write(WriteRequest(isoPath: iso.path, disk: _usb(), confirmed: true))
          .toList();
      expect(linuxHost.rawWriteCalls, 1);
      expect(linuxHost.eraseCalls, 0);
      expect(events.last.step, WriteStep.done);
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

  group('IsoInspector', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('usb_iso_inspect_');
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('classifies Windows x64, ARM, WinPE, Linux, and unknown', () {
      _writeWindowsLayout(temp, wimBytes: 8);
      expect(IsoInspector().inspectMounted(temp.path).kind, IsoKind.windowsX64);

      temp.deleteSync(recursive: true);
      temp.createSync();
      Directory(p.join(temp.path, 'efi', 'boot')).createSync(recursive: true);
      File(
        p.join(temp.path, 'efi', 'boot', 'bootaa64.efi'),
      ).writeAsBytesSync([1]);
      Directory(p.join(temp.path, 'sources')).createSync();
      File(p.join(temp.path, 'sources', 'install.wim')).writeAsBytesSync([1]);
      expect(IsoInspector().inspectMounted(temp.path).kind, IsoKind.windowsArm);

      temp.deleteSync(recursive: true);
      temp.createSync();
      Directory(p.join(temp.path, 'efi', 'boot')).createSync(recursive: true);
      File(
        p.join(temp.path, 'efi', 'boot', 'bootx64.efi'),
      ).writeAsBytesSync([1]);
      Directory(p.join(temp.path, 'sources')).createSync();
      File(p.join(temp.path, 'sources', 'boot.wim')).writeAsBytesSync([1]);
      expect(IsoInspector().inspectMounted(temp.path).kind, IsoKind.windowsPe);

      temp.deleteSync(recursive: true);
      temp.createSync();
      _writeLinuxLayout(temp);
      expect(
        IsoInspector().inspectMounted(temp.path).kind,
        IsoKind.linuxHybrid,
      );

      temp.deleteSync(recursive: true);
      temp.createSync();
      File(p.join(temp.path, 'readme.txt')).writeAsStringSync('nope');
      expect(IsoInspector().inspectMounted(temp.path).kind, IsoKind.unknown);
    });

    test('classifies a hybrid Linux ISO from the file', () {
      final iso = File(p.join(temp.path, 'ubuntu.iso'));
      iso.writeAsBytesSync(_minimalLinuxIso());
      final profile = IsoInspector().inspectIsoFile(iso.path);
      expect(profile.kind, IsoKind.linuxHybrid);
      expect(readIso9660Info(iso.path)?.volumeId, contains('Ubuntu'));
    });

    test('classifies the local Ubuntu ISO when present', () {
      const path = '/Users/ujjwaljha/Downloads/ubuntu-26.04-desktop-amd64.iso';
      if (!File(path).existsSync()) {
        return;
      }
      expect(IsoInspector().inspectIsoFile(path).kind, IsoKind.linuxHybrid);
    });
  });

  group('LayoutChooser', () {
    IsoProfile profile(IsoKind kind, {int installSize = 1024}) {
      return IsoProfile(
        mountPath: '/mnt',
        kind: kind,
        hasX64Efi: kind != IsoKind.windowsArm && kind != IsoKind.unknown,
        hasArmEfi: kind == IsoKind.windowsArm,
        installKind: kind == IsoKind.windowsPe
            ? WindowsInstallImageKind.bootWim
            : kind == IsoKind.linuxHybrid || kind == IsoKind.unknown
            ? WindowsInstallImageKind.none
            : WindowsInstallImageKind.wim,
        installImagePath: kind == IsoKind.linuxHybrid || kind == IsoKind.unknown
            ? null
            : '/mnt/sources/install.wim',
        installImageSize: installSize,
      );
    }

    test('routes Linux to raw write and unknown to unsupported', () {
      expect(
        LayoutChooser.strategyFor(
          profile: profile(IsoKind.linuxHybrid),
          windowsHost: false,
          diskSizeBytes: 16 * 1024 * 1024 * 1024,
        ),
        WriteStrategy.rawHybrid,
      );
      expect(
        LayoutChooser.strategyFor(
          profile: profile(IsoKind.unknown),
          windowsHost: true,
          diskSizeBytes: 16 * 1024 * 1024 * 1024,
        ),
        WriteStrategy.unsupported,
      );
    });

    test('uses dual partition on Windows for oversized images', () {
      expect(
        LayoutChooser.strategyFor(
          profile: profile(
            IsoKind.windowsX64,
            installSize: fat32MaxFileBytes + 1,
          ),
          windowsHost: true,
          diskSizeBytes: 64 * 1024 * 1024 * 1024,
        ),
        WriteStrategy.windowsDualPartition,
      );
      expect(
        LayoutChooser.strategyFor(
          profile: profile(
            IsoKind.windowsX64,
            installSize: fat32MaxFileBytes + 1,
          ),
          windowsHost: false,
          diskSizeBytes: 64 * 1024 * 1024 * 1024,
        ),
        WriteStrategy.windowsFileCopy,
      );
    });

    test('uses dual partition for any oversized FAT32 file on Windows', () {
      expect(
        LayoutChooser.strategyFor(
          profile: IsoProfile(
            mountPath: '/mnt',
            kind: IsoKind.windowsX64,
            hasX64Efi: true,
            hasArmEfi: false,
            installKind: WindowsInstallImageKind.wim,
            installImagePath: '/mnt/sources/install.wim',
            installImageSize: 1024,
            hasOversizedFat32File: true,
          ),
          windowsHost: true,
          diskSizeBytes: 64 * 1024 * 1024 * 1024,
        ),
        WriteStrategy.windowsDualPartition,
      );
    });

    test('describes FAT32+NTFS vs split layouts', () {
      final huge = profile(
        IsoKind.windowsX64,
        installSize: fat32MaxFileBytes + 1,
      );
      expect(
        huge.layoutSummary(WriteStrategy.windowsDualPartition),
        'Layout: FAT32+NTFS',
      );
      expect(
        huge.layoutSummary(WriteStrategy.windowsFileCopy),
        'Layout: FAT32, will split WIM',
      );
      expect(
        huge.layoutSummary(WriteStrategy.multiIso),
        'Layout: GRUB menu, FAT32 EFIBOOT + exFAT ISOBOOT',
      );
    });

    test('raw-writes generic UEFI when the ISO looks hybrid', () {
      expect(
        LayoutChooser.strategyFor(
          profile: profile(IsoKind.genericUefi),
          windowsHost: false,
          diskSizeBytes: 8 * 1024 * 1024 * 1024,
          isoLooksHybrid: true,
        ),
        WriteStrategy.rawHybrid,
      );
    });
  });

  group('usbDiskFromLinuxInfo', () {
    test('keeps a USB disk and drops the boot disk', () {
      final usb = usbDiskFromLinuxInfo({
        'name': 'sdb',
        'path': '/dev/sdb',
        'tran': 'usb',
        'type': 'disk',
        'size': 16000000000,
        'rm': true,
        'model': 'SanDisk',
        'mountpoint': '',
      }, bootName: 'sda');
      expect(usb, isNotNull);
      expect(usb!.id, 'sdb');
      expect(usb.isSafeTarget, isTrue);

      expect(
        usbDiskFromLinuxInfo({
          'name': 'sda',
          'tran': 'sata',
          'type': 'disk',
          'size': 512000000000,
          'rm': false,
          'model': 'NVMe',
        }, bootName: 'sda'),
        isNull,
      );
    });

    test('finds the boot disk from a root mount', () {
      expect(
        linuxBootDiskName([
          {
            'name': 'sda',
            'children': [
              {'name': 'sda1', 'mountpoint': '/'},
            ],
          },
        ]),
        'sda',
      );
    });
  });

  group('isoLooksLikeHybridDisk', () {
    test('reads the MBR signature', () {
      final file = File(
        '${Directory.systemTemp.createTempSync('usb_iso_mbr_').path}/disk.iso',
      );
      final bytes = List<int>.filled(512, 0);
      bytes[510] = 0x55;
      bytes[511] = 0xAA;
      file.writeAsBytesSync(bytes);
      addTearDown(() => file.parent.deleteSync(recursive: true));
      expect(isoLooksLikeHybridDisk(file.path), isTrue);
      bytes[511] = 0x00;
      file.writeAsBytesSync(bytes);
      expect(isoLooksLikeHybridDisk(file.path), isFalse);
    });
  });

  group('shouldEmitWritePercent', () {
    test('emits only when the whole percent changes', () {
      expect(
        shouldEmitWritePercent(
          writtenBytes: 0,
          totalBytes: 100,
          lastEmittedPercent: -1,
        ),
        isTrue,
      );
      expect(
        shouldEmitWritePercent(
          writtenBytes: 50,
          totalBytes: 10000,
          lastEmittedPercent: 0,
        ),
        isFalse,
      );
      expect(
        shouldEmitWritePercent(
          writtenBytes: 100,
          totalBytes: 10000,
          lastEmittedPercent: 0,
        ),
        isTrue,
      );
      expect(
        shouldEmitWritePercent(
          writtenBytes: 100,
          totalBytes: 100,
          lastEmittedPercent: 99,
        ),
        isTrue,
      );
    });
  });

  group('macosAuthopenRawWritePython', () {
    test('uses stdoutpipe and 8 MiB blocks', () {
      final script = macosAuthopenRawWritePython();
      expect(script, contains('-stdoutpipe'));
      expect(script, contains('$rawWriteChunkBytes'));
      expect(script, contains('inp.read(chunk_size)'));
    });

    test('is valid Python', () {
      const python = '/usr/bin/python3';
      if (!File(python).existsSync()) {
        return;
      }
      final file = File(
        '${Directory.systemTemp.createTempSync('usb_iso_py_').path}/write.py',
      );
      addTearDown(() => file.parent.deleteSync(recursive: true));
      file.writeAsStringSync(macosAuthopenRawWritePython());
      final compiled = Process.runSync(python, ['-m', 'py_compile', file.path]);
      expect(compiled.exitCode, 0, reason: compiled.stderr.toString());
    });
  });

  group('macosAuthopenFailureMessage', () {
    test('maps cancel and deny to the approval message', () {
      expect(
        macosAuthopenFailureMessage(
          diskId: 'disk70',
          stderr: 'User canceled authorization',
          exitCode: 1,
          writtenBytes: 0,
        ),
        macosAuthopenDeniedMessage,
      );
      expect(
        macosAuthopenFailureMessage(
          diskId: 'disk70',
          stderr: 'open dst: Operation not permitted',
          exitCode: 1,
          writtenBytes: 0,
        ),
        macosAuthopenDeniedMessage,
      );
    });

    test('keeps a mid-write I/O error', () {
      expect(
        macosAuthopenFailureMessage(
          diskId: 'disk70',
          stderr: 'Input/output error',
          exitCode: 1,
          writtenBytes: 1024,
        ),
        'Raw ISO write failed on disk70: Input/output error',
      );
    });
  });

  group('windowsRawWritePowerShell', () {
    test('takes the disk offline before writing PhysicalDrive', () {
      final script = windowsRawWritePowerShell(
        diskNumber: 2,
        isoPath: r'C:\iso\ubuntu.iso',
        progressPath: r'C:\tmp\progress',
        cancelPath: r'C:\tmp\cancel',
      );
      expect(
        script,
        contains(r'Set-Disk -Number $diskNumber -IsOffline $true'),
      );
      expect(
        script,
        contains(r'Set-Disk -Number $diskNumber -IsOffline $false'),
      );
      expect(script, contains(r'\\.\PhysicalDrive$diskNumber'));
      expect(script, contains('8MB'));
    });
  });

  group('WindowsPrivilege', () {
    test('is a no-op off Windows', () async {
      await WindowsPrivilege.ensureAdministrator(
        isWindows: false,
        probe: () async => false,
      );
    });

    test('refuses an unelevated Windows process', () async {
      expect(
        () => WindowsPrivilege.ensureAdministrator(
          isWindows: true,
          probe: () async => false,
        ),
        throwsA(
          isA<UsbIsoException>().having(
            (e) => e.message,
            'message',
            WindowsPrivilege.adminRequiredMessage,
          ),
        ),
      );
    });

    test('allows an elevated Windows process', () async {
      await WindowsPrivilege.ensureAdministrator(
        isWindows: true,
        probe: () async => true,
      );
    });
  });

  group('dryRunStrategyNotes', () {
    final huge = IsoProfile(
      mountPath: '/mnt',
      kind: IsoKind.windowsX64,
      hasX64Efi: true,
      hasArmEfi: false,
      installKind: WindowsInstallImageKind.wim,
      installImagePath: '/mnt/sources/install.wim',
      installImageSize: fat32MaxFileBytes + 1,
    );

    test('describes FAT32+NTFS as the Windows Win11 path', () {
      expect(
        dryRunStrategyNotes(
          strategy: WriteStrategy.windowsDualPartition,
          profile: huge,
          windowsHost: true,
        ),
        contains('FAT32 WINBOOT + NTFS WINSETUP'),
      );
    });

    test('calls DISM split a fallback on Windows', () {
      expect(
        dryRunStrategyNotes(
          strategy: WriteStrategy.windowsFileCopy,
          profile: huge,
          windowsHost: true,
          splitTool: r'C:\Windows\System32\Dism.exe',
        ),
        contains('DISM split is fallback only'),
      );
    });
  });

  group('VolumeFilesystem', () {
    test('parses common names', () {
      expect(parseVolumeFilesystem('FAT32'), VolumeFilesystem.fat32);
      expect(parseVolumeFilesystem('ex-fat'), VolumeFilesystem.exfat);
      expect(parseVolumeFilesystem('NTFS'), VolumeFilesystem.ntfs);
    });

    test('rejects unknown names', () {
      expect(
        () => parseVolumeFilesystem('ext4'),
        throwsA(isA<UsbIsoException>()),
      );
    });

    test('sanitizes and truncates labels', () {
      expect(sanitizeVolumeLabel(' photos ', VolumeFilesystem.fat32), 'PHOTOS');
      expect(
        sanitizeVolumeLabel(
          'this-is-a-very-long-label',
          VolumeFilesystem.fat32,
        ),
        'THIS-IS-A-V',
      );
      expect(
        sanitizeVolumeLabel('bad:name*', VolumeFilesystem.exfat),
        'badname',
      );
      expect(sanitizeVolumeLabel('   ', VolumeFilesystem.ntfs), 'USB');
    });

    test('NTFS is unsupported on macOS', () {
      expect(VolumeFilesystem.ntfs.isSupportedOn('macos'), isFalse);
      expect(VolumeFilesystem.exfat.isSupportedOn('macos'), isTrue);
      expect(VolumeFilesystem.ntfs.isSupportedOn('windows'), isTrue);
    });
  });

  group('DiskFormatter', () {
    test('refuses to format without confirmation', () async {
      final host = FakeHost(
        mount: const IsoMount(isoPath: '/iso', mountPath: '/mnt'),
      );
      expect(
        () => DiskFormatter(
          host: host,
        ).format(FormatRequest(disk: _usb())).toList(),
        throwsA(isA<ConfirmationRequiredException>()),
      );
      expect(host.formatCalls, 0);
    });

    test('dry-run does not erase the disk', () async {
      final host = FakeHost(
        mount: const IsoMount(isoPath: '/iso', mountPath: '/mnt'),
      );
      final events = await DiskFormatter(host: host)
          .format(
            FormatRequest(
              disk: _usb(),
              filesystem: VolumeFilesystem.exfat,
              volumeLabel: 'Photos',
              dryRun: true,
            ),
          )
          .toList();
      expect(host.formatCalls, 0);
      expect(events.last.step, WriteStep.done);
      expect(events.last.message, contains('Filesystem: exFAT'));
      expect(events.last.message, contains('Label: Photos'));
    });

    test('formats after confirmation', () async {
      final host = FakeHost(
        mount: const IsoMount(isoPath: '/iso', mountPath: '/mnt'),
      );
      final events = await DiskFormatter(host: host)
          .format(
            FormatRequest(
              disk: _usb(),
              filesystem: VolumeFilesystem.exfat,
              volumeLabel: 'photos',
              confirmed: true,
            ),
          )
          .toList();
      expect(host.formatCalls, 1);
      expect(host.lastFormatFilesystem, VolumeFilesystem.exfat);
      expect(host.lastFormatLabel, 'photos');
      expect(events.last.step, WriteStep.done);
      expect(events.last.message, contains('exFAT'));
    });

    test('uppercases a FAT32 volume label', () async {
      final host = FakeHost(
        mount: const IsoMount(isoPath: '/iso', mountPath: '/mnt'),
      );
      await DiskFormatter(host: host)
          .format(
            FormatRequest(
              disk: _usb(),
              filesystem: VolumeFilesystem.fat32,
              volumeLabel: 'photos',
              confirmed: true,
            ),
          )
          .toList();
      expect(host.lastFormatLabel, 'PHOTOS');
    });

    test('rejects an internal disk', () async {
      final host = FakeHost(
        mount: const IsoMount(isoPath: '/iso', mountPath: '/mnt'),
      );
      expect(
        () => DiskFormatter(host: host)
            .format(
              FormatRequest(
                disk: _usb(isInternal: true, bus: 'SATA'),
                confirmed: true,
              ),
            )
            .toList(),
        throwsA(isA<UnsafeDiskException>()),
      );
      expect(host.formatCalls, 0);
    });

    test('mentions the Windows FAT32 size cap in dry-run', () {
      expect(
        dryRunFormatSummary(
          disk: _usb(),
          filesystem: VolumeFilesystem.fat32,
          volumeLabel: 'USB',
          windowsHost: true,
        ),
        contains('Windows FAT32 is limited'),
      );
    });
  });

  group('linuxPartitionDevice', () {
    test('adds a partition suffix for scsi and nvme names', () {
      expect(linuxPartitionDevice('/dev/sda', 1), '/dev/sda1');
      expect(linuxPartitionDevice('/dev/nvme0n1', 2), '/dev/nvme0n1p2');
    });
  });

  group('multiboot host scripts', () {
    test('macOS diskutil args create EFI + ExFAT', () {
      expect(macosEfiPlusExfatArgs('disk4'), [
        'partitionDisk',
        'disk4',
        'GPT',
        'EFI',
        'EFIBOOT',
        '512M',
        'ExFAT',
        'ISOBOOT',
        'R',
      ]);
    });

    test('Windows script marks an ESP and formats exFAT', () {
      final script = windowsEfiPlusExfatPowerShell(
        diskNumber: 2,
        busGuard:
            r"if ([string]$disk.BusType -ne 'USB') { throw 'Not a USB disk' }",
      );
      expect(script, contains('{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'));
      expect(script, contains('EFIBOOT'));
      expect(script, contains('ISOBOOT'));
      expect(script, contains('exFAT'));
    });

    test('Linux parted args mark the ESP', () {
      final args = linuxEfiPlusExfatPartedArgs('/dev/sdb');
      expect(args, contains('esp'));
      expect(args, contains('ISOBOOT'));
    });
  });

  group('LinuxBootFiles', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('usb_iso_linuxboot_');
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('finds Ubuntu casper kernel and initrd', () {
      _writeLinuxLayout(temp);
      File(p.join(temp.path, 'casper', 'initrd')).writeAsBytesSync([9]);
      final boot = probeLinuxBootFromTree(temp.path);
      expect(boot, isNotNull);
      expect(boot!.kind, LinuxLiveKind.casper);
      expect(boot.kernelPath, 'casper/vmlinuz');
      expect(boot.initrdPath, 'casper/initrd');
      expect(
        boot.kernelArguments('/isos/ubuntu.iso'),
        contains('iso-scan/filename=/isos/ubuntu.iso'),
      );
    });
  });

  group('ISO 9660 path find/extract', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('usb_iso_iso9660_');
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('finds a nested file and extracts it', () {
      final iso = File(p.join(temp.path, 'nested.iso'));
      iso.writeAsBytesSync(
        _isoWithFiles({
          'casper/vmlinuz': [1, 2, 3, 4],
          'efi/boot/bootx64.efi': [5, 6, 7],
        }),
      );
      final kernel = findIso9660Path(iso.path, 'casper/vmlinuz');
      expect(kernel, isNotNull);
      expect(kernel!.isDirectory, isFalse);
      final dest = p.join(temp.path, 'vmlinuz');
      extractIso9660File(isoPath: iso.path, entry: kernel, destination: dest);
      expect(File(dest).readAsBytesSync(), [1, 2, 3, 4]);
      expect(findIso9660Path(iso.path, 'efi/boot/bootx64.efi'), isNotNull);
    });

    test('probes casper boot files from an ISO', () {
      final iso = File(p.join(temp.path, 'ubuntu.iso'));
      iso.writeAsBytesSync(
        _isoWithFiles({
          'casper/vmlinuz': [1],
          'casper/initrd': [2],
        }),
      );
      final boot = probeLinuxBootFromIso(iso.path);
      expect(boot?.kernelPath, 'casper/vmlinuz');
      expect(boot?.initrdPath, 'casper/initrd');
    });
  });

  group('MultiIsoPlan', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('usb_iso_plan_');
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('rejects a single ISO', () {
      final iso = File(p.join(temp.path, 'a.iso'))..writeAsBytesSync([1]);
      expect(
        () => planMultiboot(
          drafts: [
            MultiIsoDraft(
              isoPath: iso.path,
              profile: _linuxProfile(temp.path),
              linuxBoot: const LinuxBootFiles(
                kernelPath: 'casper/vmlinuz',
                initrdPath: 'casper/initrd',
                kind: LinuxLiveKind.casper,
              ),
            ),
          ],
          diskSizeBytes: 64 * 1024 * 1024 * 1024,
        ),
        throwsA(isA<InvalidIsoException>()),
      );
    });

    test('rejects two Windows installers', () {
      final a = File(p.join(temp.path, 'win1.iso'))..writeAsBytesSync([1]);
      final b = File(p.join(temp.path, 'win2.iso'))..writeAsBytesSync([1]);
      final win = Directory(p.join(temp.path, 'win'))..createSync();
      _writeWindowsLayout(win, wimBytes: 8);
      expect(
        () => planMultiboot(
          drafts: [
            MultiIsoDraft(
              isoPath: a.path,
              profile: IsoInspector().inspectMounted(win.path),
              mountPath: win.path,
            ),
            MultiIsoDraft(
              isoPath: b.path,
              profile: IsoInspector().inspectMounted(win.path),
              mountPath: win.path,
            ),
          ],
          diskSizeBytes: 64 * 1024 * 1024 * 1024,
        ),
        throwsA(
          isA<InvalidIsoException>().having(
            (e) => e.message,
            'message',
            contains('Only one Windows installer'),
          ),
        ),
      );
    });

    test('accepts Windows plus Ubuntu and builds a GRUB menu', () {
      final winIso = File(p.join(temp.path, 'Win11.iso'))
        ..writeAsBytesSync(List<int>.filled(2048, 1));
      final linuxIso = File(p.join(temp.path, 'ubuntu.iso'))
        ..writeAsBytesSync(List<int>.filled(2048, 2));
      final win = Directory(p.join(temp.path, 'win'))..createSync();
      _writeWindowsLayout(win, wimBytes: 8);
      File(p.join(win.path, 'sources', 'boot.wim')).writeAsBytesSync([1]);
      final linux = Directory(p.join(temp.path, 'linux'))..createSync();
      _writeLinuxLayout(linux);
      File(p.join(linux.path, 'casper', 'initrd')).writeAsBytesSync([9]);
      final plan = planMultiboot(
        drafts: [
          MultiIsoDraft(
            isoPath: winIso.path,
            profile: IsoInspector().inspectMounted(win.path),
            mountPath: win.path,
          ),
          MultiIsoDraft(
            isoPath: linuxIso.path,
            profile: IsoInspector().inspectMounted(linux.path),
            linuxBoot: probeLinuxBootFromTree(linux.path),
            mountPath: linux.path,
          ),
        ],
        diskSizeBytes: 64 * 1024 * 1024 * 1024,
      );
      expect(plan.windows, isNotNull);
      expect(plan.linux, hasLength(1));
      final cfg = buildGrubConfig(plan);
      expect(cfg, contains('chainloader /efi/boot/bootx64.efi'));
      expect(cfg, contains('/Sources/boot.wim'));
      expect(cfg, contains('/EFI/BOOT/BOOTX64.EFI'));
      expect(
        cfg,
        contains(
          'if search --file --no-floppy --set=root /sources/boot.wim; then',
        ),
      );
      expect(cfg, contains('/isos/ubuntu.iso'));
      expect(cfg, contains('iso-scan/filename=/isos/ubuntu.iso'));
      expect(cfg, contains('loopback loop'));
    });

    test(
      'accepts a Linux ISO classified as unknown when boot files are found',
      () {
        final winIso = File(p.join(temp.path, 'Win11.iso'))
          ..writeAsBytesSync(List<int>.filled(2048, 1));
        final linuxIso = File(p.join(temp.path, 'mystery.iso'))
          ..writeAsBytesSync(List<int>.filled(2048, 2));
        final win = Directory(p.join(temp.path, 'win'))..createSync();
        _writeWindowsLayout(win, wimBytes: 8);
        File(p.join(win.path, 'sources', 'boot.wim')).writeAsBytesSync([1]);
        final plan = planMultiboot(
          drafts: [
            MultiIsoDraft(
              isoPath: winIso.path,
              profile: IsoInspector().inspectMounted(win.path),
              mountPath: win.path,
            ),
            MultiIsoDraft(
              isoPath: linuxIso.path,
              profile: const IsoProfile(
                mountPath: '',
                kind: IsoKind.unknown,
                hasX64Efi: false,
                hasArmEfi: false,
                installKind: WindowsInstallImageKind.none,
                installImagePath: null,
                installImageSize: 0,
              ),
              linuxBoot: const LinuxBootFiles(
                kernelPath: 'casper/vmlinuz',
                initrdPath: 'casper/initrd',
                kind: LinuxLiveKind.casper,
              ),
            ),
          ],
          diskSizeBytes: 64 * 1024 * 1024 * 1024,
        );
        expect(plan.linux, hasLength(1));
      },
    );

    test('detects mounted EFIBOOT + ISOBOOT volumes', () {
      final temp = Directory.systemTemp.createTempSync('usb_iso_detect_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      final esp = Directory(p.join(temp.path, 'esp'))..createSync();
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      _writeMultibootStick(esp: esp, data: data);
      final volumes = detectMultibootMounts([esp.path, data.path]);
      expect(volumes, isNotNull);
      expect(volumes!.bootMount, esp.path);
      expect(volumes.dataMount, data.path);
      expect(planFromMultibootVolume(data.path).windows, isNotNull);
      expect(looksLikeMultibootDisk([data.path]), isTrue);
      expect(looksLikeMultibootDisk([esp.path]), isTrue);
    });

    test('records /isos files that cannot be probed as live images', () {
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      Directory(p.join(data.path, 'isos')).createSync(recursive: true);
      File(p.join(data.path, 'isos', 'notes.iso')).writeAsBytesSync([1, 2, 3]);
      File(p.join(data.path, 'sources', 'boot.wim'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      final plan = planFromMultibootVolume(data.path);
      expect(plan.windows, isNotNull);
      expect(plan.skippedIsoFileNames, contains('notes.iso'));
    });

    test('looksLikeMultibootDisk is true when only /isos is mounted', () {
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      Directory(p.join(data.path, 'isos')).createSync();
      expect(detectMultibootMounts([data.path]), isNull);
      expect(looksLikeMultibootDisk([data.path]), isTrue);
      expect(looksLikeMultibootDisk(['/Volumes/WINSETUP']), isFalse);
    });

    test('refuses an add that will not fit on the stick', () {
      final temp = Directory.systemTemp.createTempSync('usb_iso_space_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      Directory(p.join(data.path, 'isos')).createSync();
      File(
        p.join(data.path, 'isos', 'ubuntu.iso'),
      ).writeAsBytesSync(List<int>.filled(8 * 1024 * 1024, 1));
      expect(volumeUsedBytes(data.path), greaterThan(0));
      expect(
        () => ensureMultibootAddFits(
          diskSizeBytes: efiSystemPartitionBytes + 10 * 1024 * 1024,
          dataMount: data.path,
          incomingBytes: 4 * 1024 * 1024,
        ),
        throwsA(
          isA<UsbIsoException>().having(
            (e) => e.message,
            'message',
            contains('enough free space'),
          ),
        ),
      );
      expect(
        () => ensureMultibootAddFits(
          diskSizeBytes: 64 * 1024 * 1024 * 1024,
          dataMount: data.path,
          incomingBytes: 4 * 1024 * 1024,
        ),
        returnsNormally,
      );
    });
  });

  group('BootableWriter.writeMulti', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('usb_iso_multi_');
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('dry-run does not erase', () async {
      final winIso = File(p.join(temp.path, 'Win11.iso'))
        ..writeAsBytesSync(List<int>.filled(2048, 1));
      final linuxIso = File(p.join(temp.path, 'ubuntu.iso'))
        ..writeAsBytesSync(List<int>.filled(2048, 2));
      final win = Directory(p.join(temp.path, 'win'))..createSync();
      _writeWindowsLayout(win, wimBytes: 8);
      File(p.join(win.path, 'sources', 'boot.wim')).writeAsBytesSync([1]);
      final linux = Directory(p.join(temp.path, 'linux'))..createSync();
      _writeLinuxLayout(linux);
      File(p.join(linux.path, 'casper', 'initrd')).writeAsBytesSync([9]);
      final host = FakeHost(
        mount: IsoMount(isoPath: winIso.path, mountPath: win.path),
        mounts: {
          winIso.path: IsoMount(isoPath: winIso.path, mountPath: win.path),
          linuxIso.path: IsoMount(
            isoPath: linuxIso.path,
            mountPath: linux.path,
          ),
        },
      );
      final events = await BootableWriter(host: host)
          .writeMulti(
            MultiWriteRequest(
              isoPaths: [winIso.path, linuxIso.path],
              disk: _usb(),
              dryRun: true,
            ),
          )
          .toList();
      expect(host.eraseCalls, 0);
      expect(events.last.message, contains('multiIso'));
      expect(events.last.message, contains('GRUB'));
    });

    test('writes GRUB, the Linux ISO, and Windows Setup files', () async {
      final winIso = File(p.join(temp.path, 'Win11.iso'))
        ..writeAsBytesSync(List<int>.filled(2048, 1));
      final linuxIso = File(p.join(temp.path, 'ubuntu.iso'))
        ..writeAsBytesSync(List<int>.filled(2048, 2));
      final win = Directory(p.join(temp.path, 'win'))..createSync();
      _writeWindowsLayout(win, wimBytes: 8);
      File(p.join(win.path, 'sources', 'boot.wim')).writeAsBytesSync([1]);
      final linux = Directory(p.join(temp.path, 'linux'))..createSync();
      _writeLinuxLayout(linux);
      File(p.join(linux.path, 'casper', 'initrd')).writeAsBytesSync([9]);
      final dest = Directory(p.join(temp.path, 'dest'))..createSync();
      final host = FakeHost(
        mount: IsoMount(isoPath: winIso.path, mountPath: win.path),
        mounts: {
          winIso.path: IsoMount(isoPath: winIso.path, mountPath: win.path),
          linuxIso.path: IsoMount(
            isoPath: linuxIso.path,
            mountPath: linux.path,
          ),
        },
      )..destination = dest;
      final events = await BootableWriter(host: host)
          .writeMulti(
            MultiWriteRequest(
              isoPaths: [winIso.path, linuxIso.path],
              disk: _usb(),
              confirmed: true,
            ),
          )
          .toList();
      expect(host.eraseCalls, 1);
      expect(host.lastEraseLayout, DiskLayout.efiPlusExfat);
      expect(events.last.step, WriteStep.done);
      expect(
        File(p.join(dest.path, 'EFI', 'BOOT', 'BOOTX64.EFI')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(dest.path, 'boot', 'grub', 'grub.cfg')).readAsStringSync(),
        contains('menuentry'),
      );
      final data = Directory('${dest.path}_data');
      expect(
        File(p.join(data.path, 'isos', 'ubuntu.iso')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(data.path, 'sources', 'install.wim')).existsSync(),
        isTrue,
      );
    });

    test('adds a Linux ISO to an existing stick without erasing', () async {
      final dest = Directory(p.join(temp.path, 'esp'))..createSync();
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      _writeMultibootStick(esp: dest, data: data);
      final extra = File(p.join(temp.path, 'fedora.iso'))
        ..writeAsBytesSync(
          _isoWithFiles({
            'casper/vmlinuz': [1],
            'casper/initrd': [2],
          }),
        );
      final linux = Directory(p.join(temp.path, 'linux'))..createSync();
      _writeLinuxLayout(linux);
      File(p.join(linux.path, 'casper', 'initrd')).writeAsBytesSync([9]);
      final host = FakeHost(
        mount: IsoMount(isoPath: extra.path, mountPath: linux.path),
      );
      final disk = _usb().copyWith(mountPoints: [dest.path, data.path]);
      final events = await BootableWriter(host: host)
          .addIso(
            MultiAddRequest(isoPath: extra.path, disk: disk, confirmed: true),
          )
          .toList();
      expect(host.eraseCalls, 0);
      expect(events.last.step, WriteStep.done);
      expect(
        File(p.join(data.path, 'isos', 'fedora.iso')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(dest.path, 'boot', 'grub', 'grub.cfg')).readAsStringSync(),
        contains('fedora.iso'),
      );
    });

    test('refresh rebuilds GRUB from files already on the USB', () async {
      final dest = Directory(p.join(temp.path, 'esp'))..createSync();
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      _writeMultibootStick(esp: dest, data: data);
      File(p.join(data.path, 'isos', 'mint.iso')).writeAsBytesSync(
        _isoWithFiles({
          'casper/vmlinuz': [3],
          'casper/initrd': [4],
        }),
      );
      final host = FakeHost(
        mount: const IsoMount(isoPath: '/iso', mountPath: '/mnt'),
      );
      final disk = _usb().copyWith(mountPoints: [dest.path, data.path]);
      await BootableWriter(
        host: host,
      ).refreshMenu(MultiRefreshRequest(disk: disk)).toList();
      expect(host.eraseCalls, 0);
      expect(
        File(p.join(dest.path, 'boot', 'grub', 'grub.cfg')).readAsStringSync(),
        contains('mint.iso'),
      );
    });

    test('add refuses when the USB is too small', () async {
      final dest = Directory(p.join(temp.path, 'esp'))..createSync();
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      _writeMultibootStick(esp: dest, data: data);
      final extra = File(p.join(temp.path, 'fedora.iso'))
        ..writeAsBytesSync(
          _isoWithFiles({
            'casper/vmlinuz': [1],
            'casper/initrd': [2],
          }),
        );
      final linux = Directory(p.join(temp.path, 'linux'))..createSync();
      _writeLinuxLayout(linux);
      File(p.join(linux.path, 'casper', 'initrd')).writeAsBytesSync([9]);
      final host = FakeHost(
        mount: IsoMount(isoPath: extra.path, mountPath: linux.path),
      );
      final disk = UsbDisk(
        id: 'disk70',
        devicePath: '/dev/disk70',
        name: 'Tiny',
        sizeBytes: efiSystemPartitionBytes + 8 * 1024 * 1024,
        busProtocol: 'USB',
        isRemovable: true,
        isInternal: false,
        isBoot: false,
        isVirtual: false,
        mountPoints: [dest.path, data.path],
      );
      expect(
        () => BootableWriter(host: host)
            .addIso(
              MultiAddRequest(isoPath: extra.path, disk: disk, dryRun: true),
            )
            .toList(),
        throwsA(
          isA<UsbIsoException>().having(
            (e) => e.message,
            'message',
            contains('enough free space'),
          ),
        ),
      );
      expect(host.eraseCalls, 0);
    });

    test('add respects cancellation before copying', () async {
      final dest = Directory(p.join(temp.path, 'esp'))..createSync();
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      _writeMultibootStick(esp: dest, data: data);
      final extra = File(p.join(temp.path, 'fedora.iso'))
        ..writeAsBytesSync(
          _isoWithFiles({
            'casper/vmlinuz': [1],
            'casper/initrd': [2],
          }),
        );
      final host = FakeHost(
        mount: IsoMount(isoPath: extra.path, mountPath: extra.path),
      );
      final disk = _usb().copyWith(mountPoints: [dest.path, data.path]);
      final token = CancellationToken()..cancel();
      expect(
        () => BootableWriter(host: host)
            .addIso(
              MultiAddRequest(
                isoPath: extra.path,
                disk: disk,
                confirmed: true,
                cancellation: token,
              ),
            )
            .toList(),
        throwsA(isA<WriteCancelledException>()),
      );
      expect(
        File(p.join(data.path, 'isos', 'fedora.iso')).existsSync(),
        isFalse,
      );
    });

    test('refresh refuses a stick with no menu entries', () async {
      final dest = Directory(p.join(temp.path, 'esp'))..createSync();
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      Directory(p.join(dest.path, 'boot', 'grub')).createSync(recursive: true);
      File(
        p.join(dest.path, 'boot', 'grub', 'grub.cfg'),
      ).writeAsStringSync('menuentry "empty" { reboot }\n');
      Directory(p.join(data.path, 'isos')).createSync(recursive: true);
      final host = FakeHost(
        mount: const IsoMount(isoPath: '/iso', mountPath: '/mnt'),
      );
      final disk = _usb().copyWith(mountPoints: [dest.path, data.path]);
      expect(
        () => BootableWriter(
          host: host,
        ).refreshMenu(MultiRefreshRequest(disk: disk, dryRun: true)).toList(),
        throwsA(
          isA<UsbIsoException>().having(
            (e) => e.message,
            'message',
            contains('No Windows Setup or Linux live ISOs'),
          ),
        ),
      );
    });

    test('add refuses a second Windows installer', () async {
      final dest = Directory(p.join(temp.path, 'esp'))..createSync();
      final data = Directory(p.join(temp.path, 'data'))..createSync();
      _writeMultibootStick(esp: dest, data: data);
      final winIso = File(p.join(temp.path, 'Win11.iso'))
        ..writeAsBytesSync([1]);
      final win = Directory(p.join(temp.path, 'win'))..createSync();
      _writeWindowsLayout(win, wimBytes: 8);
      final host = FakeHost(
        mount: IsoMount(isoPath: winIso.path, mountPath: win.path),
      );
      final disk = _usb().copyWith(mountPoints: [dest.path, data.path]);
      expect(
        () => BootableWriter(host: host)
            .addIso(
              MultiAddRequest(isoPath: winIso.path, disk: disk, dryRun: true),
            )
            .toList(),
        throwsA(
          isA<InvalidIsoException>().having(
            (e) => e.message,
            'message',
            contains('already has a Windows installer'),
          ),
        ),
      );
      expect(host.eraseCalls, 0);
    });

    test('refuses two Windows ISOs without erasing', () async {
      final a = File(p.join(temp.path, 'a.iso'))..writeAsBytesSync([1]);
      final b = File(p.join(temp.path, 'b.iso'))..writeAsBytesSync([1]);
      final win = Directory(p.join(temp.path, 'win'))..createSync();
      _writeWindowsLayout(win, wimBytes: 8);
      final host = FakeHost(
        mount: IsoMount(isoPath: a.path, mountPath: win.path),
        mounts: {
          a.path: IsoMount(isoPath: a.path, mountPath: win.path),
          b.path: IsoMount(isoPath: b.path, mountPath: win.path),
        },
      );
      expect(
        () => BootableWriter(host: host)
            .writeMulti(
              MultiWriteRequest(
                isoPaths: [a.path, b.path],
                disk: _usb(),
                dryRun: true,
              ),
            )
            .toList(),
        throwsA(isA<InvalidIsoException>()),
      );
      expect(host.eraseCalls, 0);
    });
  });
}

class FakeHost implements HostPlatform {
  FakeHost({required this.mount, this.mounts});

  final IsoMount mount;
  final Map<String, IsoMount>? mounts;
  int mountCalls = 0;
  int unmountCalls = 0;
  int eraseCalls = 0;
  int formatCalls = 0;
  int rawWriteCalls = 0;
  Directory? destination;
  String? ejectError;
  VolumeFilesystem? lastFormatFilesystem;
  String? lastFormatLabel;
  DiskLayout? lastEraseLayout;

  @override
  Future<List<UsbDisk>> listUsbDisks({bool includeAdvanced = false}) async =>
      const [];

  @override
  Future<void> verifyWritable(
    UsbDisk disk, {
    bool allowAdvancedTargets = false,
  }) async {}

  @override
  Future<IsoMount> mountIso(String isoPath) async {
    mountCalls++;
    final specific = mounts?[isoPath];
    if (specific != null) {
      return specific;
    }
    return mount;
  }

  @override
  Future<void> unmountIso(IsoMount mount) async {
    unmountCalls++;
  }

  @override
  Future<void> eraseAndFormat(
    UsbDisk disk, {
    DiskLayout layout = DiskLayout.fat32,
  }) async {
    eraseCalls++;
    lastEraseLayout = layout;
  }

  @override
  Future<void> formatDataVolume(
    UsbDisk disk, {
    required VolumeFilesystem filesystem,
    String volumeLabel = defaultVolumeLabel,
    bool allowAdvancedTargets = false,
  }) async {
    formatCalls++;
    lastFormatFilesystem = filesystem;
    lastFormatLabel = volumeLabel;
  }

  @override
  Future<PreparedVolumes> waitForVolumeMount(
    UsbDisk disk, {
    DiskLayout layout = DiskLayout.fat32,
  }) async {
    final dir = destination ?? Directory.systemTemp.createTempSync('usb_dest_');
    dir.createSync(recursive: true);
    Directory? data;
    if (isDualVolumeLayout(layout)) {
      data = Directory('${dir.path}_data')..createSync(recursive: true);
    }
    return PreparedVolumes(bootMount: dir.path, dataMount: data?.path);
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

  @override
  Future<void> writeRawImage({
    required UsbDisk disk,
    required String isoPath,
    RawWriteProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    rawWriteCalls++;
    final total = File(isoPath).lengthSync();
    onProgress?.call(total, total);
    cancellation?.throwIfCancelled(diskAlreadyErased: true);
  }

  @override
  Future<void> flushDisk(UsbDisk disk) async {}
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

void _writeLinuxLayout(Directory root) {
  Directory(p.join(root.path, 'efi', 'boot')).createSync(recursive: true);
  File(p.join(root.path, 'efi', 'boot', 'bootx64.efi')).writeAsBytesSync([1]);
  Directory(p.join(root.path, 'casper')).createSync();
  File(p.join(root.path, 'casper', 'vmlinuz')).writeAsBytesSync([1, 2, 3]);
}

/// Tiny ISO 9660 image with a hybrid MBR, volume id, and a `CASPER` directory.
List<int> _minimalLinuxIso() {
  const sector = 2048;
  final bytes = List<int>.filled(21 * sector, 0);
  bytes[510] = 0x55;
  bytes[511] = 0xAA;
  final pvd = 16 * sector;
  bytes[pvd] = 1;
  final id = 'CD001'.codeUnits;
  for (var i = 0; i < id.length; i++) {
    bytes[pvd + 1 + i] = id[i];
  }
  final volume = 'Ubuntu 26.04 amd64'.padRight(32).codeUnits;
  for (var i = 0; i < volume.length; i++) {
    bytes[pvd + 40 + i] = volume[i];
  }
  const rootLba = 20;
  bytes[pvd + 156] = 34;
  bytes[pvd + 158] = rootLba;
  bytes[pvd + 166] = 0x00;
  bytes[pvd + 167] = 0x08;
  final dir = rootLba * sector;
  const name = 'CASPER';
  const recordLen = 40;
  bytes[dir] = recordLen;
  bytes[dir + 25] = 2;
  bytes[dir + 32] = name.length;
  for (var i = 0; i < name.length; i++) {
    bytes[dir + 33 + i] = name.codeUnitAt(i);
  }
  return bytes;
}

void _writeMultibootStick({required Directory esp, required Directory data}) {
  Directory(p.join(esp.path, 'EFI', 'BOOT')).createSync(recursive: true);
  File(p.join(esp.path, 'EFI', 'BOOT', 'BOOTX64.EFI')).writeAsBytesSync([1, 2]);
  Directory(p.join(esp.path, 'boot', 'grub')).createSync(recursive: true);
  File(
    p.join(esp.path, 'boot', 'grub', 'grub.cfg'),
  ).writeAsStringSync('menuentry "placeholder" { reboot }\n');
  Directory(p.join(data.path, 'isos')).createSync(recursive: true);
  Directory(p.join(data.path, 'sources')).createSync(recursive: true);
  Directory(p.join(data.path, 'efi', 'boot')).createSync(recursive: true);
  File(p.join(data.path, 'sources', 'boot.wim')).writeAsBytesSync([1]);
  File(p.join(data.path, 'sources', 'install.wim')).writeAsBytesSync([1]);
  File(p.join(data.path, 'efi', 'boot', 'bootx64.efi')).writeAsBytesSync([1]);
}

IsoProfile _linuxProfile(String mountPath) {
  return IsoProfile(
    mountPath: mountPath,
    kind: IsoKind.linuxHybrid,
    hasX64Efi: true,
    hasArmEfi: false,
    installKind: WindowsInstallImageKind.none,
    installImagePath: null,
    installImageSize: 0,
    linuxMarkers: const ['casper'],
  );
}

/// Minimal ISO 9660 image containing the given files (no Joliet).
List<int> _isoWithFiles(Map<String, List<int>> files) {
  const sector = 2048;
  final dirs = <String>{''};
  for (final path in files.keys) {
    final parts = path.toLowerCase().split('/');
    var prefix = '';
    for (var i = 0; i < parts.length - 1; i++) {
      prefix = prefix.isEmpty ? parts[i] : '$prefix/${parts[i]}';
      dirs.add(prefix);
    }
  }
  final dirList = dirs.toList()..sort();
  final dirLba = <String, int>{};
  var nextLba = 20;
  for (final dir in dirList) {
    dirLba[dir] = nextLba;
    nextLba++;
  }
  final fileLba = <String, int>{};
  final fileSize = <String, int>{};
  for (final entry in files.entries) {
    fileLba[entry.key.toLowerCase()] = nextLba;
    fileSize[entry.key.toLowerCase()] = entry.value.length;
    nextLba += (entry.value.length + sector - 1) ~/ sector;
    if (nextLba == fileLba[entry.key.toLowerCase()]) {
      nextLba++;
    }
  }

  final bytes = List<int>.filled(nextLba * sector, 0);
  bytes[510] = 0x55;
  bytes[511] = 0xAA;
  final pvd = 16 * sector;
  bytes[pvd] = 1;
  final id = 'CD001'.codeUnits;
  for (var i = 0; i < id.length; i++) {
    bytes[pvd + 1 + i] = id[i];
  }
  final volume = 'TESTISO'.padRight(32).codeUnits;
  for (var i = 0; i < volume.length; i++) {
    bytes[pvd + 40 + i] = volume[i];
  }
  bytes[pvd + 156] = 34;
  bytes[pvd + 158] = dirLba['']!;
  bytes[pvd + 166] = 0x00;
  bytes[pvd + 167] = 0x08;

  List<int> recordFor({
    required String name,
    required int lba,
    required int size,
    required bool directory,
  }) {
    final upper = name.toUpperCase();
    var length = 33 + upper.length;
    if (length.isOdd) {
      length++;
    }
    final record = List<int>.filled(length, 0);
    record[0] = length;
    record[2] = lba & 0xff;
    record[3] = (lba >> 8) & 0xff;
    record[4] = (lba >> 16) & 0xff;
    record[5] = (lba >> 24) & 0xff;
    record[10] = size & 0xff;
    record[11] = (size >> 8) & 0xff;
    record[12] = (size >> 16) & 0xff;
    record[13] = (size >> 24) & 0xff;
    if (directory) {
      record[25] = 2;
    }
    record[32] = upper.length;
    for (var i = 0; i < upper.length; i++) {
      record[33 + i] = upper.codeUnitAt(i);
    }
    return record;
  }

  for (final dir in dirList) {
    final children = <List<int>>[];
    for (final other in dirList) {
      if (other == dir) {
        continue;
      }
      final parent = other.contains('/')
          ? other.substring(0, other.lastIndexOf('/'))
          : '';
      if (parent != dir) {
        continue;
      }
      final name = other.contains('/')
          ? other.substring(other.lastIndexOf('/') + 1)
          : other;
      children.add(
        recordFor(
          name: name,
          lba: dirLba[other]!,
          size: sector,
          directory: true,
        ),
      );
    }
    for (final file in files.keys) {
      final key = file.toLowerCase();
      final parent = key.contains('/')
          ? key.substring(0, key.lastIndexOf('/'))
          : '';
      if (parent != dir) {
        continue;
      }
      final name = key.contains('/')
          ? key.substring(key.lastIndexOf('/') + 1)
          : key;
      children.add(
        recordFor(
          name: name,
          lba: fileLba[key]!,
          size: fileSize[key]!,
          directory: false,
        ),
      );
    }
    var offset = dirLba[dir]! * sector;
    for (final record in children) {
      bytes.setRange(offset, offset + record.length, record);
      offset += record.length;
    }
  }

  for (final entry in files.entries) {
    final key = entry.key.toLowerCase();
    final start = fileLba[key]! * sector;
    bytes.setRange(start, start + entry.value.length, entry.value);
  }
  return bytes;
}
