#!/usr/bin/env bash
# Rebuild the standalone GRUB EFI image bundled for multiboot USBs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/packages/usb_iso_core/lib/src/assets/grub/BOOTX64.EFI"

if ! command -v grub-mkimage >/dev/null; then
  echo "grub-mkimage not found. Install grub-common and grub-efi-amd64-bin." >&2
  exit 1
fi

embed="$(mktemp)"
trap 'rm -f "$embed"' EXIT
cat > "$embed" <<'EOF'
search --file --set=root /boot/grub/grub.cfg
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

grub-mkimage -O x86_64-efi -o "$OUT" -p /boot/grub -c "$embed" \
  fat exfat ntfs iso9660 udf ext2 \
  part_gpt part_msdos \
  loopback linux \
  search search_fs_file search_fs_uuid search_label \
  configfile normal echo ls cat test true \
  chain boot reboot halt efifwsetup \
  efi_gop efi_uga all_video video video_fb gfxterm \
  regexp probe sleep gzio xzio \
  extcmd minicmd

echo "Wrote $OUT ($(wc -c < "$OUT") bytes)"
