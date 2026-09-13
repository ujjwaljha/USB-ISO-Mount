# Bundled GRUB EFI (BOOTX64.EFI)

Standalone GRUB 2 EFI image used as the USB boot menu on multi-ISO sticks.
This is **not** a Windows or Linux installer.

- **Upstream:** [GNU GRUB](https://www.gnu.org/software/grub/)
- **License:** [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html)
- **Build:** `grub-mkimage -O x86_64-efi` from Ubuntu `grub-efi-amd64-bin` 2.12
- **Prefix:** `/boot/grub` on the FAT32 EFI partition (`EFIBOOT`)
- **Filesystems:** FAT, exFAT, NTFS, ISO 9660 (so Linux ISOs and Windows
  setup files can live on the exFAT data partition)

Rebuild with `scripts/build_grub_efi.sh`. GRUB source is available from GNU
or from the `grub2` / `grub-efi-amd64-bin` package of any current distro.
