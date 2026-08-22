import 'exceptions.dart';
import 'iso_inspector.dart';
import 'models/windows_iso_info.dart';

class WindowsIsoValidator {
  WindowsIsoValidator({IsoInspector? inspector})
    : _inspector = inspector ?? IsoInspector();

  final IsoInspector _inspector;

  /// Inspects an already-mounted Windows ISO directory.
  WindowsIsoInfo inspectMounted(String mountPath) {
    return _inspector.inspectMounted(mountPath).toWindowsIsoInfo();
  }

  void ensureValid(WindowsIsoInfo info) {
    if (!info.hasEfiBoot) {
      throw InvalidIsoException(
        'This ISO is missing EFI boot files (efi/boot/bootx64.efi or '
        'bootaa64.efi). It does not look like a Windows installer.',
      );
    }
    if (info.installKind == WindowsInstallImageKind.none) {
      throw InvalidIsoException(
        'This ISO is missing sources/install.wim, sources/install.esd, '
        'and sources/boot.wim. It does not look like a Windows installer.',
      );
    }
  }
}
