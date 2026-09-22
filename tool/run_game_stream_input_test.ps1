<#
.SYNOPSIS
Build and run the isolated Windows game-stream input-release regression.
.DESCRIPTION
Compiles the production game_stream_input.cpp and a real HWND fixture. Uses
clang++ or cl from PATH; cl requires a Visual Studio Developer PowerShell.
Flutter headers normally come from the app's generated ephemeral directory.
The test sends only targeted PostMessage input to its own offscreen windows.
All binaries, object files, and the result log stay under .codex-test.
.EXAMPLE
powershell -ExecutionPolicy Bypass -File tool/run_game_stream_input_test.ps1
.EXAMPLE
./tool/run_game_stream_input_test.ps1 -CompilerPath clang++.exe -FlutterIncludePath C:/flutter/cpp_client_wrapper/include
#>
[CmdletBinding()]
param(
    [string]$CompilerPath,
    [string]$FlutterIncludePath
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The game-stream HWND input regression is Windows-only.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$runnerDir = Join-Path $repoRoot 'fushi/windows/runner'
$testSource = Join-Path $runnerDir 'tests/game_stream_input_release_test.cpp'
$productionSource = Join-Path $runnerDir 'game_stream_input.cpp'
$outputDir = Join-Path $repoRoot '.codex-test/game-stream-input-test'
$executable = Join-Path $outputDir 'game_stream_input_release_test.exe'

if ([string]::IsNullOrWhiteSpace($FlutterIncludePath)) {
    $FlutterIncludePath = Join-Path $repoRoot 'fushi/windows/flutter/ephemeral/cpp_client_wrapper/include'
}
if (!(Test-Path -LiteralPath (Join-Path $FlutterIncludePath 'flutter/encodable_value.h'))) {
    throw 'Flutter C++ headers are missing. Generate the Windows ephemeral files or pass -FlutterIncludePath.'
}
$FlutterIncludePath = (Resolve-Path -LiteralPath $FlutterIncludePath).Path

if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    foreach ($candidate in @('clang++.exe', 'cl.exe')) {
        $compilerCommand = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $compilerCommand) {
            $CompilerPath = $compilerCommand.Source
            break
        }
    }
}
if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    throw 'No C++ compiler found. Put clang++ or cl on PATH, or pass -CompilerPath.'
}
$CompilerPath = (Get-Command $CompilerPath -CommandType Application -ErrorAction Stop).Source
$compilerName = [IO.Path]::GetFileNameWithoutExtension($CompilerPath)
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# cl writes intermediate .obj/.pdb files relative to the current directory.
# Keep them in the same ignored directory as the executable for either compiler.
Push-Location -LiteralPath $outputDir
try {
    if ($compilerName -eq 'cl') {
        $compileArguments = @(
            '/nologo', '/std:c++17', '/EHsc', '/DNOMINMAX', '/DUNICODE', '/D_UNICODE',
            "/I$runnerDir", "/I$FlutterIncludePath",
            $productionSource, $testSource, "/Fe:$executable", '/link', 'user32.lib'
        )
    } elseif ($compilerName -eq 'clang++') {
        $compileArguments = @(
            '-std=c++17', '-DNOMINMAX', '-DUNICODE', '-D_UNICODE',
            '-I', $runnerDir, '-I', $FlutterIncludePath,
            $productionSource, $testSource, '-o', $executable, '-luser32'
        )
    } else {
        throw "Unsupported compiler '$compilerName'; use clang++ or cl."
    }
    & $CompilerPath @compileArguments
    $compileExit = $LASTEXITCODE
    if ($compileExit -ne 0) {
        throw "Native input regression compilation failed with exit code $compileExit."
    }
    & $executable | Tee-Object -FilePath (Join-Path $outputDir 'results.log')
    $testExit = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $testExit
