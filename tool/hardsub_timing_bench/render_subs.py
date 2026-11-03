"""在黑底上单独渲染字幕（与烧录同参数），用来模拟「OCR 给出的字框」和精确字形掩码。"""

from __future__ import annotations

import subprocess
import sys

from bench import MEDIA, SAMPLES, duration
from burn import SAMPLES as BURN

STYLE: dict[str, str] = {s[0]: s[5] for s in BURN}

if __name__ == "__main__":
    for name in sys.argv[1:] or list(SAMPLES):
        dur: float = duration(MEDIA / f"{name}.mp4")
        filt: str = f"subtitles={SAMPLES[name]}"
        if STYLE[name]:
            filt += f":force_style='{STYLE[name]}'"
        filt += ",format=gray"
        subprocess.run(
            [
                "ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i",
                f"color=black:s=1280x720:r=24000/1001:d={dur:.3f}", "-vf", filt,
                "-c:v", "ffv1", f"{name}.subs.mkv",
            ],
            cwd=MEDIA,
            check=True,
        )
        print("rendered", name, flush=True)
