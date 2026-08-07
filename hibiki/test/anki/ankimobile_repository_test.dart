import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
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
      mediaServerLifetime: Duration.zero,
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

  test('mineEntry exposes local media as downloadable URLs for AnkiMobile',
      () async {
    final temp = await Directory.systemTemp.createTemp('ankimobile-media-');
    addTearDown(() async {
      if (temp.existsSync()) {
        await temp.delete(recursive: true);
      }
    });

    final cover = File('${temp.path}/clip.gif');
    await cover.writeAsBytes(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
    final sentenceAudio = File('${temp.path}/sentence.m4a');
    await sentenceAudio
        .writeAsBytes(<int>[0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]);
    final wordAudio = File('${temp.path}/word.mp3');
    await wordAudio.writeAsBytes(<int>[0x49, 0x44, 0x33, 0x04]);

    const dictMediaPath = 'gaiji/ios-test.svg';
    final dictCacheDir = Directory(ankiDictionaryMediaCacheDirPath());
    if (!dictCacheDir.existsSync()) dictCacheDir.createSync(recursive: true);
    final dictFile = File(
      '${dictCacheDir.path}/${ankiDictionaryMediaCacheFilename('明鏡国語辞典 第三版', dictMediaPath)}',
    );
    await dictFile.writeAsString('<svg xmlns="http://www.w3.org/2000/svg"/>');
    addTearDown(() {
      if (dictFile.existsSync()) dictFile.deleteSync();
    });

    final events = <String>[];
    final launched = <Uri>[];
    // The media server teardown is asynchronous (`Timer.run` -> HttpServer.close
    // -> recursive delete of a real temp dir), so its duration is real I/O and
    // cannot be predicted. Await the end-of-background-task callback itself --
    // that IS the completion signal we are asserting on.
    final Completer<void> backgroundTaskEnded = Completer<void>();
    final repo = AnkiMobileRepository(
      openUrl: (uri) async {
        expect(events, contains('begin-background-task'));
        events.add('open-ankimobile');
        launched.add(uri);
        return true;
      },
      readInfoForAddingJson: () async => null,
      mediaServerLifetime: Duration.zero,
      beginMediaImportBackgroundTask: () async {
        events.add('begin-background-task');
      },
      endMediaImportBackgroundTask: () async {
        events.add('end-background-task');
        if (!backgroundTaskEnded.isCompleted) backgroundTaskEnded.complete();
      },
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
        sentenceAudioPath: sentenceAudio.path,
      ),
    );

    expect(outcome.result, MineResult.success);
    expect(launched, hasLength(1));
    final fields = launched.single.queryParameters;
    expect(fields['fldExpressionAudio'],
        matches(RegExp(r'^http://127\.0\.0\.1:\d+/media/[^/]+\.mp3$')));
    expect(fields['fldSentenceAudio'],
        matches(RegExp(r'^http://127\.0\.0\.1:\d+/media/[^/]+\.m4a$')));
    expect(fields['fldPicture'],
        matches(RegExp(r'^http://127\.0\.0\.1:\d+/media/[^/]+\.gif$')));
    expect(
      fields['fldGlossary'],
      matches(RegExp(r'src="http://127\.0\.0\.1:\d+/media/[^"]+\.svg"')),
    );
    for (final value in <String>[
      fields['fldExpressionAudio']!,
      fields['fldSentenceAudio']!,
      fields['fldPicture']!,
      fields['fldGlossary']!,
    ]) {
      expect(value, isNot(contains('data:')));
      expect(value, isNot(contains(temp.path)));
      expect(value, isNot(contains('hoshi_dict_0.svg')));
    }
    await backgroundTaskEnded.future;
    expect(events, <String>[
      'begin-background-task',
      'open-ankimobile',
      'end-background-task',
    ]);
  });

  test('media URLs survive source temp cleanup until AnkiMobile fetches',
      () async {
    final temp = await Directory.systemTemp.createTemp('ankimobile-cleanup-');
    final sentenceAudio = File('${temp.path}/sentence.m4a');
    final bytes = <int>[0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70];
    await sentenceAudio.writeAsBytes(bytes);
    addTearDown(() async {
      if (temp.existsSync()) {
        await temp.delete(recursive: true);
      }
    });

    final launched = <Uri>[];
    // Same rule as above: wait for the real "server torn down" signal instead of
    // guessing a duration that must exceed lifetime + HttpServer.close +
    // recursive temp-dir delete.
    final Completer<void> backgroundTaskEnded = Completer<void>();
    final repo = AnkiMobileRepository(
      openUrl: (uri) async {
        launched.add(uri);
        return true;
      },
      readInfoForAddingJson: () async => null,
      mediaServerLifetime: const Duration(milliseconds: 500),
      beginMediaImportBackgroundTask: () async {},
      endMediaImportBackgroundTask: () async {
        if (!backgroundTaskEnded.isCompleted) backgroundTaskEnded.complete();
      },
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
          fields: <String>['SentenceAudio'],
        ),
      ],
      fieldMappings: <String, String>{
        'SentenceAudio': '{sasayaki-audio}',
      },
    ));

    final outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(<String, Object?>{
        'expression': '猫',
      }),
      context: AnkiMiningContext(
        sentence: '',
        sentenceAudioPath: sentenceAudio.path,
      ),
    );
    expect(outcome.result, MineResult.success);

    await temp.delete(recursive: true);
    final mediaUrl = launched.single.queryParameters['fldSentenceAudio'];
    expect(mediaUrl, isNotNull);

    final uri = Uri.parse(mediaUrl!);
    final socket = await Socket.connect(uri.host, uri.port);
    socket.add(utf8.encode(
      'GET ${uri.path} HTTP/1.1\r\n'
      'Host: ${uri.host}\r\n'
      'Connection: close\r\n'
      '\r\n',
    ));
    await socket.flush();
    final rawResponse = await socket.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    final headerEnd = _indexOfBytes(rawResponse, utf8.encode('\r\n\r\n'));
    expect(headerEnd, greaterThanOrEqualTo(0));
    final header = utf8.decode(rawResponse.sublist(0, headerEnd));
    final statusLine = header.split('\r\n').first;
    final responseBytes = rawResponse.sublist(headerEnd + 4);

    expect(statusLine, startsWith('HTTP/1.1 200'));
    expect(responseBytes, bytes);

    await backgroundTaskEnded.future;
  });
}

int _indexOfBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return i;
  }
  return -1;
}
