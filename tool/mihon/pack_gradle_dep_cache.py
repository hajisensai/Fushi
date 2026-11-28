#!/usr/bin/env python3
"""Pack a Gradle dependency cache into the Mihon offline build kit.

  python3 tool/mihon/pack_gradle_dep_cache.py GRADLE_USER_HOME OUTPUT.tar.gz

GRADLE_USER_HOME is the directory an online Mihon build ran with
(FUSHI_MIHON_GRADLE_ONLINE_HOME=<empty dir> tool/mihon/build_desktop_runtime.{sh,ps1}).
The archive holds `modules-2/` of that home's `caches/`, minus Gradle's lock files
and gc.properties, which is exactly the layout Gradle's read-only dependency cache
(GRADLE_RO_DEP_CACHE) expects; the build scripts extract it and run `--offline`
against it. Entries are sorted with zeroed owner / mtime, so packing the same cache
twice gives the same bytes. Procedure: third_party/mihon_build/README.md.
"""

from __future__ import annotations

import gzip
import io
import sys
import tarfile
from pathlib import Path

# Gradle's own bookkeeping, never part of a read-only cache (Gradle docs:
# "Sharing dependency caches with other hosts" -> remove *.lock and gc.properties).
_EXCLUDED_SUFFIXES: tuple[str, ...] = (".lock",)
_EXCLUDED_NAMES: frozenset[str] = frozenset({"gc.properties"})


def _included(path: Path) -> bool:
    return path.name not in _EXCLUDED_NAMES and not path.name.endswith(_EXCLUDED_SUFFIXES)


def pack(gradle_user_home: Path, output: Path) -> int:
    modules = gradle_user_home / "caches" / "modules-2"
    if not (modules / "files-2.1").is_dir():
        raise SystemExit(f"error: {modules} has no files-2.1; run an online Mihon build with this home first")
    files = sorted(p for p in modules.rglob("*") if p.is_file() and _included(p))
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for path in files:
            name = "modules-2/" + path.relative_to(modules).as_posix()
            info = tarfile.TarInfo(name)
            info.size = path.stat().st_size
            info.mode = 0o644
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            with path.open("rb") as handle:
                archive.addfile(info, handle)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as gz:
        gz.write(buffer.getvalue())
    print(f"packed {len(files)} file(s) from {modules} into {output} ({output.stat().st_size} bytes)")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 64
    return pack(Path(argv[0]), Path(argv[1]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
