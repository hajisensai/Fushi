#!/usr/bin/env bash
# Cancel older push-triggered runs of THIS workflow on THIS branch that a newer
# push has superseded while they were still young (< SUPERSEDE_WINDOW_MINUTES
# since they started, or not started at all).
#
# Why (2026-09-30, measured on 9/27-9/29): develop got 65 pushes, 20 of them
# < 5 min after the previous one; the release workflows group concurrency by
# sha with cancel-in-progress: false, so every push ran to completion. Runner
# slots (public repo: ~20 concurrent jobs, 5 macOS) are the bottleneck, so the
# dead runs showed up as 30-86 min job queues for everyone else. Cancelling runs
# superseded within 5 min frees ~28% of the release workflows' runner time.
#
# Why only "young" runs and not plain cancel-in-progress: a run older than the
# window may already be uploading (TestFlight, GitHub Release assets, the update
# manifest push); killing it there leaves half-published state. Within 5 minutes
# no release job has got anywhere near its publish steps (Android build alone is
# ~17 min, desktop legs 15-35 min). Formal releases are never touched: only runs
# whose event is `push` are considered, and only when this run is a push too.
#
# Env: GH_TOKEN (needs actions: write), REPO (owner/name), RUN_ID (this run),
#      SUPERSEDE_WINDOW_MINUTES (default 5), SUPERSEDE_DRY_RUN=1 to only list,
#      SUPERSEDE_STATUSES to override the run statuses scanned (testing).
set -euo pipefail

: "${REPO:?REPO is required}"
: "${RUN_ID:?RUN_ID is required}"
window="${SUPERSEDE_WINDOW_MINUTES:-5}"

read -r workflow_id branch event <<<"$(gh api "repos/$REPO/actions/runs/$RUN_ID" \
  --jq '[.workflow_id, .head_branch, .event] | @tsv')"

if [ "$event" != "push" ]; then
  echo "Run $RUN_ID is a '$event' run; superseding only applies to push runs."
  exit 0
fi

cutoff="$(date -u -d "-${window} minutes" +%Y-%m-%dT%H:%M:%SZ)"
echo "Looking for push runs of workflow $workflow_id on '$branch' older than run $RUN_ID that started after $cutoff (or have not started)."

# Do NOT add `event=push` to the query: combined with `branch=` the runs API
# serves a stale result set (2026-09-30 on this repo: branch+event+status
# returned runs from 09-07 while branch+status returned 09-29). Filter the
# event in jq instead.
candidates="$(
  for status in ${SUPERSEDE_STATUSES:-requested pending waiting queued in_progress}; do
    gh api "repos/$REPO/actions/workflows/$workflow_id/runs?branch=$branch&status=$status&per_page=50" \
      --jq ".workflow_runs[] | select(.event == \"push\" and .id < $RUN_ID) | select(.status != \"in_progress\" or (.run_started_at // .created_at) >= \"$cutoff\") | .id"
  done | sort -u
)"

if [ -z "$candidates" ]; then
  echo "Nothing superseded."
  exit 0
fi

for id in $candidates; do
  if [ "${SUPERSEDE_DRY_RUN:-}" = "1" ]; then
    echo "[dry run] would cancel run $id"
    continue
  fi
  # A run can finish between the listing and the cancel (409); that is fine.
  if gh api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null; then
    echo "::notice title=Superseded run cancelled::run $id (newer push run $RUN_ID arrived within ${window} min)"
  else
    echo "::warning title=Cancel skipped::run $id could not be cancelled (probably already finished)"
  fi
done
