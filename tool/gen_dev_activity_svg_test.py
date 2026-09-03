#!/usr/bin/env python3
"""Standalone unit tests for gen_dev_activity_svg.

Run:  python3 tool/gen_dev_activity_svg_test.py
Exits non-zero on the first failed assertion. No test framework required.

Covers the parts that silently produce a *plausible but wrong* chart:
  * channel classification against every tag shape actually present in the
    repository's release list (including the ones that must be excluded)
  * timezone handling -- `git log %cI` emits the committer's local offset, so a
    commit made at 2026-08-17T07:30+08:00 belongs to the *previous* UTC week
  * week bucketing boundaries and out-of-window drops
  * that render_svg emits well-formed XML (an unescaped repo name or branch
    name would otherwise produce a broken image that still commits cleanly)
"""

from __future__ import annotations

import datetime as dt
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_dev_activity_svg import (  # noqa: E402
    CHANNELS,
    RUNS_LIST_CAP,
    bucket_by_week,
    build_week_axis,
    classify_release,
    collect_run_pages,
    escape_xml,
    fetch_commit_times,
    nice_ceiling,
    parse_git_log,
    parse_iso_utc,
    render_svg,
    week_start,
)

_FAILURES: list = []


def check(condition: bool, message: str) -> None:
    if not condition:
        _FAILURES.append(message)
        print(f"FAIL: {message}", file=sys.stderr)


def utc(text: str) -> dt.datetime:
    return parse_iso_utc(text)


def test_classify_real_tags() -> None:
    """Every tag shape observed in hajisensai/Fushi's release list."""
    # Real stable releases.
    check(classify_release("v2.1.1", False, False) == "stable", "v2.1.1 -> stable")
    check(classify_release("v1.0.0", False, False) == "stable", "v1.0.0 -> stable")
    check(
        classify_release("v0.11.1", False, False) == "stable",
        "v0.11.1 -> stable",
    )

    # Real beta releases.
    check(
        classify_release("v2.0.0-beta.11553", True, False) == "beta",
        "v2.0.0-beta.11553 -> beta",
    )
    check(
        classify_release("v1.0.1-beta.6093", True, False) == "beta",
        "v1.0.1-beta.6093 -> beta",
    )

    # The rolling debug tags carry no per-build history and must never be
    # counted as a channel release; the debug lane comes from Actions runs.
    check(
        classify_release("fushi-debug-rolling", True, False) is None,
        "fushi-debug-rolling excluded",
    )
    check(
        classify_release("debug-rolling", True, False) is None,
        "debug-rolling excluded",
    )

    # Not part of the three-channel system.
    check(
        classify_release("vendor-libmpv", True, False) is None,
        "vendor-libmpv excluded",
    )
    check(classify_release("2.9.1", False, False) is None, "2.9.1 excluded")
    check(
        classify_release("2.9.0-preview3", False, False) is None,
        "2.9.0-preview3 excluded",
    )
    check(
        classify_release("v0.4.0-rc1", False, False) is None,
        "v0.4.0-rc1 excluded",
    )
    check(
        classify_release("untagged-335612d571d02c9be30e", True, False) is None,
        "untagged-* excluded",
    )

    # Flag/shape contradictions resolve to "excluded", matching the client's
    # releaseMatchesUpdateChannel: v0.5.0 is version-shaped but flagged
    # prerelease, so it is offered on no channel at all.
    check(
        classify_release("v0.5.0", True, False) is None,
        "version-shaped prerelease excluded",
    )
    check(
        classify_release("v1.4.0-beta.9473", False, False) is None,
        "beta-shaped non-prerelease excluded",
    )

    # Drafts are never published activity.
    check(classify_release("v2.1.1", False, True) is None, "draft excluded")

    # Legacy per-build debug tags were GC'd, but if one resurfaces it must not
    # be mistaken for a stable release.
    check(
        classify_release("v0.11.1-debug.4321+abcdef1", True, False) is None,
        "legacy versioned debug tag excluded",
    )


def test_timezone_and_week_start() -> None:
    # git log %cI emits the committer's offset, not UTC.
    local = utc("2026-08-17T07:30:00+08:00")
    check(
        local == utc("2026-08-16T23:30:00Z"),
        "local-offset timestamp normalizes to UTC",
    )
    # 2026-08-16 UTC is a Sunday -> its week starts Monday 2026-08-10.
    check(
        week_start(local) == dt.date(2026, 8, 10),
        f"UTC-Sunday commit lands in the 08-10 week, got {week_start(local)}",
    )
    # The same wall-clock instant read as naive local time would have landed in
    # the 08-17 week; that off-by-one-week is exactly what this guards.
    check(
        week_start(utc("2026-08-17T07:30:00Z")) == dt.date(2026, 8, 17),
        "Monday UTC commit lands in its own week",
    )
    check(
        week_start(utc("2026-08-16T23:59:59Z")) == dt.date(2026, 8, 10),
        "Sunday 23:59 UTC still belongs to the previous Monday",
    )
    # week_start must normalize on its own, not lean on its callers having done
    # it: fed a raw +08:00 datetime it still has to bucket by UTC.
    shanghai = dt.timezone(dt.timedelta(hours=8))
    check(
        week_start(dt.datetime(2026, 8, 17, 7, 30, tzinfo=shanghai))
        == dt.date(2026, 8, 10),
        "a raw +08:00 datetime is converted to UTC before bucketing",
    )
    check(
        week_start(dt.datetime(2026, 8, 24, 3, 0, tzinfo=shanghai))
        == dt.date(2026, 8, 17),
        "a raw +08:00 Monday morning belongs to the previous UTC week",
    )


def test_week_axis() -> None:
    axis = build_week_axis(utc("2026-08-17T12:00:00Z"), 12)
    check(len(axis) == 12, f"axis has 12 entries, got {len(axis)}")
    check(axis[-1] == dt.date(2026, 8, 17), f"axis ends this week, got {axis[-1]}")
    check(axis[0] == dt.date(2026, 6, 1), f"axis starts 2026-06-01, got {axis[0]}")
    check(
        all(d.weekday() == 0 for d in axis), "every axis entry is a Monday"
    )
    check(
        all(
            (axis[i + 1] - axis[i]).days == 7 for i in range(len(axis) - 1)
        ),
        "axis entries are exactly one week apart",
    )
    # Crossing a year boundary must not reset or duplicate weeks.
    across = build_week_axis(utc("2027-01-06T00:00:00Z"), 6)
    check(
        across[0] == dt.date(2026, 11, 30) and across[-1] == dt.date(2027, 1, 4),
        f"year-crossing axis spans 2026-11-30..2027-01-04, got {across[0]}..{across[-1]}",
    )

    try:
        build_week_axis(utc("2026-08-17T12:00:00Z"), 0)
    except ValueError:
        pass
    else:
        check(False, "weeks=0 must raise ValueError")


def test_bucketing() -> None:
    axis = build_week_axis(utc("2026-08-17T12:00:00Z"), 3)
    # axis == [2026-08-03, 2026-08-10, 2026-08-17]
    moments = [
        utc("2026-08-03T00:00:00Z"),  # first bucket, exact boundary
        utc("2026-08-09T23:59:59Z"),  # first bucket, last second
        utc("2026-08-10T00:00:00Z"),  # second bucket
        utc("2026-08-17T09:00:00Z"),  # third bucket
        utc("2026-08-02T23:59:59Z"),  # before the window -> dropped
        utc("2026-09-01T00:00:00Z"),  # after the window -> dropped
    ]
    counts = bucket_by_week(moments, axis)
    check(counts == [2, 1, 1], f"bucket counts are [2, 1, 1], got {counts}")
    check(sum(counts) == 4, "out-of-window moments are dropped, not clamped")
    check(bucket_by_week([], axis) == [0, 0, 0], "empty input yields zeros")


def test_parse_git_log() -> None:
    text = "2026-08-17T07:30:00+08:00\n2026-08-16T10:00:00Z\n\n"
    parsed = parse_git_log(text)
    check(len(parsed) == 2, f"blank lines skipped, got {len(parsed)}")
    check(
        parsed[0] == utc("2026-08-16T23:30:00Z"),
        "first git log entry normalized to UTC",
    )
    check(parse_git_log("") == [], "empty git log yields no commits")


def test_nice_ceiling() -> None:
    check(nice_ceiling(0) == 5, "zero rounds to 5")
    check(nice_ceiling(5) == 5, "5 rounds to 5")
    check(nice_ceiling(6) == 10, "6 rounds to 10")
    check(nice_ceiling(23) == 25, "23 rounds to 25")
    check(nice_ceiling(92) == 100, "92 rounds to 100")
    # A coarse 1/2/5/10 ladder would send these to 200 / 2000 and draw every
    # bar at roughly half the panel height.
    check(nice_ceiling(101) == 120, f"101 rounds to 120, got {nice_ceiling(101)}")
    check(
        nice_ceiling(1077) == 1200, f"1077 rounds to 1200, got {nice_ceiling(1077)}"
    )
    for value in (7, 13, 99, 250, 1077, 4001):
        ceiling = nice_ceiling(value)
        check(ceiling >= value, f"ceiling {ceiling} never clips {value}")
        check(
            ceiling <= value * 2,
            f"ceiling {ceiling} wastes less than half the panel for {value}",
        )


def test_escape_xml() -> None:
    check(
        escape_xml('a&b<c>d"e\'f') == "a&amp;b&lt;c&gt;d&quot;e&apos;f",
        "all five XML entities escaped",
    )


def _git(repo: str, *args: str, when: str = "") -> None:
    env = dict(os.environ)
    env.update(
        {
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@example.com",
        }
    )
    if when:
        env["GIT_AUTHOR_DATE"] = when
        env["GIT_COMMITTER_DATE"] = when
    done = subprocess.run(
        ["git"] + list(args),
        cwd=repo,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {done.stdout}")


def test_fetch_commit_times_reads_the_named_branch() -> None:
    """The whole point of the chart: rendered on main, measured on develop.

    Dropping the branch argument from `git log` silently charts whatever HEAD
    happens to be, which on the release branch is merge traffic rather than
    development. Nothing about the output would look wrong, so this needs a
    real repository rather than a unit-level stand-in.
    """
    with tempfile.TemporaryDirectory() as repo:
        _git(repo, "init", "-q", "-b", "main")
        with open(os.path.join(repo, "f.txt"), "w", encoding="utf-8") as fh:
            fh.write("base\n")
        _git(repo, "add", "f.txt")
        _git(repo, "commit", "-qm", "base", when="2026-08-10T10:00:00+00:00")

        _git(repo, "checkout", "-q", "-b", "develop")
        with open(os.path.join(repo, "f.txt"), "w", encoding="utf-8") as fh:
            fh.write("dev\n")
        _git(repo, "commit", "-qam", "dev work", when="2026-08-11T10:00:00+00:00")

        _git(repo, "checkout", "-q", "main")
        with open(os.path.join(repo, "g.txt"), "w", encoding="utf-8") as fh:
            fh.write("release\n")
        _git(repo, "add", "g.txt")
        _git(repo, "commit", "-qm", "release merge", when="2026-08-12T10:00:00+00:00")

        since = utc("2026-08-01T00:00:00Z")
        on_develop = fetch_commit_times("develop", since, repo)
        on_main = fetch_commit_times("main", since, repo)

        check(
            sorted(on_develop) == [utc("2026-08-10T10:00:00Z"), utc("2026-08-11T10:00:00Z")],
            f"develop yields its own commits, got {sorted(on_develop)}",
        )
        check(
            utc("2026-08-12T10:00:00Z") not in on_develop,
            "a main-only commit never appears in the develop series",
        )
        check(
            utc("2026-08-11T10:00:00Z") not in on_main,
            "reading main would miss the development commits (HEAD is main here)",
        )

        # A ref that does not resolve must fail loudly, not chart an empty week.
        try:
            fetch_commit_times("origin/nope", since, repo)
        except SystemExit as err:
            check(
                "cannot resolve" in str(err),
                f"missing ref fails with an actionable message, got: {err}",
            )
        else:
            check(False, "a missing branch ref must raise, not return []")


class FakeRuns:
    """A fake Actions runs endpoint with GitHub's 1000-item listing cap.

    ``runs_per_day`` drives how many runs each calendar day holds; the fake
    reports the true ``total_count`` but refuses to serve anything past the cap,
    exactly like the real API.
    """

    def __init__(self, runs_per_day: int, cap: int = RUNS_LIST_CAP) -> None:
        self.runs_per_day = runs_per_day
        self.cap = cap
        self.queries: list = []

    def __call__(self, created: str, page: int):
        start_s, end_s = created.split("..")
        start = dt.date.fromisoformat(start_s)
        end = dt.date.fromisoformat(end_s)
        self.queries.append((created, page))
        days = (end - start).days + 1
        total = days * self.runs_per_day
        served = min(total, self.cap)
        first = (page - 1) * 100
        if first >= served:
            return total, []
        window = []
        for i in range(first, min(first + 100, served)):
            day = start + dt.timedelta(days=i // max(self.runs_per_day, 1))
            window.append(
                {
                    "head_sha": f"{created}-{i}",
                    "run_started_at": f"{day.isoformat()}T00:00:00Z",
                }
            )
        return total, window


def test_collect_run_pages_paginates() -> None:
    fake = FakeRuns(runs_per_day=30)  # 10 days -> 300 runs, under the cap
    runs = collect_run_pages(
        fake, dt.date(2026, 6, 1), dt.date(2026, 6, 10)
    )
    check(len(runs) == 300, f"collected all 300 runs, got {len(runs)}")
    pages = [p for _, p in fake.queries]
    check(pages == [1, 2, 3], f"stopped after the last full page, got {pages}")
    check(
        len({q for q, _ in fake.queries}) == 1,
        "an under-cap range is never split",
    )


def test_collect_run_pages_splits_around_the_cap() -> None:
    # 90 days x 30 runs = 2700 > 1000: a naive paginator would return 1000.
    fake = FakeRuns(runs_per_day=30)
    runs = collect_run_pages(fake, dt.date(2026, 6, 1), dt.date(2026, 8, 29))
    check(
        len(runs) == 90 * 30,
        f"cap-exceeding range is split until complete, got {len(runs)} of 2700",
    )
    ranges = {q for q, _ in fake.queries}
    check(len(ranges) > 1, "the range was actually subdivided")
    # The split must tile the interval without gaps or overlaps.
    spans = sorted(
        (dt.date.fromisoformat(r.split("..")[0]), dt.date.fromisoformat(r.split("..")[1]))
        for r in ranges
    )
    leaves = [s for s in spans if (s[1] - s[0]).days * 30 + 30 <= RUNS_LIST_CAP]
    covered = sorted(leaves)
    check(covered[0][0] == dt.date(2026, 6, 1), "split starts at the range start")
    check(covered[-1][1] == dt.date(2026, 8, 29), "split ends at the range end")
    for i in range(len(covered) - 1):
        check(
            (covered[i + 1][0] - covered[i][1]).days == 1,
            f"leaf ranges tile without gaps: {covered[i]} -> {covered[i + 1]}",
        )
    shas = [r["head_sha"] for r in runs]
    check(len(set(shas)) == len(shas), "no run is collected twice")


def test_collect_run_pages_fails_on_unsplittable_day() -> None:
    fake = FakeRuns(runs_per_day=RUNS_LIST_CAP + 1)
    try:
        collect_run_pages(fake, dt.date(2026, 6, 1), dt.date(2026, 6, 1))
    except SystemExit as err:
        check(
            "cannot be split further" in str(err),
            f"unsplittable day fails loudly, got: {err}",
        )
    else:
        check(False, "a single day over the cap must raise, not undercount")


def test_collect_run_pages_empty_range() -> None:
    fake = FakeRuns(runs_per_day=0)
    check(
        collect_run_pages(fake, dt.date(2026, 6, 1), dt.date(2026, 6, 10)) == [],
        "an empty range yields no runs",
    )
    check(
        collect_run_pages(fake, dt.date(2026, 6, 10), dt.date(2026, 6, 1)) == [],
        "an inverted range yields no runs instead of recursing forever",
    )


def _render_sample(repo: str = "owner/name", branch: str = "origin/develop") -> str:
    axis = build_week_axis(utc("2026-08-17T12:00:00Z"), 12)
    commits = [12, 30, 0, 44, 51, 9, 63, 71, 25, 88, 40, 17]
    channels = {
        "debug": [8, 21, 0, 33, 40, 5, 52, 60, 18, 70, 30, 11],
        "beta": [0, 0, 0, 1, 0, 0, 0, 2, 0, 1, 0, 1],
        "stable": [1, 0, 0, 0, 1, 0, 0, 0, 0, 2, 0, 1],
    }
    return render_svg(repo, branch, axis, commits, channels, "2026-08-17 12:00 UTC")


def test_render_svg_is_well_formed() -> None:
    svg = _render_sample()
    try:
        root = ET.fromstring(svg)
    except ET.ParseError as err:
        check(False, f"rendered SVG must be well-formed XML: {err}")
        return
    check(
        root.tag.endswith("svg"), f"root element is <svg>, got {root.tag}"
    )
    check(root.get("width") == "920", "svg width is 920")
    check(root.get("height") == "470", "svg height is 470")

    text_nodes = [
        (node.text or "") for node in root.iter() if node.tag.endswith("text")
    ]
    joined = " ".join(text_nodes)
    for label in ("Debug (rolling)", "Beta", "Stable"):
        check(
            any(label == t for t in text_nodes),
            f"channel lane {label} is labelled in the chart",
        )
    check(
        "Commits on develop" in joined,
        "commit panel names the development branch, not HEAD",
    )
    # 12+30+0+44+51+9+63+71+25+88+40+17 == 450
    check("450 commits" in joined, f"commit total is rendered, got: {joined[:200]}")
    # debug lane total 8+21+0+33+40+5+52+60+18+70+30+11 == 348
    check(
        any(t.startswith("348 builds") for t in text_nodes),
        "debug lane reports its own total in builds",
    )
    check(
        any(t.startswith("5 releases") for t in text_nodes),
        "beta lane reports 5 releases",
    )

    rects = [node for node in root.iter() if node.tag.endswith("rect")]
    check(len(rects) > 12, f"bars are rendered as rects, got {len(rects)}")


def test_render_svg_marks_the_week_in_progress() -> None:
    """The newest week covers only the days elapsed since Monday.

    Drawn solid it reads as a collapse in activity every single day of the
    week, so it must be visually distinguished from a completed week.
    """
    root = ET.fromstring(_render_sample())
    faded = [
        node
        for node in root.iter()
        if node.tag.endswith("rect") and node.get("fill-opacity") == "0.45"
    ]
    # One per non-zero trailing bar: commits + the three channel lanes.
    check(
        len(faded) == 4,
        f"exactly the four trailing bars are faded, got {len(faded)}",
    )
    titles = [
        (node.text or "")
        for node in root.iter()
        if node.tag.endswith("title") and "in progress" in (node.text or "")
    ]
    check(
        len(titles) == 4,
        f"trailing bars are labelled as in progress, got {len(titles)}",
    )
    check(
        all(t.startswith("2026-08-17") for t in titles),
        f"only the newest week is marked in progress, got {titles}",
    )


def test_render_svg_escapes_hostile_names() -> None:
    svg = _render_sample(repo='ow<ner>/na&me"', branch="origin/de<v>")
    try:
        ET.fromstring(svg)
    except ET.ParseError as err:
        check(False, f"repo/branch names must be escaped: {err}")


def test_render_svg_rejects_length_mismatch() -> None:
    axis = build_week_axis(utc("2026-08-17T12:00:00Z"), 4)
    ok = {c: [0, 0, 0, 0] for c in CHANNELS}
    try:
        render_svg("o/n", "origin/develop", axis, [1, 2, 3], ok, "now")
    except ValueError:
        pass
    else:
        check(False, "mismatched commit series length must raise ValueError")

    bad = dict(ok)
    bad["beta"] = [1, 2]
    try:
        render_svg("o/n", "origin/develop", axis, [1, 2, 3, 4], bad, "now")
    except ValueError:
        pass
    else:
        check(False, "mismatched channel series length must raise ValueError")


def main() -> int:
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if _FAILURES:
        print(f"\n{len(_FAILURES)} check(s) failed.", file=sys.stderr)
        return 1
    print("all gen_dev_activity_svg checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
