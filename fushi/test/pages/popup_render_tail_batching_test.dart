import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 查词弹窗「渲染尾巴」行为守卫（Node 真执行 popup.js，见同名 .js）。
///
/// 守的是 BUG-2039 的四条修复各自的可观测行为，而不是源码字面：
/// ① `layoutMasonry` 三相批处理——所有卡片的 width 写先于任何 `offsetHeight` 读
///    （逐卡写完立刻读 = 每卡一次强制同步布局）；
/// ② `markMasonryDirty(body)` + `scheduleMasonry()` 只重铺该 body，无标脏 /
///    `scheduleMasonryAll()` 才全量（回到全量重铺 = O((词条×词典)²) 次回流）；
/// ③ 尾批一个宏任务里按时间预算连续建多块，但仍让出主线程（宏任务数 ≥ 2）；
/// ④ `scheduleRenderTail` 有 MessageChannel 走它（FIFO），没有回落 `setTimeout(fn, 0)`。
///
/// 变异实测（改完立即还原，每条都红）：
/// - 把相 3 的批量量高挪回相 2 的 forEach 内（逐卡读）→ ① 红；
/// - `scheduleMasonry` 的 RAF 回调改回 `layoutMasonry()` 无参全量 → ② 红；
/// - 尾批 `do … while` 的预算条件改成 `false`（一块一任务）→ ③ 红；
/// - `scheduleRenderTail` 无条件 `setTimeout(task, 0)` → ④ 红。
///
/// 无 node 时 skip（与 popup_auto_expand_dictionaries_test.dart 同款约定）。
void main() {
  test('popup render tail: masonry batching / dirty scoping / sliced tail / '
      'MessageChannel primitive (executes popup.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File('test/pages/popup_render_tail_batching_test.js');
    expect(
      jsTest.existsSync(),
      isTrue,
      reason: 'behavior harness ${jsTest.path} must exist',
    );

    final ProcessResult result = await Process.run(nodeExe, <String>[
      jsTest.path,
    ], workingDirectory: Directory.current.path);

    expect(
      result.exitCode,
      0,
      reason:
          'popup render-tail JS behavior test failed.\n'
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
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
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
