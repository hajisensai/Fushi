# 用 cargo-ndk 构建 Android 版 libfushi_rwkv.so（与 native/fushi_compute/build_android_so.ps1 同一形态）。
#
# 前提：rustup target add aarch64-linux-android x86_64-linux-android；cargo install cargo-ndk。
# 默认只编 arm64-v8a / x86_64（本机调试够用）；要与 split-per-abi APK 对齐时加
# -Abis arm64-v8a,armeabi-v7a,x86_64（另需 rustup target add armv7-linux-androideabi），
# 发布流水线走 build_android_so.sh 的同一组 ABI。
# NDK 版本与 fushi/android/app/build.gradle 的 ndkVersion 对齐（28.2.13676358），
# 平台 API = minSdk 24。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File native/fushi_rwkv/build_android_so.ps1 [-NdkRoot D:\android_sdk\ndk\28.2.13676358] [-Abis arm64-v8a,x86_64]
# 产物：native/fushi_rwkv/prebuilt/android/<abi>/libfushi_rwkv.so（git 忽略，不入库）

[CmdletBinding()]
param(
    [string]$NdkRoot = "",
    [string[]]$Abis = @("arm64-v8a", "x86_64"),
    [int]$Platform = 24
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# `powershell -File ... -Abis a,b` 把整串当成一个元素传进来（-File 不按逗号拆数组），这里统一拆开。
$Abis = @($Abis | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

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
    # cargo-ndk 会把依赖里自带 cdylib 的副本一并拷出来；libfushi_rwkv.so 是静态链接的，
    # 别的 .so 无人加载，删掉免得被误打进 APK。
    Get-ChildItem (Join-Path $outDir $abi) -Filter "*.so" |
        Where-Object { $_.Name -ne "libfushi_rwkv.so" } |
        Remove-Item -Force
    $so = Join-Path $outDir "$abi\libfushi_rwkv.so"
    if (-not (Test-Path $so)) { throw "缺少产物 $so" }
    Write-Host ("  {0}  {1:N0} bytes" -f $so, (Get-Item $so).Length)
}
