import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_deep_link.dart';

/// BUG-1666：制卡后卡片上「词典释义里指向另一个单词」的链接点开跳向
/// `http://127.0.0.1:<端口>`（Anki 桌面/AnkiDroid 的本地媒体服务器 base URL 把
/// 释义里保留的 `entry://` / 相对路径交叉引用解析成了死本地页）。
///
/// 修复分三段，三层守护对应：
/// ① 行为级——node 真执行 popup.js 的 `rewriteExportedGlossaryAnchors`，断言
///    entry://、相对路径改写成 `fushi://lookup?word=<词>` 深链、外链/`#` 保留、
///    sound:// 与无文本锚点去 href；并源级断言两个导出构建器
///    （constructGlossaryHtml / constructSingleGlossaryHtml）都在序列化前调用它。
///    无 node 时 skip。
/// ② 三镜像逐字节一致由 `browser_extension_popup_parity_guard_test.dart` 守。
/// ③ 深链消费端——`lookupWordFromDeepLink` 纯函数（Windows 冷启动 argv /
///    单实例 WM_COPYDATA 转交两条路共用）在本文件直接单测；Android 端同参数由
///    Kotlin `extractProcessText` 解析（scheme 须含 "fushi"，见源级守卫）。
void main() {
  test(
    'BUG-1666: exported glossary cross-references become fushi://lookup deep '
    'links (executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/anki/exported_glossary_anchor_deeplink_test.js');
      expect(jsTest.existsSync(), isTrue,
          reason: 'behavior harness ${jsTest.path} must exist');

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'BUG-1666 exported anchor deep-link behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'),
          reason: 'behavior harness must reach its success marker');
    },
  );

  group('lookupWordFromDeepLink', () {
    test('parses fushi://lookup?word=… (percent-decoded, trimmed)', () {
      expect(lookupWordFromDeepLink('fushi://lookup?word=belong'), 'belong');
      expect(
        lookupWordFromDeepLink(
            'fushi://lookup?word=%E9%A3%9F%E3%81%B9%E3%82%8B'),
        '食べる',
      );
      expect(lookupWordFromDeepLink(' fushi://lookup?word=%20belong%20 '),
          'belong');
    });

    test('accepts the legacy hibiki scheme', () {
      expect(lookupWordFromDeepLink('hibiki://lookup?word=belong'), 'belong');
    });

    test('rejects non-lookup URLs and empty words', () {
      expect(lookupWordFromDeepLink('fushi://auth/onedrive?code=x'), isNull);
      expect(lookupWordFromDeepLink('fushi://lookup'), isNull);
      expect(lookupWordFromDeepLink('fushi://lookup?word='), isNull);
      expect(lookupWordFromDeepLink('fushi://lookup?word=%20'), isNull);
      expect(
          lookupWordFromDeepLink('https://example.com/?word=belong'), isNull);
      expect(lookupWordFromDeepLink(r'D:\video\ep01.mkv'), isNull);
      expect(lookupWordFromDeepLink(''), isNull);
    });
  });

  test(
      'Android :popup activities accept the fushi scheme for lookup deep links '
      '(source guard)', () {
    const List<String> activities = <String>[
      'android/app/src/main/java/app/fushi/reader/PopupDictFlutterActivity.kt',
      'android/app/src/main/java/app/fushi/reader/PopupDictActivity.kt',
    ];
    for (final String path in activities) {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path must exist');
      final String source = file.readAsStringSync();
      // 断言字面量写进注释，变异测试时能定位：manifest 注册的 scheme 是
      // "fushi"，Kotlin 侧曾只认 "hibiki"（改名残留）导致深链开出空弹窗。
      expect(source, contains('uri.scheme == "fushi"'),
          reason: '$path must accept the fushi scheme (manifest registers it)');
    }
  });
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
