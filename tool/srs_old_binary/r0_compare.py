#!/usr/bin/env python3
"""R0：逐卡比对「迁移前旧库（协议 3 srs.db）」与「迁移后新代库（srs4.db 的派生缓存）」。

只读：两边都先拷进临时目录再以 mode=ro 打开（不碰原件、不留 -wal / -shm）。比的是用户看得见的东西：
卡片集合、每张卡的队列 / 到期日（due_day、due_at）/ 间隔 / reps / lapses / stability / difficulty / 最后复习时间，
以及每张卡的复习日志：条数，和按时间排好的逐条 (日志 ID, 时间, 评分, 用时) 序列（旧库 `srs_review_logs`，新库
派生的 `stats` 表；新库的 `log_ix` 不带评分）。新代库的 ID 列可能是 16 字节 BLOB，统一转成 UUID 文本再对。

新代把内置笔记类型派生出来的 ID（带 profile 盐的旧 ID）规范化成不带盐的 ID，旧 ID → 新 ID 记在 `alias_ix`；
比对前把旧库的卡片 / 笔记 / 牌组 ID 和新库日志里的卡片 ID 都经 `alias_ix` 换成规范 ID（`aliased` 记换了几个）。
换算之前先记旧库卡片行数（`old_cards_raw`）：两张旧卡换到同一个规范 ID 时不覆盖，记成 `collision` 差异（迁移把两张卡
合成了一张，是要报的结果，不是比对工具该吞掉的），两张卡的日志合在一起比。

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

LogRow = tuple[Any, Any, Any, Any]  # (日志 ID, 时间毫秒, 评分, 用时毫秒)

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
            rows: dict[Any, list[LogRow]] = {}
            for cid, lid, at, rating, dur in con.execute(
                    "SELECT card_id, id, occurred_at, rating, duration_ms FROM srs_review_logs"):
                rows.setdefault(_id(cid), []).append((_id(lid), at, rating, dur))
            meta = dict(con.execute("SELECT key, value FROM srs_meta WHERE key IN ('schema')"))
            return {"cards": cards, "logs": logs, "log_total": sum(logs.values()), "meta": meta,
                    "log_rows": rows}
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
            rows: dict[Any, list[LogRow]] = {}
            if "stats" in tables:
                for cid, lid, at, rating, dur in con.execute(
                        "SELECT card, log, at, rating, duration_ms FROM stats"):
                    rows.setdefault(_id(cid), []).append((_id(lid), at, rating, dur))
            meta = dict(con.execute("SELECT key, value FROM srs_meta WHERE key IN ('schema')")) \
                if "srs_meta" in tables else {}
            aliases: dict[Any, Any] = {}
            if "alias_ix" in tables:
                for aid, canon in con.execute("SELECT id, canon FROM alias_ix"):
                    aliases[_id(aid)] = _id(canon)
            return {"cards": cards, "logs": logs, "log_total": sum(logs.values()), "meta": meta,
                    "tables": sorted(tables), "aliases": aliases, "log_rows": rows}
        finally:
            con.close()


def canonicalize(old: dict[str, Any], new: dict[str, Any]) -> tuple[int, list[dict[str, Any]]]:
    """把旧库的卡片 / 笔记 / 牌组 ID 与新库日志的卡片 ID 经新库 `alias_ix` 换成规范 ID（原地改），返回换了几个与
    碰撞（几张旧卡换到同一个规范 ID：一个都不覆盖、日志合在一起，碰撞逐条交给调用方记成差异）。"""
    aliases: dict[Any, Any] = new.get("aliases", {})
    hits = 0

    def canon(v: Any) -> Any:
        nonlocal hits
        if v in aliases:
            hits += 1
            return aliases[v]
        return v

    def merged_counts(d: dict[Any, int]) -> dict[Any, int]:
        out: dict[Any, int] = {}
        for k, v in d.items():
            c = canon(k)
            out[c] = out.get(c, 0) + v
        return out

    def merged_rows(d: dict[Any, list[LogRow]]) -> dict[Any, list[LogRow]]:
        out: dict[Any, list[LogRow]] = {}
        for k, v in d.items():
            out.setdefault(canon(k), []).extend(v)
        for v in out.values():
            v.sort(key=lambda r: (r[1] if r[1] is not None else -1, str(r[0])))
        return out

    cards: dict[Any, Any] = {}
    sources: dict[Any, list[Any]] = {}
    for cid, row in old["cards"].items():
        row = dict(row)
        row["note_id"] = canon(row["note_id"])
        row["deck_id"] = canon(row["deck_id"])
        c = canon(cid)
        sources.setdefault(c, []).append(cid)
        if c not in cards:
            cards[c] = row
    collisions = [{"card": c, "collision": sorted(map(str, ids))} for c, ids in sources.items() if len(ids) > 1]
    old["cards"] = cards
    old["logs"] = merged_counts(old["logs"])
    new["logs"] = merged_counts(new["logs"])
    old["log_rows"] = merged_rows(old.get("log_rows", {}))
    new["log_rows"] = merged_rows(new.get("log_rows", {}))
    return hits, collisions


def compare(old: dict[str, Any], new: dict[str, Any]) -> dict[str, Any]:
    old_cards_raw = len(old["cards"])
    aliased, collisions = canonicalize(old, new)
    diffs: list[dict[str, Any]] = list(collisions)
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
        o_rows, n_rows = old["log_rows"].get(cid, []), new["log_rows"].get(cid, [])
        if o_rows != n_rows:
            diffs.append({"card": cid, "col": "log_rows", "old": o_rows, "new": n_rows})
    return {"old_cards_raw": old_cards_raw, "old_cards": len(old["cards"]),"new_cards": len(new["cards"]), "old_logs": old["log_total"],
            "new_logs": new["log_total"], "old_meta": old["meta"], "new_meta": new["meta"], "aliased": aliased,
            "diffs": diffs}


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
    out["log_rows_old"] = old["log_rows"]
    out["log_rows_new"] = new["log_rows"]
    text = json.dumps(out, ensure_ascii=False, indent=1, default=str)
    if a.json:
        Path(a.json).write_text(text, encoding="utf-8")
    print(json.dumps({k: out[k] for k in ("old_cards_raw", "old_cards", "new_cards", "old_logs", "new_logs", "old_meta",
                                          "new_meta", "aliased", "diffs")}, ensure_ascii=False, default=str))
    return 0 if not out["diffs"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
