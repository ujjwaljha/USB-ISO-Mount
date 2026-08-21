/// Shared logic for listing USB disks, mounting Windows ISOs, and writing
/// UEFI-bootable installer sticks on macOS and Windows.
library;

export 'src/bootable_writer.dart';
export 'src/bytes.dart' show formatBytes, fat32MaxFileBytes, wimSplitSizeMiB;
export 'src/disk_enumerator.dart';
export 'src/disk_id.dart';
export 'src/exceptions.dart';
export 'src/file_copy.dart' show firstOversizedFat32File, isInstallWim;
export 'src/host_platform.dart';
export 'src/iso_mounter.dart';
export 'src/iso_validator.dart';
export 'src/models/iso_mount.dart';
export 'src/models/usb_disk.dart';
export 'src/models/windows_iso_info.dart';
export 'src/models/write_progress.dart';
export 'src/paths.dart';
export 'src/platforms/macos_host.dart'
    show
        usbDiskFromMacosInfo,
        hdiutilMountPath,
        hdiutilDeviceNode,
        isoMountFromHdiutilInfo,
        isoMountFromInfoPlist;
export 'src/platforms/windows_host.dart' show usbDiskFromWindowsInfo;
export 'src/process_runner.dart';
export 'src/safety.dart';
