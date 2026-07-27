// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-875：竖排有声书读到「句首是行尾单字」的 cue 时凭空前翻一页、下一句又翻回。
///
/// 根因：`reader_pagination_scripts.dart` 的 `scrollToRange`（cue-follow +
/// search-highlight 共用落页路径）用起始边 `rect.top`（竖排）`alignToPage`(floor) 落页，
/// 但 `pageStep`（列周期 = N×(used 列宽+gap)）因 chrome inset / body padding 可比 client
/// `viewportExtent` 小最多半页（见 getScrollContext 的 physicalMaxScroll 注释）。句首是行尾
/// 单字（竖排=列底）时，其 rect.top 落在 `[pageStep, viewportExtent)` 这条「视觉仍在本页
/// 底部、却已越过 pitch 网格边界」的带内 → floor 判进下一 pitch 页 → 前翻；下一句句首起始边
/// 回到 `[0,pageStep)` → 翻回 = 抖动。
///
/// 修复：起始边落在真实 client 视口 `[0, viewportExtent)` 内即「已在本页可见」，reveal 不翻页。
///
/// 这是 JS `window.hoshiReader.scrollToRange` 落页决策的纯 Dart 影子（headless WebView 不可用，
/// 按项目测试范式：纯函数单测 + 源码守卫）。
void main() {
  // pageStep 比视口 extent 小半页：真实设备上 chrome inset / body padding 造成的失配。
  const double pageSize = 1000.0;
  const double viewportExtent = 1500.0; // pageStep < viewportExtent（相差半页）

  double? target({
    required double rectStart,
    required double currentScroll,
  }) =>
      ReaderPaginationScripts.revealScrollTargetForTesting(
        rectStart: rectStart,
        currentScroll: currentScroll,
        pageSize: pageSize,
        viewportExtent: viewportExtent,
      );

  group('BUG-875 句首落在 client 视口内即不翻页（消除页底 pitch/视口失配）', () {
    test('句首行尾单字：rect.top 落 [pageStep, viewportExtent) 带内 → 不翻页（原症状页）', () {
      // 停在第 2 页（currentScroll=2000）。句首单字在列底：rect.top=1200，越过
      // pageStep(1000) 但仍在 viewportExtent(1500) 内 = 视觉在本页底部。
      // 旧 floor：anchor=1200+2000=3200 → 落 3000（前翻一页，症状）。
      final double old =
          ReaderPaginationScripts.revealAnchorTargetScrollForTesting(
        rectStart: 1200,
        currentScroll: 2000,
        pageSize: pageSize,
      );
      expect(old, 3000, reason: '旧 floor 网格把页底可见句首判进下一 pitch 页 → 前翻（症状）');

      expect(target(rectStart: 1200, currentScroll: 2000), isNull,
          reason: '句首已在 client 视口内 → reveal 不翻页');
    });

    test('句首落 [0, pageStep) 常规区：本就同页 → 不翻页（回归保护）', () {
      expect(target(rectStart: 300, currentScroll: 2000), isNull);
    });

    test('句首恰在视口底边 viewportExtent：仍在本页 → 不翻页', () {
      expect(
          target(rectStart: viewportExtent - 1, currentScroll: 2000), isNull);
    });

    test('句首真在下一页（rect.top >= viewportExtent）：照常 floor 翻页', () {
      // rect.top=1600 越过视口 → 句首不可见、真需翻页。anchor=1600+2000=3600 → 落 3000。
      expect(target(rectStart: 1600, currentScroll: 2000), 3000);
    });

    test('句首已滚出视口首边（rect.top<0）：照常 floor 回翻', () {
      // 停在第 2 页，句首在上一页：rect.top=-200 → anchor=1800 → floor 落 1000。
      expect(target(rectStart: -200, currentScroll: 2000), 1000);
    });

    test('pageSize<=0：不翻页', () {
      expect(
        ReaderPaginationScripts.revealScrollTargetForTesting(
          rectStart: 1200,
          currentScroll: 2000,
          pageSize: 0,
          viewportExtent: viewportExtent,
        ),
        isNull,
      );
    });
  });

  group('BUG-875 源码守卫：scrollToRange 必须有 client 视口可见短路', () {
    final String scripts = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();

    String scrollToRangeBody() {
      final int start = scripts.indexOf('scrollToRange: function(range)');
      expect(start, greaterThanOrEqualTo(0), reason: '找不到 scrollToRange 定义');
      final int end = scripts.indexOf('notifyRestoreComplete: function', start);
      return scripts.substring(start, end >= 0 ? end : scripts.length);
    }

    test('getScrollContext 暴露 viewportExtent', () {
      expect(
        RegExp(r'viewportExtent\s*:\s*viewportExtent').hasMatch(scripts),
        isTrue,
        reason: 'scrollToRange 需从 context 读真实 client 视口 extent',
      );
    });

    test('scrollToRange 用 startEdge < viewportExtent 的可见短路', () {
      final String body = scrollToRangeBody();
      expect(
        RegExp(r'startEdge\s*<\s*context\.viewportExtent').hasMatch(body),
        isTrue,
        reason: '页底 pitch/视口失配的可见短路缺失 → BUG-875 竖排行尾单字翻页抖动回归',
      );
    });
  });
}
