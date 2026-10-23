import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// BUG-3664：英文 `time-blackened` 点 blackened 只查到 time（用户报「只能查到前面」）。
/// 根因：点词的「回退到词首」只停在空白 / 标点上，跨过连字符一路退回 time，喂给
/// 引擎的是「time-blackened oak…」，词典没有这个复合词就只匹配出前半截。修复：回退
/// 终点改为 `isTokenStartBoundary`（= isScanBoundary + 词内连字符），前向扫描不变。
///
/// BUG-3665：在页边（翻页模式一页的首行）点一个被断在两页的词，查词卡被挤成贴底的
/// 一条。根因：`highlightSelection` 把词的全部字形片段（含上一页屏外那段）并成锚点
/// 矩形，并集从页顶拉到页底，`calcPopupPosition` 上下都没空间。修复：
/// `anchoredWordBounds` 只取视口内、与点中片段相邻的片段。
///
/// 行为级：node 真执行浮窗/扩展的 selection.js 与阅读器注入脚本
/// （`ReaderSelectionScripts.source()` 真值落临时文件）。无 node 时 skip。
void main() {
  test(
    'BUG-3664/3665: hyphen stops the word-start back-off; popup anchor keeps '
    'only the visible tapped fragment (executes the selection engines via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final File jsTest = File(
        'test/lookup/hyphen_word_start_and_anchor_bug3664_test.js',
      );
      expect(jsTest.existsSync(), isTrue);

      final Directory tmp = Directory.systemTemp.createTempSync(
        'fushi_bug3664_',
      );
      final File readerJs = File('${tmp.path}/reader_selection.js');
      readerJs.writeAsStringSync(ReaderSelectionScripts.source());
      try {
        final ProcessResult result = await Process.run(
          nodeExe,
          <String>[jsTest.path],
          workingDirectory: Directory.current.path,
          environment: <String, String>{
            'FUSHI_READER_SELECTION_JS': readerJs.path,
          },
        );
        expect(
          result.exitCode,
          0,
          reason:
              'BUG-3664/3665 behavior test failed.\n'
              'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        final String stdout = result.stdout.toString();
        expect(stdout, contains('all assertions passed'));
        expect(
          stdout,
          isNot(contains('reader selection script not provided')),
          reason: '阅读器注入脚本必须被 harness 真执行（真值来自 source()）',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    },
  );

  test(
    'highlightSelection anchors via anchoredWordBounds with the tap point',
    () {
      final String src = ReaderSelectionScripts.source();
      expect(
        src.contains('var bounds = this.anchoredWordBounds('),
        isTrue,
        reason:
            'BUG-3665: highlightSelection 必须经 anchoredWordBounds 求锚点，'
            '不得退回全部片段的并集',
      );
      expect(
        src.contains('this.selection.point = { x: x, y: y };'),
        isTrue,
        reason: 'BUG-3665: 点词时必须记下点击点，锚点才能挑中用户点的那一段',
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
      // try next
    }
  }
  return null;
}
