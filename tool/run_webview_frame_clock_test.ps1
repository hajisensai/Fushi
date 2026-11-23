<#
.SYNOPSIS
Build and run the Windows WebView frame-clock regression test (BUG-5270).
.DESCRIPTION
Compiles packages/flutter_inappwebview_windows/windows/test/frame_clock_test.cpp
(header-only FrameClock, no WGC / WinRT / gtest) with cl and runs it. The binary
and intermediates stay under .codex-test/webview-frame-clock-test. Uses cl from
PATH, or discovers Visual Studio Build Tools via vswhere/vcvars64.bat.
Exit code = the test's exit code (0 = all checks passed).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  throw 'The WebView frame-clock test is Windows-only.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$pluginDir = Join-Path $repoRoot 'packages/flutter_inappwebview_windows/windows'
$testSource = Join-Path $pluginDir 'test/frame_clock_test.cpp'
$outputDir = Join-Path $repoRoot '.codex-test/webview-frame-clock-test'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$executable = Join-Path $outputDir 'frame_clock_test.exe'

$vcvarsPath = $null
if ($null -eq (Get-Command 'cl.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
  $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
  $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio/Installer/vswhere.exe'
  if (Test-Path -LiteralPath $vswhere) {
    $install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (![string]::IsNullOrWhiteSpace($install)) {
      $candidate = Join-Path $install 'VC/Auxiliary/Build/vcvars64.bat'
      if (Test-Path -LiteralPath $candidate) { $vcvarsPath = $candidate }
    }
  }
  if ($null -eq $vcvarsPath) {
    throw 'No cl.exe on PATH and no Visual Studio C++ tools found via vswhere.'
  }
}

$compileArguments = @('/nologo', '/utf-8', '/std:c++17', '/EHsc', '/W4', '/DNOMINMAX',
  '/DWIN32', '/D_WINDOWS', "/I$pluginDir", $testSource, "/Fe:$executable")
Push-Location -LiteralPath $outputDir
try {
  if ($vcvarsPath) {
    # vcvars64.bat needs vswhere on PATH.
    $env:PATH = (Split-Path -Parent $vswhere) + ';' + $env:PATH
    $quotedArgs = ($compileArguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    cmd /c "`"$vcvarsPath`" >nul && cl $quotedArgs"
  } else {
    & cl.exe @compileArguments
  }
  if ($LASTEXITCODE -ne 0) {
    throw "frame_clock_test compilation failed with exit code $LASTEXITCODE."
  }
  & $executable
  $testExit = $LASTEXITCODE
} finally {
  Pop-Location
}
exit $testExit
