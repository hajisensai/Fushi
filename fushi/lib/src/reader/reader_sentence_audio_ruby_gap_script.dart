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
  // BUG-3326：一句被 ruby / 书自带行内元素拆成多个 wrapper，每个 wrapper 都带圆角
  // （box-decoration-break: clone），同一行里相邻 wrapper 的接缝处两个圆角头对在一起，
  // 整句高亮在每个振假名前后被切出缺口。整条只该在「每一行的两端」是圆的：同一行里与
  // 相邻 wrapper 相接的一侧加 join class 改直角（radius 只是背景形状，不动排版）。
  // clone 下 radius 对一个元素的每一行片段一视同仁——跨行的 wrapper 若一端是接缝，它在
  // 折行处的那一端也会被一起改直角，所以先把这种 wrapper 恰好在折行处切开
  // （splitSentenceAudioJoinLines），切口两侧本来就不在同一行，排版不变。
  paintSentenceAudioRubyGaps: function() {
    this.eraseSentenceAudioRubyGaps();
    var wrappers = this.sentenceAudioGapWrappers || [];
    if (!wrappers.length) return;
    var vertical = getComputedStyle(wrappers[0]).writingMode.indexOf('vertical') === 0;
    this.splitSentenceAudioJoinLines(wrappers, vertical);
    var fills = [];
    var trims = new Map();
    var joined = [];
    for (var i = 1; i < wrappers.length; i++) {
      var prev = wrappers[i - 1];
      var next = wrappers[i];
      var pr = this.sentenceAudioLineRects(prev);
      var nr = this.sentenceAudioLineRects(next);
      if (!pr.length || !nr.length) continue;
      var a = pr[pr.length - 1];
      var b = nr[0];
      if (!this.sentenceAudioSameLine(a, b, vertical)) continue;
      var gap = vertical ? b.top - a.bottom : b.left - a.right;
      if (Math.abs(gap) > parseFloat(getComputedStyle(next).fontSize) * 3) continue;
      prev.classList.add('fushi-sentence-audio-join-end');
      next.classList.add('fushi-sentence-audio-join-start');
      joined.push(prev, next);
      // 反过来，长注音悬挂到邻字上时（Blink：ruby 基字盒按注音长度撑开、两侧压进邻字
      // 5px），ruby 内 wrapper 的背景盒与邻 wrapper 重叠，半透明底色叠出一条深色带。
      // 把 ruby 内那一侧重叠的长度从它的背景里扣掉（trim）：重叠区里是邻字，邻字自己的
      // 背景照常覆盖；只改背景的绘制范围，不动排版、不裁字形与补缝阴影。
      if (gap < -0.5) {
        var trimEl = this.rubyForNode(next) || !this.rubyForNode(prev) ? next : prev;
        var t = trims.get(trimEl) || { start: 0, end: 0 };
        if (trimEl === next) t.start = Math.max(t.start, -gap);
        else t.end = Math.max(t.end, -gap);
        trims.set(trimEl, t);
        continue;
      }
      if (!(gap > 0.5)) continue;
      if (this.rubyForNode(next)) fills.push({ el: next, dx: vertical ? 0 : -gap, dy: vertical ? -gap : 0 });
      else fills.push({ el: prev, dx: vertical ? 0 : gap, dy: vertical ? gap : 0 });
    }
    this.sentenceAudioGapJoined = joined;
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
    // 扣掉重叠：底色改由两端透明的渐变画（行内方向：竖排自上而下、横排自左而右）。
    // background-color 要压过 .fushi-sentence-audio-active 的 !important；查词优先
    // （BUG-125）与墨水屏的 !important 规则另把 background-image 置 none。
    var trimmed = [];
    trims.forEach(function(t, el) {
      var c = 'var(--fushi-sentence-audio-background-color)';
      var s = t.start.toFixed(2) + 'px';
      var e = 'calc(100% - ' + t.end.toFixed(2) + 'px)';
      el.style.setProperty('background-color', 'transparent', 'important');
      el.style.backgroundImage = 'linear-gradient(' + (vertical ? 'to bottom' : 'to right') + ', transparent ' + s +
          ', ' + c + ' ' + s + ', ' + c + ' ' + e + ', transparent ' + e + ')';
      trimmed.push(el);
    });
    this.sentenceAudioGapFilled = filled.concat(trimmed);
  },
  eraseSentenceAudioRubyGaps: function() {
    var filled = this.sentenceAudioGapFilled || [];
    filled.forEach(function(el) {
      el.style.boxShadow = '';
      el.style.backgroundImage = '';
      el.style.removeProperty('background-color');
    });
    this.sentenceAudioGapFilled = [];
    var joined = this.sentenceAudioGapJoined || [];
    joined.forEach(function(el) {
      el.classList.remove('fushi-sentence-audio-join-start', 'fushi-sentence-audio-join-end');
    });
    this.sentenceAudioGapJoined = [];
  },
  // 元素的逐行片段（去掉引擎在折行点给出的零面积空片段）。
  sentenceAudioLineRects: function(el) {
    return Array.prototype.filter.call(el.getClientRects(), function(r) {
      return r.width > 0.5 && r.height > 0.5;
    });
  },
  // 两个矩形是否在同一行：竖排看横向重叠，横排看纵向重叠。
  sentenceAudioSameLine: function(a, b, vertical) {
    return vertical ? (a.left < b.right && b.left < a.right) : (a.top < b.bottom && b.top < a.bottom);
  },
  // 跨行且一端与同一行的邻 wrapper 相接的 wrapper，在折行处切成两个：接缝一端的那一行
  // 单独成一个 wrapper（就地修改 wrappers 数组，它就是 cueWrappers 里存的那一份）。
  splitSentenceAudioJoinLines: function(wrappers, vertical) {
    var changed = false;
    for (var i = 0; i < wrappers.length; i++) {
      var w = wrappers[i];
      var rects = this.sentenceAudioLineRects(w);
      if (rects.length < 2) continue;
      var next = wrappers[i + 1];
      var nextRects = next ? this.sentenceAudioLineRects(next) : [];
      var lastLine = rects[rects.length - 1];
      if (nextRects.length && this.sentenceAudioSameLine(lastLine, nextRects[0], vertical)) {
        var self = this;
        var tail = this.splitSentenceAudioWrapper(w, function(r) {
          return self.sentenceAudioSameLine(r, lastLine, vertical);
        });
        if (tail) {
          wrappers.splice(i + 1, 0, tail);
          changed = true;
          rects = this.sentenceAudioLineRects(w);
        }
      }
      var prev = wrappers[i - 1];
      var prevRects = prev ? this.sentenceAudioLineRects(prev) : [];
      if (rects.length >= 2 && prevRects.length &&
          this.sentenceAudioSameLine(prevRects[prevRects.length - 1], rects[0], vertical)) {
        var firstLine = rects[0];
        var self2 = this;
        var rest = this.splitSentenceAudioWrapper(w, function(r) {
          return !self2.sentenceAudioSameLine(r, firstLine, vertical);
        });
        if (rest) {
          wrappers.splice(i + 1, 0, rest);
          changed = true;
        }
      }
    }
    if (changed && typeof this.buildNodeOffsets === 'function') this.buildNodeOffsets();
  },
  // 在 wrapper 里按文档序找第一个满足 startsHere(字矩形) 的字，从它起（含）后面的内容
  // 移进紧随其后的新 wrapper，返回新 wrapper；切点不在 wrapper 的直接子文本上（落在书的
  // 行内元素里）或无需切分时返回 null，保持原样。
  splitSentenceAudioWrapper: function(w, startsHere) {
    var walker = document.createTreeWalker(w, NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    var node;
    var hit = null;
    while (!hit && (node = walker.nextNode())) {
      if (node.parentElement && node.parentElement.closest('rt, rp')) continue;
      var data = node.data;
      for (var k = 0; k < data.length; k++) {
        var len = (data.charCodeAt(k) & 0xFC00) === 0xD800 && k + 1 < data.length ? 2 : 1;
        range.setStart(node, k);
        range.setEnd(node, k + len);
        var r = range.getBoundingClientRect();
        if (r.width > 0.5 && r.height > 0.5 && startsHere(r)) { hit = { node: node, offset: k }; break; }
        k += len - 1;
      }
    }
    if (!hit || hit.node.parentNode !== w) return null;
    if (hit.offset === 0 && !hit.node.previousSibling) return null;
    var moved = [];
    var first = hit.offset > 0 ? hit.node.splitText(hit.offset) : hit.node;
    for (var n = first; n; n = n.nextSibling) moved.push(n);
    var tail = w.cloneNode(false);
    tail.classList.remove('fushi-sentence-audio-join-start', 'fushi-sentence-audio-join-end');
    tail.style.boxShadow = '';
    var cut = Array.prototype.indexOf.call(w.childNodes, first);
    this.moveSentenceAudioNodesKeepingRanges(w, cut, moved, tail);
    return tail;
  },
  // 把 w 从第 cut 个子节点起的 moved 移进 tail，并把 tail 插到 w 后面。移除节点会把落在它里面的 live Range 边界
  // 塌到父节点上：查词选区、收藏 / 标注、搜索高亮都是存起来的 live Range（CSS.highlights），
  // 原生选区也是——先记下这些边界，移完按原节点 / 原偏移写回，指向 w 子节点序号的边界换算到
  // tail。插入 tail 本身对外层边界的影响由 DOM 规范自动调整。
  moveSentenceAudioNodesKeepingRanges: function(w, cut, moved, tail) {
    var ranges = [];
    try {
      if (typeof CSS !== 'undefined' && CSS.highlights) {
        CSS.highlights.forEach(function(hl) {
          hl.forEach(function(r) { if (r && typeof r.setStart === 'function') ranges.push(r); });
        });
      }
    } catch (e) {}
    var sel = window.getSelection ? window.getSelection() : null;
    if (sel && sel.rangeCount) ranges.push(sel.getRangeAt(0));
    var inMoved = function(c) {
      for (var m = 0; m < moved.length; m++) if (moved[m] === c || moved[m].contains(c)) return true;
      return false;
    };
    var remap = function(c, o) {
      if (inMoved(c)) return [c, o];
      if (c === w && o > cut) return [tail, o - cut];
      return null;
    };
    var fixes = [];
    ranges.forEach(function(r) {
      var s = remap(r.startContainer, r.startOffset);
      var e = remap(r.endContainer, r.endOffset);
      if (s || e) {
        fixes.push({ r: r, s: s || [r.startContainer, r.startOffset], e: e || [r.endContainer, r.endOffset] });
      }
    });
    moved.forEach(function(n) { tail.appendChild(n); });
    // 先把 tail 插回文档再写回边界：落在游离子树上的边界会被 setEnd 跨树塌缩。
    w.parentNode.insertBefore(tail, w.nextSibling);
    fixes.forEach(function(f) {
      try {
        f.r.setStart(f.s[0], f.s[1]);
        f.r.setEnd(f.e[0], f.e[1]);
      } catch (e) {}
    });
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
