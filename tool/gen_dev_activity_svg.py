#!/usr/bin/env python3
"""Generate a self-contained development-activity SVG for the Fushi repository.

Two panels, one shared weekly x-axis:

  * top    - commit volume on the development branch (default ``origin/develop``)
  * bottom - release cadence of the three update channels (debug / beta / stable)

The README lives on ``main`` (the GitHub default branch) but all development
happens on ``develop``; this script therefore reads commits from an explicit
branch ref rather than from ``HEAD``, so the chart committed to ``main`` shows
``develop``'s activity.

Zero third-party dependencies (Python stdlib only). Designed to run on a GitHub
Actions runner using the built-in GITHUB_TOKEN.

Security note: the token is read from the GITHUB_TOKEN environment variable at
runtime and used only for API Authorization headers. It is never written into
the repository or into the generated SVG.

Channel data sources (they are deliberately different -- see below):

  stable / beta
      GitHub Releases API. Classification mirrors the client's own
      ``releaseMatchesUpdateChannel``
      (fushi/lib/src/utils/misc/update_checker_release.dart) so the chart and
      the in-app update channels can never disagree.

  debug
      GitHub Actions API: successful ``push``-triggered runs of release.yml,
      deduplicated by head SHA. The Releases API is *not* usable here: every
      push overwrites one rolling tag (``fushi-debug-rolling``), so the API
      reports a single release no matter how many debug builds shipped, and the
      legacy per-build ``v<x>-debug.<seq>+<sha>`` tags are garbage-collected by
      release.yml. Actions history is retained ~90 days, which is why the
      default window is 12 weeks -- a longer window would render a debug lane
      that is empty for reasons unrelated to project activity.

Usage:
    GITHUB_TOKEN=... python3 tool/gen_dev_activity_svg.py \
        --repo hajisensai/Fushi --branch origin/develop \
        --out docs/assets/dev-activity.svg
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
import urllib.parse
import urllib.request
from typing import Dict, List, Optional, Sequence, Tuple

API_ROOT = "https://api.github.com"

# Workflow whose push-triggered runs correspond 1:1 with a debug channel
# publish. Only the Android workflow is counted: release-desktop.yml runs on the
# same push, so counting both would double every debug build.
DEBUG_WORKFLOW = "release.yml"

# GitHub caps any Actions run listing at 1000 items regardless of total_count.
RUNS_LIST_CAP = 1000

# Mirrors fushi/lib/src/utils/misc/update_checker_release.dart:26-31. Do not
# invent new patterns here -- a chart that classifies releases differently from
# the client is worse than no chart.
_BETA_TAG = re.compile(r"^v\d+(?:\.\d+)*-beta\.\d+$")
_STABLE_TAG = re.compile(r"^v\d+(?:\.\d+)*$")

CHANNELS: Tuple[str, str, str] = ("debug", "beta", "stable")

CHANNEL_LABEL: Dict[str, str] = {
    "debug": "Debug (rolling)",
    "beta": "Beta",
    "stable": "Stable",
}

CHANNEL_COLOR: Dict[str, str] = {
    "debug": "#58a6ff",
    "beta": "#d29922",
    "stable": "#3fb950",
}

CHANNEL_UNIT: Dict[str, str] = {
    "debug": "builds",
    "beta": "releases",
    "stable": "releases",
}


# ---------------------------------------------------------------------------
# Pure helpers (covered by tool/gen_dev_activity_svg_test.py)
# ---------------------------------------------------------------------------


def classify_release(tag: str, prerelease: bool, draft: bool) -> Optional[str]:
    """Return the update channel a GitHub release belongs to, or None.

    None means "not part of the three-channel release system": upstream vendor
    tags (``vendor-libmpv``), unprefixed tags (``2.9.1``), release-candidate
    shapes (``v0.4.0-rc1``), the rolling debug tag, and version-shaped tags
    whose prerelease flag contradicts their tag shape. Those are reported by
    the caller rather than silently folded into a neighbouring channel.
    """
    if draft:
        return None
    if _BETA_TAG.match(tag):
        return "beta" if prerelease else None
    if _STABLE_TAG.match(tag):
        return "stable" if not prerelease else None
    return None


def week_start(moment: dt.datetime) -> dt.date:
    """Monday (UTC) of the ISO week containing moment."""
    day = moment.astimezone(dt.timezone.utc).date()
    return day - dt.timedelta(days=day.weekday())


def build_week_axis(now: dt.datetime, weeks: int) -> List[dt.date]:
    """Return the ascending list of week-start dates ending at now's week."""
    if weeks < 1:
        raise ValueError(f"weeks must be >= 1, got {weeks}")
    last = week_start(now)
    return [last - dt.timedelta(days=7 * (weeks - 1 - i)) for i in range(weeks)]


def bucket_by_week(
    moments: Sequence[dt.datetime], axis: Sequence[dt.date]
) -> List[int]:
    """Count moments per week bucket. Moments outside the axis are dropped."""
    index = {start: i for i, start in enumerate(axis)}
    counts = [0] * len(axis)
    for moment in moments:
        slot = index.get(week_start(moment))
        if slot is not None:
            counts[slot] += 1
    return counts


def nice_ceiling(value: int) -> int:
    """Round value up to a visually pleasant axis maximum.

    The step ladder is deliberately finer than a plain 1/2/5/10 sequence: with
    the coarse ladder a peak of 1077 commits/week snaps to 2000 and every bar in
    the chart is drawn at half its available height.
    """
    if value <= 5:
        return 5
    if value <= 10:
        # Below 10 the fine ladder produces axis maxima like 6 or 7, whose
        # quarter-marks render as 0/2/3/5/6 -- worse than simply using 10.
        return 10
    magnitude = 10 ** (len(str(value)) - 1)
    for step in (1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        candidate = int(step * magnitude)
        if candidate >= value:
            return candidate
    return int(10 * magnitude)


def parse_iso_utc(text: str) -> dt.datetime:
    """Parse a GitHub/Git ISO-8601 timestamp into an aware UTC datetime."""
    cleaned = text.strip()
    if cleaned.endswith("Z"):
        cleaned = cleaned[:-1] + "+00:00"
    parsed = dt.datetime.fromisoformat(cleaned)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def parse_git_log(text: str) -> List[dt.datetime]:
    """Parse `git log --pretty=format:%cI` output into UTC datetimes."""
    return [parse_iso_utc(line) for line in text.splitlines() if line.strip()]


def escape_xml(text: str) -> str:
    """Escape the five XML predefined entities for SVG text nodes."""
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


# ---------------------------------------------------------------------------
# Data collection (git + GitHub API)
# ---------------------------------------------------------------------------


def _run_git(args: List[str], repo_root: str) -> str:
    result = subprocess.run(
        ["git"] + args,
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        raise SystemExit(
            f"git {' '.join(args)} failed with exit {result.returncode}: "
            f"{result.stderr.strip()}"
        )
    return result.stdout


def fetch_commit_times(
    branch: str, since: dt.datetime, repo_root: str
) -> List[dt.datetime]:
    """Return commit timestamps on branch since the given moment.

    Hard-fails when the ref does not resolve. A missing ``origin/develop`` (the
    usual cause: a shallow or single-branch checkout on the runner) must not
    degrade into an empty chart that looks like "no development happened".
    """
    try:
        _run_git(["rev-parse", "--verify", f"{branch}^{{commit}}"], repo_root)
    except SystemExit as err:
        raise SystemExit(
            f"cannot resolve '{branch}' in {os.path.abspath(repo_root)}: {err}\n"
            "The chart is generated on main but reads develop; a shallow or "
            "single-branch checkout hides that ref. Use "
            "actions/checkout with fetch-depth: 0, or fetch the branch "
            "explicitly, rather than charting an empty history."
        )
    log = _run_git(
        [
            "log",
            branch,
            "--pretty=format:%cI",
            f"--since={since.strftime('%Y-%m-%dT%H:%M:%SZ')}",
        ],
        repo_root,
    )
    return parse_git_log(log)


def _api_get(url: str, token: str) -> Tuple[object, Dict[str, str]]:
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "fushi-dev-activity")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
            headers = {k: v for k, v in resp.headers.items()}
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "replace")
        raise SystemExit(f"GitHub API error {err.code} for {url}: {body}")
    except urllib.error.URLError as err:
        raise SystemExit(f"GitHub API unreachable for {url}: {err.reason}")
    return payload, headers


def fetch_releases(repo: str, token: str) -> List[Tuple[dt.datetime, str, str]]:
    """Return (published_at, tag, channel_or_empty) for every published release."""
    out: List[Tuple[dt.datetime, str, str]] = []
    page = 1
    while page <= 20:
        url = f"{API_ROOT}/repos/{repo}/releases?per_page=100&page={page}"
        data, _ = _api_get(url, token)
        if not isinstance(data, list) or not data:
            break
        for entry in data:
            published = entry.get("published_at") or entry.get("created_at")
            if not published:
                continue
            tag = entry.get("tag_name") or ""
            channel = classify_release(
                tag,
                bool(entry.get("prerelease")),
                bool(entry.get("draft")),
            )
            out.append((parse_iso_utc(published), tag, channel or ""))
        if len(data) < 100:
            break
        page += 1
    out.sort(key=lambda item: item[0])
    return out


def collect_run_pages(
    fetch_page, start: dt.date, end: dt.date, cap: int = RUNS_LIST_CAP
) -> List[dict]:
    """Collect every workflow run in [start, end], splitting around the API cap.

    ``fetch_page(created, page)`` must return ``(total_count, runs)``.

    GitHub caps an Actions run *listing* at 1000 items no matter how many runs
    match: page 11 onwards comes back empty, so a naive paginator silently
    reports a low debug count as the project gets busier. This repository was
    already at 951 runs per 12 weeks when the chart was written, i.e. one good
    month away from truncation. When ``total_count`` exceeds the cap the date
    range is halved and re-queried until every slice fits; a single day that
    still exceeds it is a hard failure rather than a quiet undercount.
    """
    if start > end:
        return []
    created = f"{start.isoformat()}..{end.isoformat()}"
    total, runs = fetch_page(created, 1)
    if total > cap:
        if start == end:
            raise SystemExit(
                f"{total} workflow runs on {start} exceed the {cap}-item "
                "listing cap and cannot be split further; refusing to draw a "
                "truncated debug lane"
            )
        span = (end - start).days
        mid = start + dt.timedelta(days=span // 2)
        return collect_run_pages(fetch_page, start, mid, cap) + collect_run_pages(
            fetch_page, mid + dt.timedelta(days=1), end, cap
        )
    collected: List[dict] = []
    page = 1
    while runs:
        collected.extend(runs)
        if len(runs) < 100 or page * 100 >= total:
            break
        page += 1
        _, runs = fetch_page(created, page)
    return collected


def fetch_debug_builds(
    repo: str, token: str, since: dt.datetime
) -> List[dt.datetime]:
    """Return one timestamp per distinct commit that shipped a debug build.

    Successful ``push``-triggered runs of release.yml, deduplicated by head SHA
    so a manual re-run of the same commit is not counted twice.
    """

    def fetch_page(created: str, page: int) -> Tuple[int, List[dict]]:
        url = (
            f"{API_ROOT}/repos/{repo}/actions/workflows/{DEBUG_WORKFLOW}/runs"
            f"?per_page=100&page={page}&event=push&status=success"
            f"&created={urllib.parse.quote(created)}"
        )
        data, _ = _api_get(url, token)
        if not isinstance(data, dict):
            raise SystemExit(f"unexpected Actions API payload for {url}")
        return int(data.get("total_count") or 0), list(
            data.get("workflow_runs") or []
        )

    runs = collect_run_pages(
        fetch_page, since.date(), dt.datetime.now(dt.timezone.utc).date()
    )

    seen: Dict[str, dt.datetime] = {}
    for run in runs:
        sha = run.get("head_sha") or ""
        stamp = run.get("run_started_at") or run.get("created_at")
        if not sha or not stamp:
            continue
        moment = parse_iso_utc(stamp)
        if sha not in seen or moment < seen[sha]:
            seen[sha] = moment
    return sorted(seen.values())


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

BG = "#0d1117"
CARD = "#161b22"
GRID = "#30363d"
AXIS_TEXT = "#8b949e"
ACCENT_TEXT = "#f0f6fc"
COMMIT_COLOR = "#a371f7"

FONT = (
    "-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif"
)


def _partial_attr(index: int, weeks: int) -> str:
    """Fade the trailing bar: the newest week is still in progress.

    Without this the chart's last column always looks like a collapse in
    activity, because it covers however many days have elapsed since Monday.
    """
    return ' fill-opacity="0.45"' if index == weeks - 1 else ""


def _partial_note(index: int, weeks: int) -> str:
    return " (week in progress)" if index == weeks - 1 else ""


def render_svg(
    repo: str,
    branch: str,
    axis: Sequence[dt.date],
    commits: Sequence[int],
    channel_counts: Dict[str, Sequence[int]],
    generated: str,
) -> str:
    """Render the two-panel activity chart as a standalone SVG document."""
    if len(commits) != len(axis):
        raise ValueError("commit series length must match the week axis")
    for name, series in channel_counts.items():
        if len(series) != len(axis):
            raise ValueError(f"channel {name} series length must match the axis")

    width, height = 920, 470
    margin_left, margin_right = 152, 28
    plot_w = width - margin_left - margin_right

    top_y, top_h = 84, 148
    top_base = top_y + top_h
    rows_y, row_h, row_gap = 300, 30, 38

    weeks = len(axis)
    slot = plot_w / weeks
    bar_w = max(3.0, slot * 0.62)
    bar_dx = (slot - bar_w) / 2

    branch_label = branch.split("/")[-1]
    title = escape_xml(f"Development Activity · {repo}")
    subtitle = escape_xml(f"{branch_label} · last {weeks} weeks")

    parts: List[str] = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}" '
        f'font-family="{FONT}" role="img" aria-label="{title}">'
    )
    parts.append(
        '<defs><linearGradient id="commitArea" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{COMMIT_COLOR}" stop-opacity="0.9"/>'
        f'<stop offset="1" stop-color="{COMMIT_COLOR}" stop-opacity="0.45"/>'
        "</linearGradient></defs>"
    )
    parts.append(f'<rect width="{width}" height="{height}" rx="10" fill="{BG}"/>')
    parts.append(
        f'<rect x="8" y="8" width="{width - 16}" height="{height - 16}" '
        f'rx="8" fill="{CARD}" stroke="{GRID}" stroke-width="1"/>'
    )
    parts.append(
        f'<text x="28" y="36" fill="{ACCENT_TEXT}" font-size="18" '
        f'font-weight="600">{title}</text>'
    )
    parts.append(
        f'<text x="{width - 28}" y="36" fill="{AXIS_TEXT}" font-size="12" '
        f'text-anchor="end">{subtitle}</text>'
    )

    # ---- Panel A: weekly commits -----------------------------------------
    total_commits = sum(commits)
    parts.append(
        f'<text x="28" y="66" fill="{ACCENT_TEXT}" font-size="13" '
        f'font-weight="600">Commits on {escape_xml(branch_label)}</text>'
    )
    parts.append(
        f'<text x="{width - 28}" y="66" fill="{AXIS_TEXT}" font-size="12" '
        f'text-anchor="end">{total_commits} commits &#183; '
        f'peak {max(commits) if commits else 0}/wk</text>'
    )

    y_max = nice_ceiling(max(commits) if commits else 0)
    for i in range(5):
        value = round(y_max * i / 4)
        y = top_base - (i / 4) * top_h
        parts.append(
            f'<line x1="{margin_left}" y1="{y:.1f}" '
            f'x2="{margin_left + plot_w}" y2="{y:.1f}" stroke="{GRID}" '
            f'stroke-width="1" stroke-dasharray="3 3"/>'
        )
        parts.append(
            f'<text x="{margin_left - 10}" y="{y + 4:.1f}" fill="{AXIS_TEXT}" '
            f'font-size="11" text-anchor="end">{value}</text>'
        )

    for i, count in enumerate(commits):
        h = 0.0 if y_max == 0 else (count / y_max) * top_h
        x = margin_left + i * slot + bar_dx
        if h < 1.0:
            # Zero weeks still get a visible 2px stub so an empty week reads as
            # "measured zero" rather than "no data drawn here".
            parts.append(
                f'<rect x="{x:.1f}" y="{top_base - 2:.1f}" width="{bar_w:.1f}" '
                f'height="2" rx="1" fill="{GRID}"/>'
            )
            continue
        parts.append(
            f'<rect x="{x:.1f}" y="{top_base - h:.1f}" width="{bar_w:.1f}" '
            f'height="{h:.1f}" rx="2" fill="url(#commitArea)"'
            f'{_partial_attr(i, weeks)}><title>'
            f'{axis[i].isoformat()}: {count} commits{_partial_note(i, weeks)}'
            f'</title></rect>'
        )

    parts.append(
        f'<line x1="{margin_left}" y1="{top_base}" '
        f'x2="{margin_left + plot_w}" y2="{top_base}" stroke="{GRID}" '
        f'stroke-width="1"/>'
    )

    # ---- Shared x-axis labels --------------------------------------------
    label_every = max(1, weeks // 6)
    for i, start in enumerate(axis):
        if i % label_every and i != weeks - 1:
            continue
        x = margin_left + i * slot + slot / 2
        parts.append(
            f'<text x="{x:.1f}" y="{top_base + 20:.1f}" fill="{AXIS_TEXT}" '
            f'font-size="11" text-anchor="middle">{start.strftime("%m-%d")}</text>'
        )

    # ---- Panel B: release channels ---------------------------------------
    parts.append(
        f'<line x1="28" y1="268" x2="{width - 28}" y2="268" stroke="{GRID}" '
        f'stroke-width="1"/>'
    )
    parts.append(
        f'<text x="28" y="290" fill="{ACCENT_TEXT}" font-size="13" '
        f'font-weight="600">Release channels</text>'
    )
    parts.append(
        f'<text x="{width - 28}" y="290" fill="{AXIS_TEXT}" font-size="11" '
        f'text-anchor="end">each lane scaled to its own peak</text>'
    )

    for lane, channel in enumerate(CHANNELS):
        series = list(channel_counts.get(channel, [0] * weeks))
        color = CHANNEL_COLOR[channel]
        row_top = rows_y + lane * row_gap
        row_base = row_top + row_h
        lane_max = max(series) if series else 0

        parts.append(
            f'<rect x="{margin_left}" y="{row_top}" width="{plot_w}" '
            f'height="{row_h}" rx="3" fill="{BG}" fill-opacity="0.55"/>'
        )
        parts.append(
            f'<rect x="28" y="{row_top + 8}" width="10" height="10" rx="2" '
            f'fill="{color}"/>'
        )
        parts.append(
            f'<text x="44" y="{row_top + 17}" fill="{ACCENT_TEXT}" '
            f'font-size="12">{escape_xml(CHANNEL_LABEL[channel])}</text>'
        )
        parts.append(
            f'<text x="44" y="{row_top + 30}" fill="{AXIS_TEXT}" font-size="10">'
            f'{sum(series)} {CHANNEL_UNIT[channel]} &#183; peak {lane_max}/wk</text>'
        )

        for i, count in enumerate(series):
            x = margin_left + i * slot + bar_dx
            if count <= 0:
                parts.append(
                    f'<rect x="{x:.1f}" y="{row_base - 2:.1f}" '
                    f'width="{bar_w:.1f}" height="2" rx="1" fill="{GRID}"/>'
                )
                continue
            h = max(4.0, (count / lane_max) * (row_h - 6)) if lane_max else 4.0
            parts.append(
                f'<rect x="{x:.1f}" y="{row_base - h:.1f}" width="{bar_w:.1f}" '
                f'height="{h:.1f}" rx="2" fill="{color}"'
                f'{_partial_attr(i, weeks)}><title>'
                f'{axis[i].isoformat()}: {count} {CHANNEL_UNIT[channel]}'
                f'{_partial_note(i, weeks)}</title></rect>'
            )

    parts.append(
        f'<text x="28" y="{height - 18}" fill="{AXIS_TEXT}" font-size="11">'
        f'Generated {escape_xml(generated)} &#183; faded column = week in '
        f'progress</text>'
    )
    parts.append(
        f'<text x="{width - 28}" y="{height - 18}" fill="{AXIS_TEXT}" '
        f'font-size="11" text-anchor="end">debug = successful push builds of '
        f'{DEBUG_WORKFLOW}</text>'
    )
    parts.append("</svg>")
    return "".join(parts)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Generate the development-activity SVG."
    )
    parser.add_argument(
        "--repo",
        default=os.environ.get("DEV_ACTIVITY_REPO", "hajisensai/Fushi"),
        help="owner/name of the repository (default: hajisensai/Fushi)",
    )
    parser.add_argument(
        "--branch",
        default="origin/develop",
        help="git ref to read commits from (default: origin/develop)",
    )
    parser.add_argument(
        "--weeks",
        type=int,
        default=12,
        help=(
            "number of weeks to chart (default: 12, matching the ~90 day "
            "GitHub Actions run retention that bounds the debug lane)"
        ),
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="path to the git checkout to read commits from (default: .)",
    )
    parser.add_argument(
        "--out",
        default="docs/assets/dev-activity.svg",
        help="output SVG path (default: docs/assets/dev-activity.svg)",
    )
    args = parser.parse_args(argv)

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print(
            "warning: GITHUB_TOKEN not set; unauthenticated requests are "
            "rate-limited to 60/hour.",
            file=sys.stderr,
        )

    now = dt.datetime.now(dt.timezone.utc)
    axis = build_week_axis(now, args.weeks)
    since = dt.datetime.combine(axis[0], dt.time.min, tzinfo=dt.timezone.utc)

    commit_times = fetch_commit_times(args.branch, since, args.repo_root)
    commits = bucket_by_week(commit_times, axis)

    releases = fetch_releases(args.repo, token)
    unclassified = sorted({tag for _, tag, channel in releases if not channel})
    if unclassified:
        # Reported, never silently folded into a neighbouring channel.
        print(
            "note: releases outside the three-channel system (excluded): "
            + ", ".join(unclassified),
            file=sys.stderr,
        )

    channel_counts: Dict[str, List[int]] = {}
    for channel in ("beta", "stable"):
        moments = [when for when, _, ch in releases if ch == channel]
        channel_counts[channel] = bucket_by_week(moments, axis)
    channel_counts["debug"] = bucket_by_week(
        fetch_debug_builds(args.repo, token, since), axis
    )

    generated = now.strftime("%Y-%m-%d %H:%M UTC")
    svg = render_svg(
        args.repo, args.branch, axis, commits, channel_counts, generated
    )

    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(svg + "\n")

    print(
        f"wrote {args.out} ({sum(commits)} commits on {args.branch}, "
        f"debug={sum(channel_counts['debug'])} "
        f"beta={sum(channel_counts['beta'])} "
        f"stable={sum(channel_counts['stable'])} over {args.weeks} weeks)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
