@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show readerFushiEngineSourceUncompacted;
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// BUG-2903：滚动模式往下滚会卡在某处停一会。
///
/// 滚动中每帧的进度回报（onReaderScroll → fushiProgressDetails）在连续 shell 里
/// 对整章做三遍 walk，后两遍逐节点 getClientRects——6000 个文本节点的长章一次
/// 150–200ms，滚轮 rAF 缓动在其间冻住。修复后进度走章内文本索引 + 二分：
/// 真 Chrome 跑生产连续 shell，断言数值与旧全章累加逐点一致（横排 / 竖排）、
/// 单次回报的几何查询是对数级、正文 DOM 变化同步失效索引。
void main() {
  test('continuous progress uses the chapter text index with the same numbers '
      'and logarithmic geometry in real Chrome', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS execution');
      return;
    }
    final Directory temp = Directory.systemTemp.createTempSync('cprogress-');
    try {
      final File payload = File('${temp.path}/engine.json')
        ..writeAsStringSync(
          jsonEncode(<String, String>{
            'engine': ReaderPaginationScripts.engineShell(
              vnMode: false,
              continuousMode: true,
            ),
          }),
        );
      final ProcessResult result = await Process.run(nodeExe, <String>[
        'test/reader/continuous_progress_text_index_harness.mjs',
        payload.path,
      ]).timeout(const Duration(seconds: 120));
      if (result.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${result.stdout}');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS 2 browser cases'));
    } finally {
      temp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 150)));

  test(
    'host progress details reads the cached chapter total before walking',
    () {
      final String engine = readerFushiEngineSourceUncompacted(
        continuousMode: true,
      );
      final int start = engine.indexOf(
        'window.fushiProgressDetails = function()',
      );
      expect(start, isNonNegative);
      final String details = engine.substring(
        start,
        engine.indexOf('\n  };', start),
      );
      final int cached = details.indexOf('r.chapterCharTotal()');
      final int walk = details.indexOf('r.createWalker()');
      expect(cached, isNonNegative);
      expect(walk, greaterThan(cached));
      expect(
        ReaderPaginationScripts.continuousShellSource(),
        contains('chapterCharTotal: function()'),
      );
    },
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
