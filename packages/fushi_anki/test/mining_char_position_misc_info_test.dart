import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

// 反馈 MhQHXQI-sB：「制卡位置」不再打成一卡一个的 `chars_12345` 标签（把 Anki 标签列表
// 撑爆），而是写进来源字段——Lapis 的 MiscInfo；其它笔记类型写映射里的 MiscInfo 等价
// 字段（`MiscInfo` / `miscInfo` / `Source`），没有就不写。

class _RecordingAnkiConnectService extends AnkiConnectService {
  final List<Map<String, String>> addedFields = <Map<String, String>>[];
  final List<List<String>> addedTags = <List<String>>[];

  @override
  Future<bool> mediaFileExists(String filename) async => false;

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
    addedFields.add(Map<String, String>.from(fields));
    addedTags.add(List<String>.from(tags ?? const <String>[]));
    return addedFields.length;
  }
}

class _ConfiguredAnkiConnectRepository extends AnkiConnectRepository {
  _ConfiguredAnkiConnectRepository({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

AnkiSettings _settings({
  required String noteTypeName,
  required List<String> fields,
  required Map<String, String> mappings,
}) => AnkiSettings(
  selectedDeckId: 1,
  selectedNoteTypeId: 2,
  selectedNoteTypeName: noteTypeName,
  availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
  availableNoteTypes: <AnkiNoteType>[
    AnkiNoteType(id: 2, name: noteTypeName, fields: fields),
  ],
  fieldMappings: mappings,
  allowDupes: true,
);

const String _payload = '{"expression":"勉強","reading":"べんきょう"}';
const String _position = '制卡位置：第 48210 字';

Future<({Map<String, String> fields, List<String> tags})> _mine(
  AnkiSettings settings, {
  String? charPositionText = _position,
  String? documentTitle = 'Kokoro',
}) async {
  final _RecordingAnkiConnectService service = _RecordingAnkiConnectService();
  final _ConfiguredAnkiConnectRepository repo =
      _ConfiguredAnkiConnectRepository(service: service, settings: settings);
  final MineOutcome outcome = await repo.mineEntry(
    rawPayloadJson: _payload,
    context: AnkiMiningContext(
      sentence: '',
      source: AnkiMiningSource.book,
      documentTitle: documentTitle,
      charPositionText: charPositionText,
    ),
  );
  expect(outcome.result, MineResult.success);
  return (fields: service.addedFields.single, tags: service.addedTags.single);
}

void main() {
  group('charPositionTargetField：位置落哪个字段', () {
    test('Lapis：恒为 MiscInfo，映射里没列也照写', () {
      expect(
        AnkiNoteComposer.charPositionTargetField(
          mappedFields: const <String>['Expression'],
          noteTypeName: LapisNoteType.modelName,
        ),
        'MiscInfo',
      );
    });

    test('其它笔记类型：映射里的 MiscInfo 等价字段（忽略大小写）', () {
      // Senren 的 camelCase。
      expect(
        AnkiNoteComposer.charPositionTargetField(
          mappedFields: SenrenPreset.defaultFieldMappings.keys,
          noteTypeName: SenrenPreset.modelName,
        ),
        'miscInfo',
      );
      // Fushi 卡片改名后的 MiscInfo。
      expect(
        AnkiNoteComposer.charPositionTargetField(
          mappedFields: const <String>['Term', 'Source'],
          noteTypeName: 'Fushi Card',
        ),
        'Source',
      );
      // Lapis 系的改名副本 / Kiku 等，名字还是 MiscInfo。
      expect(
        AnkiNoteComposer.charPositionTargetField(
          mappedFields: const <String>['Expression', 'MiscInfo'],
          noteTypeName: 'Kiku',
        ),
        'MiscInfo',
      );
    });

    test('其它笔记类型没有等价字段：不写（不猜一个别的字段塞进去）', () {
      expect(
        AnkiNoteComposer.charPositionTargetField(
          mappedFields: const <String>['Front', 'Back', 'Sentence'],
          noteTypeName: 'Basic',
        ),
        isNull,
      );
    });
  });

  group('落卡：位置写进 MiscInfo，不再进标签', () {
    test('Lapis：追加在 MiscInfo 渲染值之后（<br> 分隔），标签里没有 chars_', () async {
      final r = await _mine(
        _settings(
          noteTypeName: LapisNoteType.modelName,
          fields: LapisNoteType.fields,
          mappings: const <String, String>{
            'Expression': '{expression}',
            'MiscInfo': '{document-title}',
          },
        ),
      );
      expect(r.fields['MiscInfo'], 'Kokoro<br>$_position');
      expect(r.tags, <String>['fushi', 'book']);
      expect(r.tags.any((String t) => t.startsWith('chars_')), isFalse);
    });

    test('Lapis：MiscInfo 渲染为空 / 未映射时只写位置本身', () async {
      final r = await _mine(
        _settings(
          noteTypeName: LapisNoteType.modelName,
          fields: LapisNoteType.fields,
          mappings: const <String, String>{'Expression': '{expression}'},
        ),
      );
      expect(r.fields['MiscInfo'], _position);
    });

    test('非 Lapis 有等价字段（Senren miscInfo）：写进去', () async {
      final r = await _mine(
        _settings(
          noteTypeName: SenrenPreset.modelName,
          fields: const <String>['word', 'miscInfo'],
          mappings: const <String, String>{
            'word': '{expression}',
            'miscInfo': '{document-title}',
          },
        ),
      );
      expect(r.fields['miscInfo'], 'Kokoro<br>$_position');
    });

    test('非 Lapis 无等价字段：任何字段都不多一个字，也不打标签', () async {
      final r = await _mine(
        _settings(
          noteTypeName: 'Basic',
          fields: const <String>['Front', 'Back'],
          mappings: const <String, String>{
            'Front': '{expression}',
            'Back': '{reading}',
          },
        ),
      );
      expect(r.fields, <String, String>{'Front': '勉強', 'Back': 'べんきょう'});
      expect(r.tags, <String>['fushi', 'book']);
    });

    test('开关关闭 / 锚点取不到（null）：MiscInfo 原样', () async {
      final r = await _mine(
        _settings(
          noteTypeName: LapisNoteType.modelName,
          fields: LapisNoteType.fields,
          mappings: const <String, String>{
            'Expression': '{expression}',
            'MiscInfo': '{document-title}',
          },
        ),
        charPositionText: null,
      );
      expect(r.fields['MiscInfo'], 'Kokoro');
    });
  });

  group('appendCharPosition', () {
    test('位置文本 HTML 转义（互联转发端送来的是外部输入）', () {
      final Map<String, String> fields = <String, String>{'MiscInfo': 'a'};
      AnkiNoteComposer.appendCharPosition(
        fields: fields,
        charPositionText: '<b>1</b>',
        mappedFields: fields.keys.toList(),
        noteTypeName: 'Other',
        manualFields: const <String, String>{},
      );
      expect(fields['MiscInfo'], 'a<br>&lt;b&gt;1&lt;&#47;b&gt;');
    });

    test('「高级制卡」手改过目标字段：不再追加（预览已带位置，避免重复）', () {
      final Map<String, String> fields = <String, String>{
        'MiscInfo': 'Kokoro<br>$_position',
      };
      AnkiNoteComposer.appendCharPosition(
        fields: fields,
        charPositionText: _position,
        mappedFields: fields.keys.toList(),
        noteTypeName: LapisNoteType.modelName,
        manualFields: <String, String>{'MiscInfo': 'Kokoro<br>$_position'},
      );
      expect(fields['MiscInfo'], 'Kokoro<br>$_position');
    });

    test('空白位置文本什么都不写', () {
      final Map<String, String> fields = <String, String>{'MiscInfo': 'a'};
      AnkiNoteComposer.appendCharPosition(
        fields: fields,
        charPositionText: '   ',
        mappedFields: fields.keys.toList(),
        noteTypeName: LapisNoteType.modelName,
        manualFields: const <String, String>{},
      );
      expect(fields, <String, String>{'MiscInfo': 'a'});
    });
  });

  test('withMediaRefs 原样带过制卡位置（媒体落盘不该丢位置）', () {
    // AnkiMiningContext 每新增一个字段就漏抄一次的老坑（见该类注释）：落卡路径
    // 统一经 withMediaRefs 重建 context，漏抄这一行 → 带媒体的卡恒无位置。
    const AnkiMiningContext context = AnkiMiningContext(
      sentence: 'x',
      source: AnkiMiningSource.book,
      charPositionText: _position,
    );
    expect(
      context
          .withMediaRefs(coverRef: null, sentenceAudioRef: null)
          .charPositionText,
      _position,
    );
    expect(context.withSourceLink(null).charPositionText, _position);
  });
}
