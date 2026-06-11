import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show ReadProgressResult, accumulateSessionChars;

/// TODO-147 / BUG-211：锁定阅读统计「字数」的 high-water mark 计数语义。
///
/// 旧实现按相邻两次进度采样的正向差累加（`charDiff>0` 才加，但 baseline 无条件
/// 下移），导致日语精读常见的「往回看再往前」往返翻页把重叠区间反复计入——
/// 一本书来回研读几遍，统计字数随往返次数倍增，呈现「字数明显非常高」。
///
/// 新实现只在当前绝对位置越过本 session 历史最高位置时增量计数，水位只升不降，
/// 往返翻页不重复累计。撤销修复（回到无条件正向差）→ 往返用例会转红。
void main() {
  group('accumulateSessionChars (high-water mark)', () {
    test('首次前进：从起点读到位置即全部计入', () {
      final ReadProgressResult r =
          accumulateSessionChars(absoluteChars: 100, highWaterMark: 0);
      expect(r.charsAdded, 100);
      expect(r.highWaterMark, 100);
    });

    test('单调前进：每次只计新推进的部分', () {
      ReadProgressResult r =
          accumulateSessionChars(absoluteChars: 100, highWaterMark: 0);
      expect(r.charsAdded, 100);
      r = accumulateSessionChars(
          absoluteChars: 250, highWaterMark: r.highWaterMark);
      expect(r.charsAdded, 150);
      expect(r.highWaterMark, 250);
    });

    test('回退不计、也不降低水位', () {
      // 读到 100 → 回退到 50：不计入，水位保持 100。
      ReadProgressResult r =
          accumulateSessionChars(absoluteChars: 100, highWaterMark: 100);
      expect(r.charsAdded, 0);
      expect(r.highWaterMark, 100);
      r = accumulateSessionChars(absoluteChars: 50, highWaterMark: 100);
      expect(r.charsAdded, 0, reason: '回退不应计入字数');
      expect(r.highWaterMark, 100, reason: '水位只升不降');
    });

    test('核心回归：往返翻页（前进-回退-再前进经过同一段）不重复计数', () {
      // 模拟日语精读：读到 100 → 回看到 50 → 再往前读到 100 → 继续读到 120。
      int water = 0;
      int total = 0;

      ReadProgressResult r =
          accumulateSessionChars(absoluteChars: 100, highWaterMark: water);
      total += r.charsAdded; // +100
      water = r.highWaterMark;

      r = accumulateSessionChars(absoluteChars: 50, highWaterMark: water);
      total += r.charsAdded; // +0 (回看)
      water = r.highWaterMark;

      r = accumulateSessionChars(absoluteChars: 100, highWaterMark: water);
      total += r.charsAdded; // +0 (重新读 50→100，已读过，不重复)
      water = r.highWaterMark;

      r = accumulateSessionChars(absoluteChars: 120, highWaterMark: water);
      total += r.charsAdded; // +20 (新读 100→120)
      water = r.highWaterMark;

      // 真实读到的不同字符量 = 120（0→120），而非旧逻辑的 100+50+20=170。
      expect(total, 120, reason: '往返研读同一段不应重复计入；总计应等于读到的最高位置');
      expect(water, 120);
    });

    test('多次往返：旧逻辑会倍增，新逻辑恒等于最高已读位置', () {
      int water = 0;
      int total = 0;
      // 来回研读 [0,200] 区间三遍，再前进到 300。
      for (final int pos in <int>[200, 0, 200, 0, 200, 0]) {
        final ReadProgressResult r =
            accumulateSessionChars(absoluteChars: pos, highWaterMark: water);
        total += r.charsAdded;
        water = r.highWaterMark;
      }
      final ReadProgressResult last =
          accumulateSessionChars(absoluteChars: 300, highWaterMark: water);
      total += last.charsAdded;
      water = last.highWaterMark;

      expect(total, 300, reason: '无论往返多少遍，session 字数 = 历史最高已读位置（300），不倍增');
      expect(water, 300);
    });

    test('停在原地：进度回调重复触发同一位置不重复计数', () {
      // 10 秒轮询在用户不翻页时反复读到同一 absoluteChars。
      int water = 500;
      int total = 0;
      for (int i = 0; i < 5; i++) {
        final ReadProgressResult r =
            accumulateSessionChars(absoluteChars: 500, highWaterMark: water);
        total += r.charsAdded;
        water = r.highWaterMark;
      }
      expect(total, 0, reason: '停在原地轮询不应累计字数');
      expect(water, 500);
    });
  });
}
