param(
    [string]$Remote = "mac",
    [string]$Branch = "",
    [switch]$AllowDirty,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
        Write-Warning "Dirty worktree allowed explicitly. Git may still refuse the merge."
        return
    }

    $status = Get-GitOutput -Args @("status", "--porcelain")
    if ($status.Length -gt 0) {
        throw "Worktree has uncommitted changes. Commit or stash first, or rerun with -AllowDirty if you know exactly why."
    }
}

function Get-CurrentBranch {
    param()

    $name = Get-GitOutput -Args @("branch", "--show-current")
    if ($name.Length -eq 0) {
        throw "Detached HEAD is not supported for sync_from_mac.ps1."
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

if ($Branch.Length -eq 0) {
    $Branch = Get-CurrentBranch
}

Assert-RemoteExists -Name $Remote
Assert-CleanWorktree

Invoke-Git -Args @("fetch", $Remote)

$remoteRef = "$Remote/$Branch"
if (-not (Test-RemoteBranchExists -RemoteRef $remoteRef)) {
    throw "Remote branch '$remoteRef' does not exist. Push it from Mac or choose -Branch explicitly."
}

$localHead = Get-Commit "HEAD"
$remoteHead = Get-Commit $remoteRef
$mergeBase = Get-GitOutput -Args @("merge-base", "HEAD", $remoteRef)

if ($localHead -eq $remoteHead) {
    Write-Host "Already in sync with $remoteRef."
    exit 0
}

if ($mergeBase -eq $localHead) {
    Invoke-Git -Args @("merge", "--ff-only", $remoteRef)
    if ($DryRun) {
        Write-Host "Would fast-forward from $remoteRef."
    } else {
        Write-Host "Fast-forwarded from $remoteRef."
    }
    exit 0
}

if ($mergeBase -eq $remoteHead) {
    Write-Host "Local branch is ahead of $remoteRef. Nothing to pull from Mac."
    exit 0
}

throw "Local branch and $remoteRef have diverged. Resolve with an explicit rebase or merge; this script will not guess."
