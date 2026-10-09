# Developer CLI forwarding only. The self-contained plugin owns installer logic.
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
$installer = Join-Path $PSScriptRoot '..\..\third_party\media_kit_libs_windows_video\bdj\bdj_runtime.ps1'
& $installer @PSBoundParameters
exit $LASTEXITCODE
