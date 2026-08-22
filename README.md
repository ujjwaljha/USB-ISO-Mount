# USB ISO Mount

Create a **bootable USB** from a Windows 10/11 (x64 or ARM), Windows PE, or Linux live ISO on **macOS, Windows, or Linux**. The same engine powers a Flutter desktop app and a command-line tool.

**Making a bootable USB erases the target drive.** Only removable USB disks are listed by default. Internal disks, disk images, and the system boot disk are refused. SD and Thunderbolt drives are optional advanced targets.

## What you need

- A Windows, Windows PE, or hybrid Linux `.iso`
- A USB stick large enough for the image (8 GB or larger is typical)
- Administrator rights (macOS password prompt, “Run as administrator” on Windows, or `sudo` on Linux)

### Extra tool for large Windows images

Windows installer files (`install.wim` / `install.esd`) are often larger than 4 GB. FAT32 cannot store a file that large.

- **Windows:** the app uses a FAT32 boot partition plus an NTFS data partition, so the image is copied intact.
- **macOS and Linux:** the image is split. That requires [wimlib](https://wimlib.net/):

```bash
brew install wimlib          # macOS
sudo apt install wimtools    # Debian/Ubuntu
```

On Windows, splitting (fallback only) uses built-in `Dism.exe`. The app is compiled to request administrator rights.

## Desktop app

```bash
cd app
flutter pub get
flutter run -d macos
# or: flutter run -d windows
```

1. Browse to an `.iso`
2. Choose a USB drive (refresh if you just plugged it in)
3. Optionally **Mount ISO** to inspect the type (Windows x64/ARM, WinPE, Linux)
4. Click **Make bootable USB** and confirm the erase warning
5. **Cancel** stops a write; if the disk was already erased it will not be bootable

After it finishes, boot the PC from the USB (UEFI). The machine you used only *creates* the stick.

## Command line

```bash
cd packages/usb_iso_cli
dart pub get

dart run usb_iso_cli list
dart run usb_iso_cli list --advanced
dart run usb_iso_cli mount --iso ~/Downloads/Win11.iso
dart run usb_iso_cli make --iso ~/Downloads/Win11.iso --disk disk4 --dry-run
sudo dart run usb_iso_cli make --iso ~/Downloads/Win11.iso --disk disk4 --yes
sudo dart run usb_iso_cli make --iso ~/Downloads/ubuntu.iso --disk sda --yes
```

On Windows, use the disk number from `list` (for example `--disk 2`) and run the terminal as Administrator.

| Command | Purpose |
| --- | --- |
| `list` | Show removable USB drives only |
| `list --advanced` | Also show SD / Thunderbolt drives |
| `mount --iso <file>` | Mount the ISO and print its detected type |
| `unmount --iso <file>` | Unmount the ISO |
| `make --iso <file> --disk <id>` | Erase the USB and write the image |
| `make … --dry-run` | Validate without writing |
| `make … --yes` | Skip the interactive `ERASE` prompt |
| `make … --advanced` | Allow an SD / Thunderbolt target |

Without `--yes`, `make` asks you to type `ERASE`. Non-interactive sessions require `--yes`.

## How the write works

The ISO is classified first (do **not** treat a hybrid MBR as Linux by itself — many Windows ISOs are hybrid too):

1. **Windows x64 / ARM / WinPE** — file-copy to a GPT FAT32 volume (`WINSETUP`). If `install.wim` or `install.esd` is over 4 GB:
   - Windows: FAT32 `WINBOOT` (EFI + `boot.wim`) + NTFS `WINSETUP` (the large installer image)
   - macOS / Linux: split the image to `install.swm` with wimlib
2. **Linux live ISO** — raw write of the ISO to the whole disk (`dd`-style). On macOS these hybrid images often cannot be mounted as a volume; the app reads ISO 9660 metadata instead.
3. **Generic UEFI** — file-copy, or raw write if the ISO file itself looks like a hybrid disk image
4. **Multi-ISO** — reserved; not implemented (no Ventoy)

After a file-copy or raw write the volume is flushed and a light verify runs (EFI / installer size, or bytes written). A failed eject after a successful write is reported as a warning, not a failed write.

## Repository layout

- [`app/`](app/) — Flutter desktop GUI (macOS and Windows)
- [`packages/usb_iso_core/`](packages/usb_iso_core/) — USB detection, ISO mount, write pipeline
- [`packages/usb_iso_cli/`](packages/usb_iso_cli/) — `usb_iso` CLI

## Safety

- Only USB / removable whole disks are offered by default
- The boot disk and internal disks are blocked
- SD and Thunderbolt drives require an extra opt-in
- The GUI requires a checkbox; the CLI requires `ERASE` or `--yes`
- `--dry-run` never erases a disk
- An ISO stored *on* the target USB is rejected so it is not deleted mid-write
- The USB is re-checked immediately before erase, and must be larger than the ISO
- Cancel after erase leaves a wiped stick

This project does not download Windows from Microsoft and does not create macOS installer USBs. Multi-ISO / Ventoy-style sticks are not implemented.
