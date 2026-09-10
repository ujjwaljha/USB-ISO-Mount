# USB ISO Mount

Create a **bootable USB** from a Windows 10/11 (x64 or ARM), Windows PE, or Linux live ISO. Put **Windows and Ubuntu on the same stick** (a GRUB menu lets you pick which one to install). You can also **format a spare USB** as FAT32, exFAT, or NTFS without writing an ISO.

**Supported (CLI and GUI):** macOS and Windows.  
**Best-effort CLI only:** Linux (no Flutter desktop target).  
**Proven on hardware:** macOS Windows ISO file-copy (FAT32 + wimlib split), and macOS Linux/hybrid raw write via CLI (`authopen`). Windows writes are implemented but not yet confirmed on a real Windows PC.

**Making a bootable USB erases the target drive.** Only removable USB disks are listed by default. Internal disks, disk images, and the system boot disk are refused. SD and Thunderbolt drives are optional advanced targets.

## What you need

- A Windows, Windows PE, or hybrid Linux `.iso`
- A USB stick large enough for the image (8 GB or larger is typical)
- Administrator rights:
  - **macOS:** password prompt for erase (`diskutil`); **authopen** prompt for a raw Linux write
  - **Windows:** run the GUI (UAC) or an **Administrator** terminal for the CLI
  - **Linux (CLI):** `sudo`

Hybrid Linux ISOs often **cannot be mounted as a volume** (especially on macOS). The app reads ISO 9660 metadata and raw-writes the image instead.

### Extra tool for large Windows images

Windows installer files (`install.wim` / `install.esd`) are often larger than 4 GB. FAT32 cannot store a file that large.

- **Windows:** FAT32 boot partition (`WINBOOT`) plus an NTFS data partition (`WINSETUP`). The image is copied intact. DISM split is used only if the stick is too small for both partitions.
- **macOS (and Linux CLI):** the image is split. That requires [wimlib](https://wimlib.net/):

```bash
brew install wimlib          # macOS
sudo apt install wimtools    # Debian/Ubuntu (CLI only)
```

On Windows, splitting (fallback only) uses built-in `Dism.exe`. The GUI is compiled to request administrator rights.

## Desktop app

macOS and Windows only (`flutter run -d linux` is not set up).

```bash
cd app
flutter pub get
flutter run -d macos
# or: flutter run -d windows
```

1. Browse to one or more `.iso` files (add both Windows and Ubuntu for a multiboot stick)
2. Choose a USB drive (refresh if you just plugged it in)
3. Optionally **Identify ISOs** to inspect the type (Windows x64/ARM, WinPE, Linux). Hybrid Linux images typically fail to mount; a single Linux ISO is **raw-copied** instead
4. Click **Make bootable USB** (or **Make multiboot USB** when two or more images are selected) and confirm the erase warning
5. **Cancel** stops a write; if the disk was already erased it will not be bootable
6. After a multiboot stick exists, select it to use **Add ISO to this USB** (copy one more image without erasing) or **Refresh GRUB menu** (rebuild the menu from `/isos`)

To wipe a stick without an ISO, choose the USB drive, click **Format USB**, pick FAT32 / exFAT / NTFS and a volume name, then confirm. This erases the drive and leaves a normal data volume (not a bootable installer). NTFS is offered on Windows only.

After it finishes, boot the PC from the USB (UEFI). The machine you used only *creates* the stick.

## Command line

```bash
cd packages/usb_iso_cli
dart pub get

dart run usb_iso_cli list
dart run usb_iso_cli list --advanced
dart run usb_iso_cli mount --iso ~/Downloads/Win11.iso
dart run usb_iso_cli make --iso ~/Downloads/Win11.iso --disk disk4 --dry-run
dart run usb_iso_cli make --iso ~/Downloads/Win11.iso --iso ~/Downloads/ubuntu.iso --disk disk4 --dry-run
dart run usb_iso_cli make --iso ~/Downloads/Win11.iso --disk disk4 --yes
dart run usb_iso_cli add --iso ~/Downloads/fedora.iso --disk disk4 --dry-run
dart run usb_iso_cli refresh --disk disk4 --dry-run
dart run usb_iso_cli format --disk disk4 --fs exfat --label PHOTOS --dry-run
dart run usb_iso_cli format --disk disk4 --fs fat32 --yes
```

On Windows, use the disk number from `list` (for example `--disk 2`) and run the terminal as Administrator. An unelevated `make` or `format` (without `--dry-run`) exits with: `Run this terminal as Administrator before writing a USB.` Ctrl+C cancels a write the same way as the GUI Cancel button. On macOS, a raw Linux write waits for the **authopen** prompt before any bytes are written; progress then updates once per percent.

Linux CLI (best-effort, not first-class):

```bash
sudo dart run usb_iso_cli make --iso ~/Downloads/ubuntu.iso --disk sda --yes
```

| Command | Purpose |
| --- | --- |
| `list` | Show removable USB drives only |
| `list --advanced` | Also show SD / Thunderbolt drives |
| `mount --iso <file>` | Mount the ISO and print its detected type |
| `unmount --iso <file>` | Unmount the ISO |
| `make --iso <file> --disk <id>` | Erase the USB and write the image |
| `make --iso <win> --iso <ubuntu> --disk <id>` | Multiboot USB (GRUB menu) |
| `add --iso <file> --disk <id>` | Copy one more ISO onto an existing multiboot USB (no erase) |
| `add … --yes` | Skip the interactive `ADD` prompt |
| `refresh --disk <id>` | Rebuild the GRUB menu from `/isos` and Windows Setup already on the stick |
| `make … --dry-run` | Validate without writing |
| `make … --yes` | Skip the interactive `ERASE` prompt |
| `make … --advanced` | Allow an SD / Thunderbolt target |
| `format --disk <id>` | Erase the USB and format it (no ISO) |
| `format … --fs fat32\|exfat\|ntfs` | Filesystem (default `fat32`) |
| `format … --label NAME` | Volume name (FAT32 max 11 characters) |
| `format … --dry-run` | Validate without formatting |
| `format … --yes` | Skip the interactive `ERASE` prompt |

Without `--yes`, `make` and `format` ask you to type `ERASE`; `add` asks for `ADD`. Non-interactive sessions require `--yes`. macOS cannot format NTFS; use FAT32 or exFAT there.

## How the write works

The ISO is classified first (do **not** treat a hybrid MBR as Linux by itself — many Windows ISOs are hybrid too):

1. **Windows x64 / ARM / WinPE** — file-copy to a GPT FAT32 volume (`WINSETUP`). If `install.wim` or `install.esd` is over 4 GB:
   - Windows: FAT32 `WINBOOT` (EFI + `boot.wim`) + NTFS `WINSETUP` (the large installer image)
   - macOS / Linux: split the image to `install.swm` with wimlib
2. **Linux live ISO** — raw write of the ISO to the whole disk (`dd`-style). On macOS, `authopen` writes `/dev/rdiskN`. On Windows, the disk is taken **offline** for an exclusive write to `\\.\PhysicalDriveN`.
3. **Generic UEFI** — file-copy, or raw write if the ISO file itself looks like a hybrid disk image
4. **Multi-ISO (two or more `--iso` / Add ISO)** — GPT with a small FAT32 EFI partition (`EFIBOOT`, GRUB) and an exFAT data partition (`ISOBOOT`). One Windows installer is extracted to the data volume root so Setup finds `\\sources`. Linux live ISOs are copied to `/isos` and loop-booted (Ubuntu/casper, Debian Live, Fedora, Arch). At firmware boot you pick an entry from the GRUB menu. After the stick exists, `add --iso` copies another Linux ISO (or Windows, if the stick has none yet) without erasing, and `refresh` rebuilds the menu if you copied files by hand. Only one Windows installer is supported, because Windows Setup looks for `\\sources` at the volume root.

After a file-copy or raw write the volume is flushed and a light verify runs (EFI / installer size, or bytes written). A failed eject after a successful write is reported as a warning, not a failed write.

## Windows first-run checklist

Code is complete; run this on a real Windows 10/11 PC before treating Windows as proven:

1. Install Flutter/Dart. From `app/`: `flutter run -d windows` (accept the UAC prompt). From `packages/usb_iso_cli`: `dart pub get`.
2. Plug in a spare USB. `dart run usb_iso_cli list` should show it as a numeric id with `BusType` USB.
3. `dart run usb_iso_cli make --iso <Win11.iso> --disk <N> --dry-run` — expect `windowsDualPartition` and `FAT32 WINBOOT + NTFS WINSETUP`.
4. `dart run usb_iso_cli make --iso <ubuntu.iso> --disk <N> --dry-run` — expect `rawHybrid`. Mount-DiskImage may fail; that is normal.
5. In an **unelevated** terminal, `make --yes` (not `--dry-run`) must refuse with the Administrator message.
6. Elevated write: Win11 (FAT32+NTFS), then Ubuntu (raw). Confirm `file_picker` works in the GUI after UAC.
7. `make --iso <Win11.iso> --iso <ubuntu.iso> --disk <N> --dry-run` — expect `multiIso` and `FAT32 EFIBOOT (GRUB) + exFAT ISOBOOT`.

Helper script (optional):

```powershell
powershell -File scripts/windows_first_run.ps1
powershell -File scripts/windows_first_run.ps1 -Iso C:\iso\Win11.iso -Disk 2
```

## Repository layout

- [`app/`](app/) — Flutter desktop GUI (macOS and Windows)
- [`packages/usb_iso_core`](packages/usb_iso_core/) — USB detection, ISO mount, write pipeline (includes a GPLv3 GRUB EFI image under `lib/src/assets/grub/`)
- [`packages/usb_iso_cli`](packages/usb_iso_cli/) — `usb_iso` CLI (macOS, Windows; Linux best-effort)

## Safety

- Only USB / removable whole disks are offered by default
- The boot disk and internal disks are blocked
- SD and Thunderbolt drives require an extra opt-in
- The GUI requires a checkbox; the CLI requires `ERASE` or `--yes`
- `--dry-run` never erases a disk
- **Format USB** / `format` uses the same disk safety checks as a bootable write
- An ISO stored *on* the target USB is rejected so it is not deleted mid-write
- The USB is re-checked immediately before erase, and must be larger than the ISO
- Cancel after erase leaves a wiped stick

This project does not download Windows from Microsoft and does not create macOS installer USBs. Multiboot sticks are UEFI-only. After the first write you can add more Linux ISOs with `add` / **Add ISO to this USB**, or copy files into `/isos` and run `refresh` — the menu is not scanned automatically at boot the way Ventoy does.
