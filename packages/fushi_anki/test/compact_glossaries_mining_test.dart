import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// issue #1432：制卡「紧凑释义」开关此前只被写入和显示，导出释义从不带紧凑样式。
/// 这里走真实落卡渲染路径（`renderMediaPayload` → `buildMinedFields`），锁定
/// 开 = 每个释义占位符都带紧凑样式、关 = 输出逐字节不变。
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
    context: const AnkiMiningContext(sentence: ''),
    coverRef: null,
    sentenceAudioRef: null,
    processedAudio: '',
    dictionaryMediaTags: const <String, String>{},
  ).fields;
}

/// popup.js `constructSingleGlossaryHtml` / `constructGlossaryHtml` 的产物形状：
/// 词典样式的 `<style>` 在 `.yomitan-glossary` 容器收尾之前。
String _glossaryDiv(String dict, String items) =>
    '<div style="text-align: left;" class="yomitan-glossary"><ol>'
    '<li data-dictionary="$dict"><i>($dict)</i> <span>'
    '<ul data-sc-content="glossary"><li>$items</li><li>two</li></ul>'
    '</span></li></ol><style>.x { color: red; }</style></div>';

void main() {
  const String compactStyle = '<style>$kCompactGlossariesAnkiCss</style>';
  final String jmdict = _glossaryDiv('JMdict', 'one');
  final String daijirin = _glossaryDiv('大辞林', 'ひとつ');
  final AnkiMiningPayload payload = AnkiMiningPayload(
    expression: '言葉',
    glossary: _glossaryDiv('all', 'one'),
    glossaryFirst: jmdict,
    singleGlossaries: <String, String>{'JMdict': jmdict, '大辞林': daijirin},
  );
  const Map<String, String> mappings = <String, String>{
    'Expression': '{expression}',
    'Glossary': '{glossary}',
    'First': '{glossary-first}',
    'FirstTwo': '{glossary-first-2}',
  };
  final _RenderPathRepo repo = _RenderPathRepo();

  group('compactAnkiGlossaryHtml', () {
    test('关闭时原样返回', () {
      expect(compactAnkiGlossaryHtml(jmdict, enabled: false), same(jmdict));
      final Map<String, String> m = <String, String>{'a': jmdict};
      expect(compactAnkiGlossaryMap(m, enabled: false), same(m));
    });

    test('开启时插在 .yomitan-glossary 容器收尾之前，与原 JS 分支同形', () {
      final String out = compactAnkiGlossaryHtml(jmdict, enabled: true);
      expect(
        out,
        '${jmdict.substring(0, jmdict.length - '</div>'.length)}'
        '$compactStyle</div>',
      );
    });

    test('空释义不注入、已注入不重复', () {
      expect(compactAnkiGlossaryHtml('', enabled: true), '');
      final String once = compactAnkiGlossaryHtml(jmdict, enabled: true);
      expect(compactAnkiGlossaryHtml(once, enabled: true), once);
    });

    test('样式与 Yomitan 同语义：行内列表 + 灰色 | 分隔', () {
      expect(kCompactGlossariesAnkiCss, contains('content: " | "'));
      expect(kCompactGlossariesAnkiCss, contains('display: inline'));
      expect(kCompactGlossariesAnkiCss, contains('list-style: none'));
    });
  });

  group('真实落卡路径（renderMediaPayload → buildMinedFields）', () {
    test('开关关闭：释义字段不带紧凑样式', () {
      final Map<String, String> off = repo.renderFor(
        settings: AnkiSettings(fieldMappings: mappings),
        payload: payload,
      );
      for (final String key in <String>['Glossary', 'First', 'FirstTwo']) {
        expect(off[key], isNotEmpty, reason: key);
        expect(off[key], isNot(contains(kCompactGlossariesAnkiCss)));
      }
    });

    test('开关打开：每个释义占位符都带紧凑样式，其余字节与关闭时一致', () {
      final Map<String, String> off = repo.renderFor(
        settings: AnkiSettings(fieldMappings: mappings),
        payload: payload,
      );
      final Map<String, String> on = repo.renderFor(
        settings: AnkiSettings(
          fieldMappings: mappings,
          compactGlossaries: true,
        ),
        payload: payload,
      );
      expect(on['Expression'], off['Expression']);
      expect(
        on['Glossary'],
        compactAnkiGlossaryHtml(off['Glossary']!, enabled: true),
      );
      expect(
        on['First'],
        compactAnkiGlossaryHtml(off['First']!, enabled: true),
      );
      // {glossary-first-2} 拼两本词典：两段各自带一份。
      expect(compactStyle.allMatches(on['FirstTwo']!), hasLength(2));
      expect(on['FirstTwo']!.replaceAll(compactStyle, ''), off['FirstTwo']);
    });

    test('长按选中的词典（{glossary-first} 走 singleGlossaries）同样带样式', () {
      final AnkiMiningPayload selected = AnkiMiningPayload(
        expression: '言葉',
        glossaryFirst: jmdict,
        singleGlossaries: <String, String>{'JMdict': jmdict, '大辞林': daijirin},
        selectedDictionary: '大辞林',
      );
      final Map<String, String> on = repo.renderFor(
        settings: AnkiSettings(
          fieldMappings: mappings,
          compactGlossaries: true,
        ),
        payload: selected,
      );
      expect(on['First'], contains('ひとつ'));
      expect(on['First'], contains(compactStyle));
    });
  });
}
