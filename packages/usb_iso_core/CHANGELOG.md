# Changelog

## 1.2.0

- Standalone USB format (FAT32, exFAT, NTFS) without writing an ISO

## 1.1.0

- Classify Windows x64/ARM, WinPE, and Linux live ISOs
- Dual FAT32+NTFS layout on Windows for installer files over 4 GB
- Split oversized WIM and ESD images on macOS and Linux
- Raw-write hybrid Linux ISOs
- Cancel, flush, and light verify after write
- Optional SD / Thunderbolt targets
- Linux host support

## 1.0.0

- List removable USB disks on macOS and Windows
- Mount Windows installer ISOs
- Write a FAT32 UEFI bootable USB, splitting oversized `install.wim` files
