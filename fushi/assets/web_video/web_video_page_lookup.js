// 网页档（原生播放器页里的站点页面）按住查词键（默认 Shift，设置「悬停查词按键」可改，
// Dart 每次页面加载下发 window.__fushiHoverKey / __fushiHoverKeyName）悬停查词：取光标下文字所在的那一句 + 字形
// 下标，投给 Dart `{type:'pageLookup', sentence, index, rect}`（与 DOM 字幕层的 lookup 载荷
// 同形，[parseWebVideoLookupPayload] 解析），由顶层查词窗口弹出。不按 Shift 时页面照常点击。
// 与阅读器 / 歌词页 / 浏览器扩展同一约定（Shift + 移动）。纯逻辑挂在
// __fushiPageLookup._pure 供 node 测试。
(function () {
  'use strict';
  if (window.__fushiPageLookup) return;
  var HANDLER = 'fushiWebVideo';

  function graphemes(text) {
    try {
      if (typeof Intl !== 'undefined' && Intl.Segmenter) {
        var seg = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
        var out = [];
        var it = seg.segment(text)[Symbol.iterator]();
        for (var r = it.next(); !r.done; r = it.next()) out.push(r.value.segment);
        return out;
      }
    } catch (_) {}
    return Array.from(text);
  }

  // 文本节点内容里 [offset] 所在的那一句（句末标点 / 换行为界，最长 200 字），以及
  // offset 在句内的字形下标。offset 落在空白上返回 null。
  // text[i] 是不是句末：中日文句末标点 / 换行，或后面跟着空白的英文句号。
  function isBoundary(text, i) {
    var ch = text.charAt(i);
    if (/[。！？!?\n\r]/.test(ch)) return true;
    return ch === '.' && /\s/.test(text.charAt(i + 1));
  }
  function sentenceAt(text, offset) {
    if (!text || offset < 0 || offset >= text.length) return null;
    if (/\s/.test(text.charAt(offset))) return null;
    var start = offset;
    while (start > 0 && offset - start < 200 && !isBoundary(text, start - 1)) start--;
    var end = offset;
    while (end < text.length && end - offset < 200 && !isBoundary(text, end)) end++;
    if (end < text.length) end++; // 句末标点归本句
    var raw = text.slice(start, end);
    var lead = raw.length - raw.replace(/^\s+/, '').length;
    var sentence = raw.trim();
    if (!sentence) return null;
    var index = graphemes(raw.slice(lead, offset - start)).length;
    return { sentence: sentence, index: index };
  }

  function caretAt(x, y) {
    if (document.caretPositionFromPoint) {
      var p = document.caretPositionFromPoint(x, y);
      if (p && p.offsetNode) return { node: p.offsetNode, offset: p.offset };
    }
    if (document.caretRangeFromPoint) {
      var r = document.caretRangeFromPoint(x, y);
      if (r) return { node: r.startContainer, offset: r.startOffset };
    }
    return null;
  }

  function editable(el) {
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      var tag = n.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || n.isContentEditable) return true;
    }
    return false;
  }

  // caret API 给的是「两字之间」的插入点：命中字形取插入点后面那个字，但光标确实落在
  // 前一个字上时（行尾 / 字右半边）取前一个。
  function hitChar(node, offset, x, y) {
    var text = node.data;
    var candidates = [offset, offset - 1];
    for (var i = 0; i < candidates.length; i++) {
      var o = candidates[i];
      if (o < 0 || o >= text.length) continue;
      var range = document.createRange();
      range.setStart(node, o);
      range.setEnd(node, o + 1);
      var rects = range.getClientRects();
      for (var j = 0; j < rects.length; j++) {
        var b = rects[j];
        if (x >= b.left && x <= b.right && y >= b.top && y <= b.bottom) {
          return { offset: o, rect: b };
        }
      }
    }
    return null;
  }

  var lastKey = '';
  var lastAt = 0;
  var mouse = null;
  function scan(x, y) {
    var c = caretAt(x, y);
    if (!c || !c.node || c.node.nodeType !== 3) return;
    var parent = c.node.parentElement;
    if (!parent || editable(parent)) return;
    var hit = hitChar(c.node, c.offset, x, y);
    if (!hit) return;
    var s = sentenceAt(c.node.data, hit.offset);
    if (!s) return;
    var key = s.sentence + '\u0000' + s.index;
    var now = Date.now();
    if (key === lastKey && now - lastAt < 1500) return;
    lastKey = key;
    lastAt = now;
    try {
      window.flutter_inappwebview.callHandler(HANDLER, {
        type: 'pageLookup', kind: 'hover', sentence: s.sentence, index: s.index,
        rect: { x: hit.rect.left, y: hit.rect.top, w: hit.rect.width, h: hit.rect.height },
      });
    } catch (_) {}
  }

  var pending = false;
  document.addEventListener('mousemove', function (e) {
    mouse = { x: e.clientX, y: e.clientY };
    if (!e[window.__fushiHoverKey || 'shiftKey'] || pending) return;
    pending = true;
    setTimeout(function () {
      pending = false;
      if (mouse) scan(mouse.x, mouse.y);
    }, 60);
  }, true);
  // 光标不动、按下查词键的那一刻也查。
  document.addEventListener('keydown', function (e) {
    var key = window.__fushiHoverKeyName || 'Shift';
    if (e.key === key && !e.repeat && mouse) scan(mouse.x, mouse.y);
  }, true);

  window.__fushiPageLookup = { _pure: { sentenceAt: sentenceAt, graphemes: graphemes } };
})();
