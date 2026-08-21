import '../bytes.dart';

/// A whole disk that may be used as a write target.
class UsbDisk {
  const UsbDisk({
    required this.id,
    required this.devicePath,
    required this.name,
    required this.sizeBytes,
    required this.busProtocol,
    required this.isRemovable,
    required this.isInternal,
    required this.isBoot,
    required this.isVirtual,
    this.mountPoints = const [],
  });

  /// Whole-disk identifier: `disk4` on macOS, `1` on Windows.
  final String id;
  final String devicePath;
  final String name;
  final int sizeBytes;
  final String busProtocol;
  final bool isRemovable;
  final bool isInternal;
  final bool isBoot;
  final bool isVirtual;
  final List<String> mountPoints;

  String get displaySize => formatBytes(sizeBytes);

  String get displayName {
    if (name.trim().isEmpty) {
      return 'USB drive ($id)';
    }
    return name.trim();
  }

  String get label => '$displayName — $displaySize ($id)';

  /// USB bus, not internal, not virtual, not the system boot disk.
  bool get isSafeTarget {
    if (isInternal || isBoot || isVirtual) {
      return false;
    }
    return busProtocol.toUpperCase() == 'USB';
  }

  UsbDisk copyWith({List<String>? mountPoints}) {
    return UsbDisk(
      id: id,
      devicePath: devicePath,
      name: name,
      sizeBytes: sizeBytes,
      busProtocol: busProtocol,
      isRemovable: isRemovable,
      isInternal: isInternal,
      isBoot: isBoot,
      isVirtual: isVirtual,
      mountPoints: mountPoints ?? this.mountPoints,
    );
  }
}
