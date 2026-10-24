#!/usr/bin/env bash
# Apply the Fushi DVD changes to a LOCAL checkout of a libmpv fork. Nothing is
# committed, pushed or dispatched: that needs the owner's approval
# (tool/dvd/forks/README.md).
#
# Usage: apply.sh android <checkout of hajisensai/libmpv-android-video-build @ fushi/unified-ffmpeg>
#        apply.sh darwin  <checkout of hajisensai/libmpv-darwin-build @ fushi/unified-ffmpeg>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
KIND="${1:?usage: apply.sh android|darwin <fork-checkout>}"
FORK="$(cd "${2:?usage: apply.sh android|darwin <fork-checkout>}" && pwd)"
NAV="${ROOT}/third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch"

case "${KIND}" in
  android)
    patch -d "${FORK}" -p1 --forward < "${HERE}/libmpv-android-video-build.patch"
    # The fork keeps its own copy of the navigation patch; v2 adds dvd-state.
    cp "${NAV}" "${FORK}/buildscripts/patches/mpv/disc-navigation-state.patch"
    ;;
  darwin)
    patch -d "${FORK}" -p1 --forward < "${HERE}/libmpv-darwin-build.patch"
    cp "${NAV}" "${FORK}/patches/disc-navigation-state.patch"
    ;;
  *) echo "apply.sh: android or darwin" >&2; exit 2 ;;
esac
echo "apply.sh: ${KIND} fork prepared in ${FORK} (not committed)."
echo "Next (owner approval required): point the unified FFmpeg lock at the new"
echo "ffmpeg-unified-mobile.yml artifacts, commit, push, run the fork's workflow."
