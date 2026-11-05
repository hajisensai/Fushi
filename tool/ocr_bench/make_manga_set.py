"""Sample comic pages (folders of images or .cbz) into a benchmark set.

Pages are taken at even spacing, skipping the first few of each volume
(covers/colour inserts). Output (in --out): pages/<book>_<n>.png and
events.jsonl ({"image", "source", "book"}); label_consensus.py --mode page adds
the line labels. Pages stay outside git (copyrighted).

Usage:
  python -I -X utf8 make_manga_set.py --book NAME=PATH [--book ...] --out DIR [--pages-per-book 12]
"""

from __future__ import annotations

import argparse
import json
import zipfile
from pathlib import Path

import cv2
import numpy as np

IMAGE_EXT = (".jpg", ".jpeg", ".png", ".webp")


def volume_pages(path: Path) -> list[tuple[str, callable]]:
    """Return (label, loader) per page across all volumes under path."""
    pages = []
    vols = sorted(p for p in path.rglob("*") if p.suffix.lower() == ".cbz" and "waifu2x" not in p.parts)
    dirs = sorted({p.parent for p in path.rglob("*") if p.suffix.lower() in IMAGE_EXT and ".yacreader" not in str(p)})
    for cbz in vols:
        z = zipfile.ZipFile(cbz)
        names = sorted(n for n in z.namelist() if n.lower().endswith(IMAGE_EXT))[4:]
        pages += [(f"{cbz.stem}/{n}", (lambda z=z, n=n: z.read(n))) for n in names]
    if not vols:
        for d in dirs:
            files = sorted(f for f in d.iterdir() if f.suffix.lower() in IMAGE_EXT)[4:]
            pages += [(f"{d.name}/{f.name}", (lambda f=f: f.read_bytes())) for f in files]
    return pages


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--book", action="append", required=True, help="NAME=PATH")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--pages-per-book", type=int, default=12)
    args = ap.parse_args()

    pages_dir = args.out / "pages"
    pages_dir.mkdir(parents=True, exist_ok=True)
    with (args.out / "events.jsonl").open("w", encoding="utf-8") as out:
        for spec in args.book:
            name, path = spec.split("=", 1)
            pages = volume_pages(Path(path))
            step = max(1, len(pages) // args.pages_per_book)
            picked = pages[step // 2:: step][: args.pages_per_book]
            for n, (label, load) in enumerate(picked):
                img = cv2.imdecode(np.frombuffer(load(), np.uint8), cv2.IMREAD_COLOR)
                dest = f"pages/{name}_{n:02d}.png"
                cv2.imwrite(str(args.out / dest), img)
                out.write(json.dumps({"image": dest, "source": label, "book": name}, ensure_ascii=False) + "\n")
            print(f"{name}: {len(pages)} pages, sampled {len(picked)}")


if __name__ == "__main__":
    main()
