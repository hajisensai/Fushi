import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-2606：覆盖已有卡 = 让它变成「此刻新制会得到的那张」——字段与标签都是。
///
/// 用户实测（Lapis）：`SentenceFurigana` 由别的工具填过，Fushi 不映射它；点覆盖后
/// `Sentence` 换成新句、`SentenceFurigana` 留旧，而 Lapis 模板
/// `{{#SentenceFurigana}}…{{/SentenceFurigana}}` 优先显示它——卡面照旧是老句子，
/// 直到手动清空。同时覆盖不打 `fushi` / 分类标签，与新制的卡不对称。
///
/// 这里钉死两后端的修复后契约：
///   * AnkiConnect：先 `notesInfo` 拿现有字段名，`updateNoteFields` 把**没映射的**
///     字段写空、映射的写渲染值；随后 `addTags` 并入新制那组标签；读不到 note 时
///     明确失败、不发半覆盖。
///   * AnkiDroid：单次 `updateNoteFields` 通道调用带 `clearUnspecified: true` +
///     `tags`，由 native 按位置把没点名的字段写空并并集标签。
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

  group('AnkiConnect 覆盖 = 整卡替换 + 补标签', () {
    test('没映射的 SentenceFurigana / Hint 被写空，映射字段写渲染值', () async {
      final _RecordingService service = _RecordingService()
        ..existingFields = <String, String>{
          'Expression': '仕業',
          'ExpressionReading': 'しわざ',
          'Sentence': '旧句',
          'SentenceFurigana': '妖怪[ようかい]のしわざのようです。',
          'Hint': 'old hint',
        };
      final MineOutcome outcome = await _ConfiguredConnectRepo(
        service: service,
        settings: settings(),
      ).updateMinedNote(
        noteId: 888,
        rawPayloadJson: kPayload,
        context: context,
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.noteId, 888);
      final Map<String, String> sent = service.updateCalls.single.fields;
      expect(sent['Expression'], '仕業');
      expect(sent['ExpressionReading'], 'しわざ');
      expect(sent['Sentence'], context.sentence);
      expect(sent.containsKey('SentenceFurigana'), isTrue,
          reason: '没映射的字段必须显式送空串，否则 native 保留旧值');
      expect(sent['SentenceFurigana'], '');
      expect(sent['Hint'], '');
      expect(service.addNoteCalls, isEmpty);
    });

    test('随后 addTags 并入新制那组标签（用户 tag + fushi + 分类 + 书名）', () async {
      final _RecordingService service = _RecordingService()
        ..existingFields = <String, String>{'Expression': '仕業'};
      await _ConfiguredConnectRepo(service: service, settings: settings())
          .updateMinedNote(
        noteId: 888,
        rawPayloadJson: kPayload,
        context: context,
      );

      expect(service.addTagsCalls, hasLength(1));
      expect(service.addTagsCalls.single.noteId, 888);
      expect(
        service.addTagsCalls.single.tags,
        <String>[
          'mine',
          BaseAnkiRepository.fushiTag,
          BaseAnkiRepository.bookTag,
          'Cardcaptor'
        ],
      );
    });

    test('note 读不到（已删 / 不可达）→ 明确失败，不发半覆盖', () async {
      final _RecordingService service = _RecordingService()
        ..existingFields = null;
      final MineOutcome outcome = await _ConfiguredConnectRepo(
        service: service,
        settings: settings(),
      ).updateMinedNote(
        noteId: 888,
        rawPayloadJson: kPayload,
        context: context,
      );

      expect(outcome.result, MineResult.error);
      expect(service.updateCalls, isEmpty);
      expect(service.addTagsCalls, isEmpty);
    });

    test('候选卡属于别的笔记类型 → 拒绝整卡覆盖，不写字段不打标签', () async {
      // findMatchingNotes 按首字段名搜同卡组，任何带同名首字段的 note type 都会命中；
      // 整卡覆盖会把那张卡没映射的字段全部清空，所以 modelName 不符必须拒绝。
      final _RecordingService service = _RecordingService()
        ..noteModelName = 'Core 2k/6k'
        ..existingFields = <String, String>{
          'Expression': '仕業',
          'Meaning': 'deed',
          'Audio': '[sound:x.mp3]',
        };
      final MineOutcome outcome = await _ConfiguredConnectRepo(
        service: service,
        settings: settings(),
      ).updateMinedNote(
        noteId: 777,
        rawPayloadJson: kPayload,
        context: context,
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorDetail, contains('Core 2k/6k'));
      expect(service.updateCalls, isEmpty);
      expect(service.addTagsCalls, isEmpty);
    });

    test('候选卡笔记类型与选定一致（或服务端没给 modelName）照常覆盖', () async {
      final _RecordingService service = _RecordingService()
        ..noteModelName = 'Lapis'
        ..existingFields = <String, String>{'Expression': '', 'Hint': 'h'};
      final MineOutcome outcome = await _ConfiguredConnectRepo(
        service: service,
        settings: settings(),
      ).updateMinedNote(
        noteId: 778,
        rawPayloadJson: kPayload,
        context: context,
      );
      expect(outcome.result, MineResult.success);
      expect(service.updateCalls, hasLength(1));
    });

    test('全部映射字段渲染皆空仍拒绝（不会借「清未映射字段」清空整卡）', () async {
      final _RecordingService service = _RecordingService()
        ..existingFields = <String, String>{
          'Expression': '仕業',
          'SentenceFurigana': 'x',
        };
      final MineOutcome outcome = await _ConfiguredConnectRepo(
        service: service,
        settings: settings().copyWith(
          fieldMappings: const <String, String>{'Sentence': '{sentence}'},
        ),
      ).updateMinedNote(
        noteId: 888,
        rawPayloadJson: kPayload,
        context: const AnkiMiningContext(sentence: ''),
      );

      expect(outcome.result, MineResult.error);
      expect(service.updateCalls, isEmpty);
    });
  });

  group('AnkiDroid 覆盖：通道带 clearUnspecified + tags', () {
    const MethodChannel channel = MethodChannel('app.fushi.reader/anki');

    test('单次 updateNoteFields 调用带 clearUnspecified:true 与新制那组标签', () async {
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

      final MineOutcome outcome =
          await _ConfiguredDroidRepo(settings()).updateMinedNote(
        noteId: 42,
        rawPayloadJson: kPayload,
        context: context,
      );

      expect(outcome.result, MineResult.success);
      expect(calls.map((MethodCall c) => c.method), <String>[
        'updateNoteFields',
      ]);
      final Map<String, dynamic> args =
          Map<String, dynamic>.from(calls.single.arguments as Map);
      expect(args['noteId'], 42);
      expect(args['clearUnspecified'], isTrue);
      expect(
        List<String>.from(args['tags'] as List),
        <String>[
          'mine',
          BaseAnkiRepository.fushiTag,
          BaseAnkiRepository.bookTag,
          'Cardcaptor'
        ],
      );
      final Map<String, String> fieldValues =
          Map<String, String>.from(args['fieldValues'] as Map);
      expect(fieldValues['Sentence'], context.sentence);
      // 没映射的字段由 native 按 clearUnspecified 写空，Dart 侧不必点名。
      expect(fieldValues.containsKey('SentenceFurigana'), isFalse);
    });
  });
}

class _RecordingService extends AnkiConnectService {
  _RecordingService();

  Map<String, String>? existingFields = <String, String>{};
  final List<Map<String, String>> addNoteCalls = <Map<String, String>>[];
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

  /// 假 note 的笔记类型名；null = 服务端没给，仓库跳过类型校验。
  String? noteModelName;

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {}

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
    AnkiDuplicateScope duplicateScope = AnkiDuplicateScope.deck,
  }) async {
    addNoteCalls.add(Map<String, String>.from(fields));
    return 1;
  }

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
