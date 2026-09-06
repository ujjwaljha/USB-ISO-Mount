import 'cancellation.dart';
import 'disk_layout.dart';
import 'models/iso_mount.dart';
import 'models/usb_disk.dart';
import 'volume_filesystem.dart';

typedef RawWriteProgress = void Function(int writtenBytes, int totalBytes);

/// OS-specific disk, ISO, and format operations.
abstract class HostPlatform {
  Future<List<UsbDisk>> listUsbDisks({bool includeAdvanced = false});

  Future<IsoMount> mountIso(String isoPath);

  Future<void> unmountIso(IsoMount mount);

  /// Re-query the live disk and throw if it is no longer a safe USB target.
  Future<void> verifyWritable(
    UsbDisk disk, {
    bool allowAdvancedTargets = false,
  });

  Future<void> eraseAndFormat(
    UsbDisk disk, {
    DiskLayout layout = DiskLayout.fat32,
  });

  /// Erase [disk] and create one GPT volume for data use (not a bootable ISO).
  Future<void> formatDataVolume(
    UsbDisk disk, {
    required VolumeFilesystem filesystem,
    String volumeLabel = defaultVolumeLabel,
    bool allowAdvancedTargets = false,
  });

  Future<PreparedVolumes> waitForVolumeMount(
    UsbDisk disk, {
    DiskLayout layout = DiskLayout.fat32,
  });

  Future<void> eject(UsbDisk disk);

  Future<String?> findWimSplitTool();

  Future<void> splitWim({
    required String sourceWim,
    required String destinationSwm,
    required String toolPath,
  });

  Future<void> writeRawImage({
    required UsbDisk disk,
    required String isoPath,
    RawWriteProgress? onProgress,
    CancellationToken? cancellation,
  });

  Future<void> flushDisk(UsbDisk disk);
}
