# 在本机打出发给志愿者的适配包：fushi-adapt-agent.exe + galgame 真机驱动 + 安装脚本。
#
#   powershell -ExecutionPolicy Bypass -File tool/remote_adapt/build_agent.ps1            # 只打 agent，驱动用已有构建
#   powershell -ExecutionPolicy Bypass -File tool/remote_adapt/build_agent.ps1 -BuildDriver
#
# 产物：tool/remote_adapt/dist/fushi-adapt/ 与同级 fushi-adapt-<日期>.zip（不入库）。
# 驱动 = fushi/integration_test/gal_realgame_driver_itest.dart 打成的 Debug 版 fushi.exe，
# 与 dist_test 跑 itest 用的是同一种构建；志愿者电脑不需要 Flutter SDK。
param(
  [switch]$BuildDriver,
  [switch]$SkipDriver,
  [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
$Repo = (Resolve-Path (Join-Path $Here "..\..")).Path
$App = Join-Path $Repo "fushi"
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $Here "dist" }
$Stage = Join-Path $OutDir "fushi-adapt"
$Work = Join-Path $OutDir "_pyinstaller"

if ($BuildDriver) {
  Push-Location $App
  try {
    & dart tool/heavy.dart --check-only -- flutter build windows --debug `
      -t integration_test/gal_realgame_driver_itest.dart
    if ($LASTEXITCODE -ne 0) { throw "驱动构建失败 exit=$LASTEXITCODE" }
    # flutter build 只在 native/galgame_hook/dist 已有双架构 zip 时才装 voice_hook/；
    # 新工作区没有 dist，这里补齐：构建 helper 分发包，再装进驱动目录。
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

if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path $Stage, $Work | Out-Null

& python -m PyInstaller --noconfirm --clean --onefile --console `
  --name fushi-adapt-agent `
  --paths $Here `
  --hidden-import win_desktop `
  --distpath $Stage --workpath $Work --specpath $Work `
  (Join-Path $Here "fleet_agent.py")
if ($LASTEXITCODE -ne 0) { throw "PyInstaller 失败 exit=$LASTEXITCODE" }

Copy-Item (Join-Path $Here "agent.example.json") $Stage
Copy-Item (Join-Path $Here "install_agent.ps1") $Stage
Copy-Item (Join-Path $Here "VOLUNTEER.md") $Stage

if (-not $SkipDriver) {
  $DriverSrc = Join-Path $App "build\windows\x64\runner\Debug"
  $DriverExe = Join-Path $DriverSrc "fushi.exe"
  if (-not (Test-Path $DriverExe)) {
    throw "找不到驱动构建 $DriverExe；加 -BuildDriver 先构建"
  }
  # 确认这份 Debug 构建的入口确实是驱动，而不是别人留下的普通 Debug 构建。
  $kernel = Join-Path $DriverSrc "data\flutter_assets\kernel_blob.bin"
  if (-not (Select-String -Path $kernel -Pattern "galgame 真机交互驱动" -SimpleMatch -Quiet -Encoding UTF8)) {
    throw "$DriverSrc 不是 gal_realgame_driver 构建（kernel 里没有驱动入口）；加 -BuildDriver 重打"
  }
  if (-not (Test-Path (Join-Path $DriverSrc "voice_hook\x64")) -or
      -not (Test-Path (Join-Path $DriverSrc "voice_hook\x86"))) {
    throw "驱动构建缺 voice_hook\x64 或 voice_hook\x86（install_into_bundle 未执行）"
  }
  $DriverDst = Join-Path $Stage "driver"
  New-Item -ItemType Directory -Force -Path $DriverDst | Out-Null
  & robocopy $DriverSrc $DriverDst /E /NFL /NDL /NJH /NJS /NP /XF *.pdb *.ilk *.exp *.lib | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "复制驱动失败 robocopy=$LASTEXITCODE" }
}

$Zip = Join-Path $OutDir ("fushi-adapt-" + (Get-Date -Format "yyyyMMdd-HHmm") + ".zip")
Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $Zip -Force
$size = [math]::Round((Get-Item $Zip).Length / 1MB, 1)
Write-Host "[build_agent] $Zip ($size MB)"
