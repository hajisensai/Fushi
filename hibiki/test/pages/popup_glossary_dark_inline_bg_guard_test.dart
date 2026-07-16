import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-847: dictionary usage tags (明鏡 の「使い方」用法タグ等) arrive as Yomitan
// structured content carrying an inline background-color designed for a WHITE
// page (a pale pastel). popup.js's setStructuredContentElementStyle passes that
// background straight through to element.style with no dark-mode treatment, so
// in dark mode the pale chip floats on the black surface and the inherited light
// body text on it is illegible.
//
// Fix: a dark-mode-only rule re-tones any dict-provided inline background on a
// TEXT structured-content node (`[class^="gloss-sc-"]`) to the app's neutral
// glossary-tag chip and restores legible text. It must:
//   * be scoped to dark mode only (light mode reads fine on white);
//   * target the text structured-content class prefix, NOT the image mask
//     (.gloss-image-background also carries an inline background-color and must
//     stay untouched — inverting it would break dictionary images);
//   * use !important, because an inline style otherwise always wins.
//
// Dark inline colours can't render in a headless Flutter test, so guard the rule
// in source. The extension mirror is regenerated from popup.css by
// generate-content-css.mjs, so also assert the scoped rule reached content.css.
void main() {
  final String css = File('assets/popup/popup.css').readAsStringSync();

  final RegExp darkTagRule = RegExp(
    r'html\[data-theme="dark"\][^{]*\[class\^="gloss-sc-"\]\[style\*="background"\]\s*\{([^}]*)\}',
  );

  test(
      'popup.css neutralizes dict inline-coloured text tags in dark mode only '
      '(BUG-847)', () {
    final RegExpMatch? match = darkTagRule.firstMatch(css);
    expect(match, isNotNull,
        reason: 'popup.css must carry a dark-mode-only rule scoped to '
            '[class^="gloss-sc-"][style*="background"] that re-tones dictionary '
            'inline background colours so usage tags stay legible on the black '
            'surface (BUG-847)');
    final String body = match!.group(1)!;
    expect(
        RegExp(r'background-color\s*:[^;]*!important').hasMatch(body), isTrue,
        reason:
            'the rule must override the inline background with !important — '
            'an inline style otherwise wins the cascade (BUG-847)');
    expect(RegExp(r'color\s*:[^;]*!important').hasMatch(body), isTrue,
        reason: 'the rule must also restore a legible text colour so the '
            'inherited light body text is not washed out on the chip (BUG-847)');
  });

  test(
      'the dark tag rule targets the text class prefix, never the image mask '
      '(BUG-847)', () {
    // The image mask (.gloss-image-background) also carries an inline
    // background-color:currentColor; the rule must not match it.
    final RegExpMatch match = darkTagRule.firstMatch(css)!;
    expect(match.group(0)!.contains('gloss-image'), isFalse,
        reason:
            'the dark tag rule must be scoped to [class^="gloss-sc-"] only, '
            'so the image mask (.gloss-image-background) is never re-toned '
            '(BUG-847)');
  });

  test(
      'the scoped dark tag rule reached both extension content.css mirrors '
      '(BUG-847)', () {
    for (final String path in const <String>[
      'assets/browser_extension/vendor/content.css',
      '../tools/browser-extension/vendor/content.css',
    ]) {
      final String content = File(path).readAsStringSync();
      expect(
        content.contains('[data-theme="dark"]') &&
            content.contains('[class^="gloss-sc-"][style*="background"]'),
        isTrue,
        reason: '$path is missing the re-rooted dark tag rule — re-run '
            'node tools/browser-extension/scripts/generate-content-css.mjs '
            '(BUG-847)',
      );
    }
  });
}
