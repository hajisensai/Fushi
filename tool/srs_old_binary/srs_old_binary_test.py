#!/usr/bin/env python3
"""srs_old_binary.py 纯逻辑部分的单测（不启动任何二进制）：python -I tool/srs_old_binary/srs_old_binary_test.py"""
from __future__ import annotations

import json
import re
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import srs_old_binary as h  # noqa: E402


def _rep(target_unchanged: bool = True, local_unchanged: bool = True, ctl=None, prompts=None):
    return {
        "target": {"unchanged": target_unchanged},
        "local_db": {"files_unchanged": local_unchanged, "logical_unchanged": local_unchanged},
        "ctl": ctl or [],
        "prompt_lines": prompts or [],
    }


class ManifestTest(unittest.TestCase):
    def test_manifest_is_pinned(self) -> None:
        versions = h.load_manifest()
        ids = [v["id"] for v in versions]
        self.assertEqual(len(ids), len(set(ids)))
        for v in versions:
            self.assertRegex(v["installer_sha256"], r"^[0-9a-f]{64}$", v["id"])
            self.assertIn(v["source"]["kind"], ("release", "actions-artifact"))
            self.assertTrue(v["source"]["asset"].endswith("-windows-setup.exe"))
        defaults = {v["id"] for v in versions if v.get("default")}
        # 默认口径：协议 2 之前的正式版、只认协议 2 的最后一个包、最新正式版、最新 debug-rolling。
        self.assertEqual(len(defaults), 4)
        self.assertEqual({v["srs_protocol"] for v in versions if v.get("default")},
                         {"pre-sync2", "2", "3"})

    def test_sources_do_not_expire(self) -> None:
        # actions artifact 会过期、fushi-debug-rolling 会轮换：只允许正式 release 与存档 prerelease 两种不过期的来源。
        for v in h.load_manifest():
            src = v["source"]
            self.assertEqual(src["kind"], "release", v["id"])
            self.assertNotEqual(src["tag"], "fushi-debug-rolling", v["id"])
            if v["id"].startswith("debug-"):
                self.assertEqual(src["tag"], h.ARCHIVE_TAG, v["id"])
                self.assertIn("origin", src, v["id"])
            else:
                self.assertEqual(src["tag"], v["id"], v["id"])

    def test_unsafe_manifest_values_are_refused(self) -> None:
        good = h.load_manifest()[0]
        for patch in ({"asset": "../evil.exe"}, {"asset": "-oProxyCommand"}, {"tag": "a b"}):
            v = {**good, "source": {**good["source"], **patch}}
            with self.assertRaises(SystemExit):
                h._check_version(v)
        with self.assertRaises(SystemExit):
            h._check_version({**good, "installer_sha256": "zz"})

    def test_select_versions(self) -> None:
        self.assertEqual(len(h.select_versions(None)), 4)
        self.assertEqual(len(h.select_versions("all")), len(h.load_manifest()))
        self.assertEqual([v["id"] for v in h.select_versions("v3.3.0")], ["v3.3.0"])
        with self.assertRaises(SystemExit):
            h.select_versions("v0.0.0")


class SnapshotTest(unittest.TestCase):
    def test_snapshot_and_diff(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a").write_bytes(b"1")
            (root / "d").mkdir()
            (root / "d" / "b").write_bytes(b"2")
            before = h.snapshot(root)
            self.assertEqual(set(before), {"a", "d/b"})
            self.assertTrue(h.diff_snapshots(before, h.snapshot(root))["unchanged"])
            (root / "a").write_bytes(b"x")
            (root / "c").write_bytes(b"3")
            (root / "d" / "b").unlink()
            d = h.diff_snapshots(before, h.snapshot(root))
            self.assertEqual((d["changed"], d["added"], d["removed"]), (["a"], ["c"], ["d/b"]))
            self.assertFalse(d["unchanged"])
            self.assertEqual(h.snapshot(root / "missing"), {})

    def test_logical_digest_tracks_rows_not_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "srs.db"
            con = sqlite3.connect(str(db))
            con.execute("CREATE TABLE srs_meta(key TEXT PRIMARY KEY, value TEXT)")
            con.execute("INSERT INTO srs_meta VALUES ('schema', '29')")
            con.commit()
            con.close()
            first = h.sqlite_logical_digest(db)
            self.assertEqual(h.srs_meta(db), {"schema": "29"})
            con = sqlite3.connect(str(db))
            con.execute("UPDATE srs_meta SET value='40099' WHERE key='schema'")
            con.commit()
            con.close()
            self.assertNotEqual(first, h.sqlite_logical_digest(db))
            self.assertIsNone(h.sqlite_logical_digest(Path(tmp) / "none.db"))

    def test_profile_uids_in_location(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            loc = Path(tmp)
            self.assertEqual(h.profile_uids_in_location(loc), [])
            (loc / "fushi-srs" / "u1" / "v3").mkdir(parents=True)
            self.assertEqual(h.profile_uids_in_location(loc), ["u1"])


class LocalChangesTest(unittest.TestCase):
    def test_control_noise_is_subtracted(self) -> None:
        before = {"tables": {"a": "1:x", "b": "1:y", "srs_meta": "2:m"}, "srs_meta": {"schema": "26", "t": "1"}}
        after = {"tables": {"a": "1:x", "b": "2:z", "srs_meta": "2:n"}, "srs_meta": {"schema": "26", "t": "2"}}
        noisy = h.local_changes(before, after, {"tables": {"b", "srs_meta"}, "srs_meta": {"t"}})
        self.assertEqual((noisy["unexplained_tables"], noisy["unexplained_srs_meta_keys"]), ([], []))
        quiet = h.local_changes(before, after, {"tables": set(), "srs_meta": set()})
        self.assertEqual((quiet["unexplained_tables"], quiet["unexplained_srs_meta_keys"]), (["b"], ["t"]))
        self.assertFalse(h.local_changes(before, after, None)["control_run"])


class JudgeTest(unittest.TestCase):
    V = {"has_srs_db": True, "has_folder_location": True}

    def test_open_db(self) -> None:
        ok = [{"path": "/api/admin/srs/decks", "status": 200}]
        bad = [{"path": "/api/admin/srs/decks", "status": 503}]
        self.assertEqual(h.judge("open-db", self.V, _rep(ctl=ok)), "accepted")
        self.assertEqual(h.judge("open-db", self.V, _rep(ctl=bad)), "rejected")
        self.assertEqual(h.judge("open-db", self.V, _rep(False, ctl=bad)), "rejected-but-wrote")
        side = {"unchanged": False, "added": ["srs.db-shm", "srs.db-wal"], "removed": [], "changed": []}
        self.assertEqual(h.judge("open-db", self.V, {**_rep(ctl=bad), "target": side}), "rejected-sidecars-only")
        side["changed"] = ["srs.db"]
        self.assertEqual(h.judge("open-db", self.V, {**_rep(ctl=bad), "target": side}), "rejected-but-wrote")
        self.assertEqual(h.judge("open-db", {"has_srs_db": False}, _rep(ctl=ok)), "n/a-untouched")

    def test_sync_location(self) -> None:
        p = ["srs sync data needs a newer app"]
        self.assertEqual(h.judge("sync-location", self.V, _rep(prompts=p)), "rejected")
        self.assertEqual(h.judge("sync-location", self.V, _rep(False, prompts=p)), "rejected-but-wrote")
        self.assertEqual(h.judge("sync-location", self.V, _rep(True, False, prompts=p)), "rejected-but-wrote")
        self.assertEqual(h.judge("sync-location", self.V, _rep(False)), "accepted")
        self.assertEqual(h.judge("sync-location", self.V, _rep()), "untouched-prompt-unverified")
        self.assertEqual(h.judge("sync-location", self.V, _rep(True, False)), "untouched-but-local-changed")

    def test_restore(self) -> None:
        rej = [{"path": "/api/admin/backups/restore", "status": 422}]
        acc = [{"path": "/api/admin/backups/restore", "status": 200}]
        self.assertEqual(h.judge("restore-backup", self.V, _rep(ctl=rej)), "rejected")
        self.assertEqual(h.judge("restore-backup", self.V, _rep(True, False, ctl=rej)), "rejected-but-wrote")
        self.assertEqual(h.judge("restore-backup", self.V, _rep(ctl=acc)), "accepted")

    def test_import_export_needs_manual(self) -> None:
        self.assertEqual(h.judge("import-export", self.V, {**_rep(), "manual": False}), "not-automatable")

    def test_prompt_lines(self) -> None:
        lines = h.prompt_lines([json.dumps({"error": "备份来自更新版本的 Fushi"}, ensure_ascii=False), "plain\nneeds a newer app\nx"])
        self.assertEqual(len(lines), 2)
        self.assertTrue(all(re.search(h.PROMPT_RE, s) for s in lines))


if __name__ == "__main__":
    unittest.main(verbosity=1)
