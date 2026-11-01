# 用 cargo-ndk 构建 Android 版 libfushi_fsrs.so。
#
# 前提：rustup target add aarch64-linux-android x86_64-linux-android；cargo install cargo-ndk。
# 默认只编 arm64-v8a / x86_64（本机调试够用）；要与 split-per-abi APK 对齐时加
# -Abis arm64-v8a,armeabi-v7a,x86_64（另需 rustup target add armv7-linux-androideabi），
# 发布流水线走 build_android_so.sh 的同一组 ABI。
# NDK 版本与 fushi/android/app/build.gradle 的 ndkVersion 对齐（28.2.13676358），
# 平台 API = minSdk 24。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File native/fushi_fsrs/build_android_so.ps1 [-NdkRoot D:\android_sdk\ndk\28.2.13676358] [-Abis arm64-v8a,x86_64]
# 产物：native/fushi_fsrs/prebuilt/android/<abi>/libfushi_fsrs.so（git 忽略，不入库）

[CmdletBinding()]
param(
    [string]$NdkRoot = "",
    [string[]]$Abis = @("arm64-v8a", "x86_64"),
    [int]$Platform = 24
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $NdkRoot) {
    $sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "" }
    if ($env:ANDROID_NDK_HOME) { $NdkRoot = $env:ANDROID_NDK_HOME }
    elseif ($sdk) { $NdkRoot = Join-Path $sdk "ndk\28.2.13676358" }
}
if (-not (Test-Path $NdkRoot)) { throw "NDK not found: '$NdkRoot'（传 -NdkRoot 或设 ANDROID_NDK_HOME）" }
$env:ANDROID_NDK_HOME = $NdkRoot

$outDir = Join-Path $scriptDir "prebuilt\android"
$cargoArgs = @("ndk", "--platform", "$Platform", "-o", $outDir)
foreach ($abi in $Abis) { $cargoArgs += @("-t", $abi) }
$cargoArgs += @("build", "--release")

Push-Location $scriptDir
try {
    Write-Host "==> cargo $($cargoArgs -join ' ')"
    & cargo @cargoArgs
    if ($LASTEXITCODE -ne 0) { throw "cargo ndk build failed" }
} finally {
    Pop-Location
}
foreach ($abi in $Abis) {
    # 与 fushi_fsrs 同一道防线：cargo-ndk 会把依赖里自带 cdylib 的副本一并拷出来；
    # libfushi_fsrs.so 是静态链接的，别的 .so 无人加载，删掉免得被误打进 APK。
    Get-ChildItem (Join-Path $outDir $abi) -Filter "*.so" |
        Where-Object { $_.Name -ne "libfushi_fsrs.so" } |
        Remove-Item -Force
    $so = Join-Path $outDir "$abi\libfushi_fsrs.so"
    if (-not (Test-Path $so)) { throw "缺少产物 $so" }
    # libsqlite3-sys 给 Android 硬编码 TEMP_STORE=3（临时库全进内存，大库 VACUUM 撑爆进程）；.cargo/config.toml
    # 改回 1。从别的目录构建会丢那份配置，这里按产物里的编译选项字符串核对。
    $soText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($so))
    if ($soText.Contains("TEMP_STORE=3") -or -not $soText.Contains("TEMP_STORE=1")) {
        throw "$so : bundled SQLite is not built with SQLITE_TEMP_STORE=1 (see native/fushi_fsrs/.cargo/config.toml)"
    }
    Write-Host ("  {0}  {1:N0} bytes" -f $so, (Get-Item $so).Length)
}
