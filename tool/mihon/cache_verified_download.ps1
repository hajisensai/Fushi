[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Uri,
    [Parameter(Mandatory = $true)][string] $Destination,
    [Parameter(Mandatory = $true)][string] $Sha256,
    [int] $LockTimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$destinationPath = [IO.Path]::GetFullPath($Destination)
$destinationDirectory = [IO.Path]::GetDirectoryName($destinationPath)
if ([string]::IsNullOrWhiteSpace($destinationDirectory)) {
    throw "Verified download destination must have a parent directory."
}
[IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
$expectedSha256 = $Sha256.ToLowerInvariant()
$archiveLockPath = "$destinationPath.lock"
$deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
$lockStream = $null

function Test-ExpectedHash {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actual -eq $expectedSha256
}

try {
    while ($null -eq $lockStream) {
        try {
            $lockStream = [IO.File]::Open(
                $archiveLockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Timed out waiting for verified download lock: $archiveLockPath"
            }
            Start-Sleep -Milliseconds 100
        }
    }

    if (Test-ExpectedHash -Path $destinationPath) {
        return
    }

    Get-ChildItem -LiteralPath $destinationDirectory `
        -Filter "$([IO.Path]::GetFileName($destinationPath)).tmp-*" `
        -File -ErrorAction SilentlyContinue |
        Remove-Item -Force

    $downloadTmp = "$destinationPath.tmp-$([Guid]::NewGuid().ToString("N"))"
    $reservation = [IO.File]::Open(
        $downloadTmp,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $reservation.Dispose()
    try {
        $testDelay = $env:HIBIKI_MIHON_DOWNLOAD_TEST_DELAY_MS
        if (-not [string]::IsNullOrWhiteSpace($testDelay)) {
            Start-Sleep -Milliseconds ([int] $testDelay)
        }
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $downloadTmp
        $actualSha256 = (
            Get-FileHash -LiteralPath $downloadTmp -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($actualSha256 -ne $expectedSha256) {
            throw "Downloaded file checksum mismatch: expected $expectedSha256, got $actualSha256"
        }
        if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
            $backupPath = "$destinationPath.backup-$([Guid]::NewGuid().ToString("N"))"
            try {
                [IO.File]::Replace(
                    $downloadTmp,
                    $destinationPath,
                    $backupPath,
                    $true
                )
            } finally {
                if (Test-Path -LiteralPath $backupPath) {
                    Remove-Item -LiteralPath $backupPath -Force
                }
            }
        } else {
            [IO.File]::Move($downloadTmp, $destinationPath)
        }
    } finally {
        if (Test-Path -LiteralPath $downloadTmp) {
            Remove-Item -LiteralPath $downloadTmp -Force
        }
    }
} finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}
