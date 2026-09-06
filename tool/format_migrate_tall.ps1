# 整仓一次性迁移到 Dart 3.7+ 的「tall」格式风格，并让 CI 以后强校验格式。
#
# 背景：仓库存量 Dart 文件是旧短风格，而 Dart >= 3.10 的 `dart format` 只输出 tall 风格，
# 本机（3.41.6 / 3.44）任何人 format 都会整文件重排；`dart run slang` 重生成 strings.g.dart
# 同理。结果是没人敢 format、i18n 生成文件只能手工补（tool/i18n_patch_generated.dart）。
#
# 这是**协调事件**，不是随手能跑的脚本：会改动几乎所有 Dart 文件，必须在所有并行分支
# 合并完、develop 冻结的窗口里由 integration owner 一次性执行并单独成一条 commit，随后
# 所有在飞分支 rebase（冲突只会是格式噪音，`git rebase -X theirs` 后再跑一次本脚本即可）。
#
# 用法（仓库根，develop 干净）：
#   pwsh -File tool/format_migrate_tall.ps1                 # 只格式化 + 报告
#   pwsh -File tool/format_migrate_tall.ps1 -Regenerate     # 顺带 dart run slang 重生成 i18n
#   pwsh -File tool/format_migrate_tall.ps1 -EnableCiCheck  # 同时把 --set-exit-if-changed 写进 CI
param(
  [switch]$Regenerate,
  [switch]$EnableCiCheck,
  [string]$Flutter = "D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat"
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Dart = Join-Path (Split-Path -Parent $Flutter) "dart.bat"

if ((git -C $Root status --porcelain | Measure-Object).Count -ne 0) {
  Write-Error "工作区不干净：先提交或 stash，再跑迁移（迁移必须单独成一条 commit）。"
}

$targets = @("fushi", "packages", "tool") | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path $_ }
Write-Host "dart format（tall 风格）: $($targets -join ', ')"
& $Dart format @targets

if ($Regenerate) {
  Push-Location (Join-Path $Root "fushi")
  try {
    & $Dart run slang
    & $Dart format lib/i18n/strings.g.dart
  } finally { Pop-Location }
}

$changed = (git -C $Root status --porcelain | Measure-Object).Count
Write-Host "已改动文件数：$changed"

if ($EnableCiCheck) {
  $ci = Join-Path $Root ".github/workflows/release.yml"
  if (-not (Test-Path $ci)) { Write-Error "找不到 $ci" }
  $text = Get-Content $ci -Raw
  if ($text -notmatch "dart format --output=none --set-exit-if-changed") {
    Write-Host "请在 release.yml 的 analyze 步骤前加：dart format --output=none --set-exit-if-changed fushi packages"
    Write-Host "（脚本不自动改 workflow：发布 workflow 受 tool/check_release_policy.ps1 守卫，改完要跑它。）"
  }
}

Write-Host @"
下一步：
  1. git add -A && git commit -m "style: migrate repo to Dart tall formatting"
  2. 通知所有在飞分支 rebase；冲突全部是格式噪音，`git rebase -X theirs` 后重跑本脚本。
  3. 之后新增 i18n 直接 `dart run slang` + `dart format`，tool/i18n_patch_generated.dart 可退役。
  4. 更新 CLAUDE.md「验证」与「i18n 纪律」两节，删掉「不要 format 既有文件」的临时口径。
"@
