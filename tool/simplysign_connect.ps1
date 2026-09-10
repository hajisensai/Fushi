<#
.SYNOPSIS
  Connect SimplySign Desktop to Certum's cloud HSM without any GUI interaction.

.DESCRIPTION
  Certum 的代码签名私钥留在云端 HSM，本机 signtool 只能通过 SimplySign Desktop
  注册的 CSP/KSP 经命名管道访问它。默认流程要人工双击托盘图标、手输手机上的
  TOTP —— 这一步是 CI 自动化的唯一拦路虎。

  但 SimplySignDesktop.exe 有未公开的命令行参数（逆向 Program.cs::Main 确认）：

      /autologin <user> <otp>
      /otpauth   <seedFile> <configFile> <certFile> [cardPin]

  `/autologin` 直接走 MainForm::loginUserOTP() -> ServerProtocol.serverLoginCas5()，
  全程不弹对话框。而 SimplySign 激活时扫的二维码就是标准 otpauth:// URI，
  所以 TOTP 完全可以本地算出来 —— 不需要模拟按键，也不需要手机在场。

  本脚本据此把「连接」变成一条可在 CI 里跑的命令。

.NOTES
  seed 是这条链上唯一可窃取的凭据（私钥导不出）。泄漏等于交出签名身份。
  只从环境变量 / GitHub Secrets 注入，绝不落盘进仓库（.gitignore 已挡 *.seed）。
#>

[CmdletBinding()]
param(
    # otpauth://totp/Certum:<user>?secret=<BASE32>&algorithm=SHA1&digits=6&period=30
    [string] $SeedUri = $env:CERTUM_OTP_URI,

    # SimplySign 账号邮箱。省略时从 seed URI 的 path 段推出。
    [string] $UserId = $env:CERTUM_USER_ID,

    # 期望出现在 Cert:\CurrentUser\My 的代码签名证书指纹（大写无空格）。
    [string] $ExpectedThumbprint = $env:CERTUM_CERT_THUMBPRINT,

    [string] $ExePath = $(if ($env:CERTUM_EXE_PATH) { $env:CERTUM_EXE_PATH } else { 'D:\APP\certum\SimplySignDesktop.exe' }),

    # 等证书出现在存储里的上限秒数。
    [int] $TimeoutSeconds = 90,

    # 已连接时直接返回，不重连（重连会先 WM_CLOSE 掉现有实例）。
    [switch] $ReuseExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string] $Message) {
    Write-Host "[simplysign] $Message"
}

function Get-SimplySignLogTail([int] $Lines = 25) {
    [string] $logDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SimplySignLog'
    if (-not (Test-Path -LiteralPath $logDir)) { return '(无日志目录)' }
    $latest = Get-ChildItem -LiteralPath $logDir -Filter '*log.txt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return '(无日志文件)' }
    # 邮箱脱敏：日志会打 "logging in. user: <邮箱>"，避免证据贴进 CI 输出时外泄。
    return ((Get-Content -LiteralPath $latest.FullName -Tail $Lines) -join "`n") `
        -replace '([A-Za-z0-9._%+-]{2})[A-Za-z0-9._%+-]*@', '$1***@'
}

function Test-CertPresent([string] $Thumbprint) {
    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        return @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue).Count -gt 0
    }
    return $null -ne (Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $Thumbprint })
}

# --------------------------------------------------------------------------
# 1. 解析 otpauth:// URI
#    格式由 CloudService.QRData 的构造函数钉死：scheme=otpauth, host=totp,
#    path 以 "/Certum:" 开头。这里按同样的不变式校验，错了立刻报，
#    而不是让它在 serverLoginCas5 那边变成一个看不懂的 login failed。
# --------------------------------------------------------------------------
function ConvertFrom-OtpAuthUri([string] $Uri) {
    if ([string]::IsNullOrWhiteSpace($Uri)) {
        throw "缺少 seed。请设置 CERTUM_OTP_URI 或传 -SeedUri。"
    }
    [Uri] $parsed = [Uri] $Uri.Trim()
    if ($parsed.Scheme -ne 'otpauth') { throw "seed scheme 应为 otpauth，实际: $($parsed.Scheme)" }
    if ($parsed.Host -ne 'totp')      { throw "seed host 应为 totp，实际: $($parsed.Host)" }

    [hashtable] $q = @{}
    foreach ($part in $parsed.Query.TrimStart('?') -split '&') {
        $kv = $part -split '=', 2
        if ($kv.Count -eq 2) { $q[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }
    }
    if (-not $q.ContainsKey('secret')) { throw "seed 缺少 secret 参数" }

    # path 形如 /Certum:user@example.com
    [string] $label = [Uri]::UnescapeDataString($parsed.LocalPath).TrimStart('/')
    [string] $userFromLabel = if ($label -match ':') { ($label -split ':', 2)[1] } else { $label }

    return [pscustomobject]@{
        Secret    = $q['secret']
        Algorithm = $(if ($q.ContainsKey('algorithm')) { $q['algorithm'].ToUpperInvariant() } else { 'SHA1' })
        Digits    = $(if ($q.ContainsKey('digits'))    { [int] $q['digits'] }  else { 6 })
        Period    = $(if ($q.ContainsKey('period'))    { [int] $q['period'] }  else { 30 })
        User      = $userFromLabel
    }
}

# --------------------------------------------------------------------------
# 2. TOTP (RFC 6238)
#    支持 SHA1/SHA256/SHA512 —— 网上流传的那份 PowerShell 片段只实现了 SHA1
#    并在其它算法上直接 throw；Certum 目前发的是 SHA1，但把三种都实现掉
#    比留一个「哪天换算法就炸」的特例分支便宜。
# --------------------------------------------------------------------------
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Security.Cryptography;

public static class HibikiTotp
{
    private const string B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    private static byte[] Base32Decode(string s)
    {
        s = s.TrimEnd('=').Replace(" ", "").ToUpperInvariant();
        int bitBuffer = 0, bitsLeft = 0;
        var outBytes = new System.Collections.Generic.List<byte>(s.Length * 5 / 8 + 1);
        foreach (char c in s)
        {
            int val = B32.IndexOf(c);
            if (val < 0) throw new ArgumentException("Invalid Base32 char: " + c);
            bitBuffer = (bitBuffer << 5) | val;
            bitsLeft += 5;
            if (bitsLeft >= 8)
            {
                outBytes.Add((byte)(bitBuffer >> (bitsLeft - 8)));
                bitsLeft -= 8;
            }
        }
        return outBytes.ToArray();
    }

    private static HMAC NewHmac(string algorithm, byte[] key)
    {
        switch (algorithm)
        {
            case "SHA1":   return new HMACSHA1(key);
            case "SHA256": return new HMACSHA256(key);
            case "SHA512": return new HMACSHA512(key);
            default: throw new ArgumentException("Unsupported TOTP algorithm: " + algorithm);
        }
    }

    public static long CounterNow(int period)
    {
        return DateTimeOffset.UtcNow.ToUnixTimeSeconds() / period;
    }

    /// <summary>Seconds remaining in the current TOTP step.</summary>
    public static int SecondsRemaining(int period)
    {
        return period - (int)(DateTimeOffset.UtcNow.ToUnixTimeSeconds() % period);
    }

    public static string Compute(string secret, string algorithm, int digits, int period)
    {
        byte[] key = Base32Decode(secret);
        byte[] cnt = BitConverter.GetBytes(CounterNow(period));
        if (BitConverter.IsLittleEndian) Array.Reverse(cnt);

        byte[] hash;
        using (HMAC h = NewHmac(algorithm, key)) { hash = h.ComputeHash(cnt); }

        int offset = hash[hash.Length - 1] & 0x0F;
        int binary =
            ((hash[offset]     & 0x7F) << 24) |
            ((hash[offset + 1] & 0xFF) << 16) |
            ((hash[offset + 2] & 0xFF) << 8)  |
             (hash[offset + 3] & 0xFF);
        int otp = binary % (int)Math.Pow(10, digits);
        return otp.ToString(new string('0', digits));
    }
}
"@

# --------------------------------------------------------------------------
# 3. 主流程
# --------------------------------------------------------------------------
if ($ReuseExisting -and (Test-CertPresent $ExpectedThumbprint)) {
    Write-Step "已连接（证书已在 Cert:\CurrentUser\My），跳过重连。"
    exit 0
}

if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "找不到 SimplySignDesktop.exe: $ExePath（用 -ExePath 或 CERTUM_EXE_PATH 指定）"
}

$seed = ConvertFrom-OtpAuthUri $SeedUri
if ([string]::IsNullOrWhiteSpace($UserId)) { $UserId = $seed.User }
if ([string]::IsNullOrWhiteSpace($UserId)) {
    throw "无法确定 SimplySign 账号：seed URI 里没有 label，也没给 -UserId / CERTUM_USER_ID。"
}

# TOTP 码只在当前时间片内有效。如果剩余秒数太少，登录请求到达服务端时码可能
# 已经翻片 —— 这类失败是间歇性的，在 CI 上会表现成「偶发 login failed」，
# 极难归因。直接等到下一片开头再算，用几秒钟换掉一整类偶发红。
[int] $remaining = [HibikiTotp]::SecondsRemaining($seed.Period)
if ($remaining -lt 5) {
    Write-Step "当前 TOTP 时间片仅剩 ${remaining}s，等待翻片以避免竞态…"
    Start-Sleep -Seconds ($remaining + 1)
}

[string] $otp = [HibikiTotp]::Compute($seed.Secret, $seed.Algorithm, $seed.Digits, $seed.Period)
Write-Step "已生成 TOTP（$($seed.Algorithm)/$($seed.Digits)位/$($seed.Period)s，剩余 $([HibikiTotp]::SecondsRemaining($seed.Period))s）"

# /autologin 会先向现有 "SimplySign Desktop" 窗口发 WM_CLOSE 再起新实例，
# 所以这里不需要自己去杀进程。
Write-Step "启动 SimplySignDesktop.exe /autologin …"
Start-Process -FilePath $ExePath -ArgumentList @('/autologin', $UserId, $otp) | Out-Null

# 判绿只认「证书真的出现在存储里」。进程起来了、日志写了 login ok 都不够——
# signtool 要的是 CSP/KSP 把卡挂上，那一步晚于 login。
Write-Step "等待证书出现在 Cert:\CurrentUser\My（上限 ${TimeoutSeconds}s）…"
[System.Diagnostics.Stopwatch] $sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    if (Test-CertPresent $ExpectedThumbprint) {
        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
        Write-Step "连接成功，耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
        Write-Step "  证书: $($cert.Subject)"
        Write-Step "  指纹: $($cert.Thumbprint)"
        Write-Step "  有效期至: $($cert.NotAfter)"
        exit 0
    }
    Start-Sleep -Milliseconds 1000
}

Write-Host ""
Write-Host "[simplysign] 连接失败：${TimeoutSeconds}s 内证书未出现在 Cert:\CurrentUser\My" -ForegroundColor Red
Write-Host "[simplysign] SimplySign 日志尾部（邮箱已脱敏）：" -ForegroundColor Yellow
Write-Host (Get-SimplySignLogTail 25)
exit 1
