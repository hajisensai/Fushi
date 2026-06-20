import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-108 + BUG-363 (TODO-643): in the dictionary popup, furigana (<ruby>'s
// <rt>) inside a glossary body must reserve vertical room so it never overlaps
// the kanji on the line above — and that reserve must survive the popup's
// content zoom (documentElement.style.zoom, set when the user enlarges the
// dictionary font size / UI scale, see dictionary_popup_webview popupContentZoom).
//
// The original BUG-108 fix borrowed the implicit line box's half-leading via
// ruby{line-height:2} and anchored the <rt> with bottom:100%. That percentage
// resolves against a per-fragment-rounded line box that also depends on the
// PREVIOUS line, so under zoom!=1 the furigana drifted up and collided with the
// line above (BUG-363). The reserve is now intrinsic to the ruby element and
// expressed purely in em (padding-top) with the <rt> anchored to the ruby's own
// top (top:0) — one element, one em chain, scales cleanly under any zoom.
//
// Ruby geometry can't render headless in a WebView, so guard the CSS rules'
// presence. The headless-Chromium repro proved the old scheme overlapped the
// line above by -7.5/-11.25/-22.5px at zoom 1/1.5/3, while the new scheme keeps
// rtTop flush with the previous line's bottom (0.00px) at every zoom.
void main() {
  final String css = File('assets/popup/popup.css').readAsStringSync();

  final RegExp glossaryRubyRule = RegExp(
    r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*ruby\s*\{([^}]*)\}',
  );
  final RegExp glossaryRtRule = RegExp(
    r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*rt\s*\{([^}]*)\}',
  );

  test(
      'glossary ruby reserves vertical room with an em padding-top, not the '
      'fragile line-height:2 leading (BUG-108 / BUG-363)', () {
    final RegExpMatch? match = glossaryRubyRule.firstMatch(css);
    expect(match, isNotNull,
        reason: 'popup.css must scope a ruby block to the glossary surfaces '
            '(.glossary-group / .glossary-content)');
    final String body = match!.group(1)!;
    // The reserve must be an em-relative padding-top on the ruby element itself,
    // so it scales 1:1 with the popup zoom and never borrows the line box.
    expect(
      RegExp(r'padding-top\s*:\s*[\d.]+em').hasMatch(body),
      isTrue,
      reason: 'glossary <ruby> must reserve furigana room with an em-relative '
          'padding-top (intrinsic + zoom-immune), not the implicit line box '
          'leading (BUG-363 / TODO-643)',
    );
    // line-height:1 keeps the ruby from re-borrowing leading; the absolute <rt>
    // lives in the padding instead.
    expect(
      RegExp(r'line-height\s*:\s*1\b').hasMatch(body),
      isTrue,
      reason: 'glossary <ruby> must use line-height:1 so the vertical reserve '
          'comes only from the em padding-top, not the line box (BUG-363)',
    );
    // The old fragile reserve must be gone.
    expect(
      RegExp(r'line-height\s*:\s*2\b').hasMatch(body),
      isFalse,
      reason: 'glossary <ruby> must NOT use the old line-height:2 leading '
          'reserve — it drifts under zoom (BUG-363)',
    );
  });

  test(
      'glossary rt anchors to the ruby top (top:0), not bottom:100% which drifts '
      'under zoom (BUG-363)', () {
    final RegExpMatch? match = glossaryRtRule.firstMatch(css);
    expect(match, isNotNull,
        reason: 'popup.css must scope an rt block to the glossary surfaces');
    final String body = match!.group(1)!;
    expect(
      RegExp(r'position\s*:\s*absolute').hasMatch(body),
      isTrue,
      reason: 'glossary <rt> stays out of the inline flow so it cannot widen '
          'the ruby base box (BUG-345)',
    );
    expect(
      RegExp(r'top\s*:\s*0\b').hasMatch(body),
      isTrue,
      reason: 'glossary <rt> must anchor to the ruby element top (top:0), '
          'inside the em padding-top reserve, so its position scales cleanly '
          'with zoom (BUG-363)',
    );
    expect(
      RegExp(r'bottom\s*:\s*100%').hasMatch(body),
      isFalse,
      reason: 'glossary <rt> must NOT use bottom:100% — that percentage '
          'resolves against a per-fragment-rounded line box and drifts under '
          'zoom (BUG-363)',
    );
  });
}
