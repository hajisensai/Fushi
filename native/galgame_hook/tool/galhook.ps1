param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$GalhookArgs
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& python (Join-Path $root 'tools/galhook.py') @GalhookArgs
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}
