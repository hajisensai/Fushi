"""Offline contracts for repacking the recommended pack into its deflate variant.

Run with Python's standard library only:
    python -m unittest discover -s fushi/tool/pack -p test_repack_recommended_pack_deflate.py
"""

import contextlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import zipfile


MODULE_PATH = Path(__file__).with_name("repack_recommended_pack_deflate.py")
SPEC = importlib.util.spec_from_file_location("repack_recommended_pack_deflate", MODULE_PATH)
REPACK = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = REPACK
SPEC.loader.exec_module(REPACK)

AUDIO = "localAudio/local_audio_1.db"
TEXT_RESOURCE = "dictionaryResources/日本語辞典/blobs.bin"
RANDOM_RESOURCE = "dictionaryResources/日本語辞典/media.bin"


def _make_audio_db(path: Path) -> list:
    """Shaped like the shipped Yomitan databases, duplicate indexes included."""
    with contextlib.closing(sqlite3.connect(path)) as db, db:
        db.executescript(
            """
            CREATE TABLE entries (id integer PRIMARY KEY NOT NULL, expression text NOT NULL,
                reading text, source text NOT NULL, speaker text, display text, file text NOT NULL);
            CREATE TABLE android (id integer PRIMARY KEY NOT NULL, file text NOT NULL,
                source text NOT NULL, data blob NOT NULL);
            CREATE INDEX idx_reading ON entries(reading);
            CREATE INDEX idx_expr_reading ON entries(expression, reading);
            CREATE INDEX idx_entries_expr_read ON entries(expression, reading);
            CREATE INDEX idx_all ON entries(expression, reading, source);
            CREATE UNIQUE INDEX idx_android_unique ON android(file, source);
            CREATE INDEX idx_android ON android(file, source);
            """
        )
        rows = []
        for i in range(300):
            data = os.urandom(64) + bytes(2000)
            db.execute("INSERT INTO entries (expression, reading, source, file) VALUES (?, ?, 'nhk16', ?)",
                       (f"語{i}", f"ご{i}", f"audio/{i}.mp3"))
            db.execute("INSERT INTO android (file, source, data) VALUES (?, 'nhk16', ?)", (f"audio/{i}.mp3", data))
            rows.append((f"audio/{i}.mp3", data))
    return rows


def _indexes(path: Path) -> set:
    with contextlib.closing(sqlite3.connect(path)) as db, db:
        return {row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")}


class RepackRecommendedPackDeflateTest(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.root = Path(self._temp.name)
        self.store = self.root / "store" / "fushi-recommended.fushi.zip"
        self.store.parent.mkdir()
        audio = self.root / "local_audio_1.db"
        self.audio_rows = _make_audio_db(audio)
        self.text = ("見出し語 " * 200000).encode("utf-8")
        self.random = os.urandom(3 * 1024 * 1024)
        with zipfile.ZipFile(self.store, "w", zipfile.ZIP_STORED, allowZip64=True) as pack:
            pack.writestr("backup_meta.json", json.dumps({"schemaVersion": 112}),
                          compress_type=zipfile.ZIP_DEFLATED)
            pack.writestr("fushi.db", b"SQLite format 3\x00" + bytes(4080))
            pack.write(audio, AUDIO)
            pack.writestr(TEXT_RESOURCE, self.text)
            pack.writestr(RANDOM_RESOURCE, self.random)

    def tearDown(self):
        self._temp.cleanup()

    def _repack(self) -> tuple:
        output = self.root / "deflate" / "fushi-recommended.deflate.fushi.zip"
        return REPACK.repack(self.store, output), output

    def test_entries_keep_order_and_bytes(self):
        _, output = self._repack()
        with zipfile.ZipFile(self.store) as old, zipfile.ZipFile(output) as new:
            self.assertEqual([i.filename for i in new.infolist()], [i.filename for i in old.infolist()])
            self.assertIsNone(new.testzip())
            for name in ("backup_meta.json", "fushi.db", TEXT_RESOURCE, RANDOM_RESOURCE):
                self.assertEqual(new.read(name), old.read(name), name)

    def test_compressible_entries_deflate_and_incompressible_stay_stored(self):
        report, output = self._repack()
        with zipfile.ZipFile(output) as new:
            self.assertEqual(new.getinfo(TEXT_RESOURCE).compress_type, zipfile.ZIP_DEFLATED)
            self.assertEqual(new.getinfo(RANDOM_RESOURCE).compress_type, zipfile.ZIP_STORED)
            self.assertEqual(new.getinfo(AUDIO).compress_type, zipfile.ZIP_DEFLATED)
        self.assertLess(report["outputBytes"], report["inputBytes"])

    def test_local_audio_keeps_rows_and_only_canonical_indexes(self):
        report, output = self._repack()
        extracted = self.root / "out.db"
        with zipfile.ZipFile(output) as new:
            extracted.write_bytes(new.read(AUDIO))
        self.assertEqual(_indexes(extracted), set(REPACK.CANONICAL_INDEXES))
        with contextlib.closing(sqlite3.connect(extracted)) as db, db:
            rows = db.execute("SELECT file, data FROM android ORDER BY id").fetchall()
            self.assertEqual(rows, self.audio_rows)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM entries").fetchone()[0], 300)
            plan = db.execute(
                "EXPLAIN QUERY PLAN SELECT file, source FROM entries WHERE expression = ? AND reading = ?",
                ("語1", "ご1"),
            ).fetchall()
            self.assertIn("idx_entries_expr_read", " ".join(str(r) for r in plan))
        self.assertEqual(
            report["localAudio"][AUDIO]["droppedIndexes"],
            ["idx_all", "idx_android", "idx_android_unique", "idx_expr_reading", "idx_reading"],
        )

    def test_missing_canonical_indexes_are_created(self):
        audio = self.root / "bare.db"
        with contextlib.closing(sqlite3.connect(audio)) as db, db:
            db.executescript(
                "CREATE TABLE entries (expression text, reading text, source text, file text);"
                "CREATE TABLE android (file text, source text, data blob);"
            )
        REPACK.slim_local_audio_db(audio)
        self.assertEqual(_indexes(audio), set(REPACK.CANONICAL_INDEXES))

    def test_same_file_name_as_store_pack_is_refused(self):
        # 切片名是「包名.NNN」，两个包的切片在同一个 release 里，同名会互相覆盖。
        with self.assertRaises(ValueError):
            REPACK.repack(self.store, self.root / "other" / self.store.name)

    def test_existing_output_is_never_overwritten(self):
        output = self.root / "deflate.fushi.zip"
        output.write_bytes(b"keep")
        with self.assertRaises(FileExistsError):
            REPACK.repack(self.store, output)
        self.assertEqual(output.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
