import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-369：滚动（连续）模式下，向上滚动「还没到章节开头就提前切到上一章」。
/// 根因 = 滚轮边界判定用单次瞬时 `scrollTop<=2` 读数，惯性/竖排 rAF 缓动把 scrollTop
/// 异步滑向 0 时连发的 wheel 会在「仍在滑动、内容未贴住章首」的某帧擦到 `<=2` → 提前
/// 跨章。修法 = arm-then-fire 二次确认（同方向第一次到边界只武装、第二次才跨章），由
/// 纯函数 [ReaderPaginationScripts.continuousWheelBoundaryEmit] 锁定。
///
/// 这是 reader_hibiki_page.dart 滚轮监听器边界确认逻辑的纯 Dart 影子（headless WebView
/// 不可用，按项目范式：纯函数单测 + 源码守卫）。
void main() {
  ({bool emit, String? nextArmedDir}) confirm({
    required String? boundaryDir,
    required String? armedDir,
  }) =>
      ReaderPaginationScripts.continuousWheelBoundaryEmit(
        boundaryDir: boundaryDir,
        armedDir: armedDir,
      );

  group('arm-then-fire backward (the buggy direction)', () {
    test('first wheel at top only arms, does NOT cross to previous chapter',
        () {
      final r = confirm(boundaryDir: 'backward', armedDir: null);
      expect(r.emit, isFalse, reason: '第一次到章首只武装，吸收惯性/缓动擦边瞬态，不能立即切上一章');
      expect(r.nextArmedDir, 'backward');
    });

    test('second wheel at top (same direction) crosses to previous chapter',
        () {
      final r = confirm(boundaryDir: 'backward', armedDir: 'backward');
      expect(r.emit, isTrue, reason: '同方向二次确认才真正跨章');
      expect(r.nextArmedDir, isNull, reason: '跨章后清武装（已重锚到新章）');
    });
  });

  group('arm-then-fire forward (symmetric)', () {
    test('first wheel at bottom only arms', () {
      final r = confirm(boundaryDir: 'forward', armedDir: null);
      expect(r.emit, isFalse);
      expect(r.nextArmedDir, 'forward');
    });

    test('second wheel at bottom crosses to next chapter', () {
      final r = confirm(boundaryDir: 'forward', armedDir: 'forward');
      expect(r.emit, isTrue);
      expect(r.nextArmedDir, isNull);
    });
  });

  group('disarm', () {
    test('leaving the boundary mid-scroll disarms (no cross)', () {
      // 已武装 backward，但这次滚动未到边界（中途）→ 解除武装。
      final r = confirm(boundaryDir: null, armedDir: 'backward');
      expect(r.emit, isFalse, reason: '中途滚动不能在已武装态下跨章——必须先解除武装');
      expect(r.nextArmedDir, isNull);
    });

    test('direction reversal at opposite boundary re-arms, does not cross', () {
      // 已武装 backward（顶部），但现在到的是 forward（底部）→ 不跨章，改武装 forward。
      final r = confirm(boundaryDir: 'forward', armedDir: 'backward');
      expect(r.emit, isFalse, reason: '方向反转不能凭旧武装直接跨章');
      expect(r.nextArmedDir, 'forward');
    });
  });

  test('inertial single-tick scrape never crosses (regression scenario)', () {
    // 模拟惯性/缓动擦边：向上快速回滚，scrollTop 在某一帧擦到 <=2（boundaryDir=backward）
    // 但下一帧又离开边界（仍在滑动，内容未贴住章首）。arm-then-fire 下：擦边帧只武装，
    // 离开帧立即解除武装 → 全程 emit 恒 false，绝不提前切上一章。
    final armed = confirm(boundaryDir: 'backward', armedDir: null);
    expect(armed.emit, isFalse);
    expect(armed.nextArmedDir, 'backward');
    final leftBoundary =
        confirm(boundaryDir: null, armedDir: armed.nextArmedDir);
    expect(leftBoundary.emit, isFalse, reason: '擦边后离开边界的瞬态必须解除武装，杜绝提前跨章');
    expect(leftBoundary.nextArmedDir, isNull);
  });
}
