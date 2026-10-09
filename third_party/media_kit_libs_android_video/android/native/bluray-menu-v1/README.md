# Android Blu-ray native libraries

These four full-flavor jars are the default Android build inputs. `sha256.json`
is checked by Gradle before packaging; there is no fallback to an older download.

- Build source: [`dff448c`](https://github.com/hajisensai/libmpv-android-video-build/commit/dff448cc3f0c32f1ff4d31a3ee47a017e271aeab).
- Successful four-ABI build: [Actions run 37763609197](https://github.com/hajisensai/libmpv-android-video-build/actions/runs/37763609197).
- mpv `36abaa32`, FFmpeg `6.1.6` full decoders, libbluray `1.5.0`,
  libplacebo `7.360.1`, Android NDK `27.3.13750724`.
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
