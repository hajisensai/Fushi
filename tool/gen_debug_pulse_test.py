#!/usr/bin/env python3
"""Unit tests for gen_debug_pulse.

Run:  python3 tool/gen_debug_pulse_test.py

A scratch git repository stands in for develop (real merge commits, squash
subjects, direct pushes) and canned dicts stand in for the GitHub API, so every
branch of the seq / base / contents / platform-state logic runs offline.
"""

from __future__ import annotations

import datetime as dt
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from typing import Dict, List, Optional

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOL_DIR)
sys.path.insert(0, TOOL_DIR)

import gen_debug_pulse as gp  # noqa: E402

FLOOR = gp.read_sequence_floor(os.path.join(TOOL_DIR, "release_sequence.sh"))


def _git(repo: str, *args: str) -> str:
    env = dict(os.environ)
    env.update({
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
        "GIT_CONFIG_NOSYSTEM": "1", "HOME": repo,
    })
    return subprocess.run(
        ["git", "-C", repo, *args], check=True, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    ).stdout.strip()


class FakeRepo:
    """develop history built commit by commit; returns full shas."""

    def __init__(self) -> None:
        self.dir = tempfile.mkdtemp(prefix="debug-pulse-test-")
        _git(self.dir, "init", "-q", "-b", "develop")
        _git(self.dir, "config", "commit.gpgsign", "false")

    def commit(self, subject: str) -> str:
        _git(self.dir, "commit", "-q", "--allow-empty", "-m", subject)
        return _git(self.dir, "rev-parse", "HEAD")

    def merge_pr(self, number: int, branch_commits: int = 2) -> str:
        branch = f"pr{number}"
        _git(self.dir, "checkout", "-q", "-b", branch)
        for i in range(branch_commits):
            self.commit(f"work {number}.{i}")
        _git(self.dir, "checkout", "-q", "develop")
        _git(self.dir, "merge", "-q", "--no-ff", "-m",
             f"Merge pull request #{number} from someone/{branch}", branch)
        return _git(self.dir, "rev-parse", "HEAD")

    def seq(self, sha: str) -> int:
        return int(_git(self.dir, "rev-list", "--count", sha)) + FLOOR

    def cleanup(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)


def asset(seq: int, platform: str, sha7: Optional[str] = None,
          updated: str = "2026-11-10T00:00:00Z") -> dict:
    mid = f"{seq}-{sha7}" if sha7 else str(seq)
    tail = {
        "android": "debug.apk",
        "windows": "windows-setup.exe",
        "macos": "macos-arm64.zip",
        "ios": "ios.ipa",
    }[platform]
    return {"name": f"fushi-3.3.0-debug.{mid}-{tail}", "updated_at": updated}


def run(workflow: str, sha: str, status: str = "completed",
        conclusion: Optional[str] = "success", updated: str = "2026-11-10T00:00:00Z",
        url: str = "https://example/run") -> dict:
    return {"workflow": workflow, "head_sha": sha, "status": status,
            "conclusion": conclusion, "html_url": url, "updated_at": updated}


def pr_meta(n: int) -> dict:
    return {"number": n, "title": f"feat: thing {n}", "author": "dev",
            "mergedAt": "2026-11-09T00:00:00Z", "additions": n, "deletions": 1,
            "labels": ["x"]}


class PureTest(unittest.TestCase):
    def test_asset_name_with_sha7(self) -> None:
        self.assertEqual(
            gp.parse_asset_name("fushi-3.3.0-debug.25034-4760a9f-debug.apk"),
            {"version": "3.3.0", "seq": 25034, "sha7": "4760a9f", "platform": "android"},
        )

    def test_asset_name_without_sha7(self) -> None:
        cases = {
            "fushi-3.3.0-debug.25010-windows-setup.exe": "windows",
            "fushi-3.3.0-debug.25010-macos-arm64.zip": "macos",
            "fushi-3.3.0-debug.25010-macos-arm64.dmg": "macos",
            "fushi-3.3.0-debug.25010-ios.ipa": "ios",
            "fushi-3.3.0-debug.25010-arm64-v8a.apk": "android",
        }
        for name, platform in cases.items():
            info = gp.parse_asset_name(name)
            self.assertIsNotNone(info, name)
            self.assertEqual(info["seq"], 25010)
            self.assertIsNone(info["sha7"], name)
            self.assertEqual(info["platform"], platform, name)

    def test_asset_name_rejects_foreign(self) -> None:
        for name in ("fushi-3.3.0-beta.1-ios.ipa", "hibiki-1.3.2-debug.10182-windows-setup.exe",
                     "fushi-3.3.0-debug.25010-linux.tar.gz", "SHA256SUMS"):
            self.assertIsNone(gp.parse_asset_name(name), name)

    def test_pr_number_of(self) -> None:
        self.assertEqual(gp.pr_number_of("Merge pull request #3101 from samutw/feat/x"), 3101)
        self.assertEqual(gp.pr_number_of("fix(reader): keep position (#2988)"), 2988)
        self.assertIsNone(gp.pr_number_of("chore: bump version"))
        self.assertIsNone(gp.pr_number_of("Merge origin/develop (#3100) into feat/x"))

    def test_run_state_mapping(self) -> None:
        self.assertEqual(gp.run_state({"status": "queued"}), "queued")
        self.assertEqual(gp.run_state({"status": "waiting"}), "queued")
        self.assertEqual(gp.run_state({"status": "pending"}), "queued")
        self.assertEqual(gp.run_state({"status": "in_progress"}), "building")
        self.assertEqual(gp.run_state({"status": "completed", "conclusion": "success"}), "built")
        self.assertEqual(gp.run_state({"status": "completed", "conclusion": "cancelled"}), "superseded")
        self.assertEqual(gp.run_state({"status": "completed", "conclusion": "skipped"}), "superseded")
        self.assertEqual(gp.run_state({"status": "completed", "conclusion": "failure"}), "failed")
        self.assertEqual(gp.run_state({"status": "completed", "conclusion": "timed_out"}), "failed")

    def test_platform_entry_all_seven_states(self) -> None:
        r = lambda status, conclusion=None: run("release.yml", "x", status, conclusion, url="u")  # noqa: E731
        got = {
            "ok": gp.platform_entry(True, r("completed", "failure")),
            "queued": gp.platform_entry(False, r("queued")),
            "building": gp.platform_entry(False, r("in_progress")),
            "built": gp.platform_entry(False, r("completed", "success")),
            "failed": gp.platform_entry(False, r("completed", "failure")),
            "superseded": gp.platform_entry(False, r("completed", "cancelled")),
            "none": gp.platform_entry(False, None),
        }
        for want, entry in got.items():
            self.assertEqual(entry["state"], want)
        self.assertNotIn("url", got["ok"])
        self.assertNotIn("url", got["none"])
        self.assertEqual(got["failed"]["url"], "u")

    def test_jobs_state(self) -> None:
        names = gp.PLATFORM_JOBS["windows"]
        job = lambda name, status, conclusion=None, steps=(): {  # noqa: E731
            "name": name, "status": status, "conclusion": conclusion,
            "steps": [{"conclusion": c} for c in steps]}
        self.assertEqual(gp.jobs_state([job("windows", "queued")], names), "queued")
        self.assertEqual(gp.jobs_state([job("windows", "in_progress")], names), "building")
        # platform job done, publish not started yet: still in the pipeline
        self.assertEqual(gp.jobs_state(
            [job("windows", "completed", "success"), job("publish", "queued")], names), "building")
        self.assertEqual(gp.jobs_state(
            [job("windows", "completed", "failure"), job("publish", "queued")], names), "failed")
        # failed step inside the still-running publish job (refresh step runs after it)
        self.assertEqual(gp.jobs_state(
            [job("windows", "completed", "success"),
             job("publish", "in_progress", None, ("success", "failure", None))], names), "failed")
        self.assertEqual(gp.jobs_state(
            [job("windows", "completed", "cancelled")], names), "superseded")
        self.assertEqual(gp.jobs_state(
            [job("windows", "completed", "success"), job("publish", "completed", "success")], names), "built")
        # other platforms' failures do not leak in
        self.assertEqual(gp.jobs_state(
            [job("ios", "completed", "failure"), job("windows", "in_progress")], names), "building")
        self.assertIsNone(gp.jobs_state([job("tests (1)", "completed", "failure")], names))

    def test_pick_run_prefers_live(self) -> None:
        old_live = run("release.yml", "a", "in_progress", None, updated="2026-01-01")
        new_done = run("release.yml", "a", "completed", "cancelled", updated="2026-02-01")
        self.assertIs(gp.pick_run([new_done, old_live]), old_live)
        self.assertIs(gp.pick_run([new_done]), new_done)
        self.assertIsNone(gp.pick_run([]))

    def test_floor_is_read_from_release_sequence_sh(self) -> None:
        with open(os.path.join(TOOL_DIR, "release_sequence.sh"), encoding="utf-8") as f:
            self.assertIn(f"RELEASE_SEQUENCE_FLOOR={FLOOR}\n", f.read())

    def test_rolling_tag_matches_release_workflows(self) -> None:
        for wf in gp.RELEASE_WORKFLOWS:
            with open(os.path.join(REPO_ROOT, ".github", "workflows", wf), encoding="utf-8") as f:
                tags = set(re.findall(r"ROLLING_DEBUG_TAG=([\w.-]+)", f.read()))
            self.assertEqual(tags, {gp.ROLLING_TAG}, wf)

    def test_cached_prs_skips_placeholders_and_other_schema(self) -> None:
        prev = {"schema": 1, "prs": {"1": pr_meta(1), "2": gp.placeholder_pr(2)}}
        self.assertEqual(set(gp.cached_prs(prev)), {1})
        self.assertEqual(gp.cached_prs({"schema": 99, "prs": {"1": pr_meta(1)}}), {})
        self.assertEqual(gp.cached_prs(None), {})


class ReportTest(unittest.TestCase):
    """End-to-end build_report over a scratch develop history."""

    def setUp(self) -> None:
        self.repo = FakeRepo()
        r = self.repo
        self.c0 = r.commit("init")
        self.b_old = r.merge_pr(10)                     # oldest still-listed build's base
        self.c_sq = r.commit("fix: squashed thing (#11)")
        self.c_direct = r.commit("chore: direct push to develop")
        self.b1 = r.merge_pr(12)                        # build 1 (oldest on the release)
        self.p13 = r.merge_pr(13)
        self.b2 = r.commit("perf: squash (#14)")        # build 2 (asset has no sha7)
        self.p15 = r.merge_pr(15)
        self.head = r.commit("docs: tweak")             # develop tip, not yet built
        self.git = gp.Git(r.dir)
        self.fetch_calls: List[List[int]] = []

    def tearDown(self) -> None:
        self.repo.cleanup()

    def fetcher(self, nums: List[int]) -> Dict[int, dict]:
        self.fetch_calls.append(list(nums))
        return {n: pr_meta(n) for n in nums}

    def report(self, assets: List[dict], runs: List[dict], previous: Optional[dict] = None,
               head: Optional[str] = None) -> dict:
        return gp.build_report(
            repo="o/r", git=self.git, floor=FLOOR, head=head or self.head,
            assets=assets, runs=runs, pr_fetcher=self.fetcher, previous=previous,
            now=dt.datetime(2026, 11, 10, 8, 0, tzinfo=dt.timezone.utc), log=lambda _: None,
        )

    def standard(self) -> dict:
        s1, s2 = self.repo.seq(self.b1), self.repo.seq(self.b2)
        sh = self.repo.seq(self.head)
        assets = [
            asset(s1, "android", self.b1[:7]), asset(s1, "windows"), asset(s1, "ios"),
            asset(s2, "android", None, updated="2026-11-10T01:00:00Z"),
            asset(s2, "windows", None, updated="2026-11-10T02:00:00Z"),
        ]
        runs = [
            # oldest build's predecessor: pruned from the release, run still listed
            run("release.yml", self.b_old),
            run("release-desktop.yml", self.b1, conclusion="failure"),
            run("release.yml", self.b2),
            run("release-desktop.yml", self.b2, conclusion="cancelled", url="https://x/sup"),
            run("release.yml", self.p15, conclusion="cancelled"),
            run("release.yml", self.head, status="in_progress", conclusion=None, url="https://x/a"),
            run("release-desktop.yml", self.head, status="queued", conclusion=None, url="https://x/d"),
        ]
        self.s1, self.s2, self.sh = s1, s2, sh
        return self.report(assets, runs)

    def test_shape_and_builds(self) -> None:
        rep = self.standard()
        self.assertEqual(rep["schema"], 1)
        self.assertEqual(rep["generatedAt"], "2026-11-10T08:00:00Z")
        self.assertEqual(rep["develop"], {"sha": self.head, "seq": self.sh})
        self.assertEqual([b["seq"] for b in rep["builds"]], [self.s2, self.s1])
        newest, oldest = rep["builds"]
        # build without sha7 resolved through its release run
        self.assertEqual(newest["sha"], self.b2)
        self.assertFalse(newest["unknown"])
        self.assertEqual(newest["publishedAt"], "2026-11-10T02:00:00Z")
        self.assertEqual(newest["baseSeq"], self.s1)
        self.assertEqual(newest["prs"], [14, 13])
        self.assertEqual(newest["direct"], [])
        self.assertFalse(newest["truncated"])
        for b in rep["builds"]:
            self.assertEqual(set(b["platforms"]), {"android", "windows", "macos", "ios"})

    def test_oldest_build_base_from_successful_run(self) -> None:
        rep = self.standard()
        oldest = rep["builds"][1]
        self.assertEqual(oldest["sha"], self.b1)
        self.assertEqual(oldest["baseSeq"], self.repo.seq(self.b_old))
        self.assertEqual(oldest["prs"], [12, 11])  # merge commit + squash subject
        self.assertEqual(oldest["direct"], [{"sha": self.c_direct, "subject": "chore: direct push to develop"}])

    def test_platform_states(self) -> None:
        rep = self.standard()
        newest, oldest = rep["builds"]
        self.assertEqual(newest["platforms"]["android"], {"state": "ok"})
        self.assertEqual(newest["platforms"]["windows"], {"state": "ok"})
        self.assertEqual(newest["platforms"]["macos"], {"state": "superseded", "url": "https://x/sup"})
        self.assertEqual(oldest["platforms"]["macos"]["state"], "failed")
        self.assertEqual(oldest["platforms"]["ios"], {"state": "ok"})

    def test_pending(self) -> None:
        rep = self.standard()
        p = rep["pending"]
        self.assertEqual(p["headSha"], self.head)
        self.assertEqual(p["headSeq"], self.sh)
        self.assertEqual(p["prs"], [15])
        self.assertEqual([d["sha"] for d in p["direct"]], [self.head])
        self.assertEqual(p["platforms"]["android"], {"state": "building", "url": "https://x/a"})
        self.assertEqual(p["platforms"]["ios"], {"state": "queued", "url": "https://x/d"})

    def test_no_pending_when_tip_is_built(self) -> None:
        s2 = self.repo.seq(self.b2)
        rep = self.report([asset(s2, "android", self.b2[:7])], [], head=self.b2)
        self.assertIsNone(rep["pending"])
        # no older build, no successful run: base unknown
        self.assertIsNone(rep["builds"][0]["baseSeq"])
        self.assertEqual(rep["builds"][0]["prs"], [])
        self.assertEqual(rep["builds"][0]["platforms"]["ios"], {"state": "none"})

    def test_sha_without_run_or_sha7_found_on_first_parent_chain(self) -> None:
        s2 = self.repo.seq(self.b2)
        rep = self.report([asset(s2, "windows")], [])
        self.assertEqual(rep["builds"][0]["sha"], self.b2)

    def test_unknown_build(self) -> None:
        # seq that no first-parent commit has (a PR-branch commit's count)
        _git(self.repo.dir, "checkout", "-q", "-b", "side", self.c0)
        side = self.repo.commit("side")
        _git(self.repo.dir, "checkout", "-q", "develop")
        bogus = self.repo.seq(self.head) + 50
        rep = self.report([asset(bogus, "ios", "abcdef1")], [])
        b = rep["builds"][0]
        self.assertTrue(b["unknown"])
        self.assertIsNone(b["sha"])
        self.assertEqual((b["prs"], b["direct"], b["baseSeq"]), ([], [], None))
        self.assertIsNone(rep["pending"])
        self.assertTrue(side)

    def test_testflight_flag(self) -> None:
        rep = self.standard()
        for b in rep["builds"]:
            has_ios = b["platforms"]["ios"]["state"] == "ok"
            self.assertEqual(b["testflight"], b["seq"] % 3 == 0 and has_ios)

    def test_prs_map_and_cache(self) -> None:
        rep = self.standard()
        self.assertEqual(set(rep["prs"]), {"11", "12", "13", "14", "15"})
        self.assertEqual(rep["prs"]["13"]["title"], "feat: thing 13")
        self.fetch_calls.clear()
        again = self.report(
            [asset(self.s1, "android", self.b1[:7]), asset(self.s2, "windows")],
            [run("release.yml", self.b_old), run("release.yml", self.b2)],
            previous=rep,
        )
        self.assertEqual(self.fetch_calls, [])
        self.assertEqual(again["prs"]["14"]["additions"], 14)

    def test_live_run_refined_by_jobs(self) -> None:
        s2 = self.repo.seq(self.b2)
        live = dict(run("release-desktop.yml", self.head, status="in_progress", conclusion=None), id=7)
        calls: List[int] = []

        def jobs(rid: int) -> List[dict]:
            calls.append(rid)
            return [
                {"name": "windows", "status": "completed", "conclusion": "failure", "steps": []},
                {"name": "macos", "status": "in_progress", "conclusion": None, "steps": []},
                {"name": "ios", "status": "completed", "conclusion": "success", "steps": []},
                {"name": "publish", "status": "queued", "conclusion": None, "steps": []},
            ]
        rep = gp.build_report(
            repo="o/r", git=self.git, floor=FLOOR, head=self.head,
            assets=[asset(s2, "android", self.b2[:7])], runs=[live],
            pr_fetcher=self.fetcher, jobs_fetcher=jobs, log=lambda _: None,
        )
        plats = rep["pending"]["platforms"]
        self.assertEqual(
            {k: v["state"] for k, v in plats.items()},
            {"android": "none", "windows": "failed", "macos": "building", "ios": "building"},
        )
        self.assertEqual(calls, [7])  # one jobs request per run, cached

    def test_fetch_failure_writes_placeholders(self) -> None:
        def boom(_nums: List[int]) -> Dict[int, dict]:
            raise RuntimeError("rate limited")
        s2 = self.repo.seq(self.b2)
        rep = gp.build_report(
            repo="o/r", git=self.git, floor=FLOOR, head=self.head,
            assets=[asset(s2, "android", self.b2[:7])], runs=[run("release.yml", self.b1)],
            pr_fetcher=boom, log=lambda _: None,
        )
        self.assertEqual(rep["prs"]["13"], gp.placeholder_pr(13))

    def test_truncation(self) -> None:
        old = gp.MAX_CHAIN
        gp.MAX_CHAIN = 2
        try:
            rep = self.standard()
        finally:
            gp.MAX_CHAIN = old
        oldest = rep["builds"][1]
        self.assertTrue(oldest["truncated"])
        self.assertEqual(oldest["prs"], [12])
        self.assertEqual(len(oldest["direct"]), 1)

    def test_dump_is_lf_json(self) -> None:
        text = gp.dump(self.standard())
        self.assertTrue(text.endswith("}\n"))
        self.assertNotIn("\r", text)


if __name__ == "__main__":
    unittest.main(verbosity=1)
