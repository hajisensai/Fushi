#!/usr/bin/env bash
# 设置项目录（settings catalog）：把导出器生成的 settings-catalog.{json,md} 推到 update-manifest
# 孤儿分支，文件名带通道（settings-catalog-debug.* / settings-catalog-stable.*）。
# 官网 fushi.moe 的边缘 Worker 把它们代理成 /settings.md、/settings.json（给 AI 读）。
#
# 生成器：fushi/test/settings/settings_catalog_export_test.dart（设 FUSHI_SETTINGS_CATALOG_DIR 时落盘）。
# 调用方：.github/workflows/release.yml 的 publish-settings-catalog job（取同一 run 的 artifact）。
#
# This is a DATA FILE pushed to a git branch, NOT a GitHub Release. It never
# creates releases or tags and never touches latest-*.json or the debug pulse:
# only the two catalog files of ONE channel are staged, on top of the LIVE
# update-manifest tip, so files a release job pushed a second earlier are
# preserved. The catalog is deterministic (no timestamp / commit), so an
# unchanged settings schema produces no commit at all.
#
# Required env:
#   GITHUB_TOKEN  contents:write on REPO
#   REPO          owner/repo
#   CATALOG_DIR   directory holding settings-catalog.json and settings-catalog.md
#   CHANNEL       debug | stable
# Optional env:
#   MANIFEST_REMOTE_OVERRIDE  offline test seam (local bare repo), never set in CI.
set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
: "${REPO:?REPO required}"
: "${CATALOG_DIR:?CATALOG_DIR required}"
: "${CHANNEL:?CHANNEL required}"

case "$CHANNEL" in
  debug | stable) ;;
  *)
    echo "::error title=Settings catalog::unknown channel '$CHANNEL' (debug | stable)."
    exit 1
    ;;
esac

SRC_JSON="$CATALOG_DIR/settings-catalog.json"
SRC_MD="$CATALOG_DIR/settings-catalog.md"
for f in "$SRC_JSON" "$SRC_MD"; do
  if [ ! -s "$f" ]; then
    echo "::error title=Settings catalog::missing or empty $f."
    exit 1
  fi
done
# A truncated export must never replace a good catalog: the site caches
# whatever is on the branch. The exporter writes `"schema"` and the Markdown
# table header on every run; their absence means the file is not a catalog.
if ! grep -q '"schema"' "$SRC_JSON" || ! grep -q '^| Key |' "$SRC_MD"; then
  echo "::error title=Settings catalog::$CATALOG_DIR does not look like a settings catalog."
  exit 1
fi

OUT_JSON="settings-catalog-$CHANNEL.json"
OUT_MD="settings-catalog-$CHANNEL.md"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REMOTE="${MANIFEST_REMOTE_OVERRIDE:-https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git}"
git -C "$WORK" init -q
git -C "$WORK" config core.autocrlf false
git -C "$WORK" remote add origin "$REMOTE"
git -C "$WORK" config user.name "github-actions[bot]"
git -C "$WORK" config user.email "github-actions[bot]@users.noreply.github.com"

# The release workflows write their own files to the same branch at overlapping
# times: on a rejected push, re-fetch the live tip and re-apply ONLY the two
# catalog files on top.
attempt=0
max_attempts=6
while :; do
  attempt=$((attempt + 1))
  if git -C "$WORK" ls-remote --exit-code --heads origin update-manifest >/dev/null 2>&1; then
    # Existing branch: a fetch failure is transient -- retry, never orphan
    # (an orphan commit would wipe the update manifests).
    if ! git -C "$WORK" fetch -q --depth=1 origin update-manifest; then
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "::error title=Settings catalog not published::could not fetch update-manifest after $max_attempts attempts."
        exit 1
      fi
      sleep "$attempt"
      continue
    fi
    git -C "$WORK" checkout -q -B update-manifest FETCH_HEAD
    git -C "$WORK" reset -q --hard FETCH_HEAD
  else
    git -C "$WORK" checkout -q --orphan update-manifest
    git -C "$WORK" rm -rfq --cached . 2>/dev/null || true
  fi
  cp "$SRC_JSON" "$WORK/$OUT_JSON"
  cp "$SRC_MD" "$WORK/$OUT_MD"
  git -C "$WORK" add "$OUT_JSON" "$OUT_MD"
  if git -C "$WORK" diff --cached --quiet; then
    echo "Settings catalog ($CHANNEL) unchanged; nothing to push."
    exit 0
  fi
  git -C "$WORK" commit -q -m "chore(update-manifest): settings catalog ($CHANNEL)"
  if git -C "$WORK" push -q origin HEAD:refs/heads/update-manifest; then
    echo "Pushed $OUT_JSON + $OUT_MD to update-manifest (attempt $attempt)."
    exit 0
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "::error title=Settings catalog not published::push to update-manifest rejected $max_attempts times."
    exit 1
  fi
  echo "Push raced (attempt $attempt); re-fetching the live tip..."
  sleep "$attempt"
done
