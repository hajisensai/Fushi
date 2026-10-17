# Windows Blu-ray menu runtime

The vendored native archive is built from mpv
`36abaa32d00a7229ee206aae12dc0e97e7962dca` (2026-10-08),
including upstream HDMV/BD-J navigation added on 2026-08-25. The previous
2026-08-13 binary had neither `discnav` nor `disc-menu`; updating Flutter alone
could not enable original menus.

Archive: `mpv-dev-x86_64-20261008-git-36abaa32d0-fushi-discnav1-hwcrop1-lua1-mkvlace1-mkvdts1-ffu1.7z` (46,022,880 bytes).
SHA-256: `aac249968e82b5d4d983be6faf29f47f73806502aa56dbf25c37f708747edc5c`.
The `fushi-discnav1-hwcrop1-lua1-mkvlace1-mkvdts1-ffu1` suffix identifies this patched build; it is not an
unmodified zhongfly release. Its DLL and dependency manifests are also tracked
beside this document for review without unpacking the binary.

`ffu1` (2026-10-17): built against the **unified FFmpeg** (`tool/ffmpeg-unified`,
FFmpeg 9.0.1 + Fushi patches, see `docs/specs/2026-10-17-unified-ffmpeg.md`)
instead of MSYS2's `mingw-w64-ffmpeg` package, and the archive also ships that
build's `ffmpeg.exe` / `ffprobe.exe`. They import the same renamed `fbd*.dll`
as `libmpv-2.dll` and are listed in `runtime-files.cmake`, so card mining runs
on exactly the FFmpeg the player decodes with (the separate
`third_party/ffmpeg-min/windows` build is gone). The closure shrank from 123 to
103 files: the unified configure mirrors MSYS2's minus whisper (ggml),
librsvg (glib/cairo/pango), frei0r, libcaca and openal.

`patches/mkv-laced-audio-timestamps.patch` (BUG-3499) fixes upstream
`handle_block()` in `demux/demux_mkv.c`: when an audio track has no
`DefaultDuration`, only the first frame of a laced block got a timestamp and
the others were left unset. mkvmerge laces Opus eight frames per block and
writes no `DefaultDuration`, so on such files the stream recorder
(`dump-cache`, used for the online-video mining snapshot) had every frame but
the first of each block rejected by the FFmpeg Matroska muxer
(`non monotonically increasing dts ... >= NOPTS` / `Failed writing packet`)
while still reporting success; the snapshot kept about 1/8 of the audio. The
patch derives the later lace frames' timestamps from their own durations:
Opus packets carry their length in the TOC byte (RFC 6716 section 3.1); for
other codecs a known `BlockDuration` is split evenly over the laces, as
FFmpeg's Matroska demuxer does; otherwise the old behaviour is kept. Block
first-frame timestamps are unchanged. Upstream master is still unfixed as of
2026-10-17.

`patches/recorder-video-dts.patch` (BUG-3500) fixes upstream
`common/recorder.c`: Matroska stores no DTS, and the recorder only set
`video_delay` (so libavformat would guess DTS) when the stream had no
`lav_codecpar` - but `demux_mkv` now attaches one to every video track. With
`video_delay` 0 libavformat used DTS = PTS, so every reordered frame of H.264
/ HEVC with B-frames was rejected and the `dump-cache` snapshot was mostly
undecodable (corrupted video in mined clips). Even with the delay set,
libavformat seeds its reorder buffer with the first packet's PTS, which
rejects the leading pictures of an open GOP, and that guessing is deprecated.
The recorder now derives the missing video DTS itself with the same reorder
buffer, seeded with the segment's output start. Upstream master is still
unfixed as of 2026-10-17.

This rebuild differs from the `lua1-mkvlace1` archive only in `libmpv-2.dll`,
`runtime-manifest.json` and `source-provenance.json` (which records both
patches under `demux_patches`); the other 234 files are byte-identical (same
MSYS2 package set). `verify_mkv_lace_dump.py` checks both fixes against the
real library (`tests/laced-opus.mkv`, `tests/open-gop-hevc.mkv`).

`patches/gpu-dumb-mode-hwdec-crop.patch` (BUG-3296) fixes upstream
`pass_render_frame_dumb()` in `video/out/gpu/video.c`: the vo=gpu "dumb mode"
(chosen automatically when every scaler is bilinear and linear/sigmoid/correct
scaling, deband and user shaders are all off - Fushi's "画质增强: 无") built the
source transform against the image size instead of the mapped plane size. With
d3d11va zero-copy the decoder surface is padded (1920x1088 for 1080p H.264,
1920x1152 for HEVC), so the padding rows were squashed into the picture. The
non-dumb path (`pass_read_video`) already used the plane size; the patch makes
the dumb path do the same. Software / copy-back frames are unaffected (plane
size equals image size). Upstream master is still unfixed as of 2026-10-13.

`patches/disc-navigation-state.patch` is the navigation change against that
upstream revision. It adds:

* `disc-navigation-state` (NODE_MAP) and `disc-navigation-state-json` (STRING),
  schema version 1. Both are obtained from the same snapshot implementation.
* Real `BD_EVENT_TITLE` / `BD_EVENT_PLAYLIST` identities, a navigation generation,
  presentation position, angle, native menu state and BD-J readiness. MPLS
  identifiers never come from edition-list indices or translated labels.
* A presentation gate: a new generation is not stable until the player's
  resync/restart completes. `position` is `get_current_time(mpctx)`, never the
  ahead-of-playback `bd_tell_time` read head.
* Separate graphics visibility and input ownership. BD-J PG subtitles remain
  visible but only IG graphics activate menu keyboard/mouse handling.
* Automatic audio/subtitle selection compares the actual active track with the
  disc's desired track, so handing `aid`/`sid` back to `auto` reapplies an
  unchanged disc selection after explicit Off/external/manual overrides.
  Explicit player selections remain authoritative until that handoff.
* `menu-call-allowed` follows libbluray's `BD_EVENT_UO_MASK_CHANGED` menu-call
  bit. Native menu/input failures propagate to the client instead of reporting
  success after a prohibited or unsupported command.
* `bluray-java-home`, passed to `BLURAY_PLAYER_JAVA_HOME` before opening the disc.
  This selects the private optional JRE without global environment mutation.
* A hard failure when requested BD-J menus lack a Java runtime; upstream's
  silent fallback to an unrelated longest title is deliberately removed.

`menu-domain` identifies top-menu, first-play and visible IG graphics. BD-J
applications may implement their own behavior inside a regular title, so this
is not a claim to infer every possible Xlet's semantic screen. `angle` is
zero-based, `-1` unknown; nonzero angles require matching export support.

## Build and package

First build the unified FFmpeg into a private prefix (MSYS2 MINGW64 shell):

    tool/ffmpeg-unified/windows/build_ffmpeg_msys2.sh <ffmpeg-work-dir>

then `tool/bluray/build_libmpv.ps1 -FfmpegWorkDirectory <ffmpeg-work-dir>`
checks out the pinned upstream revision, applies the patches and builds with
MSYS2 mingw64 against that prefix (it wins over MSYS2's own FFmpeg for both
pkg-config and the runtime closure; `package_libmpv.py` refuses a stray MSYS2
FFmpeg DLL and a source tree whose applied patches differ from the recipe). It
uses the existing vendored ANGLE headers and enables EGL/D3D11 interop. Native
compilation holds the repository's heavy-work lease.

The runtime uses the unified FFmpeg 9.0.1, libbluray 1.5.0 and libplacebo
7.360.1. Its `msys2-packages.json` records the exact MSYS2 dependency package
versions plus a `fushi-unified-ffmpeg` entry (version, upstream and patched
commit, SHA-256 of every applied patch).
`package_libmpv.py` follows PE imports recursively, fails on unresolved imports,
includes package licenses and records each DLL's size and SHA-256. This closure
includes the TrueHD decoder. Lua player scripts are built in with `-Dlua=luajit`
(MSYS2 LuaJIT, packaged as the private `fbd51.dll`). The earlier `discnav1`
builds used `-Dlua=disabled`, which silently broke user Lua scripts such as
subtitle-end pause (BUG-3325); the `lua1` suffix marks the rebuild. JavaScript
scripts remain disabled. Fushi's Flutter controls and C client/render APIs do
not depend on either.

The packager requires Python's `pefile` module. It gives all non-system
dependencies fixed, same-length `fbd` module names, preserving the public
`libmpv-2.dll` entry point; `ffmpeg.exe` / `ffprobe.exe` keep their names and
only their DLL references are rewritten. Normal imports, delay imports, export forwarders and
literal ANSI/UTF-16 dynamic-library names are rewritten without shifting PE
RVAs. It rejects name collisions and leftover original dependency references.
`private-dll-map.json`, the runtime source/new hashes and
`dynamic-dll-references.json` make that transformation reviewable. This prevents
the video player from overwriting the P2P client's OpenSSL or another renderer's
libplacebo, threading runtime or Vulkan loader. Optional externally resolved
modules, such as system GPU drivers, AACS and the configured JVM, stay explicit
in the dynamic-reference audit.

The archive includes `runtime-files.cmake`, so installation follows the verified
closure rather than globbing a potentially stale build folder. Extraction is
addressed by the archive hash and shared with media_kit_video through
`MEDIA_KIT_LIBMPV_SRC`. The private Vulkan loader has a distinct name; ANGLE's
existing public loader remains unchanged for existing consumers.

The two matching libbluray JARs sit beside `fbdbluray-4.dll`. The small optional
component bundle and its single-source installer are installed under
`<application>/bluray/bdj/`. See [bdj/README.md](bdj/README.md) for the pinned
private JRE, hashes, source and license details.

## Verification

* `tool/ffmpeg-unified/verify_ffmpeg_capabilities.py` runs the packaged
  `ffmpeg.exe` / `ffprobe.exe` with a system-only `PATH` (so only the renamed
  DLLs beside them can load) against the capability floor, and
  `tool/ffmpeg-unified/smoke-test.sh` exercises every mining / export / ASR /
  transcode argument shape with self-authored fixtures.
* `probe_libmpv.py` probes the loaded binary's options, command signatures,
  properties, Blu-ray protocol, TrueHD decoder and render API, and runs a real
  Lua script through `load-script` (it fails unless the script's own log line
  arrives; `mpv-configuration` or the command's return code alone is no proof).
* `test_probe_libmpv.py` checks dependency cycles/missing imports and, with
  `FUSHI_MPV_LIBRARY`, actual ABI and error propagation.
* `verify_menu_render.py` uses the shipped ANGLE and libmpv OpenGL render API
  offscreen. It records native snapshots, logs and rendered PNGs from a readable
  original disc; it does not substitute a title-list UI for disc graphics.
* `test_bdj_runtime.py` checks the pinned artifacts, private JVM and optionally
  real libbluray JNI/AWT startup with a generated unencrypted BD-J fixture.

These tests do not assert that encrypted discs become readable, that every
commercial BD-J application works, or that another platform's binary has the
same capabilities. Platform support is detected from the loaded library.
