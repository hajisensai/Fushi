# 构建 Windows x64 版 fushi_rwkv.dll（RWKV-Instant 排程推理，纯 Rust，除系统 / VC 运行时外无额外依赖 DLL）。
# 与 native/fushi_compute/build_windows_dll.ps1 同一形态：app 的**硬依赖**，缺库时
# fushi/windows/CMakeLists.txt 配置期 FATAL_ERROR。
#
# 前提：rustup target add x86_64-pc-windows-msvc（MSVC 工具链）。
# 访问 crates.io 不稳时先设代理：$env:CARGO_HTTP_PROXY='http://127.0.0.1:34151'
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File native/fushi_rwkv/build_windows_dll.ps1
# 产物：native/fushi_rwkv/prebuilt/windows-x64/fushi_rwkv.dll（git 忽略，不入库）

[CmdletBinding()]
param(
    [string]$Target = "x86_64-pc-windows-msvc"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $scriptDir "prebuilt\windows-x64"

Push-Location $scriptDir
try {
    # 只出 cdylib：Cargo.toml 同时声明了 staticlib / rlib（iOS 伞形库用），这里不必为它们再跑一遍 fat LTO。
    Write-Host "==> cargo rustc --release --lib --target $Target --crate-type cdylib"
    & cargo rustc --release --lib --target $Target --crate-type cdylib
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
} finally {
    Pop-Location
}

$dll = Join-Path $scriptDir "target\$Target\release\fushi_rwkv.dll"
if (-not (Test-Path $dll)) { throw "缺少构建产物 $dll" }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item $dll (Join-Path $outDir "fushi_rwkv.dll") -Force
Write-Host ("==> Done: {0} ({1:N0} bytes)" -f (Join-Path $outDir "fushi_rwkv.dll"), (Get-Item $dll).Length)
