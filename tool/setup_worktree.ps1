<#
.SYNOPSIS
  新建 git worktree 后的一键就绪脚本。

.DESCRIPTION
  本仓库强制在独立 git worktree 里改代码。两类东西不会随 worktree 自动到位，
  历史上靠 agent 手动 cp / 手动配置，反复出错：

    1) 本地真值密钥 —— google_oauth_secret.dart / log_upload_secret.dart 已入库
       (占位/空默认值，fresh worktree 能编译、能跑 flutter test)，但本机的真值用
       `git update-index --skip-worktree` 隐藏在主 checkout 里。skip-worktree 是
       每个 worktree 各自 index 的标志，不会传播 —— 新 worktree 只拿到占位值，
       要在 worktree 里真机验证 Google Drive 登录 / 日志上传就缺真值。

    2) 依赖解析 —— .dart_tool 每个 worktree 独立，不跑 pub get / bootstrap，
       flutter test 直接跑不起来。

  本脚本：
    - 从主 checkout 把所有 skip-worktree 的本地真值文件搬进当前 worktree，
      并在当前 worktree 续上 skip-worktree(不显示 dirty、绝不会被误提交)。
      密钥清单是动态读取的(零硬编码)，以后新增此类本地真值文件自动覆盖。
    - 调 tool/bootstrap.ps1 完成 pub get + 打补丁(可用 -SkipBootstrap 跳过)。

.PARAMETER SkipBootstrap
  只搬运密钥，不跑 pub get / bootstrap。WorktreeCreate 钩子用此开关，避免在
  worktree 创建时同步阻塞数分钟；需要 flutter test 前再手动 tool/bootstrap.ps1。

.EXAMPLE
  # 在新建好的 worktree 目录里(cwd 在该 worktree 内)：
  pwsh -File tool/setup_worktree.ps1                # 搬密钥 + bootstrap
  pwsh -File tool/setup_worktree.ps1 -SkipBootstrap # 只搬密钥(秒级)
#>
[CmdletBinding()]
param([switch]$SkipBootstrap)

$ErrorActionPreference = "Stop"

# --- 定位当前 worktree 根 与 主 checkout 根 -------------------------------
$here = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if (-not $here) {
    throw "不在 git 仓库内，无法定位 worktree。先 cd 到目标 worktree 再运行。"
}

$mainLine = (& git worktree list --porcelain | Select-String '^worktree ' | Select-Object -First 1)
if (-not $mainLine) { throw "无法解析 git worktree list 输出。" }
$mainWt = ($mainLine.Line -replace '^worktree ', '').Trim()

# git 一律返回正斜杠；统一后大小写不敏感比较(Windows 路径不区分大小写)。
$hereN = ($here -replace '\\', '/')
$mainN = ($mainWt -replace '\\', '/')

# --- 搬运本地真值密钥 + 续 skip-worktree ----------------------------------
if ($hereN -ieq $mainN) {
    Write-Host "当前就是主 checkout ($here)，无需搬运密钥。" -ForegroundColor Yellow
}
else {
    # 主 checkout 里所有 skip-worktree(大写 S，含同时 assume-unchanged 的 s)文件。
    $secretFiles = & git -C $mainWt ls-files -v |
        Where-Object { $_ -match '^[Ss] ' } |
        ForEach-Object { ($_ -replace '^[Ss] ', '').Trim() }

    if (-not $secretFiles) {
        Write-Host "主 checkout 没有 skip-worktree 的本地真值文件，跳过密钥搬运。" -ForegroundColor Yellow
        Write-Host "(说明本机还没填真值，占位/空值已够编译与测试。)" -ForegroundColor DarkGray
    }
    else {
        foreach ($f in $secretFiles) {
            $src = Join-Path $mainWt $f
            $dst = Join-Path $here $f

            if (-not (Test-Path $src)) {
                Write-Host "  跳过(主 checkout 无此文件): $f" -ForegroundColor DarkYellow
                continue
            }
            # 目标必须已被 track(worktree checkout 出来的占位版)才能设 skip-worktree。
            & git -C $here ls-files --error-unmatch $f *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  跳过(worktree 未 track 此文件): $f" -ForegroundColor DarkYellow
                continue
            }
            # 先设 skip-worktree，git 从此不看工作区内容；再覆盖真值。
            & git -C $here update-index --skip-worktree $f | Out-Null

            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path $dstDir)) {
                New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
            }
            Copy-Item -Force -Path $src -Destination $dst
            Write-Host "  OK 真值已搬运 + skip-worktree: $f" -ForegroundColor Green
        }
    }
}

# --- bootstrap(pub get + 打补丁) ------------------------------------------
if ($SkipBootstrap) {
    Write-Host "`n已跳过 bootstrap。跑 flutter test 前请先: pwsh -File tool/bootstrap.ps1" -ForegroundColor Cyan
    return
}

Write-Host "`n开始 bootstrap (pub get + 打补丁)..." -ForegroundColor Cyan
$bootstrap = Join-Path $here 'tool/bootstrap.ps1'
if (-not (Test-Path $bootstrap)) { throw "找不到 $bootstrap" }
Push-Location $here
try {
    & $bootstrap
}
finally {
    Pop-Location
}
Write-Host "`nworktree 就绪。" -ForegroundColor Green
