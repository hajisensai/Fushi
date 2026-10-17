#!/usr/bin/env bash
# Build the unified FFmpeg for macOS (arm64) with FFmpegKitNext and stage:
#   <out>/ffmpeg-unified-macos.tar.gz  containing
#       Frameworks/libav*.framework, libsw*.framework  (what libmpv links)
#       MacOS/ffmpeg, MacOS/ffprobe                    (what card mining runs)
# laid out exactly as inside fushi.app/Contents, so the programs' rpath
# (@executable_path/../Frameworks) resolves to the player's frameworks.
# Requires macOS with Xcode 26+.
# Usage: build_macos.sh <work-dir> <out-dir>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit_options.sh
source "${HERE}/kit_options.sh"

WORK="${1:?usage: build_macos.sh <work-dir> <out-dir>}"
OUT="${2:?usage: build_macos.sh <work-dir> <out-dir>}"
mkdir -p "${WORK}" "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
KIT="${WORK}/ffmpeg-kit-next"
bash "${HERE}/prepare_kit.sh" "${KIT}"

cd "${KIT}"
if ! FUSHI_FFMPEG_PROGRAMS=1 ./macos.sh "${KIT_COMMON_OPTIONS[@]}" "${KIT_MACOS_OPTIONS[@]}"; then
  tail -200 build.log || true
  exit 1
fi

bundle="$(find prebuilt -maxdepth 1 -type d -name 'bundle-apple-xcframework-macos*' | head -1)"
[ -n "${bundle}" ] || { echo "build_macos: no xcframework bundle produced" >&2; exit 5; }

layout="${WORK}/layout"
rm -rf "${layout}"; mkdir -p "${layout}/Frameworks" "${layout}/MacOS"
for xcf in "${bundle}"/lib*.xcframework; do
  slice="$(find "${xcf}" -mindepth 1 -maxdepth 1 -type d -name 'macos-*' | head -1)"
  [ -n "${slice}" ] || { echo "build_macos: ${xcf} has no macOS slice" >&2; exit 5; }
  cp -a "${slice}"/*.framework "${layout}/Frameworks/"
done

for prog in ffmpeg ffprobe; do
  src="$(find prebuilt -path "*/ffmpeg/bin/${prog}" -type f | head -1)"
  [ -n "${src}" ] || { echo "build_macos: ${prog} program not built (FUSHI_FFMPEG_PROGRAMS)" >&2; exit 5; }
  cp "${src}" "${layout}/MacOS/${prog}"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "${layout}/MacOS/${prog}"
  # Every FFmpeg dependency must be an @rpath framework reference, never a
  # build-machine path.
  if otool -L "${layout}/MacOS/${prog}" | grep -E 'lib(av|sw)[a-z]+' | grep -v '@rpath/lib'; then
    echo "build_macos: ${prog} links FFmpeg outside @rpath" >&2; exit 6
  fi
  codesign --force --sign - "${layout}/MacOS/${prog}"
done
for fw in "${layout}"/Frameworks/*.framework; do
  codesign --force --sign - "${fw}"
done

# Prove the shipped layout is closed: run the programs from it.
python3 "${HERE}/../verify_ffmpeg_capabilities.py" \
  --ffmpeg "${layout}/MacOS/ffmpeg" --ffprobe "${layout}/MacOS/ffprobe"
FFMPEG="${layout}/MacOS/ffmpeg" FFPROBE="${layout}/MacOS/ffprobe" \
  bash "${HERE}/../smoke-test.sh"

tar -C "${layout}" -czf "${OUT}/ffmpeg-unified-macos.tar.gz" Frameworks MacOS
(cd "${bundle}" && zip -qry "${OUT}/ffmpeg-kit-next-macos-xcframeworks.zip" ./lib*.xcframework)
ls -la "${OUT}"
