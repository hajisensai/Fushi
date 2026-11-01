import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 走真实落卡渲染路径（`renderMediaPayload` → `buildMinedFields`）的最小 repo。
class _RenderPathRepo extends BaseAnkiRepository {
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

  Map<String, String> renderFor({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
  }) => renderMediaPayload(
    settings: settings,
    payload: payload,
    context: const AnkiMiningContext(sentence: '猫が好きです。'),
    coverRef: null,
    sentenceAudioRef: null,
    processedAudio: '',
    dictionaryMediaTags: const <String, String>{},
  ).fields;
}

/// 反馈 -K86qlwBg6：「高级制卡」里手改的卡片字段（[MiningRequestOverrides.fieldValues]）
/// 只替换这一张卡的对应字段。
///
/// 钉三件事：① wire 编解码（空白值不进 wire、坏项丢弃、旧主机不认的键不影响其余覆盖）；
/// ② 真实落卡渲染路径上，改过的字段整段替换、没改的照模板生成；③ 不在映射里的字段名
/// 不会凭空多写一个字段。②是关键：渲染前那一跳会重建一份 payload，漏抄 overrides
/// 就会让手改在落卡时静默丢失——直接测渲染器照不出来。
void main() {
  group('MiningRequestOverrides.fieldValues wire', () {
    test('JSON 往返保留手改字段', () {
      const MiningRequestOverrides o = MiningRequestOverrides(
        fieldValues: <String, String>{'MainDefinition': '<b>猫</b>：ねこ'},
      );
      expect(o.isEmpty, isFalse);
      final Map<String, String> wire = MiningRequestOverrides.attach(
        <String, String>{'expression': '猫'},
        o,
      );
      final MiningRequestOverrides? back = MiningRequestOverrides.readFrom(
        wire,
      );
      expect(back?.fieldValues, <String, String>{
        'MainDefinition': '<b>猫</b>：ねこ',
      });
    });

    test('空白值 / 非字符串值 / 空键在解码时丢弃，全丢光等于没有覆盖', () {
      final MiningRequestOverrides o = MiningRequestOverrides.fromJson(
        <String, Object?>{
          'fields': <String, Object?>{'Sentence': '   ', 'Hint': 3, '': 'x'},
        },
      );
      expect(o.fieldValues, isEmpty);
      expect(o.isEmpty, isTrue);
    });

    test('只改字段时其它覆盖维度保持默认', () {
      final MiningRequestOverrides o = MiningRequestOverrides.fromJson(
        <String, Object?>{
          'fields': <String, Object?>{'Sentence': 'A'},
        },
      );
      expect(o.deckName, isNull);
      expect(o.omitAudio, isFalse);
      expect(o.mosaic, isEmpty);
      expect(o.fieldValues, <String, String>{'Sentence': 'A'});
    });
  });

  group('buildMinedFields 应用手改字段（真实落卡渲染路径）', () {
    const AnkiSettings settings = AnkiSettings(
      fieldMappings: <String, String>{
        'Expression': '{expression}',
        'Sentence': '{sentence}',
        'MainDefinition': '{glossary-first}',
      },
    );

    AnkiMiningPayload payload({MiningRequestOverrides? overrides}) =>
        AnkiMiningPayload(
          expression: '猫',
          glossaryFirst: '<ol><li>cat</li></ol>',
          overrides: overrides,
        );

    test('没手改：照模板生成', () {
      final Map<String, String> fields = _RenderPathRepo().renderFor(
        settings: settings,
        payload: payload(),
      );
      expect(fields['MainDefinition'], '<ol><li>cat</li></ol>');
      expect(fields['Sentence'], '猫が好きです。');
    });

    test('手改的字段整段替换，没改的照模板', () {
      final Map<String, String> fields = _RenderPathRepo().renderFor(
        settings: settings,
        payload: payload(
          overrides: const MiningRequestOverrides(
            fieldValues: <String, String>{'MainDefinition': '  ねこ（猫）：小型の家畜  '},
          ),
        ),
      );
      expect(fields['MainDefinition'], 'ねこ（猫）：小型の家畜');
      expect(fields['Expression'], '猫');
      expect(fields['Sentence'], '猫が好きです。');
    });

    test('不在映射里的字段名不会多写一个字段', () {
      final Map<String, String> fields = _RenderPathRepo().renderFor(
        settings: settings,
        payload: payload(
          overrides: const MiningRequestOverrides(
            fieldValues: <String, String>{'Notes': 'stray'},
          ),
        ),
      );
      expect(fields.containsKey('Notes'), isFalse);
      expect(fields['MainDefinition'], '<ol><li>cat</li></ol>');
    });

    test('经 wire 解析出来的 payload 同样生效（宿主真实入口）', () {
      final Map<String, String> wire = MiningRequestOverrides.attach(
        <String, String>{'expression': '猫', 'glossaryFirst': 'cat'},
        const MiningRequestOverrides(
          fieldValues: <String, String>{'Sentence': '手で直した例文。'},
        ),
      );
      final AnkiMiningPayload parsed = AnkiMiningPayload.fromJson(wire);
      final Map<String, String> fields = _RenderPathRepo().renderFor(
        settings: settings,
        payload: parsed,
      );
      expect(fields['Sentence'], '手で直した例文。');
    });
  });
}
