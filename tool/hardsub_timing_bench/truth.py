"""解析烧录用的字幕，生成每条查词的真值区间。

真值有两种：
* cue：这条字幕自己的 [start, end)；
* state：查词点所在、同一区域（上 / 下）可见字幕集合不变的最大区间——帧差理论上能看到的就是它。
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Event:
    start: float
    end: float
    text: str
    band: str  # "top" | "bottom"


@dataclass(frozen=True)
class Query:
    t: float
    band: str
    text: str
    cue: tuple[float, float]
    state: tuple[float, float]


_TS = re.compile(r"(\d+):(\d+):(\d+)[,.](\d+)")
_TAG = re.compile(r"\{[^}]*\}")


def _ts(s: str) -> float:
    m = _TS.search(s)
    assert m, s
    h, mi, se, frac = m.groups()
    return int(h) * 3600 + int(mi) * 60 + int(se) + int(frac) / (10 ** len(frac))


def parse_srt(path: Path) -> list[Event]:
    raw: str = path.read_text(encoding="utf-8-sig")
    out: list[Event] = []
    for block in re.split(r"\n\s*\n", raw.strip()):
        lines: list[str] = block.strip().splitlines()
        idx: int = next((i for i, l in enumerate(lines) if "-->" in l), -1)
        if idx < 0:
            continue
        a, b = lines[idx].split("-->")
        body: str = "\n".join(lines[idx + 1 :])
        band: str = "top" if re.search(r"\\an[789]", body) else "bottom"
        text: str = _TAG.sub("", body).strip()
        if text:
            out.append(Event(_ts(a), _ts(b), text, band))
    return out


def parse_ass(path: Path) -> list[Event]:
    raw: str = path.read_text(encoding="utf-8-sig")
    play_y: float = 1080.0
    styles: dict[str, int] = {}
    fmt: list[str] = []
    out: list[Event] = []
    for line in raw.splitlines():
        if line.startswith("PlayResY:"):
            play_y = float(line.split(":")[1])
        elif line.startswith("Format:"):
            fmt = [f.strip() for f in line[7:].split(",")]
        elif line.startswith("Style:"):
            vals: list[str] = [v.strip() for v in line[6:].split(",")]
            styles[vals[0]] = int(vals[fmt.index("Alignment")])
        elif line.startswith("Dialogue:"):
            vals = line[9:].split(",", len(fmt) - 1)
            d: dict[str, str] = dict(zip(fmt, (v.strip() for v in vals)))
            if "-" in d["Start"] or "-" in d["End"]:
                continue  # ffmpeg 裁剪后落在片段起点之前的事件

            body: str = d["Text"]
            if re.search(r"\\p[1-9]", body):
                continue  # 绘图
            text: str = _TAG.sub("", body).replace("\\N", "\n").replace("\\n", "\n").strip()
            if not text:
                continue
            an: int = styles.get(d["Style"], 2)
            m = re.search(r"\\an(\d)", body)
            if m:
                an = int(m.group(1))
            band: str = "top" if an >= 7 else "bottom"
            p = re.search(r"\\(?:pos|move)\(\s*[-\d.]+\s*,\s*([-\d.]+)", body)
            if p:
                band = "top" if float(p.group(1)) < play_y / 2 else "bottom"
            out.append(Event(_ts(d["Start"]), _ts(d["End"]), text, band))
    return out


def parse(path: Path) -> list[Event]:
    return parse_ass(path) if path.suffix == ".ass" else parse_srt(path)


def queries(events: list[Event], duration: float, min_state: float = 0.3) -> list[Query]:
    out: list[Query] = []
    for band in ("top", "bottom"):
        evs: list[Event] = [e for e in events if e.band == band and e.end > 0 and e.start < duration]
        bounds: list[float] = sorted({x for e in evs for x in (max(e.start, 0.0), min(e.end, duration))})
        for e in evs:
            if e.start < 1.0 or e.end > duration - 1.0:
                continue
            mid: float = (e.start + e.end) / 2
            lo: float = max(b for b in bounds if b <= mid)
            hi: float = min(b for b in bounds if b > mid)
            if hi - lo < min_state:
                continue
            out.append(Query((lo + hi) / 2, band, e.text, (e.start, e.end), (lo, hi)))
    out.sort(key=lambda q: q.t)
    return out
