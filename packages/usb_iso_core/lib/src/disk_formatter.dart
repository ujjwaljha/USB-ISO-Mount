import 'dart:io';

import 'bytes.dart';
import 'cancellation.dart';
import 'exceptions.dart';
import 'host_factory.dart';
import 'host_platform.dart';
import 'models/usb_disk.dart';
import 'models/write_progress.dart';
import 'process_runner.dart';
import 'safety.dart';
import 'volume_filesystem.dart';

class FormatRequest {
  const FormatRequest({
    required this.disk,
    this.filesystem = VolumeFilesystem.fat32,
    this.volumeLabel = defaultVolumeLabel,
    this.confirmed = false,
    this.dryRun = false,
    this.allowAdvancedTargets = false,
    this.cancellation,
  });

  final UsbDisk disk;
  final VolumeFilesystem filesystem;
  final String volumeLabel;
  final bool confirmed;
  final bool dryRun;
  final bool allowAdvancedTargets;
  final CancellationToken? cancellation;
}

/// Erases a removable USB and creates a single GPT data volume.
class DiskFormatter {
  DiskFormatter({ProcessRunner? runner, HostPlatform? host})
    : _host = host ?? createHostPlatform(runner);

  final HostPlatform _host;

  Stream<WriteProgress> format(FormatRequest request) async* {
    if (!request.dryRun && !request.confirmed) {
      throw ConfirmationRequiredException(
        'Refusing to erase ${request.disk.id} without explicit confirmation.',
      );
    }

    Safety.ensureWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    await _host.verifyWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );

    if (!request.filesystem.isSupportedOnThisHost) {
      throw UsbIsoException(request.filesystem.unsupportedHostMessage);
    }

    final label = sanitizeVolumeLabel(request.volumeLabel, request.filesystem);
    request.cancellation?.throwIfCancelled();

    if (request.dryRun) {
      yield WriteProgress(
        step: WriteStep.done,
        message: dryRunFormatSummary(
          disk: request.disk,
          filesystem: request.filesystem,
          volumeLabel: label,
          windowsHost: Platform.isWindows,
        ),
        percent: 1,
      );
      return;
    }

    yield WriteProgress(
      step: WriteStep.preparing,
      message:
          'Formatting ${request.disk.label} as ${request.filesystem.displayName} ($label)…',
      percent: 0.1,
    );
    yield WriteProgress(
      step: WriteStep.erasing,
      message: 'Erasing ${request.disk.id}…',
      percent: 0.2,
    );

    await _host.verifyWritable(
      request.disk,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    request.cancellation?.throwIfCancelled();
    await _host.formatDataVolume(
      request.disk,
      filesystem: request.filesystem,
      volumeLabel: label,
      allowAdvancedTargets: request.allowAdvancedTargets,
    );
    request.cancellation?.throwIfCancelled(
      diskAlreadyErased: true,
      message:
          'Format cancelled. The USB was erased and may need to be formatted again.',
    );

    yield WriteProgress(
      step: WriteStep.done,
      message:
          'Formatted ${request.disk.id} as ${request.filesystem.displayName} ($label). '
          'The volume should appear as a regular USB drive.',
      percent: 1,
    );
  }
}

String dryRunFormatSummary({
  required UsbDisk disk,
  required VolumeFilesystem filesystem,
  required String volumeLabel,
  required bool windowsHost,
}) {
  final buffer = StringBuffer()
    ..writeln('Dry run: would erase ${disk.label}.')
    ..writeln(
      'Filesystem: ${filesystem.displayName}  Label: $volumeLabel  Partition: GPT',
    );
  if (windowsHost &&
      filesystem == VolumeFilesystem.fat32 &&
      disk.sizeBytes > windowsFat32PartitionMaxBytes) {
    buffer.writeln(
      'Windows FAT32 is limited to a ${formatBytes(windowsFat32PartitionMaxBytes)} '
      'partition on this ${disk.displaySize} drive. Use exFAT for the whole disk.',
    );
  }
  return buffer.toString().trim();
}
