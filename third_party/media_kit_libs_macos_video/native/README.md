# macOS libmpv Blu-ray framework bundle

This is the verified full-video build from [Darwin PR #2](https://github.com/hajisensai/libmpv-darwin-build/pull/2),
rebuilt on branch `fushi/mkv-lace` with `mkv-laced-audio-timestamps.patch` (BUG-3499: laced Matroska
audio without DefaultDuration, e.g. mkvmerge Opus, lost every lace frame after the first in dump-cache)
and `recorder-video-dts.patch` (BUG-3500: Matroska video has no DTS, so dump-cache lost every B-frame).
The exact source commit, Actions run, archive checksum, inspection and arm64 runtime probe
are recorded in `provenance.json`. All frameworks are arm64-only (Fushi ships Apple Silicon only).
The bundle includes libbluray HDMV navigation and the retained Dolby Vision profile 5 GL patch.
It contains **no FFmpeg**: `Mpv.framework` links `@rpath/libav*.framework` from the unified FFmpeg
(`ffmpeg-unified-macos.tar.gz` beside this file, built from `tool/ffmpeg-unified`), the same frameworks
the bundled `ffmpeg` / `ffprobe` programs use for card mining. No Java runtime/BD-J jar is included.
Original-disc menu rendering and Dolby Vision appearance have not been tested on a Mac.

Rebuild with `tool/bluray/platforms/build_darwin.sh` from the repository root and
verify with `tool/bluray/platforms/verify_darwin_archive.py --platform macos` before replacing this archive.
The package Makefile verifies the SHA-256 before extraction and supports an explicit
`FUSHI_LIBMPV_DARWIN_ARCHIVE` / `FUSHI_LIBMPV_DARWIN_SHA256` development override.
