# SPDX-License-Identifier: LGPL-3.0-or-later
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
$expectedCommit = 'ae7160dc5deb97947396abcd784f9b98b6ee38b3'
$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
$actualCommit = (& git -C $sourcePath rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $expectedCommit) {
  throw "Expected Locale-Emulator-Core commit $expectedCommit; got $actualCommit"
}

# Apply only to pristine source. Never reset a caller's checkout or overwrite
# another patch, and never execute the modified toolchain bundled upstream.
& git -C $sourcePath diff HEAD --quiet -- LocaleEmulator/ml.h
if ($LASTEXITCODE -ne 0) { throw 'LocaleEmulator/ml.h must be pristine' }
$helperPath = Join-Path $sourcePath 'LocaleEmulator/kernel32_module_list.h'
if (Test-Path -LiteralPath $helperPath) {
  throw "Source helper already exists: $helperPath"
}
$patchPath = Join-Path $PSScriptRoot '0001-exclude-loader-list-sentinel.patch'
& git -C $sourcePath apply --check $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Locale Emulator source patch check failed' }
& git -C $sourcePath apply $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Locale Emulator source patch failed' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'kernel32_module_list.h') `
  -Destination $helperPath
Write-Output "Prepared source at $sourcePath; no runtime DLL has been built."
