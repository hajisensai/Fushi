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
// line above (BUG-363). The reserve became an em padding-top with the <rt>
// anchored to top:0 — one element, one em chain, scales cleanly under any zoom.
//
// BUG-722 then moved the reserve from the bare <ruby> onto the per-base
// <span class="ruby-unit"> (so each rt anchors to its own kanji instead of
// stretching across a multi-kanji word). The reserve + anchor therefore now
// live on `.ruby-unit`; this guard tracks them there.
//
// Ruby geometry can't render headless in a WebView, so guard the CSS rules'
// presence. The headless-Chromium repro proved the old scheme overlapped the
// line above by -7.5/-11.25/-22.5px at zoom 1/1.5/3, while the new scheme keeps
// rtTop flush with (>=0 above) the previous line's bottom at every zoom.
void main() {
  final String css = File('assets/popup/popup.css').readAsStringSync();

  final RegExp glossaryRubyUnitRule = RegExp(
    r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*\.ruby-unit\s*\{([^}]*)\}',
  );
  // BUG-1487: the absolute anchor moved off <rt> onto the neutral
  // `.ruby-rt` wrapper (WebKit force-resets `position` to static on <rt>, so
  // the whole scheme was dead on iOS/macOS). The invariant this guard protects
  // — the annotation is absolutely positioned at the unit's top:0, inside the em
  // padding reserve — is unchanged; only its carrier moved.
  final RegExp glossaryRtBoxRule = RegExp(
    r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*\.ruby-rt\s*\{([^}]*)\}',
  );
  final RegExp glossaryRtRule = RegExp(
    r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*rt\s*\{([^}]*)\}',
  );

  test(
      'glossary .ruby-unit reserves vertical room with an em padding-top, not '
      'the fragile line-height:2 leading (BUG-108 / BUG-363)', () {
    final RegExpMatch? match = glossaryRubyUnitRule.firstMatch(css);
    expect(match, isNotNull,
        reason: 'popup.css must scope a .ruby-unit block to the glossary '
            'surfaces (.glossary-group / .glossary-content)');
    final String body = match!.group(1)!;
    // The reserve must be an em-relative padding-top on the unit itself, so it
    // scales 1:1 with the popup zoom and never borrows the line box.
    expect(
      RegExp(r'padding-top\s*:\s*[\d.]+em').hasMatch(body),
      isTrue,
      reason: 'glossary .ruby-unit must reserve furigana room with an '
          'em-relative padding-top (intrinsic + zoom-immune), not the implicit '
          'line box leading (BUG-363 / TODO-643)',
    );
    // line-height:1 keeps the unit from re-borrowing leading; the absolute <rt>
    // lives in the padding instead.
    expect(
      RegExp(r'line-height\s*:\s*1\b').hasMatch(body),
      isTrue,
      reason: 'glossary .ruby-unit must use line-height:1 so the vertical '
          'reserve comes only from the em padding-top, not the line box (BUG-363)',
    );
    // The old fragile reserve must be gone.
    expect(
      RegExp(r'line-height\s*:\s*2\b').hasMatch(body),
      isFalse,
      reason: 'glossary .ruby-unit must NOT use the old line-height:2 leading '
          'reserve — it drifts under zoom (BUG-363)',
    );
  });

  test(
      'glossary reading box anchors to the unit top (top:0), not bottom:100% '
      'which drifts under zoom (BUG-363)', () {
    final RegExpMatch? match = glossaryRtBoxRule.firstMatch(css);
    expect(match, isNotNull,
        reason: 'popup.css must scope a .ruby-rt block to the glossary '
            'surfaces — that span is the positioned annotation box (BUG-1487)');
    final String body = match!.group(1)!;
    expect(
      RegExp(r'position\s*:\s*absolute').hasMatch(body),
      isTrue,
      reason: 'the glossary reading box stays out of the inline flow so it '
          'cannot widen the ruby base box (BUG-345)',
    );
    expect(
      RegExp(r'top\s*:\s*0\b').hasMatch(body),
      isTrue,
      reason: 'the glossary reading box must anchor to the .ruby-unit top '
          '(top:0), inside the em padding-top reserve, so its position scales '
          'cleanly with zoom (BUG-363)',
    );
    expect(
      RegExp(r'bottom\s*:\s*100%').hasMatch(body),
      isFalse,
      reason: 'the glossary reading box must NOT use bottom:100% — that '
          'percentage resolves against a per-fragment-rounded line box and '
          'drifts under zoom (BUG-363)',
    );
  });

  test(
      'the absolute anchor is NOT declared on <rt> itself — WebKit drops it '
      '(BUG-1487)', () {
    final RegExpMatch? match = glossaryRtRule.firstMatch(css);
    expect(match, isNotNull,
        reason: 'popup.css must still scope an rt block to the glossary '
            'surfaces (it carries the fallback font-size / line-height)');
    final String body = match!.group(1)!;
    // Measured on a real WKWebView (macOS 15.7 + iOS 18.6): WebKit resets
    // `position` to static on <rt> at the renderer level, so ANY positioning
    // declared here is silently dropped on both Apple platforms while Blink
    // honours it — the furigana then rendered inline beside its kanji. Forcing
    // `display: block` does NOT help (measured: display becomes block, position
    // stays static, and the reading drops BELOW the kanji instead).
    expect(
      RegExp(r'position\s*:').hasMatch(body),
      isFalse,
      reason: 'glossary <rt> must not declare `position` — WebKit force-resets '
          'it to static, so the anchor belongs on the neutral .ruby-rt span '
          '(BUG-1487)',
    );
    expect(
      RegExp(r'\b(top|left|right|bottom)\s*:').hasMatch(body),
      isFalse,
      reason: 'glossary <rt> must not declare box offsets — they only mean '
          'anything on a positioned box, and <rt> can never be one in WebKit '
          '(BUG-1487)',
    );
  });
}
