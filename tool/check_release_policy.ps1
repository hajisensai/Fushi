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
  Require-Text $relativePath $content 'group: fushi-release-${{ github.event.release.tag_name || github.event.inputs.tag_name || github.sha }}' 'same tag/commit publishes serialize instead of racing separate releases'
  Require-Text $relativePath $content 'cancel-in-progress: false' 'Android and desktop publishers both need to complete'
  Require-Text $relativePath $content 'fetch-depth: 0' 'release sequence uses full git history'
  Require-Text $relativePath $content 'RELEASE_SEQUENCE=$(bash tool/release_sequence.sh)' 'release sequence must be shared by Android and desktop workflows'
  # 2026-08-12: 序号不再在 workflow 里算。重写历史会让 rev-list 计数倒退，所以算式加一次性地板，
  # 收进 tool/release_sequence.sh 单一真相源（六处 workflow 不再抄魔数）。
  Require-Text $relativePath $content 'release_sequence=$RELEASE_SEQUENCE' 'build steps must consume the shared release sequence'

  # 裸算式绕过地板：新增一处 rev-list 赋值就足以把序号打回倒退态，
  # 而症状要到用户装不上包、或永远收不到更新时才暴露。
  Forbid-Pattern $relativePath $content 'RELEASE_SEQUENCE=\$\(git rev-list' 'release sequence must go through tool/release_sequence.sh (the one-time floor); a bare rev-list count regresses after any history rewrite'
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
  Require-Text $relativePath $content 'PUBLISH_TAG="$ROLLING_DEBUG_TAG"' 'debug channel PUBLISH_TAG must be the rolling tag so debug prereleases stop accumulating (TODO-1049)'
  Require-Text $relativePath $content 'DOWNLOAD_TAG: ${{ steps.channel.outputs.publish_tag }}' 'manifest publisher must form asset URLs under the actual release tag (publish_tag), not the versioned tag (TODO-1049)'
  Require-Text $relativePath $content 'echo "tag=$TAG"' 'the versioned tag must still be emitted so the manifest `tag` field drives client version comparison (TODO-1049)'
}

# TODO-1049 + BUG-1481: the rolling debug tag used to be asserted as the literal
# `ROLLING_DEBUG_TAG=debug-rolling`. That literal encoded THREE invariants at
# once and BUG-1481 had to change one of them, so assert the invariants directly
# instead of the spelling:
#   1. It is a fixed literal (no seq/sha/expression) -- that is what stops debug
#      builds from piling up one prerelease per push (TODO-1049).
#   2. Android and desktop use the SAME value, so both platforms' assets for one
#      commit land on ONE release. The old literal enforced this by accident;
#      losing it would silently split each debug build across two releases.
#   3. It is product-scoped, i.e. NOT the bare historical `debug-rolling`
#      (BUG-1481). That name is frozen for the `app.hibiki.reader` family; if
#      Fushi took it back, both families' assets would share one release again
#      and the prune step -- which groups candidates by PLATFORM only -- would
#      delete the lower-sequence family's assets on every build.
$rollingTags = @{}
foreach ($relativePath in $workflowPaths) {
  $content = Read-RepoFile $relativePath
  $found = [regex]::Matches($content, 'ROLLING_DEBUG_TAG=(\S+)')
  if ($found.Count -eq 0) {
    $failures.Add("${relativePath}: missing a ROLLING_DEBUG_TAG assignment (the debug channel must publish to one fixed rolling release tag, TODO-1049)")
    continue
  }
  $values = @($found | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  if ($values.Count -ne 1) {
    $failures.Add("${relativePath}: ROLLING_DEBUG_TAG is assigned conflicting values ($($values -join ', ')); all debug jobs in one workflow must publish to the same rolling release (TODO-1049)")
    continue
  }
  $tag = $values[0]
  if ($tag -notmatch '^[A-Za-z0-9._-]+$') {
    $failures.Add("${relativePath}: ROLLING_DEBUG_TAG='$tag' is not a fixed literal; a computed tag reintroduces one prerelease per push (TODO-1049)")
  }
  if (-not $tag.EndsWith('debug-rolling')) {
    $failures.Add("${relativePath}: ROLLING_DEBUG_TAG='$tag' must end with 'debug-rolling' so the rolling debug release stays recognizable (TODO-1049)")
  }
  if ($tag -eq 'debug-rolling') {
    $failures.Add("${relativePath}: ROLLING_DEBUG_TAG='debug-rolling' is frozen for the app.hibiki.reader family; Fushi must use a product-scoped rolling tag or the two families share one release and prune deletes the lower-sequence family (BUG-1481)")
  }
  $rollingTags[$relativePath] = $tag
}
$distinctRollingTags = @($rollingTags.Values | Sort-Object -Unique)
if ($rollingTags.Count -eq $workflowPaths.Count -and $distinctRollingTags.Count -gt 1) {
  $failures.Add(".github/workflows: release.yml and release-desktop.yml disagree on ROLLING_DEBUG_TAG ($($distinctRollingTags -join ' vs ')); Android and desktop must land on the SAME rolling release for one commit (TODO-1049)")
}

$buildGradle = Read-RepoFile 'fushi/android/app/build.gradle'
Require-Text 'fushi/android/app/build.gradle' $buildGradle 'def versionCodeBase = 1000000000' 'one-time versionCode migration floor must stay above every historically-shipped versionCode (TODO-414)'
Require-Text 'fushi/android/app/build.gradle' $buildGradle 'def maxVersionCode = 2100000000' 'versionCode ceiling guard must match Android''s 2.1e9 limit (TODO-414)'
Require-Text 'fushi/android/app/build.gradle' $buildGradle 'output.versionCodeOverride = computed' 'versionCode must be the bounds-checked computed value (TODO-414)'

$desktopWorkflow = Read-RepoFile '.github/workflows/release-desktop.yml'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow '--build-number "${{ steps.channel.outputs.release_sequence }}"' 'desktop build number must use the shared release sequence'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'flutter build windows --release' 'desktop workflow must still publish Windows'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'flutter build macos --release' 'desktop workflow must publish macOS app zips'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'flutter build ios --release --no-codesign' 'desktop workflow must publish unsigned iOS IPA artifacts without requiring Apple signing'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'fushi-*-windows-setup.exe' 'desktop workflow must upload Windows installer assets'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'fushi-*-macos.zip' 'desktop workflow must upload macOS zip assets'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'fushi-*-ios.ipa' 'desktop workflow must upload iOS IPA assets'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'Publish mirror update manifest (Apple assets)' 'Apple release assets must merge into the update manifest'
# Apple 签名链路：细粒度不变式由 fushi/test/tools/apple_signing_workflow_guard_test.dart
# 守（每个 PR 都跑）。这里只锁发布策略层面的那一条 —— TestFlight 上传绝不能挂到 push
# 事件上：push 的 debug 通道每次提交都会跑，每次上传都消耗一个不可回收的构建号
# （同一语义版本下 CFBundleVersion 必须单调递增）。
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow '[ "$GITHUB_EVENT_NAME" = workflow_dispatch ]' 'TestFlight upload must be gated on manual workflow_dispatch; a push-triggered upload burns an unrecoverable build number every commit'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'native/galgame_hook/tools/build_distribution.ps1 -RunTests' 'Windows releases must build the bundled offline galgame helper from the in-tree source'
# BUG-1449: the helper is no longer shipped as zip + sidecar for the runtime to
# unpack -- that layout left a second copy on disk that had to stay in sync with
# the app, and "staying in sync" is exactly what broke in BUG-1448. Both Windows
# workflows now unpack BOTH architectures into the build output at build time via
# the shared install_into_bundle.ps1, so helper and app come out of one build.
# Pin the bundle directory too: the archive-era `<config>\galgame_helper` payload
# check could not tell Release from Debug, and unpacking into the wrong directory
# ships an installer with no helper at all while the build stays green.
# (The anti-regression side -- never copying zips back into galgame_helper/ --
# lives in fushi/test/mining/gal_helper_bundled_as_plain_files_test.dart.)
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'install_into_bundle.ps1 -BundleDirectory "$PWD\fushi\build\windows\x64\runner\Release"' 'Windows release payload must unpack both helper architectures into the packaged Release bundle (BUG-1449)'

$multiplatformWorkflow = Read-RepoFile '.github/workflows/build-multiplatform.yml'
Require-Text '.github/workflows/build-multiplatform.yml' $multiplatformWorkflow 'native/galgame_hook/tools/build_distribution.ps1 -RunTests' 'Windows CI must exercise the same bundled helper build as release'
Require-Text '.github/workflows/build-multiplatform.yml' $multiplatformWorkflow 'install_into_bundle.ps1 -BundleDirectory "$PWD\fushi\build\windows\x64\runner\Debug"' 'Windows debug bundle must exercise the same build-time helper unpack as release (BUG-1449)'

# BUG-1292: Magpie has no download path left, so the bundled slim archive is the
# ONLY way window upscaling can ever install. If a Windows workflow stops
# building or copying it, the build still goes green and every user gets
# "Hibiki installation is incomplete" at runtime -- exactly the class of silent
# packaging regression this guard exists for. Same shape as the helper rules
# above: build step + payload directory, in BOTH Windows workflows.
$magpieBundleWorkflows = @{
  '.github/workflows/release-desktop.yml'    = @{ Content = $desktopWorkflow; Payload = 'Release\magpie_bundle' }
  '.github/workflows/build-multiplatform.yml' = @{ Content = $multiplatformWorkflow; Payload = 'Debug\magpie_bundle' }
}
foreach ($relativePath in $magpieBundleWorkflows.Keys) {
  $entry = $magpieBundleWorkflows[$relativePath]
  $content = $entry.Content
  Require-Text $relativePath $content 'tools/build_magpie_slim.ps1' 'Windows bundles must build the slim Magpie archive from the in-tree script (BUG-1217/BUG-1292)'
  Require-Text $relativePath $content $entry.Payload 'Windows bundle payload must contain magpie_bundle/ or window upscaling can never install (BUG-1292)'
  Require-Text $relativePath $content 'Magpie-hibiki-slim-x64.zip.sha256' 'the bundled Magpie archive must ship with its sha256 sidecar; the installer refuses an unverified package (BUG-1292)'
}

$buildDoc = Read-RepoFile 'docs/agent/build.md'
Require-Text 'docs/agent/build.md' $buildDoc 'cross-workflow release sequence' 'durable docs must describe the shared sequence rule'
Require-Text 'docs/agent/build.md' $buildDoc 'git rev-list --count HEAD' 'durable docs must name the sequence source'
Require-Text 'docs/agent/build.md' $buildDoc 'single GitHub Release' 'durable docs must state Android and desktop assets merge'

if ($failures.Count -gt 0) {
  Write-Error ("Release policy guard failed:`n- " + ($failures -join "`n- "))
  exit 1
}

Write-Host 'Release policy guard passed.'
