"""Scoring helpers: CER, character-bag recall/precision, script folding.

Two text views, same as docs/reviews/2026-10-15-manga-ocr-model-bench.md:
- "body": NFKC, keep only letters/digits (CJK ideographs count as letters) and ー.
- "all": NFKC with whitespace removed.
`fold=True` additionally maps Traditional to Simplified (OpenCC t2s) on both
sides, so a model that reads 這 as 这 is not counted wrong. Scoring only: the
app never converts scripts.
"""

from __future__ import annotations

import unicodedata
from collections import Counter
from functools import lru_cache

try:
    import opencc

    _T2S = opencc.OpenCC("t2s")
except Exception:  # OpenCC is optional; folded scores are skipped without it.
    _T2S = None


def has_fold() -> bool:
    return _T2S is not None


@lru_cache(maxsize=65536)
def normalize(text: str, view: str = "body", fold: bool = False) -> str:
    t = unicodedata.normalize("NFKC", text)
    t = "".join(ch for ch in t if not ch.isspace())
    if view == "body":
        t = "".join(ch for ch in t if ch.isalnum() or ch == "ー")
    if fold and _T2S is not None:
        t = _T2S.convert(t)
    return t


def edit_distance(a: str, b: str) -> int:
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


class Score:
    """Accumulates CER and exact-match over (prediction, reference) pairs."""

    def __init__(self, view: str = "body", fold: bool = False):
        self.view = view
        self.fold = fold
        self.edits = 0
        self.ref_chars = 0
        self.items = 0
        self.exact = 0

    def add(self, pred: str, ref: str) -> None:
        p = normalize(pred, self.view, self.fold)
        r = normalize(ref, self.view, self.fold)
        self.edits += edit_distance(p, r)
        self.ref_chars += len(r)
        self.items += 1
        self.exact += int(p == r)

    @property
    def cer(self) -> float:
        return self.edits / max(1, self.ref_chars)

    @property
    def exact_rate(self) -> float:
        return self.exact / max(1, self.items)


class BagScore:
    """Whole-page character-bag recall/precision (ignores boxes and order)."""

    def __init__(self, fold: bool = False):
        self.fold = fold
        self.hit = 0
        self.ref = 0
        self.pred = 0

    def add(self, pred: str, ref: str) -> None:
        p = Counter(normalize(pred, "body", self.fold))
        r = Counter(normalize(ref, "body", self.fold))
        self.hit += sum((p & r).values())
        self.ref += sum(r.values())
        self.pred += sum(p.values())

    @property
    def recall(self) -> float:
        return self.hit / max(1, self.ref)

    @property
    def precision(self) -> float:
        return self.hit / max(1, self.pred)
