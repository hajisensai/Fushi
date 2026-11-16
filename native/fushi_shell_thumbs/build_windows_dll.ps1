# 构建 Windows x64 版资源管理器封面缩略图的两个产物（纯 Rust）：
#   fushi_shell_thumbs.dll        —— COM 进程内服务器，跑在 explorer.exe 里，只转交路径；
#   fushi_shell_thumbs_host.exe   —— 一次性宿主进程，真正解析文件；按自身所在目录加载随包的
#                                    7z.dll / pdfium.dll，缺了只是对应格式不出缩略图。
#
# 前提：rustup target add x86_64-pc-windows-msvc（MSVC 工具链）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File native/fushi_shell_thumbs/build_windows_dll.ps1
#   powershell -ExecutionPolicy Bypass -File native/fushi_shell_thumbs/build_windows_dll.ps1 -InstallDirectory <Release bundle 目录>
# 产物：native/fushi_shell_thumbs/prebuilt/windows-x64/ 下的上述两个文件（git 忽略，不入库）；
# 给了 -InstallDirectory 时再拷一份进去（release-desktop.yml 用它放进安装包的 {app}）。
#
# 只随安装包走、不进 flutter build 的 bundle：它们不是 app 进程的依赖，只由安装器
# （fushi/windows/installer/fushi.iss）注册成 COM 进程内服务器。

[CmdletBinding()]
param(
    [string]$Target = "x86_64-pc-windows-msvc",
    [string]$InstallDirectory = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $scriptDir "prebuilt\windows-x64"
$artifacts = @("fushi_shell_thumbs.dll", "fushi_shell_thumbs_host.exe")

Push-Location $scriptDir
try {
    Write-Host "==> cargo build --release --locked --target $Target"
    & cargo build --release --locked --target $Target
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
} finally {
    Pop-Location
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
foreach ($name in $artifacts) {
    $built = Join-Path $scriptDir "target\$Target\release\$name"
    if (-not (Test-Path $built)) { throw "缺少构建产物 $built" }
    Copy-Item $built (Join-Path $outDir $name) -Force
    Write-Host ("==> Built: {0} ({1:N0} bytes)" -f (Join-Path $outDir $name), (Get-Item $built).Length)
}

if ($InstallDirectory -ne "") {
    if (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
        throw "InstallDirectory does not exist: $InstallDirectory"
    }
    foreach ($name in $artifacts) {
        Copy-Item (Join-Path $outDir $name) (Join-Path $InstallDirectory $name) -Force
    }
    Write-Host "==> Installed into $InstallDirectory"
}
