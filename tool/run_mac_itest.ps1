# Windows-orchestrated cross-host integration test on the remote Mac.
# Pushes committed history to the Mac, fast-forwards its checkout, then runs a
# Hibiki integration test against the REAL macOS app under HIBIKI_TEST_HIDDEN
# (the runner parks itself off-screen + .accessory + non-key, so it never
# appears or steals foreground — see hibiki/macos/Runner/MainFlutterWindow.swift).
# Phase 3 of the test-flow refactor (Windows is the conductor; the Mac runs).
#
# The test TARGET must be committed first (the Mac builds from committed
# history, not the working tree). Lives next to sync_to_mac.ps1 at the repo root.
#
# Usage (from the repo root D:\APP\vs_claude_code\hibiki):
#   .\tool\run_mac_itest.ps1
#   .\tool\run_mac_itest.ps1 integration_test/desktop_reader_css_dom_test.dart
param(
  [string]$Target = "integration_test/desktop_settings_smoke_test.dart"
)

$mac = "shfaifsj@192.168.1.34"

Write-Host "[mac-itest] syncing committed history to Mac..." -ForegroundColor Cyan
& "$PSScriptRoot\sync_to_mac.ps1" -AllowDirty

# Build the remote bash script with explicit LF joins, then ship it base64-
# encoded. base64 dodges two Windows-side traps that silently broke earlier
# attempts: (1) PowerShell re-quoting a command full of ;/&&/$ as a native-exe
# argument, and (2) PowerShell piping to stdin with CRLF line endings (the \r
# corrupts each bash command). The decoded script sets the pinned toolchain
# env, fast-forwards the checkout, and runs the test hidden on -d macos.
$lines = @(
  'export LANG=en_US.UTF-8',
  'export PATH=$HOME/flutter/bin:$HOME/.gem/ruby/2.6.0/bin:$PATH',
  'cd ~/dev/hibiki && git fetch origin && git merge --ff-only origin/develop && cd hibiki',
  "HIBIKI_TEST_HIDDEN=1 flutter test $Target -d macos --no-pub"
)
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))

Write-Host "[mac-itest] running $Target on macOS (hidden runner)..." -ForegroundColor Cyan
ssh $mac "echo $b64 | base64 --decode | bash"
exit $LASTEXITCODE
