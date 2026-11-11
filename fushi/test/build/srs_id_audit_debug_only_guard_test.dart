import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// fushi_fsrs 的 ID 审计（cargo feature `id_audit`，native/fushi_fsrs/src/store/ids.rs `audit`）只给测试与本机
/// 调试构建用：带审计的库落在 `native/fushi_fsrs/prebuilt/<平台>/id_audit/`，由调试构建 / 测试宿主的加载器从仓库里
/// 找到（packages/fushi_srs `FushiFsrs.libraryCandidates`）。**发布产物不许带审计**——这里钉住做到这一点的几处：
///
/// 1. 打包只拷 `prebuilt/<平台>/` 里的普通库：各平台的打包文件不提 `id_audit`。
/// 2. 发布 / 构建流水线不编那份库：workflow 与 composite action 里不出现 `FUSHI_FSRS_ID_AUDIT_VARIANT`、`-IdAudit`。
/// 3. 发布产物过 `verify_abi.sh` 时顺带查「不带审计」（`verify_id_audit.sh … absent`）；Windows 的构建脚本自己查。
/// 4. 本机 prebuilt 里的两份库确实一份不带、一份带（存在才查）。
void main() {
  const String marker = 'id audit: ';
  const String crate = '../native/fushi_fsrs';

  String read(String path) {
    final File f = File(path);
    expect(f.existsSync(), isTrue, reason: '请从 fushi/ 包根跑测试：$path');
    return f.readAsStringSync();
  }

  test('打包文件只认普通库，不提 id_audit', () {
    // 每个平台把 fushi_fsrs 带进包的那个文件。它们都必须提到 fushi_fsrs（否则清单过期了），且不提审计那份。
    const List<String> bundlers = <String>[
      'windows/CMakeLists.txt',
      'linux/CMakeLists.txt',
      'macos/bundle_fushi_fsrs.sh',
      'android/app/build.gradle',
      '../native/fushi_ios_umbrella/build_ios_staticlib.sh',
      '../native/fushi_fsrs/build_ios_staticlib.sh',
      '../native/fushi_fsrs/build_android_so.sh',
      '../native/fushi_fsrs/build_android_so.ps1',
    ];
    for (final String path in bundlers) {
      final String text = read(path);
      expect(text, contains('fushi_fsrs'), reason: path);
      expect(text, isNot(contains('id_audit')), reason: path);
      expect(text, isNot(contains('ID_AUDIT')), reason: path);
    }
  });

  test('流水线不编带审计的那份 prebuilt', () {
    final List<File> files = <File>[
      for (final String dir in <String>[
        '../.github/workflows',
        '../.github/actions',
      ])
        ...Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => RegExp(r'\.ya?ml$').hasMatch(f.path)),
    ];
    // 扫描规模哨兵：目录搬走时别静默变成「零个文件全都合格」。
    expect(files.length, greaterThan(20));
    final List<String> offenders = <String>[
      for (final File f in files)
        if (RegExp(
          r'FUSHI_FSRS_ID_AUDIT_VARIANT|-IdAudit\b',
        ).hasMatch(f.readAsStringSync()))
          f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('发布产物的校验里查了「不带审计」', () {
    expect(
      read('$crate/verify_abi.sh'),
      contains('verify_id_audit.sh" "\$BIN" absent'),
    );
    expect(read('$crate/verify_id_audit.sh'), contains("'$marker'"));
    final String win = read('$crate/build_windows_dll.ps1');
    expect(win, contains("'$marker'"));
    expect(
      win,
      contains(
        r'Invoke-FsrsBuild -CargoArgs @() -Destination (Join-Path $outDir "fushi_fsrs.dll") -Audited $false',
      ),
    );
    // 判据本身：这个前缀只在 `id_audit` 构建里编进去。
    final String ids = read('$crate/src/store/ids.rs');
    final int at = ids.indexOf('"$marker{}"');
    expect(at, greaterThan(0));
    final int gate = ids.lastIndexOf('#[cfg(', at);
    expect(
      ids.substring(gate, ids.indexOf('\n', gate)),
      contains('#[cfg(feature = "id_audit")]'),
    );
    expect(marker.allMatches(ids).length, 1);
  });

  test('本机 prebuilt：普通库不带审计，id_audit 目录里那份带', () {
    final String platformDir = Platform.isWindows
        ? 'windows-x64'
        : Platform.isMacOS
        ? 'macos'
        : 'linux-x64';
    final String name = Platform.isWindows
        ? 'fushi_fsrs.dll'
        : Platform.isMacOS
        ? 'libfushi_fsrs.dylib'
        : 'libfushi_fsrs.so';
    bool audited(File f) {
      final Uint8List bytes = f.readAsBytesSync();
      final List<int> needle = marker.codeUnits;
      for (int i = 0; i + needle.length <= bytes.length; i++) {
        int k = 0;
        while (k < needle.length && bytes[i + k] == needle[k]) {
          k++;
        }
        if (k == needle.length) return true;
      }
      return false;
    }

    final File plain = File('$crate/prebuilt/$platformDir/$name');
    final File variant = File('$crate/prebuilt/$platformDir/id_audit/$name');
    // CI 的 Dart 测试库是带 `id_audit` 编进普通路径的（.github/actions/test-native-linux，FUSHI_FSRS_ID_AUDIT=1）：
    // 那是只给测试用的库，不查它。
    if (plain.existsSync() &&
        Platform.environment['FUSHI_FSRS_ID_AUDIT'] != '1') {
      expect(audited(plain), isFalse, reason: plain.path);
    }
    if (variant.existsSync()) {
      expect(audited(variant), isTrue, reason: variant.path);
    }
  });
}
