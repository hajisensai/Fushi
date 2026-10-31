# Windows Blu-ray menu runtime

The vendored native archive is built from mpv
`36abaa32d00a7229ee206aae12dc0e97e7962dca` (2026-10-08),
including upstream HDMV/BD-J navigation added on 2026-08-25. The previous
2026-08-13 binary had neither `discnav` nor `disc-menu`; updating Flutter alone
could not enable original menus.

Archive: `mpv-dev-x86_64-20261008-git-36abaa32d0-fushi-discnav2-hwcrop1-lua1-mkvlace1-mkvdts1-dovi1-ffu2-dvd1-rdisc1-cdda1.7z` (40,729,854 bytes).
SHA-256: `2407c208d6e00dbb876faeb2c5a6b1731dc85844393e7b7dc3066ae35c6ca31f`.
The `fushi-discnav2-hwcrop1-lua1-mkvlace1-mkvdts1-dovi1-ffu2-dvd1-rdisc1-cdda1` suffix identifies this patched build; it is not an
unmodified zhongfly release. Its DLL and dependency manifests are also tracked
beside this document for review without unpacking the binary.

`cdda1` (2026-10-25): audio CD playback (`cdda://`, music module P5,
`docs/specs/2026-10-23-music-module-design.md` §9.3). libmpv is built with
`-Dcdda=enabled` against libcdio 2.3.0 and libcdio-paranoia 10.2+2.0.2 from
`tool/cdda/recipe.env`: pinned MSYS2 binary packages (URL + SHA-256) that
`tool/cdda/fetch_cdio_msys2.py` unpacks into a private prefix inside the build
directory - nothing is installed into MSYS2, so the rest of the closure keeps
the recorded package set. The archive adds `fbdcdio-19.dll`,
`fbdcdio_cdda-2.dll` and `fbdcdio_paranoia-2.dll` (libcdio's optional libcddb
is not imported by any of them and is not shipped) and
`licenses/fushi-cdda/` (both libraries are GPL-3.0-or-later; `SOURCE.txt`
names the MSYS2 source packages with their SHA-256), recorded as the
`fushi-cdda` entry of `native-dependency-packages.json`. The sixth mpv patch,
`patches/cdda-seek-sector-offset.patch` (`stream_patches` in the provenance),
fixes upstream `stream_cdda.c`: `seek()` kept only the sector number and
dropped the byte offset inside the 2352-byte sector (and kept serving the tail
of the sector read before the seek). The raw audio demuxer seeks to packet
boundaries, which are almost never sector boundaries, so after any seek -
including `--start` of a track - every sample was delivered up to 587 frames
early under its own timestamp; precise seeking then trimmed the wrong samples
(track 2 of the test disc came out 172 frames early, length unchanged). The
patch keeps the offset and starts the first sector after a seek there. Apart
from the three libcdio DLLs and their licenses the file list is identical to
`rdisc1` and only `libmpv-2.dll` changed (same MSYS2 package set and unified
FFmpeg prefix). `build_libmpv.ps1` ran every verifier (`probe_libmpv.py` now
also requires the `cdda` protocol with libcdio_paranoia loaded; mkv lace /
DTS; DV P5 0.36 / 255, P8.1 0.27). Real-disc check:
`fushi/test/media/music/disc/music_cdda_playback_real_test.dart` against a
cd-paranoia rip of the same disc (see the music design doc for the numbers).
The media_kit overlay (`ci/patches/hosted/media_kit-1.2.6/native_open_policy.dart`)
lets exactly `cdda://<drive>` load directly; mpv marks `stream_cdda`
`STREAM_ORIGIN_UNSAFE`, so the temporary-playlist path refuses it.

`dvd1-rdisc1` (2026-10-24): remote discs (`docs/specs/2026-10-24-disc-interaction-handoff.md`,
phase 2). `disc-navigation-state.patch` adds, without changing the v2 snapshot:
a `bluray-device` that is an `http(s)://` URL is the base of a paired host's
read-only disc share (`packages/fushi_engine/lib/sync/disc_share_routes.dart`);
libbluray opens it with `bd_open_files()` — every file is an mpv stream (HTTP
Range through the app's `http-proxy` relay, which owns TLS pinning), and
directories are listed from the share's `manifest.json` (paths with `..`,
absolute paths or backslashes reject the whole manifest). A `dvd-device` URL is
a shared DVD image read block-wise through `dvdnav_open_stream2()`; VIDEO_TS
folders cannot be streamed (libdvdnav 7.0 has no file-access entry point).
A read-only `disc-remote-access` property (`1`) tells the app the runtime can
do this; `probe_libmpv.py` requires it, and the app checks it before handing a
URL device to an older runtime (which would only report a generic open failure).
Same unified FFmpeg recipe and MSYS2 package set as `dvd1` (only the FFmpeg
`patched_commit` differs, it is a fresh local commit of the same patches);
`build_libmpv.ps1` ran every verifier. Remote verification with
`verify_menu_render.py --remote-disc` against
`packages/fushi_engine/tool/disc_share_host_probe.dart` serving the readable
Disc 2 copy over loopback HTTP: same states as the local disc (first play →
HDMV IG menu at ~18 s, `right` moves to チャプター, the local and remote
`select` on 全編再生 both return to the menu identically), and
right ×3 → `select` ×2 plays title 2 (00002.mpls) from the share.

`discnav2-...-dvd1` (2026-10-24): DVD menus (`docs/specs/2026-10-24-dvd-original-menu.md`,
`tool/dvd/README.md`). The unified FFmpeg prefix now also holds libdvdcss 1.6.0,
libdvdread 7.1.1 (linked against libdvdcss) and libdvdnav 7.0.0 from
`tool/dvd/recipe.env`; FFmpeg adds `--enable-libdvdnav --enable-libdvdread`
(`dvdvideo` demuxer) and libmpv `-Ddvdnav=enabled -Ddvda=disabled`, so both
load the same `fbddvdcss-2.dll` / `fbddvdread-8.dll` / `fbddvdnav-4.dll`
(licenses in `licenses/fushi-dvd/`, provenance entry `fushi-dvd`).
`disc-navigation-state.patch` is v2: `disc-type` plus a `dvd-state` branch;
the Blu-ray fields are unchanged and the Dart side accepts v1 and v2. Apart
from the three DVD DLLs and their licenses the file list is identical to `ffu2`.
`build_libmpv.ps1` ran every verifier (capability floor with `--require-staged`,
`probe_libmpv.py` incl. the DVD capability, mkv lace / DTS, DV P5 0.36 / 255,
P8.1 0.27). Blu-ray regression with `verify_menu_render.py` on the readable
Disc 2 test copy: same states, same HDMV IG menu (`right` moves to チャプター)
as the `ffu2` archive; the authored DVD (`tool/dvd/make_test_dvd.py`) renders
every focused button 100 % in its select colour and completes menu → title →
menu. A second, encrypted / BD-J Blu-ray does not open in the isolated probe
with either archive (no app-side AACS), identically.

`ffu1` (2026-10-17): built against the **unified FFmpeg** (`tool/ffmpeg-unified`,
FFmpeg 9.0.1 + Fushi patches, see `docs/specs/2026-10-17-unified-ffmpeg.md`)
instead of MSYS2's `mingw-w64-ffmpeg` package, and the archive also ships that
build's `ffmpeg.exe` / `ffprobe.exe`. They import the same renamed `fbd*.dll`
as `libmpv-2.dll` and are listed in `runtime-files.cmake`, so card mining runs
on exactly the FFmpeg the player decodes with (the separate
`third_party/ffmpeg-min/windows` build is gone). The closure shrank from 123 to
103 files: the unified configure mirrors MSYS2's minus whisper (ggml),
librsvg (glib/cairo/pango), frei0r, libcaca and openal.

`dovi1-ffu1` (2026-10-19): the `ffu1` unified-FFmpeg build and the `dovi1`
Dolby Vision reshaping (below) were developed in parallel; this archive is one
rebuild carrying both (same unified FFmpeg recipe and MSYS2 package set as
`ffu1`, plus `mpv-gl-dovi-p5.patch` under `render_patches`). The build script
ran every verifier below on it: capability floor, `smoke-test.sh`,
`probe_libmpv.py`, `verify_mkv_lace_dump.py` and `verify_dovi_p5.py` (P5 mean
error 0.36 / 255 under all three hwdec modes, P8.1 base layer 0.27 - the same
numbers as the `dovi1` archive).

`ffu2` (2026-10-19): rebuilt for the recipe's patch 0004 (Apple-only system
trust verification; `#ifdef __APPLE__`, so the Windows code is unchanged)
so the archive matches the whole recipe patch set, and it now ships
`licenses/ffmpeg-unified/SOURCE.txt` (GPL corresponding-source notice from
`tool/ffmpeg-unified/source_notice.py`). Same MSYS2 package set; all
verifiers passed again (P5 0.36 / 255, P8.1 0.27), plus
`tool/ffmpeg-unified/https_trust_smoke.sh` (public HTTPS opens with
`tls_verify=1`; self-signed / expired / wrong-host rejected by gnutls; since
fix/ffmpeg-https-smoke-hermetic the negative cases run against local
`openssl s_server` certificates, re-run on this archive: PASS).

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

`tool/bluray/platforms/patches/mpv-gl-dovi-p5.patch` (BUG-2691, the same file
Android / macOS / iOS ship) makes the texture renderer (`gl_video`, what
`vo=libmpv` uses) reshape Dolby Vision profile 5: it reads the frame's
`AV_FRAME_DATA_DOVI_METADATA` and ports libplacebo's RPU reshaping plus the
IPT -> LMS -> RGB decode. Without it P5 shows inverted purple / green colours,
which is why Windows used to switch DV sources to a separate `vo=gpu-next`
host window. Profiles 7 / 8 are left alone and show their HDR10 base layer.
`verify_dovi_p5.py` renders `tests/dovi-p5.mkv` / `tests/dovi-p81.mkv` through
the render API with d3d11va zero-copy, d3d11va-copy and software decoding and
compares them with libplacebo's own rendering (measured: P5 mean error
0.36 / 255, an archive without the patch 114; P8.1 matches the base layer, 0.27).

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

## Why this archive is built locally, not in CI

The mobile and macOS FFmpeg are CI builds (`ffmpeg-unified-mobile.yml`); this
Windows runtime is built on a developer machine, as every libmpv archive here
has been. A CI job was evaluated (2026-10-19) and not added, because it could
not deliver what it would be for - a reproducible, reviewable rebuild:

* The build links MSYS2's rolling `mingw-w64-x86_64-*` packages (headers and
  DLLs of ~90 libraries). MSYS2 has no dated snapshot repository; mirrors
  carry the current versions, so a CI run builds against whatever MSYS2 ships
  that day, not against the versions recorded here. Pinning would mean
  re-hosting ~90 exact package files ourselves.
* Even with identical inputs the archive is not byte-identical: FFmpeg embeds
  its configure line (install prefix) in `avutil`, and the 7z carries
  timestamps. A CI artifact could only be compared at manifest level, which
  `native-runtime-manifest.json` / `native-dependency-packages.json` already
  record for the vendored archive (bytes in the vendored-binaries release,
  pinned by tool/vendored_binaries.json).
* `verify_dovi_p5.py` and `verify_menu_render.py` render through ANGLE on
  D3D11; hosted Windows runners only offer WARP, so the render verifiers - the
  checks that caught BUG-2691 / BUG-3296 - would be skipped or untrustworthy
  there.

What keeps the local build honest instead: `native-dependency-packages.json`
records every MSYS2 package version in the closure plus the
`fushi-unified-ffmpeg` entry (upstream commit, patched commit, SHA-256 of each
applied patch, which `ffmpeg_unified_windows_runtime_guard_test.dart` compares
with `tool/ffmpeg-unified/patches/ffmpeg`), `package_libmpv.py` refuses a
source tree whose applied patches differ from the recipe, and
`build_libmpv.ps1` runs every verifier below before an archive can be
re-pinned. Revisit if MSYS2 gains dated snapshots.

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
