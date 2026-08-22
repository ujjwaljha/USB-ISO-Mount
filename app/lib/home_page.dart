import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:usb_iso_core/usb_iso_core.dart';

import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.listDisks});

  /// Override USB enumeration (used by tests). Defaults to live diskutil/Get-Disk.
  final Future<List<UsbDisk>> Function()? listDisks;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _disks = DiskEnumerator();
  final _mounter = IsoMounter();
  final _writer = BootableWriter();
  final _inspector = IsoInspector();

  List<UsbDisk> _usbDisks = [];
  UsbDisk? _selected;
  String? _isoPath;
  IsoMount? _isoMount;
  IsoProfile? _isoProfile;
  String? _error;
  String? _status;
  double? _progress;
  bool _busy = false;
  bool _loadingDisks = true;
  bool _showAdvanced = false;
  CancellationToken? _writeCancel;

  @override
  void initState() {
    super.initState();
    _refreshDisks();
  }

  Future<void> _refreshDisks() async {
    setState(() {
      _loadingDisks = true;
      _error = null;
    });
    try {
      final disks =
          await (widget.listDisks ??
              (() =>
                  _disks.listRemovableUsb(includeAdvanced: _showAdvanced)))();
      if (!mounted) {
        return;
      }
      setState(() {
        _usbDisks = disks;
        if (_selected == null ||
            disks.every((disk) => disk.id != _selected!.id)) {
          _selected = disks.isEmpty ? null : disks.first;
        } else {
          _selected = disks.firstWhere((disk) => disk.id == _selected!.id);
        }
        _loadingDisks = false;
      });
    } on UsbIsoException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.message;
        _loadingDisks = false;
      });
    }
  }

  Future<void> _pickIso() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['iso'],
      dialogTitle: 'Choose an ISO image',
    );
    final path = result?.files.single.path;
    if (path == null) {
      return;
    }
    await _unmountQuietly();
    if (!mounted) {
      return;
    }
    setState(() {
      _isoPath = path;
      _isoProfile = null;
      _error = null;
    });
  }

  Future<void> _unmountQuietly() async {
    final mount = _isoMount;
    if (mount == null) {
      return;
    }
    try {
      await _mounter.unmount(mount);
    } on UsbIsoException {
      // Best-effort when switching ISOs.
    }
    _isoMount = null;
  }

  Future<void> _mountIso() async {
    final iso = _isoPath;
    if (iso == null) {
      setState(() => _error = 'Choose an ISO first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Mounting ISO…';
    });
    try {
      final mount = await _mounter.mount(iso);
      final profile = _inspector.inspectMounted(mount.mountPath);
      if (!mounted) {
        return;
      }
      setState(() {
        _isoMount = mount;
        _isoProfile = profile;
        _status = 'Mounted at ${mount.mountPath}';
        if (profile.kind == IsoKind.unknown) {
          _error = profile.unsupportedMessage;
        }
      });
    } on UsbIsoException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.message;
        _status = 'Mount failed.';
        _progress = 0;
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _unmountIso() async {
    final mount = _isoMount;
    if (mount == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _mounter.unmount(mount);
      if (!mounted) {
        return;
      }
      setState(() {
        _isoMount = null;
        _status = 'ISO unmounted.';
      });
    } on UsbIsoException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _makeBootable() async {
    final iso = _isoPath;
    final disk = _selected;
    if (iso == null) {
      setState(() => _error = 'Choose an ISO first.');
      return;
    }
    if (disk == null) {
      setState(() => _error = 'Plug in a USB drive and refresh the list.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _EraseDialog(disk: disk, profile: _isoProfile),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final token = CancellationToken();
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
      _status = 'Starting…';
      _writeCancel = token;
    });

    try {
      await for (final event in _writer.write(
        WriteRequest(
          isoPath: iso,
          disk: disk,
          confirmed: true,
          existingMount: _isoMount,
          allowAdvancedTargets: _showAdvanced,
          cancellation: token,
        ),
      )) {
        if (!mounted) {
          return;
        }
        setState(() {
          _status = event.message;
          _progress = event.percent;
        });
      }
      await _unmountQuietly();
      await _refreshDisks();
    } on WriteCancelledException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.message;
        _status = 'Cancelled.';
        _progress = 0;
      });
    } on UsbIsoException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.message;
        _status = 'Stopped.';
        _progress = 0;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _status = 'Stopped.';
        _progress = 0;
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _writeCancel = null;
        });
      }
    }
  }

  String? get _writeLayoutLine {
    final profile = _isoProfile;
    final iso = _isoPath;
    if (profile == null) {
      return null;
    }
    final strategy = LayoutChooser.strategyFor(
      profile: profile,
      windowsHost: Platform.isWindows,
      diskSizeBytes: _selected?.sizeBytes ?? 0,
      isoLooksHybrid: iso != null && isoLooksLikeHybridDisk(iso),
    );
    return profile.layoutSummary(strategy);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF121A24), slate900, Color(0xFF0C1016)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 36),
                children: [
                  const _Header(),
                  const SizedBox(height: 24),
                  _IsoCard(
                    isoPath: _isoPath,
                    summary: _isoProfile?.summary,
                    layout: _writeLayoutLine,
                    mounted: _isoMount != null,
                    busy: _busy,
                    onBrowse: _pickIso,
                    onMount: _mountIso,
                    onUnmount: _unmountIso,
                  ),
                  const SizedBox(height: 16),
                  _UsbCard(
                    disks: _usbDisks,
                    selected: _selected,
                    loading: _loadingDisks,
                    busy: _busy,
                    showAdvanced: _showAdvanced,
                    onShowAdvanced: (value) {
                      setState(() => _showAdvanced = value);
                      _refreshDisks();
                    },
                    onChanged: (disk) => setState(() => _selected = disk),
                    onRefresh: _refreshDisks,
                  ),
                  const SizedBox(height: 16),
                  _WarningBanner(disk: _selected, profile: _isoProfile),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _busy ? null : _makeBootable,
                    icon: const Icon(Icons.usb),
                    label: const Text('Make bootable USB'),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => _writeCancel?.cancel(),
                      icon: const Icon(Icons.stop),
                      label: const Text('Cancel'),
                    ),
                  ],
                  if (_busy || _status != null) ...[
                    const SizedBox(height: 20),
                    _ProgressCard(
                      status: _status ?? '',
                      progress: _progress,
                      busy: _busy,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _ErrorCard(message: _error!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'USB ISO Mount',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
            color: ink,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Create a bootable USB from a Windows, Windows PE, or Linux live ISO.',
          style: TextStyle(color: muted, fontSize: 15, height: 1.4),
        ),
      ],
    );
  }
}

class _IsoCard extends StatelessWidget {
  const _IsoCard({
    required this.isoPath,
    required this.summary,
    required this.layout,
    required this.mounted,
    required this.busy,
    required this.onBrowse,
    required this.onMount,
    required this.onUnmount,
  });

  final String? isoPath;
  final String? summary;
  final String? layout;
  final bool mounted;
  final bool busy;
  final VoidCallback onBrowse;
  final VoidCallback onMount;
  final VoidCallback onUnmount;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ISO image',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Text(
              isoPath ?? 'No ISO selected',
              style: TextStyle(
                color: isoPath == null ? muted : ink,
                fontSize: 13,
              ),
            ),
            if (summary != null) ...[
              const SizedBox(height: 8),
              Text(
                summary!,
                style: const TextStyle(color: muted, fontSize: 13),
              ),
            ],
            if (layout != null) ...[
              const SizedBox(height: 6),
              Text(layout!, style: const TextStyle(color: muted, fontSize: 13)),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : onBrowse,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Browse…'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : (mounted ? onUnmount : onMount),
                  child: Text(mounted ? 'Unmount ISO' : 'Mount ISO'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UsbCard extends StatelessWidget {
  const _UsbCard({
    required this.disks,
    required this.selected,
    required this.loading,
    required this.busy,
    required this.showAdvanced,
    required this.onShowAdvanced,
    required this.onChanged,
    required this.onRefresh,
  });

  final List<UsbDisk> disks;
  final UsbDisk? selected;
  final bool loading;
  final bool busy;
  final bool showAdvanced;
  final ValueChanged<bool> onShowAdvanced;
  final ValueChanged<UsbDisk?> onChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'USB drive',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh drives',
                  onPressed: busy ? null : onRefresh,
                  icon: loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: showAdvanced,
              onChanged: busy
                  ? null
                  : (value) => onShowAdvanced(value ?? false),
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Show SD / Thunderbolt drives',
                style: TextStyle(fontSize: 13),
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 8),
            if (disks.isEmpty)
              const Text(
                'No removable USB drives found. Internal disks are hidden on purpose.',
                style: TextStyle(color: muted, height: 1.4),
              )
            else
              DropdownButtonFormField<UsbDisk>(
                key: ValueKey(disks.map((disk) => disk.id).join(',')),
                initialValue: selected,
                items: [
                  for (final disk in disks)
                    DropdownMenuItem(
                      value: disk,
                      child: Text(disk.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: busy ? null : onChanged,
              ),
          ],
        ),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.disk, this.profile});

  final UsbDisk? disk;
  final IsoProfile? profile;

  @override
  Widget build(BuildContext context) {
    final target = disk == null ? 'the selected USB drive' : disk!.label;
    final raw =
        profile?.kind == IsoKind.linuxHybrid ||
        profile?.kind == IsoKind.genericUefi;
    final message = raw
        ? 'This overwrites every partition on $target with the ISO image '
              '(typical for a Linux live USB). Use a spare stick.'
        : 'Make Bootable erases every file on $target. '
              'Use a spare USB stick, not a backup drive.';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: amberDim.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: amber.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: amber),
            const SizedBox(width: 10),
            Expanded(child: Text(message, style: const TextStyle(height: 1.4))),
          ],
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.status,
    required this.progress,
    required this.busy,
  });

  final String status;
  final double? progress;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(status, style: const TextStyle(height: 1.4)),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: busy && progress == null ? null : (progress ?? 0),
              color: amber,
              backgroundColor: slate700,
              minHeight: 8,
              borderRadius: BorderRadius.circular(8),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: danger.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: SelectableText(
          message,
          style: const TextStyle(color: Color(0xFFFFC9C2), height: 1.45),
        ),
      ),
    );
  }
}

class _EraseDialog extends StatefulWidget {
  const _EraseDialog({required this.disk, this.profile});

  final UsbDisk disk;
  final IsoProfile? profile;

  @override
  State<_EraseDialog> createState() => _EraseDialogState();
}

class _EraseDialogState extends State<_EraseDialog> {
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: slate800,
      title: const Text('Erase this USB drive?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.profile?.kind == IsoKind.linuxHybrid ||
                    widget.profile?.kind == IsoKind.genericUefi
                ? 'All data on ${widget.disk.label} will be permanently deleted, '
                      'then overwritten with the ISO image.'
                : 'All data on ${widget.disk.label} will be permanently deleted, '
                      'then replaced with a bootable installer.',
            style: const TextStyle(height: 1.4),
          ),
          if (widget.disk.isAdvancedTarget) ...[
            const SizedBox(height: 12),
            Text(
              'This is a ${widget.disk.busProtocol} drive, not a regular USB stick.',
              style: const TextStyle(height: 1.4, color: amber),
            ),
          ],
          const SizedBox(height: 16),
          CheckboxListTile(
            value: _understood,
            onChanged: (value) => setState(() => _understood = value ?? false),
            contentPadding: EdgeInsets.zero,
            title: const Text('I understand this cannot be undone'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _understood ? () => Navigator.pop(context, true) : null,
          child: const Text('Erase and write'),
        ),
      ],
    );
  }
}
