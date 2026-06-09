param(
    [string]$Remote = "mac",
    [string]$Branch = "",
    [switch]$AllowDirty,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    if ($DryRun) {
        Write-Host ("git " + ($Args -join " "))
        return @()
    }

    $output = & git @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }
    return @($output)
}

function Get-GitOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $output = & git @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Assert-CleanWorktree {
    param()

    if ($AllowDirty) {
        Write-Warning "Dirty worktree allowed explicitly. Pushing uncommitted files is impossible; only commits are pushed."
        return
    }

    $status = Get-GitOutput -Args @("status", "--porcelain")
    if ($status.Length -gt 0) {
        throw "Worktree has uncommitted changes. Commit or stash first, or rerun with -AllowDirty if you only want to push existing commits."
    }
}

function Get-CurrentBranch {
    param()

    $name = Get-GitOutput -Args @("branch", "--show-current")
    if ($name.Length -eq 0) {
        throw "Detached HEAD is not supported for sync_to_mac.ps1."
    }
    return $name
}

function Assert-RemoteExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $remotes = Get-GitOutput -Args @("remote")
    if (($remotes -split "\r?\n") -notcontains $Name) {
        throw "Git remote '$Name' is not configured."
    }
}

function Get-Commit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Rev
    )

    return Get-GitOutput -Args @("rev-parse", "--verify", $Rev)
}

function Test-RemoteBranchExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteRef
    )

    & git rev-parse --verify --quiet $RemoteRef *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-GitRefExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ref
    )

    & git rev-parse --verify --quiet $Ref *> $null
    return ($LASTEXITCODE -eq 0)
}

function Normalize-RepoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return $Path.Replace("\", "/").Trim().TrimStart("./")
}

function Get-SyncUploadExclusions {
    param()

    $file = Join-Path $PSScriptRoot "sync_upload_exclusions.txt"
    if (-not (Test-Path -LiteralPath $file)) {
        return @()
    }

    $paths = @()
    foreach ($line in Get-Content -LiteralPath $file -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
            continue
        }
        $paths += (Normalize-RepoPath -Path $trimmed)
    }
    return $paths
}

function Get-ChangedPathsForPush {
    param(
        [string]$BaseRef = ""
    )

    if ($BaseRef.Length -gt 0) {
        $output = Get-GitOutput -Args @(
            "-c",
            "core.quotepath=false",
            "diff",
            "--name-only",
            "--diff-filter=ACDMRTUXB",
            "$BaseRef..HEAD"
        )
    } else {
        $output = Get-GitOutput -Args @(
            "-c",
            "core.quotepath=false",
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            "--root",
            "HEAD"
        )
    }
    if ($output.Length -eq 0) {
        return @()
    }
    return @($output -split "\r?\n" | ForEach-Object { Normalize-RepoPath -Path $_ })
}

function Get-CreateBranchComparisonBase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Remote
    )

    $candidates = @(
        "$Remote/develop",
        "$Remote/main",
        "$Remote/master",
        "origin/develop",
        "origin/main",
        "origin/master"
    )
    foreach ($candidate in $candidates) {
        if (Test-GitRefExists -Ref $candidate) {
            return $candidate
        }
    }

    if (Test-GitRefExists -Ref "HEAD^") {
        return "HEAD^"
    }

    return ""
}

function Assert-NoExcludedUploadChanges {
    param(
        [string]$BaseRef = ""
    )

    $exclusions = @(Get-SyncUploadExclusions)
    if ($exclusions.Count -eq 0) {
        return
    }

    $changed = @(Get-ChangedPathsForPush -BaseRef $BaseRef)
    $blocked = @()
    foreach ($path in $changed) {
        foreach ($excluded in $exclusions) {
            if ($path.Equals($excluded, [StringComparison]::OrdinalIgnoreCase) -or
                $path.StartsWith("$excluded/", [StringComparison]::OrdinalIgnoreCase)) {
                $blocked += $path
                break
            }
        }
    }

    if ($blocked.Count -gt 0) {
        $items = ($blocked | Sort-Object -Unique | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw "Changes touch paths excluded from Mac upload:$([Environment]::NewLine)$items$([Environment]::NewLine)Remove those path changes from the commits before running sync_to_mac.ps1."
    }
}

if ($Branch.Length -eq 0) {
    $Branch = Get-CurrentBranch
}

Assert-RemoteExists -Name $Remote
Assert-CleanWorktree

Invoke-Git -Args @("fetch", $Remote)

$remoteRef = "$Remote/$Branch"
if (-not (Test-RemoteBranchExists -RemoteRef $remoteRef)) {
    $createBaseRef = Get-CreateBranchComparisonBase -Remote $Remote
    Assert-NoExcludedUploadChanges -BaseRef $createBaseRef
    Invoke-Git -Args @("push", $Remote, "HEAD:$Branch")
    if ($DryRun) {
        Write-Host "Would create $remoteRef from local HEAD."
    } else {
        Write-Host "Created $remoteRef from local HEAD."
    }
    exit 0
}

$localHead = Get-Commit "HEAD"
$remoteHead = Get-Commit $remoteRef
$mergeBase = Get-GitOutput -Args @("merge-base", "HEAD", $remoteRef)

if ($localHead -eq $remoteHead) {
    Write-Host "Already in sync with $remoteRef."
    exit 0
}

if ($mergeBase -eq $remoteHead) {
    Assert-NoExcludedUploadChanges -BaseRef $remoteRef
    Invoke-Git -Args @("push", $Remote, "HEAD:$Branch")
    if ($DryRun) {
        Write-Host "Would push local commits to $remoteRef."
    } else {
        Write-Host "Pushed local commits to $remoteRef."
    }
    exit 0
}

if ($mergeBase -eq $localHead) {
    throw "Local branch is behind $remoteRef. Run tool/sync_from_mac.ps1 first."
}

throw "Local branch and $remoteRef have diverged. Resolve with an explicit rebase or merge; this script will not guess."
