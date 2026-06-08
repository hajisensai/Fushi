@echo off
setlocal enabledelayedexpansion
title Hibiki Launcher

rem ============================================================
rem  Hibiki smart launcher
rem  Compare git HEAD with last-built commit:
rem    - updated / never built -> pub get + release build, then run
rem    - already latest         -> just run the existing exe
rem  Force clean rebuild: pass argument "clean"
rem ============================================================

set "REPO=D:\APP\vs_claude_code\hibiki"
set "APP=%REPO%\hibiki"
set "FLUTTER=D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat"
set "EXE=%APP%\build\windows\x64\runner\Release\hibiki.exe"
set "STAMP=%APP%\build\.last_built_commit"

cd /d "%APP%"

rem --- read current git HEAD ---
set "HEAD="
for /f "delims=" %%i in ('git -C "%REPO%" rev-parse HEAD 2^>nul') do set "HEAD=%%i"
if not defined HEAD (
  echo [WARN] cannot read git HEAD, launching existing build
  goto :launch
)

rem --- force clean rebuild ---
if /i "%~1"=="clean" (
  echo [CLEAN] forcing clean rebuild...
  call "%FLUTTER%" clean
  goto :build
)

rem --- read last-built commit ---
set "BUILT="
if exist "%STAMP%" set /p BUILT=<"%STAMP%"

if not exist "%EXE%" (
  echo [BUILD] no existing build, compiling for the first time...
  goto :build
)
if not "!BUILT!"=="!HEAD!" (
  echo [BUILD] code updated:
  echo         old: !BUILT!
  echo         new: !HEAD!
  echo         compiling, please wait ^(a few minutes on big changes^)...
  goto :build
)

echo [SKIP] already latest ^(!HEAD:~0,12!^), launching directly
goto :launch

:build
echo [1/2] flutter pub get ...
call "%FLUTTER%" pub get
if errorlevel 1 (
  echo.
  echo [ERROR] pub get failed, not launched. Press any key to exit.
  pause >nul
  exit /b 1
)
echo [2/2] flutter build windows --release ...
call "%FLUTTER%" build windows --release
if errorlevel 1 (
  echo.
  echo [ERROR] build failed, not launched. Press any key to exit.
  pause >nul
  exit /b 1
)
rem --- record this commit ---
>"%STAMP%" echo !HEAD!
echo [OK] build succeeded

:launch
if not exist "%EXE%" (
  echo [ERROR] executable not found: %EXE%
  echo         build once first. Press any key to exit.
  pause >nul
  exit /b 1
)
start "" "%EXE%"
endlocal
