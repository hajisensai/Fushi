import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/reader_space_override.dart';

/// 反馈 794gISjvgV：分页模式触控板横滑翻页方向反了，「反转滑动翻页方向」等开关对它
/// 都不起作用（BUG-3358；纵向两指滑的补漏见下方「纵向触控板」组）。
/// [readerWheelTickIsForward] 是 `onWheelPaginate` 唯一的方向判据。
void main() {
  bool fwd({
    required bool deltaPositive,
    required bool horizontal,
    required bool trackpad,
    required bool rtl,
    bool invertSwipe = true,
  }) => readerWheelTickIsForward(
    deltaPositive: deltaPositive,
    horizontal: horizontal,
    trackpad: trackpad,
    rtl: rtl,
    invertSwipe: invertSwipe,
  );

  group('纵向鼠标：delta>0 恒为前进，任何开关 / 书写方向都不改（TODO-737）', () {
    for (final bool rtl in <bool>[false, true]) {
      for (final bool invert in <bool>[false, true]) {
        test('rtl=$rtl invert=$invert', () {
          expect(
            fwd(
              deltaPositive: true,
              horizontal: false,
              trackpad: false,
              rtl: rtl,
              invertSwipe: invert,
            ),
            isTrue,
          );
          expect(
            fwd(
              deltaPositive: false,
              horizontal: false,
              trackpad: false,
              rtl: rtl,
              invertSwipe: invert,
            ),
            isFalse,
          );
        });
      }
    }
  });

  // BUG-3358 补漏：翻页 / VN 模式两指上下滑也走 onWheelPaginate（axis=vertical,
  // pointerKind=trackpad），修复前这一象限直接返回 delta 符号、不认开关。
  group('纵向触控板 = 滑动翻页，跟随「反转滑动翻页方向」开关', () {
    test('默认开关下与修复前一致：delta>0 前进，与书写方向无关', () {
      for (final bool rtl in <bool>[false, true]) {
        expect(
          fwd(deltaPositive: true, horizontal: false, trackpad: true, rtl: rtl),
          isTrue,
        );
        expect(
          fwd(
            deltaPositive: false,
            horizontal: false,
            trackpad: true,
            rtl: rtl,
          ),
          isFalse,
        );
      }
    });

    test('切换开关确实反转触控板上下滑', () {
      for (final bool rtl in <bool>[false, true]) {
        for (final bool positive in <bool>[false, true]) {
          expect(
            fwd(
              deltaPositive: positive,
              horizontal: false,
              trackpad: true,
              rtl: rtl,
              invertSwipe: false,
            ),
            isNot(
              fwd(
                deltaPositive: positive,
                horizontal: false,
                trackpad: true,
                rtl: rtl,
                invertSwipe: true,
              ),
            ),
            reason: 'rtl=$rtl positive=$positive',
          );
        }
      }
    });

    test('与横向触控板同一判据：开关从默认翻转时两轴一起反向', () {
      for (final bool rtl in <bool>[false, true]) {
        for (final bool invert in <bool>[false, true]) {
          final bool verticalFlipped =
              fwd(
                deltaPositive: true,
                horizontal: false,
                trackpad: true,
                rtl: rtl,
                invertSwipe: invert,
              ) !=
              fwd(
                deltaPositive: true,
                horizontal: false,
                trackpad: false,
                rtl: rtl,
                invertSwipe: invert,
              );
          final bool horizontalFlipped =
              fwd(
                deltaPositive: true,
                horizontal: true,
                trackpad: true,
                rtl: rtl,
                invertSwipe: invert,
              ) !=
              fwd(
                deltaPositive: true,
                horizontal: true,
                trackpad: false,
                rtl: rtl,
                invertSwipe: invert,
              );
          expect(
            verticalFlipped,
            horizontalFlipped,
            reason: 'rtl=$rtl invert=$invert',
          );
          expect(verticalFlipped, !invert, reason: 'rtl=$rtl invert=$invert');
        }
      }
    });
  });

  group('横向鼠标：视口往书页前进的一侧滚 = 前进，不受滑动开关影响', () {
    test('横排：向右滚前进', () {
      for (final bool invert in <bool>[false, true]) {
        expect(
          fwd(
            deltaPositive: true,
            horizontal: true,
            trackpad: false,
            rtl: false,
            invertSwipe: invert,
          ),
          isTrue,
        );
      }
    });
    test('竖排 vertical-rl：向左滚（delta<0）前进', () {
      for (final bool invert in <bool>[false, true]) {
        expect(
          fwd(
            deltaPositive: false,
            horizontal: true,
            trackpad: false,
            rtl: true,
            invertSwipe: invert,
          ),
          isTrue,
        );
      }
    });
  });

  group('横向触控板 = 滑动翻页，跟随「反转滑动翻页方向」开关', () {
    test('默认开关下与「视口往前进方向滚」逐象限一致', () {
      for (final bool rtl in <bool>[false, true]) {
        for (final bool positive in <bool>[false, true]) {
          expect(
            fwd(
              deltaPositive: positive,
              horizontal: true,
              trackpad: true,
              rtl: rtl,
            ),
            fwd(
              deltaPositive: positive,
              horizontal: true,
              trackpad: false,
              rtl: rtl,
            ),
            reason: 'rtl=$rtl positive=$positive',
          );
        }
      }
    });

    test('与触摸滑动同一套映射：delta>0 = 手指向左划', () {
      for (final bool rtl in <bool>[false, true]) {
        for (final bool invert in <bool>[false, true]) {
          expect(
            fwd(
              deltaPositive: true,
              horizontal: true,
              trackpad: true,
              rtl: rtl,
              invertSwipe: invert,
            ),
            swipeLeftIsForward(invert: invert, rtl: rtl),
            reason: 'rtl=$rtl invert=$invert',
          );
        }
      }
    });

    test('切换开关确实反转触控板横滑（反馈原话：开关对触摸板没用）', () {
      for (final bool rtl in <bool>[false, true]) {
        expect(
          fwd(
            deltaPositive: true,
            horizontal: true,
            trackpad: true,
            rtl: rtl,
            invertSwipe: true,
          ),
          isNot(
            fwd(
              deltaPositive: true,
              horizontal: true,
              trackpad: true,
              rtl: rtl,
              invertSwipe: false,
            ),
          ),
        );
      }
    });
  });
}
