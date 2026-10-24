# iOS libmpv Blu-ray framework bundle

This is the verified full-video build from [Darwin PR #2](https://github.com/hajisensai/libmpv-darwin-build/pull/2),
rebuilt on branch `fushi/mkv-lace` with `mkv-laced-audio-timestamps.patch` (BUG-3499: laced Matroska
audio without DefaultDuration, e.g. mkvmerge Opus, lost every lace frame after the first in dump-cache)
and `recorder-video-dts.patch` (BUG-3500: Matroska video has no DTS, so dump-cache lost every B-frame).
The exact source commit, Actions run, archive checksum and inspection results are recorded in `provenance.json`.
It contains iOS arm64 and arm64/x86_64 simulator slices, libbluray HDMV navigation and the
retained Dolby Vision profile 5 GL patch. It contains **no FFmpeg**: `Mpv.framework` links
`@rpath/libav*.framework` shipped by `third_party/ffmpeg_kit_next_flutter` (the unified FFmpeg of
`tool/ffmpeg-unified`), so playback and card mining load one libavcodec in the process.
No Java runtime/BD-J jar is included. Device menu rendering has not been tested.

**DVD menus (2026-10-24):** rebuilt from branch `fushi/dvd` `95d986e` (private CI mirror
`hajisensai/libmpv-darwin-build-fushi`, run 40067864441; fork patch `tool/dvd/forks/libmpv-darwin-build.patch`)
with `-Dgpl=true -Ddvdnav=enabled` (mpv's `stream_dvdnav` is GPL-only, so this libmpv is GPL-2.0-or-later).
`Mpv.framework` links `@rpath/libdvdnav.framework/libdvdnav` — `third_party/ffmpeg_kit_next_flutter`'s `libdvdnav.xcframework`, the same copy
FFmpeg's `dvdvideo` demuxer uses — and packages no DVD library of its own; it carries the v2
navigation snapshot (`dvd-state`). DVD menu playback has not been tested on a device.

Rebuild with `tool/bluray/platforms/build_darwin.sh` from the repository root and
verify with `tool/bluray/platforms/verify_darwin_archive.py --platform ios` before replacing this archive.
The package Makefile verifies the SHA-256 before extraction and supports an explicit
`FUSHI_LIBMPV_DARWIN_ARCHIVE` / `FUSHI_LIBMPV_DARWIN_SHA256` development override.
