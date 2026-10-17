"""Extend a released dictionary pack without migrating its SQLite schema.

The baseline is the compatibility contract. A current app's database is only a
read-only source of the selected dictionary row, never the exported database.
"""

import argparse
import contextlib
import copy
import datetime
import json
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import tempfile
import zipfile


def _quote(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and "\\" not in name and all(
        part not in (".", "..", "") for part in name.rstrip("/").split("/")
    )


def _schema(db: sqlite3.Connection) -> list:
    return db.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
    ).fetchall()


def _clean_database(database: Path, metadata_db: Path, title: str, version: int) -> int:
    with contextlib.closing(sqlite3.connect(database)) as db:
        if db.execute("PRAGMA user_version").fetchone()[0] != version:
            raise ValueError("baseline metadata and SQLite schema versions differ")
        original_schema = _schema(db)
        columns = [row[1] for row in db.execute("PRAGMA table_info(dictionary_metadata)")]
        if not {"name", "format_key"}.issubset(columns):
            raise ValueError("baseline lacks dictionary metadata columns")
        with contextlib.closing(sqlite3.connect(metadata_db.resolve().as_uri() + "?mode=ro", uri=True)) as source:
            source.row_factory = sqlite3.Row
            row = source.execute("SELECT * FROM dictionary_metadata WHERE name = ?", (title,)).fetchone()
            if row is None or not set(columns).issubset(row.keys()):
                raise ValueError("dictionary metadata cannot be represented in the baseline schema")
            values = [row[column] for column in columns]
        db.execute("PRAGMA foreign_keys = OFF")
        tables = [row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT GLOB 'sqlite_*'"
        )]
        with db:
            for table in tables:
                if table not in ("dictionary_metadata", "preferences"):
                    db.execute("DELETE FROM " + _quote(table))
            db.execute("DELETE FROM preferences WHERE key NOT IN ('audio_source_configs', 'local_audio_dbs')")
            db.execute("DELETE FROM dictionary_metadata WHERE name = ?", (title,))
            db.execute(
                "INSERT INTO dictionary_metadata (" + ",".join(map(_quote, columns))
                + ") VALUES (" + ",".join("?" for _ in columns) + ")", values,
            )
            if db.execute("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_sequence'").fetchone():
                db.execute("DELETE FROM sqlite_sequence")
            if db.execute("SELECT COUNT(*) FROM preferences WHERE key NOT IN ('audio_source_configs', 'local_audio_dbs')").fetchone()[0]:
                raise ValueError("baseline trigger retained private preferences")
            for table in tables:
                if table not in ("dictionary_metadata", "preferences") and db.execute(
                    "SELECT COUNT(*) FROM " + _quote(table)
                ).fetchone()[0]:
                    raise ValueError("baseline trigger retained private data")
        db.execute("VACUUM")
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        if _schema(db) != original_schema or db.execute("PRAGMA user_version").fetchone()[0] != version:
            raise ValueError("pack extension changed the baseline schema")
        if db.execute("PRAGMA quick_check").fetchone()[0] != "ok" or db.execute("PRAGMA foreign_key_check").fetchall():
            raise ValueError("invalid distribution database")
        return db.execute("SELECT COUNT(*) FROM dictionary_metadata").fetchone()[0]


def build_pack(baseline: Path, metadata_db: Path, dictionary_dir: Path, output: Path) -> dict:
    baseline, metadata_db, dictionary_dir, output = map(Path, (baseline, metadata_db, dictionary_dir, output))
    if output.exists():
        raise FileExistsError(output)
    if output.resolve() in (baseline.resolve(), metadata_db.resolve()) or output.resolve().is_relative_to(dictionary_dir.resolve()):
        raise ValueError("output must be separate from all inputs")
    if not baseline.is_file() or not metadata_db.is_file() or not dictionary_dir.is_dir():
        raise ValueError("pack inputs must exist")
    try:
        index = json.loads((dictionary_dir / "index.json").read_text(encoding="utf-8"))
        title = index["title"]
    except (OSError, ValueError, KeyError) as error:
        raise ValueError("dictionary requires a valid index.json") from error
    if not isinstance(title, str) or not _safe_member(title) or "/" in title or title in (".", ".."):
        raise ValueError("dictionary title must be a single safe directory name")
    root = dictionary_dir.resolve()
    resources = []
    for file in sorted(dictionary_dir.rglob("*")):
        if file.is_symlink() or not file.resolve().is_relative_to(root):
            raise ValueError("dictionary resources must not escape their directory")
        if file.is_file():
            relative = file.relative_to(dictionary_dir).as_posix()
            if not _safe_member(relative):
                raise ValueError("unsafe dictionary resource name")
            resources.append((relative, file))
    if not resources:
        raise ValueError("dictionary resources are empty")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pack-compat-", dir=output.parent) as temp:
        database = Path(temp) / "fushi.db"
        candidate = Path(temp) / "candidate.fushi.zip"
        with zipfile.ZipFile(baseline) as old:
            infos = old.infolist()
            names = [info.filename for info in infos]
            if len(names) != len(set(names)) or not {"fushi.db", "backup_meta.json"}.issubset(names):
                raise ValueError("baseline requires unique database and metadata entries")
            for name in names:
                if not _safe_member(name) or not (name in ("fushi.db", "backup_meta.json") or name.startswith(("dictionaryResources/", "localAudio/"))):
                    raise ValueError("baseline contains non-distribution or unsafe resources")
            meta = json.loads(old.read("backup_meta.json"))
            version = meta.get("schemaVersion")
            if not isinstance(version, int) or version <= 0:
                raise ValueError("baseline requires a real schema version")
            with old.open("fushi.db") as source, database.open("wb") as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
            count = _clean_database(database, metadata_db, title, version)
            meta["createdAt"] = datetime.datetime.now().isoformat()
            for key in ("bookCount", "statsCount", "videoBookCount", "audiobookCount", "gameCount", "progressCount", "srsNoteCount"):
                if key in meta:
                    meta[key] = 0
            prefix = "dictionaryResources/" + title + "/"
            with zipfile.ZipFile(candidate, "w", allowZip64=True) as new:
                for info in infos:
                    name = info.filename
                    if name in ("fushi.db", "backup_meta.json") or name.startswith(prefix):
                        continue
                    with old.open(info) as source, new.open(copy.copy(info), "w", force_zip64=info.file_size >= 2**31) as target:
                        shutil.copyfileobj(source, target, 1024 * 1024)
                new.writestr("backup_meta.json", json.dumps(meta, ensure_ascii=False, indent=2).encode("utf-8"), compress_type=zipfile.ZIP_DEFLATED)
                new.write(database, "fushi.db", compress_type=zipfile.ZIP_STORED)
                for relative, file in resources:
                    new.write(file, prefix + relative, compress_type=zipfile.ZIP_STORED)
        candidate.rename(output)
    return {"schemaVersion": version, "dictionaryCount": count, "dictionary": title, "bytes": output.stat().st_size}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("baseline", "metadata-db", "dictionary-dir", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    result = build_pack(args.baseline, args.metadata_db, args.dictionary_dir, args.output)
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
