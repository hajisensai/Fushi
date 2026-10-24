import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 音频 CD（音乐方案 §9.3 P5）：Windows 随包 libmpv 必须带 `cdda://`，并带
/// `patches/cdda-seek-sector-offset.patch`。
///
/// 上游 `stream_cdda.c` 的 `seek()` 只取扇区号、丢掉扇区内的字节偏移；原始音频解复用器按包
/// 对齐 seek，目标几乎总不在扇区边界上，于是 seek 之后每个样本都比时间戳早最多 587 帧
/// （实测第 2 轨整段提前 172 帧）。本守卫钉住：补丁内容、构建脚本应用它并开 `-Dcdda`、
/// libcdio 来自钉了版本与散列的私有前缀（不往 MSYS2 装包）、打包产物的 provenance 与仓内
/// 补丁逐字节一致、随包 DLL 清单与许可登记都在。换了补丁却没重编 / 重新 vendor 会在这里红。
/// 真盘验证：`test/media/music/disc/music_cdda_playback_real_test.dart`。
void main() {
  const String pkg = '../third_party/media_kit_libs_windows_video';
  final File patch = File('$pkg/patches/cdda-seek-sector-offset.patch');

  Map<String, String> recipe() => <String, String>{
    for (final String line in File('../tool/cdda/recipe.env').readAsLinesSync())
      if (line.isNotEmpty && !line.startsWith('#') && line.contains('='))
        line.substring(0, line.indexOf('=')): line.substring(
          line.indexOf('=') + 1,
        ),
  };

  test('补丁保留扇区内偏移、丢掉 seek 前的旧扇区', () {
    final String text = patch.readAsStringSync();
    expect(text, contains('+++ b/stream/stream_cdda.c'));
    expect(
      text,
      contains('+    p->data_pos = newpos % CDIO_CD_FRAMESIZE_RAW;'),
    );
    expect(text, contains('+    p->data = NULL;'));
    // seek 之后的第一扇区从 data_pos 开始，其余从 0 开始。
    expect(
      text,
      contains('+        if (p->data)\n+            p->data_pos = 0;'),
    );
    expect(text, contains('-        p->data_pos = 0;'));
    // 编进二进制的特征串：Darwin 产物验收用它确认补丁生效。
    expect(text, contains('Seek to sector %d, byte %d within the sector.'));
  });

  test('构建脚本在既有补丁之后应用它、开 -Dcdda，libcdio 来自钉住的私有前缀', () {
    final String script = File(
      '../tool/bluray/build_libmpv.ps1',
    ).readAsStringSync();
    final int dovi = script.indexOf('mpv-gl-dovi-p5.patch');
    final int cdda = script.indexOf(r'patches\cdda-seek-sector-offset.patch');
    expect(dovi, greaterThanOrEqualTo(0));
    expect(cdda, greaterThan(dovi));
    expect(script, contains("'-Dcdda=enabled'"));
    expect(script, contains(r'tool\cdda\fetch_cdio_msys2.py'));
    expect(script, contains("'--cdio-prefix', \$cdioPrefix"));
    expect(script, isNot(contains('pacman')));

    final Map<String, String> r = recipe();
    for (final String key in <String>['LIBCDIO', 'LIBCDIO_PARANOIA']) {
      expect(r['${key}_URL'], startsWith('https://repo.msys2.org/mingw/'));
      expect(r['${key}_SHA256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(r['${key}_SOURCE_SHA256'], matches(RegExp(r'^[0-9a-f]{64}$')));
    }
    final String fetch = File(
      '../tool/cdda/fetch_cdio_msys2.py',
    ).readAsStringSync();
    expect(fetch, contains('pinned'));
    expect(fetch, contains(r'sha256(data) != expected'));
  });

  test('vendored Windows libmpv：provenance 记的就是这份补丁，归档名带 -cdda', () {
    final Map<String, dynamic> provenance =
        jsonDecode(
              File('$pkg/native-source-provenance.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(
      (provenance['stream_patches']
          as Map<String, dynamic>)['cdda-seek-sector-offset.patch'],
      sha256.convert(patch.readAsBytesSync()).toString(),
      reason:
          'cdda-seek-sector-offset.patch changed without rebuilding and '
          're-vendoring libmpv (tool/bluray/build_libmpv.ps1)',
    );
    final String cmake = File('$pkg/windows/CMakeLists.txt').readAsStringSync();
    final String archive = RegExp(
      r'set\(LIBMPV "([^"]+)"\)',
    ).firstMatch(cmake)!.group(1)!;
    expect(archive, matches(RegExp(r'-cdda\d+\.7z$')));
    expect(File('$pkg/vendored/$archive').existsSync(), isTrue);
  });

  test('随包闭包里有三份 libcdio DLL（改名后的），依赖清单与许可登记对得上', () {
    final List<dynamic> manifest =
        jsonDecode(File('$pkg/native-runtime-manifest.json').readAsStringSync())
            as List<dynamic>;
    final Map<String, String> renamed = <String, String>{
      for (final dynamic row in manifest)
        (row as Map<String, dynamic>)['source_name'] as String:
            row['name'] as String,
    };
    expect(renamed['libcdio-19.dll'], 'fbdcdio-19.dll');
    expect(renamed['libcdio_cdda-2.dll'], 'fbdcdio_cdda-2.dll');
    expect(renamed['libcdio_paranoia-2.dll'], 'fbdcdio_paranoia-2.dll');
    final Map<String, dynamic> libmpv =
        manifest.firstWhere(
              (dynamic row) =>
                  (row as Map<String, dynamic>)['name'] == 'libmpv-2.dll',
            )
            as Map<String, dynamic>;
    expect(
      libmpv['imports_and_forwarders'] as List<dynamic>,
      containsAll(<String>[
        'fbdcdio-19.dll',
        'fbdcdio_cdda-2.dll',
        'fbdcdio_paranoia-2.dll',
      ]),
    );

    final List<dynamic> packages =
        jsonDecode(
              File('$pkg/native-dependency-packages.json').readAsStringSync(),
            )
            as List<dynamic>;
    final Map<String, dynamic> cdda =
        packages.firstWhere(
              (dynamic e) =>
                  (e as Map<String, dynamic>)['name'] == 'fushi-cdda',
            )
            as Map<String, dynamic>;
    final Map<String, String> r = recipe();
    expect(cdda['license'], 'GPL-3.0-or-later');
    expect(cdda['versions'], <String, String>{
      'libcdio': r['LIBCDIO_VERSION']!,
      'libcdio-paranoia': r['LIBCDIO_PARANOIA_VERSION']!,
    });
    expect(cdda['package_sha256'], <String, String>{
      'libcdio': r['LIBCDIO_SHA256']!,
      'libcdio-paranoia': r['LIBCDIO_PARANOIA_SHA256']!,
    });
    expect(cdda['files'], <String>[
      'libcdio-19.dll',
      'libcdio_cdda-2.dll',
      'libcdio_paranoia-2.dll',
    ]);

    final String licenses = File(
      '../native/third_party_licenses/manifest.json',
    ).readAsStringSync();
    for (final String name in <String>['libcdio', 'libcdio-paranoia']) {
      expect(licenses, contains('"name": "$name"'));
    }
    for (final String text in <String>[
      'libcdio-2.3.0-COPYING',
      'libcdio-paranoia-10.2+2.0.2-COPYING',
    ]) {
      expect(
        File('../native/third_party_licenses/texts/cdda/$text').existsSync(),
        isTrue,
      );
    }
  });

  test('media_kit 覆盖层只放行 app 自己构造的 cdda://<光驱>', () {
    final String policy = File(
      '../ci/patches/hosted/media_kit-1.2.6/lib/native_open_policy.dart',
    ).readAsStringSync();
    expect(
      policy,
      contains(r"RegExp(r'^cdda://(?:[A-Za-z]:|/dev/[A-Za-z][A-Za-z0-9]*)$')"),
    );
  });
}
