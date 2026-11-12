# 构建 Windows x64 版 fushi_fsrs.dll（Rust + fsrs-rs，无额外运行时依赖 DLL）。
#
# 前提：rustup target add x86_64-pc-windows-msvc（MSVC 工具链）。
# 访问 crates.io 不稳时先设代理：$env:CARGO_HTTP_PROXY='http://127.0.0.1:34151'
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File native/fushi_fsrs/build_windows_dll.ps1
# 产物：native/fushi_fsrs/prebuilt/windows-x64/fushi_fsrs.dll（git 忽略，不入库）
#
# 环境变量 FUSHI_FSRS_FEATURES（可选，逗号分隔）：额外的 cargo feature，只给测试用的库（tool/native_libs.ps1 带
# `raw_sql`，见 build_linux_so.sh）。随包发布的构建不设它。编完按是否带 `raw_sql` 核对产物（Windows 没有
# verify_abi.sh，核对口径同 verify_raw_sql.sh）。

[CmdletBinding()]
param(
    [string]$Target = "x86_64-pc-windows-msvc"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $scriptDir "prebuilt\windows-x64"

$features = "$env:FUSHI_FSRS_FEATURES".Trim()
$cargoArgs = @('build', '--release', '--target', $Target)
if ($features) { $cargoArgs += @('--features', $features) }

Push-Location $scriptDir
try {
    Write-Host "==> cargo $($cargoArgs -join ' ')"
    & cargo @cargoArgs
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
} finally {
    Pop-Location
}

$dll = Join-Path $scriptDir "target\$Target\release\fushi_fsrs.dll"
if (-not (Test-Path $dll)) { throw "缺少构建产物 $dll" }
# 原始 SQL 通道的标记文本（只在 src/store/mod.rs `exec_raw` 里出现；verify_raw_sql.sh 同一个）。
# Latin-1 逐字节一一对应：按字节找 ASCII 文本。
$image = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($dll))
$hasRaw = $image.Contains('raw exec must not leave a transaction open')
$wantRaw = ($features -split ',' | ForEach-Object { $_.Trim() }) -contains 'raw_sql'
if ($hasRaw -ne $wantRaw) {
    throw "fushi_fsrs.dll 原始 SQL 通道核对失败：FUSHI_FSRS_FEATURES='$features'，产物里$(if ($hasRaw) { '有' } else { '没有' })原始通道"
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item $dll (Join-Path $outDir "fushi_fsrs.dll") -Force
Write-Host ("==> Done: {0} ({1:N0} bytes)" -f (Join-Path $outDir "fushi_fsrs.dll"), (Get-Item $dll).Length)
