import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// TODO-1285 (third recheck) -- real WebView2 column + image geometry probe.
///
/// The user reported "per-page columns don't take effect" a THIRD time. Every
/// prior proof that columns render (`tool/reader_pitch_headless/*.mjs`) ran on
/// desktop **Google Chrome via CDP**, NOT the WebView2 engine the reader really
/// renders in (forked flutter_inappwebview_windows). This harness injects the
/// REAL [ReaderContentStyles.css] output into a live WebView2 and reads back
/// getComputedStyle / getBoundingClientRect to measure, on the actual engine:
///   1. column-count / column-width are honoured (computed values);
///   2. how many DISTINCT COLUMN BANDS render per page (band boundaries in the
///      probe glyph x/y positions -- NOT per-character positions);
///   3. column pitch, true page advance, and the JS getScrollContext pageStep;
///   4. whether a wide block image overflows the sub-column WITHOUT the
///      _imageMaxBox clamp (BUG-679 danger) and is clamped WITH it.
///
/// horizontal-tb turn axis = left/scrollLeft; vertical-rl turn axis =
/// top/scrollTop. Columns tested at N=1,2,3.
///
/// Run (from hibiki/, offscreen):
///   .\tool\run_windows_itest.ps1 integration_test\desktop_reader_columns_dom_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 5000 probe glyphs (built via DOM, not innerHTML): enough to fill 3
  // columns/page across several pages so a band-boundary count distinguishes
  // "columns don't render" from "short content" at N=3.
  const String buildProbeBodyJs = r'''
    (function() {
      var body = document.body;
      body.replaceChildren();
      var frag = document.createDocumentFragment();
      for (var i = 0; i < 5000; i++) {
        var s = document.createElement('span');
        s.className = 'hoshi-probe';
        s.textContent = 'あ';
        frag.appendChild(s);
      }
      body.appendChild(frag);
    })();
  ''';

  // A 1200x500 block image (base64 SVG, deterministic intrinsic size) for the
  // multicol image-overflow path (BUG-679).
  const String svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1200" '
      'height="500"><rect width="1200" height="500" fill="#888888"/></svg>';
  final String imgSrc =
      'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';

  Future<void> applyCss(
      InAppWebViewController controller, ReaderSettings settings) async {
    final String css = ReaderContentStyles.css(settings: settings);
    await controller.evaluateJavascript(source: '''
      (function() {
        var vars = document.getElementById('hoshi-test-vars');
        if (!vars) {
          vars = document.createElement('style');
          vars.id = 'hoshi-test-vars';
          document.head.appendChild(vars);
        }
        vars.textContent = ':root{'
          + '--page-width:' + window.innerWidth + 'px;'
          + '--page-height:' + window.innerHeight + 'px;'
          + '--reader-viewport-height:' + window.innerHeight + 'px;'
          + '--chrome-top-inset:0px;--chrome-bottom-inset:0px;}';
        var s = document.getElementById('hoshi-reader-style');
        if (!s) {
          s = document.createElement('style');
          s.id = 'hoshi-reader-style';
          document.head.appendChild(s);
        }
        s.textContent = ${jsonEncode(css)};
      })();
    ''');
  }

  // Column-band probe: clusters probe glyph turn-axis positions into COLUMN
  // BANDS (a new band starts when the gap between adjacent distinct positions
  // exceeds ~1.5x the within-column glyph pitch), so it reports real columns per
  // page, not per-character positions. Also replicates getScrollContext.pageStep.
  const String probeJs = r'''
    (function() {
      var body = document.body;
      var cs = getComputedStyle(body);
      var vertical = cs.writingMode.indexOf('vertical') === 0;
      var bodyRect = body.getBoundingClientRect();
      var pl = parseFloat(cs.paddingLeft) || 0;
      var pr = parseFloat(cs.paddingRight) || 0;
      var pt = parseFloat(cs.paddingTop) || 0;
      var pb = parseFloat(cs.paddingBottom) || 0;
      var vw = window.innerWidth, vh = window.innerHeight;
      var contentStart = vertical ? (bodyRect.top + pt) : (bodyRect.left + pl);
      var contentEnd = vertical ? (bodyRect.bottom - pb) : (bodyRect.right - pr);
      var contentBox = contentEnd - contentStart;

      var probes = document.querySelectorAll('.hoshi-probe');
      var seen = {};
      for (var i = 0; i < probes.length; i++) {
        var r = probes[i].getBoundingClientRect();
        if (r.width <= 0 && r.height <= 0) continue;
        var turnPos = vertical ? r.top : r.left;
        seen[Math.round(turnPos)] = 1;
      }
      var positions = Object.keys(seen).map(Number).sort(function(a, b) { return a - b; });

      var firstPagePos = positions.filter(function(x) {
        return x >= contentStart - 2 && x <= contentEnd + 2;
      });
      var gaps = [];
      for (var k = 1; k < firstPagePos.length; k++) {
        gaps.push(firstPagePos[k] - firstPagePos[k - 1]);
      }
      var sortedGaps = gaps.slice().sort(function(a, b) { return a - b; });
      var glyphPitch = sortedGaps.length ? sortedGaps[Math.floor(sortedGaps.length / 2)] : 22;
      if (!(glyphPitch > 0)) glyphPitch = 22;
      var bandThreshold = glyphPitch * 1.5;
      var columnBands = firstPagePos.length ? 1 : 0;
      for (var j = 1; j < firstPagePos.length; j++) {
        if (firstPagePos[j] - firstPagePos[j - 1] > bandThreshold) columnBands++;
      }
      var allBandStarts = [];
      if (positions.length) {
        allBandStarts.push(positions[0]);
        for (var m = 1; m < positions.length; m++) {
          if (positions[m] - positions[m - 1] > bandThreshold) {
            allBandStarts.push(positions[m]);
          }
        }
      }
      var columnPitch = allBandStarts.length >= 2 ? (allBandStarts[1] - allBandStarts[0]) : null;
      var trueAdvance = (allBandStarts.length > columnBands && columnBands >= 1)
        ? (allBandStarts[columnBands] - allBandStarts[0]) : null;

      var contentBoxJs;
      var resolvedColumnWidth = parseFloat(cs.columnWidth);
      if (resolvedColumnWidth > 0) {
        contentBoxJs = resolvedColumnWidth;
      } else if (vertical) {
        contentBoxJs = (vh) - pt - pb;
      } else {
        contentBoxJs = (body.clientWidth || vw) - pl - pr;
      }
      var fontFloor = parseFloat(cs.fontSize) || 1;
      contentBoxJs = Math.max(fontFloor, contentBoxJs);
      var gap = parseFloat(cs.columnGap) || 0;
      var columns = parseInt(cs.columnCount, 10);
      var columnsSource = 'columnCount';
      if (!(columns > 0)) {
        columnsSource = 'geometry-fallback';
        var fullTurnBox = vertical
          ? (vh - pt - pb)
          : ((body.getBoundingClientRect().width || body.clientWidth || vw) - pl - pr);
        columns = Math.max(1, Math.round((fullTurnBox + gap) / (contentBoxJs + gap)));
      }
      var jsPageStep = columns * (contentBoxJs + gap);

      return JSON.stringify({
        writingMode: cs.writingMode,
        vertical: vertical,
        computedColumnCount: cs.columnCount,
        computedColumnWidth: cs.columnWidth,
        computedColumnGap: cs.columnGap,
        computedColumnFill: cs.columnFill,
        vw: vw, vh: vh,
        contentBox: contentBox,
        glyphPitch: glyphPitch,
        columnBandsFirstPage: columnBands,
        columnPitchPx: columnPitch,
        truePageAdvancePx: trueAdvance,
        js_contentBox: contentBoxJs,
        js_gap: gap,
        js_columns: columns,
        js_columnsSource: columnsSource,
        js_pageStep: jsPageStep
      });
    })();
  ''';

  Map<String, dynamic> parse(Object? raw) {
    final String s = raw?.toString() ?? '';
    if (s.isEmpty || s == 'null') return <String, dynamic>{};
    return jsonDecode(s) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> measure({
    required InAppWebViewController controller,
    required ReaderSettings settings,
    required String writingMode,
    required int pageColumns,
    required WidgetTester tester,
  }) async {
    await settings.setViewMode('paginated');
    await settings.setWritingMode(writingMode);
    await settings.setPageColumns(pageColumns);
    await applyCss(controller, settings);
    await tester.pump(const Duration(milliseconds: 400));
    final Object? raw = await controller.evaluateJavascript(source: probeJs);
    return parse(raw);
  }

  Future<InAppWebViewController> bootWebView(WidgetTester tester) async {
    final Completer<InAppWebViewController> ready =
        Completer<InAppWebViewController>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(
              data: '<!DOCTYPE html><html><head><meta charset="utf-8">'
                  '</head><body></body></html>'),
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            if (!ready.isCompleted) ready.complete(controller);
          },
        ),
      ),
    ));
    for (int i = 0; i < 150 && !ready.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready.isCompleted, isTrue,
        reason: 'WebView did not load within 15s');
    final InAppWebViewController controller = await ready.future;
    await tester.pump(const Duration(seconds: 1));
    return controller;
  }

  testWidgets(
      'TODO-1285: pageColumns renders N distinct column bands per page in the '
      'real WebView2 engine (horizontal + vertical), and JS pageStep matches '
      'the true page advance', (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    final InAppWebViewController controller = await bootWebView(tester);
    await controller.evaluateJavascript(source: buildProbeBodyJs);

    final List<String> modes = <String>['horizontal-tb', 'vertical-rl'];
    final List<int> columnCounts = <int>[1, 2, 3];
    final Map<String, Map<String, dynamic>> results =
        <String, Map<String, dynamic>>{};

    for (final String mode in modes) {
      for (final int n in columnCounts) {
        final Map<String, dynamic> m = await measure(
          controller: controller,
          settings: settings,
          writingMode: mode,
          pageColumns: n,
          tester: tester,
        );
        results['$mode/N=$n'] = m;
        debugPrint('[cols-dom] $mode/N=$n => ${jsonEncode(m)}');
      }
    }

    for (final String mode in modes) {
      for (final int n in columnCounts) {
        final Map<String, dynamic> m = results['$mode/N=$n']!;
        final int bands = (m['columnBandsFirstPage'] as num?)?.toInt() ?? -1;
        expect(bands, n,
            reason: '$mode: set $n cols/page -> real WebView2 must render $n '
                'distinct column bands on page 1, measured $bands. '
                'computedColumnCount=${m['computedColumnCount']} '
                'computedColumnWidth=${m['computedColumnWidth']}');

        final num? trueAdvance = m['truePageAdvancePx'] as num?;
        final num? jsPageStep = m['js_pageStep'] as num?;
        if (trueAdvance != null && jsPageStep != null && trueAdvance > 0) {
          expect((jsPageStep - trueAdvance).abs(), lessThan(2.0),
              reason:
                  '$mode/N=$n: JS pageStep=$jsPageStep must ~= true advance='
                  '$trueAdvance (<2px), else flipping leaks a neighbour page. '
                  'js_columnsSource=${m['js_columnsSource']}');
        }
      }
    }
  });

  testWidgets(
      'TODO-1285/BUG-679: a wide block image OVERFLOWS the sub-column without '
      'the _imageMaxBox clamp and is CLAMPED with it, in the real WebView2 '
      'engine', (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setViewMode('paginated');
    await settings.setWritingMode('horizontal-tb');
    await settings.setPageColumns(2);

    final InAppWebViewController controller = await bootWebView(tester);

    // Build a wide block image + filler text (2-column page) via safe DOM APIs.
    await controller.evaluateJavascript(source: '''
      (function() {
        var body = document.body;
        body.replaceChildren();
        var img = document.createElement('img');
        img.className = 'block-img';
        img.src = ${jsonEncode(imgSrc)};
        body.appendChild(img);
        for (var i = 0; i < 400; i++) {
          var s = document.createElement('span');
          s.className = 'hoshi-probe';
          s.textContent = 'あ';
          body.appendChild(s);
        }
      })();
    ''');
    await applyCss(controller, settings);
    await tester.pump(const Duration(milliseconds: 500));

    const String imgProbe = r'''
      (function() {
        var body = document.body;
        var cs = getComputedStyle(body);
        var subCol = parseFloat(cs.columnWidth);
        var img = document.querySelector('img.block-img');
        var w = img ? img.getBoundingClientRect().width : -1;
        var maxw = img ? getComputedStyle(img).maxWidth : '';
        return JSON.stringify({ subCol: subCol, imgWidth: w, imgMaxWidth: maxw });
      })();
    ''';
    final Map<String, dynamic> noClamp =
        parse(await controller.evaluateJavascript(source: imgProbe));
    debugPrint('[img-dom] no-clamp => ${jsonEncode(noClamp)}');

    // Replicate hoshiReader._imageMaxBox: set --hoshi-image-max-width to the used
    // sub-column width (getComputedStyle(body).columnWidth).
    await controller.evaluateJavascript(source: r'''
      (function() {
        var used = parseFloat(getComputedStyle(document.body).columnWidth);
        document.documentElement.style.setProperty('--hoshi-image-max-width', used + 'px');
      })();
    ''');
    await tester.pump(const Duration(milliseconds: 300));
    final Map<String, dynamic> clamped =
        parse(await controller.evaluateJavascript(source: imgProbe));
    debugPrint('[img-dom] clamped => ${jsonEncode(clamped)}');

    final double subCol = (noClamp['subCol'] as num).toDouble();
    final double imgNoClamp = (noClamp['imgWidth'] as num).toDouble();
    final double imgClamped = (clamped['imgWidth'] as num).toDouble();

    expect(imgNoClamp, greaterThan(subCol + 2),
        reason:
            'a 1200px image without the _imageMaxBox clamp must overflow the '
            '${subCol}px sub-column (imgWidth=$imgNoClamp) -- proves the clamp '
            'is load-bearing');
    expect(imgClamped, lessThanOrEqualTo(subCol + 2),
        reason:
            'with --hoshi-image-max-width = used sub-column, the image must '
            'be clamped to <= ${subCol}px (imgWidth=$imgClamped)');
  });
}
