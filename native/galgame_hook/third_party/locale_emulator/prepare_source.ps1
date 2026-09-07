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
& git -C $sourcePath diff HEAD --quiet
if ($LASTEXITCODE -ne 0) { throw 'Tracked Locale Emulator source must be pristine' }
$helpers = @('kernel32_module_list.h', 'version_resource_locale.h', 'version_query_hooks.inc')
foreach ($helper in $helpers) {
  $helperPath = Join-Path $sourcePath "LocaleEmulator/$helper"
  if (Test-Path -LiteralPath $helperPath) {
    throw "Source helper already exists: $helperPath"
  }
}
$patches = @('0001-exclude-loader-list-sentinel.patch', '0002-version-query-locale.patch') |
  ForEach-Object { Join-Path $PSScriptRoot $_ }
& git -C $sourcePath apply --check @patches
if ($LASTEXITCODE -ne 0) { throw 'Locale Emulator source patch check failed' }
& git -C $sourcePath apply @patches
if ($LASTEXITCODE -ne 0) { throw 'Locale Emulator source patch failed' }
foreach ($helper in $helpers) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $helper) `
    -Destination (Join-Path $sourcePath "LocaleEmulator/$helper")
}
Write-Output "Prepared source at $sourcePath; no runtime DLL has been built."
