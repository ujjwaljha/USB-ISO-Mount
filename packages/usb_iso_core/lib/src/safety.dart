import 'exceptions.dart';
import 'models/usb_disk.dart';

class Safety {
  Safety._();

  /// Throws if [disk] must not be erased.
  static void ensureWritable(
    UsbDisk disk, {
    bool allowAdvancedTargets = false,
  }) {
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
    if (disk.isSafeTarget) {
      return;
    }
    if (disk.isAdvancedTarget) {
      if (!allowAdvancedTargets) {
        throw UnsafeDiskException(
          'Refusing to erase ${disk.id}: ${disk.busProtocol} drives are hidden '
          'unless advanced targets are enabled.',
        );
      }
      return;
    }
    if (bus != 'USB') {
      throw UnsafeDiskException(
        'Refusing to erase ${disk.id}: only USB drives are allowed '
        '(bus is ${disk.busProtocol}).',
      );
    }
    throw UnsafeDiskException(
      'Refusing to erase ${disk.id}: it is not a safe USB target.',
    );
  }
}
