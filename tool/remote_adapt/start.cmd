@echo off
rem 远程适配 MCP 服务启动脚本（手动运行，不做自启动）。
rem 以管理员身份运行：以管理员身份运行的游戏只接受同等权限进程的注入（UIPI）。
rem 首次运行在 %LOCALAPPDATA%\fushi_remote_adapt\venv 建虚拟环境并装依赖。
setlocal
chcp 65001 >nul

net session >nul 2>&1
if errorlevel 1 (
  echo 正在请求管理员权限……
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
  ) else (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
  )
  exit /b
)

set "STATE=%LOCALAPPDATA%\fushi_remote_adapt"
set "VENV=%STATE%\venv"
if not exist "%VENV%\Scripts\python.exe" (
  echo 首次运行：创建 Python 虚拟环境……
  py -3 -m venv "%VENV%" 2>nul || python -m venv "%VENV%"
  if not exist "%VENV%\Scripts\python.exe" (
    echo 需要 Python 3.10+：winget install Python.Python.3.12
    pause
    exit /b 1
  )
)
"%VENV%\Scripts\python.exe" -m pip install -q --disable-pip-version-check -r "%~dp0requirements.txt"
if errorlevel 1 (
  echo 依赖安装失败
  pause
  exit /b 1
)

rem 防火墙只放行 Tailscale 网段（100.64.0.0/10）进 8765，幂等。
powershell -NoProfile -Command "if (-not (Get-NetFirewallRule -DisplayName 'fushi-remote-adapt' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName 'fushi-remote-adapt' -Direction Inbound -Protocol TCP -LocalPort 8765 -RemoteAddress 100.64.0.0/10 -Action Allow | Out-Null }"

"%VENV%\Scripts\python.exe" "%~dp0server.py" %*
pause
