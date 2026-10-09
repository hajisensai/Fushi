param(
  [string]$MsysRoot = 'C:\msys64',
  [string]$OutputDirectory = '',
  [int]$Jobs = 3
)
$ErrorActionPreference = 'Stop'
$python = (Get-Command python).Source
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot '.tmp\bluray-libmpv-build' }
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path $out) { throw "Use a new output directory: $out" }
$prefix = Join-Path $MsysRoot 'mingw64'
$env:PATH = "$prefix\bin;$MsysRoot\usr\bin;$env:PATH"
New-Item -ItemType Directory -Path $out | Out-Null
function Run([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program failed: $LASTEXITCODE" }
}
$source = Join-Path $out 'source'
$build = Join-Path $out 'build'
$package = Join-Path $out 'package'
$angle = Join-Path $out 'angle'
Run 'git' @('clone', '--filter=blob:none', '--no-checkout', 'https://github.com/mpv-player/mpv.git', $source)
Run 'git' @('-C', $source, 'checkout', '--detach', '36abaa32d00a7229ee206aae12dc0e97e7962dca')
Run 'git' @('-C', $source, 'apply', (Join-Path $repoRoot 'third_party\media_kit_libs_windows_video\patches\disc-navigation-state.patch'))
New-Item -ItemType Directory -Path $angle | Out-Null
Push-Location $angle
try { Run 'cmake' @('-E', 'tar', 'xzf', (Join-Path $repoRoot 'third_party\media_kit_libs_windows_video\vendored\ANGLE.7z')) }
finally { Pop-Location }
$include = (Join-Path $angle 'include').Replace('\', '/')
Run 'meson' @('setup', $build, $source, '--buildtype=release', '-Dlibmpv=true',
  '-Dcplayer=false', '-Dlibbluray=enabled', '-Dlua=disabled', '-Djavascript=disabled',
  '-Dtests=true', '-Degl-angle=enabled', "-Dc_args=-I$include")
Push-Location (Join-Path $repoRoot 'fushi')
try { Run 'dart' @('tool/heavy.dart', '--', 'ninja', '-C', $build, '-j', "$Jobs") }
finally { Pop-Location }
Run $python @((Join-Path $PSScriptRoot 'package_libmpv.py'), '--build', $build,
  '--source', $source, '--prefix', $prefix, '--output', $package)
Copy-Item (Join-Path $repoRoot 'third_party\media_kit_libs_windows_video\bdj\libbluray*.jar') $package
Run $python @((Join-Path $PSScriptRoot 'probe_libmpv.py'), (Join-Path $package 'libmpv-2.dll'))
Write-Output "Verified native runtime directory: $package"
Write-Output 'Run verify_menu_render.py against a readable real disc before repinning an archive.'
