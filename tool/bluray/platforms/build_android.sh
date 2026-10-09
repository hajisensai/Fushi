#!/usr/bin/env bash
# Build navigation-capable Android jars locally; this does not publish assets.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: ANDROID_HOME=/sdk ANDROID_NDK_HOME=/ndk $0 NEW_BUILD_DIRECTORY [arm64|armv7l|x86|x86_64]" >&2
    exit 2
fi
case "$(uname -s)" in
    Linux|Darwin) ;;
    *) echo "The full FFmpeg/autotools build requires Linux or macOS with an Android NDK." >&2; exit 2 ;;
esac
for cmd in git meson ninja autoconf automake libtoolize pkg-config make nasm wget unzip zip python3; do
    command -v "$cmd" >/dev/null || { echo "Missing build dependency: $cmd" >&2; exit 2; }
done
python3 -c 'import mesonbuild, jsonschema, jinja2' || {
    echo "Python build modules required: meson, jsonschema (Mbed TLS), jinja2 (shader generation)." >&2
    exit 2
}
: "${ANDROID_HOME:?Set ANDROID_HOME to an existing Android SDK}"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to an existing Android NDK}"
sdk=$(cd "$ANDROID_HOME" && pwd)
export ANDROID_NDK_HOME=$(cd "$ANDROID_NDK_HOME" && pwd)
aaudio_header=$(echo "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/include/aaudio/AAudio.h)
if ! grep -q AAUDIO_FORMAT_IEC61937 "$aaudio_header"; then
    echo "The NDK lacks current AAudio headers; the verified build uses NDK 27.3.13750724." >&2
    exit 2
fi
if [[ -e "$1" ]]; then
    echo "Use a new build directory; existing source/build files will not be reset: $1" >&2
    exit 2
fi
mkdir -p "$1"
work=$(cd "$1" && pwd)
base=fe04fa1102a510a4dacd66c85dbe05b774826d1b
git -c core.autocrlf=false clone https://github.com/hajisensai/libmpv-android-video-build.git "$work/source"
git -C "$work/source" checkout --detach "$base"
git -C "$work/source" apply --check "$root/tool/bluray/platforms/patches/android-build.patch"
git -C "$work/source" apply "$root/tool/bluray/platforms/patches/android-build.patch"
cp "$root/tool/bluray/platforms/patches/mpv-gl-dovi-p5.patch" "$work/source/buildscripts/patches/mpv/mpv_gl_dovi_p5.patch"
cp "$root/third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch" "$work/source/buildscripts/patches/mpv/disc-navigation-state.patch"
cd "$work/source/buildscripts"
mkdir -p sdk
os=linux
[[ "$(uname -s)" == Darwin ]] && os=mac
ln -s "$sdk" "sdk/android-sdk-$os"
chmod +x include/*.sh scripts/*.sh
bash -e include/download-deps.sh
bash -e patch.sh
cp flavors/full.sh scripts/ffmpeg.sh
chmod +x scripts/ffmpeg.sh
build_args=()
[[ $# -eq 2 ]] && build_args=(--arch "$2")
bash -e build.sh "${build_args[@]}"

# Preserve the same verified JNI helper as the artifact-only cloud build.
mkdir -p "$work/artifacts"
for prefix in prefix/*; do
    abi=${prefix##*/}
    lib="$prefix/lib/libmpv.so"
    [[ -f "$lib" ]] || continue
    llvm_bin=$(echo "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin)
    "$llvm_bin/llvm-nm" -D "$lib" > "$work/artifacts/$abi.symbols.txt"
    grep -q ' T mpv_lavc_set_java_vm$' "$work/artifacts/$abi.symbols.txt"
    "$llvm_bin/llvm-strings" "$lib" > "$work/artifacts/$abi.strings.txt"
    grep -q '^disc-navigation-state-json$' "$work/artifacts/$abi.strings.txt"
    grep -q '^discnav$' "$work/artifacts/$abi.strings.txt"
    mkdir -p "$work/package-$abi/lib/$abi"
    python3 - "$root/third_party/media_kit_libs_android_video/android/native/bluray-menu-v1" "$abi" "$work/package-$abi" <<'PY'
import hashlib, json, pathlib, sys, zipfile
source, abi, output = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
jar = source / f'full-{abi}.jar'
expected = json.loads((source / 'sha256.json').read_text())[jar.name]
if hashlib.sha256(jar.read_bytes()).hexdigest() != expected:
    raise SystemExit(f'JNI helper source checksum mismatch: {jar}')
entry = f'lib/{abi}/libmediakitandroidhelper.so'
with zipfile.ZipFile(jar) as archive:
    (output / entry).write_bytes(archive.read(entry))
PY
    cp "$lib" "$work/package-$abi/lib/$abi/libmpv.so"
    "$llvm_bin/llvm-strip" --strip-unneeded "$work/package-$abi/lib/$abi/libmpv.so"
    (cd "$work/package-$abi" && zip -qr "$work/artifacts/full-$abi.jar" lib)
done
python3 - "$work/artifacts" <<'PY'
import hashlib, json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.glob('full-*.jar')}
if not files:
    raise SystemExit('No Android jars were built')
(directory / 'sha256.json').write_text(json.dumps(files, indent=2) + '\n')
PY
echo "Artifacts: $work/artifacts"
echo "After all four ABIs pass device checks, build Fushi with FUSHI_LIBMPV_ANDROID_DIR=$work/artifacts"
