param(
  [string]$Platform = "all",
  [string]$Only = "all",
  [string]$ReportDir = "",
  [switch]$DryRun,
  [switch]$SkipFixtures
)
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$AppDir = Join-Path $Root "hibiki"
$Dart = "D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat"
if (-not (Test-Path $Dart)) {
  $Dart = "dart"
}

$argsList = @(
  "run",
  "tool/comprehensive_test_runner.dart",
  "--platform=$Platform",
  "--only=$Only"
)
if ($DryRun) {
  $argsList += "--dry-run"
}
if ($ReportDir) {
  $argsList += "--report-dir=$ReportDir"
}

Push-Location $AppDir
try {
  if (-not $SkipFixtures) {
    & $Dart run tool/generate_test_fixtures.dart --output=../.codex-test/fixtures
    if ($LASTEXITCODE -ne 0) {
      exit $LASTEXITCODE
    }
  }
  & $Dart @argsList
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
