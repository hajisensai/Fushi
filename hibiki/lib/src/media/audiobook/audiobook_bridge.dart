import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import 'package:fushi/i18n/strings.g.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/utils/misc/hibiki_color.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// WebView ↔ Flutter 双向通道，用于有声书句子高亮和点击跳转。
///
/// fushiReader 架构：不再依赖 ttu IndexedDB / __ttu* JS API，
/// 改用 window.fushiReader (pagination_scripts) + flutter_inappwebview.callHandler。
class AudiobookBridge {
  AudiobookBridge._();

  // ── JS / CSS ────────────────────────────────────────────────────────────────

  static String _buildCss(Color highlightColor) {
    final int r = (highlightColor.r * 255.0).round().clamp(0, 255);
    final int g = (highlightColor.g * 255.0).round().clamp(0, 255);
    final int b = (highlightColor.b * 255.0).round().clamp(0, 255);
    final double a = highlightColor.a;
    final double hoverA = (a * 0.4).clamp(0.0, 1.0);
    return '''
.fushi-active {
  background: rgba($r, $g, $b, $a);
  border-radius: 2px;
  transition: background 0.15s ease;
}
[data-fushi-sid], [data-cue-id] {
  cursor: pointer;
}
[data-fushi-sid]:hover, [data-cue-id]:hover {
  background: rgba($r, $g, $b, $hoverA);
  border-radius: 2px;
}
''';
  }

  /// 高亮 + 图片暂停检测（cue 推进锚点间 DOM 判定，绕开 IntersectionObserver 视口
  /// 可见性 —— 阅读器多栏 overflow:hidden scrollLeft 离散翻页会把整页插图一帧跳过，
  /// IO 永不达阈值，故历史上图片暂停一直无效，见 BUG-007）。
  static const String _highlightFn = '''
window.__fushiImageBetween = function(prev, el) {
  if (!prev || !el || prev === el || !document.contains(prev)) return null;
  var a = prev, b = el;
  if (prev.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING) {
    a = el; b = prev;
  }
  var media = document.querySelectorAll('img, svg');
  for (var i = 0; i < media.length; i++) {
    var m = media[i];
    if ((a.compareDocumentPosition(m) & Node.DOCUMENT_POSITION_FOLLOWING) &&
        (b.compareDocumentPosition(m) & (Node.DOCUMENT_POSITION_PRECEDING | Node.DOCUMENT_POSITION_CONTAINED_BY))) {
      return m;
    }
  }
  return null;
};

// TODO-1178 / TODO-1367：揭开「上一句 prev → 当前句 el」区间内音频已读过的插图的防
// 剧透模糊遮罩（blurred 类，CSS filter:blur 盖在 img.block-img.blurred /
// svg.block-img.blurred 上）。与 __fushiImageBetween 的暂停判据平行、不改动它：那个
// 只取第一张图作暂停锚点，本函数遍历区间全部图一次全揭，一次推进跨多图也全揭。
//
// TODO-1367 根因（用户报「遮罩没去掉」）：旧实现只 querySelectorAll('img.blurred') +
// classList.remove，两处漏洞：① 区间内的插图常是 loading=lazy 的离屏懒图，cue 推进跨
// 过它时它还没 load、还没被 _fushiClassifyBlockImg 加上 blurred 类 → 'img.blurred'
// 选择器抓不到 → 随后图片暂停把视口滚到它、它才 load，此刻 _fushiBlurImage 见 key 不在
// 已揭活集 → 补加 blurred → 用户看到「暂停在一张仍然模糊的图上」。② 就算当场揭掉也不
// 持久：章节 (重)载 / 布局切换重跑 _sharedInitImages 会无条件重加 blurred（TODO-1289
// 同款重遮罩）。修法与点击 / 手柄揭开对齐：对区间内每张（含未 load 懒图）登记稳定 reveal
// key 进「本会话已揭开」活集（__fushiMarkImageRevealed，令日后 load 时 _fushiBlurImage
// 跳过遮罩）+ 有 blurred 类当场删除 + 回传 onImageRevealed 让 Dart 会话集持久（重载不再
// 遮罩）。只揭音频已跨过（读到）的图；未读到的保持模糊。仅图片防剧透模糊开启时有效
// （__fushiImageRevealKey 只有 blurImages 才注入）；关闭时无 blurred 类 / 无 key 机制，
// 前置守卫直接 no-op，绝不动懒加载 / DOM（向后兼容零副作用）。返回处理的图片数量。
window.__fushiRevealBlurredBetween = function(prev, el) {
  if (!prev || !el || prev === el || !document.contains(prev)) return 0;
  if (typeof window.__fushiImageRevealKey !== 'function') return 0;
  var a = prev, b = el;
  if (prev.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING) {
    a = el; b = prev;
  }
  var media = document.querySelectorAll('img, svg');
  var revealed = 0;
  for (var i = 0; i < media.length; i++) {
    var m = media[i];
    if (m.classList &&
        (m.classList.contains('gaiji') || m.classList.contains('gaiji-line'))) {
      continue;
    }
    if (!((a.compareDocumentPosition(m) & Node.DOCUMENT_POSITION_FOLLOWING) &&
          (b.compareDocumentPosition(m) & (Node.DOCUMENT_POSITION_PRECEDING | Node.DOCUMENT_POSITION_CONTAINED_BY)))) {
      continue;
    }
    var key = window.__fushiImageRevealKey(m);
    if (key && typeof window.__fushiMarkImageRevealed === 'function') {
      window.__fushiMarkImageRevealed(key);
    }
    if (m.classList && m.classList.contains('blurred')) {
      m.classList.remove('blurred');
    }
    if (key && window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onImageRevealed', key);
    }
    revealed++;
  }
  return revealed;
};

// BUG-898：揭开当前章（文档）内**全部**防剧透模糊图。纯图片章（无 cue，音频跨到它时走
// _pauseThroughImageOnlyChapters → awaitImageChapterPause 停留，不经 __fushiRevealBlurredBetween
// 的 prev→el 区间判定）音频停在模糊图上——用户看到「暂停在一张仍然模糊的图上」。逻辑与
// __fushiRevealBlurredBetween 一致（登记 key 进已揭活集 + 删 blurred 类 + 回传 onImageRevealed
// 持久化），只是不限区间、揭整章。仅 blurImages 开时 __fushiImageRevealKey 存在，否则前置
// 守卫 no-op（无 blurred 类 / 无 key 机制，向后兼容零副作用）。返回处理的图片数。
window.__fushiRevealAllBlurred = function() {
  if (typeof window.__fushiImageRevealKey !== 'function') return 0;
  var media = document.querySelectorAll('img, svg');
  var revealed = 0;
  for (var i = 0; i < media.length; i++) {
    var m = media[i];
    if (m.classList &&
        (m.classList.contains('gaiji') || m.classList.contains('gaiji-line'))) {
      continue;
    }
    var key = window.__fushiImageRevealKey(m);
    if (key && typeof window.__fushiMarkImageRevealed === 'function') {
      window.__fushiMarkImageRevealed(key);
    }
    if (m.classList && m.classList.contains('blurred')) {
      m.classList.remove('blurred');
    }
    if (key && window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onImageRevealed', key);
    }
    revealed++;
  }
  return revealed;
};

window.__fushiRevealTarget = function(t) {
  if (!t) return;
  var r = window.fushiReader;
  // 分页模式 fushiReader 没有 scrollToTarget、且 body overflow:hidden 下原生
  // scrollIntoView 不滚动；reader 的页对齐 reveal 原语是 scrollToRange（连续模式
  // 走 revealElement→scrollToTarget）。用 selectNode(t) 取元素自身盒，对 img/svg/
  // 文本都成立（selectNodeContents 对空的 img 取不到 rect）。
  if (r && typeof r.scrollToRange === 'function') {
    try {
      var rng = document.createRange();
      rng.selectNode(t);
      r.scrollToRange(rng);
      return;
    } catch (e) {}
  }
  if (r && typeof r.revealElement === 'function') { r.revealElement(t); return; }
  if (r && typeof r.scrollToTarget === 'function') { r.scrollToTarget(t); return; }
  t.scrollIntoView({block: 'center', behavior: 'instant'});
};

// cue 推进核心：把上一句锚点更新到 el；若两锚点之间跨过 img/svg → 通知 Dart 暂停。
// 当 reveal 且 pauseEnabled 为真时把视口滚到那张插图（而非 el），返回 true 表示
// 「已 reveal 图片，调用方不要再 reveal el」。
// onImageDetected 与 reveal/pauseEnabled 无关，跨图就发（设备测试契约；Dart 侧
// triggerImagePause 在 imagePauseSec<=0 时自然 no-op）。
//
// TODO-724：滚图必须受 imagePauseSec(>0) 门控。imagePauseSec=0 时图片暂停关闭，
// 不应把视口无预兆滚到插图——返回 false 让调用方按正常 cue 跟随 reveal el。
// 只有 imagePauseSec>0（图片暂停开启）时才滚到插图，配合 Dart 的暂停让用户看见图。
window.__fushiImagePauseAdvance = function(el, reveal, pauseEnabled) {
  var prev = window.__fushiPrevHighlight;
  var crossed = window.__fushiImageBetween(prev, el);
  window.__fushiPrevHighlight = el;
  // TODO-1178：音频已读到（跨过）的图揭开防剧透模糊。独立于图片暂停：在下面
  // reveal/pauseEnabled 门控之前无条件揭区间内所有 blurred 图；未开图片模糊时
  // 无元素带 blurred 类，remove 天然 no-op，与图片暂停功能解耦、零副作用。
  window.__fushiRevealBlurredBetween(prev, el);
  if (!crossed) return false;
  if (window.flutter_inappwebview) {
    window.flutter_inappwebview.callHandler('onImageDetected');
  }
  if (reveal && pauseEnabled) {
    // TODO-1367：命中的插图若是 loading=lazy 的离屏懒图，此刻尺寸为 0，scrollToRange
    // 滚过去只落到空白流位置、图片暂停时用户看不到图。强制 eager + 触发解码，让 reveal
    // 落到真实图盒、暂停真展示插图。svg 无 loading 语义、不动。
    if (crossed.tagName === 'IMG' &&
        crossed.getAttribute('loading') === 'lazy') {
      crossed.setAttribute('loading', 'eager');
      if (typeof crossed.decode === 'function') {
        try { crossed.decode(); } catch (e) {}
      }
    }
    window.__fushiRevealTarget(crossed);
    return true;
  }
  return false;
};

window.__fushiHighlight = function(selector, reveal, pauseEnabled) {
  if (reveal === undefined) reveal = true;
  document.querySelectorAll('.fushi-active').forEach(function(e) {
    e.classList.remove('fushi-active');
  });
  if (!selector) { window.__fushiPrevHighlight = null; return; }
  var el = document.querySelector(selector);
  if (!el) return;
  var revealedImage = window.__fushiImagePauseAdvance(el, reveal, pauseEnabled);
  el.classList.add('fushi-active');
  if (reveal && !revealedImage) {
    window.__fushiRevealTarget(el);
  }
};

// TODO-724：跳章 / 位置恢复完成后由 Dart 调用，重置 cue 推进锚点。
// 否则恢复到中段后首次 cue 推进时 prev 仍指向很早的元素，
// __fushiImageBetween 会跨越中间所有插图、误把视口 reveal 到一张远处的图。
window.__fushiResetPrevHighlight = function() {
  window.__fushiPrevHighlight = null;
};
''';

  /// SRT cue 点击事件：委托事件监听 [data-cue-id]，通过 callHandler 通知 Dart。
  static const String _cueClickFn = '''
(function() {
  if (window.__fushiCueClickBound) return;
  window.__fushiCueClickBound = true;
  document.addEventListener('click', function(e) {
    var sel = window.getSelection();
    if (sel && !sel.isCollapsed) return;
    var el = e.target.closest('[data-cue-id]');
    if (!el) return;
    var id = parseInt(el.dataset.cueId, 10);
    if (isNaN(id) || id < 0) return;
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onCueTap', id);
    }
  });
})();
''';

  /// Sasayaki 句子高亮 + 点击事件。
  ///
  /// `__fushiIsSkippable` 保留 — 归一化偏移计算需要它。
  /// 删除了 `__fushiLoadSasayakiRefs`（不再依赖 ttu IndexedDB）。
  /// cue 应用改为调用 `window.fushiReader.applySasayakiCues()`。
  static const String _sentenceAudioFn = '''
window.__fushiIsSkippable = function(c) {
  if (c >= 0x30 && c <= 0x39) return false;
  if (c >= 0x41 && c <= 0x5A) return false;
  if (c >= 0x61 && c <= 0x7A) return false;
  if (c === 0x3005 || c === 0x3006 || c === 0x3007) return false;
  if (c >= 0x3041 && c <= 0x3096) return false;
  if (c >= 0x309D && c <= 0x309F) return false;
  if (c >= 0x30A1 && c <= 0x30FA) return false;
  if (c >= 0x30FC && c <= 0x30FF) return false;
  if (c >= 0x3400 && c <= 0x4DBF) return false;
  if (c >= 0x4E00 && c <= 0x9FFF) return false;
  if (c === 0x25CB || c === 0x25EF) return false;
  if (c === 0x303B) return false;
  if (c >= 0x2E80 && c <= 0x2EFF) return false;
  if (c >= 0x2F00 && c <= 0x2FDF) return false;
  if (c >= 0xF900 && c <= 0xFAFF) return false;
  if (c >= 0x20000 && c <= 0x2A6DF) return false;
  if (c >= 0x2A700 && c <= 0x2EBE0) return false;
  if (c >= 0x2F800 && c <= 0x2FA1F) return false;
  if (c >= 0x30000 && c <= 0x323AF) return false;
  if (c >= 0xFF10 && c <= 0xFF19) return false;
  if (c >= 0xFF21 && c <= 0xFF3A) return false;
  if (c >= 0xFF41 && c <= 0xFF5A) return false;
  if (c >= 0xFF66 && c <= 0xFF9D) return false;
  return true;
};

window.__fushiClearSentenceAudioApplied = function() {
  if (window.fushiReader && typeof window.fushiReader.clearSentenceAudioCue === 'function') {
    window.fushiReader.clearSentenceAudioCue();
  }
};

window.__fushiApplySentenceAudioCues = function(sectionIndex, cuesJson) {
  if (!document.body && !document.documentElement) return;
  if (window.fushiReader && typeof window.fushiReader.applySentenceAudioCues === 'function') {
    window.fushiReader.applySentenceAudioCues(cuesJson);
    return;
  }
};

window.__fushiSentenceAudioAnchorEl = function(key) {
  var r = window.fushiReader;
  if (!r) return null;
  // BUG-898 根因：这里原本是 `if(cueRangesMap) {...} else if(cueWrappers) {...}`。
  // 但 __fushiCssHighlightsSupported 在现代 WebView 恒为 true 且 cueRangesMap **从不被
  // 填充**（applySasayakiCues 只 set cueWrappers，无 cueRangesMap.set），于是第一分支恒
  // 进入、`ranges` 恒 undefined、直接 return null——cueWrappers 兜底被 `else` 永久跳过。
  // 结果 anchor 恒为 null → __fushiHighlightSasayakiCueById 的 `if(anchor)` 守卫使
  // __fushiImagePauseAdvance 永不调用 → 有声书跨图既不暂停也不揭遮罩（用户报「章节正文里
  // 的图被直接无视」）。修法：cueRangesMap 命中不了就**无条件兜底** cueWrappers（拆 else）。
  if (window.__fushiCssHighlightsSupported && r.cueRangesMap && r.cueRangesMap.get) {
    var ranges = r.cueRangesMap.get(key);
    if (ranges && ranges[0]) {
      var n = ranges[0].startContainer;
      return n && n.nodeType === 1 ? n : (n ? n.parentElement : null);
    }
  }
  if (r.cueWrappers && r.cueWrappers.get) {
    var w = r.cueWrappers.get(key);
    if (w && w[0]) return w[0];
  }
  return null;
};

window.__fushiHighlightSentenceAudioCueById = function(key, reveal, pauseEnabled) {
  if (reveal === undefined) reveal = true;
  var r = window.fushiReader;
  if (!r || typeof r.highlightSentenceAudioCue !== 'function') return false;
  var anchor = window.__fushiSentenceAudioAnchorEl(key);
  var revealedImage = false;
  if (anchor && typeof window.__fushiImagePauseAdvance === 'function') {
    revealedImage = window.__fushiImagePauseAdvance(anchor, reveal, pauseEnabled);
  }
  // 跨过插图且需 reveal 时：让 reader 只高亮不自动滚（已滚到插图）；否则正常 reveal。
  r.highlightSentenceAudioCue(key, revealedImage ? false : reveal);
  return true;
};
''';

  /// 章节导航 — 通过 flutter_inappwebview.callHandler 请求 Dart 侧跳章。
  static const String _chapterNavFn = '''
window.__sentenceAudioAutoNav = window.__sentenceAudioAutoNav || false;

window.__sentenceAudioRequestNav = async function(n) {
  window.__sentenceAudioAutoNav = true;
  try {
    if (window.flutter_inappwebview) {
      await window.flutter_inappwebview.callHandler('onChapterNavigationRequested', n);
    }
  } catch (e) {
    console.error('[hoshi] chapter nav error: ' + e);
  } finally {
    queueMicrotask(function() { window.__sentenceAudioAutoNav = false; });
  }
};
''';

  /// 自动句子标注函数：按日文句末标点分割文本节点，包裹 data-fushi-sid span。
  static const String _annotateFn = '''
window.__fushiAnnotate = function(chapterHref) {
  if (document.__fushiAnnotated) return;
  document.__fushiAnnotated = true;

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
        span.dataset.fushiSid = String(sidCounter++);
        span.dataset.fushiChapter = chapterHref;
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

};
''';

  // ── 公开 API ───────────────────────────────────────────────────────────────

  /// 向 WebView 注入 CSS 样式和 JS 函数。
  static Future<void> inject(
    InAppWebViewController controller, {
    Color primaryColor = FushiColor.defaultHighlightYellow,
  }) async {
    final String css = _buildCss(primaryColor);
    final String cssJsonStr = jsonEncode(css);
    await controller.evaluateJavascript(source: '''
(function() {
  var existing = document.getElementById('__fushi_audio_css');
  if (existing) existing.remove();
  var s = document.createElement('style');
  s.id = '__fushi_audio_css';
  s.textContent = $cssJsonStr;
  var parent = document.head || document.documentElement || document.body;
  if (parent) {
    parent.appendChild(s);
  }
})();
''');

    await controller.evaluateJavascript(source: _highlightFn);
    await controller.evaluateJavascript(source: _cueClickFn);
    await controller.evaluateJavascript(source: _sentenceAudioFn);
    await controller.evaluateJavascript(source: _chapterNavFn);
    await controller.evaluateJavascript(source: _annotateFn);
  }

  /// 高亮 [cue] 对应的句子。
  ///
  /// [cue] 为 null 时清除所有高亮。textFragmentId 以 `sasayaki://` 开头时走
  /// Sasayaki 路径；否则按普通 CSS selector 处理。
  static Future<void> highlight(
    InAppWebViewController controller, {
    AudioCue? cue,
    bool reveal = true,
    bool pauseEnabled = false,
  }) async {
    if (cue == null || cue.textFragmentId.isEmpty) {
      await controller.evaluateJavascript(
        source:
            'if(typeof __fushiHighlight!=="undefined")__fushiHighlight("");',
      );
      return;
    }
    final String raw = cue.textFragmentId;
    final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(raw);
    // BUG-366/TODO-630 诊断：播放期逐句高亮的路径分叉。frag==null（如纯 SRT cue
    // 的 textFragmentId='[data-cue-id=...]'）走普通 __fushiHighlight，完全不碰
    // sasayaki 高亮系统——即使 setup 期建了 range 也不会激活 ::highlight。
    // TODO-724：pauseEnabled = imagePauseSec>0；仅它为真时跨图才滚到插图。
    if (frag != null) {
      await controller.evaluateJavascript(
        source: 'if(typeof __fushiHighlightSentenceAudioCueById!=="undefined")'
            'window.__fushiHighlightSentenceAudioCueById('
            '${jsonEncode(raw)}, $reveal, $pauseEnabled);',
      );
      return;
    }
    await controller.evaluateJavascript(
      source: 'if(typeof __fushiHighlight!=="undefined")'
          '__fushiHighlight(${jsonEncode(raw)}, $reveal, $pauseEnabled);',
    );
  }

  /// 重置 cue 推进锚点（`__fushiPrevHighlight`）。
  ///
  /// TODO-724：跳章 / 位置恢复完成后调用。否则恢复到章节中段后，首次 cue 推进时
  /// `__fushiPrevHighlight` 仍指向很早的元素，`__fushiImageBetween` 会跨越中间
  /// 所有插图、误把视口 reveal 到一张远处的图。与高亮清空（`__fushiHighlight("")`）
  /// 不同：那是清当前高亮 class，本方法只把推进锚点归零，不动可见高亮。
  static Future<void> resetImagePauseAnchor(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source: 'if(typeof __fushiResetPrevHighlight!=="undefined")'
          '__fushiResetPrevHighlight();',
    );
  }

  /// BUG-898：揭开当前章内全部防剧透模糊图。纯图片章走 [awaitImageChapterPause] 停留、
  /// 不经 `__fushiRevealBlurredBetween`（那要 prev→el 两个 cue 锚点），音频会停在模糊图
  /// 上。停留前调本方法揭遮罩——回传的 key 经 `onImageRevealed` handler 持久化 + 登记
  /// 会话集。`blurImages` 关时 JS 前置守卫 no-op（零副作用）。
  static Future<void> revealAllBlurred(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source: 'if(typeof __fushiRevealAllBlurred!=="undefined")'
          '__fushiRevealAllBlurred();',
    );
  }

  /// 高亮指定 selector。
  static Future<void> highlightSelector(
    InAppWebViewController controller, {
    required String selector,
  }) async {
    await controller.evaluateJavascript(
      source: 'if(typeof __fushiHighlight!=="undefined")'
          '__fushiHighlight(${jsonEncode(selector)});',
    );
  }

  /// 构造传给 WebView 的 sasayaki cue payload。
  ///
  /// 除了匹配时算出的归一化偏移（`start`/`length`，现降级为**提示位置**），
  /// 还带上 cue 自身的原文 `text`：运行时 JS 用它在**实时 DOM** 的归一化文本里
  /// 就近、单调地重新定位高亮，从而摆脱「匹配坐标系（package:html）」与
  /// 「渲染坐标系（浏览器 DOM）」逐字不一致导致的累积偏移（BUG-060）。
  /// 纯函数，可单测。
  ///
  /// BUG-405：reader setup 路径（ReaderHibikiPage._prepareSasayakiCuesJson）也
  /// 复用本函数构造 payload，确保与有声书桥接路径共用同一份必含 text 的契约，
  /// 不再各自手写循环漏字段；因此本函数是正式 API，不再标 @visibleForTesting。
  static List<Map<String, dynamic>> buildSentenceAudioPayload(
    List<AudioCue> cues,
    int sectionIndex,
  ) {
    final List<Map<String, dynamic>> payload = <Map<String, dynamic>>[];
    for (final AudioCue cue in cues) {
      final SubtitleRematchFragment? frag =
          SubtitleRematchCodec.tryDecode(cue.textFragmentId);
      if (frag == null) {
        continue;
      }
      if (frag.sectionIndex != sectionIndex) {
        continue;
      }
      payload.add(<String, dynamic>{
        'id': cue.textFragmentId,
        'start': frag.normCharStart,
        'length': frag.normCharEnd - frag.normCharStart,
        'text': cue.text,
      });
    }
    return payload;
  }

  /// 对齐 iOS Sasayaki 的 applySasayakiCues。
  static Future<void> applySentenceAudioCues(
    InAppWebViewController controller, {
    required int sectionIndex,
    required List<AudioCue> cues,
  }) async {
    final List<Map<String, dynamic>> payload =
        buildSentenceAudioPayload(cues, sectionIndex);
    if (payload.isEmpty) {
      return;
    }
    final String json = jsonEncode(payload);
    await controller.evaluateJavascript(
      source:
          'if(typeof __fushiApplySentenceAudioCues!=="undefined")__fushiApplySentenceAudioCues($sectionIndex,$json);',
    );
  }

  /// 自动标注当前章节的句子。
  static Future<void> annotate(
    InAppWebViewController controller, {
    required String chapterHref,
  }) async {
    await controller.evaluateJavascript(
      source: 'if(typeof __fushiAnnotate!=="undefined")'
          '__fushiAnnotate(${jsonEncode(chapterHref)});',
    );
  }

  /// 请求跳转到指定章节。Dart 侧通过 callHandler 处理。
  static Future<void> requestSectionNav(
    InAppWebViewController controller, {
    required int sectionIndex,
  }) async {
    await controller.evaluateJavascript(
      source: '''
(async function(){
  if (typeof __sentenceAudioRequestNav !== "undefined") {
    await __sentenceAudioRequestNav($sectionIndex);
  } else if (window.flutter_inappwebview) {
    await window.flutter_inappwebview.callHandler('onChapterNavigationRequested', $sectionIndex);
  }
})();
''',
    );
  }

  /// 解析 WebView console 消息。返回 null 表示消息与有声书无关。
  static AudiobookClickEvent? parseMessage(Map<String, dynamic> json) {
    if (json['hibiki-message-type'] != 'seekToSentence') {
      return null;
    }
    final String? sentenceAudioKey = json['sentenceAudioKey'] as String?;
    if (sentenceAudioKey != null && sentenceAudioKey.isNotEmpty) {
      return AudiobookClickEvent(sentenceAudioKey: sentenceAudioKey);
    }
    final String chapter = json['chapter'] as String? ?? '';
    final int sid = (json['sid'] as num?)?.toInt() ?? -1;
    if (sid < 0) {
      return null;
    }
    return AudiobookClickEvent(chapterHref: chapter, sentenceIndex: sid);
  }

  static Future<void> bookmarkCurrentPage(
    InAppWebViewController controller,
  ) async {}

  static Future<TtuReaderSettings> getReaderSettings(
    InAppWebViewController controller,
  ) async {
    return TtuReaderSettings.fromMap(const <String, dynamic>{});
  }

  static Future<void> setReaderSetting(
    InAppWebViewController controller, {
    required String key,
    required Object value,
  }) async {}

  static Future<List<BookSearchResult>> searchBook(
    EpubBook book,
    String query,
  ) async {
    if (query.isEmpty) return const <BookSearchResult>[];

    final List<String> chapterHtmls = List<String>.generate(
      book.chapters.length,
      (i) => book.chapters[i].html,
    );

    return compute(
      _searchIsolate,
      _SearchParams(chapterHtmls: chapterHtmls, query: query),
    );
  }

  /// 通过 fushiReader.calculateProgress() 获取当前位置。
  static Future<ReaderViewportPos?> getViewportNormOffset(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source:
          '(function(){try{if(window.fushiReader){var p=window.fushiReader.calculateProgress();return JSON.stringify({section:0,offset:Math.round(p*10000)});}return "null";}catch(e){return "null";}})()',
    );
    if (raw is! String || raw.isEmpty || raw == 'null') {
      return null;
    }
    try {
      final dynamic json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        return null;
      }
      final int? section = (json['section'] as num?)?.toInt();
      final int? offset = (json['offset'] as num?)?.toInt();
      if (section == null || offset == null || offset < 0) {
        return null;
      }
      return ReaderViewportPos(section: section, offset: offset);
    } catch (e, stack) {
      ErrorLogService.instance.log('AudiobookBridge.viewportPos', e, stack);
      return null;
    }
  }

  /// 通过 fushiReader.restoreProgress() 跳到给定进度。
  static Future<void> scrollToNormOffset(
    InAppWebViewController controller, {
    required int section,
    required int offset,
    int? restoreToken,
  }) async {
    final double progress = offset / 10000.0;
    await controller.evaluateJavascript(
      source:
          '(function(){try{if(window.fushiReader)window.fushiReader.restoreProgress($progress);}catch(e){}})()',
    );
  }

  static Future<({int sectionIndex, int sectionCharOffset})?>
      getReaderCharOffset(
    InAppWebViewController controller,
  ) async {
    return null;
  }

  static Future<void> scrollToTtuCharOffset(
    InAppWebViewController controller, {
    required int section,
    required int ttuCharOffset,
    required int expectedNormOffset,
    required int restoreToken,
  }) async {}

  static Future<List<TtuTocEntry>> fetchToc(
    InAppWebViewController controller,
  ) async {
    return const <TtuTocEntry>[];
  }
}

// ── 搜索 isolate ─────────────────────────────────────────────────────────────

class _SearchParams {
  const _SearchParams({required this.chapterHtmls, required this.query});
  final List<String> chapterHtmls;
  final String query;
}

List<BookSearchResult> _searchIsolate(_SearchParams params) {
  final String query = params.query;
  final String needle = query.toLowerCase();
  const int contextRadius = 30;
  const int maxResults = 500;
  final RegExp collapseWs = RegExp(r'\s+');

  final List<BookSearchResult> results = <BookSearchResult>[];

  for (int i = 0; i < params.chapterHtmls.length; i++) {
    final String domText = _chapterDomText(params.chapterHtmls[i]);
    final String haystack = domText.toLowerCase();
    int start = 0;
    while (true) {
      final int idx = haystack.indexOf(needle, start);
      if (idx < 0) break;

      final int ctxStart = (idx - contextRadius).clamp(0, domText.length);
      final int ctxEnd =
          (idx + query.length + contextRadius).clamp(0, domText.length);
      final String rawCtx = domText.substring(ctxStart, ctxEnd);
      final String rawMatch = domText.substring(idx, idx + query.length);

      // Fold whitespace in context for display, recalculate matchStart.
      final String context = rawCtx.replaceAll(collapseWs, ' ');
      final String matchWord = rawMatch.replaceAll(collapseWs, ' ');
      final int matchStart =
          context.toLowerCase().indexOf(matchWord.toLowerCase());

      results.add(BookSearchResult(
        sectionIndex: i,
        charOffset: idx,
        context: context,
        matchStart: matchStart >= 0 ? matchStart : 0,
      ));

      if (results.length >= maxResults) return results;
      start = idx + 1;
    }
  }

  return results;
}

/// Extract text matching JS TreeWalker output: concatenate text nodes,
/// skip rt/rp content, NO whitespace folding. This produces the same
/// coordinate space as JS scrollToSearchMatch().
String _chapterDomText(String html) {
  final html_dom.Document doc = html_parser.parse(html);
  final html_dom.Element? body = doc.body;
  if (body == null) return '';
  final StringBuffer buf = StringBuffer();
  _collectTextNodes(body, buf);
  return buf.toString();
}

void _collectTextNodes(html_dom.Node node, StringBuffer buf) {
  if (node is html_dom.Element) {
    final String tag = node.localName ?? '';
    if (tag == 'rt' || tag == 'rp') return;
    for (final html_dom.Node child in node.nodes) {
      _collectTextNodes(child, buf);
    }
  } else if (node is html_dom.Text) {
    buf.write(node.text);
  }
}

// ── 数据类 ───────────────────────────────────────────────────────────────────

class TtuTocEntry {
  const TtuTocEntry({
    required this.index,
    required this.label,
    this.parent,
    this.depth = 0,
  });

  final int index;
  final String label;
  final String? parent;
  final int depth;

  bool get isHeader => index < 0;
}

/// Reader 当前视口在全书中的位置。
class ReaderViewportPos {
  const ReaderViewportPos({
    required this.section,
    required this.offset,
    this.ttuCharOffset,
  });
  final int section;
  final int offset;
  final int? ttuCharOffset;

  @override
  String toString() =>
      'ReaderViewportPos(section=$section, offset=$offset, ttu=$ttuCharOffset)';
}

/// ttu 阅读器设定快照（保留类型供现有代码编译）。
class TtuReaderSettings {
  TtuReaderSettings({
    required this.fontSize,
    required this.lineHeight,
    required this.writingMode,
    required this.viewMode,
    required this.theme,
    required this.hideFurigana,
    required this.fontFamilyGroupOne,
    required this.fontFamilyGroupTwo,
  });

  factory TtuReaderSettings.fromMap(Map<String, dynamic> m) {
    return TtuReaderSettings(
      fontSize: (m['fontSize'] as num?)?.toDouble() ?? 20,
      lineHeight: (m['lineHeight'] as num?)?.toDouble() ?? 1.65,
      writingMode: m['writingMode'] as String? ?? 'vertical-rl',
      viewMode: m['viewMode'] as String? ?? 'paginated',
      theme: m['theme'] as String? ?? 'light-theme',
      hideFurigana: m['hideFurigana'] as bool? ?? false,
      fontFamilyGroupOne: m['fontFamilyGroupOne'] as String? ?? 'Noto Serif JP',
      fontFamilyGroupTwo: m['fontFamilyGroupTwo'] as String? ?? 'Noto Sans JP',
    );
  }

  double fontSize;
  double lineHeight;
  String writingMode;
  String viewMode;
  String theme;
  bool hideFurigana;
  String fontFamilyGroupOne;
  String fontFamilyGroupTwo;

  static const List<String> availableThemes = <String>[
    'light-theme',
    'ecru-theme',
    'water-theme',
    'eyecare-theme',
    'gray-theme',
    'dark-theme',
    'black-theme',
  ];

  static Map<String, String> get themeLabels => <String, String>{
        'light-theme': t.reader_theme_light,
        'ecru-theme': t.reader_theme_ecru,
        'water-theme': t.reader_theme_water,
        'eyecare-theme': t.reader_theme_eyecare,
        'gray-theme': t.reader_theme_gray,
        'dark-theme': t.reader_theme_dark,
        'black-theme': t.reader_theme_black,
      };
}

/// 用户在 WebView 中点击有声书句子所产生的事件。
class AudiobookClickEvent {
  const AudiobookClickEvent({
    this.chapterHref = '',
    this.sentenceIndex = -1,
    this.sentenceAudioKey,
  });

  final String chapterHref;
  final int sentenceIndex;
  final String? sentenceAudioKey;
}

class BookSearchResult {
  factory BookSearchResult.fromMap(Map<String, dynamic> m) {
    return BookSearchResult(
      sectionIndex: (m['sectionIndex'] as num).toInt(),
      charOffset: (m['charOffset'] as num).toInt(),
      context: m['context'] as String? ?? '',
      matchStart: (m['matchStart'] as num?)?.toInt() ?? 0,
    );
  }

  const BookSearchResult({
    required this.sectionIndex,
    required this.charOffset,
    required this.context,
    required this.matchStart,
  });

  final int sectionIndex;
  final int charOffset;
  final String context;
  final int matchStart;
}
