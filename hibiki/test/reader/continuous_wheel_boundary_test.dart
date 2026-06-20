import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-627 / BUG-349：连续/滚动模式下桌面鼠标**滚轮**到达内容轴尽头时必须跨章。
/// 连续模式靠原生滚动翻屏，章间切换原本只有触摸/指针的边界手势 IIFE 走
/// `onBoundarySwipe`，滚轮无此通道 → 滚到章末/章首再滚没反应。修复后滚轮复用同款
/// atStart/atEnd 判定，只在「到底」才回传 `onBoundarySwipe`，未到底放行正常滚动。
///
/// 这是 reader_hibiki_page.dart 连续模式 wheel 监听器边界判定的纯 Dart 影子
/// （headless WebView 不可用，按项目测试范式：纯函数单测 + 源码守卫）。
void main() {
  String? wheel({
    required bool vertical,
    required double delta,
    required bool atStart,
    required bool atEnd,
  }) =>
      ReaderPaginationScripts.continuousWheelBoundaryDirection(
        vertical: vertical,
        delta: delta,
        atStart: atStart,
        atEnd: atEnd,
      );

  group('horizontal continuous (scroll axis = vertical)', () {
    test('scroll down at bottom -> forward chapter turn', () {
      expect(
        wheel(vertical: false, delta: 120, atStart: false, atEnd: true),
        'forward',
        reason: '横排到底向下滚必须跨到下一章',
      );
    });

    test('scroll up at top -> backward chapter turn', () {
      expect(
        wheel(vertical: false, delta: -120, atStart: true, atEnd: false),
        'backward',
        reason: '横排到顶向上滚必须跨回上一章',
      );
    });

    test('scroll down mid-content -> null (let native scroll)', () {
      expect(
        wheel(vertical: false, delta: 120, atStart: false, atEnd: false),
        isNull,
        reason: '未到底不能打断原生滚动',
      );
    });

    test('scroll up mid-content -> null', () {
      expect(
        wheel(vertical: false, delta: -120, atStart: false, atEnd: false),
        isNull,
      );
    });

    test('scroll down at top (not bottom) -> null', () {
      // 内容轴起点向下滚还有内容可滚，不该跨章。
      expect(
        wheel(vertical: false, delta: 120, atStart: true, atEnd: false),
        isNull,
      );
    });

    test('scroll up at bottom (not top) -> null', () {
      expect(
        wheel(vertical: false, delta: -120, atStart: false, atEnd: true),
        isNull,
      );
    });
  });

  group('vertical continuous (scroll axis = horizontal, vertical-rl)', () {
    test('project-forward at end -> forward chapter turn', () {
      // 竖排投影后 delta>0 = 沿书写轴前进；到 forward 尽头(atEnd)跨下一章。
      expect(
        wheel(vertical: true, delta: 120, atStart: false, atEnd: true),
        'forward',
      );
    });

    test('project-backward at start -> backward chapter turn', () {
      expect(
        wheel(vertical: true, delta: -120, atStart: true, atEnd: false),
        'backward',
      );
    });

    test('project-forward mid-content -> null (let projected scroll)', () {
      expect(
        wheel(vertical: true, delta: 120, atStart: false, atEnd: false),
        isNull,
      );
    });
  });

  group('degenerate', () {
    test('zero delta -> null regardless of boundary', () {
      expect(
        wheel(vertical: false, delta: 0, atStart: true, atEnd: true),
        isNull,
      );
      expect(
        wheel(vertical: true, delta: 0, atStart: true, atEnd: true),
        isNull,
      );
    });
  });
}
