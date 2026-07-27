param(
  [string]$SourceDir = "",
  [switch]$Update
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root 'third_party/lunahook'
$manifestPath = Join-Path $vendor 'VERSION.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

if ($Update -and [string]::IsNullOrWhiteSpace($SourceDir)) {
  throw '-Update requires -SourceDir pointing at an unpacked official release.'
}

foreach ($property in $manifest.files.PSObject.Properties) {
  $name = $property.Name
  $target = Join-Path $vendor $name
  if ($Update) {
    $source = Join-Path $SourceDir $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      throw "Missing upstream file: $source"
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
  }
  if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Missing vendored Luna file: $target"
  }
  $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
  $expected = [string]$property.Value
  if ($actual -ne $expected.ToLowerInvariant()) {
    throw "$name differs from VERSION.json: expected=$expected actual=$actual"
  }
  Write-Host "OK $name $actual"
}

Write-Host "LunaTranslator $($manifest.version), bridge ABI $($manifest.bridgeAbi): synchronized"
