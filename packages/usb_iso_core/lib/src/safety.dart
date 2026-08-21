import 'exceptions.dart';
import 'models/usb_disk.dart';

class Safety {
  Safety._();

  /// Throws if [disk] must not be erased.
  static void ensureWritable(UsbDisk disk) {
    if (disk.isBoot) {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: it looks like a boot disk.',
      );
    }
    if (disk.isInternal) {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: it is an internal disk.',
      );
    }
    if (disk.isVirtual) {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: it is a virtual or disk-image volume.',
      );
    }
    final bus = disk.busProtocol.toUpperCase();
    if (bus == 'DISK IMAGE') {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: disk images are not USB targets.',
      );
    }
    if (bus != 'USB') {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: only USB drives are allowed '
        '(bus is ${disk.busProtocol}).',
      );
    }
    if (!disk.isSafeTarget) {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: it is not a safe USB target.',
      );
    }
  }
}
