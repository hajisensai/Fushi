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
#      SUPERSEDE_WINDOW_MINUTES (default 5), SUPERSEDE_MAX_ELAPSED_MINUTES
#      (default 9), SUPERSEDE_DRY_RUN=1 to only list,
#      SUPERSEDE_STATUSES / SUPERSEDE_NOW to override the scanned statuses and
#      the current time (replaying a past decision in a dry run).
set -euo pipefail

: "${REPO:?REPO is required}"
: "${RUN_ID:?RUN_ID is required}"
window="${SUPERSEDE_WINDOW_MINUTES:-5}"
max_elapsed="${SUPERSEDE_MAX_ELAPSED_MINUTES:-9}"

read -r workflow_id branch event created <<<"$(gh api "repos/$REPO/actions/runs/$RUN_ID" \
  --jq '[.workflow_id, .head_branch, .event, .created_at] | @tsv')"

if [ "$event" != "push" ]; then
  echo "Run $RUN_ID is a '$event' run; superseding only applies to push runs."
  exit 0
fi

# Two clocks, both measured on the older run's JOBS (run_started_at is just the
# run's creation time and says nothing about work done while jobs wait for a
# runner):
#  * superseded: its earliest job started less than $window min before THIS run
#    was created -- "the new push arrived before the old one had run 5 min".
#    Measuring against "now" instead (the first version) missed exactly that
#    case on 2026-09-29: this job itself waited 6 min for a runner, so the old
#    run looked 8 min old and survived though the push came 2.3 min after it.
#  * still safe to kill: its earliest job started less than $max_elapsed min
#    ago. Fastest publishing step measured 2026-09-27..29: the Android build
#    job's upload at the end of a >= 10.7 min job; desktop publish waits for
#    all legs (>= 12 min). A run past this cap may be uploading -> leave it.
push_cutoff="$(date -u -d "$created - ${window} minutes" +%Y-%m-%dT%H:%M:%SZ)"
safety_cutoff="$(date -u -d "${SUPERSEDE_NOW:-now} - ${max_elapsed} minutes" +%Y-%m-%dT%H:%M:%SZ)"
echo "Push runs of workflow $workflow_id on '$branch' older than run $RUN_ID (created $created): cancel those whose first job started after $push_cutoff and after $safety_cutoff, or that have not started."

# Do NOT add `event=push` to the query: combined with `branch=` the runs API
# serves a stale result set (2026-09-30 on this repo: branch+event+status
# returned runs from 09-07 while branch+status returned 09-29). Filter the
# event in jq instead.
older="$(
  for status in ${SUPERSEDE_STATUSES:-requested pending waiting queued in_progress}; do
    gh api "repos/$REPO/actions/workflows/$workflow_id/runs?branch=$branch&status=$status&per_page=50" \
      --jq ".workflow_runs[] | select(.event == \"push\" and .id < $RUN_ID) | .id"
  done | sort -u
)"

candidates=""
for id in $older; do
  # Earliest start among the run's real jobs (its own cancel-superseded job
  # starts at once and did no build work). Empty = nothing has started yet.
  first="$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
    --jq '[.jobs[] | select(.name != "cancel-superseded" and .started_at != null) | .started_at] | min // ""')"
  if [ -z "$first" ]; then
    echo "run $id: no job started yet -> superseded"
    candidates="$candidates $id"
  elif [[ "$first" > "$push_cutoff" && "$first" > "$safety_cutoff" ]]; then
    echo "run $id: first job started $first -> superseded"
    candidates="$candidates $id"
  else
    echo "run $id: first job started $first -> keep (ran too long before the push, or may be publishing)"
  fi
done

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
    echo "::notice title=Superseded run cancelled::run $id (newer push run $RUN_ID arrived within ${window} min of its start)"
  else
    echo "::warning title=Cancel skipped::run $id could not be cancelled (probably already finished)"
  fi
done
