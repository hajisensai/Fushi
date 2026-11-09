# 下载 RWKV-Instant 权重到 native/fushi_rwkv/model/ 并校验 SHA-256（Windows）。
#   大模型 RWKV_trained_on_5000_10000.bin（~11 MB，AGPL，见 UPSTREAM.md）
#   小模型 sm72e25（无泄漏 SM72、第 25 轮起降温）：int8 / f32 权重、architecture.json、黄金测试向量
#   （共 ~2.1 MB，钉 JSchoreels/anki 的提交，AGPL；见 README.md「小模型」）
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

# 小模型 sm72e25：钉 JSchoreels/anki 的提交（同 src/lib.rs 的 SMALL_MODEL_SOURCE_SHA）；
# SHA-256 同 src/lib.rs 的 SMALL_MODEL_*_SHA256（与该提交的 manifest.json 一致）。
$Small = 'https://raw.githubusercontent.com/JSchoreels/anki/986963d23e7ec9f22771c38998ef9042214c2b98'
Get-Pinned 'sm72e25_weights.int8.bin' 'ff626af2e974346ed282615d190500148b22cfe05cbfd081b1e70d5a1dfa3cd9' @(
    "$Small/qt/aqt/rwkv_inference/sm72e25/weights.int8.bin"
)
Get-Pinned 'sm72e25_weights.f32.bin' '42b79e35ad78bf291817cb48979f48fd105b39fc43b6a5ca954938d3f25cf261' @(
    "$Small/qt/aqt/rwkv_inference/sm72e25/weights.f32.bin"
)
Get-Pinned 'sm72e25_architecture.json' '9bd41f1189dc0113277d371223ce805612aaec07101804160fe86312eed15de3' @(
    "$Small/qt/aqt/rwkv_inference/sm72e25/architecture.json"
)
Get-Pinned 'sm72e25-vectors.json.gz' 'db54656bc41a22a175d2b905304d45e6ae6b0bb4efd1af8dfce9185f40ee1a01' @(
    "$Small/rslib/src/rwkv/testdata/sm72e25-vectors.json.gz"
)
exit 0
