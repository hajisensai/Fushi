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
# 版本的唯一真相源是 fushi/.fvmrc（守卫 fushi/test/build/flutter_version_single_source_guard_test.dart
# 钉死它与 CI 同版）。按版本号找 SDK，绝不静默回退到 PATH 上版本不符的旧 flutter ——
# 旧版本编不过本仓，pub get 还会把 lockfile 切走。
# 顺序：FUSHI_FLUTTER（显式覆盖，不校验版本）> fvm 缓存 > 常见安装目录 > PATH 上版本相符的 flutter。
# 这里没有任何本机私有路径：所有候选都是「按版本号拼出来的目录」。

function Get-PinnedFlutterVersion {
    [OutputType([string])]
    param([string]$RepoRoot)

    $fvmrc = Join-Path $RepoRoot 'fushi/.fvmrc'
    if (-not (Test-Path -LiteralPath $fvmrc)) {
        throw "找不到 $fvmrc，无法确定本仓钉定的 Flutter 版本。"
    }
    $text = [IO.File]::ReadAllText($fvmrc)
    $m = [regex]::Match($text, '"flutter"\s*:\s*"([^"]+)"')
    if (-not $m.Success) {
        throw "$fvmrc 里没有 `"flutter`": `"<版本>`" 字段。"
    }
    return $m.Groups[1].Value.Trim()
}

# 读 SDK 自报的版本；读不到返回 $null（不执行 flutter，免得首跑触发下载 Dart SDK）。
function Get-FlutterSdkVersion {
    [OutputType([string])]
    param([string]$SdkRoot)

    $json = Join-Path $SdkRoot 'bin/cache/flutter.version.json'
    if (Test-Path -LiteralPath $json) {
        $m = [regex]::Match([IO.File]::ReadAllText($json), '"frameworkVersion"\s*:\s*"([^"]+)"')
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
    $legacy = Join-Path $SdkRoot 'version'
    if (Test-Path -LiteralPath $legacy) {
        $v = ([IO.File]::ReadAllText($legacy)).Trim()
        if ($v) { return $v }
    }
    return $null
}

function Get-FlutterExeInSdk {
    [OutputType([string])]
    param([string]$SdkRoot)

    foreach ($name in @('flutter.bat', 'flutter')) {
        $exe = Join-Path $SdkRoot (Join-Path 'bin' $name)
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function Get-FlutterSdkCandidates {
    [OutputType([string[]])]
    param([string]$Version)

    $candidates = New-Object System.Collections.Generic.List[string]

    # fvm 缓存：FVM_CACHE_PATH / FVM_HOME（新旧两代变量）> 各平台默认缓存位置。
    foreach ($base in @($env:FVM_CACHE_PATH, $env:FVM_HOME)) {
        if ($base) { $candidates.Add((Join-Path $base "versions/$Version")) }
    }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA "fvm/versions/$Version")) }
    if ($HOME) {
        $candidates.Add((Join-Path $HOME "fvm/versions/$Version"))
        $candidates.Add((Join-Path $HOME ".fvm/versions/$Version"))
    }

    # 常见手动安装目录：<盘符或家目录>/flutter_sdk/flutter_<版本>、<…>/flutter_<版本>。
    $bases = New-Object System.Collections.Generic.List[string]
    if ($HOME) { $bases.Add($HOME) }
    try {
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq [IO.DriveType]::Fixed) { $bases.Add($drive.RootDirectory.FullName) }
        }
    }
    catch { }
    foreach ($base in $bases) {
        $candidates.Add((Join-Path $base "flutter_sdk/flutter_$Version"))
        $candidates.Add((Join-Path $base "flutter_$Version"))
    }

    return $candidates.ToArray()
}

function Resolve-FlutterExe {
    [OutputType([string])]
    param([string]$RepoRoot)

    if ($env:FUSHI_FLUTTER) {
        if (-not (Test-Path $env:FUSHI_FLUTTER)) {
            throw "FUSHI_FLUTTER 指向的文件不存在: $($env:FUSHI_FLUTTER)"
        }
        return $env:FUSHI_FLUTTER
    }

    $version = Get-PinnedFlutterVersion -RepoRoot $RepoRoot
    $checked = New-Object System.Collections.Generic.List[string]

    foreach ($sdk in (Get-FlutterSdkCandidates -Version $version)) {
        $checked.Add($sdk)
        if (-not (Test-Path -LiteralPath $sdk)) { continue }
        $exe = Get-FlutterExeInSdk -SdkRoot $sdk
        if (-not $exe) { continue }
        # 目录名按版本号拼出来只是候选；SDK 自报了别的版本就不认。
        $reported = Get-FlutterSdkVersion -SdkRoot $sdk
        if ($reported -and $reported -ne $version) { continue }
        # fvm 缓存常是指向真实 SDK 的链接：按链接目标返回，同一份 SDK 只有一个路径
        # （package_config 的 flutterRoot、setup_worktree 的编译缓存预热都按路径认 SDK）。
        $item = Get-Item -LiteralPath $sdk
        if ($item.LinkType -and $item.Target) {
            $target = @($item.Target)[0]
            $targetExe = Get-FlutterExeInSdk -SdkRoot $target
            if ($targetExe) { return $targetExe }
        }
        return $exe
    }

    $mismatched = New-Object System.Collections.Generic.List[string]
    $onPath = @(Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue)
    $seenSdks = @{}
    foreach ($cmd in $onPath) {
        # PATH 上同一 bin 目录会同时命中 flutter.bat 与无扩展名的 shell 脚本，按 SDK 去重。
        $sdk = Split-Path -Parent (Split-Path -Parent $cmd.Source)
        if ($seenSdks.ContainsKey($sdk)) { continue }
        $seenSdks[$sdk] = $true
        $reported = Get-FlutterSdkVersion -SdkRoot $sdk
        if ($reported -eq $version) {
            $exe = Get-FlutterExeInSdk -SdkRoot $sdk
            if ($exe) { return $exe }
        }
        if (-not $reported) { $reported = '未知' }
        $mismatched.Add("$sdk（$reported）")
    }

    $pathNote = if ($mismatched.Count -gt 0) { "PATH 上的 flutter 版本不符：`n    " + ($mismatched -join "`n    ") } else { 'PATH 上没有 flutter。' }
    throw @"
找不到 Flutter $version（版本取自 fushi/.fvmrc）。不会回退到其它版本：旧版本编不过本仓，pub get 还会改写 lockfile。
$pathNote
已查找的目录：
    $($checked -join "`n    ")
任选其一后重跑：
  - fvm install $version
  - 把 Flutter $version 解压到上面任一目录
  - 设 FUSHI_FLUTTER=<Flutter $version 的 flutter.bat 完整路径>
"@
}

# --- Git for Windows 的 bash -----------------------------------------------
# 不能用 PATH 上的裸 `bash`：Windows 上它常解析到 C:\Windows\System32\bash.exe
# （WSL），ci/apply-patches.sh 在 WSL 里看到的是 Linux 侧的 pub cache 与工具链，
# 必然失败。按 git 自己的安装位置推导 Git Bash；非 Windows 直接用 PATH 上的 bash。
function Resolve-GitBash {
    [OutputType([string])]
    param()

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return 'bash' }

    $roots = New-Object System.Collections.Generic.List[string]
    # git --exec-path = <Git>/mingw64/libexec/git-core（或 mingw32 / clangarm64）。
    $execPath = (& git --exec-path 2>$null | Out-String).Trim()
    if ($execPath) {
        $roots.Add((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $execPath))))
    }
    # git.exe 在 <Git>/cmd 或 <Git>/bin 下。
    $gitCmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gitCmd) { $roots.Add((Split-Path -Parent (Split-Path -Parent $gitCmd.Source))) }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if ($base) { $roots.Add((Join-Path $base 'Git')) }
    }
    if ($env:LOCALAPPDATA) { $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs/Git')) }

    foreach ($root in $roots) {
        foreach ($rel in @('bin/bash.exe', 'usr/bin/bash.exe')) {
            $candidate = Join-Path $root $rel
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }

    throw "找不到 Git for Windows 的 bash.exe（已按 git --exec-path 与常见安装目录查找：$($roots -join '; ')）。不会用 PATH 上的 bash：那通常是 WSL。安装 Git for Windows 后重跑。"
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

$flutter = Resolve-FlutterExe -RepoRoot $root
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

# Pub workspace：解析只在根发生一次，产出唯一的 pubspec.lock 和唯一的
# .dart_tool/package_config.json，所有成员共用。
#
# 这里以前是逐个 cd 进 6 个包各跑一次 pub get —— 那是 Melos 6 的做法，也正是
# 「主 app 与包各解析各的」的本地来源：fushi 被入库的 lock 钉在 sqlite3 3.3.3，
# packages/fushi_core 自己解析却拿到 3.5.2，包测试验证的依赖版本和生产跑的不是
# 同一个。改用 workspace 后各包的 pubspec.lock 由 pub 自动删除，再逐个 pub get
# 既是浪费也会重新制造 stray files。
Write-Host "pub get: workspace root" -ForegroundColor Cyan
Push-Location $root
& $flutter pub get
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    if ($proxy) {
        throw "flutter pub get failed in workspace root（已经过代理 $proxy，来源: $($resolved.Source)）。若是网络错误，先确认该代理进程还活着、端口没变。"
    }
    throw ("flutter pub get failed in workspace root。若报 socket error / 超时，多半是直连 pub.dev 不通，而当前没有配置任何代理。`n`n" + (Get-ProxyHelpText))
}
Pop-Location

Write-Host "`nWorkspace resolved (single lockfile at repo root)." -ForegroundColor Green

# Apply pub-cache patches for the non-vendored packages (single source of truth:
# ci/apply-patches.sh), run with Git Bash (see Resolve-GitBash; never the WSL bash).
$gitBash = Resolve-GitBash
Write-Host "Applying pub-cache patches... (bash: $gitBash)" -ForegroundColor Cyan
# apply-patches.sh 自己找 SDK 打 flutter-sdk 补丁时优先认 FLUTTER_ROOT、否则取 PATH 上的
# flutter —— 必须钉成上面 pub get 用的同一份 SDK，否则补丁打到 PATH 上的旧版本上。
# 用正斜杠：交给 Git Bash 的路径别带反斜杠。
$flutterSdkRoot = (Split-Path -Parent (Split-Path -Parent $flutter)) -replace '\\', '/'
$previousFlutterRoot = $env:FLUTTER_ROOT
$env:FLUTTER_ROOT = $flutterSdkRoot
Push-Location $root
try {
    & $gitBash ci/apply-patches.sh
    $patchExit = $LASTEXITCODE
}
finally {
    Pop-Location
    $env:FLUTTER_ROOT = $previousFlutterRoot
}
if ($patchExit -ne 0) {
    throw "ci/apply-patches.sh failed (bash: $gitBash, exit $patchExit)."
}

Write-Host "`nBootstrap complete. Build with, e.g.:" -ForegroundColor Green
Write-Host "  cd fushi; & '$flutter' build windows --release"
