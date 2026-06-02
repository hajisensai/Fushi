# Launch the Hibiki Flutter app in debug mode (PowerShell).
#
# Usage (from the repo root):
#   .\run.ps1                    # run on Windows desktop (default)
#   .\run.ps1 emulator-5554      # run on a specific device id (see: flutter devices)
#   .\run.ps1 windows --profile  # extra args after the device pass through to `flutter run`
#
# Flutter SDK resolution: $env:FLUTTER_BIN, then the known local SDK, then PATH.
param(
  [string]$Device = "windows",
  [Parameter(ValueFromRemainingArguments = $true)] $Rest
)
$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$AppDir = Join-Path $Root "hibiki"

$Flutter = $env:FLUTTER_BIN
if (-not $Flutter) {
  $local = "D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat"
  if (Test-Path $local) {
    $Flutter = $local
  } elseif (Get-Command flutter -ErrorAction SilentlyContinue) {
    $Flutter = "flutter"
  } else {
    Write-Error "flutter not found. Set FLUTTER_BIN to your flutter(.bat) path."
    exit 1
  }
}

Push-Location $AppDir
try {
  Write-Host "==> $Flutter pub get"
  & $Flutter pub get
  Write-Host "==> $Flutter run -d $Device $Rest"
  & $Flutter run -d $Device @Rest
} finally {
  Pop-Location
}
