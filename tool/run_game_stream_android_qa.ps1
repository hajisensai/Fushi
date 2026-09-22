param(
    [ValidateSet('Build', 'Install', 'Run')][string]$Action = 'Build',
    [string]$Serial,
    [string]$CredentialsPath,
    [string]$ApkPath,
    [string]$OutputDirectory,
    [switch]$SkipAnalysis
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repo 'fushi'
$android = Join-Path $app 'android'
$package = 'app.fushi.reader.streamqa'
if ($Action -ne 'Build' -and $Serial -notmatch '^[A-Za-z0-9_.:-]+$') {
    throw 'Install and Run require an explicit valid adb -Serial'
}
$properties = @{}
Get-Content -LiteralPath (Join-Path $android 'local.properties') | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') { $properties[$Matches[1]] = $Matches[2].Replace('\\', '\').Replace('\:', ':') }
}
$adb = Join-Path $properties['sdk.dir'] 'platform-tools/adb.exe'
$flutter = Join-Path $properties['flutter.sdk'] 'bin/flutter.bat'
$dart = Join-Path $properties['flutter.sdk'] 'bin/dart.bat'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo '.codex-test/game-stream-android-qa' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $output | Out-Null
if (-not $ApkPath) { $ApkPath = Join-Path $output 'streamqa.apk' }
$ApkPath = [IO.Path]::GetFullPath($ApkPath)

function Assert-Exit([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed (exit $LASTEXITCODE)" }
}

function Assert-IsolatedApk {
    if (-not (Test-Path -LiteralPath $ApkPath)) { throw 'Build the isolated APK first' }
    $buildTools = Get-ChildItem -LiteralPath (Join-Path $properties['sdk.dir'] 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $badging = & (Join-Path $buildTools.FullName 'aapt.exe') dump badging $ApkPath
    Assert-Exit 'APK identity inspection'
    if (-not ($badging | Select-String -SimpleMatch "package: name='$package'")) {
        throw 'Refusing to install an APK without the isolated QA applicationId'
    }
}

function Export-QAPrivateArtifact([string]$DeviceFile, [string]$Destination) {
    $capture = New-Object System.Diagnostics.ProcessStartInfo
    $capture.FileName = $adb
    $capture.Arguments = "-s $Serial exec-out run-as $package cat files/$DeviceFile"
    $capture.UseShellExecute = $false
    $capture.CreateNoWindow = $true
    $capture.RedirectStandardOutput = $true
    $capture.RedirectStandardError = $true
    $captureProcess = [Diagnostics.Process]::Start($capture)
    $artifact = [IO.File]::Create($Destination)
    try { $captureProcess.StandardOutput.BaseStream.CopyTo($artifact) } finally { $artifact.Dispose() }
    $null = $captureProcess.StandardError.ReadToEnd()
    $captureProcess.WaitForExit()
    $captureProcess.Dispose()
}

if ($Action -eq 'Build') {
    # The override exists only in an untracked Gradle init script. Production
    # applicationId, variants, manifests and user app data remain untouched.
    $init = Join-Path $output 'streamqa.init.gradle'
    @'
allprojects { project ->
    project.pluginManager.withPlugin('com.android.application') {
        project.extensions.getByName('androidComponents').finalizeDsl { android ->
            android.defaultConfig.applicationId = 'app.fushi.reader.streamqa'
        }
    }
}
'@ | Set-Content -LiteralPath $init -Encoding ascii
    Push-Location $app
    try {
        & $dart format integration_test/game_stream_lan_client_test.dart
        Assert-Exit 'Dart format'
        if (-not $SkipAnalysis) {
            & $flutter analyze --no-pub integration_test/game_stream_lan_client_test.dart
            Assert-Exit 'Fixture analysis'
        }
    } finally { Pop-Location }
    Push-Location $android
    try {
        $ErrorActionPreference = 'Continue'
        & .\gradlew.bat --init-script $init :app:assembleDebug '-Ptarget=integration_test/game_stream_lan_client_test.dart' '-Ptarget-platform=android-arm64' --console=plain 2>&1 | Tee-Object -FilePath (Join-Path $output 'build.log')
        $ErrorActionPreference = 'Stop'
        Assert-Exit 'Isolated APK build'
    } finally { Pop-Location }
    $built = Get-ChildItem -LiteralPath (Join-Path $app 'build/app/outputs/apk/debug') -Filter '*.apk' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $built) { throw 'Gradle produced no debug APK' }
    Copy-Item -LiteralPath $built.FullName -Destination $ApkPath -Force
    Assert-IsolatedApk
    Write-Output "Isolated APK: $ApkPath"
    exit 0
}

Assert-IsolatedApk
$state = & $adb -s $Serial get-state
Assert-Exit 'ADB target'
if ($state.Trim() -ne 'device') { throw 'The selected adb device is not ready' }
# Install only the checked QA package. No uninstall, pm clear or shared-storage
# fixture is used, and no user application is force-stopped by this script.
& $adb -s $Serial install -r $ApkPath
Assert-Exit 'QA APK install'
if ($Action -eq 'Install') { exit 0 }

if (-not $CredentialsPath -or -not (Test-Path -LiteralPath $CredentialsPath)) {
    throw 'Run requires the private credential file from the Windows host fixture'
}
$credentialFile = [IO.Path]::GetFullPath($CredentialsPath)
try {
    # Dart writes UTF-8 without a BOM. Windows PowerShell 5.1 otherwise uses
    # the system ANSI code page and can corrupt the Japanese fixture terms.
    $credential = Get-Content -LiteralPath $credentialFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($credential.version -ne 1 -or $credential.hostUrl -notmatch '^https://' -or -not $credential.token -or -not $credential.tlsFingerprint) { throw 'invalid' }
} catch { throw 'Invalid private credential file (contents suppressed)' }
$credential = $null
& $adb -s $Serial shell run-as $package mkdir -p files
Assert-Exit 'QA private directory'
# Pipe bytes to dd over stdin. Secrets never appear in argv, console or public
# device storage. Both run-as and the target file are restricted to the QA UID.
$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = $adb
$start.Arguments = "-s $Serial shell -T run-as $package dd of=files/game_stream_lan_credentials.private.json"
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($start)
$stream = [IO.File]::OpenRead($credentialFile)
try { $stream.CopyTo($process.StandardInput.BaseStream) } finally { $stream.Dispose(); $process.StandardInput.Close() }
$null = $process.StandardOutput.ReadToEnd()
$null = $process.StandardError.ReadToEnd()
$process.WaitForExit()
if ($process.ExitCode -ne 0) { throw 'Credential provisioning failed (output suppressed)' }
$process.Dispose()

Push-Location $app
$runExit = 1
try {
    $ErrorActionPreference = 'Continue'
    # drive otherwise uninstalls its APK on completion, deleting the private
    # evidence before this script can export it. The fixture itself disconnects
    # and removes its credential in finally; keep only this isolated QA app.
    & $flutter drive --no-pub --keep-app-running -d $Serial --driver=test_driver/integration_test.dart --target=integration_test/game_stream_lan_client_test.dart "--use-application-binary=$ApkPath" 2>&1 | Tee-Object -FilePath (Join-Path $output 'drive.log')
    $runExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
} finally {
    Pop-Location
    # Evidence contains no authentication material. Preserve failures as well.
    Export-QAPrivateArtifact 'game_stream_lan_result.json' (Join-Path $output 'result.json')
    Export-QAPrivateArtifact 'game_stream_lan.png' (Join-Path $output 'game_stream_lan.png')
    & $adb -s $Serial shell run-as $package rm -f files/game_stream_lan_credentials.private.json 2>$null | Out-Null
}
if ($runExit -ne 0) { throw "Android LAN fixture failed (exit $runExit); see $output" }
Write-Output "Android LAN fixture passed; evidence: $output"
