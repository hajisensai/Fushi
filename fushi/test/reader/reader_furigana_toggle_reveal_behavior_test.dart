import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 振假名三态 `toggle`（对齐 Hoshi Reader iOS FuriganaMode.toggle）的行为级守卫：
/// 用 node 执行 `reader_furigana_toggle_reveal_behavior_test.js`，它从
/// `reader_selection_scripts.dart` 原样切出生产的 `_hiddenFuriganaRubyAt` /
/// `selectText`，断言「点隐藏注音的 ruby = 只揭示、不查词、不算点空白」，以及
/// hidden 态 / 已揭示 / 注音可见 / 悬停查词四种情况照常查词。
///
/// 当本机/CI 没有 node 时自动 skip；有 node 的环境真跑。
void main() {
  test(
      'tapping a hidden-furigana ruby reveals it without lookup '
      '(executes fushiSelection.selectText via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File(
      'test/reader/reader_furigana_toggle_reveal_behavior_test.js',
    );
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
      reason: 'furigana toggle reveal JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('all assertions passed'),
      reason: 'behavior harness must reach its success marker',
    );
  });

  test('selectText reveals before lookup and never for hover (source guard)',
      () {
    final String src =
        File('lib/src/reader/reader_selection_scripts.dart').readAsStringSync();
    final int reveal =
        src.indexOf('var hiddenRuby = this._hiddenFuriganaRubyAt(x, y);');
    final int lookup = src.indexOf('var hit = this.getCharacterAtPoint(x, y);');
    expect(reveal, greaterThanOrEqualTo(0));
    expect(lookup, greaterThan(reveal), reason: '揭示判断必须在取字查词之前');
    final String between = src.substring(reveal - 40, lookup);
    expect(between, contains('if (!fromHover) {'), reason: '悬停查词不得揭示振假名');
    expect(between, contains("classList.add('furigana-revealed')"));
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
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
