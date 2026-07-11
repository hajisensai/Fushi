import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-345 / TODO-620: in the dictionary popup, glossary bodies that carry
// per-character furigana (明鏡-style 逐字 ruby, e.g. 顔(かお)を洗(あら)う…) rendered
// with ragged horizontal spacing. popup.js's postProcessRuby wraps each
// <ruby>'s base text node in a <span> so the ruby text stays selectable
// (BUG-110/123/125/129 must not regress), but that <span> is still a ruby base
// box: Blink sizes every ruby base box to max(base, rt). With rt{font-size:0.5em}
// a reading of >=3 kana is wider than its 1em kanji, so each base is stretched
// to its own annotation width and the line goes ragged. The fix takes the <rt>
// out of the inline flow (position:absolute) so it no longer widens the base
// box, while keeping the furigana centred above the kanji.
//
// BUG-722 then moved that base box (and the reserve below) from the bare <ruby>
// onto a per-base <span class="ruby-unit">, so the absolutely-positioned <rt>
// anchors to its OWN kanji: a multi-kanji word is one <ruby> with several
// base+<rt> pairs, and anchoring the rt to the whole <ruby> made every rt
// stretch to the full word width and superimpose. So the compaction + reserve
// invariants now live on `.ruby-unit`; the bare `ruby` keeps display:inline-block
// + position:relative only as a fallback anchor.
//
// Ruby geometry can't render headless in a WebView, so guard the CSS rules'
// presence (the headless-Chromium repro proved horizontal spread 18.25px -> 0px
// and the multi-kanji superimposition -40px -> 0px). The Windows popup inlines
// this same popup.css via _winCss, so one guard covers all platforms.
void main() {
  final String css = File('assets/popup/popup.css').readAsStringSync();

  final RegExp rubyUnitRule = RegExp(
    r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*\.ruby-unit\s*\{([^}]*)\}',
  );

  test(
      'per-base .ruby-unit is inline-block + relative so rt cannot stretch the '
      'base box and anchors to its own kanji (BUG-345 / BUG-722)', () {
    final RegExpMatch? match = rubyUnitRule.firstMatch(css);
    expect(
      match,
      isNotNull,
      reason:
          'popup.css must scope a .ruby-unit block to the glossary surfaces '
          '(.glossary-group / .glossary-content) — that per-base box is the '
          'anchor for the absolute <rt> (BUG-722)',
    );
    final String body = match!.group(1)!;
    expect(
      RegExp(r'display\s*:\s*inline-block').hasMatch(body),
      isTrue,
      reason: '.ruby-unit must be display:inline-block so the base box '
          'collapses to the kanji width instead of being stretched to the '
          'rt width (BUG-345)',
    );
    expect(
      RegExp(r'position\s*:\s*relative').hasMatch(body),
      isTrue,
      reason: '.ruby-unit must be position:relative so the absolutely '
          'positioned <rt> anchors to its own kanji, not the full-width '
          '<ruby> — otherwise multi-kanji-word readings superimpose (BUG-722)',
    );
  });

  test(
      'glossary rt is taken out of the inline flow (absolute, anchored to the '
      'unit top) so it cannot widen the base box (BUG-345 / BUG-363)', () {
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
      reason: 'glossary <rt> must anchor to the unit top (top:0) inside the em '
          'padding-top reserve, so its position scales cleanly with the popup '
          'zoom instead of drifting (BUG-363)',
    );
  });

  test(
      'the vertical furigana reserve is an em padding-top on the per-base '
      '.ruby-unit, not the old line-height:2 leading (BUG-108 reserve '
      'preserved, zoom-immune for BUG-363)', () {
    final String body = rubyUnitRule.firstMatch(css)!.group(1)!;
    expect(
      RegExp(r'padding-top\s*:\s*[\d.]+em').hasMatch(body),
      isTrue,
      reason: 'glossary .ruby-unit must reserve furigana room with an '
          'em-relative padding-top — the absolutely positioned furigana relies '
          'on that reserve to clear the line above, and the em unit keeps it '
          'correct under any popup zoom (BUG-108 reserve + BUG-363 zoom-immunity)',
    );
  });
}
