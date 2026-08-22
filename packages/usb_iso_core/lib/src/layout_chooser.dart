import 'bytes.dart';
import 'models/iso_profile.dart';

/// Picks a [WriteStrategy] from an inspected ISO and the host OS.
class LayoutChooser {
  LayoutChooser._();

  static WriteStrategy strategyFor({
    required IsoProfile profile,
    required bool windowsHost,
    required int diskSizeBytes,
    bool isoLooksHybrid = false,
  }) {
    switch (profile.kind) {
      case IsoKind.unknown:
        return WriteStrategy.unsupported;
      case IsoKind.linuxHybrid:
        return WriteStrategy.rawHybrid;
      case IsoKind.genericUefi:
        return isoLooksHybrid
            ? WriteStrategy.rawHybrid
            : WriteStrategy.windowsFileCopy;
      case IsoKind.windowsX64:
      case IsoKind.windowsArm:
      case IsoKind.windowsPe:
        if (windowsHost &&
            (profile.hasOversizedInstallImage ||
                profile.hasOversizedFat32File)) {
          const slack = 64 * 1024 * 1024;
          final needed =
              windowsFat32BootPartitionBytes + profile.installImageSize + slack;
          if (diskSizeBytes >= needed) {
            return WriteStrategy.windowsDualPartition;
          }
        }
        return WriteStrategy.windowsFileCopy;
    }
  }
}
