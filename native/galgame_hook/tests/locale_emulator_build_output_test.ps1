# SPDX-License-Identifier: LGPL-3.0-or-later
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# Load the production function without executing compiler/tool validation or a
# build. This executes its actual AST, not a test copy of its implementation.
$script = Join-Path $PSScriptRoot '../third_party/locale_emulator/build_runtime.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  $script, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Production build script failed to parse' }
$definitions = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Resolve-NewLocaleRuntimeOutputDirectory'
}, $true))
if ($definitions.Count -ne 1) { throw 'Expected one production output resolver' }
. ([scriptblock]::Create($definitions[0].Extent.Text))
if ($ast.Extent.Text -notmatch '\$output = Resolve-NewLocaleRuntimeOutputDirectory \$OutputDirectory') {
  throw 'Build output must consume the production resolver result'
}
function Assert-Equal([string]$Actual, [string]$Expected, [string]$Detail) {
  if ($Actual -cne $Expected) { throw "$Detail : expected $Expected, got $Actual" }
}
function Assert-Rejected([string]$Path, [string]$Detail) {
  $rejected = $false
  try { $null = Resolve-NewLocaleRuntimeOutputDirectory $Path }
  catch { $rejected = $true }
  if (!$rejected) { throw "$Detail : path was accepted" }
}

$originalDotNetDirectory = [Environment]::CurrentDirectory
$temporaryBase = [IO.Path]::GetTempPath()
$testRoot = Join-Path $temporaryBase ('le-output-test-' + [Guid]::NewGuid().ToString('N'))
$created = [Collections.Generic.List[string]]::new()
function New-TestDirectory([string]$Path) {
  $null = [IO.Directory]::CreateDirectory($Path)
  $created.Add($Path)
}
New-TestDirectory $testRoot
$dotNetDirectory = Join-Path $testRoot 'dotnet'
$psDirectory = Join-Path $testRoot 'powershell'
New-TestDirectory $dotNetDirectory
New-TestDirectory $psDirectory
Push-Location $psDirectory
try {
  [Environment]::CurrentDirectory = $dotNetDirectory
  Assert-Equal (Resolve-NewLocaleRuntimeOutputDirectory 'new-output') `
    (Join-Path $psDirectory 'new-output') 'PowerShell location owns relative paths'

  New-TestDirectory (Join-Path $psDirectory 'existing')
  Assert-Rejected 'existing' 'Existing output under PowerShell location'

  New-TestDirectory (Join-Path $dotNetDirectory 'elsewhere')
  Assert-Equal (Resolve-NewLocaleRuntimeOutputDirectory 'elsewhere') `
    (Join-Path $psDirectory 'elsewhere') 'Do not select an existing .NET cwd output'

  New-TestDirectory (Join-Path $psDirectory 'item0 (new)')
  Assert-Equal (Resolve-NewLocaleRuntimeOutputDirectory 'item[0] (new)') `
    (Join-Path $psDirectory 'item[0] (new)') 'Brackets and parentheses stay literal'
  New-TestDirectory (Join-Path $psDirectory 'item[0] (existing)')
  Assert-Rejected 'item[0] (existing)' 'Existing literal bracket path'

  $absolute = Join-Path $psDirectory 'absolute (new)'
  Assert-Equal (Resolve-NewLocaleRuntimeOutputDirectory $absolute) $absolute 'Absolute output'
  Assert-Rejected $psDirectory 'Existing absolute output'
  Assert-Rejected 'Env:LE_OUTPUT_TEST_UNUSED' 'Only filesystem outputs are valid'
  Write-Output '8 production output-path behavior checks passed'
} finally {
  [Environment]::CurrentDirectory = $originalDotNetDirectory
  Pop-Location
  # All test directories are empty: no recursive delete and no computed path
  # can escape the unique, explicitly named temporary test root.
  for ($index = $created.Count - 1; $index -ge 0; --$index) {
    $directory = [IO.Path]::GetFullPath($created[$index])
    if ($directory -ne $testRoot -and !$directory.StartsWith($testRoot + [IO.Path]::DirectorySeparatorChar)) {
      throw 'Refusing cleanup outside test root'
    }
    Remove-Item -LiteralPath $directory
  }
}
