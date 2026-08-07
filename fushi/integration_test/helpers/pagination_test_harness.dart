/// JS test harness injection and Dart-side invariant validation
/// for reader pagination testing.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// JS code to inject into the WebView for pagination testing.
const String paginationHarnessJs = r'''
(function() {
  window.fushiTestHarness = {
    visibleBounds: function() {
      var cs = getComputedStyle(document.body);
      var top = Math.max(0, parseFloat(cs.paddingTop) || 0);
      var bottom = Math.max(top, window.innerHeight -
        Math.max(0, parseFloat(cs.paddingBottom) || 0));
      var left = Math.max(0, parseFloat(cs.paddingLeft) || 0);
      var right = Math.max(left, window.innerWidth -
        Math.max(0, parseFloat(cs.paddingRight) || 0));
      return { top: top, bottom: bottom, left: left, right: right };
    },

    markerClientRects: function(marker) {
      var range = document.createRange();
      range.selectNodeContents(marker);
      var rects = Array.from(range.getClientRects());
      return rects.length > 0 ? rects : Array.from(marker.getClientRects());
    },

    getVisibleMarkers: function() {
      var markers = document.querySelectorAll('[id^="m"]');
      var visible = [];
      var bounds = this.visibleBounds();
      var visibleWidth = bounds.right - bounds.left;
      var visibleHeight = bounds.bottom - bounds.top;
      for (var i = 0; i < markers.length; i++) {
        // A marker counts as "on this page" only when SUBSTANTIALLY visible.
        // Use per-fragment client rects (not the union getBoundingClientRect,
        // which over-reports in multi-column layouts) and require at least
        // half of a fragment's area to fall inside the viewport. This keeps a
        // tiny sliver bleeding into the page margin (e.g. next page's content
        // peeking ~20px at the bottom edge) from being double-counted on two
        // adjacent pages, while still flagging genuine large overlaps.
        var rects = this.markerClientRects(markers[i]);
        var visibleArea = 0;
        var totalArea = 0;
        for (var r = 0; r < rects.length; r++) {
          var rect = rects[r];
          var w = rect.width;
          var h = rect.height;
          if (w <= 0 || h <= 0) continue;
          totalArea += w * h;
          var ix = Math.max(0, Math.min(rect.right, bounds.right) -
            Math.max(rect.left, bounds.left));
          var iy = Math.max(0, Math.min(rect.bottom, bounds.bottom) -
            Math.max(rect.top, bounds.top));
          visibleArea += ix * iy;
        }
        if (totalArea <= 0) continue;
        // Visibility is judged relative to the SMALLER of the element's own
        // area and the viewport area. A short paragraph counts when >=50% of
        // itself is shown; a paragraph taller than the viewport counts when it
        // fills >=50% of the screen. Using the element area alone wrongly
        // drops tall paragraphs (they can never reach 50% of themselves).
        var denom = Math.min(totalArea, visibleWidth * visibleHeight);
        if ((visibleArea / denom) >= 0.5) {
          visible.push(markers[i].id);
        }
      }
      return JSON.stringify(visible);
    },

    getPaginationState: function() {
      if (typeof fushiReader === 'undefined') {
        return JSON.stringify({error: 'fushiReader not found'});
      }
      var ctx = fushiReader.getScrollContext();
      var metrics = fushiReader.paginationMetrics ||
                    fushiReader.buildPaginationMetrics();
      // Read the page position through the reader's OWN accessor so the
      // harness measures exactly what pagination drives (scrollTop when
      // vertical, scrollLeft when horizontal). Reimplementing this here is
      // what previously produced false I1/I5 results.
      var scroll = fushiReader.getPagePosition(ctx);
      return JSON.stringify({
        scroll: scroll,
        // TODO-729：单一量纲后 ctx.pageSize 即唯一步进量(=旧 columnPitch=pageStep)；
        // ctx.columnPitch 已删。Dart 侧字段名沿用 columnPitch（语义=整页步距）。
        columnPitch: ctx.pageSize,
        pageSize: ctx.pageSize,
        maxScroll: metrics.maxScroll,
        physicalMaxScroll: ctx.physicalMaxScroll,
        minScroll: metrics.minScroll,
        totalChars: metrics.totalChars,
        vertical: ctx.vertical
      });
    },

    validateRenderedSettings: function() {
      var body = document.body;
      var cs = getComputedStyle(body);
      var textEl = document.querySelector('[id^="m"]');
      var textCs = textEl ? getComputedStyle(textEl) : cs;

      var detectedColumns = 1;
      var markers = document.querySelectorAll('[id^="m"]');
      if (markers.length >= 4) {
        var r0 = markers[0].getBoundingClientRect();
        var r2 = markers[2].getBoundingClientRect();
        var vertical = cs.writingMode === 'vertical-rl';
        if (vertical) {
          if (Math.abs(r0.top - r2.top) < 5 && Math.abs(r0.left - r2.left) > 50) {
            detectedColumns = 2;
          }
        } else {
          if (Math.abs(r0.left - r2.left) > 50 &&
              Math.abs(r0.top - r2.top) < r0.height * 3) {
            detectedColumns = 2;
          }
        }
      }

      return JSON.stringify({
        fontSize: parseFloat(textCs.fontSize),
        lineHeight: parseFloat(textCs.lineHeight) / parseFloat(textCs.fontSize),
        writingMode: cs.writingMode,
        contentWidth: body.clientWidth,
        contentHeight: body.clientHeight,
        viewportWidth: window.innerWidth,
        viewportHeight: window.innerHeight,
        paddingTop: parseFloat(cs.paddingTop) || 0,
        paddingBottom: parseFloat(cs.paddingBottom) || 0,
        paddingLeft: parseFloat(cs.paddingLeft) || 0,
        paddingRight: parseFloat(cs.paddingRight) || 0,
        columnCount: detectedColumns
      });
    },

    pageForwardAndQuery: function() {
      var result = fushiReader.paginate('forward');
      var markers = JSON.parse(this.getVisibleMarkers());
      var state = JSON.parse(this.getPaginationState());
      return JSON.stringify({
        didScroll: result === 'scrolled',
        markers: markers,
        state: state
      });
    },

    // Visible fraction of every marker (visibleArea / min(elementArea,
    // viewportArea)) at the current scroll position. Returned as a map of
    // id -> fraction for markers with any visible area.
    markerFractions: function() {
      var markers = document.querySelectorAll('[id^="m"]');
      var bounds = this.visibleBounds();
      var visibleWidth = bounds.right - bounds.left;
      var visibleHeight = bounds.bottom - bounds.top;
      var map = {};
      for (var i = 0; i < markers.length; i++) {
        var rects = this.markerClientRects(markers[i]);
        var visibleArea = 0;
        var totalArea = 0;
        for (var r = 0; r < rects.length; r++) {
          var rect = rects[r];
          if (rect.width <= 0 || rect.height <= 0) continue;
          totalArea += rect.width * rect.height;
          var ix = Math.max(0, Math.min(rect.right, bounds.right) -
            Math.max(rect.left, bounds.left));
          var iy = Math.max(0, Math.min(rect.bottom, bounds.bottom) -
            Math.max(rect.top, bounds.top));
          visibleArea += ix * iy;
        }
        if (totalArea <= 0) continue;
        var frac = visibleArea /
          Math.min(totalArea, visibleWidth * visibleHeight);
        if (frac > 0) map[markers[i].id] = frac;
      }
      return map;
    },

    fullChapterScan: function() {
      var safety = 0;
      while (fushiReader.paginate('backward') === 'scrolled' && safety < 500) {
        safety++;
      }

      var pages = [];
      var pageNum = 0;
      // Track, per marker, the page index where it is most visible (argmax).
      // This assigns every marker to exactly one page, which makes coverage
      // and continuity robust to paragraphs that split across a page boundary
      // (each side < 50%) or that are taller than the viewport.
      var best = {}; // id -> {page, frac}

      var record = function(self) {
        var fracs = self.markerFractions();
        for (var id in fracs) {
          if (!best[id] || fracs[id] > best[id].frac) {
            best[id] = { page: pageNum, frac: fracs[id] };
          }
        }
        pages.push({
          page: pageNum,
          markers: [],
          markerFractions: {},
          state: JSON.parse(self.getPaginationState())
        });
      };

      record(this);
      while (true) {
        var result = fushiReader.paginate('forward');
        if (result !== 'scrolled') break;
        pageNum++;
        if (pageNum > 1000) break;
        record(this);
      }

      // Assign each marker to its argmax page, in document (id) order.
      var ids = Object.keys(best).sort();
      for (var k = 0; k < ids.length; k++) {
        var assignedPage = best[ids[k]].page;
        if (pages[assignedPage]) {
          pages[assignedPage].markers.push(ids[k]);
          pages[assignedPage].markerFractions[ids[k]] = best[ids[k]].frac;
        }
      }

      return JSON.stringify(pages);
    },

    getProgressDetails: function() {
      if (typeof fushiProgressDetails === 'function') {
        return fushiProgressDetails();
      }
      return '0,0';
    }
  };
  return 'harness_injected';
})();
''';

// -- Data classes --

class PaginationState {
  final double scroll;
  final double columnPitch;
  final double pageSize;
  final double maxScroll;
  final double physicalMaxScroll;
  final double minScroll;
  final int totalChars;
  final bool vertical;

  PaginationState.fromJson(Map<String, dynamic> json)
      : scroll = (json['scroll'] as num).toDouble(),
        columnPitch = (json['columnPitch'] as num).toDouble(),
        pageSize = (json['pageSize'] as num).toDouble(),
        maxScroll = (json['maxScroll'] as num).toDouble(),
        physicalMaxScroll = (json['physicalMaxScroll'] as num).toDouble(),
        minScroll = (json['minScroll'] as num).toDouble(),
        totalChars = (json['totalChars'] as num?)?.toInt() ?? 0,
        vertical = json['vertical'] as bool? ?? false;

  @override
  String toString() =>
      'PaginationState(scroll=$scroll, pitch=$columnPitch, max=$maxScroll, '
      'vertical=$vertical)';
}

class PageData {
  final int pageNumber;
  final List<String> markers;
  final Map<String, double> markerFractions;
  final PaginationState state;

  PageData.fromJson(Map<String, dynamic> json)
      : pageNumber = (json['page'] as num).toInt(),
        markers = (json['markers'] as List).cast<String>(),
        markerFractions = (json['markerFractions'] as Map? ?? const {})
            .map<String, double>((dynamic key, dynamic value) =>
                MapEntry<String, double>(
                    key as String, (value as num).toDouble())),
        state = PaginationState.fromJson(json['state'] as Map<String, dynamic>);
}

class RenderedSettings {
  final double fontSize;
  final double lineHeight;
  final String writingMode;
  final double contentWidth;
  final double contentHeight;
  final double viewportWidth;
  final double viewportHeight;
  final int columnCount;

  RenderedSettings.fromJson(Map<String, dynamic> json)
      : fontSize = (json['fontSize'] as num).toDouble(),
        lineHeight = (json['lineHeight'] as num).toDouble(),
        writingMode = json['writingMode'] as String,
        contentWidth = (json['contentWidth'] as num).toDouble(),
        contentHeight = (json['contentHeight'] as num).toDouble(),
        viewportWidth = (json['viewportWidth'] as num).toDouble(),
        viewportHeight = (json['viewportHeight'] as num).toDouble(),
        columnCount = (json['columnCount'] as num).toInt();

  @override
  String toString() => 'RenderedSettings(fontSize=$fontSize, lh=$lineHeight, '
      'wm=$writingMode, cols=$columnCount)';
}

// -- Invariant violations --

class InvariantViolation {
  final String invariant;
  final int pageNumber;
  final String message;
  final Map<String, dynamic> details;

  InvariantViolation({
    required this.invariant,
    required this.pageNumber,
    required this.message,
    this.details = const {},
  });

  @override
  String toString() => '[$invariant] Page $pageNumber: $message';
}

// -- Validation functions --

List<InvariantViolation> validateChapterScan(
  List<PageData> pages, {
  required int expectedMarkerCount,
}) {
  final violations = <InvariantViolation>[];
  final allSeen = <String>{};

  for (int i = 0; i < pages.length; i++) {
    final page = pages[i];
    allSeen.addAll(page.markers);

    // I1: Scroll alignment
    if (page.state.columnPitch > 0) {
      final double pitch = page.state.columnPitch;
      final int pageIndex = (page.state.scroll / pitch).round();
      final double expectedScroll = pageIndex * pitch;
      final double error = (page.state.scroll - expectedScroll).abs();
      final bool isTerminalClamp = i == pages.length - 1 &&
          (page.state.scroll - page.state.physicalMaxScroll).abs() <= 1 &&
          (page.state.maxScroll - page.state.physicalMaxScroll).abs() <= 1;
      if (error > 1 && !isTerminalClamp) {
        violations.add(InvariantViolation(
          invariant: 'I1',
          pageNumber: page.pageNumber,
          message: 'Scroll ${page.state.scroll.toStringAsFixed(3)} not aligned '
              'to absolute pitch ${pitch.toStringAsFixed(3)} '
              '(error=${error.toStringAsFixed(3)})',
        ));
      }
    }

    // I2: Marker continuity
    if (i > 0 && pages[i - 1].markers.isNotEmpty && page.markers.isNotEmpty) {
      final prevLast = _markerIndex(pages[i - 1].markers.last);
      final currFirst = _markerIndex(page.markers.first);
      if (currFirst > prevLast + 1) {
        violations.add(InvariantViolation(
          invariant: 'I2',
          pageNumber: page.pageNumber,
          message: 'Gap: prev last=m${prevLast.toString().padLeft(3, "0")} '
              'curr first=m${currFirst.toString().padLeft(3, "0")} '
              '(${currFirst - prevLast - 1} markers skipped)',
          details: {'prevLast': prevLast, 'currFirst': currFirst},
        ));
      }
      if (currFirst < prevLast - 1) {
        violations.add(InvariantViolation(
          invariant: 'I2',
          pageNumber: page.pageNumber,
          message:
              'Severe overlap: regressed by ${prevLast - currFirst} markers',
          details: {'prevLast': prevLast, 'currFirst': currFirst},
        ));
      }
    }

    // I4: Progress monotonicity (checked via scroll position)
    if (i > 0 && page.state.scroll < pages[i - 1].state.scroll - 1) {
      violations.add(InvariantViolation(
        invariant: 'I4',
        pageNumber: page.pageNumber,
        message: 'Scroll went backward: '
            '${pages[i - 1].state.scroll} → ${page.state.scroll}',
      ));
    }

    // I6: Constant step. Every forward page turn must advance by EXACTLY one
    // columnPitch (±1px for rounding). This is the direct detector for the
    // "翻页越翻越偏" regression: a step that is consistently a few px off
    // accumulates into a growing offset even while I1 (alignment to pitch)
    // still passes. The only legitimate exception is the final turn, which
    // may land short when the chapter end is not a whole multiple of pitch.
    if (i > 0 && page.state.columnPitch > 0) {
      final delta = page.state.scroll - pages[i - 1].state.scroll;
      final pitch = page.state.columnPitch;
      final isLast = i == pages.length - 1;
      final isPhysicalTerminal = isLast &&
          (page.state.scroll - page.state.physicalMaxScroll).abs() <= 1 &&
          (page.state.maxScroll - page.state.physicalMaxScroll).abs() <= 1;
      final ok = (delta - pitch).abs() <= 1 ||
          (isPhysicalTerminal && delta > 1 && delta <= pitch + 1);
      if (!ok) {
        violations.add(InvariantViolation(
          invariant: 'I6',
          pageNumber: page.pageNumber,
          message: 'Page step ${delta.toStringAsFixed(3)} != pitch '
              '${pitch.toStringAsFixed(3)} (drift '
              '${(delta - pitch).toStringAsFixed(3)}px on turn '
              '${page.pageNumber})',
          details: {'delta': delta, 'pitch': pitch},
        ));
      }
    }
  }

  // A perfectly aligned subset can still miss the start or tail. Lock both
  // scan endpoints to the production metrics so coverage cannot self-validate
  // against an arbitrary interior range.
  if (pages.isNotEmpty) {
    final PageData first = pages.first;
    if ((first.state.scroll - first.state.minScroll).abs() > 1) {
      violations.add(InvariantViolation(
        invariant: 'I1',
        pageNumber: first.pageNumber,
        message: 'Scan starts at ${first.state.scroll.toStringAsFixed(3)}, '
            'not minScroll ${first.state.minScroll.toStringAsFixed(3)}',
      ));
    }
    final PageData last = pages.last;
    if ((last.state.scroll - last.state.maxScroll).abs() > 1) {
      violations.add(InvariantViolation(
        invariant: 'I1',
        pageNumber: last.pageNumber,
        message: 'Scan ends at ${last.state.scroll.toStringAsFixed(3)}, '
            'not maxScroll ${last.state.maxScroll.toStringAsFixed(3)}',
      ));
    }
  }

  // I2 (union): independent of argmax assignment, the union of substantially
  // visible markers must advance monotonically — the lowest-index marker on
  // each page should not move backward. Catches content being re-ordered or
  // pages repeating even if argmax bookkeeping looks continuous.
  for (int i = 1; i < pages.length; i++) {
    if (pages[i - 1].markers.isEmpty || pages[i].markers.isEmpty) continue;
    final prevFirst = _markerIndex(pages[i - 1].markers.first);
    final currFirst = _markerIndex(pages[i].markers.first);
    if (currFirst < prevFirst) {
      violations.add(InvariantViolation(
        invariant: 'I2',
        pageNumber: pages[i].pageNumber,
        message: 'First marker regressed: '
            'm${prevFirst.toString().padLeft(3, "0")} -> '
            'm${currFirst.toString().padLeft(3, "0")}',
      ));
    }
  }

  // I3: Full coverage
  for (int m = 1; m <= expectedMarkerCount; m++) {
    final id = 'm${m.toString().padLeft(3, "0")}';
    if (!allSeen.contains(id)) {
      violations.add(InvariantViolation(
        invariant: 'I3',
        pageNumber: -1,
        message: 'Marker $id never appeared on any page',
      ));
    }
  }

  // The final marker has no following page on which its hidden remainder can
  // appear. Seeing a few pixels is therefore not coverage: the chapter scan
  // must expose at least half of that marker inside the reader's clipped
  // content box on one recorded page.
  if (expectedMarkerCount > 0) {
    final String tailId = 'm${expectedMarkerCount.toString().padLeft(3, "0")}';
    double tailBestFraction = 0;
    for (final PageData page in pages) {
      final double fraction = page.markerFractions[tailId] ?? 0;
      if (fraction > tailBestFraction) tailBestFraction = fraction;
    }
    if (allSeen.contains(tailId) && tailBestFraction < 0.5) {
      violations.add(InvariantViolation(
        invariant: 'I3',
        pageNumber: pages.isEmpty ? -1 : pages.last.pageNumber,
        message: 'Tail marker $tailId was never substantially visible '
            '(best fraction ${tailBestFraction.toStringAsFixed(3)})',
        details: <String, dynamic>{'bestFraction': tailBestFraction},
      ));
    }
  }

  // I5: Last page trailing space
  if (pages.isNotEmpty) {
    final last = pages.last;
    final trailing = last.state.maxScroll - last.state.scroll;
    if (trailing > last.state.columnPitch && last.state.columnPitch > 0) {
      violations.add(InvariantViolation(
        invariant: 'I5',
        pageNumber: last.pageNumber,
        message: 'Excessive trailing space: ${trailing}px '
            '(> pitch ${last.state.columnPitch}px)',
      ));
    }
  }

  // I7: Page count reasonableness
  if (pages.isNotEmpty) {
    final totalPages = pages.length;
    final totalChars = pages.first.state.totalChars;
    if (totalChars > 0) {
      if (totalPages > totalChars / 5) {
        violations.add(InvariantViolation(
          invariant: 'I7',
          pageNumber: -1,
          message: 'Too many pages: $totalPages for $totalChars chars '
              '(< 5 chars/page)',
        ));
      }
      if (totalPages < totalChars / 2000) {
        violations.add(InvariantViolation(
          invariant: 'I7',
          pageNumber: -1,
          message: 'Too few pages: $totalPages for $totalChars chars '
              '(> 2000 chars/page)',
        ));
      }
    }
  }

  return violations;
}

/// Validate that rendered CSS matches expected settings.
List<InvariantViolation> validateRenderedSettings(
  RenderedSettings rendered, {
  double? expectedFontSize,
  double? expectedLineHeight,
  String? expectedWritingMode,
  int? expectedColumns,
}) {
  final violations = <InvariantViolation>[];

  if (expectedFontSize != null) {
    final diff = (rendered.fontSize - expectedFontSize).abs();
    if (diff > 1.5) {
      violations.add(InvariantViolation(
        invariant: 'I8',
        pageNumber: -1,
        message: 'fontSize: expected $expectedFontSize, '
            'got ${rendered.fontSize} (diff=$diff)',
      ));
    }
  }

  if (expectedLineHeight != null) {
    final diff = (rendered.lineHeight - expectedLineHeight).abs();
    if (diff > 0.2) {
      violations.add(InvariantViolation(
        invariant: 'I8',
        pageNumber: -1,
        message: 'lineHeight: expected $expectedLineHeight, '
            'got ${rendered.lineHeight} (diff=$diff)',
      ));
    }
  }

  if (expectedWritingMode != null &&
      rendered.writingMode != expectedWritingMode) {
    violations.add(InvariantViolation(
      invariant: 'I8',
      pageNumber: -1,
      message: 'writingMode: expected $expectedWritingMode, '
          'got ${rendered.writingMode}',
    ));
  }

  if (expectedColumns != null &&
      expectedColumns >= 2 &&
      rendered.columnCount < 2) {
    violations.add(InvariantViolation(
      invariant: 'I8',
      pageNumber: -1,
      message: 'columnCount: expected >= $expectedColumns, '
          'got ${rendered.columnCount}',
    ));
  }

  return violations;
}

/// Validate position restoration after config change.
List<InvariantViolation> validatePositionRestoration({
  required List<String> beforeMarkers,
  required List<String> afterMarkers,
  int maxMarkerDrift = 3,
}) {
  final violations = <InvariantViolation>[];

  if (beforeMarkers.isEmpty || afterMarkers.isEmpty) {
    violations.add(InvariantViolation(
      invariant: 'I9',
      pageNumber: -1,
      message: 'Empty markers: before=${beforeMarkers.length}, '
          'after=${afterMarkers.length}',
    ));
    return violations;
  }

  final overlap = beforeMarkers.toSet().intersection(afterMarkers.toSet());
  if (overlap.isEmpty) {
    final beforeMid = _markerIndex(beforeMarkers[beforeMarkers.length ~/ 2]);
    final afterMid = _markerIndex(afterMarkers[afterMarkers.length ~/ 2]);
    final drift = (afterMid - beforeMid).abs();
    if (drift > maxMarkerDrift) {
      violations.add(InvariantViolation(
        invariant: 'I9',
        pageNumber: -1,
        message: 'No marker overlap and drift=$drift > $maxMarkerDrift. '
            'Before: ${beforeMarkers.first}..${beforeMarkers.last}, '
            'After: ${afterMarkers.first}..${afterMarkers.last}',
      ));
    }
  }

  return violations;
}

int _markerIndex(String markerId) {
  return int.tryParse(markerId.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
}

/// Parse fullChapterScan JSON result into PageData list.
List<PageData> parseChapterScan(String jsonStr) {
  final List<dynamic> list = jsonDecode(jsonStr) as List<dynamic>;
  return list.map((e) => PageData.fromJson(e as Map<String, dynamic>)).toList();
}

/// Parse visible markers JSON.
List<String> parseMarkers(String jsonStr) {
  final List<dynamic> list = jsonDecode(jsonStr) as List<dynamic>;
  return list.cast<String>();
}

/// Parse rendered settings JSON.
RenderedSettings parseRenderedSettings(String jsonStr) {
  return RenderedSettings.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
}

/// Print formatted test report.
void printTestReport({
  required String configName,
  required String chapterName,
  required int markerCount,
  required List<PageData> pages,
  required List<InvariantViolation> violations,
}) {
  debugPrint('  $chapterName ($markerCount markers): ${pages.length} pages');
  final byInvariant = <String, List<InvariantViolation>>{};
  for (final v in violations) {
    byInvariant.putIfAbsent(v.invariant, () => []).add(v);
  }
  for (final inv in ['I1', 'I2', 'I3', 'I4', 'I5', 'I7']) {
    final vs = byInvariant[inv];
    if (vs == null || vs.isEmpty) {
      debugPrint('    ✓ $inv passed');
    } else {
      for (final v in vs) {
        debugPrint('    ✗ $v');
      }
    }
  }
}
