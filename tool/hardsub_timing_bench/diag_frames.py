"""带符号误差（以帧为单位）分布 + 未检出的样本。"""

from __future__ import annotations

import collections
import json
import sys
from pathlib import Path

rows: list[dict] = json.loads((Path(__file__).resolve().parent / "results" / f"{sys.argv[1]}_rows.json").read_text("utf-8"))
F: float = 1001 / 24000
found = [r for r in rows if r["det_start"] is not None]
for side, k in (("start", 0), ("end", 1)):
    c = collections.Counter(max(-6, min(6, round((r[f"det_{side}"] - r["state"][k]) / F))) for r in found)
    print(side, "frames:", dict(sorted(c.items())))
miss = [r for r in rows if r["det_start"] is None]
print("missed", len(miss), "by sample", dict(collections.Counter(r["sample"] for r in miss)))
print("missed state len (s):", sorted(round(r["state"][1] - r["state"][0], 2) for r in miss)[:40])
for r in miss[:12]:
    print(r["sample"], r["band"], f"t={r['t']:.2f}", f"state={r['state'][0]:.2f}-{r['state'][1]:.2f}", r["det_fill_pixels"], r["text"].replace("\n", "/")[:25])
