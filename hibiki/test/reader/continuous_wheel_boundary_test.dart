// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// TODO-627 / BUG-349：连续/滚动模式下桌面鼠标**滚轮**到达内容轴尽头时必须跨章。
/// 连续模式靠原生滚动翻屏，章间切换原本只有触摸/指针的边界手势 IIFE 走
/// `onBoundarySwipe`，滚轮无此通道 → 滚到章末/章首再滚没反应。修复后滚轮复用同款
/// atStart/atEnd 判定，只在「到底」才回传 `onBoundarySwipe`，未到底放行正常滚动。
///
/// 这是 reader_fushi_page.dart 连续模式 wheel 监听器边界判定的纯 Dart 影子
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
