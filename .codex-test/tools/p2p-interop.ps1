<#
.SYNOPSIS
  Verify Hibiki P2P sync interop between the Windows host (sync server) and a
  connected Android emulator (P2P client), end-to-end over 10.0.2.2.

.DESCRIPTION
  Network/protocol layer verification (the layer the sync settings UI configures) —
  no coordinate clicks, fully scripted per the repo test conventions.

  1) Starts a REAL HibikiSyncServer on the host (hibiki/tool/p2p_host_harness.dart),
     bound to 0.0.0.0:<Port>, seeded with one book.
  2) From the emulator, hits http://10.0.2.2:<Port> via `nc`:
       - unauthenticated GET       -> expect HTTP 401 (reached the real Hibiki server)
       - authenticated PROPFIND    -> expect HTTP 207 + the seeded "InteropBook"
         (full token-auth + WebDAV listing across the emulator<->host boundary)
  3) Tears the server down. Exit 0 on PASS, 1 on FAIL.

  Pairs with test/sync/hibiki_p2p_roundtrip_test.dart (host-side client<->server
  round-trip). Together they cover the protocol + the emulator<->host network hop.

  Real device (not emulator): point the client at the host LAN IP instead of
  10.0.2.2 (10.0.2.2 is emulator-only); the server already binds 0.0.0.0.

.EXAMPLE
  .\p2p-interop.ps1
  .\p2p-interop.ps1 -Port 38900
#>
[CmdletBinding()]
param(
    [int]$Port = 38765,
    # Documented constants (CLAUDE.md): never rely on PATH-resolved adb.
    [string]$Adb = 'D:/android_sdk/platform-tools/adb.exe',
    [string]$Dart = 'D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat'
)

$ErrorActionPreference = 'Stop'
$proc = $null
$repoRoot = (& git rev-parse --show-toplevel).Trim()
$hibikiDir = Join-Path $repoRoot 'hibiki'

function Stop-Harness {
    if ($script:proc -and -not $script:proc.HasExited) {
        try { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}
function Fail([string]$msg) {
    Write-Host "[FAIL] $msg" -ForegroundColor Red
    Stop-Harness
    exit 1
}

# ── 0) emulator present? ──────────────────────────────────────────────
$devs = (& $Adb devices) -join "`n"
$m = [regex]::Match($devs, '(emulator-\d+)\s+device')
if (-not $m.Success) { Fail "no emulator in '$Adb devices'. Start an Android emulator first." }
$emu = $m.Groups[1].Value
Write-Host "[*] emulator: $emu"

# ── 1) start the host sync server (background) ────────────────────────
$outFile = Join-Path $env:TEMP 'hibiki_p2p_harness.out'
$errFile = Join-Path $env:TEMP 'hibiki_p2p_harness.err'
Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $Dart `
    -ArgumentList @('run', 'tool/p2p_host_harness.dart', "$Port") `
    -WorkingDirectory $hibikiDir `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
    -PassThru -WindowStyle Hidden
Write-Host "[*] host sync server starting (pid $($proc.Id)) on 0.0.0.0:$Port (dart run may compile first)..."

$token = $null
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $outFile) {
        $hit = Select-String -Path $outFile -Pattern 'HIBIKI_P2P_READY port=(\d+) token=(\S+)' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $g = $hit.Matches[0].Groups; $Port = [int]$g[1].Value; $token = $g[2].Value; break }
    }
    if ($proc.HasExited) {
        $log = (Get-Content $outFile, $errFile -Raw -ErrorAction SilentlyContinue) -join "`n"
        Fail "harness exited early (port $Port in use?). Output:`n$log"
    }
    Start-Sleep -Milliseconds 500
}
if (-not $token) { Fail "server did not report ready within 120s" }
Write-Host "[+] server ready on port $Port"

# ── 2) probe from the emulator over 10.0.2.2 ──────────────────────────
# Requests are pushed as files (real CRLF) to dodge cross-shell quoting issues.
$auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("hibiki:$token"))
$reqUnauth = "GET /ttu-reader-data/ HTTP/1.0`r`nHost: h`r`n`r`n"
$reqAuth = "PROPFIND /ttu-reader-data/ HTTP/1.0`r`nHost: h`r`nAuthorization: Basic $auth`r`nDepth: 1`r`n`r`n"
$tmpU = Join-Path $env:TEMP 'hibiki_p2p_unauth.txt'
$tmpA = Join-Path $env:TEMP 'hibiki_p2p_auth.txt'
[IO.File]::WriteAllBytes($tmpU, [Text.Encoding]::ASCII.GetBytes($reqUnauth))
[IO.File]::WriteAllBytes($tmpA, [Text.Encoding]::ASCII.GetBytes($reqAuth))
& $Adb -s $emu push $tmpU /data/local/tmp/hibiki_p2p_unauth.txt | Out-Null
& $Adb -s $emu push $tmpA /data/local/tmp/hibiki_p2p_auth.txt | Out-Null

Write-Host "[*] $emu -> http://10.0.2.2:$Port  (unauthenticated, expect 401)"
$r1 = (& $Adb -s $emu shell "nc -w 5 10.0.2.2 $Port < /data/local/tmp/hibiki_p2p_unauth.txt" 2>&1) -join "`n"
Write-Host "[*] $emu -> http://10.0.2.2:$Port  (authenticated PROPFIND, expect 207 + InteropBook)"
$r2 = (& $Adb -s $emu shell "nc -w 5 10.0.2.2 $Port < /data/local/tmp/hibiki_p2p_auth.txt" 2>&1) -join "`n"

# ── 3) assertions + cleanup ───────────────────────────────────────────
$ok1 = $r1 -match '\b401\b'
$ok2 = ($r2 -match '\b207\b') -and ($r2 -match 'InteropBook')
$status1 = ([regex]::Match($r1, 'HTTP/\S+\s+\d+[^\r\n]*')).Value
$status2 = ([regex]::Match($r2, 'HTTP/\S+\s+\d+[^\r\n]*')).Value
Write-Host "  unauth : $(if ($ok1) { 'OK' } else { 'FAIL' })  ($status1)"
Write-Host "  authed : $(if ($ok2) { 'OK (207 + InteropBook)' } else { 'FAIL' })  ($status2)"

& $Adb -s $emu shell "rm -f /data/local/tmp/hibiki_p2p_unauth.txt /data/local/tmp/hibiki_p2p_auth.txt" 2>&1 | Out-Null
Remove-Item $tmpU, $tmpA -Force -ErrorAction SilentlyContinue
Stop-Harness

if ($ok1 -and $ok2) {
    Write-Host "`n[PASS] emulator <-> Windows-host Hibiki P2P interop verified." -ForegroundColor Green
    exit 0
}
Write-Host "`n[FAIL] interop check failed (see statuses above)." -ForegroundColor Red
Write-Host "--- unauth response ---`n$r1`n--- authed response ---`n$r2"
exit 1
