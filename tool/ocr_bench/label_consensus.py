"""Draft ground truth for real burned-in subtitle frames by model consensus.

For each frame in events.jsonl: find subtitle lines in the bottom band with a
detector, read each line with every recognizer, and
- if at least --agree recognizers give the same normalized text, accept it
  ("agreed");
- otherwise write the crop to review/ with all candidates ("review"). A human
  fixes those in review_fixes.json ({"<image>#<line>": "text"} or null to drop
  the line); re-running merges the fixes.

Agreement between independent models is not ground truth for hard cases, but
these subtitles are clean typeset text; the review sheet also lets a human spot
check agreed lines. The report states how many labels were human-checked.

Usage:
  python -I -X utf8 label_consensus.py --data DIR --models M --shipped S
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

import cv2
import numpy as np

from metrics import normalize
from registry import load_detector, load_recognizer

VOTERS = ["kellenok_v0.2", "ppocrv6_small", "ppocrv5_mobile", "ppocrv5_server"]


def subtitle_lines(det_boxes, band_top: int, frame_w: int) -> list[list[int]]:
    """Keep horizontal, roughly centred boxes and merge those on one row."""
    rows: list[list[int]] = []
    for b in sorted(det_boxes, key=lambda b: (b.y0, b.x0)):
        h = b.y1 - b.y0
        w = b.x1 - b.x0
        cx = (b.x0 + b.x1) / 2
        if b.vertical or h < 22 or h > 110 or w < h:
            continue
        if abs(cx - frame_w / 2) > frame_w * 0.33:
            continue
        box = [b.x0, b.y0 + band_top, b.x1, b.y1 + band_top]
        for row in rows:
            overlap = min(row[3], box[3]) - max(row[1], box[1])
            if overlap > 0.5 * min(row[3] - row[1], box[3] - box[1]):
                row[:] = [min(row[0], box[0]), min(row[1], box[1]), max(row[2], box[2]), max(row[3], box[3])]
                break
        else:
            rows.append(box)
    return sorted(rows, key=lambda r: r[1])


def page_lines(det_boxes) -> list[tuple[list[int], bool]]:
    """Comic page: keep every text line/column that is big enough to read."""
    out = []
    for b in det_boxes:
        w, h = b.x1 - b.x0, b.y1 - b.y0
        if min(w, h) < 10 or max(w, h) < 18:
            continue
        out.append(([b.x0, b.y0, b.x1, b.y1], b.vertical))
    # Manga reading order is not needed for per-line scoring; keep a stable order.
    return sorted(out, key=lambda t: (-t[0][2], t[0][1]))


def pad_crop(img: np.ndarray, box: list[int], pad: int = 4) -> np.ndarray:
    h, w = img.shape[:2]
    x0, y0, x1, y1 = box
    return img[max(0, y0 - pad): min(h, y1 + pad), max(0, x0 - pad): min(w, x1 + pad)]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--models", required=True, type=Path)
    ap.add_argument("--shipped", required=True, type=Path)
    ap.add_argument("--mode", choices=["subtitle", "page"], default="subtitle")
    ap.add_argument("--detector", help="default: ppocrv5_server_det (subtitle) / kellenok_det_v0.2 (page)")
    ap.add_argument("--agree", type=int, default=3)
    ap.add_argument("--band", type=float, default=0.78, help="band top as a fraction of frame height")
    args = ap.parse_args()

    page_mode = args.mode == "page"
    det_name = args.detector or ("kellenok_det_v0.2" if page_mode else "ppocrv5_server_det")
    det = load_detector(det_name, args.models, args.shipped, 8, resize_long=960 if page_mode else None)
    recs = [load_recognizer(n, args.models, args.shipped, 8) for n in VOTERS]
    fixes_path = args.data / "review_fixes.json"
    fixes = json.loads(fixes_path.read_text(encoding="utf-8")) if fixes_path.exists() else {}
    review_dir = args.data / "review"
    review_dir.mkdir(exist_ok=True)

    events = [json.loads(l) for l in (args.data / "events.jsonl").read_text(encoding="utf-8").splitlines() if l]
    out_records = []
    review = []
    stats = Counter()
    for ev in events:
        img = cv2.imread(str(args.data / ev["image"]))
        if page_mode:
            found = page_lines(det.detect(img))
        else:
            top = int(img.shape[0] * args.band)
            found = [(b, False) for b in subtitle_lines(det.detect(img[top:]), top, img.shape[1])]
        boxes = [b for b, _ in found]
        lines = []
        for i, (box, vertical) in enumerate(found):
            key = f"{ev['image']}#{i}"
            crop = pad_crop(img, box, pad=2 if page_mode else 4)
            cands = {r.name: r.recognize(crop, vertical).text for r in recs}
            if key in fixes:
                if fixes[key] is None:
                    stats["dropped"] += 1
                    continue
                lines.append({"text": fixes[key], "box": box, "vertical": vertical, "status": "human"})
                stats["human"] += 1
                continue
            # Vote on the body view (letters/digits): models disagree most on
            # punctuation (dash vs 一, ellipsis length), which the body score ignores.
            votes = Counter(normalize(t, "body") for t in cands.values() if normalize(t, "body"))
            best, n = votes.most_common(1)[0] if votes else ("", 0)
            if n >= args.agree and best:
                text = next(t for t in cands.values() if normalize(t, "body") == best)
                lines.append({"text": text, "box": box, "vertical": vertical, "status": "agreed"})
                stats["agreed"] += 1
            else:
                name = Path(ev["image"]).stem + f"_{i}.png"
                cv2.imwrite(str(review_dir / name), crop)
                review.append({"key": key, "crop": f"review/{name}", "vertical": vertical, "candidates": cands})
                stats["review"] += 1
        if not boxes:
            stats["no_line"] += 1
        out_records.append({**ev, "lines": lines})

    with (args.data / "labels.jsonl").open("w", encoding="utf-8") as f:
        for r in out_records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    with (args.data / "review.jsonl").open("w", encoding="utf-8") as f:
        for r in review:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(dict(stats))


if __name__ == "__main__":
    main()
