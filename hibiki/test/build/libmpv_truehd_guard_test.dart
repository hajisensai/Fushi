import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-073 source-scan guard: every platform's libmpv must come from a
/// TrueHD-capable build, never media_kit's stock "default" flavor.
///
/// Root cause (configure-level, uniform across platforms): media-kit's `default`
/// FFmpeg flavor compiles `--enable-demuxer=truehd` but NOT
/// `--enable-decoder=truehd/mlp`. So a TrueHD stream demuxes but never decodes —
/// silent. Proven on Windows by loading the bundled `libmpv-2.dll` via ctypes
/// (`Failed to initialize a decoder for codec 'truehd'`); the macOS/iOS/Android
/// `-default` builds share the exact same configure whitelist. The same DLL/so
/// also backs the audiobook player, so TrueHD audiobooks were silent too.
///
/// Fix, unified to one maintenance pattern:
///   - Windows: media-kit's win32 build is archived (no "full" flavor), so the
///     fork repoints to the maintained zhongfly/mpv-winbuild (full FFmpeg).
///   - macOS/iOS: media-kit's own darwin v0.7.0 `-video-full` (`--enable-decoders`).
///   - Android: media-kit's own v1.1.11 `full-*.jar` (`--enable-decoders`).
///   - Linux: system libmpv (distro full FFmpeg) — no override needed.
///
/// A real cross-platform build can't run here, so these checks guard the
/// *mechanism*: the dependency overrides are wired, and each fork's downloader
/// no longer pulls a TrueHD-broken "default" artifact. If any regresses, TrueHD
/// goes silent on that platform and this test goes red.
void main() {
  // Tests run with CWD = `hibiki/`; vendored packages live at the workspace root.
  final String pubspec = File('pubspec.yaml').readAsStringSync();

  String fork(String relative) =>
      File('../third_party/$relative').readAsStringSync();

  test('pubspec overrides every media_kit libs package to the vendored fork',
      () {
    for (final String pkg in const <String>[
      'media_kit_libs_windows_video',
      'media_kit_libs_macos_video',
      'media_kit_libs_ios_video',
      'media_kit_libs_android_video',
    ]) {
      final RegExp override =
          RegExp('$pkg:\\s*\\n\\s*path:\\s*\\.\\./third_party/$pkg');
      expect(
        override.hasMatch(pubspec),
        isTrue,
        reason: 'dependency_overrides must point $pkg at ../third_party/$pkg '
            '(BUG-073). Without it, pub.dev\'s default package returns and '
            'TrueHD audio goes silent on that platform.',
      );
    }
  });

  test('Windows fork repoints libmpv off the TrueHD-broken upstream', () {
    final String cmake =
        fork('media_kit_libs_windows_video/windows/CMakeLists.txt');
    final String url =
        RegExp(r'set\(LIBMPV_URL\s+"([^"]+)"\)').firstMatch(cmake)!.group(1)!;
    expect(url.contains('media-kit/libmpv-win32-video-build'), isFalse,
        reason: 'win32 upstream froze at 2023-09-24 with no TrueHD decoder.');
    expect(url.contains('zhongfly/mpv-winbuild'), isTrue,
        reason: 'expected the maintained full-FFmpeg libmpv (zhongfly).');
    expect(RegExp(r'set\(LIBMPV_MD5 "[0-9a-f]{32}"\)').hasMatch(cmake), isTrue,
        reason: 'LIBMPV_MD5 must stay pinned.');
  });

  test('macOS/iOS forks use the darwin "video-full" flavor, not "default"', () {
    for (final String plat in const <String>['macos', 'ios']) {
      final String mk = fork('media_kit_libs_${plat}_video/$plat/Makefile');
      expect(mk.contains('$plat-universal-video-default.tar.gz'), isFalse,
          reason: '$plat still downloads the "default" flavor (truehd demuxer '
              'only, no decoder). Switch to "-video-full".');
      expect(mk.contains('$plat-universal-video-full.tar.gz'), isTrue,
          reason:
              '$plat must download the "-video-full" flavor (all decoders).');
      expect(RegExp(r'MPV_XCFRAMEWORKS_SHA256SUM=[0-9a-f]{64}').hasMatch(mk),
          isTrue,
          reason: '$plat SHA256 must stay pinned for the swapped tarball.');
    }
  });

  test('Android fork uses the v1.1.11 "full" jars, not v1.1.7 "default"', () {
    final String gradle =
        fork('media_kit_libs_android_video/android/build.gradle');
    expect(gradle.contains('/v1.1.7/default-'), isFalse,
        reason: 'Android still pins v1.1.7 default jars (truehd demuxer only, '
            'no decoder). Switch to the v1.1.11 full jars.');
    for (final String abi in const <String>[
      'arm64-v8a',
      'armeabi-v7a',
      'x86_64',
      'x86',
    ]) {
      expect(gradle.contains('/v1.1.11/full-$abi.jar'), isTrue,
          reason:
              'Android must download v1.1.11 full-$abi.jar (all decoders).');
    }
    // All four full jars must keep an MD5 pin (4 distinct 32-hex checksums).
    final Iterable<RegExpMatch> md5s =
        RegExp(r'"md5":\s*"([0-9a-f]{32})"').allMatches(gradle);
    expect(md5s.length, greaterThanOrEqualTo(4),
        reason: 'each full jar must stay MD5-pinned.');
  });
}
