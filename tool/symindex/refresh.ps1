# 定时刷新符号索引：把专用 worktree（主 checkout 同级的 ../fushi-wt/symindex，按仓库规则不放 .worktrees/）拨到最新 origin/develop，
# develop 没动就什么都不做；动了就解析依赖、经本机重活租约（fushi/tool/heavy.dart）重建索引。
# 由计划任务每小时调用（tool/symindex/install_task.ps1 注册），也可手动跑。
#
#   powershell -ExecutionPolicy Bypass -File tool/symindex/refresh.ps1 [-Force]
param([switch]$Force)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$commonDir = (git -C $here rev-parse --path-format=absolute --git-common-dir).Trim()
$main = Split-Path -Parent $commonDir
$wt = Join-Path (Split-Path -Parent $main) 'fushi-wt\symindex'
$log = Join-Path $env:LOCALAPPDATA 'fushi-symindex\refresh.log'
New-Item -ItemType Directory -Force (Split-Path -Parent $log) | Out-Null
function Write-Log([string]$msg) { "$(Get-Date -Format s) $msg" | Out-File -Append -Encoding utf8 $log }

git -C $main fetch origin develop --quiet
if ($LASTEXITCODE -ne 0) { Write-Log 'fetch failed'; exit 1 }
$tip = (git -C $main rev-parse origin/develop).Trim()

if (-not (Test-Path (Join-Path $wt '.git'))) {
    git -C $main worktree add --detach $wt $tip | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log 'worktree add failed'; exit 1 }
} else {
    $head = (git -C $wt rev-parse HEAD).Trim()
    if ($head -ne $tip) {
        git -C $wt checkout --detach --force $tip --quiet
        if ($LASTEXITCODE -ne 0) { Write-Log 'checkout failed'; exit 1 }
    }
}

$py = (Get-Command python).Source
$build = Join-Path $here 'build.py'
if (-not $Force) {
    # 退出码 0 = 索引已对应这个 develop 尖端，不用重建
    & $py $build --repo $wt --check 2>$null
    if ($LASTEXITCODE -eq 0) { exit 0 }
}

# 依赖解析（pub get + 补丁 + strings.g.dart）；依赖没变时很快
# setup_worktree.ps1 处理的是「当前目录所在的 worktree」，必须先进 $wt
Push-Location $wt
try {
    & cmd.exe /d /c "powershell -NoProfile -ExecutionPolicy Bypass -File tool\setup_worktree.ps1 >> `"$log`" 2>&1"
    $code = $LASTEXITCODE
} finally { Pop-Location }
if ($code -ne 0 -or -not (Test-Path (Join-Path $wt '.dart_tool\package_config.json'))) {
    Write-Log "setup_worktree failed (exit $code) or workspace still unresolved"; exit 1
}

$dart = if ($env:FUSHI_DART) { $env:FUSHI_DART } else { 'D:/flutter_sdk/flutter_3.47.6/bin/cache/dart-sdk/bin/dart.exe' }
$flags = "--repo `"$wt`""
if (-not $Force) { $flags += ' --if-changed' }
# 经 cmd 重定向：PS 5.1 里对原生命令用 2>&1，会把 stderr 每行（heavy 的排队提示）包成
# NativeCommandError，配合 ErrorActionPreference=Stop 直接中断脚本。
$cmdLine = "`"$dart`" tool/heavy.dart -- `"$py`" `"$build`" $flags >> `"$log`" 2>&1"
Push-Location (Join-Path $wt 'fushi')
try {
    & cmd.exe /d /c $cmdLine
    $code = $LASTEXITCODE
} finally { Pop-Location }
Write-Log "build exit $code at $tip"
exit $code
