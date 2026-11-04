/// 阅读器「跳转落点」标记的唯一 JS 源（BUG-4102）。
///
/// 带句子区间的跳转（卡片来源回跳 `fushi://source`、收藏页 / 制卡历史的句子跳转）
/// 把 [start, end)（章内**学习单位**偏移，`getNormalizedOffset` /
/// `nativeSelectionSentenceRange().normalizedOffset` 口径，与 `restoreToCharOffset`
/// 同计量）画成一条 `fushi-search` CSS Custom Highlight——与书内搜索命中、按文本回退
/// 定位的收藏跳转同一种「你跳到了这里」标记（同一份 `::highlight(fushi-search)` 样式、
/// 同一层窄条，`clearSearchHighlight` 同样清掉它）。
///
/// 旧实现只把视口滚到句首，目标句本身没有任何视觉标记：回看卡片来源时用户得在满屏
/// 文字里自己找那一句（feedback i9n2zSMKgT「跳转回去没高亮」）。
///
/// 三种 shell 共用这一份：
/// - 分页 / 连续：`fushiReader.createWalker()` 走整章正文，节点的章内起点 = 走查累加的
///   `countChars`（与 `charOffsetInRange` / `scrollToCharOffset` 同一走查）。
/// - VN：正文在游离的 sourceRoot 里，屏上是克隆片段；`createWalker()` 只走当前屏，
///   节点的章内起点只能查 `renderScreen → buildNodeOffsets` 按 rangeMap 建好的
///   `nodeStartOffsets`（屏首不是章首，从 0 累加会整体错位）。句子跨屏时只标本屏那段。
///
/// 不支持 CSS Custom Highlight 的内核（旧 Blink 竖排、iOS 17.2 前）返回 false、不画——
/// 与搜索命中标记同一取舍（跳转照常）。
library;

/// 定义 `window.__fushiMarkLocatedRange(start, end)`（幂等）；成功画出返回 true。
const String kReaderLocatedRangeJs = r'''
if (typeof window.__fushiMarkLocatedRange !== 'function') {
  window.__fushiMarkLocatedRange = (function() {
    var NAME = 'fushi-search';
    // text 里第 units 个学习单位结束之后的码元下标（isUnitEnd 前缀计数的逆，句尾开区间）。
    function offsetAfterUnits(text, units) {
      if (units <= 0) return 0;
      var seen = 0;
      for (var i = 0; i < text.length;) {
        var cp = text.codePointAt(i);
        var width = cp > 0xFFFF ? 2 : 1;
        if (window.fushiStudyUnits.isUnitEnd(text, i)) {
          seen++;
          if (seen >= units) return i + width;
        }
        i += width;
      }
      return text.length;
    }
    return function(start, end) {
      var reader = window.fushiReader;
      if (!window.__fushiCssHighlightsSupported || !reader ||
          typeof reader.createWalker !== 'function' ||
          typeof reader.countChars !== 'function' || !window.fushiStudyUnits) {
        return false;
      }
      var from = Number(start);
      var to = Number(end);
      if (!isFinite(from) || !isFinite(to) || from < 0 || to <= from) return false;
      // VN 屏是克隆片段：章内起点只认 buildNodeOffsets 建的表。
      var screenMapped = !!reader.rangeMap && !!reader.nodeStartOffsets &&
        typeof reader.nodeStartOffsets.get === 'function';
      var walker = reader.createWalker();
      var running = 0;
      var node;
      var covered = [];
      var startNode = null, startOffset = 0, endNode = null, endOffset = 0;
      var lastNode = null;
      while ((node = walker.nextNode())) {
        var text = node.textContent || '';
        var base = running;
        if (screenMapped) {
          var mapped = reader.nodeStartOffsets.get(node);
          if (typeof mapped !== 'number') continue;
          base = mapped;
        }
        var units = reader.countChars(text);
        running = base + units;
        if (startNode && base >= to) {
          // 句尾恰在上一个节点末尾（本节点从句尾之后开始）。
          endNode = lastNode;
          endOffset = (lastNode.textContent || '').length;
          break;
        }
        if (!startNode) {
          if (base + units <= from) { lastNode = node; continue; }
          startNode = node;
          startOffset = window.fushiStudyUnits.unitStartOffset(text, Math.max(0, from - base));
        }
        covered.push(node);
        lastNode = node;
        if (base + units >= to) {
          endNode = node;
          endOffset = offsetAfterUnits(text, to - base);
          break;
        }
      }
      if (!startNode) return false;
      if (!endNode) {
        // 句子越过本屏（VN）/ 章末：标到最后一个可见文本节点末尾。
        endNode = lastNode;
        endOffset = (lastNode.textContent || '').length;
      }
      // BUG-3323：Range 建立之前先让覆盖到的每个文本节点可绘制（见选区脚本）。
      if (typeof window.__fushiEnsureHighlightPaintable === 'function') {
        for (var i = 0; i < covered.length; i++) {
          window.__fushiEnsureHighlightPaintable(covered[i]);
        }
      }
      var range = document.createRange();
      range.setStart(startNode, Math.min(startOffset, (startNode.textContent || '').length));
      range.setEnd(endNode, Math.min(endOffset, (endNode.textContent || '').length));
      if (range.collapsed) return false;
      CSS.highlights.set(NAME, new Highlight(range));
      return true;
    };
  })();
}
''';

/// 画跳转落点标记的 evaluateJavascript 源：先（幂等）定义，再调用。
///
/// [start] / [end]：章内学习单位偏移，[end] 为开区间终点（句首 + 句长）。
String readerMarkLocatedRangeInvocation(int start, int end) =>
    '$kReaderLocatedRangeJs\n'
    'window.__fushiMarkLocatedRange($start, $end);';
