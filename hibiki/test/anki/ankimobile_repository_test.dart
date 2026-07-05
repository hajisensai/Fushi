import 'dart:convert';
import 'dart:io';

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

  test('encodes addnote query spaces as percent escapes, not plus signs', () {
    final successCallback = Uri.parse('hibiki://ankisuccess').replace(
      queryParameters: const <String, String>{'expression': 'はい いいえ'},
    );
    final uri = buildAnkiMobileAddNoteUri(
      deckName: 'Japanese Mining',
      noteTypeName: 'Lapis Card',
      fields: const <String, String>{
        'Expression': 'はい + いいえ',
        'Meaning': '(明鏡国語辞典 第三版) はい',
      },
      tags: const <String>['hibiki', 'book tag'],
      allowDuplicate: false,
      successCallback: successCallback,
    );

    expect(uri.query, isNot(contains('+')));
    expect(uri.query, contains('deck=Japanese%20Mining'));
    expect(uri.query, contains('type=Lapis%20Card'));
    expect(uri.queryParameters['fldExpression'], 'はい + いいえ');
    expect(uri.queryParameters['fldMeaning'], '(明鏡国語辞典 第三版) はい');
    expect(uri.queryParameters['tags'], 'hibiki book tag');
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

  test('mineEntry embeds local media for AnkiMobile instead of raw paths',
      () async {
    final temp = await Directory.systemTemp.createTemp('ankimobile-media-');
    addTearDown(() async {
      if (temp.existsSync()) {
        await temp.delete(recursive: true);
      }
    });

    final cover = File('${temp.path}/clip.gif');
    await cover.writeAsBytes(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
    final sentenceAudio = File('${temp.path}/sentence.aac');
    await sentenceAudio.writeAsBytes(<int>[0xff, 0xf1, 0x50, 0x80]);
    final wordAudio = File('${temp.path}/word.mp3');
    await wordAudio.writeAsBytes(<int>[0x49, 0x44, 0x33, 0x04]);

    const dictMediaPath = 'gaiji/ios-test.svg';
    final dictCacheDir = Directory(ankiDictionaryMediaCacheDirPath());
    if (!dictCacheDir.existsSync()) dictCacheDir.createSync(recursive: true);
    final dictFile = File(
      '${dictCacheDir.path}/${ankiDictionaryMediaCacheFilename(dictMediaPath)}',
    );
    await dictFile.writeAsString('<svg xmlns="http://www.w3.org/2000/svg"/>');
    addTearDown(() {
      if (dictFile.existsSync()) dictFile.deleteSync();
    });

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
          fields: <String>[
            'ExpressionAudio',
            'SentenceAudio',
            'Picture',
            'Glossary',
          ],
        ),
      ],
      fieldMappings: <String, String>{
        'ExpressionAudio': '{audio}',
        'SentenceAudio': '{sasayaki-audio}',
        'Picture': '{book-cover}',
        'Glossary': '{glossary}',
      },
    ));

    final outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(<String, Object?>{
        'expression': '猫',
        'audio': wordAudio.path,
        'glossary': '<img class="gloss-image" src="hoshi_dict_0.svg">',
        'dictionaryMedia': <Object>[
          <String, String>{
            'dictionary': '明鏡国語辞典 第三版',
            'path': dictMediaPath,
            'filename': 'hoshi_dict_0.svg',
          },
        ],
      }),
      context: AnkiMiningContext(
        sentence: '',
        coverPath: cover.path,
        sasayakiAudioPath: sentenceAudio.path,
      ),
    );

    expect(outcome.result, MineResult.success);
    expect(launched, hasLength(1));
    final fields = launched.single.queryParameters;
    expect(fields['fldExpressionAudio'], startsWith('data:audio/mpeg;base64,'));
    expect(fields['fldSentenceAudio'], startsWith('data:audio/aac;base64,'));
    expect(fields['fldPicture'], startsWith('data:image/gif;base64,'));
    expect(
      fields['fldGlossary'],
      contains('src="data:image/svg+xml;base64,'),
    );
    for (final value in <String>[
      fields['fldExpressionAudio']!,
      fields['fldSentenceAudio']!,
      fields['fldPicture']!,
      fields['fldGlossary']!,
    ]) {
      expect(value, isNot(contains(temp.path)));
      expect(value, isNot(contains('hoshi_dict_0.svg')));
    }
  });
}
