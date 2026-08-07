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

/// TODO-1308 (user re-report) — enumerate REAL-WORLD ruby DOM markup variants
/// on the real in-app WebView2 and measure, per variant, where every <rt>
/// annotation lands relative to its base glyphs in vertical-rl under the REAL
/// reader CSS.
///
/// The user screenshot (貫禄: かん sitting INLINE between 貫 and 禄 in the base
/// column while ろ/く render in the annotation lane) implies a ruby DOM shape
/// the reader CSS does not own yet: a uniform book-CSS display override would
/// move ALL annotations the same way, so the half-inline/half-lane split must
/// come from DOM structure (rb/rtc/trailing-rt/nested forms) interacting with
/// Blink's anonymous ruby box fixup.
///
/// Violation signature, measured per form (baseline run on this machine's
/// WebView2 reproduced the screenshot via the rtc forms — the annotation gets
/// wrapped in an ANONYMOUS ruby at its flow position because Blink has no
/// rb/rtc support and our bare rt{display:ruby-text!important} hits rtc-nested
/// rt too):
///   * the two base glyphs are pushed apart (annotation consumed a character
///     slot in the base flow — かん inline between 貫/禄), or
///   * an <rt> lands vertically outside the word extent for forms with no
///     inherent trailing annotation (ろく below the word), or
///   * an <rt> intrudes the base column x-range (>0.6) / sits on the wrong
///     side (left of the base centers in vertical-rl).
///
/// Run (from fushi/):
///   tool\run_windows_itest.ps1 integration_test\reader_vertical_ruby_forms_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // DOM forms seen in real Japanese EPUBs. Every form annotates 貫禄 with
  // かん/ろく (or かんろく) so the same measurement applies to all of them.
  const Map<String, String> forms = <String, String>{
    // Interleaved mono ruby (modern EPUB3 / AozoraEpub3 output) — control.
    'mono': '<ruby>貫<rt>かん</rt>禄<rt>ろく</rt></ruby>',
    // One <ruby> per base char (InDesign-style output) — control.
    'sep': '<ruby>貫<rt>かん</rt></ruby><ruby>禄<rt>ろく</rt></ruby>',
    // Group ruby — control.
    'group': '<ruby>貫禄<rt>かんろく</rt></ruby>',
    // Group base with TWO trailing rt (annotations after all base text).
    'trail_rt': '<ruby>貫禄<rt>かん</rt><rt>ろく</rt></ruby>',
    // W3C/JIS <rb> interleaved.
    'rb_inter': '<ruby><rb>貫</rb><rt>かん</rt><rb>禄</rb><rt>ろく</rt></ruby>',
    // <rb> interleaved with <rp> fallback parens.
    'rb_rp_inter':
        '<ruby><rb>貫</rb><rp>（</rp><rt>かん</rt><rp>）</rp><rb>禄</rb><rp>（</rp><rt>ろく</rt><rp>）</rp></ruby>',
    // JIS form: all <rb> first, then all <rt> (no rtc).
    'rb_trail': '<ruby><rb>貫</rb><rb>禄</rb><rt>かん</rt><rt>ろく</rt></ruby>',
    // JIS form: all <rb> first, then <rtc> containing the <rt>s.
    'rb_rtc':
        '<ruby><rb>貫</rb><rb>禄</rb><rtc><rt>かん</rt><rt>ろく</rt></rtc></ruby>',
    // Per-base <rtc>.
    'rtc_per':
        '<ruby><rb>貫</rb><rtc><rt>かん</rt></rtc><rb>禄</rb><rtc><rt>ろく</rt></rtc></ruby>',
    // Nested ruby (jukugo grouping wrapper).
    'nested': '<ruby><ruby>貫<rt>かん</rt></ruby><ruby>禄<rt>ろく</rt></ruby></ruby>',
    // rt content wrapped in a span.
    'span_rt':
        '<ruby>貫<rt><span>かん</span></rt>禄<rt><span>ろく</span></rt></ruby>',
    // Loose <rt> with NO <ruby> wrapper at all.
    'loose_rt': '貫<rt>かん</rt>禄<rt>ろく</rt>',
    // Double annotation: inline rt + rtc level.
    'double_rtc': '<ruby>貫禄<rt>かん</rt><rtc><rt>ろく</rt></rtc></ruby>',
  };

  final StringBuffer body = StringBuffer();
  forms.forEach((String key, String ruby) {
    body.write('<p id="f_$key">それは$rubyのある人だった。'
        'ずっと昔から続いている物語であることは間違いない。</p>');
  });
  final String html = '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '</head><body>$body</body></html>';

  final String idsJson =
      jsonEncode(forms.keys.map((String k) => 'f_$k').toList(growable: false));

  // Generic measurement: per form, the rects of the base glyphs 貫/禄 (base
  // text = text nodes NOT inside rt/rp/rtc) and of every <rt>, plus computed
  // display of ruby/rt/rb/rtc, plus CSS.supports for the ruby display values.
  final String probeJs = '''
(function () {
  function rectObj(r) {
    return { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width,
             h: r.height, cx: (r.left + r.right) / 2, cy: (r.top + r.bottom) / 2 };
  }
  function charRect(root, ch) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        var e = n.parentElement;
        while (e && e !== root) {
          var tag = e.tagName;
          if (tag === 'RT' || tag === 'RP' || tag === 'RTC') {
            return NodeFilter.FILTER_REJECT;
          }
          e = e.parentElement;
        }
        return n.textContent.indexOf(ch) >= 0
            ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
      }
    });
    var n = walker.nextNode();
    if (!n) return null;
    var i = n.textContent.indexOf(ch);
    var range = document.createRange();
    range.setStart(n, i);
    range.setEnd(n, i + 1);
    return rectObj(range.getBoundingClientRect());
  }
  function measureForm(id) {
    var el = document.getElementById(id);
    if (!el) return null;
    var out = { kan: charRect(el, '貫'), roku: charRect(el, '禄'), rts: [] };
    var rtNodes = el.querySelectorAll('rt');
    for (var i = 0; i < rtNodes.length; i++) {
      var rt = rtNodes[i];
      out.rts.push({ text: rt.textContent,
                     rect: rectObj(rt.getBoundingClientRect()),
                     display: getComputedStyle(rt).display });
    }
    var ruby = el.querySelector('ruby');
    if (ruby) {
      out.rubyRect = rectObj(ruby.getBoundingClientRect());
      out.rubyDisplay = getComputedStyle(ruby).display;
    }
    var rb = el.querySelector('rb');
    if (rb) out.rbDisplay = getComputedStyle(rb).display;
    var rtc = el.querySelector('rtc');
    if (rtc) {
      out.rtcDisplay = getComputedStyle(rtc).display;
      out.rtcRect = rectObj(rtc.getBoundingClientRect());
    }
    return out;
  }
  var ids = $idsJson;
  var out = {
    writingMode: getComputedStyle(document.body).writingMode,
    supports: {
      ruby: CSS.supports('display', 'ruby'),
      rubyText: CSS.supports('display', 'ruby-text'),
      rubyBase: CSS.supports('display', 'ruby-base'),
      rubyTextContainer: CSS.supports('display', 'ruby-text-container'),
      rubyBaseContainer: CSS.supports('display', 'ruby-base-container'),
      contents: CSS.supports('display', 'contents')
    },
    forms: {}
  };
  for (var i = 0; i < ids.length; i++) out.forms[ids[i]] = measureForm(ids[i]);
  return JSON.stringify(out);
})();
''';

  testWidgets('vertical-rl ruby DOM form matrix under real reader CSS',
      (WidgetTester tester) async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode('vertical-rl');
    await settings.setViewMode('continuous');

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

    Future<void> injectStyle(String id, String css) async {
      await controller.evaluateJavascript(source: '''
        (function () {
          var s = document.getElementById(${jsonEncode(id)});
          if (!s) { s = document.createElement('style');
            s.id = ${jsonEncode(id)}; document.head.appendChild(s); }
          s.textContent = ${jsonEncode(css)};
        })();
      ''');
    }

    Future<Map<String, dynamic>> probe(String label) async {
      await controller.evaluateJavascript(
          source: 'void document.body.offsetHeight;');
      await tester.pump(const Duration(milliseconds: 400));
      final Object? raw = await controller.evaluateJavascript(source: probeJs);
      final Map<String, dynamic> m =
          jsonDecode(raw.toString()) as Map<String, dynamic>;
      debugPrint('[ruby-forms] ===== $label =====');
      debugPrint('[ruby-forms] writingMode=${m['writingMode']} '
          'supports=${jsonEncode(m['supports'])}');
      final Map<String, dynamic> f = m['forms'] as Map<String, dynamic>;
      for (final String key in f.keys) {
        final Map<String, dynamic>? g = f[key] as Map<String, dynamic>?;
        if (g == null) {
          debugPrint('[ruby-forms] $key: MISSING');
          continue;
        }
        debugPrint('[ruby-forms] $key: ${_classify(g)}');
      }
      return m;
    }

    // Phase 1: the REAL reader CSS exactly as injected in production
    // (reader style LAST in <head>). No book CSS: these DOM forms ship in real
    // books with no or harmless styles, so a broken form here is a reader bug.
    final String readerCss = ReaderContentStyles.css(settings: settings);
    await injectStyle('fushi-reader-style', readerCss);
    final Map<String, dynamic> current = await probe('READER CSS (current)');

    // Phase 2: book CSS present + reader CSS last (real cascade order),
    // for the forms that carry rb/rtc (books style them like legacy WebKit).
    await injectStyle('hibiki-book-style', '''
      rb { display: inline-block; }
      rtc { display: block; }
      ruby rt { display: inline-block; }
    ''');
    // Re-append reader style so it stays last (mirrors production order).
    await controller.evaluateJavascript(source: '''
      (function () {
        var s = document.getElementById('fushi-reader-style');
        if (s) document.head.appendChild(s);
      })();
    ''');
    final Map<String, dynamic> withBook =
        await probe('BOOK rb/rtc/rt overrides + reader CSS last');
    await injectStyle('hibiki-book-style', '');

    // Assertions: under the current reader CSS every form must keep EVERY
    // annotation out of the base column and on the correct side (right of the
    // base glyphs' centers) — the user screenshot is exactly a violation
    // (かん intruding the base column between 貫 and 禄).
    final List<String> broken = <String>[
      ..._violations(current, 'READER'),
      ..._violations(withBook, 'BOOK+READER'),
    ];
    debugPrint('[ruby-forms] violations=${broken.length}');
    for (final String v in broken) {
      debugPrint('[ruby-forms] VIOLATION: $v');
    }
    expect(broken, isEmpty,
        reason: 'ruby annotations out of lane:\n${broken.join('\n')}');
  });
}

/// Human-readable per-form classification line.
String _classify(Map<String, dynamic> g) {
  final Map<String, dynamic>? kan = g['kan'] as Map<String, dynamic>?;
  final Map<String, dynamic>? roku = g['roku'] as Map<String, dynamic>?;
  final List<dynamic> rts = g['rts'] as List<dynamic>? ?? <dynamic>[];
  final StringBuffer sb = StringBuffer();
  sb.write('ruby=${g['rubyDisplay'] ?? '-'} rb=${g['rbDisplay'] ?? '-'} '
      'rtc=${g['rtcDisplay'] ?? '-'} ');
  if (kan == null || roku == null) return '$sb(no base rects)';
  final num baseL = _min(kan['l'] as num, roku['l'] as num);
  final num baseR = _max(kan['r'] as num, roku['r'] as num);
  for (final dynamic p in rts) {
    final Map<String, dynamic> rt = p as Map<String, dynamic>;
    final Map<String, dynamic> r = rt['rect'] as Map<String, dynamic>;
    sb.write(
        '| "${rt['text']}"(${rt['display']}) ${_geom(r, kan, roku, baseL, baseR)} ');
  }
  return sb.toString();
}

String _geom(Map<String, dynamic> r, Map<String, dynamic> kan,
    Map<String, dynamic> roku, num baseL, num baseR) {
  final num overlap =
      _max(0, _min(r['r'] as num, baseR) - _max(r['l'] as num, baseL));
  final num w = r['w'] as num;
  final double intrude = w > 0 ? (overlap / w).toDouble() : 0.0;
  final bool inGap = (r['cy'] as num) > (kan['b'] as num) &&
      (r['cy'] as num) < (roku['t'] as num);
  final bool inLane = (r['l'] as num) >= baseR - 1;
  return 'x=${(r['l'] as num).toStringAsFixed(0)}..${(r['r'] as num).toStringAsFixed(0)} '
      'cy=${(r['cy'] as num).toStringAsFixed(0)} intrudeX=${intrude.toStringAsFixed(2)} '
      'gap=$inGap lane=$inLane';
}

/// Forms whose annotation boxes are consecutive (trailing rt/rtc after all
/// base content): CSS ruby pairing inherently gives the 2nd annotation an
/// empty trailing base BELOW the word, so the word-extent check does not apply
/// (that is standard engine behaviour, annotation still stays in the lane).
const Set<String> _trailingAnnotationForms = <String>{
  'f_trail_rt',
  'f_rb_trail',
  'f_double_rtc',
};

/// A violation = base glyphs pushed apart by an annotation slot (>0.5 glyph),
/// an annotation vertically outside the word extent (for forms without an
/// inherent trailing annotation), an annotation intruding the base column
/// x-range (>0.6), or one sitting left of both base glyphs (wrong side in
/// vertical-rl).
List<String> _violations(Map<String, dynamic> m, String tag) {
  final List<String> out = <String>[];
  final Map<String, dynamic> f = m['forms'] as Map<String, dynamic>;
  for (final String key in f.keys) {
    if (key == 'f_loose_rt') continue; // no <ruby> wrapper: no defined lane
    final Map<String, dynamic>? g = f[key] as Map<String, dynamic>?;
    if (g == null) continue;
    final Map<String, dynamic>? kan = g['kan'] as Map<String, dynamic>?;
    final Map<String, dynamic>? roku = g['roku'] as Map<String, dynamic>?;
    if (kan == null || roku == null) continue;
    final num baseL = _min(kan['l'] as num, roku['l'] as num);
    final num baseR = _max(kan['r'] as num, roku['r'] as num);
    final num baseCx = _max(kan['cx'] as num, roku['cx'] as num);
    final num glyphH = kan['h'] as num;
    // 貫/禄 are adjacent characters: any gap ≥ half a glyph means an
    // annotation consumed a character slot in the base flow (the screenshot).
    final num basesApart = (roku['t'] as num) - (kan['b'] as num);
    if (basesApart > glyphH * 0.5) {
      out.add(
          '$tag $key: bases pushed apart by ${basesApart.toStringAsFixed(0)}px '
          '(annotation occupies a base-flow slot)');
    }
    for (final dynamic p in g['rts'] as List<dynamic>? ?? <dynamic>[]) {
      final Map<String, dynamic> rt = p as Map<String, dynamic>;
      final Map<String, dynamic> r = rt['rect'] as Map<String, dynamic>;
      final num w = r['w'] as num;
      if (w <= 0) continue; // hidden
      final num overlap =
          _max(0, _min(r['r'] as num, baseR) - _max(r['l'] as num, baseL));
      final double intrude = (overlap / w).toDouble();
      final bool wrongSide = (r['cx'] as num) <= baseCx;
      final bool outsideExtent = !_trailingAnnotationForms.contains(key) &&
          ((r['cy'] as num) < (kan['t'] as num) - glyphH * 0.6 ||
              (r['cy'] as num) > (roku['b'] as num) + glyphH * 0.6);
      if (intrude > 0.6 || wrongSide || outsideExtent) {
        out.add(
            '$tag $key rt="${rt['text']}" intrudeX=${intrude.toStringAsFixed(2)} '
            'wrongSide=$wrongSide outsideExtent=$outsideExtent '
            '${_geom(r, kan, roku, baseL, baseR)}');
      }
    }
  }
  return out;
}

num _min(num a, num b) => a < b ? a : b;
num _max(num a, num b) => a > b ? a : b;
