import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-345 / TODO-620: in the dictionary popup, glossary bodies that carry
// per-character furigana (明鏡-style 逐字 ruby, e.g. 顔(かお)を洗(あら)う…) rendered
// with ragged horizontal spacing. popup.js's postProcessRuby replaces each
// <ruby>'s base text node with a bare <span> so the ruby text stays
// selectable (BUG-110/123/125/129 must not regress), but that <span> is still a
// ruby base box: Blink sizes every ruby base box to max(base, rt). With
// rt{font-size:0.5em}, a reading of >=3 kana is wider than its 1em kanji, so
// each ruby base is stretched to its own annotation width and the line goes
// ragged. The fix takes the <rt> out of the inline flow (position:absolute) so
// it no longer widens the base box, while keeping the furigana centred above
// the kanji.
//
// BUG-363 / TODO-643 then made the vertical reserve zoom-immune: the old
// reserve borrowed ruby{line-height:2} half-leading and anchored the <rt> with
// bottom:100% (a percentage against a per-fragment-rounded, neighbour-dependent
// line box), which drifted under the popup's content zoom. The reserve is now
// an em-relative padding-top on the ruby element with the <rt> at top:0 — both
// invariants live in the same rule pair and must stay together.
//
// Ruby geometry can't render headless in a WebView, so guard the CSS rules'
// presence (the headless-Chromium repro proved horizontal spread 18.25px -> 0px
// and the zoom vertical overlap -22.5px -> 0.00px). The Windows popup inlines
// this same popup.css via _winCss, so one guard covers all platforms.
void main() {
  final String css = File('assets/popup/popup.css').readAsStringSync();

  test(
      'glossary ruby is laid out as inline-block + relative so rt cannot '
      'stretch the base box (BUG-345)', () {
    final RegExp rubyRule = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*ruby\s*\{([^}]*)\}',
    );
    final RegExpMatch? match = rubyRule.firstMatch(css);
    expect(
      match,
      isNotNull,
      reason: 'popup.css must scope a ruby block to the glossary surfaces '
          '(.glossary-group / .glossary-content)',
    );
    final String body = match!.group(1)!;
    expect(
      RegExp(r'display\s*:\s*inline-block').hasMatch(body),
      isTrue,
      reason: 'glossary <ruby> must be display:inline-block so the base box '
          'collapses to the kanji width instead of being stretched to the '
          'rt width (BUG-345)',
    );
    expect(
      RegExp(r'position\s*:\s*relative').hasMatch(body),
      isTrue,
      reason: 'glossary <ruby> must be position:relative so the absolutely '
          'positioned <rt> anchors to its own base (BUG-345)',
    );
  });

  test(
      'glossary rt is taken out of the inline flow (absolute, anchored to the '
      'ruby top) so it cannot widen the base box (BUG-345 / BUG-363)', () {
    final RegExp rtRule = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*rt\s*\{([^}]*)\}',
    );
    final RegExpMatch? match = rtRule.firstMatch(css);
    expect(
      match,
      isNotNull,
      reason: 'popup.css must scope an rt block to the glossary surfaces',
    );
    final String body = match!.group(1)!;
    expect(
      RegExp(r'position\s*:\s*absolute').hasMatch(body),
      isTrue,
      reason: 'glossary <rt> must be position:absolute so it leaves the inline '
          'flow and stops dictating the ruby base box width (BUG-345)',
    );
    expect(
      RegExp(r'top\s*:\s*0\b').hasMatch(body),
      isTrue,
      reason: 'glossary <rt> must anchor to the ruby top (top:0) inside the em '
          'padding-top reserve, so its position scales cleanly with the popup '
          'zoom instead of drifting (BUG-363)',
    );
  });

  test(
      'the vertical furigana reserve is an em padding-top on the ruby, not the '
      'old line-height:2 leading (BUG-108 reserve preserved, zoom-immune for '
      'BUG-363)', () {
    final RegExp rubyRule = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*ruby\s*\{([^}]*)\}',
    );
    final String body = rubyRule.firstMatch(css)!.group(1)!;
    expect(
      RegExp(r'padding-top\s*:\s*[\d.]+em').hasMatch(body),
      isTrue,
      reason: 'glossary <ruby> must reserve furigana room with an em-relative '
          'padding-top — the absolutely positioned furigana relies on that '
          'reserve to clear the line above, and the em unit keeps it correct '
          'under any popup zoom (BUG-108 reserve + BUG-363 zoom-immunity)',
    );
  });
}
