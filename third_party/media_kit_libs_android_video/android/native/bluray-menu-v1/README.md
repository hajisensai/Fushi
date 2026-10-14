# Android Blu-ray native libraries

These four full-flavor jars are the default Android build inputs. `sha256.json`
is checked by Gradle before packaging; there is no fallback to an older download.

- Build source: [`8a496a2`](https://github.com/hajisensai/libmpv-android-video-build/commit/8a496a2dba0843a18d740e6f266a0c07eb76de91)
  (branch `fushi/lua-enabled`, on top of the disc-menu build `dff448c`).
- Successful four-ABI build: [Actions run 38391453531](https://github.com/hajisensai/libmpv-android-video-build/actions/runs/38391453531).
- mpv `36abaa32`, FFmpeg `6.1.6` full decoders, libbluray `1.5.0`,
  libplacebo `7.360.1`, Lua `5.2.4` (static, `-Dlua=lua`), Android NDK
  `27.3.13750724`.
- Lua lets user mpv scripts run (BUG-2032 / BUG-3325). The build fails unless
  every `libmpv.so` carries both the `-Dlua=lua` configuration and the linked
  `Lua 5.2` runtime; `fushi/test/build/android_libmpv_lua_guard_test.dart`
  checks the same on the vendored bytes. Fushi sets `ytdl=no` before every
  `open` so mpv's built-in `ytdl_hook` never bypasses Dart-side URL resolution.
- `provenance.json` records the exact navigation, Android JNI and Dolby Vision
  profile 5 patch digests. The original checksummed media-kit JNI helper remains
  bundled with each ABI.

The build rejects unresolved native symbols. Downloaded jars were checked for
matching SHA-256, correct ELF architecture and at least 16 KB LOAD alignment for
both libraries in every ABI. The C++ runtime is linked statically; no additional
`libc++_shared.so` is required.

This provides HDMV menu navigation and ISO/UDF reading. Android ART does not
replace the desktop Java runtime required by BD-J. Native build checks do not
replace Android playback/menu interaction testing.

Rebuild with `tool/bluray/platforms/build_android.sh`; an explicit
`FUSHI_LIBMPV_ANDROID_DIR` can select an alternate complete, checksummed set.
