# Bundle the standalone 7-Zip console (7za.exe, LGPL) into the Windows release
# so the discovery page can auto-extract downloaded 7z/rar game/novel archives
# offline (DiscoveryArchiveExtractor probes <exe dir>\7za\7za.exe first).
#
# Source: the official 7-Zip GitHub mirror (ip7z/7zip) "extra" package, pinned
# by SHA-256. Verify-before-use: a swapped upstream archive must fail the build,
# not ship. Extraction uses the runner's preinstalled full 7-Zip.
#
# Usage:
#   pwsh -File tools/bundle_7za.ps1 -BundleDirectory <app Release dir> [-DownloadCache <dir>]

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BundleDirectory,
  [string]$DownloadCache = "$env:TEMP\hibiki-7za-cache"
)

$ErrorActionPreference = 'Stop'

$Version = '24.09'
$ArchiveName = '7z2409-extra.7z'
$Url = "https://github.com/ip7z/7zip/releases/download/$Version/$ArchiveName"
$ExpectedSha256 = '43AE97658D0FC5B4EEC4D409D85F7BED74A80945FD5704333A3599E0BD79B5FC'

if (-not (Test-Path -LiteralPath $BundleDirectory -PathType Container)) {
  throw "BundleDirectory not found: $BundleDirectory"
}

New-Item -ItemType Directory -Force -Path $DownloadCache | Out-Null
$archivePath = Join-Path $DownloadCache $ArchiveName

function Test-ArchiveHash {
  param([string]$Path)
  return (Test-Path -LiteralPath $Path -PathType Leaf) -and
    ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $ExpectedSha256)
}

if (-not (Test-ArchiveHash $archivePath)) {
  Write-Host "Downloading $Url"
  Invoke-WebRequest -Uri $Url -OutFile $archivePath -UseBasicParsing
  if (-not (Test-ArchiveHash $archivePath)) {
    $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    throw "SHA-256 mismatch for ${ArchiveName}: expected $ExpectedSha256, got $actual"
  }
}

# Locate a system 7-Zip to unpack the .7z (preinstalled on GitHub runners).
$sevenZip = $null
foreach ($candidate in @(
  (Get-Command 7z -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
  'C:\Program Files\7-Zip\7z.exe',
  'C:\Program Files (x86)\7-Zip\7z.exe'
)) {
  if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    $sevenZip = $candidate
    break
  }
}
if (-not $sevenZip) { throw 'No system 7-Zip found to unpack the extra package' }

$extractDir = Join-Path $DownloadCache 'extracted'
if (Test-Path -LiteralPath $extractDir) {
  Remove-Item -LiteralPath $extractDir -Recurse -Force
}
& $sevenZip x '-y' "-o$extractDir" $archivePath | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z extraction failed ($LASTEXITCODE)" }

# The extra package ships x86 7za.exe at the root and the x64 build under x64\.
$sourceExe = Join-Path $extractDir 'x64\7za.exe'
$licenseFile = Join-Path $extractDir 'License.txt'
if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
  throw "x64\7za.exe missing from $ArchiveName (upstream layout changed?)"
}
if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
  throw "License.txt missing from $ArchiveName"
}

$targetDir = Join-Path $BundleDirectory '7za'
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
Copy-Item -LiteralPath $sourceExe -Destination (Join-Path $targetDir '7za.exe') -Force
Copy-Item -LiteralPath $licenseFile -Destination (Join-Path $targetDir 'License.txt') -Force
Write-Host "Bundled 7za.exe $Version into $targetDir"
