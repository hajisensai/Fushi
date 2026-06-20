import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-169：阅读器分页 `paginate()` 从「可能未对齐到整页」的 currentScroll 出发，
/// 旧实现 forward 用 `round((currentScroll + pitch) / pitch) * pitch`，等价于
/// `(round(currentScroll/pitch) + 1) * pitch`。当 currentScroll 落在两页之间（snap
/// 监听器尚未把它对齐，或 pitch 微变导致的瞬时错位）时，`round` 会把当前页算成
/// 下一页，于是 forward 实际跳 2 页（backward 对称地可能卡住/跳回）。
///
/// 正确做法（消除「错位」特例）：forward 取严格在 currentScroll 之后的整页边界
/// （`floor(currentScroll/pitch) + 1`），backward 取严格之前的整页边界
/// （`ceil(currentScroll/pitch) - 1`）。整页对齐时与旧实现等价；错位时永远只走一页。
///
/// 这是 JS `window.hoshiReader.paginate` 的纯 Dart 影子（headless WebView 不可用，
/// 按项目测试范式：纯函数单测 + 源码守卫）。
void main() {
  const double pitch = 1000.0;

  ReaderPageStep stepForward(double scroll,
          {double min = 0, double max = 9000}) =>
      ReaderPaginationScripts.resolvePaginateStepForTesting(
        direction: ReaderNavigationDirection.forward,
        currentScroll: scroll,
        columnPitch: pitch,
        minAlignedScroll: min,
        maxAlignedScroll: max,
      );

  ReaderPageStep stepBackward(double scroll,
          {double min = 0, double max = 9000}) =>
      ReaderPaginationScripts.resolvePaginateStepForTesting(
        direction: ReaderNavigationDirection.backward,
        currentScroll: scroll,
        columnPitch: pitch,
        minAlignedScroll: min,
        maxAlignedScroll: max,
      );

  group('aligned scroll behaves exactly like single-page step', () {
    test('forward from an aligned page advances exactly one pitch', () {
      final ReaderPageStep step = stepForward(2000);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 3000);
    });

    test('backward from an aligned page retreats exactly one pitch', () {
      final ReaderPageStep step = stepBackward(2000);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 1000);
    });
  });

  group('sub-pixel page-boundary drift (Windows WebView)', () {
    test('backward from just past an aligned page retreats one full page', () {
      final ReaderPageStep step = stepBackward(2000.33);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 1000);
    });

    test('backward from just before an aligned page still retreats', () {
      final ReaderPageStep step = stepBackward(1999.4);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 1000);
    });

    test('forward from near an aligned page advances one full page', () {
      final ReaderPageStep step = stepForward(2000.33);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 3000);
    });
  });

  group('misaligned scroll never skips a page (BUG-169 regression)', () {
    test('forward from just-past-mid does NOT jump two pages', () {
      // 视觉上停在第 2 页内（2000..3000 之间，偏后 0.6 页）；旧实现 round(2.6)=3
      // → target 4000（跳到第 4 页起点，越过第 3 页）。正确：到 3000（第 3 页起点）。
      final ReaderPageStep step = stepForward(2600);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 3000,
          reason: 'forward 必须落到 currentScroll 之后最近的整页边界，不能跳 2 页');
    });

    test('forward from just-past-start advances one page', () {
      final ReaderPageStep step = stepForward(2300);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 3000);
    });

    test('backward from just-past-mid retreats to current page start', () {
      // currentScroll=2600（第 2 页偏后）；backward 应回到 2000（本页起点），
      // 不应卡在原地或越过。
      final ReaderPageStep step = stepBackward(2600);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 2000);
    });

    test('backward from just-past-start retreats to previous page start', () {
      final ReaderPageStep step = stepBackward(2300);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 2000);
    });
  });

  group('boundaries clamp and report limit', () {
    test('forward at last page returns limit', () {
      final ReaderPageStep step = stepForward(9000, max: 9000);
      expect(step.scrolled, isFalse);
    });

    test('backward at first page returns limit', () {
      final ReaderPageStep step = stepBackward(0, min: 0);
      expect(step.scrolled, isFalse);
    });

    test('forward target is clamped to maxAlignedScroll', () {
      final ReaderPageStep step = stepForward(8600, max: 9000);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 9000);
    });

    test('backward target is clamped to minAlignedScroll', () {
      final ReaderPageStep step = stepBackward(600, min: 0);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 0);
    });

    test('zero or negative pitch reports limit', () {
      final ReaderPageStep step =
          ReaderPaginationScripts.resolvePaginateStepForTesting(
        direction: ReaderNavigationDirection.forward,
        currentScroll: 1000,
        columnPitch: 0,
        minAlignedScroll: 0,
        maxAlignedScroll: 9000,
      );
      expect(step.scrolled, isFalse);
    });
  });

  // TODO-627 / BUG-349: settle-recheck 落点影子。插画页晚 load 致 metrics.maxScroll
  // 被低估，currentScroll 已停在被低估的「末页」时，旧落点把 dest clamp 回
  // currentScroll → 滚轮卡死（既不翻页也不跨章）。修复后 forward 落点用 trueMaxAligned
  // 容差上界，落到 DOM 实时可滚的真实整页边界。
  group('resolveFreshStepForTesting: image-page under-measure landing', () {
    ReaderPageStep freshForward(
      double current, {
      double metricsMax = 9000,
      double metricsMin = 0,
      double trueMax = 9000,
    }) =>
        ReaderPaginationScripts.resolveFreshStepForTesting(
          direction: ReaderNavigationDirection.forward,
          currentScroll: current,
          columnPitch: pitch,
          metricsMaxScroll: metricsMax,
          metricsMinScroll: metricsMin,
          trueMaxScroll: trueMax,
        );

    ReaderPageStep freshBackward(
      double current, {
      double metricsMax = 9000,
      double metricsMin = 0,
      double trueMax = 9000,
    }) =>
        ReaderPaginationScripts.resolveFreshStepForTesting(
          direction: ReaderNavigationDirection.backward,
          currentScroll: current,
          columnPitch: pitch,
          metricsMaxScroll: metricsMax,
          metricsMinScroll: metricsMin,
          trueMaxScroll: trueMax,
        );

    test(
        'under-measured metricsMax: forward lands on the real page edge, NOT '
        'clamped back to currentScroll (TODO-627 image-page stall)', () {
      // 图片晚 load：metrics 说 maxScroll=7000，但 DOM 实时可滚到 9000，currentScroll
      // 已停在被低估的末页(7000)。旧落点 dest=min(8000, max(7000,7000))=7000=currentScroll
      // → 不动却报 scrolled（卡死）。修复后 maxF=max(7000,9000)=9000 → 落到 8000。
      final ReaderPageStep step =
          freshForward(7000, metricsMax: 7000, trueMax: 9000);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 8000,
          reason: '落点必须推进到真实整页边界，而不是 clamp 回 currentScroll 卡死');
      expect(step.targetScroll, greaterThan(7000),
          reason: '落点必须真的前进，否则插画页滚轮既不翻页也不跨章');
    });

    test('genuinely at the last real page → no scroll (走 limit/跨章)', () {
      // currentScroll == trueMaxAligned == metricsMax → 真没下一页。
      final ReaderPageStep step =
          freshForward(9000, metricsMax: 9000, trueMax: 9000);
      expect(step.scrolled, isFalse);
      expect(step.targetScroll, 9000);
    });

    test('mid-chapter forward advances exactly one page (accurate metrics)',
        () {
      final ReaderPageStep step =
          freshForward(3000, metricsMax: 9000, trueMax: 9000);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 4000);
    });

    test('sub-pixel under-measure of last content edge still advances', () {
      // metricsMax 比真末页少 1px(8999)，currentScroll 在末页前一页(8000)。
      final ReaderPageStep step =
          freshForward(8000, metricsMax: 8999, trueMax: 9000);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 9000);
    });

    test('accurate metrics: landing identical to legacy (no regression)', () {
      // trueMax 不大于 metricsMax 时，maxF == metricsMax，落点与旧实现等价。
      final ReaderPageStep step =
          freshForward(2000, metricsMax: 9000, trueMax: 9000);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 3000);
    });

    test('backward at first page → no scroll', () {
      final ReaderPageStep step = freshBackward(0, metricsMin: 0);
      expect(step.scrolled, isFalse);
      expect(step.targetScroll, 0);
    });

    test('backward mid-chapter retreats one page', () {
      final ReaderPageStep step = freshBackward(3000, metricsMin: 0);
      expect(step.scrolled, isTrue);
      expect(step.targetScroll, 2000);
    });

    test('zero pitch → no scroll', () {
      final ReaderPageStep step =
          ReaderPaginationScripts.resolveFreshStepForTesting(
        direction: ReaderNavigationDirection.forward,
        currentScroll: 1000,
        columnPitch: 0,
        metricsMaxScroll: 9000,
        metricsMinScroll: 0,
        trueMaxScroll: 9000,
      );
      expect(step.scrolled, isFalse);
    });
  });
}
