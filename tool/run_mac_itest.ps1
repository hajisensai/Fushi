# Windows-orchestrated cross-host integration test on the remote Mac.
# Pushes committed history to the Mac, fast-forwards its checkout, then runs a
# Hibiki integration test against the REAL macOS app under FUSHI_TEST_HIDDEN
# (the runner parks itself off-screen + .accessory + non-key, so it never
# appears or steals foreground — see fushi/macos/Runner/MainFlutterWindow.swift).
# Phase 3 of the test-flow refactor (Windows is the conductor; the Mac runs).
#
# The test TARGET must be committed first (the Mac builds from committed
# history, not the working tree). Lives next to sync_to_mac.ps1 at the repo root.
#
# Usage (from the repo root D:\APP\vs_claude_code\hibiki):
#   .\tool\run_mac_itest.ps1
#   .\tool\run_mac_itest.ps1 integration_test/desktop_reader_css_dom_test.dart
#   .\tool\run_mac_itest.ps1 integration_test/<t>_test.dart -Ios [-IosDevice <udid>]
#
# `-Ios`: run the SAME test on an iOS simulator hosted by that Mac instead of
# the macOS app (WebKit + the real 34pt safe area). The simulator is booted
# first if it is shut down (`xcrun simctl boot` is a no-op when already
# booted). `-IosDevice` is the simulator udid; when omitted the first
# available iPhone simulator is picked on the Mac. The iOS build needs the
# Rust aarch64-apple-ios-sim target and `~/.cargo/bin` on PATH. There is no
# isolated data root to pass: a simulator container is a clean library
# already. To look at the real screen use `xcrun simctl io <udid> screenshot`
# (captureFlutterFrame cannot grab pixels on iOS; the WebView screenshot can).
param(
  [string]$Target = "integration_test/desktop_settings_smoke_test.dart",
  [switch]$Ios,
  [string]$IosDevice = ""
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
  'export PATH=$HOME/flutter/bin:$HOME/.gem/ruby/2.6.0/bin:$HOME/.cargo/bin:$PATH',
  'cd ~/dev/hibiki && git fetch origin && git merge --ff-only origin/develop && cd fushi'
)
if ($Ios) {
  if ($IosDevice) {
    $lines += "dev=$IosDevice"
  } else {
    # First available iPhone simulator udid (36-char UUID in the simctl listing).
    $lines += 'dev=$(xcrun simctl list devices available | grep iPhone | grep -oE "[0-9A-F-]{36}" | head -1)'
    $lines += 'test -n "$dev" || { echo "[mac-itest] no available iPhone simulator" >&2; exit 2; }'
  }
  $lines += 'xcrun simctl boot "$dev" 2>/dev/null || true'
  $lines += "FUSHI_TEST_HIDDEN=1 flutter test $Target -d `"`$dev`" --no-pub"
} else {
  $lines += "FUSHI_TEST_HIDDEN=1 flutter test $Target -d macos --no-pub"
}
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))

$where = if ($Ios) { "iOS simulator" + $(if ($IosDevice) { " $IosDevice" } else { "" }) } else { "macOS (hidden runner)" }
Write-Host "[mac-itest] running $Target on $where..." -ForegroundColor Cyan
ssh $mac "echo $b64 | base64 --decode | bash"
exit $LASTEXITCODE
