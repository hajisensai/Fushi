import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// TODO-1308 reproduction probe — vertical-rl ruby (furigana) misplacement on
/// the REAL in-app WebView2 (flutter_inappwebview_windows fork), which the
/// previous headless-Edge investigation could not exercise.
///
/// It injects the actual [ReaderContentStyles.css] over a page containing
/// 貫(かん)禄(ろく) style mono-ruby and measures, per base+annotation pair, how
/// the <rt> sits relative to its base glyph. In vertical-rl the annotation must
/// sit to the RIGHT of the base column (dx > 0) and stay vertically aligned with
/// its base (|dy| ≈ 0). The reported bug: <rt> shifts down ~half a base glyph
/// (「かん挤在两个汉字之间 / ろく浮到基字右侧错位」) — i.e. large |dy|.
///
/// Run (from hibiki/): tool\run_windows_itest.ps1 integration_test\reader_vertical_ruby_probe_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Realistic chapter fragment: a paragraph mixing plain kanji, mono-ruby
  // (separate base+rt pairs — the 熟語 the user screenshotted), group ruby, and
  // a single ruby. Enough text so vertical columns actually form.
  const String html = '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '</head><body>'
      '<p id="para">'
      'それは<ruby id="mono">貫<rt>かん</rt>禄<rt>ろく</rt></ruby>のある'
      '<ruby id="group">貫禄<rt>かんろく</rt></ruby>だった。'
      '<ruby id="single">漢<rt>かん</rt></ruby>字の'
      '<ruby id="mono2">安<rt>あ</rt>達<rt>だち</rt></ruby>としまむら。'
      'ずっと昔から続いている物語であることは間違いない。'
      '</p></body></html>';

  // JS probe: returns, for each named ruby, the base+rt pairs with rects +
  // computed alignment (dx = rt.cx-base.cx, dy = rt.cy-base.cy, dyRatio =
  // dy/baseHeight). Positive dx => annotation to the right (correct in
  // vertical-rl). |dyRatio| near 0 => aligned; near 0.5+ => shifted by ~half a
  // base glyph (the bug).
  const String probeJs = r'''
(function () {
  function rectObj(r) {
    return { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height,
             cx: (r.left + r.right) / 2, cy: (r.top + r.bottom) / 2 };
  }
  function measure(ruby) {
    if (!ruby) return null;
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
        var entry = { base: base, rt: rt };
        if (base) {
          entry.dx = rt.rect.cx - base.rect.cx;
          entry.dy = rt.rect.cy - base.rect.cy;
          entry.dyRatio = base.rect.h > 0 ? (rt.rect.cy - base.rect.cy) / base.rect.h : null;
          entry.rtRightOfBase = rt.rect.cx > base.rect.cx;
        }
        pairs.push(entry);
        pendingBase = null;
      }
    }
    return { rubyRect: rectObj(ruby.getBoundingClientRect()), pairs: pairs };
  }
  var writingMode = getComputedStyle(document.body).writingMode;
  var rtFontSize = (function () {
    var rt = document.querySelector('rt');
    return rt ? getComputedStyle(rt).fontSize : null;
  })();
  return JSON.stringify({
    writingMode: writingMode,
    rtFontSize: rtFontSize,
    mono: measure(document.getElementById('mono')),
    group: measure(document.getElementById('group')),
    single: measure(document.getElementById('single')),
    mono2: measure(document.getElementById('mono2'))
  });
})();
''';

  testWidgets('vertical-rl ruby annotation alignment under real reader CSS',
      (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode('vertical-rl');

    final Completer<void> ready = Completer<void>();
    InAppWebViewController? ctrl;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: InAppWebView(
            initialData: InAppWebViewInitialData(data: html),
            onLoadStop: (InAppWebViewController controller, WebUri? url) async {
              ctrl = controller;
              if (!ready.isCompleted) ready.complete();
            },
          ),
        ),
      ),
    ));

    for (int i = 0; i < 150 && !ready.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready.isCompleted, isTrue, reason: 'WebView did not load in 15s');
    final InAppWebViewController controller = ctrl!;
    await tester.pump(const Duration(seconds: 1));

    Future<void> injectCss(String css) async {
      await controller.evaluateJavascript(source: '''
        (function () {
          var s = document.getElementById('hibiki-probe-style');
          if (!s) { s = document.createElement('style'); s.id = 'hibiki-probe-style';
            document.head.appendChild(s); }
          s.textContent = ${jsonEncode(css)};
        })();
      ''');
    }

    // Simulates the BOOK's own stylesheet: a second <style> appended AFTER the
    // reader style, so equal-specificity / !important book rules win the cascade
    // (real EPUBs ship CSS that can override the reader's ruby rules).
    Future<void> injectBookCss(String css) async {
      await controller.evaluateJavascript(source: '''
        (function () {
          var s = document.getElementById('hibiki-book-style');
          if (!s) { s = document.createElement('style'); s.id = 'hibiki-book-style';
            document.head.appendChild(s); }
          s.textContent = ${jsonEncode(css)};
        })();
      ''');
    }

    Future<Map<String, dynamic>> probe(String label) async {
      // force layout to settle
      await controller.evaluateJavascript(
          source: 'void document.body.offsetHeight;');
      await tester.pump(const Duration(milliseconds: 400));
      final Object? raw = await controller.evaluateJavascript(source: probeJs);
      final Map<String, dynamic> m =
          jsonDecode(raw.toString()) as Map<String, dynamic>;
      debugPrint('[ruby-probe] === $label ===');
      debugPrint('[ruby-probe] writingMode=${m['writingMode']} '
          'rtFontSize=${m['rtFontSize']}');
      for (final String key in <String>['mono', 'group', 'single', 'mono2']) {
        final Map<String, dynamic>? g = m[key] as Map<String, dynamic>?;
        if (g == null) continue;
        final List<dynamic> pairs = g['pairs'] as List<dynamic>;
        for (final dynamic p in pairs) {
          final Map<String, dynamic> pr = p as Map<String, dynamic>;
          final Map<String, dynamic>? base =
              pr['base'] as Map<String, dynamic>?;
          final Map<String, dynamic> rt = pr['rt'] as Map<String, dynamic>;
          debugPrint('[ruby-probe] $key base="${base?['text']}" '
              'rt="${rt['text']}" dx=${_f(pr['dx'])} dy=${_f(pr['dy'])} '
              'dyRatio=${_f(pr['dyRatio'])} rtRightOfBase=${pr['rtRightOfBase']}');
        }
      }
      return m;
    }

    // Variant A: FULL real reader CSS, continuous vertical.
    await settings.setViewMode('continuous');
    await injectCss(ReaderContentStyles.css(settings: settings));
    final Map<String, dynamic> full =
        await probe('FULL reader CSS (continuous vertical-rl)');

    // Variant B: FULL real reader CSS, paginated vertical.
    await settings.setViewMode('paginated');
    await injectCss(ReaderContentStyles.css(settings: settings));
    await probe('FULL reader CSS (paginated vertical-rl)');

    // ── BOOK-CSS OVERRIDE variants: the reader renders correctly on clean
    // markup (A/B above), so the reported misplacement must come from the
    // book's own stylesheet overriding the reader's ruby layout. Each variant
    // keeps the FULL reader CSS and layers a book stylesheet on top, then
    // measures whether the furigana shifts along the column (the bug). ──
    await settings.setViewMode('continuous');
    final String readerCss = ReaderContentStyles.css(settings: settings);
    await injectCss(readerCss);

    // Variant G: book sets rt display to inline-block (breaks ruby-text box).
    await injectBookCss('rt{display:inline-block!important;}');
    await probe('BOOK: rt{display:inline-block}');

    // Variant H: book sets ruby display to inline-block (breaks ruby container).
    await injectBookCss('ruby{display:inline-block!important;}');
    await probe('BOOK: ruby{display:inline-block}');

    // Variant I: book sets rt display to inline (drops it into the flow).
    await injectBookCss('rt{display:inline!important;}');
    await probe('BOOK: rt{display:inline}');

    // Variant J: book resets ruby+rt display to block/inline (legacy styling).
    await injectBookCss('ruby,rt{display:inline-block!important;}');
    await probe('BOOK: ruby,rt{display:inline-block}');

    // Variant K: book overrides ruby-align / ruby-position.
    await injectBookCss(
        'ruby{ruby-align:space-between!important;ruby-position:under!important;}');
    await probe('BOOK: ruby-align:space-between; ruby-position:under');

    // Variant L: book sets rt vertical-align / line-height (legacy furigana CSS).
    await injectBookCss(
        'rt{vertical-align:top!important;line-height:1!important;}');
    await probe('BOOK: rt{vertical-align:top; line-height:1}');

    // ── FIX VERIFICATION: the reader style is injected LAST in <head> (after
    // the book's stylesheets — webview.part.dart), so a reader rule that forces
    // the ruby formatting context with !important wins the cascade over the
    // book's display override. This helper appends the candidate fix as a fresh
    // <style> AFTER the book style, mirroring the real injection order. ──
    Future<void> injectFixLast(String css) async {
      await controller.evaluateJavascript(source: '''
        (function () {
          var old = document.getElementById('hibiki-fix-style');
          if (old) old.remove();
          var s = document.createElement('style');
          s.id = 'hibiki-fix-style';
          s.textContent = ${jsonEncode(css)};
          document.head.appendChild(s);
        })();
      ''');
    }

    // The fix ships in ReaderContentStyles.css itself (forced ruby/rt/rp
    // display). Injecting the REAL reader CSS LAST — exactly how the reader
    // injects its style tag before </head>, after the book stylesheets — must
    // therefore defend the ruby layout against the book's display override.

    // Variant M: worst book override + real reader CSS last (must realign).
    await injectCss(readerCss);
    await injectBookCss('ruby,rt{display:inline-block!important;}');
    await injectFixLast(readerCss);
    final Map<String, dynamic> fixed1 =
        await probe('FIX: ruby,rt{display:inline-block} + reader CSS last');

    // Variant N: rt-only override + real reader CSS last.
    await injectBookCss('rt{display:inline-block!important;}');
    await injectFixLast(readerCss);
    final Map<String, dynamic> fixed2 =
        await probe('FIX: rt{display:inline-block} + reader CSS last');

    // Clear the book + fix stylesheets for the clean-control assertion below.
    await injectFixLast('');
    await injectBookCss('');
    await injectCss(readerCss);
    await probe('CONTROL: reader CSS, no book override');

    // ── Assertions on the primary (FULL continuous) measurement ──
    // Every annotation must sit to the right of its base and stay vertically
    // aligned (|dyRatio| < 0.35 ≈ within a third of a base glyph). A dyRatio
    // near or above 0.5 is the reported「假名塌到汉字之间」misplacement.
    final List<String> failures = <String>[];
    for (final String key in <String>['mono', 'single', 'mono2']) {
      final Map<String, dynamic>? g = full[key] as Map<String, dynamic>?;
      if (g == null) continue;
      for (final dynamic p in (g['pairs'] as List<dynamic>)) {
        final Map<String, dynamic> pr = p as Map<String, dynamic>;
        final num? dyRatio = pr['dyRatio'] as num?;
        final bool rtRight = pr['rtRightOfBase'] == true;
        final Map<String, dynamic>? base = pr['base'] as Map<String, dynamic>?;
        final String rtText =
            (pr['rt'] as Map<String, dynamic>)['text'].toString();
        if (dyRatio == null) continue;
        if (!rtRight) {
          failures
              .add('$key rt="$rtText": not right of base (dx=${_f(pr['dx'])})');
        }
        if (dyRatio.abs() >= 0.35) {
          failures.add('$key base="${base?['text']}" rt="$rtText": '
              'annotation shifted along column dyRatio=${_f(dyRatio)}');
        }
      }
    }
    debugPrint('[ruby-probe] failures=${failures.length}: $failures');
    expect(failures, isEmpty,
        reason: 'vertical-rl furigana misaligned: ${failures.join("; ")}');

    // The candidate fix must restore alignment even when the book breaks the
    // ruby display: every measured pair aligns (|dyRatio| < 0.35) and stays to
    // the right of its base.
    List<String> checkAligned(Map<String, dynamic> m, String tag) {
      final List<String> bad = <String>[];
      for (final String key in <String>['mono', 'single', 'mono2']) {
        final Map<String, dynamic>? g = m[key] as Map<String, dynamic>?;
        if (g == null) continue;
        for (final dynamic p in (g['pairs'] as List<dynamic>)) {
          final Map<String, dynamic> pr = p as Map<String, dynamic>;
          final num? dyRatio = pr['dyRatio'] as num?;
          if (dyRatio == null) continue;
          final String rtText =
              (pr['rt'] as Map<String, dynamic>)['text'].toString();
          if (pr['rtRightOfBase'] != true || dyRatio.abs() >= 0.35) {
            bad.add('$tag $key rt="$rtText" dyRatio=${_f(dyRatio)} '
                'rtRight=${pr['rtRightOfBase']}');
          }
        }
      }
      return bad;
    }

    final List<String> fixFailures = <String>[
      ...checkAligned(fixed1, 'FIX-M'),
      ...checkAligned(fixed2, 'FIX-N'),
    ];
    debugPrint('[ruby-probe] fixFailures=${fixFailures.length}: $fixFailures');
    expect(fixFailures, isEmpty,
        reason:
            'candidate ruby-display fix failed to restore vertical furigana '
            'alignment against book display override: ${fixFailures.join("; ")}');
  });
}

String _f(dynamic v) {
  if (v is num) return v.toStringAsFixed(2);
  return v.toString();
}
