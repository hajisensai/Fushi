"""End-to-end det+rec runs (Python) for detector/recognizer combinations the app
does not ship yet. Writes predictions in the same jsonl shape as
packages/fushi_server/tool/ocr_pipeline_eval.dart so score_pipeline.py scores both.

Region:
  --band 0     whole image, detector input resized so the long side is --long
  --band 0.78  only the bottom 22% (subtitle band) at native resolution

Usage:
  python -I -X utf8 bench_e2e.py --data DIR --models M --shipped S --det NAME --rec NAME \
      --out preds.jsonl [--band 0.78] [--long 960]
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import cv2

from registry import load_detector, load_recognizer


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--models", required=True, type=Path)
    ap.add_argument("--shipped", required=True, type=Path)
    ap.add_argument("--det", required=True)
    ap.add_argument("--rec", required=True)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--band", type=float, default=0.0)
    ap.add_argument("--long", type=int, default=960)
    ap.add_argument("--threads", type=int, default=4)
    args = ap.parse_args()

    det = load_detector(args.det, args.models, args.shipped, args.threads,
                        resize_long=None if args.band > 0 else args.long)
    rec = load_recognizer(args.rec, args.models, args.shipped, args.threads)
    records = [json.loads(l) for l in (args.data / "labels.jsonl").read_text(encoding="utf-8").splitlines() if l]
    with args.out.open("w", encoding="utf-8") as out:
        for r in records:
            img = cv2.imread(str(args.data / r["image"]))
            top = int(img.shape[0] * args.band)
            start = time.perf_counter()
            boxes = det.detect(img[top:])
            lines, line_boxes = [], []
            for b in sorted(boxes, key=lambda b: (b.y0, b.x0)):
                crop = img[top + b.y0: top + b.y1, b.x0: b.x1]
                text = rec.recognize(crop, b.vertical).text
                if text:
                    lines.append(text)
                    line_boxes.append([b.x0, b.y0 + top, b.x1, b.y1 + top])
            ms = (time.perf_counter() - start) * 1000
            out.write(json.dumps({
                "image": r["image"], "ms": round(ms, 1),
                "blocks": [{"box": [0, top, img.shape[1], img.shape[0]], "vertical": False,
                            "lines": lines, "lineBoxes": line_boxes}],
            }, ensure_ascii=False) + "\n")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
