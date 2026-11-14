# 构建 Windows x64 版 fushi_fsrs.dll（Rust + fsrs-rs，无额外运行时依赖 DLL）。
#
# 前提：rustup target add x86_64-pc-windows-msvc（MSVC 工具链）。
# 访问 crates.io 不稳时先设代理：$env:CARGO_HTTP_PROXY='http://127.0.0.1:34151'
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File native/fushi_fsrs/build_windows_dll.ps1
# 产物：native/fushi_fsrs/prebuilt/windows-x64/fushi_fsrs.dll（git 忽略，不入库）
#
# -IdAudit：另编一份带 ID 审计的库（cargo feature `id_audit`，src/store/ids.rs `audit`）到
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

# 库里有没有审计分支的报错前缀（store/ids.rs `audit::take` 的 "id audit: "，只在 `id_audit` 构建里编进去）。
# 普通库必须没有、审计库必须有：两份共用一个 target 目录、同名产物轮流覆盖，拷错一份在这里就失败。
# 与 verify_id_audit.sh 同一个判据。
function Test-IdAuditMarker {
    [OutputType([bool])]
    param([string]$Path)

    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    return $text.Contains('id audit: ')
}

function Invoke-FsrsBuild {
    [OutputType([void])]
    param([string[]]$CargoArgs, [string]$Destination, [bool]$Audited)

    Write-Host "==> cargo build --release --target $Target $CargoArgs"
    & cargo build --release --target $Target @CargoArgs
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
    if (-not (Test-Path $dll)) { throw "缺少构建产物 $dll" }
    if ((Test-IdAuditMarker -Path $dll) -ne $Audited) {
        throw "$dll：ID 审计与预期不符（预期 audited=$Audited）"
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
