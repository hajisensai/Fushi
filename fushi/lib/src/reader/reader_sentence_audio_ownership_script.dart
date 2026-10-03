/// 有声书当前句高亮的「标点归属」——**唯一** JS 源（BUG-2907）。
///
/// cue 的 `{start, length}` 按可匹配字（假名 / 汉字 / 字母数字）计数，两条高亮路径
/// （翻页 / 滚动的 `collectSentenceAudioCueRanges`、VN 的 `collectMatchableSegments`）
/// 都只把**首个到末个可匹配字**映射回 DOM，于是「…声援が飛ぶ。」的「。」、
/// 「「さいちゃーん」」两头的括号永远落在高亮框外。
///
/// 做法对齐 Hoshi Reader Android（`reader-text-semantics.js` 的
/// `createSasayakiTextIndex`）：标点按方向并进相邻的字——
/// - 收尾类（`」』）。、！？…` 等）并进**前一个**字：cue 末端往后延；
/// - 开头类（`「『（` 等）并进**后一个**字：cue 起点往前移；
/// - 中性类（`…‥—〜`）跟随前文；前文是开头类、空白或段首时跟随后文；
/// - 空白等其它字符打断归属；块级元素、`<br>`、图片等屏障两侧互不归属
///   （下一段开头的「「」不会被并进上一句），注音 `<rt>/<rp>` 不在正文流里。
///
/// 每个标点只会归属一侧，相邻两句的高亮不会重叠。cue 坐标、匹配器、学习字数
/// 一律不动——这里只放宽「cue 区间 → DOM 片段」映射出来的首尾两端。
library;

/// 定义 `window.fushiSentenceAudioOwnership`（幂等），由 `engineShell` 在任何
/// shell 安装之前注入，翻页 / 滚动 / VN 三个 shell 共用。
const String kSentenceAudioOwnershipJs = r"""
if (!window.fushiSentenceAudioOwnership) {
  window.fushiSentenceAudioOwnership = (function() {
    var OPENING = '「『（〔［｛〈《【〖〘〚“‘｢([{';
    var TRAILING = '」』）〕］｝〉》】〗〙〛”’｣)]}。、，．！？!?‼⁇⁈⁉､｡・･：；:;';
    var NEUTRAL = '…‥—―–─〜～';
    var BLOCK = /^(address|article|aside|blockquote|body|dd|div|dl|dt|fieldset|figcaption|footer|form|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|ul|table|thead|tbody|tfoot|tr|td|th|caption)$/;
    var BARRIER = /^(br|img|svg|image|video|audio|canvas|picture|figure|iframe|object|embed|script|style)$/;
    var ANNOTATION = /^(rt|rp)$/;

    function tagOf(node) {
      return String(node && node.tagName || '').toLowerCase();
    }

    // 文档序的下一个 / 上一个正文文本节点；中间隔着块边界或屏障就返回 null。
    function step(node, forward) {
      var cur = node;
      while (cur) {
        var sib = forward ? cur.nextSibling : cur.previousSibling;
        while (!sib) {
          cur = cur.parentNode;
          if (!cur || cur.nodeType !== 1 || BLOCK.test(tagOf(cur))) return null;
          sib = forward ? cur.nextSibling : cur.previousSibling;
        }
        cur = sib;
        while (true) {
          if (cur.nodeType === 3) return cur;
          if (cur.nodeType !== 1) break;
          var tag = tagOf(cur);
          if (BLOCK.test(tag) || BARRIER.test(tag)) return null;
          if (ANNOTATION.test(tag)) break;
          var child = forward ? cur.firstChild : cur.lastChild;
          if (!child) break;
          cur = child;
        }
      }
      return null;
    }

    function charAt(text, i) {
      return String.fromCodePoint(text.codePointAt(i));
    }

    function charBefore(text, i) {
      var low = text.charCodeAt(i - 1);
      if (i >= 2 && low >= 0xDC00 && low <= 0xDFFF) {
        var high = text.charCodeAt(i - 2);
        if (high >= 0xD800 && high <= 0xDBFF) return text.slice(i - 2, i);
      }
      return text.charAt(i - 1);
    }

    // 末端：可匹配字之后连续的收尾类 / 中性类都归前一个字。
    function extendEnd(node, offset, isMatchable) {
      var end = { node: node, offset: offset };
      var n = node;
      var i = offset;
      while (n) {
        var text = n.nodeValue || '';
        while (i < text.length) {
          var ch = charAt(text, i);
          if (isMatchable(ch)) return end;
          if (TRAILING.indexOf(ch) < 0 && NEUTRAL.indexOf(ch) < 0) return end;
          i += ch.length;
          end = { node: n, offset: i };
        }
        n = step(n, true);
        i = 0;
      }
      return end;
    }

    // 起点：可匹配字之前紧挨着的开头类 / 中性类串。中性字跟谁由它前面最近的非中性
    // 字决定（开头类、空白、段首 → 跟后文），与 Hoshi 的 pendingRight 同语义。
    function extendStart(node, offset, isMatchable) {
      var run = [];
      var stopChar = null;
      var n = node;
      var i = offset;
      outer: while (n) {
        var text = n.nodeValue || '';
        while (i > 0) {
          var ch = charBefore(text, i);
          if (OPENING.indexOf(ch) < 0 && NEUTRAL.indexOf(ch) < 0) {
            stopChar = ch;
            break outer;
          }
          i -= ch.length;
          run.push({ node: n, offset: i, ch: ch });
        }
        n = step(n, false);
        i = n ? (n.nodeValue || '').length : 0;
      }
      var owner = stopChar === null || /\s/u.test(stopChar) ? 'right' : 'left';
      var pending = null;
      for (var k = run.length - 1; k >= 0; k--) {
        var item = run[k];
        if (OPENING.indexOf(item.ch) >= 0) {
          if (!pending) pending = item;
          owner = 'right';
        } else if (owner === 'right') {
          if (!pending) pending = item;
        } else {
          pending = null;
        }
      }
      return pending ? { node: pending.node, offset: pending.offset } : { node: node, offset: offset };
    }

    // 从 from 走到 to（含两端节点）的文本节点序列；走不到返回 null（不改片段）。
    function nodesBetween(from, to) {
      var nodes = [from];
      var cur = from;
      var guard = 0;
      while (cur !== to) {
        cur = step(cur, true);
        if (!cur || ++guard > 10000) return null;
        nodes.push(cur);
      }
      return nodes;
    }

    // seg 之后归它的标点：同节点直接延长 seg.end，跨节点的返回追加片段。
    function grownAfter(seg, isMatchable) {
      var extra = [];
      var end = extendEnd(seg.node, seg.end, isMatchable);
      if (end.node === seg.node) {
        seg.end = Math.max(seg.end, end.offset);
        return extra;
      }
      var after = nodesBetween(seg.node, end.node);
      if (!after) return extra;
      seg.end = (seg.node.nodeValue || '').length;
      for (var a = 1; a < after.length; a++) {
        var an = after[a];
        var ae = an === end.node ? end.offset : (an.nodeValue || '').length;
        if (ae > 0) extra.push({ node: an, start: 0, end: ae });
      }
      return extra;
    }

    // seg 之前归它的标点：同节点直接前移 seg.start，跨节点的返回前置片段。
    function grownBefore(seg, isMatchable) {
      var extra = [];
      var start = extendStart(seg.node, seg.start, isMatchable);
      if (start.node === seg.node) {
        seg.start = Math.min(seg.start, start.offset);
        return extra;
      }
      var before = nodesBetween(start.node, seg.node);
      if (!before) return extra;
      for (var b = 0; b < before.length - 1; b++) {
        var bn = before[b];
        var bs = bn === start.node ? start.offset : 0;
        var be = (bn.nodeValue || '').length;
        if (bs < be) extra.push({ node: bn, start: bs, end: be });
      }
      seg.start = 0;
      return extra;
    }

    // segments：文档序的 [{node, start, end}]（UTF-16 偏移），返回放宽后的新数组。
    // 一句是一段连续原文（与 Hoshi 的原文区间同义）：同一块内两段之间的缝（注音两侧
    // 的「」、行内元素边上的标点）整段补上；隔着块边界 / 屏障的两段不补缝，各自按
    // 标点归属放宽——上一段段末的「。」仍归这一句，下一段段首的「「」也归这一句。
    function extendSegments(segments, isMatchable) {
      if (!segments || !segments.length) return segments || [];
      var out = segments.map(function(s) {
        return { node: s.node, start: s.start, end: s.end };
      });
      var result = [];
      var growStart = true;
      for (var i = 0; i < out.length; i++) {
        var cur = out[i];
        if (growStart) Array.prototype.push.apply(result, grownBefore(cur, isMatchable));
        growStart = false;
        result.push(cur);
        var next = out[i + 1];
        if (!next) {
          Array.prototype.push.apply(result, grownAfter(cur, isMatchable));
          continue;
        }
        if (cur.node === next.node) continue;
        var path = nodesBetween(cur.node, next.node);
        if (!path) {
          Array.prototype.push.apply(result, grownAfter(cur, isMatchable));
          growStart = true;
          continue;
        }
        cur.end = (cur.node.nodeValue || '').length;
        for (var p = 1; p < path.length - 1; p++) {
          var len = (path[p].nodeValue || '').length;
          if (len > 0) result.push({ node: path[p], start: 0, end: len });
        }
        next.start = 0;
      }
      return result;
    }

    return { extendSegments: extendSegments };
  })();
}
""";
