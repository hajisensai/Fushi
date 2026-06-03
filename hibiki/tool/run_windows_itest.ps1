# Runs a Hibiki integration test against the REAL Windows desktop app in the
# background: HIBIKI_TEST_HIDDEN parks the runner off-screen + non-activating
# (see windows/runner/win32_window.cpp) so the app never appears or steals the
# foreground while the test drives it. Phase 2 of the test-flow refactor.
#
# Usage (from hibiki/):
#   .\tool\run_windows_itest.ps1                      # default: desktop settings smoke
#   .\tool\run_windows_itest.ps1 integration_test\app_smoke_test.dart
param(
  [string]$Target = "integration_test\desktop_settings_smoke_test.dart"
)

$ErrorActionPreference = "Stop"

# A stale hibiki.exe locks the runner binary (LNK1168) — refuse to build over it.
$running = Get-Process -Name "hibiki" -ErrorAction SilentlyContinue
if ($running) {
  Write-Error "hibiki.exe is running (PID $($running.Id)) — close it first (it locks the runner binary)."
  exit 1
}

$env:HIBIKI_TEST_HIDDEN = "1"
Write-Host "[itest] HIBIKI_TEST_HIDDEN=1  target=$Target" -ForegroundColor Cyan
flutter test $Target -d windows --no-pub
exit $LASTEXITCODE
