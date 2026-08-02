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

  [string] $DistDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Must stay identical to galgameHelperRequiredFiles() in
# hibiki/lib/src/mining/galgame_helper_installer.dart. Two copies of a contract
# is exactly the shape that caused BUG-1345, so it is pinned by a guard test:
# hibiki/test/mining/gal_helper_bundle_manifest_parity_test.dart parses this
# file and fails if the two lists ever diverge.
$RequiredFiles = @{
  'x86' = @(
    'hibiki_voice_injector.exe',
    'hibiki_voice_hook.dll',
    'LunaHook32.dll',
    'LunaHost32.dll',
    'LoaderDll.dll',
    'LocaleEmulator.dll',
    'LocaleEmulator-LGPL-3.0.txt'
  )
  'x64' = @(
    'hibiki_voice_injector.exe',
    'hibiki_voice_hook.dll',
    'LunaHook64.dll',
    'LunaHost64.dll',
    'unity_audio_runtime/hibiki_unity_audio_extract.exe',
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
if (-not $DistDirectory) {
  $DistDirectory = Join-Path $PSScriptRoot '..\dist'
}
$DistDirectory = [IO.Path]::GetFullPath($DistDirectory)
if (-not (Test-Path -LiteralPath $DistDirectory -PathType Container)) {
  throw "Helper dist directory does not exist (run build_distribution.ps1 first): $DistDirectory"
}

foreach ($arch in @('x86', 'x64')) {
  $zip = Join-Path $DistDirectory "voice_hook_$arch.zip"
  $sidecar = "$zip.sha256"
  foreach ($required in @($zip, $sidecar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Missing galgame helper build artifact: $required"
    }
  }

  # Build-time fail-closed. An archive that cannot be proven intact must never be
  # unpacked into a shipping bundle: what is inside is an injector executable and
  # a DLL that gets loaded into the user's game process.
  $expected = ((Get-Content -LiteralPath $sidecar -Raw) -replace '[^0-9a-fA-F]', '').ToLowerInvariant()
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
  if ($expected -ne $actual) {
    throw "Helper archive sha256 mismatch for ${arch}: sidecar=$expected actual=$actual"
  }

  $target = Join-Path $BundleDirectory "voice_hook\$arch"
  if (Test-Path -LiteralPath $target) {
    Remove-Item -LiteralPath $target -Recurse -Force
  }
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
