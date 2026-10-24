#!/usr/bin/env bash
# Prepare an FFmpegKitNext checkout that builds the unified FFmpeg:
#   1. clone the pinned FFmpegKitNext tag and verify its commit,
#   2. apply patches/ffmpeg-kit-next/*.patch (log callback sharing with libmpv),
#   3. pre-seed <kit>/src/ffmpeg with the patched unified FFmpeg source.
#
# FFmpegKitNext skips its own FFmpeg download when src/ffmpeg is non-empty, and
# `git checkout`s parts of it before configuring; prepare_ffmpeg_src.sh commits
# the patches, so that checkout keeps them.
#
# Usage: prepare_kit.sh <kit-dir>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=../recipe.env
source "${ROOT}/recipe.env"

KIT="${1:?usage: prepare_kit.sh <kit-dir>}"

git clone --quiet --depth 1 --branch "${FFMPEG_KIT_NEXT_TAG}" "${FFMPEG_KIT_NEXT_REPO}" "${KIT}"
actual="$(git -C "${KIT}" rev-parse HEAD)"
if [ "${actual}" != "${FFMPEG_KIT_NEXT_COMMIT}" ]; then
  echo "prepare_kit: ${FFMPEG_KIT_NEXT_TAG} resolved to ${actual}, expected ${FFMPEG_KIT_NEXT_COMMIT}" >&2
  exit 3
fi
git -C "${KIT}" -c user.name=fushi -c user.email=fushi@localhost \
  am --quiet "${ROOT}"/patches/ffmpeg-kit-next/*.patch

# GPL corresponding-source notice: every platform script copies
# tools/source/SOURCE into the build (AAR res/raw/source.txt, ffmpegkit.framework
# SOURCE). The stock text only points at the upstream wiki, which lacks Fushi's
# patches; replace it with one naming the exact recipe commit.
python3 "${ROOT}/source_notice.py" > "${KIT}/tools/source/SOURCE"
grep -q 'tool/ffmpeg-unified' "${KIT}/tools/source/SOURCE" ||
  { echo "prepare_kit: source notice not written" >&2; exit 4; }

mkdir -p "${KIT}/src"
bash "${ROOT}/prepare_ffmpeg_src.sh" "${KIT}/src/ffmpeg"

for f in android/ffmpeg-kit-next-android-lib/src/main/cpp/ffmpegkit.c apple/src/FFmpegKitConfig.m; do
  grep -q 'av_log_fushi_set_primary_callback' "${KIT}/${f}" ||
    { echo "PATCH MISSING: primary log callback in ${f}" >&2; exit 4; }
done
# Kit patch 0001 hands every log line of a thread with globalSessionId == 0 to
# libmpv. That is only correct because FFmpegKitNext copies the session id into
# each fftools scheduler worker (demux / decode / filtergraph / encode / mux
# threads, task_start() -> saveFFmpegContext()/loadFFmpegContext()); without
# that, a session's filter output (astats, loudnorm, ametadata) would be routed
# to libmpv instead of the session. Fail the build if upstream drops it.
for f in android/ffmpeg-kit-next-android-lib/src/main/cpp/ffmpeg_context.c apple/src/ffmpeg_context.c; do
  grep -q 'context->globalSessionId = globalSessionId' "${KIT}/${f}" &&
    grep -q 'globalSessionId = context->globalSessionId' "${KIT}/${f}" ||
    { echo "UPSTREAM CHANGED: ${f} no longer propagates globalSessionId to scheduler threads" >&2; exit 4; }
done
for f in android/ffmpeg-kit-next-android-lib/src/main/cpp/fftools/ffmpeg_sched.c apple/src/fftools/ffmpeg_sched.c; do
  grep -q 'saveFFmpegContext(task)' "${KIT}/${f}" ||
    { echo "UPSTREAM CHANGED: ${f} spawns scheduler threads without saveFFmpegContext" >&2; exit 4; }
done
grep -q 'FUSHI_FFMPEG_PROGRAMS' "${KIT}/scripts/apple/ffmpeg.sh" ||
  { echo "PATCH MISSING: macOS ffmpeg/ffprobe programs" >&2; exit 4; }
for f in scripts/android/ffmpeg.sh scripts/apple/ffmpeg.sh android/jni/Android.mk android/jni/ffmpeg/Android.mk; do
  grep -q -e 'FUSHI_DVD_ROOT' -e 'libdvdnav' "${KIT}/${f}" ||
    { echo "PATCH MISSING: shared DVD libraries in ${f} (kit patch 0003)" >&2; exit 4; }
done
echo "prepare_kit: FFmpegKitNext ${FFMPEG_KIT_NEXT_TAG} + unified FFmpeg ${FFMPEG_VERSION} -> ${KIT}"
