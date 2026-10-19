#!/usr/bin/env bash
# Build the unified FFmpeg for Android with FFmpegKitNext and stage:
#   <out>/ffmpeg-kit-next.aar           the in-process command runner + FFmpeg .so
#   <out>/ffmpeg-dev-android-<abi>.tar.gz  headers + .so + .pc per ABI, which the
#                                          libmpv build links (shared, not static)
#
# Requires ANDROID_SDK_ROOT and ANDROID_NDK_ROOT (NDK r27d, 27.3.13750724).
# Usage: build_android.sh <work-dir> <out-dir>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit_options.sh
source "${HERE}/kit_options.sh"

WORK="${1:?usage: build_android.sh <work-dir> <out-dir>}"
OUT="${2:?usage: build_android.sh <work-dir> <out-dir>}"
: "${ANDROID_SDK_ROOT:?ANDROID_SDK_ROOT must be set}"
: "${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT must be set}"

mkdir -p "${WORK}" "${OUT}"
KIT="${WORK}/ffmpeg-kit-next"
bash "${HERE}/prepare_kit.sh" "${KIT}"

cd "${KIT}"
if ! ./android.sh "${KIT_COMMON_OPTIONS[@]}" "${KIT_ANDROID_OPTIONS[@]}"; then
  tail -200 build.log || true
  exit 1
fi

aar="$(find prebuilt -path '*bundle-android-aar*' -name 'ffmpeg-kit-next-*.aar' | head -1)"
[ -n "${aar}" ] || { echo "build_android: no AAR produced" >&2; exit 5; }
cp "${aar}" "${OUT}/ffmpeg-kit-next.aar"

# Per-ABI development prefixes for libmpv. FFmpegKitNext's per-arch install
# lives at prebuilt/android-<arch>-<api>/ffmpeg/{include,lib}; pkgconfig sits
# next to it.
for dir in prebuilt/android-*-24; do
  [ -d "${dir}/ffmpeg" ] || continue
  arch="$(basename "${dir}" | sed -E 's/^android-(.*)-24$/\1/')"
  case "${arch}" in
    arm64) abi=arm64-v8a ;;
    arm) abi=armeabi-v7a ;;
    x86_64) abi=x86_64 ;;
    *) echo "build_android: unexpected arch dir ${dir}" >&2; exit 6 ;;
  esac
  stage="${WORK}/dev-${abi}"
  rm -rf "${stage}"; mkdir -p "${stage}"
  cp -a "${dir}/ffmpeg/include" "${stage}/include"
  mkdir -p "${stage}/lib/pkgconfig"
  cp -a "${dir}"/ffmpeg/lib/*.so "${stage}/lib/"
  # FFmpeg's own .pc files (install prefix); libmpv's build rewrites their
  # prefix and drops the static-link closure (scripts/unified_ffmpeg.sh).
  cp -a "${dir}"/ffmpeg/lib/pkgconfig/lib*.pc "${stage}/lib/pkgconfig/"
  tar -C "${stage}" -czf "${OUT}/ffmpeg-dev-android-${abi}.tar.gz" .
  echo "build_android: staged ${abi} from ${dir}"
done

ls -la "${OUT}"
