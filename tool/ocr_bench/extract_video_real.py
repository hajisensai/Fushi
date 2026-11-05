"""Grab one frame per dialogue line from a video with burned-in subtitles.

Uses a soft subtitle track's event times (any language: the burned-in Chinese
line is on screen while the soft English line is) so every frame shows a
different subtitle. Output (in --out): frames/<video-stem>_<n>.jpg (1920x1080)
plus events.jsonl with the event time. Labels are added by label_consensus.py.

Usage:
  python -I -X utf8 extract_video_real.py --video EP.mkv --out DIR [--per-video 100] [--track 0]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

_DIALOGUE = re.compile(r"^Dialogue:\s*[^,]*,(\d+):(\d+):(\d+)\.(\d+),(\d+):(\d+):(\d+)\.(\d+),")


def _secs(h: str, m: str, s: str, cs: str) -> float:
    return int(h) * 3600 + int(m) * 60 + int(s) + int(cs) / 100


def subtitle_events(video: Path, track: int) -> list[tuple[float, float]]:
    ass = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(video), "-map", f"0:s:{track}", "-f", "ass", "-"],
        capture_output=True, check=True,
    ).stdout.decode("utf-8", "replace")
    events = []
    for line in ass.splitlines():
        m = _DIALOGUE.match(line)
        if m:
            g = m.groups()
            start, end = _secs(*g[:4]), _secs(*g[4:])
            if end - start >= 0.8:
                events.append((start, end))
    events.sort()
    # Merge overlapping events (signs/karaoke) so each kept event is one line.
    merged: list[tuple[float, float]] = []
    for s, e in events:
        if merged and s < merged[-1][1]:
            continue
        merged.append((s, e))
    return merged


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", action="append", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--per-video", type=int, default=100)
    ap.add_argument("--track", type=int, default=0, help="soft subtitle track index used for timing")
    args = ap.parse_args()

    frames = args.out / "frames"
    frames.mkdir(parents=True, exist_ok=True)
    with (args.out / "events.jsonl").open("w", encoding="utf-8") as out:
        for video in args.video:
            events = subtitle_events(video, args.track)
            step = max(1, len(events) // args.per_video)
            picked = events[::step][: args.per_video]
            stem = re.sub(r"\W+", "_", video.stem)[-24:]
            for n, (s, e) in enumerate(picked):
                t = s + (e - s) * 0.5
                name = f"{stem}_{n:03d}.jpg"
                dest = frames / name
                if not dest.exists():
                    subprocess.run(
                        ["ffmpeg", "-v", "error", "-y", "-ss", f"{t:.2f}", "-i", str(video),
                         "-frames:v", "1", "-vf", "scale=1920:1080", "-sn", str(dest)],
                        check=True,
                    )
                out.write(json.dumps({"image": f"frames/{name}", "video": video.name, "t": round(t, 2)},
                                     ensure_ascii=False) + "\n")
            print(f"{video.name}: {len(events)} events, kept {len(picked)}")


if __name__ == "__main__":
    main()
