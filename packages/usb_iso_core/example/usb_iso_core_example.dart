import 'package:usb_iso_core/usb_iso_core.dart';

Future<void> main() async {
  final disks = await DiskEnumerator().listRemovableUsb();
  if (disks.isEmpty) {
    print('No removable USB drives found.');
    return;
  }
  for (final disk in disks) {
    print(disk.label);
  }
}
