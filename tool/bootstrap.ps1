# Workspace bootstrap for Windows (workaround for melos CJK encoding bug).
# On Linux/CI, use `dart run melos bootstrap` instead.
#
# 网络：`flutter pub get` 走的是本进程的环境变量（HTTPS_PROXY / HTTP_PROXY /
# NO_PROXY），子进程只能继承，不会自己去找代理。而 agent 每次工具调用都是新
# shell —— 上一条命令里 export/$env: 设的代理，到下一条起 setup_worktree.ps1 的
# 新 shell 就没了。本机直连 pub.dev 时好时坏，于是表现成「首跑 socket error，
# 带代理重跑就过」。这里把代理来源收敛成三条，并在真正开跑前先探一次连通性，
# 不通就把配法打在前面（只示警不拦路，实测单次探测会误报），pub get 真失败时
# 再把同一份配法作为报错抛出，而不是甩一句光秃秃的 socket error。
#   1) 调用方已设的 HTTPS_PROXY / HTTP_PROXY / ALL_PROXY（最高优先级）
#   2) FUSHI_BOOTSTRAP_PROXY（只影响 bootstrap，不污染其它工具）
#   3) <主 checkout>/tool/bootstrap.local.env（gitignore，本机私有，一次配置长期生效）
# 三条都没有也照常跑（CI / 直连可用的机器不受影响）。

$ErrorActionPreference = "Stop"

# 本文件含中文提示，必须存成 UTF-8 with BOM（Windows PowerShell 5.1 对无 BOM 的
# .ps1 按 ANSI/GBK 解码，中文注释会被解成乱码进而打爆语法分析）。输出侧同理：
# 不改 OutputEncoding，中文提示重定向到管道时是 GBK 字节，agent 读到的是乱码。
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent $PSScriptRoot

# --- flutter 可执行文件 ----------------------------------------------------
# 顺序：FUSHI_FLUTTER > 本机钉定路径（保持既有行为）> PATH。
function Resolve-FlutterExe {
    [OutputType([string])]
    param()

    if ($env:FUSHI_FLUTTER) {
        if (-not (Test-Path $env:FUSHI_FLUTTER)) {
            throw "FUSHI_FLUTTER 指向的文件不存在: $($env:FUSHI_FLUTTER)"
        }
        return $env:FUSHI_FLUTTER
    }

    $pinned = "D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat"
    if (Test-Path $pinned) { return $pinned }

    $onPath = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    throw "找不到 flutter：既不在 $pinned，也不在 PATH。设 FUSHI_FLUTTER=<flutter.bat 完整路径> 后重跑。"
}

# --- 代理解析 --------------------------------------------------------------
function Get-ProxyFromEnv {
    [OutputType([string])]
    param()

    # Windows 环境变量名大小写不敏感，只查大写即可覆盖 https_proxy 等写法。
    foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value.Trim() }
    }
    return $null
}

function Get-MainCheckoutRoot {
    [OutputType([string])]
    param([string]$Fallback)

    # worktree list 第一条永远是主 checkout；本机私有配置只存在那里，
    # 这样每个新 worktree 都不用再配一次。
    $line = & git worktree list --porcelain 2>$null |
        Select-String '^worktree ' |
        Select-Object -First 1
    if (-not $line) { return $Fallback }
    return ($line.Line -replace '^worktree ', '').Trim()
}

# 读 KEY=VALUE 形式的本机私有配置，只填当前进程尚未设置的变量（调用方显式设的永远赢）。
# 返回实际读到的文件路径；没有该文件返回 $null。
function Import-LocalBootstrapEnv {
    [OutputType([string])]
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) { return $null }

    # -Encoding UTF8 不能省：PowerShell 5.1 默认按 ANSI/GBK 解码，配置文件里带中文
    # 注释时，注释末尾落单的高位字节会把后面的换行当成 GBK 双字节的第二个字节吞掉，
    # 于是紧跟其后的那行（比如 HTTPS_PROXY=...）被并进注释里整行丢失。
    foreach ($rawLine in (Get-Content -LiteralPath $ConfigPath -Encoding UTF8)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^(?<k>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<v>.*)$') { continue }

        $key = $Matches['k']
        $value = $Matches['v'].Trim().Trim('"').Trim("'")
        if ([Environment]::GetEnvironmentVariable($key)) { continue }
        [Environment]::SetEnvironmentVariable($key, $value)
    }
    return $ConfigPath
}

# 探一次 pub.dev。必须显式指定代理：Windows PowerShell 的 .NET 默认走系统 IE 代理，
# 不认 HTTPS_PROXY 环境变量，不指定就测不到 pub 真正会走的那条路。
function Test-PubDevReachable {
    [OutputType([bool])]
    param(
        [string]$ProxyUrl,
        [int]$TimeoutSec = 10
    )

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create('https://pub.dev/api/packages/meta')
        $request.Method = 'HEAD'
        $request.Timeout = $TimeoutSec * 1000
        $request.ReadWriteTimeout = $TimeoutSec * 1000
        $request.UserAgent = 'fushi-bootstrap'
        if ($ProxyUrl) {
            $request.Proxy = New-Object Net.WebProxy($ProxyUrl, $true)
        }
        else {
            $request.Proxy = $null
        }
        $response = $request.GetResponse()
        $response.Close()
        return $true
    }
    catch {
        return $false
    }
}

function Resolve-BootstrapProxy {
    [OutputType([hashtable])]
    param([string]$RepoRoot)

    $fromEnv = Get-ProxyFromEnv
    if ($fromEnv) { return @{ Proxy = $fromEnv; Source = '调用方环境变量' } }

    if ($env:FUSHI_BOOTSTRAP_PROXY) {
        $explicit = $env:FUSHI_BOOTSTRAP_PROXY.Trim()
        return @{ Proxy = $explicit; Source = 'FUSHI_BOOTSTRAP_PROXY' }
    }

    $configPath = Join-Path (Get-MainCheckoutRoot -Fallback $RepoRoot) 'tool/bootstrap.local.env'
    $loaded = Import-LocalBootstrapEnv -ConfigPath $configPath
    $fromFile = Get-ProxyFromEnv
    if ($fromFile) { return @{ Proxy = $fromFile; Source = $loaded } }

    return @{ Proxy = $null; Source = $null }
}

# 配代理的三种办法。预检警告和 pub get 失败两处共用同一份文案，别各写各的。
function Get-ProxyHelpText {
    [OutputType([string])]
    param()

    return @"
按以下任一方式提供代理后重跑（优先级从高到低）：
  1) 和启动命令写在同一条命令里 —— agent 每次工具调用都是新 shell，
     上一条命令里设的环境变量不会留到下一条：
       PowerShell: `$env:HTTPS_PROXY='http://<host>:<port>'; powershell -ExecutionPolicy Bypass -File tool/setup_worktree.ps1
       Bash:       HTTPS_PROXY=http://<host>:<port> powershell -ExecutionPolicy Bypass -File tool/setup_worktree.ps1
  2) 只给 bootstrap 用，不污染其它工具：
       `$env:FUSHI_BOOTSTRAP_PROXY='http://<host>:<port>'
  3) 一次配置、所有 worktree 长期生效 —— 在主 checkout 建 tool/bootstrap.local.env
     （已 gitignore，仅本机，绝不入库）：
       HTTPS_PROXY=http://<host>:<port>
       NO_PROXY=localhost,127.0.0.1,::1
本机代理地址记在不入库的 CLAUDE.local.md 里，不要写进任何入库脚本。
"@
}

$flutter = Resolve-FlutterExe
Write-Host "flutter: $flutter" -ForegroundColor DarkGray

$resolved = Resolve-BootstrapProxy -RepoRoot $root
$proxy = [string]$resolved.Proxy
if ($proxy) {
    # 两个都填上：pub 按 scheme 分别取，缺一个就有请求绕过代理。
    # 写进 $env: 才会被 flutter / dart / bash ci/apply-patches.sh 这些子进程继承。
    if (-not $env:HTTPS_PROXY) { $env:HTTPS_PROXY = $proxy }
    if (-not $env:HTTP_PROXY) { $env:HTTP_PROXY = $proxy }
    Write-Host "代理: $proxy (来源: $($resolved.Source))" -ForegroundColor DarkGray
}

# 预检只是提前示警，不当闸门 —— 实测单次 HEAD 探测会误报（探测 10s 超时失败，
# 同一时刻 pub get 自带重试仍然 45s 跑通）。拿它拦下能跑的环境是纯粹的倒退，
# 所以这里只把话说在前面，真判死刑交给 pub get 自己。
if (-not $env:FUSHI_BOOTSTRAP_SKIP_NETCHECK) {
    if (-not (Test-PubDevReachable -ProxyUrl $proxy)) {
        if ($proxy) {
            Write-Warning "预检没连通 pub.dev（经代理 $proxy，来源: $($resolved.Source)，10s 超时）。可能只是抖动，继续往下跑；接下来若 pub get 报网络错误，先确认该代理进程还活着、端口没变。"
        }
        else {
            Write-Warning "预检没连通 pub.dev（直连，10s 超时），且当前没有配置任何代理。可能只是抖动，继续往下跑；接下来若 pub get 卡住或报 socket error，按下面的办法配代理后重跑。"
            Write-Host (Get-ProxyHelpText) -ForegroundColor DarkYellow
        }
        Write-Host "（本机就该直连、这条预检恒误报的话，设 FUSHI_BOOTSTRAP_SKIP_NETCHECK=1 可整个跳过预检。）" -ForegroundColor DarkGray
    }
}

$packages = @(
    "$root\packages\fushi_core",
    "$root\packages\fushi_dictionary",
    "$root\packages\fushi_anki",
    "$root\packages\fushi_audio",
    "$root\packages\fushi_platform",
    "$root\fushi"
)

foreach ($pkg in $packages) {
    $name = Split-Path -Leaf $pkg
    Write-Host "pub get: $name" -ForegroundColor Cyan
    Push-Location $pkg
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        if ($proxy) {
            throw "flutter pub get failed in $name（已经过代理 $proxy，来源: $($resolved.Source)）。若是网络错误，先确认该代理进程还活着、端口没变。"
        }
        throw ("flutter pub get failed in $name。若报 socket error / 超时，多半是直连 pub.dev 不通，而当前没有配置任何代理。`n`n" + (Get-ProxyHelpText))
    }
    Pop-Location
}

Write-Host "`nAll packages resolved." -ForegroundColor Green

# Apply pub-cache patches for the non-vendored packages (single source of truth:
# ci/apply-patches.sh). Requires bash (Git Bash) on PATH, same as CI.
Write-Host "Applying pub-cache patches..." -ForegroundColor Cyan
bash ci/apply-patches.sh
if ($LASTEXITCODE -ne 0) {
    throw "ci/apply-patches.sh failed."
}

Write-Host "`nBootstrap complete. Build with, e.g.:" -ForegroundColor Green
Write-Host "  cd fushi; & '$flutter' build windows --release"
