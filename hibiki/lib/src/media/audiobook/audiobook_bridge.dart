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
[data-hoshi-sid], [data-cue-id] {
  cursor: pointer;
}
[data-hoshi-sid]:hover, [data-cue-id]:hover {
  background: rgba(100, 180, 255, 0.18);
  border-radius: 2px;
}
''';

  /// 高亮函数：移除旧高亮并把目标元素滚动到视口内，同时对齐到整页。
  ///
  /// ttu 在 IDB 字幕 EPUB 路径下是**连续滚动模式**：真正的滚动容器是
  /// `.book-content`（scrollHeight 远大于 clientHeight），body 自身
  /// `overflow: hidden`。因此既不能通过 window.scroll 也不能通过
  /// 向 body 派发 wheel 事件来翻页 —— 必须直接赋值 `.book-content.scrollTop`。
  ///
  /// ## 为什么不用 scrollIntoView
  ///
  /// 浏览器默认把目标元素居中到视口中点，scrollTop 停在任意像素上，
  /// 导致页面上方露出上一页残字、下方露出下一页开头，视觉混乱。
  /// 改为**按 clientHeight 整数倍对齐**：计算 cue 在 content 内的
  /// 绝对 top，除以 pageH 取整得到页索引，scrollTop = pageIndex * pageH。
  /// 这样每次跳转看到的都是一整页的内容，没有跨页残留。
  ///
  /// ttu 的 Svelte store 不监听 `.book-content.scrollTop`（它监听页索引），
  /// 外部赋值不会被覆盖。
  ///
  /// ## 收敛策略：ticker
  ///
  /// 保留 `setInterval` 轮询。每 280ms 检查 scrollTop 是否已到目标页，
  /// 已对齐则停；未对齐则再赋值。新 highlight 替换 pending 目标，旧
  /// ticker 自动收敛到新目标。退路：missing 元素重试上限 30 次（≈ 9s），
  /// scroll 失败上限 30 次。
  static const String _highlightFn = '''
window.__hoshiTarget = window.__hoshiTarget || null;
window.__hoshiTickerId = window.__hoshiTickerId || null;
window.__hoshiTickIntervalMs = 280;

window.__hoshiStopTicker = function() {
  if (window.__hoshiTickerId) {
    clearInterval(window.__hoshiTickerId);
    window.__hoshiTickerId = null;
  }
};

window.__hoshiTick = function() {
  var target = window.__hoshiTarget;
  if (!target) { window.__hoshiStopTicker(); return; }
  target.tickNo = (target.tickNo || 0) + 1;

  var el = document.querySelector(target.selector);
  if (!el) {
    target.missAttempts = (target.missAttempts || 0) + 1;
    if (target.tickNo <= 3) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'diagTickMiss',
        'tickNo': target.tickNo,
        'selector': target.selector,
        'totalCueSpans': document.querySelectorAll('[data-cue-id]').length
      }));
    }
    if (target.missAttempts > 30) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'highlightMiss',
        'selector': target.selector,
        'totalCueSpans': document.querySelectorAll('[data-cue-id]').length,
        'attempts': target.missAttempts
      }));
      window.__hoshiTarget = null;
      window.__hoshiStopTicker();
    }
    return;
  }

  // Element exists. Add highlight class (idempotent).
  if (!el.classList.contains('hoshi-active')) {
    document.querySelectorAll('.hoshi-active').forEach(function(e) {
      e.classList.remove('hoshi-active');
    });
    el.classList.add('hoshi-active');
  }

  var rect = el.getBoundingClientRect();

  // Degenerate rect (ttu still hydrating, or element in collapsed/hidden
  // ancestor). NEVER infer direction from (0,0,0,0) — must retry, not stop.
  var isDegenerate = rect.width === 0 && rect.height === 0 &&
                     rect.left === 0 && rect.top === 0;
  if (isDegenerate) {
    target.staleAttempts = (target.staleAttempts || 0) + 1;
    if (target.staleAttempts > 30) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'highlightStale',
        'selector': target.selector,
        'attempts': target.staleAttempts
      }));
      window.__hoshiTarget = null;
      window.__hoshiStopTicker();
    }
    return;
  }

  var content = document.querySelector('.book-content') ||
                document.querySelector('[class*="book-content"]') ||
                document.scrollingElement || document.documentElement;
  var pageH = content.clientHeight;
  if (!pageH || pageH < 10) {
    // 容器尚未布局，下一 tick 再试。
    return;
  }

  // ttu 分页 stride = clientHeight + column-gap（40px 来自
  // .book-content-container 的 CSS `column-gap: 40px`）。单纯用
  // clientHeight 会导致每页漏掉一段 gap，页边界逐渐偏移。
  var container = content.querySelector('.book-content-container');
  var gap = 40;
  if (container) {
    var gapStr = getComputedStyle(container).columnGap;
    var gapNum = parseFloat(gapStr);
    if (!isNaN(gapNum) && gapNum > 0) gap = gapNum;
  }
  var stride = pageH + gap;

  // 把 cue 的 viewport 坐标换算成 content 内 scroll 坐标。
  var cRect = content.getBoundingClientRect();
  var elTopInContent = rect.top - cRect.top + content.scrollTop;

  // 按 stride 整数倍对齐到 ttu 的视觉页边界。
  var pageIndex = Math.floor(elTopInContent / stride);
  var maxScroll = Math.max(0, content.scrollHeight - pageH);
  var targetScrollTop = Math.max(0, Math.min(pageIndex * stride, maxScroll));

  // 已对齐到目标页：停。
  if (Math.abs(content.scrollTop - targetScrollTop) < 1) {
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }

  target.scrollAttempts = (target.scrollAttempts || 0) + 1;
  if (target.scrollAttempts > 30) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'highlightScrollCap',
      'selector': target.selector,
      'rect': {l: rect.left, t: rect.top, r: rect.right, b: rect.bottom},
      'curScrollTop': content.scrollTop,
      'targetScrollTop': targetScrollTop
    }));
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }

  if (!target.loggedFirstScroll) {
    target.loggedFirstScroll = true;
    console.log(JSON.stringify({
      'hibiki-message-type': 'highlightScrollStart',
      'selector': target.selector,
      'rect': {l: rect.left, t: rect.top, r: rect.right, b: rect.bottom},
      'elTopInContent': elTopInContent,
      'pageH': pageH,
      'gap': gap,
      'stride': stride,
      'pageIndex': pageIndex,
      'targetScrollTop': targetScrollTop,
      'contentScrollTop': content.scrollTop,
      'contentScrollHeight': content.scrollHeight
    }));
  }

  var beforeWrite = content.scrollTop;
  content.scrollTop = targetScrollTop;
  var afterWrite = content.scrollTop;

  // Diagnostic: does the write stick? Svelte store override / read-only
  // container shows up as afterWrite !== targetScrollTop on first write.
  // Also log tickNo to spot Svelte yanking us back on subsequent ticks.
  if (target.scrollAttempts <= 4) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'diagScrollWrite',
      'tickNo': target.tickNo,
      'attempt': target.scrollAttempts,
      'before': beforeWrite,
      'wanted': targetScrollTop,
      'afterImmediate': afterWrite,
      'stuck': Math.abs(afterWrite - targetScrollTop) < 1
    }));
  }
};

window.__hoshiHighlight = function(selector) {
  console.log(JSON.stringify({
    'hibiki-message-type': 'diagHighlightEntry',
    'selector': selector || '',
    'tickerRunning': !!window.__hoshiTickerId,
    'hasBookContent': !!document.querySelector('.book-content')
  }));
  if (!selector) {
    document.querySelectorAll('.hoshi-active').forEach(function(e) {
      e.classList.remove('hoshi-active');
    });
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }
  // Replace pending target. Old ticker (if running) will pick up the new
  // selector on its next tick — no double loops fighting over page state.
  window.__hoshiTarget = {
    selector: selector, missAttempts: 0, staleAttempts: 0, scrollAttempts: 0
  };
  if (!window.__hoshiTickerId) {
    window.__hoshiTickerId = setInterval(
      window.__hoshiTick, window.__hoshiTickIntervalMs);
  }
  // Run once immediately so single-page case doesn't wait 280ms.
  window.__hoshiTick();
};
''';

  /// Sasayaki 路径的辅助 JS：
  ///
  /// - `__hoshiLoadSasayakiRefs(ttuBookId)`：从 ttu IndexedDB 读 `sections` +
  ///   `elementHtml`，缓存 `sectionIndex → reference` 和每个 section 的
  ///   **归一化文本长度**（以及累计起点）。ttu 在渲染时会剥掉 section
  ///   原始 id，所以我们放弃"找章节根"这条路，改为用"整本书归一化偏移"
  ///   在 `.book-content-container` 里定位。
  /// - `__hoshiIsSkippable(code)`：镜像 Dart 的 `EpubSrtMatcher._isSkippable`
  ///   归一化规则（空白 / ASCII 标点 / CJK 标点），大写 ASCII 仍计数一次。
  /// - `__hoshiUnwrapSasayaki()`：拆掉上一次 Sasayaki 高亮包裹的 span。
  /// - `__hoshiHighlightSasayaki(s, ns, ne)`：把 (sectionIndex, normChar*)
  ///   换算成全书归一化全局偏移 → 在 `.book-content-container` 里按归一化
  ///   字符数走 text node 找到 Range → 包 `span.hoshi-active` → 触发 ticker
  ///   滚动。
  ///
  /// 与字幕 EPUB 路径（`[data-cue-id]`）互不冲突：入口在 Dart 侧的
  /// [highlight] 根据 `textFragmentId` 前缀分派。
  static const String _sasayakiFn = '''
window.__hoshiSasayakiRefs = window.__hoshiSasayakiRefs || null;
window.__hoshiSasayakiSectionStarts = window.__hoshiSasayakiSectionStarts || null;

window.__hoshiLoadSasayakiRefs = function(ttuBookId) {
  try {
    var req = indexedDB.open('books');
    req.onsuccess = function(ev) {
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

        // 每段正文归一化字符数 —— 复用 DOMParser 从原始 elementHtml 中按
        // section.reference 取元素的 textContent 再数字符。必须和 Dart 侧
        // EpubSrtMatcher._buildIndex 的累加方式严格一致，否则累计起点
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

        function stripRubyText(el) {
          var clone = el.cloneNode(true);
          var rts = clone.querySelectorAll('rt, rp');
          for (var j = 0; j < rts.length; j++) rts[j].parentNode.removeChild(rts[j]);
          return clone.textContent || '';
        }

        var refs = [];
        var starts = [];
        var cumulative = 0;
        for (var i = 0; i < sections.length; i++) {
          var ref = (sections[i] && sections[i].reference) || '';
          refs.push(ref);
          starts.push(cumulative);
          var el = ref ? doc.getElementById(ref) : null;
          var text = el ? stripRubyText(el) : '';
          cumulative += normLen(text);
        }
        window.__hoshiSasayakiRefs = refs;
        window.__hoshiSasayakiSectionStarts = starts;
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsReady',
          'count': refs.length,
          'totalNormChars': cumulative,
          'firstStarts': starts.slice(0, 5)
        }));
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
  if (c === 0x20 || c === 0x09 || c === 0x0A || c === 0x0D) return true;
  if (c >= 0x21 && c <= 0x2F) return true;
  if (c >= 0x3A && c <= 0x40) return true;
  if (c >= 0x5B && c <= 0x60) return true;
  if (c >= 0x7B && c <= 0x7E) return true;
  return (
    c === 0x3000 || c === 0x3001 || c === 0x3002 || c === 0x300C ||
    c === 0x300D || c === 0x300E || c === 0x300F || c === 0x301C ||
    c === 0x301D || c === 0x301E || c === 0x301F || c === 0x2026 ||
    c === 0x2014 || c === 0x2015 || c === 0xFF01 || c === 0xFF0C ||
    c === 0xFF0E || c === 0xFF1A || c === 0xFF1B || c === 0xFF1F ||
    c === 0xFF08 || c === 0xFF09 || c === 0xFF0D || c === 0xFF3B ||
    c === 0xFF3D || c === 0xFF5B || c === 0xFF5D
  );
};

window.__hoshiUnwrapSasayaki = function() {
  var spans = document.querySelectorAll('span.hoshi-active');
  for (var i = 0; i < spans.length; i++) {
    var span = spans[i];
    var p = span.parentNode;
    if (!p) continue;
    while (span.firstChild) p.insertBefore(span.firstChild, span);
    p.removeChild(span);
    if (p.normalize) p.normalize();
  }
};

window.__hoshiHighlightSasayaki = function(sectionIndex, normCharStart, normCharEnd) {
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

  // ttu 渲染时剥掉了 section 原始 id（实测只剩 .book-content-container 一个
  // 容器装全书），所以 (sectionIndex, normChar*) 必须换算成整本书的归一化
  // 全局偏移，再在容器的 text node 上顺序查找。
  var base = starts[sectionIndex];
  var targetStart = base + normCharStart;
  var targetEnd = base + normCharEnd;

  var root = document.querySelector('.book-content-container') ||
             document.querySelector('.book-content');
  if (!root) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiContainerMissing'
    }));
    return;
  }

  // ttu 实测默认停在封面：`.book-content-container` 只装封面 SVG，正文
  // 要用户点进去才挂载。这时 TreeWalker 找不到任何 text，每条 cue 都刷
  // 日志没意义。rootTextLen 很小（封面通常 < 50 字）就一次性告知"书还
  // 没挂载"，静默跳过后续 cue 直到用户翻过去。下次出现真正可高亮的
  // 节点时 __hoshiSasayakiNotMountedLogged 被清零。
  var rootTextLen = root.textContent ? root.textContent.length : 0;
  if (rootTextLen < 80) {
    if (!window.__hoshiSasayakiNotMountedLogged) {
      window.__hoshiSasayakiNotMountedLogged = true;
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiBookNotMounted',
        'rootTextLen': rootTextLen,
        'hint': 'navigate past cover to mount chapter text'
      }));
    }
    return;
  }
  window.__hoshiSasayakiNotMountedLogged = false;

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

  var span = document.createElement('span');
  span.className = 'hoshi-active';
  try {
    span.appendChild(range.extractContents());
    range.insertNode(span);
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiWrapErr',
      'error': String(e)
    }));
    return;
  }

  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiHighlightOk',
    'sectionIndex': sectionIndex,
    'normCharStart': normCharStart,
    'normCharEnd': normCharEnd
  }));

  // Reuse existing ticker to scroll to the freshly wrapped span.
  window.__hoshiHighlight('.hoshi-active');
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

    // 注入 JS 函数
    await controller.evaluateJavascript(source: _highlightFn);
    await controller.evaluateJavascript(source: _sasayakiFn);
    await controller.evaluateJavascript(source: _ttuApiShimFn);
    await controller.evaluateJavascript(source: _annotateFn);
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
  /// 若 textFragmentId 为空（Sasayaki 匹配失败、且不是字幕合成书路径），
  /// 视为"无可用定位"：只清一次高亮，不再每 tick 刷 `[data-cue-id]` 回落。
  static Future<void> highlight(
    InAppWebViewController controller, {
    AudioCue? cue,
  }) async {
    if (cue == null || cue.textFragmentId.isEmpty) {
      await controller.evaluateJavascript(source: '__hoshiHighlight("");');
      return;
    }
    final String raw = cue.textFragmentId;
    final SasayakiFragment? frag = SasayakiMatchCodec.tryDecode(raw);
    if (frag != null) {
      await controller.evaluateJavascript(
        source: '__hoshiHighlightSasayaki(${frag.sectionIndex}, '
            '${frag.normCharStart}, ${frag.normCharEnd});',
      );
      return;
    }
    await controller.evaluateJavascript(
      source: '__hoshiHighlight(${jsonEncode(raw)});',
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
