# 下载 RWKV-Instant 权重到 native/fushi_rwkv/model/ 并校验 SHA-256（Windows）。
#   大模型 RWKV_trained_on_5000_10000.bin（~11 MB，AGPL，见 UPSTREAM.md）
#   小模型发布包 sm56-package.zip（~5.6 MB：weights.int8.bin / weights.f32.bin / 黄金测试向量；
#   许可尚未声明，见 README.md「小模型」）
# 都不入库。
#
# 用法: powershell -ExecutionPolicy Bypass -File native/fushi_rwkv/fetch_model.ps1 [-DestDir <目录>] [-Proxy http://127.0.0.1:34151]
param(
    [string]$DestDir = (Join-Path $PSScriptRoot 'model'),
    [string]$Proxy = $env:HTTPS_PROXY
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

function Get-Pinned([string]$Name, [string]$Sha256, [string[]]$Urls) {
    $target = Join-Path $DestDir $Name
    if ((Test-Path $target) -and ((Get-FileHash -Algorithm SHA256 $target).Hash.ToLower() -eq $Sha256)) {
        Write-Host "OK (cached): $target"
        return
    }
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
                return
            }
            Write-Warning "sha256 mismatch from ${url}: $actual"
        } catch {
            Write-Warning "download failed from ${url}: $_"
        }
        if (Test-Path $tmp) { Remove-Item -Force $tmp }
    }
    Write-Error "could not fetch $Name with sha256 $Sha256"
    exit 1
}

# 大模型：钉死到具体 commit（与 src/lib.rs 的 UPSTREAM_SHA 一致）；第二个是同一文件在
# JSchoreels/anki 的副本（字节相同，作备用）。SHA-256 同 src/lib.rs 的 MODEL_SHA256。
$Big = 'RWKV_trained_on_5000_10000.bin'
Get-Pinned $Big '749ad1ad18d5b6ef8c4185802fa0c1e4a14e67cd7874f3efeaae355fffb1b9ec' @(
    "https://raw.githubusercontent.com/Pedrubik2000/kuma3-anki-core/c639bcec696f2317f9bb9a736d433b9d6c0d9c56/qt/aqt/rwkv_inference/$Big",
    "https://raw.githubusercontent.com/JSchoreels/anki/0dd75c5f8fa4ea3543f5a3559870e8aea047bf80/qt/aqt/rwkv_inference/$Big"
)

# 小模型：GitHub release 资产（作者可以替换同名资产，所以只认钉死的 SHA-256，
# 同 src/lib.rs 的 SMALL_MODEL_PACKAGE_SHA256）。
Get-Pinned 'sm56-package.zip' '7b1790f49fdabf1279510247cc9bc3bf3ac461b67cf0135ab8e51589b5efe71a' @(
    'https://github.com/JSchoreels/anki-rwkv/releases/download/small-model-sm56-2026-10-24/sm56-package.zip'
)
exit 0
