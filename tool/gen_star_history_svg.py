#!/usr/bin/env python3
"""Generate a self-contained star-history SVG for a GitHub repository.

Zero third-party dependencies (Python stdlib only). Designed to run on a
GitHub Actions runner using the built-in GITHUB_TOKEN.

Security note: this script never writes any token into the repository or the
generated SVG. The token is read from the GITHUB_TOKEN environment variable at
runtime and used only for API Authorization headers.

Usage:
    GITHUB_TOKEN=... python tool/gen_star_history_svg.py \
        --repo hajisensai/hibiki --out docs/assets/star-history.svg
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Dict, List, Tuple

API_ROOT = "https://api.github.com"


def _request(url: str, token: str) -> Tuple[list, Dict[str, str]]:
    """Perform a single GitHub API GET and return (json, response headers)."""
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github.star+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "hibiki-star-history")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
        headers = {k: v for k, v in resp.headers.items()}
    return payload, headers


def fetch_star_times(repo: str, token: str) -> List[dt.datetime]:
    """Return the sorted list of starred_at timestamps for repo.

    Paginates /repos/{repo}/stargazers with the star+json media type so each
    entry carries starred_at. The stargazers endpoint is capped by GitHub at
    ~400 pages (40k stars); we stop there defensively.
    """
    times: List[dt.datetime] = []
    page = 1
    while page <= 400:
        url = f"{API_ROOT}/repos/{repo}/stargazers?per_page=100&page={page}"
        try:
            data, _ = _request(url, token)
        except urllib.error.HTTPError as err:
            body = err.read().decode("utf-8", "replace")
            raise SystemExit(f"GitHub API error {err.code} for {url}: {body}")
        if not data:
            break
        for entry in data:
            starred_at = entry.get("starred_at")
            if starred_at:
                times.append(
                    dt.datetime.strptime(
                    starred_at, "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=dt.timezone.utc)
                )
        if len(data) < 100:
            break
        page += 1
    times.sort()
    return times


def _nice_ceiling(value: int) -> int:
    """Round value up to a visually pleasant axis maximum."""
    if value <= 5:
        return 5
    magnitude = 10 ** (len(str(value)) - 1)
    for step in (1, 2, 2.5, 5, 10):
        candidate = int(step * magnitude)
        if candidate >= value:
            return candidate
    return int(10 * magnitude)


def _build_series(
    times: List[dt.datetime],
) -> List[Tuple[dt.datetime, int]]:
    """Turn star timestamps into a cumulative (time, count) series.

    Appends a trailing point at "now" so the line extends flat to the present.
    Downsamples to at most ~120 vertices to keep the SVG small.
    """
    series: List[Tuple[dt.datetime, int]] = [
        (t, idx + 1) for idx, t in enumerate(times)
    ]
    now = dt.datetime.now(dt.timezone.utc)
    if series and series[-1][0] < now:
        series.append((now, series[-1][1]))

    max_points = 120
    if len(series) <= max_points:
        return series
    step = len(series) / max_points
    sampled: List[Tuple[dt.datetime, int]] = []
    for i in range(max_points):
        sampled.append(series[int(i * step)])
    sampled[-1] = series[-1]
    return sampled


def render_svg(repo: str, times: List[dt.datetime]) -> str:
    """Render the cumulative star history as a standalone SVG document."""
    width, height = 800, 400
    margin_left, margin_right = 64, 28
    margin_top, margin_bottom = 56, 52
    plot_w = width - margin_left - margin_right
    plot_h = height - margin_top - margin_bottom

    total = len(times)
    generated = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    title = f"Star History &#183; {repo}"

    # Colors read on both GitHub light and dark backgrounds; the SVG ships its
    # own card background so it is theme-independent.
    bg = "#0d1117"
    card = "#161b22"
    grid = "#30363d"
    axis_text = "#8b949e"
    line = "#e3b341"
    area_top = "#e3b341"
    accent_text = "#f0f6fc"

    parts: List[str] = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}" '
        f'font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif" '
        f'role="img" aria-label="{title}">'
    )
    parts.append(
        f'<defs><linearGradient id="starArea" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{area_top}" stop-opacity="0.35"/>'
        f'<stop offset="1" stop-color="{area_top}" stop-opacity="0"/>'
        f'</linearGradient></defs>'
    )
    parts.append(f'<rect width="{width}" height="{height}" rx="10" fill="{bg}"/>')
    parts.append(
        f'<rect x="8" y="8" width="{width - 16}" height="{height - 16}" '
        f'rx="8" fill="{card}" stroke="{grid}" stroke-width="1"/>'
    )
    parts.append(
        f'<text x="{margin_left}" y="34" fill="{accent_text}" '
        f'font-size="18" font-weight="600">{title}</text>'
    )
    parts.append(
        f'<text x="{width - margin_right}" y="34" fill="{axis_text}" '
        f'font-size="12" text-anchor="end">{total} stars</text>'
    )

    if total == 0:
        parts.append(
            f'<text x="{width / 2}" y="{height / 2}" fill="{axis_text}" '
            f'font-size="16" text-anchor="middle">No stars yet</text>'
        )
        parts.append(
            f'<text x="{margin_left}" y="{height - 18}" fill="{axis_text}" '
            f'font-size="11">Generated {generated}</text>'
        )
        parts.append("</svg>")
        return "".join(parts)

    series = _build_series(times)
    t_min = series[0][0]
    t_max = series[-1][0]
    span_seconds = max((t_max - t_min).total_seconds(), 1.0)
    y_max = _nice_ceiling(total)

    def x_of(t: dt.datetime) -> float:
        frac = (t - t_min).total_seconds() / span_seconds
        return margin_left + frac * plot_w

    def y_of(count: int) -> float:
        frac = count / y_max
        return margin_top + plot_h - frac * plot_h

    # Horizontal grid + y-axis labels (5 intervals).
    for i in range(6):
        value = round(y_max * i / 5)
        y = margin_top + plot_h - (i / 5) * plot_h
        parts.append(
            f'<line x1="{margin_left}" y1="{y:.1f}" x2="{margin_left + plot_w}" '
            f'y2="{y:.1f}" stroke="{grid}" stroke-width="1" '
            f'stroke-dasharray="3 3"/>'
        )
        parts.append(
            f'<text x="{margin_left - 10}" y="{y + 4:.1f}" fill="{axis_text}" '
            f'font-size="11" text-anchor="end">{value}</text>'
        )

    # X-axis date labels.
    ticks = 4
    for i in range(ticks + 1):
        t = t_min + dt.timedelta(seconds=span_seconds * i / ticks)
        x = margin_left + (i / ticks) * plot_w
        anchor = "middle"
        if i == 0:
            anchor = "start"
        elif i == ticks:
            anchor = "end"
        parts.append(
            f'<text x="{x:.1f}" y="{height - margin_bottom + 22:.1f}" '
            f'fill="{axis_text}" font-size="11" text-anchor="{anchor}">'
            f'{t.strftime("%Y-%m")}</text>'
        )

    # Step polyline: cumulative count is a step function.
    coords: List[Tuple[float, float]] = [(x_of(t), y_of(c)) for t, c in series]
    line_pts: List[str] = []
    prev_y = coords[0][1]
    for idx, (x, y) in enumerate(coords):
        if idx == 0:
            line_pts.append(f"{x:.1f},{y:.1f}")
        else:
            line_pts.append(f"{x:.1f},{prev_y:.1f}")
            line_pts.append(f"{x:.1f},{y:.1f}")
        prev_y = y
    polyline = " ".join(line_pts)

    baseline_y = margin_top + plot_h
    area_path = (
        f'M{coords[0][0]:.1f},{baseline_y:.1f} '
        + " ".join(f"L{p}" for p in line_pts)
        + f" L{coords[-1][0]:.1f},{baseline_y:.1f} Z"
    )
    parts.append(f'<path d="{area_path}" fill="url(#starArea)"/>')
    parts.append(
        f'<polyline points="{polyline}" fill="none" stroke="{line}" '
        f'stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>'
    )
    parts.append(
        f'<circle cx="{coords[-1][0]:.1f}" cy="{coords[-1][1]:.1f}" r="4" '
        f'fill="{line}" stroke="{card}" stroke-width="1.5"/>'
    )
    parts.append(
        f'<text x="{margin_left}" y="{height - 18}" fill="{axis_text}" '
        f'font-size="11">Generated {generated}</text>'
    )
    parts.append("</svg>")
    return "".join(parts)


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description="Generate a star-history SVG.")
    parser.add_argument(
        "--repo",
        default=os.environ.get("STAR_HISTORY_REPO", "hajisensai/hibiki"),
        help="owner/name of the repository (default: hajisensai/hibiki)",
    )
    parser.add_argument(
        "--out",
        default="docs/assets/star-history.svg",
        help="output SVG path (default: docs/assets/star-history.svg)",
    )
    args = parser.parse_args(argv)

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print(
            "warning: GITHUB_TOKEN not set; unauthenticated requests are "
            "rate-limited to 60/hour.",
            file=sys.stderr,
        )

    times = fetch_star_times(args.repo, token)
    svg = render_svg(args.repo, times)

    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(svg + "\n")
    print(f"wrote {args.out} ({len(times)} stars)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
