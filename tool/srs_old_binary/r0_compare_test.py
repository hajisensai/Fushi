#!/usr/bin/env python3
"""r0_compare.py 比对逻辑的单测（不读任何库文件）：python -I tool/srs_old_binary/r0_compare_test.py"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import r0_compare as rc  # noqa: E402


def _card(**kw: Any) -> dict[str, Any]:
    row: dict[str, Any] = {c: 0 for c in rc.CARD_COLS}
    row.update(note_id="n", deck_id="d", queue="review")
    row.update(kw)
    return row


def _facts(cards: dict[str, Any], rows: dict[str, list[Any]], aliases: dict[str, str] | None = None) -> dict[str, Any]:
    logs = {k: len(v) for k, v in rows.items()}
    f: dict[str, Any] = {"cards": cards, "logs": logs, "log_total": sum(logs.values()), "meta": {},
                         "log_rows": rows}
    if aliases is not None:
        f["aliases"] = aliases
    return f


class CompareTest(unittest.TestCase):
    def test_identical_after_aliasing_has_no_diffs(self) -> None:
        old = _facts({"o1": _card(), "o2": _card()},
                     {"o1": [("l1", 10, 3, 4000)], "o2": [("l2", 20, 1, 4000)]})
        new = _facts({"c1": _card(), "c2": _card()},
                     {"c1": [("l1", 10, 3, 4000)], "c2": [("l2", 20, 1, 4000)]},
                     {"o1": "c1", "o2": "c2"})
        out = rc.compare(old, new)
        self.assertEqual(out["diffs"], [])
        self.assertEqual((out["old_cards_raw"], out["old_cards"], out["new_cards"]), (2, 2, 2))

    def test_two_old_cards_on_one_canonical_id_are_a_collision_not_swallowed(self) -> None:
        # 以前：换算后 dict 覆盖，old_cards 1 = new_cards 1、diffs 空。
        old = _facts({"o1": _card(), "o2": _card()},
                     {"o1": [("l1", 10, 3, 4000)], "o2": [("l2", 20, 1, 4000)]})
        new = _facts({"c1": _card()}, {"c1": [("l1", 10, 3, 4000), ("l2", 20, 1, 4000)]},
                     {"o1": "c1", "o2": "c1"})
        out = rc.compare(old, new)
        self.assertEqual(out["old_cards_raw"], 2)
        self.assertIn({"card": "c1", "collision": ["o1", "o2"]}, out["diffs"])

    def test_log_content_is_compared_not_only_the_count(self) -> None:
        old = _facts({"c1": _card()}, {"c1": [("l1", 10, 3, 4000), ("l2", 20, 3, 4000)]})
        new = _facts({"c1": _card()}, {"c1": [("l1", 10, 3, 4000), ("l2", 20, 1, 4000)]}, {})
        out = rc.compare(old, new)
        self.assertEqual([d["col"] for d in out["diffs"]], ["log_rows"])

    def test_log_rows_are_compared_in_time_order(self) -> None:
        old = _facts({"c1": _card()}, {"c1": [("l2", 20, 3, 0), ("l1", 10, 3, 0)]})
        new = _facts({"c1": _card()}, {"c1": [("l1", 10, 3, 0), ("l2", 20, 3, 0)]}, {})
        self.assertEqual(rc.compare(old, new)["diffs"], [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
