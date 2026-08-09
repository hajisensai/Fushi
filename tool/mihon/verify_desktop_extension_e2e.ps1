[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $RuntimeDirectory,

    [Parameter(Mandatory = $true)]
    [string] $ApkPath,

    [string] $Language = "en",

    [string] $Search = "Frieren"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runtimeRoot = [IO.Path]::GetFullPath($RuntimeDirectory)
$extensionApk = [IO.Path]::GetFullPath($ApkPath)
$java = Join-Path $runtimeRoot "runtime\bin\java.exe"
$server = Join-Path $runtimeRoot "m-extension-server.jar"
foreach ($required in @($java, $server, $extensionApk)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing Mihon E2E asset: $required"
    }
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
$listener.Stop()

$tokenBytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
$token = [Convert]::ToBase64String($tokenBytes).TrimEnd("=")
$dataRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ("hibiki-mihon-extension-e2e-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($dataRoot) | Out-Null

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $java
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.Environment["FUSHI_MIHON_TOKEN"] = $token
$startInfo.ArgumentList.Add("-Xmx768m")
$startInfo.ArgumentList.Add("-Djava.awt.headless=true")
$startInfo.ArgumentList.Add(
    "-Djava.util.prefs.userRoot=$(Join-Path $dataRoot 'preferences')"
)
$startInfo.ArgumentList.Add("-jar")
$startInfo.ArgumentList.Add($server)
$startInfo.ArgumentList.Add("$port")
$startInfo.ArgumentList.Add($dataRoot)

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) {
    throw "Failed to start the bundled M-Extension-Server."
}
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$baseUri = "http://127.0.0.1:$port"
$authenticatedHeaders = @{ Authorization = "Bearer $token" }

function Invoke-MihonJson {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [hashtable] $Payload,

        [int] $TimeoutSeconds = 120
    )

    $response = Invoke-WebRequest `
        -Uri "$baseUri$Path" `
        -Method Post `
        -Headers $authenticatedHeaders `
        -ContentType "application/json; charset=utf-8" `
        -Body ($Payload | ConvertTo-Json -Depth 40 -Compress) `
        -SkipHttpErrorCheck `
        -TimeoutSec $TimeoutSeconds
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "$Path returned HTTP $($response.StatusCode): $($response.Content)"
    }
    return $response.Content | ConvertFrom-Json
}

try {
    $capabilities = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if ($process.HasExited) {
            throw "M-Extension-Server exited before becoming ready."
        }
        try {
            $capabilities = Invoke-RestMethod `
                -Uri "$baseUri/capabilities" `
                -Headers $authenticatedHeaders `
                -TimeoutSec 2
            break
        } catch {
            Start-Sleep -Milliseconds 200
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -eq $capabilities -or $capabilities.fushiMihonBridge -ne 1) {
        throw "M-Extension-Server did not expose the required capability."
    }

    $apkData = [Convert]::ToBase64String(
        [IO.File]::ReadAllBytes($extensionApk)
    )
    $inspection = Invoke-MihonJson `
        -Path "/inspect" `
        -Payload @{ data = $apkData }
    $sources = @(
        Invoke-MihonJson `
            -Path "/dalvik" `
            -Payload @{ data = $apkData; method = "sourcesManga" }
    )
    $source = $sources |
        Where-Object { $_.lang -eq $Language } |
        Select-Object -First 1
    if ($null -eq $source) {
        throw "Extension does not expose a '$Language' manga source."
    }
    $preferences = @(
        @{
            key = "__mangatan_bridge_context__"
            sourceId = [string] $source.id
        }
    )

    $popular = Invoke-MihonJson `
        -Path "/dalvik" `
        -Payload @{
            data = $apkData
            method = "getPopularManga"
            page = 1
            preferences = $preferences
        }
    if (@($popular.mangas).Count -eq 0) {
        throw "Popular browsing returned no manga."
    }

    $searchResult = Invoke-MihonJson `
        -Path "/dalvik" `
        -Payload @{
            data = $apkData
            method = "getSearchManga"
            page = 1
            search = $Search
            filterList = @()
            preferences = $preferences
        }
    $details = $null
    $chapters = @()
    $candidateManga = @(
        @($searchResult.mangas)
        @($popular.mangas)
    ) |
        Group-Object -Property url |
        ForEach-Object { $_.Group[0] } |
        Select-Object -First 8
    foreach ($manga in $candidateManga) {
        try {
            $candidateDetails = Invoke-MihonJson `
                -Path "/dalvik" `
                -Payload @{
                    data = $apkData
                    method = "getDetailsManga"
                    mangaData = $manga
                    preferences = $preferences
                }
            $candidateChapters = @(
                Invoke-MihonJson `
                    -Path "/dalvik" `
                    -Payload @{
                        data = $apkData
                        method = "getChapterList"
                        mangaData = $candidateDetails
                        preferences = $preferences
                    }
            )
            if ($candidateChapters.Count -gt 0) {
                $details = $candidateDetails
                $chapters = $candidateChapters
                break
            }
        } catch {
            Write-Verbose "Skipping manga '$($manga.title)': $_"
        }
    }
    if ($null -eq $details -or $chapters.Count -eq 0) {
        throw "Chapter browsing returned no chapters for the first eight manga."
    }

    $pages = $null
    $selectedChapter = $null
    foreach ($chapter in ($chapters | Select-Object -First 8)) {
        try {
            $candidatePages = @(
                Invoke-MihonJson `
                    -Path "/dalvik" `
                    -Payload @{
                        data = $apkData
                        method = "getPageList"
                        chapterData = $chapter
                        preferences = $preferences
                    } `
                    -TimeoutSeconds 180
            )
            if ($candidatePages.Count -gt 0) {
                $pages = $candidatePages
                $selectedChapter = $chapter
                break
            }
        } catch {
            Write-Verbose "Skipping unreadable chapter '$($chapter.name)': $_"
        }
    }
    if ($null -eq $pages -or $pages.Count -eq 0) {
        throw "No readable chapter was found in the first eight results."
    }

    $image = Invoke-WebRequest `
        -Uri ([string] $pages[0].imageUrl) `
        -Headers $authenticatedHeaders `
        -SkipHttpErrorCheck `
        -TimeoutSec 120
    if ($image.StatusCode -ne 200 -or $image.RawContentLength -le 0) {
        throw "The authenticated image proxy returned HTTP $($image.StatusCode)."
    }

    [pscustomobject] @{
        Package = $inspection.packageName
        Library = $inspection.libVersion
        SourceCount = $sources.Count
        SourceId = [string] $source.id
        PopularCount = @($popular.mangas).Count
        SearchCount = @($searchResult.mangas).Count
        Title = [string] $details.title
        ChapterCount = $chapters.Count
        Chapter = [string] $selectedChapter.name
        PageCount = $pages.Count
        ImageBytes = $image.RawContentLength
        ImageContentType = $image.Headers."Content-Type"
    }
} finally {
    try {
        Invoke-WebRequest `
            -Uri "$baseUri/stop" `
            -Method Post `
            -Headers $authenticatedHeaders `
            -SkipHttpErrorCheck `
            -TimeoutSec 2 | Out-Null
    } catch {
        Write-Verbose "Graceful sidecar stop failed: $_"
    }
    if (-not $process.WaitForExit(10000)) {
        $process.Kill($true)
        $process.WaitForExit(5000) | Out-Null
    }
    $serverOutput = $stdoutTask.GetAwaiter().GetResult()
    $serverError = $stderrTask.GetAwaiter().GetResult()
    if ($serverOutput) { Write-Verbose $serverOutput }
    if ($serverError) { Write-Verbose $serverError }
    $process.Dispose()
    if (Test-Path -LiteralPath $dataRoot) {
        Remove-Item -LiteralPath $dataRoot -Recurse -Force
    }
}
