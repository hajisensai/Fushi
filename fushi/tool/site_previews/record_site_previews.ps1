# 重拍官网 fushi.moe 首页的「App 全貌」截图与四段「实机录屏」。
#
# 每个版本 UI 变了就重跑一次（在 fushi/ 下）：
#   pwsh -File tool/site_previews/record_site_previews.ps1 -Site D:\path\to\fushi.moe
# 跑完 <官网仓>/public/overview/*.jpg 与 public/preview/*.mp4|*-poster.jpg 被覆盖，
# 去官网仓看 git diff、提交、开 PR 即可。
#
# 流程：
#   1. extract_demo_fixtures.dart  从官网仓已公开的交互 demo 抽夹具（视频片段 + 字幕、
#      漫画页 + OCR 框、有声书正文 + 音频 + cue、游戏截图 + 台词 + 语音、demo 词库 → Yomitan zip）
#   2. fetch_library_fixtures.dart 下载（并缓存）公有领域 / CC 作品，供「App 全貌」播种书架等
#   3. run_windows_itest.ps1 跑 integration_test/site_preview_capture_itest.dart：真 app、干净隔离库，
#      窗口经 FUSHI_TEST_TOPMOST 置顶停在屏幕左上（不抢焦点、不动真鼠标），ffmpeg 桌面复制录屏
#   4. postprocess.dart            缩放 / 混入媒体原声 / 出封面帧，写进官网仓
#
# 录制期间（约 3 分钟）屏幕左上会有一个置顶的 Fushi 窗口，别把别的窗口拖到它上面，
# 也别让显示器熄屏——桌面复制录的是屏上真像素。
#
# 参数：
#   -Site      官网仓 checkout（必填）
#   -Only      逗号分隔的场景：overview,video,manga,gal,audiobook（默认全部）
#   -Cache     夹具与原始产物目录（默认 fushi/build/site_previews；路径须为 ASCII，dart-define 不收非 ASCII）
#   -Proxy     下载素材与 runner 用的代理（默认 http://127.0.0.1:7890）
#   -NoPublish 只录不写官网仓（原始产物留在 <Cache>/raw/<runId>）
param(
  [Parameter(Mandatory = $true)][string]$Site,
  [string]$Only = "",
  [string]$Cache = "",
  [string]$Proxy = "http://127.0.0.1:7890",
  [switch]$NoPublish
)

$ErrorActionPreference = "Stop"
$AppRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $AppRoot
$Site = (Resolve-Path $Site).Path
if (-not (Test-Path (Join-Path $Site "public\index.html"))) {
  throw "$Site 不像官网仓（没有 public/index.html）"
}
if ([string]::IsNullOrWhiteSpace($Cache)) { $Cache = Join-Path $AppRoot "build\site_previews" }
New-Item -ItemType Directory -Force $Cache | Out-Null
$Cache = (Resolve-Path $Cache).Path
if ($Cache -match '[^\x00-\x7F]') { throw "-Cache 路径含非 ASCII 字符：$Cache" }

$flutterBin = "D:\flutter_sdk\flutter_3.47.6\bin"
$dart = if (Test-Path "$flutterBin\dart.bat") { "$flutterBin\dart.bat" } else { "dart" }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "PATH 上没有 ffmpeg" }

function Invoke-Checked([string]$what, [scriptblock]$block) {
  Write-Host "== $what"
  & $block
  if ($LASTEXITCODE -ne 0) { throw "$what 失败（exit $LASTEXITCODE）" }
}

$demoDir = Join-Path $Cache "demo"
$libraryDir = Join-Path $Cache "library"
Invoke-Checked "抽取官网 demo 夹具" { & $dart run tool/site_previews/extract_demo_fixtures.dart --site $Site --out $demoDir }
$wantOverview = [string]::IsNullOrWhiteSpace($Only) -or ($Only -split ',' | ForEach-Object { $_.Trim() }) -contains 'overview'
if ($wantOverview) {
  Invoke-Checked "下载公有领域库素材" { & $dart run tool/site_previews/fetch_library_fixtures.dart --out $libraryDir --proxy $Proxy }
}

# 置顶停靠位：主显示器左上，按系统缩放换成物理像素（FUSHI_TEST_TOPMOST 收物理像素）。
Add-Type -Namespace SitePreview -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetDpiForSystem();
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
'@
[void][SitePreview.Native]::SetProcessDPIAware()
$scale = [SitePreview.Native]::GetDpiForSystem() / 96.0
$screenW = [SitePreview.Native]::GetSystemMetrics(0)
$screenH = [SitePreview.Native]::GetSystemMetrics(1)
$needW = [int][Math]::Ceiling(1440 * $scale) + 80
$needH = [int][Math]::Ceiling(1000 * $scale) + 120
if ($screenW -lt $needW -or $screenH -lt $needH) {
  throw "主显示器 ${screenW}x${screenH}（缩放 $scale）放不下 1440x900（全貌）/ 760x1000（漫画）逻辑像素的录制窗口"
}
$env:FUSHI_TEST_TOPMOST = "40,40,$([int](1280 * $scale)),$([int](720 * $scale))"

$runId = "site-preview-" + (Get-Date -Format "yyyyMMdd-HHmmss")
$rawDir = Join-Path $Cache "raw\$runId"
New-Item -ItemType Directory -Force $rawDir | Out-Null
$defines = @(
  "SITE_PREVIEW_OUT=$rawDir",
  "SITE_PREVIEW_DEMO=$demoDir",
  "SITE_PREVIEW_LIBRARY=$libraryDir",
  "SITE_PREVIEW_ONLY=$Only"
)
$defineLiteral = ($defines | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ","
# 经本机重活租约跑 runner；-DartDefine 必须以数组传，用 EncodedCommand 免去转义。
$inner = "& '$AppRoot\tool\run_windows_itest.ps1' integration_test/site_preview_capture_itest.dart -Visible -RunId '$runId' -Proxy '$Proxy' -DartDefine @($defineLiteral)"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
Write-Host "== 录制（runId=$runId，窗口 $env:FUSHI_TEST_TOPMOST）"
& $dart tool/heavy.dart -- powershell -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand $encoded
$evidence = Join-Path $AppRoot ".codex-test\windows-itest\$runId"
$code = Get-Content (Join-Path $evidence "exit-code.txt") -ErrorAction SilentlyContinue
if ("$code".Trim() -ne "0") {
  Select-String -Path (Join-Path $evidence "command.log") -Pattern '\[site-preview\]|Expected|Actual|FAILED|Exception|error' |
    Select-Object -Last 40 | ForEach-Object { $_.Line }
  throw "录制失败（exit $code），日志：$evidence\command.log"
}

if ($NoPublish) {
  Write-Host "原始产物：$rawDir"
  exit 0
}
Invoke-Checked "后期并写入官网仓" { & $dart run tool/site_previews/postprocess.dart --raw $rawDir --site $Site }
Write-Host "完成。去 $Site 看 git status / git diff，确认后提交。"
