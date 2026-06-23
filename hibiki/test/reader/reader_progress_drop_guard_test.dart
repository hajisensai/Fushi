import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show readerScrollWithinReanchorSettle;

/// TODO-736 B-3 纯函数真值表单测。
///
/// B-3 [readerScrollWithinReanchorSettle]：样式重锚 commit 清旗后 250ms 时间窗内一律抑制
/// （治 reflow settle 尾沿的瞬态归零 scroll 落库）。看的是「时间窗」。
///
/// 注：旧 B-4 [readerProgressDropIsSpurious]「无近期输入=伪」判据已删（复核结论 b）——它
/// 想防的 reflow 归零已被 _reanchorPending（JS 不回传）+ B-3（settle 窗）两墙覆盖，反而误伤
/// 惯性甩动到真章首（momentum 期无新输入 → 误判伪 → 丢位置）。详见 navigation.part.dart
/// _refreshProgress 的「复核 b」注释。
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
}
