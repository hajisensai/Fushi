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
    [switch] $AutoConnect,

    # -Path 给目录时，递归收集其中的 .exe / .dll（用于给整个 bundle 补签）。
    [switch] $Recurse,

    # 跳过「已被他人有效签名」的文件。给整包补签时必须开：bundle 里混着微软的
    # VC++ CRT 运行库，重签会把微软的签名换成我们的 —— 那是倒退不是补齐。
    [switch] $SkipValidlySigned,

    # 每批文件数。时间戳服务器对批量签名有限流，一次性甩几百个文件容易被拒。
    [int] $BatchSize = 20
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
    # 目录必须先单独判掉。`Get-ChildItem -Path <目录> -File` 会列出目录**里面**的
    # 文件并排除目录本身，于是 PSIsContainer 永远为假、递归分支永远走不到 ——
    # 表现是「给了目录却只签到顶层几个文件」，而且报成功。
    if (Test-Path -LiteralPath $p -PathType Container) {
        if (-not $Recurse) { throw "$p 是目录；要给整个目录补签请加 -Recurse。" }
        # 也不能用 `-Recurse -Include '*.exe','*.dll'`：-Include 在路径不含通配符时
        # 只对顶层生效，子目录的命中会被静默丢弃。改为递归取全部再按扩展名过滤。
        $targets += (Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.exe', '.dll' }).FullName
        continue
    }
    $resolved = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue
    if (-not $resolved) { throw "找不到待签目标: $p" }
    $targets += $resolved.FullName
}
$targets = @($targets | Where-Object { $_ } | Select-Object -Unique)
if ($targets.Count -eq 0) { throw "没有收集到任何待签文件。" }
Write-Step "收集到 $($targets.Count) 个候选文件"

# 分流：已被**他人**有效签名的跳过（微软 CRT、第三方带签 DLL）；
# 未签名、或已由本证书签过的，都进待签队列（后者重签是幂等的）。
[string[]] $toSign = @()
[object[]] $skipped = @()
if ($SkipValidlySigned) {
    foreach ($t in $targets) {
        $s = Get-AuthenticodeSignature -LiteralPath $t
        if ($s.Status -eq 'Valid' -and $s.SignerCertificate -and
            $s.SignerCertificate.Thumbprint -ne $Thumbprint) {
            $skipped += [pscustomobject]@{ Path = $t; Signer = $s.SignerCertificate.Subject }
        } else {
            $toSign += $t
        }
    }
    Write-Step "跳过 $($skipped.Count) 个已由他方有效签名的文件，待签 $($toSign.Count) 个"
    foreach ($k in $skipped) {
        Write-Host "    skip: $(Split-Path $k.Path -Leaf)  <- $($k.Signer)"
    }
} else {
    $toSign = $targets
    Write-Step "待签文件 $($toSign.Count) 个"
}
if ($toSign.Count -eq 0) {
    Write-Step "没有需要签名的文件，结束。"
    exit 0
}

# --- 3. 签名 -----------------------------------------------------------------
[string] $signtool = Get-SignTool
Write-Step "signtool: $signtool"

# 分批 + 重试。时间戳服务器（DigiCert 免费端点）对批量请求限流，一次甩几百个
# 文件会中途拒绝；这类失败是间歇性的、且 signtool 只报一个笼统退出码。
# 重试用递增退避，不是无脑循环 —— 真错（证书没挂上、文件被占用）会稳定复现，
# 三次都失败就抛出去，不会把真问题拖成静默。
[int] $batchNo = 0
for ($i = 0; $i -lt $toSign.Count; $i += $BatchSize) {
    $batch = @($toSign[$i..([math]::Min($i + $BatchSize - 1, $toSign.Count - 1))])
    $batchNo++
    [bool] $ok = $false
    for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        & $signtool sign /sha1 $Thumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 /d $Description $batch
        if ($LASTEXITCODE -eq 0) {
            $ok = $true
        } else {
            Write-Host "[sign] 批次 $batchNo 第 $attempt 次失败（退出码 $LASTEXITCODE）" -ForegroundColor Yellow
            if ($attempt -lt 3) { Start-Sleep -Seconds (10 * $attempt) }
        }
    }
    if (-not $ok) { throw "signtool sign 批次 $batchNo 连续 3 次失败。" }
    Write-Step "批次 $batchNo 完成（$($batch.Count) 个文件，累计 $([math]::Min($i + $BatchSize, $toSign.Count))/$($toSign.Count)）"
}

# --- 4. 验证 -----------------------------------------------------------------
# 判绿只认 verify 的退出码 + 每个文件的 Authenticode 状态。sign 成功不代表链完整：
# 少装中间 CA 时 sign 照样 exit 0，verify 才会红。
# 只验我们签过的那批；跳过的文件本来就不该带我们的签名。
Write-Step "验证签名与证书链…"
& $signtool verify /pa @toSign
if ($LASTEXITCODE -ne 0) { throw "signtool verify 失败，退出码 $LASTEXITCODE（多半是中间 CA 缺失或时间戳未取到）" }
[string[]] $targetsToReport = $toSign

# 文件多时逐个打全量详情会把日志淹掉，但失败的必须点名。
# 判据对每个文件都跑，只是通过的按单行汇报。
[bool] $verbosePerFile = ($targetsToReport.Count -le 3)
[bool] $allValid = $true
[int] $okCount = 0
foreach ($t in $targetsToReport) {
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
    if (-not $ok) { $allValid = $false } else { $okCount++ }

    if ($verbosePerFile -or -not $ok) {
        Write-Host ""
        Write-Host "  文件      : $t"
        Write-Host "  状态      : $($sig.Status)$(if (-not $ok) { '   <== 判定失败' })"
        Write-Host "  签名类型  : $($sig.SignatureType)$(if (-not $isEmbedded) { '   <== 期望 Authenticode（嵌入式）' })"
        Write-Host "  签名者    : $($sig.SignerCertificate.Subject)"
        Write-Host "  签名者指纹: $($sig.SignerCertificate.Thumbprint)$(if (-not $isOurCert) { "   <== 期望 $Thumbprint" })"
        Write-Host "  时间戳    : $(if ($hasTs) { $sig.TimeStamperCertificate.Subject } else { '缺失 —— 证书到期后签名将失效！' })"
        Write-Host "  SHA256    : $hash"
        Write-Host "  大小      : $((Get-Item -LiteralPath $t).Length)"
    } else {
        Write-Host "  OK  $(Split-Path $t -Leaf)"
    }
}

if (-not $allValid) { throw "存在状态非 Valid 或缺时间戳的文件，判定失败。" }

Write-Host ""
Write-Step "签名并验证通过 $okCount 个文件$(if ($skipped.Count -gt 0) { "，另跳过 $($skipped.Count) 个他方已签名文件" })。"
exit 0
