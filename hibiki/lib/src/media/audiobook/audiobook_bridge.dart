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
  /// - `__hoshiLoadSasayakiRefs(ttuBookId)`：从 ttu IndexedDB 读 `sections`，
  ///   缓存 `sectionIndex → reference`（章节根元素 id）到 `__hoshiSasayakiRefs`。
  /// - `__hoshiIsSkippable(code)`：镜像 Dart 的 `EpubSrtMatcher._isSkippable`
  ///   归一化规则（空白 / ASCII 标点 / CJK 标点），大写 ASCII 仍计数一次。
  /// - `__hoshiUnwrapSasayaki()`：拆掉上一次 Sasayaki 高亮包裹的 span。
  /// - `__hoshiHighlightSasayaki(s, ns, ne)`：定位章节元素 → 按归一化偏移
  ///   在 text node 上找到 Range → 包 `span.hoshi-active` → 触发 ticker 滚动。
  ///
  /// 与字幕 EPUB 路径（`[data-cue-id]`）互不冲突：入口在 Dart 侧的
  /// [highlight] 根据 `textFragmentId` 前缀分派。
  static const String _sasayakiFn = '''
window.__hoshiSasayakiRefs = window.__hoshiSasayakiRefs || null;

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
        window.__hoshiSasayakiRefs = sections.map(function(s) {
          return (s && s.reference) || '';
        });
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsReady',
          'count': window.__hoshiSasayakiRefs.length
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
  var refs = window.__hoshiSasayakiRefs;
  if (!refs) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiRefsMissing',
      'sectionIndex': sectionIndex
    }));
    return;
  }
  if (sectionIndex < 0 || sectionIndex >= refs.length) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiNoRef',
      'sectionIndex': sectionIndex,
      'total': refs.length
    }));
    return;
  }
  var refId = refs[sectionIndex];
  if (!refId) return;

  // `id` lookup is the fast path (ttu concatenates all sections into one
  // document; section root keeps the original EPUB id). Some builds wrap the
  // section in an extra element — walk common alternatives.
  var root =
    document.getElementById(refId) ||
    document.querySelector('[data-original-id="' + refId + '"]') ||
    document.querySelector('[data-ttu-id="' + refId + '"]') ||
    document.querySelector('[name="' + refId + '"]');

  if (!root) {
    // Diagnostic: sample of what ids actually exist, so we can figure out
    // ttu's real naming convention the first time this runs.
    var idNodes = document.querySelectorAll('[id]');
    var sampleIds = [];
    var ttuLike = [];
    for (var di = 0; di < idNodes.length; di++) {
      var v = idNodes[di].id;
      if (di < 20) sampleIds.push(v);
      if (v && v.indexOf('ttu') === 0 && ttuLike.length < 20) ttuLike.push(v);
    }
    var bookContent = document.querySelector('.book-content');
    var childTags = [];
    if (bookContent) {
      var kids = bookContent.children;
      for (var k = 0; k < Math.min(6, kids.length); k++) {
        childTags.push(kids[k].tagName + '#' + (kids[k].id || '') +
          '.' + (kids[k].className || '').slice(0, 40));
      }
    }
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiSectionMissing',
      'refId': refId,
      'sectionIndex': sectionIndex,
      'totalIdNodes': idNodes.length,
      'sampleIds': sampleIds,
      'ttuLikeIds': ttuLike,
      'bookContentChildren': childTags
    }));
    return;
  }

  // Clear any previous Sasayaki wrap + class-only legacy highlight BEFORE
  // walking, so offsets into text nodes aren't affected by artificial spans.
  window.__hoshiUnwrapSasayaki();
  var legacy = document.querySelectorAll('.hoshi-active');
  for (var li = 0; li < legacy.length; li++) {
    legacy[li].classList.remove('hoshi-active');
  }

  // Walk all text nodes under root (include <rt> — the Dart matcher uses
  // textContent, which includes ruby annotations).
  var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
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
      if (startNode === null && normPos >= normCharStart) {
        startNode = node;
        startOffset = i;
      }
      normPos++;
      if (startNode !== null && normPos >= normCharEnd) {
        endNode = node;
        endOffset = i + 1;
        break;
      }
    }
    if (endNode !== null) break;
  }

  // normCharEnd can exceed section's normalized length when matcher window
  // spilled into the next section. Clamp to last node's end so we still
  // highlight from start through section's tail.
  if (startNode !== null && endNode === null && lastNode !== null) {
    endNode = lastNode;
    endOffset = lastNode.nodeValue ? lastNode.nodeValue.length : 0;
  }

  if (!startNode || !endNode) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiOffsetMissing',
      'refId': refId,
      'normCharStart': normCharStart,
      'normCharEnd': normCharEnd,
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
    await controller.evaluateJavascript(source: _annotateFn);
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
  static Future<void> highlight(
    InAppWebViewController controller, {
    AudioCue? cue,
  }) async {
    if (cue == null) {
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
