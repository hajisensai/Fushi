import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../helpers/android_vendored_libmpv.dart';
import '../helpers/darwin_vendored_libmpv.dart';
import '../helpers/workspace_pubspec.dart';

/// BUG-073 / TODO-1137: every bundled ABI must retain TrueHD/MLP decoders
/// and the patched FFmpeg baseline. Darwin and Android inspect checksummed
/// archive contents, not asset names or download URL suffixes. This prevents
/// one architecture silently reverting while another architecture stays current.
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

  // Tests run with CWD = `fushi/`; vendored packages live at the workspace root.
  final WorkspacePubspec ws = WorkspacePubspec.load();

  String fork(String relative) =>
      File('../third_party/$relative').readAsStringSync();

  test(
    'pubspec overrides every media_kit libs package to the vendored fork',
    () {
      for (final String pkg in const <String>[
        'media_kit_libs_windows_video',
        'media_kit_libs_macos_video',
        'media_kit_libs_ios_video',
        'media_kit_libs_android_video',
      ]) {
        expect(
          ws.isVendored(pkg, 'third_party/$pkg'),
          isTrue,
          reason:
              'the workspace-root pubspec must point $pkg at '
              'third_party/$pkg (BUG-073). Without it, pub.dev\'s default '
              'package returns and TrueHD audio goes silent on that platform.',
        );
      }
    },
  );

  /// Pulls the single value of a `set(<NAME> "...")` from a CMake file.
  ///
  /// `firstMatch` on raw text is the same class of bug BUG-1406 fixed: the
  /// CMakeLists documents the old upstream pin at length in `#` comments, and a
  /// second (or commented-out) `set()` would silently win. So comments are
  /// masked first and a duplicate assignment is a hard failure, not a
  /// coin flip over which one the build actually uses.
  String cmakeSet(String masked, String name, RegExp pattern) {
    final List<RegExpMatch> hits = pattern.allMatches(masked).toList();
    expect(
      hits.length,
      1,
      reason:
          'windows CMakeLists must assign $name exactly once, found '
          '${hits.length}. Two assignments mean this guard checks one value '
          'while the build uses the other.',
    );
    return hits.single.group(1)!;
  }

  test('Windows fork repoints libmpv off the TrueHD-broken upstream', () {
    final String cmake = maskHashComments(
      fork('media_kit_libs_windows_video/windows/CMakeLists.txt'),
    );
    final String url = cmakeSet(
      cmake,
      'LIBMPV_URL',
      RegExp(r'set\(LIBMPV_URL\s+"([^"]+)"\)'),
    );
    final String asset = cmakeSet(
      cmake,
      'LIBMPV',
      RegExp(r'set\(LIBMPV "([^"]+)"\)'),
    );
    expect(
      url.contains('media-kit/libmpv-win32-video-build'),
      isFalse,
      reason: 'win32 upstream froze at 2023-09-24 with no TrueHD decoder.',
    );
    // The libmpv .7z is mirrored into our own permanent GitHub release
    // (hajisensai/fushi `vendor-libmpv`) because zhongfly/mpv-winbuild prunes
    // releases on a ~30-day window and the pinned asset 404s (TODO-1137). The
    // mirrored file is the exact zhongfly full-FFmpeg build, so guard the real
    // BUG-073 intent (full flavor, not the broken flavors) instead of the host.
    expect(
      RegExp(r'^mpv-dev-x86_64-\d').hasMatch(asset),
      isTrue,
      reason: 'must be the full GPL FFmpeg flavor (mpv-dev-x86_64-<date>).',
    );
    expect(
      asset.contains('-lgpl'),
      isFalse,
      reason: '-lgpl drops the TrueHD decoder -> re-opens BUG-073.',
    );
    expect(
      asset.contains('-v3'),
      isFalse,
      reason: '-v3 needs Haswell+ and crashes on older CPUs.',
    );
    expect(
      RegExp(r'set\(LIBMPV_MD5 "[0-9a-f]{32}"\)').hasMatch(cmake),
      isTrue,
      reason: 'LIBMPV_MD5 must stay pinned.',
    );
  });

  test(
    'Darwin archives retain patched FFmpeg and TrueHD in every CPU slice',
    () {
      for (final String platform in <String>['macos', 'ios']) {
        for (final DarwinLibmpvSlice slice in verifiedDarwinLibmpv(platform)) {
          final String what = '$platform/${slice.identity}';
          final Iterable<RegExpMatch> configurations = RegExp(
            r'--disable-autodetect[^\x00]+',
          ).allMatches(slice.codec);
          expect(configurations, isNotEmpty, reason: what);
          for (final RegExpMatch configuration in configurations) {
            final String flags = configuration.group(0)!;
            final RegExpMatch? version = RegExp(
              r'--prefix=\S*ffmpeg-\S*-([0-9]+\.[0-9]+\.[0-9]+)(?:\s|$)',
            ).firstMatch(flags);
            expect(version, isNotNull, reason: '$what FFmpeg build version');
            expect(
              isAtLeast(
                version!.group(1)!.split('.').map(int.parse).toList(),
                minFfmpeg,
              ),
              isTrue,
              reason: '$what cannot downgrade the FFmpeg security baseline',
            );
            for (final String decoder in <String>['truehd', 'mlp']) {
              bool enabled = false;
              for (final String flag in flags.split(' ')) {
                if (<String>[
                  '--disable-all',
                  '--disable-everything',
                  '--disable-decoders',
                ].contains(flag)) {
                  enabled = false;
                } else if (flag == '--enable-decoders') {
                  enabled = true;
                } else if (flag.startsWith('--disable-decoder=') &&
                    flag
                        .substring('--disable-decoder='.length)
                        .split(',')
                        .contains(decoder)) {
                  enabled = false;
                } else if (flag.startsWith('--enable-decoder=') &&
                    flag
                        .substring('--enable-decoder='.length)
                        .split(',')
                        .contains(decoder)) {
                  enabled = true;
                }
              }
              expect(enabled, isTrue, reason: '$what must decode $decoder');
            }
          }
          expect(
            slice.mpv,
            contains('disc-navigation-state-json'),
            reason: what,
          );
          expect(slice.mpv, contains('menu-call-allowed'), reason: what);
        }
      }
    },
  );

  test('Android vendors full jars with patched FFmpeg and disc navigation', () {
    final String gradle = maskComments(
      fork('media_kit_libs_android_video/android/build.gradle'),
    );
    expect(gradle, contains("file('native/bluray-menu-v1').absolutePath"));
    expect(gradle, isNot(contains('new URL(')));
    final Set<String> checked = <String>{};
    for (final ({String abi, String contents}) artifact
        in verifiedAndroidLibmpv()) {
      checked.add(artifact.abi);
      for (final String marker in <String>[
        'ff_truehd_decoder',
        'ff_mlp_decoder',
        'n6.1.6',
        'disc-navigation-state-json',
        'menu-call-allowed',
        'mpv_lavc_set_java_vm',
      ]) {
        expect(artifact.contents, contains(marker), reason: artifact.abi);
      }
    }
    expect(checked, androidAbis);
  });
}
