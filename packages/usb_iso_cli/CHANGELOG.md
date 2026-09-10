# Changelog

## 1.3.0

- `make --iso Win11.iso --iso ubuntu.iso` writes a GRUB multiboot USB

## 1.2.0

- `format --disk` erases a USB and formats it as FAT32, exFAT, or NTFS

## 1.1.0

- Detect Windows ARM, WinPE, and Linux ISOs
- `list --advanced` and `make --advanced` for SD / Thunderbolt
- Linux disk ids (`sda`) and raw ISO writes

## 1.0.0

- Add `list`, `mount`, `unmount`, and `make` commands
- Require `ERASE` or `--yes` before wiping a USB drive
- Support `--dry-run` validation
