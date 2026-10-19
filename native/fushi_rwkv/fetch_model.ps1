# 下载 RWKV-Instant 通用预训练权重到 native/fushi_rwkv/model/ 并校验 SHA-256（Windows）。
# 权重（~11 MB）不入库；来源与许可见 UPSTREAM.md。
#
# 用法: powershell -ExecutionPolicy Bypass -File native/fushi_rwkv/fetch_model.ps1 [-DestDir <目录>] [-Proxy http://127.0.0.1:34151]
param(
    [string]$DestDir = (Join-Path $PSScriptRoot 'model'),
    [string]$Proxy = $env:HTTPS_PROXY
)
$ErrorActionPreference = 'Stop'

$Name = 'RWKV_trained_on_5000_10000.bin'
$Sha256 = '749ad1ad18d5b6ef8c4185802fa0c1e4a14e67cd7874f3efeaae355fffb1b9ec'
# 钉死到具体 commit（与 src/lib.rs 的 UPSTREAM_SHA 一致）；第二个是同一文件在
# JSchoreels/anki 的副本（字节相同，作备用）。
$Urls = @(
    "https://raw.githubusercontent.com/Pedrubik2000/kuma3-anki-core/c639bcec696f2317f9bb9a736d433b9d6c0d9c56/qt/aqt/rwkv_inference/$Name",
    "https://raw.githubusercontent.com/JSchoreels/anki/0dd75c5f8fa4ea3543f5a3559870e8aea047bf80/qt/aqt/rwkv_inference/$Name"
)

New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
$target = Join-Path $DestDir $Name
if ((Test-Path $target) -and ((Get-FileHash -Algorithm SHA256 $target).Hash.ToLower() -eq $Sha256)) {
    Write-Host "OK (cached): $target"
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tmp = "$target.download"
foreach ($url in $Urls) {
    Write-Host "downloading $url"
    try {
        $params = @{ Uri = $url; OutFile = $tmp; UseBasicParsing = $true }
        if ($Proxy) { $params.Proxy = $Proxy }
        Invoke-WebRequest @params
        $actual = (Get-FileHash -Algorithm SHA256 $tmp).Hash.ToLower()
        if ($actual -eq $Sha256) {
            Move-Item -Force $tmp $target
            Write-Host "OK: $target (sha256 $Sha256)"
            exit 0
        }
        Write-Warning "sha256 mismatch from ${url}: $actual"
    } catch {
        Write-Warning "download failed from ${url}: $_"
    }
    if (Test-Path $tmp) { Remove-Item -Force $tmp }
}
Write-Error "could not fetch $Name with sha256 $Sha256"
exit 1
