# [package:media_kit_libs_android_video](https://github.com/media-kit/media-kit)

[![](https://img.shields.io/discord/1079685977523617792?color=33cd57&label=Discord&logo=discord&logoColor=discord)](https://discord.gg/h7qf2R9n57) [![Github Actions](https://github.com/media-kit/media-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/media-kit/media-kit/actions/workflows/ci.yml)

Android package providing video (& audio) native libraries for [`package:media_kit`](https://github.com/media-kit/media-kit).

## Fushi local native builds

The default artifacts are the verified four-ABI jars in
`android/native/bluray-menu-v1`, including Blu-ray navigation, FFmpeg 6.1.6 and
Dolby Vision support. Rebuild with `tool/bluray/platforms/build_android.sh` from
the repository on a configured Linux/macOS build host. It builds mpv with
libbluray 1.5.0, libplacebo 7.360.1,
the Fushi navigation state API, and the existing Android JNI / Dolby Vision
behavior.

Set `FUSHI_LIBMPV_ANDROID_DIR` to the absolute artifact directory, or pass
`-PfushiLibmpvAndroidDir=/absolute/path` to Gradle. The directory must contain
`full-arm64-v8a.jar`, `full-armeabi-v7a.jar`, `full-x86_64.jar`, `full-x86.jar`,
and `sha256.json` mapping each filename to its lowercase SHA-256. Missing ABIs,
missing native libraries, and checksum mismatches stop the build; they never
silently fall back to old binaries.

This build enables HDMV menus and ISO/UDF reading. It does not bundle a desktop
JVM for BD-J; Android ART alone cannot run the disc's Java applications. Native
compile checks are separate from Android playback and menu interaction tests.

## License

Copyright © 2021 & onwards, Hitesh Kumar Saini <<saini123hitesh@gmail.com>>

This project & the work under this repository is governed by MIT license that can be found in the [LICENSE](./LICENSE) file.
