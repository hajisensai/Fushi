#!/usr/bin/env python3
"""R0：逐卡比对「迁移前旧库（协议 3 srs.db）」与「迁移后新代库（srs4.db 的派生缓存）」。

只读：两边都先拷进临时目录再以 mode=ro 打开（不碰原件、不留 -wal / -shm）。比的是用户看得见的东西：
卡片集合、每张卡的队列 / 到期日（due_day、due_at）/ 间隔 / reps / lapses / stability / difficulty / 最后复习时间，
以及每张卡的复习日志条数。新代库的 ID 列可能是 16 字节 BLOB，统一转成 UUID 文本再对。

  python -I tool/srs_old_binary/r0_compare.py --old <旧 app-support> --new <新 app-support> [--json out.json]
退出码：0 = 全部一致；1 = 有差异；2 = 读不了。
"""
from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Optional

CARD_COLS = ("queue", "due_day", "due_at", "scheduled_days", "reps", "lapses", "stability", "difficulty",
             "last_reviewed_at", "deck_id", "suspended", "note_id")


def _ro_copy(db: Path, td: Path) -> sqlite3.Connection:
    for suf in ("", "-wal", "-shm"):
        src = Path(str(db) + suf)
        if src.is_file():
            shutil.copy2(src, td / (db.name + suf))
    return sqlite3.connect(f"file:{td / db.name}?mode=ro", uri=True)


def _id(v: Any) -> Any:
    if isinstance(v, (bytes, bytearray)) and len(v) == 16:
        return str(uuid.UUID(bytes=bytes(v)))
    return v


def _norm(col: str, v: Any) -> Any:
    v = _id(v)
    if col in ("stability", "difficulty") and isinstance(v, float):
        return round(v, 9)
    if col == "queue" and v == "newCard":
        return "new"
    return v


def old_facts(support: Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory() as t:
        con = _ro_copy(support / "srs.db", Path(t))
        try:
            cols = ", ".join(CARD_COLS)
            cards = {_id(r[0]): {c: _norm(c, v) for c, v in zip(CARD_COLS, r[1:])}
                     for r in con.execute(f"SELECT id, {cols} FROM srs_cards_cache")}
            logs: dict[str, int] = {}
            for cid, n in con.execute("SELECT card_id, COUNT(*) FROM srs_review_logs GROUP BY card_id"):
                logs[_id(cid)] = n
            meta = dict(con.execute("SELECT key, value FROM srs_meta WHERE key IN ('schema')"))
            return {"cards": cards, "logs": logs, "log_total": sum(logs.values()), "meta": meta}
        finally:
            con.close()


def new_facts(support: Path) -> dict[str, Any]:
    db = support / "srs4.db"
    with tempfile.TemporaryDirectory() as t:
        con = _ro_copy(db, Path(t))
        try:
            tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            cols = ", ".join(CARD_COLS)
            cards = {_id(r[0]): {c: _norm(c, v) for c, v in zip(CARD_COLS, r[1:])}
                     for r in con.execute(f"SELECT id, {cols} FROM cards")} if "cards" in tables else {}
            logs: dict[str, int] = {}
            if "log_ix" in tables:
                for cid, n in con.execute("SELECT card, COUNT(*) FROM log_ix GROUP BY col, card"):
                    logs[_id(cid)] = logs.get(_id(cid), 0) + n
            meta = dict(con.execute("SELECT key, value FROM srs_meta WHERE key IN ('schema')")) \
                if "srs_meta" in tables else {}
            return {"cards": cards, "logs": logs, "log_total": sum(logs.values()), "meta": meta,
                    "tables": sorted(tables)}
        finally:
            con.close()


def compare(old: dict[str, Any], new: dict[str, Any]) -> dict[str, Any]:
    diffs: list[dict[str, Any]] = []
    for cid in sorted(set(old["cards"]) | set(new["cards"]), key=str):
        o, n = old["cards"].get(cid), new["cards"].get(cid)
        if o is None or n is None:
            diffs.append({"card": cid, "missing_in": "old" if o is None else "new"})
            continue
        for c in CARD_COLS:
            if o[c] != n[c]:
                diffs.append({"card": cid, "col": c, "old": o[c], "new": n[c]})
        if old["logs"].get(cid, 0) != new["logs"].get(cid, 0):
            diffs.append({"card": cid, "col": "log_count", "old": old["logs"].get(cid, 0),
                          "new": new["logs"].get(cid, 0)})
    return {"old_cards": len(old["cards"]), "new_cards": len(new["cards"]), "old_logs": old["log_total"],
            "new_logs": new["log_total"], "old_meta": old["meta"], "new_meta": new["meta"], "diffs": diffs}


def main(argv: Optional[list[str]] = None) -> int:
    for s in (sys.stdout, sys.stderr):
        s.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True)
    ap.add_argument("--new", required=True)
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    try:
        old = old_facts(Path(a.old))
        new = new_facts(Path(a.new))
    except sqlite3.Error as e:
        print(f"读不了：{e}")
        return 2
    out = compare(old, new)
    out["per_card_old"] = old["cards"]
    out["per_card_new"] = new["cards"]
    out["logs_old"] = old["logs"]
    out["logs_new"] = new["logs"]
    text = json.dumps(out, ensure_ascii=False, indent=1, default=str)
    if a.json:
        Path(a.json).write_text(text, encoding="utf-8")
    print(json.dumps({k: out[k] for k in ("old_cards", "new_cards", "old_logs", "new_logs", "old_meta",
                                          "new_meta", "diffs")}, ensure_ascii=False, default=str))
    return 0 if not out["diffs"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
