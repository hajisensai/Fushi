/// BUG-2806 / BUG-2917：有声书句子高亮的「分组包裹 + ruby 缝补色」JS 片段。
///
/// 片段是 `window.fushiReader = { ... }` 对象字面量里的一串方法属性（每个以 `,`
/// 结尾），三个阅读器 shell（分页 / 连续 / 视觉小说）都原样插进自己的对象字面量。
/// 只有这一份实现：VN 曾经各段单独包裹、不补缝，竖排注音处整句高亮断开（BUG-2917）。
///
/// 宿主对象需要提供 `getComputedStyle` 可用的 DOM；`sentenceAudioGap*` 状态字段由
/// 这些方法自己按需创建。
const String kSentenceAudioRubyGapJs = r'''
  // BUG-2780 / BUG-2806：把一条 cue 的文本片段（文档序）折成「可整体包裹」的分组：相邻两项
  // 父节点相同就并进同一组，组内首尾之间的兄弟节点全部被完整包含（range 两端落在同一父节点
  // 的子节点上），extractContents 不会拆开书的元素。ruby 内的基字片段各自单独成组（wrapper
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
  // BUG-2806：ruby 留在原位后，注音比基字长、又不能悬挂到邻字上（邻字是汉字、注音超出
  // 悬挂上限）时，基字 wrapper 与相邻 wrapper 之间会露出 ruby 自己撑出的间距（iOS 模拟器：
  // 「大喝采」3.9px、6 假名注音单字 13.8px），整句高亮在那里断开（BUG-2780 的原始症状）。
  // 高亮时量出同一行相邻两个 wrapper 之间的缝，由 ruby 内那个 wrapper 用 box-shadow 伸过去
  // 补色：外阴影只画在元素边框盒外、不参与排版，量多少补多少，不会与邻 wrapper 叠色。
  // 只处理当前高亮句，取消高亮时 clearSentenceAudioRubyGaps 撤掉。
  fillSentenceAudioRubyGaps: function(wrappers) {
    this.clearSentenceAudioRubyGaps();
    this.sentenceAudioGapWrappers = wrappers;
    this.paintSentenceAudioRubyGaps();
    this.watchSentenceAudioRubyGapLayout();
  },
  // 缝的宽度随注音与字号变：暂停时切振假名模式、改字号 / 字体、字体晚到、改页面尺寸都不会
  // 有下一个 cue 来重量，按旧偏移画的阴影会伸到邻字上叠色或留缺口。在真正的重排信号上
  // 重量：正文样式表被换（两条换 CSS 路径都写 #fushi-reader-style）、字体加载完成，以及
  // 一切重锚序列的落定（_setReanchorPending，改页面尺寸 / chrome 边距 / 界面缩放走这条）。
  // 不用 ResizeObserver：wrapper 是 span、ruby 是 display: ruby，都是非替换行内元素，
  // 观察它们只在开始时回调一次，之后排版怎么变都不会再回调。
  // 只装一次；无当前句时 paint 只是空擦除。
  watchSentenceAudioRubyGapLayout: function() {
    if (this.sentenceAudioGapLayoutWatched) return;
    this.sentenceAudioGapLayoutWatched = true;
    var self = this;
    var repaint = function() { self.paintSentenceAudioRubyGaps(); };
    if (window.MutationObserver && document.head) {
      new MutationObserver(repaint).observe(document.head,
          { childList: true, characterData: true, subtree: true });
    }
    if (document.fonts && document.fonts.addEventListener) {
      document.fonts.addEventListener('loadingdone', repaint);
    }
  },
  paintSentenceAudioRubyGaps: function() {
    this.eraseSentenceAudioRubyGaps();
    var wrappers = this.sentenceAudioGapWrappers || [];
    var fills = [];
    for (var i = 1; i < wrappers.length; i++) {
      var prev = wrappers[i - 1];
      var next = wrappers[i];
      var prevInRuby = !!this.rubyForNode(prev);
      var nextInRuby = !!this.rubyForNode(next);
      if (!prevInRuby && !nextInRuby) continue;
      var pr = prev.getClientRects();
      var nr = next.getClientRects();
      if (!pr.length || !nr.length) continue;
      var a = pr[pr.length - 1];
      var b = nr[0];
      var vertical = getComputedStyle(next).writingMode.indexOf('vertical') === 0;
      var sameLine = vertical ? (a.left < b.right && b.left < a.right) : (a.top < b.bottom && b.top < a.bottom);
      if (!sameLine) continue;
      var gap = vertical ? b.top - a.bottom : b.left - a.right;
      if (!(gap > 0.5) || gap > parseFloat(getComputedStyle(next).fontSize) * 3) continue;
      if (nextInRuby) fills.push({ el: next, dx: vertical ? 0 : -gap, dy: vertical ? -gap : 0 });
      else fills.push({ el: prev, dx: vertical ? 0 : gap, dy: vertical ? gap : 0 });
    }
    var shadows = new Map();
    fills.forEach(function(f) {
      var list = shadows.get(f.el) || [];
      list.push(f.dx + 'px ' + f.dy + 'px 0 0 var(--fushi-sentence-audio-background-color)');
      shadows.set(f.el, list);
    });
    var filled = [];
    shadows.forEach(function(list, el) {
      el.style.boxShadow = list.join(', ');
      filled.push(el);
    });
    this.sentenceAudioGapFilled = filled;
  },
  eraseSentenceAudioRubyGaps: function() {
    var filled = this.sentenceAudioGapFilled || [];
    filled.forEach(function(el) { el.style.boxShadow = ''; });
    this.sentenceAudioGapFilled = [];
  },
  clearSentenceAudioRubyGaps: function() {
    this.sentenceAudioGapWrappers = [];
    this.eraseSentenceAudioRubyGaps();
  },
  rubyForNode: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return el && el.closest ? el.closest('ruby') : null;
  },
''';
