#!/usr/bin/env bash
# Cancel a closed PR's still-queued / running CI, then delete the Actions caches
# scoped to its merge ref. Two callers:
#   * .github/workflows/cache-cleanup.yml    -- `pull_request: closed`, same-repo PRs
#   * .github/workflows/merged-pr-cleanup.yml -- push to develop: every PR that push
#                                                merged, fork PRs included
#
# Why two callers (2026-09-30): 79% of PRs come from a fork (W1ght/hibiki), whose
# `pull_request` token is read-only, and 82% of PR CI runner time was spent AFTER the
# PR merged. `pull_request_target` would give a fork PR the base repo's token, but it
# takes the workflow definition from the DEFAULT branch (main), which lags develop by
# a hundred-plus commits and is not synced by agents -- after #1829 moved this job to
# pull_request_target it never ran once. A push to develop runs develop's own workflow
# file with a writable token, and merging a PR IS a push to develop, so merged PRs of
# any origin are cleaned there; only fork PRs closed without merging are not covered.
#
# Modes (env):
#   single PR : REPO, PR_NUMBER, HEAD_REPO, HEAD_BRANCH
#   by push   : REPO, MERGED_BY_SHAS (commit shas of the push), BASE_BRANCH
#               -> every PR associated with one of those commits, merged into BASE_BRANCH
# Optional: SKIP_WORKFLOW_PATHS (space-separated workflow paths never cancelled),
#           CLEANUP_FORCE_AFTER_SECONDS (90), CLEANUP_DRY_RUN=1 (print, change nothing).
set -euo pipefail

: "${REPO:?REPO is required}"
force_after="${CLEANUP_FORCE_AFTER_SECONDS:-90}"
dry="${CLEANUP_DRY_RUN:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Cancel PR_NUMBER's leftover CI and delete its caches (HEAD_REPO / HEAD_BRANCH set).
cleanup_one() {
  local number="$1" head_repo_want="$2" head_branch_want="$3"
  echo "== PR #$number ($head_repo_want:$head_branch_want)"

  # PR concurrency groups only cancel-in-progress when the same PR gets a new push;
  # merging / closing cancels nothing, so a merged PR's whole CI kept running for
  # results nobody reads (2026-09-30: 14 merged PRs held ~39 runs at one moment,
  # plus an appSmoke stuck for 250 minutes). Only runs triggered by pull_request /
  # pull_request_target on this PR's branch are touched; pushes (the develop
  # releases) never are. Query by status only and compare branch / repository in
  # bash: the runs API with branch= returned a stale result set (09-07 data on
  # 09-30), and the fork-controlled branch name then never enters a URL or jq.
  local ids
  ids="$(
    for status in requested pending waiting queued in_progress; do
      gh api -X GET "repos/$REPO/actions/runs" -f status="$status" -f per_page=100 --paginate \
        --jq '.workflow_runs[] | select(.event == "pull_request" or .event == "pull_request_target") | "\(.id)\t\(.head_repository.full_name)\t\(.head_branch)\t\(.path)\t\(.name)"'
    done | sort -u
  )"
  local cancelled=0 requested="" id head_repo head_branch path name
  while IFS=$'\t' read -r id head_repo head_branch path name; do
    [ -n "${id:-}" ] || continue
    [ "$head_branch" = "$head_branch_want" ] || continue
    # A branch NAME is not unique: a PR from another fork's `develop` has it too.
    # Only runs from this PR's own head repository count.
    [ "$head_repo" = "$head_repo_want" ] || continue
    case " ${SKIP_WORKFLOW_PATHS:-} " in *" $path "*) continue ;; esac
    if [ -n "$dry" ]; then
      echo "DRY RUN: would cancel run $id ($name)"
      continue
    fi
    if gh api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null 2>&1; then
      echo "Cancelled run $id ($name)"
      cancelled=$((cancelled + 1))
      requested="$requested $id"
    else
      echo "Run $id ($name) could not be cancelled (probably already finished)"
    fi
  done <<< "$ids"

  # A plain cancel does not stop `if: always()` jobs / steps (2026-09-30: three runs
  # stayed in_progress after cancel): wait one round, force-cancel what still runs.
  local deadline pending still
  deadline=$(( $(date +%s) + force_after ))
  pending="$requested"
  while [ -n "$pending" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 10
    still=""
    for id in $pending; do
      [ "$(gh api "repos/$REPO/actions/runs/$id" --jq .status)" = "completed" ] || still="$still $id"
    done
    pending="$still"
  done
  for id in $pending; do
    gh api -X POST "repos/$REPO/actions/runs/$id/force-cancel" >/dev/null 2>&1 \
      && echo "Force-cancelled run $id (ignored the plain cancel for ${force_after}s)" \
      || echo "::warning title=Force-cancel failed::run $id"
  done
  echo "PR #$number: cancelled $cancelled leftover CI run(s)." >> "$summary"

  # Caches are bucketed per ref: what a PR run saved under refs/pull/<N>/merge is
  # never read again once the PR is closed, but GitHub only evicts it after 7 days
  # without access -- quota (10 GB) the develop caches then lose. Delete them now,
  # after the cancels, so no still-running job writes a new one afterwards.
  local ref="refs/pull/$number/merge" keys freed=0 count=0 size key
  keys="$(gh api --paginate "repos/$REPO/actions/caches?per_page=100&ref=$ref" \
    --jq '.actions_caches[] | "\(.id)\t\(.size_in_bytes)\t\(.key)"')"
  while IFS=$'\t' read -r id size key; do
    [ -n "${id:-}" ] || continue
    if [ -n "$dry" ]; then
      echo "DRY RUN: would delete cache $key ($((size / 1024 / 1024)) MB)"
      continue
    fi
    echo "Deleting $key ($((size / 1024 / 1024)) MB, id=$id)"
    # By id is exact; a failure does not fail the run (LRU may have evicted it).
    gh api -X DELETE "repos/$REPO/actions/caches/$id" \
      || echo "::warning title=Cache delete failed::$key"
    freed=$((freed + size))
    count=$((count + 1))
  done <<< "$keys"
  echo "PR #$number: deleted $count cache(s), freed $((freed / 1024 / 1024)) MB from $ref." >> "$summary"
}

if [ -n "${MERGED_BY_SHAS:-}" ]; then
  : "${BASE_BRANCH:?BASE_BRANCH is required with MERGED_BY_SHAS}"
  # "PRs associated with a commit" knows merge, squash and rebase merges alike; keep
  # only PRs actually merged into this branch. Base / merged state are compared in bash.
  prs="$(
    for sha in $MERGED_BY_SHAS; do
      gh api "repos/$REPO/commits/$sha/pulls" \
        --jq '.[] | "\(.number)\t\(.merged_at // "")\t\(.base.ref)\t\(.head.repo.full_name // "")\t\(.head.ref)"'
    done | sort -u
  )"
  found=0
  while IFS=$'\t' read -r number merged_at base head_repo head_ref; do
    [ -n "${number:-}" ] || continue
    [ -n "$merged_at" ] || continue
    [ "$base" = "$BASE_BRANCH" ] || continue
    # A deleted fork has no head repository; its runs are gone with it.
    [ -n "$head_repo" ] || continue
    found=$((found + 1))
    cleanup_one "$number" "$head_repo" "$head_ref"
  done <<< "$prs"
  [ "$found" -gt 0 ] || echo "No PR merged into $BASE_BRANCH by this push."
else
  : "${PR_NUMBER:?PR_NUMBER is required}" "${HEAD_REPO:?HEAD_REPO is required}" "${HEAD_BRANCH:?HEAD_BRANCH is required}"
  cleanup_one "$PR_NUMBER" "$HEAD_REPO" "$HEAD_BRANCH"
fi

# Quota report: warn, never fail -- this job reclaims, it does not gate.
read -r bytes entries <<< "$(gh api "repos/$REPO/actions/cache/usage" \
  --jq '"\(.active_caches_size_in_bytes) \(.active_caches_count)"')"
mb=$((bytes / 1024 / 1024))
echo "Repository cache usage: ${mb} MB in ${entries} entries (limit 10240 MB)." >> "$summary"
if [ "$mb" -gt 10240 ]; then
  echo "::warning title=Actions cache over quota::${mb} MB > 10240 MB; GitHub is LRU-evicting."
fi
