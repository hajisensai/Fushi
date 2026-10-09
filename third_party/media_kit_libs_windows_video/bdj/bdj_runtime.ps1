# Optional, per-user BD-J runtime. Never writes machine/user JAVA_HOME or PATH.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Probe', 'Run')][string]$Action = 'Probe',
    [string]$Root,
    [string]$Bundle,
    [string]$Archive,
    [string]$StagingDirectory,
    [string]$StartSignal,
    [string]$Executable,
    [string[]]$ExecutableArguments = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
if (!$Bundle) { $Bundle = $PSScriptRoot }
$Bundle = [IO.Path]::GetFullPath($Bundle)
$manifest = Get-Content -LiteralPath (Join-Path $Bundle 'manifest.json') -Raw | ConvertFrom-Json
if (!$Root) { $Root = Join-Path $env:LOCALAPPDATA $manifest.runtime.componentRootSuffix }
$Root = [IO.Path]::GetFullPath($Root)

function Assert-SafeStagingPath([string]$Stage, [string]$Parent) {
    $resolved = [IO.Path]::GetFullPath($Stage)
    if (![StringComparer]::OrdinalIgnoreCase.Equals((Split-Path $resolved -Parent), $Parent) -or
        (Split-Path $resolved -Leaf) -cnotmatch '^\.bdj-install-[0-9a-f]{32}$') {
        throw 'StagingDirectory must be a .bdj-install-<32 lowercase hex UUID> directory beside Root'
    }
    if (Test-Path -LiteralPath $resolved) {
        $item = Get-Item -LiteralPath $resolved -Force
        if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'StagingDirectory must be a real directory, not a file or reparse point'
        }
    }
}

function Assert-Hash([string]$Path, [string]$Expected) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "BD-J component checksum mismatch: $Path"
    }
    $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
    if ($actual -ne $Expected) { throw "BD-J component checksum mismatch: $Path" }
}

function Test-Runtime([string]$Directory) {
    foreach ($file in $manifest.files) {
        Assert-Hash (Join-Path $Directory $file.name) $file.sha256
    }
    $javaHome = Join-Path $Directory $manifest.runtime.directory
    $jvm = Join-Path $javaHome 'bin\server\jvm.dll'
    if (!(Test-Path -LiteralPath $jvm -PathType Leaf)) { throw "Missing BD-J JVM: $jvm" }
    # libbluray's boot classes require JNI native registration; a plain java
    # invocation must not preload them. Their exact bytes are checked above.
    $probe = & (Join-Path $javaHome 'bin\java.exe') -cp (Join-Path $Directory 'bdj-runtime-probe.jar') BdjRuntimeProbe 2>&1
    if ($LASTEXITCODE -ne 0 -or !($probe -match '^BDJ_RUNTIME_OK ')) {
        throw "BD-J runtime class loading failed: $probe"
    }
    return [ordered]@{
        ready = $true
        componentRoot = $Directory
        libbluray = $manifest.libbluray.version
        javaHome = $javaHome
        classPath = Join-Path $Directory 'libbluray-j2se-1.5.0.jar'
        jvm = $jvm
        probe = [string]($probe -join "`n")
    }
}

if ($StartSignal) {
    # The application first assigns this installer to its Windows job, then
    # creates this file. No Java child may start before that assignment succeeds.
    # Only existence matters; file contents are never read or executed.
    $signalPath = [IO.Path]::GetFullPath($StartSignal)
    $signalWait = [Diagnostics.Stopwatch]::StartNew()
    while (![IO.File]::Exists($signalPath)) {
        if ($signalWait.Elapsed.TotalSeconds -ge 60) {
            throw 'BD-J installer start signal was not received within 60 seconds'
        }
        Start-Sleep -Milliseconds 100
    }
}

if ($Action -eq 'Install') {
    # Never replace an existing or incomplete install while another player may use it.
    if (Test-Path -LiteralPath $Root) {
        Test-Runtime $Root | ConvertTo-Json
        exit 0
    }
    $parent = Split-Path $Root -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = if ($StagingDirectory) { [IO.Path]::GetFullPath($StagingDirectory) }
             else { Join-Path $parent ('.bdj-install-' + [Guid]::NewGuid().ToString('N')) }
    Assert-SafeStagingPath $stage $parent
    if (Test-Path -LiteralPath $stage) {
        if (@(Get-ChildItem -LiteralPath $stage -Force).Count -ne 0) {
            throw 'StagingDirectory must be empty; an existing installation session is never reused'
        }
    } else {
        New-Item -ItemType Directory -Path $stage | Out-Null
    }
    try {
        if (!$Archive) {
            $Archive = Join-Path $stage 'runtime.zip'
            Invoke-WebRequest -UseBasicParsing -Uri $manifest.runtime.url -OutFile $Archive
        }
        Assert-Hash $Archive $manifest.runtime.sha256
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive), $stage)
        foreach ($file in $manifest.files) {
            $source = Join-Path $Bundle $file.name
            Assert-Hash $source $file.sha256
            Copy-Item -LiteralPath $source -Destination $stage
        }
        Copy-Item -LiteralPath (Join-Path $Bundle 'COPYING.libbluray') -Destination $stage
        Copy-Item -LiteralPath (Join-Path $Bundle 'manifest.json') -Destination $stage
        $null = Test-Runtime $stage
        # Atomic directory rename exposes only a fully extracted and tested component.
        [IO.Directory]::Move($stage, $Root)
    } catch {
        $failure = $_.ToString()
        $log = $stage + '.error.log'
        try {
            [IO.File]::WriteAllText($log, $failure.Substring(0, [Math]::Min(8192, $failure.Length)), $OutputEncoding)
        } catch { $log = '(diagnostic log could not be written)' }
        # Only our validated, same-parent session directory is eligible for cleanup.
        # If the host kills this process on cancellation, it owns cleanup of the
        # explicit StagingDirectory after the process has fully exited.
        try {
            Assert-SafeStagingPath $stage $parent
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        } catch {
            throw "BD-J install failed: $failure. Stage cleanup failed for ${stage}: $_. Log: $log"
        }
        throw "BD-J install failed: $failure. Diagnostic log: $log"
    }
}
$runtime = Test-Runtime $Root
if ($Action -ne 'Run') {
    $runtime | ConvertTo-Json
    exit 0
}
if (!$Executable) { throw '-Executable is required for Run' }
$savedJava = $env:JAVA_HOME
$savedCp = $env:LIBBLURAY_CP
try {
    # Process-scoped environment is inherited only by this launched child.
    $env:JAVA_HOME = $runtime.javaHome
    $env:LIBBLURAY_CP = $runtime.classPath
    & $Executable @ExecutableArguments
    $code = $LASTEXITCODE
} finally {
    $env:JAVA_HOME = $savedJava
    $env:LIBBLURAY_CP = $savedCp
}
exit $code
