import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-553: paged-mode touch swipe must turn the page.
///
/// 回归背景：commit 890378f19 把 touch 纳入 pointer 拖动状态机（pointerdown 的
/// 门控从 `e.pointerType !== 'mouse'` 改成 `_hoshiReaderPointerPrimaryButton(e)`，
/// 对 touch 返 true）。分页模式下 touch 因此走进 native-text-start 抑制路径：
/// pointermove 超 6px 清掉 `hasStart`，touchend 被吞，`onSwipe` 永不触发 → 触摸
/// 滑动不再翻页。原静态守卫只断言源码子串，没执行 JS，漏掉了这个回归。
///
/// 这里在 `flutter test` 内通过 Node 真执行从 reader_hibiki_page.dart 抽取的
/// 真实事件处理器（伪 DOM + 派发 pointer/touch 事件序列），断言分页模式触摸
/// 横滑触发 onSwipe。撤掉 TODO-553 修复，该 Node 测试断言失败、本 Dart 守卫转红。
///
/// 防假绿的两个关键（上一版守不住回归的根因）：
/// ① 伪 DOM 必须实现 `caretRangeFromPoint` 并返回落在 TEXT_NODE 上的 range，
///    模拟手指真落在正文文字上 → 分页模式 `_hoshiReaderMouseDragStartAllowed`
///    在 `return !_hoshiReaderCaretRangeAtPoint(...)` 处得 `!range`=false，走
///    native-text 抑制路径（正确的正文行为）。缺 caret 时 helper 返 null、
///    `!null`=true，回归版会误进 pointer 拖动机却仍从 pointerup 发 onSwipe，
///    掩盖 bug。② 断言区分 onSwipe 来源（`left@touchend` vs `left@pointerup`）：
///    分页 touch 横滑的翻页必须由 touchend 路径发出，pointerup 在分页 touch 下
///    不得发 onSwipe。修复版得 `['left@touchend']`，回归版在本正文 caret 下
///    彻底丢失 swipe 得 `[]`（已实测）。
///
/// 当本机/CI 没有 node 时自动 skip（Node 守卫不强制进无 node 环境），但本地
/// 与装有 node 的环境都会真跑，提供静态守卫缺失的行为级覆盖。
void main() {
  test(
      'paged-mode touch swipe fires onSwipe (executes reader handlers via node)',
      () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File(
      'test/reader/reader_paged_touch_swipe_behavior_test.js',
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
      reason: 'reader handler JS behavior test failed.\n'
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
