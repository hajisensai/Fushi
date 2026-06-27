import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// TODO-094 S5: the lookup popup renders a kanji-dictionary card (onyomi /
// kunyomi / radical / strokes / meanings) above the term entries for a
// single-character lookup. The kanji results live on
// DictionarySearchResult.kanjiResults (populated by S4 at lookup time) and must
// ride the SAME injection path that feeds the popup WebView — no parallel
// channel. This guard locks the wiring:
//   1. dictionary_popup_webview.dart serializes widget.result.kanjiResults onto
//      window.kanjiResults next to window.lookupEntries.
//   2. popup.js builds a kanji card from window.kanjiResults and renders it in
//      renderPopup, using the real HoshiKanjiResult field names.
//
// END-TO-END NOTE: on-device, queryKanji is still empty until the hoshidicts
// native libs are rebuilt with the S3 kanji exports across all 5 platforms, so
// the card will not appear on a real lookup until that rebuild + device verify.
// This static guard + the node behavior tests
// (hibiki/test/utils/misc/popup_asset_behavior_test.js) cover the render
// pipeline that is ready now; they do NOT assert the FFI returns kanji.
void main() {
  group('kanji card data is wired through the popup injection path', () {
    late String injector;

    setUpAll(() {
      // TODO-895: kanji/term serialization + window.* injection moved into the
      // single source of truth popup_settings_injection.dart.
      injector = File(
        'lib/src/pages/implementations/popup_settings_injection.dart',
      ).readAsStringSync();
    });

    test('serializes kanjiResults onto window.kanjiResults', () {
      // Two substrings so `dart format` line-wrapping the chained `.map(...)`
      // in the injector source cannot break the guard, while still proving both
      // halves: data comes from the SAME DictionarySearchResult (no parallel
      // channel) and is serialized via the typed HoshiKanjiResult.toMap.
      expect(
        injector,
        contains('result.kanjiResults'),
        reason: 'kanji results must come from the SAME DictionarySearchResult '
            'that produced lookupEntries (no parallel channel).',
      );
      expect(
        injector,
        contains('.map((HoshiKanjiResult k) => k.toMap())'),
        reason: 'kanji results must be serialized via the typed '
            'HoshiKanjiResult.toMap contract.',
      );
      expect(injector, contains('final String kanjiResultsJson = jsonEncode('));
      expect(
        injector,
        contains(r'window.kanjiResults = $kanjiResultsJson'),
        reason: 'the kanji payload must be injected into the WebView next to '
            'window.lookupEntries in the same evaluateJavascript call.',
      );
    });

    test('window.kanjiResults injection sits in the same push as lookupEntries',
        () {
      final int entriesIdx =
          injector.indexOf(r'window.lookupEntries = $entriesJson');
      final int kanjiIdx =
          injector.indexOf(r'window.kanjiResults = $kanjiResultsJson');
      expect(entriesIdx, greaterThanOrEqualTo(0));
      expect(kanjiIdx, greaterThan(entriesIdx),
          reason: 'kanji results ride alongside the term entries in the same '
              'injection block, not a separate code path.');
    });
  });

  group('popup.js renders the kanji card from window.kanjiResults', () {
    late String popupJs;

    setUpAll(() {
      popupJs = File('assets/popup/popup.js').readAsStringSync();
    });

    test('reads window.kanjiResults and builds a kanji card', () {
      expect(popupJs, contains('function buildKanjiCards()'));
      expect(popupJs, contains('function createKanjiCard('));
      expect(popupJs, contains('window.kanjiResults'),
          reason: 'the renderer must read the injected kanji payload');
    });

    test('renders every real HoshiKanjiResult field', () {
      // The field names here must match HoshiKanjiResult.toMap (Dart).
      for (final field in <String>[
        'character',
        'onyomi',
        'kunyomi',
        'radical',
        'strokes',
        'meanings',
        'dictName',
      ]) {
        expect(popupJs, contains('kanji.$field'),
            reason: 'kanji card must render the $field field');
      }
    });

    test('renderPopup builds the kanji card and tolerates kanji-only results',
        () {
      final int renderIdx = popupJs.indexOf('window.renderPopup = function()');
      expect(renderIdx, greaterThanOrEqualTo(0));
      final String renderBody = popupJs.substring(renderIdx);
      expect(renderBody.contains('buildKanjiCards()'), isTrue,
          reason: 'renderPopup must build the kanji card');
      // A kanji-only result (no term entries) must not collapse to no-results.
      expect(
        renderBody.contains('(!entries || !entries.length) && !kanjiSection'),
        isTrue,
        reason: 'a kanji-only lookup (no term entries) must still render the '
            'kanji card instead of the no-results placeholder.',
      );
    });

    test('an empty kanji payload renders nothing', () {
      final int buildIdx = popupJs.indexOf('function buildKanjiCards()');
      expect(buildIdx, greaterThanOrEqualTo(0));
      final String buildBody = popupJs.substring(buildIdx);
      expect(
        buildBody.contains('!Array.isArray(kanji) || kanji.length === 0'),
        isTrue,
        reason: 'a missing / empty kanji array must produce no card, leaving '
            'multi-char / kana / latin lookups untouched.',
      );
    });
  });
}
