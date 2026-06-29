# Runs a Hibiki Windows integration test in an isolated background runner.
#
# The script never touches user-owned Hibiki instances (e.g.
# D:\APP\Hibiki\hibiki.exe) or IDE dart/flutter processes: those are only recorded
# as evidence. It DOES reap stale TEST-RUNNER processes from a previous crashed run
# of this same runner, scoped strictly to this worktree's build\windows\x64\runner
# path (a stuck prior runner locks the build/debug port -> "Unable to start the
# app"). The test runner then starts with a unique run id, off-screen window mode,
# isolated app data/log/temp roots, and an isolated WebView2 profile.
#
# Usage (from hibiki/):
#   .\tool\run_windows_itest.ps1
#   .\tool\run_windows_itest.ps1 integration_test\app_smoke_test.dart
#   .\tool\run_windows_itest.ps1 -DryRun integration_test\app_smoke_test.dart
#   .\tool\run_windows_itest.ps1 -Visible integration_test\app_smoke_test.dart
#
# Both modes are non-blocking: the window is always non-activating
# (WS_EX_NOACTIVATE) and never steals the user's foreground/keyboard focus.
#   default   -> window stays OFF-SCREEN; captured via PrintWindow (grabs the
#                window's own composited content even off-screen/occluded). Fully
#                invisible. Try this first.
#   -Visible  -> same non-activating window placed ON-SCREEN (HIBIKI_TEST_ONSCREEN)
#                so DWM composes it for a faithful capture if the off-screen
#                PrintWindow grab comes back blank for the WGC WebView region. It
#                shows in a corner but does NOT take focus — keep using other apps.
# Screenshots land in <evidenceDir>\screenshots\shot-NN.png (-Visible also writes
# shot-NN-screen.png via CopyFromScreen).
param(
  [string]$Target = "integration_test\desktop_settings_smoke_test.dart",
  [string]$EvidenceRoot = "",
  [string]$RunId = "",
  [switch]$DryRun,
  [switch]$Visible
)

$ErrorActionPreference = "Stop"

function ConvertTo-CommandArgument {
  param([Parameter(Mandatory = $true)][string]$Value)
  if ($Value -notmatch '[\s"]') {
    return $Value
  }
  return '"' + ($Value -replace '"', '\"') + '"'
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$AsArray
  )
  if ($AsArray) {
    $arrayValue = @($Value)
    if ($arrayValue.Count -eq 0) {
      "[]" | Out-File -LiteralPath $Path -Encoding UTF8
      return
    }
    $jsonValue = $arrayValue
  } else {
    $jsonValue = $Value
  }
  ConvertTo-Json -InputObject $jsonValue -Depth 8 |
    Out-File -LiteralPath $Path -Encoding UTF8
}

function Get-HibikiProcessSnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$CurrentRunId,
    [Parameter(Mandatory = $true)][string]$RunnerPathPrefix
  )
  $processes = @(Get-Process -Name "hibiki" -ErrorAction SilentlyContinue)
  $byId = @{}
  foreach ($process in $processes) {
    $byId[[int]$process.Id] = $process
  }

  $cimProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name = 'hibiki.exe'" `
      -ErrorAction SilentlyContinue
  )
  $snapshot = foreach ($cim in $cimProcesses) {
    $id = [int]$cim.ProcessId
    $process = $byId[$id]
    $path = [string]$cim.ExecutablePath
    $isRunner = $false
    if ($path) {
      $isRunner = $path.StartsWith($RunnerPathPrefix,
        [System.StringComparison]::OrdinalIgnoreCase)
    }
    [pscustomobject]@{
      runId = $CurrentRunId
      pid = $id
      path = $path
      commandLine = [string]$cim.CommandLine
      parentProcessId = [int]$cim.ParentProcessId
      creationDate = [string]$cim.CreationDate
      mainWindowTitle = if ($process) { [string]$process.MainWindowTitle } else { "" }
      mainWindowHandle = if ($process) { [string]$process.MainWindowHandle } else { "" }
      isTestRunner = $isRunner
    }
  }
  return @($snapshot)
}

function Add-RunnerSnapshot {
  param(
    [System.Collections.ArrayList]$RunnerRecords,
    [array]$Snapshot
  )
  if ($null -eq $Snapshot) {
    return
  }
  foreach ($process in $Snapshot) {
    if (-not $process.isTestRunner) {
      continue
    }
    $alreadyRecorded = $false
    foreach ($record in $RunnerRecords) {
      if ($record.pid -eq $process.pid) {
        $alreadyRecorded = $true
        break
      }
    }
    if (-not $alreadyRecorded) {
      [void]$RunnerRecords.Add($process)
    }
  }
}

# Native interop for window screenshots. PrintWindow with PW_RENDERFULLCONTENT
# (2) captures DirectComposition / WGC content even when the window is occluded
# or off-screen (best-effort, may still be blank for the WebView texture).
# CopyFromScreen grabs the real composited pixels when the window is on-screen
# (-Visible mode), which is the only path that reliably captures the WebView.
try {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HibikiWinShot {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
}
'@ -ErrorAction Stop
} catch {
  # Type already loaded in this session, or compilation unavailable; capture is
  # best-effort and never fails the run.
}
try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { }

function Get-RunnerWindowHandle {
  param([array]$Snapshot)
  if ($null -eq $Snapshot) { return [IntPtr]::Zero }
  foreach ($process in $Snapshot) {
    if (-not $process.isTestRunner) { continue }
    $raw = [string]$process.mainWindowHandle
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq "0") { continue }
    try {
      $handle = [IntPtr][int64]$raw
      if ($handle -ne [IntPtr]::Zero) { return $handle }
    } catch { }
  }
  return [IntPtr]::Zero
}

function Save-WindowShot {
  param(
    [Parameter(Mandatory = $true)][IntPtr]$Handle,
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$ScreenGrab
  )
  try {
    $rect = New-Object 'HibikiWinShot+RECT'
    if (-not [HibikiWinShot]::GetWindowRect($Handle, [ref]$rect)) { return $false }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { return $false }
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      if ($ScreenGrab) {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0,
          (New-Object System.Drawing.Size($width, $height)))
      } else {
        $hdc = $graphics.GetHdc()
        try {
          # PW_RENDERFULLCONTENT = 2
          [void][HibikiWinShot]::PrintWindow($Handle, $hdc, 2)
        } finally {
          $graphics.ReleaseHdc($hdc)
        }
      }
      $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
      $graphics.Dispose()
      $bitmap.Dispose()
    }
    return $true
  } catch {
    return $false
  }
}

$AppRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $AppRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($RunId)) {
  $RunId = "win-itest-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $EvidenceRoot = Join-Path $AppRoot ".codex-test\windows-itest"
}

$EvidenceDir = Join-Path $EvidenceRoot $RunId
$IsolatedRoot = Join-Path $EvidenceDir "isolated-root"
$Paths = [ordered]@{
  runId = $RunId
  target = $Target
  appRoot = $AppRoot
  repoRoot = $RepoRoot
  evidenceDir = $EvidenceDir
  isolatedRoot = $IsolatedRoot
  appData = Join-Path $IsolatedRoot "appdata"
  localAppData = Join-Path $IsolatedRoot "localappdata"
  temp = Join-Path $IsolatedRoot "temp"
  userProfile = Join-Path $IsolatedRoot "userprofile"
  documents = Join-Path $IsolatedRoot "app-documents"
  appSupport = Join-Path $IsolatedRoot "app-support"
  nativeLogs = Join-Path $IsolatedRoot "logs\native"
  webView2Profile = Join-Path $IsolatedRoot "webview2-profile"
  screenshotDir = Join-Path $EvidenceDir "screenshots"
  expectedRunnerPath = Join-Path $AppRoot "build\windows\x64\runner\Debug\hibiki.exe"
}

foreach ($path in @(
    $EvidenceDir,
    $Paths.isolatedRoot,
    $Paths.appData,
    $Paths.localAppData,
    $Paths.temp,
    $Paths.userProfile,
    $Paths.documents,
    $Paths.appSupport,
    $Paths.nativeLogs,
    $Paths.webView2Profile,
    $Paths.screenshotDir
  )) {
  New-Item -ItemType Directory -Force -Path $path | Out-Null
}

$RunnerPathPrefix = Join-Path $AppRoot "build\windows\x64\runner"
$before = @(Get-HibikiProcessSnapshot -CurrentRunId $RunId `
  -RunnerPathPrefix $RunnerPathPrefix)
Write-JsonFile $before (Join-Path $EvidenceDir "process-before.json") -AsArray
Write-JsonFile $Paths (Join-Path $EvidenceDir "paths.json")

$FlutterExe = Join-Path $env:FLUTTER_ROOT "bin\flutter.bat"
if (-not $env:FLUTTER_ROOT -or -not (Test-Path -LiteralPath $FlutterExe)) {
  $FlutterExe = "D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat"
}
if (-not (Test-Path -LiteralPath $FlutterExe)) {
  $FlutterExe = "flutter"
}

$flutterArgs = @(
  "test",
  $Target,
  "-d",
  "windows",
  "--no-pub",
  "--dart-define=HIBIKI_TEST_ROOT=$($Paths.isolatedRoot)",
  "--dart-define=HIBIKI_TEST_RUN_ID=$RunId"
)
$commandLine = "$FlutterExe $((@($flutterArgs) | ForEach-Object { ConvertTo-CommandArgument $_ }) -join ' ')"
$commandLog = Join-Path $EvidenceDir "command.log"
$runnerInfoPath = Join-Path $EvidenceDir "runner-info.json"

@(
  "[itest] runId=$RunId",
  "[itest] target=$Target",
  "[itest] evidenceDir=$EvidenceDir",
  "[itest] user Hibiki instances before=$($before.Count)",
  "[itest] command=$commandLine",
  "[itest] dryRun=$($DryRun.IsPresent)",
  "[itest] visible=$($Visible.IsPresent)"
) | Out-File -LiteralPath $commandLog -Encoding UTF8

# Reap stale TEST-RUNNER processes left by a PREVIOUS crashed run of THIS runner.
# Scope is strictly this worktree's build\windows\x64\runner path (isTestRunner is
# set by exact path-prefix match in Get-HibikiProcessSnapshot), so this NEVER kills
# the user's installed Hibiki (e.g. D:\APP\Hibiki\hibiki.exe) or IDE dart/flutter
# processes. A stuck prior test-runner locks the build output / debug port and is a
# known cause of "Unable to start the app on the device". Never hand-kill by name.
if (-not $DryRun) {
  foreach ($proc in $before) {
    if ($proc.isTestRunner) {
      try {
        Stop-Process -Id ([int]$proc.pid) -Force -ErrorAction Stop
        Add-Content -LiteralPath $commandLog `
          -Value "[itest] reaped stale test-runner pid=$($proc.pid) path=$($proc.path)"
        Write-Host "[itest] reaped stale test-runner pid=$($proc.pid)" `
          -ForegroundColor DarkYellow
      } catch {
        Add-Content -LiteralPath $commandLog `
          -Value "[itest] could not reap pid=$($proc.pid): $($_.Exception.Message)"
      }
    }
  }
}

$runnerRecords = [System.Collections.ArrayList]::new()
Write-JsonFile ([pscustomobject]@{
  runId = $RunId
  dryRun = $DryRun.IsPresent
  expectedRunnerPath = $Paths.expectedRunnerPath
  records = @()
}) $runnerInfoPath

$exitCode = 0
if ($DryRun) {
  Add-Content -LiteralPath $commandLog -Value "[itest] dry run: runner not started"
} else {
  $oldHidden = $env:HIBIKI_TEST_HIDDEN
  $oldOnscreen = $env:HIBIKI_TEST_ONSCREEN
  $oldRoot = $env:HIBIKI_TEST_ROOT
  $oldRunId = $env:HIBIKI_TEST_RUN_ID
  $oldWebView2 = $env:HIBIKI_WEBVIEW2_USER_DATA_FOLDER
  $oldAppData = $env:APPDATA
  $oldLocalAppData = $env:LOCALAPPDATA
  $oldTemp = $env:TEMP
  $oldTmp = $env:TMP
  $oldUserProfile = $env:USERPROFILE
  try {
    # Always keep HIBIKI_TEST_HIDDEN set: it makes the window non-activating
    # (WS_EX_NOACTIVATE), so the app NEVER steals the user's foreground/keyboard
    # focus in either mode. -Visible additionally sets HIBIKI_TEST_ONSCREEN to
    # place that same non-activating window on-screen (composed for a faithful
    # screenshot); the default leaves it off-screen (fully invisible). Both are
    # non-blocking — the user keeps using other apps the whole time.
    $env:HIBIKI_TEST_HIDDEN = "1"
    if ($Visible) {
      $env:HIBIKI_TEST_ONSCREEN = "1"
    } else {
      Remove-Item Env:\HIBIKI_TEST_ONSCREEN -ErrorAction SilentlyContinue
    }
    $env:HIBIKI_TEST_ROOT = $Paths.isolatedRoot
    $env:HIBIKI_TEST_RUN_ID = $RunId
    $env:HIBIKI_WEBVIEW2_USER_DATA_FOLDER = $Paths.webView2Profile
    $env:APPDATA = $Paths.appData
    $env:LOCALAPPDATA = $Paths.localAppData
    $env:TEMP = $Paths.temp
    $env:TMP = $Paths.temp
    $env:USERPROFILE = $Paths.userProfile

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $cmdExe = if ($env:ComSpec) { $env:ComSpec } else { "cmd.exe" }
    $psi.FileName = $cmdExe
    $psi.Arguments = "/d /c $(ConvertTo-CommandArgument $commandLine)"
    $psi.WorkingDirectory = $AppRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["HIBIKI_TEST_HIDDEN"] = "1"
    if ($Visible) {
      $psi.EnvironmentVariables["HIBIKI_TEST_ONSCREEN"] = "1"
    } elseif ($psi.EnvironmentVariables.ContainsKey("HIBIKI_TEST_ONSCREEN")) {
      [void]$psi.EnvironmentVariables.Remove("HIBIKI_TEST_ONSCREEN")
    }
    $psi.EnvironmentVariables["HIBIKI_TEST_ROOT"] = $Paths.isolatedRoot
    $psi.EnvironmentVariables["HIBIKI_TEST_RUN_ID"] = $RunId
    $psi.EnvironmentVariables["HIBIKI_WEBVIEW2_USER_DATA_FOLDER"] =
      $Paths.webView2Profile
    $psi.EnvironmentVariables["APPDATA"] = $Paths.appData
    $psi.EnvironmentVariables["LOCALAPPDATA"] = $Paths.localAppData
    $psi.EnvironmentVariables["TEMP"] = $Paths.temp
    $psi.EnvironmentVariables["TMP"] = $Paths.temp
    $psi.EnvironmentVariables["USERPROFILE"] = $Paths.userProfile

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $shotIteration = 0
    $shotCount = 0
    while (-not $process.HasExited) {
      $snapshot = @(Get-HibikiProcessSnapshot -CurrentRunId $RunId `
        -RunnerPathPrefix $RunnerPathPrefix)
      Add-RunnerSnapshot -RunnerRecords $runnerRecords -Snapshot $snapshot
      # Throttled OS screen-grab of the runner window: ~1 shot / 2s, capped at
      # 12. -Visible uses CopyFromScreen (real on-screen pixels incl. WebView);
      # off-screen default falls back to best-effort PrintWindow. Never fatal.
      if (($shotIteration % 8) -eq 0 -and $shotCount -lt 12) {
        $shotHandle = Get-RunnerWindowHandle -Snapshot $snapshot
        if ($shotHandle -ne [IntPtr]::Zero) {
          # PrintWindow is the primary capture: it grabs the window's own
          # composited content even when it is off-screen, behind other windows,
          # or never focused — so it works in both the default off-screen mode
          # and the non-activating on-screen (-Visible) mode without disturbing
          # the user. -Visible additionally saves a CopyFromScreen variant
          # (faithful when the window is on top of its screen region).
          $shotPath = Join-Path $Paths.screenshotDir `
            ("shot-{0:D2}.png" -f $shotCount)
          if (Save-WindowShot -Handle $shotHandle -Path $shotPath) {
            $shotCount++
            Add-Content -LiteralPath $commandLog `
              -Value "[itest] screenshot saved: $shotPath"
          }
          if ($Visible) {
            $screenPath = Join-Path $Paths.screenshotDir `
              ("shot-{0:D2}-screen.png" -f $shotCount)
            [void](Save-WindowShot -Handle $shotHandle -Path $screenPath -ScreenGrab)
          }
        }
      }
      $shotIteration++
      Start-Sleep -Milliseconds 250
    }
    Add-Content -LiteralPath $commandLog `
      -Value "[itest] screenshots captured=$shotCount visible=$($Visible.IsPresent)"
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Add-Content -LiteralPath $commandLog -Value "`n[stdout]`n$stdout"
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
      Add-Content -LiteralPath $commandLog -Value "`n[stderr]`n$stderr"
    }
  } catch {
    $exitCode = 1
    Add-Content -LiteralPath $commandLog -Value "`n[script-error]`n$($_ | Out-String)"
  } finally {
    $env:HIBIKI_TEST_HIDDEN = $oldHidden
    $env:HIBIKI_TEST_ONSCREEN = $oldOnscreen
    $env:HIBIKI_TEST_ROOT = $oldRoot
    $env:HIBIKI_TEST_RUN_ID = $oldRunId
    $env:HIBIKI_WEBVIEW2_USER_DATA_FOLDER = $oldWebView2
    $env:APPDATA = $oldAppData
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    $env:USERPROFILE = $oldUserProfile
  }
}

$after = @(Get-HibikiProcessSnapshot -CurrentRunId $RunId `
  -RunnerPathPrefix $RunnerPathPrefix)
Write-JsonFile $after (Join-Path $EvidenceDir "process-after.json") -AsArray
Write-JsonFile ([pscustomobject]@{
  runId = $RunId
  dryRun = $DryRun.IsPresent
  expectedRunnerPath = $Paths.expectedRunnerPath
  records = @($runnerRecords)
}) $runnerInfoPath
$exitCode | Out-File -LiteralPath (Join-Path $EvidenceDir "exit-code.txt") `
  -Encoding ASCII

Write-Host "[itest] evidence: $EvidenceDir" -ForegroundColor Cyan
Write-Host "[itest] exit code: $exitCode" -ForegroundColor Cyan
Write-Host "[itest] observe evidence: $($Paths.screenshotDir)\observe-*.png are authoritative (real pixels, off-screen capable)" -ForegroundColor Cyan
Write-Host "[itest] note: shot-NN.png (PrintWindow) is usually blank for Flutter/WebView; only proves the window exists" -ForegroundColor DarkGray
exit $exitCode
