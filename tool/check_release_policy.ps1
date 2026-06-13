[CmdletBinding()]
param(
  [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Read-RepoFile {
  param([Parameter(Mandatory = $true)][string]$RelativePath)

  $path = Join-Path $RepoRoot $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing required file: $RelativePath"
  }
  return Get-Content -LiteralPath $path -Raw -Encoding UTF8
}

$failures = [System.Collections.Generic.List[string]]::new()

function Require-Text {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Needle,
    [Parameter(Mandatory = $true)][string]$Reason
  )

  if (-not $Content.Contains($Needle)) {
    $failures.Add("${RelativePath}: missing '$Needle' ($Reason)")
  }
}

function Forbid-Pattern {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Reason
  )

  if ($Content -match $Pattern) {
    $failures.Add("${RelativePath}: forbidden pattern '$Pattern' ($Reason)")
  }
}

$workflowPaths = @(
  '.github/workflows/release.yml',
  '.github/workflows/release-desktop.yml'
)

foreach ($relativePath in $workflowPaths) {
  $content = Read-RepoFile $relativePath

  Require-Text $relativePath $content 'concurrency:' 'release publishers must share a cross-workflow lock'
  Require-Text $relativePath $content 'group: hibiki-release-${{ github.event.release.tag_name || github.event.inputs.tag_name || github.sha }}' 'same tag/commit publishes serialize instead of racing separate releases'
  Require-Text $relativePath $content 'cancel-in-progress: false' 'Android and desktop publishers both need to complete'
  Require-Text $relativePath $content 'fetch-depth: 0' 'release sequence uses full git history'
  Require-Text $relativePath $content 'RELEASE_SEQUENCE=$(git rev-list --count HEAD)' 'release sequence must be shared by Android and desktop workflows'
  Require-Text $relativePath $content 'release_sequence=$RELEASE_SEQUENCE' 'build steps must consume the shared release sequence'

  Forbid-Pattern $relativePath $content '\bGITHUB_RUN_NUMBER\b' 'workflow-local run_number splits same-version Android and desktop releases'
  Forbid-Pattern $relativePath $content 'github\.run_number' 'workflow-local run_number splits build numbers across release workflows'
}

$androidWorkflow = Read-RepoFile '.github/workflows/release.yml'
Require-Text '.github/workflows/release.yml' $androidWorkflow 'ANDROID_BUILD_NUMBER=$((PUBSPEC_BUILD * 1000000 + RELEASE_SEQUENCE))' 'Android versionCode must use the shared release sequence'

$desktopWorkflow = Read-RepoFile '.github/workflows/release-desktop.yml'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow '--build-number "${{ steps.channel.outputs.release_sequence }}"' 'desktop build number must use the shared release sequence'

$buildDoc = Read-RepoFile 'docs/agent/build.md'
Require-Text 'docs/agent/build.md' $buildDoc 'cross-workflow release sequence' 'durable docs must describe the shared sequence rule'
Require-Text 'docs/agent/build.md' $buildDoc 'git rev-list --count HEAD' 'durable docs must name the sequence source'
Require-Text 'docs/agent/build.md' $buildDoc 'single GitHub Release' 'durable docs must state Android and desktop assets merge'

if ($failures.Count -gt 0) {
  Write-Error ("Release policy guard failed:`n- " + ($failures -join "`n- "))
  exit 1
}

Write-Host 'Release policy guard passed.'
