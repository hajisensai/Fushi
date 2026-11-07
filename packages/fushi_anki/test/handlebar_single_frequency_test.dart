import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-4226（反馈 ArXVzMKmM5）：Yomitan 的逐词典频率标记
/// `{single-frequency-number-<词典>}` / `{single-frequency-<词典>}` 映射后字段为空。
///
/// 根因：制卡 payload 只带调和平均（`freqHarmonicRank`）与全部词典的列表 HTML，
/// 没有逐词典频率；渲染器 `_handlebarToValue` 也不认这两个标记，落到 `default`
/// 返回空串。用户把 FreqSort 映射成 `{single-frequency-number-jiten}` 制卡后为空。
///
/// 语义对齐 Yomitan（`anki-template-util.js` `getDynamicTemplates` +
/// `default-anki-field-templates.handlebars` 的 `single-frequency-number` /
/// `frequencies` partial）：标记里的词典名是 `getKebabCase(词典名)`。
/// popup.js 一侧的取数由 `fushi/test/anki/single_frequency_mining_test.js` 守。
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

void main() {
  const String jitenHtml =
      '<ul style="text-align: left;"><li>Jiten: 1234</li></ul>';
  const String bccwjHtml =
      '<ul style="text-align: left;"><li>BCCWJ Long [2]: 88㋕</li></ul>';
  const Map<String, String> numbers = <String, String>{
    'Jiten': '1234',
    'BCCWJ Long [2]': '88',
  };
  const Map<String, String> htmls = <String, String>{
    'Jiten': jitenHtml,
    'BCCWJ Long [2]': bccwjHtml,
  };
  const AnkiMiningContext context = AnkiMiningContext(sentence: '');
  const AnkiMiningPayload payload = AnkiMiningPayload(
    expression: '言葉',
    freqHarmonicRank: '163',
    singleFrequencyNumbers: numbers,
    singleFrequenciesHtml: htmls,
  );

  String render(String template, [AnkiMiningPayload p = payload]) =>
      AnkiHandlebarRenderer.render(template, p, context);

  group('{single-frequency-number-<词典>}', () {
    test('Yomitan kebab 名（反馈原样的 jiten）→ 该词典的频率数', () {
      expect(render('{single-frequency-number-jiten}'), '1234');
    });

    test('词典真名同样命中', () {
      expect(render('{single-frequency-number-Jiten}'), '1234');
    });

    test('带空格与 [n] 后缀的词典：kebab 名与去后缀名都命中', () {
      // getKebabCase('BCCWJ Long [2]') == 'bccwj-long-2'
      expect(render('{single-frequency-number-bccwj-long-2}'), '88');
      expect(render('{single-frequency-number-BCCWJ Long}'), '88');
    });

    test('不在表里的词典给空串（Yomitan 同样渲染为空）', () {
      expect(render('{single-frequency-number-jpdb}'), '');
    });

    test('不被短前缀 {single-frequency-<词典>} 抢走', () {
      expect(render('{single-frequency-number-jiten}'), isNot(jitenHtml));
    });
  });

  group('{single-frequency-<词典>}', () {
    test('只含该词典的频率列表 HTML', () {
      expect(render('{single-frequency-jiten}'), jitenHtml);
      expect(render('{single-frequency-bccwj-long-2}'), bccwjHtml);
      expect(render('{single-frequency-jpdb}'), '');
    });
  });

  group('AnkiMiningPayload.fromJson', () {
    test('WebView 桥：popup.js JSON.stringify 的字符串形态', () {
      final AnkiMiningPayload parsed =
          AnkiMiningPayload.fromJson(<String, dynamic>{
            'expression': '言葉',
            'singleFrequencyNumbers': jsonEncode(numbers),
            'singleFrequenciesHtml': jsonEncode(htmls),
          });
      expect(parsed.singleFrequencyNumbers, numbers);
      expect(parsed.singleFrequenciesHtml, htmls);
      expect(render('{single-frequency-number-jiten}', parsed), '1234');
    });

    test('保类型 JSON：原生 Map 形态', () {
      final AnkiMiningPayload parsed =
          AnkiMiningPayload.fromJson(<String, dynamic>{
            'expression': '言葉',
            'singleFrequencyNumbers': numbers,
            'singleFrequenciesHtml': htmls,
          });
      expect(parsed.singleFrequencyNumbers, numbers);
      expect(parsed.singleFrequenciesHtml, htmls);
    });

    test('旧发送端不带这两个键：空表，标记渲染为空而非抛错', () {
      final AnkiMiningPayload parsed = AnkiMiningPayload.fromJson(
        <String, dynamic>{'expression': '言葉'},
      );
      expect(parsed.singleFrequencyNumbers, isEmpty);
      expect(render('{single-frequency-number-jiten}', parsed), '');
    });
  });

  test('真实落卡路径（renderMediaPayload 重建 payload）不丢逐词典频率', () {
    final Map<String, String> fields = _RenderPathRepo().renderFor(
      settings: AnkiSettings(
        fieldMappings: const <String, String>{
          'FreqSort': '{single-frequency-number-jiten}',
          'Frequency': '{single-frequency-jiten}',
        },
      ),
      payload: payload,
    );
    expect(fields['FreqSort'], '1234');
    expect(fields['Frequency'], jitenHtml);
  });

  test('yomitanKebabCase 逐字对齐 Yomitan getKebabCase', () {
    expect(AnkiHandlebarRenderer.yomitanKebabCase('Jiten'), 'jiten');
    expect(
      AnkiHandlebarRenderer.yomitanKebabCase('BCCWJ Long [2]'),
      'bccwj-long-2',
    );
    expect(
      AnkiHandlebarRenderer.yomitanKebabCase('JPDB_v2.2　Freq'),
      'jpdb-v22-freq',
    );
    expect(AnkiHandlebarRenderer.yomitanKebabCase('大辞林 第四版'), '大辞林-第四版');
  });

  test('字段候选：频率词典各出一个 {single-frequency-number-<名>}', () {
    final List<String> options = AnkiHandlebarOptions.optionsForField(
      dictionaryNames: const <String>['JMdict'],
      frequencyDictionaryNames: const <String>['Jiten', 'Jiten'],
      currentValue: '',
    );
    expect(
      options.where((String o) => o.startsWith('{single-frequency-number-')),
      <String>['{single-frequency-number-Jiten}'],
    );
  });
}
