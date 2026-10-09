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
///   * 拉丁词长按选整词、拖动保持字符级；CJK 保持字符级；
///   * 竖排 vertical-rl 轴向互换后同样不卡；
///   * 分页页边距带（BUG-1797）绝不选中被 clip 掉的相邻页字符；
///   * 手柄横扫（跨越字缝/行尾/行距）端点单调前进、永不冻结；
///   * 纯空白文本节点端点规范化及失败保持旧选区。
///
/// New lifecycle cases run real document/handle listeners and assert coordinates
/// and visibility synchronously after every event; this is not a compositor or
/// physical-touch device test. Both CSS Highlights and non-mutating fallback run.
/// Interior handles preserve endpoint anchors; edge hit targets remain bounded.
/// Node is required locally and in CI: fail explicitly when unavailable.
void main() {
  test(
    'selection drag hit-testing: gaps / line ends / line pitch keep the handle '
    'moving (BUG-3047)',
    () async {
      final String nodeExe = _resolveNode();
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
        '17_native_api_fallback_order',
        '18_normalization_direction_and_boundary',
        '19_normalization_failure_is_not_a_raw_endpoint',
        '20_failed_drag_preserves_current_selection',
        '21_stationary_longpress_keeps_word',
        '22_drag_release_uses_last_coordinate',
        '23_no_stack_endpoint_window',
        '24_window_restores_exact_style_even_on_throw',
        '25_viewport_clear_and_bridge_order',
        '26_handle_release_uses_last_coordinate',
        '27_cancelled_drag_does_not_block_viewport_clear',
        '28_longpress_live_coordinates_each_move',
        '29_handle_listener_live_coordinates_and_bridge',
        '30_clear_then_late_end_does_not_revive_menu',
        '31_detached_dom_cancels_drag_and_late_end',
        '32_begin_resolves_after_wrapper_normalize',
        '33_handles_rect_and_legacy_top_layer_contract',
        '34_edge_touch_boxes_bounded_and_independently_grabbable',
        '35_offscreen_endpoints_are_not_clamped_into_view',
        '36_edge_small_viewport_has_explicit_geometry_limit',
        '37_interior_handles_keep_endpoint_anchors',
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
      expect(stdout, contains('passed 37 cases'));
      expect(
        RegExp(r'^SCENARIO ', multiLine: true).allMatches(stdout).length,
        37,
      );
      // Keep the complete corner matrix and both interior rendering paths.
      expect(
        stdout,
        contains(
          'SCENARIO 34_edge_touch_boxes_bounded_and_independently_grabbable '
          ':: {"cases":32}',
        ),
      );
      expect(
        stdout,
        contains(
          'SCENARIO 37_interior_handles_keep_endpoint_anchors '
          ':: {"cases":32}',
        ),
      );
      for (final String mutation in <String>[
        'early_restore',
        'bypass_text_window',
        'skip_range_fallback',
        'raw_endpoint_fallback',
        'one_direction_only',
        'reset_to_anchor',
        'drop_release',
        'lose_stationary_word',
        'restore_auto',
        'clear_busy_viewport',
        'skip_empty_notification',
        'hide_until_release',
        'freeze_text_handles',
        'freeze_handle_handles',
        'skip_drag_bridge',
        'late_end_without_session',
        'ignore_detached_nodes',
        'reuse_pre_normalize_hit',
        'skip_handles_rect_payload',
        'reopen_live_touch_target',
        'skip_touch_box_clamp',
        'overlap_clamped_grips',
        'displace_interior_anchors',
        'clamp_offscreen_endpoints',
      ]) {
        expect(stdout, contains('MUTATION $mutation :: KILLED'));
      }
      expect(stdout, contains('killed 24 mutations'));
      expect(stdout, contains('all assertions passed'));
    },
  );
}

/// Resolve Node or fail: a missing runtime must never turn behavior tests green.
String _resolveNode() {
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
  throw StateError(
    'Node.js is required for reader selection behavior/mutation tests; install Node and add it to PATH.',
  );
}
