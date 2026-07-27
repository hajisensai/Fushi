<#
.SYNOPSIS
  Build and package the x64/x86 galgame helper archives.

.DESCRIPTION
  The voice-hook-helper release and the Hibiki Windows bundle share this
  packaging entry point. Output contains only the two zip files and sidecars.
#>
[CmdletBinding()]
param(
  [string]$OutputDirectory,
  [switch]$RunTests
)

$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $outputRoot = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'dist'))
}
elseif ([IO.Path]::IsPathRooted($OutputDirectory)) {
  $outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
}
else {
  $outputRoot = [IO.Path]::GetFullPath((Join-Path $sourceRoot $OutputDirectory))
}
$buildRoot = Join-Path $sourceRoot 'build'

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
  )
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath failed with exit code $LASTEXITCODE"
  }
}

function Reset-StageDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  $full = [IO.Path]::GetFullPath($Path)
  $prefix = $outputRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to reset stage directory outside output root: $full"
  }
  if (Test-Path -LiteralPath $full) {
    Remove-Item -LiteralPath $full -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $full | Out-Null
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

foreach ($config in @(
  @{ Arch = 'x64'; GeneratorArch = 'x64' },
  @{ Arch = 'x86'; GeneratorArch = 'Win32' }
)) {
  $arch = $config.Arch
  $buildDir = Join-Path $buildRoot $arch
  Invoke-Checked -FilePath cmake -Arguments @(
    '-S', $sourceRoot, '-B', $buildDir, '-A', $config.GeneratorArch
  )
  Invoke-Checked -FilePath cmake -Arguments @(
    '--build', $buildDir, '--config', 'Release'
  )
  if ($RunTests) {
    # --no-tests=error: ctest defaults to returning 0 when NO test is registered,
    # so a CMakeLists refactor that stops registering the suite would read as a
    # pass. Same "zero tests executed masquerades as green" family as BUG-1157.
    # Matches .github/workflows/native-hoshidicts-gate.yml.
    Invoke-Checked -FilePath ctest -Arguments @(
      '--test-dir', $buildDir, '-C', 'Release', '--output-on-failure',
      '--no-tests=error'
    )
  }
}

$stageX64 = Join-Path $outputRoot 'x64'
$stageX86 = Join-Path $outputRoot 'x86'
Reset-StageDirectory $stageX64
Reset-StageDirectory $stageX86

$releaseX64 = Join-Path $buildRoot 'x64\Release'
$releaseX86 = Join-Path $buildRoot 'x86\Release'
foreach ($file in @(
  'hibiki_voice_injector.exe',
  'hibiki_voice_hook.dll',
  'LunaHook64.dll',
  'LunaHost64.dll'
)) {
  Copy-Item -LiteralPath (Join-Path $releaseX64 $file) -Destination $stageX64 -Force
}
foreach ($file in @(
  'hibiki_voice_injector.exe',
  'hibiki_voice_hook.dll',
  'LunaHook32.dll',
  'LunaHost32.dll'
)) {
  Copy-Item -LiteralPath (Join-Path $releaseX86 $file) -Destination $stageX86 -Force
}

# Locale Emulator 2.5.0.1 (LGPL-3.0), pinned by version and SHA-256 for x86.
$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$leZip = Join-Path $tempBase 'Locale.Emulator.2.5.0.1.zip'
$leDir = Join-Path $tempBase 'hibiki-locale-emulator-2.5.0.1'
$leUrl = 'https://github.com/xupefei/Locale-Emulator/releases/download/v2.5.0.1/Locale.Emulator.2.5.0.1.zip'
$expectedLeSha = '808ff584426d52cc775ad6406da00622f454be95bd4c8fbca42eef4b7235ad5c'
if (-not (Test-Path -LiteralPath $leZip -PathType Leaf) -or
    (Get-FileHash -LiteralPath $leZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedLeSha) {
  Invoke-WebRequest -Uri $leUrl -OutFile $leZip
}
$actualLeSha = (Get-FileHash -LiteralPath $leZip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualLeSha -ne $expectedLeSha) {
  throw "Locale Emulator SHA-256 mismatch: $actualLeSha"
}
if (Test-Path -LiteralPath $leDir) {
  $tempRoot = [IO.Path]::GetFullPath($tempBase).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  $leFull = [IO.Path]::GetFullPath($leDir)
  if (-not $leFull.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to reset Locale Emulator temp directory outside temp root: $leFull"
  }
  Remove-Item -LiteralPath $leFull -Recurse -Force
}
Expand-Archive -LiteralPath $leZip -DestinationPath $leDir -Force
Copy-Item -LiteralPath (Join-Path $leDir 'LoaderDll.dll') -Destination $stageX86 -Force
Copy-Item -LiteralPath (Join-Path $leDir 'LocaleEmulator.dll') -Destination $stageX86 -Force
Invoke-WebRequest `
  -Uri 'https://raw.githubusercontent.com/xupefei/Locale-Emulator/v2.5.0.1/COPYING.LESSER' `
  -OutFile (Join-Path $stageX86 'LocaleEmulator-LGPL-3.0.txt')

$expected = @{
  x64 = @('hibiki_voice_injector.exe', 'hibiki_voice_hook.dll', 'LunaHook64.dll', 'LunaHost64.dll')
  x86 = @('hibiki_voice_injector.exe', 'hibiki_voice_hook.dll', 'LunaHook32.dll', 'LunaHost32.dll', 'LoaderDll.dll', 'LocaleEmulator.dll', 'LocaleEmulator-LGPL-3.0.txt')
}
foreach ($arch in @('x64', 'x86')) {
  $stage = Join-Path $outputRoot $arch
  $actual = @(Get-ChildItem -LiteralPath $stage -File | ForEach-Object Name | Sort-Object)
  $wanted = @($expected[$arch] | Sort-Object)
  if (Compare-Object $wanted $actual) {
    throw "arch $arch staged files differ: $($actual -join ', ')"
  }

  $zip = Join-Path $outputRoot "voice_hook_$arch.zip"
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
  $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content -LiteralPath "$zip.sha256" -Value $hash -NoNewline
  Write-Host "$arch sha256=$hash"
}

# Staging is packaging-only and must not be copied into the app bundle.
foreach ($stage in @($stageX64, $stageX86)) {
  Remove-Item -LiteralPath $stage -Recurse -Force
}

Write-Host "Helper distribution archives ready: $outputRoot"
