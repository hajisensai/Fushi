import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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
/// **关键不变量**：分页兜底的「在首边之前」判据必须沿**翻页轴**、用 **body-relative
/// 量纲**：分页是 CSS multicol 沿翻页轴排列（横排列沿 x、scrollLeft 翻页；竖排列沿 y、
/// scrollTop 翻页），前页在横排的左侧 / 竖排的上方，首边是 body content-box 起点
/// （横排 padding-left / 竖排 padding-top，`pagedFirstEdge`），与分页 caret 探点
/// `pl + 2` / `pt + 2` 同量纲；不得直接调用 window 量纲（`window.innerWidth`）的连续版
/// `firstVisibleCharOffsetByScan`。
///
/// BUG-2492：此前分页兜底抄了**连续版的轴**（横排 `rect.bottom<=0`、竖排
/// `rect.left>=body.clientWidth`），分页几何下前页永远不满足 → 逐节点累加恒 0 →
/// 兜底把任何页报成章首 0；重锚路径被 `scrollToCharOffset` 的 `<=0 → 保当前页` 掩住，
/// 统计接入后（`fushiProgressDetails` 第三/四段）页首角落在插图时整段 [0, 页尾) 被当成
/// 本页可见区间，一次翻页把几千字前文计成已读（iOS 真机 5172 字）。
///
/// headless WebView 在 CI 跑不到（main.yml 走 Linux 无 WebView2），故本文件用源码守卫
/// 锁住「三失败分支不得裸 return -1」「分页兜底沿翻页轴 + body-relative 量纲」不回退；
/// 数值行为由 `paged_first_visible_scan_axis_behavior_test.dart`（Node 真跑分页 shell）
/// 覆盖，真机由 `tool/reader_pitch_headless/` 探针 + 复测（见回报与 BUG-405）。
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
      '\n  pagedFirstEdge: function(vertical) {',
    );
    pagedCountChars = _functionSource(
      source,
      '  countCharsBeforeViewportPaged: function(node, vertical, firstEdge) {',
      '\n  isTextOffsetBeforeViewportPaged:',
    );
    pagedIsBefore = _functionSource(
      source,
      '  isTextOffsetBeforeViewportPaged: function(node, offset, text, vertical, firstEdge) {',
      '\n  charOffsetOnCurrentPage: function(charOffset) {',
    );
    pagedGetFirstCode = _stripJsLineComments(pagedGetFirst);
    pagedScanCode = _stripJsLineComments(pagedScan);
    pagedCountCharsCode = _stripJsLineComments(pagedCountChars);
    pagedIsBeforeCode = _stripJsLineComments(pagedIsBefore);
  });

  group('TODO-773 P0：分页版 getFirstVisibleCharOffset 三失败出口必有扫描兜底', () {
    test('三个失败分支全部回退 firstVisibleCharOffsetByScanPaged（不得裸 return -1）', () {
      // 三处 `return this.firstVisibleCharOffsetByScanPaged()` 分别对应：
      // caret 返 null / 探点落在元素上（BUG-2492：不再取元素子树首个文本节点）/
      // nodeStartOffsets 未建。
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
        'firstVisibleCharOffsetByScanPaged 首边 = 翻页轴上的 content-box 起点（pagedFirstEdge）',
        () {
      expect(
        pagedScanCode.contains('window.innerWidth'),
        isFalse,
        reason: '分页扫描兜底不得用 window 量纲 window.innerWidth',
      );
      expect(
        pagedScan.contains('var firstEdge = this.pagedFirstEdge(vertical);'),
        isTrue,
        reason: 'BUG-2492：首边必须是翻页轴上的 content-box 起点'
            '（横排 padding-left / 竖排 padding-top），不是连续版的 0 / body.clientWidth',
      );
      final String firstEdge = _functionSource(
        source,
        '  pagedFirstEdge: function(vertical) {',
        '\n  pagedLastEdge: function(vertical) {',
      );
      expect(
        firstEdge.contains('(parseFloat(cs.paddingTop) || 0)') &&
            firstEdge.contains('(parseFloat(cs.paddingLeft) || 0)'),
        isTrue,
        reason: 'pagedFirstEdge 竖排=padding-top、横排=padding-left（与分页 caret 探点同量纲）',
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
      // 三态短路沿翻页轴：整个节点在首边之前 → 全计；整个节点在首边之后 → 0。
      expect(
        pagedCountChars.contains('if (maxEnd <= firstEdge) return totalChars;'),
        isTrue,
        reason: 'BUG-2492：「整节点在前页」= 翻页轴终边 <= firstEdge（横竖同式）',
      );
      expect(
        pagedCountChars.contains(
            'if (minStart >= firstEdge || minStart === Infinity) return 0;'),
        isTrue,
        reason: '「整节点在本页或之后」= 翻页轴起边 >= firstEdge（横竖同式）',
      );
      expect(
        pagedCountChars.contains('var start = vertical ? rect.top : rect.left;') &&
            pagedCountChars.contains('var end = vertical ? rect.bottom : rect.right;'),
        isTrue,
        reason: 'BUG-2492：翻页轴 = 竖排 y（top/bottom）、横排 x（left/right），'
            '不是连续版的竖排 x / 横排 y',
      );
    });

    test(
        'isTextOffsetBeforeViewportPaged 沿翻页轴判：竖排 rect.bottom<=firstEdge、横排 rect.right<=firstEdge',
        () {
      expect(
        pagedIsBeforeCode.contains('window.innerWidth'),
        isFalse,
        reason: '分页版单字符判据不得用 window 量纲',
      );
      expect(
        pagedIsBefore.contains(
            'return (vertical ? rect.bottom : rect.right) <= firstEdge;'),
        isTrue,
        reason: 'BUG-2492：竖排 rect.bottom<=firstEdge（=padding-top）/ '
            '横排 rect.right<=firstEdge（=padding-left）；连续版的 left>=clientWidth / '
            'bottom<=0 在分页几何下前页永远不满足 → 兜底恒 0',
      );
    });

    test('BUG-2492：getLastVisibleCharOffset(start) 先校验起点在本页，再走 isAtEnd 钳位', () {
      final String pagedGetLast = _functionSource(
        source,
        '  getLastVisibleCharOffset: function(startOffset) {',
        '\n  pageInfo: function() {',
      );
      final int check = pagedGetLast.indexOf('!this.charOffsetOnCurrentPage(startOffset)');
      final int atEnd = pagedGetLast.indexOf('if (this.isAtEnd()) return metrics.totalChars;');
      expect(check, isNonNegative,
          reason: '传入起点必须经 charOffsetOnCurrentPage 校验，不在本页返 -1（Dart 不 arrive）');
      expect(atEnd, isNonNegative);
      expect(check, lessThan(atEnd),
          reason: '校验必须先于 isAtEnd 短路：末页起点错时钳到 total 同样是整段幻象');
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

/// 用 **JS 词法**把注释掩成等长空白，保留可执行代码。负向断言只能针对真实代码——
/// 否则解释「为什么不用 window.innerWidth / 不裸 return -1」的注释会被误判违规。
///
/// 旧写法是「丢掉整行以 `//` 起的行」，三个方向都漏：`/* window.innerWidth */` 块注释
/// 一概放行、行尾注释（`return -1; // 旧写法`）留着当命中、切片长度还会变（下标不再能
/// 回原串）。这些 JS 里有正则字面量（`/\s+/` 之类），所以必须用 [maskJsComments] 而不是
/// Dart 版 [maskComments]——后者会把 `/^a\/\//` 里的 `//` 当行注释，从那里到行尾整段
/// 消失，负向断言当场变成永远绿。
String _stripJsLineComments(String slice) => maskJsComments(slice);
