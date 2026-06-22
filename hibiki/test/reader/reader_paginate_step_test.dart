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
}
