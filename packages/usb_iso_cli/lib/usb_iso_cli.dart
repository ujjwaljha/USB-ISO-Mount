import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:usb_iso_core/usb_iso_core.dart';

Future<int> run(List<String> arguments) async {
  final runner =
      CommandRunner<int>(
          'usb_iso',
          'Mount ISOs, create bootable USB drives, or format a spare USB.',
        )
        ..addCommand(ListCommand())
        ..addCommand(MountCommand())
        ..addCommand(UnmountCommand())
        ..addCommand(MakeCommand())
        ..addCommand(FormatCommand());

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

String formatCliProgress(WriteProgress progress) {
  final percent = progress.percent == null
      ? ''
      : '  (${(progress.percent! * 100).round()}%)';
  return '${progress.message}$percent';
}

/// Prints write progress, rewriting the same TTY line during a raw write.
class CliProgressWriter {
  CliProgressWriter({StringSink? sink, bool? tty})
    : _sink = sink ?? stdout,
      _tty = tty ?? stdout.hasTerminal;

  final StringSink _sink;
  final bool _tty;
  bool _rewriting = false;

  void add(WriteProgress progress) {
    final line = formatCliProgress(progress);
    if (_tty && progress.step == WriteStep.writing) {
      _sink.write('\r$line\x1b[K');
      _rewriting = true;
      return;
    }
    finish();
    _sink.writeln(line);
  }

  void finish() {
    if (!_rewriting) {
      return;
    }
    _sink.writeln();
    _rewriting = false;
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
    try {
      final mount = await IsoMounter().mount(iso);
      final profile = IsoInspector().inspectMounted(mount.mountPath);
      stdout.writeln('Mounted at ${mount.mountPath}');
      stdout.writeln(profile.summary);
      stdout.writeln(profile.layoutSummary(_strategy(profile, iso)));
      if (profile.kind == IsoKind.unknown) {
        stderr.writeln(profile.unsupportedMessage);
        return 2;
      }
      return 0;
    } on UsbIsoException {
      final profile = IsoInspector().inspectIsoFile(iso);
      stdout.writeln(
        'Could not mount as a volume (typical for hybrid Linux ISOs).',
      );
      stdout.writeln(profile.summary);
      stdout.writeln(profile.layoutSummary(_strategy(profile, iso)));
      if (profile.kind == IsoKind.unknown) {
        stderr.writeln(profile.unsupportedMessage);
        return 2;
      }
      return 0;
    }
  }

  String _requireIso() {
    final iso = argResults?['iso'] as String?;
    if (iso == null || iso.isEmpty) {
      throw UsageException('Missing --iso', usage);
    }
    return iso;
  }

  WriteStrategy _strategy(IsoProfile profile, String iso) {
    return LayoutChooser.strategyFor(
      profile: profile,
      windowsHost: Platform.isWindows,
      diskSizeBytes: 0,
      isoLooksHybrid: isoLooksLikeHybridDisk(iso),
    );
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
    final disk = await _listedDisk(id, advanced: advanced);
    if (disk == null) {
      throw UnsafeDiskException(
        'Disk $id is not a listed removable USB drive. Run `usb_iso list`.',
      );
    }

    if (!dryRun) {
      await WindowsPrivilege.ensureAdministrator();
    }

    if (!dryRun && !yes) {
      final confirmed = confirmErase(disk);
      if (!confirmed) {
        stderr.writeln('Aborted.');
        return 1;
      }
    }

    stdout.writeln('Target: ${disk.label}');
    final token = CancellationToken();
    final printer = CliProgressWriter();
    final sigint = ProcessSignal.sigint.watch().listen((_) {
      stderr.writeln('Cancel requested…');
      token.cancel();
    });
    try {
      await for (final progress in BootableWriter().write(
        WriteRequest(
          isoPath: iso,
          disk: disk,
          confirmed: true,
          dryRun: dryRun,
          allowAdvancedTargets: advanced,
          cancellation: token,
        ),
      )) {
        printer.add(progress);
      }
      printer.finish();
    } on WriteCancelledException catch (error) {
      printer.finish();
      stderr.writeln(error.message);
      return 1;
    } finally {
      await sigint.cancel();
    }
    return 0;
  }
}

class FormatCommand extends Command<int> {
  FormatCommand() {
    argParser
      ..addOption(
        'disk',
        abbr: 'd',
        help: 'Whole-disk id from `usb_iso list` (disk4, 1, or sda).',
      )
      ..addOption(
        'fs',
        abbr: 'f',
        help: 'Filesystem: fat32 (default), exfat, or ntfs.',
        defaultsTo: 'fat32',
      )
      ..addOption(
        'label',
        abbr: 'l',
        help: 'Volume name (FAT32 max 11 characters).',
        defaultsTo: defaultVolumeLabel,
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        help: 'Skip the interactive ERASE confirmation.',
        negatable: false,
      )
      ..addFlag(
        'dry-run',
        help: 'Validate the target without formatting.',
        negatable: false,
      )
      ..addFlag(
        'advanced',
        help: 'Allow SD or Thunderbolt targets listed with `list --advanced`.',
        negatable: false,
      );
  }

  @override
  String get name => 'format';

  @override
  String get description =>
      'Erase a USB drive and format it as FAT32, exFAT, or NTFS (no ISO).';

  @override
  Future<int> run() async {
    final diskArg = argResults?['disk'] as String?;
    final fsArg = argResults?['fs'] as String? ?? 'fat32';
    final labelArg = argResults?['label'] as String? ?? defaultVolumeLabel;
    final yes = argResults?['yes'] as bool? ?? false;
    final dryRun = argResults?['dry-run'] as bool? ?? false;
    final advanced = argResults?['advanced'] as bool? ?? false;

    if (diskArg == null || diskArg.isEmpty) {
      throw UsageException('Missing --disk', usage);
    }

    final filesystem = parseVolumeFilesystem(fsArg);
    final id = DiskId.normalize(diskArg);
    final disk = await _listedDisk(id, advanced: advanced);
    if (disk == null) {
      throw UnsafeDiskException(
        'Disk $id is not a listed removable USB drive. Run `usb_iso list`.',
      );
    }

    if (!dryRun) {
      await WindowsPrivilege.ensureAdministrator();
    }

    if (!dryRun && !yes) {
      final confirmed = confirmErase(disk);
      if (!confirmed) {
        stderr.writeln('Aborted.');
        return 1;
      }
    }

    stdout.writeln(
      'Target: ${disk.label}  ${filesystem.displayName}  '
      '${sanitizeVolumeLabel(labelArg, filesystem)}',
    );
    final token = CancellationToken();
    final printer = CliProgressWriter();
    final sigint = ProcessSignal.sigint.watch().listen((_) {
      stderr.writeln('Cancel requested…');
      token.cancel();
    });
    try {
      await for (final progress in DiskFormatter().format(
        FormatRequest(
          disk: disk,
          filesystem: filesystem,
          volumeLabel: labelArg,
          confirmed: true,
          dryRun: dryRun,
          allowAdvancedTargets: advanced,
          cancellation: token,
        ),
      )) {
        printer.add(progress);
      }
      printer.finish();
    } on WriteCancelledException catch (error) {
      printer.finish();
      stderr.writeln(error.message);
      return 1;
    } finally {
      await sigint.cancel();
    }
    return 0;
  }
}

Future<UsbDisk?> _listedDisk(String id, {required bool advanced}) async {
  final disks = await DiskEnumerator().listRemovableUsb(
    includeAdvanced: advanced,
  );
  for (final candidate in disks) {
    if (candidate.id == id) {
      return candidate;
    }
  }
  return null;
}

bool confirmErase(UsbDisk disk) {
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
