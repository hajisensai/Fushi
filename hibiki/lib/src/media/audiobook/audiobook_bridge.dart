import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

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

  var el = document.querySelector(target.selector);
  if (!el) {
    target.missAttempts = (target.missAttempts || 0) + 1;
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

  // 把 cue 的 viewport 坐标换算成 content 内 scroll 坐标。
  var cRect = content.getBoundingClientRect();
  var elTopInContent = rect.top - cRect.top + content.scrollTop;

  // 按 clientHeight 的整数倍对齐——ttu 虽然是连续滚动，但用户期望每次
  // 跳转都显示"一整页"，不能停在任意像素导致上/下露出相邻页残字。
  var pageIndex = Math.floor(elTopInContent / pageH);
  var maxScroll = Math.max(0, content.scrollHeight - pageH);
  var targetScrollTop = Math.max(0, Math.min(pageIndex * pageH, maxScroll));

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
      'pageIndex': pageIndex,
      'targetScrollTop': targetScrollTop,
      'contentScrollTop': content.scrollTop,
      'contentScrollHeight': content.scrollHeight
    }));
  }

  content.scrollTop = targetScrollTop;
};

window.__hoshiHighlight = function(selector) {
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
    await controller.evaluateJavascript(source: _annotateFn);
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
  /// [cue] 为 null 时清除所有高亮。
  static Future<void> highlight(
    InAppWebViewController controller, {
    AudioCue? cue,
  }) async {
    final String selector = cue?.textFragmentId ?? '';
    await controller.evaluateJavascript(
      source: '__hoshiHighlight(${jsonEncode(selector)});',
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
