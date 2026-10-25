#!/usr/bin/env bash
# Apply the Fushi remote-disc change (disc-navigation-state.patch with remote
# disc access, `rdisc1`) to a LOCAL checkout of a libmpv fork that already
# carries the DVD change (branch fushi/dvd, tool/dvd/forks/README.md).
# Nothing is committed, pushed or dispatched: that needs the owner's approval
# (tool/bluray/forks/README.md).
#
# Usage: apply.sh android <checkout of hajisensai/libmpv-android-video-build @ fushi/dvd>
#        apply.sh darwin  <checkout of hajisensai/libmpv-darwin-build @ fushi/dvd>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
KIND="${1:?usage: apply.sh android|darwin <fork-checkout>}"
FORK="$(cd "${2:?usage: apply.sh android|darwin <fork-checkout>}" && pwd)"
NAV="${ROOT}/third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch"

case "${KIND}" in
  android)
    patch -d "${FORK}" -p1 --forward < "${HERE}/libmpv-android-video-build.patch"
    cp "${NAV}" "${FORK}/buildscripts/patches/mpv/disc-navigation-state.patch"
    ;;
  darwin)
    # The Darwin archive is verified in this repo (verify_darwin_archive.py
    # requires the disc-remote-access marker); the fork only needs the patch.
    cp "${NAV}" "${FORK}/patches/disc-navigation-state.patch"
    # Audio CD (tool/cdda, macOS only): mk-pkg-mpv/video.nix on the fork's
    # fushi/cdda branch applies this last and builds -Dcdda=enabled on macOS.
    cp "${ROOT}/third_party/media_kit_libs_windows_video/patches/cdda-seek-sector-offset.patch" \
      "${FORK}/patches/mpv-cdda-seek-sector-offset.patch"
    ;;
  *) echo "apply.sh: android or darwin" >&2; exit 2 ;;
esac
echo "apply.sh: ${KIND} fork prepared in ${FORK} (not committed)."
echo "Next (owner approval required): commit on a new fork branch, push it to"
echo "the private mirror, run the mirror's workflow, then re-vendor the artifact."
