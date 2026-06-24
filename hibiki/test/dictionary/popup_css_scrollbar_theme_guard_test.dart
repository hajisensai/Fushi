// TODO-789 static guard: the shared dictionary-popup WebView surface (used by
// the lookup overlay AND the home lookup search page) must theme its scrollbar
// the same way the reader body and lyrics mode do — otherwise desktop WebView2
// shows its default arrowed grey scrollbar regardless of the app theme.
//
// Root cause: assets/popup/popup.css had no body/html-level scrollbar rules at
// all (only `.expression-scroll::-webkit-scrollbar{display:none}`, which hides
// an unrelated horizontal expression bar). reader_content_styles.dart and
// lyrics_mode_html.dart already carry the full rule set; popup.css was the only
// themed WebView surface missing it.
//
// Layer rationale: the scrollbar appearance is pure CSS in a static asset, so a
// file-text scan is the strongest landable guard — it pins the exact rules and
// the per-theme `color-scheme` (WebView2's Fluent overlay scrollbar ignores
// ::-webkit-scrollbar and only follows the UA color-scheme).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('popup.css themed scrollbar (TODO-789)', () {
    late final String css;

    setUpAll(() {
      final File file = File('assets/popup/popup.css');
      expect(file.existsSync(), isTrue,
          reason: 'popup.css not found at ${file.absolute.path}');
      css = file.readAsStringSync();
    });

    test('emits webkit scrollbar thumb + standard scrollbar props', () {
      expect(css, contains('::-webkit-scrollbar-thumb'),
          reason: 'scrollbar thumb pseudo-element rule must exist');
      expect(css, contains('::-webkit-scrollbar-track'),
          reason: 'scrollbar track pseudo-element rule must exist');
      expect(css, contains('scrollbar-width: thin;'));
      expect(css, contains('scrollbar-color: var(--text-color) transparent;'),
          reason: 'thumb must reuse the injected --text-color (onSurface)');
    });

    test('thumb colour follows the injected --text-color', () {
      expect(css, contains('background-color: var(--text-color);'),
          reason: 'webkit thumb colour must reuse --text-color, not a literal');
    });

    test('light theme block pins color-scheme: light', () {
      final int lightIdx = css.indexOf('html[data-theme="light"] {');
      expect(lightIdx, greaterThanOrEqualTo(0),
          reason: 'light theme block must exist');
      final int lightBlockEnd = css.indexOf('}', lightIdx);
      final String lightBlock = css.substring(lightIdx, lightBlockEnd);
      expect(lightBlock, contains('color-scheme: light;'),
          reason:
              'WebView2 Fluent overlay scrollbar only follows color-scheme');
    });

    test('dark theme block pins color-scheme: dark', () {
      final int darkIdx = css.indexOf('html[data-theme="dark"] {');
      expect(darkIdx, greaterThanOrEqualTo(0),
          reason: 'dark theme block must exist');
      final int darkBlockEnd = css.indexOf('}', darkIdx);
      final String darkBlock = css.substring(darkIdx, darkBlockEnd);
      expect(darkBlock, contains('color-scheme: dark;'),
          reason:
              'WebView2 Fluent overlay scrollbar only follows color-scheme');
    });
  });
}
