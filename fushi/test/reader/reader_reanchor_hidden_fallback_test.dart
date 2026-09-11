import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 重锚落定的帧调度必须能在隐藏页面里落定（`_reanchorFrame`：可见走 rAF，
/// `document.hidden` 走 setTimeout(0)）。2026-09-12 Mac 隐藏 runner 探针实测
/// hidden=true / raf=0：四条「置旗 → rAF → finally 清旗」的重锚路径全部卡死，
/// `_reanchorPending` 永远为真，进度快照恒 null、阅读位置不落库、账本不 arrive。
/// 行为本体在 `reader_reanchor_hidden_fallback_behavior_test.js`；这里钉源码形状 +
/// 驱动 node。
void main() {
  final String src = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();

  test('_reanchorFrame：hidden → setTimeout(0)，否则 requestAnimationFrame', () {
    final int s = src.indexOf('  _reanchorFrame: function(fn) {');
    expect(s, greaterThanOrEqualTo(0));
    final String body = src.substring(s, src.indexOf('\n  },\n', s));
    expect(body, contains('document.hidden === true'));
    expect(body, contains('setTimeout(fn, 0)'));
    expect(body, contains('requestAnimationFrame(fn)'));
  });

  test('四条置旗后延帧清旗的重锚路径都经 _reanchorFrame，不得裸用 rAF', () {
    expect(
      'this._reanchorFrame(function() {'.allMatches(src).length,
      greaterThanOrEqualTo(4),
      reason: '分页 / 连续 × restoreToCharOffset / updatePageSize 四处',
    );
    // 「rAF 回调里 finally 清旗」的旧形状不得回潮：清旗只能在 _reanchorFrame 调度的
    // 回调里。
    final RegExp bare = RegExp(
      r'requestAnimationFrame\(function\(\) \{\s*try \{[^}]*\} finally \{\s*self\._setReanchorPending\(false\);',
    );
    expect(bare.hasMatch(src), isFalse);
  });

  test('_reanchorFrame 行为（node）', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final ProcessResult result = await Process.run(
        nodeExe,
        <String>[
          'test/reader/reader_reanchor_hidden_fallback_behavior_test.js',
        ],
        workingDirectory: Directory.current.path);
    expect(
      result.exitCode,
      0,
      reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('reader_reanchor_hidden_fallback_behavior_test: ok'),
    );
  });
}

String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      continue;
    }
  }
  return null;
}
