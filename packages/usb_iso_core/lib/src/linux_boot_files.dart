import 'dart:io';

import 'package:path/path.dart' as p;

import 'bytes.dart';
import 'iso9660.dart';

enum LinuxLiveKind {
  /// Ubuntu and derivatives (`casper/`).
  casper,

  /// Debian Live, Kali, and other live-boot images (`live/`).
  debianLive,

  /// Fedora / RHEL-family install media (`images/install.img`, Anaconda).
  fedora,

  /// Fedora-family live media (`LiveOS/squashfs.img`, dracut dmsquash-live).
  fedoraLive,

  /// Arch ISO (`arch/boot/x86_64/`, archiso hook).
  arch,

  generic,
}

/// Kernel, initrd, and boot arguments needed to loop-boot a Linux live ISO.
class LinuxBootFiles {
  const LinuxBootFiles({
    required this.kernelPath,
    required this.initrdPath,
    required this.kind,
    this.volumeId,
    this.extraInitrdPaths = const [],
  });

  /// Path inside the ISO, using `/` (`casper/vmlinuz`).
  final String kernelPath;
  final String initrdPath;
  final LinuxLiveKind kind;

  /// ISO 9660 volume id. Fedora Live needs it for `root=live:CDLABEL=`.
  final String? volumeId;

  /// Images GRUB loads before [initrdPath] (Arch microcode updates).
  final List<String> extraInitrdPaths;

  /// Every initrd in load order, as GRUB expects them on one `initrd` line.
  List<String> get initrdPaths => [...extraInitrdPaths, initrdPath];

  String kernelArguments(String isoPathOnUsb) {
    return switch (kind) {
      LinuxLiveKind.casper =>
        'boot=casper iso-scan/filename=$isoPathOnUsb noprompt quiet splash ---',
      LinuxLiveKind.debianLive =>
        'boot=live findiso=$isoPathOnUsb components quiet splash',
      LinuxLiveKind.fedora =>
        'inst.stage2=hd:LABEL=$isoBootVolumeLabel:$isoPathOnUsb quiet',
      LinuxLiveKind.fedoraLive => _fedoraLiveArguments(isoPathOnUsb),
      LinuxLiveKind.arch =>
        'img_dev=/dev/disk/by-label/$isoBootVolumeLabel '
            'img_loop=$isoPathOnUsb archisobasedir=arch earlymodules=loop',
      LinuxLiveKind.generic => 'iso-scan/filename=$isoPathOnUsb quiet',
    };
  }

  String _fedoraLiveArguments(String isoPathOnUsb) {
    final label = volumeId?.trim() ?? '';
    if (label.isEmpty) {
      return 'iso-scan/filename=$isoPathOnUsb rd.live.image quiet';
    }
    return 'root=live:CDLABEL=${cdLabelForKernel(label)} rd.live.image '
        'iso-scan/filename=$isoPathOnUsb quiet';
  }
}

/// Encodes a volume label the way udev names `/dev/disk/by-label` entries.
///
/// dracut resolves `CDLABEL=` through that directory, where spaces and
/// slashes are stored as `\x20` and `\x2f`.
String cdLabelForKernel(String label) {
  return label
      .replaceAll(r'\', r'\x5c')
      .replaceAll('/', r'\x2f')
      .replaceAll(' ', r'\x20');
}

/// Probes a mounted ISO tree. Pass [isoPath] so the volume id can be read.
LinuxBootFiles? probeLinuxBootFromTree(String root, {String? isoPath}) {
  return _probe(_TreeSource(root, isoPath: isoPath));
}

LinuxBootFiles? probeLinuxBootFromIso(String isoPath) {
  if (!File(isoPath).existsSync()) {
    return null;
  }
  return _probe(_IsoFileSource(isoPath));
}

const _kernelNames = ['vmlinuz', 'vmlinuz.efi', 'vmlinuz.efi.signed'];
const _initrdNames = ['initrd', 'initrd.lz', 'initrd.gz', 'initrd.img'];

LinuxBootFiles? _probe(_BootSource source) {
  final casper = source.pair('casper', _kernelNames, _initrdNames);
  if (casper != null) {
    return LinuxBootFiles(
      kernelPath: casper.$1,
      initrdPath: casper.$2,
      kind: LinuxLiveKind.casper,
    );
  }
  final live = source.pair('live', _kernelNames, _initrdNames);
  if (live != null) {
    return LinuxBootFiles(
      kernelPath: live.$1,
      initrdPath: live.$2,
      kind: LinuxLiveKind.debianLive,
    );
  }
  final fedora = source.pair(
    'images/pxeboot',
    const ['vmlinuz'],
    const ['initrd.img', 'initrd'],
  );
  if (fedora != null) {
    final live = source.resolve('LiveOS/squashfs.img') != null;
    return LinuxBootFiles(
      kernelPath: fedora.$1,
      initrdPath: fedora.$2,
      kind: live ? LinuxLiveKind.fedoraLive : LinuxLiveKind.fedora,
      volumeId: live ? source.volumeId : null,
    );
  }
  final arch = source.pair(
    'arch/boot/x86_64',
    const ['vmlinuz-linux', 'vmlinuz'],
    const ['initramfs-linux.img', 'initrd.img', 'initrd'],
  );
  if (arch != null) {
    final microcode = <String>[
      for (final name in const ['intel-ucode.img', 'amd-ucode.img'])
        ?source.resolve('arch/boot/$name'),
    ];
    return LinuxBootFiles(
      kernelPath: arch.$1,
      initrdPath: arch.$2,
      kind: LinuxLiveKind.arch,
      extraInitrdPaths: microcode,
    );
  }
  return null;
}

/// Read-only view of an ISO, either mounted on disk or as a raw image file.
abstract class _BootSource {
  /// Kernel + initrd paths under [directory], with their real casing.
  (String, String)? pair(
    String directory,
    List<String> kernels,
    List<String> initrds,
  );

  /// The real-cased path of [relativePath] when it exists, otherwise null.
  String? resolve(String relativePath);

  String? get volumeId;
}

class _TreeSource implements _BootSource {
  _TreeSource(this.root, {this.isoPath});

  final String root;
  final String? isoPath;

  @override
  (String, String)? pair(
    String directory,
    List<String> kernels,
    List<String> initrds,
  ) {
    final dirPath = resolve(directory);
    if (dirPath == null) {
      return null;
    }
    final dir = Directory(p.join(root, dirPath));
    if (!dir.existsSync()) {
      return null;
    }
    final names = [
      for (final entity in dir.listSync(followLinks: false))
        if (entity is File) p.basename(entity.path),
    ];
    final kernel = _firstMatch(names, kernels);
    final initrd = _firstMatch(names, initrds);
    if (kernel == null || initrd == null) {
      return null;
    }
    return ('$dirPath/$kernel', '$dirPath/$initrd');
  }

  @override
  String? resolve(String relativePath) {
    final parts = relativePath
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    var current = root;
    final walked = <String>[];
    for (final part in parts) {
      final exact = p.join(current, part);
      if (FileSystemEntity.typeSync(exact, followLinks: false) !=
          FileSystemEntityType.notFound) {
        walked.add(part);
        current = exact;
        continue;
      }
      final dir = Directory(current);
      if (!dir.existsSync()) {
        return null;
      }
      String? match;
      for (final entity in dir.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.toLowerCase() == part.toLowerCase()) {
          match = name;
          break;
        }
      }
      if (match == null) {
        return null;
      }
      walked.add(match);
      current = p.join(current, match);
    }
    return walked.join('/');
  }

  @override
  String? get volumeId {
    final path = isoPath;
    if (path == null || !File(path).existsSync()) {
      return null;
    }
    return readIso9660Info(path)?.volumeId;
  }
}

class _IsoFileSource implements _BootSource {
  _IsoFileSource(this.isoPath);

  final String isoPath;

  @override
  (String, String)? pair(
    String directory,
    List<String> kernels,
    List<String> initrds,
  ) {
    final listed = listIso9660Directory(isoPath, directory);
    if (listed.isEmpty) {
      return null;
    }
    final byName = <String, Iso9660FileEntry>{};
    for (final entry in listed) {
      if (!entry.isDirectory) {
        byName[p.basename(entry.path)] = entry;
      }
    }
    final kernel = _firstMatch(byName.keys.toList(), kernels);
    final initrd = _firstMatch(byName.keys.toList(), initrds);
    if (kernel == null || initrd == null) {
      return null;
    }
    return (byName[kernel]!.path, byName[initrd]!.path);
  }

  @override
  String? resolve(String relativePath) {
    final entry = findIso9660Path(isoPath, relativePath);
    if (entry == null || entry.isDirectory) {
      return null;
    }
    return entry.path;
  }

  @override
  String? get volumeId => readIso9660Info(isoPath)?.volumeId;
}

/// Picks the first preferred name present in [names] (case-insensitive,
/// exact match first, then prefix), returning it with its real casing.
String? _firstMatch(List<String> names, List<String> preferred) {
  for (final want in preferred) {
    for (final name in names) {
      if (name.toLowerCase() == want) {
        return name;
      }
    }
  }
  for (final want in preferred) {
    for (final name in names) {
      if (name.toLowerCase().startsWith(want)) {
        return name;
      }
    }
  }
  return null;
}
