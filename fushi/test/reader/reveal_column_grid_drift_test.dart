// BUG-2325 · 分页落页网格的**累积漂移**容差契约。
//
// 症状（真机 HiBreak 墨水屏，竖排分页 + 有声书跟随）：读到某一句时视口自己退回上一页，
// 下一句又翻回来。退回的那句无一例外是**句首恰好落在列顶**的句子。
//
// 根因不是相位（BUG-875/1764 那条已修），而是 `pageStep` 与浏览器真实列周期之间存在
// **每页累积**的亚像素差：
//   · `getScrollContext` 的 pageStep 由 `parseFloat(getComputedStyle(body).columnWidth)`
//     推出，而 CSSOM 把 used 值序列化成 3 位小数字符串；
//   · 浏览器排版时把 used 列宽量化到 LayoutUnit（1/64 px）。
//   两者只有在列宽恰好是 1/64 的整数倍时才相等。真机 824x1648 @300dpi → DPR 1.875 →
//   CSS 视口高 878.9333…px（小数）→ used 列宽 832.9333…px 被量化成 832.921875px，JS 却
//   读到 "832.933px"：pageStep 每页比真实列周期大约 0.0111px。
//
// 于是第 j 列的真实起始坐标比网格线 `j*pageStep` **低** j·δ。列顶首字的 reveal 锚恰好等于
// 该列真实起始坐标，裸 floor 就把它判进**前一列** → 视口退回上一页；下一句不在列顶、锚离
// 网格线远，又翻回来。整数 CSS 视口（列宽本就是 1/64 倍数）δ=0，所以这条只在小数 DPR 设备
// 上现形——也解释了为什么整数几何的既有用例与探针一直是绿的。
//
// 修复：列号函数带**下侧容差** gap —— 网格线之前那一段恰好是 column-gap，里面没有任何内容
// （前一列内容盒在 gap 之前就结束了），落进去的锚只可能是后一列被漂移带下来的列顶字。
//
// 真渲染证据（headless Chrome + 真引擎 shell + 该章真实正文 + 该节 4026 条真实 cue，按真机
// 几何 DPR 1.875 逐句走 scrollToRange）：修前退回 30~112 次/章（字号 22/40/46/52 与挤压态
// chrome inset 各一组），修后全部为 0。
//
// 本文件是那条决策的纯 Dart 影子（headless WebView 不可用，按项目测试范式：纯函数单测 +
// 源码守卫）。相位本身（BUG-875 / BUG-1764）由 reveal_viewport_visible_no_flip_test.dart 守。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

void main() {
  // 真机实测几何（HiBreak 824x1648 @300dpi，DPR 1.875，字号 46）：
  //   CSS 视口高 V = 1648/1.875 = 878.9333…；used 列宽 = V − F = 832.9333…
  //   CSSOM 序列化 "832.933px" → pageStep = 832.933 + 22 = 854.933
  //   浏览器量化 832.921875 → 真实列周期 = 854.921875
  const double gap = 22.0;
  const double pageSize = 854.933; // JS 侧网格步长（读序列化列宽推出）
  const double realPitch = 854.921875; // 浏览器真实列周期（LayoutUnit 量化后）
  const double drift = pageSize - realPitch; // ≈ 0.011125 px/页，累积
  const double contentStart = 0.0; // 真机默认上下页边距 0% + 悬浮 chrome

  /// 第 j 列列顶首字的 reveal 锚（= 该列真实起始坐标，绝对文档坐标）。
  double columnTopAnchor(int column) => contentStart + column * realPitch;

  /// 停在第 j 页时，列顶首字相对视口的起始边（reveal 拿到的 rect 起始边）。
  double rectStartAt(int column) =>
      columnTopAnchor(column) - column * pageSize + contentStart;

  double? revealTarget({
    required double rectStart,
    required double currentScroll,
    double columnGap = gap,
  }) =>
      ReaderPaginationScripts.revealScrollTargetForTesting(
        rectStart: rectStart,
        currentScroll: currentScroll,
        pageSize: pageSize,
        contentStart: contentStart,
        columnGap: columnGap,
      );

  group('BUG-2325 累积网格漂移下，列顶首字不得被判进前一列', () {
    test('漂移是真的：真机几何下每页差 ~0.0111px，第 9 页起就超过 0.1px', () {
      expect(drift, greaterThan(0));
      expect(drift * 9, greaterThan(0.1));
      expect(drift * 89, greaterThan(0.98));
      // 容差必须远大于整章累积量：本章最深 845 页。
      expect(drift * 845, lessThan(gap));
    });

    test('症状复现：不带容差时，列顶首字从第 9 页起就退回前一页', () {
      // 第 9 页：锚比网格线低 9·δ ≈ 0.1px，裸 floor 掉进第 8 页。
      final double? bare = revealTarget(
        rectStart: rectStartAt(9),
        currentScroll: 9 * pageSize,
        columnGap: 0,
      );
      expect(bare, isNotNull, reason: '裸网格判定要翻页 = 症状');
      expect((bare! / pageSize).round(), 8, reason: '列顶首字被判进前一列 → 用户看到视口退回上一页');
    });

    test('修复后：第 1~1900 页的列顶首字一律留在本页（不翻页）', () {
      for (int column = 1; column <= 1900; column++) {
        expect(
          revealTarget(
            rectStart: rectStartAt(column),
            currentScroll: column * pageSize,
          ),
          isNull,
          reason: '第 $column 页列顶首字仍属本页，reveal 不得移动视口',
        );
      }
    });

    test('容差是几何真值 gap，不是随手的 ε：漂移吃满 gap 之后才退化', () {
      // 漂移超过一个 gap（约 1978 页）后容差耗尽，如实退回——这是可预期的边界，
      // 不是静默错误；真实章节远达不到（本章 845 页，drift·845 ≈ 9.4px）。
      const int beyond = 2100;
      expect(drift * beyond, greaterThan(gap));
      expect(
        revealTarget(
          rectStart: rectStartAt(beyond),
          currentScroll: beyond * pageSize,
        ),
        isNotNull,
      );
    });
  });

  group('容差不得破坏既有两个方向（BUG-1764 / BUG-875 回归锁）', () {
    // 用一组干净的整数几何，避免与漂移量纠缠。
    const double cleanPage = 1000.0;
    const double cleanBox = cleanPage - gap; // 978
    const double phase = 60.0;
    const double font = 22.0;
    const double current = 2 * cleanPage;

    double? clean(double rectStart) =>
        ReaderPaginationScripts.revealScrollTargetForTesting(
          rectStart: rectStart,
          currentScroll: current,
          pageSize: cleanPage,
          contentStart: phase,
          columnGap: gap,
        );

    test('BUG-1764：下一页第一句仍然必须翻页', () {
      expect(clean(phase + cleanPage), current + cleanPage);
    });

    test('BUG-875：本页行尾单字仍然不得前翻', () {
      expect(clean(phase + cleanBox - font), isNull);
    });

    test('列末最后一像素仍属本页（容差恰好不越界）', () {
      // 列内最大锚 = contentStart + contentBox（不含），加 gap 恰好等于 pageSize。
      expect(clean(phase + cleanBox - 0.001), isNull);
    });

    test('句首已滚出视口首边：仍回翻到句首所在页', () {
      expect(clean(phase - cleanPage + cleanBox - 200), current - cleanPage);
    });
  });

  group('源码守卫：JS 侧容差三段线（读 gap → 挂 context → 用进 floor）', () {
    final String scripts = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();

    String functionBody(String startMarker, String endMarker) {
      final int start = scripts.indexOf(startMarker);
      expect(start, greaterThanOrEqualTo(0), reason: '找不到 $startMarker');
      final int end = scripts.indexOf(endMarker, start);
      return scripts.substring(start, end >= 0 ? end : scripts.length);
    }

    test('getScrollContext 把 column-gap 挂进 context', () {
      final String body = functionBody(
        'getScrollContext: function()',
        'getPagePosition: function(context)',
      );
      expect(
        RegExp(r'columnGap\s*:\s*gap').hasMatch(body),
        isTrue,
        reason: '容差取自真实 column-gap；不挂进 context 就静默塌成 0',
      );
    });

    test('alignToPage 用 context.columnGap 做下侧容差', () {
      final String body = functionBody(
        'alignToPage: function(context, offset)',
        'alignContentStartToPage: function',
      );
      expect(
        RegExp(r'gapTolerance\s*=\s*context\.columnGap').hasMatch(body),
        isTrue,
        reason: '写死 0 = 容差失效，BUG-2325 静默回归',
      );
      expect(
        RegExp(r'offset\s*-\s*phase\s*\+\s*gapTolerance').hasMatch(body),
        isTrue,
        reason: '容差必须真的进 floor 的被除数',
      );
    });

    test('alignContentStartToPage 不吃容差（章首落点绝不跳过首行）', () {
      final String body = functionBody(
        'alignContentStartToPage: function',
        'pageStepPosition: function',
      );
      expect(
        body.contains('gapTolerance'),
        isFalse,
        reason: '章首 minScroll 吃了容差会把首行内容边推进下一列 → 跳过首行（TODO-1179）',
      );
      expect(
        RegExp(r'offset\s*-\s*phase').hasMatch(body),
        isTrue,
        reason: '章首落点仍必须减相位',
      );
    });

    test('scrollToCharOffset 的 charPage 走同一个列号函数', () {
      final String body = functionBody(
        'scrollToCharOffset: function(charOffset, hintScroll)',
        'notifyRestoreComplete: function',
      );
      expect(
        RegExp(
          r'charPage\s*=\s*Math\.round\(\s*this\.alignToPage\(',
        ).hasMatch(body),
        isTrue,
        reason: '裸 floor(scrollOffset/pageSize) 既漏相位也吃不住漂移，'
            '精确锚恢复 / 样式重锚落到页首字时同样退回前一列',
      );
    });
  });
}
