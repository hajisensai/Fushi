<#
.SYNOPSIS
  取 Magpie fork release 的完整包，裁成随主包发行的精简包（BUG-1217）。

.DESCRIPTION
  完整包 10.79 MB / 29.39 MB(解压)，其中 effects/ 占 16.41 MB（158 个文件），而 Magpie
  默认的 7 个 scalingMode 一共只引用 8 个 effect。裁掉没被引用的 145 个之后是
  4.72 MB / 13.35 MB(解压) —— 随 Windows 主包发行的就是这一份。

  🔴 裁剪清单不是拍脑袋定的，是 Magpie 源码里 `AppSettings::_SetDefaultScalingModes()`
  （src/Magpie/AppSettings.cpp:1182-1252）逐条抄下来的。改 Magpie 版本时必须重新核对该
  函数：它多一个默认 mode，这里就要多留一个 effect，否则用户切到那个 mode 会拿到
  「effect 文件不存在」而不是降级。

  同时保留全部 *.hlsli —— 那是 effect 之间的共享 include，删了会让保留下来的 effect
  编译失败（它们只有 0.37 MB，没有裁的价值）。

  产物：dist/Magpie-hibiki-slim-<arch>.zip 与同名 .sha256 侧车。
  消费方：fushi/lib/src/mining/magpie_installer.dart 的 _installBundledMagpie。

.PARAMETER Arch
  目标架构。默认只出 x64 —— ARM64 Windows 用户极少且能跑 x64 模拟，为它多背 4.7 MB
  不划算，那条路继续走按需下载。

.PARAMETER OutputDir
  产物目录，默认 <repo>/dist。
#>
[CmdletBinding()]
param(
  [ValidateSet('x64', 'ARM64')]
  [string[]]$Arch = @('x64'),
  [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'dist' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$repo = 'hajisensai/Magpie'
$tag = 'magpie-hibiki'

# Magpie 默认 7 个 scalingMode 引用的全部 effect（不含扩展名，用 / 分隔子目录）。
# 来源：src/Magpie/AppSettings.cpp:1182-1252，逐条对应：
#   [0] Lanczos          -> Lanczos
#   [1] FSR              -> FSR/FSR_EASU + FSR/FSR_RCAS
#   [2] FSRCNNX          -> FSRCNNX/FSRCNNX
#   [3] CuNNy            -> CuNNy2/CuNNy-4x12-NVL
#   [4] Anime4K          -> Anime4K/Anime4K_Upscale_Denoise_L
#   [5] CRT-Geom         -> CRT/CRT_Geom
#   [6] Integer Scale 2x -> Nearest
$keepEffects = @(
  'Lanczos',
  'FSR/FSR_EASU',
  'FSR/FSR_RCAS',
  'FSRCNNX/FSRCNNX',
  'CuNNy2/CuNNy-4x12-NVL',
  'Anime4K/Anime4K_Upscale_Denoise_L',
  'CRT/CRT_Geom',
  'Nearest'
)

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Invoke-WebRequest 不读 HTTPS_PROXY/HTTP_PROXY 环境变量（.NET 走的是系统代理设置）。
# CI 上直连 GitHub 没问题，本机验证多半要过代理，所以显式透传一次；变量没设时
# $webArgs 里就没有 Proxy 键，行为与原来完全一致。
$webArgs = @{ UseBasicParsing = $true }
$proxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { $null }
if ($proxy) {
  $webArgs['Proxy'] = $proxy
  Write-Host "使用代理 $proxy"
}

foreach ($a in $Arch) {
  Write-Host "=== $a"
  $work = Join-Path ([System.IO.Path]::GetTempPath()) ("magpie_slim_" + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  try {
    $fullZip = Join-Path $work "Magpie-hibiki-$a.zip"
    $url = "https://github.com/$repo/releases/download/$tag/Magpie-hibiki-$a.zip"

    Write-Host "  下载 $url"
    Invoke-WebRequest -Uri $url -OutFile $fullZip @webArgs

    # 🔴 先校验上游完整包，再裁。裁剪会重新打包 —— 若源包已被掉包，精简包会带着
    # 我们自己签的、看起来完全可信的侧车流进主包，等于亲手洗白一个被污染的产物。
    Write-Host "  校验上游侧车"
    $sidecarUrl = "$url.sha256"
    $sidecarBody = (Invoke-WebRequest -Uri $sidecarUrl @webArgs).Content
    # UseBasicParsing 对非 text/* 响应会给出 byte[]，先归一成字符串再匹配。
    if ($sidecarBody -is [byte[]]) {
      $sidecarBody = [System.Text.Encoding]::ASCII.GetString($sidecarBody)
    }
    if ($sidecarBody -notmatch '[0-9a-fA-F]{64}') {
      throw "上游侧车里没有合法 SHA-256 ($a)：$sidecarBody"
    }
    $expected = $Matches[0].ToLowerInvariant()
    $actual = Get-Sha256 $fullZip
    if ($expected -ne $actual) {
      throw "上游包 SHA-256 不符 ($a)：期望 $expected，实际 $actual"
    }

    $slimZip = Join-Path $OutputDir "Magpie-hibiki-slim-$a.zip"
    if (Test-Path -LiteralPath $slimZip) { Remove-Item -LiteralPath $slimZip -Force }

    $src = [System.IO.Compression.ZipFile]::OpenRead($fullZip)
    try {
      $dstStream = [System.IO.File]::Open($slimZip, [System.IO.FileMode]::CreateNew)
      try {
        $dst = New-Object System.IO.Compression.ZipArchive($dstStream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
          $kept = 0; $dropped = 0
          foreach ($entry in $src.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $name = $entry.FullName -replace '\\', '/'
            $keep = $true
            if ($name.StartsWith('effects/')) {
              $rel = $name.Substring('effects/'.Length)
              $ext = [System.IO.Path]::GetExtension($rel).TrimStart('.').ToLowerInvariant()
              $stem = $rel -replace '\.[^.]+$', ''
              # .hlsli = 共享 include，一律保留（见文件头说明）
              $keep = ($ext -eq 'hlsli') -or ($keepEffects -contains $stem)
            }
            if (-not $keep) { $dropped++; continue }
            $kept++
            $newEntry = $dst.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
            $inS = $entry.Open()
            try {
              $outS = $newEntry.Open()
              try { $inS.CopyTo($outS) } finally { $outS.Dispose() }
            } finally { $inS.Dispose() }
          }
          Write-Host "  保留 $kept 个文件，裁掉 $dropped 个"
        } finally { $dst.Dispose() }
      } finally { $dstStream.Dispose() }
    } finally { $src.Dispose() }

    $slimSha = Get-Sha256 $slimZip
    Set-Content -LiteralPath "${slimZip}.sha256" -Value $slimSha -Encoding ascii -NoNewline
    $mb = [math]::Round((Get-Item -LiteralPath $slimZip).Length / 1MB, 2)
    Write-Host "  产物 $slimZip ($mb MB)"
    Write-Host "  sha256 $slimSha"
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "完成。产物在 $OutputDir"
