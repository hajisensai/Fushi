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

.PARAMETER SkipNativeCompute
  透传给 tool/bootstrap.ps1：不备 Rust 原生库（fushi_compute / fushi_fsrs / fushi_web_core / fushi_rwkv，
  app 与 flutter test 的硬依赖；兄弟 worktree 有同源码产物时直接拷，否则需要 cargo 编）。跳过后
  flutter build / test 之前必须手动跑 tool/native_libs.ps1。

.EXAMPLE
  # 在新建好的 worktree 目录里(cwd 在该 worktree 内)：
  pwsh -File tool/setup_worktree.ps1                # 搬密钥 + bootstrap
  pwsh -File tool/setup_worktree.ps1 -SkipBootstrap # 只搬密钥(秒级)
#>
[CmdletBinding()]
param([switch]$SkipBootstrap, [switch]$SkipNativeCompute)

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

# --- 注册 i18n json 的按 key 三方合并驱动 -----------------------------------
# .gitattributes 把 fushi/lib/i18n/*.i18n.json 标成 merge=fushi-i18n-json；驱动命令
# 本身只能放 git config(不入库)。写的是仓库级 config，主 checkout 与所有 worktree
# 共用，幂等。没注册时 git 退回按行合并，不会出错，只是相邻 key 照样冲突。
& git -C $here config merge.fushi-i18n-json.name "Fushi i18n JSON key-level merge"
& git -C $here config merge.fushi-i18n-json.driver "dart fushi/tool/i18n_merge_driver.dart %O %A %B"
Write-Host "OK i18n json 合并驱动已注册(merge.fushi-i18n-json)" -ForegroundColor Green

# --- strings.g.dart 不入库：git 钩子 + 生成 -----------------------------------------
# fushi/lib/i18n/strings.g.dart 由 fushi/tool/gen_i18n.dart 生成、不入库：切分支 / 合并会删掉
# 或让它过期。tool/git_hooks/install.sh 往仓库级 hooks 目录(git rev-parse --git-path hooks，
# 主 checkout 与所有 worktree 共用；设了 core.hooksPath 就是那里)的 post-checkout / post-merge
# 写一段带标记的块(只改标记之间，用户自己的钩子行保留)，切换后调 tool/git_hooks/gen_i18n.sh
# 重新生成(戳记没变秒退)。硬门在 fushi/tool/heavy.dart：本机每次 analyze / test / build 前都生成。
function Resolve-SetupBash {
    [OutputType([string])]
    param()
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return 'bash' }
    # git --exec-path = <Git>/mingw64/libexec/git-core；git 钩子本身就由这份 Git 的 sh 执行。
    $execPath = (& git --exec-path | Out-String).Trim()
    if ($execPath) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $execPath))
        foreach ($rel in @('bin/bash.exe', 'usr/bin/bash.exe')) {
            $candidate = Join-Path $gitRoot $rel
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    throw "找不到 Git for Windows 的 bash(git --exec-path=$execPath)，装不了 i18n git 钩子。"
}
$setupBash = Resolve-SetupBash
Push-Location $here
try {
    & $setupBash tool/git_hooks/install.sh
    $hookExit = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($hookExit -ne 0) { throw "tool/git_hooks/install.sh failed (exit $hookExit)." }

# --- bootstrap(pub get + 打补丁) ------------------------------------------
if ($SkipBootstrap) {
    # bootstrap 会在 pub get 之后生成；跳过它时也要生成(依赖已解析过的 worktree 约 1~15 秒、
    # 不联网)。还没 pub get 过的 worktree 由 gen_i18n.sh 说明原因后跳过，失败则让本脚本失败。
    Push-Location $here
    try {
        & $setupBash tool/git_hooks/gen_i18n.sh setup
        $genExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($genExit -ne 0) { throw "tool/git_hooks/gen_i18n.sh setup failed (exit $genExit)." }
    # 不入库的预编译二进制（tool/vendored_binaries.json）也由 bootstrap 取回；跳过 bootstrap
    # 时它们缺席，读 libmpv / FFmpegKit / LunaHook 的构建和测试会报文件不存在。
    Write-Host "`n已跳过 bootstrap。跑 flutter test / build 前请先: pwsh -File tool/bootstrap.ps1（含取回不入库的预编译二进制；只要二进制: pwsh -File tool/vendored_binaries.ps1）" -ForegroundColor Cyan
    return
}

Write-Host "`n开始 bootstrap (pub get + 打补丁)..." -ForegroundColor Cyan
$bootstrap = Join-Path $here 'tool/bootstrap.ps1'
if (-not (Test-Path $bootstrap)) { throw "找不到 $bootstrap" }
Push-Location $here
try {
    & $bootstrap -SkipNativeCompute:$SkipNativeCompute
}
finally {
    Pop-Location
}

# --- 复用 build hook 的下载产物 -------------------------------------------------
# 新 worktree 第一次 flutter test 会让 pdfium_dart / sqlite3 的 build hook 各自从 GitHub
# 重下一遍（2026-11-20 实测 pdfium 约 17 秒）。下载产物在
# .dart_tool/hooks_runner/shared/<包>/build/ 下按内容寻址，与 worktree 路径无关，可以先拷进来；
# input.json、hook.dill、依赖哈希等写死了源 worktree 绝对路径的东西不拷。pdfium 的 hook 只看
# 文件在不在，所以工具只拷 sha256 与钉值相符的文件。细节见 fushi/tool/worktree_seed/hook_downloads.dart
# 与 docs/agent/build.md「新 worktree 第一次 flutter test」。
function Resolve-SetupDart {
    [OutputType([string])]
    param([string]$Root)
    # 用 pub get 写进 package_config 的那份 SDK（即 bootstrap 选中的 3.47.6），不用 PATH 上的 dart。
    $cfg = Join-Path $Root '.dart_tool/package_config.json'
    if (-not (Test-Path -LiteralPath $cfg)) { throw "找不到 $cfg（bootstrap 的 pub get 没成功）。" }
    $m = [regex]::Match([IO.File]::ReadAllText($cfg), '"flutterRoot"\s*:\s*"([^"]*)"')
    if (-not $m.Success) { throw "$cfg 里没有 flutterRoot。" }
    $sdk = ([Uri]$m.Groups[1].Value).LocalPath
    $exe = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'dart.bat' } else { 'dart' }
    $dart = Join-Path $sdk "bin/$exe"
    if (-not (Test-Path -LiteralPath $dart)) { throw "找不到 $dart。" }
    return $dart
}
$setupDart = Resolve-SetupDart -Root $here

Write-Host "`n复用 build hook 的下载产物..." -ForegroundColor Cyan
Push-Location $here
try {
    & $setupDart fushi/tool/worktree_seed.dart hooks --repo $here
    $hookSeedExit = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($hookSeedExit -ne 0) {
    # 只是少了加速：hook 会自己下载，worktree 照样可用；退出码原样报出来，不当成功。
    Write-Host "build hook 下载产物复用失败(exit $hookSeedExit)，首次 flutter test 会自己下载。" -ForegroundColor Yellow
}

Write-Host "`nworktree 就绪。" -ForegroundColor Green
