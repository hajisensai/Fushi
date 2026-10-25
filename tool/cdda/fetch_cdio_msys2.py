"""Unpack the pinned libcdio / libcdio-paranoia MSYS2 packages into a private prefix.

tool/cdda/recipe.env pins each package file by URL and SHA-256. This script
downloads them (or reuses --cache copies whose hash matches), refuses any hash
mismatch, and unpacks only the `mingw64/` payload into <output>/mingw64 with
the pkg-config prefix rewritten to that directory. The shared MSYS2 install is
never modified, so the build machine's other packages stay as recorded in
native-dependency-packages.json.

Static archives (lib*.a that are not import libraries) are removed so meson
can only link the DLLs that package_libmpv.py ships.

Usage: python -I fetch_cdio_msys2.py --output <new dir> [--cache <dir>]
           [--zstd C:/msys64/usr/bin/zstd.exe] [--msys-prefix C:/msys64/mingw64]
"""
import argparse
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile
import urllib.request

RECIPE = Path(__file__).resolve().parent / "recipe.env"
PACKAGES = ("LIBCDIO", "LIBCDIO_PARANOIA")


def read_recipe(path: Path = RECIPE) -> dict:
    return dict(line.split("=", 1) for line in path.read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#") and "=" in line)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(url: str, expected: str, cache: Path | None) -> bytes:
    name = url.rsplit("/", 1)[-1].replace("%2B", "+")
    if cache is not None and (cache / name).is_file():
        data = (cache / name).read_bytes()
        if sha256(data) == expected:
            return data
    # urllib honours HTTPS_PROXY / HTTP_PROXY from the environment.
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if sha256(data) != expected:
        raise RuntimeError(f"{name}: sha256 {sha256(data)} != pinned {expected}")
    if cache is not None:
        cache.mkdir(parents=True, exist_ok=True)
        (cache / name).write_bytes(data)
    return data


def unpack(data: bytes, zstd: Path, output: Path) -> None:
    tar_bytes = subprocess.run([str(zstd), "-dc"], input=data, capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as archive:
        for member in archive.getmembers():
            if not member.name.startswith("mingw64/") or ".." in Path(member.name).parts:
                continue
            target = output / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.extractfile(member).read())


def relocate(prefix: Path, msys_prefix: Path) -> None:
    """Point every .pc file at the private prefix and drop static archives.

    `-L/mingw64/lib` (for libiconv, which stays an MSYS2 package) is an MSYS
    path the native toolchain does not resolve; it becomes the MSYS2 prefix.
    """
    posix = prefix.as_posix()
    for pc in (prefix / "lib/pkgconfig").glob("*.pc"):
        lines = [f"prefix={posix}" if line.startswith("prefix=")
                 else line.replace("-L/mingw64/lib", f"-L{msys_prefix.as_posix()}/lib")
                 for line in pc.read_text(encoding="utf-8").splitlines()]
        pc.write_text("\n".join(lines) + "\n", encoding="utf-8")
    for archive in (prefix / "lib").glob("*.a"):
        if not archive.name.endswith(".dll.a"):
            archive.unlink()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--zstd", type=Path, default=Path("C:/msys64/usr/bin/zstd.exe"))
    parser.add_argument("--msys-prefix", type=Path, default=Path("C:/msys64/mingw64"))
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        raise RuntimeError(f"Use a new output directory: {output}")
    recipe = read_recipe()
    for key in PACKAGES:
        unpack(fetch(recipe[f"{key}_URL"], recipe[f"{key}_SHA256"], args.cache), args.zstd, output)
    prefix = output / "mingw64"
    relocate(prefix, args.msys_prefix)
    for pc in ("libcdio.pc", "libcdio_cdda.pc", "libcdio_paranoia.pc"):
        if not (prefix / "lib/pkgconfig" / pc).is_file():
            raise RuntimeError(f"{pc} missing from the unpacked packages")
    print(prefix)


if __name__ == "__main__":
    main()
