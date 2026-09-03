import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// BUG-2015：连续模式跨章必须区分「触摸板的一段惯性」和「离散滚轮的一格」。
///
/// 触摸板从正文滚到边界后仍会连续喷 tick；旧 arm-then-fire 会把其中第二拍当成
/// 跨章确认，导致末尾尚未停稳就跳走。新契约要求触摸板先静默、再从边界开始一次
/// 新手势；鼠标滚轮/数位板旋钮则允许一格跨章，避免单事件设备完全无响应。
void main() {
  bool shouldTurn({
    required bool moved,
    required bool trackpad,
    required bool newGesture,
  }) => ReaderPaginationScripts.continuousWheelShouldTurnChapter(
    moved: moved,
    isTrackpad: trackpad,
    startsNewGesture: newGesture,
  );

  test('触摸板同一手势从正文滚到边界后，残余惯性不跨章', () {
    expect(shouldTurn(moved: true, trackpad: true, newGesture: true), isFalse);
    for (int i = 0; i < 20; i++) {
      expect(
        shouldTurn(moved: false, trackpad: true, newGesture: false),
        isFalse,
      );
    }
  });

  test('静默后从边界开始的新触摸板手势跨章', () {
    expect(shouldTurn(moved: false, trackpad: true, newGesture: true), isTrue);
  });

  test('离散滚轮或数位板旋钮在边界的一拍即可跨章', () {
    expect(
      shouldTurn(moved: false, trackpad: false, newGesture: false),
      isTrue,
    );
  });

  test('任何设备只要正文仍在滚动就绝不跨章', () {
    expect(shouldTurn(moved: true, trackpad: false, newGesture: true), isFalse);
    expect(shouldTurn(moved: true, trackpad: true, newGesture: true), isFalse);
  });
}
