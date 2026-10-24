<#
.SYNOPSIS
  备好 app 与 flutter test 硬依赖的 Rust 原生库（fushi_compute / fushi_fsrs / fushi_web_core / fushi_rwkv / fushi_music）。

.DESCRIPTION
  tool/bootstrap.ps1 在 pub get 之后调用本脚本；已有 worktree 缺库（测试成片报
  FushiComputeUnavailableError / FUSHI_FSRS_LIB / FushiWebCoreLibraryMissing）时也可单独跑：
    powershell -ExecutionPolicy Bypass -File tool/native_libs.ps1

  每个 crate 按顺序：
    1) 本地 prebuilt/<平台>/ 旁的戳记（<产物>.source：native/<crate> 的 git 树哈希 + 产物大小 + mtime）
       与 HEAD 一致 → 跳过；
    2) 兄弟 worktree（含主 checkout）里有戳记一致的产物 → 拷过来（秒级，免 cargo）；
    3) 否则跑 native/<crate>/build_* 编译，编完写戳记（此时才需要 cargo）。
  native/<crate> 有未提交改动时不复用也不写戳记，按工作区源码编。
  产物落在 native/<crate>/prebuilt/<平台>/，测试宿主下的加载器会向上找到它，不必设 FUSHI_*_LIB。

  新增一个 app / 测试硬依赖的 crate：往 $NativeTestCrates 加一行；它必须自带
  build_{windows_dll.ps1,linux_so.sh,macos_dylib.sh}、产物落 prebuilt/<平台>/，且不依赖
  native/<crate> 目录以外的源码（戳记只哈希这个目录）。

.PARAMETER GitBash
  Linux / macOS 跑 build_*.sh 用的 bash（Windows 走 .ps1，用不到）。
#>
[CmdletBinding()]
param([string]$GitBash = 'bash')

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent $PSScriptRoot

# 缺 cargo 时（需要编的那一刻）直接失败而不是跳过：跳过的结果是之后 flutter build / test
# 在 CMake / Gradle / 加载器里才报错，离原因更远。
$NativeTestCrates = @('fushi_compute', 'fushi_fsrs', 'fushi_web_core', 'fushi_rwkv', 'fushi_music')

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

# native/<crate> 在 HEAD 的 git 树哈希；该目录有未提交改动（含未跟踪文件，不含 target/ prebuilt/
# 这些 ignored）时返回 $null —— 产物对应的源码说不清，不写戳记、不复用。
function Get-NativeSourceTree {
    [OutputType([string])]
    param([string]$RepoRoot, [string]$Crate)

    # PS 5.1 + ErrorActionPreference=Stop 下原生命令写 stderr 会变成终止性错误，
    # 拿不到树哈希只意味着「不复用、照常编」，所以整段兜住。
    try {
        $dirty = (& git -C $RepoRoot status --porcelain --untracked-files=all -- "native/$Crate" | Out-String).Trim()
        if ($dirty) { return $null }
        $tree = (& git -C $RepoRoot rev-parse "HEAD:native/$Crate" | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $tree) { return $null }
        return $tree
    }
    catch {
        return $null
    }
}

# 戳记 = <产物>.source（JSON：tree / length / mtimeUtcTicks）。大小与 mtime 也要对上：有人手动
# 重编（或别的 worktree 正在覆盖）后旧戳记自动失效，不会把别的源码编出的库当成这棵树的。
function Test-NativeStamp {
    [OutputType([bool])]
    param([string]$Lib, [string]$Tree)

    $stamp = "$Lib.source"
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

    $stamp = "$Lib.source"
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
    param([string]$RepoRoot, [string]$GitBash, [string]$Crate, [hashtable]$Layout)

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
    # 装了就用（调用方已设 RUSTC_WRAPPER 时尊重调用方），没装照常编。
    $previousWrapper = $env:RUSTC_WRAPPER
    if (-not $previousWrapper) {
        $sccache = Get-Command sccache -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sccache) {
            $env:RUSTC_WRAPPER = $sccache.Source
            Write-Host "  rustc 编译缓存：sccache ($($sccache.Source))" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  未装 sccache：依赖每个 worktree 都要从零编。装上（winget install Mozilla.sccache）后自动跨 worktree 共用缓存。" -ForegroundColor DarkYellow
        }
    }
    Write-Host "Building native/$Crate (cargo: $($cargo.Source))..." -ForegroundColor Cyan
    try {
        if ($Layout.Script.EndsWith('.ps1')) {
            & $script
            return
        }
        & $GitBash $script
        if ($LASTEXITCODE -ne 0) { throw "native/$Crate/$($Layout.Script) failed (exit $LASTEXITCODE)." }
    }
    finally {
        $env:RUSTC_WRAPPER = $previousWrapper
    }
}

function Install-NativeTestCrate {
    [OutputType([void])]
    param([string]$RepoRoot, [string]$GitBash, [string]$Crate)

    $layout = Get-NativeHostLayout
    $relLib = "native/$Crate/prebuilt/$($layout.Dir)/$($layout.Prefix)$Crate$($layout.Ext)"
    $lib = Join-Path $RepoRoot $relLib
    $tree = Get-NativeSourceTree -RepoRoot $RepoRoot -Crate $Crate

    if (Test-NativeStamp -Lib $lib -Tree $tree) {
        Write-Host "OK native/$Crate 已是 HEAD 源码编出的产物，跳过。" -ForegroundColor DarkGray
        return
    }
    if ($tree) {
        $from = Copy-NativeFromSibling -RepoRoot $RepoRoot -Crate $Crate -RelLib $relLib -Lib $lib -Tree $tree
        if ($from) {
            Write-NativeStamp -Lib $lib -Tree $tree
            Write-Host "OK native/$Crate 复用 $from 的同源码产物（树 $($tree.Substring(0, 10))），未编译。" -ForegroundColor Green
            return
        }
    }
    else {
        Write-Host "native/$Crate 有未提交改动，按当前工作区源码编译。" -ForegroundColor Yellow
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-NativeCrateBuild -RepoRoot $RepoRoot -GitBash $GitBash -Crate $Crate -Layout $layout
    if (-not (Test-Path -LiteralPath $lib)) { throw "native/$Crate 构建后缺少产物 $lib" }
    Write-NativeStamp -Lib $lib -Tree $tree
    Write-Host ("OK native/$Crate 编译完成（{0:N0} 秒）。" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
}

foreach ($crate in $NativeTestCrates) {
    Install-NativeTestCrate -RepoRoot $root -GitBash $GitBash -Crate $crate
}
