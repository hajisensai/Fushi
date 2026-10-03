#!/usr/bin/env bash
# Cancel an older develop/main release run once a newer push has queued its own
# run behind it -- but only while the old run is still young.
#
# Called by .github/workflows/supersede-develop-releases.yml on every push to
# develop/main. It is deliberately NOT a job inside the release workflows: since
# #1798 those group their push runs per branch (cancel-in-progress: false), so a
# new run -- and any job in it -- stays pending until the running one finishes,
# by which time there is nothing left to cancel. A separate workflow is outside
# that group and starts right away.
#
# Rule (optimum of a simulation over the 542 release-triggering develop pushes of
# 2026-09, with the measured sharded run durations; see the PR/commit message):
#   cancel the running push run of the same workflow + branch when its first real
#   job started less than SUPERSEDE_WINDOW_MINUTES (8) before the NEW run was
#   created, and less than SUPERSEDE_MAX_ELAPSED_MINUTES (10) before now.
#   * T = 8 minimises push -> published latency (Android mean 36.6 -> 32.2 min,
#     p90 51.8 -> 42.7; desktop 42.6 -> 37.6 / 59.6 -> 50.0) while still saving
#     ~7% runner (macOS 32.6 -> 30.3 min/h). "Always cancel" starves publishing
#     during push bursts (p90 90-100 min); 5-11 is a flat optimum.
#   * The 10 min cap keeps us away from uploads: the earliest publish step seen is
#     at ~10.7 min into the Android build job; desktop publish waits for all legs.
#   Runs are judged by their JOBS' start (run_started_at is only the creation time
#   and keeps ticking while jobs wait for runners).
# If the push did not trigger a release run (path filters), nothing supersedes the
# running one: it is still the newest release-relevant commit, so it is kept.
#
# Queries filter only by status and compare branch / event / sha in bash: with
# `branch=` the runs API has served stale result sets (09-07 data on 09-30).
# A plain cancel does not stop `if: always()` jobs / steps (desktop publish, macOS
# signing), so runs still going after SUPERSEDE_FORCE_AFTER_SECONDS are
# force-cancelled.
#
# Env: GH_TOKEN (actions: write), REPO (owner/name), HEAD_SHA (this push),
#      BRANCH (develop/main), WORKFLOWS (space-separated workflow file names),
#      SUPERSEDE_WINDOW_MINUTES (8), SUPERSEDE_MAX_ELAPSED_MINUTES (10),
#      SUPERSEDE_FORCE_AFTER_SECONDS (90), SUPERSEDE_WAIT_FOR_RUN_SECONDS (90).
#      Testing: SUPERSEDE_DRY_RUN=1, SUPERSEDE_NOW=<iso time>.
set -euo pipefail

: "${REPO:?REPO is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${BRANCH:?BRANCH is required}"
: "${WORKFLOWS:?WORKFLOWS is required}"
window="${SUPERSEDE_WINDOW_MINUTES:-8}"
max_elapsed="${SUPERSEDE_MAX_ELAPSED_MINUTES:-10}"
force_after="${SUPERSEDE_FORCE_AFTER_SECONDS:-90}"
wait_for_run="${SUPERSEDE_WAIT_FOR_RUN_SECONDS:-90}"
statuses="requested pending waiting queued in_progress"

# All active runs of one workflow as TSV: id, sha, branch, event, status, created_at.
active_runs() {
  local wf="$1" st
  for st in $statuses; do
    gh api -X GET "repos/$REPO/actions/workflows/$wf/runs" -f status="$st" -f per_page=100 --paginate \
      --jq '.workflow_runs[] | [.id, .head_sha, .head_branch, .event, .status, .created_at] | @tsv'
  done | sort -u
}

requested=""
for wf in $WORKFLOWS; do
  # 1. The run this push created (it may appear a few seconds after the push).
  new_id=""; new_created=""
  deadline=$(( $(date +%s) + wait_for_run ))
  while :; do
    while IFS=$'\t' read -r id sha br ev st created; do
      if [ "$sha" = "$HEAD_SHA" ] && [ "$br" = "$BRANCH" ] && [ "$ev" = "push" ]; then
        new_id="$id"; new_created="$created"
      fi
    done < <(active_runs "$wf")
    [ -n "$new_id" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 10
  done
  if [ -z "$new_id" ]; then
    echo "$wf: this push ($HEAD_SHA) created no active run -> the running one is still the newest; nothing to do."
    continue
  fi

  push_cutoff="$(date -u -d "$new_created - ${window} minutes" +%Y-%m-%dT%H:%M:%SZ)"
  safety_cutoff="$(date -u -d "${SUPERSEDE_NOW:-now} - ${max_elapsed} minutes" +%Y-%m-%dT%H:%M:%SZ)"
  echo "$wf: new run $new_id (created $new_created). Cancel older $BRANCH push runs whose first job started after $push_cutoff and after $safety_cutoff, or not started."

  # 2. Older active push runs on the same branch.
  while IFS=$'\t' read -r id sha br ev st created; do
    [ "$br" = "$BRANCH" ] && [ "$ev" = "push" ] && [ "$id" -lt "$new_id" ] || continue
    first="$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
      --jq '[.jobs[] | select(.started_at != null) | .started_at] | min // ""')"
    if [ -z "$first" ]; then
      verdict="superseded (no job started yet)"
    elif [[ "$first" > "$push_cutoff" && "$first" > "$safety_cutoff" ]]; then
      verdict="superseded (first job started $first)"
    else
      echo "  run $id: first job started $first -> keep (ran >= ${window} min before the push, or may be publishing)"
      continue
    fi
    if [ "${SUPERSEDE_DRY_RUN:-}" = "1" ]; then
      echo "  run $id: $verdict -> [dry run] would cancel"
      continue
    fi
    # A run can finish between the listing and the cancel (409); that is fine.
    if gh api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null; then
      echo "::notice title=Superseded run cancelled::$wf run $id: $verdict; newer push run $new_id"
      requested="$requested $id"
    else
      echo "::warning title=Cancel skipped::run $id could not be cancelled (probably already finished)"
    fi
  done < <(active_runs "$wf")
done
[ -n "$requested" ] || exit 0

# 3. Force-cancel whatever ignored the plain cancel (always() jobs / steps).
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
  if gh api -X POST "repos/$REPO/actions/runs/$id/force-cancel" >/dev/null; then
    echo "::notice title=Superseded run force-cancelled::run $id ignored the plain cancel for ${force_after}s (always() jobs)"
  else
    echo "::warning title=Force-cancel failed::run $id"
  fi
done
