import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-737：分页滚轮翻页「方向意图」纯函数守卫。
///
/// 行为变更声明：分页滚轮方向从此脱钩 `invertSwipeDirection`——该开关只管触摸滑动 /
/// 鼠标拖动（onSwipe 路径），**不再管滚轮**。滚轮方向归一为「deltaY>0=forward」，与
/// 连续滚轮（沿书写轴 delta>0=前进）一致，消除「分页滚轮方向反了」的根因（裸符号
/// `deltaY<0=forward` + onSwipe 经 invert 默认 true 连坐的完整链）。
///
/// 这是 JS wheel 监听里 `var forward = (e.deltaY > 0 || e.deltaX > 0)` 的纯 Dart 影子
/// （headless WebView 不可用，按项目范式：纯函数单测 + 源码守卫）。
void main() {
  String dir({required double deltaY, required double deltaX}) =>
      ReaderPaginationScripts.wheelPaginateDir(deltaY: deltaY, deltaX: deltaX);

  group('wheelPaginateDir: deltaY>0 = forward (对齐连续滚轮，不再 deltaY<0)', () {
    test('deltaY > 0 maps to forward', () {
      expect(dir(deltaY: 100, deltaX: 0), 'forward');
    });

    test('deltaY < 0 maps to backward', () {
      expect(dir(deltaY: -100, deltaX: 0), 'backward');
    });

    test('horizontal wheel deltaX > 0 also forward', () {
      expect(dir(deltaY: 0, deltaX: 50), 'forward');
    });

    test('horizontal wheel deltaX < 0 backward', () {
      expect(dir(deltaY: 0, deltaX: -50), 'backward');
    });

    test('zero delta defaults to backward (no positive component)', () {
      // 调用方在 JS 端不会用 0 delta 触发翻页（wheelDelta===0 已早返回），此处只锁
      // 纯函数的确定性：无正向分量 = backward。
      expect(dir(deltaY: 0, deltaX: 0), 'backward');
    });
  });

  group('TODO-737 回归锁：方向与连续滚轮 forward 判据同号', () {
    test('正 deltaY 在分页与连续都判 forward（消除方向矛盾）', () {
      // 连续滚轮纯谓词以 delta>0=forward（见 continuousWheelBoundaryDirection 注释）；
      // 分页滚轮归一后同号——同一个向下滚动两模式方向一致。
      expect(dir(deltaY: 1, deltaX: 0), 'forward');
      final String? continuousForward =
          ReaderPaginationScripts.continuousWheelBoundaryDirection(
        vertical: false,
        delta: 1,
        atStart: false,
        atEnd: true,
      );
      expect(continuousForward, 'forward',
          reason: '分页与连续滚轮的 forward 判据必须同号（delta>0）');
    });
  });
}
