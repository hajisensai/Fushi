# Builds Fushi's patched Flutter Windows engine (HDR output inside the Flutter
# compositor) and packages it for tool/engine_overlay.ps1.
#
# Steps (run any subset, in this order):
#   sync   clone flutter/flutter at -FlutterVersion into <Root>\flutter and
#          gclient-sync the engine sources (tens of GB; needs depot_tools)
#   patch  apply ci/patches/flutter-engine/<version>/{engine,ANGLE} patches
#          (idempotent: an already applied patch is skipped)
#   build  gn + ninja flutter_windows for each -Modes entry
#   stage  copy outputs into the overlay layout under <Root>\artifacts\<patch>
#   pack   zip the staged overlay (pdbs included) and print artifacts.json
#
# Example (everything):
#   tool/flutter_engine/build_patched_engine.ps1 -Root D:\fe -PatchVersion hdr-output-1
#
# Requirements: Visual Studio 2022 with the C++ workload (+ ATL; a BuildTools
# install that has ATL can be pointed at with -AtlDir), a Windows 10/11 SDK,
# Python 3, depot_tools at <Root>\depot_tools.
param(
  [Parameter(Mandatory)][string]$Root,
  [string]$PatchVersion,
  [string]$FlutterVersion,
  # Lists may also arrive as one comma-separated string (`powershell -File`).
  [string[]]$Steps = @('sync', 'patch', 'build', 'stage', 'pack'),
  [string[]]$Modes = @('debug', 'profile', 'release'),
  [string]$VsInstall,
  [string]$AtlDir,
  [string]$WindowsSdkVersion,
  [string]$Proxy = $env:HTTPS_PROXY
)
$ErrorActionPreference = 'Stop'

function Split-List {
  param([string[]]$Values, [string[]]$Allowed, [string]$Name)
  $items = @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  foreach ($item in $items) {
    if ($Allowed -notcontains $item) { throw "-$Name '$item' is not one of: $($Allowed -join ', ')." }
  }
  return $items
}
$Steps = Split-List $Steps @('sync', 'patch', 'build', 'stage', 'pack') 'Steps'
$Modes = Split-List $Modes @('debug', 'profile', 'release') 'Modes'

$repo =(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $FlutterVersion) {
  $FlutterVersion = (Get-Content (Join-Path $repo 'fushi\.fvmrc') -Raw | ConvertFrom-Json).flutter
}
$patchDir = Join-Path $repo "ci\patches\flutter-engine\$FlutterVersion"
$flutter = Join-Path $Root 'flutter'
$src = Join-Path $flutter 'engine\src'
$depot = Join-Path $Root 'depot_tools'
$cacheDirs = @{ debug = 'windows-x64'; profile = 'windows-x64-profile'; release = 'windows-x64-release' }

function Invoke-Native {
  param([string]$What, [scriptblock]$Command)
  & $Command
  if ($LASTEXITCODE -ne 0) { throw "$What failed ($LASTEXITCODE)" }
}

function Set-Toolchain {
  $env:PATH = "$depot;$env:PATH"
  $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
  if (-not $VsInstall) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $script:VsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  }
  $env:GYP_MSVS_OVERRIDE_PATH = $VsInstall
  $env:WINDOWSSDKDIR = "${env:ProgramFiles(x86)}\Windows Kits\10"
  if ($AtlDir) {
    # vcvarsall appends to INCLUDE/LIB and setup_toolchain.py keeps them when
    # VSINSTALLDIR is unset: seed them with an ATL from another VS install.
    Remove-Item Env:\VSINSTALLDIR -ErrorAction SilentlyContinue
    $env:INCLUDE = Join-Path $AtlDir 'include'
    $env:LIB = Join-Path $AtlDir 'lib\x64'
  }
  if ($Proxy) { $env:HTTPS_PROXY = $Proxy; $env:HTTP_PROXY = $Proxy }
}

function Set-WindowsSdk {
  # The engine pins one Windows SDK; any installed 10.0.x SDK has compatible
  # headers/libs. Point setup_toolchain.py at the one present.
  $version = $WindowsSdkVersion
  if (-not $version) {
    $version = (Get-ChildItem "$env:WINDOWSSDKDIR\Include" -Directory |
        Where-Object { $_.Name -like '10.0.*' } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1).Name
  }
  $setup = Join-Path $src 'build\toolchain\win\setup_toolchain.py'
  $text = [IO.File]::ReadAllText($setup)
  $patched = $text -replace "SDK_VERSION = '10\.0\.\d+\.0'", "SDK_VERSION = '$version'"
  if ($patched -ne $text) {
    [IO.File]::WriteAllText($setup, $patched, (New-Object Text.UTF8Encoding($false)))
  }
}

function Invoke-Patch {
  param([string]$RepoDir, [string]$PatchFile)
  $name = Split-Path $PatchFile -Leaf
  & git -C $RepoDir apply --check --reverse $PatchFile 2>$null
  if ($LASTEXITCODE -eq 0) { "already applied: $name"; return }
  Invoke-Native "git apply $name" { git -C $RepoDir apply --whitespace=nowarn $PatchFile }
  "applied: $name"
}

Set-Toolchain

if ($Steps -contains 'sync') {
  if (-not (Test-Path (Join-Path $flutter '.git'))) {
    Invoke-Native 'clone' {
      git clone --depth 1 --branch $FlutterVersion https://github.com/flutter/flutter.git $flutter
    }
  }
  Copy-Item (Join-Path $flutter 'engine\scripts\standard.gclient') (Join-Path $flutter '.gclient') -Force
  Push-Location $flutter
  try { Invoke-Native 'gclient sync' { & (Join-Path $depot 'gclient.bat') sync --no-history -D } }
  finally { Pop-Location }
}

if ($Steps -contains 'patch') {
  Invoke-Patch $flutter (Join-Path $patchDir 'engine-hdr-output.patch')
  Invoke-Patch (Join-Path $src 'flutter\third_party\angle') (Join-Path $patchDir 'angle-scrgb-swapchain.patch')
}

if ($Steps -contains 'build') {
  Set-WindowsSdk
  Push-Location $src
  try {
    foreach ($mode in $Modes) {
      # Same configuration as the official windows-x64{,-profile,-release}
      # artifacts (optimized).
      Invoke-Native "gn $mode" { python .\flutter\tools\gn --runtime-mode $mode --no-goma --no-rbe }
      Invoke-Native "ninja $mode" { ninja -C "out\host_$mode" flutter/shell/platform/windows:flutter_windows }
    }
  } finally { Pop-Location }
}

$staged = if ($PatchVersion) { Join-Path $Root "artifacts\$PatchVersion" } else { $null }

if ($Steps -contains 'stage') {
  if (-not $PatchVersion) { throw 'stage needs -PatchVersion.' }
  $engineVersion = (Get-Content (Join-Path $flutter 'bin\internal\engine.version') -Raw).Trim()
  if (Test-Path $staged) { Remove-Item $staged -Recurse -Force }
  foreach ($mode in $Modes) {
    $out = Join-Path $src "out\host_$mode"
    $dir = Join-Path $staged $cacheDirs[$mode]
    New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($f in 'flutter_windows.dll', 'flutter_windows.dll.lib', 'flutter_windows.dll.exp', 'flutter_windows.dll.pdb') {
      Copy-Item (Join-Path $out $f) (Join-Path $dir $f) -Force
    }
    Copy-Item (Join-Path $src 'flutter\shell\platform\windows\public\flutter_windows.h') $dir -Force
    Copy-Item (Join-Path $src 'flutter\shell\platform\common\public\flutter_texture_registrar.h') $dir -Force
  }
  $meta = [ordered]@{ engineVersion = $engineVersion; patchVersion = $PatchVersion } | ConvertTo-Json
  [IO.File]::WriteAllText((Join-Path $staged 'engine-overlay.json'), $meta, (New-Object Text.UTF8Encoding($false)))
  "staged: $staged"
}

if ($Steps -contains 'pack') {
  if (-not $PatchVersion) { throw 'pack needs -PatchVersion.' }
  $zip = Join-Path $Root "flutter-engine-windows-$FlutterVersion-$PatchVersion.zip"
  # The pdbs ship too (~200 MB zipped): flutter_tools requires
  # flutter_windows.dll.pdb next to the dll, and matching symbols are what
  # makes a crash in the patched engine diagnosable.
  if (Test-Path $zip) { Remove-Item $zip -Force }
  Compress-Archive -Path (Join-Path $staged '*') -DestinationPath $zip -CompressionLevel Optimal
  $meta = Get-Content (Join-Path $staged 'engine-overlay.json') -Raw | ConvertFrom-Json
  [ordered]@{
    engineVersion = $meta.engineVersion
    patchVersion = $PatchVersion
    url = '<release asset URL>'
    sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  } | ConvertTo-Json
  "packed: $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
}
