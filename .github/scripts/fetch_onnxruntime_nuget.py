#!/usr/bin/env python3
"""Fetch the ONNX Runtime CPU library from the official NuGet package.

Why: github.com/microsoft/onnxruntime (the repository and every release asset,
e.g. ``onnxruntime-linux-x64-1.22.0.tgz``) has returned 404 since 2026-11-17
with no migration notice, so the server workflows could no longer download
ORT. nuget.org still serves the same official release as
``Microsoft.ML.OnnxRuntime``; the nupkg is a zip with the native library under
``runtimes/<rid>/native/``.

The nupkg is pinned by SHA-256 (it is machine code that ships in the server
bundle), and so is each extracted library. Cleanup condition: none needed when
the GitHub release returns -- NuGet is an equally official channel. A version
bump must add its pins here (and in
``third_party/flutter_onnxruntime/linux/CMakeLists.txt``).

Usage: fetch_onnxruntime_nuget.py <version> <rid> <dest_dir>
  rid: linux-x64 | win-x64
Linux: writes libonnxruntime.so (real file) + libonnxruntime.so.1 symlink
(the SONAME, same names the old tarball's lib/ shipped).
Windows: writes onnxruntime.dll.
"""

from __future__ import annotations

import hashlib
import os
import sys
import tempfile
import time
import urllib.request
import zipfile

# version -> (nupkg sha256, {rid: (member path, member sha256)})
PINS: dict[str, tuple[str, dict[str, tuple[str, str]]]] = {
    "1.22.0": (
        "d571e63a2329baacb713f441e65ad75284de354db6e1ac435fe4bebbb417986a",
        {
            "linux-x64": (
                "runtimes/linux-x64/native/libonnxruntime.so",
                "3da6146e14e7b8aaec625dde11d6114c7457c87a5f93d744897da8781e35c673",
            ),
            "win-x64": (
                "runtimes/win-x64/native/onnxruntime.dll",
                "579b636403983254346a5c1d80bd28f1519cd1e284cd204f8d4ff41f8d711559",
            ),
        },
    ),
}


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _download(url: str, dest: str) -> None:
    last: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=120) as r, open(dest, "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        return
                    f.write(chunk)
        except Exception as e:  # noqa: BLE001 - retried, then re-raised
            last = e
            time.sleep(2 * (attempt + 1))
    raise SystemExit(f"download failed: {url}: {last}")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    version, rid, dest = argv[1], argv[2], argv[3]
    if version not in PINS or rid not in PINS[version][1]:
        raise SystemExit(f"no pinned sha256 for onnxruntime {version} / {rid}")
    nupkg_sha, members = PINS[version]
    member, member_sha = members[rid]
    url = (
        "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/"
        f"{version}/microsoft.ml.onnxruntime.{version}.nupkg"
    )
    os.makedirs(dest, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        pkg = os.path.join(tmp, "ort.nupkg")
        _download(url, pkg)
        got = _sha256(pkg)
        if got != nupkg_sha:
            raise SystemExit(f"nupkg sha256 mismatch: {got} != {nupkg_sha}")
        name = os.path.basename(member)
        out = os.path.join(dest, name)
        with zipfile.ZipFile(pkg) as z, z.open(member) as src, open(out, "wb") as dst:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                dst.write(chunk)
    got = _sha256(out)
    if got != member_sha:
        os.remove(out)
        raise SystemExit(f"{member} sha256 mismatch: {got} != {member_sha}")
    if rid.startswith("linux-"):
        os.chmod(out, 0o755)
        soname = os.path.join(dest, "libonnxruntime.so.1")
        if os.path.lexists(soname):
            os.remove(soname)
        os.symlink("libonnxruntime.so", soname)
    print(f"onnxruntime {version} {rid} -> {out} (sha256 {member_sha})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
