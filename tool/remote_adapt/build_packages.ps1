# 一条命令打出两个压缩包（token 和地址都已写好，解压即用）：
#
#   powershell -ExecutionPolicy Bypass -File tool/remote_adapt/build_packages.ps1 -Gateway <你的公网域名或IP>
#   （首次或驱动代码有变化时加 -BuildDriver）
#
#   dist/fushi-adapt-主控端-<日期>.zip  你自己用：解压，双击 fushi-fleet-gateway.exe
#   dist/fushi-adapt-志愿者-<日期>.zip  发给朋友：解压，双击 双击开始适配.exe
#
# token 与网关证书存在 ~/.fushi-fleet/（没有就生成），两个包配套；换掉任一个都会让旧志愿者包失效。
# 主控端包里有 token 和证书私钥，只留在自己手里。
# 驱动 = fushi/integration_test/gal_realgame_driver_itest.dart 打成的 Debug 版 fushi.exe，
# 志愿者电脑不需要 Flutter SDK。
param(
  [Parameter(Mandatory = $true)][string]$Gateway,
  [int]$Port = 8765,          # 志愿者连的公网端口（路由器对外端口）
  [int]$ListenPort = 48765,   # 网关在本机监听的端口（路由器转发的目标；本机 8765 被 Fushi 占用）
  [switch]$BuildDriver,
  [switch]$SkipDriver
)

$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
$Repo = (Resolve-Path (Join-Path $Here "..\..")).Path
$App = Join-Path $Repo "fushi"
$OutDir = Join-Path $Here "dist"
$Work = Join-Path $OutDir "_pyinstaller"
$Stamp = Get-Date -Format "yyyyMMdd-HHmm"

# 地址：允许写 host 或 host:port；中文域名转 punycode（websockets 只认 ASCII 主机名）。
$hostPart = $Gateway.Trim()
if ($hostPart -match '^(.+):(\d+)$') { $hostPart = $Matches[1]; $Port = [int]$Matches[2] }
$hostAscii = (New-Object System.Globalization.IdnMapping).GetAscii($hostPart)
$GatewayUrl = "wss://${hostAscii}:$Port/agent"

$TokenFile = Join-Path $env:USERPROFILE ".fushi-fleet\token"
if (-not (Test-Path $TokenFile)) {
  & python (Join-Path $Here "fleet_gateway.py") --print-token --token-file $TokenFile | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "生成 token 失败" }
}
$Token = (Get-Content -Raw -Encoding UTF8 $TokenFile).Trim()
# 网关自签 TLS 证书（~/.fushi-fleet/gateway.crt/.key，没有就生成）。证书写进志愿者包，agent 只信任它，
# 公网上被 DNS 劫持或中间人冒充时连不上，也不会把 token 交出去。
$CertDir = Join-Path $env:USERPROFILE ".fushi-fleet"
$CertPem = (& python (Join-Path $Here "fleet_gateway.py") --print-cert --cert-dir $CertDir) -join "`n"
if ($LASTEXITCODE -ne 0 -or $CertPem -notmatch "BEGIN CERTIFICATE") { throw "生成网关证书失败" }

if ($BuildDriver) {
  Push-Location $App
  try {
    & dart tool/heavy.dart --check-only -- flutter build windows --debug `
      -t integration_test/gal_realgame_driver_itest.dart
    if ($LASTEXITCODE -ne 0) { throw "驱动构建失败 exit=$LASTEXITCODE" }
    # flutter build 只在 native/galgame_hook/dist 已有双架构 zip 时才装 voice_hook/；新工作区补齐。
    $HookRoot = Join-Path $Repo "native\galgame_hook"
    & dart tool/heavy.dart --check-only -- powershell -NoProfile -ExecutionPolicy Bypass `
      -File (Join-Path $HookRoot "tools\build_distribution.ps1")
    if ($LASTEXITCODE -ne 0) { throw "galgame helper 构建失败 exit=$LASTEXITCODE" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HookRoot "tools\install_into_bundle.ps1") `
      -BundleDirectory (Join-Path $App "build\windows\x64\runner\Debug") `
      -DistDirectory (Join-Path $HookRoot "dist")
    if ($LASTEXITCODE -ne 0) { throw "helper 装入驱动目录失败 exit=$LASTEXITCODE" }
  } finally { Pop-Location }
}

function Build-Exe([string]$Script, [string]$Name, [string]$Dest) {
  # --uac-admin：双击即弹 UAC 以管理员运行（管理员权限的游戏也能被操作；网关要写防火墙规则）。
  & python -m PyInstaller --noconfirm --clean --onefile --console --uac-admin `
    --name $Name --paths $Here --hidden-import win_desktop `
    --distpath $Dest --workpath (Join-Path $Work $Name) --specpath (Join-Path $Work $Name) `
    (Join-Path $Here $Script)
  if ($LASTEXITCODE -ne 0) { throw "PyInstaller $Name 失败 exit=$LASTEXITCODE" }
}

function Write-Utf8([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

# ── 志愿者包 ────────────────────────────────────────────────────────────────
$Vol = Join-Path $OutDir "志愿者"
if (Test-Path $Vol) { Remove-Item -Recurse -Force $Vol }
New-Item -ItemType Directory -Force -Path $Vol, $Work | Out-Null
Build-Exe "fleet_agent.py" "fushi-adapt-agent" $Vol
Move-Item (Join-Path $Vol "fushi-adapt-agent.exe") (Join-Path $Vol "双击开始适配.exe")
$agentJson = [ordered]@{ gateway = $GatewayUrl; token = $Token; name = ""; gateway_cert = $CertPem } | ConvertTo-Json
Write-Utf8 (Join-Path $Vol "agent.json") $agentJson
Copy-Item (Join-Path $Here "VOLUNTEER.txt") (Join-Path $Vol "说明.txt")

if (-not $SkipDriver) {
  $DriverSrc = Join-Path $App "build\windows\x64\runner\Debug"
  if (-not (Test-Path (Join-Path $DriverSrc "fushi.exe"))) {
    throw "找不到驱动构建 $DriverSrc\fushi.exe；加 -BuildDriver 先构建"
  }
  # 确认这份 Debug 构建的入口确实是驱动，而不是别人留下的普通 Debug 构建。
  $kernel = Join-Path $DriverSrc "data\flutter_assets\kernel_blob.bin"
  if (-not (Select-String -Path $kernel -Pattern "galgame 真机交互驱动" -SimpleMatch -Quiet -Encoding UTF8)) {
    throw "$DriverSrc 不是 gal_realgame_driver 构建；加 -BuildDriver 重打"
  }
  if (-not (Test-Path (Join-Path $DriverSrc "voice_hook\x64")) -or
      -not (Test-Path (Join-Path $DriverSrc "voice_hook\x86"))) {
    throw "驱动构建缺 voice_hook\x64 或 voice_hook\x86；加 -BuildDriver 重打"
  }
  & robocopy $DriverSrc (Join-Path $Vol "driver") /E /NFL /NDL /NJH /NJS /NP /XF *.pdb *.ilk *.exp *.lib | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "复制驱动失败 robocopy=$LASTEXITCODE" }
}

# ── 主控端包 ────────────────────────────────────────────────────────────────
$Ctl = Join-Path $OutDir "主控端"
if (Test-Path $Ctl) { Remove-Item -Recurse -Force $Ctl }
New-Item -ItemType Directory -Force -Path $Ctl | Out-Null
Build-Exe "fleet_gateway.py" "fushi-fleet-gateway" $Ctl
Write-Utf8 (Join-Path $Ctl "token.txt") $Token
Write-Utf8 (Join-Path $Ctl "gateway.json") (@{ agent_port = $ListenPort } | ConvertTo-Json)
Copy-Item (Join-Path $CertDir "gateway.crt"), (Join-Path $CertDir "gateway.key") $Ctl
Write-Utf8 (Join-Path $Ctl "说明.txt") @"
双击 fushi-fleet-gateway.exe（会弹管理员确认），保持窗口打开。
第一次运行会自动：放行防火墙入站 TCP $ListenPort、把 fleet 注册进 Claude Code。

志愿者连的地址：$GatewayUrl
路由器要把公网 TCP $Port 转发到这台电脑的 TCP $ListenPort。

然后在 Claude Code 新开一个会话，直接说「看看有哪些机器在线」「在 XXX 上启动驱动 launch 某游戏」即可，
一个会话可以同时操作所有在线机器。操作记录在 %USERPROFILE%\.fushi-fleet\audit\。

token.txt 和 gateway.key 别外传：有它们就能冒充网关或连进来。
"@

foreach ($pair in @(@($Vol, "志愿者"), @($Ctl, "主控端"))) {
  $zip = Join-Path $OutDir ("fushi-adapt-" + $pair[1] + "-" + $Stamp + ".zip")
  Compress-Archive -Path (Join-Path $pair[0] "*") -DestinationPath $zip -Force
  $size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
  Write-Host "[build_packages] $zip ($size MB)"
}
Write-Host "[build_packages] 志愿者连接地址 $GatewayUrl"
