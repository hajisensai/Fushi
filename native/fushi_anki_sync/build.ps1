# Build fushi-anki-sync (Windows). See README.md.
#
# 1. Shallow-clone official Anki at the pinned tag into .anki-src (once), with the two
#    translation submodules rslib's build needs.
# 2. Verify the checkout is the pinned commit (a moved tag must not slip through).
# 3. Apply patches/*.patch idempotently (honest "fushi" sync client identity).
# 4. cargo build --release. Requires `protoc` (set $env:PROTOC or put it on PATH).
[CmdletBinding()]
param([switch]$DebugBuild)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$AnkiTag = '26.09.3'
$AnkiCommit = '29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba'
$Src = Join-Path $Here '.anki-src'

# PowerShell 5.1 turns a native command's stderr into a terminating error under
# ErrorActionPreference=Stop once output is redirected; git and cargo both write
# progress to stderr. Judge native commands by exit code only.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host
    } finally {
        $ErrorActionPreference = $old
    }
    return $LASTEXITCODE
}

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    $code = Invoke-Native $Exe $Arguments
    if ($code -ne 0) { throw "$Exe $($Arguments -join ' ') failed ($code)" }
}

if (-not (Test-Path (Join-Path $Src '.git'))) {
    Invoke-Checked git @('clone', '--depth', '1', '--branch', $AnkiTag, 'https://github.com/ankitects/anki', $Src)
    Invoke-Checked git @('-C', $Src, 'submodule', 'update', '--init', '--depth', '1', 'ftl/core-repo', 'ftl/qt-repo')
}

$head = (& git -C $Src rev-parse HEAD).Trim()
if ($head -ne $AnkiCommit) {
    throw ".anki-src is at $head, expected $AnkiCommit (tag $AnkiTag). Delete .anki-src and rebuild."
}

foreach ($patch in Get-ChildItem (Join-Path $Here 'patches') -Filter *.patch | Sort-Object Name) {
    $code = Invoke-Native git @('-C', $Src, 'apply', '--reverse', '--check', $patch.FullName)
    if ($code -eq 0) { continue }  # already applied
    Invoke-Checked git @('-C', $Src, 'apply', $patch.FullName)
}

if (-not $env:PROTOC -and -not $env:PROTOC_BINARY -and -not (Get-Command protoc -ErrorAction SilentlyContinue)) {
    throw 'protoc not found: set $env:PROTOC to protoc.exe (Anki pins v31.1) or put it on PATH.'
}
# Anki's proto build appends ".exe" to $env:PROTOC on Windows but uses PROTOC_BINARY
# verbatim (rslib/proto/rust.rs set_protoc_path) — pass the path through untouched.
if ($env:PROTOC -and -not $env:PROTOC_BINARY) { $env:PROTOC_BINARY = $env:PROTOC }

$version = (Select-String -Path (Join-Path $Here 'Cargo.toml') -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value
$env:FUSHI_ANKI_SYNC_VERSION = $version

Push-Location $Here
try {
    $cargoArgs = if ($DebugBuild) { @('build') } else { @('build', '--release') }
    Invoke-Checked cargo $cargoArgs
} finally {
    Pop-Location
}
