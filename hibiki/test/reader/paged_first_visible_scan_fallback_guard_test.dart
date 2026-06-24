import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-773 P0 源码守卫（源码扫描，沿用 `reader_paginate_js_guard_static_test.dart` 的
/// `File(...).readAsStringSync()` + 函数切片 + `contains` 模式）。
///
/// 现象（老大难）：竖排切字号 / 字体 / 主题后正文漂移。根因 A：分页版
/// `getFirstVisibleCharOffset` 三个失败出口（caretRangeFromPoint 返 null / walker 无
/// 文本节点 / nodeStartOffsets 未建）**全是裸 `return -1`，无扫描兜底**；而连续版在相同
/// 三失败点都回退 `firstVisibleCharOffsetByScan()`。竖排切样式 → `beginStyleReanchor`
/// 调分页版 → 页顶落 ruby/图片/折叠盒 → caret 返 null → 分页版返 -1 →
/// `beginStyleReanchor` 返 -1 → Dart 跳过 commit → CSS 已换但 scrollTop 停残值不滚回 →
/// 漂移。
///
/// 修复（轴感知兜底）：分页版三失败出口改回退 `firstVisibleCharOffsetByScanPaged()`。
/// **关键不变量**：分页兜底的视口首边判据必须用 **body-relative 量纲**
/// （`document.body.clientWidth`），不得直接调用 window 量纲（`window.innerWidth`）的
/// 连续版 `firstVisibleCharOffsetByScan`——分页几何 scrollEl=document.body / 分页 caret
/// 探边用 `document.body.clientWidth-pr`，刻意不用 window.innerWidth。裸抄连续版会在 body
/// 不满窗时锚到错列。
///
/// headless WebView 在 CI 跑不到（main.yml 走 Linux 无 WebView2），故只能源码守卫锁住
/// 「三失败分支不得裸 return -1」「分页兜底用 body-relative 量纲」不回退；数值/真机行为
/// 由 `tool/reader_pitch_headless/` 探针 + 真机复测覆盖（见回报与 BUG-405）。
void main() {
  late String source;
  late String pagedGetFirst;
  late String pagedScan;
  late String pagedCountChars;
  late String pagedIsBefore;
  // 去掉 `//` 行注释后的纯可执行代码切片：负向断言（不得出现 window.innerWidth /
  // 裸 return -1）只能针对真实代码，否则解释「为什么不用 X」的注释会把 X 当成违规命中。
  late String pagedGetFirstCode;
  late String pagedScanCode;
  late String pagedCountCharsCode;
  late String pagedIsBeforeCode;

  setUpAll(() {
    source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
    // 分页版 getFirstVisibleCharOffset 紧跟 paginate 之后、scrollToCharOffset(charOffset,
    // hintScroll)（带 hintScroll 形参是分页版独有）之前。
    pagedGetFirst = _functionSource(
      source,
      '  getFirstVisibleCharOffset: function() {\n    var context = this.getScrollContext();',
      '\n  scrollToCharOffset: function(charOffset, hintScroll) {',
    );
    pagedScan = _functionSource(
      source,
      '  firstVisibleCharOffsetByScanPaged: function() {',
      '\n  countCharsBeforeViewportPaged:',
    );
    pagedCountChars = _functionSource(
      source,
      '  countCharsBeforeViewportPaged: function(node, vertical, firstEdge) {',
      '\n  isTextOffsetBeforeViewportPaged:',
    );
    pagedIsBefore = _functionSource(
      source,
      '  isTextOffsetBeforeViewportPaged: function(node, offset, text, vertical, firstEdge) {',
      '\n  buildSasayakiNormIndex:',
    );
    pagedGetFirstCode = _stripJsLineComments(pagedGetFirst);
    pagedScanCode = _stripJsLineComments(pagedScan);
    pagedCountCharsCode = _stripJsLineComments(pagedCountChars);
    pagedIsBeforeCode = _stripJsLineComments(pagedIsBefore);
  });

  group('TODO-773 P0：分页版 getFirstVisibleCharOffset 三失败出口必有扫描兜底', () {
    test('三个失败分支全部回退 firstVisibleCharOffsetByScanPaged（不得裸 return -1）', () {
      // 三处 `return this.firstVisibleCharOffsetByScanPaged()` 分别对应：
      // caret 返 null / walker 无文本节点 / nodeStartOffsets 未建。
      final int fallbacks = 'return this.firstVisibleCharOffsetByScanPaged();'
          .allMatches(pagedGetFirst)
          .length;
      expect(
        fallbacks,
        equals(3),
        reason: '分页版三个失败出口都必须回退 firstVisibleCharOffsetByScanPaged，'
            '否则竖排页顶 ruby/图片 caret 返 null → -1 → 跳过 commit → 切样式漂移',
      );
    });

    test('分页版函数体内不得再出现裸 return -1（根因 A 守死）', () {
      expect(
        pagedGetFirstCode.contains('return -1'),
        isFalse,
        reason: '分页版三失败出口的裸 return -1 是 TODO-773 漂移根因 A，'
            '必须全部换成 firstVisibleCharOffsetByScanPaged 兜底',
      );
    });

    test('分页 caret 探边仍用 body-relative 量纲 document.body.clientWidth（不漂回 window）',
        () {
      expect(
        pagedGetFirst.contains('document.body.clientWidth - pr - 2'),
        isTrue,
        reason: '分页版 caret 竖排探边必须用 document.body.clientWidth（body-relative），'
            '不得改用 window.innerWidth',
      );
    });
  });

  group('TODO-773 P0：分页兜底必须 body-relative，不得裸抄连续版 window 量纲', () {
    test(
        '分页版 getFirstVisibleCharOffset 不调用连续版 window 量纲的 firstVisibleCharOffsetByScan',
        () {
      // 只允许出现带 Paged 后缀的分页专版调用，绝不能调用无后缀的连续版（window.innerWidth）。
      expect(
        pagedGetFirstCode.contains('this.firstVisibleCharOffsetByScan()'),
        isFalse,
        reason: '分页版禁止回退连续版 firstVisibleCharOffsetByScan（window.innerWidth 量纲），'
            '必须用 body-relative 的 firstVisibleCharOffsetByScanPaged',
      );
    });

    test(
        'firstVisibleCharOffsetByScanPaged 竖排首边用 document.body.clientWidth（横排用 0）',
        () {
      expect(
        pagedScan.contains('document.body.clientWidth'),
        isTrue,
        reason: '分页扫描兜底竖排首边参照必须是 document.body.clientWidth（与分页 caret 同量纲）',
      );
      expect(
        pagedScanCode.contains('window.innerWidth'),
        isFalse,
        reason: '分页扫描兜底不得用 window 量纲 window.innerWidth',
      );
      expect(
        pagedScan.contains(
            'var firstEdge = vertical ? document.body.clientWidth : 0;'),
        isTrue,
        reason: '竖排首边=document.body.clientWidth、横排首边=0（分页 body 填满视口左上角）',
      );
      // 兜底必须走分页专版的逐节点累加，不串到连续版。
      expect(
        pagedScan.contains('this.countCharsBeforeViewportPaged('),
        isTrue,
        reason:
            '分页扫描兜底必须调 countCharsBeforeViewportPaged（传入 body-relative firstEdge）',
      );
    });

    test('countCharsBeforeViewportPaged 判据用传入 firstEdge，不硬编码 window.innerWidth',
        () {
      expect(
        pagedCountCharsCode.contains('window.innerWidth'),
        isFalse,
        reason: '分页版 countChars 不得用 window 量纲，首边一律走传入的 firstEdge 参数',
      );
      expect(
        pagedCountChars.contains('this.isTextOffsetBeforeViewportPaged('),
        isTrue,
        reason: '二分必须调分页版 isTextOffsetBeforeViewportPaged（带 firstEdge）',
      );
      // 竖排三态短路用 firstEdge。
      expect(
        pagedCountChars
            .contains('if (minStart >= firstEdge) return totalChars;'),
        isTrue,
        reason: '竖排已滚出首边判据必须用传入 firstEdge',
      );
    });

    test(
        'isTextOffsetBeforeViewportPaged 竖排判 rect.left>=firstEdge、横排判 rect.bottom<=firstEdge',
        () {
      expect(
        pagedIsBeforeCode.contains('window.innerWidth'),
        isFalse,
        reason: '分页版单字符判据不得用 window 量纲',
      );
      expect(
        pagedIsBefore.contains(
            'return vertical ? rect.left >= firstEdge : rect.bottom <= firstEdge;'),
        isTrue,
        reason:
            '竖排 rect.left>=firstEdge（=body.clientWidth）/ 横排 rect.bottom<=firstEdge（=0）',
      );
    });
  });

  group('TODO-773 P0：连续版 window 量纲三件套零改动（别误把分页量纲串进连续路径）', () {
    test(
        '连续版 firstVisibleCharOffsetByScan 仍存在且仍调 countCharsBeforeViewport（无 Paged 后缀）',
        () {
      final String continuousScan = _functionSource(
        source,
        '  firstVisibleCharOffsetByScan: function() {',
        '\n  // TODO-773 P0：分页版 getFirstVisibleCharOffset',
      );
      expect(
        continuousScan
            .contains('this.countCharsBeforeViewport(node, vertical)'),
        isTrue,
        reason: '连续版扫描兜底必须仍调无后缀的 countCharsBeforeViewport（window 量纲），不被改写',
      );
    });

    test('连续版 isTextOffsetBeforeViewport 仍用 window.innerWidth（竖排首边）', () {
      final String continuousIsBefore = _functionSource(
        source,
        '  isTextOffsetBeforeViewport: function(node, offset, text, vertical) {',
        '\n  // TODO-736 A-2：getFirstVisibleCharOffset 的全文扫描兜底',
      );
      expect(
        continuousIsBefore.contains(
            'return vertical ? rect.left >= window.innerWidth : rect.bottom <= 0;'),
        isTrue,
        reason: '连续版（window 量纲）判据必须保持 window.innerWidth / 0，不得被分页改动污染',
      );
    });

    test('连续版 getFirstVisibleCharOffset 仍回退连续版 firstVisibleCharOffsetByScan',
        () {
      final String continuousGetFirst = _functionSource(
        source,
        '  getFirstVisibleCharOffset: function() {\n    var vertical = this.isVertical();',
        '\n  // BUG-162: 连续模式按 section 内绝对字符偏移定位',
      );
      final int fallbacks = 'return this.firstVisibleCharOffsetByScan();'
          .allMatches(continuousGetFirst)
          .length;
      expect(
        fallbacks,
        equals(3),
        reason: '连续版三失败出口仍回退连续版 firstVisibleCharOffsetByScan（window 量纲），不被改动',
      );
    });
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

/// 删掉 `//` 行注释（整行以可选空白 + `//` 起的行），保留可执行代码行。负向断言只能针对
/// 真实代码——否则解释「为什么不用 window.innerWidth / 不裸 return -1」的注释会被误判违规。
/// 这些 JS 全是 `_sharedJs` 里的行注释（无 `/* */` 块、无字符串内嵌 `//`），按行剥即足够。
String _stripJsLineComments(String slice) {
  return slice
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}
