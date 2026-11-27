#!/usr/bin/env python3
"""Unit tests for server_release_plan (automatic fushi_server releases).

Run:  python3 tool/server_release_plan_test.py   (no network, no framework)
"""

from __future__ import annotations

import os
import sys
import unittest
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from server_release_plan import (  # noqa: E402
    DEBUG_TAG,
    SERVER_BUILD_FLOOR,
    Plan,
    count_failures,
    debug_change_is_relevant,
    debug_paused,
    plan_auto,
    target_key,
    workflow_file_of,
)

SRC = "hajisensai/Fushi"
SRV = "hajisensai/fushi-server"
HEAD = "a" * 40
OLD = "b" * 40
FORMAL_SHA = "c" * 40
BETA_SHA = "d" * 40


class FakeApi:
    def __init__(self, routes: Dict[str, object]) -> None:
        self.routes = routes
        self.calls: List[str] = []

    def __call__(self, endpoint: str) -> Optional[object]:
        self.calls.append(endpoint)
        return self.routes.get(endpoint)


def _routes(**overrides: object) -> Dict[str, object]:
    routes: Dict[str, object] = {
        f"repos/{SRC}/releases/latest": {
            "tag_name": "v3.3.0", "target_commitish": FORMAL_SHA,
            "draft": False, "prerelease": False,
        },
        f"repos/{SRC}/releases?per_page=50": [
            {"tag_name": "fushi-debug-rolling", "prerelease": True, "draft": False},
            {"tag_name": "v2.7.0-beta.14929", "target_commitish": BETA_SHA,
             "prerelease": True, "draft": False},
            {"tag_name": "v2.6.0-beta.14741", "target_commitish": "e" * 40,
             "prerelease": True, "draft": False},
            {"tag_name": "v3.0.1", "prerelease": True, "draft": False},
        ],
        f"repos/{SRV}/releases/tags/v3.3.0": {"id": 1},
        f"repos/{SRV}/releases/tags/v2.7.0-beta.14929": {"id": 2},
        f"repos/{SRC}/commits/develop": {"sha": HEAD},
        f"repos/{SRV}/releases/tags/{DEBUG_TAG}": {"body": f"x\n\nsource-sha: {OLD}"},
        f"repos/{SRC}/compare/{OLD}...{HEAD}": {
            "status": "ahead",
            "files": [{"filename": "packages/fushi_server/lib/a.dart"}],
        },
        f"repos/{SRC}/compare/{SERVER_BUILD_FLOOR}...{FORMAL_SHA}": {"status": "ahead"},
        f"repos/{SRC}/compare/{SERVER_BUILD_FLOOR}...{BETA_SHA}": {"status": "ahead"},
    }
    for k, v in overrides.items():
        routes[k.replace("SRC", SRC).replace("SRV", SRV)] = v
    return routes


def _plan(
    routes: Dict[str, object],
    failures: Optional[Dict[str, int]] = None,
    pause_debug: bool = False,
) -> Plan:
    warnings: List[str] = []
    return plan_auto(FakeApi(routes), failures or {}, SRC, SRV, warnings.append,
                     pause_debug=pause_debug)


class PlanAutoTest(unittest.TestCase):
    def test_formal_without_server_release_comes_first(self) -> None:
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/v3.3.0"]
        del routes[f"repos/{SRV}/releases/tags/v2.7.0-beta.14929"]
        self.assertEqual(_plan(routes), Plan("formal", FORMAL_SHA, "v3.3.0",
                                             "app formal v3.3.0 has no server release"))

    def test_newest_beta_by_sequence(self) -> None:
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/v2.7.0-beta.14929"]
        p = _plan(routes)
        self.assertEqual((p.channel, p.source_ref, p.tag_name),
                         ("beta", BETA_SHA, "v2.7.0-beta.14929"))

    def test_tag_resolved_through_commits_api_when_commitish_is_a_branch(self) -> None:
        routes = _routes(**{"SRC/commits/v3.3.0": {"sha": FORMAL_SHA}})
        routes[f"repos/{SRC}/releases/latest"]["target_commitish"] = "main"
        routes[f"repos/{SRC}/commits/v3.3.0"] = {"sha": FORMAL_SHA}
        del routes[f"repos/{SRV}/releases/tags/v3.3.0"]
        self.assertEqual(_plan(routes).source_ref, FORMAL_SHA)

    def test_debug_when_develop_moved(self) -> None:
        p = _plan(_routes())
        self.assertEqual((p.channel, p.source_ref, p.tag_name), ("debug", HEAD, ""))

    def test_paused_debug_is_not_planned(self) -> None:
        api = FakeApi(_routes())
        p = plan_auto(api, {}, SRC, SRV, [].append, pause_debug=True)
        self.assertEqual(p.channel, "")
        self.assertIn("paused", p.reason)
        self.assertNotIn(f"repos/{SRC}/commits/develop", api.calls)

    def test_pause_does_not_hold_back_formal_or_beta(self) -> None:
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/v3.3.0"]
        self.assertEqual(_plan(routes, pause_debug=True).channel, "formal")
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/v2.7.0-beta.14929"]
        self.assertEqual(_plan(routes, pause_debug=True).channel, "beta")

    def test_debug_first_build_without_rolling_release(self) -> None:
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/{DEBUG_TAG}"]
        self.assertEqual(_plan(routes).channel, "debug")

    def test_nothing_when_debug_is_current(self) -> None:
        routes = _routes()
        routes[f"repos/{SRV}/releases/tags/{DEBUG_TAG}"] = {"body": f"source-sha: {HEAD}"}
        self.assertEqual(_plan(routes).channel, "")

    def test_docs_and_app_only_changes_skip_debug(self) -> None:
        routes = _routes()
        routes[f"repos/{SRC}/compare/{OLD}...{HEAD}"] = {
            "status": "ahead",
            "files": [{"filename": "docs/BUGS.md"}, {"filename": "fushi/lib/main.dart"},
                      {"filename": "README.md"}],
        }
        self.assertEqual(_plan(routes).channel, "")

    def test_failed_target_is_skipped_and_next_channel_runs(self) -> None:
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/v3.3.0"]
        p = _plan(routes, {"v3.3.0": 2})
        self.assertEqual(p.channel, "debug")

    def test_single_failure_is_retried(self) -> None:
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/v3.3.0"]
        self.assertEqual(_plan(routes, {"v3.3.0": 1}).channel, "formal")

    def test_failing_debug_head_is_not_rebuilt(self) -> None:
        self.assertEqual(_plan(_routes(), {target_key("debug", "", HEAD): 2}).channel, "")

    def test_release_older_than_build_floor_is_skipped_for_next_channel(self) -> None:
        # App v3.3.0 predates the server bundle scripts and the Flutter 3.50 pin.
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/v3.3.0"]
        del routes[f"repos/{SRV}/releases/tags/v2.7.0-beta.14929"]
        routes[f"repos/{SRC}/compare/{SERVER_BUILD_FLOOR}...{FORMAL_SHA}"] = {
            "status": "diverged"}
        warnings: List[str] = []
        p = plan_auto(FakeApi(routes), {}, SRC, SRV, warnings.append)
        self.assertEqual((p.channel, p.tag_name), ("beta", "v2.7.0-beta.14929"))
        self.assertTrue(any("predates the server build floor" in w for w in warnings))

    def test_floor_itself_is_buildable(self) -> None:
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/v3.3.0"]
        routes[f"repos/{SRC}/compare/{SERVER_BUILD_FLOOR}...{FORMAL_SHA}"] = {
            "status": "identical"}
        self.assertEqual(_plan(routes).channel, "formal")

    def test_unknown_compare_is_not_buildable(self) -> None:
        routes = _routes()
        del routes[f"repos/{SRV}/releases/tags/v3.3.0"]
        del routes[f"repos/{SRC}/compare/{SERVER_BUILD_FLOOR}...{FORMAL_SHA}"]
        self.assertEqual(_plan(routes).channel, "debug")


class HelpersTest(unittest.TestCase):
    def test_relevance(self) -> None:
        self.assertTrue(debug_change_is_relevant(None))
        self.assertTrue(debug_change_is_relevant({"status": "diverged", "files": []}))
        self.assertTrue(debug_change_is_relevant(
            {"status": "ahead", "files": [{"filename": "fushi/pubspec.yaml"}]}))
        self.assertTrue(debug_change_is_relevant(
            {"status": "ahead", "files": [{"filename": "fushi/assets/transforms/x.json"}]}))
        self.assertTrue(debug_change_is_relevant(
            {"status": "ahead", "files": [{"filename": "docs/a.md"}] * 300}))
        self.assertFalse(debug_change_is_relevant(
            {"status": "ahead", "files": [{"filename": "fushi/lib/x.dart"}]}))

    def test_debug_paused_only_on_exact_true(self) -> None:
        self.assertTrue(debug_paused("true"))
        self.assertTrue(debug_paused("TRUE"))  # expression == ignores case
        for value in ("", "false", " true", "1", "yes"):
            self.assertFalse(debug_paused(value), value)

    def test_workflow_file_of(self) -> None:
        self.assertEqual(workflow_file_of(
            "hajisensai/fushi-server/.github/workflows/release.yml@refs/heads/main"),
            "release.yml")

    def test_count_failures_once_per_run(self) -> None:
        api = FakeApi({
            f"repos/{SRV}/actions/workflows/release.yml/runs?status=failure&per_page=10":
                {"workflow_runs": [{"id": 1}, {"id": 2}]},
            f"repos/{SRV}/actions/runs/1/jobs?per_page=100": {"jobs": [
                {"name": "release / linux [target:v3.3.0]", "conclusion": "failure"},
                {"name": "release / windows [target:v3.3.0]", "conclusion": "failure"},
            ]},
            f"repos/{SRV}/actions/runs/2/jobs?per_page=100": {"jobs": [
                {"name": "release / linux [target:v3.3.0]", "conclusion": "failure"},
                {"name": "release / docker [target:debug@aaaaaaaaaaaa]", "conclusion": "success"},
            ]},
        })
        self.assertEqual(count_failures(api, SRV, "release.yml"), {"v3.3.0": 2})


if __name__ == "__main__":
    unittest.main()
