<#
.SYNOPSIS
Build and run the isolated Windows game-stream WebRTC capture helper tests.
.DESCRIPTION
Compiles only the deterministic helper test for the WGC->WebRTC adapter. The
binary and all cl intermediates stay under .codex-test/game-stream-capture-test.
Uses clang++ or cl from PATH, or discovers Visual Studio Build Tools via
vswhere/vcvars64.bat when cl is not already available.
#>
[CmdletBinding()]
param(
    [string]$CompilerPath
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The game-stream capture helper test is Windows-only.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$runnerDir = Join-Path $repoRoot 'fushi/windows/runner'
$testSource = Join-Path $runnerDir 'tests/game_stream_webrtc_capture_helper_test.cpp'
$outputDir = Join-Path $repoRoot '.codex-test/game-stream-capture-test'
$executable = Join-Path $outputDir 'game_stream_webrtc_capture_helper_test.exe'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$vcvarsPath = $null
if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    foreach ($candidate in @('clang++.exe', 'cl.exe')) {
        $cmd = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            $CompilerPath = $cmd.Source
            break
        }
    }
}
if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $vswhereCandidates = @(
        (Join-Path $programFilesX86 'Microsoft Visual Studio/Installer/vswhere.exe'),
        (Join-Path $programFiles 'Microsoft Visual Studio/Installer/vswhere.exe')
    )
    foreach ($vswhere in $vswhereCandidates) {
        if (Test-Path -LiteralPath $vswhere) {
            $install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
            if (![string]::IsNullOrWhiteSpace($install)) {
                $candidate = Join-Path $install 'VC/Auxiliary/Build/vcvars64.bat'
                if (Test-Path -LiteralPath $candidate) {
                    $vcvarsPath = $candidate
                    $CompilerPath = 'cl.exe'
                    break
                }
            }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    throw 'No C++ compiler found. Put clang++ or cl on PATH, install VS Build Tools, or pass -CompilerPath.'
}

$compilerName = [IO.Path]::GetFileNameWithoutExtension($CompilerPath)
Push-Location -LiteralPath $outputDir
try {
    if ($compilerName -eq 'cl') {
        $compileArguments = @('/nologo','/utf-8','/std:c++17','/EHsc','/DNOMINMAX','/DWIN32','/D_WINDOWS',"/I$runnerDir",$testSource,"/Fe:$executable")
        if ($vcvarsPath) {
            $quotedArgs = ($compileArguments | ForEach-Object { '"' + ($_ -replace '"','\"') + '"' }) -join ' '
            cmd /c "`"$vcvarsPath`" >nul && cl $quotedArgs"
        } else {
            & $CompilerPath @compileArguments
        }
    } elseif ($compilerName -eq 'clang++') {
        & $CompilerPath '-std=c++17' '-DNOMINMAX' '-DWIN32' '-D_WINDOWS' '-I' $runnerDir $testSource '-o' $executable
    } else {
        throw "Unsupported compiler '$compilerName'; use clang++ or cl."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Capture helper test compilation failed with exit code $LASTEXITCODE."
    }
    & $executable | Tee-Object -FilePath (Join-Path $outputDir 'results.log')
    $testExit = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $testExit
