[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,
    [string] $SourceDirectory = "",
    [string] $DownloadCache = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$serverRepository = "https://github.com/miru-project/M-Extension-Server.git"
$serverCommit = "ee55c65106bb18bf81a5ddc660d321b4e14ea2f9"
$temurinVersion = "jdk-21.0.11+10"
$temurinArchive = "OpenJDK21U-jdk_x64_windows_hotspot_21.0.11_10.zip"
$temurinSha256 = "d3625e7cadf23787ea540229544b6e2ab494b3b54da1801879e583e1dfee0a64"
$temurinUrl = "https://github.com/adoptium/temurin21-binaries/releases/download/$($temurinVersion.Replace('+', '%2B'))/$temurinArchive"

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$overlayRoot = Join-Path $repositoryRoot "third_party\m_extension_server"
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
if ([IO.Path]::GetPathRoot($resolvedOutput) -eq $resolvedOutput) {
    throw "Refusing to write a desktop runtime to a filesystem root."
}

if ([string]::IsNullOrWhiteSpace($DownloadCache)) {
    $DownloadCache = Join-Path ([IO.Path]::GetTempPath()) "hibiki-mihon-downloads"
}
$resolvedCache = [IO.Path]::GetFullPath($DownloadCache)
[IO.Directory]::CreateDirectory($resolvedCache) | Out-Null

$workingRoot = Join-Path ([IO.Path]::GetTempPath()) ("hibiki-mihon-build-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($workingRoot) | Out-Null
$sourceRoot = Join-Path $workingRoot "M-Extension-Server"
$stagingRoot = Join-Path $workingRoot "output"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Executable,
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable failed with exit code $LASTEXITCODE"
    }
}

function Copy-Overlay {
    param([string] $From, [string] $To)
    Get-ChildItem -LiteralPath $From -Recurse -File | ForEach-Object {
        $relativePath = [IO.Path]::GetRelativePath($From, $_.FullName)
        $destination = Join-Path $To $relativePath
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
        Invoke-Checked -Executable git -Arguments @("clone", "--filter=blob:none", "--no-checkout", $serverRepository, $sourceRoot)
        Invoke-Checked -Executable git -Arguments @("-C", $sourceRoot, "checkout", "--detach", $serverCommit)
    } else {
        $providedSource = [IO.Path]::GetFullPath($SourceDirectory)
        $actualCommit = (& git -C $providedSource rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $serverCommit) {
            throw "M-Extension-Server source must be at $serverCommit, found $actualCommit"
        }
        Invoke-Checked -Executable git -Arguments @("clone", "--no-hardlinks", "--no-checkout", $providedSource, $sourceRoot)
        Invoke-Checked -Executable git -Arguments @("-C", $sourceRoot, "checkout", "--detach", $serverCommit)
    }

    Invoke-Checked -Executable git -Arguments @(
        "-C",
        $sourceRoot,
        "apply",
        "--unidiff-zero",
        (Join-Path $overlayRoot "server-build.gradle.patch")
    )
    Copy-Overlay (Join-Path $overlayRoot "overlay") $sourceRoot

    $archivePath = Join-Path $resolvedCache $temurinArchive
    if (-not (Test-Path -LiteralPath $archivePath)) {
        Invoke-WebRequest -Uri $temurinUrl -OutFile $archivePath
    }
    $actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $temurinSha256) {
        throw "Temurin archive checksum mismatch: expected $temurinSha256, got $actualSha256"
    }

    $jdkExtractRoot = Join-Path $workingRoot "jdk"
    Expand-Archive -LiteralPath $archivePath -DestinationPath $jdkExtractRoot
    $jdkRoot = Get-ChildItem -LiteralPath $jdkExtractRoot -Directory | Select-Object -First 1
    if ($null -eq $jdkRoot) {
        throw "Temurin archive did not contain a JDK directory."
    }

    # The pinned server targets Java 21. Running Gradle/tests with the host JDK
    # can compile the classes but then fail every test class at execution time
    # when the host is Java 17. Use the same verified JDK that will be linked
    # into the app, so compilation, tests, jdeps and jlink share one toolchain.
    $previousJavaHome = $env:JAVA_HOME
    try {
        $env:JAVA_HOME = $jdkRoot.FullName
        Invoke-Checked -Executable (Join-Path $sourceRoot "gradlew.bat") -Arguments @(
            "-p", $sourceRoot,
            ":server:test",
            ":server:shadowJar",
            "--no-daemon"
        )
    } finally {
        if ($null -eq $previousJavaHome) {
            Remove-Item Env:JAVA_HOME -ErrorAction SilentlyContinue
        } else {
            $env:JAVA_HOME = $previousJavaHome
        }
    }

    $serverJar = Get-ChildItem -LiteralPath (Join-Path $sourceRoot "server\build") -Filter "*.jar" |
        Where-Object { $_.Name -like "MExtensionServer-*" } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $serverJar) {
        throw "The M-Extension-Server shadow JAR was not produced."
    }

    $jdeps = Join-Path $jdkRoot.FullName "bin\jdeps.exe"
    $jlink = Join-Path $jdkRoot.FullName "bin\jlink.exe"
    $detectedModules = (& $jdeps --ignore-missing-deps --multi-release 21 --print-module-deps $serverJar.FullName).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "jdeps failed while inspecting the M-Extension-Server JAR."
    }
    $moduleSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    @(
        $detectedModules -split ","
        "java.base"
        "java.desktop"
        "java.logging"
        "java.naming"
        "java.net.http"
        "java.prefs"
        "java.security.jgss"
        "java.sql"
        "jdk.crypto.ec"
        "jdk.unsupported"
    ) | ForEach-Object {
        $module = $_.Trim()
        if (-not [string]::IsNullOrWhiteSpace($module)) {
            $moduleSet.Add($module) | Out-Null
        }
    }
    $modules = (($moduleSet | Sort-Object) -join ",")

    [IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
    Invoke-Checked -Executable $jlink -Arguments @(
        "--add-modules", $modules,
        "--strip-debug",
        "--no-header-files",
        "--no-man-pages",
        "--compress=2",
        "--output", (Join-Path $stagingRoot "runtime")
    )
    Copy-Item -LiteralPath $serverJar.FullName -Destination (Join-Path $stagingRoot "m-extension-server.jar")
    Copy-Item -LiteralPath (Join-Path $sourceRoot "LICENSE") -Destination (Join-Path $stagingRoot "LICENSE-M-Extension-Server.txt")
    Copy-Item -LiteralPath (Join-Path $overlayRoot "NOTICE") -Destination (Join-Path $stagingRoot "NOTICE-M-Extension-Server.txt")

    $checksums = [ordered]@{
        mExtensionServer = [ordered]@{
            version = "v1.0.5.0"
            commit = $serverCommit
            sha256 = (Get-FileHash -LiteralPath (Join-Path $stagingRoot "m-extension-server.jar") -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        temurin = [ordered]@{
            version = $temurinVersion
            archive = $temurinArchive
            archiveSha256 = $temurinSha256
        }
    }
    $checksums | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stagingRoot "checksums.json") -Encoding utf8NoBOM

    $backup = $null
    if (Test-Path -LiteralPath $resolvedOutput) {
        $backup = "$resolvedOutput.backup-$([Guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $resolvedOutput -Destination $backup
    }
    try {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolvedOutput)) | Out-Null
        Move-Item -LiteralPath $stagingRoot -Destination $resolvedOutput
        if ($null -ne $backup) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
    } catch {
        if ($null -ne $backup -and -not (Test-Path -LiteralPath $resolvedOutput)) {
            Move-Item -LiteralPath $backup -Destination $resolvedOutput
        }
        throw
    }
} finally {
    if (Test-Path -LiteralPath $workingRoot) {
        Remove-Item -LiteralPath $workingRoot -Recurse -Force
    }
}
