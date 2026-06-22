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

REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git"
git -C "$WORK_DIR" init -q
git -C "$WORK_DIR" remote add origin "$REMOTE"
git -C "$WORK_DIR" config user.name "github-actions[bot]"
git -C "$WORK_DIR" config user.email "github-actions[bot]@users.noreply.github.com"

attempt=0
max_attempts=5
while :; do
  attempt=$((attempt + 1))

  # Fetch the existing manifest branch if present; otherwise start an orphan.
  if git -C "$WORK_DIR" fetch -q origin update-manifest 2>/dev/null; then
    git -C "$WORK_DIR" checkout -q -B update-manifest FETCH_HEAD
  else
    git -C "$WORK_DIR" checkout -q --orphan update-manifest
    git -C "$WORK_DIR" rm -rfq --cached . 2>/dev/null || true
    find "$WORK_DIR" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +
  fi

  # Merge THIS platform's assets into any existing manifest for the same tag
  # (preserve the other platform's assets), then rewrite the file. Runs inside
  # the branch checkout so the manifest path resolves against the branch tree.
  (
    cd "$WORK_DIR"
    MANIFEST_FILE="$MANIFEST_FILE" \
    CHANNEL="$CHANNEL" TAG="$TAG" VERSION="$VERSION" \
    PRERELEASE="$PRERELEASE" NOTES="$NOTES" \
    RELEASE_SEQUENCE="$RELEASE_SEQUENCE" \
    PLATFORM_ASSETS_JSON="$PLATFORM_ASSETS_JSON" \
    python3 - <<'PY'
import json, os

path = os.environ["MANIFEST_FILE"]
tag = os.environ["TAG"]
channel = os.environ["CHANNEL"]
version = os.environ["VERSION"]
prerelease = os.environ["PRERELEASE"].strip().lower() == "true"
notes = os.environ["NOTES"]
release_sequence = os.environ["RELEASE_SEQUENCE"]
new_assets = json.loads(os.environ["PLATFORM_ASSETS_JSON"])

existing = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            existing = json.load(f)
        if not isinstance(existing, dict):
            existing = {}
    except Exception:
        existing = {}

# Same-tag manifest: keep the other platform's assets and merge ours (dedupe by
# name). A newer tag fully supersedes the prior assets.
prior_assets = []
if existing.get("tag") == tag and isinstance(existing.get("assets"), list):
    prior_assets = [
        a for a in existing["assets"]
        if isinstance(a, dict) and a.get("name") and a.get("browser_download_url")
    ]

by_name = {a["name"]: a for a in prior_assets}
for a in new_assets:
    by_name[a["name"]] = a
merged = sorted(by_name.values(), key=lambda a: a["name"])

manifest = {
    "schemaVersion": 1,
    "version": version,
    "tag": tag,
    "channel": channel,
    "prerelease": prerelease,
    "releaseSequence": int(release_sequence),
    "notes": notes,
    "assets": merged,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"Wrote {path} with {len(merged)} asset(s) for tag {tag}")
PY
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
  echo "Push raced/failed (attempt $attempt); resetting and retrying..."
  git -C "$WORK_DIR" reset -q --hard
  sleep $((attempt * 3))
done
