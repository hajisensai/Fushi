# 生成 2026-10 UI / 动效重做的效果图（Windows 版，与 render_previews.sh 等价）。
#   powershell -ExecutionPolicy Bypass -File fushi/tool/design_preview/render_previews.ps1 [-Out <目录>]
param([string]$Out)
$ErrorActionPreference = "Stop"
$appDir = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$repoDir = Resolve-Path (Join-Path $appDir "..")
if (-not $Out) { $Out = Join-Path $repoDir "docs\design\2026-10-ui-motion-redesign" }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path

Write-Host "==> 渲染效果图到 $Out"
$env:FUSHI_DESIGN_PREVIEW_OUT = $Out
Push-Location $appDir
try {
  flutter test --no-pub test/design_preview/redesign_preview_test.dart
  if ($LASTEXITCODE -ne 0) { throw "flutter test 失败（退出码 $LASTEXITCODE）" }
} finally {
  Pop-Location
  Remove-Item Env:FUSHI_DESIGN_PREVIEW_OUT
}

$frames = Join-Path $Out "frames"
if (Test-Path $frames) {
  $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
  Get-ChildItem $frames -Recurse -Filter "000.png" | ForEach-Object {
    $dir = $_.DirectoryName
    $rel = $dir.Substring($frames.Length + 1) -replace '[\\/]', '_'
    $gif = Join-Path $Out "motion_$rel.gif"
    if ($ffmpeg) {
      & ffmpeg -loglevel error -y -framerate 6 -i (Join-Path $dir "%03d.png") `
        -vf "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse" -loop 0 $gif
      Write-Host "   $gif"
    } else {
      Write-Host "   跳过 GIF（未找到 ffmpeg），分帧保留在 $dir"
    }
  }
  if ($ffmpeg -and $env:KEEP_FRAMES -ne "1") { Remove-Item -Recurse -Force $frames }
}
Write-Host "==> 完成"
Get-ChildItem $Out | Select-Object -ExpandProperty Name
