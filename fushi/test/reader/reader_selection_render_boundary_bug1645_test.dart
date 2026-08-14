import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// BUG-1645（阅读器引擎侧）：阅读器有一份与 popup `selection.js` 同构、但独立维护的
/// 取词引擎（[ReaderSelectionScripts.source]），正文 / 歌词模式 / 漫画覆盖层 /
/// 键盘手柄 caret 全部复用它的 `selectFromPosition`。它的 `selectFromPosition` 与
/// `getSentenceContext` 同样跨文本节点续扫，会把渲染上分开的两段文字粘成一串——
/// 对拉丁语系是致命的（C++ `scan_candidates` 禁止在单词中间切，粘住的
/// `acridpungent` 永远还原不出 `acrid`，查词必然无结果）。
///
/// 行为守卫：把**真实注入脚本**（`source()`，不是复制粘贴的副本）dump 到临时文件，
/// 用 node 在 fake DOM 里真执行，断言三件事：
/// ① 嵌套块边界处取词收手；② 行内连排仍跨节点拼接（`<b>ac</b>rid` 不回归）；
/// ③ 句子提取同样在渲染断点处收句。
void main() {
  test(
    'BUG-1645: reader selection stops at a render boundary '
    '(executes the real injected source via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/reader/reader_selection_render_boundary_bug1645_test.js');
      expect(jsTest.existsSync(), isTrue,
          reason: 'behavior harness ${jsTest.path} must exist');

      final Directory temp =
          Directory.systemTemp.createTempSync('bug1645_reader_selection');
      try {
        final File dumped = File('${temp.path}/reader_selection.js');
        dumped.writeAsStringSync(ReaderSelectionScripts.source());

        final ProcessResult result = await Process.run(
          nodeExe,
          <String>[jsTest.path, dumped.path],
          workingDirectory: Directory.current.path,
        );

        expect(
          result.exitCode,
          0,
          reason: 'BUG-1645 reader render-boundary behavior test failed.\n'
              'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        expect(result.stdout.toString(), contains('all assertions passed'),
            reason: 'behavior harness must reach its success marker');
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
  );

  test('reader selection source keeps the render-boundary check wired in',
      () {
    final String source = ReaderSelectionScripts.source();
    // 断言字面量同时写进注释，变异测试时能定位（见 fast-workflow 的守卫纪律）。
    expect(source, contains('crossesRenderBoundary: function(from, to)'),
        reason: 'the reader engine must define the render-boundary check');
    expect(source,
        contains('this.crossesRenderBoundary(scanNode, nextScanNode)'),
        reason: 'the word scan must consult it before gluing the next node');
    expect(source,
        contains('this.crossesRenderBoundary(node, nextSentenceNode)'),
        reason: 'the forward sentence walk must consult it too');
    expect(source,
        contains('this.crossesRenderBoundary(prevSentenceNode, node)'),
        reason: 'the backward sentence walk must consult it too');
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
