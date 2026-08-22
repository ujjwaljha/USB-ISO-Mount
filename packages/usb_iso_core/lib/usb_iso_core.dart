/// Shared logic for listing USB disks, mounting ISOs, and writing
/// bootable installer sticks on macOS, Windows, and Linux.
library;

export 'src/bootable_writer.dart';
export 'src/bytes.dart'
    show
        formatBytes,
        fat32MaxFileBytes,
        wimSplitSizeMiB,
        windowsFat32PartitionMaxBytes,
        windowsFat32BootPartitionBytes;
export 'src/cancellation.dart';
export 'src/disk_enumerator.dart';
export 'src/disk_id.dart';
export 'src/disk_layout.dart';
export 'src/exceptions.dart';
export 'src/file_copy.dart'
    show firstOversizedFat32File, isInstallWim, isInstallImage;
export 'src/host_platform.dart';
export 'src/hybrid_iso.dart';
export 'src/iso9660.dart';
export 'src/iso_inspector.dart';
export 'src/iso_mounter.dart';
export 'src/iso_validator.dart';
export 'src/layout_chooser.dart';
export 'src/models/iso_mount.dart';
export 'src/models/iso_profile.dart';
export 'src/models/usb_disk.dart';
export 'src/models/windows_iso_info.dart';
export 'src/models/write_progress.dart';
export 'src/paths.dart';
export 'src/platforms/linux_host.dart'
    show usbDiskFromLinuxInfo, linuxBootDiskName;
export 'src/platforms/macos_host.dart'
    show
        usbDiskFromMacosInfo,
        hdiutilMountPath,
        hdiutilDeviceNode,
        isoMountFromHdiutilInfo,
        isoMountFromInfoPlist;
export 'src/platforms/windows_host.dart'
    show usbDiskFromWindowsInfo, isAdvancedWindowsBus;
export 'src/process_runner.dart';
export 'src/safety.dart';
