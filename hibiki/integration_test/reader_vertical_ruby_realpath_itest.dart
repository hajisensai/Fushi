import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/sources/reader_hibiki_source.dart'
    show ReaderHibikiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart'
    show ReaderHibikiPage;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel, seedReaderBook;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// TODO-1308 real-path reproduction — vertical-rl furigana misplacement after a
/// TOC/bookmark jump, exercised through the REAL reader WebView (real bundled
/// font, real pagination/reveal/reanchor path, real `_applyChapterHighlights`),
/// which the previous headless / bare-InAppWebView probes could not reach.
///
/// It measures, per base+annotation pair, how each <rt> sits relative to its
/// base glyph in vertical-rl. Correct: annotation to the RIGHT of the base
/// column (dx > 0) and vertically aligned with its base (|dyRatio| ≈ 0). The
/// reported bug: the <rt> shifts along the column (かん lands between 貫 and 禄,
/// ろく floats to the base's right at the wrong height) => large |dyRatio|.
///
/// It measures BOTH the book's own seeded ruby AND an injected paragraph
/// carrying the exact 貫(かん)禄(ろく) / 安達 mono-ruby the user screenshotted
/// (with <rp> fallback parens, real-EPUB markup), before and after a jump.
///
/// Run (PowerShell, from hibiki/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       -Visible integration_test/reader_vertical_ruby_realpath_itest.dart

bool _webViewShown() =>
    find.byKey(const ValueKey<String>('hoshi_webview')).evaluate().isNotEmpty;

bool _contentReady() => find
    .byKey(const ValueKey<String>('hoshi_content_ready'))
    .evaluate()
    .isNotEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (ready()) {
      debugPrint('[vruby] $label ready after ${i * 500}ms');
      return;
    }
  }
  fail('$label did not become ready');
}

// Injects a paragraph with the user's exact mono-ruby (per-character furigana)
// at the tail of the real reader body, then measures ALL ruby on the page.
const String _injectAndMeasureJs = r'''
(function () {
  function rectObj(r) {
    return { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height,
             cx: (r.left + r.right) / 2, cy: (r.top + r.bottom) / 2 };
  }
  // Ensure our probe paragraph exists exactly once.
  var host = document.getElementById('vruby-probe');
  if (!host) {
    host = document.createElement('p');
    host.id = 'vruby-probe';
    // Real-EPUB mono-ruby markup, per-character furigana with <rp> fallback.
    host.innerHTML =
      'それは<ruby class="vr" data-b="貫">貫<rp>(</rp><rt>かん</rt><rp>)</rp>' +
      '禄<rp>(</rp><rt>ろく</rt><rp>)</rp></ruby>のある' +
      '<ruby class="vr" data-b="安達">安<rp>(</rp><rt>あ</rt><rp>)</rp>' +
      '達<rp>(</rp><rt>だち</rt><rp>)</rp></ruby>としまむら。' +
      '<ruby class="vr" data-b="漢1">漢<rt>かん</rt></ruby>' +
      '<ruby class="vr" data-b="字1">字<rt>じ</rt></ruby>の物語。';
    (document.body || document.documentElement).appendChild(host);
  }
  void host.offsetHeight;

  function measureRuby(ruby, tag) {
    var pairs = [];
    var pendingBase = null;
    var nodes = ruby.childNodes;
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (n.nodeType === 3) {
        var txt = n.textContent;
        if (!txt || !txt.trim()) continue;
        var range = document.createRange();
        range.selectNodeContents(n);
        pendingBase = { text: txt, rect: rectObj(range.getBoundingClientRect()) };
      } else if (n.tagName === 'RT') {
        var rt = { text: n.textContent, rect: rectObj(n.getBoundingClientRect()) };
        var base = pendingBase;
        var entry = { tag: tag, base: base, rt: rt };
        if (base && rt.rect.h > 0 && base.rect.h > 0) {
          entry.dx = rt.rect.cx - base.rect.cx;
          entry.dy = rt.rect.cy - base.rect.cy;
          entry.dyRatio = (rt.rect.cy - base.rect.cy) / base.rect.h;
          entry.rtRightOfBase = rt.rect.cx > base.rect.cx;
        }
        pairs.push(entry);
        pendingBase = null;
      }
    }
    return pairs;
  }

  var out = [];
  // Injected mono-ruby (the reported case).
  var vr = document.querySelectorAll('#vruby-probe ruby.vr');
  for (var i = 0; i < vr.length; i++) {
    var m = measureRuby(vr[i], 'inject:' + (vr[i].getAttribute('data-b') || i));
    for (var j = 0; j < m.length; j++) out.push(m[j]);
  }
  // First few of the book's own seeded ruby (real book content baseline).
  var book = document.querySelectorAll('body ruby:not(.vr)');
  for (var k = 0; k < book.length && k < 6; k++) {
    var mb = measureRuby(book[k], 'book:' + k);
    for (var jj = 0; jj < mb.length; jj++) out.push(mb[jj]);
  }
  var rtCss = null;
  var anyRt = document.querySelector('rt');
  if (anyRt) {
    var cs = getComputedStyle(anyRt);
    rtCss = { fontSize: cs.fontSize, rubyPosition: cs.rubyPosition || cs.webkitRubyPosition,
              rubyAlign: cs.rubyAlign, display: cs.display, lineHeight: cs.lineHeight };
  }
  return JSON.stringify({
    writingMode: getComputedStyle(document.body).writingMode,
    bodyFont: getComputedStyle(document.body).fontFamily,
    bodyLineHeight: getComputedStyle(document.body).lineHeight,
    rtCss: rtCss,
    pairs: out
  });
})();
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-1308 vertical-rl furigana stays aligned with its base through the '
    'real reader render path (before and after a jump)',
    (WidgetTester tester) async {
      await runHibikiItest(
        label: 'vruby',
        body: () async {
          app.main();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));

          final AppModel appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          await seedReaderBook(tester, fileName: 'todo1308_vertical_ruby.epub');
          final FocusDriver driver = FocusDriver(tester);

          final List<Finder> navTargets = findPrimaryNavigationTargets();
          if (navTargets.isNotEmpty) {
            await driver.focusWidget(navTargets.first);
            await driver.activate();
            await tester.pump(const Duration(seconds: 1));
          }

          final Finder bookEntries = findBookEntries();
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (bookEntries.evaluate().isNotEmpty) break;
          }
          expect(bookEntries, findsWidgets,
              reason: 'seeded book must appear on the shelf');
          expect(await driver.focusWidget(bookEntries.first), isTrue,
              reason: 'book card must be reachable by focus');
          await driver.activate();
          await tester.pump(const Duration(seconds: 3));

          await _waitFor(tester, _webViewShown, 'reader WebView');
          await _waitFor(tester, _contentReady, 'hoshi content');

          // Keep vertical-rl (the machine default) + continuous scroll (the
          // reported scenario). writingMode/viewMode are structural layout keys:
          // fire onLayoutReloadLive to re-run pagination (the product path).
          await ReaderHibikiSource.instance.setReaderWritingMode('vertical-rl');
          await ReaderHibikiSource.instance.setReaderViewMode('continuous');
          ReaderHibikiSource.onLayoutReloadLive?.call();
          for (int i = 0; i < 16; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await _waitFor(tester, _contentReady, 'continuous content');

          final Future<dynamic> Function(String source)? runJs =
              ReaderHibikiPage.debugEvaluateJavascript;
          expect(runJs, isNotNull,
              reason: 'reader must expose debugEvaluateJavascript hook');

          final Object? verticalRaw =
              await runJs!('window.fushiReader.isVertical();');
          expect(verticalRaw == true || verticalRaw == 'true', isTrue,
              reason: 'reader must be vertical-rl for TODO-1308');

          Future<Map<String, dynamic>> probe(String label) async {
            await runJs('void document.body.offsetHeight;');
            await tester.pump(const Duration(milliseconds: 400));
            final Object? raw = await runJs(_injectAndMeasureJs);
            final Map<String, dynamic> m =
                jsonDecode(raw.toString()) as Map<String, dynamic>;
            debugPrint('[vruby] === $label ===');
            debugPrint('[vruby] writingMode=${m['writingMode']} '
                'bodyLineHeight=${m['bodyLineHeight']} rtCss=${m['rtCss']}');
            debugPrint('[vruby] bodyFont=${m['bodyFont']}');
            for (final dynamic p in (m['pairs'] as List<dynamic>)) {
              final Map<String, dynamic> pr = p as Map<String, dynamic>;
              final Map<String, dynamic>? base =
                  pr['base'] as Map<String, dynamic>?;
              final Map<String, dynamic> rt = pr['rt'] as Map<String, dynamic>;
              debugPrint('[vruby] ${pr['tag']} base="${base?['text']}" '
                  'rt="${rt['text']}" dx=${_f(pr['dx'])} dy=${_f(pr['dy'])} '
                  'dyRatio=${_f(pr['dyRatio'])} rtRight=${pr['rtRightOfBase']}');
            }
            return m;
          }

          // Measure BEFORE any jump.
          final Map<String, dynamic> before = await probe('BEFORE jump');

          // Trigger the real jump/relayout path: scroll to a char offset (the
          // reveal/reanchor machinery) + toggle chrome insets (forces the same
          // incremental relayout _applyChapterHighlights triggers).
          await runJs('window.fushiReader.restoreToCharOffset(200);');
          await tester.pump(const Duration(milliseconds: 400));
          await runJs('window.fushiReader.setChromeInsets(48, 96);');
          await tester.pump(const Duration(milliseconds: 400));
          await runJs('window.fushiReader.setChromeInsets(0, 0);');
          await tester.pump(const Duration(milliseconds: 400));

          // Measure AFTER jump/relayout.
          final Map<String, dynamic> after = await probe('AFTER jump');

          // Capture real pixels (authoritative evidence).
          final captureHook = ReaderHibikiPage.debugCaptureWebView;
          if (captureHook != null) {
            try {
              await captureHook();
              debugPrint('[vruby] captured reader WebView pixels');
            } catch (e) {
              debugPrint('[vruby] capture failed: $e');
            }
          }

          // Assert alignment on the AFTER measurement (the reported state).
          final List<String> failures = <String>[];
          for (final dynamic p in (after['pairs'] as List<dynamic>)) {
            final Map<String, dynamic> pr = p as Map<String, dynamic>;
            final num? dyRatio = pr['dyRatio'] as num?;
            if (dyRatio == null) continue;
            final Map<String, dynamic>? base =
                pr['base'] as Map<String, dynamic>?;
            final String rtText =
                (pr['rt'] as Map<String, dynamic>)['text'].toString();
            if (pr['rtRightOfBase'] != true) {
              failures.add('${pr['tag']} rt="$rtText" not right of base '
                  '(dx=${_f(pr['dx'])})');
            }
            if (dyRatio.abs() >= 0.35) {
              failures.add('${pr['tag']} base="${base?['text']}" rt="$rtText" '
                  'shifted along column dyRatio=${_f(dyRatio)}');
            }
          }
          debugPrint('[vruby] BEFORE pairs=${(before['pairs'] as List).length} '
              'AFTER pairs=${(after['pairs'] as List).length}');
          debugPrint('[vruby] failures=${failures.length}: $failures');
          expect(failures, isEmpty,
              reason: 'vertical-rl furigana misaligned through the real reader '
                  'path: ${failures.join("; ")}');
        },
      );
    },
  );
}

String _f(dynamic v) {
  if (v is num) return v.toStringAsFixed(2);
  return v.toString();
}
