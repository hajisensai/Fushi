"""Build the synthetic donghua subtitle set: Chinese subtitle lines rendered over
real frames of a video, in the styles burned-in subtitles usually use.

Ground truth is exact (we render it). Output (in --out):
  frames/NNNN.jpg      full 1920x1080 frame with the subtitle burned in
  labels.jsonl         one record per frame: lines[{text, box, script, role}]

Frames come from the video's body (skips the first/last minutes where OP/ED
credits already carry text). Lines come from lines_zh.txt next to this script;
about half are converted to Traditional with OpenCC so both scripts are tested.

Usage:
  python -I -X utf8 make_video_synth.py --video EP.mkv [--video EP2.mkv] --out DIR [--count 160]
"""

from __future__ import annotations

import argparse
import json
import random
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

try:
    import opencc

    S2T = opencc.OpenCC("s2t")
except Exception:
    S2T = None

FONTS_SC = ["msyh.ttc", "msyhbd.ttc", "Deng.ttf", "Dengb.ttf", "simhei.ttf", "simsun.ttc", "simkai.ttf"]
FONTS_TC = ["msjh.ttc", "msjhbd.ttc", "mingliu.ttc", "kaiu.ttf"]
FONT_DIR = Path("C:/Windows/Fonts")
ENGLISH = [
    "Do you really think you can stop me?",
    "The formation is about to collapse.",
    "Senior brother, please wait for me.",
    "This pill will restore your spiritual power.",
    "Leave now, before the sect elders arrive.",
    "I have never seen such a powerful treasure.",
]

STYLES = ["outline", "outline", "outline", "shadow", "yellow", "thin", "boxed"]


def probe_duration(video: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(video)],
        capture_output=True, text=True, check=True,
    )
    return float(out.stdout.strip())


def grab_frame(video: Path, t: float, dest: Path) -> None:
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-ss", f"{t:.2f}", "-i", str(video), "-frames:v", "1",
         "-vf", "scale=1920:1080", "-sn", str(dest)],
        check=True,
    )


def draw_line(
    img: Image.Image, text: str, font: ImageFont.FreeTypeFont, y: int, style: str, rng: random.Random
) -> tuple[int, int, int, int]:
    draw = ImageDraw.Draw(img)
    l, t, r, b = draw.textbbox((0, 0), text, font=font)
    w, h = r - l, b - t
    x = (img.width - w) // 2 - l
    stroke = 0
    fill = (255, 255, 255)
    stroke_fill = (0, 0, 0)
    if style == "outline":
        stroke = rng.choice([2, 3, 4])
    elif style == "yellow":
        stroke = 3
        fill = (255, 228, 92)
    elif style == "thin":
        fill = (235, 235, 235)
    elif style == "shadow":
        shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(shadow).text((x + 3, y + 3), text, font=font, fill=(0, 0, 0, 220))
        img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(2)))
    elif style == "boxed":
        pad = 10
        overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(overlay).rectangle(
            (x + l - pad, y + t - pad, x + r + pad, y + b + pad), fill=(0, 0, 0, 150)
        )
        img.alpha_composite(overlay)
    draw = ImageDraw.Draw(img)
    draw.text((x, y), text, font=font, fill=fill, stroke_width=stroke, stroke_fill=stroke_fill)
    return (x + l - stroke, y + t - stroke, x + r + stroke, y + b + stroke)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", action="append", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--count", type=int, default=160)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    lines = [
        ln.strip() for ln in (Path(__file__).with_name("lines_zh.txt")).read_text(encoding="utf-8").splitlines()
        if ln.strip() and not ln.startswith("#")
    ]
    frames_dir = args.out / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    raw_dir = args.out / "_raw"
    raw_dir.mkdir(exist_ok=True)

    durations = {v: probe_duration(v) for v in args.video}
    records = []
    for i in range(args.count):
        video = args.video[i % len(args.video)]
        dur = durations[video]
        t = rng.uniform(150, dur - 150)
        raw = raw_dir / f"{i:04d}.png"
        if not raw.exists():
            grab_frame(video, t, raw)
        img = Image.open(raw).convert("RGBA")

        text = lines[i % len(lines)]
        traditional = S2T is not None and rng.random() < 0.45
        if traditional:
            text = S2T.convert(text)
        font_name = rng.choice(FONTS_TC if traditional else FONTS_SC)
        size = rng.choice([40, 46, 52, 58, 64])
        font = ImageFont.truetype(str(FONT_DIR / font_name), size)
        style = rng.choice(STYLES)
        bilingual = rng.random() < 0.25

        out_lines = []
        # Stay above the bottom ~22% so the line never overlaps the source's own
        # burned-in subtitles (those are scored separately in the real set).
        base_y = int(img.height * 0.77) - rng.randint(0, 140) - (size + 44 if bilingual else 0) - size
        box = draw_line(img, text, font, base_y, style, rng)
        out_lines.append({"text": text, "box": box, "script": "tc" if traditional else "sc", "role": "zh"})
        if bilingual:
            en = rng.choice(ENGLISH)
            en_font = ImageFont.truetype(str(FONT_DIR / "arial.ttf"), int(size * 0.7))
            en_box = draw_line(img, en, en_font, box[3] + 14, "outline" if style != "boxed" else "boxed", rng)
            out_lines.append({"text": en, "box": en_box, "script": "en", "role": "en"})

        name = f"{i:04d}.jpg"
        img.convert("RGB").save(frames_dir / name, quality=88)
        records.append({
            "image": f"frames/{name}", "video": video.name, "t": round(t, 2),
            "font": font_name, "size": size, "style": style, "lines": out_lines,
        })

    with (args.out / "labels.jsonl").open("w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {len(records)} frames to {args.out}")


if __name__ == "__main__":
    main()
