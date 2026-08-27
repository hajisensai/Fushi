<#
.SYNOPSIS
  Compute a deterministic fingerprint for the galgame helper build inputs.

.DESCRIPTION
  build_distribution.ps1 writes this fingerprint next to its archives and
  install_into_bundle.ps1 recomputes it before publishing plain helper files.
  This closes the otherwise invisible "complete, integrity-valid, but built
  from an older checkout" state that an incremental Flutter build cannot
  distinguish from a fresh helper distribution (BUG-1881).

  Keep the input list limited to files that can affect the shipped injector,
  hook DLL, Luna bridge, Locale Emulator package, or Unity audio runtime. Tests
  and diagnostics intentionally do not invalidate a helper binary.
#>

function Get-FushiFileSha256Hex {
  param([Parameter(Mandatory = $true)][string] $Path)

  $stream = [IO.File]::OpenRead($Path)
  try {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
      return (($hasher.ComputeHash($stream) |
        ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
      $hasher.Dispose()
    }
  }
  finally {
    $stream.Dispose()
  }
}

function Get-FushiHelperSourceFingerprint {
  param([Parameter(Mandatory = $true)][string] $SourceRoot)

  $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/')
  $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
  $relativeFiles = [System.Collections.Generic.List[string]]::new()

  foreach ($relativeRoot in @(
      'hook',
      'include',
      'injector',
      'third_party/minhook/src',
      'third_party/minhook/include'
    )) {
    $directory = Join-Path $root ($relativeRoot -replace '/', '\')
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
      throw "Helper fingerprint input directory is missing: $directory"
    }
    foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse) {
      $full = [IO.Path]::GetFullPath($file.FullName)
      if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Helper fingerprint input escapes source root: $full"
      }
      $relativeFiles.Add($full.Substring($rootPrefix.Length).Replace('\', '/'))
    }
  }

  foreach ($relativeFile in @(
      'CMakeLists.txt',
      'third_party/lunahook/LunaHook32.dll',
      'third_party/lunahook/LunaHook64.dll',
      'third_party/lunahook/LunaHost32.dll',
      'third_party/lunahook/LunaHost64.dll',
      'unity_audio_extract/Fushi.UnityAudioExtract.csproj',
      'unity_audio_extract/Program.cs',
      'unity_audio_extract/fetch_runtime.ps1',
      'tools/build_distribution.ps1',
      'tools/helper_source_fingerprint.ps1'
    )) {
    $path = Join-Path $root ($relativeFile -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Helper fingerprint input file is missing: $path"
    }
    $relativeFiles.Add($relativeFile)
  }

  $manifest = [Text.StringBuilder]::new()
  # Sort-Object follows the host PowerShell's culture/collation rules; Windows
  # PowerShell 5.1 and PowerShell 7 produced different manifests for the same
  # checkout. The stamp must survive whichever shell invokes the shared script.
  $orderedFiles = $relativeFiles.ToArray()
  [Array]::Sort($orderedFiles, [StringComparer]::Ordinal)
  foreach ($relative in $orderedFiles) {
    $path = Join-Path $root ($relative -replace '/', '\')
    [void]$manifest.Append($relative)
    [void]$manifest.Append([char]0)
    [void]$manifest.Append((Get-FushiFileSha256Hex -Path $path))
    [void]$manifest.Append("`n")
  }

  $bytes = [Text.Encoding]::UTF8.GetBytes($manifest.ToString())
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return (($hasher.ComputeHash($bytes) |
      ForEach-Object { $_.ToString('x2') }) -join '')
  }
  finally {
    $hasher.Dispose()
  }
}
