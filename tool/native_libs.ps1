<#
.SYNOPSIS
  备好 app 与 flutter test 硬依赖的 Rust 原生库（fushi_compute / fushi_fsrs / fushi_web_core / fushi_rwkv / fushi_music / fushi_corpus）。

.DESCRIPTION
  tool/bootstrap.ps1 在 pub get 之后调用本脚本；已有 worktree 缺库（测试成片报
  FushiComputeUnavailableError / FUSHI_FSRS_LIB / FushiWebCoreLibraryMissing）时也可单独跑：
    powershell -ExecutionPolicy Bypass -File tool/native_libs.ps1

  每个 crate 按顺序：
    1) 本地 prebuilt/<平台>/ 旁的戳记（<产物>.source：native/<crate> 的源码内容键 + 产物大小 + mtime）
       与 HEAD 一致 → 跳过；
    2) 兄弟 worktree（含主 checkout）里有戳记一致的产物 → 拷过来（秒级，免 cargo）；
    3) 否则跑 native/<crate>/build_* 编译，编完写戳记（此时才需要 cargo）。
  native/<crate> 有未提交改动时不复用也不写戳记，按工作区源码编。
  产物落在 native/<crate>/prebuilt/<平台>/，测试宿主下的加载器会向上找到它，不必设 FUSHI_*_LIB。

  fushi_fsrs 另备一份带 ID 审计的库（cargo feature id_audit）到 prebuilt/<平台>/id_audit/：只有调试构建与测试
  宿主加载它（packages/fushi_srs 的 kFushiFsrsIdAuditDir），不随包。它与普通库同一次构建脚本调用编出、各有
  各的戳记，复用规则相同。

  备哪些 crate、带什么 feature、要不要 id_audit 那份，全部取自登记表 native/crates.json
  （经 tool/native_crates.py 读；新增 crate 只改登记表，本脚本不列名字）：主机平台备
  `host_test_lib: true` 的，-Android 备 Android 上 `required: always` 的 Rust crate。它们必须自带
  登记表 build.<平台> 写的构建脚本、产物落 prebuilt/<平台>/。戳记的源码键也由
  tool/native_crates.py 算（`key`：native/<crate> 加登记表 external_sources 等输入的已提交内容，
  与 dist worker、CI 原生产物库同一个函数；tool/native_crates_test.py 钉住）。

  -Android：改为备 Android 出包硬依赖的 .so（`fushi/android/app/build.gradle` 的 checkFushi*Native 查的那几个），落在
  native/<crate>/prebuilt/android/<abi>/。新 worktree 不带它们，bootstrap 也不编（多数 worktree 从不出
  Android 包，五个 crate × 三个 ABI 的 release 交叉编译要几十分钟）；需要时由 gradle 的
  ensureFushiAndroidNative 任务自动调用本模式，也可手动跑：
    powershell -ExecutionPolicy Bypass -File tool/native_libs.ps1 -Android [-Abis arm64-v8a,armeabi-v7a,x86_64]
  顺序同上，多一级本机缓存（worktree 每天被清理，兄弟里常常没有）：
    1) 本地戳记一致 → 跳过；
    2) 本机缓存 <LOCALAPPDATA>/fushi-native-cache（FUSHI_NATIVE_CACHE 可改）里有这棵源码树编出的产物 → 拷过来；
    3) 兄弟 worktree 里有戳记一致的产物 → 拷过来；
    4) 否则跑 native/<crate>/build_android_so.ps1 编（要 cargo-ndk 与 NDK），编完写戳记并存进本机缓存。
  所以同一份 native/<crate> 源码在一台机器上只编一次。

.PARAMETER GitBash
  Linux / macOS 跑 build_*.sh 用的 bash（Windows 走 .ps1，用不到）。

.PARAMETER Android
  备 Android 的 .so 而不是主机平台的库。

.PARAMETER PrintKeys
  只打印各主机测试库 crate 的源码键（不带 feature 后缀）后退出，不备库。

.PARAMETER Abis
  -Android 时要备的 ABI，默认三个（与 split-per-abi 发布包一致）。
#>
[CmdletBinding()]
param(
    [string]$GitBash = 'bash',
    [switch]$Android,
    [switch]$PrintKeys,
    [string[]]$Abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64')
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'python3.ps1')
# 登记表读取与源码键的唯一实现（tool/native_crates.py）；缺 Python 时 Resolve-Python3 直接抛错，不静默降级。
$NativePython = Resolve-Python3
$NativeCratesPy = Join-Path $PSScriptRoot 'native_crates.py'

# 跑一次 tool/native_crates.py，返回退出码与 stdout 各行。stderr 原样转给用户（PS 5.1 在
# ErrorActionPreference=Stop 下会把原生命令的 stderr 变成终止性错误，所以本函数内放宽到 Continue）。
function Invoke-NativeCrates {
    [OutputType([hashtable])]
    param([string[]]$Arguments)

    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $lines = @()
    $prefix = @($NativePython | Select-Object -Skip 1)
    & $NativePython[0] @prefix $NativeCratesPy @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
        else {
            $lines += [string]$_
        }
    }
    return @{ Code = [int]$LASTEXITCODE; Lines = $lines }
}

function Get-NativeCrateList {
    [OutputType([string[]])]
    param([string[]]$Filter)

    $r = Invoke-NativeCrates -Arguments (@('list') + $Filter)
    if ($r.Code -ne 0 -or $r.Lines.Count -eq 0) {
        throw "tool/native_crates.py list $($Filter -join ' ') 失败（exit $($r.Code)）：native/crates.json 读不了或筛出零个 crate。"
    }
    return , $r.Lines
}

function Get-NativeCrateField {
    [OutputType([string])]
    param([string]$Crate, [string]$Field)

    $r = Invoke-NativeCrates -Arguments @('get', $Crate, $Field)
    if ($r.Code -ne 0) { throw "tool/native_crates.py get $Crate $Field 失败（exit $($r.Code)）。" }
    return (($r.Lines -join "`n").Trim())
}

# 缺 cargo 时（需要编的那一刻）直接失败而不是跳过：跳过的结果是之后 flutter build / test
# 在 CMake / Gradle / 加载器里才报错，离原因更远。
# 带 `id_audit: true` 的 crate 另备一份带 ID 审计的库（prebuilt/<平台>/id_audit/<产物>）：构建脚本认 -IdAudit（.ps1）/
# FUSHI_FSRS_ID_AUDIT_VARIANT=1（.sh），一次调用把两份都编出来。
$NativeIdAuditDir = 'id_audit'

# 测试用的库要带的 cargo feature 是登记表的 test_features（经 FUSHI_FSRS_FEATURES 交给 build_* 脚本）：fushi_fsrs 的
# `raw_sql` 是测试专用的原始 SQL 通道（native/fushi_fsrs/Cargo.toml），fushi_engine / fushi 的测试靠它直接改库造场景。
# feature 记进戳记（源码键后接 `+<features>`，`key --features`）：不带它编出的旧产物不会被当成这棵树的、也不会被兄弟
# worktree 拷走。注意：这里备的库同时是本机 `flutter run` / 本机 `flutter build` 随包的那一份，所以本机自己编的 app 带
# 原始通道；CI 出的发布包不带（verify_abi.sh / build_windows_dll.ps1 核对）。

function Get-NativeHostLayout {
    [OutputType([hashtable])]
    param()

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return @{ Dir = 'windows-x64'; Prefix = ''; Ext = '.dll'; Script = 'build_windows_dll.ps1' }
    }
    $isMac = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)
    if ($isMac) {
        return @{ Dir = 'macos'; Prefix = 'lib'; Ext = '.dylib'; Script = 'build_macos_dylib.sh' }
    }
    return @{ Dir = 'linux-x64'; Prefix = 'lib'; Ext = '.so'; Script = 'build_linux_so.sh' }
}

# native/<crate> 的源码内容键：tool/native_crates.py `key`（dist worker 与 CI 原生产物库调的同一个函数）。
# -WithFeatures 时后接 `+<test_features>`。该 crate 的任一输入有未提交改动（含未跟踪文件，不含
# target/ prebuilt/ 这些 ignored）时返回 $null —— 产物对应的源码说不清，不写戳记、不复用；
# 算键本身失败（git 不可用等）也返回 $null，只意味着「不复用、照常编」。
function Get-NativeSourceTree {
    [OutputType([string])]
    param([string]$Crate, [switch]$WithFeatures)

    $arguments = @('key', $Crate, '--require-clean')
    if ($WithFeatures) { $arguments += '--features' }
    $r = Invoke-NativeCrates -Arguments $arguments
    if ($r.Code -ne 0 -or $r.Lines.Count -ne 1) { return $null }
    return $r.Lines[0].Trim()
}

# 戳记文件的位置：主机平台的库是 <产物>.source；Android 的 .so 所在目录（prebuilt/android/）整个是 gradle 的
# jniLibs 源目录，放在里面的任何文件都会被 merge<Variant>JniLibFolders 收进去（2026-11-20 实测 .source 出现在
# merged_jni_libs 里），所以戳记放到旁边的 prebuilt/android-stamps/<abi>/。
function Get-NativeStampPath {
    [OutputType([string])]
    param([string]$Lib)

    $norm = $Lib -replace '\\', '/'
    if ($norm -match '/prebuilt/android/') {
        return (($norm -replace '/prebuilt/android/', '/prebuilt/android-stamps/') + '.source')
    }
    return "$Lib.source"
}

# 戳记 = <产物>.source（JSON：tree / length / mtimeUtcTicks）。大小与 mtime 也要对上：有人手动
# 重编（或别的 worktree 正在覆盖）后旧戳记自动失效，不会把别的源码编出的库当成这棵树的。
function Test-NativeStamp {
    [OutputType([bool])]
    param([string]$Lib, [string]$Tree)

    $stamp = Get-NativeStampPath -Lib $Lib
    if (-not $Tree -or -not (Test-Path -LiteralPath $Lib) -or -not (Test-Path -LiteralPath $stamp)) {
        return $false
    }
    try {
        $s = [IO.File]::ReadAllText($stamp) | ConvertFrom-Json
        $f = Get-Item -LiteralPath $Lib
        return ($s.tree -eq $Tree) -and ([int64]$s.length -eq $f.Length) -and
            ([int64]$s.mtimeUtcTicks -eq $f.LastWriteTimeUtc.Ticks)
    }
    catch {
        return $false
    }
}

function Write-NativeStamp {
    [OutputType([void])]
    param([string]$Lib, [string]$Tree)

    $stamp = Get-NativeStampPath -Lib $Lib
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stamp) | Out-Null
    if (-not $Tree) {
        if (Test-Path -LiteralPath $stamp) { Remove-Item -LiteralPath $stamp -Force }
        return
    }
    $f = Get-Item -LiteralPath $Lib
    $json = '{"tree":"' + $Tree + '","length":' + $f.Length + ',"mtimeUtcTicks":' + $f.LastWriteTimeUtc.Ticks + '}'
    [IO.File]::WriteAllText($stamp, $json, (New-Object Text.UTF8Encoding($false)))
}

# 从兄弟 worktree（含主 checkout）找戳记与 $Tree 一致的产物，拷到 $Lib；拷成功返回来源目录。
function Copy-NativeFromSibling {
    [OutputType([string])]
    param([string]$RepoRoot, [string]$Crate, [string]$RelLib, [string]$Lib, [string]$Tree)

    $selfN = ($RepoRoot -replace '\\', '/').TrimEnd('/')
    $lines = & git -C $RepoRoot worktree list --porcelain | Select-String '^worktree '
    foreach ($line in $lines) {
        $wt = ($line.Line -replace '^worktree ', '').Trim()
        if ((($wt -replace '\\', '/').TrimEnd('/')) -ieq $selfN) { continue }
        $src = Join-Path $wt $RelLib
        if (-not (Test-NativeStamp -Lib $src -Tree $Tree)) { continue }
        $dir = Split-Path -Parent $Lib
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # 先写临时名再改名：并发跑的测试不会读到拷了一半的库。
        $tmp = "$Lib.seeding"
        Copy-Item -LiteralPath $src -Destination $tmp -Force
        # 拷完再核一次来源：拷的过程中对方若开始重编，大小 / mtime 会变。
        if (-not (Test-NativeStamp -Lib $src -Tree $Tree)) {
            Remove-Item -LiteralPath $tmp -Force
            continue
        }
        Move-Item -LiteralPath $tmp -Destination $Lib -Force
        return $wt
    }
    return $null
}

function Invoke-NativeCrateBuild {
    [OutputType([void])]
    param([string]$RepoRoot, [string]$GitBash, [string]$Crate, [hashtable]$Layout, [bool]$IdAudit)

    $cargo = Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cargo) {
        throw @"
找不到 cargo：native/$Crate（Rust）是 app 与 flutter test 的硬依赖，本机 / 兄弟 worktree 都没有同源码的现成产物，必须编出来。
  - 安装 Rust：https://rustup.rs （Windows 需 MSVC 工具链：rustup target add x86_64-pc-windows-msvc）
  - 装好后重跑本脚本；或先用 -SkipNativeCompute（FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1）跳过，
    之后手动跑 native/$Crate/ 下对应平台的 build_* 脚本。
"@
    }
    $script = Join-Path (Join-Path $RepoRoot "native/$Crate") $Layout.Script
    # 跨 worktree 共用编译缓存：每个 worktree 的 target/ 各自独立，不能共用一个 target 目录
    # （cdylib 产物不带哈希，别的 worktree 编的库会被当成新鲜产物链进来；并发构建还会互相等锁）。
    # sccache 按内容哈希缓存 rustc 输出，crates.io 依赖在所有 worktree 里路径相同（~/.cargo/registry），
    # 能跨 worktree、跨 crate 命中；cdylib 的最终链接不缓存，正好每次用本 worktree 的源码。
    # 命中率有限（2026-11-11 实测 fushi_fsrs 换 target 目录后约两成：带 build script 的依赖把 target 下的
    # OUT_DIR 编进产物，下游跟着失配），冷编约省四成；见 docs/agent/build.md「Rust 本地开发循环」。
    # 装了就用（调用方已设 RUSTC_WRAPPER 时尊重调用方），没装照常编。
    $previousWrapper = $env:RUSTC_WRAPPER
    if (-not $previousWrapper) {
        $sccache = Get-Command sccache -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        # 缓存是可选的加速，不能变成硬依赖。2026-11-20 本机实测：cargo 拉起的 sccache 客户端间歇性报
        # 「Server startup failed: A Windows port exclusion is blocking use of the configured port …
        # os error 10013」并退 2，cargo 连 `rustc -vV` 都跑不了，整个备库失败；同一条命令隔一会儿又
        # 正常（6 次里 6 次过）。当时服务其实在监听（netstat 可见）：客户端没连上就自己再起一个，绑
        # 已被独占的端口得到 10013，那句「port exclusion」是 sccache 对这个错误码的猜测，端口并不在
        # 系统排除范围里。客户端为什么会连不上没查清（多个会话同时编译时出现）。所以这里：先把服务
        # 起好并确认它应答，起不来就不挂；挂了之后构建失败，再不挂缓存编一次（见下面的 try）。
        $sccacheUp = $false
        if ($sccache) {
            $null = & cmd /c "`"$($sccache.Source)`" --start-server >nul 2>&1"
            $null = & cmd /c "`"$($sccache.Source)`" --show-stats >nul 2>&1"
            $sccacheUp = ($LASTEXITCODE -eq 0)
        }
        if ($sccacheUp) {
            $env:RUSTC_WRAPPER = $sccache.Source
            Write-Host "  rustc 编译缓存：sccache ($($sccache.Source))" -ForegroundColor DarkGray
        }
        elseif ($sccache) {
            Write-Host "  sccache 的服务起不来（sccache --show-stats 失败），这次不用缓存、照常编。" -ForegroundColor DarkYellow
        }
        else {
            Write-Host "  未装 sccache：依赖每个 worktree 都要从零编。装上（winget install Mozilla.sccache）后自动跨 worktree 共用缓存。" -ForegroundColor DarkYellow
        }
    }
    # 两份库（普通 / id_audit）都带登记表 test_features 的 feature：构建脚本把 FUSHI_FSRS_FEATURES 并进审计那份。
    $features = Get-NativeCrateField -Crate $Crate -Field 'test_features'
    $previousFeatures = $env:FUSHI_FSRS_FEATURES
    if ($features) { $env:FUSHI_FSRS_FEATURES = $features }
    Write-Host "Building native/$Crate (cargo: $($cargo.Source))$(if ($features) { " features $features" })..." -ForegroundColor Cyan
    $previousVariant = $env:FUSHI_FSRS_ID_AUDIT_VARIANT
    $runBuild = {
        if ($Layout.Script.EndsWith('.ps1')) {
            if ($IdAudit) { & $script -IdAudit } else { & $script }
            return
        }
        if ($IdAudit) { $env:FUSHI_FSRS_ID_AUDIT_VARIANT = '1' }
        & $GitBash $script
        if ($LASTEXITCODE -ne 0) { throw "native/$Crate/$($Layout.Script) failed (exit $LASTEXITCODE)." }
    }
    try {
        # 本函数自己挂上的 sccache 才有「不挂再编一次」：调用方设的 RUSTC_WRAPPER 是调用方的选择，
        # 没挂缓存时失败就是失败。真正的编译错误第二次照样失败，只多花一次增量构建的时间。
        $ownWrapper = (-not $previousWrapper) -and $env:RUSTC_WRAPPER
        try {
            & $runBuild
        }
        catch {
            if (-not $ownWrapper) { throw }
            Write-Host "  挂着 sccache 的构建失败（$($_.Exception.Message)）；不挂缓存再编一次，以分清是缓存还是代码的问题。" -ForegroundColor DarkYellow
            $env:RUSTC_WRAPPER = $null
            & $runBuild
        }
    }
    finally {
        $env:RUSTC_WRAPPER = $previousWrapper
        $env:FUSHI_FSRS_FEATURES = $previousFeatures
        $env:FUSHI_FSRS_ID_AUDIT_VARIANT = $previousVariant
    }
}

function Install-NativeTestCrate {
    [OutputType([void])]
    param([string]$RepoRoot, [string]$GitBash, [string]$Crate)

    $layout = Get-NativeHostLayout
    $name = "$($layout.Prefix)$Crate$($layout.Ext)"
    $idAudit = (Get-NativeCrateField -Crate $Crate -Field 'id_audit') -eq 'true'
    # 这个 crate 要备的全部产物（相对仓库根）：普通库，加上带 ID 审计的那份（如有）。
    $relLibs = @("native/$Crate/prebuilt/$($layout.Dir)/$name")
    if ($idAudit) { $relLibs += "native/$Crate/prebuilt/$($layout.Dir)/$NativeIdAuditDir/$name" }
    $tree = Get-NativeSourceTree -Crate $Crate -WithFeatures

    $missing = @($relLibs | Where-Object { -not (Test-NativeStamp -Lib (Join-Path $RepoRoot $_) -Tree $tree) })
    if ($missing.Count -eq 0) {
        Write-Host "OK native/$Crate 已是 HEAD 源码编出的产物，跳过。" -ForegroundColor DarkGray
        return
    }
    if ($tree) {
        $from = $null
        $stillMissing = @()
        foreach ($rel in $missing) {
            $lib = Join-Path $RepoRoot $rel
            $src = Copy-NativeFromSibling -RepoRoot $RepoRoot -Crate $Crate -RelLib $rel -Lib $lib -Tree $tree
            if ($src) {
                Write-NativeStamp -Lib $lib -Tree $tree
                $from = $src
            }
            else {
                $stillMissing += $rel
            }
        }
        if ($stillMissing.Count -eq 0) {
            Write-Host "OK native/$Crate 复用 $from 的同源码产物（树 $($tree.Substring(0, 10))），未编译。" -ForegroundColor Green
            return
        }
    }
    else {
        Write-Host "native/$Crate 有未提交改动，按当前工作区源码编译。" -ForegroundColor Yellow
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-NativeCrateBuild -RepoRoot $RepoRoot -GitBash $GitBash -Crate $Crate -Layout $layout -IdAudit $idAudit
    foreach ($rel in $relLibs) {
        $lib = Join-Path $RepoRoot $rel
        if (-not (Test-Path -LiteralPath $lib)) { throw "native/$Crate 构建后缺少产物 $lib" }
        Write-NativeStamp -Lib $lib -Tree $tree
    }
    Write-Host ("OK native/$Crate 编译完成（{0:N0} 秒）。" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
}

# --- Android 出包硬依赖的 .so（-Android） ------------------------------------------------------

# 本机缓存里每个产物保留最近用过的几棵源码树。
$NativeCacheKeepTrees = 4

function Get-NativeCacheRoot {
    [OutputType([string])]
    param()

    if ($env:FUSHI_NATIVE_CACHE) { return $env:FUSHI_NATIVE_CACHE }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'fushi-native-cache') }
    return (Join-Path $HOME '.cache/fushi-native-cache')
}

# 缓存位置：<根>/<产物相对路径的目录>/<源码树哈希>/<文件名>。路径里的树哈希就是戳记：只有干净的
# 源码树编出的产物才存进来（Save-NativeToCache 的调用方保证），所以不另写 .source。
function Get-NativeCachePath {
    [OutputType([string])]
    param([string]$RelLib, [string]$Tree)

    $dir = Split-Path -Parent $RelLib
    $name = Split-Path -Leaf $RelLib
    return (Join-Path (Join-Path (Join-Path (Get-NativeCacheRoot) $dir) $Tree) $name)
}

function Copy-NativeFromCache {
    [OutputType([bool])]
    param([string]$RelLib, [string]$Lib, [string]$Tree)

    $src = Get-NativeCachePath -RelLib $RelLib -Tree $Tree
    if (-not (Test-Path -LiteralPath $src) -or (Get-Item -LiteralPath $src).Length -le 0) { return $false }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Lib) | Out-Null
    $tmp = "$Lib.seeding"
    Copy-Item -LiteralPath $src -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $Lib -Force
    # 记一次「用过」：清理按目录的最后写入时间留最近的几棵树。
    (Get-Item -LiteralPath (Split-Path -Parent $src)).LastWriteTimeUtc = [DateTime]::UtcNow
    return $true
}

function Save-NativeToCache {
    [OutputType([void])]
    param([string]$RelLib, [string]$Lib, [string]$Tree)

    $dst = Get-NativeCachePath -RelLib $RelLib -Tree $Tree
    $treeDir = Split-Path -Parent $dst
    New-Item -ItemType Directory -Force -Path $treeDir | Out-Null
    # 先写临时名再改名：别的 worktree 不会拷到写了一半的库。
    $tmp = "$dst.$PID.tmp"
    Copy-Item -LiteralPath $Lib -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $dst -Force
    $old = @(Get-ChildItem -LiteralPath (Split-Path -Parent $treeDir) -Directory |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip $NativeCacheKeepTrees)
    foreach ($d in $old) {
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop } catch { }
    }
}

function Install-NativeAndroidCrate {
    [OutputType([void])]
    param([string]$RepoRoot, [string]$Crate, [string[]]$Abis)

    $relLibs = @($Abis | ForEach-Object { "native/$Crate/prebuilt/android/$_/lib$Crate.so" })
    $tree = Get-NativeSourceTree -Crate $Crate
    $missing = @($relLibs | Where-Object { -not (Test-NativeStamp -Lib (Join-Path $RepoRoot $_) -Tree $tree) })
    if ($missing.Count -eq 0) {
        Write-Host "OK native/$Crate (android) 已是 HEAD 源码编出的产物，跳过。" -ForegroundColor DarkGray
        return
    }
    if ($tree) {
        $from = @()
        $stillMissing = @()
        foreach ($rel in $missing) {
            $lib = Join-Path $RepoRoot $rel
            if (Copy-NativeFromCache -RelLib $rel -Lib $lib -Tree $tree) {
                Write-NativeStamp -Lib $lib -Tree $tree
                $from += '本机缓存'
                continue
            }
            $src = Copy-NativeFromSibling -RepoRoot $RepoRoot -Crate $Crate -RelLib $rel -Lib $lib -Tree $tree
            if ($src) {
                Write-NativeStamp -Lib $lib -Tree $tree
                Save-NativeToCache -RelLib $rel -Lib $lib -Tree $tree
                $from += $src
            }
            else {
                $stillMissing += $rel
            }
        }
        if ($stillMissing.Count -eq 0) {
            $where = (@($from | Select-Object -Unique)) -join '、'
            Write-Host "OK native/$Crate (android) 复用 $where 的同源码产物（树 $($tree.Substring(0, 10))），未编译。" -ForegroundColor Green
            return
        }
    }
    else {
        Write-Host "native/$Crate 有未提交改动，按当前工作区源码编译（不进缓存）。" -ForegroundColor Yellow
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "native/$Crate 的 Android .so 没有现成产物；非 Windows 主机请直接跑 bash native/$Crate/build_android_so.sh <ndk-root> $($Abis -join ' ')。"
    }
    $cargo = Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cargo) {
        throw "找不到 cargo：native/$Crate 的 Android .so 在本机缓存与兄弟 worktree 里都没有同源码的现成产物，必须编（Rust + cargo-ndk + NDK，见 docs/agent/build.md）。"
    }
    Write-Host "Building native/$Crate for Android ($($Abis -join ', '))..." -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # 一次调用编齐全部 ABI：依赖只解析一遍，产物齐不齐由下面逐个核对。
    & (Join-Path (Join-Path $RepoRoot "native/$Crate") 'build_android_so.ps1') -Abis $Abis
    foreach ($rel in $relLibs) {
        $lib = Join-Path $RepoRoot $rel
        if (-not (Test-Path -LiteralPath $lib)) { throw "native/$Crate 构建后缺少产物 $lib" }
        Write-NativeStamp -Lib $lib -Tree $tree
        if ($tree) { Save-NativeToCache -RelLib $rel -Lib $lib -Tree $tree }
    }
    Write-Host ("OK native/$Crate (android) 编译完成（{0:N0} 秒）。" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
}

if ($Android) {
    # `powershell -File ... -Abis a,b` 把整串当成一个元素传进来，这里统一拆开。
    $Abis = @($Abis | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # fushi/android/app/build.gradle 的 checkFushi*Native 查的那一组（与 fushi/tool/dist_test/worker_build.sh 远端备的
    # 同一组）：登记表里 Android 上 `required: always` 的 Rust crate。
    foreach ($crate in (Get-NativeCrateList -Filter @('--android-local'))) {
        Install-NativeAndroidCrate -RepoRoot $root -Crate $crate -Abis $Abis
    }
    return
}

if ($PrintKeys) {
    # 只打印戳记用的源码键（`<crate> <键>`，有未提交改动的打印 `-`），不备库：核对本机、dist worker、
    # CI 产物库对同一棵源码算出同一个键时用（tool/native_crates_test.py 的说明）。
    foreach ($crate in (Get-NativeCrateList -Filter @('--host-test'))) {
        $key = Get-NativeSourceTree -Crate $crate
        Write-Output "$crate $(if ($key) { $key } else { '-' })"
    }
    return
}

foreach ($crate in (Get-NativeCrateList -Filter @('--host-test'))) {
    Install-NativeTestCrate -RepoRoot $root -GitBash $GitBash -Crate $crate
}
