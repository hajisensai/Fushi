# SPDX-License-Identifier: LGPL-3.0-or-later
[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
if (-not $OutputDirectory) {
  $OutputDirectory = Join-Path $repoRoot '.codex-test/locale-module-list'
}
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$vswhere = Join-Path ${env:ProgramFiles(x86)} `
  'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = (& $vswhere -latest -products '*' `
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  -property installationPath | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $visualStudio) {
  throw 'An installed official MSVC x86 toolchain is required'
}
$vcvars = Join-Path $visualStudio 'VC/Auxiliary/Build/vcvars32.bat'
$testSource = Join-Path $repoRoot `
  'native/galgame_hook/tests/locale_emulator_module_list_test.cpp'
$objectFile = Join-Path $outputPath 'locale_emulator_module_list_test.obj'
$executable = Join-Path $outputPath 'locale_emulator_module_list_test.exe'
$logFile = Join-Path $outputPath 'test.log'
# These paths are passed to cmd.exe as quoted arguments. Reject expansion and
# control characters rather than interpreting user-provided output paths.
foreach ($argument in @($vcvars, $testSource, $objectFile, $executable)) {
  if ($argument -match '["%&|<>^!\r\n]') { throw 'Unsupported shell path' }
}
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
$command = '"{0}" >nul && cl /nologo /W4 /WX /EHsc /std:c++17 /O2 /DNDEBUG "{1}" /Fo"{2}" /Fe"{3}" && "{3}"' `
  -f $vcvars, $testSource, $objectFile, $executable
& cmd.exe /d /s /c $command 2>&1 | Tee-Object -FilePath $logFile
if ($LASTEXITCODE -ne 0) {
  throw "Locale Emulator module-list test failed; see $logFile"
}
