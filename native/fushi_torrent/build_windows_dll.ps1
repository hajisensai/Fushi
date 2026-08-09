# 构建内置 libtorrent 引擎的 Windows DLL 并把运行时依赖收拢到
# prebuilt/windows-x64/ 供 flutter windows runner 随包（见 fushi/windows/
# CMakeLists.txt 的 copy-if-present 集成）。
#
# 为什么不在 flutter build 时现编：libtorrent 经 vcpkg 首次源码编译约 40min
# （boost+openssl+libtorrent），CI/多数开发机不该被迫装 vcpkg。故本脚本单独
# 产出 4 个 DLL（bridge + torrent-rasterbar + ssl + crypto），flutter windows
# 构建只做「有则拷、无则跳」，不依赖 vcpkg（阶段4 决策：vendored 预编译）。
#
# 用法（需先 vcpkg install libtorrent:x64-windows）：
#   pwsh -File native/fushi_torrent/build_windows_dll.ps1 -VcpkgRoot D:\APP\vcpkg
# 产物：native/fushi_torrent/prebuilt/windows-x64/*.dll（git 忽略，不入库）

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VcpkgRoot,

    [string]$Triplet = "x64-windows",

    [string]$Config = "Release"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDir = Join-Path $scriptDir "build"
$outDir = Join-Path $scriptDir "prebuilt\windows-x64"

$toolchain = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"
if (-not (Test-Path $toolchain)) {
    throw "vcpkg toolchain not found: $toolchain (装好 vcpkg 并传 -VcpkgRoot)"
}

Write-Host "==> CMake configure ($Triplet)"
cmake -B $buildDir -S $scriptDir -A x64 `
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
    "-DVCPKG_TARGET_TRIPLET=$Triplet"
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

Write-Host "==> CMake build ($Config)"
cmake --build $buildDir --config $Config
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

$releaseDir = Join-Path $buildDir $Config
# bridge DLL + vcpkg applocal 部署的运行时依赖（torrent-rasterbar / ssl /
# crypto）都在 Release 目录里；全量收拢，缺一不可（DynamicLibrary 预载靠它们）。
$required = @(
    "fushi_torrent_ffi.dll",
    "torrent-rasterbar.dll",
    "libssl-3-x64.dll",
    "libcrypto-3-x64.dll"
)

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
foreach ($dll in $required) {
    $src = Join-Path $releaseDir $dll
    if (-not (Test-Path $src)) {
        throw "缺少构建产物 $dll（$src）——检查 vcpkg libtorrent 是否装全"
    }
    Copy-Item $src (Join-Path $outDir $dll) -Force
    Write-Host "  copied $dll"
}

Write-Host "==> Done. Prebuilt DLLs in: $outDir"
Write-Host "    flutter build windows 会自动把它们拷到 hibiki.exe 旁（见 windows/CMakeLists.txt）。"
