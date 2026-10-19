# Android Blu-ray native libraries

These three full-flavor jars (arm64-v8a, armeabi-v7a, x86_64) are the default
Android build inputs. `sha256.json` is checked by Gradle before packaging; there
is no fallback to an older download.

- **Unified FFmpeg (2026-10-17).** `libmpv.so` carries no FFmpeg of its own: it
  `DT_NEEDED`s `libavcodec.so`, `libavformat.so`, ... from the app's
  FFmpegKitNext AAR (`third_party/ffmpeg_kit_next_flutter`), i.e. the same
  unified FFmpeg 9.0.1 (`tool/ffmpeg-unified`) that card mining runs. Playback
  and mining therefore share one FFmpeg; the jars shrank from ~9 MB to ~3 MB.
  Both sides route `av_log` through the unified FFmpeg's primary/secondary
  callback patch, so neither steals the other's log stream.
- Build source: [`452510d`](https://github.com/hajisensai/libmpv-android-video-build/commit/452510d169c847cbc5bd59ed72602ecc2eb163ce)
  (branch `fushi/unified-ffmpeg`, on top of `fushi/mkv-lace` `3166982`):
  `buildscripts/scripts/unified_ffmpeg.sh` installs the unified FFmpeg
  development prefix pinned by `buildscripts/unified-ffmpeg.lock`, and
  `buildscripts/bundle_unified.sh` fails unless every `libmpv.so` NEEDs the
  shared FFmpeg libraries, defines no FFmpeg symbol itself, and carries the
  navigation, Lua and dump-cache patch strings (`without DefaultDuration`,
  `Deriving missing DTS`; BUG-3499 / BUG-3500). Built at API 24 (the app's
  minSdk, matching the FFmpegKitNext libraries).
- Successful three-ABI build: Actions run 39037350491 in the private mirror
  `hajisensai/libmpv-android-build-fushi` (same commit). Pushes to the fork
  itself do not start Actions runs.
- mpv `36abaa32`, libbluray `1.5.0`, libplacebo `7.360.1`, Lua `5.2.4` (static,
  `-Dlua=lua`), Android NDK `27.3.13750724`. TrueHD / MLP decoding, the
  matroska muxer behind dump-cache and MediaCodec hwaccel come from the unified
  FFmpeg (`fushi/test/build/libmpv_truehd_guard_test.dart`,
  `libmpv_mkv_muxer_guard_test.dart`).
- Lua lets user mpv scripts run (BUG-2032 / BUG-3325). The build fails unless
  every `libmpv.so` carries both the `-Dlua=lua` configuration and the linked
  `Lua 5.2` runtime; `fushi/test/build/android_libmpv_lua_guard_test.dart`
  checks the same on the vendored bytes. Fushi sets `ytdl=no` before every
  `open` so mpv's built-in `ytdl_hook` never bypasses Dart-side URL resolution.
- `provenance.json` records the exact navigation, Android JNI and Dolby Vision
  profile 5 patch digests plus the unified FFmpeg lock. The original
  checksummed media-kit JNI helper remains bundled with each ABI.

The build rejects unresolved native symbols. Downloaded jars were checked for
matching SHA-256, correct ELF architecture and at least 16 KB LOAD alignment for
both libraries in every ABI. The C++ runtime is linked statically; no additional
`libc++_shared.so` is required.

This provides HDMV menu navigation and ISO/UDF reading. Android ART does not
replace the desktop Java runtime required by BD-J. Native build checks do not
replace Android playback/menu interaction testing.

`FUSHI_LIBMPV_ANDROID_DIR` can select an alternate complete, checksummed set.
