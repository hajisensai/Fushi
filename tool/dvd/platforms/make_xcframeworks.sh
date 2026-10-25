#!/usr/bin/env bash
# Assemble libdvd{css,read,nav}.xcframework from build_cross.sh prefixes, the
# same shape as FFmpegKitNext's libav*.xcframework (the app embeds them next to
# each other; libavformat and Mpv load them as @rpath/<lib>.framework/<lib>).
#
# Usage: make_xcframeworks.sh ios|macos <dvd-work-dir> <out-dir>
#   ios:   needs <work>/ios-arm64, ios-simulator-arm64, ios-simulator-x86_64
#          (the simulator slice is one fat arm64 + x86_64 framework)
#   macos: needs <work>/macos-arm64 (Fushi ships Apple Silicon only)
set -euo pipefail

PLATFORM="${1:?usage: make_xcframeworks.sh ios|macos <dvd-work-dir> <out-dir>}"
WORK="$(cd "${2:?usage}" && pwd)"
OUT="${3:?usage}"
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"

for name in libdvdcss libdvdread libdvdnav; do
  rm -rf "${OUT}/${name}.xcframework"
  case "${PLATFORM}" in
    ios)
      sim="${WORK}/xcframework-sim/${name}.framework"
      rm -rf "${sim}"; mkdir -p "$(dirname "${sim}")"
      cp -R "${WORK}/ios-simulator-arm64/frameworks/${name}.framework" "${sim}"
      lipo -create \
        "${WORK}/ios-simulator-arm64/frameworks/${name}.framework/${name}" \
        "${WORK}/ios-simulator-x86_64/frameworks/${name}.framework/${name}" \
        -output "${sim}/${name}"
      xcodebuild -create-xcframework \
        -framework "${WORK}/ios-arm64/frameworks/${name}.framework" \
        -framework "${sim}" \
        -output "${OUT}/${name}.xcframework"
      ;;
    macos)
      xcodebuild -create-xcframework \
        -framework "${WORK}/macos-arm64/frameworks/${name}.framework" \
        -output "${OUT}/${name}.xcframework"
      ;;
    *) echo "make_xcframeworks: platform must be ios or macos" >&2; exit 2 ;;
  esac
done
ls -d "${OUT}"/libdvd*.xcframework
