import 'dart:io';

import 'exceptions.dart';
import 'process_runner.dart';

/// Host privilege checks used before a destructive write.
class WindowsPrivilege {
  WindowsPrivilege._();

  static const adminRequiredMessage =
      'Run this terminal as Administrator before writing a USB.';

  /// No-op off Windows. On Windows, throws unless the process is elevated.
  static Future<void> ensureAdministrator({
    bool? isWindows,
    Future<bool> Function()? probe,
    ProcessRunner? runner,
  }) async {
    if (!(isWindows ?? Platform.isWindows)) {
      return;
    }
    final elevated = probe != null
        ? await probe()
        : await probeNetSession(runner ?? ProcessRunner());
    if (!elevated) {
      throw UsbIsoException(adminRequiredMessage);
    }
  }

  static Future<bool> probeNetSession(ProcessRunner runner) async {
    final result = await runner.run('net', ['session']);
    return result.success;
  }
}
