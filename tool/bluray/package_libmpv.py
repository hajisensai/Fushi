"""Package libmpv and its complete PE import closure from fixed prefixes.

The unified FFmpeg (tool/ffmpeg-unified) is resolved from its private prefix
first, every other dependency from the fixed MSYS2 prefix. ffmpeg.exe and
ffprobe.exe from the unified FFmpeg are packaged as additional roots, so card
mining runs on exactly the FFmpeg DLLs libmpv plays with.

Fails on missing imports, and records every DLL hash. No PATH-based resolution.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from namespace_runtime import module_references, namespace_runtime

# The unified FFmpeg's programs, shipped next to fushi.exe on the shared DLLs.
FFMPEG_PROGRAMS = ("ffmpeg.exe", "ffprobe.exe")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def imports(path):
    return module_references(path)


def collect(roots, prefixes, system):
    pending, found = list(roots), {}
    while pending:
        path = pending.pop()
        if path.name.lower() in found:
            continue
        found[path.name.lower()] = path
        for name in imports(path):
            dependency = next((prefix / "bin" / name for prefix in prefixes
                               if (prefix / "bin" / name).is_file()), None)
            if dependency is not None:
                pending.append(dependency)
            elif not (system / name).is_file() and not name.lower().startswith(("api-ms-", "ext-ms-")):
                raise RuntimeError(f"Unresolved {name}, imported by {path.name}")
    return sorted(found.values(), key=lambda p: p.name.lower())


def patch_subject(patch):
    """The commit subject of a `git format-patch` file (RFC 2822 folding undone)."""
    lines = patch.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("Subject: "))
    subject = lines[start][len("Subject: "):]
    for line in lines[start + 1:]:
        if not line.startswith((" ", "\t")):
            break
        subject += " " + line.strip()
    return subject.split("] ", 1)[-1] if subject.startswith("[PATCH") else subject


def unified_ffmpeg_provenance(closure, ffmpeg_prefix, ffmpeg_source, output):
    """Record the unified FFmpeg build (not pacman-owned) and ship its license."""
    recipe_dir = Path(__file__).resolve().parents[1] / "ffmpeg-unified"
    recipe = dict(line.split("=", 1) for line in (recipe_dir / "recipe.env").read_text().splitlines()
                  if line and not line.startswith("#") and "=" in line)
    commit = subprocess.check_output(["git", "-C", str(ffmpeg_source), "rev-parse", "HEAD"], text=True).strip()
    patches = sorted((recipe_dir / "patches/ffmpeg").glob("*.patch"))
    # The build must carry exactly the recipe's patches (prepare_ffmpeg_src.sh
    # commits one per patch on top of FFMPEG_COMMIT). A tree prepared before a
    # patch was added would otherwise be shipped under the new recipe's name.
    applied = subprocess.check_output(
        ["git", "-C", str(ffmpeg_source), "log", "--reverse", "--format=%s",
         f"{recipe['FFMPEG_COMMIT']}..HEAD"], text=True).splitlines()
    expected = [patch_subject(p) for p in patches]
    if applied != expected:
        raise RuntimeError(f"Unified FFmpeg source carries {applied}, recipe expects {expected}; "
                           "rebuild it with tool/ffmpeg-unified/windows/build_ffmpeg_msys2.sh")
    license_dir = output / "licenses" / "ffmpeg-unified"
    license_dir.mkdir(parents=True, exist_ok=True)
    for name in ("COPYING.GPLv3", "COPYING.LGPLv3", "LICENSE.md"):
        if (ffmpeg_source / name).is_file():
            shutil.copy2(ffmpeg_source / name, license_dir / name)
    return {
        "name": "fushi-unified-ffmpeg",
        "version": recipe["FFMPEG_VERSION"],
        "upstream_commit": recipe["FFMPEG_COMMIT"],
        "patched_commit": commit,
        "patches": {p.name: sha256(p) for p in patches},
        "files": sorted(path.name for path in closure if path.parent == ffmpeg_prefix / "bin"),
    }


def package_sources(closure, prefix, output, unified=None):
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
    if unified is not None:
        packages.append(unified)
    (output / "msys2-packages.json").write_text(json.dumps(sorted(packages, key=lambda p: p["name"]), indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, default=Path("C:/msys64/mingw64"))
    parser.add_argument("--ffmpeg-prefix", type=Path, required=True,
                        help="private prefix of the unified FFmpeg (build_ffmpeg_msys2.sh)")
    parser.add_argument("--ffmpeg-source", type=Path, required=True,
                        help="patched unified FFmpeg source tree (for provenance/licenses)")
    parser.add_argument("--system", type=Path, default=Path("C:/Windows/System32"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise RuntimeError("Output must be a new directory; never mix dependency generations")
    roots = [args.build / "libmpv-2.dll"] + [args.ffmpeg_prefix / "bin" / name for name in FFMPEG_PROGRAMS]
    closure = collect(roots, [args.ffmpeg_prefix, args.prefix], args.system)
    # libmpv must link the unified FFmpeg, never a stray MSYS2 copy of it.
    stray = sorted(p.name for p in closure if p.parent == args.prefix / "bin"
                   and p.name.lower().startswith(("avcodec-", "avformat-", "avutil-", "avfilter-",
                                                  "avdevice-", "swscale-", "swresample-")))
    if stray:
        raise RuntimeError(f"FFmpeg DLLs resolved from MSYS2 instead of the unified prefix: {stray}")
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
    package_sources(closure, args.prefix, args.output,
                    unified_ffmpeg_provenance(closure, args.ffmpeg_prefix, args.ffmpeg_source, args.output))
    shutil.copy2(args.source / "LICENSE.GPL", args.output / "licenses/MPV-GPL.txt")
    shutil.copy2(args.source / "LICENSE.LGPL", args.output / "licenses/MPV-LGPL.txt")
    commit = subprocess.check_output(["git", "-C", str(args.source), "rev-parse", "HEAD"], text=True).strip()
    patches = Path(__file__).resolve().parents[2] / "third_party/media_kit_libs_windows_video/patches"
    patch_file = patches / "disc-navigation-state.patch"
    # BUG-3296: render-path fixes applied on top of the navigation patch.
    render_patches = ["gpu-dumb-mode-hwdec-crop.patch"]
    # BUG-3499: demuxer fixes (timestamps of laced Matroska audio frames).
    # BUG-3500: the recorder behind dump-cache derives missing video DTS.
    demux_patches = ["mkv-laced-audio-timestamps.patch", "recorder-video-dts.patch"]
    (args.output / "source-provenance.json").write_text(json.dumps({
        "mpv_commit": commit, "patch_sha256": sha256(patch_file),
        "render_patches": {name: sha256(patches / name) for name in render_patches},
        "demux_patches": {name: sha256(patches / name) for name in demux_patches},
        "native_menu_schema": 1, "runtime_manifest": "runtime-manifest.json",
        "dependency_packages": "msys2-packages.json",
    }, indent=2) + "\n")
    print(json.dumps({"files": len(manifest), "bytes": sum(row["bytes"] for row in manifest)}))


if __name__ == "__main__":
    main()
