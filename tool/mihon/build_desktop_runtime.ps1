[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
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
$gradleVersion = "9.2.1"

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$overlayRoot = Join-Path $repositoryRoot "third_party\m_extension_server"
$vendoredSourceRoot = Join-Path $overlayRoot "upstream_src"
# 离线构建包（third_party/mihon_build/README.md）：JDK 归档、Gradle 发行包、Gradle 依赖缓存都是
# tool/vendored_binaries.json 钉住的 vendored 件，构建期不连 adoptium / services.gradle.org /
# Maven Central（2026-11-27 发版时 Maven Central 回 429 把 Linux 构建弄红，三端同一做法）。
$offlineKit = Join-Path $repositoryRoot "third_party\mihon_build"
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
if ([IO.Path]::GetPathRoot($resolvedOutput) -eq $resolvedOutput) {
    throw "Refusing to write a desktop runtime to a filesystem root."
}

$workingRoot = Join-Path ([IO.Path]::GetTempPath()) ("fushi-mihon-build-" + [Guid]::NewGuid().ToString("N"))
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
    # [IO.Path]::GetRelativePath 只存在于 .NET Core/5+；Windows PowerShell 5.1
    # 跑在 .NET Framework 上会 MethodNotFound 直接中断构建。用根前缀裁剪算相对
    # 路径，pwsh 7 与 5.1 行为一致。
    $fromRoot = [IO.Path]::GetFullPath($From).TrimEnd([IO.Path]::DirectorySeparatorChar)
    Get-ChildItem -LiteralPath $From -Recurse -File -Force | ForEach-Object {
        $relativePath = [IO.Path]::GetFullPath($_.FullName).Substring($fromRoot.Length).TrimStart(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
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
    # 顺序和语义与 clone 时代完全一致：先打 build/上游逻辑补丁，再用 Fushi 的
    # 安全 overlay 覆盖同名文件。
    #
    # 补丁必须带上下文，这里也**绝不能**加回 `--unidiff-zero`（BUG-1428）：零上下文
    # 补丁里纯插入的 hunk 没有任何可校验的内容，`git apply --check` 对上游漂移
    # exit 0，真 apply 时按行号把新代码盲插到错误位置（实测 JGroupFilter 的
    # `stateString` 字段被插到 `name` 与 `type` 之间——data class 的字段顺序是位置
    # 语义，编译照过、行为已错）。带上下文之后，上游只是整体位移则 git 自动重定位，
    # 内容真变了就硬失败。
    Invoke-Checked -Executable git -Arguments @(
        "-C",
        $sourceRoot,
        "apply",
        (Join-Path $overlayRoot "server-build.gradle.patch")
    )
    Copy-Tree (Join-Path $overlayRoot "overlay") $sourceRoot

    # 把 vendored 的 org.jogamp 离线 Maven 仓库搬进构建树。补丁后的 build.gradle.kts
    # 用 `rootProject.file("fushi-offline-maven/jogamp")` 找它，目录在就离线解析、
    # 不在就回落到两个远端镜像（见 third_party/jogamp/UPSTREAM：那两个主机分别在
    # 2026-08-09 和 2026-08-25 把 CI 弄红过，而 Maven Central 根本没有 2.5.0）。
    # 路径必须与补丁里的字面量一致，守卫 fushi/test/build/mihon_vendored_jogamp_guard_test.dart。
    $jogampRepo = Join-Path $repositoryRoot "third_party\jogamp"
    if (-not (Test-Path -LiteralPath (Join-Path $jogampRepo "org\jogamp\jogl\jogl-all\2.5.0\jogl-all-2.5.0.jar") -PathType Leaf)) {
        throw "Vendored org.jogamp repository is missing at $jogampRepo"
    }
    Copy-Tree (Join-Path $jogampRepo "org") (Join-Path $sourceRoot "fushi-offline-maven\jogamp\org")

    # 构建用到的离线件一次取齐（已在盘上且哈希对得上就只算一遍 sha256；CI 由
    # .github/actions/fetch-vendored-binaries 预先放好，这里只是校验）。
    $python = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { "python" }
    Invoke-Checked -Executable $python -Arguments @(
        (Join-Path $repositoryRoot "tool\vendored_binaries.py"),
        "fetch", "--group", "mihon-build", "--group", "mihon-jdk-windows-x64"
    )
    $archivePath = Join-Path $offlineKit "jdk\$temurinArchive"
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
    #
    # Gradle 发行包直接解开用（不走 gradlew.bat：wrapper 会去 services.gradle.org 下发行包）。
    # 依赖只从 vendored 的只读依赖缓存取（Gradle 官方的 GRADLE_RO_DEP_CACHE：目录下是一份
    # caches/modules-2 拷贝），GRADLE_USER_HOME 每次全新、--offline 禁止任何远端解析：缓存缺件
    # 就当场红并点名缺的坐标，而不是悄悄联网。依赖变了按 third_party/mihon_build/README.md 重新打包。
    # FUSHI_MIHON_GRADLE_ONLINE_HOME 只给重新打包用：指向一个空目录时联网解析并把缓存留在那里。
    $gradleRoot = Join-Path $workingRoot "gradle-dist"
    Expand-Archive -LiteralPath (Join-Path $offlineKit "gradle-$gradleVersion-bin.zip") -DestinationPath $gradleRoot
    $gradleLauncher = Join-Path $gradleRoot "gradle-$gradleVersion\bin\gradle.bat"
    $gradleArguments = @("-p", $sourceRoot, ":server:test", ":server:shadowJar", "--no-daemon")
    $onlineHome = $env:FUSHI_MIHON_GRADLE_ONLINE_HOME
    $savedEnvironment = @{}
    foreach ($name in @("JAVA_HOME", "ProductRevision", "GRADLE_USER_HOME", "GRADLE_RO_DEP_CACHE")) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    try {
        $env:JAVA_HOME = $jdkRoot.FullName
        $env:ProductRevision = $serverRevision
        if (-not [string]::IsNullOrWhiteSpace($onlineHome)) {
            [IO.Directory]::CreateDirectory($onlineHome) | Out-Null
            $env:GRADLE_USER_HOME = $onlineHome
            Remove-Item Env:GRADLE_RO_DEP_CACHE -ErrorAction SilentlyContinue
        } else {
            $roDepCache = Join-Path $workingRoot "gradle-ro-dep-cache"
            [IO.Directory]::CreateDirectory($roDepCache) | Out-Null
            # Windows 10+ 自带 bsdtar（System32\tar.exe），认 .tar.gz。写全路径：从 Git Bash /
            # CI 的 bash 步骤起的进程 PATH 里排在前面的是 Git 的 GNU tar，它把 `D:\...` 的盘符
            # 当远程主机名（"Cannot connect to D: resolve failed"）。
            $systemTar = Join-Path $env:SystemRoot "System32\tar.exe"
            Invoke-Checked -Executable $systemTar -Arguments @(
                "-xzf", (Join-Path $offlineKit "gradle-ro-dep-cache.tar.gz"), "-C", $roDepCache
            )
            $env:GRADLE_USER_HOME = Join-Path $workingRoot "gradle-home"
            $env:GRADLE_RO_DEP_CACHE = $roDepCache
            $gradleArguments += "--offline"
        }
        Invoke-Checked -Executable $gradleLauncher -Arguments $gradleArguments
    } finally {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], "Process")
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
    # -Encoding utf8NoBOM 是 pwsh 6+ 独有的值，5.1 只认 utf8（带 BOM）并会报
    # ParameterArgumentValidationError。直接用 .NET 写无 BOM UTF-8，两个 shell 同结果。
    [IO.File]::WriteAllText(
        (Join-Path $stagingRoot "checksums.json"),
        ($checksums | ConvertTo-Json -Depth 4),
        (New-Object Text.UTF8Encoding($false)))

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
