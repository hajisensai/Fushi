# 志愿者电脑上运行（解压适配包后，在包目录里右键「用 PowerShell 运行」或命令行执行）：
#
#   powershell -ExecutionPolicy Bypass -File install_agent.ps1 -Name 小明 -Gateway ws://100.64.1.2:8765/agent -Token <维护者给的 token>
#
# 做三件事：写 agent.json；登录后自动启动 agent；现在就启动一次。
# -Elevated：以最高权限启动（游戏以管理员身份运行时必须，否则点击被 UIPI 拦下）。
# -Uninstall：去掉自启动并结束 agent。
param(
  [string]$Name = "",
  [string]$Gateway = "",
  [string]$Token = "",
  [switch]$Elevated,
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
$Exe = Join-Path $Here "fushi-adapt-agent.exe"
$Config = Join-Path $Here "agent.json"
$TaskName = "FushiAdaptAgent"
$Shortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Fushi 远程适配 agent.lnk"

function Remove-Autostart {
  if (Test-Path $Shortcut) { Remove-Item $Shortcut -Force }
  try { & schtasks /Delete /TN $TaskName /F 2>$null | Out-Null } catch {}
}

if ($Uninstall) {
  Remove-Autostart
  Get-Process fushi-adapt-agent -ErrorAction SilentlyContinue | Stop-Process -Force
  Write-Host "已移除自启动并结束 agent。可以直接删除本目录。"
  exit 0
}

if (-not (Test-Path $Exe)) { throw "找不到 $Exe，请在解压后的适配包目录里运行" }

if (-not (Test-Path $Config)) {
  if (-not $Name -or -not $Gateway -or -not $Token) {
    throw "首次安装需要 -Name -Gateway -Token（向维护者要）"
  }
  $cfg = [ordered]@{
    name = $Name
    gateway = $Gateway
    token = $Token
    workdir = (Join-Path $Here "work")
    galdriver_exe = "driver\fushi.exe"
    seed_support_dir = "%APPDATA%\Fushi\Fushi"
    seed_documents_dir = $null
  }
  $json = $cfg | ConvertTo-Json
  [System.IO.File]::WriteAllText($Config, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "已写入 $Config"
} else {
  Write-Host "沿用已有 $Config（要改机器名 / 网关就直接编辑它）"
}

if (-not (Get-Command tailscale -ErrorAction SilentlyContinue) -and
    -not (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) {
  Write-Warning "没检测到 Tailscale。请先安装并用维护者发的邀请登录：winget install Tailscale.Tailscale"
}

Remove-Autostart
if ($Elevated) {
  # 登录时以最高权限、在交互桌面里启动（/IT），能操作以管理员运行的游戏。
  & schtasks /Create /TN $TaskName /TR "`"$Exe`"" /SC ONLOGON /RL HIGHEST /IT /F | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "创建计划任务失败（-Elevated 需要在管理员 PowerShell 里运行）" }
  & schtasks /Run /TN $TaskName | Out-Null
  Write-Host "已设置登录后以管理员身份自动启动，并已启动。"
} else {
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut($Shortcut)
  $lnk.TargetPath = $Exe
  $lnk.WorkingDirectory = $Here
  $lnk.WindowStyle = 7  # 最小化
  $lnk.Save()
  Start-Process -FilePath $Exe -WorkingDirectory $Here -WindowStyle Minimized
  Write-Host "已设置登录后自动启动，并已启动（任务栏里的「Fushi 远程适配 agent」窗口，关掉即断开）。"
}
