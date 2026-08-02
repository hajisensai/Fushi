[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,
    [string] $DownloadCache = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# 上游 miru-project/M-Extension-Server 已从 GitHub 消失（404），原先的 `git clone`
# 会转去交互取凭据并以 exit 128 挂掉整个 job。源码按 MPL-2.0 vendored 进
# third_party/m_extension_server/upstream_src/，构建从本地树取，不再依赖外部仓库。
$serverCommit = "ee55c65106bb18bf81a5ddc660d321b4e14ea2f9"
# 上游 server/build.gradle.kts 用 `git rev-list HEAD --count` 生成 revision，
# vendored 树没有 .git 会退化成空串。走上游自带的 ProductRevision 钩子把它钉成
# 被 vendor 的 commit 短 SHA，产物名与 manifest 因此直接指向真相源。
$serverRevision = $serverCommit.Substring(0, 7)
$temurinVersion = "jdk-21.0.11+10"
$temurinArchive = "OpenJDK21U-jdk_x64_windows_hotspot_21.0.11_10.zip"
$temurinSha256 = "d3625e7cadf23787ea540229544b6e2ab494b3b54da1801879e583e1dfee0a64"
$temurinUrl = "https://github.com/adoptium/temurin21-binaries/releases/download/$($temurinVersion.Replace('+', '%2B'))/$temurinArchive"

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$overlayRoot = Join-Path $repositoryRoot "third_party\m_extension_server"
$vendoredSourceRoot = Join-Path $overlayRoot "upstream_src"
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

function Copy-Tree {
    param([string] $From, [string] $To)
    # -Force：vendored 树里有 .gitattributes / .gitignore / .github 这类点开头
    # 的条目，缺了它 Get-ChildItem 会静默漏掉隐藏项。
    Get-ChildItem -LiteralPath $From -Recurse -File -Force | ForEach-Object {
        $relativePath = [IO.Path]::GetRelativePath($From, $_.FullName)
        $destination = Join-Path $To $relativePath
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
    }
}

try {
    if (-not (Test-Path -LiteralPath (Join-Path $vendoredSourceRoot "settings.gradle.kts") -PathType Leaf)) {
        throw "Vendored M-Extension-Server source is missing at $vendoredSourceRoot"
    }
    [IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
    Copy-Tree $vendoredSourceRoot $sourceRoot

    # `git apply` 在非 git 目录下同样可用（实测 exit 0），补丁与 overlay 的应用
    # 顺序和语义与 clone 时代完全一致：先打 build/上游逻辑补丁，再用 Hibiki 的
    # 安全 overlay 覆盖同名文件。
    Invoke-Checked -Executable git -Arguments @(
        "-C",
        $sourceRoot,
        "apply",
        "--unidiff-zero",
        (Join-Path $overlayRoot "server-build.gradle.patch")
    )
    Copy-Tree (Join-Path $overlayRoot "overlay") $sourceRoot

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
    $previousProductRevision = $env:ProductRevision
    try {
        $env:JAVA_HOME = $jdkRoot.FullName
        $env:ProductRevision = $serverRevision
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
        if ($null -eq $previousProductRevision) {
            Remove-Item Env:ProductRevision -ErrorAction SilentlyContinue
        } else {
            $env:ProductRevision = $previousProductRevision
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
