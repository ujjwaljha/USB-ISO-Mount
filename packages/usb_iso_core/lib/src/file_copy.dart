import 'dart:io';

import 'package:path/path.dart' as p;

import 'bytes.dart';
import 'cancellation.dart';

typedef CopyProgress = void Function(int copiedBytes, int totalBytes);

/// Recursively copies [source] to [destination], optionally skipping files.
Future<void> copyDirectory(
  String source,
  String destination, {
  bool Function(File file, String relativePath)? shouldSkip,
  CopyProgress? onProgress,
  CancellationToken? cancellation,
  bool countSkippedInProgress = true,
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
    cancellation?.throwIfCancelled(diskAlreadyErased: true);
    final relative = p.relative(file.path, from: source);
    final size = await file.length();
    if (shouldSkip != null && shouldSkip(file, relative)) {
      if (countSkippedInProgress) {
        copiedBytes += size;
        onProgress?.call(copiedBytes, totalBytes);
      }
      continue;
    }

    final target = File(p.join(destination, relative));
    await target.parent.create(recursive: true);
    await file.copy(target.path);
    copiedBytes += size;
    onProgress?.call(copiedBytes, totalBytes);
  }
}

/// Copies one file, reporting progress as bytes are written.
Future<void> copyFileWithProgress(
  String source,
  String destination, {
  CopyProgress? onProgress,
  CancellationToken? cancellation,
}) async {
  final file = File(source);
  if (!file.existsSync()) {
    throw FileSystemException('Source file does not exist', source);
  }
  final total = await file.length();
  await File(destination).parent.create(recursive: true);
  final output = File(destination).openWrite();
  var copied = 0;
  onProgress?.call(0, total);
  try {
    await for (final chunk in file.openRead()) {
      cancellation?.throwIfCancelled(diskAlreadyErased: true);
      output.add(chunk);
      copied += chunk.length;
      onProgress?.call(copied, total);
    }
    await output.flush();
  } finally {
    await output.close();
  }
}

bool isInstallWim(String relativePath) {
  final normalized = relativePath.replaceAll(r'\', '/').toLowerCase();
  return normalized == 'sources/install.wim';
}

bool isInstallImage(String relativePath) {
  final normalized = relativePath.replaceAll(r'\', '/').toLowerCase();
  return normalized == 'sources/install.wim' ||
      normalized == 'sources/install.esd';
}

bool isOversizedFat32File(File file, {int limit = fat32MaxFileBytes}) {
  return file.lengthSync() > limit;
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
    if (skipWim && isInstallImage(relative)) {
      continue;
    }
    return relative;
  }
  return null;
}
