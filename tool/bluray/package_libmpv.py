"""Package libmpv and its complete PE import closure from a fixed MSYS2 prefix.

Fails on missing imports, and records every DLL hash. No PATH-based resolution.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from namespace_runtime import module_references, namespace_runtime


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def imports(path):
    return module_references(path)


def collect(root, prefix, system):
    pending, found = [root], {}
    while pending:
        path = pending.pop()
        if path.name.lower() in found:
            continue
        found[path.name.lower()] = path
        for name in imports(path):
            dependency = prefix / "bin" / name
            if dependency.is_file():
                pending.append(dependency)
            elif not (system / name).is_file() and not name.lower().startswith(("api-ms-", "ext-ms-")):
                raise RuntimeError(f"Unresolved {name}, imported by {path.name}")
    return sorted(found.values(), key=lambda p: p.name.lower())


def package_sources(closure, prefix, output):
    """Record the package versions and licenses behind every imported DLL."""
    msys = prefix.parent
    wanted = {"mingw64/bin/" + path.name: path.name for path in closure if path.parent == prefix / "bin"}
    owned = set()
    packages = []
    for entry in (msys / "var/lib/pacman/local").iterdir():
        if not (entry / "files").is_file():
            continue
        names = (entry / "files").read_text().splitlines()
        matched = sorted(set(names) & wanted.keys())
        if not matched:
            continue
        owned.update(matched)
        desc = (entry / "desc").read_text().splitlines()
        name = desc[desc.index("%NAME%") + 1]
        version = desc[desc.index("%VERSION%") + 1]
        url = desc[desc.index("%URL%") + 1] if "%URL%" in desc else None
        packages.append({"name": name, "version": version, "upstream": url,
                         "dlls": [wanted[p] for p in matched]})
        for filename in names:
            source = msys / filename
            if filename.startswith("mingw64/share/licenses/") and source.is_file():
                target = output / "licenses" / name / Path(filename).name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
    if missing := wanted.keys() - owned:
        raise RuntimeError(f"DLLs without package provenance: {sorted(missing)}")
    (output / "msys2-packages.json").write_text(json.dumps(sorted(packages, key=lambda p: p["name"]), indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, default=Path("C:/msys64/mingw64"))
    parser.add_argument("--system", type=Path, default=Path("C:/Windows/System32"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise RuntimeError("Output must be a new directory; never mix dependency generations")
    closure = collect(args.build / "libmpv-2.dll", args.prefix, args.system)
    args.output.mkdir(parents=True)
    for source in closure:
        target = args.output / source.name
        shutil.copy2(source, target)
    manifest = namespace_runtime(args.output)
    shutil.copy2(args.build / "libmpv.dll.a", args.output)
    include = args.output / "include/mpv"
    include.mkdir(parents=True)
    for name in ("client.h", "render.h", "render_gl.h", "stream_cb.h"):
        shutil.copy2(args.source / "include/mpv" / name, include)
    (args.output / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # CMake uses the explicit closure, never a glob that might include old DLLs.
    (args.output / "runtime-files.cmake").write_text(
        "set(LIBMPV_RUNTIME_NAMES\n" + "".join(f'  "{row["name"]}"\n' for row in manifest) + ")\n")
    package_sources(closure, args.prefix, args.output)
    shutil.copy2(args.source / "LICENSE.GPL", args.output / "licenses/MPV-GPL.txt")
    shutil.copy2(args.source / "LICENSE.LGPL", args.output / "licenses/MPV-LGPL.txt")
    commit = subprocess.check_output(["git", "-C", str(args.source), "rev-parse", "HEAD"], text=True).strip()
    patch_file = Path(__file__).resolve().parents[2] / "third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch"
    (args.output / "source-provenance.json").write_text(json.dumps({
        "mpv_commit": commit, "patch_sha256": sha256(patch_file),
        "native_menu_schema": 1, "runtime_manifest": "runtime-manifest.json",
        "dependency_packages": "msys2-packages.json",
    }, indent=2) + "\n")
    print(json.dumps({"files": len(manifest), "bytes": sum(row["bytes"] for row in manifest)}))


if __name__ == "__main__":
    main()
