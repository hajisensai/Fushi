# Installs (or removes) Fushi's patched Flutter Windows engine in the Flutter
# SDK's artifact cache.
#
# Why: HDR video is composed inside Flutter's own swap chain, which needs a
# half-float output path the stock engine does not have (see
# ci/patches/flutter-engine/README.md). The patched engine is a drop-in
# replacement of flutter_windows.dll (+ import library and the two public
# headers that gained an append-only API); everything else in the cache stays
# stock. `flutter build windows` copies these files into the app on every
# build, so overlaying the cache is all that is needed.
#
# Usage:
#   tool/engine_overlay.ps1 -ArtifactDir <dir>            # install
#   tool/engine_overlay.ps1 -Restore                      # back to stock
#
# <dir> holds one sub-directory per cache directory it replaces
# (windows-x64, windows-x64-profile, windows-x64-release), each with
# flutter_windows.dll, flutter_windows.dll.lib, flutter_windows.dll.exp,
# flutter_windows.dll.pdb (optional), flutter_windows.h and
# flutter_texture_registrar.h, plus engine-overlay.json at the top level.
param(
  [string]$ArtifactDir,
  [switch]$Restore,
  [string]$FlutterRoot,
  # Defaults to all three; a subset is for local iteration (e.g. only the
  # debug engine was rebuilt). Never mix modes: each cache directory must get
  # the engine built for its own runtime mode.
  [string[]]$Modes = @('windows-x64', 'windows-x64-profile', 'windows-x64-release')
)
$ErrorActionPreference = 'Stop'

function Resolve-FlutterRoot {
  param([string]$Explicit)
  if ($Explicit) { return (Resolve-Path $Explicit).Path }
  if ($env:FLUTTER_ROOT) { return (Resolve-Path $env:FLUTTER_ROOT).Path }
  $flutter = (Get-Command flutter -ErrorAction Stop).Source
  return (Resolve-Path (Join-Path (Split-Path $flutter) '..')).Path
}

$root = Resolve-FlutterRoot $FlutterRoot
$cache = Join-Path $root 'bin\cache\artifacts\engine'
$engineVersion = (Get-Content (Join-Path $root 'bin\internal\engine.version') -Raw).Trim()
$modes = $Modes
$files = @('flutter_windows.dll', 'flutter_windows.dll.lib', 'flutter_windows.dll.exp',
           'flutter_windows.dll.pdb', 'flutter_windows.h', 'flutter_texture_registrar.h')
$marker = 'fushi-engine-overlay.json'

foreach ($mode in $modes) {
  $dir = Join-Path $cache $mode
  if (-not (Test-Path $dir)) {
    throw "Flutter cache $dir is missing; run 'flutter precache --windows' first."
  }
  $backup = Join-Path $dir '.stock-backup'

  if ($Restore) {
    if (-not (Test-Path $backup)) { "${mode}: already stock"; continue }
    foreach ($f in $files) {
      $saved = Join-Path $backup $f
      if (Test-Path $saved) { Copy-Item $saved (Join-Path $dir $f) -Force }
    }
    Remove-Item $backup -Recurse -Force
    Remove-Item (Join-Path $dir $marker) -ErrorAction SilentlyContinue
    "${mode}: restored stock engine"
    continue
  }

  if (-not $ArtifactDir) { throw 'Pass -ArtifactDir or -Restore.' }
  $manifestPath = Join-Path $ArtifactDir 'engine-overlay.json'
  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  if ($manifest.engineVersion -ne $engineVersion) {
    # A patched engine built for another engine revision must never be mixed
    # with this SDK's Dart snapshot and other artifacts.
    throw "Overlay is for engine $($manifest.engineVersion) but the SDK at $root uses $engineVersion."
  }
  $source = Join-Path $ArtifactDir $mode
  if (-not (Test-Path $backup)) {
    New-Item -ItemType Directory -Force $backup | Out-Null
    foreach ($f in $files) {
      $orig = Join-Path $dir $f
      if (Test-Path $orig) { Copy-Item $orig (Join-Path $backup $f) }
    }
  }
  foreach ($f in $files) {
    $from = Join-Path $source $f
    if (Test-Path $from) { Copy-Item $from (Join-Path $dir $f) -Force }
    elseif ($f -ne 'flutter_windows.dll.pdb') { throw "Overlay is missing $mode\$f" }
  }
  Copy-Item $manifestPath (Join-Path $dir $marker) -Force
  "${mode}: installed patched engine $($manifest.patchVersion)"
}
