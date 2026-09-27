# 用 cargo-ndk 构建 Android 版 libfushi_p2p.so。
#
# 前提：rustup target add aarch64-linux-android x86_64-linux-android；cargo install cargo-ndk。
# NDK 版本与 fushi/android/app/build.gradle 的 ndkVersion 对齐（28.2.13676358），
# 平台 API = minSdk 24。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File native/fushi_p2p/build_android_so.ps1 [-NdkRoot D:\android_sdk\ndk\28.2.13676358] [-Abis arm64-v8a,x86_64]
# 产物：native/fushi_p2p/prebuilt/android/<abi>/libfushi_p2p.so（git 忽略，不入库）

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
    # cargo-ndk 会把 deps 里 iroh / iroh-relay 自带 cdylib 的副本（libiroh-<hash>.so）
    # 一并拷出来；libfushi_p2p.so 是静态链接的（NEEDED 只有 libc/libm/libdl），
    # 这些副本不被任何人加载，删掉免得被误打进 APK。
    Get-ChildItem (Join-Path $outDir $abi) -Filter "*.so" |
        Where-Object { $_.Name -ne "libfushi_p2p.so" } |
        Remove-Item -Force
    $so = Join-Path $outDir "$abi\libfushi_p2p.so"
    if (-not (Test-Path $so)) { throw "缺少产物 $so" }
    Write-Host ("  {0}  {1:N0} bytes" -f $so, (Get-Item $so).Length)
}
