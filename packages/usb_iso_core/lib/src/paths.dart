import 'package:path/path.dart' as p;

/// True when [isoPath] is the mount root or a file inside it.
bool isoLivesOnMount(String isoPath, String mountPoint) {
  if (isoPath.isEmpty || mountPoint.isEmpty) {
    return false;
  }
  final iso = p.normalize(p.absolute(isoPath));
  var root = p.normalize(p.absolute(mountPoint));
  // `E:` and `E:\` should compare as the same Windows volume root.
  if (root.length == 2 && root.endsWith(':')) {
    root = '$root${p.separator}';
  }
  return p.equals(iso, root) || p.isWithin(root, iso);
}

bool isoLivesOnAnyMount(String isoPath, Iterable<String> mountPoints) {
  return mountPoints.any((mount) => isoLivesOnMount(isoPath, mount));
}
