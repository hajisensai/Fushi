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
  findParagraph: function(node) {
    var el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return (el && el.closest('p, .glossary-content, .cue')) || null;
  },
  createWalker: function(rootNode) {
    var root = rootNode || document.body;
    return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => this.isFurigana(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
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
    if (document.caretPositionFromPoint) {
      var pos = document.caretPositionFromPoint(x, y);
      if (!pos) return null;
      var range = document.createRange();
      range.setStart(pos.offsetNode, pos.offset);
      range.collapse(true);
      return range;
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
    var leadingTrim = rawSentence.length - rawSentence.trimStart().length;
    return {
      sentence: rawSentence.trim(),
      sentenceOffset: Math.max(0, beforeText.length - leadingTrim),
      sStartNode: sStartNode,
      sStartOffset: sStartOffset,
      sEndNode: sEndNode,
      sEndOffset: sEndOffset
    };
  },
  getSentence: function(startNode, startOffset) {
    return this.getSentenceContext(startNode, startOffset).sentence;
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
      var ctx = this.getSentenceContext(before.node, before.offset + 1);
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
    var sentenceNormalizedOffset = null;
    var sentenceNormalizedLength = null;
    if (window.hoshiReader) {
      var snStart = this.getNormalizedOffset(
        sentenceContext.sStartNode, sentenceContext.sStartOffset);
      var snEnd = this.getNormalizedOffset(
        sentenceContext.sEndNode, sentenceContext.sEndOffset);
      if (snStart !== null && snEnd !== null) {
        sentenceNormalizedOffset = snStart;
        sentenceNormalizedLength = Math.max(0, snEnd - snStart);
      }
    }
    return {
      text: text,
      sentence: sentenceContext.sentence,
      normalizedOffset: normalizedOffset,
      normalizedLength: normalizedLength,
      sentenceOffset: sentenceContext.sentenceOffset,
      sentenceNormalizedOffset: sentenceNormalizedOffset,
      sentenceNormalizedLength: sentenceNormalizedLength
    };
  },
  // 从任意节点下钻到它包含的第一个非空文本节点（含自身），返回 {node, offset:0}。
  firstTextNode: function(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      return node.textContent.length > 0 ? { node: node, offset: 0 } : null;
    }
    var walker = this.createWalker(node);
    var next = walker.nextNode();
    while (next) {
      if (next.textContent.length > 0) return { node: next, offset: 0 };
      next = walker.nextNode();
    }
    return null;
  },
  // 返回 (node, offset) 之前一个文本字符的位置（跨文本节点，跳振假名），无则 null。
  charBefore: function(node, offset) {
    if (offset > 0) return { node: node, offset: offset - 1 };
    var container = this.findParagraph(node) || document.body;
    var walker = this.createWalker(container);
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
  charAt: function(node, offset) {
    if (offset < node.textContent.length) return { node: node, offset: offset };
    var container = this.findParagraph(node) || document.body;
    var walker = this.createWalker(container);
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
    var sentenceContext = this.getSentenceContext(startNode, startOffset);
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
    window.flutter_inappwebview.callHandler('onTextSelected', JSON.stringify({
      text: text,
      sentence: sentenceContext.sentence,
      rect: this.getSelectionRect(x, y),
      normalizedOffset: normalizedOffset,
      normalizedLength: normalizedLength,
      sentenceOffset: sentenceContext.sentenceOffset,
      sentenceNormalizedOffset: sentenceNormalizedOffset,
      sentenceNormalizedLength: sentenceNormalizedLength
    }));
    return text;
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
    this.selection = null;
  }
};
""";
}
