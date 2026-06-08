@echo off
setlocal enabledelayedexpansion
title Hibiki - Build and Install ARM (192.168.1.50)
chcp 65001 >/dev/null

rem ============================================================
rem  Hibiki: build arm64 release APK and install to 192.168.1.50
rem    1) adb connect 192.168.1.50:5555  (only this device)
rem    2) flutter build apk --target-platform android-arm64 --release
rem    3) adb -s 192.168.1.50:5555 install -r
rem  Only ever touches 192.168.1.50. If it is not online -> stop.
rem
rem  Usage:
rem    手机编译安装ARM.bat              -> 192.168.1.50:5555, incremental
rem    手机编译安装ARM.bat :37000       -> custom port on 192.168.1.50
rem    手机编译安装ARM.bat clean        -> flutter clean first
rem    手机编译安装ARM.bat :37000 clean
rem ============================================================

set "REPO=D:\APP\vs_claude_code\hibiki"
set "APP=%REPO%\hibiki"
set "FLUTTER=D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat"
set "APK=%APP%\build\app\outputs\flutter-apk\app-release.apk"
set "IP=192.168.1.50"
set "PORT=5555"

rem --- parse args: optional :port and/or "clean" ---
set "DOCLEAN="
for %%a in (%*) do (
  if /i "%%~a"=="clean" (
    set "DOCLEAN=1"
  ) else (
    set "P=%%~a"
    set "PORT=!P::=!"
  )
)
set "TARGET=%IP%:%PORT%"

cd /d "%APP%"

echo ============================================================
echo  Target device : %TARGET%   ^(only this device^)
echo  App dir       : %APP%
echo ============================================================

adb start-server
echo [ADB] connecting to %TARGET% ...
adb connect %TARGET%

rem --- verify EXACTLY this device is online; never use another ---
set "ONLINE="
for /f "tokens=1,2" %%d in ('adb devices') do (
  if "%%d"=="%TARGET%" if "%%e"=="device" set "ONLINE=1"
)
if not defined ONLINE (
  echo.
  echo [ERROR] %TARGET% is not online. Aborting ^(will NOT install to any other device^).
  echo   - Turn ON "Wireless debugging" on 192.168.1.50
  echo   - Android 11+ uses a random port: connect USB once then run  adb tcpip 5555
  echo     ^(or pass the wireless-debug port:  手机编译安装ARM.bat :37000^)
  echo.
  adb devices
  goto :end
)
echo [ADB] %TARGET% online.

if defined DOCLEAN (
  echo [CLEAN] flutter clean ...
  call "%FLUTTER%" clean
)

echo [DEPS] flutter pub get ...
call "%FLUTTER%" pub get
if errorlevel 1 ( echo [ERROR] pub get failed. & goto :end )

echo [BUILD] flutter build apk --target-platform android-arm64 --release ...
call "%FLUTTER%" build apk --target-platform android-arm64 --release
if errorlevel 1 ( echo [ERROR] build failed. & goto :end )
if not exist "%APK%" ( echo [ERROR] APK not found: %APK% & goto :end )

echo [INSTALL] adb -s %TARGET% install -r ...
adb -s %TARGET% install -r "%APK%"
if errorlevel 1 (
  echo [WARN] install -r failed, retrying with -r -d ^(downgrade allowed^) ...
  adb -s %TARGET% install -r -d "%APK%"
)

echo.
echo ============================================================
echo  Done. Installed to %TARGET%
echo  APK: %APK%
echo ============================================================

:end
endlocal
pause
