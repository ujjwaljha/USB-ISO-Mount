import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:usb_iso_core/usb_iso_core.dart';

Future<int> run(List<String> arguments) async {
  final runner =
      CommandRunner<int>(
          'usb_iso',
          'Mount ISOs and create bootable USB drives (Windows, WinPE, Linux).',
        )
        ..addCommand(ListCommand())
        ..addCommand(MountCommand())
        ..addCommand(UnmountCommand())
        ..addCommand(MakeCommand());

  try {
    final code = await runner.run(arguments);
    return code ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    return 64;
  } on UsbIsoException catch (error) {
    stderr.writeln(error.message);
    return 1;
  } catch (error) {
    stderr.writeln(error.toString());
    return 1;
  }
}

class ListCommand extends Command<int> {
  ListCommand() {
    argParser.addFlag(
      'advanced',
      help: 'Include SD and Thunderbolt drives.',
      negatable: false,
    );
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List removable USB drives.';

  @override
  Future<int> run() async {
    final advanced = argResults?['advanced'] as bool? ?? false;
    final disks = await DiskEnumerator().listRemovableUsb(
      includeAdvanced: advanced,
    );
    if (disks.isEmpty) {
      stdout.writeln('No removable USB drives found.');
      return 0;
    }
    for (final disk in disks) {
      final mounts = disk.mountPoints.isEmpty
          ? ''
          : '  mounts: ${disk.mountPoints.join(', ')}';
      stdout.writeln(
        '${disk.id}\t${disk.displayName}\t${disk.displaySize}$mounts',
      );
    }
    return 0;
  }
}

class MountCommand extends Command<int> {
  MountCommand() {
    argParser.addOption('iso', abbr: 'i', help: 'Path to an ISO image.');
  }

  @override
  String get name => 'mount';

  @override
  String get description => 'Mount an ISO without writing a USB.';

  @override
  Future<int> run() async {
    final iso = _requireIso();
    final mount = await IsoMounter().mount(iso);
    final profile = IsoInspector().inspectMounted(mount.mountPath);
    stdout.writeln('Mounted at ${mount.mountPath}');
    stdout.writeln(profile.summary);
    if (profile.kind == IsoKind.unknown) {
      stderr.writeln(profile.unsupportedMessage);
      return 2;
    }
    return 0;
  }

  String _requireIso() {
    final iso = argResults?['iso'] as String?;
    if (iso == null || iso.isEmpty) {
      throw UsageException('Missing --iso', usage);
    }
    return iso;
  }
}

class UnmountCommand extends Command<int> {
  UnmountCommand() {
    argParser.addOption('iso', abbr: 'i', help: 'Path to the mounted ISO.');
  }

  @override
  String get name => 'unmount';

  @override
  String get description => 'Unmount a previously mounted ISO.';

  @override
  Future<int> run() async {
    final iso = argResults?['iso'] as String?;
    if (iso == null || iso.isEmpty) {
      throw UsageException('Missing --iso', usage);
    }
    await IsoMounter().unmount(IsoMount(isoPath: iso, mountPath: ''));
    stdout.writeln('Unmounted $iso');
    return 0;
  }
}

class MakeCommand extends Command<int> {
  MakeCommand() {
    argParser
      ..addOption('iso', abbr: 'i', help: 'Path to a Windows or Linux ISO.')
      ..addOption(
        'disk',
        abbr: 'd',
        help: 'Whole-disk id from `usb_iso list` (disk4, 1, or sda).',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        help: 'Skip the interactive ERASE confirmation.',
        negatable: false,
      )
      ..addFlag(
        'dry-run',
        help: 'Validate the ISO and target without writing.',
        negatable: false,
      )
      ..addFlag(
        'advanced',
        help: 'Allow SD or Thunderbolt targets listed with `list --advanced`.',
        negatable: false,
      );
  }

  @override
  String get name => 'make';

  @override
  String get description =>
      'Erase a USB drive and write a bootable Windows or Linux image.';

  @override
  Future<int> run() async {
    final iso = argResults?['iso'] as String?;
    final diskArg = argResults?['disk'] as String?;
    final yes = argResults?['yes'] as bool? ?? false;
    final dryRun = argResults?['dry-run'] as bool? ?? false;
    final advanced = argResults?['advanced'] as bool? ?? false;

    if (iso == null || iso.isEmpty) {
      throw UsageException('Missing --iso', usage);
    }
    if (diskArg == null || diskArg.isEmpty) {
      throw UsageException('Missing --disk', usage);
    }

    final id = DiskId.normalize(diskArg);
    final disks = await DiskEnumerator().listRemovableUsb(
      includeAdvanced: advanced,
    );
    UsbDisk? disk;
    for (final candidate in disks) {
      if (candidate.id == id) {
        disk = candidate;
        break;
      }
    }
    if (disk == null) {
      throw UnsafeDiskException(
        'Disk $id is not a listed removable USB drive. Run `usb_iso list`.',
      );
    }

    if (!dryRun && !yes) {
      final confirmed = _confirmErase(disk);
      if (!confirmed) {
        stderr.writeln('Aborted.');
        return 1;
      }
    }

    stdout.writeln('Target: ${disk.label}');
    await for (final progress in BootableWriter().write(
      WriteRequest(
        isoPath: iso,
        disk: disk,
        confirmed: true,
        dryRun: dryRun,
        allowAdvancedTargets: advanced,
      ),
    )) {
      final percent = progress.percent == null
          ? ''
          : '  (${(progress.percent! * 100).round()}%)';
      stdout.writeln('${progress.message}$percent');
    }
    return 0;
  }

  bool _confirmErase(UsbDisk disk) {
    if (!stdin.hasTerminal) {
      stderr.writeln(
        'Refusing to erase ${disk.id} without --yes (stdin is not a terminal).',
      );
      return false;
    }
    stdout.writeln(
      'This will permanently erase ${disk.label}. Type ERASE to continue:',
    );
    final line = stdin.readLineSync();
    return line?.trim() == 'ERASE';
  }
}
