// DVD 原生依赖守卫（docs/specs/2026-10-24-dvd-original-menu.md）。
//
// 钉住的不变式：
// ① `tool/dvd/recipe.env` 是 libdvdcss / libdvdread / libdvdnav 的唯一版本真相源，
//    每个库都有 VideoLAN 官方 tarball URL + 64 位 SHA256，构建脚本先校验散列再解包；
// ② libdvdread 直接链接 libdvdcss（meson `-Dlibdvdcss=enabled`，即 `--with-libdvdcss`），
//    构建后用 config.h 证明真的链上了——否则加密盘静默读不出；
// ③ 只此一份：Windows 的 DVD 库装进统一 FFmpeg 的私有前缀，FFmpeg
//    （`--enable-libdvdnav --enable-libdvdread`）与 libmpv（`-Ddvdnav=enabled`）链同一组，
//    打包时三个 DLL 必须从该前缀解析且各一份；
// ④ `dvdvideo` demuxer 现处在 capabilities.json 的 `staged` 区：新构建
//    （build_libmpv.ps1 → `--require-staged`）必须带，已入库的旧产物不被它判红；
//    各平台产物重新 vendor 后挪进下限。staged 与下限不得重复登记。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/store_compliance.dart';

Map<String, String> _recipe() => <String, String>{
  for (final String line in File('../tool/dvd/recipe.env').readAsLinesSync())
    if (line.contains('=') && !line.startsWith('#'))
      line.split('=').first: line.substring(line.indexOf('=') + 1),
};

void main() {
  test('libdvdcss ships on all five platforms, iOS included (2026-10-24)', () {
    // Owner decision (docs/specs/2026-10-24-dvd-original-menu.md, D6). The
    // App Store fallback is reserved in store_compliance.dart, not scattered.
    expect(dvdCssDecryptionAvailableOn(isIOS: true), isTrue);
    expect(dvdCssDecryptionAvailableOn(isIOS: false), isTrue);
    final String cross = File(
      '../tool/dvd/platforms/build_cross.sh',
    ).readAsStringSync();
    expect(cross, contains('-DFUSHI_DVDCSS_NO_DRIVE'));
    expect(
      File(
        '../tool/dvd/patches/libdvdcss/0001-no-drive-ioctls.patch',
      ).readAsStringSync(),
      contains('#elif defined( FUSHI_DVDCSS_NO_DRIVE )'),
    );
  });

  test(
    'recipe pins version, VideoLAN URL and SHA256 for all three libraries',
    () {
      final Map<String, String> recipe = _recipe();
      for (final String lib in <String>[
        'LIBDVDCSS',
        'LIBDVDREAD',
        'LIBDVDNAV',
      ]) {
        final String? version = recipe['${lib}_VERSION'];
        final String? url = recipe['${lib}_URL'];
        final String? sha = recipe['${lib}_SHA256'];
        expect(version, matches(RegExp(r'^\d+\.\d+\.\d+$')), reason: lib);
        expect(
          url,
          'https://download.videolan.org/pub/videolan/${lib.toLowerCase()}/'
          '$version/${lib.toLowerCase()}-$version.tar.xz',
          reason: '$lib URL must name its own version',
        );
        expect(sha, matches(RegExp(r'^[0-9a-f]{64}$')), reason: lib);
      }
    },
  );

  test(
    'build script verifies hashes and links libdvdread against libdvdcss',
    () {
      final String script = File(
        '../tool/dvd/build_dvd_libs.sh',
      ).readAsStringSync();
      expect(script, contains('SHA256 mismatch'));
      expect(script, contains('-Dlibdvdcss=enabled'));
      expect(script, contains('HAVE_DVDCSS_DVDCSS_H'));
      // Shared by default: libmpv and libavformat must load the same copy.
      expect(
        script,
        contains(r'LIBRARY_KIND="${DVD_DEFAULT_LIBRARY:-shared}"'),
      );
      // libdvdcss before libdvdread before libdvdnav.
      final int css = script.indexOf('build libdvdcss ');
      final int read = script.indexOf('build libdvdread ');
      final int nav = script.indexOf('build libdvdnav ');
      expect(css, greaterThan(0));
      expect(read, greaterThan(css));
      expect(nav, greaterThan(read));
    },
  );

  test('Windows: FFmpeg and libmpv link one set of DVD libraries', () {
    final String ffmpeg = File(
      '../tool/ffmpeg-unified/windows/build_ffmpeg_msys2.sh',
    ).readAsStringSync();
    expect(ffmpeg, contains('--enable-libdvdnav'));
    expect(ffmpeg, contains('--enable-libdvdread'));
    final int dvd = ffmpeg.indexOf(
      r'bash "${ROOT}/../dvd/build_dvd_libs.sh" "${WORK}/dvd" "${PREFIX_NATIVE}"',
    );
    expect(dvd, greaterThan(0), reason: 'DVD libs go into the FFmpeg prefix');
    expect(
      dvd,
      lessThan(ffmpeg.indexOf(r'"${SRC}/configure"')),
      reason: 'DVD libs must exist before FFmpeg configure looks for them',
    );

    final String libmpv = File(
      '../tool/bluray/build_libmpv.ps1',
    ).readAsStringSync();
    expect(libmpv, contains("'-Ddvdnav=enabled'"));
    expect(libmpv, contains(r'lib\pkgconfig\dvdnav.pc'));
    expect(libmpv, contains("'--require-staged'"));

    final String package = File(
      '../tool/bluray/package_libmpv.py',
    ).readAsStringSync();
    expect(package, contains('dvd_provenance(closure, args.ffmpeg_prefix'));
    expect(
      package,
      contains('must resolve exactly once from the unified FFmpeg'),
    );

    final String probe = File(
      '../tool/bluray/probe_libmpv.py',
    ).readAsStringSync();
    expect(probe, contains('"dvd": dvd_capability(protocols)'));
    expect(probe, contains('not report["dvd"]["errors"]'));
  });

  test(
    'dvdvideo is staged: required of new builds, not yet of vendored ones',
    () {
      final Map<String, dynamic> caps =
          jsonDecode(
                File(
                  '../tool/ffmpeg-unified/capabilities.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final Map<String, dynamic> staged =
          caps['staged'] as Map<String, dynamic>;
      expect(staged['demuxers'], contains('dvdvideo'));
      expect(
        staged['configure'],
        containsAll(<String>['--enable-libdvdnav', '--enable-libdvdread']),
      );
      for (final MapEntry<String, dynamic> entry in staged.entries) {
        if (entry.value is! List || !caps.containsKey(entry.key)) continue;
        for (final dynamic name in entry.value as List<dynamic>) {
          expect(
            caps[entry.key] as List<dynamic>,
            isNot(contains(name)),
            reason:
                '$name is both staged and in the floor: delete it from staged '
                'once every platform artifact carries it',
          );
        }
      }
      final String verifier = File(
        '../tool/ffmpeg-unified/verify_ffmpeg_capabilities.py',
      ).readAsStringSync();
      expect(verifier, contains('--require-staged'));
      expect(verifier, contains('-buildconf'));
    },
  );

  test(
    'the three GPL-2.0-or-later DVD libraries are in the license registry',
    () {
      final Map<String, dynamic> manifest =
          jsonDecode(
                File(
                  '../native/third_party_licenses/manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final Map<String, String> recipe = _recipe();
      for (final String name in <String>[
        'libdvdcss',
        'libdvdread',
        'libdvdnav',
      ]) {
        final Map<String, dynamic> entry =
            (manifest['prebuilt'] as List<dynamic>)
                .cast<Map<String, dynamic>>()
                .firstWhere((Map<String, dynamic> e) => e['name'] == name);
        expect(entry['license'], 'GPL-2.0-or-later', reason: name);
        expect(
          entry['version'],
          recipe['${name.toUpperCase()}_VERSION'],
          reason: '$name license entry must follow tool/dvd/recipe.env',
        );
        for (final dynamic text in entry['texts'] as List<dynamic>) {
          expect(File('../$text').existsSync(), isTrue, reason: '$text');
        }
      }
    },
  );

  test('mobile: FFmpegKitNext and the libmpv forks link the same DVD libs', () {
    const String mobile = '../tool/ffmpeg-unified/mobile';
    final String kitPatch = File(
      '../tool/ffmpeg-unified/patches/ffmpeg-kit-next/'
      '0003-fushi-dvd-link-the-shared-tool-dvd-libraries.patch',
    ).readAsStringSync();
    expect(kitPatch, contains('--enable-libdvdnav --enable-libdvdread'));
    expect(kitPatch, contains('LOCAL_SHARED_LIBRARIES += libdvdcss'));
    expect(
      File('$mobile/prepare_kit.sh').readAsStringSync(),
      contains('kit patch 0003'),
    );
    for (final String platform in <String>['android', 'ios', 'macos']) {
      final String script = File(
        '$mobile/build_$platform.sh',
      ).readAsStringSync();
      expect(
        script,
        contains('FUSHI_DVD_ROOT="\${DVD}"'),
        reason: '$platform must hand the tool/dvd prefixes to the kit',
      );
      expect(script, contains('dvd/platforms/build_cross.sh'));
    }
    final String workflow = File(
      '../.github/workflows/ffmpeg-unified-mobile.yml',
    ).readAsStringSync();
    expect(
      RegExp(
        r'verify_mobile_outputs\.py \w+ "\$RUNNER_TEMP/out" --require-staged',
      ).allMatches(workflow).length,
      2,
    );
    // Fork overlays: mpv's stream_dvdnav.c only builds with -Dgpl=true.
    for (final String fork in <String>[
      'libmpv-android-video-build',
      'libmpv-darwin-build',
    ]) {
      final String patch = File(
        '../tool/dvd/forks/$fork.patch',
      ).readAsStringSync();
      expect(patch, contains('-Dgpl=true'), reason: fork);
      expect(patch, contains('-Ddvdnav=enabled'), reason: fork);
    }
  });

  test('music module formats are in the capability floor (spec §7.1)', () {
    // Measured 2026-10-24: every vendored artifact (Windows libmpv archive,
    // Android AAR, iOS xcframeworks, macOS layout) already carries all of
    // them, so they enter the floor directly instead of the staged section.
    final Map<String, dynamic> caps =
        jsonDecode(
              File(
                '../tool/ffmpeg-unified/capabilities.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(
      caps['decoders'],
      containsAll(<String>[
        'alac',
        'ape',
        'wavpack',
        'tak',
        'tta',
        'mpc8',
        'dsd_lsbf',
        'dsd_msbf',
        'dsd_lsbf_planar',
        'dsd_msbf_planar',
        'cdgraphics',
      ]),
    );
    expect(
      caps['demuxers'],
      containsAll(<String>[
        'ape',
        'wv',
        'tak',
        'tta',
        'dsf',
        'iff',
        'aiff',
        'caf',
        'w64',
        'cdg',
        'mpc8',
      ]),
    );
  });
}
