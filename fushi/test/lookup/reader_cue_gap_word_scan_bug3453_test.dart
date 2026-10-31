import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// BUG-3453：英文有声书（SRT 字幕把一句话拆成多条 cue）里，每条 cue 的最后一个词
/// 点了查不到（`greeted us` 的 us、`boy with` 的 with），以标点收尾的（`hair.`）正常。
///
/// 根因：有声书句子高亮把每条 cue 的文字各自包进 wrapper，cue 之间的空格成了 wrapper
/// 之间独立的纯空白文本节点；阅读器 `createWalker` 跳过纯空白节点（TODO-956），前向取词
/// 于是把 "us" 和下一条 cue 的 "belonged" 粘成 "usbelonged"，句子里也丢了这个空格。
///
/// 行为级：用 node 真执行阅读器注入脚本 `ReaderSelectionScripts.source()` 的
/// `selectFromPosition` / `getSentenceContext` / `textBetween`。无 node 时 skip。
void main() {
  test(
    'BUG-3453: whitespace gap between audiobook cue wrappers ends the word scan '
    'and survives in the sentence (executes reader selection script via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final File jsTest = File(
        'test/lookup/reader_cue_gap_word_scan_bug3453_test.js',
      );
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final Directory tmp = Directory.systemTemp.createTempSync(
        'fushi_bug3452_',
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
              'BUG-3453 behavior test failed.\n'
              'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        expect(
          result.stdout.toString(),
          contains('all assertions passed'),
          reason: 'behavior harness must reach its success marker',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    },
  );
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
