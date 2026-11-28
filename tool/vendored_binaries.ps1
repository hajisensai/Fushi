<#
.SYNOPSIS
  Restore the prebuilt third-party binaries that are not committed (Windows entry point).

.DESCRIPTION
  Thin wrapper over tool/vendored_binaries.py (the single implementation shared
  with CI and the dist_test workers): finds a Python 3 interpreter and runs
  `fetch`. Extra arguments are passed through, e.g.
    tool/vendored_binaries.ps1 --group windows
  Called by tool/bootstrap.ps1. Fails (throws) when Python is missing or any
  file cannot be fetched / does not match tool/vendored_binaries.json.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FetchArgs
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'python3.ps1')

$python = Resolve-Python3
$script = Join-Path $PSScriptRoot 'vendored_binaries.py'
$arguments = @($python | Select-Object -Skip 1) + @($script, 'fetch') + @($FetchArgs | Where-Object { $_ })
Write-Host "vendored binaries: $($python[0]) $($arguments -join ' ')" -ForegroundColor Cyan
$exitCode = Invoke-NativeExitCode -Executable $python[0] -Arguments $arguments -PassOutput
if ($exitCode -ne 0) {
    throw "tool/vendored_binaries.py fetch failed (exit $exitCode)。网络问题先配代理（HTTPS_PROXY，见 tool/bootstrap.ps1 头部）；sha256 不符说明 release 资产或 tool/vendored_binaries.json 有误，别绕过。"
}
