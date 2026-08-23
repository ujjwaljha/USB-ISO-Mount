# First-run checklist for USB ISO Mount on Windows.
# From an elevated PowerShell at the repo root:
#   powershell -File scripts/windows_first_run.ps1
# Optional:
#   powershell -File scripts/windows_first_run.ps1 -Iso C:\iso\Win11.iso -Disk 2
#   powershell -File scripts/windows_first_run.ps1 -Iso C:\iso\ubuntu.iso -Disk 2 -Write

param(
  [string]$Iso,
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
    dart run usb_iso_cli make --iso $Iso --disk $Disk --dry-run
    if ($Write) {
      if (-not (Test-Admin)) {
        Write-Host 'Refusing -Write: this shell is not Administrator.'
        exit 1
      }
      dart run usb_iso_cli make --iso $Iso --disk $Disk --yes
    }
  } else {
    Write-Host 'Pass -Iso and -Disk to run a dry-run against a real image.'
  }
} finally {
  Pop-Location
}
