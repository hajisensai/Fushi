import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import 'package:hibiki/i18n/strings.g.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/utils/misc/Hibiki_color.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// WebView ↔ Flutter 双向通道，用于有声书句子高亮和点击跳转。
///
/// hoshiReader 架构：不再依赖 ttu IndexedDB / __ttu* JS API，
/// 改用 window.hoshiReader (pagination_scripts) + flutter_inappwebview.callHandler。
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
.hoshi-active {
  background: rgba($r, $g, $b, $a);
  border-radius: 2px;
  transition: background 0.15s ease;
}
[data-hoshi-sid], [data-cue-id] {
  cursor: pointer;
}
[data-hoshi-sid]:hover, [data-cue-id]:hover {
  background: rgba($r, $g, $b, $hoverA);
  border-radius: 2px;
}
''';
  }

  /// 高亮函数 — reveal 时委托 hoshiReader.scrollToTarget，fallback scrollIntoView。
  static const String _highlightFn = '''
window.__hoshiHighlight = function(selector, reveal) {
  if (reveal === undefined) reveal = true;
  document.querySelectorAll('.hoshi-active').forEach(function(e) {
    e.classList.remove('hoshi-active');
  });
  if (!selector) return;
  var el = document.querySelector(selector);
  if (el) {
    el.classList.add('hoshi-active');
    if (reveal) {
      if (window.hoshiReader && window.hoshiReader.scrollToTarget) {
        window.hoshiReader.scrollToTarget(el);
      } else {
        el.scrollIntoView({block: 'center', behavior: 'instant'});
      }
    }
  }
};
''';

  /// SRT cue 点击事件：委托事件监听 [data-cue-id]，通过 callHandler 通知 Dart。
  static const String _cueClickFn = '''
(function() {
  if (window.__hoshiCueClickBound) return;
  window.__hoshiCueClickBound = true;
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
  /// `__hoshiIsSkippable` 保留 — 归一化偏移计算需要它。
  /// 删除了 `__hoshiLoadSasayakiRefs`（不再依赖 ttu IndexedDB）。
  /// cue 应用改为调用 `window.hoshiReader.applySasayakiCues()`。
  static const String _sasayakiFn = '''
window.__hoshiIsSkippable = function(c) {
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

window.__hoshiClearSasayakiApplied = function() {
  if (window.hoshiReader && typeof window.hoshiReader.clearSasayakiCue === 'function') {
    window.hoshiReader.clearSasayakiCue();
  }
};

window.__hoshiApplySasayakiCues = function(sectionIndex, cuesJson) {
  if (!document.body && !document.documentElement) return;
  if (window.hoshiReader && typeof window.hoshiReader.applySasayakiCues === 'function') {
    window.hoshiReader.applySasayakiCues(cuesJson);
    return;
  }
};

window.__hoshiHighlightSasayakiCueById = function(key, reveal) {
  if (reveal === undefined) reveal = true;
  if (window.hoshiReader && typeof window.hoshiReader.highlightSasayakiCue === 'function') {
    window.hoshiReader.highlightSasayakiCue(key, reveal);
    return true;
  }
  return false;
};
''';

  /// 章节导航 — 通过 flutter_inappwebview.callHandler 请求 Dart 侧跳章。
  static const String _chapterNavFn = '''
window.__sasayakiAutoNav = window.__sasayakiAutoNav || false;

window.__sasayakiRequestNav = async function(n) {
  window.__sasayakiAutoNav = true;
  try {
    if (window.flutter_inappwebview) {
      await window.flutter_inappwebview.callHandler('onChapterNavigationRequested', n);
    }
  } catch (e) {
    console.error('[hoshi] chapter nav error: ' + e);
  } finally {
    queueMicrotask(function() { window.__sasayakiAutoNav = false; });
  }
};
''';

  /// 图片进入视口检测 — IntersectionObserver 监测 <img> / <svg>，回调 Flutter。
  static const String _imagePauseFn = '''
(function() {
  if (window.__hoshiImageObserver) return;
  var cooldown = false;
  window.__hoshiImageObserver = new IntersectionObserver(function(entries) {
    if (cooldown) return;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].isIntersecting) {
        cooldown = true;
        if (window.flutter_inappwebview) {
          window.flutter_inappwebview.callHandler('onImageDetected');
        }
        setTimeout(function() { cooldown = false; }, 3000);
        break;
      }
    }
  }, { threshold: 0.3 });
  function observe() {
    var imgs = document.querySelectorAll('img, svg');
    for (var j = 0; j < imgs.length; j++) {
      window.__hoshiImageObserver.observe(imgs[j]);
    }
  }
  observe();
  var mo = new MutationObserver(function() { observe(); });
  mo.observe(document.body || document.documentElement, { childList: true, subtree: true });
})();
''';

  /// 自动句子标注函数：按日文句末标点分割文本节点，包裹 data-hoshi-sid span。
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

};
''';

  // ── 公开 API ───────────────────────────────────────────────────────────────

  /// 向 WebView 注入 CSS 样式和 JS 函数。
  static Future<void> inject(
    InAppWebViewController controller, {
    Color primaryColor = HibikiColor.defaultHighlightYellow,
  }) async {
    final String css = _buildCss(primaryColor);
    final String cssJsonStr = jsonEncode(css);
    await controller.evaluateJavascript(source: '''
(function() {
  var existing = document.getElementById('__hoshi_audio_css');
  if (existing) existing.remove();
  var s = document.createElement('style');
  s.id = '__hoshi_audio_css';
  s.textContent = $cssJsonStr;
  var parent = document.head || document.documentElement || document.body;
  if (parent) {
    parent.appendChild(s);
  }
})();
''');

    await controller.evaluateJavascript(source: _highlightFn);
    await controller.evaluateJavascript(source: _cueClickFn);
    await controller.evaluateJavascript(source: _sasayakiFn);
    await controller.evaluateJavascript(source: _chapterNavFn);
    await controller.evaluateJavascript(source: _annotateFn);
    await controller.evaluateJavascript(source: _imagePauseFn);
  }

  /// 高亮 [cue] 对应的句子。
  ///
  /// [cue] 为 null 时清除所有高亮。textFragmentId 以 `sasayaki://` 开头时走
  /// Sasayaki 路径；否则按普通 CSS selector 处理。
  static Future<void> highlight(
    InAppWebViewController controller, {
    AudioCue? cue,
    bool reveal = true,
  }) async {
    if (cue == null || cue.textFragmentId.isEmpty) {
      await controller.evaluateJavascript(
        source:
            'if(typeof __hoshiHighlight!=="undefined")__hoshiHighlight("");',
      );
      return;
    }
    final String raw = cue.textFragmentId;
    final SasayakiFragment? frag = SasayakiMatchCodec.tryDecode(raw);
    if (frag != null) {
      await controller.evaluateJavascript(
        source: 'if(typeof __hoshiHighlightSasayakiCueById!=="undefined")'
            'window.__hoshiHighlightSasayakiCueById('
            '${jsonEncode(raw)}, $reveal);',
      );
      return;
    }
    await controller.evaluateJavascript(
      source: 'if(typeof __hoshiHighlight!=="undefined")'
          '__hoshiHighlight(${jsonEncode(raw)}, $reveal);',
    );
  }

  /// 高亮指定 selector。
  static Future<void> highlightSelector(
    InAppWebViewController controller, {
    required String selector,
  }) async {
    await controller.evaluateJavascript(
      source: 'if(typeof __hoshiHighlight!=="undefined")'
          '__hoshiHighlight(${jsonEncode(selector)});',
    );
  }

  /// 对齐 iOS Sasayaki 的 applySasayakiCues。
  static Future<void> applySasayakiCues(
    InAppWebViewController controller, {
    required int sectionIndex,
    required List<AudioCue> cues,
  }) async {
    final List<Map<String, dynamic>> payload = <Map<String, dynamic>>[];
    for (final AudioCue cue in cues) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
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
      });
    }
    if (payload.isEmpty) {
      return;
    }
    final String json = jsonEncode(payload);
    await controller.evaluateJavascript(
      source:
          'if(typeof __hoshiApplySasayakiCues!=="undefined")__hoshiApplySasayakiCues($sectionIndex,$json);',
    );
  }

  /// 自动标注当前章节的句子。
  static Future<void> annotate(
    InAppWebViewController controller, {
    required String chapterHref,
  }) async {
    await controller.evaluateJavascript(
      source: 'if(typeof __hoshiAnnotate!=="undefined")'
          '__hoshiAnnotate(${jsonEncode(chapterHref)});',
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
  if (typeof __sasayakiRequestNav !== "undefined") {
    await __sasayakiRequestNav($sectionIndex);
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
    final String? sasayakiKey = json['sasayakiKey'] as String?;
    if (sasayakiKey != null && sasayakiKey.isNotEmpty) {
      return AudiobookClickEvent(sasayakiKey: sasayakiKey);
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

  /// 通过 hoshiReader.calculateProgress() 获取当前位置。
  static Future<ReaderViewportPos?> getViewportNormOffset(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source:
          '(function(){try{if(window.hoshiReader){var p=window.hoshiReader.calculateProgress();return JSON.stringify({section:0,offset:Math.round(p*10000)});}return "null";}catch(e){return "null";}})()',
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

  /// 通过 hoshiReader.restoreProgress() 跳到给定进度。
  static Future<void> scrollToNormOffset(
    InAppWebViewController controller, {
    required int section,
    required int offset,
    int? restoreToken,
  }) async {
    final double progress = offset / 10000.0;
    await controller.evaluateJavascript(
      source:
          '(function(){try{if(window.hoshiReader)window.hoshiReader.restoreProgress($progress);}catch(e){}})()',
    );
  }

  static Future<({int sectionIndex, int sectionCharOffset})?> getTtuCharOffset(
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
    'gray-theme',
    'dark-theme',
    'black-theme',
  ];

  static Map<String, String> get themeLabels => <String, String>{
        'light-theme': t.reader_theme_light,
        'ecru-theme': t.reader_theme_ecru,
        'water-theme': t.reader_theme_water,
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
    this.sasayakiKey,
  });

  final String chapterHref;
  final int sentenceIndex;
  final String? sasayakiKey;
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
