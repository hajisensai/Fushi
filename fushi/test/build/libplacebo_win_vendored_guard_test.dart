import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计划 P2 守卫：`third_party/libplacebo-win` 随包产物的完整性与三处契约一致。
///
/// · `bin/SHA256SUMS` 列出的每个 DLL 都在且哈希一致（防静默换包 / 半截提交）；
/// · 头文件 `config.h` 的 `PL_API_VER` 与 DLL 名（`libplacebo-<ver>.dll`）以及 fork
///   `placebo_pass.cc` 的 `kPlaceboDll` 三者同版本——fork 只按结构体布局用头文件，版本错配是静默崩溃；
/// · fork CMake 真把该目录接进编译 + bundled_libraries。
void main() {
  const String root = '../third_party/libplacebo-win';

  test('SHA256SUMS 里每个 DLL 都在且哈希一致', () {
    final File sums = File('$root/bin/SHA256SUMS');
    expect(sums.existsSync(), isTrue, reason: sums.path);
    final List<String> lines = sums
        .readAsLinesSync()
        .where((String l) => l.trim().isNotEmpty)
        .toList();
    expect(lines.length, 1, reason: 'shaderc、spirv-cross 与 MinGW 运行时应静态链入本体');
    final List<String> dllNames =
        Directory('$root/bin')
            .listSync()
            .whereType<File>()
            .map((File file) => file.uri.pathSegments.last)
            .where((String name) => name.toLowerCase().endsWith('.dll'))
            .toList()
          ..sort();
    expect(dllNames, <String>['libplacebo-360.dll']);
    for (final String line in lines) {
      final List<String> parts = line.split(RegExp(r'\s+'));
      final String hash = parts.first.toLowerCase();
      final String name = parts.last;
      final File dll = File('$root/bin/$name');
      expect(dll.existsSync(), isTrue, reason: '缺 $name');
      final String actual = sha256.convert(dll.readAsBytesSync()).toString();
      expect(actual, hash, reason: '$name 内容与 SHA256SUMS 不符');
    }
  });

  // DLL 不入库（2026-11-01）：tool/vendored_binaries.json 钉 sha256 + release 资产，
  // .gitignore 按原路径排除，bootstrap / CI 用 tool/vendored_binaries.py fetch 取回。
  // 全量对账在 vendored_binaries_manifest_guard_test.dart，这里钉本目录这一条。
  test('DLL 由 vendored-binaries 清单钉住、gitignore、与 SHA256SUMS 同哈希', () {
    final Map<String, dynamic> manifest =
        jsonDecode(File('../tool/vendored_binaries.json').readAsStringSync())
            as Map<String, dynamic>;
    final List<String> sums = File(
      '$root/bin/SHA256SUMS',
    ).readAsLinesSync().where((String l) => l.trim().isNotEmpty).toList();
    final Set<String> ignore = File(
      '../.gitignore',
    ).readAsLinesSync().map((String l) => l.trim()).toSet();
    for (final String line in sums) {
      final List<String> parts = line.split(RegExp(r'\s+'));
      final String path = 'third_party/libplacebo-win/bin/${parts.last}';
      final Map<String, dynamic>? entry = (manifest['files'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((Map<String, dynamic> e) => e['path'] == path)
          .firstOrNull;
      expect(
        entry,
        isNotNull,
        reason: '$path 必须登记在 tool/vendored_binaries.json',
      );
      expect(entry!['sha256'], parts.first.toLowerCase());
      expect(entry['group'], 'windows');
      expect(ignore, contains('/$path'), reason: '$path 必须被 .gitignore 精确排除');
    }
  });

  test('PL_API_VER == DLL 名里的版本 == fork placebo_pass.cc 的 kPlaceboDll', () {
    final String config = File(
      '$root/include/libplacebo/config.h',
    ).readAsStringSync();
    final RegExpMatch? m = RegExp(
      r'#define PL_API_VER (\d+)',
    ).firstMatch(config);
    expect(m, isNotNull, reason: 'config.h 必须是构建生成的那份（含 PL_API_VER）');
    final String ver = m!.group(1)!;
    expect(File('$root/bin/libplacebo-$ver.dll').existsSync(), isTrue);
    final String pass = File(
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/placebo_pass.cc',
    ).readAsStringSync();
    expect(pass, contains('L"libplacebo-$ver.dll"'));
    // 导出名带 API 版本后缀的只有 pl_log_create_<ver>：fork 经宏字符串化取名，头文件版本一变自动跟。
    expect(pass, contains('PL_STR(pl_log_create)'));
  });

  test('fork CMake 接入：头文件目录 + 通道源码 + DLL 进 bundled_libraries', () {
    final String cmake = File(
      '../packages/flutter_inappwebview_windows/windows/CMakeLists.txt',
    ).readAsStringSync();
    expect(cmake, contains('third_party/libplacebo-win'));
    expect(cmake, contains('HAVE_LIBPLACEBO_HEADERS'));
    expect(cmake, contains('custom_platform_view/placebo_pass.cc'));
    expect(cmake, contains(r'${LIBPLACEBO_WIN_DLLS}'));
    expect(
      RegExp(
        r'set\(flutter_inappwebview_windows_bundled_libraries\s+\$\{LIBPLACEBO_WIN_DLLS\}\s+PARENT_SCOPE',
      ).hasMatch(cmake),
      isTrue,
      reason: 'DLL 必须进 bundled_libraries 才会落到 fushi.exe 同级',
    );
  });

  test('UPSTREAM.md 记了版本与哈希来源', () {
    final String up = File('$root/UPSTREAM.md').readAsStringSync();
    expect(up, contains('v7.360.1'));
    expect(up, contains('SHA256SUMS'));
    expect(utf8.encode(up).length, greaterThan(500));
  });
}
