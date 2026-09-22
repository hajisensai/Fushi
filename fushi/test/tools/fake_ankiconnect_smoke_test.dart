// `integration_test/support/fake_ankiconnect.dart` 的形状冒烟：裸 HttpClient 逐条
// POST 看信封，再用本仓真 `AnkiConnectService` 走一遍制卡链路要用的那几条 action，
// 证明假服务与生产客户端的请求/响应形状对得上。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

import '../../integration_test/support/fake_ankiconnect.dart';

Future<Map<String, Object?>> _post(
  FakeAnkiConnect server,
  String action, {
  Map<String, Object?>? params,
  bool versioned = true,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.postUrl(server.uri);
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode(<String, Object?>{
        'action': action,
        if (versioned) 'version': 6,
        if (params != null) 'params': params,
      }),
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200, reason: 'action=$action');
    final String body = await utf8.decoder.bind(res).join();
    final Object? decoded = jsonDecode(body);
    expect(decoded, isA<Map<String, Object?>>(), reason: 'action=$action');
    return decoded! as Map<String, Object?>;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late FakeAnkiConnect server;

  setUp(() async {
    server = await FakeAnkiConnect.start();
  });

  tearDown(() => server.close());

  test(
    '裸 HTTP：version / deckNames / modelFieldNames / addNote / findNotes 形状',
    () async {
      final Map<String, Object?> version = await _post(server, 'version');
      expect(version, <String, Object?>{'result': 6, 'error': null});

      final Map<String, Object?> decks = await _post(server, 'deckNames');
      expect(decks['error'], isNull);
      expect(decks['result'], containsAll(<String>['Default', 'FushiItest']));

      final Map<String, Object?> fields = await _post(
        server,
        'modelFieldNames',
        params: <String, Object?>{'modelName': LapisNoteType.modelName},
      );
      expect(fields['error'], isNull);
      expect(fields['result'], LapisNoteType.fields);

      final Map<String, Object?> added = await _post(
        server,
        'addNote',
        params: <String, Object?>{
          'note': <String, Object?>{
            'deckName': 'FushiItest',
            'modelName': LapisNoteType.modelName,
            'fields': <String, String>{
              'Expression': '猫',
              'ExpressionReading': 'ねこ',
              'Sentence': '猫がいる',
              'NotAField': 'dropped',
            },
            'options': <String, Object?>{
              'allowDuplicate': false,
              'duplicateScope': 'deck',
              'duplicateScopeOptions': <String, Object?>{
                'deckName': 'FushiItest',
                'checkChildren': true,
                'checkAllModels': true,
              },
            },
            'tags': <String>['hibiki', 'itest'],
          },
        },
      );
      expect(added['error'], isNull);
      final int noteId = added['result']! as int;
      expect(server.notes, hasLength(1));
      expect(server.notes.single['noteId'], noteId);
      expect(
        (server.notes.single['fields']! as Map<String, String>)['Expression'],
        '猫',
      );
      expect(
        (server.notes.single['fields']! as Map<String, String>).containsKey(
          'NotAField',
        ),
        isFalse,
        reason: '笔记类型里不存在的字段名应像真 Anki 一样被静默丢弃',
      );

      // findNotesByField 的查询串形状（ankiconnect_service.dart `_fieldValueQuery`）。
      final Map<String, Object?> found = await _post(
        server,
        'findNotes',
        params: <String, Object?>{'query': 'deck:"FushiItest" "Expression:猫"'},
      );
      expect(found, <String, Object?>{
        'result': <Object?>[noteId],
        'error': null,
      });
      final Map<String, Object?> miss = await _post(
        server,
        'findNotes',
        params: <String, Object?>{'query': 'deck:"FushiItest" "Expression:犬"'},
      );
      expect(miss['result'], isEmpty);

      // notesInfo：每项 `{noteId, modelName, tags, fields:{name:{value, order}}}`。
      final Map<String, Object?> info = await _post(
        server,
        'notesInfo',
        params: <String, Object?>{
          'notes': <int>[noteId, 42],
        },
      );
      final List<Object?> items = info['result']! as List<Object?>;
      expect(items, hasLength(2));
      final Map<String, Object?> first = items[0]! as Map<String, Object?>;
      expect(first['noteId'], noteId);
      expect(first['modelName'], LapisNoteType.modelName);
      expect(first['tags'], <String>['hibiki', 'itest']);
      final Map<String, Object?> f = first['fields']! as Map<String, Object?>;
      expect(f['Expression'], <String, Object?>{'value': '猫', 'order': 0});
      expect(f['ExpressionReading'], <String, Object?>{
        'value': 'ねこ',
        'order': 2,
      });
      expect(items[1], isEmpty, reason: '不存在的 note 回空对象');

      // 重复：文案与 kAnkiConnectDuplicateError 一字不差。
      final Map<String, Object?> dup = await _post(
        server,
        'addNote',
        params: <String, Object?>{
          'note': <String, Object?>{
            'deckName': 'FushiItest',
            'modelName': 'Basic',
            'fields': <String, String>{'Front': '猫'},
            'options': <String, Object?>{
              'allowDuplicate': false,
              'duplicateScope': 'deck',
              'duplicateScopeOptions': <String, Object?>{
                'deckName': 'FushiItest',
                'checkChildren': true,
                'checkAllModels': true,
              },
            },
          },
        },
      );
      expect(dup, <String, Object?>{
        'result': null,
        'error': kAnkiConnectDuplicateError,
      });

      final Map<String, Object?> unknown = await _post(server, 'nope');
      expect(unknown, <String, Object?>{
        'result': null,
        'error': 'unsupported: nope',
      });

      expect(
        server.requests.map((Map<String, Object?> r) => r['action']),
        containsAllInOrder(<String>[
          'version',
          'deckNames',
          'modelFieldNames',
          'addNote',
          'findNotes',
        ]),
      );
    },
  );

  test('真 AnkiConnectService 走通制卡链路要用的 action', () async {
    final AnkiConnectService service = AnkiConnectService(
      host: server.uri.host,
      port: server.port,
    );
    expect(await service.checkConnection(), isNull);
    expect(await service.getDeckNames(), contains('FushiItest'));
    expect(await service.getModelNames(), contains(LapisNoteType.modelName));
    expect(
      await service.getModelFields(LapisNoteType.modelName),
      LapisNoteType.fields,
    );
    expect(
      await service.getDeckNamesAndIds(),
      containsPair('FushiItest', isA<int>()),
    );
    expect(
      await service.getModelNamesAndIds(),
      containsPair(LapisNoteType.modelName, isA<int>()),
    );
    expect(
      (await service.modelTemplates(
        LapisNoteType.modelName,
      )).map((AnkiCardTemplate t) => t.name),
      <String>[LapisNoteType.cardName],
    );
    expect(await service.modelStyling(LapisNoteType.modelName), isNotEmpty);

    // 查重探针（isDuplicateForAdd → canAddNotesWithErrorDetail）：加卡前 false。
    expect(
      await service.isDuplicateForAdd(
        deckName: 'FushiItest',
        modelName: LapisNoteType.modelName,
        firstFieldName: 'Expression',
        firstFieldValue: '猫',
      ),
      isFalse,
    );

    // 媒体：storeMediaFile(data) → getMediaFilesNames → getMediaDirPath。
    await service.storeMediaFile(
      filename: 'fushi_audio_abc.mp3',
      data: base64Encode(<int>[1, 2, 3]),
    );
    expect(await service.mediaFileExists('fushi_audio_abc.mp3'), isTrue);
    expect(await service.mediaFileExists('fushi_audio_zzz.mp3'), isFalse);
    expect(await service.getMediaDirPath(), server.mediaDirPath);
    expect(
      File(
        '${server.mediaDirPath}${Platform.pathSeparator}fushi_audio_abc.mp3',
      ).readAsBytesSync(),
      <int>[1, 2, 3],
    );

    final int? noteId = await service.addNote(
      deckName: 'FushiItest',
      modelName: LapisNoteType.modelName,
      fields: <String, String>{
        'Expression': '猫',
        'ExpressionAudio': '[sound:fushi_audio_abc.mp3]',
      },
      tags: <String>['hibiki'],
    );
    expect(noteId, isNotNull);
    expect(server.requestsFor('addNote'), hasLength(1));

    // 加卡后：查重探针 true；addNote 再来一次抛 AnkiConnectDuplicateException。
    expect(
      await service.isDuplicateForAdd(
        deckName: 'FushiItest',
        modelName: LapisNoteType.modelName,
        firstFieldName: 'Expression',
        firstFieldValue: '猫',
      ),
      isTrue,
    );
    await expectLater(
      service.addNote(
        deckName: 'FushiItest',
        modelName: LapisNoteType.modelName,
        fields: <String, String>{'Expression': '猫'},
      ),
      throwsA(isA<AnkiConnectDuplicateException>()),
    );

    expect(
      await service.findNotesByField(
        deckName: 'FushiItest',
        fieldName: 'Expression',
        fieldValue: '猫',
      ),
      <int>[noteId!],
    );
    // BUG-2051 的同源搜索串：`(did:…) ("dupe:mid,猫")`。
    final Map<String, int> models = await service.getModelNamesAndIds();
    final Map<String, int> decks = await service.getDeckNamesAndIds();
    expect(
      await service.findNotesByQuery(
        ankiDuplicateSearchQuery(
          value: '猫',
          modelIds: models.values,
          deckIds: ankiDuplicateDeckIds(
            deckName: 'FushiItest',
            scope: AnkiDuplicateScope.deck,
            deckNamesAndIds: decks,
          ),
        ),
      ),
      <int>[noteId],
    );
    // 媒体去重按文件名裸文本反查。
    expect(await service.findNotesByQuery('"fushi_audio_abc.mp3"'), <int>[
      noteId,
    ]);

    final AnkiConnectNoteInfo? info = await service.noteInfo(noteId);
    expect(info?.modelName, LapisNoteType.modelName);
    expect(info?.fields['Expression'], '猫');
    expect(info?.fields['Sentence'], '');

    await service.updateNoteFields(noteId, <String, String>{
      'Sentence': '猫がいる',
    });
    await service.addTags(noteId, <String>['video']);
    expect((await service.notesInfo(noteId))?['Sentence'], '猫がいる');
    expect(server.notes.single['tags'], <String>['hibiki', 'video']);

    // multi：逐条分发、同序、子项失败不拖累整批。
    final List<AnkiConnectBatchResult> batch = await service.requestMulti(
      <AnkiConnectAction>[
        const AnkiConnectAction('version'),
        AnkiConnectAction('findNotes', <String, dynamic>{
          'query': 'nid:$noteId',
        }),
        const AnkiConnectAction('nope'),
      ],
    );
    expect(
      batch.map((AnkiConnectBatchResult r) => r.result).toList(),
      <Object?>[
        6,
        <Object?>[noteId],
        null,
      ],
    );
    expect(batch[2].error, 'unsupported: nope');
    expect(server.requestsFor('findNotes').length, greaterThanOrEqualTo(4));

    // 卡片级：findCards / cardsInfo / setSpecificValueOfCard / guiBrowse。
    final List<int> cards = await service.findCards(
      ankiDeckNewCardsQuery(decks, 'FushiItest'),
    );
    expect(cards, hasLength(1));
    final List<AnkiCardInfo> infos = await service.cardsInfo(cards);
    expect(infos.single.noteId, noteId);
    final List<AnkiConnectBatchResult> due = await service.setCardsDueMany(
      <AnkiCardDueUpdate>[AnkiCardDueUpdate(cardId: cards.single, due: 7)],
    );
    expect(ankiSetSpecificValueFailure(due.single), isNull);
    expect(server.notes.single['due'], 7);
    expect(await service.guiBrowseQuery('nid:$noteId'), cards);

    // 删媒体后再查不到。
    await service.deleteMediaFile('fushi_audio_abc.mp3');
    expect(await service.mediaFileExists('fushi_audio_abc.mp3'), isFalse);
  });

  test('createModel / createDeck / 模板与样式改写', () async {
    final AnkiConnectService service = AnkiConnectService(
      host: server.uri.host,
      port: server.port,
    );
    await service.createDeck('Lapis');
    expect(await service.getDeckNames(), contains('Lapis'));
    await service.createModel(
      const AnkiNoteTypeTemplate(
        name: 'Mini',
        fields: <String>['Word', 'Meaning'],
        cardName: 'Card 1',
        front: '{{Word}}',
        back: '{{Meaning}}',
        css: '.card{}',
      ),
    );
    expect(await service.getModelFields('Mini'), <String>['Word', 'Meaning']);
    await service.updateModelStyling('Mini', '.card{color:red}');
    expect(await service.modelStyling('Mini'), '.card{color:red}');
    await service.updateModelTemplates('Mini', <AnkiCardTemplate>[
      const AnkiCardTemplate(name: 'Card 1', front: 'F', back: 'B'),
    ]);
    final List<AnkiCardTemplate> tpls = await service.modelTemplates('Mini');
    expect(tpls.single.front, 'F');
    expect(tpls.single.back, 'B');
    await expectLater(
      service.createModel(
        const AnkiNoteTypeTemplate(
          name: 'Mini',
          fields: <String>['Word'],
          cardName: 'Card 1',
          front: '',
          back: '',
          css: '',
        ),
      ),
      throwsA(isA<AnkiConnectException>()),
    );
  });

  test('apiKey 门：不带 key 的请求被拒', () async {
    final FakeAnkiConnect keyed = await FakeAnkiConnect.start(apiKey: 'secret');
    try {
      final Map<String, Object?> denied = await _post(keyed, 'version');
      expect(denied['error'], 'valid api key must be provided');
      final AnkiConnectService ok = AnkiConnectService(
        host: keyed.uri.host,
        port: keyed.port,
        apiKey: 'secret',
      );
      expect(await ok.checkConnection(), isNull);
    } finally {
      await keyed.close();
    }
  });
}
