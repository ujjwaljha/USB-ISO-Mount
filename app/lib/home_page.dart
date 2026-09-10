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
  final _formatter = DiskFormatter();
  final _inspector = IsoInspector();

  List<UsbDisk> _usbDisks = [];
  UsbDisk? _selected;
  final List<_SelectedIso> _isos = [];
  String? _error;
  String? _status;
  double? _progress;
  bool _busy = false;
  bool _loadingDisks = true;
  bool _showAdvanced = false;
  CancellationToken? _opCancel;

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
      allowMultiple: true,
      dialogTitle: 'Choose ISO images',
    );
    final paths = [
      for (final file in result?.files ?? const <PlatformFile>[])
        if (file.path != null) file.path!,
    ];
    if (paths.isEmpty) {
      return;
    }
    await _addIsoPaths(paths);
  }

  Future<void> _addIsoPaths(List<String> paths) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Identifying ISO images…';
    });
    try {
      for (final path in paths) {
        if (_isos.any((iso) => pEquals(iso.path, path))) {
          continue;
        }
        final item = _SelectedIso(path: path);
        try {
          final mount = await _mounter.mount(path);
          item.mount = mount;
          item.profile = _inspector.inspectMounted(mount.mountPath);
        } on UsbIsoException catch (error) {
          try {
            item.profile = _inspector.inspectIsoFile(path);
            item.mountError = error.message;
          } on UsbIsoException catch (fileError) {
            item.mountError = fileError.message;
          }
        }
        _isos.add(item);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _status = _isos.length > 1
            ? '${_isos.length} ISO images selected. The USB will get a boot menu.'
            : _isos.isEmpty
            ? null
            : 'ISO selected.';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _removeIso(_SelectedIso item) async {
    if (item.mount != null) {
      try {
        await _mounter.unmount(item.mount!);
      } on UsbIsoException {
        // Best-effort when removing an ISO.
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isos.remove(item);
      _error = null;
    });
  }

  bool pEquals(String a, String b) {
    return File(a).absolute.path == File(b).absolute.path;
  }

  Future<void> _unmountQuietly() async {
    for (final iso in _isos) {
      final mount = iso.mount;
      if (mount == null) {
        continue;
      }
      try {
        await _mounter.unmount(mount);
      } on UsbIsoException {
        // Best-effort when switching ISOs.
      }
      iso.mount = null;
    }
  }

  Future<void> _mountIso() async {
    if (_isos.isEmpty) {
      setState(() => _error = 'Choose an ISO first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Mounting ISO…';
    });
    try {
      for (final item in _isos) {
        if (item.mount != null) {
          continue;
        }
        try {
          final mount = await _mounter.mount(item.path);
          item.mount = mount;
          item.profile = _inspector.inspectMounted(mount.mountPath);
          item.mountError = null;
        } on UsbIsoException catch (error) {
          try {
            item.profile = _inspector.inspectIsoFile(item.path);
            item.mountError = error.message;
          } on UsbIsoException {
            item.mountError = error.message;
          }
        }
      }
      if (!mounted) {
        return;
      }
      final unknown = _isos.where(
        (iso) => iso.profile?.kind == IsoKind.unknown,
      );
      setState(() {
        _status = _isos.length > 1
            ? 'Identified ${_isos.length} ISO images.'
            : _isos.first.mount != null
            ? 'Mounted at ${_isos.first.mount!.mountPath}'
            : _isos.first.profile?.kind == IsoKind.linuxHybrid
            ? 'Could not mount as a volume (typical for hybrid Linux ISOs). '
                  'A single-ISO write will raw-copy the image.'
            : 'Could not mount as a volume.';
        _error = unknown.isEmpty
            ? null
            : unknown.first.profile?.unsupportedMessage;
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _unmountIso() async {
    setState(() => _busy = true);
    try {
      await _unmountQuietly();
      if (!mounted) {
        return;
      }
      setState(() => _status = 'ISO unmounted.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _makeBootable() async {
    final disk = _selected;
    if (_isos.isEmpty) {
      setState(() => _error = 'Choose an ISO first.');
      return;
    }
    if (disk == null) {
      setState(() => _error = 'Plug in a USB drive and refresh the list.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _EraseDialog(
        disk: disk,
        profile: _isos.length == 1 ? _isos.first.profile : null,
        multibootTitles: _isos.length > 1
            ? [for (final iso in _isos) iso.displayLabel]
            : const [],
      ),
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
      _opCancel = token;
    });

    try {
      final stream = _isos.length == 1
          ? _writer.write(
              WriteRequest(
                isoPath: _isos.first.path,
                disk: disk,
                confirmed: true,
                existingMount: _isos.first.mount,
                allowAdvancedTargets: _showAdvanced,
                cancellation: token,
              ),
            )
          : _writer.writeMulti(
              MultiWriteRequest(
                isoPaths: [for (final iso in _isos) iso.path],
                disk: disk,
                confirmed: true,
                existingMounts: {
                  for (final iso in _isos)
                    if (iso.mount != null) iso.path: iso.mount!,
                },
                allowAdvancedTargets: _showAdvanced,
                cancellation: token,
              ),
            );
      await for (final event in stream) {
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
          _opCancel = null;
        });
      }
    }
  }

  Future<void> _formatUsb() async {
    final disk = _selected;
    if (disk == null) {
      setState(() => _error = 'Plug in a USB drive and refresh the list.');
      return;
    }

    final choice = await showDialog<_FormatChoice>(
      context: context,
      builder: (context) => _FormatDialog(disk: disk),
    );
    if (choice == null || !mounted) {
      return;
    }

    final token = CancellationToken();
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
      _status = 'Starting…';
      _opCancel = token;
    });

    try {
      await for (final event in _formatter.format(
        FormatRequest(
          disk: disk,
          filesystem: choice.filesystem,
          volumeLabel: choice.label,
          confirmed: true,
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
          _opCancel = null;
        });
      }
    }
  }

  String? get _writeLayoutLine {
    if (_isos.length > 1) {
      return 'Layout: GRUB menu, FAT32 EFIBOOT + exFAT ISOBOOT '
          '(Windows Setup at the volume root, Linux ISOs in /isos)';
    }
    if (_isos.isEmpty || _isos.first.profile == null) {
      return null;
    }
    final profile = _isos.first.profile!;
    final strategy = LayoutChooser.strategyFor(
      profile: profile,
      windowsHost: Platform.isWindows,
      diskSizeBytes: _selected?.sizeBytes ?? 0,
      isoLooksHybrid: isoLooksLikeHybridDisk(_isos.first.path),
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
                    isos: _isos,
                    layout: _writeLayoutLine,
                    busy: _busy,
                    onBrowse: _pickIso,
                    onMount: _mountIso,
                    onUnmount: _unmountIso,
                    onRemove: _removeIso,
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
                  _WarningBanner(
                    disk: _selected,
                    profile: _isos.length == 1 ? _isos.first.profile : null,
                    multiboot: _isos.length > 1,
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _makeBootable,
                        icon: const Icon(Icons.usb),
                        label: Text(
                          _isos.length > 1
                              ? 'Make multiboot USB'
                              : 'Make bootable USB',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _formatUsb,
                        icon: const Icon(Icons.sd_card),
                        label: const Text('Format USB'),
                      ),
                    ],
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => _opCancel?.cancel(),
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
          'Create a bootable USB from a Windows, Windows PE, or Linux live ISO. '
          'Add both Windows and Ubuntu to get a GRUB menu on the same stick, '
          'or format a spare drive as FAT32, exFAT, or NTFS.',
          style: TextStyle(color: muted, fontSize: 15, height: 1.4),
        ),
      ],
    );
  }
}

class _SelectedIso {
  _SelectedIso({required this.path});

  final String path;
  IsoProfile? profile;
  IsoMount? mount;
  String? mountError;

  String get displayLabel {
    final name = path.split(RegExp(r'[/\\]')).last;
    final kind = profile?.kindLabel;
    return kind == null ? name : '$name — $kind';
  }
}

class _IsoCard extends StatelessWidget {
  const _IsoCard({
    required this.isos,
    required this.layout,
    required this.busy,
    required this.onBrowse,
    required this.onMount,
    required this.onUnmount,
    required this.onRemove,
  });

  final List<_SelectedIso> isos;
  final String? layout;
  final bool busy;
  final VoidCallback onBrowse;
  final VoidCallback onMount;
  final VoidCallback onUnmount;
  final ValueChanged<_SelectedIso> onRemove;

  @override
  Widget build(BuildContext context) {
    final mounted = isos.any((iso) => iso.mount != null);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ISO images',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add one ISO for a single installer, or Windows plus Ubuntu '
              '(and other Linux live images) for a boot menu on the same USB.',
              style: TextStyle(color: muted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            if (isos.isEmpty)
              const Text(
                'No ISO selected',
                style: TextStyle(color: muted, fontSize: 13),
              )
            else
              for (final iso in isos) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    iso.displayLabel,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: iso.profile == null
                      ? (iso.mountError == null
                            ? null
                            : Text(
                                iso.mountError!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: muted,
                                ),
                              ))
                      : Text(
                          iso.profile!.summary,
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                  trailing: IconButton(
                    tooltip: 'Remove ISO',
                    onPressed: busy ? null : () => onRemove(iso),
                    icon: const Icon(Icons.close, size: 18),
                  ),
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
                  label: Text(isos.isEmpty ? 'Browse…' : 'Add ISO…'),
                ),
                OutlinedButton(
                  onPressed: busy || isos.isEmpty
                      ? null
                      : (mounted ? onUnmount : onMount),
                  child: Text(mounted ? 'Unmount ISO' : 'Identify ISOs'),
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
  const _WarningBanner({
    required this.disk,
    this.profile,
    this.multiboot = false,
  });

  final UsbDisk? disk;
  final IsoProfile? profile;
  final bool multiboot;

  @override
  Widget build(BuildContext context) {
    final target = disk == null ? 'the selected USB drive' : disk!.label;
    final raw =
        !multiboot &&
        (profile?.kind == IsoKind.linuxHybrid ||
            profile?.kind == IsoKind.genericUefi);
    final message = multiboot
        ? 'This erases every partition on $target, then installs a GRUB menu '
              'so you can choose Windows Setup or a Linux live ISO at boot. '
              'Use a spare stick.'
        : raw
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
  const _EraseDialog({
    required this.disk,
    this.profile,
    this.multibootTitles = const [],
  });

  final UsbDisk disk;
  final IsoProfile? profile;
  final List<String> multibootTitles;

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
            widget.multibootTitles.isNotEmpty
                ? 'All data on ${widget.disk.label} will be permanently deleted, '
                      'then replaced with a GRUB boot menu for:\n'
                      '${widget.multibootTitles.map((title) => '• $title').join('\n')}'
                : widget.profile?.kind == IsoKind.linuxHybrid ||
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

class _FormatChoice {
  const _FormatChoice({required this.filesystem, required this.label});

  final VolumeFilesystem filesystem;
  final String label;
}

class _FormatDialog extends StatefulWidget {
  const _FormatDialog({required this.disk});

  final UsbDisk disk;

  @override
  State<_FormatDialog> createState() => _FormatDialogState();
}

class _FormatDialogState extends State<_FormatDialog> {
  late final TextEditingController _label;
  VolumeFilesystem _filesystem = VolumeFilesystem.fat32;
  bool _understood = false;

  List<VolumeFilesystem> get _options {
    return [
      VolumeFilesystem.fat32,
      VolumeFilesystem.exfat,
      if (!Platform.isMacOS) VolumeFilesystem.ntfs,
    ];
  }

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: defaultVolumeLabel);
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: slate800,
      title: const Text('Format this USB drive?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'All data on ${widget.disk.label} will be permanently deleted. '
              'This does not install an operating system — it only formats the stick.',
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
            DropdownButtonFormField<VolumeFilesystem>(
              initialValue: _filesystem,
              items: [
                for (final fs in _options)
                  DropdownMenuItem(value: fs, child: Text(fs.displayName)),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() => _filesystem = value);
              },
              decoration: const InputDecoration(labelText: 'Filesystem'),
            ),
            const SizedBox(height: 8),
            Text(
              _filesystem == VolumeFilesystem.fat32
                  ? 'FAT32 works on the most devices. Files cannot be 4 GB or larger.'
                  : _filesystem == VolumeFilesystem.exfat
                  ? 'exFAT supports large files and is a good default for data sticks.'
                  : 'NTFS is native to Windows. macOS and some cameras may be read-only.',
              style: const TextStyle(color: muted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              decoration: InputDecoration(
                labelText: 'Volume name',
                helperText:
                    'Up to ${_filesystem.maxLabelLength} characters for ${_filesystem.displayName}.',
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _understood,
              onChanged: (value) =>
                  setState(() => _understood = value ?? false),
              contentPadding: EdgeInsets.zero,
              title: const Text('I understand this cannot be undone'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _understood
              ? () => Navigator.pop(
                  context,
                  _FormatChoice(filesystem: _filesystem, label: _label.text),
                )
              : null,
          child: const Text('Erase and format'),
        ),
      ],
    );
  }
}
