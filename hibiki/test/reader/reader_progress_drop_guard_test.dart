import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show readerProgressDropIsSpurious, readerScrollWithinReanchorSettle;

/// TODO-736 B-3 / B-4 纯函数真值表单测。
///
/// 两条判据**正交独立、禁互兜底**：
///  - B-3 [readerScrollWithinReanchorSettle]：样式重锚 commit 清旗后 250ms 时间窗内一律
///    抑制（治 reflow settle 尾沿的瞬态归零 scroll 落库）。看的是「时间窗」。
///  - B-4 [readerProgressDropIsSpurious]：进度从非零突降≈0 且无近期真实用户输入 → 伪归零
///    抑制；有近期输入 = 用户真把视口滚回章首 → 必落库（防 BUG-162 丢位置）。看的是
///    「突降 + 输入」。
void main() {
  group('B-3 readerScrollWithinReanchorSettle（settle 时间窗去抖）', () {
    final DateTime t0 = DateTime(2026, 6, 23, 12, 0, 0);

    test('reanchorClearedAt 为 null（从未样式重锚）→ 不抑制', () {
      expect(
        readerScrollWithinReanchorSettle(reanchorClearedAt: null, now: t0),
        isFalse,
      );
    });

    test('清旗后 0ms（同刻）→ 抑制', () {
      expect(
        readerScrollWithinReanchorSettle(reanchorClearedAt: t0, now: t0),
        isTrue,
      );
    });

    test('清旗后 249ms（窗内）→ 抑制', () {
      expect(
        readerScrollWithinReanchorSettle(
          reanchorClearedAt: t0,
          now: t0.add(const Duration(milliseconds: 249)),
        ),
        isTrue,
      );
    });

    test('清旗后 250ms（窗边界外）→ 不抑制', () {
      expect(
        readerScrollWithinReanchorSettle(
          reanchorClearedAt: t0,
          now: t0.add(const Duration(milliseconds: 250)),
        ),
        isFalse,
      );
    });

    test('清旗后 1s（远超窗）→ 不抑制', () {
      expect(
        readerScrollWithinReanchorSettle(
          reanchorClearedAt: t0,
          now: t0.add(const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });

    test('now 早于 clearedAt（时钟回拨/负差）→ 不抑制（不误吞）', () {
      expect(
        readerScrollWithinReanchorSettle(
          reanchorClearedAt: t0,
          now: t0.subtract(const Duration(milliseconds: 100)),
        ),
        isFalse,
      );
    });
  });

  group('B-4 readerProgressDropIsSpurious（突降 + 无输入 = 伪）', () {
    test('真章首落库：上次非零、本次≈0、有近期输入（用户真滚回章首）→ 不伪（必落库）', () {
      expect(
        readerProgressDropIsSpurious(
          lastProgress: 0.62,
          newProgress: 0.0,
          sinceUserInputMs: 50,
          reanchorSettling: false,
        ),
        isFalse,
        reason: '有近期真实用户输入 = 用户主动回章首，必落库防 BUG-162 丢位置',
      );
    });

    test('伪归零跳过：上次非零、本次≈0、无近期输入（reflow 自发归零）→ 伪（跳过落库）', () {
      expect(
        readerProgressDropIsSpurious(
          lastProgress: 0.62,
          newProgress: 0.0,
          sinceUserInputMs: null,
          reanchorSettling: false,
        ),
        isTrue,
        reason: 'reflow 自发归零、无用户输入 → 伪归零，跳过落库',
      );
    });

    test('伪归零跳过：输入超窗（800ms 前，早已不算近期）→ 伪', () {
      expect(
        readerProgressDropIsSpurious(
          lastProgress: 0.50,
          newProgress: 0.001,
          sinceUserInputMs: 800,
          reanchorSettling: false,
        ),
        isTrue,
        reason: '400ms 外的旧输入不算近期 → 仍判伪',
      );
    });

    test('非突降不抑制：上次本就接近 0（正常停在章首附近滚动）→ 不伪', () {
      expect(
        readerProgressDropIsSpurious(
          lastProgress: 0.005,
          newProgress: 0.0,
          sinceUserInputMs: null,
          reanchorSettling: false,
        ),
        isFalse,
        reason: '上次就接近 0，不是「非零突降」，照常落库',
      );
    });

    test('非突降不抑制：本次不接近 0（正常往后滚）→ 不伪', () {
      expect(
        readerProgressDropIsSpurious(
          lastProgress: 0.30,
          newProgress: 0.45,
          sinceUserInputMs: null,
          reanchorSettling: false,
        ),
        isFalse,
      );
    });

    test('边界：本次恰好 0.005（zeroThreshold 上界，不算≈0）→ 不伪', () {
      expect(
        readerProgressDropIsSpurious(
          lastProgress: 0.40,
          newProgress: 0.005,
          sinceUserInputMs: null,
          reanchorSettling: false,
        ),
        isFalse,
      );
    });

    test('边界：上次恰好 0.02（nonZeroThreshold 上界，不算非零）→ 不伪', () {
      expect(
        readerProgressDropIsSpurious(
          lastProgress: 0.02,
          newProgress: 0.0,
          sinceUserInputMs: null,
          reanchorSettling: false,
        ),
        isFalse,
      );
    });

    test('正交独立：reanchorSettling=true 不反向放行有输入的真章首（输入仍胜出 → 不伪）', () {
      // 禁互兜底：B-4 不依赖 B-3，有近期输入恒不伪（B-3 时间窗自有独立拦截）。
      expect(
        readerProgressDropIsSpurious(
          lastProgress: 0.62,
          newProgress: 0.0,
          sinceUserInputMs: 30,
          reanchorSettling: true,
        ),
        isFalse,
        reason: '有近期输入恒不伪，settle 标志不反向覆盖（防 BUG-162）',
      );
    });
  });
}
