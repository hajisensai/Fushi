// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// 分页 reveal 落页的**网格相位**契约：BUG-875 与 BUG-1764 是同一个缺陷的两面。
///
/// `scrollToRange` 是 cue-follow + search-highlight 共用的落页路径：取句首起始边
/// （竖排 `rect.top`、横排 `rect.left`）+ 当前滚动量得到 anchor，再 `alignToPage` 落页。
///
/// 滚动坐标的原点是 body 的 **padding box** 起始边，而列内容从 **content box** 起始边
/// 开始，两者恰差一个 turn 轴起始 padding（竖排 `padding-top`＝含 `--chrome-top-inset`，
/// 横排 `padding-left`＝`margin-left vw`）。所以列 j 的起始滚动坐标是
/// `contentStart + j*pageStep`，**不是** `j*pageStep`。裸 `floor(anchor/pageStep)` 等于把
/// 网格整体平移了 contentStart，两个方向各错一次：
///
/// - `contentStart > column-gap` → 每列末尾 `contentStart − gap` 那段被判进下一列：
///   有声书读到「句首是行尾单字」的 cue 时凭空前翻一页、下一句又翻回 = 抖动（**BUG-875**）。
/// - 旧修法给 `scrollToRange` 加了一条 `rectStart < viewportExtent` 的「已可见即不翻」
///   短路。client 视口比一页真正的内容宽出 turn 轴**两侧** padding，于是**结束边** padding
///   > gap 时（横排 W>1100px 的宽屏、竖排字号>22 / 底栏占位 / 移动端系统 inset），下一页
///   开头那段落进 `[pageStep, viewportExtent)` 带、被判成「本页可见」→ 该翻不翻，要等下一句
///   才翻，用户感知就是「有声书下一页的第一句话不会自动翻页」（**BUG-1764**）。
///
/// 两个场景的 `rectStart` / `targetScroll` 取值完全相同，单一阈值结构上区分不了 —— 判据
/// 维度本身就错了。根因修复是给 `alignToPage` 补上相位，之后 `targetScroll == currentScroll`
/// 已经精确表达「句首就在本页」，可见性特例短路不再需要。
///
/// 这是 JS `window.fushiReader.scrollToRange` 落页决策的纯 Dart 影子（headless WebView
/// 不可用，按项目测试范式：纯函数单测 + 源码守卫）。
void main() {
  // 一组自洽的真实几何（量纲取自 reader_content_styles.dart 的 body 规则）：
  //   column-gap 恒 22px；列周期 pageStep = contentBox + gap；
  //   client 视口 extent = contentStart + contentBox + contentEnd（body 是 border-box、
  //   margin/border 皆 0，故 client == padding box）。
  // contentStart=60 取「竖排移动端状态栏 + 顶部进度挤压」量级（> gap，BUG-875 的成立条件）；
  // contentEnd=100 取「字号 22px + 底栏占位」量级（> gap，BUG-1764 的成立条件）。
  const double gap = 22.0;
  const double contentBox = 978.0;
  const double pageSize = contentBox + gap; // 1000
  const double contentStart = 60.0;
  const double contentEnd = 100.0;
  const double viewportExtent = contentStart + contentBox + contentEnd; // 1138
  const double fontSize = 22.0;

  // 当前停在第 2 页（页网格恒为 j*pageStep）。
  const double currentScroll = 2 * pageSize;

  double? target(double rectStart) =>
      ReaderPaginationScripts.revealScrollTargetForTesting(
        rectStart: rectStart,
        currentScroll: currentScroll,
        pageSize: pageSize,
        contentStart: contentStart,
      );

  /// 补相位前的裸网格（旧 `alignToPage`），仅用于证明症状真实存在。
  double legacyTarget(double rectStart) =>
      ((rectStart + currentScroll) / pageSize).floorToDouble() * pageSize;

  /// 旧的「已可见即不翻」短路（BUG-875 旧修法），仅用于证明它吞掉了下一页开头。
  bool legacyVisibleShortCircuit(double rectStart) =>
      rectStart >= 0 && rectStart < viewportExtent;

  group('BUG-1764 下一页第一句必须翻页（旧 client 视口短路吞掉了下一页开头）', () {
    // 列 j 起始滚动坐标 = contentStart + j*pageStep，故停在第 2 页时下一页（列 3）
    // 的第一句句首起始边 = contentStart + pageStep。
    const double nextPageFirstCue = contentStart + pageSize; // 1060

    test('症状复现：下一页首句起始边落在旧短路带内 → 旧实现判「已可见」不翻页', () {
      expect(nextPageFirstCue, greaterThanOrEqualTo(pageSize),
          reason: '句首已越过列周期边界 = 真的在下一页');
      expect(nextPageFirstCue, lessThan(viewportExtent),
          reason: '但仍落在 client 视口内 → 旧短路把它当成本页可见');
      expect(legacyVisibleShortCircuit(nextPageFirstCue), isTrue,
          reason: '旧 rectStart<viewportExtent 短路命中 → 该翻不翻（BUG-1764 症状）');
    });

    test('修复后：下一页首句落到下一页网格线上，翻页', () {
      expect(target(nextPageFirstCue), currentScroll + pageSize);
    });

    test('下一页首句之后的整页内容都落同一页，不会翻过头', () {
      // 下一页（列 3）内容的滚动坐标范围 = [contentStart+3*pageStep, +contentBox]。
      // 相对当前滚动的起始边 = contentStart+pageStep .. contentStart+pageStep+contentBox。
      for (final double offsetInPage in <double>[0, 1, 300, contentBox - 1]) {
        expect(
            target(nextPageFirstCue + offsetInPage), currentScroll + pageSize,
            reason: '列内偏移 $offsetInPage 仍属下一页，不该翻两页');
      }
      // 裸网格在这里会翻过头整整一页（相位缺失的第二个症状）。
      expect(legacyTarget(nextPageFirstCue + contentBox - 1),
          currentScroll + 2 * pageSize,
          reason: '旧网格把下一页后半段判进再下一页');
    });
  });

  group('BUG-875 本页行尾单字不得凭空前翻（相位修正后无需可见性特例）', () {
    // 竖排一句 cue 的句首是行尾单字 = 落在列的 inline 轴末端，其起始边（字的顶边）
    // = contentStart + contentBox − 字高。
    const double lineTailChar = contentStart + contentBox - fontSize; // 1016

    test('症状复现：裸网格把列末尾 (contentStart − gap) 那段判进下一列 → 前翻', () {
      expect(contentStart, greaterThan(gap),
          reason: 'contentStart > gap 是 BUG-875 的成立条件');
      expect(lineTailChar, greaterThanOrEqualTo(pageSize),
          reason: '视觉仍在本页列底，却已越过裸网格的页边界');
      expect(legacyTarget(lineTailChar), currentScroll + pageSize,
          reason: '旧裸网格前翻一页（BUG-875 症状）');
    });

    test('修复后：行尾单字仍属本页 → 不翻页', () {
      expect(target(lineTailChar), isNull);
    });

    test('列内任意位置都属本页（相邻句不再在翻/不翻之间摆动）', () {
      for (final double edge in <double>[
        contentStart, // 列首
        contentStart + 1,
        contentStart + contentBox / 2,
        contentStart + contentBox - 1, // 列末最后一像素
      ]) {
        expect(target(edge), isNull, reason: '起始边 $edge 仍在本页列内');
      }
    });
  });

  group('reveal 落页的其余边界（回归保护）', () {
    test('句首已滚出视口首边（rectStart<0）：回翻到句首所在页', () {
      // 句首在上一页列内：相对起始边 = contentStart + contentBox − pageStep − 200。
      const double prevPage = contentStart - pageSize + contentBox - 200;
      expect(prevPage, lessThan(0));
      expect(target(prevPage), currentScroll - pageSize);
    });

    test('句首恰在本页内容起始边：不翻页', () {
      expect(target(contentStart), isNull);
    });

    test('pageSize<=0：不翻页（与 JS 早退一致）', () {
      expect(
        ReaderPaginationScripts.revealScrollTargetForTesting(
          rectStart: contentStart + pageSize,
          currentScroll: currentScroll,
          pageSize: 0,
          contentStart: contentStart,
        ),
        isNull,
      );
    });

    test('contentStart 省略时退化为裸网格（连续/VN 等无相位场景零行为变化）', () {
      expect(
        ReaderPaginationScripts.revealScrollTargetForTesting(
          rectStart: pageSize,
          currentScroll: currentScroll,
          pageSize: pageSize,
        ),
        currentScroll + pageSize,
      );
    });
  });

  group('源码守卫：落页网格必须带相位，且不得复活 client 视口可见短路', () {
    final String scripts = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();

    String functionBody(String signature, String nextSignature) {
      final int start = scripts.indexOf(signature);
      expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
      final int end = scripts.indexOf(nextSignature, start);
      return scripts.substring(start, end >= 0 ? end : scripts.length);
    }

    test('getScrollContext 暴露 contentStart（turn 轴起始 padding）', () {
      expect(
        RegExp(r'contentStart\s*:\s*contentStart').hasMatch(scripts),
        isTrue,
        reason: 'alignToPage 需要从 context 读列网格相位',
      );
      expect(
        RegExp(r'contentStart\s*=\s*vertical\s*\?\s*\(parseFloat\(cs\.paddingTop\)')
            .hasMatch(scripts),
        isTrue,
        reason: '相位必须按 turn 轴取 paddingTop/paddingLeft，与落页锚同源',
      );
    });

    test('alignToPage 先减相位再 floor', () {
      final String body = functionBody('alignToPage: function(context, offset)',
          'alignContentStartToPage: function');
      expect(
        RegExp(r'offset\s*-\s*phase').hasMatch(body),
        isTrue,
        reason: '缺相位 → BUG-875 前翻 / BUG-1764 该翻不翻同时回归',
      );
    });

    test('scrollToRange 不得再用 client 视口 extent 作可见短路', () {
      final String body = functionBody(
          'scrollToRange: function(range)', 'notifyRestoreComplete: function');
      expect(
        RegExp(r'^\s*if\s*\([^\n]*startEdge\s*<\s*context\.viewportExtent',
                multiLine: true)
            .hasMatch(body),
        isFalse,
        reason: 'client 视口比一页内容宽出两侧 padding，该短路会吞掉下一页开头（BUG-1764）',
      );
    });
  });
}
