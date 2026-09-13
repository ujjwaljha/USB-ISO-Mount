import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'exceptions.dart';
import 'grub_config.dart';
import 'iso9660.dart';
import 'process_runner.dart';

/// Installs GRUB EFI files and a generated menu onto the FAT32 ESP.
class GrubInstaller {
  GrubInstaller({ProcessRunner? runner, this.bundledX64Efi, this.bundledArmEfi})
    : _runner = runner ?? ProcessRunner();

  final ProcessRunner _runner;
  final List<int>? bundledX64Efi;
  final List<int>? bundledArmEfi;

  Future<void> install({
    required String espMount,
    required String grubCfg,
    List<String> linuxMountPaths = const [],
    List<String> linuxIsoPaths = const [],
  }) async {
    final bootGrub = Directory(p.join(espMount, 'boot', 'grub'));
    await bootGrub.create(recursive: true);
    await File(p.join(bootGrub.path, 'grub.cfg')).writeAsString(grubCfg);

    final efiBoot = Directory(p.join(espMount, 'EFI', 'BOOT'));
    await efiBoot.create(recursive: true);
    await File(
      p.join(efiBoot.path, 'grub.cfg'),
    ).writeAsString(grubTrampolineConfig());

    final x64 = await _resolveX64Efi(linuxMountPaths, linuxIsoPaths);
    if (x64 == null) {
      throw DependencyMissingException(
        'Could not install a GRUB boot menu. Add a Linux live ISO (Ubuntu '
        'includes GRUB), install grub-mkimage, or keep the bundled '
        'BOOTX64.EFI next to the app.',
      );
    }
    await File(p.join(efiBoot.path, 'BOOTX64.EFI')).writeAsBytes(x64);

    final arm = await _resolveArmEfi(linuxMountPaths, linuxIsoPaths);
    if (arm != null) {
      await File(p.join(efiBoot.path, 'BOOTAA64.EFI')).writeAsBytes(arm);
    }
  }

  Future<List<int>?> _resolveX64Efi(
    List<String> linuxMounts,
    List<String> linuxIsos,
  ) async {
    if (bundledX64Efi != null && bundledX64Efi!.isNotEmpty) {
      return bundledX64Efi;
    }
    final bundled = await loadBundledGrubEfi('BOOTX64.EFI');
    if (bundled != null) {
      return bundled;
    }
    final built = await _grubMkimage();
    if (built != null) {
      return built;
    }
    for (final mount in linuxMounts) {
      final file = _firstExistingFile(mount, const [
        'efi/boot/bootx64.efi',
        'EFI/BOOT/BOOTX64.EFI',
        'EFI/Boot/bootx64.efi',
        'efi/boot/grubx64.efi',
        'EFI/BOOT/grubx64.efi',
      ]);
      if (file != null) {
        return file.readAsBytesSync();
      }
    }
    for (final iso in linuxIsos) {
      for (final relative in const [
        'efi/boot/bootx64.efi',
        'EFI/BOOT/BOOTX64.EFI',
        'EFI/Boot/bootx64.efi',
        'efi/boot/grubx64.efi',
        'EFI/BOOT/grubx64.efi',
        'EFI/Boot/grubx64.efi',
      ]) {
        final entry = findIso9660Path(iso, relative);
        if (entry == null || entry.isDirectory) {
          continue;
        }
        final temp = File(
          p.join(
            Directory.systemTemp.createTempSync('usb_iso_grub_').path,
            'BOOTX64.EFI',
          ),
        );
        extractIso9660File(isoPath: iso, entry: entry, destination: temp.path);
        return temp.readAsBytesSync();
      }
    }
    return null;
  }

  Future<List<int>?> _resolveArmEfi(
    List<String> linuxMounts,
    List<String> linuxIsos,
  ) async {
    if (bundledArmEfi != null && bundledArmEfi!.isNotEmpty) {
      return bundledArmEfi;
    }
    final bundled = await loadBundledGrubEfi('BOOTAA64.EFI');
    if (bundled != null) {
      return bundled;
    }
    for (final mount in linuxMounts) {
      final file = _firstExistingFile(mount, const [
        'efi/boot/bootaa64.efi',
        'EFI/BOOT/BOOTAA64.EFI',
        'efi/boot/grubaa64.efi',
      ]);
      if (file != null) {
        return file.readAsBytesSync();
      }
    }
    for (final iso in linuxIsos) {
      final entry =
          findIso9660Path(iso, 'efi/boot/bootaa64.efi') ??
          findIso9660Path(iso, 'efi/boot/grubaa64.efi');
      if (entry == null || entry.isDirectory) {
        continue;
      }
      final temp = File(
        p.join(
          Directory.systemTemp.createTempSync('usb_iso_grub_').path,
          'BOOTAA64.EFI',
        ),
      );
      extractIso9660File(isoPath: iso, entry: entry, destination: temp.path);
      return temp.readAsBytesSync();
    }
    return null;
  }

  Future<List<int>?> _grubMkimage() async {
    final tool = await _which('grub-mkimage');
    if (tool == null) {
      return null;
    }
    final dir = Directory.systemTemp.createTempSync('usb_iso_grubmk_');
    final embed = File(p.join(dir.path, 'embed.cfg'))
      ..writeAsStringSync(grubTrampolineConfig());
    final out = File(p.join(dir.path, 'BOOTX64.EFI'));
    final result = await _runner.run(tool, [
      '-O',
      'x86_64-efi',
      '-o',
      out.path,
      '-p',
      '/boot/grub',
      '-c',
      embed.path,
      'fat',
      'exfat',
      'ntfs',
      'iso9660',
      'part_gpt',
      'loopback',
      'linux',
      'search',
      'search_fs_file',
      'configfile',
      'normal',
      'chain',
    ]);
    if (!result.success || !out.existsSync()) {
      return null;
    }
    return out.readAsBytesSync();
  }

  Future<String?> _which(String command) async {
    if (Platform.isWindows) {
      return null;
    }
    final result = await _runner.run('sh', ['-c', 'command -v $command']);
    final path = result.stdout.trim().split('\n').first.trim();
    if (result.success && path.isNotEmpty) {
      return path;
    }
    return null;
  }
}

File? _firstExistingFile(String root, List<String> relatives) {
  for (final relative in relatives) {
    final file = File(p.join(root, relative));
    if (file.existsSync()) {
      return file;
    }
  }
  return null;
}

/// Loads a bundled GRUB EFI from the package, or from well-known repo paths.
Future<List<int>?> loadBundledGrubEfi(String name) async {
  try {
    final resolved = await Isolate.resolvePackageUri(
      Uri.parse('package:usb_iso_core/src/assets/grub/$name'),
    );
    if (resolved != null && resolved.isScheme('file')) {
      final file = File.fromUri(resolved);
      if (file.existsSync()) {
        return file.readAsBytesSync();
      }
    }
  } catch (_) {
    // Package URIs are unavailable in some AOT / test layouts.
  }
  final candidates = [
    p.join(Directory.current.path, 'lib', 'src', 'assets', 'grub', name),
    p.join(
      Directory.current.path,
      'packages',
      'usb_iso_core',
      'lib',
      'src',
      'assets',
      'grub',
      name,
    ),
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      return file.readAsBytesSync();
    }
  }
  return null;
}
