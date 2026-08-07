[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $RuntimeDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runtimeRoot = [IO.Path]::GetFullPath($RuntimeDirectory)
$java = Join-Path $runtimeRoot "runtime\bin\java.exe"
$server = Join-Path $runtimeRoot "m-extension-server.jar"
foreach ($required in @(
    $java,
    $server,
    (Join-Path $runtimeRoot "checksums.json"),
    (Join-Path $runtimeRoot "LICENSE-M-Extension-Server.txt"),
    (Join-Path $runtimeRoot "NOTICE-M-Extension-Server.txt")
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing Mihon desktop runtime asset: $required"
    }
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
$listener.Stop()
$tokenBytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
$token = [Convert]::ToBase64String($tokenBytes).TrimEnd("=")
$dataRoot = Join-Path ([IO.Path]::GetTempPath()) ("hibiki-mihon-smoke-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($dataRoot) | Out-Null

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $java
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.Environment["FUSHI_MIHON_TOKEN"] = $token
$startInfo.ArgumentList.Add("-Xmx512m")
$startInfo.ArgumentList.Add("-Djava.awt.headless=true")
$startInfo.ArgumentList.Add("-Djava.util.prefs.userRoot=$(Join-Path $dataRoot 'preferences')")
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

try {
    $capabilities = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if ($process.HasExited) {
            throw "M-Extension-Server exited before becoming ready."
        }
        try {
            $capabilities = Invoke-RestMethod -Uri "$baseUri/capabilities" -Headers $authenticatedHeaders -TimeoutSec 2
            if (
                $capabilities.hibikiMihonBridge -eq 1 -and
                $capabilities.sourceFactory -eq $true -and
                $capabilities.preferenceCallbacks -eq $true -and
                $capabilities.imageProxy -eq $true -and
                $capabilities.sourceUrls -eq $true
            ) {
                break
            }
        } catch {
            Start-Sleep -Milliseconds 200
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (
        $null -eq $capabilities -or
        $capabilities.hibikiMihonBridge -ne 1 -or
        $capabilities.sourceFactory -ne $true -or
        $capabilities.preferenceCallbacks -ne $true -or
        $capabilities.imageProxy -ne $true -or
        $capabilities.sourceUrls -ne $true
    ) {
        throw "M-Extension-Server did not expose the required bridge capability."
    }

    foreach ($probe in @(
        @{ Method = "GET"; Path = "/" },
        @{ Method = "GET"; Path = "/capabilities" },
        @{ Method = "POST"; Path = "/dalvik" },
        @{ Method = "POST"; Path = "/inspect" },
        @{ Method = "POST"; Path = "/source-image" },
        @{ Method = "POST"; Path = "/source-data/clear" },
        @{ Method = "GET"; Path = "/image/not-registered" },
        @{ Method = "POST"; Path = "/stop" }
    )) {
        $response = Invoke-WebRequest `
            -Uri "$baseUri$($probe.Path)" `
            -Method $probe.Method `
            -ContentType "application/json; charset=utf-8" `
            -Body "{}" `
            -SkipHttpErrorCheck `
            -TimeoutSec 2
        if ($response.StatusCode -ne 401) {
            throw "Unauthenticated $($probe.Path) returned $($response.StatusCode), expected 401."
        }
    }

    $externalAddress = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
        Where-Object {
            $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
            -not [Net.IPAddress]::IsLoopback($_)
        } |
        Select-Object -First 1
    if ($null -ne $externalAddress) {
        $externalProbe = [Net.Sockets.TcpClient]::new()
        try {
            $connect = $externalProbe.ConnectAsync($externalAddress, $port)
            if ($connect.Wait(750) -and $externalProbe.Connected) {
                throw "M-Extension-Server accepted a non-loopback connection on $externalAddress."
            }
        } catch [AggregateException] {
            # Connection refused is the expected loopback-only result.
        } finally {
            $externalProbe.Dispose()
        }
    }

    Invoke-WebRequest `
        -Uri "$baseUri/stop" `
        -Method Post `
        -Headers $authenticatedHeaders `
        -SkipHttpErrorCheck `
        -TimeoutSec 2 | Out-Null
    if (-not $process.WaitForExit(10000)) {
        throw "M-Extension-Server did not exit after authenticated /stop."
    }
    if ($process.ExitCode -ne 0) {
        throw "M-Extension-Server exited with code $($process.ExitCode)."
    }
} finally {
    if (-not $process.HasExited) {
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
