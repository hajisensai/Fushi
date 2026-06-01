import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// Real-device AnkiDroid integration (HBK-AUDIT-020/051).
///
/// Requires: AnkiDroid installed with a collection, and Hibiki granted
/// `com.ichi2.anki.permission.READ_WRITE_DATABASE`. Exercises the real
/// AnkiDroid ContentProvider IPC through Hibiki's native AnkiChannelHandler —
/// the path the unit suite cannot cover.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('AnkiDroid API integration', () {
    late AnkiRepository repo;

    setUpAll(() {
      repo = AnkiRepository();
    });

    testWidgets('fetchConfiguration returns real decks and note types',
        (WidgetTester tester) async {
      final AnkiFetchResult result = await repo.fetchConfiguration();
      expect(
        result,
        isA<AnkiFetchSuccess>(),
        reason: 'AnkiDroid must be installed with a collection + the API '
            'permission granted to Hibiki',
      );
      final AnkiFetchSuccess success = result as AnkiFetchSuccess;
      expect(success.decks, isNotEmpty); // the Default deck
      expect(success.noteTypes, isNotEmpty); // Basic, Cloze, ...
    });

    testWidgets('isDuplicate completes without hanging (HBK-AUDIT-020)',
        (WidgetTester tester) async {
      // checkForDuplicates queries the ContentProvider on the main looper; the
      // 020 fix guarantees the Future always completes (success or error) even
      // if the provider throws — so this await must not hang.
      final bool dupe = await repo
          .isDuplicate('統合テスト用語', 'とうごう')
          .timeout(const Duration(seconds: 15));
      expect(dupe, isA<bool>());
    });

    testWidgets('mineEntry adds a note to AnkiDroid',
        (WidgetTester tester) async {
      final AnkiFetchResult fetch = await repo.fetchConfiguration();
      expect(fetch, isA<AnkiFetchSuccess>());

      // Map the first field of the selected note type to the expression so the
      // rendered note is non-empty (otherwise the 018 guard rejects it).
      final AnkiSettings settings = await repo.loadSettings();
      final AnkiNoteType? noteType = settings.selectedNoteType;
      expect(noteType, isNotNull);
      expect(noteType!.fields, isNotEmpty);
      await repo.updateSettings(
        (AnkiSettings s) => s.copyWith(
          fieldMappings: <String, String>{
            noteType.fields.first: '{expression}'
          },
        ),
      );

      final String payloadJson = jsonEncode(<String, dynamic>{
        'expression': '統合テスト',
        'reading': 'とうごうてすと',
        'glossary': 'integration-test entry',
      });
      final MineResult result = await repo
          .mineEntry(
            rawPayloadJson: payloadJson,
            context: const AnkiMiningContext(sentence: '統合テストの文。'),
          )
          .timeout(const Duration(seconds: 20));

      // A fresh add returns success; a re-run hits the dupe check. Either proves
      // the full mine -> ContentProvider add path works end-to-end.
      expect(
        result,
        anyOf(MineResult.success, MineResult.duplicate),
        reason: 'mineEntry must add the card or detect a duplicate, not '
            'fail/notConfigured',
      );
    });
  });
}
