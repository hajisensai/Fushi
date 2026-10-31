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

function Resolve-Python3 {
    [OutputType([string[]])]
    param()

    # `py -3` first: the python3 / python names may be the Microsoft Store stub.
    foreach ($candidate in @(@('py', '-3'), @('python3'), @('python'))) {
        $command = Get-Command $candidate[0] -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $command) { continue }
        $prefix = @($command.Source) + @($candidate | Select-Object -Skip 1)
        $probeArgs = @($prefix | Select-Object -Skip 1) + @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)')
        & $prefix[0] @probeArgs 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return , $prefix }
    }
    throw '找不到 Python 3（试过 py -3 / python3 / python）。tool/vendored_binaries.py 需要它取回不入库的预编译二进制；装 Python 3.8+ 后重跑。'
}

$python = Resolve-Python3
$script = Join-Path $PSScriptRoot 'vendored_binaries.py'
$arguments = @($python | Select-Object -Skip 1) + @($script, 'fetch') + @($FetchArgs | Where-Object { $_ })
Write-Host "vendored binaries: $($python[0]) $($arguments -join ' ')" -ForegroundColor Cyan
& $python[0] @arguments
if ($LASTEXITCODE -ne 0) {
    throw "tool/vendored_binaries.py fetch failed (exit $LASTEXITCODE)。网络问题先配代理（HTTPS_PROXY，见 tool/bootstrap.ps1 头部）；sha256 不符说明 release 资产或 tool/vendored_binaries.json 有误，别绕过。"
}
