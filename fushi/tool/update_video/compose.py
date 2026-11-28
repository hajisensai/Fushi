"""把实机录屏片段与文字卡拼成一期更新视频（B 站 1920×1080 / 30fps）。

    python tool/update_video/compose.py --spec tool/update_video/3.4.0.json \
        --clips <postprocess 产出的 preview 目录> --out <成片.mp4> [--bgm <音乐>] [--keep-work]

spec 见同目录 3.4.0.json：segments 依次是
  card   标题卡：title / subtitle / seconds（logo: true 时放 app 图标）
  clip   实机片段：file（相对 --clips）/ from / to（秒，可省）/ caption / tag
  flash  文字快闪：items（[标题, 说明]）/ secondsEach
无配音：字幕卡烧进画面，片段保留 app 原声，--bgm 给了就垫在下面（片段原声处自动压低）。
只依赖 PATH 上的 ffmpeg 与 Pillow。
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H, FPS = 1920, 1080, 30
FADE = 0.35  # 段间淡入淡出（秒）
LOUDNORM = "loudnorm=I=-16:TP=-1.5:LRA=11"  # 成片响度（B 站等平台常见 -14～-16 LUFS）
ROOT = Path(__file__).resolve().parents[2]  # fushi/
ICON = ROOT / "assets" / "meta" / "launcher_icon_squircle.png"


def font(path: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, size)


def brand_color() -> tuple[int, int, int]:
    """取图标的主色当强调色，换图标不用改脚本。"""
    img = Image.open(ICON).convert("RGBA").resize((64, 64))
    px = [p[:3] for p in img.getdata() if p[3] > 200]
    # 去掉近白近黑，取饱和度最高的一档的平均。
    def sat(c: tuple[int, int, int]) -> int:
        return max(c) - min(c)

    px = sorted((c for c in px if 40 < sum(c) / 3 < 230), key=sat, reverse=True)
    top = px[: max(1, len(px) // 4)]
    return tuple(sum(c[i] for c in top) // len(top) for i in range(3))  # type: ignore[return-value]


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


class Painter:
    def __init__(self, fonts: dict[str, str], accent: str | None = None) -> None:
        self.regular = fonts["regular"]
        self.bold = fonts["bold"]
        self.accent = (
            tuple(int(accent.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[assignment]
            if accent else brand_color()
        )
        self.bg = mix(self.accent, (255, 255, 255), 0.92)
        self.ink = mix(self.accent, (0, 0, 0), 0.78)

    def _background(self) -> Image.Image:
        img = Image.new("RGB", (W, H), self.bg)
        d = ImageDraw.Draw(img)
        # 右下角两个大色块，呼应 M3E 色块风格。
        d.ellipse((W - 760, H - 640, W + 360, H + 480), fill=mix(self.accent, self.bg, 0.55))
        d.rounded_rectangle((-240, -260, 520, 300), radius=180, fill=mix(self.accent, self.bg, 0.78))
        return img.filter(ImageFilter.GaussianBlur(2))

    def card(self, title: str, subtitle: str, logo: bool) -> Image.Image:
        img = self._background()
        d = ImageDraw.Draw(img)
        y = 330
        if logo:
            icon = Image.open(ICON).convert("RGBA").resize((200, 200), Image.LANCZOS)
            img.paste(icon, (W // 2 - 100, 190), icon)
            y = 440
        ft = font(self.bold, 104)
        d.text((W // 2, y), title, font=ft, fill=self.ink, anchor="ma")
        if subtitle:
            fs = font(self.regular, 48)
            for i, line in enumerate(subtitle.split("\n")):
                d.text((W // 2, y + 160 + i * 70), line, font=fs, fill=mix(self.ink, self.bg, 0.3), anchor="ma")
        return img

    def flash(self, head: str, body: str, index: int, total: int) -> Image.Image:
        img = self._background()
        d = ImageDraw.Draw(img)
        d.text((W // 2, 400), head, font=font(self.bold, 96), fill=self.ink, anchor="ma")
        d.text((W // 2, 560), body, font=font(self.regular, 46), fill=mix(self.ink, self.bg, 0.3), anchor="ma")
        # 底部进度点。
        gap, r = 34, 8
        x0 = W // 2 - (total - 1) * gap // 2
        for i in range(total):
            c = self.accent if i == index else mix(self.accent, self.bg, 0.7)
            d.ellipse((x0 + i * gap - r, 900 - r, x0 + i * gap + r, 900 + r), fill=c)
        return img

    def caption(self, text: str, tag: str, top: bool = False) -> Image.Image:
        """片段上的下三分之一字幕条（RGBA，叠在画面上）。"""
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        fc = font(self.bold, 50)
        ftag = font(self.bold, 34)
        tw = d.textlength(text, font=fc)
        tagw = d.textlength(tag, font=ftag) + 44 if tag else 0
        pad = 34
        box_w = tw + tagw + pad * 2 + (24 if tag else 0)
        x0 = (W - box_w) / 2
        # 顶部：片段自带字幕（番剧台词）在底部时不挡它。
        y0, y1 = (70, 180) if top else (H - 190, H - 80)
        d.rounded_rectangle((x0, y0, x0 + box_w, y1), radius=30, fill=(*mix(self.ink, (0, 0, 0), 0.3), 225))
        x = x0 + pad
        if tag:
            d.rounded_rectangle((x, y0 + 26, x + tagw, y1 - 26), radius=29, fill=(*self.accent, 255))
            d.text((x + tagw / 2, (y0 + y1) / 2), tag, font=ftag, fill=(255, 255, 255, 255), anchor="mm")
            x += tagw + 24
        d.text((x, (y0 + y1) / 2), text, font=fc, fill=(255, 255, 255, 255), anchor="lm")
        return img


def run(cmd: list[str]) -> None:
    print("+ ffmpeg " + " ".join(cmd[1:])[:300], flush=True)
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        sys.stderr.write(r.stderr[-4000:])
        raise SystemExit(f"ffmpeg 失败（exit {r.returncode}）")


def probe_duration(path: Path) -> float:
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True,
    )
    return float(r.stdout.strip())


def has_audio(path: Path) -> bool:
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True,
    )
    return bool(r.stdout.strip())


ENC = ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-r", str(FPS),
       "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"]


def still_segment(img: Image.Image, seconds: float, out: Path, work: Path,
                  fade_in: bool = True, fade_out_: bool = True) -> None:
    png = work / (out.stem + ".png")
    img.save(png)
    fade_out = max(0.0, seconds - FADE)
    fades = ",".join(
        f for f, on in ((f"fade=t=in:d={FADE}", fade_in), (f"fade=t=out:st={fade_out}:d={FADE}", fade_out_)) if on
    )
    run(["ffmpeg", "-y", "-loop", "1", "-framerate", str(FPS), "-t", f"{seconds}", "-i", str(png),
         "-f", "lavfi", "-t", f"{seconds}", "-i", "anullsrc=r=48000:cl=stereo",
         # 不做缓放：zoompan 逐帧把裁切坐标取整到整像素，慢推时文字一抖一抖。
         "-vf", f"scale={W}:{H},format=yuv420p" + (f",{fades}" if fades else ""),
         "-shortest", *ENC, str(out)])


def clip_segment(seg: dict, clips: Path, out: Path, work: Path, painter: Painter) -> None:
    src = clips / seg["file"]
    if not src.exists():
        raise SystemExit(f"缺片段：{src}")
    start = float(seg.get("from", 0))
    end = float(seg["to"]) if "to" in seg else probe_duration(src)
    dur = end - start
    cap = work / (out.stem + "-cap.png")
    painter.caption(seg.get("caption", ""), seg.get("tag", ""), seg.get("captionPos") == "top").save(cap)
    fade_out = max(0.0, dur - FADE)
    # 片段居中放进 1080p 画布：横版铺满，竖版（漫画）两侧用模糊放大的同一画面垫底。
    vf = (
        f"[0:v]split[a][b];"
        f"[a]scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},boxblur=40:2,eq=brightness=-0.08[bg];"
        f"[b]scale={W}:{H}:force_original_aspect_ratio=decrease:flags=lanczos[fg];"
        f"[bg][fg]overlay=(W-w)/2:(H-h)/2[base];"
        f"[1:v]format=rgba,fade=t=in:st=0.5:d=0.4:alpha=1[cap];"
        f"[base][cap]overlay=0:0,fps={FPS},format=yuv420p,"
        f"fade=t=in:d={FADE},fade=t=out:st={fade_out}:d={FADE}[v]"
    )
    audio_in = ["-ss", f"{start}", "-t", f"{dur}", "-i", str(src)] if has_audio(src) else \
        ["-f", "lavfi", "-t", f"{dur}", "-i", "anullsrc=r=48000:cl=stereo"]
    af = f"[2:a]aresample=48000,afade=t=in:d={FADE},afade=t=out:st={fade_out}:d={FADE},apad[aout]"
    run(["ffmpeg", "-y", "-ss", f"{start}", "-t", f"{dur}", "-i", str(src),
         "-loop", "1", "-framerate", str(FPS), "-t", f"{dur}", "-i", str(cap),
         *audio_in,
         "-filter_complex", vf + ";" + af, "-map", "[v]", "-map", "[aout]", "-t", f"{dur}",
         *ENC, str(out)])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True)
    ap.add_argument("--clips", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--bgm")
    ap.add_argument("--bgm-volume", type=float, default=0.35)
    ap.add_argument("--keep-work", action="store_true")
    args = ap.parse_args()

    spec = json.loads(Path(args.spec).read_text(encoding="utf-8"))
    painter = Painter(spec["fonts"], spec.get("accent"))
    clips = Path(args.clips)
    work = Path(tempfile.mkdtemp(prefix="fushi-update-video-"))
    parts: list[Path] = []
    try:
        for i, seg in enumerate(spec["segments"]):
            kind = seg["type"]
            if kind == "card":
                out = work / f"{i:02d}-card.mp4"
                still_segment(painter.card(seg["title"], seg.get("subtitle", ""), seg.get("logo", False)),
                              float(seg["seconds"]), out, work)
                parts.append(out)
            elif kind == "clip":
                out = work / f"{i:02d}-clip.mp4"
                clip_segment(seg, clips, out, work, painter)
                parts.append(out)
            elif kind == "flash":
                items = seg["items"]
                for j, (head, body) in enumerate(items):
                    out = work / f"{i:02d}-{j:02d}-flash.mp4"
                    # 组内直接切，只在整组首尾淡入淡出（逐张过黑会一闪一闪）。
                    still_segment(painter.flash(head, body, j, len(items)), float(seg["secondsEach"]), out, work,
                                  fade_in=j == 0, fade_out_=j == len(items) - 1)
                    parts.append(out)
            else:
                raise SystemExit(f"未知段落类型 {kind}")

        listing = work / "parts.txt"
        listing.write_text("".join(f"file '{p.as_posix()}'\n" for p in parts), encoding="utf-8")
        joined = work / "joined.mp4"
        run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(listing), "-c", "copy", str(joined)])

        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        if args.bgm:
            total = probe_duration(joined)
            # 片段原声出现时 BGM 自动压低（sidechaincompress），结尾 2 秒淡出。
            run(["ffmpeg", "-y", "-i", str(joined), "-stream_loop", "-1", "-i", args.bgm,
                 "-filter_complex",
                 f"[0:a]asplit[voice][key];"
                 f"[1:a]aresample=48000,volume={args.bgm_volume},atrim=0:{total},"
                 f"afade=t=in:d=1,afade=t=out:st={max(0.0, total - 2)}:d=2[bgm];"
                 f"[bgm][key]sidechaincompress=threshold=0.03:ratio=6:attack=20:release=400[duck];"
                 f"[voice][duck]amix=inputs=2:normalize=0:duration=first,{LOUDNORM}[a]",
                 "-map", "0:v", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                 "-movflags", "+faststart", str(out)])
        else:
            run(["ffmpeg", "-y", "-i", str(joined), "-af", LOUDNORM, "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                 "-movflags", "+faststart", str(out)])
        print(f"完成：{out}（{probe_duration(out):.1f} 秒）")
    finally:
        if args.keep_work:
            print(f"中间产物：{work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
