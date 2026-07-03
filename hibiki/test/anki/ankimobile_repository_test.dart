import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/anki/ankimobile_repository.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('builds an AnkiMobile addnote URL with deck type fields and callback',
      () {
    final successCallback = Uri.parse('hibiki://ankisuccess').replace(
      queryParameters: const <String, String>{'expression': '日本語'},
    );
    final uri = buildAnkiMobileAddNoteUri(
      deckName: 'Japanese::Mining',
      noteTypeName: 'Lapis',
      fields: const <String, String>{
        'Expression': '日本語',
        'Sentence': 'line 1<br>line 2',
      },
      tags: const <String>['hibiki', 'book'],
      allowDuplicate: true,
      successCallback: successCallback,
    );

    expect(uri.scheme, 'anki');
    expect(uri.host, 'x-callback-url');
    expect(uri.path, '/addnote');
    expect(uri.queryParameters['deck'], 'Japanese::Mining');
    expect(uri.queryParameters['type'], 'Lapis');
    expect(uri.queryParameters['fldExpression'], '日本語');
    expect(uri.queryParameters['fldSentence'], 'line 1<br>line 2');
    expect(uri.queryParameters['tags'], 'hibiki book');
    expect(uri.queryParameters['dupes'], '1');
    expect(
      uri.queryParameters['x-success'],
      successCallback.toString(),
    );
  });

  test('imports AnkiMobile infoForAdding clipboard JSON into settings',
      () async {
    final repo = AnkiMobileRepository(
      openUrl: (_) async => true,
      readInfoForAddingJson: () async => jsonEncode(<String, Object?>{
        'profiles': <Object>[
          <String, Object?>{'name': 'User 1'},
        ],
        'decks': <Object>[
          <String, Object?>{'name': 'Default'},
          <String, Object?>{'name': 'Japanese'},
        ],
        'notetypes': <Object>[
          <String, Object?>{
            'name': 'Lapis',
            'fields': <Object>[
              <String, Object?>{'name': 'Expression'},
              <String, Object?>{'name': 'Sentence'},
            ],
          },
        ],
      }),
    );

    final result = await repo.consumeInfoForAddingPasteboard();

    expect(result, isA<AnkiFetchSuccess>());
    final settings = await repo.loadSettings();
    expect(settings.selectedDeckName, 'Japanese');
    expect(settings.selectedNoteTypeName, 'Lapis');
    expect(settings.availableDecks.map((d) => d.name), ['Default', 'Japanese']);
    expect(
        settings.availableNoteTypes.single.fields, ['Expression', 'Sentence']);
    expect(settings.fieldMappings.keys, contains('Expression'));
  });

  test('mineEntry opens addnote URL from persisted settings', () async {
    final launched = <Uri>[];
    final repo = AnkiMobileRepository(
      openUrl: (uri) async {
        launched.add(uri);
        return true;
      },
      readInfoForAddingJson: () async => null,
    );
    await repo.saveSettings(const AnkiSettings(
      selectedDeckId: 0,
      selectedDeckName: 'Japanese',
      selectedNoteTypeId: 0,
      selectedNoteTypeName: 'Lapis',
      availableDecks: <AnkiDeck>[AnkiDeck(id: 0, name: 'Japanese')],
      availableNoteTypes: <AnkiNoteType>[
        AnkiNoteType(
          id: 0,
          name: 'Lapis',
          fields: <String>['Expression', 'Sentence'],
        ),
      ],
      fieldMappings: <String, String>{
        'Expression': '{expression}',
        'Sentence': '{sentence}',
      },
      tags: 'custom',
    ));

    final outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(<String, String>{'expression': '猫'}),
      context: const AnkiMiningContext(
        sentence: '黒い猫です。',
        source: AnkiMiningSource.book,
      ),
    );

    expect(outcome.result, MineResult.success);
    expect(launched, hasLength(1));
    expect(launched.single.queryParameters['fldExpression'], '猫');
    expect(launched.single.queryParameters['fldSentence'], '黒い猫です。');
    expect(launched.single.queryParameters['tags'], 'custom hibiki book');
    expect(launched.single.queryParameters, isNot(contains('dupes')));
  });
}
