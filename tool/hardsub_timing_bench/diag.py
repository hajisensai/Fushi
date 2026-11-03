"""误差分型：太早切（检测区间偏短）还是漏切（偏长），以及最差的几条。"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

rows: list[dict] = json.loads((Path(__file__).resolve().parent / "results" / f"{sys.argv[1]}_rows.json").read_text("utf-8"))
F: float = 1001 / 24000
for side, k in (("start", 0), ("end", 1)):
    e = np.array([r[f"det_{side}"] - r["state"][k] for r in rows if r["det_start"] is not None])
    bins = [-99, -2, -0.5, -0.25, -2.01 * F, 2.01 * F, 0.25, 0.5, 2, 99]
    h, _ = np.histogram(e, bins)
    print(side, dict(zip(["<-2", "-2..-.5", "-.5..-.25", "-.25..-2f", "±2f", "2f..+.25", ".25..+.5", ".5..2", ">2"], h.tolist())))
bad = sorted(
    (r for r in rows if r["det_start"] is not None),
    key=lambda r: -max(abs(r["det_start"] - r["state"][0]), abs(r["det_end"] - r["state"][1])),
)
for r in bad[: int(sys.argv[2]) if len(sys.argv) > 2 else 15]:
    print(
        r["sample"], r["band"], f"t={r['t']:.2f}", f"state={r['state'][0]:.2f}-{r['state'][1]:.2f}",
        f"det={r['det_start']:.2f}-{r['det_end']:.2f}", r["det_fill_pixels"], r["text"].replace("\n", "/")[:30],
    )
