# 构建 Windows x64 版 fushi_fsrs.dll（Rust + fsrs-rs，无额外运行时依赖 DLL）。
#
# 前提：rustup target add x86_64-pc-windows-msvc（MSVC 工具链）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File native/fushi_fsrs/build_windows_dll.ps1
# 产物：native/fushi_fsrs/prebuilt/windows-x64/fushi_fsrs.dll（git 忽略，不入库）
#
# 环境变量 FUSHI_FSRS_FEATURES（可选，逗号分隔）：额外的 cargo feature，只给测试用的库（tool/native_libs.ps1 带
# `raw_sql`，见 build_linux_so.sh）。随包发布的构建不设它。每份产物编完都按是否带 `raw_sql` 核对（Windows 没有
# verify_abi.sh，核对口径同 verify_raw_sql.sh）。
#
# -IdAudit：另编一份带 ID 审计的库（cargo feature `id_audit`，src/store/ids.rs `audit`；外加 FUSHI_FSRS_FEATURES）到
#   prebuilt/windows-x64/id_audit/fushi_fsrs.dll。只给本机的调试构建与测试宿主用（Dart 侧
#   packages/fushi_srs 的 kFushiFsrsIdAuditDir：断言开着才去找它），不随包——fushi/windows/CMakeLists.txt 只拷
#   上一级目录里的普通库。tool/native_libs.ps1 带这个开关调；发布流水线不带，产物与以前相同。
# 不带 -IdAudit 重编时会删掉已有的 id_audit 目录：那份库对应的是上一次的源码，留着会被调试构建优先加载。

[CmdletBinding()]
param(
    [string]$Target = "x86_64-pc-windows-msvc",
    [switch]$IdAudit
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $scriptDir "prebuilt\windows-x64"
$auditDir = Join-Path $outDir "id_audit"
$dll = Join-Path $scriptDir "target\$Target\release\fushi_fsrs.dll"

# 库里有没有某段 ASCII 标记文本（Latin-1 逐字节一一对应：按字节找）。两个判据：
# - ID 审计：审计分支的报错前缀 "id audit: "（store/ids.rs `audit::take`，只在 `id_audit` 构建里编进去），
#   与 verify_id_audit.sh 同一个判据；
# - 原始 SQL 通道：'raw exec must not leave a transaction open'（只在 src/store/mod.rs `exec_raw` 里出现），
#   与 verify_raw_sql.sh 同一个判据。
# 两份（普通 / 审计）共用一个 target 目录、同名产物轮流覆盖，拷错一份在这里就失败。
function Test-DllMarker {
    [OutputType([bool])]
    param([string]$Path, [string]$Marker)

    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    return $text.Contains($Marker)
}

# FUSHI_FSRS_FEATURES 对两份都加（cargo 认多个 --features，取并集）；每份编完核对审计与原始通道都与预期一致。
$features = "$env:FUSHI_FSRS_FEATURES".Trim()
$wantRaw = ($features -split ',' | ForEach-Object { $_.Trim() }) -contains 'raw_sql'

function Invoke-FsrsBuild {
    [OutputType([void])]
    param([string[]]$CargoArgs, [string]$Destination, [bool]$Audited)

    $allArgs = @($CargoArgs)
    if ($features) { $allArgs += @('--features', $features) }
    Write-Host "==> cargo build --release --target $Target $allArgs"
    & cargo build --release --target $Target @allArgs
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
    if (-not (Test-Path $dll)) { throw "缺少构建产物 $dll" }
    if ((Test-DllMarker -Path $dll -Marker 'id audit: ') -ne $Audited) {
        throw "$dll：ID 审计与预期不符（预期 audited=$Audited）"
    }
    $hasRaw = Test-DllMarker -Path $dll -Marker 'raw exec must not leave a transaction open'
    if ($hasRaw -ne $wantRaw) {
        throw "fushi_fsrs.dll 原始 SQL 通道核对失败：FUSHI_FSRS_FEATURES='$features'，产物里$(if ($hasRaw) { '有' } else { '没有' })原始通道"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item $dll $Destination -Force
    Write-Host ("==> Done: {0} ({1:N0} bytes)" -f $Destination, (Get-Item $dll).Length)
}

Push-Location $scriptDir
try {
    if (Test-Path $auditDir) { Remove-Item -LiteralPath $auditDir -Recurse -Force }
    Invoke-FsrsBuild -CargoArgs @() -Destination (Join-Path $outDir "fushi_fsrs.dll") -Audited $false
    if ($IdAudit) {
        Invoke-FsrsBuild -CargoArgs @('--features', 'id_audit') `
            -Destination (Join-Path $auditDir "fushi_fsrs.dll") -Audited $true
    }
} finally {
    Pop-Location
}
