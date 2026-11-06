@echo off
rem Builds out\probe.exe (standalone probe, not part of the app build).
rem WebView2 SDK comes from the NuGet cache, same version as the runner.
setlocal
set "HERE=%~dp0"
set "WV2=%USERPROFILE%\.nuget\packages\microsoft.web.webview2\1.0.2792.45\build\native"
if not exist "%WV2%\include\WebView2.h" (
  echo WebView2 SDK not found: %WV2%
  exit /b 1
)
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VS="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if not defined VS (
  echo No Visual Studio with the C++ x64 tools found.
  exit /b 1
)
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist "%HERE%out" mkdir "%HERE%out"
cl /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /O2 /MT /DUNICODE /D_UNICODE ^
  /I "%WV2%\include" "%HERE%probe.cpp" /Fo"%HERE%out\\" /Fe"%HERE%out\probe.exe" ^
  /link /SUBSYSTEM:WINDOWS /ENTRY:wmainCRTStartup /MANIFEST:EMBED /MANIFESTINPUT:"%HERE%probe.manifest" "%WV2%\x64\WebView2LoaderStatic.lib" d3d11.lib dxgi.lib dcomp.lib dwmapi.lib ^
  windowscodecs.lib ole32.lib user32.lib gdi32.lib advapi32.lib shell32.lib version.lib
