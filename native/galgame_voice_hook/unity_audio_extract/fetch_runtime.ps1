param(
  [Parameter(Mandatory = $true)]
  [string]$RuntimeDir
)

$ErrorActionPreference = 'Stop'
$runtimePath = [System.IO.Path]::GetFullPath($RuntimeDir)
New-Item -ItemType Directory -Force -Path $runtimePath | Out-Null

$decoder = Join-Path $runtimePath 'vgmstream-cli.exe'
$classdata = Join-Path $runtimePath 'classdata.tpk'
if ((Test-Path -LiteralPath $decoder) -and (Test-Path -LiteralPath $classdata)) {
  exit 0
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'hibiki-unity-audio-runtime-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
  $vgmZip = Join-Path $tempRoot 'vgmstream-win64.zip'
  $uabeaZip = Join-Path $tempRoot 'uabea-windows.zip'
  Invoke-WebRequest `
    -Uri 'https://github.com/vgmstream/vgmstream/releases/download/r2117/vgmstream-win64.zip' `
    -OutFile $vgmZip
  Invoke-WebRequest `
    -Uri 'https://github.com/nesrak1/UABEA/releases/download/v8/uabea-windows.zip' `
    -OutFile $uabeaZip

  function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
      }
      finally {
        $sha.Dispose()
      }
    }
    finally {
      $stream.Dispose()
    }
  }
  $vgmHash = Get-Sha256 $vgmZip
  $uabeaHash = Get-Sha256 $uabeaZip
  if ($vgmHash -ne '6C4A8A3813864FEFED081BBD337DBC0AD93BF88E0B92F5DB98D7AB258B22DC6C') {
    throw "vgmstream r2117 SHA256 mismatch: $vgmHash"
  }
  if ($uabeaHash -ne '0623AB1DC099A6397C3A7E72782B91405E60B286C6825FB6FA21E553FF2EA580') {
    throw "UABEA v8 SHA256 mismatch: $uabeaHash"
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($vgmZip, $runtimePath)
  $uabeaDir = Join-Path $tempRoot 'uabea'
  [System.IO.Compression.ZipFile]::ExtractToDirectory($uabeaZip, $uabeaDir)
  Copy-Item -LiteralPath (Join-Path $uabeaDir 'classdata.tpk') `
    -Destination $classdata -Force
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
