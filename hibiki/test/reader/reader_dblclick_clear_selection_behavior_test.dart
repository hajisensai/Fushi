import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1028 / BUG-481: a native double-click that establishes a text selection
/// must NOT hijack single-tap lookup, and must NOT block the furigana whole-page
/// double-click toggle.
///
/// 回归背景：WebView 原生双击在正文上建立蓝色框选（`selectstart` 抑制只挡拖动起手
/// 400ms 内、不挡双击；正文 `_hoshiReaderMouseNativeTextStart=true` 放过双击选词），
/// 盖住单击查词的 CSS Highlight，并把振假名整页切换（`_buildFuriganaJs` 'toggle' 分支
/// 的 dblclick handler 带 `if (sel && !sel.isCollapsed) return` 守卫）绊住——双击自己
/// 产生的选区让守卫早退，振假名不切换。修复在 `_buildReaderSetupScript` 加 capture 阶段
/// dblclick → `removeAllRanges()`，先于振假名 bubble handler 清掉选区，振假名切换反而
/// 恢复正常。
///
/// 这里在 `flutter test` 内通过 Node 真执行从 webview.part.dart 抽取的两个真实
/// dblclick handler（伪 DOM + capture→bubble 顺序派发），断言双击后选区被清
/// （isCollapsed===true）且 show-all-rt 仍被 toggle（振假名保留）。撤掉修复，Node
/// 断言失败、本 Dart 守卫转红。
///
/// 当本机/CI 没有 node 时自动 skip，但本地与装有 node 的环境都会真跑，提供静态守卫
/// 缺失的行为级覆盖。
void main() {
  test(
      'double-click clears native selection but still toggles furigana '
      '(executes reader handlers via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File(
      'test/reader/reader_dblclick_clear_selection_behavior_test.js',
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
      reason: 'reader dblclick handler JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('all assertions passed'),
      reason: 'behavior harness must reach its success marker',
    );
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
