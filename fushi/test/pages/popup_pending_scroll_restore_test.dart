import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 弹窗内原地跳转：后退 / 前进回到历史页时的滚动位恢复（Node 真执行 popup.js，
/// 见同名 .js）。
///
/// 守的是 `__fushiApplyPendingScrollTop` 的可观测行为：没有 pending 不动；非 final
/// 且文档不够高时**不滚、pending 保留**（提前滚会被夹到底、再被后续内容顶回去）；
/// 够高即滚到位并清零；final 兜底一律应用并清零。Dart 侧 / 三处调用点的接线守卫在
/// dictionary_popup_inplace_navigation_test.dart。无 node 时 skip（与
/// popup_render_tail_batching_test.dart 同款约定）。
void main() {
  test('popup pending scroll restore (executes popup.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File('test/pages/popup_pending_scroll_restore_test.js');
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
      reason: 'popup pending-scroll JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // try next candidate
    }
  }
  return null;
}
