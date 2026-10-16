/// BUG-2806 / BUG-2917：有声书句子高亮的「分组包裹」JS 片段。
///
/// 片段是 `window.fushiReader = { ... }` 对象字面量里的一串方法属性（每个以 `,`
/// 结尾），三个阅读器 shell（分页 / 连续 / 视觉小说）都原样插进自己的对象字面量。
/// 只有这一份实现：VN 曾经各段单独包裹，竖排注音处整句高亮断开（BUG-2917）。
///
/// 注音撑出的缝（ruby 留在原位、长注音不能悬挂时基字 wrapper 与邻 wrapper 之间的间距）
/// 原先由这里逐缝量出、用 box-shadow 补色，接缝改直角（BUG-2806 / 3326）。2026-10-15
/// 起所有高亮的底色都由窄条层 `__fushiLanes`（reader_selection_scripts.dart）画：同一行
/// 里同一句的片段并成一条 1em 窄条，缝、叠色、接头一并消失，补缝代码已删除。
const String kSentenceAudioRubyGapJs = r'''
  // BUG-2780 / BUG-2806：把一条 cue 的文本片段（文档序）折成「可整体包裹」的分组：相邻两项
  // 父节点相同就并进同一组，组内首尾之间的兄弟节点全部被完整包含（两端落在同一父节点
  // 的子节点上），包裹不会拆开书的元素。ruby 内的基字片段各自单独成组（wrapper
  // 落在 ruby / rb 里、不跨 rt），ruby 本身永远不被移动（见 applySentenceAudioCues）。
  sentenceAudioWrapItems: function(segments) {
    var groups = [];
    var current = null;
    for (var j = 0; j < segments.length; j++) {
      var node = segments[j].node;
      var item = { node: node, start: segments[j].start, end: segments[j].end, parent: node.parentNode };
      if (!item.parent) continue;
      if (this.rubyForNode(node)) {
        groups.push([item]);
        current = null;
        continue;
      }
      if (current && current[0].parent === item.parent &&
          this.sentenceAudioInlineGap(current[current.length - 1], item)) {
        current.push(item);
      } else {
        current = [item];
        groups.push(current);
      }
    }
    return groups;
  },
  // 把 sentenceAudioWrapItems 的一组（首尾同一父节点、文档序）原地包进 wrapper。不用
  // Range.extractContents：它把切点两侧的文字复制成新文本节点、原节点就地截短——VN 在播放中
  // 按句懒包裹，此时的查词选区（「文本节点 + 偏移」）偏移越界，落在这段文字里的收藏 / 搜索高亮与
  // 原生选区塌缩。改为先在首尾切点切开文本节点，再把首尾之间的兄弟节点原样搬进 wrapper，两步都经
  // 阅读器共享的 __fushiLiveRanges（选区换算 + live Range 保护），节点身份不变。
  // 调用方倒序处理各组：切开只改切点之后的节点，前面各组记下的「节点 + 偏移」仍然有效。
  wrapSentenceAudioGroup: function(group, wrapper) {
    var guard = window.__fushiLiveRanges;
    var first = group[0];
    var last = group[group.length - 1];
    var endNode = last.node;
    if (last.end < endNode.data.length) guard.splitText(endNode, last.end);
    var startNode = first.start > 0 ? guard.splitText(first.node, first.start) : first.node;
    if (first.node === last.node) endNode = startNode;
    var parent = startNode.parentNode;
    var moved = [];
    for (var n = startNode; n; n = n.nextSibling) {
      moved.push(n);
      if (n === endNode) break;
    }
    if (moved[moved.length - 1] !== endNode) throw new Error('sentence audio group is not one sibling run');
    guard.moveNodes(moved, function() {
      parent.insertBefore(wrapper, startNode);
      moved.forEach(function(m) { wrapper.appendChild(m); });
    });
    return wrapper;
  },
  // 两项之间的兄弟节点都是行内内容才并组（夹着块级元素就断开，不把块包进 span）；
  // 夹着 <ruby>（或含 ruby 的行内元素）也断开——ruby 一进 wrapper，WebKit 就取消注音悬挂、
  // 改排版（BUG-2806）。
  sentenceAudioInlineGap: function(prev, next) {
    var a = prev.node;
    var b = next.node;
    if (a === b) return true;
    for (var n = a.nextSibling; n; n = n.nextSibling) {
      if (n === b) return true;
      if (n.nodeType !== 1) continue;
      if (n.tagName === 'RUBY' || (n.querySelector && n.querySelector('ruby'))) return false;
      var display = getComputedStyle(n).display;
      if (display.indexOf('inline') !== 0 && display !== 'contents' && display !== 'none') return false;
    }
    return false;
  },
  // BUG-3432：一整批逐句包裹 / 拆包裹只读一次原生选区（见 __fushiLiveRanges.batch）。选区脚本
  // 还没注入时直接执行——那时 wrapSentenceAudioGroup 本来就走不通、按组回退。
  withLiveRangeBatch: function(fn) {
    var guard = window.__fushiLiveRanges;
    return guard && typeof guard.batch === 'function' ? guard.batch(fn) : fn();
  },
  rubyForNode: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return el && el.closest ? el.closest('ruby') : null;
  },
''';
