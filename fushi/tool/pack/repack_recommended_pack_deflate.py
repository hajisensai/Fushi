"""Repack a released (STORE) recommended pack into the smaller deflate variant.

The STORE pack stays the compatibility contract for every installed app: old
versions inflate deflated entries with archive 3.6.1's pure-Dart
``Inflate.stream`` (measured 1.13 MB/s), so they must keep getting STORE. Apps
that inflate with native zlib read the ``deflate_pack`` manifest key instead
(``kRecommendedPackDeflateManifestKey`` in ``recommended_pack.dart``).

What changes, entry by entry, and nothing else:

* ``localAudio/local_audio_*.db``: every index except the two the app queries
  through is dropped (the shipped databases carry duplicate same-column indexes
  under Yomitan's names plus ones no query uses), the two canonical ones are
  created if missing, then ``VACUUM``. Rows are untouched; checked by row count
  and ``quick_check``.
* Every entry is written DEFLATE when a sample of it shrinks, STORE otherwise
  (already-compressed blobs/images gain nothing and only cost CPU).

The output file name must differ from the input's: slices are named
``<pack name>.NNN`` and both packs' slices live in the same release.

Publishing both packs (one release in hajisensai/fushi-pack, one manifest):

1. Repack (this script):
       python fushi/tool/pack/repack_recommended_pack_deflate.py \\
           --input D:/packs/fushi-recommended.fushi.zip \\
           --output D:/packs/deflate/fushi-recommended.deflate.fushi.zip
2. Slice + manifest the deflate pack on its own (in ``fushi/``):
       dart run tool/make_download_manifest.dart \\
           --input D:/packs/deflate/fushi-recommended.deflate.fushi.zip \\
           --out-dir D:/packs/slices --manifest-out D:/packs/deflate.manifest.json \\
           --whole-url <deflate whole-file url> --part-base-url <release dir> ...
3. Slice + manifest the STORE pack, embedding step 2's manifest:
       dart run tool/make_download_manifest.dart \\
           --input D:/packs/fushi-recommended.fushi.zip --out-dir D:/packs/slices \\
           --whole-url <store whole-file url> --part-base-url <release dir> ... \\
           --deflate-manifest D:/packs/deflate.manifest.json
   Upload both packs' slices plus step 3's manifest as ``manifest.json``.
   Old apps read its top level (STORE); new apps read ``deflate_pack``.
"""

import argparse
import contextlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import tempfile
import zipfile
import zlib


LOCAL_AUDIO_PREFIX = "localAudio/"
COPY_CHUNK = 8 * 1024 * 1024
SAMPLE_BYTES = 4 * 1024 * 1024
# Deflate only pays when it saves at least this fraction of a sampled window.
MAX_DEFLATE_RATIO = 0.97
DEFLATE_LEVEL = 6

# The two lookups the app runs (LocalAudioDb._indexSpecs on desktop,
# TtsChannelHandler on Android): entries by (expression, reading) and the audio
# blob by (file, source). Same names the app would create at bind time, so a
# repacked database never triggers an index build on first use.
CANONICAL_INDEXES = {
    "idx_entries_expr_read": ("entries", ("expression", "reading")),
    "idx_android_file_source": ("android", ("file", "source")),
}


def _quote(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and "\\" not in name and all(
        part not in (".", "..", "") for part in name.rstrip("/").split("/")
    )


def _row_counts(db: sqlite3.Connection) -> dict:
    tables = [row[0] for row in db.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT GLOB 'sqlite_*'"
    )]
    return {table: db.execute("SELECT COUNT(*) FROM " + _quote(table)).fetchone()[0] for table in tables}


def slim_local_audio_db(path: Path) -> dict:
    """Drops non-canonical indexes, ensures the canonical ones, VACUUMs."""
    before = path.stat().st_size
    with contextlib.closing(sqlite3.connect(path)) as db:
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        if not {"entries", "android"}.issubset(tables):
            raise ValueError(f"{path.name} is not a local-audio database")
        counts = _row_counts(db)
        # sql IS NULL = automatic indexes (PRIMARY KEY / UNIQUE constraints):
        # part of the table definition, not droppable and not ours to touch.
        dropped = [row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL"
        ) if row[0] not in CANONICAL_INDEXES]
        with db:
            for name in dropped:
                db.execute("DROP INDEX " + _quote(name))
            for name, (table, columns) in CANONICAL_INDEXES.items():
                db.execute(
                    "CREATE INDEX IF NOT EXISTS " + _quote(name) + " ON " + _quote(table)
                    + "(" + ", ".join(map(_quote, columns)) + ")"
                )
        db.execute("VACUUM")
        if db.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise ValueError(f"{path.name} failed quick_check after slimming")
        if _row_counts(db) != counts:
            raise ValueError(f"{path.name} row counts changed while slimming")
    return {"before": before, "after": path.stat().st_size, "droppedIndexes": sorted(dropped)}


def _should_deflate(sample: bytes) -> bool:
    if not sample:
        return False
    return len(zlib.compress(sample, DEFLATE_LEVEL)) <= len(sample) * MAX_DEFLATE_RATIO


def _sample_middle(open_stream, size: int) -> bytes:
    """Reads SAMPLE_BYTES from the middle of an entry (headers lie about ratio)."""
    with open_stream() as stream:
        skip = max(0, size // 2 - SAMPLE_BYTES // 2)
        while skip > 0:
            chunk = stream.read(min(skip, COPY_CHUNK))
            if not chunk:
                break
            skip -= len(chunk)
        return stream.read(SAMPLE_BYTES)


def _write_entry(new: zipfile.ZipFile, template: zipfile.ZipInfo, size: int, open_stream) -> int:
    # Fresh header rather than a copy: the source's extra field can carry its own
    # zip64 record, which zipfile would append a second one to.
    info = zipfile.ZipInfo(template.filename, date_time=template.date_time)
    info.external_attr = template.external_attr
    info.compress_type = (
        zipfile.ZIP_DEFLATED if _should_deflate(_sample_middle(open_stream, size)) else zipfile.ZIP_STORED
    )
    info.file_size = size
    with open_stream() as source, new.open(info, "w", force_zip64=size >= 2**31) as target:
        shutil.copyfileobj(source, target, COPY_CHUNK)
    return info.compress_type


def repack(input_path: Path, output_path: Path) -> dict:
    input_path, output_path = Path(input_path), Path(output_path)
    if output_path.exists():
        raise FileExistsError(output_path)
    if not input_path.is_file():
        raise ValueError("input pack must exist")
    if output_path.name == input_path.name:
        raise ValueError(
            "output file name must differ from the STORE pack's: both packs' slices "
            "(<pack name>.NNN) live in the same release and would overwrite each other"
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"entries": 0, "deflated": 0, "localAudio": {}}
    with tempfile.TemporaryDirectory(prefix="pack-deflate-", dir=output_path.parent) as temp:
        candidate = Path(temp) / "candidate.zip"
        with zipfile.ZipFile(input_path) as old, zipfile.ZipFile(candidate, "w", allowZip64=True) as new:
            names = [info.filename for info in old.infolist()]
            if len(names) != len(set(names)) or not {"fushi.db", "backup_meta.json"}.issubset(names):
                raise ValueError("input requires unique database and metadata entries")
            for info in old.infolist():
                name = info.filename
                if not _safe_member(name):
                    raise ValueError(f"unsafe entry name: {name}")
                report["entries"] += 1
                if name.startswith(LOCAL_AUDIO_PREFIX) and name.endswith(".db"):
                    staged = Path(temp) / PurePosixPath(name).name
                    with old.open(info) as source, staged.open("wb") as target:
                        shutil.copyfileobj(source, target, COPY_CHUNK)
                    report["localAudio"][name] = slim_local_audio_db(staged)
                    kind = _write_entry(new, info, staged.stat().st_size, lambda p=staged: p.open("rb"))
                    staged.unlink()
                else:
                    kind = _write_entry(new, info, info.file_size, lambda i=info: old.open(i))
                if kind == zipfile.ZIP_DEFLATED:
                    report["deflated"] += 1
        with zipfile.ZipFile(candidate) as check:
            bad = check.testzip()
            if bad is not None:
                raise ValueError(f"CRC check failed for {bad}")
            if [i.filename for i in check.infolist()] != names:
                raise ValueError("repacked entry list differs from the input")
        candidate.rename(output_path)
    report["inputBytes"] = input_path.stat().st_size
    report["outputBytes"] = output_path.stat().st_size
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(repack(args.input, args.output), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
