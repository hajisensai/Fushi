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

function Get-StageRelativePath {
  # CI runs this on the windows runner under Windows PowerShell 5.1 (.NET Framework
  # 4.x), which has NO [IO.Path]::GetRelativePath -- that API is .NET Core /
  # netstandard2.1+ only. Calling it there throws "does not contain a method named
  # GetRelativePath" and takes the whole packaging step down with it. Same
  # prefix-trim shape as Reset-StageDirectory above; emits forward slashes so the
  # result lines up with the $expected manifest.
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$FullName
  )
  $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  $full = [IO.Path]::GetFullPath($FullName)
  # OrdinalIgnoreCase mirrors GetRelativePath's own Windows comparison. Appending the
  # separator before comparing is load-bearing: a bare StartsWith would treat
  # "<root>extra\file" as living inside "<root>". A staged file outside its arch root
  # is a packaging bug, so fail loudly instead of emitting a "..\" path that would
  # only surface later as a baffling manifest diff.
  if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Staged file escapes its arch root ($Root): $full"
  }
  return $full.Substring($rootPrefix.Length).Replace('\', '/')
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
$unityAudioRuntimeFiles = @(
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
foreach ($file in $unityAudioRuntimeFiles) {
  $destination = Join-Path $stageX64 $file
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force |
    Out-Null
  Copy-Item -LiteralPath (Join-Path $releaseX64 $file) -Destination $destination -Force
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
  x64 = @(
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
  x86 = @('hibiki_voice_injector.exe', 'hibiki_voice_hook.dll', 'LunaHook32.dll', 'LunaHost32.dll', 'LoaderDll.dll', 'LocaleEmulator.dll', 'LocaleEmulator-LGPL-3.0.txt')
}
foreach ($arch in @('x64', 'x86')) {
  $stage = Join-Path $outputRoot $arch
  $actual = @(
    Get-ChildItem -LiteralPath $stage -File -Recurse |
      ForEach-Object { Get-StageRelativePath -Root $stage -FullName $_.FullName } |
      Sort-Object
  )
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
