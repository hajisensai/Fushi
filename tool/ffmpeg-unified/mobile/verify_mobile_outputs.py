#!/usr/bin/env python3
"""Verify unified-FFmpeg mobile artifacts by reading the binaries' bytes.

    verify_mobile_outputs.py android <out-dir> [--require-staged]   # ffmpeg-kit-next.aar + ffmpeg-dev-android-*.tar.gz
    verify_mobile_outputs.py ios <out-dir> [--require-staged]       # ffmpeg-kit-next-ios-xcframeworks.zip

--require-staged also checks capabilities.json's "staged" section (new builds;
see verify_ffmpeg_capabilities.py) and, for the DVD entries, that the shared
tool/dvd libraries ship next to the libav* libraries (AAR jni/<abi>/ and the
iOS xcframework zip) and that libavformat links them dynamically.

The mobile binaries cannot run on the CI host, so this checks what the guard
tests also pin: ABI/slice set, the embedded FFmpeg configure line, the version,
every Fushi patch present in the shipped code, and the capability floor of
../capabilities.json (the same list verify_ffmpeg_capabilities.py checks by
running the desktop programs).

Capability evidence: every component name in capabilities.json must occur as a
NUL-delimited C string (b"\0name\0") in the library that registers it. The
AVCodec / AVOutputFormat / AVInputFormat / AVFilter / URLProtocol / bitstream
filter structs keep their short `name` even with --enable-small (only long
names are stripped), and a component that is not compiled in leaves no such
string (checked: libx265, libaom-av1, frei0r, zscale ... are absent from these
builds while every capability name is present).
"""
from __future__ import annotations

import io
import json
import pathlib
import re
import sys
import tarfile
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
LIBS = ("libavcodec", "libavdevice", "libavfilter", "libavformat",
        "libavutil", "libswresample", "libswscale")
ANDROID_ABIS = {"arm64-v8a", "armeabi-v7a", "x86_64"}

COMMON_FLAGS = ("--enable-gpl", "--enable-libx264", "--enable-libvpx",
                "--enable-libopus", "--enable-libdav1d", "--enable-libsvtav1",
                "--enable-libwebp", "--enable-openssl", "--enable-libxml2")
PLATFORM_FLAGS = {"android": ("--enable-mediacodec", "--enable-jni", "--enable-zlib"),
                  "ios": ("--enable-videotoolbox", "--enable-zlib")}
# (library, marker, meaning) - byte strings each Fushi patch leaves behind.
PATCH_MARKERS = (
    ("libavformat", b"tls_pin_sha256", "patch 0001 tls_pin_sha256 option"),
    ("libavutil", b"av_log_fushi_set_primary_callback", "patch 0002 primary log callback"),
    ("ffmpegkit", b"av_log_fushi_set_primary_callback", "kit patch: primary log callback"),
)
ANDROID_ONLY_MARKERS = (
    ("libavformat", b"Android system CA certificates", "patch 0001 Android CA loader"),
)
# Patch 0004: on Apple the OpenSSL backend verifies peers with the system trust
# store (Security.framework); OpenSSL's own default CA path is the CI machine's.
APPLE_ONLY_MARKERS = (
    ("libavformat", b"System trust rejected the certificate", "patch 0004 Apple system trust"),
    # LC_LOAD_DYLIB: .../Security.framework/Security (iOS) or
    # .../Security.framework/Versions/A/Security (macOS).
    ("libavformat", b"/System/Library/Frameworks/Security.framework/",
     "patch 0004: libavformat links Security.framework"),
)
# capabilities.json key -> library that registers that component class.
CAPABILITY_LIBS = {
    "encoders": "libavcodec", "decoders": "libavcodec", "bsfs": "libavcodec",
    "muxers": "libavformat", "demuxers": "libavformat", "protocols": "libavformat",
    "filters": "libavfilter",
}


def capabilities() -> dict:
    return json.loads((HERE.parent / "capabilities.json").read_text(encoding="utf-8"))


REQUIRE_STAGED = False
# tool/dvd: the shared libraries libmpv and libavformat both link (one copy).
DVD_LIBS = ("libdvdcss", "libdvdread", "libdvdnav")


def check_capabilities(label: str, blobs: dict[str, bytes], failures: list[str]) -> None:
    caps = capabilities()
    for key, lib in CAPABILITY_LIBS.items():
        for name in caps.get(key, []):
            if b"\0" + name.encode() + b"\0" not in blobs[lib]:
                failures.append(f"{label}: capability floor: {key[:-1]} {name!r} not in {lib}")
    if not REQUIRE_STAGED:
        return
    staged = caps["staged"]
    for key, lib in CAPABILITY_LIBS.items():
        for name in staged.get(key, []):
            if b"\0" + name.encode() + b"\0" not in blobs[lib]:
                failures.append(f"{label}: staged: {key[:-1]} {name!r} not in {lib}")
    conf = configuration(blobs["libavutil"])
    for flag in staged.get("configure", []):
        if flag not in conf:
            failures.append(f"{label}: staged configure flag {flag} missing")
    # Dynamic link to the shared DVD libraries (ELF DT_NEEDED "libdvdnav.so" or
    # Mach-O "@rpath/libdvdnav.framework/libdvdnav"), never a private copy.
    for dvd in ("libdvdnav", "libdvdread"):
        pattern = rb"\0(?:@rpath/)?" + dvd.encode() + rb"(?:\.so|\.framework/" + dvd.encode() + rb")\0"
        if not re.search(pattern, blobs["libavformat"]):
            failures.append(f"{label}: libavformat does not link the shared {dvd}")
    for dvd in DVD_LIBS:
        if dvd not in blobs:
            failures.append(f"{label}: {dvd} is not shipped next to libavformat")


def recipe_version() -> str:
    for line in (HERE.parent / "recipe.env").read_text(encoding="utf-8").splitlines():
        if line.startswith("FFMPEG_VERSION="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("recipe.env has no FFMPEG_VERSION")


def configuration(blob: bytes) -> str:
    m = re.search(rb"--(?:prefix|cross-prefix|arch|target-os)=[^\x00]{200,}", blob)
    return m.group().decode("latin-1") if m else ""


def check_lib_blobs(platform: str, label: str, blobs: dict[str, bytes], failures: list[str]) -> None:
    # Android ships libffmpegkit.so, Apple ffmpegkit.framework/ffmpegkit.
    if "libffmpegkit" in blobs:
        blobs = {**blobs, "ffmpegkit": blobs["libffmpegkit"]}
    missing = [lib for lib in LIBS + ("ffmpegkit",) if lib not in blobs]
    for lib in missing:
        failures.append(f"{label}: missing {lib}")
    if missing:
        return
    conf = configuration(blobs["libavutil"])
    if not conf:
        failures.append(f"{label}: no embedded configure line in libavutil")
    for flag in COMMON_FLAGS + PLATFORM_FLAGS[platform]:
        if flag not in conf:
            failures.append(f"{label}: configure lacks {flag}")
    if "--disable-everything" in conf:
        failures.append(f"{label}: built with --disable-everything (unified builds are full)")
    version = recipe_version().encode()
    if version not in blobs["libavutil"] and version not in blobs["libavcodec"]:
        failures.append(f"{label}: FFmpeg version {recipe_version()} not found in libavutil/libavcodec")
    markers = PATCH_MARKERS + (ANDROID_ONLY_MARKERS if platform == "android"
                               else APPLE_ONLY_MARKERS)
    for lib, marker, meaning in markers:
        if marker not in blobs[lib]:
            failures.append(f"{label}: {meaning} missing from {lib}")
    check_capabilities(label, blobs, failures)


def verify_android(out: pathlib.Path) -> list[str]:
    failures: list[str] = []
    aar = out / "ffmpeg-kit-next.aar"
    if not aar.is_file():
        return [f"missing {aar.name}"]
    with zipfile.ZipFile(aar) as z:
        names = z.namelist()
        abis = {n.split("/")[1] for n in names if n.startswith("jni/") and n.count("/") == 2}
        if abis != ANDROID_ABIS:
            failures.append(f"AAR ABIs {sorted(abis)} != {sorted(ANDROID_ABIS)}")
        if any("_neon" in n for n in names):
            failures.append("AAR still ships *_neon.so variants (libmpv links plain names)")
        for abi in sorted(abis & ANDROID_ABIS):
            blobs = {n.rsplit("/", 1)[1][:-3]: z.read(n) for n in names
                     if n.startswith(f"jni/{abi}/") and n.endswith(".so")}
            check_lib_blobs("android", f"aar/{abi}", blobs, failures)
    for abi in sorted(ANDROID_ABIS):
        dev = out / f"ffmpeg-dev-android-{abi}.tar.gz"
        if not dev.is_file():
            failures.append(f"missing {dev.name}")
            continue
        with tarfile.open(dev) as t:
            members = {m.name.lstrip("./") for m in t.getmembers()}
        for lib in LIBS:
            for need in (f"lib/{lib}.so", f"lib/pkgconfig/{lib}.pc", f"include/{lib}/version.h"):
                if need not in members:
                    failures.append(f"{dev.name}: missing {need}")
    return failures


def verify_ios(out: pathlib.Path) -> list[str]:
    failures: list[str] = []
    archive = out / "ffmpeg-kit-next-ios-xcframeworks.zip"
    if not archive.is_file():
        return [f"missing {archive.name}"]
    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        for fw in LIBS + ("ffmpegkit",):
            slices = {n.split("/")[1] for n in names
                      if n.startswith(f"{fw}.xcframework/") and n.count("/") >= 2
                      and n.split("/")[1].startswith("ios-")}
            if not any(s.startswith("ios-arm64") and "simulator" not in s for s in slices):
                failures.append(f"{fw}: no iOS device slice ({sorted(slices)})")
            if not any("simulator" in s for s in slices):
                failures.append(f"{fw}: no iOS simulator slice ({sorted(slices)})")
        device = {}
        for n in names:
            m = re.match(r"^(\w+)\.xcframework/ios-arm64[^/]*/\1\.framework/\1$", n)
            if m and "simulator" not in n:
                device[m.group(1)] = z.read(n)
        check_lib_blobs("ios", "ios-device", device, failures)
    return failures


def main() -> int:
    global REQUIRE_STAGED
    args = [a for a in sys.argv[1:] if a != "--require-staged"]
    REQUIRE_STAGED = len(args) != len(sys.argv) - 1
    if len(args) != 2 or args[0] not in ("android", "ios"):
        print(__doc__)
        return 2
    sys.argv[1:] = args
    out = pathlib.Path(sys.argv[2])
    failures = verify_android(out) if sys.argv[1] == "android" else verify_ios(out)
    if failures:
        print(f"unified FFmpeg {sys.argv[1]} artifacts FAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"unified FFmpeg {sys.argv[1]} artifacts OK ({recipe_version()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
