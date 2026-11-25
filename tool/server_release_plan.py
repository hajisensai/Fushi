#!/usr/bin/env python3
"""Decide what the next automatic fushi_server release should be.

Called by the `plan` job of `.github/workflows/release-server.yml` when the
caller (hajisensai/fushi-server's thin `release.yml`, run on a schedule) passes
`channel: auto`. Cross-repository events need a PAT, so the server repo polls the
app repo instead and follows its three channels:

* formal: the app's `releases/latest` (`v<x.y.z>`) has no server release with the
  same tag yet;
* beta:   the app's newest `v<x.y.z>-beta.<seq>` prerelease has no server release
  with the same tag yet;
* debug:  `develop` moved past the commit the server's rolling `debug-rolling`
  release was built from (recorded as `source-sha: <sha>` in its body), and the
  change is not docs-only.

An app release whose commit does not contain SERVER_BUILD_FLOOR is never a
candidate: its source predates what this workflow builds (no server bundle
scripts, older Flutter pin), so it cannot produce a server package at all.

One target per run, in that order, so a run is one ordinary linear release.
A target whose build already failed FAIL_LIMIT times in recent runs is skipped
with a warning (the job names carry `[target:<key>]`), so a broken source tag is
not rebuilt every half hour; dispatch it manually once fixed.

Outputs (GITHUB_OUTPUT): channel (empty = nothing to do), source_ref, tag_name,
reason. Other channels pass straight through.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

DEBUG_TAG = "debug-rolling"
FAIL_LIMIT = 2
BETA_TAG = re.compile(r"^v\d+(\.\d+)*-beta\.(\d+)$")
FORMAL_TAG = re.compile(r"^v\d+(\.\d+)*$")
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
SOURCE_SHA_MARK = re.compile(r"source-sha: ([0-9a-f]{40})")
TARGET_MARK = re.compile(r"\[target:([^\]]+)\]")
# Paths that never reach the server bundle. fushi/ is the app; the server only
# reads fushi/pubspec.yaml (version) and fushi/assets/transforms (deinflection).
IRRELEVANT_PATH = re.compile(
    r"^(docs/|.*\.md$|fushi/(?!pubspec\.yaml$|assets/transforms/))"
)
# GitHub's compare API lists at most 300 files; a full list means "maybe more".
COMPARE_FILE_CAP = 300
# Oldest develop commit release-server.yml can build: #3400 (Flutter 3.50.0 pin),
# which already contains #3468 (packages/fushi_server/tool/build_linux_bundle.sh).
# App v3.3.0 (a2638e03) predates both and fails on either platform (fushi-server
# run 45491284403). Bump this in the same commit as any change that stops the
# workflow from building older sources.
SERVER_BUILD_FLOOR = "283a92028615e3ddf92cd510d316234ae2ecbf35"

# endpoint -> parsed JSON, or None when the API answers 404.
Fetch = Callable[[str], Optional[object]]


@dataclass(frozen=True)
class Plan:
    channel: str  # '' = nothing to release
    source_ref: str = ""
    tag_name: str = ""
    reason: str = ""


def target_key(channel: str, tag: str, sha: str) -> str:
    """The `[target:<key>]` marker the release jobs put in their names."""
    return "debug@" + sha[:12] if channel == "debug" else tag


def debug_change_is_relevant(compare: Optional[object]) -> bool:
    """True unless the compare result proves only docs / app-only files changed."""
    if not isinstance(compare, dict) or compare.get("status") != "ahead":
        return True  # unknown base (history rewrite, deleted sha): rebuild
    files = compare.get("files")
    if not isinstance(files, list) or not files or len(files) >= COMPARE_FILE_CAP:
        return True
    for f in files:
        name = f.get("filename") if isinstance(f, dict) else None
        if not isinstance(name, str) or not IRRELEVANT_PATH.match(name):
            return True
    return False


def _resolve_sha(fetch: Fetch, source_repo: str, release: dict) -> str:
    commitish = release.get("target_commitish")
    if isinstance(commitish, str) and FULL_SHA.match(commitish):
        return commitish
    commit = fetch(f"repos/{source_repo}/commits/{release['tag_name']}")
    sha = commit.get("sha") if isinstance(commit, dict) else None
    if not isinstance(sha, str) or not FULL_SHA.match(sha):
        raise RuntimeError(f"cannot resolve commit of {release['tag_name']}")
    return sha


def source_is_buildable(fetch: Fetch, source_repo: str, sha: str) -> bool:
    """True when `sha` contains SERVER_BUILD_FLOOR (unknown compare = not provable)."""
    compare = fetch(f"repos/{source_repo}/compare/{SERVER_BUILD_FLOOR}...{sha}")
    return isinstance(compare, dict) and compare.get("status") in ("ahead", "identical")


def _newest_beta(releases: object) -> Optional[dict]:
    best: Optional[dict] = None
    best_seq = -1
    for r in releases if isinstance(releases, list) else []:
        if not isinstance(r, dict) or r.get("draft") or not r.get("prerelease"):
            continue
        m = BETA_TAG.match(str(r.get("tag_name", "")))
        if m and int(m.group(2)) > best_seq:
            best, best_seq = r, int(m.group(2))
    return best


def plan_auto(
    fetch: Fetch,
    failures: Dict[str, int],
    source_repo: str,
    caller_repo: str,
    warn: Callable[[str], None],
) -> Plan:
    def has_server_release(tag: str) -> bool:
        return fetch(f"repos/{caller_repo}/releases/tags/{tag}") is not None

    def gave_up(key: str) -> bool:
        if failures.get(key, 0) >= FAIL_LIMIT:
            warn(
                f"{key} failed {failures[key]} times in recent runs; skipped. "
                "Fix the cause, then dispatch it manually."
            )
            return True
        return False

    def candidate(channel: str, release: dict) -> Optional[Plan]:
        tag = release["tag_name"]
        if has_server_release(tag) or gave_up(tag):
            return None
        sha = _resolve_sha(fetch, source_repo, release)
        if not source_is_buildable(fetch, source_repo, sha):
            warn(
                f"app {channel} {tag} ({sha[:12]}) predates the server build floor "
                f"{SERVER_BUILD_FLOOR[:12]}; skipped (its source cannot build fushi_server)."
            )
            return None
        return Plan(channel, sha, tag, f"app {channel} {tag} has no server release")

    latest = fetch(f"repos/{source_repo}/releases/latest")
    if (
        isinstance(latest, dict)
        and not latest.get("draft")
        and not latest.get("prerelease")
        and FORMAL_TAG.match(str(latest.get("tag_name", "")))
    ):
        plan = candidate("formal", latest)
        if plan is not None:
            return plan

    beta = _newest_beta(fetch(f"repos/{source_repo}/releases?per_page=50"))
    if beta is not None:
        plan = candidate("beta", beta)
        if plan is not None:
            return plan

    head_commit = fetch(f"repos/{source_repo}/commits/develop")
    head = head_commit.get("sha") if isinstance(head_commit, dict) else None
    if not isinstance(head, str) or not FULL_SHA.match(head):
        raise RuntimeError("cannot resolve develop")
    rolling = fetch(f"repos/{caller_repo}/releases/tags/{DEBUG_TAG}")
    mark = SOURCE_SHA_MARK.search(str(rolling.get("body") or "")) if isinstance(rolling, dict) else None
    last = mark.group(1) if mark else None
    if last == head:
        return Plan("", reason=f"debug is current ({head[:12]})")
    if gave_up(target_key("debug", "", head)):
        return Plan("", reason="debug head keeps failing")
    if last is not None and not debug_change_is_relevant(
        fetch(f"repos/{source_repo}/compare/{last}...{head}")
    ):
        return Plan("", reason=f"{last[:12]}..{head[:12]} touches nothing the server ships")
    return Plan("debug", head, "", f"develop moved to {head[:12]}")


def count_failures(fetch: Fetch, caller_repo: str, workflow_file: str) -> Dict[str, int]:
    """How many recent failed runs of the calling workflow failed each target."""
    runs = fetch(
        f"repos/{caller_repo}/actions/workflows/{workflow_file}/runs?status=failure&per_page=10"
    )
    counts: Dict[str, int] = {}
    for run in (runs or {}).get("workflow_runs", []) if isinstance(runs, dict) else []:
        jobs = fetch(f"repos/{caller_repo}/actions/runs/{run['id']}/jobs?per_page=100")
        keys = set()
        for job in (jobs or {}).get("jobs", []) if isinstance(jobs, dict) else []:
            if job.get("conclusion") != "failure":
                continue
            m = TARGET_MARK.search(str(job.get("name", "")))
            if m:
                keys.add(m.group(1))
        for k in keys:
            counts[k] = counts.get(k, 0) + 1
    return counts


def workflow_file_of(workflow_ref: str) -> str:
    """`owner/repo/.github/workflows/release.yml@refs/heads/main` -> `release.yml`."""
    m = re.match(r"^[^/]+/[^/]+/\.github/workflows/([^@]+)@", workflow_ref)
    if not m:
        raise RuntimeError(f"unexpected workflow ref {workflow_ref!r}")
    return m.group(1)


def gh_fetch(endpoint: str) -> Optional[object]:
    proc = subprocess.run(
        ["gh", "api", endpoint], capture_output=True, text=True, encoding="utf-8"
    )
    if proc.returncode == 0:
        return json.loads(proc.stdout)
    if "HTTP 404" in proc.stderr:
        return None
    raise RuntimeError(f"gh api {endpoint}: {proc.stderr.strip()}")


def write_outputs(plan: Plan) -> None:
    lines: List[str] = [
        f"channel={plan.channel}",
        f"source_ref={plan.source_ref}",
        f"tag_name={plan.tag_name}",
        f"reason={plan.reason}",
    ]
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
    print("\n".join(lines))


def main() -> int:
    channel = os.environ.get("INPUT_CHANNEL", "").strip() or "beta"
    if channel != "auto":
        write_outputs(Plan(
            channel,
            os.environ.get("INPUT_SOURCE_REF", "").strip() or "develop",
            os.environ.get("INPUT_TAG_NAME", "").strip(),
            "explicit channel",
        ))
        return 0
    source_repo = os.environ["SOURCE_REPO"]
    caller_repo = os.environ["CALLER_REPO"]
    failures = count_failures(gh_fetch, caller_repo, workflow_file_of(os.environ["WORKFLOW_REF"]))
    plan = plan_auto(
        gh_fetch, failures, source_repo, caller_repo,
        lambda msg: print(f"::warning title=Server auto release::{msg}"),
    )
    write_outputs(plan)
    if plan.channel:
        print(f"::notice title=Server auto release::{plan.channel}: {plan.reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
