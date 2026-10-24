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

**DVD menus (2026-10-24):** rebuilt from branch `fushi/dvd` `95d986e` (private CI mirror
`hajisensai/libmpv-darwin-build-fushi`, run 40067864441; fork patch `tool/dvd/forks/libmpv-darwin-build.patch`)
with `-Dgpl=true -Ddvdnav=enabled` (mpv's `stream_dvdnav` is GPL-only, so this libmpv is GPL-2.0-or-later).
`Mpv.framework` links `@rpath/libdvdnav.framework/libdvdnav` — `Frameworks/libdvdnav.framework` of `ffmpeg-unified-macos.tar.gz`, the same copy
FFmpeg's `dvdvideo` demuxer uses — and packages no DVD library of its own; it carries the v2
navigation snapshot (`dvd-state`). DVD menu playback has not been tested on a device.

**Remote disc access (2026-10-24, `rdisc1`):** rebuilt from branch `fushi/rdisc` `568c907`
(private CI mirror `hajisensai/libmpv-darwin-build-fushi`, run 40085846799) with the updated
`disc-navigation-state.patch` (sha256 `5edcd0de...`): `bluray-device` / `dvd-device` accept
`http(s)://` URLs of a paired host's disc share, and `Mpv` carries the read-only property
`disc-remote-access` (`verify_darwin_archive.py` requires it). Remote playback has not been tested on a device.

**Audio CD (2026-10-25, `cdda1`):** rebuilt from branch `fushi/cdda` `07d6afd` (private CI mirror
`hajisensai/libmpv-darwin-build-fushi`, run 40132136924) with `-Dcdda=enabled` and the sixth mpv patch
`cdda-seek-sector-offset.patch` (stream_cdda's seek kept only the sector and dropped the byte offset
inside it). libcdio 2.3.0 and libcdio-paranoia 10.2+2.0.2 (GPL-3.0-or-later) are built in the fork and
ship as `Cdio` / `Cdio_cdda` / `Cdio_paranoia` frameworks linking the system `/usr/lib/libiconv.2.dylib`,
IOKit and DiskArbitration; `Mpv` links `@rpath/Cdio_paranoia.framework` and carries the patch's
`Seek to sector %d, byte %d within the sector.` string (`verify_darwin_archive.py` requires both on
macOS). The Makefile cache key moved to `unified-07d6afd9f8c2` so existing build trees re-extract.
Audio CD playback has not been tested on a Mac. iOS is unchanged (`-Dcdda=disabled`; its rebuild from
the same commit differed only in build paths and the configure string, so the vendored iOS archive
was kept).

Rebuild with `tool/bluray/platforms/build_darwin.sh` from the repository root and
verify with `tool/bluray/platforms/verify_darwin_archive.py --platform macos` before replacing this archive.
The package Makefile verifies the SHA-256 before extraction and supports an explicit
`FUSHI_LIBMPV_DARWIN_ARCHIVE` / `FUSHI_LIBMPV_DARWIN_SHA256` development override.
