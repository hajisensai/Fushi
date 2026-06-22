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

  # TODO-705: forbid a HARDCODED make_latest:true literal so a push/debug/beta
  # workflow can never promote a Latest release. The legitimate usage is
  # make_latest: ${{ steps.channel.outputs.make_latest }} (template
  # interpolation), which this literal pattern does not match -- it only fires
  # when true is written directly after make_latest:.
  Forbid-Pattern $relativePath $content 'make_latest:\s*true\b' 'a hardcoded make_latest:true would force a Latest release on push/debug/beta; use the channel output (release-channel hard rule)'
}

$androidWorkflow = Read-RepoFile '.github/workflows/release.yml'
# TODO-414: versionCode = build.gradle versionCodeBase + 100 * <build-number> + abiOffset,
# where the build number is JUST the monotonic commit count. The old
# `PUBSPEC_BUILD * 1000000 + seq` build number produced versionCode ~6.6e9
# (overflows int32 / exceeds Android's 2.1e9 ceiling), so the Android build
# number must be the bare release sequence and never multiply by 1000000.
Require-Text '.github/workflows/release.yml' $androidWorkflow 'ANDROID_BUILD_NUMBER=$RELEASE_SEQUENCE' 'Android build number must be the bare monotonic release sequence (versionCode base is applied in build.gradle)'
Forbid-Pattern '.github/workflows/release.yml' $androidWorkflow 'PUBSPEC_BUILD \* 1000000' 'the *1000000 build number overflowed int32 / exceeded Android''s 2.1e9 versionCode ceiling (TODO-414)'

# TODO-705: both release workflows must publish the mirror update manifest
# (latest-<channel>.json on the update-manifest branch) so beta/debug in-China
# update checks succeed (BUG-292). Guard that each consumes the SHARED release
# sequence (never a workflow run_number) and that the manifest step is wired in.
foreach ($relativePath in $workflowPaths) {
  $content = Read-RepoFile $relativePath
  Require-Text $relativePath $content 'tool/publish_update_manifest.sh' 'release workflows must publish the mirror update manifest (TODO-705)'
  Require-Text $relativePath $content 'RELEASE_SEQUENCE: ${{ steps.channel.outputs.release_sequence }}' 'manifest publisher must consume the shared release sequence, not run_number (TODO-705)'
}

$manifestScript = Read-RepoFile 'tool/publish_update_manifest.sh'
Require-Text 'tool/publish_update_manifest.sh' $manifestScript 'releases/download/' 'manifest asset URLs must be releases/download/<tag>/<name> (TODO-705)'
# The manifest is a DATA FILE on a git branch, NOT a GitHub Release: it must
# never invoke the release API nor promote Latest.
Forbid-Pattern 'tool/publish_update_manifest.sh' $manifestScript 'make_latest' 'the mirror manifest is a data file on a git branch, not a GitHub Release; it must never set make_latest (TODO-705)'
Forbid-Pattern 'tool/publish_update_manifest.sh' $manifestScript '\brun_number\b' 'manifest sequence must be the shared git release sequence, never a workflow run_number (TODO-705)'

$buildGradle = Read-RepoFile 'hibiki/android/app/build.gradle'
Require-Text 'hibiki/android/app/build.gradle' $buildGradle 'def versionCodeBase = 1000000000' 'one-time versionCode migration floor must stay above every historically-shipped versionCode (TODO-414)'
Require-Text 'hibiki/android/app/build.gradle' $buildGradle 'def maxVersionCode = 2100000000' 'versionCode ceiling guard must match Android''s 2.1e9 limit (TODO-414)'
Require-Text 'hibiki/android/app/build.gradle' $buildGradle 'output.versionCodeOverride = computed' 'versionCode must be the bounds-checked computed value (TODO-414)'

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
