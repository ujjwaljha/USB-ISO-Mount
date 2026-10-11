# First-run checklist for USB ISO Mount on Windows.
# From an elevated PowerShell at the repo root:
#   powershell -File scripts/windows_first_run.ps1
# Optional:
#   powershell -File scripts/windows_first_run.ps1 -Iso C:\iso\Win11.iso -Disk 2
#   powershell -File scripts/windows_first_run.ps1 -Iso C:\iso\ubuntu.iso -Disk 2 -Write
#   powershell -File scripts/windows_first_run.ps1 -Iso C:\iso\Win11.iso -SecondIso C:\iso\ubuntu.iso -Disk 2
#     (multiboot dry-run, then `add` and `refresh` dry-runs against the same disk)

param(
  [string]$Iso,
  [string]$SecondIso,
  [string]$Disk,
  [switch]$Write
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $repo 'packages\usb_iso_cli'

function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host 'USB ISO Mount — Windows first-run checklist'
Write-Host "Repository: $repo"
Write-Host "Administrator: $(Test-Admin)"
Write-Host ''
Write-Host 'Manual checks:'
Write-Host '  1. dart run usb_iso_cli list'
Write-Host '  2. dart run usb_iso_cli make --iso <Win11.iso> --disk <N> --dry-run'
Write-Host '     Expect: Strategy windowsDualPartition, FAT32 WINBOOT + NTFS WINSETUP'
Write-Host '  3. dart run usb_iso_cli make --iso <ubuntu.iso> --disk <N> --dry-run'
Write-Host '     Expect: Strategy rawHybrid (Mount-DiskImage may fail; raw-write is used)'
Write-Host '  4. Elevated write: Win11 (FAT32+NTFS), then Ubuntu (raw ISO)'
Write-Host '  5. Unelevated make --yes must print:'
Write-Host '     Run this terminal as Administrator before writing a USB.'
Write-Host '  6. flutter run -d windows  (UAC prompt expected)'
Write-Host '  7. dart run usb_iso_cli make --iso <Win11.iso> --iso <ubuntu.iso> --disk <N> --dry-run'
Write-Host '     Expect: multiIso, FAT32 EFIBOOT (GRUB) + exFAT ISOBOOT'
Write-Host '  8. After a multiboot write: add --iso <fedora.iso> --disk <N> --dry-run'
Write-Host '     Expect: no erase; then refresh --disk <N> --dry-run'
Write-Host '  9. Re-plug the stick and repeat 8 elevated: EFIBOOT gets a drive letter assigned'
Write-Host ''

if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
  Write-Host 'dart is not on PATH. Install the Dart SDK or Flutter, then re-run.'
  exit 2
}

Push-Location $cli
try {
  dart pub get
  dart run usb_iso_cli list
  if ($Iso -and $Disk) {
    if ($SecondIso) {
      # Step 7: multiboot plan. Steps 8/9 only succeed once the stick has
      # been written as multiboot, so their failure here is informational.
      dart run usb_iso_cli make --iso $Iso --iso $SecondIso --disk $Disk --dry-run
      Write-Host ''
      Write-Host 'Checking add/refresh against the current contents of the disk (expected to fail on a stick that is not multiboot yet):'
      $previousPreference = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        dart run usb_iso_cli add --iso $SecondIso --disk $Disk --dry-run
        dart run usb_iso_cli refresh --disk $Disk --dry-run
      } finally {
        $ErrorActionPreference = $previousPreference
      }
    } else {
      dart run usb_iso_cli make --iso $Iso --disk $Disk --dry-run
    }
    if ($Write) {
      if (-not (Test-Admin)) {
        Write-Host 'Refusing -Write: this shell is not Administrator.'
        exit 1
      }
      if ($SecondIso) {
        dart run usb_iso_cli make --iso $Iso --iso $SecondIso --disk $Disk --yes
      } else {
        dart run usb_iso_cli make --iso $Iso --disk $Disk --yes
      }
    }
  } else {
    Write-Host 'Pass -Iso and -Disk to run a dry-run against a real image (add -SecondIso for the multiboot plan).'
  }
} finally {
  Pop-Location
}
