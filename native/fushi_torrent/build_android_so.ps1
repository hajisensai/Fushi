# 构建内置 libtorrent 引擎的 Android .so 并落到 prebuilt/android/<abi>/ 供
# fushi/android 的 jniLibs copy-if-present 随包（见 fushi/android/app/build.gradle）。
#
# 与 Windows 版（build_windows_dll.ps1）同一套「vendored 预编译」决策，但产物形态
# 不同：vcpkg 的 android triplet 是静态链接，libtorrent/boost/openssl 全部链进
# 单个 libfushi_torrent_ffi.so，不存在 Windows 那 4 个运行时 DLL 的收拢问题。
#
# 用法（vcpkg 首次编 libtorrent:<triplet> 约 30~60min/架构，之后走二进制缓存）：
#   pwsh -File native/fushi_torrent/build_android_so.ps1 `
#       -VcpkgRoot D:\APP\vcpkg -NdkRoot D:\android_sdk\ndk\27.0.12077973
#   # 默认只编 arm64-v8a（真机主力）；模拟器验证再加 x86_64：
#   pwsh -File ... -Abis arm64-v8a,x86_64
# 产物：native/fushi_torrent/prebuilt/android/<abi>/libfushi_torrent_ffi.so
# （git 忽略，不入库——repo 不放二进制，构建/发布流程各自现产。）

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VcpkgRoot,

    [Parameter(Mandatory = $true)]
    [string]$NdkRoot,

    [string[]]$Abis = @("arm64-v8a"),

    [string]$Config = "Release",

    # ninja 所在目录（Android SDK 的 cmake 包自带；PATH 里已有 ninja 可不传）。
    [string]$NinjaDir = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ABI -> vcpkg 社区 triplet（armeabi-v7a 用 neon 变体：minSdk 24 的设备全部带 NEON）。
$tripletByAbi = @{
    "arm64-v8a"   = "arm64-android"
    "armeabi-v7a" = "arm-neon-android"
    "x86_64"      = "x64-android"
    "x86"         = "x86-android"
}

$vcpkgExe = Join-Path $VcpkgRoot "vcpkg.exe"
if (-not (Test-Path $vcpkgExe)) { throw "vcpkg not found: $vcpkgExe" }
$androidToolchain = Join-Path $NdkRoot "build\cmake\android.toolchain.cmake"
if (-not (Test-Path $androidToolchain)) {
    throw "NDK cmake toolchain not found: $androidToolchain (传 -NdkRoot <NDK 根目录>)"
}
$vcpkgToolchain = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"

if ($NinjaDir -ne "") { $env:PATH = "$NinjaDir;$env:PATH" }
if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
    throw "ninja not on PATH（Android SDK 的 cmake 目录自带，传 -NinjaDir <dir>）"
}

# vcpkg 的 android toolchain 从 ANDROID_NDK_HOME 找编译器。
$env:ANDROID_NDK_HOME = $NdkRoot

foreach ($abi in $Abis) {
    $triplet = $tripletByAbi[$abi]
    if ($null -eq $triplet) { throw "unknown ABI: $abi（支持 $($tripletByAbi.Keys -join ', ')）" }

    Write-Host "==> vcpkg install libtorrent:$triplet (overlay: API 24)"
    # overlay triplet 把依赖钉到 API 24（对齐 app minSdk）：vcpkg 自带 android
    # triplet 钉 28，boost.asio 会引用 API 28 才有的 aligned_alloc，bridge 按
    # android-24 链接直接 undefined symbol（详见 vcpkg-triplets/ 内注释）。
    $overlay = Join-Path $scriptDir "vcpkg-triplets"
    & $vcpkgExe install "libtorrent:$triplet" "--overlay-triplets=$overlay"
    if ($LASTEXITCODE -ne 0) { throw "vcpkg install libtorrent:$triplet failed" }

    $buildDir = Join-Path $scriptDir "build-android-$abi"
    Write-Host "==> CMake configure ($abi / $triplet)"
    # vcpkg 工具链在前（find_package 解析到 triplet 的静态归档），chainload NDK
    # 工具链拿交叉编译器。ANDROID_PLATFORM 对齐 app minSdkVersion 24。
    # ANDROID_STL=c++_shared 与 app 内 fushidicts 一致（libc++_shared.so 已随包）。
    cmake -G Ninja -B $buildDir -S $scriptDir `
        "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchain" `
        "-DVCPKG_TARGET_TRIPLET=$triplet" `
        "-DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=$androidToolchain" `
        "-DANDROID_ABI=$abi" `
        "-DANDROID_PLATFORM=android-24" `
        "-DANDROID_STL=c++_shared" `
        "-DCMAKE_BUILD_TYPE=$Config"
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($abi)" }

    Write-Host "==> CMake build ($abi)"
    cmake --build $buildDir
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($abi)" }

    $so = Join-Path $buildDir "libfushi_torrent_ffi.so"
    if (-not (Test-Path $so)) { throw "构建产物缺失: $so" }

    $outDir = Join-Path $scriptDir "prebuilt\android\$abi"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Copy-Item $so (Join-Path $outDir "libfushi_torrent_ffi.so") -Force

    # 静态链 boost/libtorrent 的未 strip 产物有几十 MB 调试符号；随包必 strip。
    $strip = Join-Path $NdkRoot "toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe"
    if (Test-Path $strip) {
        & $strip --strip-unneeded (Join-Path $outDir "libfushi_torrent_ffi.so")
        if ($LASTEXITCODE -ne 0) { throw "llvm-strip failed ($abi)" }
    } else {
        Write-Warning "llvm-strip not found at $strip — 产物未 strip（APK 会显著变大）"
    }

    $size = (Get-Item (Join-Path $outDir "libfushi_torrent_ffi.so")).Length
    Write-Host ("==> OK {0}: {1:N1} MB -> {2}" -f $abi, ($size / 1MB), $outDir)
}
