#!/usr/bin/env bash
# 调试版流水线（debug pulse）：生成 debug-pulse-fushi.json 并推到 update-manifest 孤儿分支。
# 契约：docs/specs/2026-11-10-debug-pulse.md；生成器：tool/gen_debug_pulse.py。
#
# 由 release.yml / release-desktop.yml 已有的 job 内步骤调用（不另起 workflow / job / runner，
# 不占 CI 排队位）：发布 run 开头一次（本 run in_progress、被顶掉的旧 run 已 cancelled），
# 发布收尾一次（出包结果，失败也跑）。只在 develop 的 push（= debug 通道）上调用。
# 调用方步骤一律 continue-on-error + 步骤超时：本脚本失败绝不能让发布变红。
#
# This is a DATA FILE pushed to a git branch, NOT a GitHub Release. It never
# creates releases or tags and never touches latest-*.json: only
# debug-pulse-fushi.json is staged, on top of the LIVE update-manifest tip, so a
# manifest that a sibling release job pushed a second earlier is preserved. The
# push uses GITHUB_TOKEN (does not cascade workflow runs) and update-manifest is
# absent from every workflow's push trigger.
#
# Required env:
#   GITHUB_TOKEN  contents:write + actions:read on REPO
#   REPO          owner/repo
# Optional env:
#   PULSE_GIT_DIR  clone with full develop commit history (default: cwd). The
#                  calling jobs all check out with fetch-depth: 0.
#   MANIFEST_REMOTE_OVERRIDE  offline test seam (local bare repo), never set in CI.
set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
: "${REPO:?REPO required}"
GIT_DIR_IN="${PULSE_GIT_DIR:-$PWD}"
FILE=debug-pulse-fushi.json
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Windows runners ship `python`; a bare `python3` there can be the Store stub
# that exits non-zero without running anything. Take the first one that runs.
PYTHON=""
for candidate in python3 python; do
  if "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "::warning title=Debug pulse::no working python on this runner."
  exit 1
fi

# Pending = develop tip vs the newest build, so read the LIVE develop tip, not
# the commit this release run checked out (a newer push may already be queued).
if git -C "$GIT_DIR_IN" fetch -q --no-tags origin +refs/heads/develop:refs/remotes/origin/develop; then
  HEAD_REF=refs/remotes/origin/develop
else
  echo "::warning title=Debug pulse::could not fetch develop; using the checked-out commit as the tip."
  HEAD_REF=HEAD
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REMOTE="${MANIFEST_REMOTE_OVERRIDE:-https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git}"
git -C "$WORK" init -q
git -C "$WORK" config core.autocrlf false
git -C "$WORK" remote add origin "$REMOTE"
git -C "$WORK" config user.name "github-actions[bot]"
git -C "$WORK" config user.email "github-actions[bot]@users.noreply.github.com"

# Previous pulse = PR metadata cache. Fail-open: without it every PR is fetched.
PREV="$WORK.prev.json"
rm -f "$PREV"
if git -C "$WORK" fetch -q --depth=1 origin update-manifest 2>/dev/null &&
  git -C "$WORK" show "FETCH_HEAD:$FILE" > "$PREV" 2>/dev/null; then
  echo "Previous pulse: $(wc -c < "$PREV") bytes"
else
  rm -f "$PREV"
fi

OUT="$WORK.out.json"
"$PYTHON" "$SCRIPT_DIR/gen_debug_pulse.py" \
  --repo "$REPO" --git-dir "$GIT_DIR_IN" --head "$HEAD_REF" \
  --previous "$PREV" --out "$OUT"
SEQ="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["develop"]["seq"])' "$OUT")"

# Both release workflows write this file at overlapping times. Every write is a
# full recomputation, so "last push wins" is the intended semantics: on a
# rejected push, re-fetch the live tip and re-apply ONLY this file on top.
attempt=0
max_attempts=6
while :; do
  attempt=$((attempt + 1))
  if git -C "$WORK" ls-remote --exit-code --heads origin update-manifest >/dev/null 2>&1; then
    # Existing branch: a fetch failure is transient -- retry, never orphan
    # (an orphan commit would wipe the update manifests).
    if ! git -C "$WORK" fetch -q --depth=1 origin update-manifest; then
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "::warning title=Debug pulse not published::could not fetch update-manifest after $max_attempts attempts."
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
  cp "$OUT" "$WORK/$FILE"
  git -C "$WORK" add "$FILE"
  if git -C "$WORK" diff --cached --quiet; then
    echo "$FILE unchanged; nothing to push."
    exit 0
  fi
  git -C "$WORK" commit -q -m "chore(update-manifest): debug pulse (develop seq $SEQ)"
  if git -C "$WORK" push -q origin HEAD:refs/heads/update-manifest; then
    echo "Pushed $FILE to update-manifest (attempt $attempt)."
    exit 0
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "::warning title=Debug pulse not published::push to update-manifest rejected $max_attempts times."
    exit 1
  fi
  echo "Push raced (attempt $attempt); re-fetching the live tip..."
  sleep "$attempt"
done
