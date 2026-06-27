import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-881：有声书自动读逐句 reveal 翻页抖动（中点锚 → 起始边锚）。
///
/// 根因：`reader_pagination_scripts.dart` 的 `scrollToRange`（cue-follow +
/// search-highlight 共用的落页路径）用 cue 首段 client rect 的**几何中点**当翻页
/// 锚（`(top+bottom)/2` 或 `(left+right)/2`）再 `alignToPage`(floor) 落页。这是
/// 分页引擎里**唯一**用中点的落页路径，其余（恢复 / jumpToFragment /
/// scrollToCharOffset）全用**起始边**。
///
/// 当一句 cue 首行 rect 在分页轴向占大半列、且这句可见**起点**落在当前列后半段时，
/// rect 中点越界进相邻列，floor 落到下一页（前翻）；下一句中点又落回 → 翻回。逐句
/// 在「中点越界/不越界」间摆动 = 有声书自动读来回抖动。
///
/// 修复：锚取**起始边**（竖排 rect.top、横排 rect.left），与引擎其余统一。起始边
/// 锚恒等于「这句开头所在那一页」，不越界。
///
/// 这是 JS `window.hoshiReader.scrollToRange` 落页锚的纯 Dart 影子（headless
/// WebView 不可用，按项目测试范式：纯函数单测 + 源码守卫）。
void main() {
  const double pageSize = 1000.0;

  /// 旧实现（中点锚）的等价计算，仅用于在测试里证明「中点会越界落到相邻页」这一
  /// 失败场景确实存在，并对比起始边的正确行为。
  double midpointTarget({
    required double rectStart,
    required double rectExtent,
    required double currentScroll,
  }) {
    final double mid = rectStart + rectExtent / 2;
    final double anchor = mid + currentScroll;
    final double safe = anchor < 0 ? 0 : anchor;
    return (safe / pageSize).floorToDouble() * pageSize;
  }

  double startEdgeTarget({
    required double rectStart,
    required double currentScroll,
  }) =>
      ReaderPaginationScripts.revealAnchorTargetScrollForTesting(
        rectStart: rectStart,
        currentScroll: currentScroll,
        pageSize: pageSize,
      );

  group('TODO-881 起始边锚落到「句子起点所在页」（消除中点越界）', () {
    test('句首落当前列后半段、rect 中点越界相邻列：起始边不前翻', () {
      // 当前停在第 2 页（currentScroll=2000）。这句 cue 首行 rect 起点落在该列
      // 偏后（rectStart=600，即列内 0.6 处），首行 rect 宽 700（占大半列）→ 中点
      // = 600 + 350 = 950，越界进 [1000,2000) 相邻列。
      const double currentScroll = 2000;
      const double rectStart = 600;
      const double rectExtent = 700;

      // 旧中点锚：anchor = 950 + 2000 = 2950 → floor 落 2000？不——验证它确实越界。
      final double mid = midpointTarget(
        rectStart: rectStart,
        rectExtent: rectExtent,
        currentScroll: currentScroll,
      );
      // 中点 anchor=2950 → 仍在第 2 页内。换个让它真正越界进下一页的构造：
      // 起点更靠后 + 更宽 rect，使中点 >= 下一页边界。
      expect(mid, 2000); // 这组 0.95 列还没越界，说明需要更极端构造

      // 真正越界构造：rectStart=700, rectExtent=700 → mid=1050 → anchor=3050 →
      // floor 落 3000（前翻一页）；起始边 anchor=700+2000=2700 → floor 落 2000。
      final double midOver = midpointTarget(
        rectStart: 700,
        rectExtent: 700,
        currentScroll: currentScroll,
      );
      expect(midOver, 3000, reason: '中点锚在句首落列后半段时越界相邻列 → floor 前翻到下一页（症状）');

      final double startEdge =
          startEdgeTarget(rectStart: 700, currentScroll: currentScroll);
      expect(startEdge, 2000, reason: '起始边锚恒落「句子起点所在页」，不越界、不前翻');

      // 双锚分歧正是抖动来源：修复后必须取起始边那一页。
      expect(startEdge, isNot(equals(midOver)));
    });

    test('下一句句首落列前半段：中点回落上一页（翻回），起始边稳定同页', () {
      const double currentScroll = 2000;
      // 下一句首行 rect 起点落在第 2 页较前（rectStart=100），宽 700 → 中点
      // = 450 → anchor=2450 → floor 落 2000（停回上一页）。与上一句中点落 3000
      // 形成「前翻 → 翻回」抖动。
      final double mid = midpointTarget(
        rectStart: 100,
        rectExtent: 700,
        currentScroll: currentScroll,
      );
      expect(mid, 2000);

      final double startEdge =
          startEdgeTarget(rectStart: 100, currentScroll: currentScroll);
      expect(startEdge, 2000,
          reason: '起始边对相邻两句都落第 2 页 → 不抖动（中点会在 3000/2000 间摆动）');
    });

    test('句首恰落整页边界：起始边 floor 落该页起点', () {
      final double startEdge =
          startEdgeTarget(rectStart: 0, currentScroll: 2000);
      expect(startEdge, 2000);
    });

    test('负 anchor clamp 到第 0 页', () {
      final double startEdge =
          startEdgeTarget(rectStart: -50, currentScroll: 0);
      expect(startEdge, 0);
    });

    test('pageSize<=0 回退当前滚动量（与 JS pageSize<=0 早退一致）', () {
      final double t =
          ReaderPaginationScripts.revealAnchorTargetScrollForTesting(
        rectStart: 700,
        currentScroll: 2000,
        pageSize: 0,
      );
      expect(t, 2000);
    });
  });

  group('TODO-881 源码守卫：scrollToRange 必须用起始边锚（中点回归即红）', () {
    final String scripts = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();

    /// 取 `scrollToRange` 函数体（从签名到下一个对象方法 `notifyRestoreComplete`
    /// 之前；同对象字面量里方法以 `name: function` 形式排列）。
    String scrollToRangeBody() {
      final int start = scripts.indexOf('scrollToRange: function(range)');
      expect(start, greaterThanOrEqualTo(0), reason: '找不到 scrollToRange 定义');
      // 下一个方法 notifyRestoreComplete 紧随其后（见同文件 :1546 / :710 结构）。
      final int end = scripts.indexOf('notifyRestoreComplete: function', start);
      return scripts.substring(start, end >= 0 ? end : scripts.length);
    }

    test('scrollToRange 不含中点锚（rect.bottom)/2 或 (rect.right)/2）', () {
      final String body = scrollToRangeBody();
      expect(
        RegExp(r'rect\.bottom\s*\)\s*/\s*2').hasMatch(body),
        isFalse,
        reason: '竖排中点锚 (rect.top + rect.bottom)/2 回归 → 有声书自动读翻页抖动',
      );
      expect(
        RegExp(r'rect\.right\s*\)\s*/\s*2').hasMatch(body),
        isFalse,
        reason: '横排中点锚 (rect.left + rect.right)/2 回归 → 有声书自动读翻页抖动',
      );
    });

    test('scrollToRange 用起始边锚（竖排 rect.top、横排 rect.left）', () {
      final String body = scrollToRangeBody();
      expect(
        RegExp(r'context\.vertical\s*\?\s*rect\.top\s*:\s*rect\.left')
            .hasMatch(body),
        isTrue,
        reason: '落页锚必须与 restoreToCharOffset / jumpToFragment 起始边轴向一致',
      );
    });
  });
}
