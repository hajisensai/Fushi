# Installs (or removes) Fushi's patched Flutter Windows engine in the Flutter
# SDK's artifact cache.
#
# Why: HDR video is composed inside Flutter's own swap chain, which needs a
# half-float output path the stock engine does not have (see
# ci/patches/flutter-engine/<version>/README.md). The patched engine is a drop-in
# replacement of flutter_windows.dll (+ import library and the two public
# headers that gained an append-only API); everything else in the cache stays
# stock. `flutter build windows` copies these files into the app on every
# build, so overlaying the cache is all that is needed.
#
# Usage:
#   tool/engine_overlay.ps1 -ArtifactDir <dir>            # install
#   tool/engine_overlay.ps1 -Manifest <artifacts.json>    # download, verify, install
#   tool/engine_overlay.ps1 -Restore                      # back to stock
#
# <artifacts.json> (ci/patches/flutter-engine/<version>/artifacts.json) names
# the published zip: { "engineVersion", "patchVersion", "url", "sha256" }. The
# zip's SHA-256 must match before anything is extracted.
#
# <dir> holds one sub-directory per cache directory it replaces
# (windows-x64, windows-x64-profile, windows-x64-release), each with
# flutter_windows.dll, flutter_windows.dll.lib, flutter_windows.dll.exp,
# flutter_windows.dll.pdb (optional), flutter_windows.h and
# flutter_texture_registrar.h, plus engine-overlay.json at the top level.
param(
  [string]$ArtifactDir,
  [string]$Manifest,
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

function Expand-PublishedArtifacts {
  param([string]$ManifestPath)
  $published = Get-Content $ManifestPath -Raw | ConvertFrom-Json
  foreach ($key in @('engineVersion', 'patchVersion', 'url', 'sha256')) {
    if (-not $published.$key) { throw "$ManifestPath has no '$key'." }
  }
  $work = Join-Path ([IO.Path]::GetTempPath()) "fushi-engine-$($published.patchVersion)"
  $zip = "$work.zip"
  if (Test-Path $work) { Remove-Item $work -Recurse -Force }
  # Invoke-WebRequest honours HTTPS_PROXY on PowerShell 7 and the system proxy
  # on 5.1; progress rendering slows 5.1 downloads by an order of magnitude.
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $published.url -OutFile $zip -UseBasicParsing
  $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $published.sha256.ToLowerInvariant()) {
    Remove-Item $zip -Force
    throw "SHA-256 mismatch for $($published.url): expected $($published.sha256), got $actual."
  }
  Expand-Archive -Path $zip -DestinationPath $work -Force
  Remove-Item $zip -Force
  $inner = Get-Content (Join-Path $work 'engine-overlay.json') -Raw | ConvertFrom-Json
  if ($inner.engineVersion -ne $published.engineVersion -or
      $inner.patchVersion -ne $published.patchVersion) {
    throw "Archive metadata ($($inner.engineVersion)/$($inner.patchVersion)) does not match $ManifestPath."
  }
  return $work
}

if ($Manifest) { $ArtifactDir = Expand-PublishedArtifacts $Manifest }

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

  if (-not $ArtifactDir) { throw 'Pass -ArtifactDir, -Manifest or -Restore.' }
  # Not $manifest: PowerShell names are case-insensitive and -Manifest is a
  # [string] parameter, which would coerce the parsed object to a string.
  $overlayPath = Join-Path $ArtifactDir 'engine-overlay.json'
  $overlay = Get-Content $overlayPath -Raw | ConvertFrom-Json
  if ($overlay.engineVersion -ne $engineVersion) {
    # A patched engine built for another engine revision must never be mixed
    # with this SDK's Dart snapshot and other artifacts.
    throw "Overlay is for engine $($overlay.engineVersion) but the SDK at $root uses $engineVersion."
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
    $to = Join-Path $dir $f
    if (Test-Path $from) { Copy-Item $from $to -Force }
    elseif ($f -ne 'flutter_windows.dll.pdb') { throw "Overlay is missing $mode\$f" }
    # A pdb left over from the stock engine or an earlier overlay would not
    # match this dll; no symbols beats wrong symbols.
    elseif (Test-Path $to) { Remove-Item $to -Force }
  }
  Copy-Item $overlayPath (Join-Path $dir $marker) -Force
  "${mode}: installed patched engine $($overlay.patchVersion)"
}
