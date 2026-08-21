# USB ISO Mount

Create a **UEFI-bootable Windows 10 or 11 USB installer** on macOS or Windows. The same engine powers a Flutter desktop app and a command-line tool.

**Making a bootable USB erases the target drive.** Only removable USB disks are listed. Internal disks, disk images, and the system boot disk are refused.

## What you need

- A Windows 10 or 11 ISO (from Microsoft)
- A USB stick with enough space for the ISO (8 GB or larger is typical)
- Administrator rights (macOS password prompt, or “Run as administrator” on Windows)

### macOS extra tool

Windows installer files (`install.wim`) are often larger than 4 GB. FAT32 cannot store a file that large, so the app splits the WIM. That requires [wimlib](https://wimlib.net/):

```bash
brew install wimlib
```

### Windows extra tool

Splitting uses the built-in `Dism.exe`. The app is compiled to request administrator rights.

## Desktop app

```bash
cd app
flutter pub get
flutter run -d macos
# or: flutter run -d windows
```

1. Browse to a Windows `.iso`
2. Choose a USB drive (refresh if you just plugged it in)
3. Optionally **Mount ISO** to inspect it
4. Click **Make bootable USB** and confirm the erase warning

After it finishes, boot the PC from the USB (UEFI). The Mac or Windows machine you used only *creates* the stick; Windows is installed on the PC you boot.

## Command line

```bash
cd packages/usb_iso_cli
dart pub get

dart run usb_iso_cli list
dart run usb_iso_cli mount --iso ~/Downloads/Win11.iso
dart run usb_iso_cli make --iso ~/Downloads/Win11.iso --disk disk4 --dry-run
sudo dart run usb_iso_cli make --iso ~/Downloads/Win11.iso --disk disk4 --yes
```

On Windows, use the disk number from `list` (for example `--disk 2`) and run the terminal as Administrator.

| Command | Purpose |
| --- | --- |
| `list` | Show removable USB drives only |
| `mount --iso <file>` | Mount the ISO |
| `unmount --iso <file>` | Unmount the ISO |
| `make --iso <file> --disk <id>` | Erase the USB and write the installer |
| `make … --dry-run` | Validate without writing |
| `make … --yes` | Skip the interactive `ERASE` prompt |

Without `--yes`, `make` asks you to type `ERASE`. Non-interactive sessions require `--yes`.

## How the write works

1. Confirm the ISO has EFI boot files and `sources/install.wim` or `install.esd`
2. Erase the USB, create a GPT layout, format FAT32 (`WINSETUP`)
3. Copy the installer files
4. If `install.wim` is over 4 GB, split it to `install.swm` (wimlib on macOS, DISM on Windows)
5. Eject the USB

On Windows, FAT32 partitions are capped at 30 GB so the built-in formatter succeeds on large sticks. The Windows ISO still fits.

## Repository layout

- [`app/`](app/) — Flutter desktop GUI (macOS and Windows)
- [`packages/usb_iso_core/`](packages/usb_iso_core/) — USB detection, ISO mount, write pipeline
- [`packages/usb_iso_cli/`](packages/usb_iso_cli/) — `usb_iso` CLI

## Safety

- Only USB / removable whole disks are offered
- The boot disk and internal disks are blocked
- The GUI requires a checkbox; the CLI requires `ERASE` or `--yes`
- `--dry-run` never erases a disk
- An ISO stored *on* the target USB is rejected so it is not deleted mid-write
- The USB is re-checked immediately before erase, and must be larger than the ISO
- A failed eject after a successful write is reported as a warning, not a failed write

This project does not download Windows from Microsoft and does not create macOS installer USBs.
