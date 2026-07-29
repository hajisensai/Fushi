import 'dart:convert';
import 'dart:ui';

/// TODO-393：阅读器 DOM 里「当前查词句」前后一条上下文句的解析结果。
/// [normOffset]/[normLength] 是整书归一化偏移（有 [window.hoshiReader] 时才有值），
/// 供有声书把这句映射到音频区间；纯阅读时为 null（只合文本）。
class SurroundingSentence {
  const SurroundingSentence({
    required this.sentence,
    this.normOffset,
    this.normLength,
  });

  final String sentence;
  final int? normOffset;
  final int? normLength;
}

class ReaderSelectionScripts {
  ReaderSelectionScripts._();

  /// TODO-956：「收藏句子」的数据契约——选中可见词 ⇒ currentSentence 必非空。
  /// 唯一写点 `lookup.part.dart` 把 `currentSentence` 写成 JS 回传的 [sentence]
  /// （`ReaderSelectionData.sentence`），但某些书籍模式（歌词模式 / TextToEpub
  /// 合成有声书 / 竖排或空段 DOM 使 findParagraph 落到空容器）即便 JS 端已有块级
  /// textContent 兜底，[sentence] 仍可能回空。此时收藏读点（chrome.part.dart
  /// `_toggleFavoriteSentence`）读到空串，误报「未选择句子」。
  ///
  /// 本 helper 是模式无关的下限兜底：能派生出完整句子（[sentence] 非空）就用句子；
  /// 派生不出时退回 [word]（被选中的词本身，由调用方 `data.text.isEmpty` 守卫保证
  /// 非空）。与 JS 块级兜底叠加，彻底消灭「未选择句子」误报。
  static String resolveCurrentSentenceText(String sentence, String word) =>
      sentence.isNotEmpty ? sentence : word;

  /// TODO-851：[fromHover] 区分调用来源——`true` 表示悬停查词（onShiftHover /
  /// onDismissBarrierHover），命中空白时 JS 端**不** fire `onTapEmpty`（只清选区），
  /// 避免悬停扫过正文空白反复 toggle 操作栏导致闪烁；`false`（默认）是真点击路径，
  /// 命中空白仍 fire `onTapEmpty`（保留「点空白隐藏操作栏」行为，向后兼容）。
  static String selectInvocation(
    double x,
    double y,
    int maxLength, {
    bool fromHover = false,
  }) =>
      'window.hoshiSelection.selectText($x, $y, $maxLength, $fromHover)';

  static String highlightInvocation(int count) =>
      'JSON.stringify(window.hoshiSelection.highlightSelection($count))';

  static String clearInvocation() => 'window.hoshiSelection.clearSelection()';

  /// TODO-1317: 移动端「长按拖选」手势 IIFE（注入进阅读器 setup script）。触屏在正文
  /// 长按 [delayMs] 毫秒进入拖选态，拖动经 `window.hoshiSelection.updateRangeSelection`
  /// 扩展 app 自绘选区（CSS Custom Highlight `hoshi-selection`，绝不建立原生选区，
  /// 保住 TODO-1279 触屏无双选区），松手经 `endRangeSelection` 弹选区菜单（复制 / 查词，
  /// 走 `onSelectionMenu`）—— 选区间(可复制)与查词/制卡共存，不再被强制查词；原地未拖动
  /// 退回单击查词（`selectText`，保住慢速点词）。移动 > [slop]px
  /// 未及 [delayMs] 判为滑动/滚动，放弃拖选（长按 vs swipe 消歧）。置全局标志
  /// `window.__hoshiTextSelectDragActive`，翻页（`_gestureEnd`）与边界跨章（`_bEnd`）
  /// 见到即让路，绝不与拖选争同一次触摸（消除拖选后误翻页 / 双查词）。
  ///
  /// 单独一个 IIFE、只挂 document 上的 touch 监听，与图片长按（`onImageLongPress`，
  /// 550ms，仅命中图片才 arm）按命中元素天然互斥；多指触摸（缩放）直接不 arm。
  static String longPressDragGestureScript({
    int delayMs = 500,
    int slop = 10,
    int maxLength = 400,
  }) {
    final int slopSq = slop * slop;
    return '''
(function() {
  var LPS_DELAY = $delayMs;
  var LPS_SLOP_SQ = $slopSq;
  var LPS_MAXLEN = $maxLength;
  var lpsTimer = null;
  var lpsActive = false;
  var lpsStartX = 0, lpsStartY = 0;
  window.__hoshiTextSelectDragActive = false;
  function lpsClearTimer() { if (lpsTimer) { clearTimeout(lpsTimer); lpsTimer = null; } }
  function lpsReset() {
    lpsClearTimer();
    lpsActive = false;
    window.__hoshiTextSelectDragActive = false;
  }
  // Arm only over real matchable text, never over links / form controls / caret
  // ring / block images (those own their own gestures). getCharacterAtPoint is
  // the same hit test the tap path uses, so blank margins never arm.
  function lpsAllowed(target, x, y) {
    var el = target || document.elementFromPoint(x, y);
    if (el && el.closest &&
        el.closest('a[href], img, .block-img-wrapper, input, textarea, select, button, [contenteditable="true"], [data-hoshi-clk], #hoshi-caret-ring, [data-hoshi-sel-handle]')) {
      return false;
    }
    return !!(window.hoshiSelection && window.hoshiSelection.getCharacterAtPoint &&
      window.hoshiSelection.getCharacterAtPoint(x, y));
  }
  document.addEventListener('touchstart', function(e) {
    lpsReset();
    // Only single-finger presses select; a second finger is pinch/zoom.
    if (!e.touches || e.touches.length !== 1) return;
    var t = e.touches[0];
    if (!lpsAllowed(e.target, t.clientX, t.clientY)) return;
    lpsStartX = t.clientX;
    lpsStartY = t.clientY;
    lpsTimer = setTimeout(function() {
      lpsTimer = null;
      if (window.hoshiSelection && window.hoshiSelection.beginRangeSelection &&
          window.hoshiSelection.beginRangeSelection(lpsStartX, lpsStartY)) {
        lpsActive = true;
        // Set BEFORE touchend so tap/swipe (_gestureEnd) and boundary cross-chapter
        // (_bEnd) both bail: the drag-select owns this touch exclusively.
        window.__hoshiTextSelectDragActive = true;
      }
    }, LPS_DELAY);
  }, {passive: true});
  document.addEventListener('touchmove', function(e) {
    if (!e.touches || !e.touches.length) return;
    var t = e.touches[0];
    if (lpsActive) {
      // Own the gesture: block native scroll and extend the app-drawn selection.
      if (e.cancelable) e.preventDefault();
      if (window.hoshiSelection && window.hoshiSelection.updateRangeSelection) {
        window.hoshiSelection.updateRangeSelection(t.clientX, t.clientY);
      }
      return;
    }
    if (lpsTimer) {
      var dx = t.clientX - lpsStartX;
      var dy = t.clientY - lpsStartY;
      // Moved past slop before the long-press fired: it is a scroll/swipe, not a
      // select; drop the arm and let the native scroll & swipe paths own it.
      if ((dx * dx + dy * dy) > LPS_SLOP_SQ) lpsClearTimer();
    }
  }, {passive: false});
  document.addEventListener('touchend', function(e) {
    if (!lpsActive) { lpsClearTimer(); return; }
    if (e.cancelable && e.preventDefault) e.preventDefault();
    var t = (e.changedTouches && e.changedTouches[0]) || null;
    var x = t ? t.clientX : lpsStartX;
    var y = t ? t.clientY : lpsStartY;
    var fired = window.hoshiSelection && window.hoshiSelection.endRangeSelection &&
      window.hoshiSelection.endRangeSelection(x, y);
    if (!fired && window.hoshiSelection && window.hoshiSelection.selectText) {
      // Long-press without a drag: behave exactly like a tap (word lookup),
      // preserving slow-steady-tap word lookup (TODO-971).
      window.hoshiSelection.selectText(x, y, LPS_MAXLEN);
    }
    // Keep __hoshiTextSelectDragActive true until the next touchstart resets it:
    // a trailing compatibility pointerup (order vs touchend varies by WebView)
    // must still see the flag so _gestureEnd bails -> no double lookup.
    lpsClearTimer();
    lpsActive = false;
  }, {passive: false});
  document.addEventListener('touchcancel', function() { lpsReset(); }, {passive: true});
})();''';
  }

  /// BUG-402：取**浏览器原生选区**（`window.getSelection()`）的纯文本，给桌面
  /// Windows 的 Ctrl+C 复制兼容层用。刻意走原生 `getSelection()` 而非
  /// `window.hoshiSelection`（后者是查词选区，是另一套坐标/状态），因为短拖/竖拖
  /// 时原生选区照样建立，与查词逻辑无关（selectstart 在拖动起约 400ms 被
  /// preventDefault 只影响查词高亮路径）。结果由 [nativeSelectionTextFromResult]
  /// 解析。JSON.stringify 让结果稳定为带引号的字符串，便于解析 + 兼容各平台
  /// evaluateJavascript 返回类型差异。
  static String nativeSelectionTextInvocation() =>
      'JSON.stringify(window.getSelection ? window.getSelection().toString() : null)';

  /// 解析 [nativeSelectionTextInvocation] 的结果为选中文本。无选区时 JS 端
  /// `JSON.stringify(null)` 回传字面量 `null` → 空串；有选区回传带引号的 JSON
  /// 字符串（如 `"text"`）→ 解码出文本。Windows WebView2 经 JSON.stringify 回
  /// 这种带引号串；若某平台直接回裸 String（非合法 JSON），原样返回兜底。
  static String nativeSelectionTextFromResult(Object? raw) {
    if (raw == null) return '';
    if (raw is! String) return '';
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    try {
      final Object? decoded = jsonDecode(trimmed);
      // JSON `null` / 非字符串（如数字）→ 无选区，空串。
      return decoded is String ? decoded : '';
    } catch (_) {
      // 不是合法 JSON：当作平台直接回的裸选区文本兜底。
      return raw;
    }
  }

  /// TODO-393：取「当前查词句」前后各 N 句的上下文（制卡「上 N 句 / 下 N 句」用）。
  /// 返回的 JSON 由 [surroundingSentencesFromResult] 解析。[prevCount] / [nextCount]
  /// 是想要的最大句数（实际可能更少，到段首/文首即止）。
  static String surroundingSentencesInvocation(int prevCount, int nextCount) =>
      'JSON.stringify(window.hoshiSelection.getSurroundingSentences('
      '$prevCount, $nextCount))';

  /// 解析 [surroundingSentencesInvocation] 的结果为 `(prev, next)` 两组句子上下文，
  /// 每条带 [sentence] 文本与（可选）整书归一化偏移 [normOffset]/[normLength]
  /// （供有声书裁句子音频区间）。无选区 / 解析失败时返回两个空列表。
  static ({List<SurroundingSentence> prev, List<SurroundingSentence> next})
      surroundingSentencesFromResult(Object? raw) {
    const empty = (
      prev: <SurroundingSentence>[],
      next: <SurroundingSentence>[],
    );
    if (raw == null) return empty;
    try {
      final Object decoded;
      if (raw is String) {
        final String trimmed = raw.trim();
        if (trimmed.isEmpty || trimmed == 'null') return empty;
        decoded = jsonDecode(trimmed) as Object;
      } else {
        decoded = raw;
      }
      if (decoded is! Map) return empty;
      List<SurroundingSentence> parseList(Object? list) {
        if (list is! List) return const <SurroundingSentence>[];
        return <SurroundingSentence>[
          for (final Object? item in list)
            if (item is Map)
              SurroundingSentence(
                sentence: item['sentence']?.toString() ?? '',
                normOffset: (item['normOffset'] as num?)?.toInt(),
                normLength: (item['normLength'] as num?)?.toInt(),
              ),
        ];
      }

      return (
        prev: parseList(decoded['prev']),
        next: parseList(decoded['next']),
      );
    } catch (_) {
      return empty;
    }
  }

  /// TODO-954：取**浏览器原生选区**的句级归一化区间（阅读器右键「导出片段」用）。
  /// 回传 JSON 字段与 onTextSelected 同构（[ReaderSelectionData.fromJson] 直接可解），
  /// 让右键导出复用 tap 路径同一套选区→cue 状态，不另起特例。无选区回传 `null`。
  static String nativeSelectionSentenceRangeInvocation() =>
      'JSON.stringify(window.hoshiSelection.nativeSelectionSentenceRange())';

  /// TODO-1127：取**当前原生选区**内夹带的 EPUB 插图（<img> / 光栅封面 <svg><image>）。
  /// 回传 JSON 数组，每项 `{src, normOffset}`，由 [clipSelectionImagesFromResult] 解析。
  /// 供有声书片段导出把「选区中间的插图」按相对顺序渲进卡片。
  static String nativeSelectionImagesInvocation() =>
      'JSON.stringify(window.hoshiSelection.nativeSelectionImages())';

  /// 解析 [nativeSelectionImagesInvocation] 的结果为选区插图列表：每项 [src]（可交给
  /// 宿主 `_readerImageFileForUrl` 解析成解压目录文件的绝对 URL）+ [normOffset]（该图在
  /// 整书归一化文本坐标里的位置；JS 端 `imageNormOffset` 取不到时回传 null → 这里归一为
  /// `-1`，宿主据此把图兜底挂到最前一段）。无选区 / 无图 / 解析失败 → 空列表。
  static List<({String src, int normOffset})> clipSelectionImagesFromResult(
    Object? raw,
  ) {
    if (raw == null) return const <({String src, int normOffset})>[];
    try {
      final Object decoded;
      if (raw is String) {
        final String trimmed = raw.trim();
        if (trimmed.isEmpty || trimmed == 'null') {
          return const <({String src, int normOffset})>[];
        }
        decoded = jsonDecode(trimmed) as Object;
      } else {
        decoded = raw;
      }
      if (decoded is! List) return const <({String src, int normOffset})>[];
      final List<({String src, int normOffset})> result =
          <({String src, int normOffset})>[];
      for (final Object? item in decoded) {
        if (item is! Map) continue;
        final String src = item['src']?.toString() ?? '';
        if (src.isEmpty) continue;
        final int normOffset = (item['normOffset'] as num?)?.toInt() ?? -1;
        result.add((src: src, normOffset: normOffset));
      }
      return result;
    } catch (_) {
      return const <({String src, int normOffset})>[];
    }
  }

  static bool didSelectNothing(String? result) {
    if (result == null) return true;
    final String trimmed = result.trim().replaceAll('"', '');
    return trimmed.isEmpty || trimmed == 'null';
  }

  static Rect? highlightRectFromResult(Object? raw, {double topOffset = 0}) {
    if (raw == null) return null;
    try {
      final Map<String, dynamic> data;
      if (raw is String) {
        final String trimmed = raw.trim();
        if (trimmed.isEmpty || trimmed == 'null') return null;
        data = jsonDecode(trimmed) as Map<String, dynamic>;
      } else if (raw is Map) {
        data = Map<String, dynamic>.from(raw);
      } else {
        return null;
      }
      final double width = (data['width'] as num).toDouble();
      final double height = (data['height'] as num).toDouble();
      if (width <= 0 || height <= 0) return null;
      return Rect.fromLTWH(
        (data['x'] as num).toDouble(),
        (data['y'] as num).toDouble() + topOffset,
        width,
        height,
      );
    } catch (_) {
      return null;
    }
  }

  static String script() => '<script>\n${source()}\n</script>';

  static String source() => r"""
const CJK_UNIFIED_IDEOGRAPHS_RANGE = [0x4e00, 0x9fff];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_A_RANGE = [0x3400, 0x4dbf];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_B_RANGE = [0x20000, 0x2a6df];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_C_RANGE = [0x2a700, 0x2b73f];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_D_RANGE = [0x2b740, 0x2b81f];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_E_RANGE = [0x2b820, 0x2ceaf];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_F_RANGE = [0x2ceb0, 0x2ebef];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_G_RANGE = [0x30000, 0x3134f];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_H_RANGE = [0x31350, 0x323af];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_I_RANGE = [0x2ebf0, 0x2ee5f];
const CJK_COMPATIBILITY_IDEOGRAPHS_RANGE = [0xf900, 0xfaff];
const CJK_COMPATIBILITY_IDEOGRAPHS_SUPPLEMENT_RANGE = [0x2f800, 0x2fa1f];
const CJK_IDEOGRAPH_RANGES = [
  CJK_UNIFIED_IDEOGRAPHS_RANGE,
  CJK_UNIFIED_IDEOGRAPHS_EXTENSION_A_RANGE,
  CJK_UNIFIED_IDEOGRAPHS_EXTENSION_B_RANGE,
  CJK_UNIFIED_IDEOGRAPHS_EXTENSION_C_RANGE,
  CJK_UNIFIED_IDEOGRAPHS_EXTENSION_D_RANGE,
  CJK_UNIFIED_IDEOGRAPHS_EXTENSION_E_RANGE,
  CJK_UNIFIED_IDEOGRAPHS_EXTENSION_F_RANGE,
  CJK_UNIFIED_IDEOGRAPHS_EXTENSION_G_RANGE,
  CJK_UNIFIED_IDEOGRAPHS_EXTENSION_H_RANGE,
  CJK_UNIFIED_IDEOGRAPHS_EXTENSION_I_RANGE,
  CJK_COMPATIBILITY_IDEOGRAPHS_RANGE,
  CJK_COMPATIBILITY_IDEOGRAPHS_SUPPLEMENT_RANGE,
];
const FULLWIDTH_CHARACTER_RANGES = [
  [0xff10, 0xff19],
  [0xff21, 0xff3a],
  [0xff41, 0xff5a],
  [0xff01, 0xff0f],
  [0xff1a, 0xff1f],
  [0xff3b, 0xff3f],
  [0xff5b, 0xff60],
  [0xffe0, 0xffee],
];
const JAPANESE_RANGES = [
  [0x3040, 0x309f],
  [0x30a0, 0x30ff],
  ...CJK_IDEOGRAPH_RANGES,
  [0xff66, 0xff9f],
  [0x30fb, 0x30fc],
  [0xff61, 0xff65],
  [0x3000, 0x303f],
  ...FULLWIDTH_CHARACTER_RANGES,
];
window.__hoshiCssHighlightsSupported = !!(window.CSS && CSS.highlights && window.Highlight);
window.hoshiSelection = {
  selection: null,
  // TODO-1317: mobile long-press drag-select anchor / whether the finger
  // actually dragged (vs a stationary long-press that falls back to word lookup).
  dragAnchor: null,
  dragMoved: false,
  // TODO-1366: screen anchor of the long-press start + a small pixel slop, so
  // "drag intent" is physical finger movement (even a short drag that stays
  // inside one glyph box) rather than crossing a character boundary. A truly
  // stationary long-press (jitter < slop) still falls through to word lookup
  // (TODO-971). This kills the "short selection is treated as a stationary tap
  // and immediately looks up" special case the user hit.
  dragStartX: 0,
  dragStartY: 0,
  dragMoveSlopSq: 64,
  // TODO-1366: start/end drag handles (touch grips) for the app-drawn selection.
  // Elements are lazily created and parented to <html> (like the caret ring),
  // shown only while a drag-selection is live and adjustable, hidden on clear.
  selectionHandles: null,
  activeHandle: null,
  highlightWrappers: [],
  selectionRubyElements: [],
  scanDelimiters: '。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]・：；:;，,.─\n\r"\'“”‘’«»‹›',
  sentenceDelimiters: '。！？.!?\n\r',
  trailingSentenceChars: '。、！？…‥」』）)】〉》〕｝}］]',
  brackets: {'「':'」', '『': '』', '（':'）', '(':')', '【':'】', '〈':'〉', '《':'》', '〔':'〕', '｛':'｝', '{':'}', '［':'］', '[':']'},
  isCodePointJapanese: function(codePoint) {
    return JAPANESE_RANGES.some(function(range) { return codePoint >= range[0] && codePoint <= range[1]; });
  },
  isScanBoundary: function(char) {
    return /^[\s　]$/.test(char) ||
      this.scanDelimiters.includes(char) ||
      (window.scanNonJapaneseText === false && !this.isCodePointJapanese(char.codePointAt(0)));
  },
  isFurigana: function(node) {
    var el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return !!(el && el.closest('rt, rp'));
  },
  rubyForNode: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return el && el.closest ? el.closest('ruby') : null;
  },
  clearSelectionRubyHighlights: function() {
    if (!this.selectionRubyElements || !this.selectionRubyElements.length) return;
    this.selectionRubyElements.forEach(function(ruby) {
      ruby.classList.remove('hoshi-selection-ruby-active');
    });
    this.selectionRubyElements = [];
  },
  // TODO-956：从选区节点解析「界定句子游走范围」的块级祖先。原实现只认
  // p/.glossary-content/.cue，落在 h1-h6 / div / li / figcaption / blockquote /
  // section / td / dd 里的词解析不到段落 → getSentenceContext 回退到 document.body
  // → TreeWalker 跨兄弟块游走，把块间空白 / 换行 nodeValue 当唯一内容 → 句子 trim 成
  // 空。修：扩到常见块级标签，且永不回退到整个 body：找不到块级祖先时退到选区容器的
  // 父元素（仍把游走限制在词自身的局部块内），保持 createWalker 的边界永远是「词的块」
  // 而非整篇文档。
  BLOCK_SELECTOR: 'p, .glossary-content, .cue, h1, h2, h3, h4, h5, h6, div, li, figcaption, blockquote, section, td, dd',
  findParagraph: function(node) {
    var el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    if (!el) return null;
    var block = el.closest ? el.closest(this.BLOCK_SELECTOR) : null;
    if (block) return block;
    // 没有任何块级祖先：绝不放到整个 body 上游走，退到选区容器的父元素（最坏情况也
    // 只覆盖词所在的直接父节点，绝不跨整篇）。
    return el.parentElement || el;
  },
  createWalker: function(rootNode) {
    var root = rootNode || document.body;
    var self = this;
    return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        if (self.isFurigana(n)) return NodeFilter.FILTER_REJECT;
        // TODO-956：跳过纯空白 / 纯换行文本节点（块间缩进、HTML 排版换行）。它们的
        // nodeValue 全是空白，被当作句子内容会让 rawSentence.trim() 退化成空字符串。
        var v = n.nodeValue;
        if (v != null && /^[\s　]*$/.test(v)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
  },
  inCharRange: function(charRange, x, y, pad) {
    // TODO-916 症状④：字符矩形按 [pad]（默认 0 = 旧的精确包含）外扩一圈再判包含，
    // 消除落在字缝/行距/描边外缘的 miss。pad 仅在 getCaretRange 的逐字符兜底里传入小值，
    // 其它调用点（±1 offset 确认）仍走精确 0。
    pad = pad || 0;
    var rects = charRange.getClientRects();
    if (rects.length) {
      for (var i = 0; i < rects.length; i++) {
        var rect = rects[i];
        if (x >= rect.left - pad && x <= rect.right + pad && y >= rect.top - pad && y <= rect.bottom + pad) return true;
      }
      return false;
    }
    var fallback = charRange.getBoundingClientRect();
    return x >= fallback.left - pad && x <= fallback.right + pad && y >= fallback.top - pad && y <= fallback.bottom + pad;
  },
  // TODO-916 症状④：点到字符矩形中心的距离平方（落在矩形内为 0），供逐字符兜底取最近字符。
  charRangeDistanceSq: function(charRange, x, y) {
    var rect = charRange.getClientRects()[0] || charRange.getBoundingClientRect();
    if (!rect) return Infinity;
    var cx = x < rect.left ? rect.left : (x > rect.right ? rect.right : x);
    var cy = y < rect.top ? rect.top : (y > rect.bottom ? rect.bottom : y);
    var dx = cx - x;
    var dy = cy - y;
    return dx * dx + dy * dy;
  },
  getCaretRange: function(x, y) {
    // BUG-765 续修：`caretPositionFromPoint` 命中「非文本 / 振假名」节点时**不再早退**，
    // 落到下面的 `elementFromPoint`+最近字符几何兜底。根因：拖选区手柄时手指压在手柄
    // div 上，即便 `moveSelectionHandle` 已把手柄 `pointer-events:none`，部分 Android
    // WebView 的 `caretPositionFromPoint` 仍把命中解析到手柄自身 / documentElement
    // （ELEMENT_NODE）→ getCharacterAtPoint 返回 null → 手柄冻结拖不动。旧代码押注
    // 「caretPositionFromPoint 尊重 pointer-events」这一脆弱假设，真机不成立。现在只在
    // 拿到可用文本节点时才走快路，否则统一落到 elementFromPoint（对 pointer-events:none
    // 稳定生效）解析出的底层文本块里做有界的最近字符扫描，横竖排通吃。
    if (document.caretPositionFromPoint) {
      var pos = document.caretPositionFromPoint(x, y);
      // 命中文本节点走快路（振假名文本仍返回，由 getCharacterAtPoint 自己 reject，
      // 保持「点振假名不查词」老行为）；命中非文本节点（遮挡的手柄 div /
      // documentElement）则**不早退**，继续走下面的几何兜底。
      if (pos && pos.offsetNode && pos.offsetNode.nodeType === Node.TEXT_NODE) {
        var caretRange = document.createRange();
        caretRange.setStart(pos.offsetNode, pos.offset);
        caretRange.collapse(true);
        return caretRange;
      }
    }
    var element = document.elementFromPoint(x, y);
    if (!element) return null;
    var container = element.closest('p, div, span, ruby, a') || document.body;
    var walker = this.createWalker(container);
    var range = document.createRange();
    var node;
    // 第一遍：精确包含（旧行为，零回归）。
    while (node = walker.nextNode()) {
      for (var i = 0; i < node.textContent.length; i++) {
        range.setStart(node, i);
        range.setEnd(node, i + 1);
        if (this.inCharRange(range, x, y)) {
          range.collapse(true);
          return range;
        }
      }
    }
    // 第二遍（TODO-916 症状④）：精确全 miss 时回退到「最近字符」——仅当该字符在一个
    // 保守容差内（半行高，约半个字宽）才采纳，避免点空白处误选远字。walker 已 REJECT
    // furigana（rt/rp），故振假名永不被兜底命中；只放宽正文字符命中精度。
    var walker2 = this.createWalker(container);
    var bestNode = null;
    var bestOffset = -1;
    var bestDistSq = Infinity;
    while (node = walker2.nextNode()) {
      for (var j = 0; j < node.textContent.length; j++) {
        range.setStart(node, j);
        range.setEnd(node, j + 1);
        var distSq = this.charRangeDistanceSq(range, x, y);
        if (distSq >= bestDistSq) continue;
        var rect = range.getClientRects()[0] || range.getBoundingClientRect();
        if (!rect) continue;
        var tol = Math.max(6, Math.max(rect.width, rect.height) / 2);
        if (distSq <= tol * tol) {
          bestDistSq = distSq;
          bestNode = node;
          bestOffset = j;
        }
      }
    }
    if (bestNode) {
      range.setStart(bestNode, bestOffset);
      range.collapse(true);
      return range;
    }
    return document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
  },
  getCharacterAtPoint: function(x, y) {
    var range = this.getCaretRange(x, y);
    if (!range) return null;
    var node = range.startContainer;
    if (node.nodeType !== Node.TEXT_NODE || this.isFurigana(node)) return null;
    var text = node.textContent;
    var caret = range.startOffset;
    var offsets = [caret, caret - 1, caret + 1];
    // 第一遍精确确认（旧行为，零回归）；TODO-916 症状④：精确全 miss 时第二遍带容差
    // （半字宽/行高）兜底，消除字缝/行距点不中。scan 边界字（空白/标点）任一遍命中均不查词。
    var pads = [0, 6];
    for (var p = 0; p < pads.length; p++) {
      for (var i = 0; i < offsets.length; i++) {
        var offset = offsets[i];
        if (offset < 0 || offset >= text.length) continue;
        var charRange = document.createRange();
        charRange.setStart(node, offset);
        charRange.setEnd(node, offset + 1);
        if (this.inCharRange(charRange, x, y, pads[p])) {
          if (this.isScanBoundary(text[offset])) return null;
          return { node: node, offset: offset };
        }
      }
    }
    return null;
  },
  getSentenceContext: function(startNode, startOffset) {
    var container = this.findParagraph(startNode) || document.body;
    var walker = this.createWalker(container);
    walker.currentNode = startNode;
    var partsBefore = [];
    var node = startNode;
    var limit = startOffset;
    var sStartNode = startNode;
    var sStartOffset = 0;
    while (node) {
      var text = node.textContent;
      var foundStart = false;
      for (var i = limit - 1; i >= 0; i--) {
        if (this.sentenceDelimiters.includes(text[i])) {
          partsBefore.push(text.slice(i + 1, limit));
          sStartNode = node;
          sStartOffset = i + 1;
          foundStart = true;
          break;
        }
      }
      if (foundStart) break;
      partsBefore.push(text.slice(0, limit));
      sStartNode = node;
      sStartOffset = 0;
      node = walker.previousNode();
      if (node) limit = node.textContent.length;
    }
    walker.currentNode = startNode;
    var partsAfter = [];
    node = startNode;
    var start = startOffset;
    var sEndNode = startNode;
    var sEndOffset = startNode.textContent.length;
    while (node) {
      var afterText = node.textContent;
      var foundEnd = false;
      for (var j = start; j < afterText.length; j++) {
        if (this.sentenceDelimiters.includes(afterText[j])) {
          var end = j + 1;
          while (end < afterText.length && this.trailingSentenceChars.includes(afterText[end])) end++;
          partsAfter.push(afterText.slice(start, end));
          sEndNode = node;
          sEndOffset = end;
          foundEnd = true;
          break;
        }
      }
      if (foundEnd) break;
      partsAfter.push(afterText.slice(start));
      sEndNode = node;
      sEndOffset = afterText.length;
      node = walker.nextNode();
      start = 0;
    }
    var beforeText = partsBefore.reverse().join('');
    var rawSentence = beforeText + partsAfter.join('');
    var trimmedSentence = rawSentence.trim();
    var leadingTrim = rawSentence.length - rawSentence.trimStart().length;
    var sentenceOffset = Math.max(0, beforeText.length - leadingTrim);
    // TODO-956：契约——可见正文里选中的可见词必须产出非空句子。若逐分隔符游走拼出的
    // 句子 trim 后仍为空（例如游走只命中了块间空白 / 换行节点，或被分隔符切成空片段），
    // 退回到「词所在块自身的可见文本」。container 已是 findParagraph 解析出的块级元素
    // （绝不会是整个 body），故这层兜底不会越界跨块。仅当块本身就没有可见文本（纯空白
    // 容器）时才仍返回空字符串——这正是 card_mined_no_sentence_captured 该触发的真空选。
    if (trimmedSentence === '' && container && container.textContent) {
      var blockText = container.textContent.trim();
      if (blockText !== '') {
        trimmedSentence = blockText;
        sentenceOffset = 0;
      }
    }
    return {
      sentence: trimmedSentence,
      sentenceOffset: sentenceOffset,
      sStartNode: sStartNode,
      sStartOffset: sStartOffset,
      sEndNode: sEndNode,
      sEndOffset: sEndOffset
    };
  },
  getSentence: function(startNode, startOffset) {
    return this.getSentenceContext(startNode, startOffset).sentence;
  },
  // TODO-1104：拖选跨句时，让制卡「句子」文本 + 句级归一化区间一起从**起点句首**扩到
  // **终点句尾**，使卡片文本与裁出的句子音频同源、同宽。入参是同一 normalized 文本坐标
  // 系里的两端归一化位置（起点句首 startSStart、终点句尾 endSEnd，均由 getNormalizedOffset
  // 解析），以及两个 getSentenceContext 结果。返回 { offset, length, sStartNode,
  // sStartOffset, sEndNode, sEndOffset, merged }：
  //   * merged=true  → 采纳并区间（起点句首 → 终点句尾）；
  //   * merged=false → 保守回退到起点单句（今天的行为）。
  // 回退条件（never-break 硬约束）：
  //   1) 任一归一化位置为 null（reader 未就绪 / 节点未映射）——无法定坐标；
  //   2) 终点句尾归一化 < 起点句首归一化——两端跨 block 导致区间在 normalized 坐标系里
  //      反向 / 不连续（拖选跨段落时起点句与终点句可能分属不同块，合并会产出错误区间），
  //      保守只取起点单句。
  // start==end（tap 单点 / 未拖动）时两端 getSentenceContext 落同一句，startSStart===
  // endSStart 且 startSEnd===endSEnd → 合并区间与起点单句逐字节相同（下方调用点对此加
  // 断言守卫）。
  spanSentenceRange: function(startContext, endContext, startSStart, endSEnd) {
    // 起点句自身（回退基准 = 今天的行为）。
    var startOnly = {
      offset: startSStart,
      sStartNode: startContext.sStartNode,
      sStartOffset: startContext.sStartOffset,
      sEndNode: startContext.sEndNode,
      sEndOffset: startContext.sEndOffset,
      merged: false
    };
    if (startSStart === null || startSStart === undefined) return startOnly;
    if (endSEnd === null || endSEnd === undefined) return startOnly;
    // 反向 / 不连续（跨 block）：保守回退起点单句，绝不产出错误区间。
    if (endSEnd < startSStart) return startOnly;
    return {
      offset: startSStart,
      length: Math.max(0, endSEnd - startSStart),
      sStartNode: startContext.sStartNode,
      sStartOffset: startContext.sStartOffset,
      sEndNode: endContext.sEndNode,
      sEndOffset: endContext.sEndOffset,
      merged: true
    };
  },
  // TODO-1104：按 document 顺序把 [sStartNode:sStartOffset, sEndNode:sEndOffset) 之间的
  // 文本节点内容拼起来（跳振假名 / 纯空白节点，与 getSentenceContext 同一套 createWalker
  // 边界）。用于拖选跨句合并后取「起点句首→终点句尾」并区间正文。sStartNode===sEndNode
  // 时退化为同节点切片。终点不在起点之后的 walk 可达范围内（跨 block 越界）返回空串，由
  // 调用点决定回退。
  textBetween: function(sStartNode, sStartOffset, sEndNode, sEndOffset) {
    if (sStartNode === sEndNode) {
      return sStartNode.textContent.slice(sStartOffset, sEndOffset);
    }
    var container = this.findParagraph(sStartNode) || document.body;
    var walker = this.createWalker(container);
    walker.currentNode = sStartNode;
    var parts = [];
    var node = sStartNode;
    var reachedEnd = false;
    while (node) {
      var text = node.textContent;
      if (node === sStartNode) {
        parts.push(text.slice(sStartOffset));
      } else if (node === sEndNode) {
        parts.push(text.slice(0, sEndOffset));
        reachedEnd = true;
        break;
      } else {
        parts.push(text);
      }
      node = walker.nextNode();
    }
    if (!reachedEnd) return '';
    return parts.join('');
  },
  // TODO-393：从「当前查词句」往前 / 往后逐句采集上下文（制卡「上 N 句 / 下 N 句」）。
  // 以当前 this.selection 的起点定位当前句边界，再用 getSentenceContext 从「当前句首
  // 的前一个字符」继续往前取上一句、从「当前句尾的后一个字符」往后取下一句，逐句迭代。
  // 每条返回 sentence 文本 + （有 window.hoshiReader 时）整书归一化偏移，供宿主裁句子
  // 音频区间。到段首 / 文首（无更多字符）即止，故实际句数可能少于请求数。
  getSurroundingSentences: function(prevCount, nextCount) {
    var result = { prev: [], next: [] };
    if (!this.selection) return result;
    var self = this;
    var describe = function(ctx) {
      var entry = { sentence: ctx.sentence };
      if (window.hoshiReader) {
        var s = self.getNormalizedOffset(ctx.sStartNode, ctx.sStartOffset);
        var e = self.getNormalizedOffset(ctx.sEndNode, ctx.sEndOffset);
        if (s !== null && e !== null) {
          entry.normOffset = s;
          entry.normLength = Math.max(0, e - s);
        }
      }
      return entry;
    };
    // 当前句边界：从查词选区起点解析。
    var current = this.getSentenceContext(
      this.selection.startNode, this.selection.startOffset);
    // 往前：以「当前句首的前一个位置」作为新起点取上一句，再以它的句首继续。
    var anchorNode = current.sStartNode;
    var anchorOffset = current.sStartOffset;
    for (var i = 0; i < prevCount; i++) {
      var before = this.charBefore(anchorNode, anchorOffset);
      if (!before) break;
      // BUG-934：before.offset 已是「当前句首的前一个字符」（前一句末尾的分隔符 /
      // trailing）。此处必须直接落在该字符上取前一句；若给该偏移再多加 1 会把起点推回当前
      // 句首，getSentenceContext 立刻撞分隔符 → 往后取回当前句自身，导致「前加一句」把当前
      // 句重复采集两遍（与「后加一句」用 after.offset 不加偏移对称）。
      var ctx = this.getSentenceContext(before.node, before.offset);
      if (!ctx.sentence) {
        anchorNode = ctx.sStartNode;
        anchorOffset = ctx.sStartOffset;
        // 空句（纯分隔符段）：跳过它继续往前，避免死循环。
        if (anchorNode === before.node && anchorOffset === before.offset) break;
        continue;
      }
      result.prev.unshift(describe(ctx));
      anchorNode = ctx.sStartNode;
      anchorOffset = ctx.sStartOffset;
    }
    // 往后：以「当前句尾的后一个位置」作为新起点取下一句，再以它的句尾继续。
    anchorNode = current.sEndNode;
    anchorOffset = current.sEndOffset;
    for (var j = 0; j < nextCount; j++) {
      var after = this.charAt(anchorNode, anchorOffset);
      if (!after) break;
      var ctxN = this.getSentenceContext(after.node, after.offset);
      if (!ctxN.sentence) {
        anchorNode = ctxN.sEndNode;
        anchorOffset = ctxN.sEndOffset;
        if (anchorNode === after.node && anchorOffset === after.offset) break;
        continue;
      }
      result.next.push(describe(ctxN));
      anchorNode = ctxN.sEndNode;
      anchorOffset = ctxN.sEndOffset;
    }
    return result;
  },
  // TODO-954：从**浏览器原生选区**（window.getSelection()，长按/拖动框选建立）解析出
  // 句级归一化区间，供阅读器右键「导出片段」在没有查词弹窗（未走 onTextSelected 的
  // tap 路径、_cachedSentenceRange 为空）时也能定位 cue。复用与 tap 路径同一套
  // getSentenceContext + getNormalizedOffset 机制，回传字段与 onTextSelected 同构，
  // 故宿主可填进同样的 _cachedSelectionRange / _cachedSentenceRange 状态后走既有导出链。
  // 无选区 / 选区不在文本节点上 → 返回 null（宿主走空选区兜底 toast）。
  nativeSelectionSentenceRange: function() {
    var sel = window.getSelection ? window.getSelection() : null;
    if (!sel || sel.rangeCount === 0) return null;
    var text = sel.toString();
    if (!text) return null;
    var range = sel.getRangeAt(0);
    var startNode = range.startContainer;
    var startOffset = range.startOffset;
    // 选区起点可能落在元素节点上（如 <p> 的子节点边界）；下钻到其首个文本节点，
    // 与 getNormalizedOffset / getSentenceContext 的「文本节点 + 字符偏移」契约对齐。
    if (startNode.nodeType !== Node.TEXT_NODE) {
      var firstText = this.firstTextNode(startNode);
      if (!firstText) return null;
      startNode = firstText.node;
      startOffset = firstText.offset;
    }
    var endNode = range.endContainer;
    var endOffset = range.endOffset;
    if (endNode.nodeType !== Node.TEXT_NODE) {
      var firstEnd = this.firstTextNode(endNode);
      if (firstEnd) { endNode = firstEnd.node; endOffset = firstEnd.offset; }
      else { endNode = startNode; endOffset = startOffset; }
    }
    var sentenceContext = this.getSentenceContext(startNode, startOffset);
    var normalizedOffset = window.hoshiReader
      ? this.getNormalizedOffset(startNode, startOffset) : null;
    var normalizedLength = null;
    if (normalizedOffset !== null) {
      var normalizedEnd = this.getNormalizedOffset(endNode, endOffset);
      if (normalizedEnd !== null) {
        normalizedLength = Math.max(0, normalizedEnd - normalizedOffset);
      }
    }
    // TODO-1104：拖选跨句时把句级区间 + 卡片正文一起从起点句首扩到终点句尾（文本 / 音频
    // 同源同宽）。start==end（tap / 未拖动，两端在下钻后落同一 (node,offset)）时只算一次
    // 起点句，与今天逐字节相同；否则另在终点算一次句上下文并合并。合并 / 回退判定见
    // spanSentenceRange（跨 block 反向 → 保守回退起点单句）。
    var sentence = sentenceContext.sentence;
    var sentenceOffset = sentenceContext.sentenceOffset;
    var sentenceNormalizedOffset = null;
    var sentenceNormalizedLength = null;
    if (window.hoshiReader) {
      var isDrag = !(startNode === endNode && startOffset === endOffset);
      var endContext = isDrag
        ? this.getSentenceContext(endNode, endOffset) : sentenceContext;
      var snStart = this.getNormalizedOffset(
        sentenceContext.sStartNode, sentenceContext.sStartOffset);
      var snEnd = this.getNormalizedOffset(
        endContext.sEndNode, endContext.sEndOffset);
      var span = this.spanSentenceRange(
        sentenceContext, endContext, snStart, snEnd);
      if (span.offset !== null && span.offset !== undefined) {
        sentenceNormalizedOffset = span.offset;
        if (span.merged) {
          sentenceNormalizedLength = span.length;
          if (isDrag) {
            // 合并成功：卡片正文也取起点句首→终点句尾的并区间正文（与音频同源）。
            // textBetween 越界（跨 block 不连续）返回空串时保守保留起点单句正文。
            var merged = this.textBetween(
              span.sStartNode, span.sStartOffset,
              span.sEndNode, span.sEndOffset).trim();
            if (merged !== '') {
              sentence = merged;
              sentenceOffset = 0;
            }
          }
        } else {
          // 回退：起点单句自身归一化长度（今天的行为）。
          var fbEnd = this.getNormalizedOffset(
            sentenceContext.sEndNode, sentenceContext.sEndOffset);
          if (fbEnd !== null) {
            sentenceNormalizedLength = Math.max(0, fbEnd - span.offset);
          }
        }
      }
    }
    return {
      text: text,
      sentence: sentence,
      normalizedOffset: normalizedOffset,
      normalizedLength: normalizedLength,
      sentenceOffset: sentenceOffset,
      sentenceNormalizedOffset: sentenceNormalizedOffset,
      sentenceNormalizedLength: sentenceNormalizedLength
    };
  },
  // TODO-1127：抽取**当前原生选区**内夹带的 EPUB 插图（<img> 与光栅封面 <svg><image>），
  // 供有声书片段导出把「选区中间的插图」渲进卡片。返回按文档序的数组，每项
  // { src, normOffset }：src 是可交给宿主 _readerImageFileForUrl 解析成解压目录文件的绝对
  // URL（hoshi.local/epub/...），normOffset 是该图在整书归一化文本坐标里的位置（用相邻文本
  // 节点算，供宿主把图挂到相对顺序正确的 cue 段后）。选区无图 / 无原生选区 → 空数组。
  nativeSelectionImages: function() {
    var sel = window.getSelection ? window.getSelection() : null;
    if (!sel || sel.rangeCount === 0) return [];
    var candidates = document.querySelectorAll('img, svg');
    var out = [];
    for (var i = 0; i < candidates.length; i++) {
      var el = candidates[i];
      var inSel = false;
      try {
        inSel = sel.containsNode ? sel.containsNode(el, true) : false;
      } catch (e) {
        inSel = false;
      }
      if (!inSel) continue;
      var src = this.resolveClipImageSrc(el);
      if (!src) continue;
      out.push({ src: src, normOffset: this.imageNormOffset(el) });
    }
    return out;
  },
  // 解析一个图节点的可下载源 URL。<img>（跳过外字 gaiji 内联小图）→ el.src；光栅封面
  // <svg><image xlink:href=..>（BUG-025 先例）→ 内层 <image> 的解析后绝对 href；纯矢量
  // svg（无 <image>）无对应文件 → null（宿主跳过并记日志）。
  resolveClipImageSrc: function(el) {
    var tag = el.tagName ? el.tagName.toLowerCase() : '';
    if (tag === 'img') {
      if (el.classList &&
          (el.classList.contains('gaiji') ||
           el.classList.contains('gaiji-line'))) {
        return null;
      }
      return el.src || el.getAttribute('src') || null;
    }
    if (tag === 'svg') {
      var inner = el.querySelector('image');
      if (!inner) return null;
      var raw = (inner.href && inner.href.baseVal) ||
        inner.getAttribute('xlink:href') || inner.getAttribute('href');
      if (!raw) return null;
      try {
        return new URL(raw, document.baseURI).href;
      } catch (e) {
        return raw;
      }
    }
    return null;
  },
  // 图节点在整书归一化文本坐标里的位置：优先取图**后**第一个正文文本节点的归一化偏移
  // （图排在这句之前），取不到再退到图**前**最后一个文本节点的末端偏移。无 hoshiReader
  // （无归一化映射）时返回 null，宿主兜底挂到最前一段。
  imageNormOffset: function(el) {
    if (!window.hoshiReader) return null;
    var w = this.createWalker(document.body);
    w.currentNode = el;
    var after = w.nextNode();
    if (after) {
      var o = this.getNormalizedOffset(after, 0);
      if (o !== null) return o;
    }
    var w2 = this.createWalker(document.body);
    w2.currentNode = el;
    var before = w2.previousNode();
    if (before) {
      var o2 = this.getNormalizedOffset(before, before.textContent.length);
      if (o2 !== null) return o2;
    }
    return null;
  },
  // 从任意节点下钻到它包含的第一个非空文本节点（含自身），返回 {node, offset:0}。
  firstTextNode: function(node) {
    // TODO-956：下钻首个**含可见文本**的节点。纯空白 / 纯换行文本节点不算正文（其
    // textContent 全是换行或空格），跳过它们；否则导出路径会把这样一个空白节点当选区
    // 起点，解析出的句子游走从空白起锚 → 句子退化成空白。createWalker 已 REJECT 纯空白
    // 节点，但自身是文本节点的入参仍需在此判一次。
    var isVisible = function(text) { return !!text && /[^\s　]/.test(text); };
    if (node.nodeType === Node.TEXT_NODE) {
      return isVisible(node.textContent) ? { node: node, offset: 0 } : null;
    }
    var walker = this.createWalker(node);
    var next = walker.nextNode();
    while (next) {
      if (isVisible(next.textContent)) return { node: next, offset: 0 };
      next = walker.nextNode();
    }
    return null;
  },
  // 返回 (node, offset) 之前一个文本字符的位置（跨文本节点，跳振假名），无则 null。
  // TODO-393 修「后加一句/前退一句跨段无反应」：walker 根用 document.body（不是
  // findParagraph 的当前块），故「上一句」的种子字符能跨 <p>/块级边界回退。句子自身仍
  // 由 getSentenceContext 的 findParagraph 限定在其块内，这里只把「找相邻句起点」放宽到
  // 跨段——与 collectRangeBetween 同一套 document 级 walker（同样 REJECT 振假名/空白节点）。
  charBefore: function(node, offset) {
    if (offset > 0) return { node: node, offset: offset - 1 };
    var walker = this.createWalker(document.body);
    walker.currentNode = node;
    var prev = walker.previousNode();
    while (prev) {
      if (prev.textContent.length > 0) {
        return { node: prev, offset: prev.textContent.length - 1 };
      }
      prev = walker.previousNode();
    }
    return null;
  },
  // 返回 (node, offset) 处（含本位）的下一个有效文本位置，无则 null。
  // TODO-393 修：同 charBefore，walker 根用 document.body 以支持「下一句」跨 <p> 段落取到
  // 下一段首个可见文本节点（旧实现困在 findParagraph 当前块内、段末即 break → 后加一句没反应）。
  charAt: function(node, offset) {
    if (offset < node.textContent.length) return { node: node, offset: offset };
    var walker = this.createWalker(document.body);
    walker.currentNode = node;
    var next = walker.nextNode();
    while (next) {
      if (next.textContent.length > 0) return { node: next, offset: 0 };
      next = walker.nextNode();
    }
    return null;
  },
  selectText: function(x, y, maxLength, fromHover) {
    if (document.elementFromPoint(x, y)?.closest('a')) {
      return null;
    }
    var hit = this.getCharacterAtPoint(x, y);
    if (!hit) {
      this.clearSelection();
      // TODO-851：悬停查词（fromHover）命中空白只清选区，绝不 fire onTapEmpty——
      // 否则鼠标在正文空白移动会反复触发「点空白隐藏操作栏」让操作栏闪烁。
      // 真点击（fromHover falsy）仍 fire，保留点空白隐藏操作栏的旧行为。
      if (!fromHover) {
        window.flutter_inappwebview.callHandler('onTapEmpty');
      }
      return null;
    }
    if (this.selection && hit.node === this.selection.startNode && hit.offset === this.selection.startOffset) {
      // 悬停连续查词（fromHover）命中的还是同一个词：什么都不做，保留当前选区
      // 高亮与弹窗——这是「按住 Shift 一路滑，弹窗跟着光标走」的去重基石。滑过一
      // 个词只查一次，同词内继续移动不重复 fire onTextSelected，不闪、不刷 FFI /
      // 查词历史。真点击（fromHover falsy）保持旧的 toggle 语义：再点同词 = 取消。
      if (fromHover) {
        return null;
      }
      this.clearSelection();
      return null;
    }
    this.clearSelection();
    return this.selectFromPosition(hit.node, hit.offset, maxLength, x, y);
  },
  // Build the dictionary selection starting at (node, offset): expand a
  // non-Japanese hit left to its token start, scan forward up to maxLength
  // characters, compute the sentence + whole-book normalized offsets, and fire
  // onTextSelected. Shared by the coordinate (tap) path and the keyboard/gamepad
  // caret path. x/y are optional — the caret path omits them, in which case the
  // selection rect falls back to the first character's bounding box. The caller
  // is responsible for clearing any prior selection first.
  selectFromPosition: function(node, offset, maxLength, x, y) {
    var startNode = node;
    var startOffset = offset;
    var hitContent = startNode.textContent;
    if (startOffset < hitContent.length && !this.isCodePointJapanese(hitContent.codePointAt(startOffset))) {
      while (startOffset > 0 && !this.isScanBoundary(hitContent[startOffset - 1])) {
        startOffset--;
      }
    }
    var container = this.findParagraph(startNode) || document.body;
    var walker = this.createWalker(container);
    var text = '';
    var scanNode = startNode;
    var scanOffset = startOffset;
    var ranges = [];
    walker.currentNode = scanNode;
    while (text.length < maxLength && scanNode) {
      var content = scanNode.textContent;
      var start = scanOffset;
      while (scanOffset < content.length && text.length < maxLength) {
        var char = content[scanOffset];
        if (this.isScanBoundary(char)) break;
        text += char;
        scanOffset++;
      }
      if (scanOffset > start) ranges.push({ node: scanNode, start: start, end: scanOffset });
      if (scanOffset < content.length || text.length >= maxLength) break;
      scanNode = walker.nextNode();
      scanOffset = 0;
    }
    if (!text) return null;
    this.selection = { startNode: startNode, startOffset: startOffset, ranges: ranges, text: text };
    return this.fireTextSelected(x, y);
  },
  // Build the onTextSelected/onSelectionMenu payload for the current
  // this.selection. Extracted verbatim from selectFromPosition's tail so the
  // tap/word path (fireTextSelected), the TODO-1317 drag-select menu path
  // (fireSelectionMenu) and the drag->lookup path all build the identical payload
  // (text / sentence / rect / normalized offsets) and reuse one downstream
  // dictionary/mining pipeline. Returns null when there is no live selection.
  buildSelectionPayload: function(x, y) {
    if (!this.selection || !this.selection.ranges || !this.selection.ranges.length) return null;
    var startNode = this.selection.startNode;
    var startOffset = this.selection.startOffset;
    var ranges = this.selection.ranges;
    var text = this.selection.text;
    var sentenceContext = this.getSentenceContext(startNode, startOffset);
    // Manga OCR producers may split one visual sentence into several adjacent
    // line/column blocks. The overlay resolves that geometry once and exposes
    // the complete sentence on every participating block. EPUB nodes do not
    // carry this attribute and retain the normal punctuation-based context.
    var startElement = startNode.parentElement;
    var mangaSentenceElement = startElement && startElement.closest
      ? startElement.closest('[data-manga-sentence]') : null;
    var mangaSentence = mangaSentenceElement
      ? mangaSentenceElement.getAttribute('data-manga-sentence') : null;
    var orientationElement = startElement && startElement.closest
      ? startElement.closest('[data-ocr-orientation]') : null;
    var verticalWriting = orientationElement
      ? orientationElement.getAttribute('data-ocr-orientation') === 'vertical'
      : false;
    // Anchor manga popups to the complete reconstructed sentence group rather
    // than the tapped glyph. This places vertical dialogue outside the left or
    // right edge of the bubble and horizontal dialogue above or below its text.
    var mangaGroupRect = null;
    var mangaGroup = mangaSentenceElement
      ? mangaSentenceElement.getAttribute('data-manga-sentence-group') : null;
    var mangaPage = mangaSentenceElement && mangaSentenceElement.closest
      ? mangaSentenceElement.closest('.manga-page') : null;
    if (mangaGroup !== null && mangaPage) {
      var groupBoxes = mangaPage.querySelectorAll(
        '.ocr-box[data-manga-sentence-group]'
      );
      var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
      for (var groupIndex = 0; groupIndex < groupBoxes.length; groupIndex++) {
        var groupBox = groupBoxes[groupIndex];
        if (groupBox.getAttribute('data-manga-sentence-group') !== mangaGroup) {
          continue;
        }
        var groupBoxRect = groupBox.getBoundingClientRect();
        left = Math.min(left, groupBoxRect.left);
        top = Math.min(top, groupBoxRect.top);
        right = Math.max(right, groupBoxRect.right);
        bottom = Math.max(bottom, groupBoxRect.bottom);
      }
      if (Number.isFinite(left) && Number.isFinite(top) &&
          Number.isFinite(right) && Number.isFinite(bottom)) {
        mangaGroupRect = {
          x: left,
          y: top,
          width: Math.max(0, right - left),
          height: Math.max(0, bottom - top)
        };
      }
    }
    var normalizedOffset = window.hoshiReader ? this.getNormalizedOffset(startNode, startOffset) : null;
    var normalizedLength = null;
    if (normalizedOffset !== null && ranges.length > 0) {
      var lastRange = ranges[ranges.length - 1];
      var normalizedEnd = this.getNormalizedOffset(lastRange.node, lastRange.end);
      if (normalizedEnd !== null) normalizedLength = Math.max(0, normalizedEnd - normalizedOffset);
    }
    var sentenceNormalizedOffset = null;
    var sentenceNormalizedLength = null;
    if (window.hoshiReader) {
      var snStart = this.getNormalizedOffset(sentenceContext.sStartNode, sentenceContext.sStartOffset);
      var snEnd = this.getNormalizedOffset(sentenceContext.sEndNode, sentenceContext.sEndOffset);
      if (snStart !== null && snEnd !== null) {
        sentenceNormalizedOffset = snStart;
        sentenceNormalizedLength = Math.max(0, snEnd - snStart);
      }
    }
    return {
      text: text,
      sentence: mangaSentence !== null && mangaSentence !== ''
        ? mangaSentence : sentenceContext.sentence,
      rect: mangaGroupRect || this.getSelectionRect(x, y),
      normalizedOffset: normalizedOffset,
      normalizedLength: normalizedLength,
      sentenceOffset: mangaSentence !== null && mangaSentence !== ''
        ? 0 : sentenceContext.sentenceOffset,
      sentenceNormalizedOffset: sentenceNormalizedOffset,
      sentenceNormalizedLength: sentenceNormalizedLength,
      verticalWriting: verticalWriting
    };
  },
  // Fire onTextSelected for the current this.selection (tap/word lookup path and
  // the caret/keyboard path). Goes straight to the dictionary/mining popup.
  fireTextSelected: function(x, y) {
    var payload = this.buildSelectionPayload(x, y);
    if (!payload) return null;
    window.flutter_inappwebview.callHandler('onTextSelected', JSON.stringify(payload));
    return payload.text;
  },
  // TODO-1317: mobile long-press *drag*-select ends here instead of firing
  // lookup directly. Dart shows a selection menu (Copy / Lookup) so a plain-text
  // range selection (copy) and lookup/mining coexist -- the user is no longer
  // forced into an immediate lookup. this.selection (and its hoshi-selection
  // highlight) is kept so the menu overlays the live selection; Dart clears it on
  // copy/dismiss, or converges it to the match on lookup.
  fireSelectionMenu: function(x, y) {
    var payload = this.buildSelectionPayload(x, y);
    if (!payload) return null;
    window.flutter_inappwebview.callHandler('onSelectionMenu', JSON.stringify(payload));
    return payload.text;
  },
  // -- TODO-1317: mobile long-press drag-select --------------------------------
  // Direction B: keep TODO-1279's `@media (pointer: coarse) user-select:none`
  // (touch never builds a native blue selection -> no double selection) and
  // instead drive the *app-drawn* selection (this.selection + CSS Custom
  // Highlight `hoshi-selection`) from a long-press drag. These never call
  // window.getSelection()/addRange, so no native selection is ever created. On
  // release a real drag hands Dart a selection menu (fireSelectionMenu ->
  // onSelectionMenu) offering Copy / Lookup so plain-text selection (copy) and
  // lookup/mining coexist. A stationary long-press (no drag) falls back to word
  // lookup at the caller so slow-steady taps keep looking up the whole word.
  //
  // Build the ordered per-textnode ranges + concatenated text spanning the two
  // character positions (drag anchor + current point). Endpoints are ordered by
  // document position; the character under the later point is included (+1). The
  // walker skips furigana (rt/rp) and whitespace-only nodes (createWalker), so a
  // cross-paragraph drag yields clean matchable text.
  collectRangeBetween: function(nodeA, offA, nodeB, offB) {
    var startNode, startOffset, endNode, endOffset;
    var before;
    if (nodeA === nodeB) {
      before = offA <= offB;
    } else {
      before = !!(nodeA.compareDocumentPosition(nodeB) & Node.DOCUMENT_POSITION_FOLLOWING);
    }
    if (before) {
      startNode = nodeA; startOffset = offA; endNode = nodeB; endOffset = offB + 1;
    } else {
      startNode = nodeB; startOffset = offB; endNode = nodeA; endOffset = offA + 1;
    }
    var walker = this.createWalker(document.body);
    walker.currentNode = startNode;
    var ranges = [];
    var text = '';
    var node = startNode;
    var from = startOffset;
    // Bound the walk so a broken node relationship can never spin forever.
    var guard = 0;
    while (node && guard++ < 100000) {
      var content = node.textContent;
      var to = (node === endNode) ? Math.min(endOffset, content.length) : content.length;
      if (to > from) {
        ranges.push({ node: node, start: from, end: to });
        text += content.slice(from, to);
      }
      if (node === endNode) break;
      node = walker.nextNode();
      from = 0;
    }
    if (!text) return null;
    return { startNode: startNode, startOffset: startOffset, ranges: ranges, text: text };
  },
  // Render the whole current this.selection via the same highlighter as the tap
  // path. Only re-render per drag frame on the CSS Custom Highlight path (it is
  // DOM-mutation-free); the wrapper fallback (extractContents) mutates the DOM,
  // so it is left to render once post-lookup (highlightSelection from Dart).
  renderSelectionHighlight: function() {
    if (!this.selection || !this.selection.text) return;
    if (window.__hoshiCssHighlightsSupported) {
      this.highlightSelection(this.selection.text.length + 1);
    }
  },
  beginRangeSelection: function(x, y) {
    var el = document.elementFromPoint(x, y);
    if (el && el.closest && el.closest('a')) return false;
    var hit = this.getCharacterAtPoint(x, y);
    if (!hit) return false;
    this.clearSelection();
    this.dragAnchor = { node: hit.node, offset: hit.offset };
    this.dragStartX = x;
    this.dragStartY = y;
    this.dragMoved = false;
    this.updateRangeSelection(x, y);
    return true;
  },
  updateRangeSelection: function(x, y) {
    if (!this.dragAnchor) return null;
    var hit = this.getCharacterAtPoint(x, y);
    // Over a gap/blank while dragging, keep the anchor as the end (no shrink).
    var endNode = hit ? hit.node : this.dragAnchor.node;
    var endOffset = hit ? hit.offset : this.dragAnchor.offset;
    // TODO-1366: drag intent = physical finger travel past a small pixel slop
    // OR crossing into a different glyph. The pixel test makes a short drag that
    // stays within one glyph box still count as a drag (so release stops at the
    // selection state instead of falling through to an immediate word lookup);
    // the glyph-cross test is kept so nothing that used to register as a drag
    // regresses. Truly stationary jitter (< slop, same glyph) stays a stationary
    // long-press -> word lookup (TODO-971).
    var ddx = x - this.dragStartX;
    var ddy = y - this.dragStartY;
    if ((ddx * ddx + ddy * ddy) > this.dragMoveSlopSq) {
      this.dragMoved = true;
    }
    if (hit && (hit.node !== this.dragAnchor.node || hit.offset !== this.dragAnchor.offset)) {
      this.dragMoved = true;
    }
    var built = this.collectRangeBetween(
      this.dragAnchor.node, this.dragAnchor.offset, endNode, endOffset);
    if (!built) return null;
    this.selection = {
      startNode: built.startNode, startOffset: built.startOffset,
      ranges: built.ranges, text: built.text
    };
    this.renderSelectionHighlight();
    return built.text;
  },
  // Finalize the drag: extend to the release point, then present the selection
  // menu (Copy / Lookup) iff the finger actually dragged a range. Returns true
  // when it handled the release (caller does nothing more), false for a
  // stationary long-press (caller falls back to single-word lookup, TODO-971).
  // TODO-1317: a real drag no longer fires lookup directly -- it keeps
  // this.selection (highlight stays up) and hands Dart a menu so a plain-text
  // range selection (copy) and lookup/mining coexist instead of forcing lookup.
  endRangeSelection: function(x, y) {
    var moved = this.dragMoved;
    this.updateRangeSelection(x, y);
    moved = moved || this.dragMoved;
    this.dragAnchor = null;
    this.dragMoved = false;
    if (!moved || !this.selection || !this.selection.text) {
      this.clearSelection();
      return false;
    }
    // TODO-1366: stop at the selection state -- keep the highlight, raise the
    // start/end grips so the range is adjustable, and hand Dart the confirm
    // menu. Lookup only happens when the user confirms it (menu "search").
    this.showSelectionHandles();
    this.fireSelectionMenu(x, y);
    return true;
  },
  // -- TODO-1366: start/end selection handles (touch grips) -------------------
  // The app-drawn selection (this.selection.ranges) has a visual start (first
  // glyph of the first range) and end (last glyph of the last range). Two round
  // touch grips are drawn at those endpoints so the user can adjust the range
  // after a drag-select instead of being forced into an immediate lookup. Drag
  // semantics honour the writing mode via hoshiReader.isVertical(). The grips
  // only ever mutate the app-drawn selection, never the browser's native one, so
  // no double selection is created (TODO-1279).
  _selectionVertical: function() {
    if (window.hoshiReader && typeof window.hoshiReader.isVertical === 'function') {
      return window.hoshiReader.isVertical();
    }
    return window.getComputedStyle(document.body).writingMode === 'vertical-rl';
  },
  // Visual endpoints of the current selection as {startNode, startOffset (first
  // glyph), endNode, endOffset (index of the last glyph = one before range end)}.
  // null when there is no live glyph selection.
  selectionEndpoints: function() {
    if (!this.selection || !this.selection.ranges || !this.selection.ranges.length) {
      return null;
    }
    var first = this.selection.ranges[0];
    var last = this.selection.ranges[this.selection.ranges.length - 1];
    if (last.end <= last.start) return null;
    return {
      startNode: first.node, startOffset: first.start,
      endNode: last.node, endOffset: last.end - 1
    };
  },
  _glyphRect: function(node, offset) {
    var len = 1;
    var cp = node.textContent.codePointAt(offset);
    if (cp !== undefined && cp > 0xffff) len = 2;
    var range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, Math.min(offset + len, node.textContent.length));
    var rects = range.getClientRects();
    for (var i = 0; i < rects.length; i++) {
      if (rects[i].width > 0 && rects[i].height > 0) return rects[i];
    }
    return range.getBoundingClientRect();
  },
  ensureSelectionHandles: function() {
    if (this.selectionHandles && this.selectionHandles.start.isConnected &&
        this.selectionHandles.end.isConnected) {
      return this.selectionHandles;
    }
    var self = this;
    var make = function(which) {
      var el = document.getElementById('hoshi-sel-handle-' + which);
      if (!el) {
        el = document.createElement('div');
        el.id = 'hoshi-sel-handle-' + which;
        el.setAttribute('data-hoshi-sel-handle', which);
        // BUG-765 续：外层是 32×32 透明触控盒（比旧 24px 大，改善抓取；不取更大是因为
        // 1~2 字 CJK 短选区两端相距仅约一个字宽，触控盒过大会几乎完全重叠、反而遮住起
        // 手柄）。命中区大、视觉小；pointer-events:auto + touch-action:none 让它吃掉浏览器
        // 滚动手势并可拖。视觉抓手是内层 18px 实心圆钮，用主题色 var(--hoshi-sel-handle)
        // （reader CSS 从 linkColor 下发，随主题变）+ 白描边（任意背景都可见）+ 单柔和阴
        // 影，去掉旧的刺眼橙色 + 双重发光 box-shadow（用户投诉「难看」）。
        el.style.cssText = 'position:fixed;z-index:2147483645;width:32px;height:32px;' +
          'margin-left:-16px;margin-top:-16px;box-sizing:border-box;' +
          'background:transparent;border:0;' +
          'pointer-events:auto;touch-action:none;display:none;';
        var ball = document.createElement('div');
        ball.setAttribute('data-hoshi-sel-ball', which);
        ball.style.cssText = 'position:absolute;left:50%;top:50%;width:18px;height:18px;' +
          'margin-left:-9px;margin-top:-9px;border-radius:50%;box-sizing:border-box;' +
          'background:var(--hoshi-sel-handle, #3a5fad);' +
          'border:2px solid rgba(255,255,255,0.95);' +
          'box-shadow:0 1px 4px rgba(0,0,0,0.35);pointer-events:none;';
        el.appendChild(ball);
        document.documentElement.appendChild(el);
        self._wireHandle(el, which);
      }
      return el;
    };
    this.selectionHandles = { start: make('start'), end: make('end') };
    return this.selectionHandles;
  },
  _wireHandle: function(el, which) {
    var self = this;
    // stopPropagation keeps the document-level long-press / page-gesture
    // listeners from arming on a grip touch; preventDefault + touch-action:none
    // stop the browser treating the grip drag as a scroll.
    el.addEventListener('touchstart', function(e) {
      if (e.cancelable) e.preventDefault();
      e.stopPropagation();
      self.activeHandle = which;
    }, {passive: false});
    el.addEventListener('touchmove', function(e) {
      if (self.activeHandle !== which) return;
      if (e.cancelable) e.preventDefault();
      e.stopPropagation();
      var t = (e.touches && e.touches[0]) || null;
      if (t) self.moveSelectionHandle(which, t.clientX, t.clientY);
    }, {passive: false});
    el.addEventListener('touchend', function(e) {
      if (self.activeHandle !== which) return;
      if (e.cancelable) e.preventDefault();
      e.stopPropagation();
      self.activeHandle = null;
      var t = (e.changedTouches && e.changedTouches[0]) || null;
      var x = t ? t.clientX : 0;
      var y = t ? t.clientY : 0;
      self.positionSelectionHandles();
      // Re-present the confirm menu at the released grip so lookup/copy/export
      // stay one tap away after an adjustment.
      self.fireSelectionMenu(x, y);
    }, {passive: false});
    el.addEventListener('touchcancel', function() {
      if (self.activeHandle === which) {
        self.activeHandle = null;
        self.positionSelectionHandles();
      }
    }, {passive: true});
  },
  // Drag one grip to (x,y): the other endpoint's glyph is the fixed anchor, the
  // grip's glyph becomes the point under the finger. Rebuild + re-highlight +
  // reposition both grips. No-op over a gap so the range never collapses.
  moveSelectionHandle: function(which, x, y) {
    var eps = this.selectionEndpoints();
    if (!eps) return;
    // The grip div sits directly under the finger (pointer-events:auto, top
    // z-index). A hit-test at the raw finger point resolves elementFromPoint /
    // caretPositionFromPoint to the grip element (an ELEMENT_NODE, not a text
    // node) -> getCharacterAtPoint returns null -> the grip appears frozen and
    // the range never adjusts. Make both grips transparent to hit-testing for
    // the duration of the point resolution so the finger coordinate falls
    // through to the glyph underneath, then restore. No native selection is
    // touched (still app-drawn only).
    var handles = this.selectionHandles;
    var savedStartPe = handles ? handles.start.style.pointerEvents : null;
    var savedEndPe = handles ? handles.end.style.pointerEvents : null;
    if (handles) {
      handles.start.style.pointerEvents = 'none';
      handles.end.style.pointerEvents = 'none';
    }
    var hit = this.getCharacterAtPoint(x, y);
    if (handles) {
      handles.start.style.pointerEvents = savedStartPe || 'auto';
      handles.end.style.pointerEvents = savedEndPe || 'auto';
    }
    if (!hit) return;
    var anchorNode, anchorOffset;
    if (which === 'end') {
      anchorNode = eps.startNode; anchorOffset = eps.startOffset;
    } else {
      anchorNode = eps.endNode; anchorOffset = eps.endOffset;
    }
    var built = this.collectRangeBetween(anchorNode, anchorOffset, hit.node, hit.offset);
    if (!built) return;
    this.selection = {
      startNode: built.startNode, startOffset: built.startOffset,
      ranges: built.ranges, text: built.text
    };
    this.renderSelectionHighlight();
    this.positionSelectionHandles();
  },
  positionSelectionHandles: function() {
    var eps = this.selectionEndpoints();
    if (!eps) { this.hideSelectionHandles(); return; }
    var handles = this.ensureSelectionHandles();
    var vertical = this._selectionVertical();
    var sRect = this._glyphRect(eps.startNode, eps.startOffset);
    var eRect = this._glyphRect(eps.endNode, eps.endOffset);
    var sx, sy, ex, ey;
    // 圆钮离开文字的间隙（约半个钮），让抓手悬在选区外缘、不压住字。
    var GAP = 8;
    if (vertical) {
      // vertical-rl: reading runs top->bottom, columns right->left. Start grip
      // above the first glyph, end grip below the last glyph.
      sx = sRect.left + sRect.width / 2;
      sy = sRect.top - GAP;
      ex = eRect.left + eRect.width / 2;
      ey = eRect.bottom + GAP;
    } else {
      // horizontal: start grip at the lower-left of the first glyph, end grip at
      // the lower-right of the last glyph (below the baseline).
      sx = sRect.left;
      sy = sRect.bottom + GAP;
      ex = eRect.right;
      ey = eRect.bottom + GAP;
    }
    handles.start.style.left = sx + 'px';
    handles.start.style.top = sy + 'px';
    handles.start.style.display = 'block';
    handles.end.style.left = ex + 'px';
    handles.end.style.top = ey + 'px';
    handles.end.style.display = 'block';
  },
  showSelectionHandles: function() {
    this.positionSelectionHandles();
  },
  hideSelectionHandles: function() {
    this.activeHandle = null;
    if (this.selectionHandles) {
      this.selectionHandles.start.style.display = 'none';
      this.selectionHandles.end.style.display = 'none';
    }
  },
  getSelectionRect: function(x, y) {
    if (!this.selection || !this.selection.ranges.length) return null;
    var first = this.selection.ranges[0];
    var range = document.createRange();
    range.setStart(first.node, first.start);
    range.setEnd(first.node, first.start + 1);
    var rects = Array.from(range.getClientRects());
    var rect = rects.find(function(rect) { return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom; }) || range.getBoundingClientRect();
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  },
  highlightSelection: function(charCount) {
    if (!this.selection || !this.selection.ranges.length) return null;
    var trimmedRanges = [];
    var remaining = charCount;
    for (var i = 0; i < this.selection.ranges.length; i++) {
      var r = this.selection.ranges[i];
      if (remaining <= 0) break;
      var end = r.start;
      while (end < r.end && remaining > 0) {
        var char = String.fromCodePoint(r.node.textContent.codePointAt(end));
        end += char.length;
        remaining--;
      }
      trimmedRanges.push({ node: r.node, start: r.start, end: end });
    }
    var bounds = null;
    for (var i = 0; i < trimmedRanges.length; i++) {
      var seg = trimmedRanges[i];
      var bRange = document.createRange();
      bRange.setStart(seg.node, seg.start);
      bRange.setEnd(seg.node, seg.end);
      var rects = bRange.getClientRects();
      for (var j = 0; j < rects.length; j++) {
        var r = rects[j];
        if (!bounds) {
          bounds = { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
        } else {
          if (r.left < bounds.left) bounds.left = r.left;
          if (r.top < bounds.top) bounds.top = r.top;
          if (r.right > bounds.right) bounds.right = r.right;
          if (r.bottom > bounds.bottom) bounds.bottom = r.bottom;
        }
      }
    }
    if (window.__hoshiCssHighlightsSupported) {
      // BUG-110：<ruby> 内的字不放进 ::highlight（竖排下 ::highlight 把 ruby 基字盒
      // 画两遍 → 半透明叠加成深色带遮字），改给 <ruby> 元素加 class 单次绘背景。
      var highlights = [];
      this.clearSelectionRubyHighlights();
      for (var i = 0; i < trimmedRanges.length; i++) {
        var seg = trimmedRanges[i];
        var ruby = this.rubyForNode(seg.node);
        if (ruby) {
          if (this.selectionRubyElements.indexOf(ruby) < 0) {
            ruby.classList.add('hoshi-selection-ruby-active');
            this.selectionRubyElements.push(ruby);
          }
          continue;
        }
        var range = document.createRange();
        range.setStart(seg.node, seg.start);
        range.setEnd(seg.node, seg.end);
        highlights.push(range);
      }
      var selHl = highlights.length ? new Highlight(...highlights) : new Highlight();
      // BUG-125：查词高亮 priority=1，叠在音频(sasayaki, 默认 priority=0)之上；
      // 配合 CSS 里查词用的不透明色，重叠处只显示查词单层（查词优先），无双重高亮。
      selHl.priority = 1;
      CSS.highlights.set('hoshi-selection', selHl);
    } else {
      this.clearHighlightWrappers();
      var range = document.createRange();
      for (var i = trimmedRanges.length - 1; i >= 0; i--) {
        var seg = trimmedRanges[i];
        range.setStart(seg.node, seg.start);
        range.setEnd(seg.node, seg.end);
        var wrapper = document.createElement('span');
        wrapper.className = 'hoshi-dict-highlight';
        wrapper.appendChild(range.extractContents());
        range.insertNode(wrapper);
        this.highlightWrappers.push(wrapper);
      }
      this.highlightWrappers.reverse();
    }
    return bounds ? { x: bounds.left, y: bounds.top, width: bounds.right - bounds.left, height: bounds.bottom - bounds.top } : null;
  },
  getNormalizedOffset: function(targetNode, offset) {
    if (!window.hoshiReader) return null;
    var base = window.hoshiReader.nodeStartOffsets
      ? window.hoshiReader.nodeStartOffsets.get(targetNode) : undefined;
    if (base !== undefined) {
      var count = base || 0;
      var text = targetNode.textContent;
      for (var i = 0; i < offset;) {
        var char = String.fromCodePoint(text.codePointAt(i));
        if (window.hoshiReader.isMatchableChar(char)) count++;
        i += char.length;
      }
      return count;
    }
    var walker = this.createWalker(document.body);
    var count = 0;
    var node;
    while ((node = walker.nextNode()) != null) {
      var nodeText = node.textContent;
      if (node === targetNode) {
        for (var i = 0; i < offset;) {
          var char = String.fromCodePoint(nodeText.codePointAt(i));
          if (window.hoshiReader.isMatchableChar(char)) count++;
          i += char.length;
        }
        return count;
      }
      for (var i = 0; i < nodeText.length;) {
        var char = String.fromCodePoint(nodeText.codePointAt(i));
        if (window.hoshiReader.isMatchableChar(char)) count++;
        i += char.length;
      }
    }
    return null;
  },
  clearHighlightWrappers: function() {
    if (!this.highlightWrappers.length) return;
    for (var i = 0; i < this.highlightWrappers.length; i++) {
      var wrapper = this.highlightWrappers[i];
      var parent = wrapper.parentNode;
      if (!parent) continue;
      while (wrapper.firstChild) {
        parent.insertBefore(wrapper.firstChild, wrapper);
      }
      parent.removeChild(wrapper);
      parent.normalize();
    }
    this.highlightWrappers = [];
    if (!window.__hoshiCssHighlightsSupported && window.hoshiReader && window.hoshiReader.buildNodeOffsets) {
      window.hoshiReader.buildNodeOffsets();
    }
  },
  clearSelection: function() {
    window.getSelection()?.removeAllRanges();
    if (window.__hoshiCssHighlightsSupported) {
      CSS.highlights.delete('hoshi-selection');
      this.clearSelectionRubyHighlights();
    } else {
      this.clearHighlightWrappers();
    }
    this.hideSelectionHandles();
    this.selection = null;
  }
};
""";
}
