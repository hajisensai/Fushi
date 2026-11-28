<#
.SYNOPSIS
  Shared Python 3 lookup for the Windows entry points that wrap a Python tool
  (tool/vendored_binaries.ps1, tool/native_libs.ps1). Dot-source it:
    . (Join-Path $PSScriptRoot 'python3.ps1')
    $python = Resolve-Python3   # @(<exe>, <prefix args>...)
#>

function Invoke-NativeExitCode {
    <#
      Runs a native command and returns only its exit code. Windows PowerShell 5.1
      turns every stderr line of a native command into an ErrorRecord once stderr is
      redirected (here, or by a caller running this script under `*>` / a pipeline),
      and under the script-wide ErrorActionPreference=Stop the first one throws --
      before $LASTEXITCODE could be read. The probe must survive exactly that (the
      Microsoft Store python3 stub prints to stderr and exits 9009), so stderr is
      merged into the success stream with the preference relaxed to Continue for
      this call only, and the verdict is the exit code alone.
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Arguments = @(),
        [switch]$PassOutput
    )

    $ErrorActionPreference = 'Continue'  # function scope: the caller keeps Stop
    $global:LASTEXITCODE = 0
    try {
        if ($PassOutput) {
            & $Executable @Arguments 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    # python's stderr (error: ... lines); the exit code decides.
                    Write-Host $_.Exception.Message -ForegroundColor Yellow
                } else {
                    Write-Host $_
                }
            }
        } else {
            & $Executable @Arguments 2>&1 | Out-Null
        }
    } catch {
        # The executable could not be started at all (e.g. a broken stub).
        if ($PassOutput) { throw }
        return 9009
    }
    return [int]$LASTEXITCODE
}

function Resolve-Python3 {
    [OutputType([string[]])]
    param()

    # `py -3` first: the python3 / python names may be the Microsoft Store stub.
    foreach ($candidate in @(@('py', '-3'), @('python3'), @('python'))) {
        $commands = @(Get-Command $candidate[0] -CommandType Application -ErrorAction SilentlyContinue)
        foreach ($command in $commands) {
            $prefix = @($command.Source) + @($candidate | Select-Object -Skip 1)
            $probeArgs = @($prefix | Select-Object -Skip 1) + @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)')
            $code = Invoke-NativeExitCode -Executable $prefix[0] -Arguments $probeArgs
            if ($code -eq 0) { return , $prefix }
            Write-Verbose "python3: $($prefix -join ' ') is not a usable Python 3.8+ (exit $code)"
        }
    }
    throw '找不到 Python 3（试过 py -3 / python3 / python）。tool/vendored_binaries.py（取回不入库的预编译二进制）与 tool/native_crates.py（原生库登记表与源码键）都需要它；装 Python 3.8+ 后重跑。'
}
