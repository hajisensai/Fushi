# 构建 Windows x64 版 fushi_fsrs.dll（Rust + fsrs-rs，无额外运行时依赖 DLL）。
#
# 前提：rustup target add x86_64-pc-windows-msvc（MSVC 工具链）。
# 访问 crates.io 不稳时先设代理：$env:CARGO_HTTP_PROXY='http://127.0.0.1:34151'
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File native/fushi_fsrs/build_windows_dll.ps1
# 产物：native/fushi_fsrs/prebuilt/windows-x64/fushi_fsrs.dll（git 忽略，不入库）

[CmdletBinding()]
param(
    [string]$Target = "x86_64-pc-windows-msvc"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $scriptDir "prebuilt\windows-x64"

Push-Location $scriptDir
try {
    Write-Host "==> cargo build --release --target $Target"
    & cargo build --release --target $Target
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
} finally {
    Pop-Location
}

$dll = Join-Path $scriptDir "target\$Target\release\fushi_fsrs.dll"
if (-not (Test-Path $dll)) { throw "缺少构建产物 $dll" }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item $dll (Join-Path $outDir "fushi_fsrs.dll") -Force
Write-Host ("==> Done: {0} ({1:N0} bytes)" -f (Join-Path $outDir "fushi_fsrs.dll"), (Get-Item $dll).Length)
