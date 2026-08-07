// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// BUG-239：连续/滚动模式滑动无法翻页。统一手势 `_gestureEnd` 只在水平滑动
/// （absDx > absDy）回传 onSwipe，那是分页模式（touch-action:none，无原生滚动）的
/// 唯一翻页通道；连续模式靠原生滚动（滚动轴 = 书写轴），再回传 onSwipe 会与原生滚动
/// 产生轴向冲突。修复后连续模式一律不回传 onSwipe（交给原生滚动 + 边界 IIFE）。
///
/// 这是 JS `_gestureEnd` onSwipe 门控的纯 Dart 影子（headless WebView 不可用，
/// 按项目测试范式：纯函数单测 + 源码守卫）。
void main() {
  group('continuous mode never fires onSwipe (BUG-239)', () {
    test('horizontal swipe in continuous mode does NOT paginate', () {
      expect(
        ReaderPaginationScripts.continuousSwipeShouldPaginate(
          continuousMode: true,
          absDx: 200,
          absDy: 10,
        ),
        isFalse,
        reason: '连续模式横向滑动不该触发 90% 跳页（轴向冲突）',
      );
    });

    test('vertical swipe in continuous mode does NOT paginate', () {
      expect(
        ReaderPaginationScripts.continuousSwipeShouldPaginate(
          continuousMode: true,
          absDx: 10,
          absDy: 200,
        ),
        isFalse,
        reason: '连续模式沿滚动轴的滑动交给原生滚动，不走 onSwipe',
      );
    });
  });

  group('paged mode keeps the legacy horizontal-swipe page turn', () {
    test('horizontal swipe in paged mode paginates', () {
      expect(
        ReaderPaginationScripts.continuousSwipeShouldPaginate(
          continuousMode: false,
          absDx: 200,
          absDy: 10,
        ),
        isTrue,
      );
    });

    test('vertical swipe in paged mode does not paginate (unchanged)', () {
      expect(
        ReaderPaginationScripts.continuousSwipeShouldPaginate(
          continuousMode: false,
          absDx: 10,
          absDy: 200,
        ),
        isFalse,
      );
    });
  });
}
