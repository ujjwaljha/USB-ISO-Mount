/// A mounted ISO image.
class IsoMount {
  const IsoMount({
    required this.isoPath,
    required this.mountPath,
    this.deviceNode,
  });

  final String isoPath;

  /// Directory where the ISO contents are visible.
  final String mountPath;

  /// macOS `/dev/diskN` from `hdiutil`, if known.
  final String? deviceNode;
}
