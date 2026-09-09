# SPDX-License-Identifier: LGPL-3.0-or-later
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$SourceRoot,
  [Parameter(Mandatory = $true)][string]$VcBin,
  [Parameter(Mandatory = $true)][string]$LldLink,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [string]$SevenZip = '7z.exe',
  [string]$Python = 'python.exe'
)
$ErrorActionPreference = 'Stop'
$commit = 'ae7160dc5deb97947396abcd784f9b98b6ee38b3'
function Assert-Hash([string]$Path, [string]$Expected) {
  if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
    throw "Unexpected build input: $Path"
  }
}
function Run-Native([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit $LASTEXITCODE" }
}
function Resolve-NewLocaleRuntimeOutputDirectory([string]$Path) {
  # PowerShell's Set-Location need not change the process/.NET current directory.
  # Resolve once in the caller's provider location before checking or writing.
  $provider = $null
  $drive = $null
  $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $Path, [ref]$provider, [ref]$drive)
  if ($provider.Name -ne 'FileSystem') {
    throw 'Locale runtime output must be a filesystem directory'
  }
  if (Test-Path -LiteralPath $resolved) {
    throw 'Choose a new output directory; existing build files are never replaced'
  }
  return $resolved
}
$sourceRepository = (Resolve-Path -LiteralPath $SourceRoot).Path
$vc = (Resolve-Path -LiteralPath $VcBin).Path
$lld = (Resolve-Path -LiteralPath $LldLink).Path
Assert-Hash "$vc/cl.exe" '73D9B4DACC7CE25A28A4AD5A1BD7FFBEF935FF08ACF21BD94D4105B02C7B0C2E'
Assert-Hash "$vc/c1xx.dll" 'C316DD637DDF39FD3CE39E353A20586301D62E57079818CEAFB0CF9A07E32BE6'
Assert-Hash "$vc/c2.dll" 'B10D627973B35E8E4547ED5F8468DE8E6902285D6F64DA6291F386088C35B247'
Assert-Hash "$vc/link.exe" '7B00E6D4D3865D61E0B10327281CE9C8133FE6FD762191B48D86CE9CE200040B'
Assert-Hash $lld '7B8E47E423175ED6CACCC0E96603FBAD97A6BEC6361387BBED145DC7ACC08E49'
$gitDirectory = (& git -C $sourceRepository rev-parse --absolute-git-dir | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'SourceRoot must be a Git checkout' }
Run-Native git @('-C', $sourceRepository, 'cat-file', '-e', "$commit^{commit}")
$output = Resolve-NewLocaleRuntimeOutputDirectory $OutputDirectory
New-Item -ItemType Directory -Path $output | Out-Null
$source = Join-Path $output 'source'
$objects = Join-Path $output 'objects'
$runtime = Join-Path $output 'runtime'
New-Item -ItemType Directory -Path $source, $objects, $runtime | Out-Null
# Export immutable source, ignoring local modifications. Exclude _Compilers.
$archive = Join-Path $output 'upstream-source.tar'
Run-Native git @('-C', $sourceRepository, 'archive', '--format=tar', "--output=$archive",
  $commit, 'LocaleEmulator', '_Headers', '_Libs/_Libs.7z', '_WDK/_WDK.7z')
Run-Native tar @('-xf', $archive, '-C', $source)
Assert-Hash "$source/_WDK/_WDK.7z" '14DC13C35A884653288C1F6420442A6963C42F6CC0F759D074F486DA48C7FA40'
Assert-Hash "$source/_Libs/_Libs.7z" 'F59C7AADF5DE64F0DFECDDA41DBD6E7435F268A6579DDE7449A4791CFD07F2E0'
foreach ($patch in @('0001-exclude-loader-list-sentinel.patch', '0002-version-query-locale.patch')) {
  $path = Join-Path $PSScriptRoot $patch
  Run-Native git @("--git-dir=$gitDirectory", "--work-tree=$source", '-C', $source, 'apply', '--check', $path)
  Run-Native git @("--git-dir=$gitDirectory", "--work-tree=$source", '-C', $source, 'apply', $path)
}
foreach ($helper in @('kernel32_module_list.h', 'version_resource_locale.h', 'version_query_hooks.inc')) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $helper) -Destination "$source/LocaleEmulator/$helper"
}
Run-Native $SevenZip @('x', "$source/_WDK/_WDK.7z", "-o$source/_WDK", '-y')
Run-Native $SevenZip @('x', "$source/_Libs/_Libs.7z", "-o$source/_Libs", '-y')
$units = @('HandleTable', 'HookPort', 'Hooks/Gdi32Hook', 'Hooks/Kernel32Hook',
  'Hooks/NtdllHook', 'Hooks/User32Hook', 'LocaleEmulator', 'ml', 'stdafx', 'Utility/Utility')
$savedEnvironment = @{}
foreach ($name in @('PATH', 'INCLUDE', 'LIB', 'CL', '_CL_', 'LINK')) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location $output
try {
  foreach ($name in @('CL', '_CL_', 'LINK')) {
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
  }
  $env:PATH = "$vc;$env:PATH"
  $env:INCLUDE = (@('_WDK/WIN8/Include/shared', '_WDK/WIN8/Include/um',
    '_WDK/WIN8/Include/km', '_WDK/WIN7/inc/api', '_WDK/WIN7/inc/crt',
    '_WDK/WIN7/inc/api/crt/stl60', '_Headers', 'LocaleEmulator') |
    ForEach-Object { Join-Path $source $_ }) -join ';'
  $env:LIB = (@('_Libs', '_WDK/WIN7/lib/win7/i386', '_WDK/WIN7/lib/Crt/i386') |
    ForEach-Object { Join-Path $source $_ }) -join ';'
  $compile = @('/nologo', '/c', '/W4', '/O2', '/Ob1', '/GF', '/Gy', '/Gr', '/GL',
    '/GS-', '/MD', '/arch:SSE', '/DWIN32', '/DNDEBUG', '/DUSE_NT_VER=1', "/Fo$objects\")
  $compile += @($units | ForEach-Object { "$source/LocaleEmulator/$_.cpp" })
  Run-Native "$vc/cl.exe" $compile
  $objectFiles = @($units | ForEach-Object { Join-Path $objects ((Split-Path $_ -Leaf) + '.obj') })
  $libraries = @('MyLib.lib', 'undoc_ntdll.lib', 'undoc_k32.lib', 'ntdll.lib',
    'kernel32.lib', 'user32.lib', 'gdi32.lib', 'dbghelp.lib', 'msvcrt.lib', 'oldnames.lib')
  $common = @('/dll', '/opt:ref', '/safeseh:no', '/dynamicbase:no', '/nxcompat', '/debug')
  $delay = @('/delayload:KERNEL32.dll', '/delayload:USER32.dll',
    '/delayload:GDI32.dll', '/delayload:DBGHELP.dll')
  # The first DLL exists only to materialize old /GL code as ordinary COFF.
  # Official MSVC ignores Kernel32 delay loading; never ship this intermediate.
  $iobj = Join-Path $objects 'native.iobj'
  Run-Native "$vc/link.exe" (@('/nologo', '/ltcg:incremental', "/ltcgout:$iobj",
    "/out:$objects/codegen-only.dll") + $common + $objectFiles + $libraries + $delay)
  $dll = Join-Path $runtime 'LocaleEmulator.dll'
  # IOBJ omits source directives: preserve each explicit upstream contract.
  Run-Native $lld (@('/entry:DllMain', '/export:GetFileAttributesA=_FuckStupid2DJGame@4',
    '/section:.Asuna,ERW', '/merge:.rdata=.text', '/merge:.data=.text', '/merge:.text=.Asuna',
    "/out:$dll", $iobj) + $common + $libraries + $delay)
  Run-Native $Python @((Join-Path $PSScriptRoot 'verify_runtime_pe.py'), $dll)
  Get-FileHash -LiteralPath $dll -Algorithm SHA256
  Write-Output 'Local experimental runtime built. No bundle was changed.'
} finally {
  Pop-Location
  foreach ($name in $savedEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
  }
}
