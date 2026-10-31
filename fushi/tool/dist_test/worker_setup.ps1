<#
.SYNOPSIS
  One-time setup of a dist_test worker on Windows, run BY THE MACHINE'S OWNER
  in the dedicated standard (non-admin) account, e.g. `fushitest`.

.DESCRIPTION
  docs/specs/2026-10-24-distributed-unit-tests.md sections 6-7. Everything
  lands in this account's profile:

    - copies worker_shim.sh to ~\.fushi-worker\shim (read it first: it is the
      whole interface the key gets) and writes ~\.fushi-worker\shim.cmd, which
      starts it with Git Bash;
    - writes ~\.fushi-worker\limits and ~\.fushi-worker\path if missing;
    - bare-clones the public repo to ~\.fushi-worker\seed (unless -NoSeed),
      whose objects the checkouts borrow so pushes carry only new commits;
    - appends the key to ~\.ssh\authorized_keys pinned to the shim:
        restrict,command="<profile>\.fushi-worker\shim.cmd" <key>
      `restrict` turns off port / agent / X11 forwarding and the pty;
      `command=` means this key can run nothing but the shim. The file's ACL
      is reduced to this account and SYSTEM (Windows OpenSSH ignores the file
      otherwise).

  Prerequisites it checks but does not install: OpenSSH Server (sshd running),
  Git for Windows (its bash runs the shim), Flutter (fushi/.fvmrc's version),
  Rust (cargo) with the MSVC build tools.

  Afterwards, from Git Bash:  bash ~/.fushi-worker/shim pause|resume|status

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File worker_setup.ps1 -PublicKey "ssh-ed25519 AAAA... fushi-dist"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PublicKey,
    # Skip the bare clone of the public repo that checkouts borrow objects
    # from (without it the requester's first push carries the full history).
    [switch]$NoSeed
)

$ErrorActionPreference = 'Stop'

if ($env:USERPROFILE -match '\s') {
    # sshd runs the forced command through cmd.exe; keep the shim path free of spaces.
    throw "use an account whose profile path has no spaces (this one: $env:USERPROFILE)"
}
if ($PublicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) [A-Za-z0-9+/=]+( \S+)?$') {
    throw 'pass the bare public key line ("ssh-ed25519 AAAA... comment")'
}

function Find-GitBash {
    [OutputType([string])]
    param()
    $candidates = New-Object System.Collections.Generic.List[string]
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) { $candidates.Add((Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin\bash.exe')) }
    foreach ($base in @($env:ProgramFiles, $env:ProgramW6432, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if ($base) { $candidates.Add((Join-Path $base 'Git\bin\bash.exe')) }
    }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw 'Git for Windows not found (its bin\bash.exe runs the shim); install it first'
}

$bash = Find-GitBash
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$w = Join-Path $env:USERPROFILE '.fushi-worker'
$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Force -Path $w, $sshDir | Out-Null

Copy-Item -LiteralPath (Join-Path $here 'worker_shim.sh') -Destination (Join-Path $w 'shim') -Force
$cmd = "@echo off`r`n`"$bash`" `"%USERPROFILE%\.fushi-worker\shim`"`r`n"
[IO.File]::WriteAllText((Join-Path $w 'shim.cmd'), $cmd, (New-Object Text.ASCIIEncoding))
Write-Host "installed $w\shim (runs with $bash)"

$limits = Join-Path $w 'limits'
if (-not (Test-Path -LiteralPath $limits)) {
    $text = "# dist_test worker limits (KEY=number). Edit freely; the requester cannot.`n" +
        "MAX_SLOTS=1`n# MAX_CONCURRENCY=4`nMIN_FREE_MEM_MB=4096`nMIN_FREE_DISK_GB=20`n" +
        "# Compile checks (Android / desktop builds whose output never leaves this`n" +
        "# machine); 0 turns them off.`n# ALLOW_BUILD=0`n"
    [IO.File]::WriteAllText($limits, $text, (New-Object Text.ASCIIEncoding))
    Write-Host "wrote $limits"
}

# Git Bash directories (/c/...) of flutter and cargo for the shim's PATH.
$pathFile = Join-Path $w 'path'
if (-not (Test-Path -LiteralPath $pathFile)) {
    $dirs = @()
    foreach ($tool in @('flutter', 'cargo')) {
        $found = Get-Command $tool -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $d = Split-Path -Parent $found.Source
            $dirs += '/' + $d.Substring(0, 1).ToLower() + ($d.Substring(2) -replace '\\', '/')
        }
        else {
            Write-Warning "$tool is not on PATH; add its bin directory (as /c/...) to $pathFile"
        }
    }
    [IO.File]::WriteAllText($pathFile, (($dirs | Select-Object -Unique) -join "`n") + "`n", (New-Object Text.ASCIIEncoding))
    Write-Host "wrote $pathFile"
}

$seed = Join-Path $w 'seed'
if (-not $NoSeed -and -not (Test-Path -LiteralPath $seed)) {
    Write-Host 'cloning the seed repository (bare, a few GB; -NoSeed skips)'
    & git clone --bare --quiet 'https://github.com/hajisensai/fushi' $seed
    if ($LASTEXITCODE -ne 0) { throw 'seed clone failed' }
}

$auth = Join-Path $sshDir 'authorized_keys'
if (-not (Test-Path -LiteralPath $auth)) { New-Item -ItemType File -Path $auth | Out-Null }
$existing = [IO.File]::ReadAllText($auth)
if ($existing.Contains($PublicKey)) {
    Write-Host 'key already in authorized_keys (left as it is; check it carries the restrict,command= prefix)'
}
else {
    $line = "restrict,command=`"$w\shim.cmd`" $PublicKey`n"
    [IO.File]::AppendAllText($auth, $line, (New-Object Text.ASCIIEncoding))
    Write-Host 'added the key, pinned to the shim'
}
& icacls $auth /inheritance:r /grant "${env:USERNAME}:F" /grant 'SYSTEM:F' | Out-Null

$sshd = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $sshd -or $sshd.Status -ne 'Running') {
    Write-Warning 'OpenSSH Server (sshd) is not running; an administrator has to install / start it'
}

Write-Host ''
Write-Host "== self check (what the requester's 'hello' will see)"
$env:SSH_ORIGINAL_COMMAND = 'hello'
& $bash (Join-Path $w 'shim')
Remove-Item Env:\SSH_ORIGINAL_COMMAND
