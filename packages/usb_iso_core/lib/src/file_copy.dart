import 'dart:io';

import 'package:path/path.dart' as p;

import 'bytes.dart';

typedef CopyProgress = void Function(int copiedBytes, int totalBytes);

/// Recursively copies [source] to [destination], optionally skipping files.
Future<void> copyDirectory(
  String source,
  String destination, {
  bool Function(File file, String relativePath)? shouldSkip,
  CopyProgress? onProgress,
}) async {
  final sourceDir = Directory(source);
  if (!sourceDir.existsSync()) {
    throw FileSystemException('Source directory does not exist', source);
  }

  final files = <File>[];
  await for (final entity in sourceDir.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) {
      files.add(entity);
    }
  }

  var totalBytes = 0;
  for (final file in files) {
    totalBytes += await file.length();
  }

  var copiedBytes = 0;
  onProgress?.call(0, totalBytes);

  for (final file in files) {
    final relative = p.relative(file.path, from: source);
    final size = await file.length();
    if (shouldSkip != null && shouldSkip(file, relative)) {
      copiedBytes += size;
      onProgress?.call(copiedBytes, totalBytes);
      continue;
    }

    final target = File(p.join(destination, relative));
    await target.parent.create(recursive: true);
    await file.copy(target.path);
    copiedBytes += size;
    onProgress?.call(copiedBytes, totalBytes);
  }
}

bool isInstallWim(String relativePath) {
  final normalized = relativePath.replaceAll(r'\', '/').toLowerCase();
  return normalized == 'sources/install.wim';
}

/// Relative path of the first file over [limit], or null.
Future<String?> firstOversizedFat32File(
  String mountPath, {
  required bool skipWim,
  int limit = fat32MaxFileBytes,
}) async {
  await for (final entity in Directory(
    mountPath,
  ).list(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final size = await entity.length();
    if (size <= limit) {
      continue;
    }
    final relative = p.relative(entity.path, from: mountPath);
    if (skipWim && isInstallWim(relative)) {
      continue;
    }
    return relative;
  }
  return null;
}
