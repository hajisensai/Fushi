"""Public manhua-style smoke set: Pepper&Carrot by David Revoy (CC BY 4.0),
Simplified Chinese translation (translators: Ran Zhuang, Yan Jing, Lou Simons).

Downloads the rendered Chinese pages and their translation SVGs; the SVG text of
a page is its page-level ground truth (`page_text`, no line boxes), so only
end-to-end character recall/precision are scored on this set
(score_pipeline.py). Text drawn into the artwork itself (signs, SFX) is not in
the SVG and shows up as lower precision.

Attribution when publishing results: "Pepper&Carrot" by David Revoy,
www.peppercarrot.com, CC BY 4.0.

Usage:
  python -I -X utf8 make_peppercarrot_set.py --out DIR [--episodes 20-39] [--max-pages 60]
"""

from __future__ import annotations

import argparse
import json
import re
import time
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = "https://www.peppercarrot.com/0_sources"
SVG_NS = "{http://www.w3.org/2000/svg}"
UA = {"User-Agent": "fushi-ocr-bench/1.0"}


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def svg_text(svg: bytes) -> str:
    """All text in the translation layer, in document order."""
    root = ET.fromstring(svg)
    parts: list[str] = []
    for el in root.iter():
        tag = el.tag.replace(SVG_NS, "")
        if tag in ("tspan", "flowPara", "text") and el.text and el.text.strip():
            t = el.text.strip()
            # Hidden editor notes in the SVGs are plain English ("Edit this one...").
            if re.fullmatch(r"[A-Za-z ,.'’-]+", t):
                continue
            parts.append(t)
    return "".join(parts)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--episodes", default="20-39")
    ap.add_argument("--max-pages", type=int, default=60)
    args = ap.parse_args()

    lo, hi = (int(x) for x in args.episodes.split("-"))
    episodes = json.loads(fetch(f"{ROOT}/episodes.json"))
    pages_dir = args.out / "pages"
    pages_dir.mkdir(parents=True, exist_ok=True)
    records = []
    for ep in episodes:
        m = re.match(r"ep(\d+)_", ep["name"])
        if not m or not lo <= int(m.group(1)) <= hi or "cn" not in ep["translated_languages"]:
            continue
        n = int(m.group(1))
        # The last page of every episode is the donor credits page (names drawn
        # into the artwork, not in the SVG), so it is left out.
        for page in range(1, ep["total_pages"]):
            if len(records) >= args.max_pages:
                break
            tag = f"E{n:02d}P{page:02d}"
            try:
                text = svg_text(fetch(f"{ROOT}/{ep['name']}/lang/cn/{tag}.svg"))
            except Exception as e:  # missing page translation: skip it, say so
                print(f"skip {tag}: {e}")
                continue
            # Skip wordless pages and the closing credits / donor pages (not dialogue).
            if len(text) < 4 or "peppercarrot.com" in text or "Creative Commons" in text or len(text) > 400:
                continue
            dest = pages_dir / f"{tag}.jpg"
            if not dest.exists():
                dest.write_bytes(fetch(f"{ROOT}/{ep['name']}/low-res/cn_Pepper-and-Carrot_by-David-Revoy_{tag}.jpg"))
                time.sleep(0.3)
            records.append({"image": f"pages/{tag}.jpg", "page_text": text, "lines": [],
                            "source": f"{ep['name']}/{tag}"})
    with (args.out / "labels.jsonl").open("w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    (args.out / "ATTRIBUTION.txt").write_text(
        "Pepper&Carrot by David Revoy, www.peppercarrot.com, CC BY 4.0.\n"
        "Simplified Chinese translation: Ran Zhuang, Yan Jing, Lou Simons.\n", encoding="utf-8")
    print(f"wrote {len(records)} pages")


if __name__ == "__main__":
    main()
