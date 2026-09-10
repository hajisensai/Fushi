<#
.SYNOPSIS
  Authenticode-sign Windows release artifacts with the Certum cloud certificate.

.DESCRIPTION
  私钥在 Certum 云端 HSM，导不出 .pfx，所以 signtool 只能用 /sha1 走本机证书存储
  （由 SimplySign Desktop 挂上去），不能用 /f cert.pfx。仓库早先那条
  WINDOWS_CERT_BASE64 -> cert.pfx -> signtool /f 的路径对这类证书永远走不通。

  时间戳是硬要求，不是可选项：证书有效期只有一年，没有 RFC3161 时间戳的话，
  证书一到期，已经发出去的所有安装包的签名会当场全部失效。加了时间戳，
  Windows 用签名时刻而非验证时刻去校验有效期，老包永久有效。

.NOTES
  必须用 PowerShell 调 signtool，不能用 Git Bash：MSYS 会把 /fd、/sha1、/tr
  这类斜杠开头的参数当 POSIX 路径改写，signtool 收不到 /fd，报的却是
  "No file digest algorithm specified" —— 指向一个你明明传了的参数。
#>

[CmdletBinding()]
param(
    # 待签文件；支持多个路径与通配符。
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]] $Path,

    [string] $Thumbprint = $(if ($env:CERTUM_CERT_THUMBPRINT) { $env:CERTUM_CERT_THUMBPRINT } else { 'D717A3F6A12F50B75E9D04072A69B1BCB590AE14' }),

    [string] $TimestampUrl = 'http://timestamp.digicert.com',

    # 显示在 UAC 提权对话框上的程序描述。
    [string] $Description = 'Fushi',

    # 先确保 SimplySign 已连接（未连接时用 seed 自动登录）。
    [switch] $AutoConnect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string] $Message) { Write-Host "[sign] $Message" }

function Get-SignTool() {
    $candidates = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Directory.Parent.Name) } -ErrorAction SilentlyContinue
    if (-not $candidates) { throw "找不到 signtool.exe（需要 Windows SDK）。" }
    return ($candidates | Select-Object -Last 1).FullName
}

function Test-CertPresent([string] $Tp) {
    return $null -ne (Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $Tp })
}

# --- 1. 确保证书可用 ---------------------------------------------------------
if (-not (Test-CertPresent $Thumbprint)) {
    if ($AutoConnect) {
        Write-Step "证书不在存储中，尝试自动连接 SimplySign…"
        & (Join-Path $PSScriptRoot 'simplysign_connect.ps1') -ExpectedThumbprint $Thumbprint
        if ($LASTEXITCODE -ne 0) { throw "SimplySign 自动连接失败（见上方日志）。" }
    } else {
        throw @"
证书 $Thumbprint 不在 Cert:\CurrentUser\My 中。
私钥在 Certum 云端，需要先让 SimplySign Desktop 连上：
  - 手动：托盘图标 -> 输入手机 App 的 TOTP
  - 自动：加 -AutoConnect（需设 CERTUM_OTP_URI）
"@
    }
}

$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $Thumbprint }
Write-Step "证书: $($cert.Subject)"
Write-Step "有效期至: $($cert.NotAfter)  (剩余 $([int]($cert.NotAfter - (Get-Date)).TotalDays) 天)"

# --- 2. 解析待签文件 ---------------------------------------------------------
[string[]] $targets = @()
foreach ($p in $Path) {
    $resolved = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue
    if (-not $resolved) { throw "找不到待签文件: $p" }
    $targets += $resolved.FullName
}
Write-Step "待签文件 $($targets.Count) 个"

# --- 3. 签名 -----------------------------------------------------------------
[string] $signtool = Get-SignTool
Write-Step "signtool: $signtool"

& $signtool sign /sha1 $Thumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 /d $Description /v @targets
if ($LASTEXITCODE -ne 0) { throw "signtool sign 失败，退出码 $LASTEXITCODE" }

# --- 4. 验证 -----------------------------------------------------------------
# 判绿只认 verify 的退出码 + 每个文件的 Authenticode 状态。sign 成功不代表链完整：
# 少装中间 CA 时 sign 照样 exit 0，verify 才会红。
Write-Step "验证签名与证书链…"
& $signtool verify /pa /v @targets
if ($LASTEXITCODE -ne 0) { throw "signtool verify 失败，退出码 $LASTEXITCODE（多半是中间 CA 缺失或时间戳未取到）" }

[bool] $allValid = $true
foreach ($t in $targets) {
    $sig = Get-AuthenticodeSignature -LiteralPath $t
    [string] $hash = (Get-FileHash -LiteralPath $t -Algorithm SHA256).Hash
    [bool] $hasTs = $null -ne $sig.TimeStamperCertificate

    # 四条判据缺一不可。只判 Status 是空壳：Windows 安全目录（.cat）里登记过的
    # 文件，即使我们没签成，Get-AuthenticodeSignature 也会返回别人的目录签名并
    # 报 Valid。Authenticode 哈希不覆盖证书表和 PE checksum，所以嵌入签名并不会
    # 让旧目录条目失配 —— 拿 OS 二进制做实验时实测撞上过这一幕。
    # 因此必须同时钉死：签名类型是嵌入式、签名者就是我们这张证书。
    [bool] $isEmbedded = ($sig.SignatureType -eq 'Authenticode')
    [bool] $isOurCert  = ($null -ne $sig.SignerCertificate) -and
                         ($sig.SignerCertificate.Thumbprint -eq $Thumbprint)
    [bool] $ok = ($sig.Status -eq 'Valid') -and $hasTs -and $isEmbedded -and $isOurCert
    if (-not $ok) { $allValid = $false }

    Write-Host ""
    Write-Host "  文件      : $t"
    Write-Host "  状态      : $($sig.Status)$(if (-not $ok) { '   <== 判定失败' })"
    Write-Host "  签名类型  : $($sig.SignatureType)$(if (-not $isEmbedded) { '   <== 期望 Authenticode（嵌入式）' })"
    Write-Host "  签名者    : $($sig.SignerCertificate.Subject)"
    Write-Host "  签名者指纹: $($sig.SignerCertificate.Thumbprint)$(if (-not $isOurCert) { "   <== 期望 $Thumbprint" })"
    Write-Host "  时间戳    : $(if ($hasTs) { $sig.TimeStamperCertificate.Subject } else { '缺失 —— 证书到期后签名将失效！' })"
    Write-Host "  SHA256    : $hash"
    Write-Host "  大小      : $((Get-Item -LiteralPath $t).Length)"
}

if (-not $allValid) { throw "存在状态非 Valid 或缺时间戳的文件，判定失败。" }

Write-Host ""
Write-Step "全部 $($targets.Count) 个文件签名并验证通过。"
exit 0
