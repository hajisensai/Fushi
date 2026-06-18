import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-240：分页 `paginate()` 在「这一步翻不动」时不应立刻跨章——必须用 settle 后
/// 重建的 metrics + DOM 实时 `maxScroll` 复核确认真到章节首/末页才跨章，避免陈旧/
/// 低估的 metrics.maxScroll 提前触发 `_handlePageTurnLimit` → `_navigateToChapter`。
///
/// 这是 JS `window.hoshiReader._stepWithFreshMetrics` 的纯 Dart 影子（headless WebView
/// 不可用，按项目测试范式：纯函数单测 + 源码守卫 reader_paginate_js_guard_static_test）。
void main() {
  const double pitch = 1000.0;

  bool crossForward(
    double current, {
    double metricsMax = 9000,
    double metricsMin = 0,
    double trueMax = 9000,
  }) =>
      ReaderPaginationScripts.shouldCrossChapterOnLimit(
        direction: ReaderNavigationDirection.forward,
        currentScroll: current,
        columnPitch: pitch,
        metricsMaxScroll: metricsMax,
        metricsMinScroll: metricsMin,
        trueMaxScroll: trueMax,
      );

  bool crossBackward(
    double current, {
    double metricsMax = 9000,
    double metricsMin = 0,
    double trueMax = 9000,
  }) =>
      ReaderPaginationScripts.shouldCrossChapterOnLimit(
        direction: ReaderNavigationDirection.backward,
        currentScroll: current,
        columnPitch: pitch,
        metricsMaxScroll: metricsMax,
        metricsMinScroll: metricsMin,
        trueMaxScroll: trueMax,
      );

  group('forward: do not cross chapter while content remains (BUG-240)', () {
    test('genuinely at the last content page → cross', () {
      // currentScroll == metricsMax == trueMax aligned → no next page.
      expect(crossForward(9000, metricsMax: 9000, trueMax: 9000), isTrue);
    });

    test(
        'stale/under-measured metricsMax must NOT cross when DOM still scrolls',
        () {
      // metrics 低估了末页（说 maxScroll=7000），但 DOM 实时可滚到 9000，且当前停在
      // 第 8 页（7000）。旧实现：targetForward=8000 > metricsMax(7000) → clamp 7000 →
      // 7000 <= 7000+1 → limit → 跨章（跳过 7000..9000 的内容）。修复后：用 trueMax
      // 派生的 9000 作容差上界 → 还能前进 → 不跨章。
      expect(crossForward(7000, metricsMax: 7000, trueMax: 9000), isFalse);
    });

    test('mid-chapter never crosses', () {
      expect(crossForward(3000, metricsMax: 9000, trueMax: 9000), isFalse);
    });

    test('sub-pixel under-measure of last content edge does not cross', () {
      // metricsMax 比真末页少 1px（8999），currentScroll 在末页前一页（8000）。
      // 仍应翻到末页而不是跨章。
      expect(crossForward(8000, metricsMax: 8999, trueMax: 9000), isFalse);
    });
  });

  group('backward: symmetric guard', () {
    test('at the first content page → cross to previous chapter', () {
      expect(crossBackward(0, metricsMin: 0), isTrue);
    });

    test('mid-chapter backward never crosses', () {
      expect(crossBackward(3000, metricsMin: 0), isFalse);
    });

    test('sub-pixel drift just past a page boundary does not cross', () {
      expect(crossBackward(1000.33, metricsMin: 0), isFalse);
    });

    test('clamped to metricsMin: at min already → cross', () {
      expect(crossBackward(1000, metricsMin: 1000), isTrue);
    });
  });

  group('degenerate geometry', () {
    test('zero or negative pitch crosses (cannot paginate)', () {
      expect(
        ReaderPaginationScripts.shouldCrossChapterOnLimit(
          direction: ReaderNavigationDirection.forward,
          currentScroll: 1000,
          columnPitch: 0,
          metricsMaxScroll: 9000,
          metricsMinScroll: 0,
          trueMaxScroll: 9000,
        ),
        isTrue,
      );
    });
  });
}
