import 'dart:io';

import 'package:path/path.dart' as p;

import 'bytes.dart';
import 'exceptions.dart';
import 'linux_boot_files.dart';
import 'models/iso_profile.dart';

enum MultiIsoRole { windows, linux }

class MultiIsoItem {
  const MultiIsoItem({
    required this.isoPath,
    required this.profile,
    required this.role,
    required this.menuTitle,
    required this.usbIsoFileName,
    this.linuxBoot,
    this.mountPath,
  });

  final String isoPath;
  final IsoProfile profile;
  final MultiIsoRole role;
  final String menuTitle;

  /// Basename used under `/isos` on the USB (Linux only).
  final String usbIsoFileName;
  final LinuxBootFiles? linuxBoot;
  final String? mountPath;

  String get isoPathOnUsb => '/$multibootIsoFolder/$usbIsoFileName';
}

class MultiIsoPlan {
  const MultiIsoPlan({required this.items, required this.requiredBytes});

  final List<MultiIsoItem> items;
  final int requiredBytes;

  MultiIsoItem? get windows {
    for (final item in items) {
      if (item.role == MultiIsoRole.windows) {
        return item;
      }
    }
    return null;
  }

  List<MultiIsoItem> get linux => [
    for (final item in items)
      if (item.role == MultiIsoRole.linux) item,
  ];

  String get summary {
    final lines = [
      for (final item in items)
        item.role == MultiIsoRole.windows
            ? '  • ${item.menuTitle} (extract Windows Setup to the USB root)'
            : '  • ${item.menuTitle} (ISO file ${item.isoPathOnUsb})',
    ];
    return lines.join('\n');
  }
}

bool isWindowsInstallerKind(IsoKind kind) {
  return kind == IsoKind.windowsX64 ||
      kind == IsoKind.windowsArm ||
      kind == IsoKind.windowsPe;
}

bool isLinuxLiveKind(IsoKind kind) {
  return kind == IsoKind.linuxHybrid;
}

/// Builds a validated multiboot plan from already-inspected ISOs.
MultiIsoPlan planMultiboot({
  required List<MultiIsoDraft> drafts,
  required int diskSizeBytes,
}) {
  if (drafts.length < 2) {
    throw InvalidIsoException(
      'A multiboot USB needs at least two ISO images (for example Windows '
      'and Ubuntu). For a single image, write it with the regular make command.',
    );
  }

  final seen = <String>{};
  var windowsCount = 0;
  final usedNames = <String>{};
  final items = <MultiIsoItem>[];

  for (final draft in drafts) {
    final normalized = p.normalize(File(draft.isoPath).absolute.path);
    if (!seen.add(normalized)) {
      throw InvalidIsoException(
        'The same ISO was added twice: ${draft.isoPath}',
      );
    }
    if (!File(draft.isoPath).existsSync()) {
      throw InvalidIsoException('ISO not found: ${draft.isoPath}');
    }

    final kind = draft.profile.kind;
    if (isWindowsInstallerKind(kind)) {
      windowsCount++;
      if (windowsCount > 1) {
        throw InvalidIsoException(
          'Only one Windows installer can be used on a multiboot USB. '
          'Windows Setup looks for \\sources at the volume root, so a second '
          'Windows ISO cannot share the stick. Keep one Windows image and add '
          'Linux live ISOs, or write the other Windows ISO to its own USB.',
        );
      }
      if (draft.mountPath == null) {
        throw InvalidIsoException(
          'Could not mount ${p.basename(draft.isoPath)} to copy Windows Setup '
          'files. Mount it first, or write that ISO by itself.',
        );
      }
      items.add(
        MultiIsoItem(
          isoPath: draft.isoPath,
          profile: draft.profile,
          role: MultiIsoRole.windows,
          menuTitle: _menuTitle(draft.profile, draft.isoPath),
          usbIsoFileName: _uniqueIsoFileName(draft.isoPath, usedNames),
          mountPath: draft.mountPath,
        ),
      );
      continue;
    }

    final linuxBoot =
        draft.linuxBoot ??
        (draft.mountPath != null
            ? probeLinuxBootFromTree(draft.mountPath!)
            : null) ??
        probeLinuxBootFromIso(draft.isoPath);
    if (linuxBoot == null ||
        (!isLinuxLiveKind(kind) && kind != IsoKind.genericUefi)) {
      throw InvalidIsoException(
        '${p.basename(draft.isoPath)} is not a Windows installer or a Linux '
        'live image that this app can put on a GRUB menu. Ubuntu, Debian Live, '
        'Fedora, and similar casper/live ISOs are supported.',
      );
    }
    items.add(
      MultiIsoItem(
        isoPath: draft.isoPath,
        profile: draft.profile,
        role: MultiIsoRole.linux,
        menuTitle: _menuTitle(draft.profile, draft.isoPath),
        usbIsoFileName: _uniqueIsoFileName(draft.isoPath, usedNames),
        linuxBoot: linuxBoot,
        mountPath: draft.mountPath,
      ),
    );
  }

  var required = efiSystemPartitionBytes + 64 * 1024 * 1024;
  for (final item in items) {
    required += File(item.isoPath).lengthSync();
  }
  if (diskSizeBytes < required) {
    throw UsbIsoException(
      'This USB is ${formatBytes(diskSizeBytes)} but the selected ISOs need '
      'about ${formatBytes(required)} (EFI boot partition plus the images). '
      'Use a larger drive.',
    );
  }

  return MultiIsoPlan(items: items, requiredBytes: required);
}

class MultiIsoDraft {
  const MultiIsoDraft({
    required this.isoPath,
    required this.profile,
    this.linuxBoot,
    this.mountPath,
  });

  final String isoPath;
  final IsoProfile profile;
  final LinuxBootFiles? linuxBoot;
  final String? mountPath;
}

String _menuTitle(IsoProfile profile, String isoPath) {
  final name = p
      .basenameWithoutExtension(isoPath)
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .trim();
  if (name.isEmpty) {
    return profile.kindLabel;
  }
  return '${profile.kindLabel}: $name';
}

String uniqueIsoFileName(String isoPath, Set<String> used) =>
    _uniqueIsoFileName(isoPath, used);

String _uniqueIsoFileName(String isoPath, Set<String> used) {
  var base = p.basename(isoPath).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (base.isEmpty) {
    base = 'linux.iso';
  }
  if (!base.toLowerCase().endsWith('.iso')) {
    base = '$base.iso';
  }
  var candidate = base;
  var index = 2;
  while (used.contains(candidate.toLowerCase())) {
    final stem = p.basenameWithoutExtension(base);
    candidate = '${stem}_$index.iso';
    index++;
  }
  used.add(candidate.toLowerCase());
  return candidate;
}
