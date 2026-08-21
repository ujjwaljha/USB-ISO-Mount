import 'host_factory.dart';
import 'host_platform.dart';
import 'models/usb_disk.dart';
import 'process_runner.dart';

class DiskEnumerator {
  DiskEnumerator({ProcessRunner? runner, HostPlatform? host})
    : _host = host ?? createHostPlatform(runner);

  final HostPlatform _host;

  /// Removable USB whole disks only. Internal and virtual disks are omitted.
  Future<List<UsbDisk>> listRemovableUsb() => _host.listUsbDisks();
}
