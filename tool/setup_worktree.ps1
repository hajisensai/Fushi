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

  网络：bootstrap 是在本脚本同一个 PowerShell 进程里跑的，代理只能靠环境变量继承。
  agent 每次工具调用都是新 shell，上一条命令里设的 HTTPS_PROXY 不会留到下一条 ——
  要用代理就和启动命令写在同一条命令里，或者在主 checkout 建 tool/bootstrap.local.env
  (gitignore，本机私有)一次配好，后者对所有 worktree 长期生效。bootstrap 开跑前会先探
  一次 pub.dev，不通就把这几种配法打在前面，不再等几分钟后甩一句 socket error 了事。
  详见 tool/bootstrap.ps1 头部注释。

.PARAMETER SkipBootstrap
  只搬运密钥，不跑 pub get / bootstrap。WorktreeCreate 钩子用此开关，避免在
  worktree 创建时同步阻塞数分钟；需要 flutter test 前再手动 tool/bootstrap.ps1。

.PARAMETER SkipCacheSeed
  不从兄弟 worktree 复制 flutter test 的增量编译缓存(见下方「预热 flutter test
  编译缓存」一节)。默认会在 bootstrap 之后做这一步。

.EXAMPLE
  # 在新建好的 worktree 目录里(cwd 在该 worktree 内)：
  pwsh -File tool/setup_worktree.ps1                # 搬密钥 + bootstrap
  pwsh -File tool/setup_worktree.ps1 -SkipBootstrap # 只搬密钥(秒级)
#>
[CmdletBinding()]
param([switch]$SkipBootstrap, [switch]$SkipCacheSeed)

$ErrorActionPreference = "Stop"

# 本文件的中文提示重定向到管道时默认按 GBK 编码，agent 读到的是乱码。
# (文件本身必须存成 UTF-8 with BOM，否则 PowerShell 5.1 按 ANSI 解码源码。)
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

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
            # 用 `ls-files -- <path>`(未 track 时输出空、退出码 0)而非
            # `--error-unmatch`：后者未命中会写 stderr，PS 5.1 把原生命令的 stderr
            # 包成 NativeCommandError 而中断整个脚本 —— 主 checkout 与 worktree 分处
            # 目录改名前后的分支时(hibiki/ vs fushi/)必然逐个未命中，脚本会死在
            # 第一个密钥文件上，连后面的 bootstrap 都不跑。
            $tracked = & git -C $here ls-files -- $f
            if (-not $tracked) {
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
$bootstrapError = $null
Push-Location $here
try {
    & $bootstrap
}
catch {
    # 先记下，预热照做再抛：本机 bootstrap 常死在 apply-patches(bash 走了 WSL)，
    # 那时 pub get 已经成功，预热不依赖补丁(补丁打在全机共享的 pub cache 上)。
    $bootstrapError = $_
}
finally {
    Pop-Location
}

# --- 预热 flutter test 编译缓存 ------------------------------------------------
# 新 worktree 第一次 flutter test 慢在 frontend_server 从零编译(2026-10-07 实测
# 同一测试冷启动编译 4.7 分钟、预热后 3.2 分钟；重负载下冷编译曾到 20 分钟)，
# 不在 native-asset hooks(0.5~1.5 分钟)或 unit_test_assets(约 20 秒)。
# flutter test 用 fushi/build/test_cache/build/<md5>.cache.dill.track.dill 做
# --initialize-from-dill；文件名只由 dart-define / 前端参数 / Flutter 版本决定，
# 与 worktree 路径无关，所以从兄弟 worktree 拷过来能被直接命中。
# 内容安全性：frontend_server 拿到 dill 后按 package_config 重新解析每个
# package: 库的文件路径，路径与 dill 里记录的不同(本仓 fushi 与 packages/* 必然
# 如此)就整库重编，只复用 Flutter SDK 与 pub cache 里路径不变的库；再逐个比对
# 源码字节，变了的也重编。所以拷来的 dill 只影响速度、不影响正确性(实测预热
# 后产出的 dill 里源 worktree 的 fushi/lib、packages 路径为 0 处)。收益因此只
# 是 SDK 与 pub 依赖那部分的编译时间。
# 只拷 dill：.dart_tool/hooks_runner 的 input.json / 依赖哈希文件里写死了源
# worktree 的绝对路径，且 hook 依赖环境变量 PATH 的哈希(每个 shell 都不同)，
# 拷过来要么失效要么指向别人的目录；unit_test_assets 只按 mtime 判新旧，
# 拷来会用别的提交的资源冒充当前提交，二者都不拷。
function Get-FlutterSdkKey([string]$root) {
    $cfg = Join-Path $root '.dart_tool/package_config.json'
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    $text = [IO.File]::ReadAllText($cfg)
    $sdkRoot = [regex]::Match($text, '"flutterRoot"\s*:\s*"([^"]*)"')
    $sdkVersion = [regex]::Match($text, '"flutterVersion"\s*:\s*"([^"]*)"')
    if (-not $sdkRoot.Success -or -not $sdkVersion.Success) { return $null }
    return ($sdkRoot.Groups[1].Value.ToLowerInvariant() + '|' + $sdkVersion.Groups[1].Value)
}

function Get-LockHash([string]$root) {
    $lock = Join-Path $root 'pubspec.lock'
    if (-not (Test-Path -LiteralPath $lock)) { return $null }
    # Not Get-FileHash: when Windows PowerShell 5.1 is started from pwsh 7 or
    # Git Bash it inherits pwsh 7 module paths in PSModulePath, autoloads the
    # wrong Microsoft.PowerShell.Utility and Get-FileHash is "not recognized".
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($lock)))
    }
    finally {
        $sha.Dispose()
    }
}

function Invoke-TestKernelCacheSeed([string]$targetRoot) {
    $rel = 'fushi/build/test_cache/build'
    $targetDir = Join-Path $targetRoot $rel

    $targetSdk = Get-FlutterSdkKey $targetRoot
    if (-not $targetSdk) {
        Write-Host "跳过预热：本 worktree 没有 .dart_tool/package_config.json(pub get 没成功)。" -ForegroundColor Yellow
        return
    }
    $targetLock = Get-LockHash $targetRoot
    if (-not $targetLock) {
        Write-Host "跳过预热：本 worktree 没有 pubspec.lock。" -ForegroundColor Yellow
        return
    }
    if ((Test-Path -LiteralPath $targetDir) -and
        @(Get-ChildItem -LiteralPath $targetDir -Filter '*.dill' -File).Count -gt 0) {
        Write-Host "跳过预热：本 worktree 已有 flutter test 编译缓存。" -ForegroundColor DarkGray
        return
    }

    # 两分钟内还在写的 dill 可能是别人 flutter test 写到一半的，不拿。
    $cutoff = (Get-Date).AddMinutes(-2)
    $targetN = ($targetRoot -replace '\\', '/').TrimEnd('/')
    $noCache = 0; $lockDiffers = 0; $sdkDiffers = 0
    $best = $null; $bestDills = $null; $bestTime = [datetime]::MinValue

    $lines = & git -C $targetRoot worktree list --porcelain | Select-String '^worktree '
    foreach ($line in $lines) {
        $wt = ($line.Line -replace '^worktree ', '').Trim()
        if ((($wt -replace '\\', '/').TrimEnd('/')) -ieq $targetN) { continue }
        $srcDir = Join-Path $wt $rel
        if (-not (Test-Path -LiteralPath $srcDir)) { $noCache++; continue }
        $dills = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.dill' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 0 -and $_.LastWriteTime -lt $cutoff })
        if ($dills.Count -eq 0) { $noCache++; continue }
        if ((Get-LockHash $wt) -ne $targetLock) { $lockDiffers++; continue }
        if ((Get-FlutterSdkKey $wt) -ne $targetSdk) { $sdkDiffers++; continue }
        $newest = ($dills | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        if ($newest -gt $bestTime) {
            $best = $wt; $bestDills = $dills; $bestTime = $newest
        }
    }

    if (-not $best) {
        Write-Host ("跳过预热：没有可用的兄弟 worktree(无缓存 {0} 个，pubspec.lock 不同 {1} 个，Flutter SDK 不同 {2} 个)。" -f $noCache, $lockDiffers, $sdkDiffers) -ForegroundColor Yellow
        return
    }

    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    $totalMb = 0
    foreach ($d in $bestDills) {
        # 先写临时名再改名：flutter test 不会读到拷了一半的 dill。
        $tmp = Join-Path $targetDir ($d.Name + '.seeding')
        Copy-Item -LiteralPath $d.FullName -Destination $tmp -Force
        Move-Item -LiteralPath $tmp -Destination (Join-Path $targetDir $d.Name) -Force
        $totalMb += [math]::Round($d.Length / 1MB)
    }
    Write-Host ("OK 已从 {0} 预热 flutter test 编译缓存：{1} 个 dill，约 {2} MB(最新写于 {3:yyyy-MM-dd HH:mm})。" -f $best, $bestDills.Count, $totalMb, $bestTime) -ForegroundColor Green
}

if ($SkipCacheSeed) {
    Write-Host "`n已跳过 flutter test 编译缓存预热(-SkipCacheSeed)。" -ForegroundColor DarkGray
}
else {
    Write-Host "`n预热 flutter test 编译缓存..." -ForegroundColor Cyan
    try {
        Invoke-TestKernelCacheSeed $here
    }
    catch {
        Write-Host "预热失败(不影响 worktree 可用，首次 flutter test 只是慢)：$_" -ForegroundColor Yellow
    }
}

if ($bootstrapError) { throw $bootstrapError }
Write-Host "`nworktree 就绪。" -ForegroundColor Green
