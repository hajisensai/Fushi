@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_caret_scripts.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

/// 路线图 m1 实测（桌面 headless Chrome，10 万字单章）：
///
/// - BUG-5028 / gap-readerjs1-3：分页章末一次 `fushiProgressDetails` 19ms、插图页（页首 caret 落图走
///   扫描兜底）56ms——「字符偏移 → 文本节点」、越界判据、扫描兜底都从章首逐节点 walk。
///   修复后共用连续 shell 的章内文本索引（BUG-2903）+ 二分。
/// - BUG-5021 / gap-readerjs2-2：光标换行移动每按一次键对整章逐字 getClientRects（113892 次、约
///   620ms）。修复后先按文本节点行盒判是否与视口相交，不相交的整节点跳过（同章降到
///   约 13ms）。
///
/// 真 Chrome 跑生产分页 shell + 光标脚本，断言数值 / 落点与旧算法逐点一致、扫描兜底的
/// 几何查询是对数级、光标一次移动的几何查询远少于章内字数、正文 DOM 变化同步失效索引。
void main() {
  test(
    'paged offsets use the shared text index and caret line moves only measure '
    'glyphs of on-page text nodes, with unchanged results in real Chrome',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('paginated');
      final Map<String, String> css = <String, String>{};
      for (final String mode in <String>['horizontal-tb', 'vertical-rl']) {
        await settings.setWritingMode(mode);
        css[mode] = ReaderContentStyles.css(settings: settings);
      }
      final ({int exitCode, String stdout, String stderr}) result =
          await _runNodeHarness(
            nodeExe,
            'test/reader/paged_text_index_caret_harness.mjs',
            <String, Object?>{
              'engine': ReaderPaginationScripts.engineShell(
                vnMode: false,
                continuousMode: false,
              ),
              'caret': ReaderCaretScripts.source(),
              'css': css,
              'config': <String, Object?>{
                'vnMode': false,
                'continuousMode': false,
                'perfTraceEnabled': false,
                'chromeTopInset': 0,
                'chromeBottomInset': 0,
                'dartPageWidth': 1000,
                'dartPageHeight': 800,
                'initialFragment': null,
                'initialCharOffset': -1,
                'initialProgress': 0,
                'sentenceAudioCues': null,
              },
            },
          );
      if (result.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${result.stdout}');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS 2 browser cases'));
    },
    timeout: const Timeout(Duration(seconds: 150)),
  );
}

Future<({int exitCode, String stdout, String stderr})> _runNodeHarness(
  String nodeExe,
  String harness,
  Map<String, Object?> payload,
) async {
  final Process process = await Process.start(nodeExe, <String>[harness]);
  final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(utf8.encode(jsonEncode(payload)));
  await process.stdin.close();
  return (
    exitCode: await process.exitCode,
    stdout: await stdout,
    stderr: await stderr,
  );
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}
