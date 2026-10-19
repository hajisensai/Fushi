#!/usr/bin/env bash
# Build the unified FFmpeg for iOS with FFmpegKitNext and stage:
#   <out>/ffmpeg-kit-next-ios-xcframeworks.zip  ffmpegkit + libav*/libsw* xcframeworks
#
# libmpv (libmpv-darwin-build) links the libav*/libsw* xcframeworks from this
# same zip, so the player and the in-process command runner share one FFmpeg.
# Requires macOS with Xcode 26+.
# Usage: build_ios.sh <work-dir> <out-dir>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit_options.sh
source "${HERE}/kit_options.sh"

WORK="${1:?usage: build_ios.sh <work-dir> <out-dir>}"
OUT="${2:?usage: build_ios.sh <work-dir> <out-dir>}"
mkdir -p "${WORK}" "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
KIT="${WORK}/ffmpeg-kit-next"
bash "${HERE}/prepare_kit.sh" "${KIT}"

cd "${KIT}"
if ! ./ios.sh "${KIT_COMMON_OPTIONS[@]}" "${KIT_IOS_OPTIONS[@]}"; then
  tail -200 build.log || true
  exit 1
fi

bundle="$(find prebuilt -maxdepth 1 -type d -name 'bundle-apple-xcframework-ios*' | head -1)"
[ -n "${bundle}" ] || { echo "build_ios: no xcframework bundle produced" >&2; exit 5; }
(cd "${bundle}" && zip -qry "${OUT}/ffmpeg-kit-next-ios-xcframeworks.zip" ./*.xcframework)
ls -la "${OUT}"
