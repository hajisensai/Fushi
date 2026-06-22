import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-729「翻页翻一半跳章节」回归：方案A 把分页收敛成单一量纲——
/// 列周期(column-width + column-gap) == pageStep == 对齐量 == maxScroll 减项。
///
/// 旧实现（双量纲）：对齐/步进用 columnPitch = pageSize + gap，maxScroll 却用
/// totalSize − clientSize（clientSize 含 padding）。两者相差 (padding − gap)。当竖排把
/// chrome inset / 字号 / margin 塞进 column-gap 使 pitch ≠ 真实列周期、且 maxScroll
/// 减项与对齐量不同源时，倒数第二页算出的「下一整页」越过被低估/错位的末页边界被
/// clamp 回当前位置 → paginate 误判 limit → `_handlePageTurnLimit` 提前跨章
/// （用户「翻一半跳章」）。
///
/// 单一量纲后 `maxAlignedScroll` 由 `floor(maxScroll/pageStep)*pageStep` 派生、与
/// pageStep 严格同源，倒数第二页 forward 必 scrolled=true，只有真末页 forward 才
/// scrolled=false（→ paginate return "limit" → 跨章）。本测试用纯函数影子
/// `resolvePaginateStepForTesting`（JS `paginate` 的同算法 Dart 镜像，headless WebView
/// 不可用）锁住「整页对齐到真末列才跨章」不变式。
void main() {
  ReaderPageStep forward(
    double current, {
    required double pitch,
    double min = 0,
    required double max,
  }) =>
      ReaderPaginationScripts.resolvePaginateStepForTesting(
        direction: ReaderNavigationDirection.forward,
        currentScroll: current,
        columnPitch: pitch,
        minAlignedScroll: min,
        maxAlignedScroll: max,
      );

  ReaderPageStep backward(
    double current, {
    required double pitch,
    required double min,
    double max = double.infinity,
  }) =>
      ReaderPaginationScripts.resolvePaginateStepForTesting(
        direction: ReaderNavigationDirection.backward,
        currentScroll: current,
        columnPitch: pitch,
        minAlignedScroll: min,
        maxAlignedScroll: max,
      );

  // 模拟单一量纲下 buildPaginationMetrics 的 maxAlignedScroll 派生：
  // maxScroll = totalSize − pageStep；maxAligned = floor(maxScroll/pageStep)*pageStep。
  double alignedMax(double totalSize, double pageStep) {
    final double maxScroll =
        (totalSize - pageStep) < 0 ? 0 : totalSize - pageStep;
    return (maxScroll / pageStep).floorToDouble() * pageStep;
  }

  group('整页对齐才跨章：单一量纲下倒数第二页必前进、仅真末页跨章', () {
    test('竖排 notch：pageStep 含 inset 仍与 maxScroll 同源 → 倒数第二页前进', () {
      // 竖排某设备：content-box 高 = 视口 − 上下 padding(margin+fontSize+notch+chrome)。
      // 例：pageStep = 812（content-box 790 + gap 22）。共 5 整页，totalSize 含一末列。
      const double pitch = 812;
      const double total = pitch * 4 + 600; // 末列只有 600px 内容（< pitch）
      final double max =
          alignedMax(total, pitch); // = floor((total-pitch)/pitch)*pitch
      // 倒数第二页（max − pitch）forward 必须真翻到对齐末页边界。
      final ReaderPageStep s = forward(max - pitch, pitch: pitch, max: max);
      expect(s.scrolled, isTrue, reason: '倒数第二页还有整页可翻，绝不能误判 limit 提前跨章（翻一半跳章）');
      expect(s.targetScroll, max);
    });

    test('真末页 forward 才不翻（→ paginate return limit → 跨章）', () {
      const double pitch = 812;
      const double total = pitch * 4 + 600;
      final double max = alignedMax(total, pitch);
      final ReaderPageStep s = forward(max, pitch: pitch, max: max);
      expect(s.scrolled, isFalse, reason: '只有真正对齐到末列后才允许跨章');
    });

    test('横排：pageStep = content-box宽 + 22 与 maxScroll 同源', () {
      const double pitch = 1058; // 内容宽 1036 + gap 22
      const double total = pitch * 6 + 300;
      final double max = alignedMax(total, pitch);
      // 倒数第二页（max − pitch）forward 必前进到末页。
      final ReaderPageStep s = forward(max - pitch, pitch: pitch, max: max);
      expect(s.scrolled, isTrue);
      expect(s.targetScroll, max);
      // 末页不前进。
      expect(forward(max, pitch: pitch, max: max).scrolled, isFalse);
    });
  });

  group('padding/pitch 失配回归：减项与对齐量必须同源', () {
    test('同源减项下，整章每一页都能逐页前进直到真末页', () {
      const double pitch = 740;
      const double total = pitch * 8 + 123;
      final double max = alignedMax(total, pitch);
      // 逐页前进，每一步都应 scrolled=true，直到落到 max。
      double cur = 0;
      int guard = 0;
      while (cur < max && guard < 100) {
        final ReaderPageStep s = forward(cur, pitch: pitch, max: max);
        expect(s.scrolled, isTrue,
            reason: 'scroll=$cur 还未到末页(max=$max)，必须能前进，'
                '不得在 padding≠gap 失配下提前误判 limit');
        expect(s.targetScroll, greaterThan(cur));
        cur = s.targetScroll;
        guard++;
      }
      expect(cur, max, reason: '应恰好逐页落到对齐末页');
      expect(forward(max, pitch: pitch, max: max).scrolled, isFalse,
          reason: '到达对齐末页后才停（跨章）');
    });

    test('1px sub-pixel 漂移在末页前一页不被误判 limit（WebView 漂移）', () {
      const double pitch = 812;
      const double total = pitch * 4 + 600;
      final double max = alignedMax(total, pitch);
      // 倒数第二页带 0.4px 漂移，仍须前进到末页。
      final ReaderPageStep s =
          forward(max - pitch + 0.4, pitch: pitch, max: max);
      expect(s.scrolled, isTrue);
      expect(s.targetScroll, max);
    });
  });

  group('backward 对称：仅章首才跨章', () {
    test('第二页 backward 退回首页（不跨章）', () {
      const double pitch = 812;
      expect(backward(2 * pitch, pitch: pitch, min: 0).scrolled, isTrue);
    });

    test('章首 backward 不动（→ limit → 回上一章）', () {
      const double pitch = 812;
      expect(backward(0, pitch: pitch, min: 0).scrolled, isFalse);
    });

    test('章首带 0.33px 漂移 backward 不误判可翻', () {
      const double pitch = 812;
      expect(backward(0.33, pitch: pitch, min: 0).scrolled, isFalse);
    });
  });
}
