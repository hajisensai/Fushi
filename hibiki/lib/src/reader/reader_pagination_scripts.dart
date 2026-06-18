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

/// `paginate()` 一次翻页的纯数据结果：是否真的滚动了（[scrolled]）以及目标
/// 滚动量（[targetScroll]，未滚动时为当前对齐页，调用方可忽略）。
class ReaderPageStep {
  const ReaderPageStep({required this.scrolled, required this.targetScroll});

  /// 是否在边界内成功翻了一页（false ⇒ 已到首/末页，调用方走 limit 分支）。
  final bool scrolled;

  /// 翻页后应落到的滚动量（已 clamp 到 [min,max] 整页边界）。
  final double targetScroll;
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
          // BUG-282：未命中只为这一条 cue 选一个尽力而为的回落位置，**绝不推进
          // 单调游标**。游标只在「DOM 真命中」时前进；若让回落按未经核实的 hint
          // 猜测推进 cursor，就可能越过后面真正能命中的 cue 的真实位置，使其搜索
          // 窗口下界 max(cursor, hint-window) 把真实位置排除掉 → 整本逐句累积漂移
          // （BUG-060 想消除的正是累积漂移，这里是它的回落漏洞）。
          resolved = _clampInt(hint, cursor, fullNorm.length);
        }
      } else {
        // 空 needle 同理：只给回落位置，不污染游标。
        resolved = _clampInt(hint, cursor, fullNorm.length);
      }
      out.add(resolved);
    }
    return out;
  }

  /// JS `window.hoshiReader.paginate` 的纯 Dart 影子，供单测验证「错位不跳页」
  /// 不变量（BUG-169）。两侧同算法：
  ///
  /// - forward → 严格在 [currentScroll] 之后的最近整页边界
  ///   （`floor(currentScroll/pitch) + 1`）；
  /// - backward → 严格在 [currentScroll] 之前的最近整页边界
  ///   （`ceil(currentScroll/pitch) - 1`）。
  ///
  /// 当 [currentScroll] 已对齐到整页时与「当前页 ±1」完全等价；当它落在两页之间
  /// （snap 监听器尚未把它对齐 / pitch 微变导致瞬时错位）时，floor/ceil 也只走一页，
  /// 不会像旧实现 `round((currentScroll ± pitch)/pitch)` 那样把当前页算成相邻页而跳 2 页。
  /// 目标值再 clamp 到 [[minAlignedScroll], [maxAlignedScroll]]。
  @visibleForTesting
  static ReaderPageStep resolvePaginateStepForTesting({
    required ReaderNavigationDirection direction,
    required double currentScroll,
    required double columnPitch,
    required double minAlignedScroll,
    required double maxAlignedScroll,
  }) {
    if (columnPitch <= 0) {
      return ReaderPageStep(scrolled: false, targetScroll: currentScroll);
    }
    // 先把 1px 内的 WebView sub-pixel 漂移视为已落到整页边界，再算出「严格相邻
    // 整页边界」并 clamp 到 [min,max]；是否真的翻了一页由 clamp 后
    // 的目标与当前位置比较得出。这样首/末页判定与步长计算共用同一个 target，不再有
    // 「currentScroll 错位 → guard 用 cur±pitch 误判已到边界 / round 跳 2 页」的特例。
    final double stepScroll = _pageStepPosition(currentScroll, columnPitch);
    final double target;
    if (direction == ReaderNavigationDirection.forward) {
      final int basePage = (stepScroll / columnPitch).floor();
      target = _clampDouble(
          (basePage + 1) * columnPitch, minAlignedScroll, maxAlignedScroll);
      // 已对齐在末页时 target == currentScroll（差值 <=1px 视为同页）→ 无下一页。
      final bool scrolled = target > stepScroll + 1;
      return ReaderPageStep(scrolled: scrolled, targetScroll: target);
    } else {
      final int basePage = (stepScroll / columnPitch).ceil();
      target = _clampDouble(
          (basePage - 1) * columnPitch, minAlignedScroll, maxAlignedScroll);
      final bool scrolled = target < stepScroll - 1;
      return ReaderPageStep(scrolled: scrolled, targetScroll: target);
    }
  }

  /// BUG-240 纯谓词：分页 `paginate()` 在「这一步翻不动」时，是否应当真的跨章
  /// （而不是被陈旧/低估的 metrics 误判成已到章节边界）。JS `_stepWithFreshMetrics`
  /// 的 Dart 影子——给定 **settle 后重建** 的几何，判定还有没有真实可滚动整页。
  ///
  /// 入参（均为 settle/重建后的实时几何）：
  /// - [currentScroll]：当前对齐滚动量；
  /// - [columnPitch]：当前 settle 后的整页步距；
  /// - [metricsMaxScroll] / [metricsMinScroll]：重建后 `buildPaginationMetrics`
  ///   的内容末/首页（`min(maxAlignedScroll, lastContentScroll)` 派生，可能因末列
  ///   内容边缘低估而偏小）；
  /// - [trueMaxScroll]：`getScrollContext().maxScroll`（DOM 实时滚动上限，含末尾
  ///   占位空白，永不陈旧）。
  ///
  /// 返回 true ⇒ 真到章节首/末页，调用方可放心跨章；false ⇒ 还有整页可翻，
  /// 不该跨章（消除「翻不动 == 到边界」的特例混淆）。forward 复核用
  /// `max(metricsMaxScroll, trueMaxAligned)` 作容差上界，抵消内容边缘低估。
  @visibleForTesting
  static bool shouldCrossChapterOnLimit({
    required ReaderNavigationDirection direction,
    required double currentScroll,
    required double columnPitch,
    required double metricsMaxScroll,
    required double metricsMinScroll,
    required double trueMaxScroll,
  }) {
    if (columnPitch <= 0) return true;
    final double stepScroll = _pageStepPosition(currentScroll, columnPitch);
    if (direction == ReaderNavigationDirection.forward) {
      final double trueMaxAligned =
          (trueMaxScroll / columnPitch).floor() * columnPitch;
      final double ceiling =
          metricsMaxScroll > trueMaxAligned ? metricsMaxScroll : trueMaxAligned;
      double target =
          (stepScroll / columnPitch).floor() * columnPitch + columnPitch;
      if (target > ceiling) target = ceiling;
      if (target < metricsMinScroll) target = metricsMinScroll;
      // 还有 >1px 的整页可前进 ⇒ 不跨章。
      return target <= stepScroll + 1;
    } else {
      double target =
          (stepScroll / columnPitch).ceil() * columnPitch - columnPitch;
      if (target < metricsMinScroll) target = metricsMinScroll;
      if (target > metricsMaxScroll) target = metricsMaxScroll;
      return target >= stepScroll - 1;
    }
  }

  static double _pageStepPosition(double currentScroll, double columnPitch) {
    if (columnPitch <= 0) return currentScroll;
    final double nearestPage =
        (currentScroll / columnPitch).round() * columnPitch;
    return (currentScroll - nearestPage).abs() <= 1
        ? nearestPage
        : currentScroll;
  }

  static double _clampDouble(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  static int _clampInt(int v, int lo, int hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  /// BUG-239 纯谓词：阅读器统一手势 `_gestureEnd` 检测到一次滑动后，是否应当
  /// 回传 `onSwipe`（→ 90% 整屏翻页）。
  ///
  /// - **分页模式**（[continuousMode] == false）：CSS `touch-action:none` 禁掉原生
  ///   pan，水平滑动是唯一翻页通道 → 沿用「水平滑动（`absDx > absDy`）才翻页」。
  /// - **连续模式**（[continuousMode] == true）：靠原生滚动（滚动轴 = 书写轴），
  ///   章间切换由边界手势 IIFE（`onBoundarySwipe`）负责。再让 `_gestureEnd` 回传
  ///   `onSwipe` 会与原生滚动产生轴向冲突（横向滑动错误触发垂直 90% 跳页 / 沿滚动
  ///   轴的滑动被原生滚动吞掉）→ 一律不回传，交给原生滚动 + 边界 IIFE + 按钮/键盘/
  ///   音量键 `_paginate` 连续分支。
  ///
  /// JS `_gestureEnd` 用同一判定（见 setup 脚本注入的 `continuousMode` 门控）。
  @visibleForTesting
  static bool continuousSwipeShouldPaginate({
    required bool continuousMode,
    required double absDx,
    required double absDy,
  }) {
    if (continuousMode) return false;
    return absDx > absDy;
  }

  static String paginateInvocation(ReaderNavigationDirection direction) =>
      "window.hoshiReader && window.hoshiReader.paginate('${direction.jsValue}')";

  static String progressInvocation() =>
      'window.hoshiReader && window.hoshiReader.calculateProgress()';

  static String stableProgressInvocation() =>
      'window.hoshiReader && !window.hoshiReader._reanchorPending '
      '&& window.hoshiProgressDetails ? window.hoshiProgressDetails() : null';

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
    int initialCharOffset = -1,
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
        initialCharOffset: initialCharOffset,
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
      initialCharOffset: initialCharOffset,
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
    if (typeof this.warmPaginationMetrics === 'function') {
      this.warmPaginationMetrics();
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
        // BUG-282：未命中只给这一条 cue 一个尽力而为的回落区间，**不推进单调
        // 游标 cursor**。游标只在 DOM 真命中时前进；让回落按未核实的 hint 猜测
        // 推进游标会越过后面真正能命中 cue 的真实位置，把其搜索窗口下界顶过去
        // → 整本逐句累积漂移（与 Dart 影子 resolveCueNormStartsForTesting 同改）。
        spanStart = hint < cursor ? cursor : (hint > map.length ? map.length : hint);
        spanLen = len;
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
    int initialCharOffset = -1,
    int fontSize = ReaderLayoutDefaults.fontSizePx,
    String? sasayakiCuesJson,
    String? initialFragment,
    double chromeTopInset = 0.0,
    double chromeBottomInset = 0.0,
    double? dartPageWidth,
    double? dartPageHeight,
  }) {
    // BUG-162: 优先精确字符偏移恢复（restoreToCharOffset），无精确锚（旧存档）才
    // 回退粗粒度 restoreProgress；书签/fragment 跳转仍走 jumpToFragment。
    final String initialRestoreScript = initialFragment != null
        ? 'window.hoshiReader.jumpToFragment(${_jsStringLiteral(initialFragment)});'
        : (initialCharOffset >= 0
            ? 'window.hoshiReader.restoreToCharOffset($initialCharOffset);'
            : 'window.hoshiReader.restoreProgress($initialProgress);');

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
  pageStepPosition: function(currentScroll, pitch) {
    if (pitch <= 0) return currentScroll;
    var nearestPage = Math.round(currentScroll / pitch) * pitch;
    return Math.abs(currentScroll - nearestPage) <= 1 ? nearestPage : currentScroll;
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
  warmPaginationMetrics: function() {
    if (this.paginationMetrics) return;
    var run = () => {
      if (this.paginationMetrics) return;
      this.buildPaginationMetrics();
    };
    if (window.requestIdleCallback) {
      window.requestIdleCallback(run, { timeout: 1000 });
    } else {
      setTimeout(run, 200);
    }
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
  // BUG-162: 退出再进的精确恢复——按 section 内绝对字符偏移落到该字符真实所在页
  // （成熟 scrollToCharOffset 路径，是「存→取」不动点），替代粗粒度
  // restoreProgress/scrollToProgressPaged（alignToPage 取整落相邻页）。charOffset<0
  // （旧存档无精确锚）回退章首；调用方在 initialCharOffset<0 时改走 restoreProgress。
  restoreToCharOffset: async function(charOffset) {
    await document.fonts.ready;
    var context = this.getScrollContext();
    if (charOffset < 0) { this.scrollToProgressPaged(context, 0); }
    else { this.scrollToCharOffset(charOffset); }
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
  // BUG-240：跨章 limit 的 settle 复核。已对齐 currentScroll 出发的整页步进若被
  // 当前（可能陈旧/低估的）metrics clamp 成「翻不动」，先重建一次 metrics 拿到
  // settle 后的真实 max/min，再用 getScrollContext().maxScroll（DOM 实时滚动上限，
  // 永不陈旧）派生的整页末页作 1px 容差复核：只要 currentScroll 之后仍有真实可滚动
  // 整页就放行翻页，避免「这一次没滚动」被误当「已到章节首/末页」而提前跨章。
  // 不动 BUG-169 的 floor+1/ceil-1 步长公式，只在 limit 边缘多一道复核。
  _stepWithFreshMetrics: function(context, direction) {
    var metrics = this.buildPaginationMetrics();
    var pitch = context.columnPitch;
    var currentScroll = this.getPagePosition(context);
    var stepScroll = this.pageStepPosition(currentScroll, pitch);
    // 真末页/真首页：用实时 maxScroll 派生整页边界，metrics.maxScroll 取两者较大者，
    // 抵消末列内容边缘被低估导致的 metrics.maxScroll 偏小。trueMaxAligned 含末尾占位
    // 空白页 → 只作 forward 复核的容差上界，不作落点（落点仍用 metrics.maxScroll）。
    var trueMaxAligned = Math.floor(context.maxScroll / pitch) * pitch;
    if (direction === "forward") {
      var maxF = Math.max(metrics.maxScroll, trueMaxAligned);
      var targetF = (Math.floor(stepScroll / pitch) + 1) * pitch;
      if (targetF > maxF) targetF = maxF;
      if (targetF < metrics.minScroll) targetF = metrics.minScroll;
      if (targetF <= stepScroll + 1) return "limit";
      // 落点仍 clamp 到内容末页，不停在末尾空白占位页。
      var dest = Math.min(targetF, Math.max(metrics.maxScroll, currentScroll));
      this.setPagePosition(context, dest);
      return "scrolled";
    } else {
      var targetB = (Math.ceil(stepScroll / pitch) - 1) * pitch;
      if (targetB < metrics.minScroll) targetB = metrics.minScroll;
      if (targetB > metrics.maxScroll) targetB = metrics.maxScroll;
      if (targetB >= stepScroll - 1) return "limit";
      this.setPagePosition(context, targetB);
      return "scrolled";
    }
  },
  paginate: function(direction) {
    var context = this.getScrollContext();
    if (context.columnPitch <= 0) return "limit";
    var currentScroll = this.getPagePosition(context);
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    var minAlignedScroll = metrics.minScroll;
    var maxAlignedScroll = metrics.maxScroll;
    var pitch = context.columnPitch;
    var stepScroll = this.pageStepPosition(currentScroll, pitch);
    // BUG-169：从可能未对齐的 currentScroll 出发先算「严格相邻整页边界」再 clamp，
    // 是否真翻页由 clamp 后的 target 与当前位置比较得出（共用同一 target，首/末页
    // 判定与步长计算一致）。旧实现 forward 用 round((cur+pitch)/pitch)（= round(cur/
    // pitch)+1），cur 落在两页之间时 round 把当前页算成下一页 → 实际跳 2 页；且 guard
    // 用 cur+pitch 在末页前一页且 cur 错位时会误判已到边界。floor+1 / ceil-1 在对齐时
    // 与旧实现等价、错位时永远只走一页。1px 内的 WebView sub-pixel 漂移先归一化
    // 到最近整页，避免连续 backward 把 17955.33 → 17955 误判成 limit。
    // 与 Dart 影子 resolvePaginateStepForTesting 同算法。
    if (direction === "forward") {
      var targetForward = (Math.floor(stepScroll / pitch) + 1) * pitch;
      if (targetForward > maxAlignedScroll) targetForward = maxAlignedScroll;
      if (targetForward < minAlignedScroll) targetForward = minAlignedScroll;
      // BUG-240：陈旧/低估的 metrics 让这一步看似翻不动时，重建 metrics + 实时 maxScroll
      // 复核后再定夺是否真到末页，避免提前跨章。
      if (targetForward <= stepScroll + 1) return this._stepWithFreshMetrics(context, "forward");
      this.setPagePosition(context, targetForward);
      var afterScrollF = this.getPagePosition(context);
      console.log('[HoshiPagination] paginate FORWARD: before=' + currentScroll
        + ' target=' + targetForward + ' after=' + afterScrollF
        + ' pitch=' + pitch + ' drift=' + (afterScrollF - targetForward)
        + ' min=' + minAlignedScroll + ' max=' + maxAlignedScroll);
      return "scrolled";
    } else {
      var targetBack = (Math.ceil(stepScroll / pitch) - 1) * pitch;
      if (targetBack < minAlignedScroll) targetBack = minAlignedScroll;
      if (targetBack > maxAlignedScroll) targetBack = maxAlignedScroll;
      // BUG-240：backward 同理用 settle 后的 metrics 复核，避免低估 minScroll 提前回上一章。
      if (targetBack >= stepScroll - 1) return this._stepWithFreshMetrics(context, "backward");
      this.setPagePosition(context, targetBack);
      var afterScrollB = this.getPagePosition(context);
      console.log('[HoshiPagination] paginate BACKWARD: before=' + currentScroll
        + ' target=' + targetBack + ' after=' + afterScrollB
        + ' pitch=' + pitch + ' drift=' + (afterScrollB - targetBack)
        + ' min=' + minAlignedScroll + ' max=' + maxAlignedScroll);
      return "scrolled";
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
    int initialCharOffset = -1,
    String? sasayakiCuesJson,
    String? initialFragment,
    double chromeTopInset = 0.0,
    double chromeBottomInset = 0.0,
    double? dartPageWidth,
    double? dartPageHeight,
  }) {
    // BUG-162: 同分页——优先精确字符偏移恢复，旧存档回退分数。
    final String initialRestoreScript = initialFragment != null
        ? 'window.hoshiReader.jumpToFragment(${_jsStringLiteral(initialFragment)});'
        : (initialCharOffset >= 0
            ? 'window.hoshiReader.restoreToCharOffset($initialCharOffset);'
            : 'window.hoshiReader.restoreProgress($initialProgress);');

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
    var before = vertical ? window.scrollX : root.scrollTop;
    var wm = window.getComputedStyle(document.body).writingMode;
    var amount = vertical
      ? Math.max(1, Math.floor(window.innerWidth * 0.9))
      : Math.max(1, Math.floor(window.innerHeight * 0.9));
    var forwardSign = vertical && wm === 'vertical-rl' ? -1 : 1;
    var step = amount * (direction === "forward" ? forwardSign : -forwardSign);
    if (vertical) {
      window.scrollBy({left: step, top: 0, behavior: 'auto'});
    } else {
      window.scrollBy({left: 0, top: step, behavior: 'auto'});
    }
    var after = vertical ? window.scrollX : root.scrollTop;
    var moved = Math.abs(after - before) > 1;
    return moved ? "scrolled" : "limit";
  },
  getFirstVisibleCharOffset: function() {
    var vertical = this.isVertical();
    var cs = getComputedStyle(document.body);
    var pt = parseFloat(cs.paddingTop) || 0;
    var pl = parseFloat(cs.paddingLeft) || 0;
    var pr = parseFloat(cs.paddingRight) || 0;
    var x = vertical ? (window.innerWidth - pr - 2) : (pl + 2);
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
  // BUG-162: 连续模式按 section 内绝对字符偏移定位（连续滚动语义：把目标字符滚到
  // 视口首边）。抽自原 setChromeInsets 内联体，供 setChromeInsets 重锚与退出再进
  // 恢复共用（DRY）。
  scrollToCharOffset: function(charOffset) {
    if (charOffset < 0) return;
    var walker = this.createWalker();
    var node;
    var runningOffset = 0;
    var targetNode = null;
    while (node = walker.nextNode()) {
      var nodeChars = this.countChars(node.textContent);
      if (runningOffset + nodeChars > charOffset) { targetNode = node; break; }
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
      if (this.isMatchableChar(ch)) charIdx++;
      if (cp > 0xFFFF) i++;
      textOffset = i + 1;
    }
    var range = document.createRange();
    range.setStart(targetNode, Math.min(textOffset, text.length));
    range.collapse(true);
    var rect = range.getBoundingClientRect();
    var vertical = this.isVertical();
    var root = document.scrollingElement || document.documentElement;
    var cs = getComputedStyle(document.body);
    if (vertical) {
      var pr = parseFloat(cs.paddingRight) || 0;
      var targetX = window.innerWidth - pr;
      root.scrollLeft += rect.left - targetX;
    } else {
      var pt = parseFloat(cs.paddingTop) || 0;
      root.scrollTop += rect.top - pt;
    }
  },
  // BUG-162: 退出再进的精确恢复（连续）。charOffset<0（旧存档）回退章首；调用方在
  // initialCharOffset<0 时改走 restoreProgress（分数）。
  restoreToCharOffset: async function(charOffset) {
    await document.fonts.ready;
    var self = this;
    if (charOffset < 0) { this.scrollToChapterStart(); }
    else { this.scrollToCharOffset(charOffset); }
    setTimeout(function() {
      setTimeout(function() { self.notifyRestoreComplete(); }, 16);
    }, 16);
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
        self.scrollToCharOffset(charOffset);
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
