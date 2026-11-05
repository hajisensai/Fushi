"""Recognizer benchmark on labelled line crops.

Every recognizer reads the same crops (ground-truth boxes), so differences come
from the recognizer alone. Datasets are folders with labels.jsonl:
  {"image": "...", "lines": [{"text", "box": [x0,y0,x1,y1], "vertical": bool,
    "script"?: "sc"|"tc"|"en", "role"?: "zh"|"en"}], ...frame fields}
Lines with role "en" are skipped (Chinese benchmark).

Usage:
  python -I -X utf8 bench_rec.py --data DIR [--data DIR2] --models M --shipped S \
      [--rec kellenok_v0.2 --rec ppocrv5_server ...] [--group style] [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

import cv2

from metrics import Score, has_fold
from registry import RECOGNIZERS, load_recognizer, model_bytes


def crops(data: Path, pad: int):
    for line_no, rec in enumerate((data / "labels.jsonl").read_text(encoding="utf-8").splitlines()):
        if not rec:
            continue
        r = json.loads(rec)
        img = None
        for i, ln in enumerate(r["lines"]):
            if ln.get("role") == "en" or not ln.get("text"):
                continue
            if img is None:
                img = cv2.imread(str(data / r["image"]))
            h, w = img.shape[:2]
            x0, y0, x1, y1 = (int(v) for v in ln["box"])
            crop = img[max(0, y0 - pad): min(h, y1 + pad), max(0, x0 - pad): min(w, x1 + pad)]
            yield r, ln, crop


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", action="append", required=True, type=Path)
    ap.add_argument("--models", required=True, type=Path)
    ap.add_argument("--shipped", required=True, type=Path)
    ap.add_argument("--rec", action="append", help="recognizer names (default: all)")
    ap.add_argument("--group", action="append", default=[], help="frame/line field to break results down by")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--pad", type=int, default=4)
    ap.add_argument("--json", type=Path)
    ap.add_argument("--dump", type=Path, help="write per-line predictions (jsonl)")
    args = ap.parse_args()

    names = args.rec or list(RECOGNIZERS)
    samples = [s for d in args.data for s in crops(d, args.pad)]
    print(f"{len(samples)} lines from {', '.join(str(d.name) for d in args.data)}; folded scores: {has_fold()}")
    results = {}
    dump = args.dump.open("w", encoding="utf-8") if args.dump else None
    for name in names:
        rec = load_recognizer(name, args.models, args.shipped, args.threads)
        rec.recognize(samples[0][2], samples[0][1].get("vertical", False))  # warm-up
        body, body_fold, allc = Score("body"), Score("body", fold=True), Score("all")
        groups: dict[str, Score] = defaultdict(lambda: Score("body", fold=True))
        times = []
        for r, ln, crop in samples:
            out = rec.recognize(crop, ln.get("vertical", False))
            times.append(out.ms)
            for s in (body, body_fold, allc):
                s.add(out.text, ln["text"])
            for g in args.group:
                key = ln.get(g, r.get(g))
                if key is not None:
                    groups[f"{g}={key}"].add(out.text, ln["text"])
            if dump:
                dump.write(json.dumps({"rec": name, "image": r["image"], "ref": ln["text"], "pred": out.text},
                                      ensure_ascii=False) + "\n")
        results[name] = {
            "cer_body": body.cer, "cer_body_folded": body_fold.cer, "cer_all": allc.cer,
            "exact_folded": body_fold.exact_rate, "lines": body.items, "ref_chars": body.ref_chars,
            "ms_median": statistics.median(times), "ms_mean": statistics.fmean(times),
            "mb": model_bytes(name, args.models, args.shipped) / 1e6,
            "groups": {k: {"cer": v.cer, "lines": v.items} for k, v in sorted(groups.items())},
        }
    if dump:
        dump.close()

    print(f"\n| recognizer | CER body | CER body (t2s fold) | CER all chars | exact (fold) | ms/line median | MB |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for name, m in results.items():
        print(f"| {name} | {m['cer_body']:.2%} | {m['cer_body_folded']:.2%} | {m['cer_all']:.2%} | "
              f"{m['exact_folded']:.1%} | {m['ms_median']:.1f} | {m['mb']:.1f} |")
    if args.group:
        keys = sorted({k for m in results.values() for k in m["groups"]})
        print("\n| group (CER body, folded) | " + " | ".join(results) + " |")
        print("|---|" + "---:|" * len(results))
        for k in keys:
            cells = [f"{results[n]['groups'].get(k, {}).get('cer', float('nan')):.2%}" for n in results]
            lines = next(m["groups"][k]["lines"] for m in results.values() if k in m["groups"])
            print(f"| {k} ({lines}) | " + " | ".join(cells) + " |")
    if args.json:
        args.json.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
