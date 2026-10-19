#!/usr/bin/env python3
"""Write the corresponding-source notice shipped with every unified FFmpeg build.

The unified FFmpeg is GPL-3.0-or-later (--enable-gpl --enable-version3, x264),
so a binary distribution must say where its complete corresponding source is.
FFmpegKitNext's stock SOURCE file only points at the upstream wiki, which does
not contain Fushi's patches. This notice names the exact upstream versions and
the Fushi recipe (version pins + patches + build scripts) at the commit the
build was made from. It replaces FFmpegKitNext's tools/source/SOURCE before a
mobile/macOS build (-> AAR res/raw/source.txt, ffmpegkit.framework SOURCE, the
macOS layout) and is written into licenses/ffmpeg-unified/ of the Windows
runtime archive.

    source_notice.py [--commit SHA] > SOURCE

The commit defaults to $GITHUB_SHA, then to `git rev-parse HEAD` of this
checkout.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO_URL = "https://github.com/hajisensai/Fushi"


def recipe() -> dict[str, str]:
    out: dict[str, str] = {}
    for line in (HERE / "recipe.env").read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            out[key] = value.strip()
    return out


def fushi_commit(explicit: str | None) -> str:
    if explicit:
        return explicit
    if os.environ.get("GITHUB_SHA"):
        return os.environ["GITHUB_SHA"]
    try:
        return subprocess.check_output(["git", "-C", str(HERE), "rev-parse", "HEAD"],
                                       text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def notice(commit: str) -> str:
    r = recipe()
    patches_ffmpeg = sorted(p.name for p in (HERE / "patches/ffmpeg").glob("*.patch"))
    patches_kit = sorted(p.name for p in (HERE / "patches/ffmpeg-kit-next").glob("*.patch"))
    tree = f"{REPO_URL}/tree/{commit}/tool/ffmpeg-unified"
    lines = [
        "Corresponding source of this FFmpeg build (Fushi unified FFmpeg)",
        "===============================================================",
        "",
        "This binary is FFmpeg built with --enable-gpl --enable-version3 and is",
        "distributed under the GNU General Public License version 3 or later.",
        "Its complete corresponding source is:",
        "",
        f"1. FFmpeg {r['FFMPEG_VERSION']}: {r['FFMPEG_REPO']}",
        f"   tag {r['FFMPEG_TAG']}, commit {r['FFMPEG_COMMIT']}",
        f"2. FFmpegKitNext (Android / iOS command runner): {r['FFMPEG_KIT_NEXT_REPO']}",
        f"   tag {r['FFMPEG_KIT_NEXT_TAG']}, commit {r['FFMPEG_KIT_NEXT_COMMIT']}",
        "   Its build scripts pin the external libraries (x264, libvpx, Opus,",
        "   dav1d, SVT-AV1, libwebp, OpenSSL, libxml2, ...); their versions and",
        "   download locations are listed in scripts/source.sh at that commit and",
        "   on https://github.com/arthenica/ffmpeg-kit-next/wiki/Source.",
        "3. Fushi's modifications and build recipe, applied on top of the above:",
        f"   {tree}",
        f"   (repository {REPO_URL}, commit {commit})",
        "   - recipe.env                      version pins",
        *[f"   - patches/ffmpeg/{p}" for p in patches_ffmpeg],
        *[f"   - patches/ffmpeg-kit-next/{p}" for p in patches_kit],
        "   - prepare_ffmpeg_src.sh, mobile/, windows/   build scripts",
        "",
        "To rebuild: check out the Fushi commit above and run",
        "tool/ffmpeg-unified/mobile/build_{android,ios,macos}.sh or",
        "tool/ffmpeg-unified/windows/build_ffmpeg_msys2.sh.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit")
    args = ap.parse_args()
    sys.stdout.write(notice(fushi_commit(args.commit)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
