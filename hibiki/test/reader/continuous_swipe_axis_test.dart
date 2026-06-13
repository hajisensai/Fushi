import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

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
