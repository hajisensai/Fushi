import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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
///
/// BUG-1406 widened the version check from "the first marker in the file" to
/// "every marker, plus every pinned artifact carries one". See
/// [_ffmpegMarker] / `expectEveryMarkerPatched` below for why the old shape was
/// a hole a single ABI could slip through.
final RegExp _ffmpegMarker = RegExp(r'ffmpeg(\d+)\.(\d+)\.(\d+)');

void main() {
  /// Lowest FFmpeg that carries the fixes this guard exists for (TODO-1137).
  const List<int> minFfmpeg = <int>[6, 1, 6];

  /// The ABIs the Android artifact set must cover, spelled out here rather than
  /// read back from `build.gradle`. Deriving the expectation from the file under
  /// guard is how a guard silently shrinks to the empty set: delete three
  /// entries and a "whatever is in the file" expectation deletes itself too.
  const Set<String> androidAbis = <String>{
    'arm64-v8a',
    'armeabi-v7a',
    'x86_64',
    'x86',
  };

  bool isAtLeast(List<int> actual, List<int> minimum) {
    for (int i = 0; i < 3; i++) {
      if (actual[i] != minimum[i]) return actual[i] > minimum[i];
    }
    return true;
  }

  /// The (trimmed) line [index] falls on, so a failure names the offending ABI
  /// instead of just quoting a version number.
  String lineAt(String text, int index) {
    final int start = text.lastIndexOf('\n', index) + 1;
    int end = text.indexOf('\n', index);
    if (end < 0) end = text.length;
    return text.substring(start, end).trim();
  }

  /// **Every** `ffmpeg<x.y.z>` marker in [text] must be at least [minFfmpeg].
  ///
  /// BUG-1406: this used to be `RegExp.firstMatch`, so only the *first* marker
  /// in a whole build file was ever compared. Android pins four independent
  /// artifacts in one file, so dropping a single ABI's URL back to
  /// `ffmpeg6.0.0` left this guard green — reproduced by mutation before the
  /// fix. Nothing else backstopped it either: the MD5 pins only assert that
  /// four checksums *exist*, never which build they belong to, so a downgraded
  /// URL shipped with its own matching MD5 verified perfectly.
  ///
  /// [atLeastMarkers] is the anchor. If a refactor moves the version out of
  /// these files, scanning zero markers must go red rather than vacuously pass.
  void expectEveryMarkerPatched(
    String text,
    String what, {
    required int atLeastMarkers,
  }) {
    final List<RegExpMatch> markers = _ffmpegMarker.allMatches(text).toList();
    expect(markers.length, greaterThanOrEqualTo(atLeastMarkers),
        reason: '$what must carry at least $atLeastMarkers ffmpeg<x.y.z> '
            'marker(s), found ${markers.length}. An unversioned artifact is '
            'unverifiable: it can silently be a stock FFmpeg 6.0 build '
            '(TODO-1137). If the pin layout changed, update this guard '
            'deliberately instead of letting it scan nothing.');
    for (final RegExpMatch m in markers) {
      final List<int> version = <int>[
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
      ];
      if (isAtLeast(version, minFfmpeg)) continue;
      fail('$what pins FFmpeg ${version.join(".")}, older than '
          '${minFfmpeg.join(".")} (TODO-1137: 6.0 still carries the magicyuv '
          'OOB write reachable from a crafted mkv/mov/avi). Rebuild from the '
          'hajisensai fork. Offending line:\n  ${lineAt(text, m.start)}');
    }
  }

  // Tests run with CWD = `fushi/`; vendored packages live at the workspace root.
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

  /// Pulls the single value of a `set(<NAME> "...")` from a CMake file.
  ///
  /// `firstMatch` on raw text is the same class of bug BUG-1406 fixed: the
  /// CMakeLists documents the old upstream pin at length in `#` comments, and a
  /// second (or commented-out) `set()` would silently win. So comments are
  /// masked first and a duplicate assignment is a hard failure, not a
  /// coin flip over which one the build actually uses.
  String cmakeSet(String masked, String name, RegExp pattern) {
    final List<RegExpMatch> hits = pattern.allMatches(masked).toList();
    expect(hits.length, 1,
        reason: 'windows CMakeLists must assign $name exactly once, found '
            '${hits.length}. Two assignments mean this guard checks one value '
            'while the build uses the other.');
    return hits.single.group(1)!;
  }

  test('Windows fork repoints libmpv off the TrueHD-broken upstream', () {
    final String cmake = maskHashComments(
        fork('media_kit_libs_windows_video/windows/CMakeLists.txt'));
    final String url =
        cmakeSet(cmake, 'LIBMPV_URL', RegExp(r'set\(LIBMPV_URL\s+"([^"]+)"\)'));
    final String asset =
        cmakeSet(cmake, 'LIBMPV', RegExp(r'set\(LIBMPV "([^"]+)"\)'));
    expect(url.contains('media-kit/libmpv-win32-video-build'), isFalse,
        reason: 'win32 upstream froze at 2023-09-24 with no TrueHD decoder.');
    // The libmpv .7z is mirrored into our own permanent GitHub release
    // (hajisensai/fushi `vendor-libmpv`) because zhongfly/mpv-winbuild prunes
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
    final Map<String, String> sha256ByPlatform = <String, String>{};
    for (final String plat in const <String>['macos', 'ios']) {
      final String mk =
          maskHashComments(fork('media_kit_libs_${plat}_video/$plat/Makefile'));
      expect(mk.contains('-video-default'), isFalse,
          reason: '$plat still downloads the "default" flavor (truehd demuxer '
              'only, no decoder). Switch to "-video-full".');
      expect(mk.contains('$plat-universal-video-full'), isTrue,
          reason:
              '$plat must download the "-video-full" flavor (all decoders).');
      // Mirrored into our own permanent release for the same reason Windows is:
      // upstream assets get pruned or retagged, and the media-kit originals are
      // built against FFmpeg 6.0 regardless.
      expect(mk.contains('media-kit/libmpv-darwin-build'), isFalse,
          reason: '$plat must not pull media-kit\'s own release: those are '
              'built against FFmpeg 6.0 (TODO-1137).');

      final List<RegExpMatch> sums =
          RegExp(r'MPV_XCFRAMEWORKS_SHA256SUM=([0-9a-f]{64})')
              .allMatches(mk)
              .toList();
      expect(sums.length, 1,
          reason: '$plat must pin exactly one MPV_XCFRAMEWORKS_SHA256SUM for '
              'the swapped tarball, found ${sums.length}.');
      sha256ByPlatform[plat] = sums.single.group(1)!;

      // The darwin flavour of the BUG-1406 hole: the version lives in a
      // variable and the download URL interpolates it. Hardcode a version into
      // the URL and the variable keeps reading 6.1.6 while the tarball actually
      // fetched is whatever the URL spells. Requiring the interpolation keeps
      // "the version this guard checked" and "the version downloaded" the same
      // token; `expectEveryMarkerPatched` then covers a hardcoded one anyway.
      expect(mk.contains(r'-video-full-${MPV_XCFRAMEWORKS_VERSION}.tar.gz'),
          isTrue,
          reason: '$plat download URL must interpolate '
              'MPV_XCFRAMEWORKS_VERSION, not spell a version of its own — '
              'otherwise the pinned variable and the fetched tarball can drift '
              '(TODO-1137).');

      expectEveryMarkerPatched(mk, plat, atLeastMarkers: 1);
    }
    // iOS and macOS ship two different tarballs. An identical pin means one
    // Makefile was copy-pasted from the other, so its `shasum -c` now verifies
    // the wrong artifact — and would reject the right one at build time.
    expect(sha256ByPlatform['ios'], isNot(sha256ByPlatform['macos']),
        reason: 'ios and macos pin the same SHA256; one of them verifies the '
            'other platform\'s tarball.');
  });

  test('Android downloads "full" jars built on a patched FFmpeg', () {
    final String gradle =
        maskComments(fork('media_kit_libs_android_video/android/build.gradle'));
    expect(RegExp(r'/default-[\w-]+\.jar').hasMatch(gradle), isFalse,
        reason: 'Android still pins "default" jars (truehd demuxer only, no '
            'decoder). Switch to the full jars.');
    expect(gradle.contains('media-kit/libmpv-android-video-build'), isFalse,
        reason: 'Android must not pull media-kit\'s own release: those are '
            'built against FFmpeg 6.0 (TODO-1137).');
    for (final String abi in androidAbis) {
      expect(RegExp('full-$abi[\\w.-]*\\.jar').hasMatch(gradle), isTrue,
          reason: 'Android must download a full-$abi jar (all decoders).');
    }

    // Parse the download table entry by entry instead of asking global
    // questions of the whole file. Four artifacts pinned in one file is exactly
    // the shape that hid BUG-1406: any "does this file contain X" phrasing is
    // satisfied by the three healthy siblings of a swapped-out ABI.
    final RegExp entry = RegExp(
      r'\[\s*"url"\s*:\s*"([^"]+)"\s*,\s*"md5"\s*:\s*"([0-9a-f]{32})"\s*,'
      r'\s*"destination"\s*:\s*file\("([^"]+)"\)\s*\]',
    );
    final Map<String, String> md5ByAbi = <String, String>{};
    for (final RegExpMatch m in entry.allMatches(gradle)) {
      final String url = m.group(1)!;
      final String md5 = m.group(2)!;
      final String destination = m.group(3)!;
      final RegExpMatch? abiMatch =
          RegExp(r'full-([\w-]+)\.jar$').firstMatch(destination);
      expect(abiMatch, isNotNull,
          reason: 'jar entry lands on "$destination"; expected '
              '.../full-<abi>.jar so the ABI is identifiable.');
      final String abi = abiMatch!.group(1)!;
      expect(md5ByAbi.containsKey(abi), isFalse,
          reason: 'two download entries claim ABI $abi.');
      expect(url.contains('full-$abi-'), isTrue,
          reason: 'the entry written to full-$abi.jar downloads "$url" — URL '
              'and destination disagree on which ABI this jar is, so one ABI '
              'would ship another ABI\'s libmpv.');
      expect(_ffmpegMarker.hasMatch(url), isTrue,
          reason: 'the $abi jar URL carries no ffmpeg<x.y.z> marker, so this '
              'guard cannot tell a patched build from a stock 6.0 one '
              '(TODO-1137). URL: $url');
      md5ByAbi[abi] = md5;
    }

    // Anchor: if the table shape changes and the loop above matches nothing,
    // this fails instead of leaving a guard that scans zero entries.
    expect(md5ByAbi.keys.toSet(), androidAbis,
        reason: 'parsed download entries for ${md5ByAbi.keys.toList()}, '
            'expected exactly $androidAbis. Either an ABI was dropped or the '
            'entry layout changed and this guard stopped seeing anything.');
    // Deliberately NOT asserting the MD5 *values*: those already live in
    // build.gradle, and copying them here would only mean every artifact swap
    // edits two files in the same commit — a maintenance tax that proves
    // nothing. What is worth pinning is the correspondence: one checksum per
    // ABI (enforced by the entry regex above) and four distinct ones, so a
    // copy-pasted checksum can't leave two ABIs verifying the same jar.
    expect(md5ByAbi.values.toSet().length, androidAbis.length,
        reason: 'two ABIs share an MD5 pin: ${md5ByAbi.toString()}. A pasted '
            'checksum means one ABI is verified against another ABI\'s jar.');

    expectEveryMarkerPatched(gradle, 'Android',
        atLeastMarkers: androidAbis.length);
  });
}
