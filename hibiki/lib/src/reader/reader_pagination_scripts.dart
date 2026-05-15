import 'dart:convert';

import 'package:hibiki/src/reader/reader_content_styles.dart';

enum ReaderNavigationDirection {
  forward('forward'),
  backward('backward');

  const ReaderNavigationDirection(this.jsValue);
  final String jsValue;
}

class ReaderPaginationScripts {
  ReaderPaginationScripts._();

  static String paginateInvocation(ReaderNavigationDirection direction) =>
      "window.hoshiReader && window.hoshiReader.paginate('${direction.jsValue}')";

  static String progressInvocation() =>
      'window.hoshiReader && window.hoshiReader.calculateProgress()';

  static String updatePageSizeInvocation(double width, double height) =>
      'window.hoshiReader && window.hoshiReader.updatePageSize($width, $height)';

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

  static bool didScroll(String? result) =>
      result?.trim().replaceAll('"', '') == 'scrolled';

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
  }) {
    if (continuousMode) {
      return _continuousShellScript(
        initialProgress: initialProgress,
        sasayakiCuesJson: sasayakiCuesJson,
        initialFragment: initialFragment,
      );
    }
    return _paginatedShellScript(
      initialProgress: initialProgress,
      fontSize: fontSize,
      sasayakiCuesJson: sasayakiCuesJson,
      initialFragment: initialFragment,
    );
  }

  // ── Shared JS (properties + methods used by both modes) ────────────

  static const String _sharedJs = r'''
  cueWrappers: new Map(),
  cueRangesMap: new Map(),
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
  collectSasayakiCueRanges: function(cues) {
    var cueRanges = new Map();
    if (!cues.length) return [];
    var index = 0;
    var current = cues[0];
    var start = current.start;
    var end = start + current.length;
    var cursor = 0;
    var segment = null;
    var flushSegment = function(node) {
      if (!segment) return;
      var ranges = cueRanges.get(segment.id) || [];
      ranges.push({ node: node, start: segment.start, end: segment.end });
      cueRanges.set(segment.id, ranges);
      segment = null;
    };
    var advanceCue = function() {
      index += 1;
      current = cues[index];
      if (current) {
        start = current.start;
        end = start + current.length;
      }
    };
    var walker = this.createWalker();
    var node;
    while (current && (node = walker.nextNode())) {
      var text = node.textContent;
      var i = 0;
      while (i < text.length && current) {
        var char = String.fromCodePoint(text.codePointAt(i));
        var next = i + char.length;
        if (this.isMatchableChar(char)) {
          if (cursor >= start && cursor < end) {
            if (!segment) {
              segment = { id: current.id, start: i, end: next };
            } else {
              segment.end = next;
            }
          } else {
            flushSegment(node);
          }
          cursor += 1;
          if (cursor === end) {
            flushSegment(node);
            advanceCue();
          }
        } else if (segment) {
          segment.end = next;
        }
        i = next;
      }
      flushSegment(node);
    }
    return cues.map(function(cue) {
      return { id: cue.id, ranges: cueRanges.get(cue.id) || [] };
    });
  },
  applySasayakiCues: function(cues) {
    if (window.hoshiSelection) window.hoshiSelection.clearSelection();
    this.resetSasayakiCues();
    var cueSegments = this.collectSasayakiCueRanges(cues);
    if (window.__hoshiCssHighlightsSupported) {
      for (var i = 0; i < cueSegments.length; i++) {
        var id = cueSegments[i].id;
        var segments = cueSegments[i].ranges;
        if (!segments.length) continue;
        var ranges = [];
        for (var j = 0; j < segments.length; j++) {
          try {
            var r = document.createRange();
            r.setStart(segments[j].node, segments[j].start);
            r.setEnd(segments[j].node, segments[j].end);
            ranges.push(r);
          } catch (e) {}
        }
        if (ranges.length) this.cueRangesMap.set(id, ranges);
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
  highlightSasayakiCue: function(cueId, reveal) {
    this.clearSasayakiCue();
    if (window.__hoshiCssHighlightsSupported) {
      var ranges = this.cueRangesMap.get(cueId);
      if (!ranges || !ranges.length) return null;
      this.activeCueId = cueId;
      CSS.highlights.set('hoshi-sasayaki', new Highlight(...ranges));
      if (reveal && ranges[0]) {
        if (this.scrollToRange) {
          if (this.scrollToRange(ranges[0])) return this.calculateProgress();
        } else if (this.scrollToTarget) {
          if (this.scrollToTarget(ranges[0])) return this.calculateProgress();
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
  clearSasayakiCue: function() {
    if (!this.activeCueId) return;
    if (window.__hoshiCssHighlightsSupported) {
      CSS.highlights.delete('hoshi-sasayaki');
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
    if (svg.querySelector('image') && svg.getAttribute('preserveAspectRatio') === 'none') {
      svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
    }
  });
  var imagePromises = Array.from(document.querySelectorAll('img')).map(function(img) {
    return new Promise(function(resolve) {
      var isGaiji = img.classList.contains('gaiji') || img.classList.contains('gaiji-line');
      var mark = function() {
        if (!isGaiji && (img.naturalWidth > 256 || img.naturalHeight > 256)) {
          img.classList.add('block-img');
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
    var columnPitch = vertical ? clientSize : (clientSize + $fontSize);
    var totalSize = vertical ? scrollEl.scrollHeight : scrollEl.scrollWidth;
    var maxScroll = Math.max(0, totalSize - clientSize);
    var gap = parseFloat(cs.columnGap) || 0;
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
  restoreProgress: async function(progress) {
    await document.fonts.ready;
    var context = this.getScrollContext();
    this.scrollToProgressPaged(context, progress);
    var pos = this.getPagePosition(context);
    requestAnimationFrame(() => {
      this.setPagePosition(context, pos);
      this.registerSnapScroll(pos);
      requestAnimationFrame(() => this.notifyRestoreComplete());
    });
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
    requestAnimationFrame(() => {
      this.setPagePosition(context, targetScroll);
      this.registerSnapScroll(targetScroll);
      requestAnimationFrame(() => this.notifyRestoreComplete());
    });
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
$_sharedInitViewport
  var pageHeight = window.innerHeight + $bottomOverlapPx;
  var pageWidth = window.innerWidth;
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
  var progress = this.calculateProgress();
  document.documentElement.style.setProperty('--page-height', newHeight + 'px');
  document.documentElement.style.setProperty('--page-width', newWidth + 'px');
  var cs = this._contentSize();
  document.documentElement.style.setProperty('--hoshi-image-max-width', Math.max(1, Math.floor(cs.w * $imageWidthRatio)) + 'px');
  document.documentElement.style.setProperty('--hoshi-image-max-height', Math.max(1, cs.h) + 'px');
  this.pageHeight = newHeight;
  this.pageWidth = newWidth;
  this.paginationMetrics = null;
  var self = this;
  requestAnimationFrame(function() {
    self.scrollToProgressPaged(self.getScrollContext(), progress);
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
    if (progress <= 0) {
      this.scrollToChapterStart();
      requestAnimationFrame(() => {
        this.scrollToChapterStart();
        this.notifyRestoreComplete();
      });
      return;
    }
    this.scrollToProgressContinuous(progress);
    requestAnimationFrame(() => {
      requestAnimationFrame(() => this.notifyRestoreComplete());
    });
  },
  jumpToFragment: async function(fragment) {
    await document.fonts.ready;
    var rawFragment = (fragment || '').trim();
    var target = rawFragment && (document.getElementById(rawFragment) || document.getElementsByName(rawFragment)[0]);
    if (!target) {
      this.notifyRestoreComplete();
      return false;
    }
    target.scrollIntoView();
    requestAnimationFrame(() => {
      requestAnimationFrame(() => this.notifyRestoreComplete());
    });
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
$_sharedInitViewport
  document.documentElement.style.setProperty('--hoshi-continuous-height', window.innerHeight + 'px');
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
  var progress = changed ? this.calculateProgress() : 0;
  document.documentElement.style.setProperty('--hoshi-continuous-height', newHeight + 'px');
  var cs = this._contentSize();
  document.documentElement.style.setProperty('--hoshi-image-max-width', Math.max(1, Math.floor(cs.w * $imageWidthRatio)) + 'px');
  document.documentElement.style.setProperty('--hoshi-image-max-height', Math.max(1, cs.h) + 'px');
  if (progress <= 0) return;
  var self = this;
  requestAnimationFrame(function() {
    self.scrollToProgressContinuous(progress);
  });
};
(function() {
  var TAP_SLOP = 12;
  var SWIPE_THRESHOLD = 20;
  var downX = 0, downY = 0, hasDown = false;
  document.addEventListener('touchstart', function(e) {
    if (!e.touches.length) return;
    hasDown = true;
    downX = e.touches[0].clientX;
    downY = e.touches[0].clientY;
  }, {passive: true});
  document.addEventListener('touchend', function(e) {
    if (!hasDown || !e.changedTouches.length) return;
    hasDown = false;
    var dx = e.changedTouches[0].clientX - downX;
    var dy = e.changedTouches[0].clientY - downY;
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
  }, {passive: true});
})();
$_sharedInitBoot
</script>''';
  }

  static String _jsStringLiteral(String value) {
    return jsonEncode(value);
  }
}
