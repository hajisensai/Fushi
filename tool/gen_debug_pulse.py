#!/usr/bin/env python3
"""Generate ``debug-pulse-fushi.json``: what is in each Fushi debug build.

Contract: docs/specs/2026-11-10-debug-pulse.md (schema 1). Consumers are debug-
channel clients that read the file from the ``update-manifest`` branch through
the same raw + mirror path as ``latest-debug-fushi.json``: they have no GitHub
token, anonymous api.github.com is 60 req/h and unreachable from mainland China,
so every derived fact is computed here, in CI, once.

Data sources -- deliberately split so the expensive/ambiguous parts never touch
the network:

  local git (the workflow checks out develop with full commit history)
      * seq of any commit = ``git rev-list --count <sha>`` + RELEASE_SEQUENCE_FLOOR
        (the floor is READ from tool/release_sequence.sh, never copied);
      * contents of a build = ``git log --first-parent <base>..<build>``: merge /
        squash commits on develop's first-parent chain are PRs, everything else on
        that chain was pushed straight to develop.

  GitHub REST / GraphQL (GITHUB_TOKEN)
      * assets of the rolling debug release (``fushi-debug-rolling``): asset names
        ``fushi-<ver>-debug.<seq>[-<sha7>]-<platform>`` are the only record of
        which seqs are still downloadable;
      * push runs of release.yml / release-desktop.yml on develop: seq <-> sha for
        builds whose asset names carry no sha7, the base of the oldest build
        (its predecessor was pruned from the rolling release), and per-platform
        "queued / building / built / failed / superseded" state, refined by the
        run's jobs while it is live (the refresh runs INSIDE release runs, see
        tool/publish_debug_pulse.sh, so the current run is always still live);
      * PR metadata (title / author / labels / additions / deletions / mergedAt),
        cached through the previous ``debug-pulse-fushi.json`` so a steady-state
        run only asks for PRs merged since the last run.

Every git / network access goes through the small ``Git`` / ``GitHubApi``
objects so tests can substitute a scratch repository and canned responses.

Usage:
    GITHUB_TOKEN=... python3 tool/gen_debug_pulse.py \\
        --repo hajisensai/Fushi --head HEAD \\
        --previous prev.json --out debug-pulse-fushi.json

Security note: the token is read from GITHUB_TOKEN and only used for API
Authorization headers; it is never written into the output.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

SCHEMA = 1

# The rolling GitHub Release every debug publish overwrites. Same literal as
# `ROLLING_DEBUG_TAG=` in release.yml / release-desktop.yml; the unit test reads
# both workflows and fails if they ever diverge from this constant.
ROLLING_TAG = "fushi-debug-rolling"

# Release workflow -> platforms it ships. A platform's run state is read from
# the workflow that builds it.
PLATFORM_WORKFLOWS: Dict[str, str] = {
    "android": "release.yml",
    "windows": "release-desktop.yml",
    "macos": "release-desktop.yml",
    "ios": "release-desktop.yml",
}
PLATFORMS: Tuple[str, ...] = ("android", "windows", "macos", "ios")
# Jobs (names = job keys, none of them sets `name:`) whose outcome decides
# whether a platform's package comes out of a run. Lets a refresh taken from
# inside a still-running release run tell "this platform already failed" from
# "still building" -- the run itself only completes after the refresh step.
PLATFORM_JOBS: Dict[str, Tuple[str, ...]] = {
    "android": ("build", "publish-android"),
    "windows": ("windows", "publish"),
    "macos": ("macos", "publish"),
    "ios": ("ios", "publish"),
}
RELEASE_WORKFLOWS: Tuple[str, ...] = ("release.yml", "release-desktop.yml")

MAX_BUILDS = 30
# First-parent commits listed per build / pending before `truncated` is set.
MAX_CHAIN = 300
# One page of runs per workflow. 30 builds need well under 100 push runs per
# workflow (superseded pending runs included); older runs only matter for the
# base of the oldest build, which takes the newest successful one below it.
RUNS_PER_WORKFLOW = 100
PR_GRAPHQL_BATCH = 50

ASSET_RE = re.compile(
    r"^fushi-(\d+\.\d+\.\d+)-debug\.(\d+)(?:-([0-9a-f]{7,40}))?-(.+)$"
)
MERGE_PR_RE = re.compile(r"^Merge pull request #(\d+)\b")
SQUASH_PR_RE = re.compile(r"\(#(\d+)\)\s*$")
FLOOR_RE = re.compile(r"^RELEASE_SEQUENCE_FLOOR=(\d+)\s*$", re.MULTILINE)

LIVE_STATUSES = {"queued", "waiting", "pending", "requested", "in_progress"}
SUPERSEDED_CONCLUSIONS = {"cancelled", "skipped", "stale"}
FAILED_CONCLUSIONS = {"failure", "timed_out", "startup_failure", "action_required"}


# --------------------------------------------------------------------------- #
# Pure helpers
# --------------------------------------------------------------------------- #


def read_sequence_floor(release_sequence_sh: str) -> int:
    """RELEASE_SEQUENCE_FLOOR from tool/release_sequence.sh (single source)."""
    with open(release_sequence_sh, encoding="utf-8") as f:
        text = f.read()
    m = FLOOR_RE.search(text)
    if not m:
        raise SystemExit(
            f"RELEASE_SEQUENCE_FLOOR=<int> not found in {release_sequence_sh}"
        )
    return int(m.group(1))


def platform_of(rest: str) -> Optional[str]:
    """Platform of an asset-name tail (the part after ``debug.<seq>[-<sha7>]-``)."""
    if rest.endswith(".apk"):
        return "android"
    for p in ("windows", "macos", "ios"):
        if rest.startswith(p):
            return p
    return None


def parse_asset_name(name: str) -> Optional[dict]:
    """``fushi-3.3.0-debug.25034-4760a9f-debug.apk`` -> version/seq/sha7/platform."""
    m = ASSET_RE.match(name)
    if not m:
        return None
    platform = platform_of(m.group(4))
    if platform is None:
        return None
    return {
        "version": m.group(1),
        "seq": int(m.group(2)),
        "sha7": m.group(3),
        "platform": platform,
    }


def pr_number_of(subject: str) -> Optional[int]:
    """PR number of a first-parent commit: GitHub merge commit or squash ``(#N)``."""
    m = MERGE_PR_RE.match(subject)
    if m:
        return int(m.group(1))
    m = SQUASH_PR_RE.search(subject)
    if m:
        return int(m.group(1))
    return None


def run_state(run: dict) -> str:
    """Contract state of one release run (never ``ok`` / ``none``)."""
    status = run.get("status") or ""
    if status != "completed":
        return "building" if status == "in_progress" else "queued"
    conclusion = run.get("conclusion") or ""
    if conclusion == "success":
        return "built"
    if conclusion in SUPERSEDED_CONCLUSIONS:
        return "superseded"
    return "failed"


def pick_run(runs: Sequence[dict]) -> Optional[dict]:
    """The run that speaks for a (seq, workflow): a live one, else the newest."""
    if not runs:
        return None
    live = [r for r in runs if (r.get("status") or "") in LIVE_STATUSES]
    if live:
        return max(live, key=lambda r: r.get("updated_at") or "")
    return max(runs, key=lambda r: r.get("updated_at") or "")


def jobs_state(jobs: Sequence[dict], names: Sequence[str]) -> Optional[str]:
    """Platform state from the run's jobs; None = jobs say nothing (fall back
    to the run-level state)."""
    rel = [j for j in jobs if j.get("name") in names]
    if not rel:
        return None
    for j in rel:
        if j.get("status") == "completed" and j.get("conclusion") in FAILED_CONCLUSIONS:
            return "failed"
        # A failed step inside a job that is still running (e.g. the always()
        # refresh step after a failed upload) already decides the platform.
        if any((st or {}).get("conclusion") == "failure" for st in j.get("steps") or []):
            return "failed"
    if any(j.get("status") == "completed" and j.get("conclusion") == "cancelled" for j in rel):
        return "superseded"
    if all(j.get("status") == "completed" for j in rel):
        if all(j.get("conclusion") == "success" for j in rel):
            return "built"
        return None
    if any(j.get("status") in ("in_progress", "completed") for j in rel):
        return "building"
    return "queued"


def platform_entry(has_asset: bool, run: Optional[dict], state: Optional[str] = None) -> dict:
    if has_asset:
        return {"state": "ok"}
    if run is None:
        return {"state": "none"}
    entry = {"state": state or run_state(run)}
    if run.get("html_url"):
        entry["url"] = run["html_url"]
    return entry


def classify_chain(chain: Sequence[Tuple[str, str]]) -> Tuple[List[int], List[dict]]:
    """Split first-parent commits (newest first) into PR numbers and direct pushes."""
    prs: List[int] = []
    direct: List[dict] = []
    for sha, subject in chain:
        n = pr_number_of(subject)
        if n is None:
            direct.append({"sha": sha, "subject": subject})
        elif n not in prs:
            prs.append(n)
    return prs, direct


# --------------------------------------------------------------------------- #
# Injectable I/O
# --------------------------------------------------------------------------- #


class Git:
    """Read-only access to the local clone (commit graph only)."""

    def __init__(self, repo_dir: str) -> None:
        self.repo_dir = repo_dir
        self._count: Dict[str, Optional[int]] = {}

    def _run(self, args: List[str], check: bool = True) -> Optional[str]:
        proc = subprocess.run(
            ["git", "-C", self.repo_dir, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        if proc.returncode != 0:
            if check:
                raise RuntimeError(
                    f"git {' '.join(args)} failed: {proc.stderr.strip()}"
                )
            return None
        return proc.stdout

    def resolve(self, rev: str) -> Optional[str]:
        """Full sha of a commit-ish, or None when it is not in local history."""
        out = self._run(["rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"], check=False)
        return out.strip() if out else None

    def count(self, sha: str) -> Optional[int]:
        """``git rev-list --count <sha>``; None when the commit is unknown."""
        if sha not in self._count:
            out = self._run(["rev-list", "--count", f"{sha}^{{commit}}", "--"], check=False)
            self._count[sha] = int(out.strip()) if out and out.strip().isdigit() else None
        return self._count[sha]

    def parents(self, head: str) -> Dict[str, List[str]]:
        """Every commit reachable from head -> its parents (one git call)."""
        out = self._run(["rev-list", "--parents", head]) or ""
        graph: Dict[str, List[str]] = {}
        for line in out.splitlines():
            parts = line.split()
            if parts:
                graph[parts[0]] = parts[1:]
        return graph

    def first_parent_shas(self, head: str) -> List[str]:
        """develop's first-parent chain, newest first."""
        out = self._run(["rev-list", "--first-parent", head]) or ""
        return out.split()

    def first_parent_log(self, base: str, head: str, limit: int) -> List[Tuple[str, str]]:
        """``git log --first-parent base..head`` as (sha, subject), newest first."""
        out = self._run(
            ["log", "--first-parent", f"-n{limit}", "--format=%H%x1f%s", f"{base}..{head}"]
        ) or ""
        rows: List[Tuple[str, str]] = []
        for line in out.splitlines():
            if "\x1f" in line:
                sha, subject = line.split("\x1f", 1)
                rows.append((sha, subject))
        return rows


class GitHubApi:
    """Minimal REST + GraphQL client on GITHUB_TOKEN."""

    def __init__(self, token: str, base: str = "https://api.github.com") -> None:
        self.token = token
        self.base = base

    def _request(self, url: str, body: Optional[bytes] = None) -> object:
        req = urllib.request.Request(url, data=body)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "fushi-debug-pulse")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        if body is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def get(self, path: str) -> object:
        return self._request(self.base + path)

    def graphql(self, query: str, variables: dict) -> dict:
        data = self._request(
            self.base + "/graphql",
            json.dumps({"query": query, "variables": variables}).encode("utf-8"),
        )
        if not isinstance(data, dict) or data.get("errors"):
            raise RuntimeError(f"GraphQL error: {data.get('errors') if isinstance(data, dict) else data}")
        return data.get("data") or {}


def fetch_rolling_assets(api: GitHubApi, repo: str) -> List[dict]:
    """Assets of the rolling debug release; [] only when the release is absent.

    Any other failure raises: publishing an empty build list because one request
    flaked would tell every debug client their build vanished.
    """
    try:
        rel = api.get(f"/repos/{repo}/releases/tags/{ROLLING_TAG}")
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return []
        raise
    return list((rel or {}).get("assets") or []) if isinstance(rel, dict) else []


def fetch_runs(api: GitHubApi, repo: str, workflow: str) -> List[dict]:
    """Push runs of a release workflow on develop (the debug channel), newest first."""
    data = api.get(
        f"/repos/{repo}/actions/workflows/{workflow}/runs"
        f"?branch=develop&event=push&per_page={RUNS_PER_WORKFLOW}"
    )
    runs = data.get("workflow_runs") if isinstance(data, dict) else None
    out = []
    for r in runs or []:
        if r.get("event") != "push":
            continue
        out.append({
            "id": r.get("id"),
            "workflow": workflow,
            "head_sha": r.get("head_sha") or "",
            "status": r.get("status") or "",
            "conclusion": r.get("conclusion"),
            "html_url": r.get("html_url") or "",
            "updated_at": r.get("updated_at") or "",
        })
    return out


def fetch_jobs(api: GitHubApi, repo: str, run_id: int) -> List[dict]:
    data = api.get(f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")
    jobs = data.get("jobs") if isinstance(data, dict) else None
    return [
        {
            "name": j.get("name"),
            "status": j.get("status"),
            "conclusion": j.get("conclusion"),
            "steps": [{"conclusion": st.get("conclusion")} for st in j.get("steps") or []],
        }
        for j in jobs or []
    ]


def fetch_prs(api: GitHubApi, repo: str, numbers: Iterable[int]) -> Dict[int, dict]:
    """PR metadata in GraphQL batches (one request per PR_GRAPHQL_BATCH PRs)."""
    owner, name = repo.split("/", 1)
    nums = sorted(set(numbers))
    out: Dict[int, dict] = {}
    fields = (
        "number title mergedAt additions deletions author { login } "
        "labels(first: 20) { nodes { name } }"
    )
    for start in range(0, len(nums), PR_GRAPHQL_BATCH):
        chunk = nums[start:start + PR_GRAPHQL_BATCH]
        parts = " ".join(f"p{n}: pullRequest(number: {n}) {{ {fields} }}" for n in chunk)
        query = (
            "query($owner: String!, $name: String!) { "
            f"repository(owner: $owner, name: $name) {{ {parts} }} }}"
        )
        data = api.graphql(query, {"owner": owner, "name": name})
        for node in ((data.get("repository") or {}).values()):
            if not node:
                continue
            out[int(node["number"])] = {
                "number": int(node["number"]),
                "title": node.get("title") or "",
                "author": ((node.get("author") or {}).get("login")) or "",
                "mergedAt": node.get("mergedAt"),
                "additions": int(node.get("additions") or 0),
                "deletions": int(node.get("deletions") or 0),
                "labels": [l["name"] for l in ((node.get("labels") or {}).get("nodes") or []) if l],
            }
    return out


# --------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------- #


def placeholder_pr(n: int) -> dict:
    return {
        "number": n, "title": f"#{n}", "author": "", "mergedAt": None,
        "additions": 0, "deletions": 0, "labels": [],
    }


def cached_prs(previous: Optional[dict]) -> Dict[int, dict]:
    """Reusable PR entries of the previous file: only merged ones (immutable
    enough); placeholders (mergedAt null) are re-fetched."""
    out: Dict[int, dict] = {}
    if not isinstance(previous, dict) or previous.get("schema") != SCHEMA:
        return out
    for key, pr in (previous.get("prs") or {}).items():
        if isinstance(pr, dict) and pr.get("mergedAt"):
            try:
                out[int(key)] = pr
            except ValueError:
                continue
    return out


class _Seqs:
    """seq <-> sha resolution on local git.

    ``git rev-list --count`` walks the whole history per call (~0.3 s each on a
    Windows runner, and a refresh needs ~100 of them), so the counts of every
    commit on develop's first-parent chain are computed in ONE pass over the
    commit graph instead: walking the chain oldest -> newest and flood-filling
    each commit's not-yet-seen ancestors keeps ``seen`` == ancestors(c_i), so
    count(c_i) == len(seen). Release runs build develop tips, which all sit on
    that chain; anything off it falls back to ``git rev-list --count``.
    """

    def __init__(self, git: Git, floor: int, head: str) -> None:
        self.git = git
        self.floor = floor
        self.head = head
        self._by_sha: Optional[Dict[str, int]] = None
        self._by_seq: Dict[int, str] = {}

    def _chain_counts(self) -> Dict[str, int]:
        if self._by_sha is None:
            graph = self.git.parents(self.head)
            chain = list(reversed(self.git.first_parent_shas(self.head)))
            seen = set()
            counts: Dict[str, int] = {}
            for c in chain:
                stack = [c]
                while stack:
                    x = stack.pop()
                    if x in seen:
                        continue
                    seen.add(x)
                    stack.extend(p for p in graph.get(x, ()) if p not in seen)
                counts[c] = len(seen)
            self._by_sha = counts
            self._by_seq = {n + self.floor: sha for sha, n in counts.items()}
        return self._by_sha

    def seq_of(self, sha: str) -> Optional[int]:
        n = self._chain_counts().get(sha)
        if n is None:
            n = self.git.count(sha)
        return None if n is None else n + self.floor

    def sha_on_chain(self, seq: int) -> Optional[str]:
        """Commit on develop's first-parent chain with this seq."""
        self._chain_counts()
        return self._by_seq.get(seq)


def _contents(git: Git, base: str, head: str) -> Tuple[List[int], List[dict], bool]:
    chain = git.first_parent_log(base, head, MAX_CHAIN + 1)
    truncated = len(chain) > MAX_CHAIN
    prs, direct = classify_chain(chain[:MAX_CHAIN])
    return prs, direct, truncated


def build_report(
    *,
    repo: str,
    git: Git,
    floor: int,
    head: str,
    assets: Sequence[dict],
    runs: Sequence[dict],
    pr_fetcher: Callable[[List[int]], Dict[int, dict]],
    jobs_fetcher: Optional[Callable[[int], List[dict]]] = None,
    previous: Optional[dict] = None,
    now: Optional[dt.datetime] = None,
    log: Callable[[str], None] = lambda msg: print(msg, file=sys.stderr),
) -> dict:
    head_sha = git.resolve(head)
    if not head_sha:
        raise SystemExit(f"cannot resolve develop head {head!r}")
    seqs = _Seqs(git, floor, head_sha)
    head_seq = seqs.seq_of(head_sha)

    # 1. Builds from rolling-release asset names.
    by_seq: Dict[int, dict] = {}
    for a in assets:
        info = parse_asset_name(a.get("name") or "")
        if info is None:
            continue
        b = by_seq.setdefault(info["seq"], {
            "seq": info["seq"], "version": info["version"], "sha7": None,
            "platforms": set(), "publishedAt": "",
        })
        if info["sha7"] and not b["sha7"]:
            b["sha7"] = info["sha7"]
        b["platforms"].add(info["platform"])
        updated = a.get("updated_at") or ""
        if updated > b["publishedAt"]:
            b["publishedAt"] = updated
    ordered = sorted(by_seq.values(), key=lambda b: b["seq"], reverse=True)[:MAX_BUILDS]

    # 2. seq of every run's head commit (local git, no API).
    run_rows = []
    for r in runs:
        seq = seqs.seq_of(r["head_sha"]) if r.get("head_sha") else None
        run_rows.append(dict(r, seq=seq))
    run_sha_by_seq: Dict[int, str] = {}
    for r in run_rows:
        if r["seq"] is not None:
            run_sha_by_seq.setdefault(r["seq"], r["head_sha"])

    # 3. seq -> sha: release run head (exact), else asset sha7, else develop's
    #    first-parent chain. A candidate whose count disagrees with the seq is
    #    rejected rather than trusted.
    for b in ordered:
        sha = None
        candidates = []
        if b["seq"] in run_sha_by_seq:
            candidates.append(run_sha_by_seq[b["seq"]])
        if b["sha7"]:
            candidates.append(b["sha7"])
        for cand in candidates:
            full = git.resolve(cand)
            if full and seqs.seq_of(full) == b["seq"]:
                sha = full
                break
        if sha is None:
            sha = seqs.sha_on_chain(b["seq"])
        b["sha"] = sha

    def runs_for(seq: int, workflow: str) -> List[dict]:
        return [r for r in run_rows if r["seq"] == seq and r["workflow"] == workflow]

    jobs_cache: Dict[int, Optional[List[dict]]] = {}

    def platform(p: str, has_asset: bool, run: Optional[dict]) -> dict:
        """Asset first; else the run, refined by its jobs while it is live or
        did not succeed (one jobs request per such run, cached)."""
        if has_asset or run is None:
            return platform_entry(has_asset, run)
        state = None
        needs_jobs = run.get("status") != "completed" or (
            run.get("conclusion") not in ("success",) and run.get("conclusion") not in SUPERSEDED_CONCLUSIONS
        )
        if jobs_fetcher is not None and needs_jobs and run.get("id") is not None:
            rid = run["id"]
            if rid not in jobs_cache:
                try:
                    jobs_cache[rid] = jobs_fetcher(rid)
                except Exception as err:  # fall back to the run-level state
                    log(f"::warning title=Run jobs::run {rid}: {err}")
                    jobs_cache[rid] = None
            if jobs_cache[rid]:
                state = jobs_state(jobs_cache[rid], PLATFORM_JOBS[p])
        return platform_entry(False, run, state)

    # 4. Contents: previous known build, else (oldest build) the newest
    #    successful release run below it -- its predecessor was pruned.
    builds_out: List[dict] = []
    referenced: List[int] = []
    for i, b in enumerate(ordered):
        entry = {
            "seq": b["seq"], "version": b["version"], "sha": b["sha"],
            "unknown": b["sha"] is None, "publishedAt": b["publishedAt"] or None,
            "testflight": b["seq"] % 3 == 0 and "ios" in b["platforms"],
            "baseSeq": None, "prs": [], "direct": [], "truncated": False,
        }
        if b["sha"]:
            base_sha, base_seq = None, None
            for older in ordered[i + 1:]:
                if older["sha"]:
                    base_sha, base_seq = older["sha"], older["seq"]
                    break
            if base_sha is None:
                ok = [
                    r for r in run_rows
                    if r["seq"] is not None and r["seq"] < b["seq"]
                    and r["status"] == "completed" and r.get("conclusion") == "success"
                ]
                if ok:
                    best = max(ok, key=lambda r: r["seq"])
                    base_sha, base_seq = best["head_sha"], best["seq"]
            if base_sha:
                prs, direct, truncated = _contents(git, base_sha, b["sha"])
                entry.update(baseSeq=base_seq, prs=prs, direct=direct, truncated=truncated)
                referenced.extend(prs)
        entry["platforms"] = {
            p: platform(p, p in b["platforms"], pick_run(runs_for(b["seq"], PLATFORM_WORKFLOWS[p])))
            for p in PLATFORMS
        }
        builds_out.append(entry)

    # 5. Pending: develop tip newer than the newest identified build.
    pending = None
    latest = next((b for b in ordered if b["sha"]), None)
    if latest is not None and head_sha != latest["sha"] and (head_seq or 0) > latest["seq"]:
        prs, direct, truncated = _contents(git, latest["sha"], head_sha)
        referenced.extend(prs)
        platforms = {}
        for p in PLATFORMS:
            newer = [
                r for r in run_rows
                if r["workflow"] == PLATFORM_WORKFLOWS[p]
                and r["seq"] is not None and r["seq"] > latest["seq"]
            ]
            run = None
            if newer:
                top = max(r["seq"] for r in newer)
                run = pick_run([r for r in newer if r["seq"] == top])
            platforms[p] = platform(p, False, run)
        pending = {
            "headSha": head_sha, "headSeq": head_seq, "prs": prs,
            "direct": direct, "truncated": truncated, "platforms": platforms,
        }

    # 6. PR metadata: cache from the previous file, fetch the rest.
    cache = cached_prs(previous)
    need = sorted(set(referenced))
    missing = [n for n in need if n not in cache]
    fetched: Dict[int, dict] = {}
    if missing:
        try:
            fetched = pr_fetcher(missing)
        except Exception as err:  # metadata is decoration; contents stay exact
            log(f"::warning title=PR metadata::fetching {len(missing)} PRs failed: {err}")
    log(f"PR metadata: {len(need)} referenced, {len(need) - len(missing)} cached, {len(fetched)} fetched")
    prs_out = {}
    for n in need:
        pr = cache.get(n) or fetched.get(n) or placeholder_pr(n)
        prs_out[str(n)] = {
            "number": n,
            "title": pr.get("title") or f"#{n}",
            "author": pr.get("author") or "",
            "mergedAt": pr.get("mergedAt"),
            "additions": int(pr.get("additions") or 0),
            "deletions": int(pr.get("deletions") or 0),
            "labels": list(pr.get("labels") or []),
        }

    moment = now or dt.datetime.now(dt.timezone.utc)
    return {
        "schema": SCHEMA,
        "generatedAt": moment.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repo": repo,
        "develop": {"sha": head_sha, "seq": head_seq},
        "builds": builds_out,
        "pending": pending,
        "prs": prs_out,
    }


def dump(report: dict) -> str:
    return json.dumps(report, ensure_ascii=False, indent=1) + "\n"


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--head", default="HEAD", help="develop tip (commit-ish)")
    ap.add_argument("--git-dir", default=".", help="local clone with develop history")
    ap.add_argument("--previous", help="previous debug-pulse-fushi.json (PR cache); may be missing")
    ap.add_argument("--out", required=True)
    ap.add_argument(
        "--release-sequence-script",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "release_sequence.sh"),
    )
    args = ap.parse_args(argv)

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print("GITHUB_TOKEN is required", file=sys.stderr)
        return 2
    api = GitHubApi(token)
    floor = read_sequence_floor(args.release_sequence_script)

    previous = None
    if args.previous and os.path.isfile(args.previous):
        try:
            with open(args.previous, encoding="utf-8") as f:
                previous = json.load(f)
        except (OSError, ValueError) as err:
            print(f"::warning title=Previous pulse unreadable::{err}", file=sys.stderr)

    assets = fetch_rolling_assets(api, args.repo)
    runs: List[dict] = []
    for wf in RELEASE_WORKFLOWS:
        runs.extend(fetch_runs(api, args.repo, wf))

    report = build_report(
        repo=args.repo,
        git=Git(args.git_dir),
        floor=floor,
        head=args.head,
        assets=assets,
        runs=runs,
        pr_fetcher=lambda nums: fetch_prs(api, args.repo, nums),
        jobs_fetcher=lambda rid: fetch_jobs(api, args.repo, rid),
        previous=previous,
    )
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write(dump(report))
    print(
        f"debug pulse: {len(report['builds'])} builds, "
        f"pending={'yes' if report['pending'] else 'no'}, {len(report['prs'])} PRs -> {args.out}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
