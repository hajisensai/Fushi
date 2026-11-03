"""跑 benchmark：每条字幕模拟一次查词，比较帧差检测区间与真值。"""

from __future__ import annotations

import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, fields
from pathlib import Path

import numpy as np

from detect import Detection, Params, detect
from truth import Query, parse, queries

MEDIA: Path = Path(__file__).resolve().parent / "media"
SAMPLES: dict[str, str] = {
    "takagi": "takagi.seg.srt",
    "takagi_yellow": "takagi_yellow.seg.srt",
    "takagi_box": "takagi_box.seg.srt",
    "kon": "kon.seg.ass",
}
FRAME: float = 1001 / 24000


def duration(video: Path) -> float:
    out: str = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(video)], capture_output=True, text=True, errors="replace"
    ).stderr
    h, m, s = out.split("Duration: ")[1].split(",")[0].split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def iou(a: tuple[float, float], b: tuple[float, float]) -> float:
    inter: float = max(0.0, min(a[1], b[1]) - max(a[0], b[0]))
    union: float = max(a[1], b[1]) - min(a[0], b[0])
    return inter / union if union > 0 else 0.0


def run_sample(name: str, p: Params) -> list[dict[str, object]]:
    video: Path = MEDIA / f"{name}.mp4"
    dur: float = duration(video)
    qs: list[Query] = queries(parse(MEDIA / SAMPLES[name]), dur)

    def one(q: Query) -> dict[str, object]:
        d: Detection = detect(str(video), q.t, q.band, dur, p, str(MEDIA / f"{name}.subs.mkv"))
        return {"sample": name, **asdict(q), **{f"det_{k}": v for k, v in asdict(d).items()}}

    with ThreadPoolExecutor(8) as ex:
        return list(ex.map(one, qs))


def pct(x: np.ndarray, q: float) -> float:
    return float(np.percentile(x, q)) if len(x) else float("nan")


def summarize(rows: list[dict[str, object]]) -> dict[str, object]:
    found: list[dict[str, object]] = [r for r in rows if r["det_start"] is not None]
    n: int = len(rows)
    out: dict[str, object] = {"queries": n, "found": len(found)}
    if not found:
        return out
    ds: np.ndarray = np.array([r["det_start"] - r["state"][0] for r in found])
    de: np.ndarray = np.array([r["det_end"] - r["state"][1] for r in found])
    both: np.ndarray = np.maximum(np.abs(ds), np.abs(de))
    out.update(
        {
            "start_err_med_ms": round(float(np.median(np.abs(ds))) * 1000),
            "end_err_med_ms": round(float(np.median(np.abs(de))) * 1000),
            "within_1frame": round(float((both <= FRAME * 1.01).mean()), 3),
            "within_2frames": round(float((both <= 2 * FRAME * 1.01).mean()), 3),
            "within_250ms": round(float((both <= 0.25).mean()), 3),
            "gross_gt_500ms": int((both > 0.5).sum()),
            "iou_state_mean": round(float(np.mean([iou((r["det_start"], r["det_end"]), r["state"]) for r in found])), 3),
            "iou_cue_mean": round(float(np.mean([iou((r["det_start"], r["det_end"]), r["cue"]) for r in found])), 3),
            "iou_cue_naive5s_mean": round(
                float(np.mean([iou((r["t"] - 2.5, r["t"] + 2.5), r["cue"]) for r in rows])), 3
            ),
            "decode_ms_med": round(pct(np.array([r["det_decode_s"] for r in rows]), 50) * 1000),
            "decode_ms_p90": round(pct(np.array([r["det_decode_s"] for r in rows]), 90) * 1000),
            "analyze_ms_med": round(pct(np.array([r["det_analyze_s"] for r in rows]), 50) * 1000),
        }
    )
    return out


if __name__ == "__main__":
    # 用法：python bench.py <tag> [key=value ...] [sample ...]
    tag: str = sys.argv[1] if len(sys.argv) > 1 else "best"
    kv: dict[str, str] = dict(a.split("=", 1) for a in sys.argv[2:] if "=" in a)
    names: list[str] = [a for a in sys.argv[2:] if "=" not in a] or [
        n for n in SAMPLES if (MEDIA / f"{n}.mp4").exists()
    ]
    types: dict[str, type] = {f.name: type(getattr(Params(), f.name)) for f in fields(Params)}
    p: Params = Params(
        **{k: (v.lower() == "true" if types[k] is bool else types[k](v)) for k, v in kv.items()}
    )
    all_rows: list[dict[str, object]] = []
    summary: dict[str, object] = {"params": asdict(p)}
    for nm in names:
        rows = run_sample(nm, p)
        all_rows += rows
        summary[nm] = summarize(rows)
        print(nm, json.dumps(summary[nm], ensure_ascii=False), flush=True)
    summary["ALL"] = summarize(all_rows)
    print("ALL", json.dumps(summary["ALL"], ensure_ascii=False))
    out: Path = Path(__file__).resolve().parent / "results"
    out.mkdir(exist_ok=True)
    (out / f"{tag}_rows.json").write_text(json.dumps(all_rows, ensure_ascii=False, indent=1), encoding="utf-8")
    (out / f"{tag}_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
