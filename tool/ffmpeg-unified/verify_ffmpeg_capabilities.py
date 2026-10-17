#!/usr/bin/env python3
"""Check a unified-FFmpeg ffmpeg/ffprobe pair against capabilities.json.

Runs the binaries (so it validates what actually links and loads, not what a
configure string claims) and fails on the first missing component class:

    verify_ffmpeg_capabilities.py --ffmpeg PATH [--ffprobe PATH]

Also asserts the version line matches recipe.env and that the TLS protocol
exposes the Fushi tls_pin_sha256 option (patch 0001).
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent

# `ffmpeg -<list>` flag -> capabilities.json key. The list output is
# " <flags> <name> <description>"; the name is the first token after a flags
# column made of [A-Z.] characters (e.g. " V....D libx264 ...", " E mp4 ...").
_LISTS = {
    "encoders": "-encoders",
    "decoders": "-decoders",
    "muxers": "-muxers",
    "demuxers": "-demuxers",
    "filters": "-filters",
    "bsfs": "-bsfs",
}


def _run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        raise SystemExit(f"FAILED: {' '.join(cmd)} exited {proc.returncode}\n"
                         f"{proc.stderr[-2000:]}")
    return proc.stdout + proc.stderr


def _names(listing: str, key: str) -> set[str]:
    names: set[str] = set()
    for line in listing.splitlines():
        if key == "bsfs":
            token = line.strip()
            if token and " " not in token:
                names.add(token)
            continue
        m = re.match(r"^\s*[A-Z.|]{1,8}\s+(\S+)", line)
        if m:
            # Muxer/demuxer rows may list "mov,mp4,m4a,3gp,3g2,mj2".
            names.update(m.group(1).split(","))
    return names


def _recipe_version() -> str:
    for line in (HERE / "recipe.env").read_text(encoding="utf-8").splitlines():
        if line.startswith("FFMPEG_VERSION="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("recipe.env has no FFMPEG_VERSION")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ffmpeg", required=True)
    ap.add_argument("--ffprobe")
    args = ap.parse_args()

    caps = json.loads((HERE / "capabilities.json").read_text(encoding="utf-8"))
    ffmpeg = args.ffmpeg
    failures: list[str] = []

    version = _run([ffmpeg, "-hide_banner", "-version"])
    want = _recipe_version()
    if not re.search(rf"ffmpeg version n?{re.escape(want)}\b", version):
        failures.append(f"version: expected {want}, got {version.splitlines()[0]!r}")

    for key, flag in _LISTS.items():
        have = _names(_run([ffmpeg, "-hide_banner", flag]), key)
        missing = [n for n in caps[key] if n not in have]
        if missing:
            failures.append(f"{key}: missing {missing}")

    protocols = _run([ffmpeg, "-hide_banner", "-protocols"])
    proto_names = {l.strip() for l in protocols.splitlines()}
    missing = [p for p in caps["protocols"] if p not in proto_names]
    if missing:
        failures.append(f"protocols: missing {missing}")

    tls_help = _run([ffmpeg, "-hide_banner", "-h", "protocol=tls"])
    for opt in caps["tls_options"]:
        if opt not in tls_help:
            failures.append(f"tls option missing: {opt} (patch 0001 not applied?)")

    if args.ffprobe:
        probe = _run([args.ffprobe, "-hide_banner", "-version"])
        if not re.search(rf"ffprobe version n?{re.escape(want)}\b", probe):
            failures.append(f"ffprobe version: expected {want}, got {probe.splitlines()[0]!r}")

    if failures:
        print("unified FFmpeg capability check FAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"unified FFmpeg capability check OK ({want}): "
          + ", ".join(f"{k}={len(caps[k])}" for k in _LISTS)
          + f", protocols={len(caps['protocols'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
