import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/advanced_mining_deck_section.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 真实后端渲染器（`previewMinedFields` → `renderMediaPayload` → `buildMinedFields`），
/// 只有网络 / Anki 那几个入口是桩。
class _Repo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() => throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => throw UnimplementedError();

  @override
  Future<bool> isDuplicate(String expression, String reading) =>
      throw UnimplementedError();

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      throw UnimplementedError();

  @override
  Future<bool> createDeck(String name) => throw UnimplementedError();
}

/// 反馈 -K86qlwBg6：「高级制卡」卡片字段分区的组装（字段映射 → 可编辑字段）。
void main() {
  const AnkiSettings settings = AnkiSettings(
    fieldMappings: <String, String>{
      'Expression': '{expression}',
      'Sentence': '{sentence}',
      'MainDefinition': '{glossary-first}',
      'Glossary': '{glossary}',
      'Hint': '',
    },
  );

  List<String> names(AdvancedMiningFieldsSection s) => <String>[
    for (final AdvancedMiningField f in s.fields) f.name,
  ];

  test('字段 = 映射里模板非空的字段（映射顺序），模板原样带上', () {
    final AdvancedMiningFieldsSection s = buildAdvancedMiningFieldsSection(
      settings,
    )!;
    expect(names(s), <String>[
      'Expression',
      'Sentence',
      'MainDefinition',
      'Glossary',
    ]);
    expect(s.fields[2].template, '{glossary-first}');
  });

  test('从没选过：默认显示释义类字段', () {
    final AdvancedMiningFieldsSection s = buildAdvancedMiningFieldsSection(
      settings,
    )!;
    expect(s.visibleFields, <String>{'MainDefinition', 'Glossary'});
  });

  test('记住的选择优先；映射里已不存在的名字丢掉；空列表 = 一个都不显示', () {
    expect(
      buildAdvancedMiningFieldsSection(
        settings,
        remembered: const <String>['Sentence', 'Gone'],
      )!.visibleFields,
      <String>{'Sentence'},
    );
    expect(
      buildAdvancedMiningFieldsSection(
        settings,
        remembered: const <String>[],
      )!.visibleFields,
      isEmpty,
    );
  });

  test('没配字段映射：没有这个分区', () {
    expect(buildAdvancedMiningFieldsSection(const AnkiSettings()), isNull);
  });

  test('落卡时才生成的字段（媒体 / 出处）标成只读', () {
    final AdvancedMiningFieldsSection s = buildAdvancedMiningFieldsSection(
      const AnkiSettings(
        fieldMappings: <String, String>{
          'MainDefinition': '{glossary-first}',
          'Picture': '{card-image}',
          'SentenceAudio': '{sentence-audio}',
        },
      ),
    )!;
    expect(
      <String, bool>{
        for (final AdvancedMiningField f in s.fields)
          f.name: f.generatedAtMining,
      },
      <String, bool>{
        'MainDefinition': false,
        'Picture': true,
        'SentenceAudio': true,
      },
    );
  });

  group('advancedMiningFieldPreview（弹窗 payload → 真实渲染管线）', () {
    const AnkiSettings mapped = AnkiSettings(
      fieldMappings: <String, String>{
        'Sentence': '{sentence}',
        'MainDefinition': '{glossary-first}',
      },
    );
    // 与 mineEntry 桥交给宿主的字段同形（全字符串）。
    const Map<String, String> wirePayload = <String, String>{
      'expression': '猫',
      'glossaryFirst': '<ol><li>cat</li></ol>',
      'singleGlossaries':
          '{"JMdict":"<ol><li>cat</li></ol>","Daijirin":"<p>ねこ</p>"}',
      'selectedDictionary': 'Daijirin',
    };

    test('预填 = 后端 previewMinedFields 的结果；句子取对话框给的那句', () async {
      int fetches = 0;
      final AdvancedMiningFieldPreview preview = advancedMiningFieldPreview(
        repository: _Repo(),
        settings: mapped,
        fetchPayload: () async {
          fetches++;
          return wirePayload;
        },
        fallbackSentence: () => '宿主的当前句。',
      );
      final Map<String, String>? first = await preview('猫が好きです。');
      expect(first, <String, String>{
        'Sentence': '猫が好きです。',
        // 长按选中的词典（selectedDictionary）同样作用在预填上：与落卡一致。
        'MainDefinition': '<p>ねこ</p>',
      });
      final Map<String, String>? second = await preview(null);
      expect(second?['Sentence'], '宿主的当前句。');
      // payload 与句子无关：加减句子只重渲染，不再回 WebView 取。
      expect(fetches, 1);
    });

    test('取不到 payload → null，下次重试', () async {
      int fetches = 0;
      final AdvancedMiningFieldPreview preview = advancedMiningFieldPreview(
        repository: _Repo(),
        settings: mapped,
        fetchPayload: () async {
          fetches++;
          return fetches == 1 ? null : wirePayload;
        },
        fallbackSentence: () => '',
      );
      expect(await preview('a'), isNull);
      expect((await preview('a'))?['MainDefinition'], '<p>ねこ</p>');
      expect(fetches, 2);
    });
  });
}
