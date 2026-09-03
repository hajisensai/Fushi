<#
.SYNOPSIS
  Install the galgame helper straight into a Windows app bundle as plain files.

.DESCRIPTION
  Extracts the two per-architecture helper archives produced by
  build_distribution.ps1 into <Bundle>\voice_hook\<arch>\, which is exactly where
  the app looks for them at runtime (GalgameHelperInstaller._archDir /
  GalHookSessionController.defaultInjectorResolver).

  Why plain files instead of shipping the .zip next to the exe (BUG-1449):
  the zip + sha256 sidecar + runtime-install machinery was designed back when the
  helper was DOWNLOADED over the network. Once it started riding along inside the
  Windows package (BUG-1196) that machinery kept a second copy of the helper on
  disk -- an extracted directory that has to be kept in sync with the app. Keeping
  it in sync is precisely what broke: a stale extracted copy from an older app
  version kept getting injected, built an old-contract shared memory segment, and
  the current app reported protocol_mismatch (BUG-1448).

  Extracting at BUILD time removes the second copy entirely. The helper and the
  app are produced by one build and land through one installer, so they cannot
  drift. hibiki.iss packages via `Source: "{#SourceDir}\*"` with recursesubdirs,
  so this directory rides into the installer with no installer change at all.

  Integrity is not weakened, only moved earlier: the archive is verified against
  its sha256 sidecar HERE, at build time, and refuses to publish on mismatch. The
  old runtime check defended against a tampered *download*; for files that sit in
  the app directory it defended against an attacker who, by definition, could
  equally well replace hibiki.exe itself.

.PARAMETER BundleDirectory
  The built Flutter Windows bundle (the directory containing hibiki.exe).

.PARAMETER DistDirectory
  Where build_distribution.ps1 wrote its archives. Defaults to the repo's
  native/galgame_hook/dist.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $BundleDirectory,

  [string] $DistDirectory,

  # The helper distribution has not been produced in this workspace yet.  That is
  # normal for a UI-only developer build, and it is also what every CI *release*
  # build sees: release-desktop.yml runs `flutter build windows --release` before
  # it runs build_distribution.ps1, so the dist directory is necessarily empty at
  # install time.  The fail-closed call is the later workflow step, which passes
  # no Allow* switch at all -- that one, not this one, gates the shipped package.
  #
  # Whatever the reason, the bundle must not keep plain helper files from an older
  # build: injecting a stale DLL is worse than reporting the helper as unavailable
  # (BUG-1881).
  [switch] $AllowMissingDistribution,

  # The distribution is complete and intact, but was built from a *different*
  # checkout than the one being compiled now.  Tolerated for local Debug builds
  # (the stale helper is disabled and the build continues); refused for
  # Profile/Release, where it means a release artifact would be assembled from two
  # different source trees.  Gated per configuration in fushi/windows/CMakeLists.txt.
  [switch] $AllowStaleDistribution
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$fingerprintScript = Join-Path $PSScriptRoot 'helper_source_fingerprint.ps1'
if (-not (Test-Path -LiteralPath $fingerprintScript -PathType Leaf)) {
  throw "Helper source fingerprint script is missing: $fingerprintScript"
}
. $fingerprintScript

# --- Making a stale helper unloadable (BUG-1880) -----------------------------
#
# Why this is not `Remove-Item -Recurse -Force`: the files under voice_hook\<arch>\
# are exactly the ones that get injected into the user's game and are then held by
# the host process until it exits (fushi_voice_hook.dll, LunaHook<arch>.dll -- see
# the BUG-1708 notes in fushi/lib/src/mining/galgame_hook_runtime_stage.dart).  A
# developer machine that ran a game a minute ago is the normal case, not an edge
# case.  Windows refuses to delete a mapped image, so Remove-Item throws, the
# script exits non-zero, and the FATAL_ERROR in the CMake install(CODE) rule fails
# the whole `flutter build windows` for a reason unrelated to what was built.
#
# "Failed to delete, never mind" is not the alternative: leaving the old DLL in
# place is precisely the stale-injection state BUG-1881 was filed for.  The root
# cause is that two different things were treated as one: *deleting the files* and
# *making the stale helper unloadable*.  Only the second one is required.
#
# The runtime load rule (GalgameHookRuntimeStage._ensureStaged) is a plain
# per-path existence check of
#   <dir of fushi.exe>\voice_hook\<arch>\{fushi_voice_injector.exe, fushi_voice_hook.dll, ...}
# and reports the architecture as unavailable the moment one of them is not at its
# exact path.  So moving the directory aside *is* the "explicitly unavailable"
# state that the app already knows how to read; no new marker file is invented.
#
# Measured on this machine (Windows 11, Windows PowerShell 5.1):
#   * DLL mapped by LoadLibrary : Delete -> access denied, Remove-Item -Recurse on
#     its directory -> access denied, [IO.Directory]::Move -> SUCCEEDS.
#   * running .exe              : Delete -> access denied, Move -> SUCCEEDS.
#   * file held by an ordinary handle without FILE_SHARE_DELETE (an antivirus or
#     indexer scanning it): Delete and Move both fail.
# The last case leaves no way to make the old files unloadable, so it is the one
# case that must fail the build -- with a message that says which directory and
# what to close.

# Delete `<Path>.stale*` directories left behind by an earlier build.  They are
# already neutralized, so one that is still held is not an error -- but it is
# reported rather than swallowed.
function Remove-FushiHelperLeftovers {
  param([Parameter(Mandatory = $true)][string] $Path)

  $parent = Split-Path -Parent $Path
  $leaf = Split-Path -Leaf $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return }

  $pattern = '^' + [regex]::Escape($leaf) + '\.stale[0-9]*$'
  foreach ($entry in @(Get-ChildItem -LiteralPath $parent -Force |
      Where-Object { $_.Name -match $pattern })) {
    try {
      Remove-Item -LiteralPath $entry.FullName -Recurse -Force
    }
    catch {
      Write-Host ("galgame helper: leftover $($entry.FullName) is still held by " +
        'another process; leaving it for a later build.')
    }
  }
}

# Make the helper tree at $Path unloadable, and delete it when possible.
#
# Rename first, delete second: the rename is atomic, so the path the app reads
# stops existing in one step.  There is never a half-deleted directory that still
# happens to hold a complete set of files.  Deleting the renamed copy is cleanup;
# failing at that changes nothing about the guarantee.
function Disable-FushiStaleHelper {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string] $Reason
  )

  Remove-FushiHelperLeftovers -Path $Path
  if (-not (Test-Path -LiteralPath $Path)) { return }

  $asidePath = $null
  $renameError = $null
  for ($n = 1; $n -le 99; $n++) {
    $suffix = '.stale'
    if ($n -gt 1) { $suffix = ".stale$n" }
    $candidate = "$Path$suffix"
    if (Test-Path -LiteralPath $candidate) { continue }
    try {
      [IO.Directory]::Move($Path, $candidate)
      $asidePath = $candidate
    }
    catch {
      $renameError = $_
    }
    break
  }

  if ($null -eq $asidePath) {
    $detail = 'every .stale name next to it is taken'
    if ($null -ne $renameError) { $detail = $renameError.Exception.Message }
    throw (
      "Cannot disable the stale galgame helper at $Path ($Reason): deleting and " +
      "renaming it were both refused, so the app would keep loading it. " +
      "Rename error: $detail. Close whatever still holds those files -- the game " +
      'you last injected into (the hook DLL stays loaded until that process ' +
      'exits), fushi_voice_injector.exe, a running Fushi, or an antivirus/indexer ' +
      'scanning the directory -- and build again.')
  }

  try {
    Remove-Item -LiteralPath $asidePath -Recurse -Force
    Write-Host "galgame helper: removed stale files at $Path ($Reason)"
  }
  catch {
    Write-Host ("galgame helper: stale files at $Path are still held by another " +
      "process ($Reason); moved to $asidePath so the app can no longer load " +
      'them. A later build deletes them once the holder exits.')
  }
}

# Must stay identical to galgameHelperRequiredFiles() in
# fushi/lib/src/mining/galgame_helper_installer.dart. Two copies of a contract
# is exactly the shape that caused BUG-1345, so it is pinned by a guard test:
# fushi/test/mining/gal_helper_bundle_manifest_parity_test.dart parses this
# file and fails if the two lists ever diverge.
$RequiredFiles = @{
  'x86' = @(
    'fushi_voice_injector.exe',
    'fushi_voice_hook.dll',
    'LunaHook32.dll',
    'LunaHost32.dll',
    'LoaderDll.dll',
    'LocaleEmulator.dll',
    'LocaleEmulator-LGPL-3.0.txt'
  )
  'x64' = @(
    'fushi_voice_injector.exe',
    'fushi_voice_hook.dll',
    'LunaHook64.dll',
    'LunaHost64.dll',
    'unity_audio_runtime/fushi_unity_audio_extract.exe',
    'unity_audio_runtime/classdata.tpk',
    'unity_audio_runtime/vgmstream-cli.exe',
    'unity_audio_runtime/avcodec-vgmstream-59.dll',
    'unity_audio_runtime/avformat-vgmstream-59.dll',
    'unity_audio_runtime/avutil-vgmstream-57.dll',
    'unity_audio_runtime/swresample-vgmstream-4.dll',
    'unity_audio_runtime/libatrac9.dll',
    'unity_audio_runtime/libcelt-0061.dll',
    'unity_audio_runtime/libcelt-0110.dll',
    'unity_audio_runtime/libg719_decode.dll',
    'unity_audio_runtime/libmpg123-0.dll',
    'unity_audio_runtime/libspeex-1.dll',
    'unity_audio_runtime/libvorbis.dll',
    'unity_audio_runtime/COPYING'
  )
}

if (-not (Test-Path -LiteralPath $BundleDirectory -PathType Container)) {
  throw "Bundle directory does not exist: $BundleDirectory"
}
# Absolute from here on: Disable-FushiStaleHelper renames through
# [IO.Directory]::Move, which resolves a relative path against the *process*
# working directory rather than this script's.
$BundleDirectory = [IO.Path]::GetFullPath($BundleDirectory)
if (-not $DistDirectory) {
  $DistDirectory = Join-Path $PSScriptRoot '..\dist'
}
$DistDirectory = [IO.Path]::GetFullPath($DistDirectory)

$distributionArtifacts = @()
foreach ($arch in @('x86', 'x64')) {
  $zip = Join-Path $DistDirectory "voice_hook_$arch.zip"
  $distributionArtifacts += $zip
  $distributionArtifacts += "$zip.sha256"
}
$sourceFingerprintFile = Join-Path $DistDirectory 'voice_hook_source.sha256'
$distributionArtifacts += $sourceFingerprintFile
$missingArtifacts = @(
  $distributionArtifacts |
    Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
)

# BUG-1449 removed runtime zip installation.  An incremental Flutter build may
# still contain galgame_helper/ or voice_hook/ from an older checkout/build;
# remove the legacy archive unconditionally so it cannot repopulate stale plain
# files after this script returns.
$legacyBundle = Join-Path $BundleDirectory 'galgame_helper'
Disable-FushiStaleHelper -Path $legacyBundle -Reason 'legacy runtime archive directory (BUG-1449)'

if ($missingArtifacts.Count -gt 0) {
  if (-not $AllowMissingDistribution) {
    throw "Missing galgame helper build artifact(s): $($missingArtifacts -join ', ') (run build_distribution.ps1 first)"
  }

  # A build without a fresh dist is allowed, but the helper must then be honestly
  # unavailable.  Leaving yesterday's voice_hook directory in the incremental
  # bundle caused BUG-1881: SGRE injected pre-fix glyph geometry and selected a
  # different character (or no character) even though Flutter had just rebuilt.
  $plainBundle = Join-Path $BundleDirectory 'voice_hook'
  Disable-FushiStaleHelper -Path $plainBundle -Reason 'no helper distribution was built for this checkout'
  Write-Host "galgame helper distribution is absent; bundle helper disabled: $BundleDirectory"
  return
}

$recordedSourceFingerprint =
  ((Get-Content -LiteralPath $sourceFingerprintFile -Raw) -replace '[^0-9a-fA-F]', '').ToLowerInvariant()
$currentSourceFingerprint =
  Get-FushiHelperSourceFingerprint -SourceRoot ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
if ($recordedSourceFingerprint -ne $currentSourceFingerprint) {
  if (-not $AllowStaleDistribution) {
    throw "Galgame helper distribution is stale: recorded=$recordedSourceFingerprint current=$currentSourceFingerprint (run build_distribution.ps1 again)"
  }
  $plainBundle = Join-Path $BundleDirectory 'voice_hook'
  Disable-FushiStaleHelper -Path $plainBundle -Reason 'the helper distribution was built from a different checkout'
  Write-Host "galgame helper distribution is stale; bundle helper disabled: $BundleDirectory"
  return
}

foreach ($arch in @('x86', 'x64')) {
  $zip = Join-Path $DistDirectory "voice_hook_$arch.zip"
  $sidecar = "$zip.sha256"

  # Build-time fail-closed. An archive that cannot be proven intact must never be
  # unpacked into a shipping bundle: what is inside is an injector executable and
  # a DLL that gets loaded into the user's game process.
  $expected = ((Get-Content -LiteralPath $sidecar -Raw) -replace '[^0-9a-fA-F]', '').ToLowerInvariant()
  $actual = Get-FushiFileSha256Hex -Path $zip
  if ($expected -ne $actual) {
    throw "Helper archive sha256 mismatch for ${arch}: sidecar=$expected actual=$actual"
  }

  $target = Join-Path $BundleDirectory "voice_hook\$arch"
  # Same reasoning as the purge paths above: a previously injected hook DLL is
  # still mapped into the game the developer just closed, so the old directory has
  # to be moved aside rather than deleted in place.  Expand-Archive then writes
  # into a directory nothing holds.
  Disable-FushiStaleHelper -Path $target -Reason "replacing $arch with the freshly built helper"
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Expand-Archive -LiteralPath $zip -DestinationPath $target -Force

  $missing = @()
  foreach ($relative in $RequiredFiles[$arch]) {
    $path = Join-Path $target ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      $missing += $relative
    }
  }
  if ($missing.Count -gt 0) {
    throw "Extracted helper is incomplete for ${arch}: missing $($missing -join ', ')"
  }

  # Write the same version marker the runtime installer would have written, so a
  # bundle produced here is indistinguishable from one it installed itself. This
  # keeps GalgameHelperInstaller's bookkeeping honest (the marker records which
  # archive these files came from) and keeps the diagnostic value of the file.
  Set-Content -LiteralPath (Join-Path $target 'installed.sha256') -Value $actual -NoNewline -Encoding ascii

  Write-Host "galgame helper ${arch}: extracted $($RequiredFiles[$arch].Count) required files into $target (sha256 $actual)"
}

Write-Host "galgame helper installed into bundle as plain files; no runtime extraction needed."
