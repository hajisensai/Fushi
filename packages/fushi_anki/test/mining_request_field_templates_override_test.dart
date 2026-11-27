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
    keepEmpty: true,
  ).fields;
}

/// 拍板台 b1JDe8McbS：查词弹窗的每颗制卡按钮绑一套制卡方案，方案只记它和字段映射
/// 不一样的字段模板（[MiningRequestOverrides.fieldTemplates]），随这一次请求走。
///
/// 钉：① wire 往返（空串模板保留 = 该字段留空；非字符串 / 空键丢弃）；② 真实落卡渲染
/// 路径上只替换被改的字段、其余继承映射；③ 映射里没有的字段不凭空多写；④ 手写值
/// （高级制卡）优先于方案模板。
void main() {
  group('MiningRequestOverrides.fieldTemplates wire', () {
    test('JSON 往返保留模板，空串模板也保留', () {
      const MiningRequestOverrides o = MiningRequestOverrides(
        fieldTemplates: <String, String>{'Expression': '{reading}', 'Hint': ''},
      );
      expect(o.isEmpty, isFalse);
      final Map<String, String> wire = MiningRequestOverrides.attach(
        <String, String>{'expression': '猫'},
        o,
      );
      final MiningRequestOverrides? back = MiningRequestOverrides.readFrom(
        wire,
      );
      expect(back?.fieldTemplates, <String, String>{
        'Expression': '{reading}',
        'Hint': '',
      });
    });

    test('非字符串值 / 空键丢弃，全丢光等于没有覆盖', () {
      final MiningRequestOverrides o = MiningRequestOverrides.fromJson(
        <String, Object?>{
          'fieldTemplates': <String, Object?>{'Hint': 3, '': '{reading}'},
        },
      );
      expect(o.fieldTemplates, isEmpty);
      expect(o.isEmpty, isTrue);
    });
  });

  group('buildMinedFields 应用方案字段模板（真实落卡渲染路径）', () {
    const AnkiSettings settings = AnkiSettings(
      fieldMappings: <String, String>{
        'Expression': '{expression}',
        'Reading': '{reading}',
        'Sentence': '{sentence}',
      },
    );

    AnkiMiningPayload payload({MiningRequestOverrides? overrides}) =>
        AnkiMiningPayload(expression: '猫', reading: 'ねこ', overrides: overrides);

    test('只替换方案改过的字段，其余继承映射', () {
      final Map<String, String> fields = _RenderPathRepo().renderFor(
        settings: settings,
        payload: payload(
          overrides: const MiningRequestOverrides(
            fieldTemplates: <String, String>{'Expression': '{reading}'},
          ),
        ),
      );
      expect(fields['Expression'], 'ねこ');
      expect(fields['Reading'], 'ねこ');
      expect(fields['Sentence'], '猫が好きです。');
    });

    test('空串模板让该字段留空', () {
      final Map<String, String> fields = _RenderPathRepo().renderFor(
        settings: settings,
        payload: payload(
          overrides: const MiningRequestOverrides(
            fieldTemplates: <String, String>{'Sentence': ''},
          ),
        ),
      );
      expect(fields['Sentence'], '');
      expect(fields['Expression'], '猫');
    });

    test('映射里没有的字段名不会多写一个字段', () {
      final Map<String, String> fields = _RenderPathRepo().renderFor(
        settings: settings,
        payload: payload(
          overrides: const MiningRequestOverrides(
            fieldTemplates: <String, String>{'Notes': '{reading}'},
          ),
        ),
      );
      expect(fields.containsKey('Notes'), isFalse);
    });

    test('手写值优先于方案模板', () {
      final Map<String, String> fields = _RenderPathRepo().renderFor(
        settings: settings,
        payload: payload(
          overrides: const MiningRequestOverrides(
            fieldTemplates: <String, String>{'Expression': '{reading}'},
            fieldValues: <String, String>{'Expression': '手写'},
          ),
        ),
      );
      expect(fields['Expression'], '手写');
    });

    test('经 wire 解析出来的 payload 同样生效（宿主真实入口）', () {
      final Map<String, String> wire = MiningRequestOverrides.attach(
        <String, String>{'expression': '猫', 'reading': 'ねこ'},
        const MiningRequestOverrides(
          fieldTemplates: <String, String>{'Expression': '{reading}'},
        ),
      );
      final AnkiMiningPayload parsed = AnkiMiningPayload.fromJson(wire);
      final Map<String, String> fields = _RenderPathRepo().renderFor(
        settings: settings,
        payload: parsed,
      );
      expect(fields['Expression'], 'ねこ');
    });
  });
}
