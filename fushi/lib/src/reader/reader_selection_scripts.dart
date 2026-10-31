import 'dart:convert';
import 'dart:ui';

import 'package:fushi/src/reader/reader_settings.dart';

/// TODO-393：阅读器 DOM 里「当前查词句」前后一条上下文句的解析结果。
/// [normOffset]/[normLength] 是整书归一化偏移（有 [window.fushiReader] 时才有值），
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
  }) => 'window.fushiSelection.selectText($x, $y, $maxLength, $fromHover)';

  static String highlightInvocation(int count) =>
      'JSON.stringify(window.fushiSelection.highlightSelection($count))';

  static String clearInvocation() => 'window.fushiSelection.clearSelection()';

  /// 悬停查词背压的宿主侧显式释放（见 webview.part.dart 的 `_fushiHoverLookup*`）：
  /// onTextSelected 回调处理完一次**悬停**查词（成功、失败、异常都算）后对正文 WebView
  /// eval 这一句，按 payload 里的 `selectedSeq` 释放 JS 侧在等的那一次。不依赖
  /// callHandler 的 Promise 是否送达；序号对不上（已被回执释放、又发了新一次）时 JS 侧忽略。
  /// 非悬停查词（点按 / 键盘）或没有合法序号的 payload 返回 null，调用方什么也不做。
  static String? hoverLookupSettledInvocation(Map<String, dynamic> payload) {
    if (payload['fromHover'] != true) return null;
    final Object? raw = payload['selectedSeq'];
    if (raw is! num || !raw.isFinite || raw != raw.truncate() || raw <= 0) {
      return null;
    }
    final int seq = raw.toInt();
    return 'window.__fushiHoverLookupSettled && '
        'window.__fushiHoverLookupSettled($seq)';
  }

  /// TODO-1317: 移动端「长按拖选」手势 IIFE（注入进阅读器 setup script）。触屏在正文
  /// 长按 [delayMs] 毫秒即建立单字选区，继续拖动经
  /// `window.fushiSelection.updateRangeSelection`
  /// 扩展 app 自绘选区（CSS Custom Highlight `fushi-selection`，绝不建立原生选区，
  /// 保住 TODO-1279 触屏无双选区），松手经 `endRangeSelection` 弹选区菜单（复制 / 查词，
  /// 走 `onSelectionMenu`）—— 选区间(可复制)与查词/制卡共存，不再被强制查词；原地未拖动
  /// 也保留长按时建立的单字选区，对齐 Hoshi/Android 原生长按选择。移动 > [slop]px
  /// 未及 [delayMs] 判为滑动/滚动，放弃拖选（长按 vs swipe 消歧）。置全局标志
  /// `window.__fushiTextSelectDragActive`，翻页（`_gestureEnd`）与边界跨章（`_bEnd`）
  /// 见到即让路，绝不与拖选争同一次触摸（消除拖选后误翻页 / 双查词）。
  ///
  /// 单独一个 IIFE、只挂 document 上的 touch 监听，与图片长按（`onImageLongPress`，
  /// 550ms，仅命中图片才 arm）按命中元素天然互斥；多指触摸（缩放）直接不 arm。
  ///
  /// BUG-2919（长按抢走翻页滑动）：长按与滑动翻页是两个并行识别器，同一次触摸
  /// 两者都可能接受——长按判据是「[delayMs] 内位移不超过 [slop]」，翻页判据是
  /// 「松手时位移 ≥ 24px」（**不限时**，慢滑也翻页）。重叠区 = 手指在 [delayMs]
  /// 内走不出 [slop]：先按住停顿一下再滑、或滑得慢于 slop/delay，计时器先 fire，
  /// 置 `__fushiTextSelectDragActive` 后翻页让路，于是「翻页变成选中」。BUG-2563
  /// 把参数从 400/10 放宽到 280/16，重叠速度从 25px/s 抬到 57px/s、停顿窗口缩到
  /// 280ms（比 Android 平台长按时限 `ViewConfiguration` 400ms 还短），用户翻页
  /// 时的自然停顿就落进去了。所以：
  /// * [delayMs] 取 Android 平台长按时限 400ms——用户对「长按」的肌肉记忆就是它。
  /// * [slop] 取单击判据同一个真值 [ReaderSettings.tapSlopPx]：「没动」只有一个
  ///   定义，长按不该比单击更宽容地吞掉位移。
  /// BUG-2563「长按不灵敏」的真根因是命中判定（已另行修复，不受此处影响）。
  static String longPressDragGestureScript({
    int delayMs = 400,
    int slop = ReaderSettings.tapSlopPx,
  }) {
    final int slopSq = slop * slop;
    return '''
(function() {
  var LPS_DELAY = $delayMs;
  var LPS_SLOP_SQ = $slopSq;
  var lpsTimer = null;
  var lpsActive = false;
  var lpsStartX = 0, lpsStartY = 0;
  window.__fushiTextSelectDragActive = false;
  function lpsClearTimer() { if (lpsTimer) { clearTimeout(lpsTimer); lpsTimer = null; } }
  function lpsReset() {
    lpsClearTimer();
    lpsActive = false;
    window.__fushiTextSelectDragActive = false;
  }
  // Arm over any visible glyph, never over links / form controls / caret ring /
  // block images (those own their own gestures). Uses the *selection* hit test,
  // not the lookup one: a long press onto a comma, a full stop or an indent is a
  // perfectly ordinary place to start selecting text, and gating the arm on the
  // lookup test (which rejects scan boundaries) is what made the long press feel
  // dead on exactly those spots. Blank margins still never arm -- the geometry
  // and visibility checks live in the shared lower layer.
  function lpsAllowed(target, x, y) {
    var el = target || document.elementFromPoint(x, y);
    if (el && el.closest &&
        el.closest('a[href], img, .block-img-wrapper, input, textarea, select, button, [contenteditable="true"], [data-fushi-clk], #fushi-caret-ring, [data-fushi-sel-handle]')) {
      return false;
    }
    return !!(window.fushiSelection && window.fushiSelection.getSelectableCharacterAtPoint &&
      window.fushiSelection.getSelectableCharacterAtPoint(x, y));
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
      if (window.fushiSelection && window.fushiSelection.beginRangeSelection &&
          window.fushiSelection.beginRangeSelection(lpsStartX, lpsStartY)) {
        lpsActive = true;
        // Set BEFORE touchend so tap/swipe (_gestureEnd) and boundary cross-chapter
        // (_bEnd) both bail: the drag-select owns this touch exclusively.
        window.__fushiTextSelectDragActive = true;
      }
    }, LPS_DELAY);
  }, {passive: true});
  document.addEventListener('touchmove', function(e) {
    if (!e.touches || !e.touches.length) return;
    var t = e.touches[0];
    if (lpsActive) {
      // Own the gesture: block native scroll and extend the app-drawn selection.
      if (e.cancelable) e.preventDefault();
      if (window.fushiSelection && window.fushiSelection.updateRangeSelection) {
        window.fushiSelection.updateRangeSelection(t.clientX, t.clientY);
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
    if (window.fushiSelection && window.fushiSelection.endRangeSelection) {
      window.fushiSelection.endRangeSelection(x, y);
    }
    // Keep __fushiTextSelectDragActive true until the next touchstart resets it:
    // a trailing compatibility pointerup (order vs touchend varies by WebView)
    // must still see the flag so _gestureEnd bails -> no double lookup.
    lpsClearTimer();
    lpsActive = false;
  }, {passive: false});
  document.addEventListener('touchcancel', function() {
    lpsReset();
    if (window.fushiSelection) window.fushiSelection.dragAnchor = null;
  }, {passive: true});
})();''';
  }

  /// BUG-402：取**浏览器原生选区**（`window.getSelection()`）的纯文本，给桌面
  /// Windows 的 Ctrl+C 复制兼容层用。刻意走原生 `getSelection()` 而非
  /// `window.fushiSelection`（后者是查词选区，是另一套坐标/状态），因为短拖/竖拖
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
      'JSON.stringify(window.fushiSelection.getSurroundingSentences('
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
      'JSON.stringify(window.fushiSelection.nativeSelectionSentenceRange())';

  /// TODO-1127：取**当前原生选区**内夹带的 EPUB 插图（<img> / 光栅封面 <svg><image>）。
  /// 回传 JSON 数组，每项 `{src, normOffset}`，由 [clipSelectionImagesFromResult] 解析。
  /// 供有声书片段导出把「选区中间的插图」按相对顺序渲进卡片。
  static String nativeSelectionImagesInvocation() =>
      'JSON.stringify(window.fushiSelection.nativeSelectionImages())';

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
// BUG-3343：判据唯一出处是 Dart 的 kReaderCssHighlightsSupportedJs（reader_css_highlight_capability.dart，
// 旧 Blink 竖排 ::highlight 画错位置 → 退回包裹兜底）。本源码是原始字符串、被多份 node 行为测试按
// 文本切出来直接跑，所以这里放逐字副本；与常量逐字相等由 reader_css_highlight_capability_bug3328_test 钉住。
window.__fushiCssHighlightsSupported = (!!(window.CSS && CSS.highlights && window.Highlight) && !(function(){var ua=typeof navigator!=="undefined"&&navigator.userAgent||"";var m=/Chrome\/(\d+)\./.exec(ua);return !!m && +m[1] < 120;})());
// BUG-3326 审查（#2115 / #2119 同类）：阅读器里所有「切开 / 搬移正文节点」的 DOM 手术共用这一处
// 保护，各写入点不各写一份。会被弄坏的状态有两类：
// 1. 查词选区（fushiSelection.selection / dragAnchor）存的是「文本节点 + 数字偏移」普通对象。文本
//    节点被切开时切点之后的偏移越界（RangeError、高亮画不出、拖动柄消失、制卡句子指错）——切开一律
//    走 splitText()，由选区的拥有者（noteTextNodeSplit）按 DOM splitText 的同一语义换算。
// 2. live Range（ranges() 列出的）与原生选区。节点被移出父节点时，端点落在它里面的边界按 DOM 规范
//    塌到 (parent, index)——搬移一律走 moveNodes()：搬前钉住落在被搬节点里的端点（节点身份不变，
//    偏移原样可用）与 remap 换算的端点，搬完写回；原生选区用 setBaseAndExtent 还原，保留拖选方向
//    （macOS 先拖出原生选区再收藏 / 搜索，复制、导出不再少一段）。
// 不要再用 Range.extractContents / surroundContents 切正文：它们把切点两侧的文字复制成新文本节点、
// 原节点就地截短，两类状态都救不回。新增「存起来的 live Range」要在 ranges() 里登记。
if (!window.__fushiLiveRanges) {
  window.__fushiLiveRanges = {
    // 要保住的 live Range：CSS.highlights 里登记的（查词选区、收藏 / 标注、搜索）、高亮桥已建好但
    // 还没合批登记进 CSS.highlights 的收藏 Range 表，以及不进 CSS.highlights 的迟到图片重锚目标
    // （搜索命中 Range 的 cloneRange，见 registerImageLateAnchor）。原生选区由 moveNodes 单独处理。
    ranges: function() {
      var out = [];
      var add = function(r) {
        if (r && typeof r.setStart === 'function' && out.indexOf(r) < 0) out.push(r);
      };
      if (typeof CSS !== 'undefined' && CSS.highlights) {
        // 遍历拿到的是交给引擎绘制的那份；窄条层在 Blink 上会剔掉一部分文字另存一份（BUG-3776），
        // get 读回的调用方原件也要一起写回。
        CSS.highlights.forEach(function(hl, name) {
          hl.forEach(add);
          var own = CSS.highlights.get(name);
          if (own && own !== hl) own.forEach(add);
        });
      }
      var pending = window.__fushiHighlightRangeMap;
      if (pending) {
        for (var id in pending) (pending[id].ranges || []).forEach(add);
      }
      if (window.fushiReader) add(window.fushiReader.__imgReanchorTarget);
      if (window.__fushiCueRanges) window.__fushiCueRanges.tracked().forEach(add);
      return out;
    },
    // 在 offset 处切开文本节点，返回切点之后的新节点。live Range（含原生选区）由 DOM splitText 自己
    // 换算；查词选区的「节点 + 偏移」由它的拥有者换算。
    splitText: function(node, offset) {
      var tail = node.splitText(offset);
      var selection = window.fushiSelection;
      if (selection && typeof selection.noteTextNodeSplit === 'function') {
        selection.noteTextNodeSplit(node, offset, tail);
      }
      return tail;
    },
    // BUG-3432：批量手术（开章逐句包裹 / 拆包裹、套收藏）期间为真 = 进批时确认过没有原生选区。
    // DOM 刚改过时读 getSelection().rangeCount / anchorNode 会让 Blink 对整章同步排版一次
    // （长章约 5ms），moveNodes 每次都读：一章 2700 句的有声书逐句包裹就是 2700 次整章排版，
    // WebView 主线程卡几十秒、开书超时白屏。批内是同步执行、不会有用户输入新建选区，读一次就够。
    noNativeSelection: false,
    batch: function(fn) {
      if (this.noNativeSelection) return fn();
      var sel = window.getSelection ? window.getSelection() : null;
      this.noNativeSelection = !sel || !sel.rangeCount;
      try {
        return fn();
      } finally {
        this.noNativeSelection = false;
      }
    },
    // mutate() 把 moved 里的节点（连同子孙）移走再插回文档，节点身份不变；返回前必须已插回文档
    // （落在游离子树上的边界会被 setEnd 跨树塌缩）。remap(container, offset) 换算不在 moved 里、
    // 却被这次搬移改了含义的端点（如原父节点里切点之后的子节点序号），返回 [node, offset] 或 null。
    // 其余端点由 DOM 规范自己调整，写回时取搬移之后的值。
    moveNodes: function(moved, mutate, remap) {
      var inMoved = function(c) {
        for (var m = 0; m < moved.length; m++) {
          if (moved[m] === c || moved[m].contains(c)) return true;
        }
        return false;
      };
      var pin = function(c, o) {
        if (inMoved(c)) return [c, o];
        return remap ? remap(c, o) : null;
      };
      var fixes = [];
      this.ranges().forEach(function(r) {
        var s = pin(r.startContainer, r.startOffset);
        var e = pin(r.endContainer, r.endOffset);
        if (s || e) fixes.push({ r: r, s: s, e: e });
      });
      // 原生选区没被钉住的那一端交给一个折叠的 live Range 跟踪：DOM 规范对它的调整就是对那一端的调整
      // （搬移之后再读 anchor / focus 不可靠：被塌缩的一端可能让选区方向翻转）。
      var hold = function(pinned, c, o) {
        if (pinned) return { pinned: pinned };
        var probe = document.createRange();
        probe.setStart(c, o);
        return { probe: probe };
      };
      var read = function(h) {
        return h.pinned || [h.probe.startContainer, h.probe.startOffset];
      };
      var sel = !this.noNativeSelection && window.getSelection ? window.getSelection() : null;
      var native = null;
      if (sel && sel.rangeCount && sel.anchorNode && sel.focusNode) {
        var a = pin(sel.anchorNode, sel.anchorOffset);
        var f = pin(sel.focusNode, sel.focusOffset);
        if (a || f) {
          native = {
            a: hold(a, sel.anchorNode, sel.anchorOffset),
            f: hold(f, sel.focusNode, sel.focusOffset)
          };
        }
      }
      mutate();
      fixes.forEach(function(x) {
        var s = x.s || [x.r.startContainer, x.r.startOffset];
        var e = x.e || [x.r.endContainer, x.r.endOffset];
        x.r.setStart(s[0], s[1]);
        x.r.setEnd(e[0], e[1]);
      });
      if (native) {
        var na = read(native.a);
        var nf = read(native.f);
        sel.setBaseAndExtent(na[0], na[1], nf[0], nf[1]);
      }
    },
    // 把 node 里 [start, end) 这段文字原地包进 wrapper：先在首尾切开，再把中间那个文本节点原样搬进
    // wrapper（不用 surroundContents / extractContents，理由见上）。返回 wrapper。
    wrapText: function(node, start, end, wrapper) {
      if (end < node.data.length) this.splitText(node, end);
      var mid = start > 0 ? this.splitText(node, start) : node;
      var parent = mid.parentNode;
      this.moveNodes([mid], function() {
        parent.insertBefore(wrapper, mid);
        wrapper.appendChild(mid);
      });
      return wrapper;
    },
    // 拆掉 wrapper、子节点原样留在原位，返回原父节点（没挂在文档里返回 null）。不合并文本节点，
    // 调用方拆完一批后对父节点调 normalize()。
    unwrap: function(wrapper) {
      var parent = wrapper.parentNode;
      if (!parent) return null;
      var moved = Array.prototype.slice.call(wrapper.childNodes);
      this.moveNodes(moved, function() {
        moved.forEach(function(m) { parent.insertBefore(m, wrapper); });
        parent.removeChild(wrapper);
      });
      return parent;
    },
    // BUG-3343：Node.normalize() 把相邻文本节点并进第一个、其余移出文档。live Range 与原生选区由
    // DOM 规范自己换算到合并后的节点；查词选区与拖选锚点是「节点 + 偏移」普通对象，指向被并掉
    // 节点的点会失效（删除收藏 / 标注时高亮桥拆包裹并 normalize，查词选区随之丢失）。合并一律走
    // 这里，由选区的拥有者（trackTextPoints）在合并期间跟踪这些点、合并完写回。
    normalize: function(node) {
      if (!node) return;
      var selection = window.fushiSelection;
      var restore = selection && typeof selection.trackTextPoints === 'function'
        ? selection.trackTextPoints() : null;
      node.normalize();
      if (restore) restore();
    }
  };
}
// BUG-3518（「句子被高亮顶开」）：WebKit 只在同一个文本节点内做字距调整（kerning，Hiragino 等日文字体
// 在「、机」「。表」这类字对上收 1–2px）；文本节点一旦被切开——包进 span、拆成两个相邻文本节点、
// 哪怕包裹是 display:contents——切口两侧的字对就不再调整，切口之后整行的字往后挪（iOS 26.5 模拟器
// 实测；font-feature-settings:'kern' 0 关不掉，只有 font-kerning:none 能关）。有声书原先把每句
// 包进 .fushi-sentence-audio-cue：分页 / 滚动在开章时整章包裹，句界处的字距一律变松；VN 在播放到
// 那句时才包裹，排版恰好在高亮出现那一刻变动。Blink 把整段行内文字一起排版，切开不影响字距。
// 所以 WebKit 上有声书句子不再改 DOM：每句登记成 live Range，当前句交给 CSS.highlights 的
// 'fushi-sentence-audio'——字色走 ::highlight()，底色照旧由窄条层画（窄条层本来就读这一组）。
// Range 登记在 tracked() 里，正文其它 DOM 手术（__fushiLiveRanges.moveNodes）会把它们写回而不塌缩。
// Blink 与不支持 CSS Highlight 的旧 WebView 继续走包裹。window.__fushiSentenceAudioRangeMode
// （布尔）可强制开关，供测试在 Chrome 里跑这条路径。
// BUG-3778：VN 逐字显现时未显现的字只是被 ::highlight(fushi-vn-unrevealed) 画成透明，仍在 DOM
// 里、照样能被 caretPositionFromPoint 命中。window.__fushiRevealRange 是那段未显现正文的
// live Range（VN shell 维护，其余时候为 null）；查词命中与窄条层都经这里认出「还看不见」的字。
if (typeof window.__fushiTextUnrevealed !== 'function') {
  window.__fushiTextUnrevealed = function(node, offset) {
    var range = window.__fushiRevealRange;
    if (!range) return false;
    try {
      return range.comparePoint(node, offset) === 0;
    } catch (_) {
      return false;
    }
  };
}
if (!window.__fushiCueRanges) {
  window.__fushiCueRanges = (function() {
    var HIGHLIGHT = 'fushi-sentence-audio';
    var owners = [];
    var isWebKit = function() {
      var ua = typeof navigator !== 'undefined' && navigator.userAgent || '';
      return /AppleWebKit\//.test(ua) && !/(Chrome|Chromium)\//.test(ua);
    };
    return {
      enabled: function() {
        if (!window.__fushiCssHighlightsSupported || typeof Highlight !== 'function') return false;
        var forced = window.__fushiSentenceAudioRangeMode;
        return typeof forced === 'boolean' ? forced : isWebKit();
      },
      // BUG-3741：VN 播放到哪句才处理哪句，任何引擎上切 DOM 都发生在句子已经显示之后——Blink
      // 包裹段落里后一句的文本节点会让同段含 ruby 的那一列行盒差出 6px，整屏跟着居中平移。
      // 所以 VN 只要引擎支持 CSS Highlight 就走 Range（分页 / 滚动开章即整章包裹，不受影响）。
      availableForLiveText: function() {
        if (!window.__fushiCssHighlightsSupported || typeof Highlight !== 'function') return false;
        return window.__fushiSentenceAudioRangeMode !== false;
      },
      // BUG-3776：Blink 用 CSS Highlight 换字色时把字形墨迹裁进文字片段盒（傍点、墨迹宽的字体被切边，
      // 见窄条层 paintable）。当前句真要换字色（用户设了自定义字色）时，VN 改在换屏、显示之前把屏上
      // 各句包裹好，字色走 wrapper 的 class，播放中只切 class。sample 取正文里的一个元素，比较它的
      // ::highlight 计算字色与本身字色。
      recolorClipsInk: function(sample) {
        if (!sample || isWebKit()) return false;
        var ua = typeof navigator !== 'undefined' && navigator.userAgent || '';
        if (!/(Chrome|Chromium)\//.test(ua)) return false;
        var color = getComputedStyle(sample, '::highlight(' + HIGHLIGHT + ')').color;
        return !!color && color !== getComputedStyle(sample).color;
      },
      // 分段 {node, start, end} → Range（建 Range 前让文本可被 ::highlight 绘制，见 BUG-3323）。
      build: function(segments) {
        var out = [];
        for (var i = 0; i < segments.length; i++) {
          var seg = segments[i];
          if (!seg.node || !seg.node.parentNode || seg.end <= seg.start) continue;
          if (typeof window.__fushiEnsureHighlightPaintable === 'function') {
            window.__fushiEnsureHighlightPaintable(seg.node);
          }
          var r = document.createRange();
          r.setStart(seg.node, seg.start);
          r.setEnd(seg.node, seg.end);
          out.push(r);
        }
        return out;
      },
      // owner：一个 Map(cueId → Range[])，由各引擎持有；登记后其中的 Range 随 DOM 手术写回。
      track: function(owner) {
        if (owners.indexOf(owner) < 0) owners.push(owner);
      },
      untrack: function(owner) {
        var k = owners.indexOf(owner);
        if (k >= 0) owners.splice(k, 1);
      },
      tracked: function() {
        var out = [];
        owners.forEach(function(owner) {
          owner.forEach(function(ranges) { for (var i = 0; i < ranges.length; i++) out.push(ranges[i]); });
        });
        return out;
      },
      show: function(ranges) {
        var h = new Highlight();
        for (var i = 0; i < ranges.length; i++) h.add(ranges[i]);
        // 查词（priority 1）压过当前句（BUG-125）。
        h.priority = 0;
        CSS.highlights.set(HIGHLIGHT, h);
        if (window.__fushiLanes) window.__fushiLanes.repaint(HIGHLIGHT);
      },
      hide: function() {
        if (!window.__fushiCssHighlightsSupported || !CSS.highlights.has(HIGHLIGHT)) return;
        CSS.highlights.delete(HIGHLIGHT);
        if (window.__fushiLanes) window.__fushiLanes.repaint(HIGHLIGHT);
      }
    };
  })();
}
// BUG-3323: WebKit never paints ::highlight() on a text node whose layout parent is
// an *anonymous* block -- i.e. text sitting directly in a block container that also
// has an in-flow block-level child box (a real child element, or a ::before/::after
// with display:block). Every selector form fails (p::highlight, *::highlight, ...);
// an inline element parent paints fine; Blink is unaffected. The WebKit paginated
// page-top ruby reserve (BUG-2761: block `p::after`) puts the text of *every* <p>
// into such an anonymous block, so on iOS / macOS the drag-select, lookup,
// favourite and search highlights all went invisible while their grips still
// showed. Call this on each text node before building a Range for a CSS Highlight:
// when the node is in that position it is moved, unchanged, into an unstyled inline
// wrapper. Node identity and offsets are preserved; the move goes through
// __fushiLiveRanges.moveNodes, so existing live Ranges and the native selection with
// an endpoint in the node are written back instead of collapsing onto the parent.
// The wrapper adds no box, so layout and text walkers are unaffected. Idempotent; a
// no-op wherever the engine already lays the text out under a real element.
// Blink (Android WebView / WebView2) paints these highlights fine, so there the
// helper is a no-op: the move would be pure DOM churn (per drag frame computed-style
// probes, structural-selector flips below) with nothing to fix.
// The move must also never change which reader rule a sibling matches: the reader
// centres a lone illustration with `p > img:only-child { display:block }`; wrapping
// the text beside it would end :only-child, turn the image inline and reflow the
// paragraph on lookup. Such text stays where it is (unpainted on WebKit, as before).
if (typeof window.__fushiEnsureHighlightPaintable !== 'function') {
  window.__fushiEnsureHighlightPaintable = (function() {
    var WRAPPER_TAG = 'fushi-hl-text';
    var ua = (window.navigator && window.navigator.userAgent) || '';
    if (/\b(?:Chrome|Chromium|HeadlessChrome)\//.test(ua)) return function() {};
    function siblingReliesOnOnlyChild(parent) {
      var first = parent.firstElementChild;
      return !!first && !first.nextElementSibling && first.localName === 'img';
    }
    function inlineLevelDisplay(display) {
      return !display || display === 'none' || display === 'contents' ||
        display.indexOf('inline') === 0 || display.indexOf('ruby') === 0;
    }
    function inFlowBlockLevel(cs) {
      if (!cs || inlineLevelDisplay(cs.display)) return false;
      if (cs.position === 'absolute' || cs.position === 'fixed') return false;
      return !cs.cssFloat || cs.cssFloat === 'none';
    }
    function generatedBlockBox(el, pseudo) {
      var cs = window.getComputedStyle(el, pseudo);
      var content = cs && cs.content;
      if (!content || content === 'none' || content === 'normal') return false;
      return inFlowBlockLevel(cs);
    }
    function textLaidOutAnonymously(parent) {
      var display = window.getComputedStyle(parent).display || '';
      if (inlineLevelDisplay(display)) return false;
      // Text directly in a flex / grid container becomes an anonymous item.
      if (display.indexOf('flex') >= 0 || display.indexOf('grid') >= 0) return true;
      if (generatedBlockBox(parent, '::before') || generatedBlockBox(parent, '::after')) {
        return true;
      }
      for (var child = parent.firstElementChild; child; child = child.nextElementSibling) {
        if (inFlowBlockLevel(window.getComputedStyle(child))) return true;
      }
      return false;
    }
    // The verdict depends only on computed styles (the parent, its ::before / ::after
    // and its element children), so it holds until the styles change. Where the
    // helper never wraps (scrolling mode, parents that are not anonymous blocks) every
    // drag frame would otherwise re-probe the parent of every segment: on ruby-dense
    // paragraphs that is O(segments x element children) getComputedStyle calls per
    // frame on iOS. Cache per parent; any change of the <head> styles (both reader CSS
    // swap paths rewrite #fushi-reader-style, book stylesheets) or of the class / style
    // of <html> / <body> drops the whole cache.
    var anonymousByParent = new WeakMap();
    if (window.MutationObserver && document.head) {
      var styleObserver = new window.MutationObserver(function() { anonymousByParent = new WeakMap(); });
      styleObserver.observe(document.head,
          { childList: true, characterData: true, attributes: true, subtree: true });
      [document.documentElement, document.body].forEach(function(root) {
        if (root) styleObserver.observe(root, { attributes: true, attributeFilter: ['class', 'style'] });
      });
    }
    function laidOutAnonymously(parent) {
      var known = anonymousByParent.get(parent);
      if (known === undefined) {
        known = textLaidOutAnonymously(parent);
        anonymousByParent.set(parent, known);
      }
      return known;
    }
    return function(node) {
      // Numeric node types: this runs in node test harnesses that have no `Node`.
      if (!node || node.nodeType !== 3) return;
      var parent = node.parentNode;
      if (!parent || parent.nodeType !== 1) return;
      if (parent.localName === WRAPPER_TAG) return;
      if (!laidOutAnonymously(parent)) return;
      if (siblingReliesOnOnlyChild(parent)) return;
      var wrapper = document.createElement(WRAPPER_TAG);
      window.__fushiLiveRanges.moveNodes([node], function() {
        parent.insertBefore(wrapper, node);
        wrapper.appendChild(node);
      });
    };
  })();
}
// 高亮条一律一个字高（用户 2026-10-15：「所有字体都要一个字高」）。阅读器里的高亮原本各画各的底色：
// ::highlight()（查词 / 收藏 / 搜索）只能设 background-color，铺满整个文字盒；元素背景（有声书当前句
// wrapper、ruby 分流 class、旧 WebView 的包裹 span）同样按文字盒铺。盒厚 = 字体 ascent + descent，随字体变
// （Hiragino 1.14em、Noto Sans JP 约 1.45em），收不窄。现在所有高亮的底色都由这里统一画：
// - 来源：CSS.highlights 里登记的 Range，加上带高亮 class 的元素（见 GROUPS），逐文本节点（跳过 rt / rp
//   注音与 VN 未显现的字）取行片段。各路径自己的底色一律透明（reader_content_styles.dart），字色、收藏
//   下划线、墨水屏线式标记仍由原来的 ::highlight / class 规则负责。
// - 形状：CJK 沿块方向居中、厚 1em；西文按字体真实度量盖住上伸 / 下延（BUG-3435）；有注音时收到振假名
//   墨迹之外（见 blockExtent / lanes）；同一行里同一层的片段并成一条（有声书整句被振假名拆成多个
//   wrapper 时也不留缝、不叠色，取代逐缝补 box-shadow 的旧做法）。
// - 位置：body 里一个 z-index:-1 的绝对定位层，在正文之下、body 背景之上（body 是层叠上下文与包含块），
//   跟正文一起滚动 / 翻页；不切文本节点，拖选每帧重画也不碰正文 DOM。
// - 书自带底色（BUG-3421）：同一层叠上下文里，块级元素的背景画在 z-index:-1 层之后，书里 `p { background }`
//   之类的段落 / 块底色会把 body 层的窄条整片盖掉。落在这种元素里的字，窄条改画进该元素自己的一层：
//   元素标 data-fushi-hl-backdrop（CSS 给 isolation:isolate，自成层叠上下文，不改包含块与几何），层是它的
//   末尾子元素、同样 z-index:-1——于是画在它的底色之上、它的字之下。底色元素不能挂子层（ruby 内部、表格
//   行 / 行组等）时挂到它下面最近的可挂元素（同样在底色之后画）；用完即撤，书的底色本身一律不动。
// - 叠放自下而上：有声书当前句 → 收藏 → 搜索 → 查词（BUG-125：查词压过当前句）。颜色由 CSS 按 data-hl
//   给（fushi-hl-lane[data-hl=...]）。
// 重画时机：CSS.highlights 增删、高亮 class 增删（MutationObserver），同一任务内合批到微任务，赶在本帧
// 绘制前；窗口尺寸变化、字体加载完、正文样式表被换、图片加载完（重排）、阅读器重锚落定、VN 换屏。
if (typeof window.__fushiLanes !== 'object' || !window.__fushiLanes) {
  window.__fushiLanes = (function() {
    var HOST = 'fushi-hl-lanes';
    var LANE = 'fushi-hl-lane';
    var LANE_EM = 1;
    var GROUPS = [
      { name: 'fushi-sentence-audio', join: 2,
        selector: '.fushi-sentence-audio-cue.fushi-sentence-audio-active, ruby.fushi-sentence-audio-ruby-active, .fushi-active' }
    ].concat(['yellow', 'green', 'blue', 'pink', 'purple'].map(function(c) {
      return { name: 'fushi-hl-' + c, join: 0.5, selector: '.fushi-hl-' + c + ', ruby.fushi-hl-' + c + '-ruby-active' };
    })).concat([
      { name: 'fushi-search', join: 0.5, selector: null },
      { name: 'fushi-selection', join: 0.5, selector: 'ruby.fushi-selection-ruby-active, .fushi-dict-highlight' }
    ]);
    var BACKDROP = 'data-fushi-hl-backdrop';
    // 不能挂窄条层的元素：ruby 内部（插子元素会打乱注音排版）、表格结构（行 / 行组 / 列不是普通盒）、
    // 自己没有盒的（contents / none），以及阅读器自己的包裹元素（会被拆掉）。
    var NO_LAYER_TAG = /^(ruby|rb|rt|rp|rtc|table|thead|tbody|tfoot|tr|colgroup|col|br|wbr|img|svg|math|video|audio|canvas|iframe|object)$/;
    var NO_LAYER_DISPLAY = /^(contents|none|table|inline-table|table-row|table-row-group|table-header-group|table-footer-group|table-column|table-column-group|ruby|ruby-base|ruby-text|ruby-base-container|ruby-text-container)$/;
    var CLASS = /(^|\s)fushi-(sentence-audio-active|sentence-audio-ruby-active|active|hl-[a-z-]+|selection-ruby-active|dict-highlight)(\s|$)/;
    var host = null;
    // 书底色元素 → 它里面的窄条层（见文件头「书自带底色」）。
    var backdrops = new Map();
    // 单次重画内的计算样式缓存：元素 → 是否自带底色 / 能否挂层。
    var paintsMemo = null;
    var dirty = {};
    var queued = false;
    var registry = function() {
      return typeof CSS !== 'undefined' && CSS.highlights && window.__fushiCssHighlightsSupported ? CSS.highlights : null;
    };
    var groupOf = function(name) {
      for (var i = 0; i < GROUPS.length; i++) if (GROUPS[i].name === name) return GROUPS[i];
      return null;
    };
    var hostEl = function() {
      var body = document.body;
      if (!body) return null;
      if (!host || host.parentNode !== body) {
        var stale = body.querySelectorAll(':scope > ' + HOST);
        for (var i = 0; i < stale.length; i++) stale[i].remove();
        host = makeLayer();
        body.appendChild(host);
      }
      return host;
    };
    var makeLayer = function() {
      var layer = document.createElement(HOST);
      layer.setAttribute('aria-hidden', 'true');
      GROUPS.forEach(function(g) {
        var el = document.createElement(HOST + '-group');
        el.setAttribute('data-hl-group', g.name);
        layer.appendChild(el);
      });
      return layer;
    };
    var styleOf = function(el) {
      var known = paintsMemo && paintsMemo.get(el);
      if (known) return known;
      var cs = getComputedStyle(el);
      var bg = cs.backgroundColor || '';
      var clear = bg === '' || bg === 'transparent' || /^rgba\(.*,\s*0(\.0+)?\)$/.test(bg);
      // 行内盒（display:inline）的底色随行内内容一起画，自成层叠上下文也压不住它（Chromium 实测：
      // isolation / position+z-index / opacity 都一样），给它挂层没用，按没有底色处理、也不在它里面挂层。
      var inline = cs.display === 'inline';
      var info = {
        paints: !inline && (!clear || (!!cs.backgroundImage && cs.backgroundImage !== 'none')),
        layerable: !inline && !NO_LAYER_TAG.test(el.localName) && !NO_LAYER_DISPLAY.test(cs.display) &&
            el.localName.indexOf('fushi-') !== 0 && !(el.classList && el.classList.contains('fushi-sentence-audio-cue'))
      };
      if (paintsMemo) paintsMemo.set(el, info);
      return info;
    };
    // 文本所在的、自带底色的最近祖先（到 body 为止）里挂窄条层的元素；没有底色 = null（画在 body 层）。
    var backdropOf = function(parent) {
      var below = [];
      for (var el = parent; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
        var info = styleOf(el);
        if (info.paints) {
          if (info.layerable) return el;
          for (var i = below.length - 1; i >= 0; i--) if (styleOf(below[i]).layerable) return below[i];
          return null;
        }
        below.push(el);
      }
      return null;
    };
    var layerFor = function(owner) {
      if (!owner) return hostEl();
      var layer = backdrops.get(owner);
      if (!layer || layer.parentNode !== owner) {
        if (layer) layer.remove();
        layer = makeLayer();
        owner.setAttribute(BACKDROP, '');
        owner.appendChild(layer);
        backdrops.set(owner, layer);
      }
      return layer;
    };
    // 空了的 / 主人已离开文档的书底色层撤掉，标记一并撤。
    var pruneBackdrops = function() {
      backdrops.forEach(function(layer, owner) {
        var live = owner.isConnected && layer.parentNode === owner;
        var used = live && Array.prototype.some.call(layer.children, function(g) { return !!g.firstChild; });
        if (used) return;
        layer.remove();
        if (owner.isConnected) owner.removeAttribute(BACKDROP);
        backdrops.delete(owner);
      });
    };
    // 条的块方向范围按这款字体的真实度量算（canvas measureText，按字体缓存，字体加载完清空）：
    // - CJK（与 CJK 标点）：沿块方向 1em、按墨迹中线居中。横排时盒中线不是汉字的中线——盒 = 字体
    //   ascent + descent，多数日文字体 ascent 偏大，盒中线比汉字墨迹中线高 0.01–0.08em（Mac WebKit 逐字体
    //   实测，Noto Serif TC 墨迹下沿出条 0.05em），所以按「国」的墨迹中线居中；竖排（中心基线）按盒中线。
    // - 西文等其它文字（BUG-3435）：西文字形不在 1em 中心带里，上伸（b d f h k l t）顶到基线上 ~0.75em、
    //   下延（g j p q y）落到基线下 ~0.25em，1em 居中条会削掉 p/g/y 的尾巴和 f/l/t 的头。改为从盒推出
    //   基线（盒顶 + 字体 ascent），条盖住「上伸 + 下延参考字形」与这一段自己（带重音符等）的墨迹，各留
    //   LATIN_PAD。同一字体的西文行厚度一致，不随这一行有没有 p/g/y 忽粗忽细。竖排横躺的西文同理
    //   （顺时针转 90°，ascent 一侧朝右）；竖排直立（计算样式 textOrientation 为 upright / 纵中横）仍按 CJK 算。
    // 无论哪种都不出文字盒；有注音时再由 lanes() 收到振假名墨迹之外（F-JNEJVkuC：贴字、不碰振假名）。
    var CJK = /[぀-ヿ㐀-鿿豈-﫿가-힯]/;
    // 不是空白、CJK、CJK 标点（U+3000–303F）或全角形（U+FF00–FFEF）的字。
    var NON_CJK = /[^\s　-〿぀-ヿ㐀-鿿豈-﫿가-힯＀-￯]/;
    var LATIN_REF = 'bdfhkltgjpqy';
    var LATIN_PAD = 0.04;
    var measureCtx = null;
    var metricCache = {};
    var fontKey = function(cs) {
      return cs.fontStyle + ' ' + cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
    };
    var measureText = function(font, text) {
      try {
        if (!measureCtx) measureCtx = document.createElement('canvas').getContext('2d');
        measureCtx.font = font;
        return measureCtx.measureText(text);
      } catch (e) {
        return null;
      }
    };
    // 字体级度量：fa/fd 字体 ascent/descent，shift 盒中线 → 汉字墨迹中线（向下为正），cjkInk 汉字墨迹厚，
    // la/ld 西文参考字形的墨迹上伸/下延（相对基线）。量不到时 ok=false，调用方退回盒几何。
    var fontMetrics = function(cs) {
      var font = fontKey(cs);
      if (Object.prototype.hasOwnProperty.call(metricCache, font)) return metricCache[font];
      var res = { ok: false, fa: 0, fd: 0, shift: 0, cjkInk: 0, la: 0, ld: 0 };
      var m = measureText(font, '国');
      if (m && m.fontBoundingBoxAscent > 0 && m.actualBoundingBoxAscent > 0) {
        res.ok = true;
        res.fa = m.fontBoundingBoxAscent;
        res.fd = m.fontBoundingBoxDescent;
        res.shift = ((m.fontBoundingBoxAscent - m.fontBoundingBoxDescent) -
            (m.actualBoundingBoxAscent - m.actualBoundingBoxDescent)) / 2;
        res.cjkInk = m.actualBoundingBoxAscent + m.actualBoundingBoxDescent;
        var l = measureText(font, LATIN_REF);
        if (l) {
          res.la = l.actualBoundingBoxAscent;
          res.ld = l.actualBoundingBoxDescent;
        }
      }
      metricCache[font] = res;
      return res;
    };
    // 片段的块方向范围 [lo, hi]（横排是纵坐标，竖排是横坐标）。
    var blockExtent = function(r, cs, em, vertical, text) {
      var thick = vertical ? r.width : r.height;
      var boxStart = vertical ? r.left : r.top;
      var mt = fontMetrics(cs);
      var lane = Math.min(thick, em * LANE_EM);
      var upright = vertical && (cs.textOrientation === 'upright' ||
          (cs.textCombineUpright && cs.textCombineUpright !== 'none'));
      var latin = NON_CJK.test(text) && !upright && mt.ok && mt.fa + mt.fd > 0;
      var lo = Infinity, hi = -Infinity;
      if (!latin || CJK.test(text)) {
        var mid = boxStart + thick / 2 + (vertical || !mt.ok ? 0 : mt.shift);
        lo = mid - lane / 2;
        hi = mid + lane / 2;
      }
      if (latin) {
        var own = measureText(fontKey(cs), text);
        var asc = Math.max(mt.la, own ? own.actualBoundingBoxAscent : 0);
        var desc = Math.max(mt.ld, own ? own.actualBoundingBoxDescent : 0);
        var pad = em * LATIN_PAD;
        var ascentPart = thick * mt.fa / (mt.fa + mt.fd);
        if (vertical) {
          var baseX = boxStart + thick - ascentPart;
          lo = Math.min(lo, baseX - desc - pad);
          hi = Math.max(hi, baseX + asc + pad);
        } else {
          var baseY = boxStart + ascentPart;
          lo = Math.min(lo, baseY - asc - pad);
          hi = Math.max(hi, baseY + desc + pad);
        }
      }
      return { lo: Math.max(lo, boxStart), hi: Math.min(hi, boxStart + thick) };
    };
    // 振假名的墨迹范围：rt 文本盒按注音字体的汉字墨迹厚居中（与 CJK 条同一口径），一个 ruby 只量一次。
    var annotationInk = function(ruby, cache) {
      for (var c = 0; c < cache.length; c++) if (cache[c].ruby === ruby) return cache[c].ink;
      var ink = [];
      var walker = document.createTreeWalker(ruby, NodeFilter.SHOW_TEXT);
      for (var n = walker.nextNode(); n; n = walker.nextNode()) {
        var rt = n.parentElement && n.parentElement.closest('rt');
        if (!rt || !ruby.contains(rt) || !n.data.trim()) continue;
        var cs = getComputedStyle(rt);
        if (cs.visibility === 'hidden' || cs.display === 'none') continue;
        var vertical = (cs.writingMode || '').indexOf('vertical') === 0;
        var mt = fontMetrics(cs);
        var range = document.createRange();
        range.selectNodeContents(n);
        // 竖排（直立）注音逐字量真实墨迹：带浊点 / 半浊点的假名（ぶ ぱ）比「国」宽，按汉字墨迹厚居中会
        // 低估 1–1.5px，窄条就压到振假名上（BUG-3518 顺带）。量不到时退回汉字墨迹厚居中。
        var glyphs = null;
        if (vertical && mt.ok) {
          glyphs = [];
          for (var g = 0; g < n.data.length; g++) {
            var gm = n.data.charAt(g).trim() ? measureText(fontKey(cs), n.data.charAt(g)) : null;
            if (gm && gm.actualBoundingBoxLeft + gm.actualBoundingBoxRight > 0) glyphs.push(gm);
          }
        }
        var rects = range.getClientRects();
        for (var i = 0; i < rects.length; i++) {
          var r = rects[i];
          if (r.width <= 0.5 || r.height <= 0.5) continue;
          var thick = vertical ? r.width : r.height;
          if (glyphs && glyphs.length) {
            var c = r.left + r.width / 2, glo = Infinity, ghi = -Infinity;
            glyphs.forEach(function(m) {
              glo = Math.min(glo, c - m.width / 2 - m.actualBoundingBoxLeft);
              ghi = Math.max(ghi, c - m.width / 2 + m.actualBoundingBoxRight);
            });
            ink.push({ lo: glo, hi: ghi, a: r.top, b: r.bottom });
            continue;
          }
          var half = (mt.ok && mt.cjkInk > 0 ? Math.min(thick, mt.cjkInk) : thick) / 2;
          var mid = (vertical ? r.left : r.top) + thick / 2 + (vertical || !mt.ok ? 0 : mt.shift);
          ink.push({ lo: mid - half, hi: mid + half, a: vertical ? r.top : r.left, b: vertical ? r.bottom : r.right });
        }
      }
      cache.push({ ruby: ruby, ink: ink });
      return ink;
    };
    // 片段两端的全角标点按墨迹收边：「、。」』）」这类收尾标点的墨迹在字格前半（竖排上半、横排左半），
    // 「「『（」这类起头标点在后半；全角字格的另一半是空白，窄条铺满整格会伸到字外、像句与句之间多出
    // 一截。只收片段的首尾字（并条时后续片段照常接上），字格已被 vpal / palt 压窄的不收。
    var CLOSE_PUNCT = /[、。，．」』）】〉》〕｝］〙〗]/;
    var OPEN_PUNCT = /[「『（【〈《〔｛［〘〖]/;
    var PUNCT_INK = 0.6;
    var punctInk = function(node, start, end, vertical, em, pieces) {
      var s = start, e = end;
      while (s < e && /\s/.test(node.data.charAt(s))) s++;
      while (e > s && /\s/.test(node.data.charAt(e - 1))) e--;
      if (e <= s) return;
      var edge = function(i, open) {
        var r = document.createRange();
        r.setStart(node, i);
        r.setEnd(node, i + 1);
        var cr = r.getClientRects()[0];
        if (!cr) return;
        var a = vertical ? cr.top : cr.left, b = vertical ? cr.bottom : cr.right;
        if (b - a < 0.75 * em) return;
        var line = vertical ? cr.left + cr.width / 2 : cr.top + cr.height / 2;
        pieces.forEach(function(p) {
          var pl = vertical ? p.r.left + p.r.width / 2 : p.r.top + p.r.height / 2;
          if (Math.abs(pl - line) >= 1) return;
          if (open) p.inkA = b - PUNCT_INK * (b - a);
          else p.inkB = a + PUNCT_INK * (b - a);
        });
      };
      if (CLOSE_PUNCT.test(node.data.charAt(e - 1))) edge(e - 1, false);
      if (OPEN_PUNCT.test(node.data.charAt(s))) edge(s, true);
    };
    // 一个文本节点 [start, end) 的行片段。
    var nodeRects = function(node, start, end, seen, out) {
      var parent = node.parentElement;
      if (!parent || end <= start) return;
      // VN 逐字显现时未显现的字（data-fushi-visual-novel-unrevealed）是 visibility:hidden 的，窄条不能先露出来。
      if (parent.closest('rt, rp, [data-fushi-visual-novel-unrevealed], ' + HOST)) return;
      // Range 版逐字显现（BUG-3778）：未显现的部分同样不画，只留已显现的那截。
      var unrevealed = window.__fushiRevealRange;
      if (unrevealed && typeof window.__fushiTextUnrevealed === 'function') {
        if (window.__fushiTextUnrevealed(node, start)) return;
        if (unrevealed.startContainer === node && unrevealed.startOffset < end) end = unrevealed.startOffset;
        if (end <= start) return;
      }
      if (seen) {
        if (seen.indexOf(node) >= 0) return;
        seen.push(node);
      }
      var r = document.createRange();
      r.setStart(node, start);
      r.setEnd(node, end);
      var cs = getComputedStyle(parent);
      var em = parseFloat(cs.fontSize) || 16;
      var vertical = (cs.writingMode || '').indexOf('vertical') === 0;
      var text = node.data.slice(start, end);
      var ruby = parent.closest('ruby');
      var owner = backdropOf(parent);
      var rects = r.getClientRects();
      var first = out.length;
      for (var i = 0; i < rects.length; i++) {
        if (rects[i].width > 0.5 && rects[i].height > 0.5) {
          out.push({ r: rects[i], em: em, v: vertical, x: blockExtent(rects[i], cs, em, vertical, text), ruby: ruby, o: owner });
        }
      }
      if (out.length > first) punctInk(node, start, end, vertical, em, out.slice(first));
    };
    // Range 的可见正文片段。整个元素被包住时 Range.getClientRects 还会带上元素边框盒（含注音的 ruby 盒），
    // 所以逐文本节点取。
    var rangeRects = function(range, out) {
      var root = range.commonAncestorContainer;
      if (!root || !root.isConnected) return;
      var visit = function(node) {
        var start = node === range.startContainer ? range.startOffset : 0;
        var end = node === range.endContainer ? range.endOffset : node.data.length;
        nodeRects(node, start, end, null, out);
      };
      if (root.nodeType === 3) { visit(root); return; }
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (var n = walker.nextNode(); n; n = walker.nextNode()) {
        if (range.intersectsNode(n)) visit(n);
      }
    };
    var elementRects = function(el, seen, out) {
      var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (var n = walker.nextNode(); n; n = walker.nextNode()) nodeRects(n, 0, n.data.length, seen, out);
    };
    // 行片段 → 窄条（块方向范围见 blockExtent）。同一行（文字盒中线一致、字号一致）里相隔不超过 join 个字的
    // 片段并成一条，块方向取并集（一行里 CJK 与西文混排也是一条等厚的条）；最后把条收到这一行振假名的
    // 墨迹之外，贴字而不碰注音。
    // 翻页模式的分栏（BUG-3518）：body 是多列容器，每一栏（竖排一页 / 横排一页或子列）沿行方向占
    // [start + k·step, start + k·step + width)。悬挂标点（Apple 正文 hanging-punctuation: allow-end）
    // 把行尾「、」「。」挂到栏外，字形盒伸进列间距；窄条照字形盒画就越出栏尾，字号大于列间距时越出
    // 的那截落进下一页页顶（竖排各页同一横坐标、横排同一纵坐标）。栏外的字本来就被 body 的 clip-path
    // 裁掉，所以窄条沿行方向收进它所在的栏；并条也不跨栏。滚动 / VN 没有分栏，返回 null 不收。
    // 横排 RTL 的栏从右往左排，这里不处理（返回 null）。
    var columnFrame = function() {
      var body = document.body;
      if (!body) return null;
      var cs = getComputedStyle(body);
      var width = parseFloat(cs.columnWidth);
      if (!(width > 0)) return null;
      var vertical = (cs.writingMode || '').indexOf('vertical') === 0;
      if (!vertical && cs.direction === 'rtl') return null;
      var box = body.getBoundingClientRect();
      var start = vertical
        ? box.top + (parseFloat(cs.borderTopWidth) || 0) + (parseFloat(cs.paddingTop) || 0) - body.scrollTop
        : box.left + (parseFloat(cs.borderLeftWidth) || 0) + (parseFloat(cs.paddingLeft) || 0) - body.scrollLeft;
      var gap = parseFloat(cs.columnGap) || 0;
      return { v: vertical, start: start, step: width + gap, width: width, gap: gap };
    };
    var lanes = function(pieces, join) {
      var annCache = [];
      var frame = columnFrame();
      var items = pieces.map(function(p) {
        var r = p.r;
        var it = {
          v: p.v, em: p.em,
          line: p.v ? r.left + r.width / 2 : r.top + r.height / 2,
          lo: p.x.lo, hi: p.x.hi,
          a: Math.max(p.v ? r.top : r.left, p.inkA == null ? -Infinity : p.inkA),
          b: Math.min(p.v ? r.bottom : r.right, p.inkB == null ? Infinity : p.inkB),
          col: 0,
          rubies: p.ruby ? [p.ruby] : []
        };
        if (frame && frame.v === p.v && frame.step > 0) {
          // 按片段起点归栏（悬挂字形只会伸出栏尾），只把栏尾收进这一栏。
          //
          // DEHOXVOYVQ（安卓翻页：当前句只亮第一行，折到下一行的部分全没了）：算出来的栏
          // 网格 start + k·step 与浏览器真实排出的栏并不逐像素重合——计算样式里的
          // column-width 是 calc 的浮点结果，而 Blink 排栏用 1/64px 的定点数，每一栏差
          // 不到 1/64px，翻到第 k 页就累积 k 倍；scrollLeft 又按设备像素取整。几十页后
          // 每行行首（恰在真实栏起点）就落到算出的栏起点左边超过 0.5px，旧的 `+ 0.5`
          // 容差把它归进前一栏，再被收到前一栏栏尾、宽度归零被滤掉——一句话折行后只剩
          // 第一行（行中起头的那段起点离栏界远，不受影响）。
          // 正文片段的起点永远在某一栏内（悬挂标点也只从栏尾往外伸），从不落在列间距
          // 前半段之外，所以归栏容差放宽到半个列间距：网格误差远小于它，归栏不再错。
          // 栏头不再收（片段不会从栏头之前开始，收它只会把漂移量削进字里）。
          var tol = Math.max(0.5, Math.min(frame.gap / 2, frame.step / 4));
          it.col = Math.floor((it.a + tol - frame.start) / frame.step);
          var colStart = frame.start + it.col * frame.step;
          it.b = Math.min(it.b, colStart + frame.width);
        }
        return it;
      });
      items = items.filter(function(it) { return it.b - it.a > 0.5; });
      items.sort(function(x, y) {
        if (x.col !== y.col) return x.col - y.col;
        return Math.abs(x.line - y.line) >= 1 ? x.line - y.line : x.a - y.a;
      });
      var out = [];
      items.forEach(function(it) {
        var prev = out[out.length - 1];
        if (prev && prev.v === it.v && prev.col === it.col && Math.abs(prev.line - it.line) < 1 &&
            Math.abs(prev.em - it.em) < 0.5 && it.a <= prev.b + join * it.em) {
          prev.b = Math.max(prev.b, it.b);
          prev.lo = Math.min(prev.lo, it.lo);
          prev.hi = Math.max(prev.hi, it.hi);
          it.rubies.forEach(function(rb) { if (prev.rubies.indexOf(rb) < 0) prev.rubies.push(rb); });
          return;
        }
        out.push(it);
      });
      out.forEach(function(l) {
        // mid：这一行墨迹带（blockExtent 的并集）在收到振假名之外**之前**的中线。笔触样式（markBand /
        // lineGeom / readingOrder / isFresh）以它为跨行中心——笔划自带粗细与「盖住振假名」开关，按收窄后
        // 的 lo/hi 取中会让有注音的行整条偏离字心；经典窄条照旧只用收窄后的 lo/hi。
        var mid = l.mid = (l.lo + l.hi) / 2;
        l.rubies.forEach(function(rb) {
          annotationInk(rb, annCache).forEach(function(ink) {
            if (ink.b <= l.a || ink.a >= l.b) return;
            var inkMid = (ink.lo + ink.hi) / 2;
            if (inkMid < mid) l.lo = Math.max(l.lo, Math.min(ink.hi, mid));
            else l.hi = Math.min(l.hi, Math.max(ink.lo, mid));
          });
        });
      });
      return out.filter(function(l) { return l.hi - l.lo > 0.5; });
    };
    // ── 高亮条的笔触样式（用户 2026-10-15「高亮条自定义做成配置，用户自己可自选样式」「全部高亮都要
    // 能选可以自定义高亮」）──
    // 四类高亮（收藏 / 查词 / 有声书当前句 / 搜索）各有一套配置。经典样式照旧画 1em 窄条；选了笔触样式
    // （马克笔 / 荧光笔 / 手绘 / 半截 / 彩铅 / 胶带）时，这一组改画一张 SVG：同样的行片段、同样的坐标系
    // （所在窄条层的局部坐标——body 层或书底色元素里的层，随正文滚动 / 翻页），只是形状换成斜切、毛边、双笔这些。配置全走正文 CSS 的 :root
    // 变量（--fushi-mark-<种类>-*，ReaderContentStyles 按设置写），改设置 = 换正文样式表 = head 的
    // MutationObserver 触发重画，不需要额外的桥调用。颜色仍是各组原来的颜色：用一个探针 lane 读这一组
    // 的 CSS 底色（与经典窄条同一条规则），只取 RGB，浓度听配置；底色是透明的（如关掉了有声书底色）就
    // 不画。
    // 形状在「沿行 u / 跨行 v」局部坐标里算：横排 u=x、v=y；竖排 u=y、v=-x。v 的负方向是振假名所在
    // 的 over 侧（横排上方、竖排右侧），「盖住振假名」就是往 over 侧加厚。笔划画在正文之下，振假名字
    // 本身仍压在笔划上面。随机抖动的种子取组名 + 行的局部坐标 + 样式：翻页、重画不变形，重排才换一笔。
    // Dart 侧设置页预览（highlight_stroke_preview.dart）按同一套参数画示意，两边改形状要一起改。
    var MARK_KINDS = ['audio', 'lookup', 'favorite', 'search'];
    var KIND_OF = { 'fushi-sentence-audio': 'audio', 'fushi-selection': 'lookup', 'fushi-search': 'search' };
    var kindOf = function(name) {
      return KIND_OF[name] || (/^fushi-hl-[a-z]+$/.test(name) ? 'favorite' : null);
    };
    var MARK_STYLES = ['marker', 'fluo', 'rough', 'under', 'crayon', 'tape'];
    var clampNum = function(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); };
    var cssNum = function(cs, name, fallback) {
      var v = parseFloat(cs.getPropertyValue(name));
      return isFinite(v) ? v : fallback;
    };
    // 每类高亮的笔触配置；经典（或没写变量）的种类不在结果里。
    var markConfigs = function() {
      var out = {};
      if (typeof getComputedStyle !== 'function' || !document.documentElement) return out;
      var cs = getComputedStyle(document.documentElement);
      var dark = cssNum(cs, '--fushi-mark-dark', 0) > 0;
      var paper = (cs.getPropertyValue('--fushi-mark-paper') || '').trim() || (dark ? '#000' : '#fff');
      // 落笔节奏由 Dart 按 FushiMotion 下发（highlightStrokeCssVariables）：单行时长 = base + 行长(em) ×
      // perEm，行间隔 gap，单位 ms。缺任一项就不放动画——时长与「减弱动态效果 / 墨水屏归零」都只认
      // Dart 侧的 fushiMotionEnabled，JS 不自定时长、也不自己读系统的减弱动态媒体查询。
      var sweepBase = cssNum(cs, '--fushi-mark-sweep-base-ms', -1);
      var sweepPerEm = cssNum(cs, '--fushi-mark-sweep-per-em-ms', -1);
      var sweepGap = cssNum(cs, '--fushi-mark-sweep-gap-ms', -1);
      var sweep = sweepBase >= 0 && sweepPerEm >= 0 && sweepGap >= 0 && (sweepBase > 0 || sweepPerEm > 0)
        ? { base: sweepBase / 1000, perEm: sweepPerEm / 1000, gap: sweepGap / 1000 }
        : null;
      MARK_KINDS.forEach(function(kind) {
        var p = '--fushi-mark-' + kind + '-';
        var style = (cs.getPropertyValue(p + 'style') || '').trim();
        if (MARK_STYLES.indexOf(style) < 0) return;
        out[kind] = {
          kind: kind,
          style: style,
          thickness: clampNum(cssNum(cs, p + 'thickness', 1), 0.4, 2),
          opacity: clampNum(cssNum(cs, p + 'opacity', 0.35), 0.05, 1),
          cover: cssNum(cs, p + 'cover-ruby', 0) > 0,
          rough: clampNum(cssNum(cs, p + 'roughness', 0.5), 0, 1),
          animate: !!sweep && cssNum(cs, p + 'animate', 0) > 0,
          sweep: sweep,
          paper: paper
        };
      });
      return out;
    };
    // 这一组的颜色：探针 lane 的计算底色（与经典窄条同一条 CSS 规则，收藏五色、有声书自定义色、
    // 查词色都在那里）。返回 'rgb(r,g,b)'；底色完全透明返回 null（这一组不画）。
    var groupColor = function(name) {
      var probe = document.createElement(LANE);
      probe.setAttribute('data-hl', name);
      host.appendChild(probe);
      var raw = getComputedStyle(probe).backgroundColor || '';
      probe.remove();
      var m = /rgba?\(([^)]*)\)/.exec(raw);
      if (!m) return null;
      var parts = m[1].split(/[\s,/]+/).filter(function(s) { return s !== ''; }).map(parseFloat);
      if (parts.length < 3) return null;
      if (parts.length > 3 && !(parts[3] > 0)) return null;
      return 'rgb(' + Math.round(parts[0]) + ',' + Math.round(parts[1]) + ',' + Math.round(parts[2]) + ')';
    };
    var markRng = function(seed) {
      var a = seed >>> 0;
      return function() {
        a = (a + 0x6D2B79F5) >>> 0;
        var t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
      };
    };
    var markHash = function(s) {
      var h = 2166136261;
      for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
      return h >>> 0;
    };
    var fx = function(n) { return (Math.round(n * 100) / 100).toString(); };
    var markPoint = function(vertical) {
      return vertical
        ? function(u, v) { return fx(-v) + ',' + fx(u); }
        : function(u, v) { return fx(u) + ',' + fx(v); };
    };
    var polyD = function(P, pts) {
      var d = '';
      for (var i = 0; i < pts.length; i++) d += (i ? 'L' : 'M') + P(pts[i][0], pts[i][1]);
      return d + 'Z';
    };
    var wobble = function(from, to, v, amp, step, rnd) {
      var out = [];
      var n = Math.max(1, Math.round(Math.abs(to - from) / step));
      for (var i = 1; i < n; i++) out.push([from + (to - from) * i / n, v + (rnd() - 0.5) * 2 * amp]);
      return out;
    };
    // 各笔触的自然粗细（em）。经典窄条守「一个字高」；选了笔触样式就以好看为先，允许超过字高、
    // 擦到甚至盖到振假名（用户 2026-10-16「使用了这种自定义样式应该可付出一点代价可以超过字高，
    // 主要是要更美观」），默认取参考图那种几乎填满行距的粗细。与 Dart 的 kHighlightStrokeNaturalEm
    // 逐项相同（测试钉住）。半截荧光只涂下半截，不在表里。
    var MARK_NATURAL_EM = { marker: 1.35, fluo: 1.3, rough: 1.25, crayon: 1.38, tape: 1.45 };
    // 笔划的跨行上下沿：自然粗细 × 用户粗细倍数，居中于墨迹中线；
    // 盖住振假名时 over 侧多加一个注音高（约 0.6em）。
    var markBand = function(line, k, cfg, rnd) {
      var half = line.em * k * cfg.thickness / 2;
      var j = (rnd() - 0.5) * line.em * 0.05 * cfg.rough;
      return { top: line.vc - half - (cfg.cover ? line.em * 0.6 : 0) + j, bot: line.vc + half + j };
    };
    var pathTag = function(d, attrs) { return '<path d="' + d + '" ' + attrs + '/>'; };
    var MARKERS = {
      // 斜切马克笔：逐行一条，两端平行斜切，收笔端微毛并略积墨。
      marker: function(l, c) {
        var r = c.rnd, cfg = c.cfg, em = l.em, b = markBand(l, MARK_NATURAL_EM.marker, cfg, r), h = b.bot - b.top;
        var s = h * (0.18 + 0.22 * cfg.rough);
        var a = l.u0 - em * (0.06 + r() * 0.1 * cfg.rough), z = l.u1 + em * (0.04 + r() * 0.16 * cfg.rough);
        var amp = h * 0.025 * cfg.rough;
        var pts = [[a + s / 2, b.top]].concat(wobble(a + s / 2, z + s / 2, b.top, amp, em * 1.6, r),
          [[z + s / 2, b.top], [z + s * 0.1 + (r() - 0.5) * em * 0.12 * cfg.rough, b.top + h * 0.45], [z - s / 2, b.bot]],
          wobble(z - s / 2, a - s / 2, b.bot, amp, em * 1.6, r), [[a - s / 2, b.bot]]);
        var p0 = Math.max(a, z - em * 0.7);
        return pathTag(polyD(c.P, pts), 'fill="' + c.fill + '" fill-opacity="' + fx(cfg.opacity) + '"') +
          pathTag(polyD(c.P, [[p0 + s / 2, b.top], [z + s / 2, b.top], [z - s / 2, b.bot], [p0 - s / 2, b.bot]]),
            'fill="' + c.fill + '" fill-opacity="' + fx(cfg.opacity * 0.28) + '"');
      },
      // 水性荧光笔：边缘被纸纤维晕开（位移滤镜），起笔收笔更深（渐变），中段几道浅色拖痕。
      fluo: function(l, c) {
        var r = c.rnd, cfg = c.cfg, em = l.em, b = markBand(l, MARK_NATURAL_EM.fluo, cfg, r), h = b.bot - b.top, s = h * 0.18;
        var a = l.u0 - em * 0.1, z = l.u1 + em * (0.04 + r() * 0.14 * cfg.rough);
        var gid = c.uid + 'g';
        c.defs.push('<linearGradient id="' + gid + '" x1="0" y1="0" x2="' + (l.v ? 0 : 1) + '" y2="' + (l.v ? 1 : 0) + '">' +
          [[0, 1.55], [0.06, 1], [0.5, 0.82], [0.94, 1], [1, 1.7]].map(function(st) {
            return '<stop offset="' + st[0] + '" stop-color="' + c.fill + '" stop-opacity="' + fx(Math.min(1, cfg.opacity * st[1])) + '"/>';
          }).join('') + '</linearGradient>');
        var amp = h * (0.02 + 0.05 * cfg.rough);
        var pts = [[a + s, b.top]].concat(wobble(a + s, z, b.top, amp, em * 0.7, r),
          [[z, b.top], [z - s, b.bot]], wobble(z - s, a, b.bot, amp, em * 0.7, r), [[a, b.bot]]);
        var out = pathTag(polyD(c.P, pts), 'fill="url(#' + gid + ')" filter="url(#' + c.base + 'fray)"');
        for (var k = 0; k < 2; k++) {
          var v = b.top + h * (0.3 + r() * 0.45);
          var u0 = a + (z - a) * r() * 0.3, u1 = Math.min(u0 + (z - a) * (0.35 + r() * 0.4), z - s);
          out += pathTag('M' + c.P(u0, v) + 'L' + c.P(u1, v + (r() - 0.5) * 1.5),
            'fill="none" stroke="' + c.paper + '" stroke-opacity="0.22" stroke-width="1.1" stroke-linecap="round"');
        }
        return out;
      },
      // 手绘双笔：两道略带弧度的粗笔叠画，重叠处更深（rough-notation 的 highlight 画法）。
      rough: function(l, c) {
        var r = c.rnd, cfg = c.cfg, em = l.em, b = markBand(l, MARK_NATURAL_EM.rough, cfg, r), w = b.bot - b.top, vc = (b.top + b.bot) / 2;
        var out = '';
        for (var k = 0; k < 2; k++) {
          var a = l.u0 - em * (0.04 + r() * 0.14 * cfg.rough), z = l.u1 + em * r() * 0.18 * cfg.rough;
          var j = w * (0.08 + 0.2 * cfg.rough);
          var v0 = vc + (r() - 0.5) * j, v1 = vc + (r() - 0.5) * j, bow = (r() - 0.5) * j * 1.3;
          out += pathTag('M' + c.P(a, v0) + 'Q' + c.P((a + z) / 2, (v0 + v1) / 2 + bow) + ' ' + c.P(z, v1),
            'fill="none" stroke="' + c.fill + '" stroke-opacity="' + fx(cfg.opacity * 0.72) + '" stroke-width="' +
            fx(w * (0.84 + r() * 0.1)) + '"');
        }
        return out;
      },
      // 半截荧光：只涂墨迹中线到字下沿（竖排是左侧），振假名永远露在外面，「盖住振假名」对它无效。
      under: function(l, c) {
        var r = c.rnd, cfg = c.cfg, em = l.em;
        var top = l.vc + em * 0.02, bot = l.vc + em * 0.5 * cfg.thickness, s = (bot - top) * 0.4;
        var a = l.u0 - em * 0.05, z = l.u1 + em * (0.03 + r() * 0.1 * cfg.rough);
        var amp = 0.3 + 0.6 * cfg.rough;
        var pts = [[a + s / 2, top]].concat(wobble(a, z, top, amp, em, r), [[z + s / 2, top], [z - s / 2, bot]],
          wobble(z, a, bot, amp, em, r), [[a - s / 2, bot]]);
        return pathTag(polyD(c.P, pts), 'fill="' + c.fill + '" fill-opacity="' + fx(Math.min(0.9, cfg.opacity * 1.35)) + '"');
      },
      // 彩铅涂抹：纸面颗粒把颜色打散（颗粒滤镜），边缘不规则。
      crayon: function(l, c) {
        var r = c.rnd, cfg = c.cfg, em = l.em, b = markBand(l, MARK_NATURAL_EM.crayon, cfg, r), h = b.bot - b.top;
        var a = l.u0 - em * 0.1, z = l.u1 + em * (0.05 + r() * 0.12 * cfg.rough);
        var amp = h * (0.02 + 0.06 * cfg.rough);
        var pts = [[a, b.top + h * 0.08]].concat(wobble(a, z, b.top, amp, em * 0.5, r),
          [[z, b.top + h * 0.1], [z + em * 0.05, b.bot - h * 0.2], [z - em * 0.1, b.bot]],
          wobble(z, a, b.bot, amp, em * 0.5, r), [[a - em * 0.04, b.bot - h * 0.1]]);
        return pathTag(polyD(c.P, pts), 'fill="' + c.fill + '" fill-opacity="' + fx(Math.min(1, cfg.opacity * 2)) +
          '" filter="url(#' + c.base + 'grain)"');
      },
      // 和纸胶带：半透明胶带，两端锯齿撕口、略微歪斜，叠一层细斜纹。
      tape: function(l, c) {
        var r = c.rnd, cfg = c.cfg, em = l.em, b = markBand(l, MARK_NATURAL_EM.tape, cfg, r), h = b.bot - b.top;
        var a = l.u0 - em * 0.16, z = l.u1 + em * 0.16, tilt = (r() - 0.5) * h * 0.2 * cfg.rough;
        var torn = function(u, top, bot, dir) {
          var out = [];
          for (var i = 0; i <= 5; i++) {
            out.push([u + dir * (i % 2 ? em * 0.08 : 0) + (r() - 0.5) * 1.2 * cfg.rough, top + (bot - top) * i / 5]);
          }
          return out;
        };
        var pts = torn(z, b.top + tilt, b.bot + tilt, 1).concat(torn(a, b.bot - tilt, b.top - tilt, -1));
        var d = polyD(c.P, pts);
        return pathTag(d, 'fill="' + c.fill + '" fill-opacity="' + fx(Math.min(0.85, cfg.opacity * 1.05)) + '"') +
          pathTag(d, 'fill="url(#' + c.base + 'stripe)"');
      }
    };
    var markDefs = function(base, cfg) {
      return '<filter id="' + base + 'fray" x="-4%" y="-40%" width="108%" height="180%">' +
          '<feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="3" result="n"/>' +
          '<feDisplacementMap in="SourceGraphic" in2="n" scale="' + fx(1.6 + 2.4 * cfg.rough) +
          '" xChannelSelector="R" yChannelSelector="G"/></filter>' +
        '<filter id="' + base + 'grain" x="-4%" y="-30%" width="108%" height="160%">' +
          '<feTurbulence type="fractalNoise" baseFrequency="1.15" numOctaves="1" seed="7" result="n"/>' +
          '<feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -2.4 1.75" result="m"/>' +
          '<feComposite in="SourceGraphic" in2="m" operator="in" result="c"/>' +
          '<feDisplacementMap in="c" in2="n" scale="' + fx(1 + 2 * cfg.rough) + '" xChannelSelector="R" yChannelSelector="G"/></filter>' +
        '<pattern id="' + base + 'stripe" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(35)">' +
          '<rect width="2" height="6" fill="' + cfg.paper + '" fill-opacity="0.25"/></pattern>';
    };
    // 落笔动画（SMIL，声明式、不需要帧循环；节奏由 Dart 从 FushiMotion 下发、与设置页预览
    // HighlightStrokePreviewPainter 同一公式，减弱动态效果 / 墨水屏时 Dart 写 animate=0，见 markConfigs）：
    // - 收藏：刚收藏的句子由 HighlightBridge 在写入 CSS.highlights 之前把行片段登记进来（markFresh），
    //   下一次画收藏层时这几行沿书写方向展开。只用一次、2 秒过期；章节打开 / 重排后的重新应用不登记，
    //   所以翻页、重排永远不会重放。
    // - 有声书当前句：读到新的一句（这一组出现了上次没有的行）时画出新行。这一组第一次画（开章、刚切到
    //   笔触样式）不算新，避免一打开就扫一遍。
    // - 查词 / 搜索：出现一处全新的高亮（与上次画的行没有任何重叠：点了另一个词、跳到下一个命中）时
    //   整处画出来；拖选时每帧的新选区都与上一帧重叠，不重播。
    var fresh = [];
    var markFresh = function(ranges, elements) {
      if (!hostEl()) return;
      var origin = host.getBoundingClientRect();
      var pieces = [];
      (ranges || []).forEach(function(range) { rangeRects(range, pieces); });
      var seen = [];
      (elements || []).forEach(function(el) { elementRects(el, seen, pieces); });
      var until = Date.now() + 2000;
      pieces.forEach(function(p) {
        fresh.push({ x0: p.r.left - origin.left, y0: p.r.top - origin.top,
          x1: p.r.right - origin.left, y1: p.r.bottom - origin.top, until: until });
      });
    };
    var isFresh = function(line) {
      var now = Date.now();
      for (var i = 0; i < fresh.length; i++) {
        var f = fresh[i];
        if (f.until < now) continue;
        var midHit = line.v ? (line.x >= f.x0 - 1 && line.x <= f.x1 + 1) : (line.y >= f.y0 - 1 && line.y <= f.y1 + 1);
        var spanHit = line.v ? (line.b0 < f.y1 && line.b1 > f.y0) : (line.b0 < f.x1 && line.b1 > f.x0);
        if (midHit && spanHit) return true;
      }
      return false;
    };
    // 竖排的行是否从左往右排（vertical-lr）；vertical-rl 与未知一律当从右往左。
    var readsLeftToRight = function() {
      try { return getComputedStyle(document.body).writingMode.indexOf('vertical-lr') === 0; } catch (e) { return false; }
    };
    // 有声书：上一次画过的行（组名 → { 行键: true }）。
    var paintedLines = {};
    // 查词 / 搜索：上一次画过的行几何（组名 → [{v, u0, u1, vc, em}]）。
    var paintedGeom = {};
    // 有声书：这一组画出过句子没有（空列表的重画不算）。第一次画出句子不放动画。
    var paintedAny = {};
    var overlapsAny = function(lines, prev) {
      for (var i = 0; i < lines.length; i++) {
        for (var j = 0; j < prev.length; j++) {
          var a = lines[i], b = prev[j];
          if (a.v !== b.v || Math.abs(a.vc - b.vc) > Math.max(a.em, b.em) * 0.5) continue;
          if (a.u0 < b.u1 && a.u1 > b.u0) return true;
        }
      }
      return false;
    };
    // 落笔按阅读顺序：lanes() 按中线坐标升序给行，横排即从上到下；竖排 vertical-rl 的行序是
    // 从右往左（用户 2026-10-16「竖排是从右往左的，横排是上到下的」），中线降序。
    var readingOrder = function(list) {
      if (list.length > 1 && list[0].v && !readsLeftToRight()) {
        return list.slice().sort(function(x, y) {
          if (x.col !== y.col) return x.col - y.col;
          return Math.abs(x.mid - y.mid) >= 1 ? y.mid - x.mid : x.a - y.a;
        });
      }
      return list;
    };
    // 一行在某个层里的「沿行 u / 跨行 v」局部几何（见文件头笔触说明）。
    var lineGeom = function(l, o) {
      return l.v
        ? { v: true, u0: l.a - o.top, u1: l.b - o.top, vc: -(l.mid - o.left), em: l.em }
        : { v: false, u0: l.a - o.left, u1: l.b - o.left, vc: l.mid - o.top, em: l.em };
    };
    var lineKey = function(g) { return Math.round(g.u0) + ':' + Math.round(g.u1) + ':' + Math.round(g.vc); };
    // 每个窄条层一个短标签，拼进 SVG 的 id：同一组可能同时画在 body 层与几个书底色层里，id 必须全文档唯一。
    var layerSeq = 0;
    var layerTag = function(layer) {
      if (layer === host) return 'b';
      if (!layer.__fushiMarkTag) layer.__fushiMarkTag = 'l' + (++layerSeq);
      return layer.__fushiMarkTag;
    };
    // 这一组本次重画的落笔判定（整组一次，跨所有层）：状态一律按 body 层局部坐标记，书底色层里的行
    // 与 body 层里的行放在同一套「上次画过什么」里比较。
    var markRun = function(name, cfg, allGeom) {
      var prevLines = paintedLines[name];
      var prevGeom = paintedGeom[name] || [];
      var seenBefore = !!paintedAny[name];
      var nowLines = {};
      paintedLines[name] = nowLines;
      paintedGeom[name] = allGeom;
      if (allGeom.length) paintedAny[name] = true;
      var whole = (cfg.kind === 'lookup' || cfg.kind === 'search') && !overlapsAny(allGeom, prevGeom);
      return {
        prevLines: prevLines || {},
        nowLines: nowLines,
        animate: cfg.animate &&
          (cfg.kind === 'favorite' ? fresh.length > 0 : cfg.kind === 'audio' ? seenBefore && !!prevLines : whole),
        delay: 0
      };
    };
    // 返回 { ink, still }：ink 是要写进 DOM 的串（新行带落笔动画），still 是同一张图去掉动画的串。
    // paintGroup 只按 still 判断「形状变没变」：落笔动画播放中阅读器常会再重画一次（切句后滚到该句、
    // 重锚落定），那次的 ink 不带动画，若按 ink 比较就会替换 DOM、把正在播的动画截断。
    // [origin] 是这一层的原点（路径坐标），[hostOrigin] 是 body 层原点（落笔判定的状态坐标），
    // [run] 是 markRun 给的整组判定（延迟在同组各层之间接力，行与行依次画出）。
    var markSvg = function(name, tag, list, origin, hostOrigin, cfg, run) {
      var empty = { ink: '', still: '' };
      if (!list.length) return empty;
      var geom = list.map(function(l) { return lineGeom(l, origin); });
      var fill = groupColor(name);
      if (!fill) return empty;
      var base = 'fushi-mark-' + name.replace(/^fushi-/, '') + '-' + tag + '-';
      var shared = markDefs(base, cfg);
      var ink = '';
      var still = '';
      var animate = run.animate;
      list.forEach(function(l, i) {
        var line = geom[i];
        var hline = lineGeom(l, hostOrigin);
        var key = lineKey(hline);
        run.nowLines[key] = true;
        var c = {
          cfg: cfg, P: markPoint(line.v), fill: fill, paper: cfg.paper, base: base, uid: base + i, defs: [],
          rnd: markRng(markHash(name + ':' + cfg.style + ':' + Math.round(line.u0) + ':' + Math.round(line.vc)))
        };
        var shape = MARKERS[cfg.style](line, c);
        // 滤镜 / 纹理按 id 全文档引用，只写进第一张；每行自己的 defs 跟着自己那张。
        var defs = (i === 0 ? shared : '') + c.defs.join('');
        var open = markOpen(line);
        still += open + '<defs>' + defs + '</defs>' + shape + '</svg>';
        var isNew = false;
        if (animate && cfg.kind === 'favorite') {
          isNew = isFresh(l.v
            ? { v: true, x: l.mid - hostOrigin.left, b0: hline.u0, b1: hline.u1 }
            : { v: false, y: l.mid - hostOrigin.top, b0: hline.u0, b1: hline.u1 });
        } else if (animate && cfg.kind === 'audio') {
          isNew = !run.prevLines[key];
        } else {
          isNew = animate;
        }
        if (!isNew) { ink += open + '<defs>' + defs + '</defs>' + shape + '</svg>'; return; }
        var em = line.em, len = line.u1 - line.u0 + em * 2, dur = cfg.sweep.base + (len / em) * cfg.sweep.perEm;
        var delay = run.delay;
        var cid = base + i + 'c';
        var rect = line.v
          ? '<rect x="' + fx(-line.vc - em * 3) + '" y="' + fx(line.u0 - em) + '" width="' + fx(em * 6) + '" height="0">' +
            '<animate attributeName="height" from="0" to="' + fx(len) + '"'
          : '<rect x="' + fx(line.u0 - em) + '" y="' + fx(line.vc - em * 3) + '" width="0" height="' + fx(em * 6) + '">' +
            '<animate attributeName="width" from="0" to="' + fx(len) + '"';
        var clip = '<clipPath id="' + cid + '" clipPathUnits="userSpaceOnUse">' + rect + ' begin="' + fx(delay) + 's" dur="' +
          fx(dur) + 's" fill="freeze" calcMode="spline" keyTimes="0;1" keySplines="0.3 0.6 0.4 1"/></rect></clipPath>';
        ink += open + '<defs>' + defs + clip + '</defs><g clip-path="url(#' + cid + ')">' + shape + '</g></svg>';
        run.delay = delay + dur + cfg.sweep.gap;
      });
      return { ink: ink, still: still };
    };
    // 一行笔划自己的 svg 开标签：盒子就是这一行笔划的包围盒，viewBox 与盒子同位同大，路径坐标仍是所在层
    // 的局部坐标。
    // BUG-3506：曾经是定在层原点的 1×1 svg 靠 overflow:visible 把笔划全画在盒外，WebKit 竖排下
    // 算不对这块溢出区的重绘范围——DOM 已换成新一句、屏上停在旧笔划（翻页重建才补上），竖排滚动
    // 更是整张不画。包围盒按 markBand 的上限放宽：沿行 ±2em（笔头斜切、收笔外延），跨行 ±3.5em
    // （粗细倍数上限 2 × 自然粗细上限 1.45em / 2 + 盖住振假名 0.6em + 抖动、滤镜外扩），与落笔
    // clip 矩形（沿行 ±1em、跨行 ±3em）同口径且更宽，不会裁到笔划。
    // 一行一张而不是一组一张：WebKit 竖排里落笔动画（SMIL 驱动的 clipPath）的重绘区按 svg 盒子左右
    // 镜像——整组一张时跨三栏的句子第一栏与第三栏的重绘互换，最后播的第三栏动画播完屏上只剩右侧一窄条，
    // 整层重建才补全（BUG-3578）。盒子以本行为中心，镜像后仍落在本行上。
    var markOpen = function(g) {
      var a = g.u0 - g.em * 2, b = g.u1 + g.em * 2, lo = g.vc - g.em * 3.5, hi = g.vc + g.em * 3.5;
      // 横排 (x, y) = (u, v)，竖排 (x, y) = (-v, u)（同 markPoint）。
      var x0 = Math.floor(g.v ? -hi : a), x1 = Math.ceil(g.v ? -lo : b);
      var y0 = Math.floor(g.v ? a : lo), y1 = Math.ceil(g.v ? b : hi);
      var box = fx(x0) + ' ' + fx(y0) + ' ' + fx(x1 - x0) + ' ' + fx(y1 - y0);
      return '<svg xmlns="http://www.w3.org/2000/svg" class="fushi-mark-ink" width="' + fx(x1 - x0) + '" height="' +
        fx(y1 - y0) + '" viewBox="' + box + '" aria-hidden="true" style="left:' + fx(x0) + 'px !important;top:' + fx(y0) +
        'px !important;width:' + fx(x1 - x0) + 'px !important;height:' + fx(y1 - y0) + 'px !important">';
    };
    var paintGroup = function(group, reg, mark) {
      var pieces = [];
      var highlight = reg ? reg.get(group.name) : null;
      if (highlight) highlight.forEach(function(range) { rangeRects(range, pieces); });
      if (group.selector) {
        var seen = [];
        var els = document.body.querySelectorAll(group.selector);
        for (var i = 0; i < els.length; i++) elementRects(els[i], seen, pieces);
      }
      // 按所在的层分开并条：书底色元素里的字进它自己的层，其余进 body 层。
      var byLayer = new Map();
      byLayer.set(hostEl(), []);
      backdrops.forEach(function(layer) { byLayer.set(layer, []); });
      pieces.forEach(function(p) {
        var layer = layerFor(p.o);
        if (!byLayer.has(layer)) byLayer.set(layer, []);
        byLayer.get(layer).push(p);
      });
      if (mark) {
        // 笔触样式：先收齐这一组所有层的行（「是不是新的一处 / 新的一句」按整组判，坐标统一换成 body
        // 层局部坐标），再逐层画各自的 SVG（路径坐标是该层局部坐标）。
        var hostOrigin = hostEl().getBoundingClientRect();
        var jobs = [];
        var allGeom = [];
        byLayer.forEach(function(own, layer) {
          var el = layer.querySelector(':scope > [data-hl-group="' + group.name + '"]');
          if (!el) return;
          var list = readingOrder(lanes(own, group.join));
          list.forEach(function(l) { allGeom.push(lineGeom(l, hostOrigin)); });
          jobs.push({ layer: layer, el: el, list: list });
        });
        var run = markRun(group.name, mark, allGeom);
        jobs.forEach(function(job) {
          var origin = job.list.length ? job.layer.getBoundingClientRect() : null;
          var res = markSvg(group.name, layerTag(job.layer), job.list, origin, hostOrigin, mark, run);
          // 比上次写入的静态串，不比 innerHTML：SVG 回读的序列化与写入串不逐字相同，比 innerHTML 会每次
          // 都判成「变了」、重建 DOM 并重放落笔动画；比 ink 则会截断正在播的动画（见 markSvg）。
          if (job.el.__fushiInk !== res.still) {
            job.el.innerHTML = res.ink;
            job.el.__fushiInk = res.still;
          }
        });
        return;
      }
      delete paintedLines[group.name];
      delete paintedGeom[group.name];
      delete paintedAny[group.name];
      byLayer.forEach(function(own, layer) {
        var el = layer.querySelector(':scope > [data-hl-group="' + group.name + '"]');
        if (!el) return;
        el.__fushiInk = null;
        var origin = own.length ? layer.getBoundingClientRect() : null;
        var html = '';
        lanes(own, group.join).forEach(function(l) {
          var x = l.v ? l.lo : l.a;
          var y = l.v ? l.a : l.lo;
          var w = l.v ? l.hi - l.lo : l.b - l.a;
          var h = l.v ? l.b - l.a : l.hi - l.lo;
          html += '<' + LANE + ' data-hl="' + group.name + '" style="left:' + (x - origin.left).toFixed(2) +
              'px;top:' + (y - origin.top).toFixed(2) + 'px;width:' + w.toFixed(2) +
              'px;height:' + h.toFixed(2) + 'px"></' + LANE + '>';
        });
        if (el.innerHTML !== html) el.innerHTML = html;
      });
    };
    var flush = function() {
      queued = false;
      var names = dirty;
      dirty = {};
      if (!hostEl()) return;
      hookRegistry();
      var reg = registry();
      var marks = markConfigs();
      var favPainted = false;
      paintsMemo = new Map();
      try {
        GROUPS.forEach(function(g) {
          if (!names[g.name]) return;
          var kind = kindOf(g.name);
          paintGroup(g, reg, kind ? marks[kind] || null : null);
          if (kind === 'favorite') favPainted = true;
        });
      } finally {
        paintsMemo = null;
      }
      if (favPainted) fresh = [];
      pruneBackdrops();
    };
    var schedule = function(name) {
      if (name === undefined) {
        GROUPS.forEach(function(g) { dirty[g.name] = true; });
      } else if (groupOf(name)) {
        dirty[name] = true;
      } else {
        return;
      }
      if (queued) return;
      queued = true;
      Promise.resolve().then(flush);
    };
    // 元素 class 变化 → 对应层重画。窄条层自己的变动不算。
    var touched = function(node) {
      if (!node || node.nodeType !== 1) return false;
      if (CLASS.test(node.className && node.className.baseVal === undefined ? node.className : '')) return true;
      return !!(node.querySelector && node.querySelector(
          '.fushi-sentence-audio-active, .fushi-sentence-audio-ruby-active, .fushi-active, [class*="fushi-hl-"], ' +
          '.fushi-selection-ruby-active, .fushi-dict-highlight'));
    };
    var onMutations = function(records) {
      var hit = false;
      for (var i = 0; i < records.length && !hit; i++) {
        var rec = records[i];
        if (rec.target && rec.target.closest && rec.target.closest(HOST)) continue;
        if (rec.type === 'attributes') {
          hit = CLASS.test(rec.oldValue || '') || touched(rec.target);
        } else {
          for (var a = 0; a < rec.addedNodes.length && !hit; a++) hit = touched(rec.addedNodes[a]);
          for (var d = 0; d < rec.removedNodes.length && !hit; d++) hit = touched(rec.removedNodes[d]);
        }
      }
      if (hit) schedule();
    };
    // 钩子装在注册表对象自己身上，所以这个对象必须一直被强引用：WebKit 的 CSS.highlights 包装对象没人
    // 引用时会被回收、下次读到的是新对象，挂在旧对象上的钩子随之消失，查词 / 搜索写进注册表后窄条层收不到
    // 通知、不重画（BUG-3506）。hookedRegistry 由 flush 每次经 hookRegistry 读到，保证它活着；万一引擎
    // 仍换了对象，hookRegistry 给新对象补装。
    var hookedRegistry = null;
    // BUG-3776：Blink 上任何生效的 CSS Custom Highlight 都把它覆盖的文字裁进文字片段盒里重画——墨迹伸出
    // 片段盒的部分一律丢掉：着重号（傍点）只剩一角，墨迹宽的字体（圆体 / Meiryo 等）在 ruby 基字与行首字上
    // 被切平（::highlight 规则为空也一样，Chromium 实测；WebKit 不受影响）。底色本来就由窄条层画，所以注册表
    // 入口按元素核对这层 ::highlight 的计算样式：对这段字什么都不改（字色相同、无底色 / 装饰 / 阴影 / 描边）
    // 的文字不交给引擎绘制；带着重号的文字也不交（宁可不换字色，也不能把傍点裁掉）。窄条层仍读调用方给的
    // 完整范围（painted 记着名字 → 原件，get 读回原件）。调用方都是建好整份 Highlight 再 set、之后不再改，剔一次即可。
    var painted = new Map();
    var clipsInk = (function() {
      var ua = typeof navigator !== 'undefined' && navigator.userAgent || '';
      return /(Chrome|Chromium)\//.test(ua);
    })();
    var clearColor = function(c) {
      return c === 'transparent' || /^rgba\(.*,\s*0(\.0+)?\)$/.test(c);
    };
    // 这一元素里的字不交给引擎绘制：带着重号，或这层高亮对它是空操作。读不到 ::highlight 计算样式的旧内核
    // 返回空串，按「会改」处理（照旧交给引擎）。
    var unpainted = function(el, name, memo) {
      if (!el) return false;
      if (memo.has(el)) return memo.get(el);
      var cs = getComputedStyle(el);
      var hs = getComputedStyle(el, '::highlight(' + name + ')');
      var emphasis = (cs.textEmphasisStyle || cs.webkitTextEmphasisStyle || 'none') !== 'none';
      var noop = !!hs.color && hs.color === cs.color && clearColor(hs.backgroundColor) &&
          hs.textDecorationLine === 'none' && hs.textShadow === 'none' &&
          !(parseFloat(hs.webkitTextStrokeWidth) > 0);
      var hit = emphasis || noop;
      memo.set(el, hit);
      return hit;
    };
    // range 里的文字按元素切开，返回仍要交给引擎绘制的那几段；整段都要绘制返回 null（原样用）。
    var paintedParts = function(range, name, memo) {
      if (!range || range.collapsed || typeof range.intersectsNode !== 'function') return null;
      var root = range.commonAncestorContainer;
      var nodes = [];
      if (root.nodeType === 3) {
        nodes.push(root);
      } else {
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        for (var n = walker.nextNode(); n; n = walker.nextNode()) {
          if (range.intersectsNode(n)) nodes.push(n);
        }
      }
      var out = [];
      var cut = false;
      var run = null;
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        var s = node === range.startContainer ? range.startOffset : 0;
        var e = node === range.endContainer ? range.endOffset : node.length;
        if (e <= s) continue;
        if (unpainted(node.parentElement, name, memo)) {
          cut = true;
          if (run) out.push(run);
          run = null;
          continue;
        }
        if (!run) {
          run = document.createRange();
          run.setStart(node, s);
        }
        run.setEnd(node, e);
      }
      if (run) out.push(run);
      return cut ? out : null;
    };
    // VN 逐字显现的「未显现」高亮（fushi-vn-unrevealed）本意就是把字画成透明：剔掉带着重号的元素会让
    // 傍点字在轮到它之前就露出来，所以它整份原样交给引擎。
    var paintable = function(name, value) {
      if (name === 'fushi-vn-unrevealed') return value;
      if (!clipsInk || !value || typeof value.forEach !== 'function' || typeof Highlight !== 'function') return value;
      var memo = new Map();
      var ranges = [];
      var cut = false;
      value.forEach(function(range) {
        var parts = paintedParts(range, name, memo);
        if (parts) {
          cut = true;
          for (var i = 0; i < parts.length; i++) ranges.push(parts[i]);
        } else {
          ranges.push(range);
        }
      });
      if (!cut) return value;
      var h = new Highlight();
      for (var i = 0; i < ranges.length; i++) h.add(ranges[i]);
      h.priority = value.priority;
      if (value.type) h.type = value.type;
      return h;
    };
    var hookRegistry = function() {
      var reg = registry();
      if (!reg || reg === hookedRegistry) return;
      hookedRegistry = reg;
      if (reg.__fushiLanesHooked) return;
      reg.__fushiLanesHooked = true;
      var set = reg.set, get = reg.get, del = reg.delete, clear = reg.clear;
      // 读回的是调用方 set 进来的原件（窄条层、跟读 / 查词各处都按原件取范围）；剔过的那份只给引擎绘制。
      reg.get = function(name) {
        var value = get.call(this, name);
        var entry = painted.get(name);
        return entry && entry.paint === value ? entry.value : value;
      };
      reg.set = function(name, value) {
        var paint = paintable(name, value);
        if (paint !== value) painted.set(name, { paint: paint, value: value });
        else painted.delete(name);
        var res = set.call(this, name, paint);
        schedule(name);
        return res;
      };
      reg.delete = function(name) { painted.delete(name); var res = del.call(this, name); schedule(name); return res; };
      reg.clear = function() { painted.clear(); var res = clear.call(this); schedule(); return res; };
    };
    hookRegistry();
    var repaintAll = function() { schedule(); };
    if (typeof window.addEventListener === 'function') window.addEventListener('resize', repaintAll);
    if (typeof document !== 'undefined' && document.fonts && document.fonts.addEventListener) {
      document.fonts.addEventListener('loadingdone', function() { metricCache = {}; repaintAll(); });
    }
    if (typeof document !== 'undefined' && typeof document.addEventListener === 'function') {
      document.addEventListener('load', function(e) {
        if (e.target && e.target.tagName === 'IMG') repaintAll();
      }, true);
    }
    var observe = function() {
      if (!window.MutationObserver || !document.body) return;
      new MutationObserver(onMutations).observe(document.body, {
        subtree: true, childList: true, attributes: true, attributeFilter: ['class'], attributeOldValue: true
      });
      if (document.head) new MutationObserver(repaintAll).observe(document.head, { childList: true, characterData: true, subtree: true });
      schedule();
    };
    if (typeof document !== 'undefined') {
      if (document.body) observe();
      else if (typeof document.addEventListener === 'function') document.addEventListener('DOMContentLoaded', observe);
    }
    return {
      repaint: function(name) { schedule(name); },
      flush: flush,
      laneEm: LANE_EM,
      markFresh: markFresh,
      markStyles: MARK_STYLES,
      markKinds: MARK_KINDS
    };
  })();
}
window.fushiSelection = {
  selection: null,
  // TODO-1317: mobile long-press selection anchor.
  // 本次修复把它扩成**区间**：{node, offset, endNode, endOffset}，空格分词词里长按定下的
  // 是整词（词首..词末），其它脚本是单字（首尾同一位置）。见 selectionAnchorAtHit。
  dragAnchor: null,
  // TODO-1366: start/end drag handles (touch grips) for the app-drawn selection.
  // Elements are lazily created and parented to <html> (like the caret ring),
  // shown only while a drag-selection is live and adjustable, hidden on clear.
  selectionHandles: null,
  activeHandle: null,
  highlightWrappers: [],
  selectionRubyElements: [],
  scanDelimiters: '。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]・：；:;，,.─\n\r"\'“”‘’«»‹›',
  // BUG-2196：**换行不是句子边界**。在 HTML 语义里 \n / \r 只是空白，
  // 而 EPUB 的 XHTML 正文普遍在源码里硬换行；把它们算作分隔符，
  // `shepherds abiding in the field,\n keeping watch...` 就会被切在逗号后的换行处，
  // 制卡拿到半截句、按句区间裁出的音频也跟着漏词（用户报的「制卡压没念」）。
  // 同仓库先例：视觉小说模式（reader_visual_novel_scripts.dart）本来就不含 \n\r；
  // PDF 路径（reader_pdf_page.dart）则是先把 \n/\r 等长换成空格再分句。
  // **扁平文本那条路（lookup/sentence_extraction.dart）刻意保留换行**：Windows UIA
  // 抓到的是没有块级结构的裸串，galgame / 聊天窗里一行就是一句。
  sentenceDelimiters: '。！？.!?',
  trailingSentenceChars: '。、！？…‥」』）)】〉》〕｝}］]',
  brackets: {'「':'」', '『': '』', '（':'）', '(':')', '【':'】', '〈':'〉', '《':'》', '〔':'〕', '｛':'｝', '{':'}', '［':'］', '[':']'},
  isCodePointJapanese: function(codePoint) {
    return JAPANESE_RANGES.some(function(range) { return codePoint >= range[0] && codePoint <= range[1]; });
  },
  // BUG-1773：空白不是「词边界」的同义词，这里必须拆成两个谓词。
  //
  // isScanBoundary 回答的是「这个字符能不能是一个词的一部分」——点击命中判定
  // （点空格不查词）和词首回退用它，空白当然算边界。
  //
  // 但**前向扫描**问的是另一个问题：「查询串该在哪停」。空格分词语言里空格是
  // 词**间连接符**而非终点，把它当终点就等于把 `listen to` / `look forward to`
  // 这类短语词条整类排除在匹配之外。引擎本来就按空格分词生成三级候选
  // （`listen to music` / `listen to` / `listen`，禁止在单词中间切，见
  // native/fushidicts/fushidicts_src/scan/word_scan.cpp），单词自己不会被挤掉。
  //
  // 故：isScanStop = 真正的扫描终点（标点 + 只扫日文时的门控），**不含空白**；
  // 空白能否跨过去由 selectFromPosition 的桥接规则单独决定。
  isScanWhitespace: function(char) {
    return /^[\s　]$/.test(char);
  },
  isScanStop: function(char) {
    return this.scanDelimiters.includes(char) ||
      (window.scanNonJapaneseText === false && !this.isCodePointJapanese(char.codePointAt(0)));
  },
  isScanBoundary: function(char) {
    return this.isScanWhitespace(char) || this.isScanStop(char);
  },
  // BUG-3664：点词时「回退到词首」的终点。除了 [isScanBoundary]，还要停在**词内连字符**
  // 上：`time-blackened` 点 blackened，旧逻辑跨过 `-` 一路退到 time 的 t，把
  // 「time-blackened oak…」交给引擎，词典里没有复合词就只匹配出前半截 time
  // （用户报「只能查到前面」）。连字符只截回退、不截前向扫描：点 time 仍把整串交给
  // 引擎，`well-known` 这类有词条的复合词照样能查到。与 Dart 侧
  // `latin_word_lookup.dart`（只回退拉丁字母/数字）和长按选词
  // [spaceDelimitedWordBounds]（只回退空格分词字母）同一口径。软连字符 U+00AD 不在其列
  // （它不可见，是排版断词点而不是词间连接符）。
  wordHyphenPattern: /[\-\u2010\u2011\u2012\u2013\u2014\u2015\u2212\uFE63\uFF0D]/,
  // 反馈 pm3A75D5xZ：点的是非日文字母时，词首回退不可能跨进日文（含 〖〗 等 CJK 标点）
  // 或任何开/闭括号与引号（Unicode Ps/Pe/Pi/Pf）——旧判据只认 scanDelimiters 清单，
  // 『〖tempering』点 t 回退吃进『〖』，高亮整体左移一格。与 popup selection.js 一致。
  tokenStartBracketPattern: /[\p{Ps}\p{Pe}\p{Pi}\p{Pf}]/u,
  isTokenStartBoundary: function(char) {
    if (!char) return true;
    return this.isScanBoundary(char) || this.wordHyphenPattern.test(char) ||
      this.tokenStartBracketPattern.test(char) ||
      this.isCodePointJapanese(char.codePointAt(0));
  },

  // BUG-2056：撇号在**词内**时不是词边界。英语的缩合形与所有格（don’t / it’s /
  // John’s / we’ve）在真实 EPUB 里几乎都用排版撇号 U+2019，而它和 ASCII ' 一样躺在
  // scanDelimiters 里，于是前向扫描一撞上就 break：点 "don" 喂给引擎的查询串是
  // "don"，点 "t" 是 "t"，en.json 词形还原表里 don't 这类词条整类匹配不到。
  //
  // 判据只看上下文、不看语言：撇号两侧都是**空格分词类字母**才算词内。字母集与
  // native/fushidicts/fushidicts_src/scan/word_scan.cpp 的 is_space_delimited_letter
  // 逐区间对齐（拉丁/希腊/西里尔/亚美尼亚/希伯来/阿拉伯/格鲁吉亚），全仓一个模型。
  //   don’t / John’s / l’homme → 撇号被跨过，当一个 token 继续扫
  //   ‘hello’ world            → 右侧是空白，仍是终点（引号语义不受影响）
  //   日文/中文正文里的 ’      → 两侧非空格分词脚本，仍是终点
  //
  // **只作用于前向扫描，不动词首回退**：回退跨撇号会把法语/意大利语省音写法
  // （l’homme、dell’arte）的锚点从 homme 拖回 l’，反而查不到 homme。前向跨过是纯
  // 增益——scan_candidates 会生成 don’t / don’ / don 三级前缀，短词不会被挤掉。
  //
  // 撇号集里四个码点的**角色不同**，别当成一视同仁的白名单：
  //   ' U+0027 / ‘ U+2018 / ’ U+2019 —— 都在 scanDelimiters 里，是真正被本判据
  //     救回来的三个（U+2018 是 OCR 把 ’ 认错的常见产物：`don‘t` 原本也被截成 don）；
  //   ʼ U+02BC —— **不在** scanDelimiters 里，本来就不截断，列在这里是为了让
  //     「撇号类字符」在四份实现里是同一个集合；哪天有人把它加进 scanDelimiters，
  //     桥接已经就位。测试用不变式钉住这层耦合，而不是假装它改变了行为。
  //
  // 扫出整词只是**半条链**：查询串 don’t 还要经 native/fushidicts 的
  // text_processor 撇号归一（U+2019/U+2018/U+02BC → ASCII '）才对得上 en.json 的
  // ASCII 还原规则与 ASCII 条目键——U+2019 没有 NFKC 兼容分解，折不掉。
  //     闭环 e2e：native/fushidicts/tests/en_apostrophe_lookup_test.cpp
  intraWordApostrophePattern: /['‘’ʼ]/,
  spaceDelimitedLetterPattern: /[A-Za-z\u00AA\u00B5\u00BA\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02AF\u0370-\u03FF\u0400-\u052F\u0531-\u0556\u0561-\u0587\u05D0-\u05EA\u05EF-\u05F2\u0620-\u063F\u0641-\u064A\u066E\u066F\u0671-\u06D3\u06D5\u06EE\u06EF\u06FA-\u06FC\u06FF\u0750-\u077F\u08A0-\u08BD\u10A0-\u10C5\u10D0-\u10FA\u1E00-\u1EFF\u1F00-\u1FFF]/,
  isSpaceDelimitedLetter: function(char) {
    return char !== undefined && this.spaceDelimitedLetterPattern.test(char);
  },
  isIntraWordApostrophe: function(text, index) {
    return this.intraWordApostrophePattern.test(text[index] || '') &&
      this.isSpaceDelimitedLetter(text[index - 1]) &&
      this.isSpaceDelimitedLetter(text[index + 1]);
  },
  isFurigana: function(node) {
    var el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return !!(el && el.closest('rt, rp'));
  },
  rubyForNode: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return el && el.closest ? el.closest('ruby') : null;
  },
  // 文本节点所在的 ruby 基字段：{ nodes: 该段基字的文本节点（文档序）, reading: 配对的
  // <rt> 文本 }。一个 <ruby> 可有多对基字 / rt（<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>），
  // 按子节点顺序把 rt 之前累积的基字节点与这个 rt 配对。不在 ruby 基字里（含 rt / rp
  // 自身）返回 null。cache 是一次 payload 构建内的 ruby → 段表缓存。
  rubySegmentOf: function(node, cache) {
    if (!node || this.isFurigana(node)) return null;
    var ruby = this.rubyForNode(node);
    if (!ruby) return null;
    var segments = cache.get(ruby);
    if (!segments) {
      segments = [];
      var pending = [];
      var collect = function(n) {
        if (n.nodeType === Node.TEXT_NODE) {
          if (!/^[\s　]*$/.test(n.nodeValue || '')) pending.push(n);
          return;
        }
        if (n.nodeType !== Node.ELEMENT_NODE) return;
        var tag = n.tagName;
        if (tag === 'RT') {
          segments.push({ nodes: pending, reading: (n.textContent || '').trim() });
          pending = [];
          return;
        }
        if (tag === 'RP' || tag === 'RTC') return;
        for (var c = n.firstChild; c; c = c.nextSibling) collect(c);
      };
      for (var child = ruby.firstChild; child; child = child.nextSibling) collect(child);
      cache.set(ruby, segments);
    }
    for (var i = 0; i < segments.length; i++) {
      if (segments[i].nodes.indexOf(node) >= 0) return segments[i];
    }
    return null;
  },
  // 查询串 text（= ranges 各段依次拼接）里**完整**落在选区内的 ruby 基字：
  // [{ s, e, r }]，s/e 是 text 内 UTF-16 区间，r 是来源自带的 <rt> 读音。基字只被扫到
  // 一部分（从基字中间点起 / 扫描在基字中途截断）的不报——读音无法按字拆分。宿主据此
  // 让读音吻合的同长度词典候选排前（只用来源读音，不推断）。
  rubyReadingSpans: function(ranges, text) {
    var spans = [];
    var cache = new Map();
    var pos = 0;
    var open = null;
    for (var i = 0; i < ranges.length; i++) {
      var range = ranges[i];
      var length = range.end - range.start;
      // 坐标系守卫：text 必须正是各段的依次拼接，否则区间会错位，宁可整体不报。
      if (text.substr(pos, length) !== (range.node.nodeValue || '').slice(range.start, range.end)) {
        return [];
      }
      var seg = this.rubySegmentOf(range.node, cache);
      var full = range.start === 0 && range.end === (range.node.nodeValue || '').length;
      if (!seg || !seg.reading || !full) {
        open = null;
      } else {
        var index = seg.nodes.indexOf(range.node);
        if (index === 0) {
          open = { seg: seg, start: pos, next: 1 };
        } else if (!open || open.seg !== seg || open.next !== index) {
          open = null;
        } else {
          open.next = index + 1;
        }
        if (open && open.next === seg.nodes.length) {
          spans.push({ s: open.start, e: pos + length, r: seg.reading });
          open = null;
        }
      }
      pos += length;
    }
    return spans;
  },
  clearSelectionRubyHighlights: function() {
    if (!this.selectionRubyElements || !this.selectionRubyElements.length) return;
    this.selectionRubyElements.forEach(function(ruby) {
      ruby.classList.remove('fushi-selection-ruby-active');
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
  // 字幕合成书（`CuesToEpub`：独立 SRT 书 / 语音转录产物）把相邻 cue 拼进同一个 <p>，每条
  // cue 一个 [data-cue-id] span。听写稿常常整段没有句末标点，只按标点切句会把整段（几十条
  // cue）当成一句塞进卡片。cue 是转录器按停顿 / 时长切好的语音单元，是没有标点时唯一可靠的
  // 句界，所以：相邻两条 cue **都**不含句末标点时，它们之间的边界算句界。只要任一侧有标点
  // （正常带标点的稿、被停顿切开的半句「今日は天気が」|「いいですね。」），照旧按标点取句，
  // 不受影响。
  cueSpanOf: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return el && el.closest ? el.closest('[data-cue-id]') : null;
  },
  hasSentenceDelimiter: function(text) {
    if (!text) return false;
    for (var i = 0; i < text.length; i++) {
      if (this.sentenceDelimiters.includes(text[i])) return true;
    }
    return false;
  },
  isUnpunctuatedCueBoundary: function(a, b) {
    var cueA = this.cueSpanOf(a);
    var cueB = this.cueSpanOf(b);
    if (!cueA || !cueB || cueA === cueB) return false;
    return !this.hasSentenceDelimiter(cueA.textContent) &&
      !this.hasSentenceDelimiter(cueB.textContent);
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
  // BUG-3453：createWalker 跳过的纯空白文本节点在排版上是真实的词间空格。有声书句子
  // 高亮（sentenceAudioWrapItems / wrapSentenceAudioGroup）把每条 cue 的文字各自包进
  // wrapper，cue 之间的空格落在两个 wrapper 之间，成了独立的纯空白节点——walker 一跳过
  // 它，前向取词就把「…greeted us」和下一条 cue 的「belonged」粘成 usbelonged（英文整词
  // 查不到），句子里也丢掉这个空格。cue 以标点收尾时（hair.）标点先终止扫描，所以只有
  // 每条 cue 的最后一个词出问题。
  //
  // 本谓词回答：对 createWalker 相邻的两个文本节点 a → b（文档序），两者之间是否夹着被
  // 跳过的纯空白节点（振假名 / 注音不算）。中间只会是被拒的节点，guard 只防异常 DOM。
  hasSkippedWhitespaceBetween: function(a, b) {
    if (!a || !b || a === b) return false;
    var self = this;
    var raw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        return self.isFurigana(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });
    raw.currentNode = a;
    var guard = 0;
    for (var n = raw.nextNode(); n && n !== b && guard < 256; n = raw.nextNode(), guard++) {
      var v = n.nodeValue;
      if (v && /^[\s　]+$/.test(v)) return true;
    }
    return false;
  },
  // 被跳过的空白缝是否算一个词间空格：缝前（及缝后，若给出）都是非空白、非日文字符。
  // 日文排版里 HTML 换行缝历来按无缝处理（取词跨过、句子不加空格），此处保持不变。
  isWordGapBetweenChars: function(beforeText, afterText) {
    var before = this.lastCodePointOf(beforeText);
    if (before === null || this.isScanWhitespace(String.fromCodePoint(before)) ||
        this.isCodePointJapanese(before)) return false;
    if (afterText === undefined) return true;
    if (!afterText) return false;
    var after = afterText.codePointAt(0);
    return !this.isScanWhitespace(String.fromCodePoint(after)) &&
      !this.isCodePointJapanese(after);
  },
  lastCodePointOf: function(text) {
    if (!text) return null;
    var i = text.length - 1;
    var unit = text.charCodeAt(i);
    if (unit >= 0xDC00 && unit <= 0xDFFF && i > 0) i--;
    return text.codePointAt(i);
  },
  // BUG-1797：可见正文盒 = body 的 content box ∩ 视口。
  //
  // 分页模式把整章内容当**一根** multicol，靠移动 scrollLeft/scrollTop 看每一页，所以
  // 相邻页的列在几何上就真实地落在 body 的 padding（页边距）带里。body{overflow:hidden}
  // 只在 border-box 裁，裁不掉 padding 带**内**的东西；真正遮住它的是 body 的 clip-path
  // 和 html::before 覆盖条（reader_content_styles.dart 的 contentClipCss / TODO-1285），
  // 两者都是**绘制期**机制。而命中测试是**布局期**的：caretPositionFromPoint 把落点 clamp
  // 到最近字符，getClientRects 完全无视 clip-path 与覆盖条 —— 于是「看不见」和「点得到」
  // 用了两套互不相干的真相，点页边距就查到了相邻页的词（横排在左右间距、竖排在上下间距）。
  //
  // 修法不是给页边距加特例分支，而是让两者同源：判据从「找得到字符」变成「这个字符可见吗」。
  // 盒子取 body 的 content box（border-box 内缩 computed padding，与 contentClipCss 逐项
  // 一致），computed 值已由引擎把 vh/vw/calc/var 解析成 px，不在 JS 里重算一遍 CSS、也就
  // 不会跟 CSS 那侧漂移。三种布局零特例：分页下 body 是钉在视口帧上的 scroller，content
  // box 恰等于 clip 出的可见区；连续模式 body 随内容滚动，与视口取交后滚出去的那截不会被
  // 误判成不可见；VN 模式 body padding 为 0，盒 == 整视口、判据近似恒真。
  visibleContentBox: function() {
    try {
      var body = document.body;
      if (!body) return null;
      var rect = body.getBoundingClientRect();
      var cs = window.getComputedStyle(body);
      var px = function(v) { var n = parseFloat(v); return isFinite(n) ? n : 0; };
      var left = rect.left + px(cs.borderLeftWidth) + px(cs.paddingLeft);
      var top = rect.top + px(cs.borderTopWidth) + px(cs.paddingTop);
      var right = rect.right - px(cs.borderRightWidth) - px(cs.paddingRight);
      var bottom = rect.bottom - px(cs.borderBottomWidth) - px(cs.paddingBottom);
      var vw = window.innerWidth || (document.documentElement && document.documentElement.clientWidth) || 0;
      var vh = window.innerHeight || (document.documentElement && document.documentElement.clientHeight) || 0;
      if (left < 0) left = 0;
      if (top < 0) top = 0;
      if (vw > 0 && right > vw) right = vw;
      if (vh > 0 && bottom > vh) bottom = vh;
      if (!(right > left) || !(bottom > top)) return null;
      return { left: left, top: top, right: right, bottom: bottom };
    } catch (err) {
      return null;
    }
  },
  // BUG-1797：这个字符真的可见吗（字形矩形与可见正文盒有正面积交集）。命中链上每个候选
  // 字符都要过这一关，页边距带里被 clip 掉的相邻页字符因此永远成不了查词/选词目标；跨在
  // 边界上、还露出半个的字符仍算可见（clip 后用户确实看得到，点它就该查得到）。
  // [box] 由调用方一次算好往下传：逐字符兜底扫描会跑上千次，每次现算 getComputedStyle
  // 就是上千次强制 reflow。拿不到盒（无 body / 退化几何）一律返回 true —— 这道守卫只负责
  // 拦下**确证不可见**的字符，绝不在几何未知时把正常查词一起拦掉。
  charRangeVisible: function(charRange, box) {
    if (typeof window.__fushiTextUnrevealed === 'function' &&
        window.__fushiTextUnrevealed(charRange.startContainer, charRange.startOffset)) return false;
    if (box === undefined) box = this.visibleContentBox();
    if (!box) return true;
    var rects = charRange.getClientRects();
    var list = (rects && rects.length) ? rects : [charRange.getBoundingClientRect()];
    for (var i = 0; i < list.length; i++) {
      var r = list[i];
      if (!r) continue;
      if (Math.min(r.right, box.right) > Math.max(r.left, box.left) &&
          Math.min(r.bottom, box.bottom) > Math.max(r.top, box.top)) {
        return true;
      }
    }
    return false;
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
  // BUG-1797：[box] 是调用方算好的可见正文盒（见 visibleContentBox），沿命中链往下传，
  // 逐字符兜底扫描才不会每个字符都现算一次 getComputedStyle。不传时自己算一份。
  getCaretRange: function(x, y, box) {
    if (box === undefined) box = this.visibleContentBox();
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
    // 查词卡顿（P2）：容器常常就是整章（点在页边 / 段落间时 elementFromPoint 落到 body 或
    // 正文外层 div），下面两遍逐字 getClientRects 会把全章每个字量两次。先按文本节点的行盒
    // 剪枝（caretScanCandidates），只逐字扫「可能被两遍任何一遍采纳」的节点。
    var candidates = this.caretScanCandidates(container, x, y, box);
    var range = document.createRange();
    var node;
    // 第一遍：精确包含（旧行为，零回归）。
    for (var ci = 0; ci < candidates.length; ci++) {
      node = candidates[ci];
      for (var i = 0; i < node.textContent.length; i++) {
        range.setStart(node, i);
        range.setEnd(node, i + 1);
        // BUG-1797：命中还不够，字符得真的可见 —— 页边距带里的相邻页字符会被这里剔掉。
        if (this.inCharRange(range, x, y) && this.charRangeVisible(range, box)) {
          range.collapse(true);
          return range;
        }
      }
    }
    // 第二遍（TODO-916 症状④）：精确全 miss 时回退到「最近字符」——仅当该字符在一个
    // 保守容差内（半行高，约半个字宽）才采纳，避免点空白处误选远字。walker 已 REJECT
    // furigana（rt/rp），故振假名永不被兜底命中；只放宽正文字符命中精度。
    var bestNode = null;
    var bestOffset = -1;
    var bestDistSq = Infinity;
    for (var cj = 0; cj < candidates.length; cj++) {
      node = candidates[cj];
      for (var j = 0; j < node.textContent.length; j++) {
        range.setStart(node, j);
        range.setEnd(node, j + 1);
        var distSq = this.charRangeDistanceSq(range, x, y);
        if (distSq >= bestDistSq) continue;
        var rect = range.getClientRects()[0] || range.getBoundingClientRect();
        if (!rect) continue;
        // BUG-1797：不可见字符不得参与「最近字符」竞争 —— 否则页边距带里的相邻页字符
        // 会以更近的距离抢走本页边缘字符的名额，落点从「查错词」变成「查不到词」。
        if (!this.charRangeVisible(range, box)) continue;
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
  // getCaretRange 逐字兜底的扫描范围：container 里 walker 接受的文本节点，去掉其中「没有
  // 一个字可能被两遍采纳」的节点（文档序不变）。剪枝只用必要条件，不设经验上限，所以命中
  // 结果与逐节点全扫逐位相同：
  //   - 字形盒落在所属文本节点的某个行盒（整节点 Range 的 getClientRects）之内；
  //   - 两遍都要求字可见（charRangeVisible：字形盒与可见正文盒 box 有正面积交集）⇒ 至少
  //     一个行盒与 box 有正面积交集；
  //   - 第一遍要点落在字形盒内（距离 0），第二遍要距离 <= tol = max(6, max(字宽, 字高)/2)，
  //     而字形盒在行盒内 ⇒ 点到行盒的距离 <= 点到字形盒的距离，字宽高 <= 行盒宽高
  //     ⇒ 点到该行盒的距离 <= max(6, max(行盒宽, 行盒高)/2)。
  // 两个条件分开判（一个字跨行时，量距离的首个字形盒与可见的那块可能落在不同行盒）：节点
  // 的行盒里既没有可见的、或没有够得着的，才跳过该节点。量不出行盒（空 / 隐藏节点）
  // 的节点一律保留，交给逐字判定原样处理。分页模式下相邻页 / 整章其余列的节点都在可见盒
  // 外，扫描面因此收敛到「当前页、点附近」的几行。
  caretScanCandidates: function(container, x, y, box) {
    var walker = this.createWalker(container);
    var probe = document.createRange();
    var out = [];
    var node;
    while (node = walker.nextNode()) {
      var len = node.textContent.length;
      if (!len) continue;
      probe.setStart(node, 0);
      probe.setEnd(node, len);
      var rects = probe.getClientRects();
      if (!rects || !rects.length) { out.push(node); continue; }
      var visible = !box;
      var near = false;
      for (var i = 0; i < rects.length && !(visible && near); i++) {
        var r = rects[i];
        if (!r) continue;
        if (!visible && Math.min(r.right, box.right) > Math.max(r.left, box.left) &&
            Math.min(r.bottom, box.bottom) > Math.max(r.top, box.top)) {
          visible = true;
        }
        if (!near) {
          var reach = Math.max(6, Math.max(r.width, r.height) / 2);
          var dx = x < r.left ? r.left - x : (x > r.right ? x - r.right : 0);
          var dy = y < r.top ? r.top - y : (y > r.bottom ? y - r.bottom : 0);
          near = dx * dx + dy * dy <= reach * reach;
        }
      }
      if (visible && near) out.push(node);
    }
    return out;
  },
  // BUG-长按选择不灵敏：命中测试拆成两层，因为**查词**和**选文本**对「这个点算不算
  // 命中」的要求根本不同。查词要的是一个可扫描的词首字，落在空白/标点上必须放弃
  // （否则拿标点去查词）；而文本选择要的只是「这里有字」——选中标点、选中句号完全
  // 正当。旧实现让两者共用带 isScanBoundary 剔除的这一个函数，于是长按落在标点、
  // 行首缩进、句读旁边时 lpsAllowed 直接返回 false，**连计时器都不 arm**，表现就是
  // 「长按了半天没反应、也没有高亮」。下层保留几何与可见性，上层只给查词加边界剔除。
  getCharacterAtPoint: function(x, y) {
    var hit = this.getSelectableCharacterAtPoint(x, y);
    if (!hit) return null;
    if (this.isScanBoundary(hit.node.textContent[hit.offset])) return null;
    return hit;
  },
  // 几何命中层：只回答「这个点上有没有一个**可见的**字」，不判断它是不是词边界。
  getSelectableCharacterAtPoint: function(x, y) {
    // BUG-1797：整条命中链共用同一个可见正文盒，一次 hit-test 只量一次几何。
    var box = this.visibleContentBox();
    var range = this.getCaretRange(x, y, box);
    if (!range) return null;
    var node = range.startContainer;
    if (node.nodeType !== Node.TEXT_NODE || this.isFurigana(node)) return null;
    var text = node.textContent;
    var caret = range.startOffset;
    var offsets = [caret, caret - 1, caret + 1];
    // 第一遍精确确认（旧行为，零回归）；TODO-916 症状④：精确全 miss 时第二遍带容差
    // （半字宽/行高）兜底，消除字缝/行距点不中。
    var pads = [0, 6];
    for (var p = 0; p < pads.length; p++) {
      for (var i = 0; i < offsets.length; i++) {
        var offset = offsets[i];
        if (offset < 0 || offset >= text.length) continue;
        var charRange = document.createRange();
        charRange.setStart(node, offset);
        charRange.setEnd(node, offset + 1);
        // BUG-1797：caretPositionFromPoint 的快路把落点 clamp 到最近字符，页边距上的点
        // 因此照样解析出一个字符；这里的可见性确认是「不可见就不可点」这条不变式在查词/
        // 选词全部入口（selectText / beginRangeSelection / updateRangeSelection /
        // moveSelectionHandle / tapHasCharacter）上的唯一收口。
        if (this.inCharRange(charRange, x, y, pads[p]) &&
            this.charRangeVisible(charRange, box)) {
          return { node: node, offset: offset };
        }
      }
    }
    return null;
  },
  // ---- 坐标 -> 文本位置（选区拖动端点解析层） --------------------------------
  //
  // 根因（用户报「长按拖选 / 拖手柄到字缝、行尾、段间空白，手柄就卡住、松手再拖也过不
  // 去」）：拖动路径原来**只**认几何命中 `getSelectableCharacterAtPoint`——它要求手指压
  // 在某个字符矩形上（先精确、再 ±6px）。字缝、行距、行尾/行首空白（text-indent、两端
  // 对齐的伸缩空隙、段间 margin）上没有任何字符矩形盖住手指，命中返回 null；于是
  // `updateRangeSelection` 把端点钉回锚点（整段选区当场塌回锚点字）、`moveSelectionHandle`
  // 直接 return（手柄视觉冻结）。修法不是把 ±6px 调大——那只是把卡住的位置推迟到下一个
  // 缝隙。这里补一层真正的「坐标 -> 文本位置」解析，语义与 Android
  // `TextView.getOffsetForPosition()` / Flutter `TextPainter.getPositionForOffset()` 一致：
  //
  //   手指坐标 -> 最近 caret（字符之间的位置）-> 方向修正 -> 端点字符 -> collectRangeBetween
  //
  // 三级解析（每级都过 BUG-1797 的可见性收口：分页页边距带里被 clip 掉的相邻页字符永不
  // 参与竞争，否则手柄会被拉到看不见的另一页文字上）：
  //   ① 原生 caret API（`caretPositionFromPoint` / `caretRangeFromPoint`）：Chrome WebView
  //      与 WKWebView 都实现了「最近 caret」语义（落在行距/字缝/行尾会按最近行盒 clamp），
  //      O(1)，绝大多数帧走这条。只认文本节点结果（BUG-765：手柄 div / documentElement
  //      的命中不可信），并复核相邻字符可见。
  //   ② 原生不可用 / 命中被遮挡 / 结果不可见时，在命中元素所在的**文本块**里逐字符几何
  //      扫描：交叉轴（横排 = y，竖排 = x）先定行，行内轴再按字符矩形中点规则定 caret
  //      （与 `Layout.getOffsetForHorizontal` 同判据）。扫描有界于块、有字符数上限。
  //   ③ 都失败 -> null。调用方保持旧端点（不收缩、不清高亮），旧路径零回归。
  //
  // 字符 (node, offset) 的 Range（按码点算 1~2 个 UTF-16 单元）。越界 / 非文本节点返回 null。
  charRangeAt: function(node, offset) {
    if (!node || node.nodeType !== Node.TEXT_NODE) return null;
    var text = node.textContent || '';
    if (offset < 0 || offset >= text.length) return null;
    var codePoint = text.codePointAt(offset);
    var length = (codePoint !== undefined && codePoint > 0xffff) ? 2 : 1;
    var range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, Math.min(offset + length, text.length));
    return range;
  },
  // 字符矩形的交叉轴 / 行内轴区间（横排：交叉轴 = y、行内轴 = x；竖排 vertical-rl：
  // 交叉轴 = x、行内轴 = y）。阅读方向（列内从上到下 / 行内从左到右）与偏移增长方向
  // 一致，故中点规则两个轴向共用一套判据。
  charAxisBounds: function(rect, vertical) {
    return {
      crossLo: vertical ? rect.left : rect.top,
      crossHi: vertical ? rect.right : rect.bottom,
      inlineLo: vertical ? rect.top : rect.left,
      inlineHi: vertical ? rect.bottom : rect.right,
    };
  },
  // 两个文本位置 (node, offset) 的文档序：-1 在前 / 0 同一位置 / 1 在后。判据与
  // collectRangeBetween 的端点排序同源（compareDocumentPosition）。
  compareTextPosition: function(nodeA, offsetA, nodeB, offsetB) {
    if (nodeA === nodeB) return offsetA < offsetB ? -1 : (offsetA > offsetB ? 1 : 0);
    if (!nodeA || !nodeB) return 0;
    return (nodeA.compareDocumentPosition(nodeB) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1;
  },
  // 空格分词词的边界 [start, end)（`isSpaceDelimitedLetter` + 词内撇号，与扫描模型同一套
  // 真值）。`index` 处的字符不属于这样的词（CJK / 标点 / 空白）时返回 null。
  spaceDelimitedWordBounds: function(text, index) {
    if (!text || index < 0 || index >= text.length) return null;
    if (!this.isSpaceDelimitedLetter(text[index])) return null;
    var start = index;
    var end = index + 1;
    while (start > 0 &&
        (this.isSpaceDelimitedLetter(text[start - 1]) || this.isIntraWordApostrophe(text, start - 1))) {
      start--;
    }
    while (end < text.length &&
        (this.isSpaceDelimitedLetter(text[end]) || this.isIntraWordApostrophe(text, end))) {
      end++;
    }
    return { start: start, end: end };
  },
  // 端点规范化：collectRangeBetween 的游走用 createWalker（REJECT 纯空白节点与振假名），
  // Endpoints must belong to the walker, not filtered whitespace / ruby nodes.
  // Prefer the drag direction, then the other side: no previous text at a leading
  // indent does NOT mean no body text. Only failure on both sides returns null.
  normalizeEndpoint: function(node, offset, forward) {
    if (!node || node.nodeType !== Node.TEXT_NODE) return null;
    var text = node.textContent || '';
    var walkable = text.length > 0 && !this.isFurigana(node) && !/^[\s　]*$/.test(text);
    if (walkable) return { node: node, offset: Math.max(0, Math.min(offset, text.length - 1)) };
    for (var attempt = 0; attempt < 2; attempt++) {
      var searchForward = attempt === 0 ? forward : !forward;
      var walker = this.createWalker(document.body);
      walker.currentNode = node;
      var adjacent = searchForward ? walker.nextNode() : walker.previousNode();
      if (adjacent) {
        return { node: adjacent, offset: searchForward ? 0 : adjacent.textContent.length - 1 };
      }
    }
    return null;
  },
  // caret (node, offset) 相邻字符里有没有可见的（BUG-1797 可见性收口）。相邻 = caret 左右
  // 各一个字；都不在（节点首尾 / 都不可见）时返回 false，交给几何兜底再试。
  caretHasVisibleNeighbour: function(node, offset, box) {
    var offsets = [offset - 1, offset];
    for (var i = 0; i < offsets.length; i++) {
      var range = this.charRangeAt(node, offsets[i]);
      if (!range) continue;
      if (this.charRangeVisible(range, box)) return true;
    }
    return false;
  },
  // ① 原生 caret 快路。返回 {node, offset}（caret 语义，offset ∈ [0, len]）或 null。
  nativeCaretAtPoint: function(x, y, box) {
    // Presence does not imply success: null / element / invisible results must
    // try the range dialect before resorting to geometric hit-testing.
    for (var api = 0; api < 2; api++) {
      var node = null;
      var offset = 0;
      try {
        if (api === 0 && document.caretPositionFromPoint) {
          var pos = document.caretPositionFromPoint(x, y);
          if (pos) { node = pos.offsetNode; offset = pos.offset; }
        } else if (api === 1 && document.caretRangeFromPoint) {
          var range = document.caretRangeFromPoint(x, y);
          if (range) { node = range.startContainer; offset = range.startOffset; }
        }
      } catch (err) {
        // A WebView may expose an unsupported native entry point. Try the other.
        continue;
      }
      if (!node || node.nodeType !== Node.TEXT_NODE || this.isFurigana(node)) continue;
      if (!this.caretHasVisibleNeighbour(node, offset, box)) continue;
      return { node: node, offset: offset };
    }
    return null;
  },
  // Fallback for callers outside the shared transparent endpoint window. Skip
  // grips in the stack when available; a single-point hit on a grip is no text.
  _hitElementUnderPoint: function(x, y) {
    var isHandle = function(candidate) {
      return !!(candidate && candidate.closest &&
        candidate.closest('[data-fushi-sel-handle]'));
    };
    if (document.elementsFromPoint) {
      var stack = document.elementsFromPoint(x, y) || [];
      for (var i = 0; i < stack.length; i++) {
        if (isHandle(stack[i])) continue;
        if (stack[i]) return stack[i];
      }
      return null;
    }
    var single = document.elementFromPoint(x, y);
    if (isHandle(single)) return null;
    return single;
  },
  // ② 几何兜底：在命中元素所在的文本块里逐字符扫描，按「交叉轴最近 -> 行内轴最近」定
  // caret。交叉轴优先是关键：行距/段距里的点必须先归到最近的**行**，否则拖到行尾右侧时
  // 下一行的字在内联轴上贴着手指、交叉轴只差一个行距，端点会跳行。行内轴按字符矩形的
  // 中点规则取前沿/后沿：落在字符前的空隙取前沿、字符后的空隙取后沿 -> 行尾右侧空白
  // clamp 到行尾（最后一个字被包含）、行首左侧空白 clamp 到行首。
  // 有界：根 = 命中元素所在的块（绝不落到整个 body），并且有字符数上限。
  geometricCaretAtPoint: function(x, y, box) {
    var el = this._hitElementUnderPoint(x, y);
    if (!el) return null;
    var container = (el.closest && el.closest('p, div, span, ruby, a')) || document.body;
    if (!container) return null;
    var vertical = this._selectionVertical();
    var inlineCoord = vertical ? y : x;
    var crossCoord = vertical ? x : y;
    var walker = this.createWalker(container);
    var best = null;
    var scanned = 0;
    var node;
    while ((node = walker.nextNode()) && scanned < 4000) {
      var text = node.textContent || '';
      for (var i = 0; i < text.length && scanned < 4000;) {
        var codePoint = text.codePointAt(i);
        var charLength = (codePoint !== undefined && codePoint > 0xffff) ? 2 : 1;
        var charRange = this.charRangeAt(node, i);
        scanned++;
        if (charRange && this.charRangeVisible(charRange, box)) {
          var rects = charRange.getClientRects();
          for (var r = 0; r < rects.length; r++) {
            var rect = rects[r];
            if (!rect || !(rect.width > 0) || !(rect.height > 0)) continue;
            var bounds = this.charAxisBounds(rect, vertical);
            var crossDist = crossCoord < bounds.crossLo ? bounds.crossLo - crossCoord
              : (crossCoord > bounds.crossHi ? crossCoord - bounds.crossHi : 0);
            var inlineDist = inlineCoord < bounds.inlineLo ? bounds.inlineLo - inlineCoord
              : (inlineCoord > bounds.inlineHi ? inlineCoord - bounds.inlineHi : 0);
            if (best && (crossDist > best.crossDist ||
                (crossDist === best.crossDist && inlineDist >= best.inlineDist))) continue;
            // 中点规则：点越过字符中线（或已在其后沿之外）-> 取后沿（下一个字符的前面 /
            // 行尾）；否则取前沿。
            var afterGlyph = inlineCoord > bounds.inlineHi ||
              (inlineCoord >= bounds.inlineLo &&
               inlineCoord >= (bounds.inlineLo + bounds.inlineHi) / 2);
            best = {
              node: node,
              offset: afterGlyph ? i + charLength : i,
              crossDist: crossDist,
              inlineDist: inlineDist
            };
          }
        }
        i += charLength;
      }
    }
    return best ? { node: best.node, offset: best.offset } : null;
  },
  // 坐标 -> caret：原生快路 -> 几何兜底 -> null。[box] 由调用方复用（一次拖动只在需要时量
  // 一次几何）；不传时自己算一份。
  caretPositionAtPoint: function(x, y, box) {
    if (box === undefined) box = this.visibleContentBox();
    var native = this.nativeCaretAtPoint(x, y, box);
    if (native) return native;
    return this.geometricCaretAtPoint(x, y, box);
  },
  // 拖动入口的端点解析（唯一出口）：
  //   [strictHit] 严格几何命中的字符（getSelectableCharacterAtPoint 的结果，可为 null）；
  //   (refNode, refOffset) 定锚端，用来判定这次拖动是向锚点之后扩（forward）还是之前缩。
  // 返回 {node, offset, forward}，或 null（解析失败 -> 调用方保持旧选区，绝不收缩）。
  // 严格命中优先 = 旧行为零回归（手指压在字符矩形上时端点就是那个字）；只有严格命中落空
  // （字缝 / 行距 / 行尾 / 行首等没有字符矩形盖住手指的点）才走「坐标 -> 文本位置」解析。
  resolveSelectionEndpoint: function(x, y, strictHit, refNode, refOffset) {
    var node = null;
    var offset = 0;
    var forward = true;
    if (strictHit) {
      node = strictHit.node;
      offset = strictHit.offset;
      forward = this.compareTextPosition(node, offset, refNode, refOffset) >= 0;
    } else {
      var box = this.visibleContentBox();
      var caret = this.caretPositionAtPoint(x, y, box);
      if (!caret) return null;
      forward = this.compareTextPosition(caret.node, caret.offset, refNode, refOffset) > 0;
      // caret 是**字符之间**的位置：正向（往锚点之后拖）取 caret 前一个字符，反向取 caret
      // 所在字符 —— 与 collectRangeBetween「端点字符计入区间」的语义配套。
      var neighbour = forward
        ? this.charBefore(caret.node, caret.offset)
        : this.charAt(caret.node, caret.offset);
      if (!neighbour || !neighbour.node) return null;
      node = neighbour.node;
      offset = neighbour.offset;
      // BUG-1797：端点必须是**可见**字符。分页页边距带里被 clip 掉的相邻页字符可以被
      // clamp 命中（布局期几何仍在），但用户看不见它 —— 那种点解析不出端点，保持旧端点，
      // 绝不把选区拉到看不见的另一页文字上。
      var endpointRange = this.charRangeAt(node, offset);
      if (!endpointRange || !this.charRangeVisible(endpointRange, box)) return null;
    }
    var endpoint = this.normalizeEndpoint(node, offset, forward);
    if (!endpoint) return null;
    var normalizedRange = this.charRangeAt(endpoint.node, endpoint.offset);
    if (!normalizedRange || !this.charRangeVisible(normalizedRange, this.visibleContentBox())) return null;
    return { node: endpoint.node, offset: endpoint.offset, forward: forward };
  },
  // Strict hit AND caret/geometric resolution share one transparent window.
  // No visual hiding, no dependence on elementsFromPoint; restore even on throw.
  selectionEndpointAtPoint: function(x, y, refNode, refOffset) {
    var handles = this.selectionHandles;
    var savedStartPe = handles ? handles.start.style.pointerEvents : null;
    var savedEndPe = handles ? handles.end.style.pointerEvents : null;
    try {
      if (handles) {
        handles.start.style.pointerEvents = 'none';
        handles.end.style.pointerEvents = 'none';
      }
      var hit = this.getSelectableCharacterAtPoint(x, y);
      return this.resolveSelectionEndpoint(x, y, hit, refNode, refOffset);
    } finally {
      if (handles) {
        handles.start.style.pointerEvents = savedStartPe;
        handles.end.style.pointerEvents = savedEndPe;
      }
    }
  },
  // 长按定锚的锚点区间：空格分词词里长按 -> 整词锚点（词首..词末），原地长按即选中整词、
  // 向两侧拖动都不丢词尾；CJK / 标点 / 空白 -> 单字锚点（与 BUG-609 起的老行为一致）。
  selectionAnchorAtHit: function(hit) {
    var bounds = this.spaceDelimitedWordBounds(hit.node.textContent, hit.offset);
    if (!bounds) {
      return { node: hit.node, offset: hit.offset, endNode: hit.node, endOffset: hit.offset };
    }
    return { node: hit.node, offset: bounds.start, endNode: hit.node, endOffset: bounds.end - 1 };
  },
  getSentenceContext: function(startNode, startOffset) {
    // BUG-3630：视觉小说模式只把一屏的切片克隆进 document，切屏可以落在一句话中间
    // （「…ミステリ書」|「きと同じ…」）。在克隆上取句会把句子截在屏首 / 屏尾，制卡只拿到
    // 半句。阅读器能把克隆位置换回源章节时，在源章节上按同一套标点规则取句——三种阅读
    // 模式的句子边界因此一致（分页 / 连续本就是整章 DOM，没有这个钩子，原地取句）。
    // 返回的 sStart / sEnd 节点随之是源节点，归一化 / 音频偏移由阅读器按源节点换算。
    var reader = window.fushiReader;
    if (reader && typeof reader.sourceTextPosition === 'function') {
      var source = reader.sourceTextPosition(startNode, startOffset);
      if (source && source.node && source.node !== startNode) {
        return this.getSentenceContext(source.node, source.offset);
      }
    }
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
      var laterNode = node;
      node = walker.previousNode();
      // 无标点听写稿：cue 边界即句界（见 isUnpunctuatedCueBoundary）。
      if (node && this.isUnpunctuatedCueBoundary(node, laterNode)) break;
      if (node) {
        limit = node.textContent.length;
        // BUG-3453：被跳过的空白缝还原成一个空格（partsBefore 最后反转拼接）。
        if (this.hasSkippedWhitespaceBetween(node, laterNode) &&
            this.isWordGapBetweenChars(node.textContent, laterNode.textContent)) {
          partsBefore.push(' ');
        }
      }
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
      var earlierNode = node;
      node = walker.nextNode();
      start = 0;
      if (node && this.isUnpunctuatedCueBoundary(earlierNode, node)) break;
      // BUG-3453：同上，向后拼接时也把被跳过的空白缝还原成一个空格。
      if (node && this.hasSkippedWhitespaceBetween(earlierNode, node) &&
          this.isWordGapBetweenChars(earlierNode.textContent, node.textContent)) {
        partsAfter.push(' ');
      }
    }
    var beforeText = partsBefore.reverse().join('');
    // BUG-2196：换行在 HTML 里等价于空格。**等长**替换（1 字符换 1 字符），
    // 因此 beforeText.length / sentenceOffset / sStartOffset / sEndOffset 与
    // getNormalizedOffset 的下标全部保持不变——用 \s+ 折叠会把偏移打乱，
    // 进而毁掉喂给 miningSentenceAudioRange 的 normOffset/normLength。
    var rawSentence = (beforeText + partsAfter.join(''))
        .replace(/[\n\r]/g, ' ');
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
      var prevNode = node;
      node = walker.nextNode();
      // BUG-3453：与 getSentenceContext 同一规则还原被跳过的词间空白缝。
      if (node && this.hasSkippedWhitespaceBetween(prevNode, node) &&
          this.isWordGapBetweenChars(prevNode.textContent, node.textContent)) {
        parts.push(' ');
      }
    }
    if (!reachedEnd) return '';
    return parts.join('');
  },
  // TODO-393：从「当前查词句」往前 / 往后逐句采集上下文（制卡「上 N 句 / 下 N 句」）。
  // 以当前 this.selection 的起点定位当前句边界，再用 getSentenceContext 从「当前句首
  // 的前一个字符」继续往前取上一句、从「当前句尾的后一个字符」往后取下一句，逐句迭代。
  // 每条返回 sentence 文本 + （有 window.fushiReader 时）整书归一化偏移，供宿主裁句子
  // 音频区间。到段首 / 文首（无更多字符）即止，故实际句数可能少于请求数。
  getSurroundingSentences: function(prevCount, nextCount) {
    var result = { prev: [], next: [] };
    if (!this.selection) return result;
    var self = this;
    var describe = function(ctx) {
      var entry = { sentence: ctx.sentence };
      if (window.fushiReader) {
        var s = self.getMatchableOffset(ctx.sStartNode, ctx.sStartOffset);
        var e = self.getMatchableOffset(ctx.sEndNode, ctx.sEndOffset);
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
    // Clip against the actual Range. Element offsets are child indexes, not
    // text offsets; descending to the element's first child shifts selections.
    // Use the same visible-text walker as lookup, excluding ruby annotations.
    var walker = this.createWalker(document.body);
    var selected = [];
    var node;
    while ((node = walker.nextNode()) != null) {
      if (!range.intersectsNode(node)) continue;
      var start = node === range.startContainer ? range.startOffset : 0;
      var end = node === range.endContainer ? range.endOffset : node.textContent.length;
      if (end > start) selected.push({ node: node, start: start, end: end });
    }
    if (!selected.length) return null;
    var first = selected[0], last = selected[selected.length - 1];
    var startNode = first.node, startOffset = first.start;
    var endNode = last.node, endOffset = last.end;
    text = selected.map(function(part) {
      return part.node.textContent.slice(part.start, part.end);
    }).join('');
    var rubyReadings = this.rubyReadingSpans(selected, text);
    var sentenceContext = this.getSentenceContext(startNode, startOffset);
    var normalizedOffset = window.fushiReader
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
    if (window.fushiReader) {
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
    var match = this.matchableRange(startNode, startOffset, endNode, endOffset);
    var matchSentence = this.matchableRange(
      sentenceContext.sStartNode, sentenceContext.sStartOffset,
      span && span.merged ? span.sEndNode : sentenceContext.sEndNode,
      span && span.merged ? span.sEndOffset : sentenceContext.sEndOffset);
    return {
      matchableOffset: match.offset,
      matchableLength: match.length,
      sentenceMatchableOffset: matchSentence.offset,
      sentenceMatchableLength: matchSentence.length,
      text: text,
      rubyReadings: rubyReadings,
      sentence: sentence,
      audioCuePayload: window.fushiReader && window.fushiReader.cueIdAtDomPoint
        ? window.fushiReader.cueIdAtDomPoint(startNode, startOffset) : null,
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
  // URL（fushi.local/epub/...），normOffset 是该图在整书归一化文本坐标里的位置（用相邻文本
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
  // （图排在这句之前），取不到再退到图**前**最后一个文本节点的末端偏移。无 fushiReader
  // （无归一化映射）时返回 null，宿主兜底挂到最前一段。
  imageNormOffset: function(el) {
    if (!window.fushiReader) return null;
    var w = this.createWalker(document.body);
    w.currentNode = el;
    var after = w.nextNode();
    if (after) {
      var o = this.getMatchableOffset(after, 0);
      if (o !== null) return o;
    }
    var w2 = this.createWalker(document.body);
    w2.currentNode = el;
    var before = w2.previousNode();
    if (before) {
      var o2 = this.getMatchableOffset(before, before.textContent.length);
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
  // 振假名 toggle 态（ReaderSettings.furiganaMode == 'toggle'，CSS 把未揭示 ruby 的
  // rt 设成 visibility:hidden）：命中这样的 ruby 时返回它，调用方只揭示不查词。
  // 判据读注音的**计算样式**而不是某个模式旗——设置热切换只重发 CSS，读旗会过期；
  // hidden 态 rt 是 display:none（不算），快捷键 show-all-rt 揭示后 visible（不算）。
  _hiddenFuriganaRubyAt: function(x, y) {
    var el = document.elementFromPoint(x, y);
    var ruby = el && el.closest ? el.closest('ruby') : null;
    if (!ruby || ruby.classList.contains('furigana-revealed')) return null;
    var rt = ruby.querySelector('rt');
    if (!rt) return null;
    var cs = getComputedStyle(rt);
    if (cs.display === 'none' || cs.visibility !== 'hidden') return null;
    return ruby;
  },
  selectText: function(x, y, maxLength, fromHover) {
    if (document.elementFromPoint(x, y)?.closest('a')) {
      return null;
    }
    // Hoshi Reader iOS Toggle 语义：点隐藏注音的 ruby = 揭示它，这一下不查词、
    // 也不算点空白（不 fire onTapEmpty）；悬停查词（fromHover）不揭示。
    if (!fromHover) {
      var hiddenRuby = this._hiddenFuriganaRubyAt(x, y);
      if (hiddenRuby) {
        hiddenRuby.classList.add('furigana-revealed');
        this.clearSelection();
        return null;
      }
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
    // Hover identity uses the matched word, not the entire forward scan buffer.
    // The latter can contain the rest of the sentence and would block new words.
    if (fromHover && this.selection) {
      var insideMatch = (this.selection.matchedRanges || []).some(function(r) {
        return hit.node === r.node && hit.offset >= r.start && hit.offset < r.end;
      });
      var wrapper = hit.node.parentElement && hit.node.parentElement.closest('.fushi-dict-highlight');
      if (insideMatch || (wrapper && this.highlightWrappers.indexOf(wrapper) >= 0)) return null;
      // Before lookup finishes, normalize Latin hits just as selectFromPosition
      // does so hovering a different letter does not enqueue the same lookup.
      var content = hit.node.textContent;
      var offset = hit.offset;
      if (offset < content.length && !this.isCodePointJapanese(content.codePointAt(offset))) {
        while (offset > 0 && !this.isTokenStartBoundary(content[offset - 1])) offset--;
      }
      if (hit.node === this.selection.startNode && offset === this.selection.startOffset) return null;
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
    return this.selectFromPosition(hit.node, hit.offset, maxLength, x, y, fromHover);
  },
  // Build the dictionary selection starting at (node, offset): expand a
  // non-Japanese hit left to its token start, scan forward up to maxLength
  // characters, compute the sentence + whole-book normalized offsets, and fire
  // onTextSelected. Shared by the coordinate (tap) path and the keyboard/gamepad
  // caret path. x/y are optional — the caret path omits them, in which case the
  // selection rect falls back to the first character's bounding box. The caller
  // is responsible for clearing any prior selection first.
  selectFromPosition: function(node, offset, maxLength, x, y, fromHover) {
    var startNode = node;
    var startOffset = offset;
    var hitContent = startNode.textContent;
    if (startOffset < hitContent.length && !this.isCodePointJapanese(hitContent.codePointAt(startOffset))) {
      while (startOffset > 0 && !this.isTokenStartBoundary(hitContent[startOffset - 1])) {
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
        // BUG-2056：词内撇号先于终点判定跨过去（don’t 不被截成 don）。
        if (this.isIntraWordApostrophe(content, scanOffset)) {
          text += char;
          scanOffset++;
          continue;
        }
        if (this.isScanStop(char)) break;
        // BUG-1773：空白只当**同一文本节点内**的词间连接符跨过去，且只跨一个：
        // 左边必须已有本节点扫入的内容（`scanOffset === start` 即本节点开头，不桥接），
        // 右边必须紧跟一个可扫字符。于是本节点开头/末尾的空白、连续空白、空白后接
        // 标点一律终止——跨节点续扫走下面的 walker 分支，新节点开头的空白照样不吃，
        // 「跨块级空白把两段正文粘成一个词」不会发生。
        // 已知取舍：`<b>listen</b> to` 这种被行内标签劈开的短语仍查不到短语（空白落在
        // 新节点开头）。真实 EPUB 里罕见，换来的是零跨块粘连风险。
        if (this.isScanWhitespace(char)) {
          var nextChar = content[scanOffset + 1];
          if (scanOffset === start || nextChar === undefined ||
              this.isScanWhitespace(nextChar) || this.isScanStop(nextChar)) break;
        }
        text += char;
        scanOffset++;
      }
      if (scanOffset > start) ranges.push({ node: scanNode, start: start, end: scanOffset });
      if (scanOffset < content.length || text.length >= maxLength) break;
      var scannedNode = scanNode;
      scanNode = walker.nextNode();
      scanOffset = 0;
      // BUG-3453：两个节点之间夹着被 createWalker 跳过的空白节点（有声书 cue wrapper 之间
      // 的空格）= 新节点开头的空白，按 BUG-1773 同一规则终止，不把下一条 cue 的词粘上来。
      if (scanNode && this.hasSkippedWhitespaceBetween(scannedNode, scanNode) &&
          this.isWordGapBetweenChars(text)) break;
    }
    if (!text) return null;
    this.selection = { startNode: startNode, startOffset: startOffset, ranges: ranges, text: text };
    // BUG-3665：记下点击点，[highlightSelection] 用它挑出用户点中的那一段字形当锚点。
    if (typeof x === 'number' && typeof y === 'number' && isFinite(x) && isFinite(y)) {
      this.selection.point = { x: x, y: y };
    }
    return this.fireTextSelected(x, y, fromHover);
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
    var mangaPageIndex = mangaPage
      ? Number(mangaPage.getAttribute('data-page')) : null;
    if (!Number.isInteger(mangaPageIndex) || mangaPageIndex < 0) {
      mangaPageIndex = null;
    }
    var mangaGroupNumber = mangaGroup !== null ? Number(mangaGroup) : null;
    if (!Number.isInteger(mangaGroupNumber) || mangaGroupNumber < 0) {
      mangaGroupNumber = null;
    }
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
    var normalizedOffset = window.fushiReader ? this.getNormalizedOffset(startNode, startOffset) : null;
    var normalizedLength = null;
    if (normalizedOffset !== null && ranges.length > 0) {
      var lastRange = ranges[ranges.length - 1];
      var normalizedEnd = this.getNormalizedOffset(lastRange.node, lastRange.end);
      if (normalizedEnd !== null) normalizedLength = Math.max(0, normalizedEnd - normalizedOffset);
    }
    var sentenceNormalizedOffset = null;
    var sentenceNormalizedLength = null;
    if (window.fushiReader) {
      var snStart = this.getNormalizedOffset(sentenceContext.sStartNode, sentenceContext.sStartOffset);
      var snEnd = this.getNormalizedOffset(sentenceContext.sEndNode, sentenceContext.sEndOffset);
      if (snStart !== null && snEnd !== null) {
        sentenceNormalizedOffset = snStart;
        sentenceNormalizedLength = Math.max(0, snEnd - snStart);
      }
    }
    var lastSelectedRange = ranges.length ? ranges[ranges.length - 1] : null;
    var match = lastSelectedRange
      ? this.matchableRange(startNode, startOffset, lastSelectedRange.node, lastSelectedRange.end)
      : { offset: null, length: null };
    var matchSentence = this.matchableRange(
      sentenceContext.sStartNode, sentenceContext.sStartOffset,
      sentenceContext.sEndNode, sentenceContext.sEndOffset);
    return {
      matchableOffset: match.offset,
      matchableLength: match.length,
      sentenceMatchableOffset: matchSentence.offset,
      sentenceMatchableLength: matchSentence.length,
      text: text,
      rubyReadings: this.rubyReadingSpans(ranges, text),
      sentence: mangaSentence !== null && mangaSentence !== ''
        ? mangaSentence : sentenceContext.sentence,
      rect: mangaGroupRect || this.getSelectionRect(x, y),
      // BUG-3604: the sentence-group rect can fill (or, zoomed in, exceed) the
      // whole viewport, leaving no room around it. Carry the tapped glyph too
      // so the host can fall back to anchoring next to the word.
      glyphRect: mangaGroupRect ? this.getSelectionRect(x, y) : null,
      audioCuePayload: window.fushiReader && window.fushiReader.cueIdAtDomPoint
        ? window.fushiReader.cueIdAtDomPoint(startNode, startOffset) : null,
      normalizedOffset: normalizedOffset,
      normalizedLength: normalizedLength,
      sentenceOffset: mangaSentence !== null && mangaSentence !== ''
        ? 0 : sentenceContext.sentenceOffset,
      sentenceNormalizedOffset: sentenceNormalizedOffset,
      sentenceNormalizedLength: sentenceNormalizedLength,
      verticalWriting: verticalWriting,
      mangaPageIndex: mangaPageIndex,
      // Sentence group of the hit OCR block. The host maps it back to the
      // page's OCR blocks to get the sentence rect in source-image space
      // (card-image cropping); the viewport rect above cannot provide that.
      mangaSentenceGroup: mangaGroupNumber
    };
  },
  // Fire onTextSelected for the current this.selection (tap/word lookup path and
  // the caret/keyboard path). Goes straight to the dictionary/mining popup.
  // fromHover tells the host this lookup came from a pointer sweep (Shift-hover /
  // hover lookup), not an explicit tap — the host skips paid per-lookup work
  // (AI headword pick) for those; see ReaderSelectionData.fromHover.
  fireTextSelected: function(x, y, fromHover) {
    var payload = this.buildSelectionPayload(x, y);
    if (!payload) return null;
    payload.fromHover = !!fromHover;
    // 歌词文档（lyrics_mode_html 覆写 selectText / 歌词光标 _setCueContext）在选词前把
    // 命中 cue 写进 window.__lyricsCueContext。随 payload 一起带走，宿主不必在查词前再
    // 单独 eval 一次去读它（同一时刻的同一个值，少一个 JS 来回）。没有这个全局的文档
    // （正文）不带这个键，宿主照旧行为。
    if ('__lyricsCueContext' in window) {
      payload.lyricsCueContext = window.__lyricsCueContext || null;
    }
    // 宿主处理完这次查词（callHandler 的 Promise 在 Dart 回调 await 完后兑现）的回执，
    // 供悬停查词做背压：回执到之前只留最后一个悬停位置（见 webview.part.dart 的
    // _fushiHoverLookup*）。点按路径不读它，行为不变。
    // selectedSeq 随 payload 带给宿主：回执之外，宿主处理完（成功或失败）还会按这个序号
    // 显式调 window.__fushiHoverLookupSettled(seq) 释放背压，两条释放路按序号对账。
    var seq = (this.textSelectedSeq || 0) + 1;
    this.textSelectedSeq = seq;
    payload.selectedSeq = seq;
    var ack = window.flutter_inappwebview.callHandler('onTextSelected', JSON.stringify(payload));
    this.lastTextSelectedAck = ack;
    return payload.text;
  },
  // TODO-1317: mobile long-press *drag*-select ends here instead of firing
  // lookup directly. Dart shows a selection menu (Copy / Lookup) so a plain-text
  // range selection (copy) and lookup/mining coexist -- the user is no longer
  // forced into an immediate lookup. this.selection (and its fushi-selection
  // highlight) is kept so the menu overlays the live selection; Dart clears it on
  // copy/dismiss, or converges it to the match on lookup.
  fireSelectionMenu: function(x, y) {
    var payload = this.buildSelectionPayload(x, y);
    if (!payload) return null;
    // Viewport CSS pixels, including BOTH 32px touch targets. Lookup's
    // single-glyph getSelectionRect remains unchanged.
    payload.handlesRect = this.selectionHandlesRect();
    // 两个球**各自**的触控盒：宿主避让操作条要按单个球算 —— 只有并集 bbox 时，两球之间
    // 的整段正文空白也算成障碍（竖排长选区里 bbox 一路延伸到末字球），宿主在页顶"上方
    // 放不下"就只能翻到 bbox 底端，操作条于是掉到选区尾部下方。
    payload.handlesBoxes = this.selectionHandlesBoxes();
    window.flutter_inappwebview.callHandler('onSelectionMenu', JSON.stringify(payload));
    return payload.text;
  },
  // -- TODO-1317: mobile long-press drag-select --------------------------------
  // Direction B: keep TODO-1279's `@media (pointer: coarse) user-select:none`
  // (touch never builds a native blue selection -> no double selection) and
  // instead drive the *app-drawn* selection (this.selection + CSS Custom
  // Highlight `fushi-selection`) from a long-press drag. These never call
  // window.getSelection()/addRange, so no native selection is ever created. On
  // release a real drag hands Dart a selection menu (fireSelectionMenu ->
  // onSelectionMenu) offering Copy / Lookup so plain-text selection (copy) and
  // lookup/mining coexist. The anchor glyph is selected as soon as the long-press
  // threshold fires, so a stationary long-press behaves like Hoshi/Android's
  // native text selection instead of requiring a hidden extra drag.
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
    if (window.__fushiCssHighlightsSupported) {
      this.highlightSelection(this.selection.text.length + 1);
    }
  },
  beginRangeSelection: function(x, y) {
    var el = document.elementFromPoint(x, y);
    if (el && el.closest && el.closest('a')) return false;
    var hit = this.getSelectableCharacterAtPoint(x, y);
    if (!hit) return false;
    // Clearing legacy wrappers unwraps + normalizes text nodes, invalidating
    // hits obtained before that mutation. Resolve against the resulting DOM.
    var hadWrappers = this.highlightWrappers.length > 0;
    this.clearSelection();
    if (hadWrappers) hit = this.getSelectableCharacterAtPoint(x, y);
    if (!hit) return false;
    // 锚点区间：空格分词词里长按定的是整词（原地长按即选中整词 —— 浏览器 / Android 长按
    // 的语义），CJK / 标点 / 空白定的是单字（与 BUG-609 起的老行为一致）。
    var anchor = this.selectionAnchorAtHit(hit);
    this.dragAnchor = {
      node: anchor.node, offset: anchor.offset,
      endNode: anchor.endNode, endOffset: anchor.endOffset,
      startX: x, startY: y, moved: false
    };
    // Establish and paint the anchor glyph immediately. This is the feedback the
    // native Android selection path gives at long-press time; the old path only
    // armed an anchor and made selection contingent on a later drag.
    //
    // 这里**直接画锚点区间**，不经过端点解析：手指此刻还压在这次长按的锚点上，解析会把
    // 端点收到手指所在的那一个字、把刚定下的词截成半截。浏览器同理——不拖就不动；拖动
    // 由 touchmove 的 updateRangeSelection 负责，那边端点逐字跟随手指（不再有词边界吸附），
    // 所以拉丁文本照样能选到词内的任意字符。
    var built = this.collectRangeBetween(
      anchor.node, anchor.offset, anchor.endNode, anchor.endOffset);
    if (built) {
      this.selection = {
        startNode: built.startNode, startOffset: built.startOffset,
        ranges: built.ranges, text: built.text
      };
      this.renderSelectionHighlight();
      this.showSelectionHandles();
      this.notifySelectionDragStarted();
      return true;
    }
    this.clearSelection();
    return false;
  },
  notifySelectionDragStarted: function() {
    if (window.flutter_inappwebview &&
        typeof window.flutter_inappwebview.callHandler === 'function') {
      window.flutter_inappwebview.callHandler('onSelectionDragStarted');
    }
  },
  liveDragAnchor: function() {
    var anchor = this.dragAnchor;
    return !!(anchor && this.liveSelectionPoint(anchor.node, anchor.offset) &&
      this.liveSelectionPoint(anchor.endNode, anchor.endOffset) && this.selectionEndpoints());
  },
  updateRangeSelection: function(x, y) {
    if (!this.dragAnchor) return null;
    if (!this.liveDragAnchor()) { this.clearSelection(); return null; }
    var anchor = this.dragAnchor;
    if (x !== anchor.startX || y !== anchor.startY) anchor.moved = true;
    if (!anchor.moved) return this.selection ? this.selection.text : null;
    // 端点**始终**跟随手指：压在字符矩形上就用那个字，落在字缝 / 行距 / 行尾 / 行首等没有
    // 字符矩形的位置就走「坐标 -> 文本位置」解析（Android TextView.getOffsetForPosition 语义），
    // 端点才能连续跟随手指。锚点区间只是长按那一刻选中的初始范围（浏览器语义：不拖不动），
    // 拖动可以自由收缩到词内、也可以越过词尾向外扩 —— 这里刻意**不**保留「落在锚点区间内
    // 就维持锚点」的粘滞判定：那会让拉丁词永远只按整词进退、选不到词内的任意字符（用户
    // 报「拉丁语言没法随意选择字符」的根因，与网上的实现不一致）。
    var endpoint = this.selectionEndpointAtPoint(x, y, anchor.node, anchor.offset);
    if (!endpoint) return null;
    var built = endpoint.forward
      ? this.collectRangeBetween(anchor.node, anchor.offset, endpoint.node, endpoint.offset)
      : this.collectRangeBetween(endpoint.node, endpoint.offset, anchor.endNode, anchor.endOffset);
    if (!built) return null;
    this.selection = {
      startNode: built.startNode, startOffset: built.startOffset,
      ranges: built.ranges, text: built.text
    };
    this.renderSelectionHighlight();
    this.positionSelectionHandles();
    return built.text;
  },
  // Finalize the long-press selection: extend to the release point, then present
  // the selection menu (Copy / Lookup). `beginRangeSelection` already selected
  // the anchor glyph, so this also handles a stationary long-press.
  // TODO-1317: a real drag no longer fires lookup directly -- it keeps
  // this.selection (highlight stays up) and hands Dart a menu so a plain-text
  // range selection (copy) and lookup/mining coexist instead of forcing lookup.
  endRangeSelection: function(x, y) {
    // A late touchend after clear / DOM replacement must not confirm a lookup
    // selection established by a different action in the meantime.
    if (!this.dragAnchor) return false;
    if (!this.liveDragAnchor()) { this.clearSelection(); return false; }
    // Stationary holds retain the word; an actual drag consumes the release
    // coordinate, which need not have arrived in the last touchmove event.
    if (this.dragAnchor && this.dragAnchor.moved) this.updateRangeSelection(x, y);
    if (!this.dragAnchor) return false;
    this.dragAnchor = null;
    if (!this.selection || !this.selection.text) {
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
  // semantics honour the writing mode via fushiReader.isVertical(). The grips
  // only ever mutate the app-drawn selection, never the browser's native one, so
  // no double selection is created (TODO-1279).
  _selectionVertical: function() {
    if (window.fushiReader && typeof window.fushiReader.isVertical === 'function') {
      return window.fushiReader.isVertical();
    }
    return window.getComputedStyle(document.body).writingMode === 'vertical-rl';
  },
  // Visual endpoints of the current selection as {startNode, startOffset (first
  // glyph), endNode, endOffset (index of the last glyph = one before range end)}.
  // null when there is no live glyph selection.
  liveSelectionPoint: function(node, offset) {
    return !!(node && node.nodeType === Node.TEXT_NODE && node.isConnected &&
      document.body.contains(node) && offset >= 0 && offset < node.textContent.length);
  },
  selectionEndpoints: function() {
    if (!this.selection || !this.selection.ranges || !this.selection.ranges.length) {
      return null;
    }
    for (var i = 0; i < this.selection.ranges.length; i++) {
      var segment = this.selection.ranges[i];
      if (segment.end <= segment.start ||
          !this.liveSelectionPoint(segment.node, segment.start) ||
          !this.liveSelectionPoint(segment.node, segment.end - 1)) return null;
    }
    var first = this.selection.ranges[0];
    var last = this.selection.ranges[this.selection.ranges.length - 1];
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
      var el = document.getElementById('fushi-sel-handle-' + which);
      if (!el) {
        el = document.createElement('div');
        el.id = 'fushi-sel-handle-' + which;
        el.setAttribute('data-fushi-sel-handle', which);
        // BUG-765 续：外层是 32×32 透明触控盒（比旧 24px 大，改善抓取；不取更大是因为
        // 1~2 字 CJK 短选区两端相距仅约一个字宽，触控盒过大会几乎完全重叠、反而遮住起
        // 手柄）。命中区大、视觉小；pointer-events:auto + touch-action:none 让它吃掉浏览器
        // 滚动手势并可拖。视觉抓手是内层 18px 实心圆钮，用主题色 var(--fushi-sel-handle)
        // （reader CSS 从 linkColor 下发，随主题变）+ 白描边（任意背景都可见）+ 单柔和阴
        // 影，去掉旧的刺眼橙色 + 双重发光 box-shadow（用户投诉「难看」）。
        // html itself is a multi-column/overflow container in paged books.
        // Promote the SAME touch target out of column clipping when supported;
        // older WebViews keep the fixed-position path.
        if (typeof el.showPopover === 'function') el.setAttribute('popover', 'manual');
        el.style.cssText = 'position:fixed;z-index:2147483645;width:32px;height:32px;' +
          'inset:auto;margin:0;margin-left:-16px;margin-top:-16px;padding:0;' +
          'overflow:visible;writing-mode:horizontal-tb;box-sizing:border-box;' +
          'background:transparent;border:0;' +
          'pointer-events:auto;touch-action:none;display:none;';
        var ball = document.createElement('div');
        ball.setAttribute('data-fushi-sel-ball', which);
        ball.style.cssText = 'position:absolute;left:50%;top:50%;width:18px;height:18px;' +
          'margin-left:-9px;margin-top:-9px;border-radius:50%;box-sizing:border-box;' +
          'background:var(--fushi-sel-handle, #3a5fad);' +
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
      if (!e.touches || e.touches.length !== 1 || !self.selectionEndpoints() ||
          !self.selectionHandles || self.selectionHandles[which] !== el) return;
      self.activeHandle = which;
      self.notifySelectionDragStarted();
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
      var t = (e.changedTouches && e.changedTouches[0]) || null;
      if (t) self.moveSelectionHandle(which, t.clientX, t.clientY);
      // move can invalidate the session if its source DOM was replaced.
      if (self.activeHandle !== which) return;
      if (!self.selectionEndpoints()) { self.clearSelection(); return; }
      self.activeHandle = null;
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
    if (!eps) { this.clearSelection(); return; }
    // 定锚端（对侧端点）：拖 end 手柄时锚点是选区起点，拖 start 手柄时锚点是选区终点。
    var anchorNode, anchorOffset;
    if (which === 'end') {
      anchorNode = eps.startNode; anchorOffset = eps.startOffset;
    } else {
      anchorNode = eps.endNode; anchorOffset = eps.endOffset;
    }
    var endpoint = this.selectionEndpointAtPoint(x, y, anchorNode, anchorOffset);
    if (!endpoint) return;
    var built = this.collectRangeBetween(anchorNode, anchorOffset, endpoint.node, endpoint.offset);
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
    // Clamp only the controls, never the text range or its visibility test.
    var vw = window.innerWidth || document.documentElement.clientWidth || 0;
    var vh = window.innerHeight || document.documentElement.clientHeight || 0;
    var SIZE = 32, half = SIZE / 2; // Same outer touch box as ensureSelectionHandles.
    var box = this.visibleContentBox() || { left: 0, top: 0, right: vw, bottom: vh };
    if (vw < SIZE || vh < SIZE ||
        !this.charRangeVisible(this.charRangeAt(eps.startNode, eps.startOffset), box) ||
        !this.charRangeVisible(this.charRangeAt(eps.endNode, eps.endOffset), box)) {
      this.hideSelectionHandles();
      return;
    }
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
    var clampCenter = function(value, extent) {
      return Math.max(half, Math.min(extent - half, value));
    };
    var edgeClamped = sx < half || sx > vw - half || ex < half || ex > vw - half ||
      sy < half || sy > vh - half || ey < half || ey > vh - half;
    sx = clampCenter(sx, vw); ex = clampCenter(ex, vw);
    sy = clampCenter(sy, vh); ey = clampCenter(ey, vh);
    // Preserve ordinary interior placement. At an edge a single glyph can put
    // both balls under one touch box after clamping. Separate those boxes along
    // the reading axis, moving the pair together when it meets a viewport edge.
    if (edgeClamped && Math.abs(sx - ex) < SIZE && Math.abs(sy - ey) < SIZE) {
      var alongY = vertical;
      if ((alongY ? vh : vw) < SIZE * 2) alongY = !alongY;
      var extent = alongY ? vh : vw;
      // No room for two full non-overlapping boxes on either axis: fail closed
      // rather than shrink targets, overlap them or manufacture more text.
      if (extent < SIZE * 2) { this.hideSelectionHandles(); return; }
      var a = alongY ? sy : sx, b = alongY ? ey : ex;
      var mid = Math.max(SIZE, Math.min(extent - SIZE, (a + b) / 2));
      var direction = a <= b ? 1 : -1;
      a = mid - direction * half; b = mid + direction * half;
      if (alongY) { sy = a; ey = b; }
      else { sx = a; ex = b; }
    }
    handles.start.style.left = sx + 'px';
    handles.start.style.top = sy + 'px';
    handles.end.style.left = ex + 'px';
    handles.end.style.top = ey + 'px';
    [handles.start, handles.end].forEach(function(el) {
      // Never hide/reopen a live target: it owns the whole touch stream.
      if (el.style.display !== 'block') el.style.display = 'block';
      if (typeof el.showPopover === 'function' && !el.matches(':popover-open')) {
        el.showPopover();
      }
    });
  },
  selectionHandlesRect: function() {
    var handles = this.selectionHandles;
    if (!handles || !this.selectionEndpoints()) return null;
    var bounds = null;
    for (var i = 0; i < 2; i++) {
      var el = i === 0 ? handles.start : handles.end;
      if (!el.isConnected || el.style.display === 'none') return null;
      var r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return null;
      if (!bounds) bounds = { x: r.left, y: r.top, right: r.right, bottom: r.bottom };
      else {
        bounds.x = Math.min(bounds.x, r.left); bounds.y = Math.min(bounds.y, r.top);
        bounds.right = Math.max(bounds.right, r.right); bounds.bottom = Math.max(bounds.bottom, r.bottom);
      }
    }
    return { x: bounds.x, y: bounds.y, width: bounds.right - bounds.x, height: bounds.bottom - bounds.y };
  },
  // 两个球各自的触控盒（视口 CSS 像素，顺序 = start, end）。宿主避让操作条时按单个盒子
  // 算：只有并集 bbox 会把两球之间的正文也算成障碍。任一端不可用 -> null（宿主退回并集）。
  selectionHandlesBoxes: function() {
    var handles = this.selectionHandles;
    if (!handles || !this.selectionEndpoints()) return null;
    var boxes = [];
    for (var i = 0; i < 2; i++) {
      var el = i === 0 ? handles.start : handles.end;
      if (!el.isConnected || el.style.display === 'none') return null;
      var r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return null;
      boxes.push({ x: r.left, y: r.top, width: r.width, height: r.height });
    }
    return boxes;
  },
  showSelectionHandles: function() {
    this.positionSelectionHandles();
  },
  hideSelectionHandles: function() {
    this.activeHandle = null;
    if (this.selectionHandles) {
      [this.selectionHandles.start, this.selectionHandles.end].forEach(function(el) {
        if (typeof el.hidePopover === 'function' && el.matches(':popover-open')) el.hidePopover();
        el.style.display = 'none';
      });
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
  isVerticalTextNode: function(node) {
    var el = node && (node.nodeType === Node.TEXT_NODE ? node.parentElement : node);
    if (!el || !window.getComputedStyle) return false;
    var mode = window.getComputedStyle(el).writingMode || '';
    return mode.indexOf('vertical') === 0 || mode.indexOf('tb') === 0;
  },
  // BUG-3665：查词弹窗的锚点矩形 = 被查词「用户看得见、点中的那一段」字形，而不是
  // 全部字形片段的并集。一个词被断在两栏 / 两页（`su-` 在上一页末行、`perfluous` 在
  // 本页首行）时，旧实现把屏外那段也并进来：并集从页顶一直拉到页底，弹窗上下都没空间，
  // 被 calcPopupPosition 的「绝不压词」挤成贴底的一条（用户报「在边缘查词，卡片位置
  // 不合适」）。规则：
  //   1. 只看与视口相交的片段（翻页模式下别的页在屏外）；一个都不相交时退回全部片段。
  //   2. 锚段 = 含点击点的片段，没有点击点（键盘 / 手柄光标）或都不含时取第一段。
  //   3. 从锚段出发，只并入交叉轴上与已并区间相距不超过两行的片段——同一栏里折到下一行
  //      的半个词仍并进来（弹窗不压它），隔栏 / 隔半页的另一段不并。
  anchoredWordBounds: function(rects, point, vertical) {
    var list = [];
    for (var i = 0; i < rects.length; i++) {
      var r = rects[i];
      if (r && r.width > 0 && r.height > 0) list.push(r);
    }
    if (!list.length) return null;
    var vw = window.innerWidth || document.documentElement.clientWidth || 0;
    var vh = window.innerHeight || document.documentElement.clientHeight || 0;
    var visible = list.filter(function(r) {
      return r.right > 0 && r.bottom > 0 && (!vw || r.left < vw) && (!vh || r.top < vh);
    });
    if (!visible.length) visible = list;
    var anchor = null;
    if (point) {
      anchor = visible.find(function(r) {
        return point.x >= r.left && point.x <= r.right && point.y >= r.top && point.y <= r.bottom;
      }) || null;
    }
    if (!anchor) anchor = visible[0];
    var bounds = { left: anchor.left, top: anchor.top, right: anchor.right, bottom: anchor.bottom };
    var lineSize = vertical ? anchor.width : anchor.height;
    var maxGap = lineSize * 2;
    var pending = visible.filter(function(r) { return r !== anchor; });
    var grew = true;
    while (grew && pending.length) {
      grew = false;
      for (var k = pending.length - 1; k >= 0; k--) {
        var c = pending[k];
        var gap = vertical
          ? Math.max(0, Math.max(c.left, bounds.left) - Math.min(c.right, bounds.right))
          : Math.max(0, Math.max(c.top, bounds.top) - Math.min(c.bottom, bounds.bottom));
        if (gap > maxGap) continue;
        if (c.left < bounds.left) bounds.left = c.left;
        if (c.top < bounds.top) bounds.top = c.top;
        if (c.right > bounds.right) bounds.right = c.right;
        if (c.bottom > bounds.bottom) bounds.bottom = c.bottom;
        pending.splice(k, 1);
        grew = true;
      }
    }
    return bounds;
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
    this.selection.matchedRanges = trimmedRanges;
    var wordRects = [];
    for (var i = 0; i < trimmedRanges.length; i++) {
      var seg = trimmedRanges[i];
      var bRange = document.createRange();
      bRange.setStart(seg.node, seg.start);
      bRange.setEnd(seg.node, seg.end);
      var rects = bRange.getClientRects();
      for (var j = 0; j < rects.length; j++) wordRects.push(rects[j]);
    }
    var firstSeg = trimmedRanges.length ? trimmedRanges[0] : null;
    var bounds = this.anchoredWordBounds(
      wordRects, this.selection.point || null,
      firstSeg ? this.isVerticalTextNode(firstSeg.node) : false);
    if (window.__fushiCssHighlightsSupported) {
      // BUG-110：<ruby> 内的字不放进 ::highlight（竖排下 ::highlight 把 ruby 基字盒
      // 画两遍 → 半透明叠加成深色带遮字），改给 <ruby> 元素加 class 单次绘背景。
      var highlights = [];
      this.clearSelectionRubyHighlights();
      for (var i = 0; i < trimmedRanges.length; i++) {
        var seg = trimmedRanges[i];
        var ruby = this.rubyForNode(seg.node);
        if (ruby) {
          if (this.selectionRubyElements.indexOf(ruby) < 0) {
            ruby.classList.add('fushi-selection-ruby-active');
            this.selectionRubyElements.push(ruby);
          }
          continue;
        }
        if (typeof window.__fushiEnsureHighlightPaintable === 'function') {
          window.__fushiEnsureHighlightPaintable(seg.node);
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
      CSS.highlights.set('fushi-selection', selHl);
    } else {
      // 拆旧包裹时合并文本节点，trimmedRanges（= selection.matchedRanges）的段由 trackTextPoints
      // 就地换算。包裹走 __fushiLiveRanges.wrapText（BUG-3343）：extractContents 会把选中的字复制进
      // 新节点、原节点截掉这段，选区的「节点 + 偏移」从此指向别的字。倒序包裹：切开只影响切点之后。
      this.clearHighlightWrappers();
      for (var i = trimmedRanges.length - 1; i >= 0; i--) {
        var seg = trimmedRanges[i];
        if (seg.end <= seg.start) continue;
        var wrapper = document.createElement('span');
        wrapper.className = 'fushi-dict-highlight';
        window.__fushiLiveRanges.wrapText(seg.node, seg.start, seg.end, wrapper);
        this.highlightWrappers.push(wrapper);
      }
      this.highlightWrappers.reverse();
    }
    return bounds ? { x: bounds.left, y: bounds.top, width: bounds.right - bounds.left, height: bounds.bottom - bounds.top } : null;
  },
  // Audio coordinates use normalized UTF-16 units, independently of study
  // counts. Do not read nodeStartOffsets: that index belongs to navigation.
  getMatchableOffset: function(targetNode, offset) {
    if (!window.fushiReader || !targetNode) return null;
    // VN renders a clone of one screen. Its source map retains the chapter
    // position; walking document.body here would restart audio offsets at zero.
    if (typeof window.fushiReader.getMatchableOffset === 'function') {
      return window.fushiReader.getMatchableOffset(targetNode, offset);
    }
    // 查词卡顿（P0-1）：旧实现每次都从 document.body 把整章文本节点逐码点走一遍，而
    // buildSelectionPayload 一次查词要调 4 次（词首尾 + 句首尾），全在 onTextSelected
    // 交给 Dart 之前同步执行，章越长越卡。现在按文本节点缓存「此节点之前的可匹配码元数」
    // （matchableNodeStart），查词只数目标节点内 [0, offset) 这一段。数值口径与旧的整章
    // 游走逐位相同：同一个 createWalker（拒振假名 / 纯空白节点）、同一个 isMatchableChar、
    // 同样按码点步进累加 ch.length。
    var base = this.matchableNodeStart(targetNode);
    if (base === undefined) {
      // 表不可用（无 MutationObserver）才会走到这里：退回旧的整章游走，结果不变。
      return this.getMatchableOffsetByWalk(targetNode, offset);
    }
    if (base === null) return null; // 目标不是 walker 接受的文本节点：旧实现同样返回 null
    return base + this.countMatchableUnits(targetNode.textContent || '', offset);
  },
  // 旧算法原样保留：无缓存表时的回退，也是一致性测试的参照实现。
  getMatchableOffsetByWalk: function(targetNode, offset) {
    var walker = this.createWalker(document.body);
    var count = 0;
    var node;
    while ((node = walker.nextNode()) != null) {
      var text = node.textContent || '';
      var limit = node === targetNode ? offset : text.length;
      for (var i = 0; i < limit;) {
        var ch = String.fromCodePoint(text.codePointAt(i));
        if (window.fushiReader.isMatchableChar(ch)) count += ch.length;
        i += ch.length;
      }
      if (node === targetNode) return count;
    }
    return null;
  },
  // text 的 [0, limit) 里可匹配字符的 UTF-16 码元数（逐码点步进，与旧游走同一循环）。
  countMatchableUnits: function(text, limit) {
    var count = 0;
    for (var i = 0; i < limit;) {
      var ch = String.fromCodePoint(text.codePointAt(i));
      if (window.fushiReader.isMatchableChar(ch)) count += ch.length;
      i += ch.length;
    }
    return count;
  },
  // 文本节点 → 它之前全部 walker 接受节点的可匹配码元总数。返回 number = 命中；
  // null = 该节点不在 walker 序列里（振假名 / 纯空白 / 游离 / body 外）；undefined =
  // 环境不支持缓存（调用方退回整章游走）。
  //
  // 失效：表只对「建表那一刻的 DOM」成立。建表后挂一个 MutationObserver（childList +
  // characterData，subtree）看着整棵文档；任何节点增删 / 文本改写都让表作废——回调是
  // 异步的，所以每次读表前先 takeRecords() 同步收掉还没派发的记录，保证同一任务里
  // 「先改 DOM 再查词」（如非 CSS Highlights 环境的查词高亮包裹、有声书 cue 包裹）也读不到
  // 旧表。作废即断开观察，下次查词时重建（一遍整章游走，仍比旧实现每次查词 4 遍少）。
  // 不在 buildNodeOffsets 里顺手建：那条路在翻章 / 每次 cue 包裹后都跑，逐码点正则会直接
  // 加到翻章耗时上；而且只靠「谁调了 buildNodeOffsets」来失效会漏掉不经它的 DOM 改动。
  matchableNodeStart: function(targetNode) {
    if (typeof MutationObserver !== 'function') return undefined;
    var observer = this._matchableObserver;
    if (observer && this._matchableStarts && observer.takeRecords().length) {
      this.invalidateMatchableIndex();
    }
    if (!this._matchableStarts) this.buildMatchableIndex();
    if (!this._matchableStarts) return undefined;
    var base = this._matchableStarts.get(targetNode);
    return base === undefined ? null : base;
  },
  buildMatchableIndex: function() {
    var root = document.documentElement;
    if (!document.body || !root) return;
    var starts = new WeakMap();
    var walker = this.createWalker(document.body);
    var count = 0;
    var node;
    while ((node = walker.nextNode()) != null) {
      starts.set(node, count);
      var text = node.textContent || '';
      count += this.countMatchableUnits(text, text.length);
    }
    var self = this;
    if (!this._matchableObserver) {
      this._matchableObserver = new MutationObserver(function() {
        self.invalidateMatchableIndex();
      });
    }
    this._matchableObserver.observe(root, { childList: true, characterData: true, subtree: true });
    this._matchableStarts = starts;
  },
  invalidateMatchableIndex: function() {
    this._matchableStarts = null;
    if (this._matchableObserver) {
      this._matchableObserver.takeRecords();
      this._matchableObserver.disconnect();
    }
  },
  matchableRange: function(startNode, startOffset, endNode, endOffset) {
    var start = this.getMatchableOffset(startNode, startOffset);
    var end = this.getMatchableOffset(endNode, endOffset);
    return { offset: start, length: start !== null && end !== null && end >= start
      ? end - start : null };
  },
  // Historical API name: this is a learning-unit offset for navigation, not
  // an audio matching or DOM text index. Keep persisted navigation compatible.
  getNormalizedOffset: function(targetNode, offset) {
    if (!window.fushiReader) return null;
    var base = window.fushiReader.nodeStartOffsets
      ? window.fushiReader.nodeStartOffsets.get(targetNode) : undefined;
    // BUG-3630：视觉小说模式取句回到源章节，句首 / 句尾是源节点（不在 document 里，下面
    // 遍历 body 的兜底数不到它），用源节点自己的章内偏移。
    if (base === undefined &&
        typeof window.fushiReader.sourceTextOffsetForNode === 'function') {
      base = window.fushiReader.sourceTextOffsetForNode(targetNode);
    }
    if (base !== undefined) {
      var count = base || 0;
      var text = targetNode.textContent;
      for (var i = 0; i < offset;) {
        var char = String.fromCodePoint(text.codePointAt(i));
        if (window.fushiStudyUnits.isUnitEnd(text, i)) count++;
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
          if (window.fushiStudyUnits.isUnitEnd(nodeText, i)) count++;
          i += char.length;
        }
        return count;
      }
      for (var i = 0; i < nodeText.length;) {
        var char = String.fromCodePoint(nodeText.codePointAt(i));
        if (window.fushiStudyUnits.isUnitEnd(nodeText, i)) count++;
        i += char.length;
      }
    }
    return null;
  },
  clearHighlightWrappers: function() {
    if (!this.highlightWrappers.length) return;
    for (var i = 0; i < this.highlightWrappers.length; i++) {
      // BUG-3343：拆包裹与合并都经 __fushiLiveRanges，查词选区（highlightSelection 重画时仍要用）
      // 与 live Range 换算到合并后的节点。
      window.__fushiLiveRanges.normalize(window.__fushiLiveRanges.unwrap(this.highlightWrappers[i]));
    }
    this.highlightWrappers = [];
    if (!window.__fushiCssHighlightsSupported && window.fushiReader && window.fushiReader.buildNodeOffsets) {
      window.fushiReader.buildNodeOffsets();
    }
  },
  // BUG-3326 审查：选区与拖选锚点存的是「文本节点 + 数字偏移」，不是 live Range。别的模块在
  // offset 处 splitText 切开 node（tail 是切点之后的新节点，如有声书整句高亮在折行处切 wrapper）
  // 后调这里，按 DOM splitText 对 live Range 的同一语义换算：落在切点及之后的点改指 tail、
  // 偏移减去 offset；跨切点的段拆成前后两段。不换算的话切点之后的偏移越界——查词高亮
  // （highlightSelection 的 codePointAt 读空）、拖动柄（selectionEndpoints）与制卡句子上下文都会坏。
  noteTextNodeSplit: function(node, offset, tail) {
    var point = function(n, o) {
      return n === node && o >= offset ? { node: tail, offset: o - offset } : { node: n, offset: o };
    };
    var copy = function(r, n, start, end) {
      var c = {};
      for (var k in r) c[k] = r[k];
      c.node = n; c.start = start; c.end = end;
      return c;
    };
    var segments = function(list) {
      var out = [];
      list.forEach(function(r) {
        if (r.node !== node || r.end <= offset) out.push(r);
        else if (r.start >= offset) out.push(copy(r, tail, r.start - offset, r.end - offset));
        else out.push(copy(r, node, r.start, offset), copy(r, tail, 0, r.end - offset));
      });
      return out;
    };
    var sel = this.selection;
    if (sel) {
      var s = point(sel.startNode, sel.startOffset);
      sel.startNode = s.node; sel.startOffset = s.offset;
      if (sel.ranges) sel.ranges = segments(sel.ranges);
      if (sel.matchedRanges) sel.matchedRanges = segments(sel.matchedRanges);
    }
    var anchor = this.dragAnchor;
    if (anchor) {
      var a = point(anchor.node, anchor.offset);
      anchor.node = a.node; anchor.offset = a.offset;
      var e = point(anchor.endNode, anchor.endOffset);
      anchor.endNode = e.node; anchor.endOffset = e.offset;
    }
  },
  // BUG-3343：合并相邻文本节点（__fushiLiveRanges.normalize）前调这里。选区与拖选锚点里的每个
  // 「节点 + 偏移」各由一个折叠的 live Range 跟踪——DOM 规范在 normalize() 里对 live Range 做的
  // 换算（并进前一个节点、偏移加上前面的长度）正是这些点该有的换算；返回的函数在合并之后把
  // 换算结果原地写回（ranges / matchedRanges 的段对象就地改，别处持有的同一批段也一起更新）。
  trackTextPoints: function() {
    var writes = [];
    var track = function(node, offset, write) {
      if (!node) return;
      var probe = document.createRange();
      try { probe.setStart(node, offset); } catch (_ignored) { return; }
      writes.push(function() { write(probe.startContainer, probe.startOffset); });
    };
    var trackSegments = function(list) {
      (list || []).forEach(function(seg) {
        track(seg.node, seg.start, function(n, o) { seg.node = n; seg.start = o; });
        track(seg.node, seg.end, function(n, o) { seg.end = o; });
      });
    };
    var sel = this.selection;
    if (sel) {
      track(sel.startNode, sel.startOffset, function(n, o) { sel.startNode = n; sel.startOffset = o; });
      trackSegments(sel.ranges);
      if (sel.matchedRanges !== sel.ranges) trackSegments(sel.matchedRanges);
    }
    var anchor = this.dragAnchor;
    if (anchor) {
      track(anchor.node, anchor.offset, function(n, o) { anchor.node = n; anchor.offset = o; });
      track(anchor.endNode, anchor.endOffset, function(n, o) { anchor.endNode = n; anchor.endOffset = o; });
    }
    return function() { writes.forEach(function(write) { write(); }); };
  },
  clearSelectionOnViewportChange: function() {
    if (this.dragAnchor || this.activeHandle) return;
    this.clearSelection();
  },
  clearSelection: function() {
    window.getSelection()?.removeAllRanges();
    if (window.__fushiCssHighlightsSupported) {
      CSS.highlights.delete('fushi-selection');
      this.clearSelectionRubyHighlights();
    } else {
      this.clearHighlightWrappers();
    }
    this.hideSelectionHandles();
    this.selection = null;
    // 锚点是「一次长按拖选」的会话状态：选区清掉就复位，下次长按重新建立。
    this.dragAnchor = null;
    // Always notify, including already-empty JS state, to clear stale host UI.
    // The host clears only its own toolbar, never calls back into JS. begin's
    // clear notification precedes the new selection/menu notification.
    if (window.flutter_inappwebview &&
        typeof window.flutter_inappwebview.callHandler === 'function') {
      window.flutter_inappwebview.callHandler('onSelectionCleared');
    }
  }
};
""";
}
