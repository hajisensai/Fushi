"""把软字幕烧进画面，做带真值的硬字幕样片（720p x264 CRF23，模拟真实硬字幕的有损压缩）。

片源是本机 BD 文件，不入库；换机器改下面的路径（任意带日文软字幕的番剧都行）。
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

MEDIA: Path = Path(__file__).resolve().parent / "media"
_TAKAGI_DIR: str = (
    "D:/downloads/Bangumi/Teasing.Master.Takagi-san.S01.1080p.BluRay.Remux.Dual-Audio.FLAC2.0.H.264-CRUCiBLE/"
    "Teasing.Master.Takagi-san.S01E01.1080p.BluRay.Remux.Dual-Audio.FLAC2.0.H.264-CRUCiBLE"
)
TAKAGI: str = _TAKAGI_DIR + ".mkv"
KON: str = "D:/downloads/Bangumi/[MTBB] K-ON! the Movie (2011) (BD 1080p) [805DBF12].mkv"
# 源字幕 → 复制进 media/ 后的文件名
SUB_SOURCES: dict[str, str] = {
    "takagi01.ja.srt": _TAKAGI_DIR + ".ja.srt",
    "kon_movie.ja.ass": "D:/downloads/Bangumi/[MTBB] K-ON! the Movie (2011) (BD 1080p) [805DBF12].ja.ass",
}

# (名字, 源视频, 源字幕, 起点秒, 时长秒, force_style)
SAMPLES: list[tuple[str, str, str, float, float, str]] = [
    ("takagi", TAKAGI, "takagi01.ja.srt", 0.0, 480.0, "FontName=Yu Gothic UI,Bold=1"),
    (
        "takagi_yellow",
        TAKAGI,
        "takagi01.ja.srt",
        480.0,
        480.0,
        "FontName=Yu Gothic UI,PrimaryColour=&H0000FFFF,Outline=1,Shadow=1",
    ),
    ("takagi_box", TAKAGI, "takagi01.ja.srt", 960.0, 420.0, "FontName=Yu Gothic UI,BorderStyle=3,Outline=2"),
    ("kon", KON, "kon_movie.ja.ass", 600.0, 600.0, ""),
]


def run(cmd: list[str]) -> None:
    r = subprocess.run(cmd, cwd=MEDIA, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        sys.stderr.write(r.stderr[-3000:])
        raise SystemExit(f"failed: {cmd[:6]}")


def burn(name: str, video: str, sub: str, start: float, dur: float, style: str) -> None:
    ext: str = Path(sub).suffix
    seg: str = f"{name}.seg{ext}"
    # 字幕按同一起点裁剪并平移到 0，作为真值。
    run(["ffmpeg", "-y", "-v", "error", "-ss", str(start), "-t", str(dur), "-i", sub, seg])
    filt: str = f"scale=1280:720,subtitles={seg}"
    if style:
        filt += f":force_style='{style}'"
    run(
        [
            "ffmpeg", "-y", "-v", "error", "-ss", str(start), "-t", str(dur), "-i", video,
            "-map", "0:v:0", "-map", "0:a:0", "-vf", filt,
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k", f"{name}.mp4",
        ]
    )
    print("done", name, flush=True)


if __name__ == "__main__":
    MEDIA.mkdir(exist_ok=True)
    for dst, src in SUB_SOURCES.items():
        if not (MEDIA / dst).exists():
            shutil.copyfile(src, MEDIA / dst)
    only: set[str] = set(sys.argv[1:])
    for s in SAMPLES:
        if not only or s[0] in only:
            burn(*s)
