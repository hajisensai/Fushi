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

# TODO-1049: the debug channel publishes to ONE fixed rolling GitHub Release
# tag (`debug-rolling`) so debug builds no longer pile up one prerelease per
# push. Guard the invariants that keep this safe AND keep the client update
# check working:
#   1. Both workflows publish the managed release under `publish_tag`
#      (the actual git tag: `debug-rolling` for debug, the version tag
#      otherwise) -- NOT the raw versioned `tag`.
#   2. The debug channel maps PUBLISH_TAG to the fixed rolling tag.
#   3. Asset download URLs resolve under DOWNLOAD_TAG = publish_tag, while the
#      manifest's `tag` field still carries the versioned/seq `tag` output the
#      client compares. This decoupling in publish_update_manifest.sh is what
#      lets one rolling release coexist with a monotonically advancing manifest.
#   4. The rolling debug tag must still be prerelease + non-Latest (no hardcoded
#      make_latest:true -- already forbidden above, re-stated here for the tag).
Require-Text 'tool/publish_update_manifest.sh' $manifestScript 'DOWNLOAD_TAG' 'manifest download URLs must resolve under the actual release tag (DOWNLOAD_TAG), decoupled from the versioned manifest tag (TODO-1049)'
foreach ($relativePath in $workflowPaths) {
  $content = Read-RepoFile $relativePath
  Require-Text $relativePath $content 'tag_name: ${{ steps.channel.outputs.publish_tag }}' 'the managed release must publish under publish_tag (rolling `debug-rolling` for debug), not the versioned tag (TODO-1049)'
  Require-Text $relativePath $content 'ROLLING_DEBUG_TAG=debug-rolling' 'the debug channel must publish to the fixed rolling release tag `debug-rolling` (TODO-1049)'
  Require-Text $relativePath $content 'PUBLISH_TAG="$ROLLING_DEBUG_TAG"' 'debug channel PUBLISH_TAG must be the rolling tag so debug prereleases stop accumulating (TODO-1049)'
  Require-Text $relativePath $content 'DOWNLOAD_TAG: ${{ steps.channel.outputs.publish_tag }}' 'manifest publisher must form asset URLs under the actual release tag (publish_tag), not the versioned tag (TODO-1049)'
  Require-Text $relativePath $content 'echo "tag=$TAG"' 'the versioned tag must still be emitted so the manifest `tag` field drives client version comparison (TODO-1049)'
}

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
