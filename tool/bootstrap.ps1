# Workspace bootstrap for Windows (workaround for melos CJK encoding bug).
# On Linux/CI, use `dart run melos bootstrap` instead.

$ErrorActionPreference = "Stop"
$flutter = "D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat"
$root = Split-Path -Parent $PSScriptRoot

$packages = @(
    "$root\packages\hibiki_core",
    "$root\packages\hibiki_dictionary",
    "$root\packages\hibiki_anki",
    "$root\packages\hibiki_audio",
    "$root\packages\hibiki_platform",
    "$root\hibiki"
)

foreach ($pkg in $packages) {
    $name = Split-Path -Leaf $pkg
    Write-Host "pub get: $name" -ForegroundColor Cyan
    Push-Location $pkg
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        throw "flutter pub get failed in $name"
    }
    Pop-Location
}

Write-Host "`nAll packages resolved." -ForegroundColor Green

# Apply pub-cache patches for the non-vendored packages (single source of truth:
# ci/apply-patches.sh). Requires bash (Git Bash) on PATH, same as CI.
Write-Host "Applying pub-cache patches..." -ForegroundColor Cyan
bash ci/apply-patches.sh
if ($LASTEXITCODE -ne 0) {
    throw "ci/apply-patches.sh failed."
}

Write-Host "`nBootstrap complete. Build with, e.g.:" -ForegroundColor Green
Write-Host "  cd hibiki; & '$flutter' build windows --release"
