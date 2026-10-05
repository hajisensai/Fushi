import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 移动端 EPUB 选区拖动命中**行为**测试（问题：「手柄拖到字缝/行尾/行距/段间空白就卡住，
/// 松手再拖也过不去」）。
///
/// 与既有的 `reader_longpress_vs_swipe_behavior_test.dart` 同一范式：Node 真跑**生产代码**
/// （`reader_selection_drag_hit_behavior_test.js` 从 `reader_selection_scripts.dart` 的
/// `source()` 原始字符串里 verbatim 抽出 `window.fushiSelection`），对着一个复现真实 WebView
/// 几何的 fake DOM 回放拖动坐标序列。
///
/// 为什么不能用源码扫描守：BUG-765 的教训——守卫全绿而真机手柄仍拖不动，因为缺陷是**几何**
/// 的（严格命中要求手指压在字符矩形上）。所以这里断言真行为：
///   * 字缝（两端对齐撑开的空白）里继续拖 -> 端点必须前进；
///   * 行尾/行首空白 -> clamp 到本行，且不跳到相邻行；
///   * 行距 / 段末 -> 归最近的一行 / 本段末字；
///   * 无原生 caret API 时的几何兜底同样不卡；
///   * 拉丁词长按选整词、拖动吸附词边界；CJK 保持字符级；
///   * 竖排 vertical-rl 轴向互换后同样不卡；
///   * 分页页边距带（BUG-1797）绝不选中被 clip 掉的相邻页字符；
///   * 手柄横扫（跨越字缝/行尾/行距）端点单调前进、永不冻结；
///   * 纯空白文本节点端点规范化（否则区间游走会把选区撑到文末）。
///
/// 本机 / CI 无 node 时 skip（源码契约由 reader_selection_drag_hit_guard_test.dart 兜底）。
void main() {
  test(
    'selection drag hit-testing: gaps / line ends / line pitch keep the handle '
    'moving (BUG-2951)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final File harness = File(
        'test/reader/reader_selection_drag_hit_behavior_test.js',
      );
      expect(
        harness.existsSync(),
        isTrue,
        reason: 'behavior harness ${harness.path} must exist',
      );

      final ProcessResult result = await Process.run(nodeExe, <String>[
        harness.path,
      ], workingDirectory: Directory.current.path);
      expect(
        result.exitCode,
        0,
        reason:
            'selection drag hit-testing harness failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      final String stdout = result.stdout.toString();
      // 每条 scenario 都执行到（不是零执行被伪装成通过）。
      for (final String scenario in <String>[
        '1_inter_char_gap_advances',
        '2_line_end_clamps_to_line',
        '3_next_line_right_blank_clamps_to_that_line',
        '4_below_paragraph_clamps_to_last_glyph',
        '5_geometric_fallback_without_native_caret_api',
        '6_latin_drag_is_character_precise',
        '7_latin_long_press_selects_word',
        '8_latin_drag_can_shrink_into_the_anchor_word',
        '9_cjk_stays_character_granular',
        '10_vertical_writing_gap_does_not_freeze',
        '11_page_margin_band_never_selects_clipped_neighbour',
        '12_strict_hit_unchanged',
        '13_handle_drag_sweep_never_freezes',
        '14_whitespace_only_node_endpoint_normalized',
        '15_handle_drag_under_grip_still_advances',
        '16_text_drag_under_grip_still_advances',
      ]) {
        expect(
          stdout,
          contains('SCENARIO $scenario ::'),
          reason: 'harness must execute $scenario',
        );
        expect(
          stdout,
          isNot(contains('SCENARIO $scenario :: FAILED')),
          reason: '$scenario failed',
        );
      }
      expect(stdout, contains('passed 16 cases'));
      expect(stdout, contains('all assertions passed'));
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
