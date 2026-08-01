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
///   - macOS/iOS: darwin `-video-full` (`--enable-decoders`).
///   - Android: `full-*.jar` (`--enable-decoders`).
///   - Linux: system libmpv (distro full FFmpeg) — no override needed.
///
/// TODO-1137 adds a second, independent requirement to the same artifacts.
/// media-kit's own builds pin FFmpeg 6.0 (2023-02), which is off the maintenance
/// branches and receives no security backports — it still carries the magicyuv
/// OOB write reachable from a crafted mkv/mov/avi, among others. macOS/iOS and
/// Android are therefore built from hajisensai's forks at FFmpeg 6.1.6 and
/// mirrored into our own permanent release. So the mobile/darwin artifacts must
/// now satisfy BOTH: the "full" flavor (or TrueHD goes silent) AND an FFmpeg new
/// enough to carry the fixes (or a known-vulnerable decoder ships).
///
/// A real cross-platform build can't run here, so these checks guard the
/// *mechanism*: the dependency overrides are wired, each downloader pulls a
/// "full" artifact rather than a TrueHD-broken "default" one, and the pinned
/// asset advertises a patched FFmpeg. Being a source scan, this can only verify
/// what the build files *claim* — the checksum pins are what tie the claim to
/// actual bytes. If any of it regresses, this test goes red.
void main() {
  /// Lowest FFmpeg that carries the fixes this guard exists for (TODO-1137).
  const List<int> minFfmpeg = <int>[6, 1, 6];

  /// Pulls the `ffmpeg<major>.<minor>.<patch>` marker out of a vendored asset
  /// name. Null when the asset carries no marker at all, which is itself a
  /// failure: an unversioned asset can silently be an old, vulnerable build.
  List<int>? ffmpegVersionOf(String text) {
    final RegExpMatch? m =
        RegExp(r'ffmpeg(\d+)\.(\d+)\.(\d+)').firstMatch(text);
    if (m == null) return null;
    return <int>[
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    ];
  }

  /// Drops `#` / `//` comment lines. These build files *document* the flavors
  /// they must not use ("upstream pins v0.6.0 `-video-default`"), so scanning
  /// raw text makes a correct file fail on its own explanation.
  String withoutComments(String source) =>
      source.split('\n').where((String line) {
        final String t = line.trimLeft();
        return !t.startsWith('#') && !t.startsWith('//');
      }).join('\n');

  bool isAtLeast(List<int> actual, List<int> minimum) {
    for (int i = 0; i < 3; i++) {
      if (actual[i] != minimum[i]) return actual[i] > minimum[i];
    }
    return true;
  }

  void expectPatchedFfmpeg(String assetText, String platform) {
    final List<int>? version = ffmpegVersionOf(assetText);
    expect(version, isNotNull,
        reason: '$platform asset must carry an ffmpeg<x.y.z> marker so this '
            'guard can tell a patched build from a vulnerable one (TODO-1137). '
            'Found: $assetText');
    expect(isAtLeast(version!, minFfmpeg), isTrue,
        reason: '$platform pins FFmpeg ${version.join(".")}, older than '
            '${minFfmpeg.join(".")}. media-kit stock builds sit on 6.0, which '
            'still has the magicyuv OOB write a crafted mkv/mov/avi can reach '
            '(TODO-1137). Rebuild from the hajisensai fork.');
  }

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
    final String asset =
        RegExp(r'set\(LIBMPV "([^"]+)"\)').firstMatch(cmake)!.group(1)!;
    expect(url.contains('media-kit/libmpv-win32-video-build'), isFalse,
        reason: 'win32 upstream froze at 2023-09-24 with no TrueHD decoder.');
    // The libmpv .7z is mirrored into our own permanent GitHub release
    // (hajisensai/hibiki `vendor-libmpv`) because zhongfly/mpv-winbuild prunes
    // releases on a ~30-day window and the pinned asset 404s (TODO-1137). The
    // mirrored file is the exact zhongfly full-FFmpeg build, so guard the real
    // BUG-073 intent (full flavor, not the broken flavors) instead of the host.
    expect(RegExp(r'^mpv-dev-x86_64-\d').hasMatch(asset), isTrue,
        reason: 'must be the full GPL FFmpeg flavor (mpv-dev-x86_64-<date>).');
    expect(asset.contains('-lgpl'), isFalse,
        reason: '-lgpl drops the TrueHD decoder -> re-opens BUG-073.');
    expect(asset.contains('-v3'), isFalse,
        reason: '-v3 needs Haswell+ and crashes on older CPUs.');
    expect(RegExp(r'set\(LIBMPV_MD5 "[0-9a-f]{32}"\)').hasMatch(cmake), isTrue,
        reason: 'LIBMPV_MD5 must stay pinned.');
  });

  test('macOS/iOS use a "video-full" xcframework on a patched FFmpeg', () {
    for (final String plat in const <String>['macos', 'ios']) {
      final String mk =
          withoutComments(fork('media_kit_libs_${plat}_video/$plat/Makefile'));
      expect(mk.contains('-video-default'), isFalse,
          reason: '$plat still downloads the "default" flavor (truehd demuxer '
              'only, no decoder). Switch to "-video-full".');
      expect(mk.contains('$plat-universal-video-full'), isTrue,
          reason:
              '$plat must download the "-video-full" flavor (all decoders).');
      expect(RegExp(r'MPV_XCFRAMEWORKS_SHA256SUM=[0-9a-f]{64}').hasMatch(mk),
          isTrue,
          reason: '$plat SHA256 must stay pinned for the swapped tarball.');
      // Mirrored into our own permanent release for the same reason Windows is:
      // upstream assets get pruned or retagged, and the media-kit originals are
      // built against FFmpeg 6.0 regardless.
      expect(mk.contains('media-kit/libmpv-darwin-build'), isFalse,
          reason: '$plat must not pull media-kit\'s own release: those are '
              'built against FFmpeg 6.0 (TODO-1137).');
      expectPatchedFfmpeg(mk, plat);
    }
  });

  test('Android downloads "full" jars built on a patched FFmpeg', () {
    final String gradle = withoutComments(
        fork('media_kit_libs_android_video/android/build.gradle'));
    expect(RegExp(r'/default-[\w-]+\.jar').hasMatch(gradle), isFalse,
        reason: 'Android still pins "default" jars (truehd demuxer only, no '
            'decoder). Switch to the full jars.');
    expect(gradle.contains('media-kit/libmpv-android-video-build'), isFalse,
        reason: 'Android must not pull media-kit\'s own release: those are '
            'built against FFmpeg 6.0 (TODO-1137).');
    for (final String abi in const <String>[
      'arm64-v8a',
      'armeabi-v7a',
      'x86_64',
      'x86',
    ]) {
      expect(RegExp('full-$abi[\\w.-]*\\.jar').hasMatch(gradle), isTrue,
          reason: 'Android must download a full-$abi jar (all decoders).');
    }
    expectPatchedFfmpeg(gradle, 'Android');
    // All four full jars must keep an MD5 pin (4 distinct 32-hex checksums).
    final Iterable<RegExpMatch> md5s =
        RegExp(r'"md5":\s*"([0-9a-f]{32})"').allMatches(gradle);
    expect(md5s.length, greaterThanOrEqualTo(4),
        reason: 'each full jar must stay MD5-pinned.');
  });
}
