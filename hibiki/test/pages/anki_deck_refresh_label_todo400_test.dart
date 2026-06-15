import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';

// TODO-400: a user could not find the "ひびき" deck in the Anki settings. Root
// cause was UX, not a missing API: ひびき is an Anki *deck*, not a note type, so
// it belongs in the deck dropdown — which only ever renders the snapshot the
// last "fetch" returned. The deck list never filters, so the real reasons the
// deck was invisible were (1) the user had not re-fetched after creating the
// deck in Anki and (2) the fetch button was labelled "Fetch from AnkiDroid",
// which a desktop AnkiConnect user does not recognise as the refresh entry.
//
// We lock the two fixes:
//   1. The fetch label + not-configured copy are platform-neutral (no AnkiDroid)
//      and a refresh-hint key exists, in every locale.
//   2. _buildDeckDropdown renders ALL of settings.availableDecks with no filter,
//      so whatever the fetch returned is selectable.
void main() {
  group('TODO-400 platform-neutral fetch copy', () {
    // The desktop/iOS backend is AnkiConnect, not AnkiDroid; the fetch row is
    // the only refresh entry point, so its label must not name a single
    // platform's app (which made AnkiConnect users miss it).
    for (final AppLocale locale in AppLocale.values) {
      test(
          '${locale.languageTag}: fetch + not-configured copy is not '
          'AnkiDroid-only', () {
        final t = locale.translations;
        expect(
          t.anki_fetch.toLowerCase().contains('ankidroid'),
          isFalse,
          reason: '${locale.languageTag} anki_fetch still names AnkiDroid: '
              '"${t.anki_fetch}"',
        );
        expect(
          t.anki_not_configured.toLowerCase().contains('ankidroid'),
          isFalse,
          reason: '${locale.languageTag} anki_not_configured still names '
              'AnkiDroid: "${t.anki_not_configured}"',
        );
        // The refresh hint that tells users to tap after creating/renaming in
        // Anki must be present and non-empty in every locale.
        expect(t.anki_refresh_hint.trim(), isNotEmpty);
      });
    }

    test('English copy reads as a generic refresh action', () {
      final t = AppLocale.en.translations;
      expect(t.anki_fetch, 'Refresh decks & note types');
      expect(
        t.anki_not_configured.toLowerCase().contains('refresh'),
        isTrue,
      );
    });

    test('Chinese copy reads as a generic refresh action', () {
      final t = AppLocale.zhCn.translations;
      expect(t.anki_fetch, '刷新牌组与笔记类型');
      expect(t.anki_refresh_hint.contains('刷新'), isTrue);
    });
  });

  group('TODO-400 deck dropdown renders every fetched deck', () {
    late String deckDropdownBlock;

    setUpAll(() {
      final String source = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      final int start = source.indexOf('Widget _buildDeckDropdown(');
      expect(start, greaterThanOrEqualTo(0),
          reason: '_buildDeckDropdown not found');
      final int end = source.indexOf('Widget _buildNoteTypeDropdown(', start);
      expect(end, greaterThan(start));
      deckDropdownBlock = source.substring(start, end);
    });

    test('options come straight from settings.availableDecks', () {
      // The picker options must be built by mapping availableDecks directly —
      // the deck list the fetch wrote — so any deck Anki returned (including
      // ひびき) is selectable.
      expect(deckDropdownBlock.contains('settings.availableDecks'), isTrue,
          reason: 'deck dropdown must read from settings.availableDecks');
      expect(
        RegExp(r'decks\s*\.\s*map\s*\(').hasMatch(deckDropdownBlock),
        isTrue,
        reason: 'deck dropdown must map the full deck list into options',
      );
    });

    test('no filtering hides any fetched deck', () {
      // A .where(...) on the deck list would let a deck Anki returned silently
      // vanish from the dropdown — exactly the failure this task addresses.
      expect(
        RegExp(r'decks\s*\.\s*where\s*\(').hasMatch(deckDropdownBlock),
        isFalse,
        reason: 'deck dropdown must not filter out any fetched deck',
      );
    });
  });
}
