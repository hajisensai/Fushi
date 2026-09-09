$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$installation) { throw 'MSVC x64 tools are required for the native mutex test.' }
$vcvars = Join-Path $installation 'VC/Auxiliary/Build/vcvars64.bat'
$outputDir = Join-Path ([IO.Path]::GetTempPath()) ('fushi-mutex-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $outputDir | Out-Null
$source = Join-Path $PSScriptRoot 'single_instance_mutex_test.cpp'
$command = @"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX "$source" /Fo"$outputDir/test.obj" /Fe"$outputDir/test.exe"
if errorlevel 1 exit /b 1
"$outputDir/test.exe"
"@
$script = Join-Path $outputDir 'build.cmd'
Set-Content -LiteralPath $script -Value $command -Encoding ascii
& cmd /c $script
if ($LASTEXITCODE -ne 0) { throw "Native mutex test failed; artifacts: $outputDir" }
Write-Host "Native mutex test artifacts: $outputDir"
