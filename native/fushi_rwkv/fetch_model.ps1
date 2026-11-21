# 下载 RWKV-Instant 权重到 native/fushi_rwkv/model/ 并校验 SHA-256（Windows）。
#   大模型 RWKV_trained_on_5000_10000.bin（~11 MB，AGPL，见 UPSTREAM.md）
#   小模型 sm98（Instant-Only，show-time 间隔训练）：int8 / f32 权重、architecture.json、黄金测试向量
#   （共 ~2.1 MB，AGPL；见 README.md「小模型」）。int8 权重首选 Fushi 自己的镜像 release
#   （hajisensai/Fushi tag rwkv-models，内容寻址、永不覆盖），上游 JSchoreels/anki 钉死提交的 raw URL 备用；
#   其余三个文件只在上游提交里。
# 都不入库。
#
# 用法: powershell -ExecutionPolicy Bypass -File native/fushi_rwkv/fetch_model.ps1 [-DestDir <目录>] [-Proxy <代理 URL>]
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

# 小模型 sm98：钉 JSchoreels/anki 的提交（同 src/lib.rs 的 SMALL_MODEL_SOURCE_SHA）；
# SHA-256 同 src/lib.rs 的 SMALL_MODEL_*_SHA256（与该提交的 manifest.json 一致）。
$Mirror = 'https://github.com/hajisensai/Fushi/releases/download/rwkv-models'
$Small = 'https://raw.githubusercontent.com/JSchoreels/anki/001440b03395f24ffc1714b18ad3d9d4d89d2067'
Get-Pinned 'sm98_weights.int8.bin' 'b2f335bd712b9d602150201de41ab5a0f0a4c291644705e2aa1ed2a1bf1592c3' @(
    "$Mirror/b2f335bd712b9d60-sm98-weights.int8.bin",
    "$Small/qt/aqt/rwkv_inference/sm98/weights.int8.bin"
)
Get-Pinned 'sm98_weights.f32.bin' 'a006dcc039d19142dc95d257d9c238fb93c7efa12b78e18ec6ae881ac9009a24' @(
    "$Small/qt/aqt/rwkv_inference/sm98/weights.f32.bin"
)
Get-Pinned 'sm98_architecture.json' '9bd41f1189dc0113277d371223ce805612aaec07101804160fe86312eed15de3' @(
    "$Small/qt/aqt/rwkv_inference/sm98/architecture.json"
)
Get-Pinned 'sm98-vectors.json.gz' 'c7d8df407966fccd8f98227241816e114ce9ed1dfea799587e481c1d5926a453' @(
    "$Small/rslib/src/rwkv/testdata/sm98-vectors.json.gz"
)
# Tiny 小模型 sm101：同一提交；SHA-256 同 src/lib.rs 的 TINY_MODEL_*_SHA256。
Get-Pinned 'sm101_weights.int8.bin' '77703dd2f2a21a1bcadaedfed1cec93ee0fd6fd6d3c840be221e72b5e1c05066' @(
    "$Mirror/77703dd2f2a21a1b-sm101-weights.int8.bin",
    "$Small/qt/aqt/rwkv_inference/sm101/weights.int8.bin"
)
Get-Pinned 'sm101_weights.f32.bin' '2faacb5b913bcfbdc0e363532d533e3bcff6872c8358f1ef753ca87f9d2a60fd' @(
    "$Small/qt/aqt/rwkv_inference/sm101/weights.f32.bin"
)
Get-Pinned 'sm101_architecture.json' '49650457329d43ff7f3f04f68926e371d49060699142cfec9497cb759ac7a75f' @(
    "$Small/qt/aqt/rwkv_inference/sm101/architecture.json"
)
Get-Pinned 'sm101-vectors.json.gz' '18de8ae77a1a40986dc432531116dfb009beae2385001ef425389a3ad7919a9e' @(
    "$Small/rslib/src/rwkv/testdata/sm101-vectors.json.gz"
)
exit 0
