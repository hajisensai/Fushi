#!/usr/bin/env bash
# TODO-705: Publish a mirror update manifest (latest-<channel>.json) to the
# `update-manifest` orphan branch so beta/debug update checks succeed inside
# China (raw.githubusercontent.com is reachable through public gh proxies; the
# api.github.com /releases list is 403'd through every mirror, see BUG-292).
#
# This is a DATA FILE pushed to a git branch, NOT a GitHub Release. It must
# never promote a Latest release / prerelease:false and never call the release
# the release-channel hard rules (CLAUDE.md) say push events only produce
# debug/prerelease/non-Latest artifacts, and `update-manifest` is intentionally
# absent from both release workflows' push trigger branch lists (main/develop
# only), so writing it never cascades a new workflow run.
#
# Required env:
#   CHANNEL           release channel (debug|beta|formal|github-release)
#   TAG               release tag, e.g. v0.10.1-beta.162
#   PRERELEASE        true|false  (echoed verbatim from steps.channel outputs)
#   NOTES             release notes / body
#   RELEASE_SEQUENCE  monotonic git rev-list count (NOT a workflow run-number)
#   VERSION           normalized version (build_version_name)
#   REPO              owner/repo, e.g. hdjsadgfwtg/hibiki
#   GITHUB_TOKEN      token with contents:write on REPO
#   ARTIFACTS_DIR     dir holding the built release assets for THIS platform
#   ASSET_GLOB        glob (relative to ARTIFACTS_DIR) of this platform's assets
#   PLATFORM_LABEL    short label for the commit message (android|desktop)
set -euo pipefail

: "${CHANNEL:?CHANNEL required}"
: "${TAG:?TAG required}"
: "${RELEASE_SEQUENCE:?RELEASE_SEQUENCE required}"
: "${VERSION:?VERSION required}"
: "${REPO:?REPO required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
: "${ARTIFACTS_DIR:?ARTIFACTS_DIR required}"
: "${ASSET_GLOB:?ASSET_GLOB required}"
PRERELEASE="${PRERELEASE:-true}"
NOTES="${NOTES:-}"
PLATFORM_LABEL="${PLATFORM_LABEL:-platform}"

# Map channel -> manifest filename. Only managed channels get a manifest;
# github-release events publish through the Release UI directly and are skipped.
case "$CHANNEL" in
  debug)  MANIFEST_FILE="latest-debug.json" ;;
  beta)   MANIFEST_FILE="latest-beta.json" ;;
  formal) MANIFEST_FILE="latest-stable.json" ;;
  *)
    echo "::notice title=Manifest skipped::channel '$CHANNEL' is not a managed update channel; not writing a manifest."
    exit 0
    ;;
esac

# Collect this platform's assets (name + GitHub release download URL). Build
# numbers / run-numbers are NEVER used to form the URL: the download URL is
# purely releases/download/<tag>/<asset-name>, the path the client expects.
# Expand the glob inside the artifacts dir and take basenames. Using a glob
# loop (not `ls`) keeps names clean: an `ls -F` alias cannot append a classify
# suffix (*, /). CI asset names are controlled (no spaces/newlines), so a
# newline-delimited loop is safe and avoids embedding a NUL in this script.
ASSET_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && ASSET_FILES+=("$f")
done < <(cd "$ARTIFACTS_DIR" && for g in $ASSET_GLOB; do [ -e "$g" ] && basename "$g"; done)
if [ "${#ASSET_FILES[@]}" -eq 0 ]; then
  echo "::error title=No manifest assets::No files matched $ASSET_GLOB in $ARTIFACTS_DIR"
  exit 1
fi

PLATFORM_ASSETS_JSON="$(
  REPO="$REPO" TAG="$TAG" python3 - "${ASSET_FILES[@]}" <<'PY'
import json, os, sys
repo = os.environ["REPO"]
tag = os.environ["TAG"]
base = f"https://github.com/{repo}/releases/download/{tag}"
out = [{"name": name, "browser_download_url": f"{base}/{name}"} for name in sys.argv[1:]]
print(json.dumps(out))
PY
)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Default to the real GitHub remote. MANIFEST_REMOTE_OVERRIDE lets the
# offline race test (hibiki/test/tools/update_manifest_publish_race_test.dart)
# point at a local bare repo; it is never set in CI.
REMOTE="${MANIFEST_REMOTE_OVERRIDE:-https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git}"
git -C "$WORK_DIR" init -q
git -C "$WORK_DIR" remote add origin "$REMOTE"
git -C "$WORK_DIR" config user.name "github-actions[bot]"
git -C "$WORK_DIR" config user.email "github-actions[bot]@users.noreply.github.com"


# Locate the extracted, unit-testable merge step next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_PY="$SCRIPT_DIR/merge_update_manifest.py"
if [ ! -f "$MERGE_PY" ]; then
  echo "::error title=Missing merge step::$MERGE_PY not found"
  exit 1
fi

# Publish loop: ALWAYS merge this platform's assets onto the LIVE remote tip and
# push. On any non-fast-forward rejection (a sibling platform job pushed first)
# re-fetch the new tip and re-merge so the loser preserves the winner's assets.
#
# Race fix (TODO-781): the prior version swallowed `git fetch` errors and fell
# into orphan-branch mode, which would WIPE the other platform's already-pushed
# assets on a transient network blip. Branch existence is now decided
# deterministically with `git ls-remote`: a present branch MUST fetch cleanly
# (network failure -> retry, never orphan); only a genuinely absent branch
# starts an orphan tree.
attempt=0
max_attempts=8
while :; do
  attempt=$((attempt + 1))

  # Does the manifest branch exist on the remote right now? Decide orphan-vs-fetch
  # from this, not from whether a fetch happened to fail.
  branch_exists=0
  if git -C "$WORK_DIR" ls-remote --exit-code --heads origin update-manifest >/dev/null 2>&1; then
    branch_exists=1
  fi

  if [ "$branch_exists" -eq 1 ]; then
    # Branch exists -> we MUST sync onto its live tip. A fetch failure here is a
    # transient error, NOT a signal to orphan; retry without destroying assets.
    if ! git -C "$WORK_DIR" fetch -q origin update-manifest; then
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "::error title=Manifest fetch failed::Could not fetch existing update-manifest after $max_attempts attempts."
        exit 1
      fi
      echo "Fetch of existing update-manifest failed (attempt $attempt); retrying..."
      sleep $((attempt * 3))
      continue
    fi
    git -C "$WORK_DIR" checkout -q -B update-manifest FETCH_HEAD
    git -C "$WORK_DIR" reset -q --hard FETCH_HEAD
  else
    # Branch genuinely absent -> start a fresh orphan tree.
    git -C "$WORK_DIR" checkout -q --orphan update-manifest
    git -C "$WORK_DIR" rm -rfq --cached . 2>/dev/null || true
    find "$WORK_DIR" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +
  fi

  # Merge THIS platform's assets into any existing same-tag manifest (preserve
  # the other platform's assets, dedupe by name). A different (older) tag is
  # fully superseded. Runs inside the branch checkout so the manifest path
  # resolves against the branch tree.
  (
    cd "$WORK_DIR"
    MANIFEST_FILE="$MANIFEST_FILE" \
    CHANNEL="$CHANNEL" TAG="$TAG" VERSION="$VERSION" \
    PRERELEASE="$PRERELEASE" NOTES="$NOTES" \
    RELEASE_SEQUENCE="$RELEASE_SEQUENCE" \
    PLATFORM_ASSETS_JSON="$PLATFORM_ASSETS_JSON" \
    python3 "$MERGE_PY"
  )

  git -C "$WORK_DIR" add "$MANIFEST_FILE"
  if git -C "$WORK_DIR" diff --cached --quiet; then
    echo "Manifest $MANIFEST_FILE already up to date; nothing to push."
    break
  fi

  git -C "$WORK_DIR" commit -q -m "chore(update-manifest): $PLATFORM_LABEL $CHANNEL $TAG (seq $RELEASE_SEQUENCE)"
  if git -C "$WORK_DIR" push -q origin update-manifest; then
    echo "Pushed $MANIFEST_FILE to update-manifest (attempt $attempt)."
    break
  fi

  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "::error title=Manifest push failed::Could not push update-manifest after $max_attempts attempts."
    exit 1
  fi
  # Non-fast-forward: a sibling job pushed first. Drop our commit, loop back to
  # re-fetch the new live tip and re-merge onto it (preserving their assets).
  echo "Push raced/failed (attempt $attempt); re-fetching live tip and re-merging..."
  git -C "$WORK_DIR" reset -q --hard
  sleep $((attempt * 3))
done
