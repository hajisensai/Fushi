"""Score end-to-end OCR output (detector + recognizer) against labels.jsonl.

Predictions are jsonl lines {"image", "ms", "blocks": [{"lines", "lineBoxes",
"box", "vertical"}]}, as written by packages/fushi_server/tool/ocr_pipeline_eval.dart
(the app pipeline) or bench_e2e.py (Python det+rec combinations).

Metrics (all on the folded "body" text view, see metrics.py):
- line CER: for every labelled line, the predicted lines whose box lies mostly
  inside it (or that it lies mostly inside) are joined and compared. A missed
  line counts as all deletions, so detection misses show up here.
- char recall / precision: character bags per image. --precision-band limits the
  predictions counted for precision to y >= band*height (subtitle band), so
  on-screen text that is not a subtitle (logos, signs) is not counted as noise.

Usage:
  python -I -X utf8 score_pipeline.py --data DIR --pred preds.jsonl [--pred more.jsonl] [--precision-band 0.78]
"""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

import cv2

from metrics import BagScore, Score


def overlap(a, b) -> float:
    """Intersection area over the smaller box's area."""
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    small = min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
    return inter / small if small > 0 else 0.0


def pred_lines(rec: dict) -> list[tuple[str, list[float]]]:
    out = []
    for b in rec["blocks"]:
        boxes = b.get("lineBoxes") or []
        if len(boxes) == len(b["lines"]):
            out += list(zip(b["lines"], boxes))
        else:  # no per-line geometry: fall back to the block box
            out.append(("".join(b["lines"]), b["box"]))
    return out


def score(data: Path, pred_path: Path, band: float | None) -> dict:
    labels = {
        r["image"]: r
        for r in (json.loads(l) for l in (data / "labels.jsonl").read_text(encoding="utf-8").splitlines() if l)
    }
    preds = [json.loads(l) for l in pred_path.read_text(encoding="utf-8").splitlines() if l]
    line_score = Score("body", fold=True)
    bag = BagScore(fold=True)
    times = []
    heights: dict[str, int] = {}
    for p in preds:
        ref = labels.get(p["image"])
        if ref is None:
            continue
        times.append(p["ms"])
        gt = [l for l in ref["lines"] if l.get("role") != "en" and l.get("text")]
        plines = pred_lines(p)
        for g in gt:
            hits = [t for t, box in plines if overlap(g["box"], box) >= 0.5]
            line_score.add("".join(hits), g["text"])
        counted = plines
        if band is not None:
            if p["image"] not in heights:
                heights[p["image"]] = cv2.imread(str(data / p["image"])).shape[0]
            cut = heights[p["image"]] * band
            counted = [(t, box) for t, box in plines if (box[1] + box[3]) / 2 >= cut]
        # Page-level-only sets (Pepper&Carrot) carry the whole page text instead of lines.
        ref_text = ref.get("page_text") or "".join(g["text"] for g in gt)
        bag.add("".join(t for t, _ in counted), ref_text)
    return {
        "images": len(times),
        "line_cer": line_score.cer,
        "line_exact": line_score.exact_rate,
        "recall": bag.recall,
        "precision": bag.precision,
        "ms_median": statistics.median(times) if times else 0,
        "ms_mean": statistics.fmean(times) if times else 0,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--pred", action="append", required=True, type=Path)
    ap.add_argument("--precision-band", type=float)
    args = ap.parse_args()
    print("| run | images | line CER | line exact | char recall | char precision | ms/image median |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for pred in args.pred:
        m = score(args.data, pred, args.precision_band)
        cer = "n/a" if m["line_cer"] == 0 and m["line_exact"] == 0 else f"{m['line_cer']:.2%}"
        print(f"| {pred.stem} | {m['images']} | {cer} | {m['line_exact']:.1%} | "
              f"{m['recall']:.1%} | {m['precision']:.1%} | {m['ms_median']:.0f} |")


if __name__ == "__main__":
    main()
