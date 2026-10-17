# Builds libmpv against the unified FFmpeg (tool/ffmpeg-unified) and packages
# libmpv-2.dll + ffmpeg.exe + ffprobe.exe on ONE set of fbd*.dll: the player and
# card mining share the same FFmpeg. Build the FFmpeg first:
#   MINGW64> tool/ffmpeg-unified/windows/build_ffmpeg_msys2.sh <ffmpeg-work-dir>
param(
  [Parameter(Mandatory = $true)][string]$FfmpegWorkDirectory,
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
$ffmpegWork = [IO.Path]::GetFullPath($FfmpegWorkDirectory)
$ffmpegPrefix = Join-Path $ffmpegWork 'prefix'
$ffmpegSource = Join-Path $ffmpegWork 'src'
foreach ($required in @("$ffmpegPrefix\bin\ffmpeg.exe", "$ffmpegPrefix\bin\ffprobe.exe",
    "$ffmpegPrefix\lib\pkgconfig\libavcodec.pc")) {
  if (-not (Test-Path $required)) { throw "Unified FFmpeg is not built: missing $required" }
}
# The unified FFmpeg must win over MSYS2's own ffmpeg package for both meson's
# pkg-config lookup and the runtime closure (package_libmpv.py enforces it).
$env:PKG_CONFIG_PATH = "$ffmpegPrefix\lib\pkgconfig"
$env:PATH = "$ffmpegPrefix\bin;$prefix\bin;$MsysRoot\usr\bin;$env:PATH"
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
# BUG-3296: vo=gpu dumb mode ignored the hwdec surface padding (1080p H.264 on
# d3d11va zero-copy rendered the 1088-row surface squashed into 1080 rows).
Run 'git' @('-C', $source, 'apply', (Join-Path $repoRoot 'third_party\media_kit_libs_windows_video\patches\gpu-dumb-mode-hwdec-crop.patch'))
# BUG-3499: laced Matroska audio without DefaultDuration (mkvmerge Opus) left
# every lace frame after the first without a timestamp, so dump-cache dropped
# them and the mining snapshot kept ~1/8 of the audio.
Run 'git' @('-C', $source, 'apply', (Join-Path $repoRoot 'third_party\media_kit_libs_windows_video\patches\mkv-laced-audio-timestamps.patch'))
# BUG-3500: Matroska video has no DTS; the recorder left it to libavformat,
# which (without video_delay) set DTS = PTS and rejected every B-frame, so the
# dump-cache snapshot of HEVC/H.264 with B-frames was mostly undecodable.
Run 'git' @('-C', $source, 'apply', (Join-Path $repoRoot 'third_party\media_kit_libs_windows_video\patches\recorder-video-dts.patch'))
New-Item -ItemType Directory -Path $angle | Out-Null
Push-Location $angle
try { Run 'cmake' @('-E', 'tar', 'xzf', (Join-Path $repoRoot 'third_party\media_kit_libs_windows_video\vendored\ANGLE.7z')) }
finally { Pop-Location }
$include = (Join-Path $angle 'include').Replace('\', '/')
Run 'meson' @('setup', $build, $source, '--buildtype=release', '-Dlibmpv=true',
  '-Dcplayer=false', '-Dlibbluray=enabled', '-Dlua=luajit', '-Djavascript=disabled',
  '-Dtests=true', '-Degl-angle=enabled', "-Dc_args=-I$include")
Push-Location (Join-Path $repoRoot 'fushi')
try { Run 'dart' @('tool/heavy.dart', '--', 'ninja', '-C', $build, '-j', "$Jobs") }
finally { Pop-Location }
Run $python @((Join-Path $PSScriptRoot 'package_libmpv.py'), '--build', $build,
  '--source', $source, '--prefix', $prefix, '--ffmpeg-prefix', $ffmpegPrefix,
  '--ffmpeg-source', $ffmpegSource, '--output', $package)
Copy-Item (Join-Path $repoRoot 'third_party\media_kit_libs_windows_video\bdj\libbluray*.jar') $package
# Run the packaged programs from a PATH without any prefix, so they can only
# load the renamed fbd*.dll next to them (proves the shared runtime is closed).
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
Run $python @('-I', (Join-Path $repoRoot 'tool\ffmpeg-unified\verify_ffmpeg_capabilities.py'),
  '--ffmpeg', (Join-Path $package 'ffmpeg.exe'), '--ffprobe', (Join-Path $package 'ffprobe.exe'))
Run $python @((Join-Path $PSScriptRoot 'probe_libmpv.py'), (Join-Path $package 'libmpv-2.dll'))
# BUG-3499 / BUG-3500: dump-cache must keep every frame of laced Matroska audio
# and of Matroska B-frame video.
Run $python @((Join-Path $PSScriptRoot 'verify_mkv_lace_dump.py'), '--library', $package,
  '--ffmpeg', (Join-Path $package 'ffmpeg.exe'))
Write-Output "Verified native runtime directory: $package"
Write-Output 'Run verify_menu_render.py against a readable real disc before repinning an archive.'
