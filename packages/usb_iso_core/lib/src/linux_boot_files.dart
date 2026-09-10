import 'dart:io';

import 'package:path/path.dart' as p;

import 'iso9660.dart';

enum LinuxLiveKind { casper, debianLive, fedora, arch, generic }

/// Kernel, initrd, and boot arguments needed to loop-boot a Linux live ISO.
class LinuxBootFiles {
  const LinuxBootFiles({
    required this.kernelPath,
    required this.initrdPath,
    required this.kind,
  });

  /// Path inside the ISO, using `/` (`casper/vmlinuz`).
  final String kernelPath;
  final String initrdPath;
  final LinuxLiveKind kind;

  String kernelArguments(String isoPathOnUsb) {
    return switch (kind) {
      LinuxLiveKind.casper =>
        'boot=casper iso-scan/filename=$isoPathOnUsb noprompt quiet splash ---',
      LinuxLiveKind.debianLive =>
        'boot=live findiso=$isoPathOnUsb components quiet splash',
      LinuxLiveKind.fedora =>
        'iso-scan/filename=$isoPathOnUsb inst.stage2=hd:LABEL=ISOBOOT:$isoPathOnUsb quiet',
      LinuxLiveKind.arch => 'img_loop=$isoPathOnUsb quiet',
      LinuxLiveKind.generic => 'iso-scan/filename=$isoPathOnUsb quiet',
    };
  }
}

LinuxBootFiles? probeLinuxBootFromTree(String root) {
  final casper = _pairFromTree(root, 'casper', _kernelNames, _initrdNames);
  if (casper != null) {
    return LinuxBootFiles(
      kernelPath: casper.$1,
      initrdPath: casper.$2,
      kind: LinuxLiveKind.casper,
    );
  }
  final live = _pairFromTree(root, 'live', _kernelNames, _initrdNames);
  if (live != null) {
    return LinuxBootFiles(
      kernelPath: live.$1,
      initrdPath: live.$2,
      kind: LinuxLiveKind.debianLive,
    );
  }
  final fedora = _pairFromTree(
    root,
    'images/pxeboot',
    const ['vmlinuz'],
    const ['initrd.img', 'initrd'],
  );
  if (fedora != null) {
    return LinuxBootFiles(
      kernelPath: fedora.$1,
      initrdPath: fedora.$2,
      kind: LinuxLiveKind.fedora,
    );
  }
  final arch = _pairFromTree(
    root,
    'arch/boot/x86_64',
    const ['vmlinuz-linux', 'vmlinuz'],
    const ['initramfs-linux.img', 'initrd.img', 'initrd'],
  );
  if (arch != null) {
    return LinuxBootFiles(
      kernelPath: arch.$1,
      initrdPath: arch.$2,
      kind: LinuxLiveKind.arch,
    );
  }
  return null;
}

LinuxBootFiles? probeLinuxBootFromIso(String isoPath) {
  final casper = _pairFromIso(isoPath, 'casper', _kernelNames, _initrdNames);
  if (casper != null) {
    return LinuxBootFiles(
      kernelPath: casper.$1,
      initrdPath: casper.$2,
      kind: LinuxLiveKind.casper,
    );
  }
  final live = _pairFromIso(isoPath, 'live', _kernelNames, _initrdNames);
  if (live != null) {
    return LinuxBootFiles(
      kernelPath: live.$1,
      initrdPath: live.$2,
      kind: LinuxLiveKind.debianLive,
    );
  }
  final fedora = _pairFromIso(
    isoPath,
    'images/pxeboot',
    const ['vmlinuz'],
    const ['initrd.img', 'initrd'],
  );
  if (fedora != null) {
    return LinuxBootFiles(
      kernelPath: fedora.$1,
      initrdPath: fedora.$2,
      kind: LinuxLiveKind.fedora,
    );
  }
  final arch = _pairFromIso(
    isoPath,
    'arch/boot/x86_64',
    const ['vmlinuz-linux', 'vmlinuz'],
    const ['initramfs-linux.img', 'initrd.img', 'initrd'],
  );
  if (arch != null) {
    return LinuxBootFiles(
      kernelPath: arch.$1,
      initrdPath: arch.$2,
      kind: LinuxLiveKind.arch,
    );
  }
  return null;
}

const _kernelNames = ['vmlinuz', 'vmlinuz.efi', 'vmlinuz.efi.signed'];
const _initrdNames = ['initrd', 'initrd.lz', 'initrd.gz', 'initrd.img'];

(String, String)? _pairFromTree(
  String root,
  String directory,
  List<String> kernels,
  List<String> initrds,
) {
  final dir = Directory(p.join(root, directory));
  if (dir.existsSync()) {
    final names = [
      for (final entity in dir.listSync(followLinks: false))
        if (entity is File) p.basename(entity.path).toLowerCase(),
    ];
    final kernel = _firstMatch(names, kernels, prefix: true);
    final initrd = _firstMatch(names, initrds, prefix: true);
    if (kernel != null && initrd != null) {
      return ('$directory/$kernel', '$directory/$initrd');
    }
  }
  for (final kernel in kernels) {
    for (final initrd in initrds) {
      final kernelFile = File(p.join(root, directory, kernel));
      final initrdFile = File(p.join(root, directory, initrd));
      if (kernelFile.existsSync() && initrdFile.existsSync()) {
        return ('$directory/$kernel', '$directory/$initrd');
      }
    }
  }
  return null;
}

(String, String)? _pairFromIso(
  String isoPath,
  String directory,
  List<String> kernels,
  List<String> initrds,
) {
  for (final kernel in kernels) {
    for (final initrd in initrds) {
      final kernelEntry = findIso9660Path(isoPath, '$directory/$kernel');
      final initrdEntry = findIso9660Path(isoPath, '$directory/$initrd');
      if (kernelEntry != null &&
          !kernelEntry.isDirectory &&
          initrdEntry != null &&
          !initrdEntry.isDirectory) {
        return (kernelEntry.path, initrdEntry.path);
      }
    }
  }
  final listed = listIso9660Directory(isoPath, directory);
  if (listed.isEmpty) {
    return null;
  }
  final names = [
    for (final entry in listed)
      if (!entry.isDirectory) p.basename(entry.path),
  ];
  final kernel = _firstMatch(names, kernels, prefix: true);
  final initrd = _firstMatch(names, initrds, prefix: true);
  if (kernel == null || initrd == null) {
    return null;
  }
  return ('$directory/$kernel', '$directory/$initrd');
}

String? _firstMatch(
  List<String> names,
  List<String> preferred, {
  required bool prefix,
}) {
  final lower = [for (final name in names) name.toLowerCase()];
  for (final want in preferred) {
    for (final name in lower) {
      if (name == want) {
        return name;
      }
    }
  }
  if (!prefix) {
    return null;
  }
  for (final want in preferred) {
    for (final name in lower) {
      if (name.startsWith(want)) {
        return name;
      }
    }
  }
  return null;
}
