import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';

enum ReaderNavigationDirection {
  forward('forward'),
  backward('backward');

  const ReaderNavigationDirection(this.jsValue);
  final String jsValue;
}

/// 一条 sasayaki cue 的运行时定位输入：归一化原文 [needle]、匹配时算出的
/// 归一化偏移提示 [hint]、提示长度 [length]（仅在未命中回落时用于推进游标）。
class SasayakiCueHint {
  const SasayakiCueHint({
    required this.needle,
    required this.hint,
    required this.length,
  });

  final String needle;
  final int hint;
  final int length;
}

class ReaderPaginationScripts {
  ReaderPaginationScripts._();

  /// sasayaki 高亮就近重定位的搜索半径（归一化字符）。整句 needle 很长，
  /// 半径内出现同一整句重复的概率极低；半径限制 + 单调游标 ⇒ 不会跳到远处
  /// 重复句（BUG-060 用户担心的「来回跳动」）。
  static const int kSasayakiSearchWindow = 256;

  /// 把 cue 的归一化偏移（提示）+ 原文，映射成在 [fullNorm]（实时 DOM 的
  /// 归一化文本）里的解析起点。这是 JS `collectSasayakiCueRanges` 搜索逻辑的
  /// 纯 Dart 影子，供单测验证「漂移自愈 / 不跳远处重复 / 未命中回落提示」三
  /// 不变量；JS 侧实现同一算法（见同文件脚本字符串 + 源码守卫测试）。
  ///
  /// 规则：单调游标 `cursor` 只增不减；每条 cue 在 `[max(cursor, hint-window),
  /// hint+window]` 内取**离 hint 最近**的整句出现位置（对齐既有
  /// scrollToSearchMatch 的就近策略）；窗口内无命中则回落到裁剪后的 hint。
  @visibleForTesting
  static List<int> resolveCueNormStartsForTesting({
    required String fullNorm,
    required List<SasayakiCueHint> cues,
    int window = kSasayakiSearchWindow,
  }) {
    final List<int> out = <int>[];
    int cursor = 0;
    for (final SasayakiCueHint c in cues) {
      final String needle = c.needle;
      final int hint = c.hint;
      int resolved;
      if (needle.isNotEmpty) {
        final int lo = cursor > (hint - window) ? cursor : (hint - window);
        final int start = lo < 0 ? 0 : lo;
        int best = -1;
        int bestDist = 1 << 30;
        if (start <= fullNorm.length) {
          int from = start;
          while (true) {
            final int i = fullNorm.indexOf(needle, from);
            if (i < 0 || i > hint + window) {
              break;
            }
            final int d = (i - hint).abs();
            if (d < bestDist) {
              bestDist = d;
              best = i;
            }
            from = i + 1;
          }
        }
        if (best >= 0) {
          resolved = best;
          cursor = best + needle.length;
        } else {
          resolved = _clampInt(hint, cursor, fullNorm.length);
          cursor = resolved + c.length;
        }
      } else {
        resolved = _clampInt(hint, cursor, fullNorm.length);
        cursor = resolved + c.length;
      }
      out.add(resolved);
    }
    return out;
  }

  static int _clampInt(int v, int lo, int hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  static String paginateInvocation(ReaderNavigationDirection direction) =>
      "window.hoshiReader && window.hoshiReader.paginate('${direction.jsValue}')";

  static String progressInvocation() =>
      'window.hoshiReader && window.hoshiReader.calculateProgress()';

  static String stableProgressInvocation() =>
      'window.hoshiReader && !window.hoshiReader._reanchorPending '
      '? window.hoshiReader.calculateProgress() : null';

  static String updatePageSizeInvocation(double width, double height) =>
      'window.hoshiReader && window.hoshiReader.updatePageSize($width, $height)';

  static ReaderNavigationDirection? navigationDirectionForKey(
    LogicalKeyboardKey key, {
    bool shiftPressed = false,
  }) {
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        (key == LogicalKeyboardKey.space && !shiftPressed)) {
      return ReaderNavigationDirection.forward;
    }
    if (key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        (key == LogicalKeyboardKey.space && shiftPressed)) {
      return ReaderNavigationDirection.backward;
    }
    return null;
  }

  static String applySasayakiCuesInvocation(String cuesJson) =>
      'window.hoshiReader && window.hoshiReader.applySasayakiCues($cuesJson)';

  static String highlightSasayakiCueInvocation(
    String cueId, {
    required bool reveal,
  }) =>
      'window.hoshiReader.highlightSasayakiCue(${_jsStringLiteral(cueId)}, $reveal)';

  static String clearSasayakiCueInvocation() =>
      'window.hoshiReader.clearSasayakiCue()';

  static String scrollToSearchMatchInvocation(String query, int hintOffset) =>
      'window.hoshiReader.scrollToSearchMatch(${_jsStringLiteral(query)}, $hintOffset)';

  static String clearSearchHighlightInvocation() =>
      'window.hoshiReader.clearSearchHighlight()';

  static String getFirstVisibleCharOffsetInvocation() =>
      'window.hoshiReader && window.hoshiReader.getFirstVisibleCharOffset()';

  /// Returns the current page / total pages within the loaded chapter as a JSON
  /// string (`{"currentPage":N,"totalPages":M}`), or the literal `"null"` when
  /// the reader is in a non-paged mode (continuous) where pages don't apply.
  static String pageInfoInvocation() =>
      'JSON.stringify((window.hoshiReader && window.hoshiReader.pageInfo) '
      '? window.hoshiReader.pageInfo() : null)';

  static String scrollToCharOffsetInvocation(int charOffset) =>
      'window.hoshiReader && window.hoshiReader.scrollToCharOffset($charOffset)';

  static String setChromeInsetsInvocation(double topPx, double bottomPx) =>
      'window.hoshiReader && window.hoshiReader.setChromeInsets($topPx, $bottomPx)';

  static bool didScroll(String? result) =>
      result?.trim().replaceAll('"', '') == 'scrolled';

  static int? intResult(dynamic result) {
    if (result == null) return null;
    if (result is int) return result;
    if (result is num) return result.toInt();
    if (result is String) {
      return int.tryParse(result.trim().replaceAll('"', ''));
    }
    return null;
  }

  static double? doubleResult(dynamic result) {
    if (result == null) return null;
    if (result is double) return result;
    if (result is num) return result.toDouble();
    if (result is String) {
      return double.tryParse(result.trim().replaceAll('"', ''));
    }
    return null;
  }

  static String shellScript({
    double initialProgress = 0.0,
    bool continuousMode = false,
    int fontSize = ReaderLayoutDefaults.fontSizePx,
    String? sasayakiCuesJson,
    String? initialFragment,
    double chromeTopInset = 0.0,
    double chromeBottomInset = 0.0,
    double? dartPageWidth,
    double? dartPageHeight,
  }) {
    if (continuousMode) {
      return _continuousShellScript(
        initialProgress: initialProgress,
        sasayakiCuesJson: sasayakiCuesJson,
        initialFragment: initialFragment,
        chromeTopInset: chromeTopInset,
        chromeBottomInset: chromeBottomInset,
        dartPageWidth: dartPageWidth,
        dartPageHeight: dartPageHeight,
      );
    }
    return _paginatedShellScript(
      initialProgress: initialProgress,
      fontSize: fontSize,
      sasayakiCuesJson: sasayakiCuesJson,
      initialFragment: initialFragment,
      chromeTopInset: chromeTopInset,
      chromeBottomInset: chromeBottomInset,
      dartPageWidth: dartPageWidth,
      dartPageHeight: dartPageHeight,
    );
  }

  // ── Shared JS (properties + methods used by both modes) ────────────

  static const String _sharedJs = r'''
  cueWrappers: new Map(),
  cueRangesMap: new Map(),
  cueRubyElements: new Map(),
  activeCueId: null,
  ttuRegexNegated: /[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゟァ-ヺー-ヿ０-９Ａ-Ｚａ-ｚｦ-ﾝ\u{2E80}-\u{2EFF}\u{2F00}-\u{2FDF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{F900}-\u{FAFF}\u{20000}-\u{2A6DF}\u{2A700}-\u{2EBE0}\u{2F800}-\u{2FA1F}\u{30000}-\u{323AF}]+/gimu,
  ttuRegex: /[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゟァ-ヺー-ヿ０-９Ａ-Ｚａ-ｚｦ-ﾝ\u{2E80}-\u{2EFF}\u{2F00}-\u{2FDF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{F900}-\u{FAFF}\u{20000}-\u{2A6DF}\u{2A700}-\u{2EBE0}\u{2F800}-\u{2FA1F}\u{30000}-\u{323AF}]/iu,
  nodeStartOffsets: new WeakMap(),
  isVertical: function() {
    return window.getComputedStyle(document.body).writingMode === "vertical-rl";
  },
  isFurigana: function(node) {
    var el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return !!(el && el.closest('rt, rp'));
  },
  normalizeText: function(text) {
    return (text || '').replace(this.ttuRegexNegated, '');
  },
  countChars: function(text) {
    return Array.from(this.normalizeText(text)).length;
  },
  isMatchableChar: function(char) {
    return this.ttuRegex.test(char || '');
  },
  scrollToProgressContinuous: function(progress) {
    var targetNode = this.findNodeAtProgress(progress);
    if (targetNode && targetNode.parentElement) {
      targetNode.parentElement.scrollIntoView({
        block: progress >= 0.999999 ? 'end' : 'start',
        inline: 'nearest',
        behavior: 'instant'
      });
    }
  },
  findNodeAtProgress: function(progress) {
    var walker = this.createWalker();
    var totalChars = 0;
    var node;
    while (node = walker.nextNode()) {
      totalChars += this.countChars(node.textContent);
    }
    if (totalChars <= 0) return null;
    var targetCharCount = Math.ceil(totalChars * progress);
    var runningSum = 0;
    var targetNode = null;
    walker = this.createWalker();
    while (node = walker.nextNode()) {
      runningSum += this.countChars(node.textContent);
      if (runningSum > targetCharCount) { targetNode = node; break; }
    }
    return targetNode;
  },
  scrollToProgressPaged: function(context, progress) {
    if (context.pageSize <= 0 || progress <= 0) {
      this.setPagePosition(context, this.contentFirstPageScroll(context));
      return;
    }
    if (progress >= 0.99) {
      this.setPagePosition(context, Math.max(0, this.contentLastPageScroll(context)));
      return;
    }
    var targetNode = this.findNodeAtProgress(progress);
    if (targetNode) {
      var range = document.createRange();
      range.setStart(targetNode, 0);
      range.setEnd(targetNode, Math.min(1, targetNode.length));
      var rect = this.getRect(range);
      var scroll = this.getPagePosition(context);
      var anchor = (context.vertical ? rect.top : rect.left) + scroll;
      this.setPagePosition(context, this.alignToPage(context, anchor));
    }
  },
  notifyRestoreComplete: function() {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('onRestoreComplete');
    }
  },
  createWalker: function(rootNode) {
    var root = rootNode || document.body;
    return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => this.isFurigana(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
    });
  },
  getRect: function(target) {
    var rect = target.getClientRects()[0];
    return rect || target.getBoundingClientRect();
  },
  buildNodeOffsets: function() {
    var offsets = new WeakMap();
    var walker = this.createWalker();
    var count = 0;
    var node;
    while (node = walker.nextNode()) {
      offsets.set(node, count);
      count += this.countChars(node.textContent);
    }
    this.nodeStartOffsets = offsets;
    if (this.paginationMetrics !== undefined) this.paginationMetrics = null;
  },
  buildSasayakiNormIndex: function() {
    // 一次性遍历 DOM 文本节点（createWalker 跳过振假名 rt/rp），构建归一化
    // 全文 full 与反查表 map：map[k] = {node,start,end}（第 k 个归一化字符在其
    // 文本节点内的原始 UTF-16 偏移区间）。归一化口径 = isMatchableChar，与
    // normalizeText 完全一致（白名单：假名/汉字/字母数字）。
    var walker = this.createWalker();
    var node;
    var map = [];
    var full = '';
    while (node = walker.nextNode()) {
      var text = node.textContent;
      var i = 0;
      var chunk = '';
      while (i < text.length) {
        var ch = String.fromCodePoint(text.codePointAt(i));
        var next = i + ch.length;
        if (this.isMatchableChar(ch)) {
          // full 是 UTF-16 码元串（full.indexOf 返回码元偏移），map 必须与之同粒度：
          // 星平面字符（CJK 扩展 B+，白名单含  0+）占 2 个码元，push 两条
          // 指向同一原始区间的反查项，否则码元偏移索引逐码点 map 会在代理对后错位。
          for (var u = 0; u < ch.length; u++) {
            map.push({ node: node, start: i, end: next });
          }
          chunk += ch;
        }
        i = next;
      }
      full += chunk;
    }
    return { full: full, map: map };
  },
  rangesForNormSpan: function(map, normStart, normLen) {
    // 把归一化区间 [normStart, normStart+normLen) 映射成按文本节点分组的 DOM
    // 子区间；同一节点内被跨过的非匹配字符（标点等）一并纳入（保持原视觉）。
    var ranges = [];
    if (normLen <= 0 || normStart < 0 || normStart >= map.length) return ranges;
    var endEx = Math.min(normStart + normLen, map.length);
    var curNode = null, curStart = 0, curEnd = 0;
    for (var k = normStart; k < endEx; k++) {
      var e = map[k];
      if (e.node !== curNode) {
        if (curNode) ranges.push({ node: curNode, start: curStart, end: curEnd });
        curNode = e.node; curStart = e.start; curEnd = e.end;
      } else {
        curEnd = e.end;
      }
    }
    if (curNode) ranges.push({ node: curNode, start: curStart, end: curEnd });
    return ranges;
  },
  collectSasayakiCueRanges: function(cues) {
    // BUG-060：高亮坐标由实时 DOM 权威定位。匹配时算出的 start/length 仅作
    // 「提示」，运行时用 cue 原文 text 在实时 DOM 的归一化全文里就近、单调地
    // 重新定位 —— 摆脱 package:html(匹配坐标系) 与浏览器 DOM(渲染坐标系) 逐字
    // 不一致导致的累积偏移。不变量：① 游标 cursor 单调不回退；② 搜索窗口有界
    // (整句 needle + 半径 WINDOW)，不跳远处重复句；③ 窗口内取离 hint 最近者；
    // ④ 未命中回落提示偏移，绝不空高亮。与 Dart 影子
    // ReaderPaginationScripts.resolveCueNormStartsForTesting 同算法。
    var out = [];
    if (!cues.length) return out;
    var idx = this.buildSasayakiNormIndex();
    var full = idx.full;
    var map = idx.map;
    var WINDOW = 256;
    var cursor = 0;
    for (var ci = 0; ci < cues.length; ci++) {
      var cue = cues[ci];
      var needle = this.normalizeText(cue.text || '');
      var hint = (typeof cue.start === 'number') ? cue.start : cursor;
      var len = (typeof cue.length === 'number') ? cue.length : 0;
      var normLen = needle.length;
      var resolved = -1;
      if (normLen > 0) {
        var lo = cursor > (hint - WINDOW) ? cursor : (hint - WINDOW);
        var startAt = lo < 0 ? 0 : lo;
        var best = -1, bestDist = 1 << 30;
        if (startAt <= full.length) {
          var from = startAt;
          while (true) {
            var p = full.indexOf(needle, from);
            if (p < 0 || p > hint + WINDOW) break;
            var d = Math.abs(p - hint);
            if (d < bestDist) { bestDist = d; best = p; }
            from = p + 1;
          }
        }
        if (best >= 0) { resolved = best; cursor = best + normLen; }
      }
      var spanStart, spanLen;
      if (resolved >= 0) {
        spanStart = resolved; spanLen = normLen;
      } else {
        spanStart = hint < cursor ? cursor : (hint > map.length ? map.length : hint);
        spanLen = len;
        cursor = spanStart + len;
      }
      out.push({ id: cue.id, ranges: this.rangesForNormSpan(map, spanStart, spanLen) });
    }
    return out;
  },
  applySasayakiCues: function(cues) {
    if (window.hoshiSelection) window.hoshiSelection.clearSelection();
    this.resetSasayakiCues();
    var cueSegments = this.collectSasayakiCueRanges(cues);
    if (window.__hoshiCssHighlightsSupported) {
      // BUG-110：在 <ruby> 内的节点不放进 ::highlight range（竖排下 ::highlight 会把
      // ruby 基字盒画两遍 → 半透明叠加成深色带遮字）；改把 <ruby> 元素本身收集起来，
      // 高亮时给它加 class（背景画在元素上、只画一遍）。普通文字仍走 ::highlight。
      // 移植自 Hoshi-Reader-Android buildSasayakiHighlightRanges。
      for (var i = 0; i < cueSegments.length; i++) {
        var id = cueSegments[i].id;
        var segments = cueSegments[i].ranges;
        if (!segments.length) continue;
        var ranges = [];
        var rubyElements = [];
        for (var j = 0; j < segments.length; j++) {
          var ruby = this.rubyForNode(segments[j].node);
          if (ruby) {
            if (rubyElements.indexOf(ruby) < 0) rubyElements.push(ruby);
            continue;
          }
          try {
            var r = document.createRange();
            r.setStart(segments[j].node, segments[j].start);
            r.setEnd(segments[j].node, segments[j].end);
            ranges.push(r);
          } catch (e) {}
        }
        if (ranges.length) this.cueRangesMap.set(id, ranges);
        if (rubyElements.length) this.cueRubyElements.set(id, rubyElements);
      }
    } else {
      var range = document.createRange();
      for (var i = cueSegments.length - 1; i >= 0; i--) {
        var id = cueSegments[i].id;
        var segments = cueSegments[i].ranges;
        if (!segments.length) continue;
        var wrappers = [];
        for (var j = segments.length - 1; j >= 0; j--) {
          range.setStart(segments[j].node, segments[j].start);
          range.setEnd(segments[j].node, segments[j].end);
          var wrapper = document.createElement('span');
          wrapper.className = 'hoshi-sasayaki-cue';
          wrapper.appendChild(range.extractContents());
          range.insertNode(wrapper);
          wrappers.push(wrapper);
        }
        wrappers.reverse();
        this.cueWrappers.set(id, wrappers);
      }
      this.buildNodeOffsets();
    }
  },
  rubyForNode: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return el && el.closest ? el.closest('ruby') : null;
  },
  highlightSasayakiCue: function(cueId, reveal) {
    this.clearSasayakiCue();
    if (window.__hoshiCssHighlightsSupported) {
      var ranges = this.cueRangesMap.get(cueId) || [];
      var rubyElements = this.cueRubyElements.get(cueId) || [];
      if (!ranges.length && !rubyElements.length) return null;
      this.activeCueId = cueId;
      if (ranges.length) CSS.highlights.set('hoshi-sasayaki', new Highlight(...ranges));
      // ruby 元素用 class 高亮（背景画在元素上，避免 ::highlight 对 ruby 双绘，BUG-110）
      rubyElements.forEach(function(ruby) { ruby.classList.add('hoshi-sasayaki-ruby-active'); });
      if (reveal) {
        var anchor = ranges.length ? ranges[0] : null;
        if (anchor) {
          if (this.scrollToRange) {
            if (this.scrollToRange(anchor)) return this.calculateProgress();
          } else if (this.scrollToTarget) {
            if (this.scrollToTarget(anchor)) return this.calculateProgress();
          }
        } else if (rubyElements[0] && this.revealElement) {
          if (this.revealElement(rubyElements[0])) return this.calculateProgress();
        }
      }
    } else {
      var wrappers = this.cueWrappers.get(cueId);
      if (!wrappers || !wrappers.length) return null;
      this.activeCueId = cueId;
      wrappers.forEach(function(wrapper) { wrapper.classList.add('hoshi-sasayaki-active'); });
      if (reveal && this.revealElement(wrappers[0])) {
        return this.calculateProgress();
      }
    }
    return null;
  },
  // 反查：把屏幕坐标解析到所属 cue 的标识，供中键 seek 用。先认合成书可点的
  // [data-cue-id]（sentenceIndex），否则用 caret 点在 cueRangesMap / cueWrappers
  // （键=textFragmentId）里做包含判定。命中回 JSON.stringify({type,id})，无命中
  // 回 null。复用既有 cue↔DOM 映射，不碰 normChar 反查数学（规避码点代理对错位）。
  cueIdAtPoint: function(x, y) {
    var el = document.elementFromPoint(x, y);
    if (el && el.closest) {
      var sidEl = el.closest('[data-cue-id]');
      if (sidEl) {
        var sid = sidEl.getAttribute('data-cue-id');
        if (sid !== null) return JSON.stringify({ type: 'sid', id: sid });
      }
    }
    if (!window.hoshiSelection || !window.hoshiSelection.getCaretRange) return null;
    var caret = window.hoshiSelection.getCaretRange(x, y);
    if (!caret) return null;
    var node = caret.startContainer, off = caret.startOffset;
    var found = null;
    if (this.cueRangesMap && this.cueRangesMap.size) {
      this.cueRangesMap.forEach(function(ranges, id) {
        if (found) return;
        for (var i = 0; i < ranges.length; i++) {
          try { if (ranges[i].comparePoint(node, off) === 0) { found = id; break; } }
          catch (e) {}
        }
      });
      if (found) return JSON.stringify({ type: 'frag', id: found });
    }
    if (this.cueRubyElements && this.cueRubyElements.size) {
      this.cueRubyElements.forEach(function(rubyElements, id) {
        if (found) return;
        for (var i = 0; i < rubyElements.length; i++) {
          if (rubyElements[i].contains(node)) { found = id; break; }
        }
      });
      if (found) return JSON.stringify({ type: 'frag', id: found });
    }
    if (this.cueWrappers && this.cueWrappers.size) {
      this.cueWrappers.forEach(function(wrappers, id) {
        if (found) return;
        for (var i = 0; i < wrappers.length; i++) {
          if (wrappers[i].contains(node)) { found = id; break; }
        }
      });
      if (found) return JSON.stringify({ type: 'frag', id: found });
    }
    return null;
  },
  clearSasayakiCue: function() {
    if (!this.activeCueId) return;
    if (window.__hoshiCssHighlightsSupported) {
      CSS.highlights.delete('hoshi-sasayaki');
      var rubyElements = this.cueRubyElements.get(this.activeCueId) || [];
      rubyElements.forEach(function(ruby) { ruby.classList.remove('hoshi-sasayaki-ruby-active'); });
    } else {
      var wrappers = this.cueWrappers.get(this.activeCueId) || [];
      wrappers.forEach(function(wrapper) { wrapper.classList.remove('hoshi-sasayaki-active'); });
    }
    this.activeCueId = null;
  },
  resetSasayakiCues: function() {
    if (window.hoshiSelection) window.hoshiSelection.clearSelection();
    if (window.__hoshiCssHighlightsSupported) {
      CSS.highlights.delete('hoshi-sasayaki');
      this.cueRubyElements.forEach(function(rubyElements) {
        rubyElements.forEach(function(ruby) { ruby.classList.remove('hoshi-sasayaki-ruby-active'); });
      });
      this.cueRubyElements.clear();
      this.cueRangesMap.clear();
    } else {
      var self = this;
      this.cueWrappers.forEach(function(wrappers) { self.unwrap(wrappers); });
      this.cueWrappers.clear();
    }
    this.activeCueId = null;
  },
  unwrap: function(wrappers) {
    wrappers.forEach(function(wrapper) {
      var parent = wrapper.parentNode;
      if (!parent) return;
      while (wrapper.firstChild) {
        parent.insertBefore(wrapper.firstChild, wrapper);
      }
      parent.removeChild(wrapper);
      parent.normalize();
    });
  },
  scrollToSearchMatch: function(query, hintOffset) {
    if (!query) return null;
    var walker = this.createWalker();
    var node;
    var segments = [];
    while (node = walker.nextNode()) {
      segments.push({ node: node, text: node.textContent });
    }
    var fullText = segments.map(function(s) { return s.text; }).join('');
    var lowerQuery = query.toLowerCase();
    var lowerFull = fullText.toLowerCase();
    var matches = [];
    var searchFrom = 0;
    while (searchFrom <= lowerFull.length) {
      var idx = lowerFull.indexOf(lowerQuery, searchFrom);
      if (idx < 0) break;
      matches.push(idx);
      searchFrom = idx + 1;
    }
    if (!matches.length) return null;
    var bestIdx = matches[0];
    var bestDist = Math.abs(bestIdx - hintOffset);
    for (var m = 1; m < matches.length; m++) {
      var dist = Math.abs(matches[m] - hintOffset);
      if (dist < bestDist) { bestIdx = matches[m]; bestDist = dist; }
    }
    var targetStart = bestIdx;
    var targetEnd = targetStart + query.length;
    var charPos = 0;
    var startNode = null, startOffset = 0, endNode = null, endOffset = 0;
    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i];
      var segEnd = charPos + seg.text.length;
      if (!startNode && targetStart < segEnd) {
        startNode = seg.node;
        startOffset = targetStart - charPos;
      }
      if (targetEnd <= segEnd) {
        endNode = seg.node;
        endOffset = targetEnd - charPos;
        break;
      }
      charPos = segEnd;
    }
    if (!startNode || !endNode) return null;
    var range = document.createRange();
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset);
    if (window.__hoshiCssHighlightsSupported) {
      CSS.highlights.set('hoshi-search', new Highlight(range));
    }
    if (this.scrollToRange) {
      this.scrollToRange(range);
    } else if (this.scrollToTarget) {
      var span = document.createElement('span');
      range.surroundContents(span);
      this.scrollToTarget(span);
    }
    return this.calculateProgress();
  },
  clearSearchHighlight: function() {
    if (window.__hoshiCssHighlightsSupported) {
      CSS.highlights.delete('hoshi-search');
    }
  },
''';

  // ── Shared init logic (viewport + SVG + images) ────────────────────

  static const String _sharedInitViewport = '''
  var viewport = document.querySelector('meta[name="viewport"]');
  if (viewport) { viewport.remove(); }
  var newViewport = document.createElement('meta');
  newViewport.name = 'viewport';
  newViewport.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
  document.head.appendChild(newViewport);
''';

  static String _sharedInitImages() => '''
  Array.from(document.querySelectorAll('svg')).forEach(function(svg) {
    var svgImage = svg.querySelector('image');
    if (!svgImage) return;
    if (svg.getAttribute('preserveAspectRatio') === 'none') {
      svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
    }
    if (svg.classList.contains('gaiji') || svg.classList.contains('gaiji-line')) return;
    // Fixed-layout EPUB covers/illustrations ship as <svg><image> instead of
    // <img>. Give large ones the same block treatment as <img> below (centre
    // via .block-img-wrapper + tap-to-zoom) so they don't fall through as
    // inline content that drifts to the page edge in vertical-rl reflow.
    var iw = parseFloat(svgImage.getAttribute('width')) || 0;
    var ih = parseFloat(svgImage.getAttribute('height')) || 0;
    if (iw <= 256 && ih <= 256) {
      var vb = (svg.getAttribute('viewBox') || '').split(/[ ,]+/);
      iw = parseFloat(vb[2]) || iw;
      ih = parseFloat(vb[3]) || ih;
    }
    if ((iw > 256 || ih > 256) && !svg.closest('.block-img-wrapper')) {
      svg.classList.add('block-img');
      var swrap = document.createElement('div');
      swrap.className = 'block-img-wrapper';
      svg.parentNode.insertBefore(swrap, svg);
      swrap.appendChild(svg);
    }
  });
  var imagePromises = Array.from(document.querySelectorAll('img')).map(function(img) {
    return new Promise(function(resolve) {
      var isGaiji = img.classList.contains('gaiji') || img.classList.contains('gaiji-line');
      var mark = function() {
        if (!isGaiji && (img.naturalWidth > 256 || img.naturalHeight > 256)) {
          img.classList.add('block-img');
          var wrapper = document.createElement('div');
          wrapper.className = 'block-img-wrapper';
          img.parentNode.insertBefore(wrapper, img);
          wrapper.appendChild(img);
        }
        resolve();
      };
      if (img.complete && img.naturalWidth > 0) {
        mark();
      } else {
        img.onload = mark;
        img.onerror = function() { resolve(); };
      }
    });
  });
''';

  static const String _sharedInitBoot = '''
window.addEventListener('load', function() {
  window.hoshiReader.initialize();
});
if (document.readyState === 'complete') {
  window.hoshiReader.initialize();
}
''';

  // ── Paginated mode ─────────────────────────────────────────────────

  static String _paginatedShellScript({
    required double initialProgress,
    int fontSize = ReaderLayoutDefaults.fontSizePx,
    String? sasayakiCuesJson,
    String? initialFragment,
    double chromeTopInset = 0.0,
    double chromeBottomInset = 0.0,
    double? dartPageWidth,
    double? dartPageHeight,
  }) {
    final String initialRestoreScript = initialFragment != null
        ? 'window.hoshiReader.jumpToFragment(${_jsStringLiteral(initialFragment)});'
        : 'window.hoshiReader.restoreProgress($initialProgress);';

    final String sasayakiInit = sasayakiCuesJson != null
        ? 'window.hoshiReader.applySasayakiCues($sasayakiCuesJson);'
        : '';

    const int bottomOverlapPx = ReaderLayoutDefaults.bottomOverlapPx;
    const double imageWidthRatio = ReaderLayoutDefaults.imageWidthViewportRatio;
    const String spacerHeight = ReaderLayoutDefaults.trailingSpacerHeightCss;
    const String spacerWidth = ReaderLayoutDefaults.trailingSpacerWidthCss;

    final String initImages = _sharedInitImages();

    return '''<script>
window.__hoshiCssHighlightsSupported = !!(window.CSS && CSS.highlights && window.Highlight);
window.hoshiReader = {
  pageHeight: 0,
  pageWidth: 0,
  paginationMetrics: null,
$_sharedJs
  revealElement: function(element) {
    var range = document.createRange();
    range.selectNodeContents(element);
    return this.scrollToRange(range);
  },
  getScrollContext: function() {
    var vertical = this.isVertical();
    var scrollEl = document.body;
    var cs = getComputedStyle(scrollEl);
    var pageSize;
    if (vertical) {
      var pt = parseFloat(cs.paddingTop) || 0;
      var pb = parseFloat(cs.paddingBottom) || 0;
      pageSize = (this.pageHeight || scrollEl.clientHeight || window.innerHeight) - pt - pb;
    } else {
      var pl = parseFloat(cs.paddingLeft) || 0;
      var pr = parseFloat(cs.paddingRight) || 0;
      pageSize = (scrollEl.clientWidth || this.pageWidth || window.innerWidth) - pl - pr;
    }
    pageSize = Math.max(1, pageSize);
    var clientSize = vertical
      ? (this.pageHeight || scrollEl.clientHeight || window.innerHeight)
      : (scrollEl.clientWidth || this.pageWidth || window.innerWidth);
    var gap = parseFloat(cs.columnGap) || 0;
    // Column pitch = one page worth of column(s). The CSS column period is
    // (column-width + column-gap); the single column expands to fill the content
    // box, so that equals (content size + gap) = pageSize + gap. pageSize already
    // subtracts body padding. Using the full clientSize here (the old behaviour)
    // ignored padding, so once chrome insets enlarged padding-top/bottom the
    // vertical pitch over-scrolled by exactly (chrome-top + chrome-bottom) every
    // page and the text drifted further each turn. For horizontal this equals the
    // old "clientSize + fontSize" because the gap already carries the left/right
    // margins that pageSize's padding subtraction cancels out.
    var columnPitch = pageSize + gap;
    var totalSize = vertical ? scrollEl.scrollHeight : scrollEl.scrollWidth;
    var maxScroll = Math.max(0, totalSize - clientSize);
    var pageHeightVar = getComputedStyle(document.documentElement).getPropertyValue('--page-height');
    var bodyRect = scrollEl.getBoundingClientRect();
    var htmlCH = document.documentElement.clientHeight;
    console.log('[HoshiPagination] ctx: v=' + vertical
      + ' hoshiPH=' + this.pageHeight + ' clientH=' + scrollEl.clientHeight
      + ' bodyRectH=' + bodyRect.height + ' --page-height=' + pageHeightVar
      + ' scrollH=' + scrollEl.scrollHeight
      + ' pageSize=' + pageSize + ' pitch=' + columnPitch
      + ' cssGap=' + gap + ' innerH=' + window.innerHeight);
    return { vertical: vertical, scrollEl: scrollEl, pageSize: pageSize, columnPitch: columnPitch, maxScroll: maxScroll };
  },
  getPagePosition: function(context) {
    return context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
  },
  lockRootViewport: function() {
    var root = document.documentElement;
    var didScroll = false;
    if (root.scrollTop !== 0) {
      root.scrollTop = 0;
      didScroll = true;
    }
    if (root.scrollLeft !== 0) {
      root.scrollLeft = 0;
      didScroll = true;
    }
    if (window.scrollX !== 0 || window.scrollY !== 0) {
      window.scrollTo(0, 0);
      didScroll = true;
    }
    return didScroll;
  },
  assignPagePosition: function(context, position) {
    if (context.vertical) {
      context.scrollEl.scrollTop = position;
    } else {
      context.scrollEl.scrollLeft = position;
    }
    this.lockRootViewport();
  },
  setPagePosition: function(context, position) {
    var clamped = Math.min(Math.max(0, position), context.maxScroll);
    window.lastPageScroll = clamped;
    this.assignPagePosition(context, clamped);
    return clamped;
  },
  registerSnapScroll: function(initialScroll) {
    if (window.snapScrollRegistered) return;
    window.snapScrollRegistered = true;
    window.lastPageScroll = initialScroll;
    this.lockRootViewport();
    window.addEventListener('scroll', () => {
      if (this.lockRootViewport()) {
        requestAnimationFrame(() => this.lockRootViewport());
      }
    }, { passive: true });
    document.body.addEventListener('scroll', () => {
      this.lockRootViewport();
      var context = this.getScrollContext();
      if (context.columnPitch <= 0) return;
      var currentScroll = this.getPagePosition(context);
      var snappedScroll = Math.round(currentScroll / context.columnPitch) * context.columnPitch;
      snappedScroll = Math.min(Math.max(0, snappedScroll), context.maxScroll);
      if (Math.abs(currentScroll - snappedScroll) > 1) {
        this.assignPagePosition(context, window.lastPageScroll || 0);
      } else {
        window.lastPageScroll = snappedScroll;
      }
    }, { passive: true });
  },
  alignToPage: function(context, offset) {
    return Math.floor(Math.max(0, offset) / context.columnPitch) * context.columnPitch;
  },
  alignContentStartToPage: function(context, offset) {
    var safeOffset = Math.max(0, offset);
    var nearestPage = Math.round(safeOffset / context.columnPitch) * context.columnPitch;
    if (Math.abs(safeOffset - nearestPage) < 1) {
      return nearestPage;
    }
    return this.alignToPage(context, safeOffset);
  },
  scrollToRange: function(range) {
    var context = this.getScrollContext();
    if (context.pageSize <= 0) return false;
    var rect = this.getRect(range);
    var currentScroll = this.getPagePosition(context);
    var anchor = (context.vertical ? (rect.top + rect.bottom) / 2 : (rect.left + rect.right) / 2) + currentScroll;
    var targetScroll = this.alignToPage(context, anchor);
    if (targetScroll === currentScroll) return false;
    this.setPagePosition(context, targetScroll);
    var self = this;
    requestAnimationFrame(function() {
      self.setPagePosition(context, targetScroll);
    });
    return true;
  },
  contentLastPageScroll: function(context) {
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    return metrics.maxScroll;
  },
  contentFirstPageScroll: function(context) {
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    return metrics.minScroll;
  },
  buildPaginationMetrics: function() {
    var context = this.getScrollContext();
    var currentScroll = this.getPagePosition(context);
    var maxAlignedScroll = Math.floor(context.maxScroll / context.columnPitch) * context.columnPitch;
    if (context.pageSize <= 0) {
      var emptyMetrics = { minScroll: 0, maxScroll: 0, totalChars: 0, progressStops: [] };
      this.paginationMetrics = emptyMetrics;
      return emptyMetrics;
    }
    var lastContentEdge = 0;
    var firstContentEdge = null;
    var progressStops = [];
    var exploredChars = 0;
    var totalChars = 0;
    var walker = this.createWalker();
    var node;
    while (node = walker.nextNode()) {
      var nodeLen = this.countChars(node.textContent);
      totalChars += nodeLen;
      if (nodeLen <= 0) continue;
      var range = document.createRange();
      range.selectNodeContents(node);
      var rects = range.getClientRects();
      var progressRect = this.getRect(range);
      var nodeStartEdge = progressRect && progressRect.width > 0 && progressRect.height > 0
        ? (context.vertical ? progressRect.top : progressRect.left) + currentScroll
        : null;
      for (var i = 0; i < rects.length; i++) {
        var rect = rects[i];
        if (rect.width <= 0 || rect.height <= 0) continue;
        var startEdge = (context.vertical ? rect.top : rect.left) + currentScroll;
        var endEdge = (context.vertical ? rect.bottom : rect.right) + currentScroll;
        firstContentEdge = firstContentEdge === null ? startEdge : Math.min(firstContentEdge, startEdge);
        lastContentEdge = Math.max(lastContentEdge, endEdge);
      }
      if (nodeStartEdge !== null) {
        progressStops.push({ scroll: nodeStartEdge, exploredChars: exploredChars + nodeLen });
      }
      exploredChars += nodeLen;
    }
    var media = document.querySelectorAll('img, svg, image, video, canvas');
    for (var j = 0; j < media.length; j++) {
      var mediaRect = media[j].getBoundingClientRect();
      if (mediaRect.width <= 0 || mediaRect.height <= 0) continue;
      var mediaStart = (context.vertical ? mediaRect.top : mediaRect.left) + currentScroll;
      var mediaEnd = (context.vertical ? mediaRect.bottom : mediaRect.right) + currentScroll;
      firstContentEdge = firstContentEdge === null ? mediaStart : Math.min(firstContentEdge, mediaStart);
      lastContentEdge = Math.max(lastContentEdge, mediaEnd);
    }
    var minScroll = firstContentEdge === null ? 0 : Math.min(maxAlignedScroll, this.alignContentStartToPage(context, firstContentEdge));
    var lastContentScroll = lastContentEdge <= 0 ? 0 : Math.floor(Math.max(0, lastContentEdge - 1) / context.columnPitch) * context.columnPitch;
    var maxScroll = Math.min(maxAlignedScroll, lastContentScroll);
    progressStops.sort(function(a, b) { return a.scroll - b.scroll; });
    var metrics = {
      minScroll: minScroll,
      maxScroll: maxScroll,
      totalChars: totalChars,
      progressStops: progressStops
    };
    this.paginationMetrics = metrics;
    return metrics;
  },
  calculateProgress: function() {
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    if (metrics.totalChars <= 0) return 0;
    var context = this.getScrollContext();
    var currentScroll = this.getPagePosition(context);
    var stops = metrics.progressStops;
    var low = 0;
    var high = stops.length - 1;
    var exploredChars = 0;
    while (low <= high) {
      var mid = Math.floor((low + high) / 2);
      if (stops[mid].scroll <= currentScroll) {
        exploredChars = stops[mid].exploredChars;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return exploredChars / metrics.totalChars;
  },
  pageInfo: function() {
    // Page numbers only make sense once layout has settled. During a
    // pending re-anchor rAF (page-size / chrome-inset transition) getPagePosition
    // can read a transiently reset scrollTop (see setChromeInsets / HBK-REG-004),
    // which would mis-report page 1 — so bail and let the caller show no page.
    if (this._reanchorPending === true) return null;
    var context = this.getScrollContext();
    if (context.pageSize <= 0 || context.columnPitch <= 0) return null;
    // totalPages math relies on min/maxScroll being whole-columnPitch aligned,
    // which buildPaginationMetrics guarantees (alignContentStartToPage / floor*pitch).
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    var span = Math.max(0, metrics.maxScroll - metrics.minScroll);
    var totalPages = Math.round(span / context.columnPitch) + 1;
    var currentScroll = this.getPagePosition(context);
    var page = Math.round((currentScroll - metrics.minScroll) / context.columnPitch) + 1;
    if (page < 1) page = 1;
    if (page > totalPages) page = totalPages;
    return { currentPage: page, totalPages: totalPages };
  },
  restoreProgress: async function(progress) {
    await document.fonts.ready;
    var context = this.getScrollContext();
    this.scrollToProgressPaged(context, progress);
    var pos = this.getPagePosition(context);
    var self = this;
    setTimeout(function() {
      self.setPagePosition(context, pos);
      self.registerSnapScroll(pos);
      setTimeout(function() { self.notifyRestoreComplete(); }, 16);
    }, 16);
  },
  jumpToFragment: async function(fragment) {
    await document.fonts.ready;
    var context = this.getScrollContext();
    var rawFragment = (fragment || '').trim();
    var target = rawFragment && (document.getElementById(rawFragment) || document.getElementsByName(rawFragment)[0]);
    if (context.pageSize <= 0 || !target) {
      this.registerSnapScroll(this.getPagePosition(context));
      this.notifyRestoreComplete();
      return false;
    }
    var rect = this.getRect(target);
    var currentScroll = this.getPagePosition(context);
    var anchor = (context.vertical ? rect.top : rect.left) + currentScroll;
    var targetScroll = this.alignToPage(context, anchor);
    this.setPagePosition(context, targetScroll);
    var self = this;
    setTimeout(function() {
      self.setPagePosition(context, targetScroll);
      self.registerSnapScroll(targetScroll);
      setTimeout(function() { self.notifyRestoreComplete(); }, 16);
    }, 16);
    return true;
  },
  paginate: function(direction) {
    var context = this.getScrollContext();
    if (context.columnPitch <= 0) return "limit";
    var currentScroll = this.getPagePosition(context);
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    var minAlignedScroll = metrics.minScroll;
    var maxAlignedScroll = metrics.maxScroll;
    var actualScroll = this.getPagePosition(context);
    if (direction === "forward") {
      if ((currentScroll + context.columnPitch) <= (maxAlignedScroll + 1)) {
        var targetForward = Math.round((currentScroll + context.columnPitch) / context.columnPitch) * context.columnPitch;
        this.setPagePosition(context, targetForward);
        var afterScroll = this.getPagePosition(context);
        console.log('[HoshiPagination] paginate FORWARD: before=' + currentScroll
          + ' target=' + targetForward + ' after=' + afterScroll
          + ' pitch=' + context.columnPitch + ' drift=' + (afterScroll - targetForward)
          + ' min=' + minAlignedScroll + ' max=' + maxAlignedScroll);
        return "scrolled";
      }
      return "limit";
    } else {
      if (currentScroll > (minAlignedScroll + 1)) {
        var targetBack = Math.round((currentScroll - context.columnPitch) / context.columnPitch) * context.columnPitch;
        targetBack = Math.max(minAlignedScroll, targetBack);
        this.setPagePosition(context, targetBack);
        var afterScroll = this.getPagePosition(context);
        console.log('[HoshiPagination] paginate BACKWARD: before=' + currentScroll
          + ' target=' + targetBack + ' after=' + afterScroll
          + ' pitch=' + context.columnPitch + ' drift=' + (afterScroll - targetBack)
          + ' min=' + minAlignedScroll + ' max=' + maxAlignedScroll);
        return "scrolled";
      }
      return "limit";
    }
  },
  getFirstVisibleCharOffset: function() {
    var context = this.getScrollContext();
    var cs = getComputedStyle(document.body);
    var pt = parseFloat(cs.paddingTop) || 0;
    var pl = parseFloat(cs.paddingLeft) || 0;
    var pr = parseFloat(cs.paddingRight) || 0;
    var x = context.vertical ? (document.body.clientWidth - pr - 2) : (pl + 2);
    var y = pt + 2;
    var range = document.caretRangeFromPoint(x, y);
    if (!range || !range.startContainer) return -1;
    var target = range.startContainer;
    if (target.nodeType !== Node.TEXT_NODE) {
      var walker = this.createWalker(target);
      target = walker.nextNode();
      if (!target) return -1;
    }
    var baseOffset = this.nodeStartOffsets.get(target);
    if (baseOffset === undefined) {
      this.buildNodeOffsets();
      baseOffset = this.nodeStartOffsets.get(target);
      if (baseOffset === undefined) return -1;
    }
    var localChars = 0;
    var text = target.textContent;
    var limit = Math.min(range.startOffset, text.length);
    for (var i = 0; i < limit; i++) {
      var cp = text.codePointAt(i);
      var char = String.fromCodePoint(cp);
      if (this.isMatchableChar(char)) localChars++;
      if (cp > 0xFFFF) i++;
    }
    return baseOffset + localChars;
  },
  scrollToCharOffset: function(charOffset, hintScroll) {
    var walker = this.createWalker();
    var node;
    var runningOffset = 0;
    var targetNode = null;
    var remaining = 0;
    while (node = walker.nextNode()) {
      var nodeChars = this.countChars(node.textContent);
      if (runningOffset + nodeChars > charOffset) {
        targetNode = node;
        remaining = charOffset - runningOffset;
        break;
      }
      runningOffset += nodeChars;
    }
    if (!targetNode) return;
    var charIdx = 0;
    var textOffset = 0;
    var text = targetNode.textContent;
    for (var i = 0; i < text.length && charIdx < remaining; i++) {
      var cp = text.codePointAt(i);
      var ch = String.fromCodePoint(cp);
      if (this.isMatchableChar(ch)) charIdx++;
      if (cp > 0xFFFF) i++;
      textOffset = i + 1;
    }
    var range = document.createRange();
    range.setStart(targetNode, Math.min(textOffset, text.length));
    range.collapse(true);
    var rect = range.getBoundingClientRect();
    var context = this.getScrollContext();
    var scrollOffset = context.vertical
      ? (context.scrollEl.scrollTop + rect.top)
      : (context.scrollEl.scrollLeft + rect.left);
    var charPage = Math.floor(Math.max(0, scrollOffset) / context.columnPitch);
    var aligned;
    if (hintScroll !== undefined) {
      // Page-stable hint: if the target char is within one page of where we
      // started, keep the original page so a ±1-column repagination doesn't
      // visibly shift the reader; otherwise jump to the char's actual page.
      var origPage = Math.round(hintScroll / context.columnPitch);
      aligned = (Math.abs(charPage - origPage) <= 1)
        ? origPage * context.columnPitch
        : charPage * context.columnPitch;
    } else {
      aligned = charPage * context.columnPitch;
    }
    this.setPagePosition(context, aligned);
  },
  setChromeInsets: function(topPx, bottomPx) {
    // Re-anchoring (after a chrome-inset OR a page-size change) is serialised
    // through one shared in-flight flag, _reanchorPending. A layout change
    // transiently resets scrollTop to 0; if a re-anchor rAF is already pending
    // (from this handler or updatePageSize), reading a fresh char offset now
    // would sample that reset as the chapter start and snap there. So when one
    // is in flight we only apply the new CSS and let the pending rAF restore
    // position once the layout settles. This serialises without masking via a
    // delay, and covers both rapid toggles and toggle/resize interleaving.
    // (HBK-REG-004)
    var inFlight = this._reanchorPending === true;
    var charOffset = inFlight ? -1 : this.getFirstVisibleCharOffset();
    var scrollBefore = inFlight ? 0 : this.getPagePosition(this.getScrollContext());
    document.documentElement.style.setProperty('--chrome-top-inset', topPx + 'px');
    document.documentElement.style.setProperty('--chrome-bottom-inset', bottomPx + 'px');
    if (inFlight || charOffset < 0) return;
    this._reanchorPending = true;
    var self = this;
    requestAnimationFrame(function() {
      try {
        self.scrollToCharOffset(charOffset, scrollBefore);
      } finally {
        self._reanchorPending = false;
      }
    });
  }
};
window.hoshiReader._contentSize = function() {
  var cs = getComputedStyle(document.body);
  var pl = parseFloat(cs.paddingLeft) || 0;
  var pr = parseFloat(cs.paddingRight) || 0;
  var pt = parseFloat(cs.paddingTop) || 0;
  var pb = parseFloat(cs.paddingBottom) || 0;
  return { w: (document.body.clientWidth || window.innerWidth) - pl - pr, h: (document.body.clientHeight || window.innerHeight) - pt - pb };
};
window.hoshiReader.initialize = function() {
  if (window.hoshiReader.didInitialize) return;
  window.hoshiReader.didInitialize = true;
  document.documentElement.style.setProperty('--chrome-top-inset', '${chromeTopInset}px');
  document.documentElement.style.setProperty('--chrome-bottom-inset', '${chromeBottomInset}px');
$_sharedInitViewport
  var dartW = ${dartPageWidth != null ? '${dartPageWidth.round()}' : 'null'};
  var dartH = ${dartPageHeight != null ? '${dartPageHeight.round()}' : 'null'};
  var pageWidth = dartW || window.innerWidth;
  var pageHeight = (dartH || window.innerHeight) + $bottomOverlapPx;
  console.log('[HoshiInit] dartW=' + dartW + ' dartH=' + dartH
    + ' innerW=' + window.innerWidth + ' innerH=' + window.innerHeight
    + ' usedW=' + pageWidth + ' usedH=' + pageHeight);
  document.documentElement.style.setProperty('--page-height', pageHeight + 'px');
  document.documentElement.style.setProperty('--page-width', pageWidth + 'px');
  var cs = this._contentSize();
  document.documentElement.style.setProperty('--hoshi-image-max-width', Math.max(1, Math.floor(cs.w * $imageWidthRatio)) + 'px');
  document.documentElement.style.setProperty('--hoshi-image-max-height', Math.max(1, cs.h) + 'px');
  window.hoshiReader.pageHeight = pageHeight;
  window.hoshiReader.pageWidth = pageWidth;
$initImages
  var spacer = document.createElement('div');
  spacer.style.height = '$spacerHeight';
  spacer.style.width = '$spacerWidth';
  spacer.style.display = 'block';
  spacer.style.breakInside = 'avoid';
  document.body.appendChild(spacer);
  Promise.all(imagePromises).then(function() {
    window.hoshiReader.buildNodeOffsets();
    $sasayakiInit
    $initialRestoreScript
  });
};
window.hoshiReader.updatePageSize = function(cssWidth, cssHeight) {
  var newHeight = Math.round(cssHeight) + $bottomOverlapPx;
  var newWidth = Math.round(cssWidth);
  if (newHeight === this.pageHeight && newWidth === this.pageWidth) return;
  // Shares the _reanchorPending flag with setChromeInsets (see there). If a
  // re-anchor rAF is already pending, reading calculateProgress now would read a
  // transiently reset scrollTop as progress 0 and snap to the chapter start, so
  // we only update the page metrics and let the pending rAF restore position.
  var inFlight = this._reanchorPending === true;
  var progress = inFlight ? 0 : this.calculateProgress();
  document.documentElement.style.setProperty('--page-height', newHeight + 'px');
  document.documentElement.style.setProperty('--page-width', newWidth + 'px');
  var cs = this._contentSize();
  document.documentElement.style.setProperty('--hoshi-image-max-width', Math.max(1, Math.floor(cs.w * $imageWidthRatio)) + 'px');
  document.documentElement.style.setProperty('--hoshi-image-max-height', Math.max(1, cs.h) + 'px');
  this.pageHeight = newHeight;
  this.pageWidth = newWidth;
  this.paginationMetrics = null;
  if (inFlight) return;
  this._reanchorPending = true;
  var self = this;
  requestAnimationFrame(function() {
    try {
      self.scrollToProgressPaged(self.getScrollContext(), progress);
    } finally {
      self._reanchorPending = false;
    }
  });
};
window.hoshiReader.reanchorAfterStyleChange = function(styleEl, css) {
  // 外部 live CSS 变更（字体大小 / 字体 / 主题 / 行间 / 余白）会让 body 重新分页
  // 排版。必须「重排前捕捉位置 → 换样式 → 失效 metrics → rAF 重锚」，否则 body 停在
  // 重排前的错位滚动量、且重排过程残留的 root scrollTop 不被清掉，最上一行被裁
  // （BUG-023）。
  //
  // BUG-109：重锚必须用**精确字符偏移**（getFirstVisibleCharOffset →
  // scrollToCharOffset），对齐同文件 setChromeInsets 的成熟路径，而非粗粒度进度分数
  // （calculateProgress → scrollToProgressPaged）。进度分数 = 已读字符/总字符，重排后
  // 字形宽度与列宽变化 → 同一分数反推出的字符落点 + alignToPage 取整落到相邻页边界
  // → 切主题/字体「翻页」。getFirstVisibleCharOffset 锚到首个可见字符的真实所在页，
  // 并用 scrollBefore 作 page-stable hint（±1 列保持原页）抑制微小重排的可见跳动。
  //
  // 共用 _reanchorPending 串行标志，避免与 chrome-inset / 页尺寸重锚互相打架
  // （见 setChromeInsets / updatePageSize，HBK-REG-004）。
  if (!this.didInitialize) { styleEl.textContent = css; return; }
  var inFlight = this._reanchorPending === true;
  var charOffset = inFlight ? -1 : this.getFirstVisibleCharOffset();
  var scrollBefore = inFlight ? 0 : this.getPagePosition(this.getScrollContext());
  styleEl.textContent = css;
  this.paginationMetrics = null;
  var cs = this._contentSize();
  document.documentElement.style.setProperty('--hoshi-image-max-width', Math.max(1, Math.floor(cs.w * $imageWidthRatio)) + 'px');
  document.documentElement.style.setProperty('--hoshi-image-max-height', Math.max(1, cs.h) + 'px');
  if (inFlight || charOffset < 0) return;
  this._reanchorPending = true;
  var self = this;
  requestAnimationFrame(function() {
    try {
      self.scrollToCharOffset(charOffset, scrollBefore);
    } finally {
      self._reanchorPending = false;
    }
  });
};
$_sharedInitBoot
</script>''';
  }

  // ── Continuous mode ────────────────────────────────────────────────

  static String _continuousShellScript({
    required double initialProgress,
    String? sasayakiCuesJson,
    String? initialFragment,
    double chromeTopInset = 0.0,
    double chromeBottomInset = 0.0,
    double? dartPageWidth,
    double? dartPageHeight,
  }) {
    final String initialRestoreScript = initialFragment != null
        ? 'window.hoshiReader.jumpToFragment(${_jsStringLiteral(initialFragment)});'
        : 'window.hoshiReader.restoreProgress($initialProgress);';

    final String sasayakiInit = sasayakiCuesJson != null
        ? 'window.hoshiReader.applySasayakiCues($sasayakiCuesJson);'
        : '';

    const double imageWidthRatio = ReaderLayoutDefaults.imageWidthViewportRatio;

    final String initImages = _sharedInitImages();

    return '''<script>
window.__hoshiCssHighlightsSupported = !!(window.CSS && CSS.highlights && window.Highlight);
window.hoshiReader = {
$_sharedJs
  scrollToChapterStart: function() {
    var root = document.scrollingElement || document.documentElement;
    window.scrollTo(0, 0);
    root.scrollTop = 0;
    root.scrollLeft = 0;
    document.documentElement.scrollTop = 0;
    document.documentElement.scrollLeft = 0;
    document.body.scrollTop = 0;
    document.body.scrollLeft = 0;
  },
  scrollToTarget: function(target) {
    var rect = this.getRect(target);
    var margin = 0.15;
    var wm = window.getComputedStyle(document.body).writingMode;
    if (wm.startsWith('vertical')) {
      var vw = window.innerWidth;
      var safe = vw * margin;
      if (rect.left >= safe && rect.right <= vw - safe) return false;
      if (wm === 'vertical-rl') {
        window.scrollBy({left: rect.right - (vw - safe), behavior: 'smooth'});
      } else {
        window.scrollBy({left: rect.left - safe, behavior: 'smooth'});
      }
    } else {
      var vh = window.innerHeight;
      var safe = vh * margin;
      if (rect.top >= safe && rect.bottom <= vh - safe) return false;
      window.scrollBy({top: rect.top - safe, behavior: 'smooth'});
    }
    return true;
  },
  revealElement: function(element) {
    return this.scrollToTarget(element);
  },
  calculateProgress: function() {
    var vertical = this.isVertical();
    var walker = this.createWalker();
    var totalChars = 0;
    var exploredChars = 0;
    var node;
    while (node = walker.nextNode()) {
      var nodeLen = this.countChars(node.textContent);
      totalChars += nodeLen;
      if (nodeLen > 0) {
        var range = document.createRange();
        range.selectNodeContents(node);
        var rect = this.getRect(range);
        if (vertical ? (rect.left > window.innerWidth) : (rect.bottom < 0)) {
          exploredChars += nodeLen;
        }
      }
    }
    return totalChars > 0 ? exploredChars / totalChars : 0;
  },
  restoreProgress: async function(progress) {
    await document.fonts.ready;
    var self = this;
    if (progress <= 0) {
      this.scrollToChapterStart();
      setTimeout(function() {
        self.scrollToChapterStart();
        self.notifyRestoreComplete();
      }, 16);
      return;
    }
    this.scrollToProgressContinuous(progress);
    setTimeout(function() {
      setTimeout(function() { self.notifyRestoreComplete(); }, 16);
    }, 16);
  },
  jumpToFragment: async function(fragment) {
    await document.fonts.ready;
    var rawFragment = (fragment || '').trim();
    var target = rawFragment && (document.getElementById(rawFragment) || document.getElementsByName(rawFragment)[0]);
    if (!target) {
      this.notifyRestoreComplete();
      return false;
    }
    var self = this;
    target.scrollIntoView();
    setTimeout(function() {
      setTimeout(function() { self.notifyRestoreComplete(); }, 16);
    }, 16);
    return true;
  },
  paginate: function(direction) {
    var vertical = this.isVertical();
    var root = document.scrollingElement || document.documentElement;
    if (direction === "forward") {
      if (vertical) {
        return Math.abs(window.scrollX) + window.innerWidth >= root.scrollWidth - 2 ? "limit" : "scrolled";
      }
      return root.scrollTop + window.innerHeight >= root.scrollHeight - 2 ? "limit" : "scrolled";
    }
    if (vertical) {
      return window.scrollX >= -2 ? "limit" : "scrolled";
    }
    return root.scrollTop <= 2 ? "limit" : "scrolled";
  },
  getFirstVisibleCharOffset: function() {
    var vertical = this.isVertical();
    var cs = getComputedStyle(document.body);
    var pt = parseFloat(cs.paddingTop) || 0;
    var pl = parseFloat(cs.paddingLeft) || 0;
    var pr = parseFloat(cs.paddingRight) || 0;
    var x = vertical ? (document.body.clientWidth - pr - 2) : (pl + 2);
    var y = pt + 2;
    var range = document.caretRangeFromPoint(x, y);
    if (!range || !range.startContainer) return -1;
    var target = range.startContainer;
    if (target.nodeType !== Node.TEXT_NODE) {
      var walker = this.createWalker(target);
      target = walker.nextNode();
      if (!target) return -1;
    }
    var baseOffset = this.nodeStartOffsets.get(target);
    if (baseOffset === undefined) {
      this.buildNodeOffsets();
      baseOffset = this.nodeStartOffsets.get(target);
      if (baseOffset === undefined) return -1;
    }
    var localChars = 0;
    var text = target.textContent;
    var limit = Math.min(range.startOffset, text.length);
    for (var i = 0; i < limit; i++) {
      var cp = text.codePointAt(i);
      var char = String.fromCodePoint(cp);
      if (this.isMatchableChar(char)) localChars++;
      if (cp > 0xFFFF) i++;
    }
    return baseOffset + localChars;
  },
  setChromeInsets: function(topPx, bottomPx) {
    // See the paginated setChromeInsets: re-anchoring is serialised through the
    // shared _reanchorPending flag so a transiently reset scrollTop (from a
    // previous inset/size change's relayout) is never sampled as the chapter
    // start. The rAF clears the flag in a finally{} so an early return from a
    // failed node lookup can never leave the flag stuck. (HBK-REG-004)
    var inFlight = this._reanchorPending === true;
    var charOffset = inFlight ? -1 : this.getFirstVisibleCharOffset();
    document.documentElement.style.setProperty('--chrome-top-inset', topPx + 'px');
    document.documentElement.style.setProperty('--chrome-bottom-inset', bottomPx + 'px');
    if (inFlight || charOffset < 0) return;
    this._reanchorPending = true;
    var self = this;
    requestAnimationFrame(function() {
      try {
        var walker = self.createWalker();
        var node;
        var runningOffset = 0;
        var targetNode = null;
        while (node = walker.nextNode()) {
          var nodeChars = self.countChars(node.textContent);
          if (runningOffset + nodeChars > charOffset) {
            targetNode = node;
            break;
          }
          runningOffset += nodeChars;
        }
        if (!targetNode) return;
        var remaining = charOffset - runningOffset;
        var charIdx = 0;
        var textOffset = 0;
        var text = targetNode.textContent;
        for (var i = 0; i < text.length && charIdx < remaining; i++) {
          var cp = text.codePointAt(i);
          var ch = String.fromCodePoint(cp);
          if (self.isMatchableChar(ch)) charIdx++;
          if (cp > 0xFFFF) i++;
          textOffset = i + 1;
        }
        var range = document.createRange();
        range.setStart(targetNode, Math.min(textOffset, text.length));
        range.collapse(true);
        var rect = range.getBoundingClientRect();
        var vertical = self.isVertical();
        var root = document.scrollingElement || document.documentElement;
        var cs = getComputedStyle(document.body);
        if (vertical) {
          var pr = parseFloat(cs.paddingRight) || 0;
          var targetX = document.body.clientWidth - pr;
          root.scrollLeft += rect.left - targetX;
        } else {
          var pt = parseFloat(cs.paddingTop) || 0;
          root.scrollTop += rect.top - pt;
        }
      } finally {
        self._reanchorPending = false;
      }
    });
  }
};
window.hoshiReader._contentSize = function() {
  var cs = getComputedStyle(document.body);
  var pl = parseFloat(cs.paddingLeft) || 0;
  var pr = parseFloat(cs.paddingRight) || 0;
  var pt = parseFloat(cs.paddingTop) || 0;
  var pb = parseFloat(cs.paddingBottom) || 0;
  return { w: (document.body.clientWidth || window.innerWidth) - pl - pr, h: (document.body.clientHeight || window.innerHeight) - pt - pb };
};
window.hoshiReader.initialize = function() {
  if (window.hoshiReader.didInitialize) return;
  window.hoshiReader.didInitialize = true;
  document.documentElement.style.setProperty('--chrome-top-inset', '${chromeTopInset}px');
  document.documentElement.style.setProperty('--chrome-bottom-inset', '${chromeBottomInset}px');
$_sharedInitViewport
  var dartH = ${dartPageHeight != null ? '${dartPageHeight.round()}' : 'null'};
  var contHeight = dartH || window.innerHeight;
  document.documentElement.style.setProperty('--hoshi-continuous-height', contHeight + 'px');
  var cs = this._contentSize();
  document.documentElement.style.setProperty('--hoshi-image-max-width', Math.max(1, Math.floor(cs.w * $imageWidthRatio)) + 'px');
  document.documentElement.style.setProperty('--hoshi-image-max-height', Math.max(1, cs.h) + 'px');
$initImages
  Promise.all(imagePromises).then(function() {
    window.hoshiReader.buildNodeOffsets();
    $sasayakiInit
    $initialRestoreScript
  });
};
window.hoshiReader.updatePageSize = function(cssWidth, cssHeight) {
  var newHeight = Math.round(cssHeight);
  var newWidth = Math.round(cssWidth);
  var changed = (newHeight !== this._contH || newWidth !== this._contW);
  this._contH = newHeight;
  this._contW = newWidth;
  // Shares _reanchorPending with setChromeInsets (see there): while a re-anchor
  // rAF is in flight, only update the layout and let it restore position.
  var inFlight = this._reanchorPending === true;
  var progress = (changed && !inFlight) ? this.calculateProgress() : 0;
  document.documentElement.style.setProperty('--hoshi-continuous-height', newHeight + 'px');
  var cs = this._contentSize();
  document.documentElement.style.setProperty('--hoshi-image-max-width', Math.max(1, Math.floor(cs.w * $imageWidthRatio)) + 'px');
  document.documentElement.style.setProperty('--hoshi-image-max-height', Math.max(1, cs.h) + 'px');
  if (inFlight || progress <= 0) return;
  this._reanchorPending = true;
  var self = this;
  requestAnimationFrame(function() {
    try {
      self.scrollToProgressContinuous(progress);
    } finally {
      self._reanchorPending = false;
    }
  });
};
window.hoshiReader.reanchorAfterStyleChange = function(styleEl, css) {
  // 连续模式同理（见分页版注释）：外部 live CSS 变更后必须按进度重新滚动回同一
  // 位置，否则字体/行间变更后内容相对视口漂移。镜像本模式 updatePageSize 的重锚序列，
  // 共用 _reanchorPending（BUG-023）。
  if (!this.didInitialize) { styleEl.textContent = css; return; }
  var inFlight = this._reanchorPending === true;
  var progress = inFlight ? 0 : this.calculateProgress();
  styleEl.textContent = css;
  var cs = this._contentSize();
  document.documentElement.style.setProperty('--hoshi-image-max-width', Math.max(1, Math.floor(cs.w * $imageWidthRatio)) + 'px');
  document.documentElement.style.setProperty('--hoshi-image-max-height', Math.max(1, cs.h) + 'px');
  if (inFlight || progress <= 0) return;
  this._reanchorPending = true;
  var self = this;
  requestAnimationFrame(function() {
    try {
      self.scrollToProgressContinuous(progress);
    } finally {
      self._reanchorPending = false;
    }
  });
};
(function() {
  var TAP_SLOP = 12;
  var SWIPE_THRESHOLD = 20;
  var downX = 0, downY = 0, hasDown = false;
  function _bStart(x, y) { hasDown = true; downX = x; downY = y; }
  function _bEnd(x, y) {
    if (!hasDown) return;
    hasDown = false;
    var dx = x - downX;
    var dy = y - downY;
    if (Math.abs(dx) < TAP_SLOP && Math.abs(dy) < TAP_SLOP) return;
    var root = document.scrollingElement || document.documentElement;
    var vertical = window.hoshiReader && window.hoshiReader.isVertical();
    var dir = null;
    if (vertical) {
      if (Math.abs(dx) < SWIPE_THRESHOLD || Math.abs(dx) < Math.abs(dy)) return;
      var atStart = root.scrollLeft >= -2 && root.scrollLeft <= 2;
      var atEnd = Math.abs(root.scrollLeft) + window.innerWidth >= root.scrollWidth - 2;
      if (dx > 0 && atEnd) dir = 'forward';
      else if (dx < 0 && atStart) dir = 'backward';
    } else {
      if (Math.abs(dy) < SWIPE_THRESHOLD || Math.abs(dy) < Math.abs(dx)) return;
      var atTop = root.scrollTop <= 2;
      var atBottom = root.scrollTop + window.innerHeight >= root.scrollHeight - 2;
      if (dy < 0 && atBottom) dir = 'forward';
      else if (dy > 0 && atTop) dir = 'backward';
    }
    if (dir && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('onBoundarySwipe', dir);
    }
  }
  document.addEventListener('touchstart', function(e) {
    if (!e.touches.length) return;
    _bStart(e.touches[0].clientX, e.touches[0].clientY);
  }, {passive: true});
  document.addEventListener('touchend', function(e) {
    if (!e.changedTouches.length) return;
    _bEnd(e.changedTouches[0].clientX, e.changedTouches[0].clientY);
  }, {passive: true});
  document.addEventListener('pointerdown', function(e) {
    if (e.pointerType === 'touch' || e.button !== 0) return;
    _bStart(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointerup', function(e) {
    if (e.pointerType === 'touch' || e.button !== 0) return;
    _bEnd(e.clientX, e.clientY);
  }, {passive: true});
})();
$_sharedInitBoot
</script>''';
  }

  static String _jsStringLiteral(String value) {
    return jsonEncode(value);
  }
}
