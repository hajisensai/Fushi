# 一键出一期版本更新视频（B 站横屏 1920×1080）。在 fushi/ 下：
#   pwsh -File tool/update_video/build_update_video.ps1 -Spec tool/update_video/3.4.0.json `
#        -Uv D:\path\to\uvfix -Bgm D:\path\to\bgm.m4a -Out D:\path\to\Fushi-3.4.0.mp4
#
# 流程：
#   1. tool/site_previews/record_site_previews.ps1 -Only <spec.scenes> -NoPublish
#      真 app 录 uv-* 场景（场景代码在 integration_test/site_preview_update_video_scenes.dart）
#   2. tool/site_previews/postprocess.dart  缩放 / 混原声 / 剪掉查词等待
#   3. tool/update_video/compose.py         标题卡 + 字幕条 + 文字快闪 + BGM（原声处自动压低）+ 响度归一
#
# -Uv：素材夹具目录（uv.json + manga/ + video/ + dict/，见场景文件头）；不给就用官网 demo 素材。
# -Site：官网仓（只用来抽 demo 夹具）。录制约 5 分钟，期间屏幕左上角有置顶 Fushi 窗口，别挡、别熄屏。
param(
  [Parameter(Mandatory = $true)][string]$Spec,
  [Parameter(Mandatory = $true)][string]$Out,
  [string]$Uv = "",
  [string]$Bgm = "",
  [string]$Site = "D:\codehibiki-site\fushi.moe",
  [string]$Proxy = "",
  [string]$Only = ""
)

$ErrorActionPreference = "Stop"
$AppRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $AppRoot
$specJson = Get-Content -Raw -Encoding UTF8 $Spec | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Only)) { $Only = $specJson.scenes }
$flutterBin = "D:\flutter_sdk\flutter_3.50.0\bin"
$dart = if (Test-Path "$flutterBin\dart.bat") { "$flutterBin\dart.bat" } else { "dart" }

$rawRoot = Join-Path $AppRoot "build\site_previews\raw"
$before = @(Get-ChildItem $rawRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
& pwsh -NoProfile -File tool/site_previews/record_site_previews.ps1 -Site $Site -Only $Only -Uv $Uv -Proxy $Proxy -NoPublish
if ($LASTEXITCODE -ne 0) { throw "录制失败（exit $LASTEXITCODE）" }
$raw = Get-ChildItem $rawRoot -Directory | Where-Object { $before -notcontains $_.FullName } |
  Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $raw) { throw "没找到本次录制的原始产物目录" }

$stage = Join-Path $AppRoot "build\update_video\$($raw.Name)"
New-Item -ItemType Directory -Force (Join-Path $stage "public\preview"), (Join-Path $stage "public\overview") | Out-Null
& $dart run tool/site_previews/postprocess.dart --raw $raw.FullName --site $stage
if ($LASTEXITCODE -ne 0) { throw "后期失败（exit $LASTEXITCODE）" }

$composeArgs = @("tool/update_video/compose.py", "--spec", $Spec, "--clips", (Join-Path $stage "public\preview"), "--out", $Out)
if (-not [string]::IsNullOrWhiteSpace($Bgm)) { $composeArgs += @("--bgm", $Bgm) }
& python @composeArgs
if ($LASTEXITCODE -ne 0) { throw "合成失败（exit $LASTEXITCODE）" }
Write-Host "完成：$Out"
