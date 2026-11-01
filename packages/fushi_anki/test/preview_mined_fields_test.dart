import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 走真实落卡渲染路径（`renderMediaPayload` → `buildMinedFields`）的最小 repo。
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

  /// 确认后真正落卡时的渲染（带上本次的词典媒体引用）。
  Map<String, String> mine({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    Map<String, String> dictionaryMediaTags = const <String, String>{},
  }) => renderMediaPayload(
    settings: settings,
    payload: payload,
    context: context,
    coverRef: '<img src="cover.webp">',
    sentenceAudioRef: '[sound:sentence.mp3]',
    processedAudio: '[sound:word.mp3]',
    dictionaryMediaTags: dictionaryMediaTags,
  ).fields;
}

/// 反馈 -K86qlwBg6：「高级制卡」字段预填走与落卡**同一条**渲染管线
/// （[AnkiNoteComposer.previewMinedFields]），没改的字段与落卡结果逐字节一致；改过的
/// 字段里的词典媒体占位符在落卡时照常换成本次的媒体引用。
void main() {
  const AnkiSettings settings = AnkiSettings(
    fieldMappings: <String, String>{
      'Expression': '{expression}',
      'Sentence': '{sentence}',
      'MainDefinition': '{glossary-first}',
      'Picture': '{card-image}',
      'SentenceAudio': '{sentence-audio}',
      'MiscInfo': '{document-title}',
    },
  );
  const String gloss =
      '<ol><li>cat <img src="fushi_dict_0.svg" alt="[猫]"></li></ol>';
  const AnkiMiningPayload payload = AnkiMiningPayload(
    expression: '猫',
    glossaryFirst: gloss,
    singleGlossaries: <String, String>{
      'JMdict': gloss,
      'Daijirin': '<p>ねこ</p>',
    },
  );
  const AnkiMiningContext context = AnkiMiningContext(sentence: '猫が好きです。');

  test('预填 = 落卡管线的文本字段（选中词典同样生效），媒体字段为空', () {
    final Map<String, String> preview = _Repo().previewMinedFields(
      settings: settings,
      payload: const AnkiMiningPayload(
        expression: '猫',
        glossaryFirst: gloss,
        singleGlossaries: <String, String>{
          'JMdict': gloss,
          'Daijirin': '<p>ねこ</p>',
        },
        selectedDictionary: 'Daijirin',
      ),
      context: context,
    );
    expect(preview['Expression'], '猫');
    expect(preview['Sentence'], '猫が好きです。');
    expect(preview['MainDefinition'], '<p>ねこ</p>');
    expect(preview['Picture'], '');
    expect(preview['SentenceAudio'], '');
    // keepEmpty：映射里的每个字段都在（对话框按映射列字段）。
    expect(preview.keys.toSet(), settings.fieldMappings.keys.toSet());
  });

  test('预填保留词典媒体占位符；不改直接落卡与预填的文本逐字节一致', () {
    final _Repo repo = _Repo();
    final Map<String, String> preview = repo.previewMinedFields(
      settings: settings,
      payload: payload,
      context: context,
    );
    expect(preview['MainDefinition'], contains('fushi_dict_0.svg'));
    final Map<String, String> mined = repo.mine(
      settings: settings,
      payload: payload,
      context: context,
      dictionaryMediaTags: const <String, String>{
        'fushi_dict_0.svg': 'fushi_abc.svg',
      },
    );
    expect(
      mined['MainDefinition'],
      preview['MainDefinition']!.replaceAll(
        'fushi_dict_0.svg',
        'fushi_abc.svg',
      ),
    );
    expect(mined['Sentence'], preview['Sentence']);
  });

  test('改过的释义（含占位符）落卡时占位符换成本次媒体引用，媒体字段照常生成', () {
    final _Repo repo = _Repo();
    final String edited = repo
        .previewMinedFields(
          settings: settings,
          payload: payload,
          context: context,
        )['MainDefinition']!
        .replaceAll('cat', 'cat (pet)');
    final Map<String, String> mined = repo.mine(
      settings: settings,
      payload: AnkiMiningPayload(
        expression: '猫',
        glossaryFirst: gloss,
        overrides: MiningRequestOverrides(
          fieldValues: <String, String>{'MainDefinition': edited},
        ),
      ),
      context: context,
      dictionaryMediaTags: const <String, String>{
        'fushi_dict_0.svg': 'fushi_abc.svg',
      },
    );
    expect(mined['MainDefinition'], contains('cat (pet)'));
    expect(mined['MainDefinition'], contains('fushi_abc.svg'));
    expect(mined['MainDefinition'], isNot(contains('fushi_dict_0')));
    expect(mined['Picture'], '<img src="cover.webp">');
    expect(mined['SentenceAudio'], '[sound:sentence.mp3]');
  });

  test('落卡时才生成的占位符判据', () {
    expect(AnkiNoteComposer.isLateBoundTemplate('{card-image}'), isTrue);
    expect(
      AnkiNoteComposer.isLateBoundTemplate('{sentence}<br>{sentence-audio}'),
      isTrue,
    );
    expect(
      AnkiNoteComposer.isLateBoundTemplate('{document-title} {clip-timestamp}'),
      isTrue,
    );
    expect(AnkiNoteComposer.isLateBoundTemplate('{glossary-first}'), isFalse);
    expect(AnkiNoteComposer.isLateBoundTemplate('{sentence}'), isFalse);
  });
}
