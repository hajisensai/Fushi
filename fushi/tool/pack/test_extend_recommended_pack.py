"""Offline regression contracts for extending an existing recommended pack.

Run with Python's standard library only:
    python -m unittest discover -s fushi/tool/pack -p test_extend_recommended_pack.py
"""

import hashlib
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


MODULE_PATH = Path(__file__).with_name("extend_recommended_pack.py")
SPEC = importlib.util.spec_from_file_location("extend_recommended_pack", MODULE_PATH)
PACK = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PACK
SPEC.loader.exec_module(PACK)

TITLE = "日本語シソーラス 類語検索辞典"
OLD_TITLE = "既存辞典"
SECRET = "PRIVATE_SENTINEL_80bbf82672ac4e66"
OLD_COLUMNS = (
    "name", "format_key", "order", "type", "metadata_json",
    "hidden_languages_json", "collapsed_languages_json",
)
OLD_ROW = (OLD_TITLE, "yomichan", 12, "term", '{"kept":true}', '["en"]', '["ja"]')
NEW_ROW = (TITLE, "yomichan", 13, "term", '{"revision":"new"}', "[]", "[]")
PREFERENCES = [
    ("audio_source_configs", '[{"name":"本地音声"}]', 42),
    ("local_audio_dbs", '["local_audio_test.db"]', 43),
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()


def schema(connection):
    return connection.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
    ).fetchall()


@contextmanager
def database(path):
    connection = sqlite3.connect(path)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def create_database(path, version=86, modern=False):
    with database(path) as db:
        db.execute(f"PRAGMA user_version = {version}")
        db.executescript('''
            CREATE TABLE dictionary_metadata (
                name TEXT NOT NULL PRIMARY KEY,
                format_key TEXT NOT NULL,
                "order" INTEGER NOT NULL,
                type TEXT NOT NULL DEFAULT 'term',
                metadata_json TEXT NOT NULL DEFAULT '{}',
                hidden_languages_json TEXT NOT NULL DEFAULT '[]',
                collapsed_languages_json TEXT NOT NULL DEFAULT '[]'
            );
            CREATE INDEX dictionary_order ON dictionary_metadata("order");
            CREATE TABLE preferences (
                key TEXT NOT NULL PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE reading_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL
            );
            CREATE TABLE extra_private_data (value TEXT NOT NULL);
            CREATE VIEW history_view AS SELECT content FROM reading_history;
        ''')
        if modern:
            db.execute("ALTER TABLE dictionary_metadata ADD COLUMN expanded_languages_json TEXT DEFAULT '[]'")
            db.execute("ALTER TABLE dictionary_metadata ADD COLUMN display_name TEXT")
            db.execute("CREATE TABLE schema117_only(value TEXT)")
            db.execute("INSERT INTO schema117_only VALUES (?)", (SECRET,))
        marks = ",".join("?" for _ in OLD_COLUMNS)
        columns = ",".join('"' + col + '"' for col in OLD_COLUMNS)
        db.execute(f"INSERT INTO dictionary_metadata ({columns}) VALUES ({marks})", NEW_ROW if modern else OLD_ROW)
        if modern:
            db.execute(f"INSERT INTO dictionary_metadata ({columns}) VALUES ({marks})",
                       ("Unrelated private dictionary", "yomichan", 99, "term", json.dumps({"private": SECRET}), "[]", "[]"))
        db.executemany("INSERT INTO preferences VALUES (?, ?, ?)", PREFERENCES)
        db.executemany("INSERT INTO preferences VALUES (?, ?, ?)", [
            ("access_token", SECRET, 99),
            ("audio_source_configs_backup", SECRET, 100),
            ("local_audio_dbs_private", SECRET, 101),
        ])
        db.execute("INSERT INTO reading_history(content) VALUES (?)", (SECRET * 1000,))
        db.execute("INSERT INTO extra_private_data VALUES (?)", (SECRET,))


class ExtendRecommendedPackTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old_db = self.root / "old.db"
        self.source = self.root / "metadata.db"
        create_database(self.old_db)
        create_database(self.source, 117, modern=True)
        self.dictionary = self.root / "dictionary"
        self.dictionary.mkdir()
        (self.dictionary / "index.json").write_text(json.dumps({"title": TITLE, "format": 3}), encoding="utf-8")
        (self.dictionary / "term_bank_1.json").write_text('[["語","ご","","",0,["ことば"],0,""]]', encoding="utf-8")
        (self.dictionary / "nested").mkdir()
        (self.dictionary / "nested" / "image.bin").write_bytes(b"new-resource\x00\xff")
        self.baseline = self.root / "baseline.zip"
        self.output = self.root / "result.zip"
        self.meta = {
            "version": 1, "schemaVersion": 86, "appVersion": "1.0.0",
            "bookCount": 0, "statsCount": 0, "dictionaryCount": 1,
            "excludedCategories": ["books", "statistics"],
            "localAudioRoot": "C:\\old-support", "customField": {"keep": True},
        }
        self.resources = {
            f"dictionaryResources/{OLD_TITLE}/index.json": b'{"title":"old"}',
            f"dictionaryResources/{OLD_TITLE}/term_bank_1.json": b"old terms\x00\xff",
            "localAudio/local_audio_test.db": b"local audio unchanged\x00\xff",
        }
        self.write_baseline()

    def write_baseline(self, extra=(), meta=None):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.baseline, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.write(self.old_db, "fushi.db")
                archive.writestr("backup_meta.json", json.dumps(self.meta if meta is None else meta))
                for name, data in list(self.resources.items()) + list(extra):
                    archive.writestr(name, data)

    def build(self, **overrides):
        args = dict(baseline=self.baseline, metadata_db=self.source, dictionary_dir=self.dictionary, output=self.output)
        args.update(overrides)
        return PACK.build_pack(**args)

    def output_database(self):
        path = self.root / "result.db"
        with zipfile.ZipFile(self.output) as archive:
            path.write_bytes(archive.read("fushi.db"))
        return path

    def assert_rejected(self, error=ValueError, **kwargs):
        baseline_hash, source_hash = digest(self.baseline), digest(self.source)
        before = {item.name for item in self.root.iterdir()}
        with self.assertRaises(error):
            self.build(**kwargs)
        self.assertFalse(self.output.exists(), "failure must not leave a partial publishable pack")
        self.assertEqual(before, {item.name for item in self.root.iterdir()}, "failure left temporary artifacts")
        self.assertEqual(baseline_hash, digest(self.baseline))
        self.assertEqual(source_hash, digest(self.source))

    def test_schema86_is_preserved_with_schema117_metadata_source(self):
        before = (digest(self.baseline), digest(self.source))
        report = self.build()
        self.assertIsInstance(report, dict)
        with database(self.old_db) as old, database(self.output_database()) as result:
            self.assertEqual(86, result.execute("PRAGMA user_version").fetchone()[0])
            self.assertEqual(schema(old), schema(result), "must preserve every old table/index/view definition")
            self.assertEqual([OLD_ROW, NEW_ROW], result.execute('SELECT * FROM dictionary_metadata ORDER BY "order"').fetchall())
            self.assertNotIn("schema117_only", {row[1] for row in schema(result)})
        with zipfile.ZipFile(self.output) as archive:
            meta = json.loads(archive.read("backup_meta.json"))
        self.assertEqual(86, meta["schemaVersion"])
        self.assertEqual(self.meta["appVersion"], meta["appVersion"])
        self.assertEqual(self.meta["localAudioRoot"], meta["localAudioRoot"])
        self.assertEqual(self.meta["customField"], meta["customField"])
        self.assertEqual(before, (digest(self.baseline), digest(self.source)))

    def test_sanitization_retains_only_exact_audio_preferences_and_dictionary_rows(self):
        self.build()
        path = self.output_database()
        with database(path) as result:
            self.assertEqual(PREFERENCES, result.execute("SELECT * FROM preferences ORDER BY key").fetchall())
            for table in ("reading_history", "extra_private_data", "sqlite_sequence"):
                self.assertEqual(0, result.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0], table)
            self.assertEqual("ok", result.execute("PRAGMA integrity_check").fetchone()[0])
        self.assertNotIn(SECRET.encode(), path.read_bytes(), "deleted private bytes survived on database pages")

    def test_old_resource_bytes_crc_and_new_resources_are_preserved(self):
        self.build()
        with zipfile.ZipFile(self.baseline) as old, zipfile.ZipFile(self.output) as result:
            self.assertEqual(len(result.namelist()), len(set(result.namelist())))
            for name, data in self.resources.items():
                self.assertEqual(data, result.read(name))
                self.assertEqual(old.getinfo(name).CRC, result.getinfo(name).CRC)
            for resource in self.dictionary.rglob("*"):
                if resource.is_file():
                    name = f"dictionaryResources/{TITLE}/{resource.relative_to(self.dictionary).as_posix()}"
                    self.assertEqual(resource.read_bytes(), result.read(name))

    def test_same_name_replacement_removes_obsolete_resources_and_avoids_duplicates(self):
        with database(self.old_db) as db:
            db.execute('INSERT INTO dictionary_metadata VALUES (?, ?, ?, ?, ?, ?, ?)',
                       (TITLE, "yomichan", 7, "term", '{"obsolete":true}', "[]", "[]"))
        prefix = f"dictionaryResources/{TITLE}/"
        self.write_baseline(extra=[(prefix + "index.json", b"old index"), (prefix + "obsolete.bin", b"obsolete")])
        self.build()
        with database(self.output_database()) as result:
            self.assertEqual([NEW_ROW], result.execute("SELECT * FROM dictionary_metadata WHERE name=?", (TITLE,)).fetchall())
        with zipfile.ZipFile(self.output) as archive:
            self.assertNotIn(prefix + "obsolete.bin", archive.namelist())
            self.assertEqual(1, archive.namelist().count(prefix + "index.json"))

    def test_new_dictionary_files_are_streamed(self):
        read_bytes = Path.read_bytes
        def guarded_read(path):
            if path.name == "image.bin":
                self.fail("dictionary resources must be streamed, not read_bytes into memory")
            return read_bytes(path)
        with mock.patch.object(Path, "read_bytes", guarded_read):
            self.build()
        self.assertTrue(self.output.exists())

    def test_mismatched_meta_schema_version_is_rejected(self):
        self.write_baseline(meta={**self.meta, "schemaVersion": 117})
        self.assert_rejected()

    def test_baseline_without_metadata_is_rejected(self):
        with zipfile.ZipFile(self.baseline, "w") as archive:
            archive.write(self.old_db, "fushi.db")
        self.assert_rejected()

    def test_source_without_matching_dictionary_metadata_is_rejected(self):
        with database(self.source) as db:
            db.execute("DELETE FROM dictionary_metadata")
        self.assert_rejected()

    def test_missing_required_old_column_is_rejected(self):
        with database(self.source) as db:
            db.execute("DROP INDEX dictionary_order")
            db.execute('ALTER TABLE dictionary_metadata DROP COLUMN "order"')
        self.assert_rejected()

    def test_source_missing_format_key_is_rejected(self):
        with database(self.source) as db:
            db.execute("ALTER TABLE dictionary_metadata DROP COLUMN format_key")
        self.assert_rejected()

    def test_metadata_trigger_cannot_restore_unapproved_preferences(self):
        with database(self.old_db) as db:
            db.execute("DELETE FROM preferences WHERE key = 'access_token'")
            db.execute(f'''
                CREATE TRIGGER metadata_private_preference
                AFTER INSERT ON dictionary_metadata
                BEGIN
                    INSERT INTO preferences(key, value, updated_at)
                    VALUES ('access_token', '{SECRET}', 999);
                END
            ''')
        self.write_baseline()
        self.assert_rejected()

    def test_existing_output_is_never_overwritten(self):
        self.output.write_bytes(b"already published")
        with self.assertRaises(FileExistsError):
            self.build()
        self.assertEqual(b"already published", self.output.read_bytes())

    def test_output_cannot_be_an_input_database_or_baseline(self):
        for path in (self.baseline, self.source):
            with self.subTest(path=path.name):
                before = digest(path)
                with self.assertRaises((ValueError, FileExistsError)):
                    self.build(output=path)
                self.assertEqual(before, digest(path))

    def test_output_cannot_be_inside_dictionary_resources(self):
        output = self.dictionary / "pack.zip"
        with self.assertRaises(ValueError):
            self.build(output=output)
        self.assertFalse(output.exists())

    def test_unsafe_archive_paths_are_rejected(self):
        for name in ("../escape.txt", "/absolute.txt", "C:/escape.txt", "dictionaryResources/../escape.txt", "dictionaryResources\\..\\escape.txt"):
            with self.subTest(name=name):
                self.write_baseline(extra=[(name, b"unsafe")])
                self.assert_rejected()

    def test_duplicate_archive_entries_are_rejected(self):
        self.write_baseline(extra=[("backup_meta.json", json.dumps(self.meta))])
        self.assert_rejected()

    def test_unsafe_dictionary_titles_are_rejected(self):
        for title in ("../escape", "a/b", "a\\b", ".", "..", "C:escape", ""):
            with self.subTest(title=title):
                (self.dictionary / "index.json").write_text(json.dumps({"title": title}), encoding="utf-8")
                self.assert_rejected()

    def test_dictionary_without_index_is_rejected(self):
        (self.dictionary / "index.json").unlink()
        self.assert_rejected()

    def test_dictionary_path_must_be_directory(self):
        self.assert_rejected(dictionary_dir=self.dictionary / "index.json")

    def test_dictionary_symlink_cannot_import_external_files(self):
        outside = self.root / "private.bin"
        outside.write_bytes(SECRET.encode())
        try:
            (self.dictionary / "external.bin").symlink_to(outside)
        except OSError as error:
            self.skipTest(f"host cannot create symlinks: {error}")
        self.assert_rejected()

    def test_resource_read_failure_leaves_no_partial_pack(self):
        original_open = zipfile.ZipFile.open
        def failing_open(archive, name, mode="r", *args, **kwargs):
            filename = name.filename if isinstance(name, zipfile.ZipInfo) else name
            if mode == "w" and filename.endswith("/image.bin"):
                raise OSError("simulated dictionary resource write failure")
            return original_open(archive, name, mode, *args, **kwargs)
        with mock.patch.object(zipfile.ZipFile, "open", failing_open):
            self.assert_rejected(error=OSError)


if __name__ == "__main__":
    unittest.main()
