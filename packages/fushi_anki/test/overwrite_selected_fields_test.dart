import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 反馈 nWWjBp3Clo：覆写已有卡时只改用户勾选的字段（按笔记类型记住）。
///
/// 预制卡组（JLPT 标注、释义等）只想让 Fushi 补句子 / 图片 / 音频：勾了的字段按
/// 渲染值写（没映射到的写空），**没勾的字段一个都不点名**——两后端都按「未给出的
/// 字段保留旧值」原样留着。没有选择时仍是 BUG-2606 的整卡替换（[overwrite_whole_card_test]）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String kPayload = '{"expression":"仕業","reading":"しわざ"}';

  AnkiSettings settings() => const AnkiSettings(
    selectedDeckId: 1,
    selectedNoteTypeId: 2,
    availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
    availableNoteTypes: <AnkiNoteType>[
      AnkiNoteType(
        id: 2,
        name: 'Lapis',
        fields: <String>[
          'Expression',
          'ExpressionReading',
          'Sentence',
          'SentenceFurigana',
          'Hint',
        ],
      ),
    ],
    fieldMappings: <String, String>{
      'Expression': '{expression}',
      'ExpressionReading': '{reading}',
      'Sentence': '{sentence}',
    },
    tags: 'mine',
    allowDupes: true,
  );

  const AnkiMiningContext context = AnkiMiningContext(
    sentence: 'ひょっとして これも クロウカードの仕業でしょうか？',
    source: AnkiMiningSource.book,
    bookTitleTag: 'Cardcaptor',
  );

  Map<String, String> lapisNote() => <String, String>{
    'Expression': '仕業',
    'ExpressionReading': 'しわざ',
    'Sentence': '旧句',
    'SentenceFurigana': '妖怪[ようかい]のしわざのようです。',
    'Hint': 'JLPT N1',
  };

  group('AnkiSettings 覆写字段选择', () {
    test('缺省 = 每种笔记类型都覆写全部字段', () {
      const AnkiSettings s = AnkiSettings();
      expect(s.overwriteFieldsFor('Lapis'), isNull);
      expect(s.overwriteFieldsFor(null), isNull);
    });

    test('按笔记类型记住；空 / null 选择 = 删掉条目回到全部字段', () {
      final AnkiSettings s = const AnkiSettings()
          .withOverwriteFields('Lapis', <String>['Sentence', 'Picture'])
          .withOverwriteFields('Basic', <String>['Back']);
      expect(s.overwriteFieldsFor('Lapis'), <String>{'Sentence', 'Picture'});
      expect(s.overwriteFieldsFor('Basic'), <String>{'Back'});
      expect(s.overwriteFieldsFor('Other'), isNull);

      final AnkiSettings cleared = s
          .withOverwriteFields('Lapis', null)
          .withOverwriteFields('Basic', const <String>[]);
      expect(cleared.overwriteFieldsFor('Lapis'), isNull);
      expect(cleared.overwriteFieldsFor('Basic'), isNull);
      expect(cleared.overwriteFieldsByNoteType, isEmpty);
    });

    test('toJson / fromJson 往返；坏形状与空清单容错成「全部字段」', () {
      final AnkiSettings s = const AnkiSettings().withOverwriteFields(
        'Lapis',
        <String>['Sentence', 'Picture'],
      );
      final AnkiSettings back = AnkiSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.overwriteFieldsFor('Lapis'), <String>{'Sentence', 'Picture'});

      expect(overwriteFieldsByNoteTypeFromJson(null), isEmpty);
      expect(overwriteFieldsByNoteTypeFromJson('x'), isEmpty);
      expect(
        overwriteFieldsByNoteTypeFromJson(<String, Object?>{
          'Lapis': <Object?>['Sentence', 3, ''],
          'Empty': <Object?>[],
          'Bad': 'Sentence',
        }),
        <String, List<String>>{
          'Lapis': <String>['Sentence'],
        },
      );
    });
  });

  group('AnkiConnect 只覆写勾选的字段', () {
    test('只点名勾选的字段：映射的写渲染值，没映射的写空；没勾的不送', () async {
      final _RecordingService service = _RecordingService()
        ..noteModelName = 'Lapis'
        ..existingFields = lapisNote();
      final MineOutcome outcome =
          await _ConfiguredConnectRepo(
            service: service,
            settings: settings().withOverwriteFields('Lapis', <String>[
              'Sentence',
              'SentenceFurigana',
            ]),
          ).updateMinedNote(
            noteId: 888,
            rawPayloadJson: kPayload,
            context: context,
          );

      expect(outcome.result, MineResult.success);
      final Map<String, String> sent = service.updateCalls.single.fields;
      expect(sent, <String, String>{
        'Sentence': context.sentence,
        'SentenceFurigana': '',
      });
      expect(
        sent.containsKey('Hint'),
        isFalse,
        reason: '没勾的字段（JLPT 标注）不点名，Anki 保留旧值',
      );
      // 标签照旧只增不减（用户原有标签由 addTags 语义保留）。
      expect(service.addTagsCalls, hasLength(1));
    });

    test('别的笔记类型的选择不影响这张卡：仍整卡替换', () async {
      final _RecordingService service = _RecordingService()
        ..noteModelName = 'Lapis'
        ..existingFields = lapisNote();
      await _ConfiguredConnectRepo(
        service: service,
        settings: settings().withOverwriteFields('Basic', <String>['Back']),
      ).updateMinedNote(
        noteId: 888,
        rawPayloadJson: kPayload,
        context: context,
      );

      expect(
        service.updateCalls.single.fields.keys.toSet(),
        lapisNote().keys.toSet(),
      );
    });

    test('勾的字段这次全空 → 拒绝（overwriteFieldsEmpty），不写字段不打标签', () async {
      final _RecordingService service = _RecordingService()
        ..noteModelName = 'Lapis'
        ..existingFields = lapisNote();
      final MineOutcome outcome =
          await _ConfiguredConnectRepo(
            service: service,
            settings: settings().withOverwriteFields('Lapis', <String>[
              'SentenceFurigana',
              'Hint',
            ]),
          ).updateMinedNote(
            noteId: 888,
            rawPayloadJson: kPayload,
            context: context,
          );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, AnkiErrorCode.overwriteFieldsEmpty);
      expect(isFieldMappingConfigError(outcome.errorCode), isFalse);
      expect(service.updateCalls, isEmpty);
      expect(service.addTagsCalls, isEmpty);
    });

    test('勾的字段一个都不在这张卡上（字段改过名）→ 拒绝，不退回整卡替换', () async {
      final _RecordingService service = _RecordingService()
        ..noteModelName = 'Lapis'
        ..existingFields = lapisNote();
      final MineOutcome outcome =
          await _ConfiguredConnectRepo(
            service: service,
            settings: settings().withOverwriteFields('Lapis', <String>[
              'OldSentenceName',
            ]),
          ).updateMinedNote(
            noteId: 888,
            rawPayloadJson: kPayload,
            context: context,
          );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, AnkiErrorCode.overwriteFieldsEmpty);
      expect(service.updateCalls, isEmpty);
    });
  });

  group('AnkiDroid 只覆写勾选的字段', () {
    const MethodChannel channel = MethodChannel('app.fushi.reader/anki');

    test('只点名勾选的字段 + clearUnspecified:false，native 保留其余字段', () async {
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'requestAnkidroidPermissions') return true;
            calls.add(call);
            if (call.method == 'updateNoteFields') return null;
            fail('unexpected channel call: ${call.method}');
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final MineOutcome outcome = await _ConfiguredDroidRepo(
        settings().withOverwriteFields('Lapis', <String>[
          'Sentence',
          'SentenceFurigana',
        ]),
      ).updateMinedNote(noteId: 42, rawPayloadJson: kPayload, context: context);

      expect(outcome.result, MineResult.success);
      final Map<String, dynamic> args = Map<String, dynamic>.from(
        calls.single.arguments as Map,
      );
      expect(args['clearUnspecified'], isFalse);
      expect(
        Map<String, String>.from(args['fieldValues'] as Map),
        <String, String>{'Sentence': context.sentence, 'SentenceFurigana': ''},
      );
    });
  });
}

class _RecordingService extends AnkiConnectService {
  _RecordingService();

  Map<String, String>? existingFields = <String, String>{};
  String? noteModelName;
  final List<({int noteId, Map<String, String> fields})> updateCalls =
      <({int noteId, Map<String, String> fields})>[];
  final List<({int noteId, List<String> tags})> addTagsCalls =
      <({int noteId, List<String> tags})>[];

  @override
  Future<bool> mediaFileExists(String filename) async => false;

  @override
  Future<AnkiConnectNoteInfo?> noteInfo(int noteId) async {
    final Map<String, String>? fields = existingFields;
    if (fields == null) return null;
    return (modelName: noteModelName, fields: fields);
  }

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {}

  @override
  Future<void> updateNoteFields(int noteId, Map<String, String> fields) async {
    updateCalls.add((noteId: noteId, fields: Map<String, String>.from(fields)));
  }

  @override
  Future<void> addTags(int noteId, List<String> tags) async {
    addTagsCalls.add((noteId: noteId, tags: List<String>.from(tags)));
  }
}

class _ConfiguredConnectRepo extends AnkiConnectRepository {
  _ConfiguredConnectRepo({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

class _ConfiguredDroidRepo extends AnkiRepository {
  _ConfiguredDroidRepo(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}
