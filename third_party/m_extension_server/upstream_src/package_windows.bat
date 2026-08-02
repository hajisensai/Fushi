@echo off
REM --------------------------------------------------------------------------
REM package_windows.bat - Wrapper to run PowerShell packaging script
REM --------------------------------------------------------------------------

setlocal enabledelayedexpansion

REM Check if PowerShell is available
where powershell >nul 2>&1
if errorlevel 1 (
    echo Error: PowerShell not found
    pause
    exit /b 1
)

REM Set execution policy for this script only and run PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package_windows.ps1" %*

if errorlevel 1 (
    echo.
    echo Build failed!
    pause
    exit /b 1
)

echo.
echo Packaging complete. Press any key to exit.
pause >nul
exit /b 0
