import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2466：连续模式听书跟随滚动跨过一个视口以上必须瞬时落地（smooth 补间会把途中
/// 所有页 arrive 进阅读账本 = 字数虚增 / 字/时爆表）；一个视口之内保持 TODO-825 的
/// smooth 跟读动画。行为本体在 `reader_follow_scroll_jump_behavior_test.js`
/// （node vm 原样执行 `scrollToTarget`），这里驱动它并钉源码形状。
void main() {
  test('scrollToTarget：followBehavior 按位移 vs 视口选 smooth / auto（源码）', () {
    final String src = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
    final int s = src.indexOf('  scrollToTarget: function(target) {');
    final int e = src.indexOf('  revealElement: function(element) {', s);
    expect(s, greaterThanOrEqualTo(0));
    expect(e, greaterThan(s));
    final String body = src.substring(s, e);
    expect(body, contains('var followBehavior = function(delta, viewport) {'));
    expect(
      body,
      contains("return Math.abs(delta) > viewport ? 'auto' : behavior;"),
    );
    expect(body, contains('behavior: followBehavior(dx, vw)'));
    expect(body, contains('behavior: followBehavior(dy, vh)'));
  });

  test('scrollToTarget 行为（node）', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final File jsTest = File(
      'test/reader/reader_follow_scroll_jump_behavior_test.js',
    );
    expect(jsTest.existsSync(), isTrue);
    final ProcessResult result = await Process.run(
        nodeExe,
        <String>[
          jsTest.path,
        ],
        workingDirectory: Directory.current.path);
    expect(
      result.exitCode,
      0,
      reason: 'follow scroll JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('reader_follow_scroll_jump_behavior_test: ok'),
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
