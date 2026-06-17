# Runs a Hibiki Windows integration test in an isolated background runner.
#
# The script intentionally does not close, kill, or block on existing Hibiki
# processes. A user-owned Hibiki instance is recorded as evidence, then the
# test runner starts with a unique run id, off-screen window mode, isolated app
# data/log/temp roots, and an isolated WebView2 profile.
#
# Usage (from hibiki/):
#   .\tool\run_windows_itest.ps1
#   .\tool\run_windows_itest.ps1 integration_test\app_smoke_test.dart
#   .\tool\run_windows_itest.ps1 -DryRun integration_test\app_smoke_test.dart
param(
  [string]$Target = "integration_test\desktop_settings_smoke_test.dart",
  [string]$EvidenceRoot = "",
  [string]$RunId = "",
  [switch]$DryRun
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
    $Paths.webView2Profile
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
  "[itest] dryRun=$($DryRun.IsPresent)"
) | Out-File -LiteralPath $commandLog -Encoding UTF8

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
  $oldRoot = $env:HIBIKI_TEST_ROOT
  $oldRunId = $env:HIBIKI_TEST_RUN_ID
  $oldWebView2 = $env:HIBIKI_WEBVIEW2_USER_DATA_FOLDER
  $oldAppData = $env:APPDATA
  $oldLocalAppData = $env:LOCALAPPDATA
  $oldTemp = $env:TEMP
  $oldTmp = $env:TMP
  $oldUserProfile = $env:USERPROFILE
  try {
    $env:HIBIKI_TEST_HIDDEN = "1"
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

    while (-not $process.HasExited) {
      $snapshot = @(Get-HibikiProcessSnapshot -CurrentRunId $RunId `
        -RunnerPathPrefix $RunnerPathPrefix)
      Add-RunnerSnapshot -RunnerRecords $runnerRecords -Snapshot $snapshot
      Start-Sleep -Milliseconds 250
    }
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
exit $exitCode
