import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';

/// WebView ↔ Flutter 双向通道，用于有声书句子高亮和点击跳转。
///
/// 使用方式：
/// 1. 章节加载完成后调用 [inject]，注入 CSS + JS。
/// 2. 若 XHTML 没有句子级 span，调用 [annotate] 自动分割并打标。
/// 3. 播放器 currentCue 变化时调用 [highlight]。
/// 4. WebView onConsoleMessage 中调用 [parseMessage] 解析点击事件。
class AudiobookBridge {
  AudiobookBridge._();

  // ── JS / CSS 常量 ──────────────────────────────────────────────────────────

  /// 注入到 WebView 的 CSS（高亮当前句、打标句子 hover 效果）。
  /// 同时覆盖 [data-hoshi-sid]（annotate 路径）和 [data-cue-id]（字幕 EPUB 路径）。
  static const String _css = '''
.hoshi-active {
  background: rgba(255, 220, 0, 0.42);
  border-radius: 2px;
  transition: background 0.15s ease;
}
::highlight(hoshi-active) {
  background-color: rgba(255, 220, 0, 0.42);
}
.__hoshi-overlay-rect {
  position: fixed;
  background: rgba(255, 220, 0, 0.42);
  border-radius: 2px;
  pointer-events: none;
  z-index: 2147483646;
}
[data-hoshi-sid], [data-cue-id] {
  cursor: pointer;
}
[data-hoshi-sid]:hover, [data-cue-id]:hover {
  background: rgba(100, 180, 255, 0.18);
  border-radius: 2px;
}
''';

  /// 高亮函数：清掉旧高亮并把目标元素滚动到视口内，同时对齐到整页。
  ///
  /// ttu 在 IDB 字幕 EPUB 路径下：真正的滚动容器是 `.book-content`
  /// （scrollHeight 远大于 clientHeight），body 自身 `overflow: hidden`。
  /// 既不能通过 window.scroll 也不能通过向 body 派发 wheel 事件来翻页 ——
  /// 必须直接赋值 `.book-content.scrollTop`。
  ///
  /// ## 翻页算法（对齐上游 Sasayaki reader.js `alignToPage`）
  ///
  /// `anchor = (rect.top + rect.bottom) / 2 + scrollTop`（content 滚动坐标），
  /// `pageIndex = Math.floor(anchor / stride)`，`scrollTop = pageIndex * stride`。
  /// stride 是 `clientHeight + column-gap`（CSS columns 分栏的实际页步长）。
  /// 选页按 **rect 中心**落在哪一页定 —— 上游就是这个语义，跨页 cue 选择
  /// 和上游一致。（旧的 "max-intersection tiebreak" 对长 cue 容易选到"只覆盖
  /// 上半"的那一页，高亮靠边不稳。）
  ///
  /// ## 收敛策略：一次写 + 双 RAF 再写
  ///
  /// 上游 Sasayaki 是 `scrollTop = target` + 双 RAF 固化，没有常驻 ticker。
  /// 旧实现用 280ms setInterval 轮询 30 次（≈9s）"追 scrollTop 到目标"，
  /// 本意是抗 Svelte 可能的 yank，实测 Svelte store 只监听页索引不监听
  /// scrollTop，yank 从未发生——反而用户手翻页时 ticker 还没收敛，会立刻
  /// 把用户拽回音频页（体感"翻页时机不对"）。改为一次写 + 双 RAF 再写，
  /// 失败就吞，让下一条 cue 自己重新尝试。
  static const String _highlightFn = '''
// 旧 ticker 的 __hoshiTarget / __hoshiTickerId / __hoshiStopTicker / __hoshiTick
// 仍有若干外部调用点（sasayaki fallback 里的"清 pending 目标"），保留名字
// 但内部是空操作。一次写 + 双 RAF 再写一次固化就够了。
window.__hoshiTarget = null;
window.__hoshiTickerId = null;
window.__hoshiTickIntervalMs = 0;
window.__hoshiStopTicker = function() { /* no-op */ };
window.__hoshiTick = function() { /* no-op */ };

// 对齐上游 Sasayaki reader.js alignToPage：
// anchor = (rect.top + rect.bottom) / 2 + scrollTop（content 滚动坐标）
// pageIndex = Math.floor(anchor / stride); scrollTop = pageIndex * stride
// stride = clientHeight + column-gap（ttu CSS columns 的实际页步长）。
window.__hoshiAlignToRect = function(rect) {
  if (!rect) return;
  var isDegenerate = rect.width === 0 && rect.height === 0 &&
                     rect.left === 0 && rect.top === 0;
  if (isDegenerate) return;
  var content = document.querySelector('.book-content') ||
                document.querySelector('[class*="book-content"]') ||
                document.scrollingElement || document.documentElement;
  var pageH = content.clientHeight;
  if (!pageH || pageH < 10) return;
  var container = content.querySelector('.book-content-container');
  var gap = 40;
  if (container) {
    var gapNum = parseFloat(getComputedStyle(container).columnGap);
    if (!isNaN(gapNum) && gapNum > 0) gap = gapNum;
  }
  var stride = pageH + gap;
  var cRect = content.getBoundingClientRect();
  var elTop = rect.top - cRect.top + content.scrollTop;
  var elBot = rect.bottom - cRect.top + content.scrollTop;
  var anchor = (elTop + elBot) / 2;
  var pageIndex = Math.floor(anchor / stride);
  var maxScroll = Math.max(0, content.scrollHeight - pageH);
  var targetScrollTop = Math.max(0, Math.min(pageIndex * stride, maxScroll));
  if (Math.abs(content.scrollTop - targetScrollTop) < 1) return;
  content.scrollTop = targetScrollTop;
};

window.__hoshiAlignToRange = function(range) {
  if (!range) return;
  function doAlign() {
    var rect;
    try { rect = range.getBoundingClientRect(); } catch (e) { return; }
    window.__hoshiAlignToRect(rect);
  }
  doAlign();
  requestAnimationFrame(function() {
    requestAnimationFrame(doAlign);
  });
};

window.__hoshiAlignToElement = function(el) {
  if (!el) return;
  function doAlign() {
    var rect;
    try { rect = el.getBoundingClientRect(); } catch (e) { return; }
    window.__hoshiAlignToRect(rect);
  }
  doAlign();
  requestAnimationFrame(function() {
    requestAnimationFrame(doAlign);
  });
};

window.__hoshiHighlight = function(selector, reveal) {
  if (reveal === undefined) reveal = true;
  console.log(JSON.stringify({
    'hibiki-message-type': 'diagHighlightEntry',
    'selector': selector || '',
    'reveal': reveal,
    'hasBookContent': !!document.querySelector('.book-content')
  }));
  // 无论 selector 是否非空，先清一轮旧 class。
  document.querySelectorAll('.hoshi-active').forEach(function(e) {
    e.classList.remove('hoshi-active');
  });
  if (!selector) return;
  var el = document.querySelector(selector);
  if (el) {
    el.classList.add('hoshi-active');
    if (reveal) window.__hoshiAlignToElement(el);
  }
};

// Sasayaki 路径：cueMap miss 时 walker fallback 会传进一个 Range。reveal=true
// 才翻页，reveal=false 只是静默（高亮自身由 __hoshiSetActiveRanges 或
// span toggle 另行负责）。
window.__hoshiHighlightRange = function(range, reveal) {
  if (reveal === undefined) reveal = true;
  if (!range || !reveal) return;
  window.__hoshiAlignToRange(range);
};
''';

  /// 高亮绘制抽象层：
  ///
  /// - `__hoshiPaintApiOk`：feature detect CSS Custom Highlight API（Chromium
  ///   105+）。现代 WebView 上 true，走 `CSS.highlights.set('hoshi-active', ...)`，
  ///   零 DOM 改动。
  /// - `__hoshiSetActiveRanges(ranges)` / `__hoshiClearActiveRanges()`：
  ///   Sasayaki 路径的统一入口。所有定位逻辑（TreeWalker / indexOf fallback /
  ///   cueMap 查表）产出 Range 后都交给它；内部按 feature detect 走 Highlight
  ///   API 或 overlay fallback。
  /// - 旧设备 overlay fallback：按 `range.getClientRects()` 在 `document.body`
  ///   上 `position: fixed` 画多个黄色矩形，跟随视口。`.book-content` 滚动时
  ///   通过 `__hoshiInstallOverlayScrollSync` 自动重画一次。
  ///
  /// 为什么不继续用 wrap span：`range.extractContents() + insertNode(span)`
  /// 会把 text node 拆成 "前半段 + <span>中段</span> + 后半段"。ttu 正文走
  /// CSS columns 分栏，inline DOM 一变，浏览器重跑 inline layout，文字会在
  /// 列边界漂移——用户看到的就是"每句高亮都让正文跳一下"。
  static const String _paintFn = '''
window.__hoshiActiveRanges = window.__hoshiActiveRanges || [];
window.__hoshiOverlayEls = window.__hoshiOverlayEls || [];
window.__hoshiOverlayScrollHandler = window.__hoshiOverlayScrollHandler || null;

window.__hoshiPaintApiOk = (function() {
  try {
    if (typeof CSS === 'undefined') return false;
    if (!CSS.highlights || typeof CSS.highlights.set !== 'function') return false;
    if (typeof Highlight !== 'function') return false;
    var probe = new Highlight();
    CSS.highlights.set('__hoshi_probe', probe);
    CSS.highlights.delete('__hoshi_probe');
    return true;
  } catch (e) {
    return false;
  }
})();

window.__hoshiEnsureHighlightRegistry = function() {
  if (!window.__hoshiPaintApiOk) return null;
  var h = CSS.highlights.get('hoshi-active');
  if (!h) {
    h = new Highlight();
    CSS.highlights.set('hoshi-active', h);
  }
  return h;
};

window.__hoshiClearOverlay = function() {
  var els = window.__hoshiOverlayEls;
  for (var i = 0; i < els.length; i++) {
    var el = els[i];
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }
  window.__hoshiOverlayEls = [];
};

window.__hoshiPaintOverlay = function(ranges) {
  window.__hoshiClearOverlay();
  if (!document.body) return;
  for (var i = 0; i < ranges.length; i++) {
    var rects;
    try { rects = ranges[i].getClientRects(); } catch (e) { rects = null; }
    if (!rects) continue;
    for (var r = 0; r < rects.length; r++) {
      var rect = rects[r];
      if (!rect || rect.width < 1 || rect.height < 1) continue;
      var div = document.createElement('div');
      div.className = '__hoshi-overlay-rect';
      div.style.left = rect.left + 'px';
      div.style.top = rect.top + 'px';
      div.style.width = rect.width + 'px';
      div.style.height = rect.height + 'px';
      document.body.appendChild(div);
      window.__hoshiOverlayEls.push(div);
    }
  }
};

window.__hoshiSetActiveRanges = function(ranges) {
  window.__hoshiActiveRanges = ranges && ranges.length ? ranges.slice() : [];
  if (window.__hoshiPaintApiOk) {
    var h = window.__hoshiEnsureHighlightRegistry();
    if (h) {
      h.clear();
      for (var i = 0; i < window.__hoshiActiveRanges.length; i++) {
        try { h.add(window.__hoshiActiveRanges[i]); } catch (e) {}
      }
    }
    // 若之前走过 overlay 路径（比如调试切换），顺带清一次残留。
    window.__hoshiClearOverlay();
  } else {
    window.__hoshiPaintOverlay(window.__hoshiActiveRanges);
  }
};

window.__hoshiClearActiveRanges = function() {
  window.__hoshiActiveRanges = [];
  if (window.__hoshiPaintApiOk) {
    var h = window.__hoshiEnsureHighlightRegistry();
    if (h) h.clear();
  }
  window.__hoshiClearOverlay();
};

// 旧 WebView 的 overlay 走 position:fixed（视口坐标），内容滚动时 overlay
// 不会自动跟着移；监听 .book-content 的 scroll，再画一次。ticker 到位后
// scroll 稳定，overlay 也就稳定。用户手动翻页时同样重画。
window.__hoshiInstallOverlayScrollSync = function() {
  if (window.__hoshiPaintApiOk) return;
  if (window.__hoshiOverlayScrollHandler) return;
  var c = document.querySelector('.book-content');
  if (!c) return;
  window.__hoshiOverlayScrollHandler = function() {
    if (window.__hoshiActiveRanges.length > 0) {
      window.__hoshiPaintOverlay(window.__hoshiActiveRanges);
    }
  };
  c.addEventListener('scroll', window.__hoshiOverlayScrollHandler,
      { passive: true });
};

console.log(JSON.stringify({
  'hibiki-message-type': 'paintInit',
  'apiOk': window.__hoshiPaintApiOk
}));
''';

  /// Sasayaki 路径的辅助 JS：
  ///
  /// - `__hoshiLoadSasayakiRefs(ttuBookId)`：从 ttu IndexedDB 读 `sections` +
  ///   `elementHtml`，缓存 `sectionIndex → reference` 和每个 section 的
  ///   **归一化文本长度**（以及累计起点）。ttu 在渲染时会剥掉 section
  ///   原始 id，所以我们放弃"找章节根"这条路，改为用"整本书归一化偏移"
  ///   在 `.book-content-container` 里定位。
  /// - `__hoshiIsSkippable(code)`：镜像 Dart 的 `EpubSrtMatcher._isKeepable`
  ///   的反函数。白名单规则（只留假名/汉字/字母数字），其余一律视为可跳过。
  /// - `__hoshiUnwrapSasayaki()`：历史名；现在重定向到 `__hoshiClearActiveRanges()`
  ///   （高亮改走 CSS Highlight API / overlay，没有 span 可拆）。
  /// - `__hoshiHighlightSasayaki(s, ns, ne)`：把 (sectionIndex, normChar*)
  ///   换算成全书归一化全局偏移 → 在 `.book-content-container` 里按归一化
  ///   字符数走 text node 找到 Range → 交给 `__hoshiSetActiveRanges` 画层 →
  ///   `__hoshiHighlightRange` 触发 ticker 滚动。不再动 DOM。
  ///
  /// 与字幕 EPUB 路径（`[data-cue-id]`）互不冲突：入口在 Dart 侧的
  /// [highlight] 根据 `textFragmentId` 前缀分派。
  static const String _sasayakiFn = '''
window.__hoshiSasayakiRefs = window.__hoshiSasayakiRefs || null;
window.__hoshiSasayakiSectionStarts = window.__hoshiSasayakiSectionStarts || null;
window.__hoshiSasayakiSectionFirstChars = window.__hoshiSasayakiSectionFirstChars || null;
window.__hoshiSasayakiSectionLens = window.__hoshiSasayakiSectionLens || null;
window.__hoshiSasayakiTotalNorm = (typeof window.__hoshiSasayakiTotalNorm === 'number')
  ? window.__hoshiSasayakiTotalNorm : null;
window.__hoshiCurrentMountedSection = (typeof window.__hoshiCurrentMountedSection === 'number')
  ? window.__hoshiCurrentMountedSection : -1;
// 运行期 fallback 的前向单调锚——记住上一条 cue 在当前段里实际落到的
// normChar 终点，fallback indexOf 从这里往后找。Sasayaki 上游的导入期
// matcher（epub_srt_matcher.dart）本身就是 cursor 单调前向的，但运行期
// 如果 DOM ↔ 导入期 normChar 有系统性偏移（ttu 渲染后正文字符数和 DOMParser
// 抽的 elementHtml 对不上），fallback 的 Math.abs(p - targetStart) tiebreak
// 会在重复短句上挑到**上一条 cue 之前**的命中，表现成"高亮往回跳"。
// 段切换时重置（用 section 判定，不是时间判定）。
window.__hoshiSasayakiLastFoundSection = (typeof window.__hoshiSasayakiLastFoundSection === 'number')
  ? window.__hoshiSasayakiLastFoundSection : -1;
window.__hoshiSasayakiLastFoundEnd = (typeof window.__hoshiSasayakiLastFoundEnd === 'number')
  ? window.__hoshiSasayakiLastFoundEnd : 0;

window.__hoshiLoadSasayakiRefs = function(ttuBookId) {
  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiRefsLoading',
    'ttuBookId': ttuBookId
  }));
  try {
    var req = indexedDB.open('books');
    req.onsuccess = function(ev) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiRefsDbOpen',
        'stores': Array.prototype.slice.call(ev.target.result.objectStoreNames)
      }));
      var db = ev.target.result;
      if (!db.objectStoreNames.contains('data')) {
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsErr',
          'error': 'no_data_store'
        }));
        return;
      }
      var tx = db.transaction(['data'], 'readonly');
      var g = tx.objectStore('data').get(ttuBookId);
      g.onsuccess = function(e) {
        var rec = e.target.result;
        var sections = (rec && rec.sections) || [];
        var html = (rec && rec.elementHtml) || '';
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsRecord',
          'ttuBookId': ttuBookId,
          'recFound': !!rec,
          'sectionsLen': sections.length,
          'htmlLen': html.length
        }));

        // 每段正文归一化字符数 —— 复用 DOMParser 从原始 elementHtml 中按
        // section.reference 取元素的 textContent 再数字符。必须和 Dart 侧
        // `EpubSrtMatcher._buildIndex` 的累加方式严格一致，否则累计起点
        // 会漂移。剥 <rt>/<rp> 的规则也必须和 TtuIdbReader 保持一致，否则
        // 匹配时的偏移基准 vs 运行期高亮基准会错位。
        var parser = new DOMParser();
        var doc = parser.parseFromString('<div>' + html + '</div>', 'text/html');

        function normLen(t) {
          var n = 0;
          for (var i = 0; i < t.length; i++) {
            if (!window.__hoshiIsSkippable(t.charCodeAt(i))) n++;
          }
          return n;
        }

        // 与运行期 DOM measure 的 firstChars 取样口径严格一致：
        // 只收非 skippable 字符，最多 32 个。用于后续按章节首字识别
        // ttu 当前挂载的是哪一段。
        function firstNormChars(t, cap) {
          var out = '';
          for (var i = 0; i < t.length && out.length < cap; i++) {
            var c = t.charCodeAt(i);
            if (!window.__hoshiIsSkippable(c)) out += t[i];
          }
          return out;
        }

        function stripRubyText(el) {
          var clone = el.cloneNode(true);
          var rts = clone.querySelectorAll('rt, rp');
          for (var j = 0; j < rts.length; j++) rts[j].parentNode.removeChild(rts[j]);
          return clone.textContent || '';
        }

        var refs = [];
        var starts = [];
        var firsts = [];
        var sectionLens = [];
        var cumulative = 0;
        for (var i = 0; i < sections.length; i++) {
          var ref = (sections[i] && sections[i].reference) || '';
          refs.push(ref);
          starts.push(cumulative);
          var el = ref ? doc.getElementById(ref) : null;
          var text = el ? stripRubyText(el) : '';
          firsts.push(firstNormChars(text, 32));
          var segLen = normLen(text);
          sectionLens.push(segLen);
          cumulative += segLen;
        }
        window.__hoshiSasayakiRefs = refs;
        window.__hoshiSasayakiSectionStarts = starts;
        window.__hoshiSasayakiSectionFirstChars = firsts;
        window.__hoshiSasayakiSectionLens = sectionLens;
        window.__hoshiSasayakiTotalNorm = cumulative;
        // 强制下一次 highlight 重新识别当前挂载段（载入后 rootTextLen 可能
        // 相同但 section 定义换了）。
        window.__hoshiDomMeasuredFor = -1;
        window.__hoshiCurrentMountedSection = -1;
        // sectionLens 已在上面按段累计时记下，方便和 Dart matcher 的
        // [sasayaki] matcher.section[N] 日志逐行比对。两侧任何一行的
        // normLen 不一样就是 normalize 规则 / ruby 处理 / DOMParser 行为
        // 的偏移，立刻能定位到具体哪段崩了。
        // 单条消息太长会被 Android logcat 截断，把大数组拆短条打。
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsReady',
          'count': refs.length,
          'totalNormChars': cumulative
        }));
        for (var pi = 0; pi < refs.length; pi++) {
          console.log(JSON.stringify({
            'hibiki-message-type': 'sasayakiRefsSection',
            'i': pi,
            'ref': refs[pi],
            'start': starts[pi],
            'normLen': sectionLens[pi]
          }));
        }
      };
      g.onerror = function(e) {
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsErr',
          'error': String(e.target.error)
        }));
      };
    };
    req.onerror = function(e) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiRefsErr',
        'error': String(e.target.error)
      }));
    };
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiRefsErr',
      'error': String(e)
    }));
  }
};

window.__hoshiIsSkippable = function(c) {
  // 与 Dart EpubSrtMatcher._isKeepable 对应的"反函数"：只要不在白名单里
  // 就视为 skippable（不计入 normChar 计数）。白名单必须与 Dart 严格一致，
  // 否则匹配期写回的 normCharStart/End 与 WebView 运行期计数对不上 → 高亮漂。
  if (c >= 0x30 && c <= 0x39) return false;   // 0-9
  if (c >= 0x41 && c <= 0x5A) return false;   // A-Z
  if (c >= 0x61 && c <= 0x7A) return false;   // a-z
  if (c === 0x3005 || c === 0x3006 || c === 0x3007) return false; // 々 〆 〇
  if (c >= 0x3041 && c <= 0x3096) return false; // ぁ-ゖ
  if (c >= 0x309D && c <= 0x309F) return false; // ゝゞゟ
  if (c >= 0x30A1 && c <= 0x30FA) return false; // ァ-ヺ
  if (c >= 0x30FC && c <= 0x30FF) return false; // ー ヽ ヾ ヿ
  if (c >= 0x3400 && c <= 0x4DBF) return false; // CJK Ext A
  if (c >= 0x4E00 && c <= 0x9FFF) return false; // CJK Unified
  if (c >= 0xFF10 && c <= 0xFF19) return false; // ０-９
  if (c >= 0xFF21 && c <= 0xFF3A) return false; // Ａ-Ｚ
  if (c >= 0xFF41 && c <= 0xFF5A) return false; // ａ-ｚ
  if (c >= 0xFF66 && c <= 0xFF9D) return false; // ｦ-ﾝ
  return true;
};

// 历史遗留名字。过去 Sasayaki 路径靠 wrap span 做高亮，unwrap 就是把
// 那批 span 的内容重新插回父节点。现在高亮改走 CSS Highlight API / overlay
// 路径（零 DOM 改动），没有 span 可拆；保留 API 签名供既有调用点复用，
// 语义变成"清当前高亮"。
window.__hoshiUnwrapSasayaki = function() {
  if (typeof window.__hoshiClearActiveRanges === 'function') {
    window.__hoshiClearActiveRanges();
  }
};

window.__hoshiHighlightSasayaki = function(sectionIndex, normCharStart, normCharEnd, expectedCue, reveal) {
  if (reveal === undefined) reveal = true;
  var starts = window.__hoshiSasayakiSectionStarts;
  var refs = window.__hoshiSasayakiRefs;
  if (!starts || !refs) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiRefsMissing',
      'sectionIndex': sectionIndex
    }));
    return;
  }
  if (sectionIndex < 0 || sectionIndex >= starts.length) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiNoRef',
      'sectionIndex': sectionIndex,
      'total': starts.length
    }));
    return;
  }

  // 实测 ttu **只挂载当前 section** 的 DOM 到 .book-content-container（rootText
  // 长度恰好等于当前段 normLen），不是全书共用一个容器。所以 walker 的
  // normPos=0 就是当前段起点，target 直接用段内偏移 (normCharStart/End)，
  // 不能再加 starts[sectionIndex] —— 以前加了 base 等于往后多走了前面所有
  // 段的字符数，高亮就落到后一句。
  //
  // 代价是：如果 cue 的 sectionIndex 与用户当前挂载的 section 不同，walker
  // 会在当前段内找不到（normCharStart 可能超出当前段长度），走 offsetMissing
  // 分支降级。跨 section 自动跳章要等 PR8a ttu fork API 落地。
  var base = starts[sectionIndex];
  var targetStart = normCharStart;
  var targetEnd = normCharEnd;

  var root = document.querySelector('.book-content-container') ||
             document.querySelector('.book-content');
  if (!root) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiContainerMissing'
    }));
    return;
  }

  // ttu 实测默认停在封面：`.book-content-container` 只装封面 SVG，正文
  // 要用户点进去才挂载。rootTextLen 很小（封面通常 < 50 字）说明还在封面。
  // 为了排查 "挂载状态何时变化"，按 tick 序号采样打（前 3 次 + 每 20 次一次），
  // 既能捕捉状态翻转也不会刷屏。
  var rootTextLen = root.textContent ? root.textContent.length : 0;
  if (rootTextLen < 80) {
    window.__hoshiNotMountedCount = (window.__hoshiNotMountedCount || 0) + 1;
    if (window.__hoshiNotMountedCount <= 3 ||
        window.__hoshiNotMountedCount % 20 === 0) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiBookNotMounted',
        'rootTextLen': rootTextLen,
        'count': window.__hoshiNotMountedCount,
        'hint': 'navigate past cover to mount chapter text'
      }));
    }
    return;
  }
  // 挂载上了就清零计数，用户翻回封面再翻回来还能重新打挂载日志。
  window.__hoshiNotMountedCount = 0;

  // 测 walker 看到的 root 里总 norm 字符数 + 首尾采样。用 rootTextLen
  // 作脏标记：rootTextLen 变了说明 ttu 切换了 section 挂载内容，要重新
  // 测。否则一段内反复测浪费 CPU。
  if (window.__hoshiDomMeasuredFor !== rootTextLen) {
    window.__hoshiDomMeasuredFor = rootTextLen;
    try {
      var measureWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: function(n) {
          var p = n.parentNode;
          while (p && p !== root) {
            var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
            if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
            p = p.parentNode;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      var totalNorm = 0;
      var firstChars = '';
      var sampleAt1000 = '';
      var sampleAt10000 = '';
      var mnode;
      while ((mnode = measureWalker.nextNode())) {
        var mtxt = mnode.nodeValue || '';
        for (var mi = 0; mi < mtxt.length; mi++) {
          var mc = mtxt.charCodeAt(mi);
          if (window.__hoshiIsSkippable(mc)) continue;
          if (totalNorm < 32) firstChars += mtxt[mi];
          if (totalNorm === 1000) sampleAt1000 = '';
          if (totalNorm >= 1000 && sampleAt1000.length < 32) sampleAt1000 += mtxt[mi];
          if (totalNorm === 10000) sampleAt10000 = '';
          if (totalNorm >= 10000 && sampleAt10000.length < 32) sampleAt10000 += mtxt[mi];
          totalNorm++;
        }
      }
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiDomMeasure',
        'rootTotalNormChars': totalNorm,
        'rootTextContentLen': root.textContent ? root.textContent.length : 0,
        'firstChars': firstChars,
        'sampleAt1000': sampleAt1000,
        'sampleAt10000': sampleAt10000
      }));

      // ── 识别 ttu 当前挂载的是哪一段 ──
      // ttu 只挂当前 section；如果播放中的 cue 指向别的 section 而我们
      // 仍按"段内偏移"去 walker 找字符，在当前段长度足够长时会命中一个
      // **错误的句子**，然后 ticker 把页面滚到远离真实播放位置的地方。
      // 通过首字 + normLen 匹配找出真正挂载的段 idx，供 highlight 主逻辑
      // 做跨段短路判断。
      var mounted = -1;
      var secFirsts = window.__hoshiSasayakiSectionFirstChars;
      var secLens = window.__hoshiSasayakiSectionLens;
      // 首字匹配：每段前 32 个归一化字符，取前 16 个比对（够区分且抗
      // 段首空白 / 标点 / 章号差异的鲁棒性更好）。
      if (secFirsts && firstChars && firstChars.length > 0) {
        var probe = firstChars.slice(0, 16);
        if (probe.length >= 8) {
          for (var si = 0; si < secFirsts.length; si++) {
            var sf = secFirsts[si];
            if (sf && sf.slice(0, probe.length) === probe) {
              mounted = si;
              break;
            }
          }
        }
      }
      // 首字没匹中（少数纯数字/罗马数字章首）→ 退回 normLen 精确匹配。
      // 多段同长时取第一个；极少见，日志里能看出。
      if (mounted === -1 && secLens) {
        for (var sj = 0; sj < secLens.length; sj++) {
          if (secLens[sj] === totalNorm) {
            mounted = sj;
            break;
          }
        }
      }
      window.__hoshiCurrentMountedSection = mounted;
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiMountedSection',
        'mountedSection': mounted,
        'rootTotalNormChars': totalNorm,
        'firstCharsProbe': firstChars ? firstChars.slice(0, 16) : ''
      }));
      // 把"运行期 DOM 测出的归一化字符数"和"导入期 DOMParser 抽 elementHtml
      // 数出来的字符数"对账。两者不等说明 ttu 渲染后正文里多/少了字符
      // （常见：ttu 注入章节标题、版权水印、章末导航）；fallback 的 delta
      // 字段会跟 drift 完全一致，根因在这一条日志里能直接看到。
      if (secLens && mounted >= 0 && secLens[mounted] !== totalNorm) {
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiSectionLenDrift',
          'mountedSection': mounted,
          'expectedNormLen': secLens[mounted],
          'domNormLen': totalNorm,
          'delta': totalNorm - secLens[mounted]
        }));
      }
    } catch (me) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiDomMeasureErr',
        'error': String(me)
      }));
    }
  }

  // ── 跨段短路 ──
  // DOM 测出的挂载段 != cue 要高亮的段 → 立刻 return，不调 walker、不动
  // 页面。避免"段内偏移命中错误句子 → 滚到无关位置"。高亮留空，等用户
  // 翻到正确段（或 Follow audio 自动跳段）再次 tick 时恢复。
  var mountedSec = window.__hoshiCurrentMountedSection;
  if (mountedSec >= 0 && mountedSec !== sectionIndex) {
    window.__hoshiSectionMismatchCount = (window.__hoshiSectionMismatchCount || 0) + 1;
    if (window.__hoshiSectionMismatchCount <= 3 ||
        window.__hoshiSectionMismatchCount % 20 === 0) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiSectionMismatch',
        'mountedSection': mountedSec,
        'cueSection': sectionIndex,
        'count': window.__hoshiSectionMismatchCount,
        'hint': 'cue belongs to a different section; skipping highlight'
      }));
    }
    // 清一次旧高亮避免"上一条高亮留在错误位置"。
    window.__hoshiUnwrapSasayaki();
    var stale = document.querySelectorAll('.hoshi-active');
    for (var sli = 0; sli < stale.length; sli++) {
      stale[sli].classList.remove('hoshi-active');
    }
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }
  // 匹配上了就清 mismatch 计数。
  window.__hoshiSectionMismatchCount = 0;

  // Clear any previous Sasayaki wrap + class-only legacy highlight BEFORE
  // walking, so offsets into text nodes aren't affected by artificial spans.
  window.__hoshiUnwrapSasayaki();
  var legacy = document.querySelectorAll('.hoshi-active');
  for (var li = 0; li < legacy.length; li++) {
    legacy[li].classList.remove('hoshi-active');
  }

  // Walk text nodes under root, skipping <rt>/<rp> (furigana). Dart 侧
  // 匹配用的是剥掉振假名的纯正文；这里必须对齐，否则带 ruby 的章节每过
  // 一段就被读音的额外字符挤偏，高亮会漂到后面几十字。
  var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: function(n) {
      var p = n.parentNode;
      while (p && p !== root) {
        var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
        if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
        p = p.parentNode;
      }
      return NodeFilter.FILTER_ACCEPT;
    }
  });
  var startNode = null, startOffset = 0;
  var endNode = null, endOffset = 0;
  var normPos = 0;
  var lastNode = null;
  // 顺便累积 walker 视角的 **纯化文本**（跳过 rt/rp + skippable）。
  // 不能用 range.toString() 做 match 对账：DOM Range 规范会把 Range 跨越
  // 的所有 Text 节点内容拼进去（包括被 walker 跳过的 <rt> 振假名），对
  // 日文带 ruby 的正文必然比 expectedCue 多出一串假名，match 永远假阳性。
  var actualNormText = '';
  var node;
  while ((node = walker.nextNode())) {
    lastNode = node;
    var text = node.nodeValue || '';
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (window.__hoshiIsSkippable(c)) continue;
      if (startNode === null && normPos >= targetStart) {
        startNode = node;
        startOffset = i;
      }
      if (startNode !== null && normPos < targetEnd) {
        actualNormText += text[i];
      }
      normPos++;
      if (startNode !== null && normPos >= targetEnd) {
        endNode = node;
        endOffset = i + 1;
        break;
      }
    }
    if (endNode !== null) break;
  }

  // targetEnd 超出全书归一化字符数（最后几章的 cue、或 matcher 溢出到尾部）
  // 时高亮到尾节点结束。
  if (startNode !== null && endNode === null && lastNode !== null) {
    endNode = lastNode;
    endOffset = lastNode.nodeValue ? lastNode.nodeValue.length : 0;
  }

  if (!startNode || !endNode) {
    // targetStart 超过当前挂载章节的归一化字符数——cue 在尚未挂载的
    // 章节里。ttu 只在当前显示章节挂载 DOM，用户翻过去就行。
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiOffsetMissing',
      'sectionIndex': sectionIndex,
      'targetStart': targetStart,
      'targetEnd': targetEnd,
      'scannedChars': normPos
    }));
    return;
  }

  var range = document.createRange();
  try {
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset);
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiRangeErr',
      'error': String(e)
    }));
    return;
  }

  // ★ 关键诊断：在包裹 span 之前用 walker 累积的纯化文本与 expectedCue
  // 直接对账。两者不同 → sectionIndex/normChar 偏移或 normalize 规则有
  // 问题；两者相同但用户视觉上仍错位 → 渲染层 bug（Svelte 重渲染吃掉
  // span 之类）。注意不能用 range.toString()：Range 会把跨越的 <rt>
  // 假名一起拼进字符串，对带 ruby 的正文永远假阳性。
  var actualText = actualNormText;

  // ── 兜底：cue 文本对不上时按 indexOf 重定位 ──
  // 按 Dart 侧 normChar 偏移定位到的 range 落在错位的句子上（ttu 渲染
  // 期对 HTML 做了 Dart 侧 DOMParser 不会做的改写时触发）。用 expectedCue
  // normalize 后的串在当前挂载段里 indexOf 定位，按"离原 targetStart 最
  // 近"的命中重建 range。找不到就放弃本条，不 wrap、不滚动、保持视口不动。
  function normKeep(t) {
    var b = '';
    for (var i = 0; i < t.length; i++) {
      if (!window.__hoshiIsSkippable(t.charCodeAt(i))) b += t[i];
    }
    return b;
  }
  var normActual = actualNormText;
  var normExpected = normKeep(expectedCue || '');
  var usedFallback = false;
  var fallbackDelta = 0;
  // 阈值从 4 降到 2：原阈值是为了避免短串（"はい""そう"）在整段 indexOf
  // 里命中过多噪声。下面 fallback 的 indexOf 起点已经被 monotonicFrom 夹到
  // 上一条 cue 终点附近，搜索域窄到一两句，2 字短串也安全了。
  if (normExpected.length >= 2 && normActual !== normExpected) {
    var fbNodes = [];
    var fbMap = [];
    var fbStr = '';
    var fbWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        var p = n.parentNode;
        while (p && p !== root) {
          var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
          if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
          p = p.parentNode;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var fbNode;
    while ((fbNode = fbWalker.nextNode())) {
      var ti = fbNodes.length;
      fbNodes.push(fbNode);
      var ftext = fbNode.nodeValue || '';
      for (var fi = 0; fi < ftext.length; fi++) {
        var fc = ftext.charCodeAt(fi);
        if (window.__hoshiIsSkippable(fc)) continue;
        fbStr += ftext[fi];
        fbMap.push([ti, fi]);
      }
    }
    // 选离原 targetStart 最近的命中——同一段内同句多次出现时避免 indexOf
    // 总是挑第一个。但起点夹在上一条 cue 的终点附近（同 section 内才生效），
    // 避免在段头碰到同样短串时挑到上一条 cue 之前的位置 → "高亮往回跳"。
    // tolerance=64：cue 之间偶有重叠（音轨切换瞬间）或 audio 微秒级回退时，
    // 允许 fallback 命中比 lastFoundEnd 略早一点的位置；超出就当回退是误匹配。
    var monotonicFrom = 0;
    if (window.__hoshiSasayakiLastFoundSection === sectionIndex) {
      monotonicFrom = Math.max(0, (window.__hoshiSasayakiLastFoundEnd || 0) - 64);
    }
    var bestIdx = -1;
    var bestDelta = Infinity;
    var from = monotonicFrom;
    while (from <= fbStr.length - normExpected.length) {
      var p = fbStr.indexOf(normExpected, from);
      if (p < 0) break;
      var d = Math.abs(p - targetStart);
      if (d < bestDelta) { bestDelta = d; bestIdx = p; }
      from = p + 1;
    }
    // monotonicFrom 卡得太紧时（用户 seek 到段中间或导入后第一条 cue 的
    // targetStart 实际就在 lastFoundEnd 之前）整段内反而找不到——重试一遍
    // 全段 indexOf，并把这次回退当成新的锚点起点。
    if (bestIdx < 0 && monotonicFrom > 0) {
      from = 0;
      while (from <= fbStr.length - normExpected.length) {
        var p2 = fbStr.indexOf(normExpected, from);
        if (p2 < 0) break;
        var d2 = Math.abs(p2 - targetStart);
        if (d2 < bestDelta) { bestDelta = d2; bestIdx = p2; }
        from = p2 + 1;
      }
    }
    if (bestIdx >= 0 && bestIdx + normExpected.length <= fbMap.length) {
      var sMap = fbMap[bestIdx];
      var eMap = fbMap[bestIdx + normExpected.length - 1];
      startNode = fbNodes[sMap[0]];
      startOffset = sMap[1];
      endNode = fbNodes[eMap[0]];
      endOffset = eMap[1] + 1;
      try {
        range = document.createRange();
        range.setStart(startNode, startOffset);
        range.setEnd(endNode, endOffset);
        // 走 fbStr 切片而不是 range.toString()：后者会把 Range 跨越的
        // <rt>/<rp> 拼进来导致日志假阳性。
        actualText = fbStr.slice(bestIdx, bestIdx + normExpected.length);
        usedFallback = true;
        fallbackDelta = bestIdx - targetStart;
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiHighlightFallback',
          'sectionIndex': sectionIndex,
          'origNormStart': targetStart,
          'foundNormStart': bestIdx,
          'delta': fallbackDelta,
          'fbStrLen': fbStr.length,
          'monotonicFrom': monotonicFrom
        }));
      } catch (fbErr) {
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiHighlightFallbackErr',
          'error': String(fbErr)
        }));
        return;
      }
    } else {
      // 当前段里确实找不到这条 cue —— 要么 cue 指向别段而挂载识别误判，
      // 要么 cue 文本来源（字幕）和当前章节正文差异超出 indexOf 能容忍的
      // 范围。保持视口不动，放弃本条高亮，等下一条对得上的 cue 恢复。
      window.__hoshiClearActiveRanges();
      window.__hoshiTarget = null;
      window.__hoshiStopTicker();
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiHighlightFallbackMiss',
        'sectionIndex': sectionIndex,
        'fbStrLen': fbStr.length,
        'normExpectedLen': normExpected.length,
        'expectedHead': normExpected.slice(0, 16)
      }));
      return;
    }
  }

  // 不再包 span：CSS Custom Highlight API / overlay fallback 直接吃 Range，
  // 不动 DOM。extractContents+insertNode 会改 inline 流，让 CSS columns
  // 重排一次，表现为"每次高亮正文都跳一下"。
  try {
    window.__hoshiSetActiveRanges([range]);
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiPaintErr',
      'error': String(e)
    }));
    return;
  }

  function clip(s, n) {
    if (!s) return '';
    s = String(s).replace(/\\n/g, '\\\\n').replace(/\\r/g, '\\\\r');
    return s.length <= n ? s : s.slice(0, n) + '…';
  }

  // 更新前向单调锚——下一条 cue 的 fallback 从这里往后找。fallback 路径
  // 用 fallback 实际命中的 [bestIdx, bestIdx + normExpected.length) 终点；
  // 直接路径（offsets 对得上）用 cue 的标称 targetEnd。
  window.__hoshiSasayakiLastFoundSection = sectionIndex;
  window.__hoshiSasayakiLastFoundEnd = usedFallback
    ? (bestIdx + normExpected.length)
    : targetEnd;

  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiHighlightOk',
    'sectionIndex': sectionIndex,
    'normCharStart': normCharStart,
    'normCharEnd': normCharEnd,
    'targetStart': targetStart,
    'targetEnd': targetEnd,
    'base': base,
    'expectedCue': clip(expectedCue, 64),
    'actualText': clip(actualText, 64),
    'usedFallback': usedFallback,
    'fallbackDelta': fallbackDelta,
    'monotonicAnchor': monotonicFrom,
    'match': (actualText && expectedCue)
      ? (function() {
          // 用 normalize 后的串比，避免标点差异造成误报
          function norm(t) {
            var b = '';
            for (var i = 0; i < t.length; i++) {
              if (!window.__hoshiIsSkippable(t.charCodeAt(i))) b += t[i];
            }
            return b;
          }
          return norm(actualText) === norm(expectedCue);
        })()
      : null
  }));

  // reveal=true 时把当前 Range 喂给 ticker；Range 不消失 ttu 正常滚动。
  // reveal=false（Follow audio OFF / 未 play）视觉高亮已由 paint 层落地，
  // 视口保持用户当前位置。
  if (reveal) {
    window.__hoshiHighlightRange(range, true);
  } else {
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
  }
};

// ── 章节挂载时批量预解析 Range + Map 缓存 ──────────────────────────────
// 对齐 Sasayaki 原版 reader.js 的 applySasayakiCues / cueWrappers Map /
// highlightSasayakiCue(id) 模型。动机：原有 __hoshiHighlightSasayaki 每次
// 高亮都 TreeWalker 扫一遍整章归一化字符再切 Range，每句触发一次，成本高；
// 改成"章节挂载时一次性遍历，按 normChar 偏移把这一章所有 cue 预解析成
// Range，cueKey → Range[] 塞进 Map"，运行期 O(1) 查表交给 paint 层。
//
// 不再 wrap span——extractContents+insertNode 会改 DOM，让 CSS columns
// 重排导致正文"跳位"。高亮改走 CSS Custom Highlight API / overlay 画层。
//
// cueKey = Dart 侧 cue.textFragmentId（形如 "sasayaki://s=0&ns=100&ne=120"），
// 稳定唯一，不需要单独 id 空间。
//
// 降级：apply 失败（cue 跨节点、跨段、offsetMissing 等）时 Map 里没有 key，
// __hoshiHighlightSasayakiCueById 会自己回退到旧的偏移定位路径 __hoshiHighlightSasayaki，
// 所以全章匹配率不是 100% 也能工作。
window.__hoshiSasayakiCueMap = window.__hoshiSasayakiCueMap || null;
window.__hoshiSasayakiAppliedForSection =
  (typeof window.__hoshiSasayakiAppliedForSection === 'number')
    ? window.__hoshiSasayakiAppliedForSection : -1;
window.__hoshiSasayakiAppliedRootLen =
  (typeof window.__hoshiSasayakiAppliedRootLen === 'number')
    ? window.__hoshiSasayakiAppliedRootLen : -1;

window.__hoshiClearSasayakiApplied = function() {
  // 对齐上游 Sasayaki：apply 时把 cue 包进 <span class="hoshi-sasayaki-cue">，
  // 这里拆包。ttu 切章 innerHTML 整体替换时 span 会被一起清掉，但同段 re-apply
  // （rootLen 变、被 requestSectionNav 强制失效等）必须手动 unwrap，否则上一轮
  // span 残留在 DOM 里，新一轮再包一层，嵌套累积。
  if (document.body) {
    var spans = document.querySelectorAll('.hoshi-sasayaki-cue');
    var parents = [];
    var seen = new Set();
    for (var i = 0; i < spans.length; i++) {
      var span = spans[i];
      var parent = span.parentNode;
      if (!parent) continue;
      while (span.firstChild) parent.insertBefore(span.firstChild, span);
      parent.removeChild(span);
      if (!seen.has(parent)) {
        seen.add(parent);
        parents.push(parent);
      }
    }
    // 合并相邻 text node，避免每次 apply/clear 把节点数量越拆越多影响
    // 后续 TreeWalker 扫描成本。
    for (var pi = 0; pi < parents.length; pi++) {
      try { parents[pi].normalize(); } catch (e) {}
    }
  }
  window.__hoshiSasayakiCueMap = null;
  // range-based fallback（walker miss 路径）可能留的 CSS Highlight API 记录也清掉。
  if (typeof window.__hoshiClearActiveRanges === 'function') {
    window.__hoshiClearActiveRanges();
  }
};

window.__hoshiApplySasayakiCues = function(sectionIndex, cuesJson) {
  // cuesJson：[{key, ns, ne}, ...]，ns/ne 是**段内归一化字符偏移**（Sasayaki
  // 路径 ttu 只挂当前段，不是全书字符）。按 ns 升序排好；调用方保证 ns 单调
  // 不减且 ne >= ns。TreeWalker 一次线性扫，累积 normPos，匹配到就切 Range 包。
  var cues;
  try {
    cues = (typeof cuesJson === 'string') ? JSON.parse(cuesJson) : cuesJson;
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplyParseErr',
      'error': String(e)
    }));
    return;
  }
  if (!Array.isArray(cues) || cues.length === 0) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplySkip',
      'reason': 'no_cues',
      'sectionIndex': sectionIndex
    }));
    return;
  }
  var root = document.querySelector('.book-content-container') ||
             document.querySelector('.book-content');
  if (!root) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplyNoRoot'
    }));
    return;
  }
  var rootTextLen = root.textContent ? root.textContent.length : 0;
  if (rootTextLen < 80) {
    // 封面 / 尚未挂载，别包；等下次 mountedSection 事件。
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplySkip',
      'reason': 'root_too_short',
      'rootTextLen': rootTextLen
    }));
    return;
  }
  // 同一段 + 同一 root 已经 apply 过就跳过。ttu 切章会换 root innerHTML，
  // rootLen 通常随之变化；同段重复 apply 的情况主要来自 sasayakiMountedSection
  // 连发两条消息。
  if (window.__hoshiSasayakiAppliedForSection === sectionIndex &&
      window.__hoshiSasayakiAppliedRootLen === rootTextLen &&
      window.__hoshiSasayakiCueMap &&
      window.__hoshiSasayakiCueMap.size > 0) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplySkip',
      'reason': 'already_applied',
      'sectionIndex': sectionIndex,
      'mapSize': window.__hoshiSasayakiCueMap.size
    }));
    return;
  }
  // 切段/换 root：先卸掉旧包裹，释放旧 Map。
  window.__hoshiClearSasayakiApplied();
  window.__hoshiSasayakiCueMap = new Map();

  // 按 ns 升序，防止外部没排好序；同 ns 按 ne 升序作次序。
  cues.sort(function(a, b) {
    if (a.ns !== b.ns) return a.ns - b.ns;
    return (a.ne || 0) - (b.ne || 0);
  });

  // 采集 text node + 归一化字符 → 原节点/节点内 offset 的映射。一次性建好
  // 再批量解析 Range。不再 wrap span——Range 保留原始节点引用，高亮由
  // CSS Highlight API / overlay 自己画，不动 DOM，CSS columns 布局不抖。
  var fbNodes = [];
  var fbMap = [];   // [nodeIdx, charIdx]，长度 = 归一化字符总数
  var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: function(n) {
      var p = n.parentNode;
      while (p && p !== root) {
        var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
        if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
        p = p.parentNode;
      }
      return NodeFilter.FILTER_ACCEPT;
    }
  });
  var node;
  while ((node = walker.nextNode())) {
    var ti = fbNodes.length;
    fbNodes.push(node);
    var text = node.nodeValue || '';
    for (var i = 0; i < text.length; i++) {
      if (window.__hoshiIsSkippable(text.charCodeAt(i))) continue;
      fbMap.push([ti, i]);
    }
  }

  // 对齐上游 Sasayaki 原版：先按每条 cue 把 [ns, ne) 映射成**节点内 char 段**
  // 列表 ({nodeIdx, startChar, endChar})，一条 cue 可能跨多个 text node。
  // 然后按 cue 逆序 × 段逆序包 <span class="hoshi-sasayaki-cue">。
  //
  // 为什么逆序：Range.surroundContents 把 text node 从中间切开，原 node
  // 保留"前半段"、span 里是"中段"、再插一个 node 装"后半段"。先包节点内
  // 靠后的段、再包靠前的段，靠前段用的 charOffset 仍然落在原 node 的"前半段"
  // 里，索引不失效。cue 维度同理：后面的 cue 先包，前面的 cue 的 fbMap 条目
  // 不受影响。
  //
  // 运行期高亮只 toggle 这些 span 的 class，不再 TreeWalker / 不再 Range +
  // CSS Highlight API —— 上游 paginated reader.js 走同样 CSS columns 布局用
  // 同样 span 策略，重排问题在"只 apply 一次"前提下是不成立的。
  var perCue = [];  // [{key, segs: [{nodeIdx, startChar, endChar}, ...]}]
  var skippedOob = 0;
  for (var ci = 0; ci < cues.length; ci++) {
    var c = cues[ci];
    var ns = c.ns | 0;
    var ne = c.ne | 0;
    if (ne <= ns) { skippedOob++; continue; }
    if (ns < 0 || ne > fbMap.length) { skippedOob++; continue; }
    var segs = [];
    var curNode = -1;
    var curStart = -1;
    var curEnd = -1;
    var ok = true;
    for (var k = ns; k < ne; k++) {
      var m = fbMap[k];
      if (!m) { ok = false; break; }
      if (m[0] !== curNode) {
        if (curNode !== -1) {
          segs.push({nodeIdx: curNode, startChar: curStart, endChar: curEnd + 1});
        }
        curNode = m[0];
        curStart = m[1];
      }
      curEnd = m[1];
    }
    if (!ok) { skippedOob++; continue; }
    if (curNode !== -1) {
      segs.push({nodeIdx: curNode, startChar: curStart, endChar: curEnd + 1});
    }
    if (segs.length === 0) { skippedOob++; continue; }
    perCue.push({key: c.key, segs: segs});
  }

  var applied = 0;
  var skippedCross = 0;
  for (var pi = perCue.length - 1; pi >= 0; pi--) {
    var entry = perCue[pi];
    var wrappers = [];
    for (var si = entry.segs.length - 1; si >= 0; si--) {
      var seg = entry.segs[si];
      var tn = fbNodes[seg.nodeIdx];
      if (!tn || !tn.parentNode) continue;
      // 节点长度变化（同节点前面已有 span 被包出来切短）时 endChar 可能超界——
      // 被裁剪过的 tn 只保留"第一个被包 range 之前的"部分，而我们逆序处理
      // 保证当前 seg 正好落在这个"前半段"里，endChar <= tn.length 仍然成立。
      // 但 tn 可能已经完全被拆到 span 里（startChar == tn.length），这时直接跳。
      if (seg.startChar >= (tn.nodeValue || '').length) continue;
      try {
        var r = document.createRange();
        r.setStart(tn, seg.startChar);
        r.setEnd(tn, Math.min(seg.endChar, (tn.nodeValue || '').length));
        var span = document.createElement('span');
        span.className = 'hoshi-sasayaki-cue';
        span.setAttribute('data-sasayaki-key', entry.key);
        r.surroundContents(span);
        // 逆序 push + 最后 reverse，让 wrappers 与 DOM 顺序一致（第一个
        // wrapper 对应最靠前的段），高亮入口用 wrappers[0] 做翻页锚点。
        wrappers.push(span);
      } catch (e) {
        skippedCross++;
      }
    }
    if (wrappers.length > 0) {
      wrappers.reverse();
      window.__hoshiSasayakiCueMap.set(entry.key, wrappers);
      applied++;
    }
  }

  window.__hoshiSasayakiAppliedForSection = sectionIndex;
  window.__hoshiSasayakiAppliedRootLen = rootTextLen;

  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiApplied',
    'sectionIndex': sectionIndex,
    'cuesTotal': cues.length,
    'applied': applied,
    'skippedOob': skippedOob,
    'skippedCross': skippedCross,
    'mapSize': window.__hoshiSasayakiCueMap.size
  }));
};

window.__hoshiHighlightSasayakiCueById = function(key, reveal) {
  if (reveal === undefined) reveal = true;
  var map = window.__hoshiSasayakiCueMap;
  var wrappers = map ? map.get(key) : null;
  // 先清上一条 cue 的 active class。class toggle 不动 DOM 结构，不会触发
  // CSS columns 重排，相邻 cue 切换时视觉稳定。
  var prev = document.querySelectorAll('.hoshi-sasayaki-cue.hoshi-active');
  for (var pi = 0; pi < prev.length; pi++) {
    prev[pi].classList.remove('hoshi-active');
  }
  // 同时清 range-based fallback 留下的 CSS Highlight/overlay（如果上一条
  // 是 cueMap miss 走了 walker 路径）。
  if (typeof window.__hoshiClearActiveRanges === 'function') {
    window.__hoshiClearActiveRanges();
  }
  if (!wrappers || wrappers.length === 0) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiCueMapMiss',
      'key': key,
      'hasMap': !!map,
      'mapSize': map ? map.size : 0
    }));
    return false;
  }
  for (var wi = 0; wi < wrappers.length; wi++) {
    wrappers[wi].classList.add('hoshi-active');
  }
  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiCueHighlightOk',
    'key': key,
    'wrapperCount': wrappers.length,
    'reveal': reveal
  }));
  if (reveal) window.__hoshiAlignToElement(wrappers[0]);
  return true;
};
''';

  /// PR8a 的 Flutter 侧准备：ttu fork 之前就把"调用面"铺好，所有消费者只
  /// 认 `__sasayakiRequestNav` 这个统一入口，fork 落地后只改这一段 JS，其他
  /// 位置无感。
  ///
  /// ### 组件
  ///
  /// - `window.__sasayakiAutoNav`：系统触发的章节跳转期间为 true，用户翻页
  ///   为 false。PR8b 的 "Follow audio" 判断用户意图靠这个 flag，不用时间
  ///   窗。ttu fork 暴露 section API 时也必须在"恢复阅读位置"这类程序化
  ///   调用里手动置 true（或用另起的 `__ttuInternalNav`），否则会被误判。
  /// - `window.__sasayakiRequestNav(n)`：PR8b 调用的入口。当前实现两条分支：
  ///   ttu fork 已落地（`__ttuGoToSection` 存在）→ 调用并 await；否则打
  ///   `ttuForkMissing` 日志直接 resolve，让上层降级为 pill 提示。两种状态
  ///   调用面一致，上层不做分支。
  /// - `window.__hoshiTtuProbe()`：一次性探针，返回 `{hasGoToSection,
  ///   hasCurrentSection, hasSectionCount, sectionCount, currentSection}`，
  ///   供 [AudiobookBridge.probeTtuApi] 消费写进 AudiobookHealth.reason。
  static const String _ttuApiShimFn = '''
window.__sasayakiAutoNav = window.__sasayakiAutoNav || false;

window.__sasayakiRequestNav = async function(n) {
  window.__sasayakiAutoNav = true;
  try {
    if (typeof window.__ttuGoToSection === 'function') {
      await window.__ttuGoToSection(n);
      // ttu 跳章（哪怕目标段等于当前段）会整体替换 .book-content-container
      // 的 innerHTML，cueMap 里的 span 立刻变成孤儿节点——再给它们 addClass
      // 也找不到 .hoshi-active 了（见 highlightMiss 病症）。所以这里强制
      // 失效 applied 状态 + 丢掉旧 map，下一个 sasayakiMountedSection 事件
      // 会让上层跑 applySasayakiCues，新 DOM 上重建 cueMap。
      window.__hoshiSasayakiAppliedForSection = -1;
      window.__hoshiSasayakiAppliedRootLen = -1;
      if (typeof window.__hoshiClearSasayakiApplied === 'function') {
        window.__hoshiClearSasayakiApplied();
      }
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiNavOk', 'section': n
      }));
    } else {
      console.log(JSON.stringify({
        'hibiki-message-type': 'ttuForkMissing',
        'api': '__ttuGoToSection',
        'requestedSection': n
      }));
    }
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiNavErr',
      'section': n,
      'error': String(e)
    }));
  } finally {
    // queueMicrotask 保证 ttu 的 sectionChange 回调读到 true —— 它们通常
    // 在同一个 task 里同步派发，再下一个 microtask 才轮到我们复位。
    queueMicrotask(function() { window.__sasayakiAutoNav = false; });
  }
};

window.__hoshiTtuProbe = function() {
  var result = {
    'hibiki-message-type': 'ttuProbe',
    'hasGoToSection': typeof window.__ttuGoToSection === 'function',
    'hasCurrentSection': typeof window.__ttuCurrentSection === 'function',
    'hasSectionCount': typeof window.__ttuSectionCount === 'function',
    'sectionCount': null,
    'currentSection': null
  };
  try {
    if (result.hasSectionCount) {
      result.sectionCount = window.__ttuSectionCount();
    }
    if (result.hasCurrentSection) {
      result.currentSection = window.__ttuCurrentSection();
    }
  } catch (e) {
    result.probeError = String(e);
  }
  console.log(JSON.stringify(result));
  return JSON.stringify(result);
};
''';

  /// 自动句子标注函数：按日文句末标点分割文本节点，包裹 data-hoshi-sid span。
  ///
  /// 跳过 ruby 内部节点，避免破坏振假名结构。
  static const String _annotateFn = '''
window.__hoshiAnnotate = function(chapterHref) {
  if (document.__hoshiAnnotated) return;
  document.__hoshiAnnotated = true;

  var sidCounter = 0;
  var sentenceEnd = /[。！？」』）]/;

  function isInsideRuby(node) {
    var p = node.parentNode;
    while (p) {
      if (p.nodeName === 'RUBY' || p.nodeName === 'RT' || p.nodeName === 'RP') {
        return true;
      }
      p = p.parentNode;
    }
    return false;
  }

  function wrapText(textNode) {
    if (isInsideRuby(textNode)) return;
    var text = textNode.nodeValue;
    if (!text || text.trim().length === 0) return;

    var frag = document.createDocumentFragment();
    var buf = '';
    for (var i = 0; i < text.length; i++) {
      buf += text[i];
      if (sentenceEnd.test(text[i]) || i === text.length - 1) {
        var span = document.createElement('span');
        span.dataset.hoshiSid = String(sidCounter++);
        span.dataset.hoshiChapter = chapterHref;
        span.textContent = buf;
        frag.appendChild(span);
        buf = '';
      }
    }
    textNode.parentNode.replaceChild(frag, textNode);
  }

  var walker = document.createTreeWalker(
    document.body,
    NodeFilter.SHOW_TEXT,
    null,
    false
  );
  var nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  nodes.forEach(wrapText);

  // 点击事件：回传 {type, chapter, sid}
  document.addEventListener('click', function(e) {
    var span = e.target.closest('[data-hoshi-sid]');
    if (!span) return;
    console.log(JSON.stringify({
      'hibiki-message-type': 'seekToSentence',
      'chapter': span.dataset.hoshiChapter || '',
      'sid': parseInt(span.dataset.hoshiSid, 10)
    }));
  }, true);
};
''';

  /// Reader 位置持久化的 JS 反查 + 跳转 API。
  ///
  /// - `__hibikiGetViewportNormOffset()`：从视口左上探针点反查当前挂载段和
  ///   章内 Sasayaki 归一化字符偏移（和 AudioCue.normCharStart 同基准）。
  ///   用 `caretRangeFromPoint` 找视口顶部第一个可见文本节点，再用 Sasayaki
  ///   那套 walker 逐字符累加到命中位置。用于 Flutter 节流后写 Isar
  ///   [ReaderPosition]。
  /// - `__hibikiScrollToNormOffset(section, offset)`：包一层 __hoshiHighlightSasayaki
  ///   复用 ticker 翻页，把目标位置滚进视口；900ms 后调用
  ///   `__hoshiClearActiveRanges()` 清掉临时锚点高亮。
  ///
  /// 依赖 Sasayaki 已经准备好的 `__hoshiSasayakiSectionStarts` /
  /// `__hoshiCurrentMountedSection` / `__hoshiIsSkippable`，必须在
  /// [initSasayakiRefs] 和挂载 Sasayaki refs 完成后才用得上。
  static const String _readerPosFn = '''
window.__hibikiGetViewportNormOffset = function() {
  var section = -1;
  try {
    if (typeof window.__ttuCurrentSection === 'function') {
      var v = window.__ttuCurrentSection();
      if (typeof v === 'number') section = v;
    }
  } catch (e) {}
  // mountedSection 是 Sasayaki walker 实际看到的段，优先它 —— ttu
  // currentSection 在 sectionChanged skip(1) 的坑下可能滞后。
  if (typeof window.__hoshiCurrentMountedSection === 'number' &&
      window.__hoshiCurrentMountedSection >= 0) {
    section = window.__hoshiCurrentMountedSection;
  }
  if (section < 0) return null;

  var root = document.querySelector('.book-content-container') ||
             document.querySelector('.book-content');
  if (!root) return null;

  // 视口左上不一定命中文本，多试几个探针点（避开边距 / 段首空行）
  var w = window.innerWidth || 360;
  var h = window.innerHeight || 640;
  var probes = [
    [16, 32],
    [Math.floor(w * 0.1), Math.floor(h * 0.15)],
    [Math.floor(w * 0.2), Math.floor(h * 0.25)],
    [Math.floor(w * 0.5), Math.floor(h * 0.5)]
  ];
  var target = null;
  for (var i = 0; i < probes.length; i++) {
    var px = probes[i][0], py = probes[i][1];
    var r = null;
    try {
      if (document.caretRangeFromPoint) {
        r = document.caretRangeFromPoint(px, py);
      } else if (document.caretPositionFromPoint) {
        var cp = document.caretPositionFromPoint(px, py);
        if (cp && cp.offsetNode) {
          r = document.createRange();
          r.setStart(cp.offsetNode, cp.offset);
        }
      }
    } catch (err) { r = null; }
    if (r && r.startContainer && r.startContainer.nodeType === 3) {
      target = { node: r.startContainer, offset: r.startOffset };
      break;
    }
  }
  if (!target) return { section: section, offset: 0 };

  // Sasayaki walker 配方：SHOW_TEXT + 拒绝 rt/rp 祖先（ruby 振假名不计数）
  var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: function(n) {
      var p = n.parentNode;
      while (p && p !== root) {
        var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
        if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
        p = p.parentNode;
      }
      return NodeFilter.FILTER_ACCEPT;
    }
  });
  var normPos = 0;
  var node;
  while ((node = walker.nextNode())) {
    if (node === target.node) {
      var t = node.nodeValue || '';
      var cap = Math.min(target.offset, t.length);
      for (var j = 0; j < cap; j++) {
        if (!window.__hoshiIsSkippable(t.charCodeAt(j))) normPos++;
      }
      return { section: section, offset: normPos };
    }
    var txt = node.nodeValue || '';
    for (var k = 0; k < txt.length; k++) {
      if (!window.__hoshiIsSkippable(txt.charCodeAt(k))) normPos++;
    }
  }
  // target 不在 walker 可达范围（比如被 rt/rp 拒）→ 拿累加到终点的值兜底
  return { section: section, offset: normPos };
};

window.__hibikiScrollToNormOffset = function(section, offset) {
  // 复用 __hoshiHighlightSasayaki 的 walker + ticker 翻页。只高亮 1 个归一化
  // 字符做锚点，reveal=true 启 ticker；完事后清掉临时高亮（CSS Highlight API
  // 或 overlay），否则那一个字符会一直带黄色高亮。
  try {
    window.__hoshiHighlightSasayaki(section, offset, offset + 1, '', true);
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'hibikiScrollToNormOffsetErr',
      'error': String(e),
      'section': section, 'offset': offset
    }));
    return;
  }
  setTimeout(function(){
    try {
      if (window.__hoshiClearActiveRanges) window.__hoshiClearActiveRanges();
    } catch (_e) {}
  }, 900);
};
''';

  // ── 公开 API ───────────────────────────────────────────────────────────────

  /// 向 WebView 注入 CSS 样式和 JS 函数（章节加载完成后调用一次）。
  static Future<void> inject(InAppWebViewController controller) async {
    // 注入 CSS
    await controller.evaluateJavascript(source: '''
(function() {
  var existing = document.getElementById('__hoshi_audio_css');
  if (existing) return;
  var s = document.createElement('style');
  s.id = '__hoshi_audio_css';
  s.textContent = ${jsonEncode(_css)};
  document.head.appendChild(s);
})();
''');

    // 注入 JS 函数。顺序：highlight ticker → paint（CSS Highlight API /
    // overlay 抽象） → sasayaki（依赖 paint 的 setActiveRanges / clear）。
    await controller.evaluateJavascript(source: _highlightFn);
    await controller.evaluateJavascript(source: _paintFn);
    await controller.evaluateJavascript(source: _sasayakiFn);
    await controller.evaluateJavascript(source: _ttuApiShimFn);
    await controller.evaluateJavascript(source: _annotateFn);
    // 旧 WebView 的 overlay 走 position:fixed，.book-content 滚动时需要
    // 重画一次。Highlight API 可用时此调用内部提前 return。
    await controller.evaluateJavascript(
      source: '__hoshiInstallOverlayScrollSync();',
    );
    // _readerPosFn 依赖 __hoshiIsSkippable / __hoshiHighlightSasayaki，
    // 必须在 _sasayakiFn 之后 evaluate
    await controller.evaluateJavascript(source: _readerPosFn);
  }

  /// 探测 ttu 侧是否已挂出 PR8a 的 section 导航 API。
  ///
  /// fork 落地前预期全部 `hasXxx` 为 false；落地后为 true。调用方据此填
  /// AudiobookHealth.reason / UI 角标。在 [inject] 之后任何时候调用都行，
  /// 结果反映当次 WebView 上下文。
  ///
  /// 返回结构镜像 `window.__hoshiTtuProbe()` 的 JSON：
  /// `hasGoToSection` / `hasCurrentSection` / `hasSectionCount` /
  /// `sectionCount` / `currentSection`。
  static Future<TtuApiProbe> probeTtuApi(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source: '__hoshiTtuProbe();',
    );
    if (raw is! String) {
      return const TtuApiProbe.missing();
    }
    try {
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
      return TtuApiProbe(
        hasGoToSection: json['hasGoToSection'] == true,
        hasCurrentSection: json['hasCurrentSection'] == true,
        hasSectionCount: json['hasSectionCount'] == true,
        sectionCount: (json['sectionCount'] as num?)?.toInt(),
        currentSection: (json['currentSection'] as num?)?.toInt(),
      );
    } catch (_) {
      return const TtuApiProbe.missing();
    }
  }

  /// 请求跳转到指定 section。fork 未落地时此调用会在 JS 侧打
  /// `ttuForkMissing` 日志后直接 resolve，外层据此降级为 pill 提示。
  static Future<void> requestSectionNav(
    InAppWebViewController controller, {
    required int sectionIndex,
  }) async {
    await controller.evaluateJavascript(
      source: '__sasayakiRequestNav($sectionIndex);',
    );
  }

  /// 拿 ttu 的章节列表（`window.__ttuGetToc()`）。ttu fork 未就绪时
  /// 返回空列表。label 缺失的 section 退回 reference（fork 已处理）。
  static Future<List<TtuTocEntry>> fetchToc(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source:
          '(function(){try{return JSON.stringify(window.__ttuGetToc?window.__ttuGetToc():[]);}catch(e){return "[]";}})();',
    );
    if (raw is! String || raw.isEmpty) return const <TtuTocEntry>[];
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return const <TtuTocEntry>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> m) => TtuTocEntry(
                index: (m['index'] as num?)?.toInt() ?? -1,
                label: (m['label'] as String?) ?? '',
                parent: m['parent'] as String?,
              ))
          .where((TtuTocEntry e) => e.index >= 0)
          .toList(growable: false);
    } catch (_) {
      return const <TtuTocEntry>[];
    }
  }

  /// 触发 ttu 的"添加当前位置为书签"（`window.__ttuBookmarkPage()`）。
  /// fork 已处理 paginated / continuous 分支 + selection bookmark +
  /// database.putBookmark 落库。fork 未落地时是 no-op。
  static Future<void> bookmarkCurrentPage(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source:
          '(async function(){try{if(window.__ttuBookmarkPage){await window.__ttuBookmarkPage();}}catch(e){console.error("[hibiki] __ttuBookmarkPage",e);}})();',
    );
  }

  /// 从视口左上探针反查当前挂载段和章内归一化字符偏移。
  ///
  /// null 代表视口里没命中文本节点 / Sasayaki refs 还没挂上 / ttu 还没就位 ——
  /// 调用方直接跳过这一次保存，别拿 offset=0 瞎写（会覆盖之前保存的有效位置）。
  static Future<ReaderViewportPos?> getViewportNormOffset(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source:
          '(function(){try{return JSON.stringify(window.__hibikiGetViewportNormOffset ? (window.__hibikiGetViewportNormOffset()||null) : null);}catch(e){return "null";}})();',
    );
    if (raw is! String || raw.isEmpty || raw == 'null') {
      return null;
    }
    try {
      final dynamic json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final int? section = (json['section'] as num?)?.toInt();
      final int? offset = (json['offset'] as num?)?.toInt();
      if (section == null || section < 0 || offset == null || offset < 0) {
        return null;
      }
      return ReaderViewportPos(section: section, offset: offset);
    } catch (_) {
      return null;
    }
  }

  /// 跳到给定 section + 章内归一化偏移，复用 Sasayaki ticker 翻页。完事后
  /// 900ms 自动 unwrap 临时锚点 span。
  static Future<void> scrollToNormOffset(
    InAppWebViewController controller, {
    required int section,
    required int offset,
  }) async {
    await controller.evaluateJavascript(
      source: '__hibikiScrollToNormOffset($section, $offset);',
    );
  }

  /// 初始化 Sasayaki 路径所需的 `sectionIndex → DOM id` 映射。
  ///
  /// 在 [inject] 之后、首次 [highlight] Sasayaki-encoded cue 之前调用一次；
  /// 异步读 ttu IndexedDB，完成后控制台会打 `sasayakiRefsReady`。
  static Future<void> initSasayakiRefs(
    InAppWebViewController controller, {
    required int ttuBookId,
  }) async {
    await controller.evaluateJavascript(
      source: '__hoshiLoadSasayakiRefs($ttuBookId);',
    );
  }

  /// 对齐 Sasayaki 原版 reader.js 的 `applySasayakiCues(cues)`：ttu 章节
  /// 挂载完成（或 sasayakiMountedSection 识别出当前段）后，把该段所有
  /// Sasayaki cue 批量传给 WebView，JS 侧一次性 TreeWalker 扫归一化字符 →
  /// 按每条 cue 的 (normCharStart, normCharEnd) 包 `<span>` 存进
  /// `__hoshiSasayakiCueMap`。之后每句高亮就是 Map 查表，不再走 walker。
  ///
  /// [cues] 只需包含本段的 Sasayaki cue（非 Sasayaki 的 cue.textFragmentId
  /// 解码会返回 null，调用方已过滤）。同段重复调用会被 JS 侧 appliedForSection
  /// 缓存守卫跳过，不会重新包。
  static Future<void> applySasayakiCues(
    InAppWebViewController controller, {
    required int sectionIndex,
    required List<AudioCue> cues,
  }) async {
    final List<Map<String, dynamic>> payload = <Map<String, dynamic>>[];
    for (final AudioCue cue in cues) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag == null) continue;
      if (frag.sectionIndex != sectionIndex) continue;
      payload.add(<String, dynamic>{
        'key': cue.textFragmentId,
        'ns': frag.normCharStart,
        'ne': frag.normCharEnd,
      });
    }
    if (payload.isEmpty) return;
    await controller.evaluateJavascript(
      source: '__hoshiApplySasayakiCues($sectionIndex, '
          '${jsonEncode(payload)});',
    );
  }

  /// 自动标注当前章节的句子（在 [inject] 之后调用）。
  ///
  /// [chapterHref] 用于 click 回传，标识来源章节。
  static Future<void> annotate(
    InAppWebViewController controller, {
    required String chapterHref,
  }) async {
    await controller.evaluateJavascript(
      source: '__hoshiAnnotate(${jsonEncode(chapterHref)});',
    );
  }

  /// 高亮 [cue] 对应的句子。
  ///
  /// [cue] 为 null 时清除所有高亮。textFragmentId 以 `sasayaki://` 开头时走
  /// Sasayaki 路径（按 sectionIndex + 归一化字符偏移在 DOM 中定位）；否则
  /// 按普通 CSS selector 处理。
  ///
  /// [reveal] 对齐 Sasayaki 原版 `displayCue(cue, reveal:)`：true 时把
  /// cue 滚进视口（ticker 翻页），false 时**只加高亮 class**，保持用户
  /// 当前阅读位置不动。Reader 端一般传
  /// `controller.shouldRevealCurrentCue`（= followAudio && hasPlayedOnce）。
  ///
  /// 若 textFragmentId 为空（Sasayaki 匹配失败、且不是字幕合成书路径），
  /// 视为"无可用定位"：只清一次高亮，不再每 tick 刷 `[data-cue-id]` 回落。
  static Future<void> highlight(
    InAppWebViewController controller, {
    AudioCue? cue,
    bool reveal = true,
  }) async {
    if (cue == null || cue.textFragmentId.isEmpty) {
      await controller.evaluateJavascript(source: '__hoshiHighlight("");');
      return;
    }
    final String raw = cue.textFragmentId;
    final SasayakiFragment? frag = SasayakiMatchCodec.tryDecode(raw);
    if (frag != null) {
      // 优先走 Sasayaki 原版模型：章节挂载时已经通过 applySasayakiCues
      // 批量预包 span，运行期只是 Map 查表加 class。cueMap 未命中时 JS 自己
      // 回退到旧的 __hoshiHighlightSasayaki（TreeWalker + indexOf 回退）
      // 处理那条 cue，Dart 侧不分支。
      //
      // 为什么不让 Dart 根据 JS 返回值自己分支：evaluateJavascript 的返回
      // 值类型在不同 WebView 实现下不稳定，把控制流放在 JS 里一条链条
      // 到底更可靠。
      //
      // 翻页路径：reveal=true 时先 await 新的 `window.__ttuScrollToCharOffset`
      // （ttu fork 原生，走 bookmarkManager.scrollToBookmark 的 charCount
      // 反推路径，paginated / continuous 都支持），再画高亮。feature-detect
      // 兜底：API 不在（早期 fork 或上游 ttu）时 cueMap 命中路径退回
      // `__hoshiHighlightRange(ranges[0], true)`（range-based ticker），
      // cueMap miss 路径继续用 __hoshiHighlightSasayaki 自带的 walker+ticker。
      final String cueJson = jsonEncode(cue.text);
      await controller.evaluateJavascript(
        source: '(async function(){'
            'var reveal = $reveal;'
            'var useForkScroll = reveal && '
            '  typeof window.__ttuScrollToCharOffset === "function";'
            'if (useForkScroll) {'
            '  try { await window.__ttuScrollToCharOffset('
            '    ${frag.sectionIndex}, ${frag.normCharStart}); }'
            '  catch (e) {'
            '    console.log(JSON.stringify({'
            '      "hibiki-message-type": "scrollToCharOffsetErr",'
            '      "section": ${frag.sectionIndex},'
            '      "offset": ${frag.normCharStart},'
            '      "error": String(e)'
            '    }));'
            '    useForkScroll = false;'
            '  }'
            '}'
            // cueMap 路径。useForkScroll 成功时 reveal 传 false（滚动已完成,
            // 只 add class）；否则回退老 ticker：reveal 透传让它自己走。
            'if (window.__hoshiHighlightSasayakiCueById('
            '    ${jsonEncode(raw)}, useForkScroll ? false : reveal)) return;'
            // cueMap miss 路径。useForkScroll 成功时滚动已完成，只要 walker
            // 包 span + add class，reveal=false 跳过旧 ticker；否则交给老路径
            // 自己 ticker 翻页。
            'window.__hoshiHighlightSasayaki(${frag.sectionIndex}, '
            '  ${frag.normCharStart}, ${frag.normCharEnd}, $cueJson, '
            '  useForkScroll ? false : reveal);'
            '})();',
      );
      return;
    }
    await controller.evaluateJavascript(
      source: '__hoshiHighlight(${jsonEncode(raw)}, $reveal);',
    );
  }

  /// 高亮指定 selector（直接传 selector 字符串，不经过 AudioCue）。
  static Future<void> highlightSelector(
    InAppWebViewController controller, {
    required String selector,
  }) async {
    await controller.evaluateJavascript(
      source: '__hoshiHighlight(${jsonEncode(selector)});',
    );
  }

  /// 为字幕 EPUB 中的 `[data-cue-id]` span 注册点击事件。
  ///
  /// 调用此方法后，点击 span 会向 Flutter 回传
  /// `{hibiki-message-type: 'seekToSentence', chapter: chapterHref, sid: N}`。
  ///
  /// 与 [annotate] 互斥：字幕 EPUB 已有预打标的 span，不需要 annotate。
  ///
  /// 若页面中未找到 `[data-cue-id]` span，会输出 warn 日志但不抛出异常。
  static Future<void> injectCueClickHandler(
    InAppWebViewController controller, {
    required String chapterHref,
  }) async {
    final String chapterJson = jsonEncode(chapterHref);
    await controller.evaluateJavascript(source: '''
(function() {
  if (document.__hoshiCueClickRegistered) return;
  document.__hoshiCueClickRegistered = true;

  var count = document.querySelectorAll('[data-cue-id]').length;
  if (count === 0) {
    console.log('[hibiki] warn: no [data-cue-id] spans found in this page');
  }

  document.addEventListener('click', function(e) {
    var span = e.target.closest('[data-cue-id]');
    if (!span) return;
    var sid = parseInt(span.getAttribute('data-cue-id'), 10);
    if (isNaN(sid)) return;
    console.log(JSON.stringify({
      'hibiki-message-type': 'seekToSentence',
      'chapter': $chapterJson,
      'sid': sid
    }));
  }, true);
})();
''');
  }

  /// 解析 WebView console 消息，若为有声书点击事件则返回 [AudiobookClickEvent]。
  ///
  /// 返回 null 表示消息与有声书无关，调用方应继续正常处理。
  static AudiobookClickEvent? parseMessage(Map<String, dynamic> json) {
    if (json['hibiki-message-type'] != 'seekToSentence') {
      return null;
    }
    final String chapter = json['chapter'] as String? ?? '';
    final int sid = (json['sid'] as num?)?.toInt() ?? -1;
    if (sid < 0) {
      return null;
    }
    return AudiobookClickEvent(chapterHref: chapter, sentenceIndex: sid);
  }
}

/// PR8a 的 ttu section 导航 API 探针结果。
///
/// fork 未落地时 [hasGoToSection] / [hasCurrentSection] / [hasSectionCount]
/// 全部为 false，[sectionCount] 与 [currentSection] 为 null。UI 不会显示
/// 跨章自动跳转开关（PR8b 的 "Follow audio"），仅显示 pill 提示。
class TtuApiProbe {
  const TtuApiProbe({
    required this.hasGoToSection,
    required this.hasCurrentSection,
    required this.hasSectionCount,
    this.sectionCount,
    this.currentSection,
  });

  const TtuApiProbe.missing()
      : hasGoToSection = false,
        hasCurrentSection = false,
        hasSectionCount = false,
        sectionCount = null,
        currentSection = null;

  final bool hasGoToSection;
  final bool hasCurrentSection;
  final bool hasSectionCount;
  final int? sectionCount;
  final int? currentSection;

  /// 三项都挂上才算 fork 就绪；任何一项缺失都走兼容路径。
  bool get forkReady =>
      hasGoToSection && hasCurrentSection && hasSectionCount;

  /// 人话版摘要，方便写进 `AudiobookHealth.reason` 或 debug 日志。
  String describe() {
    if (forkReady) {
      return 'ttu fork ready (sections=$sectionCount, cur=$currentSection)';
    }
    final List<String> missing = <String>[];
    if (!hasGoToSection) missing.add('goToSection');
    if (!hasCurrentSection) missing.add('currentSection');
    if (!hasSectionCount) missing.add('sectionCount');
    return 'ttu fork missing: ${missing.join(", ")}';
  }
}

/// ttu 章节列表（`__ttuGetToc`）的单项。`index` 可直接传给
/// [AudiobookBridge.requestSectionNav] / ttu fork 的 `__ttuGoToSection`。
class TtuTocEntry {
  const TtuTocEntry({
    required this.index,
    required this.label,
    this.parent,
  });

  final int index;
  final String label;

  /// ttu `Section.parentChapter` —— 父章节 reference 字符串。UI 侧据此
  /// 缩进渲染二级章节（null 表示顶级章节）。
  final String? parent;
}

/// Reader 当前视口在全书中的位置 —— 章内 Sasayaki 归一化字符偏移。
///
/// 跟 AudioCue.normCharStart 同基准（ruby 剥、skippable 跳过），字号 /
/// pageColumns 变了也不会飘。对应 Isar 里的 [ReaderPosition]。
class ReaderViewportPos {
  const ReaderViewportPos({required this.section, required this.offset});
  final int section;
  final int offset;

  @override
  String toString() => 'ReaderViewportPos(section=$section, offset=$offset)';
}

/// 用户在 WebView 中点击有声书句子所产生的事件。
class AudiobookClickEvent {
  const AudiobookClickEvent({
    required this.chapterHref,
    required this.sentenceIndex,
  });

  /// 来源章节（EPUB spine href）。
  final String chapterHref;

  /// 点击的句子在章节内的序号（data-hoshi-sid）。
  final int sentenceIndex;
}
