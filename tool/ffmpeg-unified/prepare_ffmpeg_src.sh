#!/usr/bin/env bash
# Materialise the unified FFmpeg source tree: clone the pinned tag, verify the
# commit, and apply every patch under patches/ffmpeg/ as real commits.
#
# The patches are COMMITTED (git am), not left in the working tree, because
# FFmpegKitNext's build scripts `git checkout libavutil libavformat/...` before
# configuring and would silently revert uncommitted edits.
#
# Usage: prepare_ffmpeg_src.sh <dest-dir>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=recipe.env
source "${HERE}/recipe.env"

DEST="${1:?usage: prepare_ffmpeg_src.sh <dest-dir>}"

if [ -e "${DEST}" ] && [ -n "$(ls -A "${DEST}" 2>/dev/null)" ]; then
  echo "prepare_ffmpeg_src: ${DEST} exists and is not empty" >&2
  exit 2
fi

git clone --quiet --depth 1 --branch "${FFMPEG_TAG}" "${FFMPEG_REPO}" "${DEST}"
actual="$(git -C "${DEST}" rev-parse HEAD)"
if [ "${actual}" != "${FFMPEG_COMMIT}" ]; then
  echo "prepare_ffmpeg_src: ${FFMPEG_TAG} resolved to ${actual}, expected ${FFMPEG_COMMIT}" >&2
  exit 3
fi

git -C "${DEST}" -c user.name=fushi -c user.email=fushi@localhost \
  am --quiet --keep-cr "${HERE}"/patches/ffmpeg/*.patch

# Fail loudly if a patch silently stopped applying its payload.
grep -q 'tls_pin_sha256' "${DEST}/libavformat/tls.h" ||
  { echo "PATCH MISSING: tls_pin_sha256 option" >&2; exit 4; }
grep -q 'openssl_load_android_system_cas' "${DEST}/libavformat/tls_openssl.c" ||
  { echo "PATCH MISSING: Android system CA loader" >&2; exit 4; }
grep -q 'av_log_fushi_set_primary_callback' "${DEST}/libavutil/log.c" ||
  { echo "PATCH MISSING: primary/secondary log callback" >&2; exit 4; }
grep -q 'iOS GLES has no 10-bit' "${DEST}/libavcodec/videotoolbox.c" ||
  { echo "PATCH MISSING: iOS 10-bit VideoToolbox -> BGRA" >&2; exit 4; }

echo "prepare_ffmpeg_src: ${FFMPEG_TAG} (${FFMPEG_COMMIT}) + $(ls "${HERE}"/patches/ffmpeg/*.patch | wc -l) patches -> ${DEST}"
