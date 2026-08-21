import 'host_factory.dart';
import 'host_platform.dart';
import 'models/iso_mount.dart';
import 'process_runner.dart';

class IsoMounter {
  IsoMounter({ProcessRunner? runner, HostPlatform? host})
    : _host = host ?? createHostPlatform(runner);

  final HostPlatform _host;

  Future<IsoMount> mount(String isoPath) => _host.mountIso(isoPath);

  Future<void> unmount(IsoMount mount) => _host.unmountIso(mount);
}
