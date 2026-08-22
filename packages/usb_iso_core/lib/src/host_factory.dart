import 'dart:io';

import 'exceptions.dart';
import 'host_platform.dart';
import 'platforms/linux_host.dart';
import 'platforms/macos_host.dart';
import 'platforms/windows_host.dart';
import 'process_runner.dart';

HostPlatform createHostPlatform([ProcessRunner? runner]) {
  final processRunner = runner ?? ProcessRunner();
  if (Platform.isMacOS) {
    return MacosHost(processRunner);
  }
  if (Platform.isWindows) {
    return WindowsHost(processRunner);
  }
  if (Platform.isLinux) {
    return LinuxHost(processRunner);
  }
  throw UnsupportedPlatformException(
    'USB ISO Mount supports macOS, Windows, and Linux '
    '(this OS is ${Platform.operatingSystem}).',
  );
}
