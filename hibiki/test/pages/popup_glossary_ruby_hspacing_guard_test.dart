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

  // BUG-846: the compaction above (absolute rt → base box collapses to the kanji
  // width) reserves the vertical axis via padding-top but reserves NOTHING on the
  // horizontal axis, so a reading wider than its kanji (明鏡-style 逐字 ruby, e.g.
  // 教<rt>きょう</rt>法<rt>ほう</rt>) overhangs and collides with the next base's
  // reading — the "few px spill" BUG-345 accepted became a full overlap for
  // >=3-kana readings. The fix injects an in-flow, zero-height twin of the
  // reading (.ruby-reserve) into each .ruby-unit so the unit's shrink-to-fit
  // width grows to max(kanji, reading); the base centres under its reading and
  // adjacent readings never overlap. Ruby geometry can't render headless, so
  // guard both halves of the contract in source.
  test(
      'popup.css reserves horizontal room via an in-flow, zero-height '
      '.ruby-reserve sized to the reading (BUG-846)', () {
    final RegExp reserveRule = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*\.ruby-reserve\s*\{([^}]*)\}',
    );
    final RegExpMatch? match = reserveRule.firstMatch(css);
    expect(match, isNotNull,
        reason: 'popup.css must scope a .ruby-reserve block to the glossary '
            'surfaces — that in-flow twin is what widens the per-base unit to '
            'the reading width so adjacent furigana cannot overlap (BUG-846)');
    final String body = match!.group(1)!;
    expect(RegExp(r'width\s*:\s*(-webkit-)?max-content').hasMatch(body), isTrue,
        reason: '.ruby-reserve must be width:max-content so it shrink-wraps to '
            'the reading and drives the unit width (BUG-846)');
    expect(RegExp(r'height\s*:\s*0\b').hasMatch(body), isTrue,
        reason: '.ruby-reserve must be height:0 so it reserves horizontal room '
            'WITHOUT shifting the base off its baseline — the BUG-108/363 '
            'vertical reserve must stay unchanged (BUG-846)');
    expect(RegExp(r'font-size\s*:\s*0?\.5em').hasMatch(body), isTrue,
        reason:
            '.ruby-reserve must match the rt font-size (0.5em) so its width '
            'equals the rendered reading width (BUG-846)');
  });

  test(
      'postProcessRuby injects a .ruby-reserve twin of the reading into each '
      'unit, hidden from selection (BUG-846)', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    expect(js.contains("className = 'ruby-reserve'"), isTrue,
        reason: 'postProcessRuby must create the .ruby-reserve twin (BUG-846)');
    expect(js.contains('reserve.textContent = sib.textContent'), isTrue,
        reason:
            'the reserve must copy the reading text so its width equals the '
            'rt width (BUG-846)');
    expect(js.contains("setAttribute('aria-hidden', 'true')"), isTrue,
        reason:
            'the reserve must be aria-hidden so it never affects ruby lookup '
            'selection or accessibility (BUG-110/123/125/129)');
  });
}
