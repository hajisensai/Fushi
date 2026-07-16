import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/reader_space_override.dart';

/// BUG-横排滑动翻页方向不随书写方向翻转：滑动 / 鼠标拖动翻页方向此前只看
/// `invertSwipeDirection` 开关，横排与竖排共用同一套映射（横排方向反了）。键盘方向
/// 键早已用 `leftIsForward = rtl ^ reverse` 翻转，滑动漏了。本测试锁住补齐后的纯谓词
/// [swipeLeftIsForward]（`invert ^ rtl`）：横排与竖排相反，且竖排默认手感不变。
void main() {
  group('swipeLeftIsForward: 横排与竖排方向必须相反', () {
    test('竖排默认(rtl=T, invert=T) → 左滑=后退（与历史行为一致，不破坏手感）', () {
      expect(swipeLeftIsForward(invert: true, rtl: true), isFalse);
    });

    test('横排默认(rtl=F, invert=T) → 左滑=前进（相对竖排反转）', () {
      expect(swipeLeftIsForward(invert: true, rtl: false), isTrue);
    });

    test('同一 invert 下，横排与竖排的「左滑是否前进」恒相反', () {
      for (final bool invert in <bool>[true, false]) {
        expect(
          swipeLeftIsForward(invert: invert, rtl: true),
          isNot(swipeLeftIsForward(invert: invert, rtl: false)),
          reason: 'invert=$invert 时横排/竖排方向必须相反',
        );
      }
    });

    test('invertSwipeDirection 开关在任一书写方向下都整体取反', () {
      for (final bool rtl in <bool>[true, false]) {
        expect(
          swipeLeftIsForward(invert: true, rtl: rtl),
          isNot(swipeLeftIsForward(invert: false, rtl: rtl)),
          reason: 'rtl=$rtl 时 invert 开关必须整体反转左右语义',
        );
      }
    });
  });
}
