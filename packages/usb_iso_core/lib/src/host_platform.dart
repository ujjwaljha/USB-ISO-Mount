import 'models/iso_mount.dart';
import 'models/usb_disk.dart';

/// OS-specific disk, ISO, and format operations.
abstract class HostPlatform {
  Future<List<UsbDisk>> listUsbDisks();

  Future<IsoMount> mountIso(String isoPath);

  Future<void> unmountIso(IsoMount mount);

  /// Re-query the live disk and throw if it is no longer a safe USB target.
  Future<void> verifyWritable(UsbDisk disk);

  Future<void> eraseAndFormat(UsbDisk disk);

  Future<String> waitForVolumeMount(UsbDisk disk);

  Future<void> eject(UsbDisk disk);

  Future<String?> findWimSplitTool();

  Future<void> splitWim({
    required String sourceWim,
    required String destinationSwm,
    required String toolPath,
  });
}
