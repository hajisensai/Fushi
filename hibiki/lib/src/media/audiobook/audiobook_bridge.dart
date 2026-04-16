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

  /// 高亮函数：移除旧高亮并把目标元素翻页到视口内。
  ///
  /// 直接 set scrollLeft/scrollTop 不可行：ttu 用 Svelte store 跟踪
  /// 当前页索引，每帧把 scroll 同步回它的 state，外部赋值会被覆盖。
  /// 改为复用 ttu 自己的翻页 API（wheel event，即 reader 页注入的
  /// `window.__hibikiTurnPage`），循环翻页直到目标元素进入视口。
  ///
  /// ## 收敛策略：ticker 而非一次性 step 循环
  ///
  /// 旧实现是 `__hoshiHighlight` 调用一次 `step` 循环（最多 12 次翻页）。
  /// 失败原因：
  /// - 章节切换 / IDB 水合时 `querySelector` 可能瞬间返回 null 或
  ///   `getBoundingClientRect` 返回 (0,0,0,0)，被错判为"已在当前页"，
  ///   循环立即退出，用户停在标题页。
  /// - 12 次翻页上限对跨多页跳转不够（手动 TOC 跳章节后追赶失败）。
  ///
  /// 新实现：用 `setInterval` 持续轮询 pending 目标，直到元素就绪且
  /// 进入视口；新 highlight 调用替换 pending 目标，旧 ticker 自动收敛
  /// 到新目标。退路：missing 元素重试上限 30 次（≈ 9s），prev 方向
  /// 翻页上限 30 次（防止跨章节 prev 风暴回到标题页）。
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
  if (typeof window.__hibikiTurnPage !== 'function') {
    if (!target.loggedNoTurnFn) {
      target.loggedNoTurnFn = true;
      console.log(JSON.stringify({
        'hibiki-message-type': 'highlightNoTurnFn',
        'selector': target.selector
      }));
    }
    return;
  }

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

  var vpW = window.innerWidth, vpH = window.innerHeight;
  var cx = (rect.left + rect.right) / 2;
  var cy = (rect.top + rect.bottom) / 2;

  // On current page? Center within viewport.
  if (cx >= 0 && cx <= vpW && cy >= 0 && cy <= vpH) {
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }

  var direction;
  if (cx > vpW) direction = 'next';
  else if (cx < 0) direction = 'prev';
  else if (cy > vpH) direction = 'next';
  else if (cy < 0) direction = 'prev';
  else {
    // Unreachable now (isDegenerate catches (0,0,0,0)); kept as safety.
    console.log(JSON.stringify({
      'hibiki-message-type': 'highlightUnknownDir',
      'selector': target.selector,
      'rect': {l: rect.left, t: rect.top, r: rect.right, b: rect.bottom}
    }));
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }

  // Cap prev turns: avoid cascading into prev chapters / book start
  // when the cue's chapter isn't where we think it is.
  if (direction === 'prev') {
    target.prevTurns = (target.prevTurns || 0) + 1;
    if (target.prevTurns > 30) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'highlightPrevCap',
        'selector': target.selector
      }));
      window.__hoshiTarget = null;
      window.__hoshiStopTicker();
      return;
    }
  }

  if (!target.loggedFirstTurn) {
    target.loggedFirstTurn = true;
    console.log(JSON.stringify({
      'hibiki-message-type': 'highlightFirstTurn',
      'selector': target.selector,
      'direction': direction,
      'rect': {l: rect.left, t: rect.top, r: rect.right, b: rect.bottom},
      'vp': {w: vpW, h: vpH}
    }));
  }
  // 不用 scrollIntoView — 它会把 scroll 停在任意像素，破坏 ttu 分页边界
  // 对齐（顶栏会露出上一页残留字符）。走 wheel → flipPage 才会按 page
  // 高度整数倍 scroll。
  window.__hibikiTurnPage(direction);
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
    selector: selector, missAttempts: 0, staleAttempts: 0, prevTurns: 0
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
