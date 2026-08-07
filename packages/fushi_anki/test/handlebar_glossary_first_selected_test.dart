import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-1035：弹窗里长按选中的词典必须真的落到卡片主释义上。
///
/// 回归背景：`{glossary-first}` 原本只读 [AnkiMiningPayload.glossaryFirst]（popup.js
/// 的 `Object.values(singleGlossaries)[0]`，恒是排在第一位的那本词典），而全模板里只有
/// `{selected-glossary}` 消费 [AnkiMiningPayload.selectedDictionary]。Lapis 出厂默认把
/// `MainDefinition` 映射成 `{glossary-first}`，于是「长按词典标题选中」在默认配置下是**死
/// 交互**：弹窗把标题染成主题色加粗给了明确「已选中」反馈，制出的卡片主释义却恒是第一本。
///
/// 修复语义：`{glossary-first}` = 选中优先，没选中才退回第一本。没长按时逐字节零变化。
void main() {
  const Map<String, String> singleGlossaries = <String, String>{
    '三省堂国語辞典 第八版': '〔俗〕←ポリス。',
    '大辞泉 第二版': '「ポリス」「ポリスマン」の略。',
    '日本語俗語辞書': 'ポリとは、警察、警察官、巡査のこと。',
  };

  const AnkiMiningContext context = AnkiMiningContext(sentence: 'ポリが来た！');

  AnkiMiningPayload payloadWith(String selected) => AnkiMiningPayload(
        expression: 'ポリ',
        singleGlossaries: singleGlossaries,
        // popup.js 恒把「第一本」放进 glossaryFirst，与选中无关。
        glossaryFirst: singleGlossaries.values.first,
        selectedDictionary: selected,
      );

  String renderFirst(AnkiMiningPayload payload) =>
      AnkiHandlebarRenderer.render('{glossary-first}', payload, context);

  group('{glossary-first} 选中优先（BUG-1035）', () {
    test('长按选中第二本 → 主释义取那本，而不是第一本', () {
      final String value = renderFirst(payloadWith('大辞泉 第二版'));
      expect(value, '「ポリス」「ポリスマン」の略。');
      expect(value, isNot(singleGlossaries.values.first),
          reason: '选中了却仍渲染第一本 = 长按是死交互，正是 BUG-1035 的症状');
    });

    test('长按选中第三本 → 主释义取那本', () {
      expect(renderFirst(payloadWith('日本語俗語辞書')), 'ポリとは、警察、警察官、巡査のこと。');
    });

    test('没长按（selectedDictionary 空）→ 逐字节退回第一本（零破坏）', () {
      expect(renderFirst(payloadWith('')), singleGlossaries.values.first);
    });

    test('选中的词典名在 singleGlossaries 里查不到 → 退回第一本，不产出空字段', () {
      expect(
          renderFirst(payloadWith('存在しない辞典')), singleGlossaries.values.first);
    });

    test('词典名带 [n] 后缀时按归一化命中（与 {selected-glossary} 同一匹配规则）', () {
      expect(renderFirst(payloadWith('大辞泉 第二版 [2]')), '「ポリス」「ポリスマン」の略。');
    });

    test('选中时 {glossary-first} 与 {selected-glossary} 同值', () {
      final AnkiMiningPayload payload = payloadWith('大辞泉 第二版');
      expect(
        renderFirst(payload),
        AnkiHandlebarRenderer.render('{selected-glossary}', payload, context),
      );
    });

    test('{selected-glossary} 语义不变：没选中时仍是空串（不被本次 fallback 污染）', () {
      expect(
        AnkiHandlebarRenderer.render(
            '{selected-glossary}', payloadWith(''), context),
        '',
      );
    });

    test('{glossary} 全量释义不受选中影响', () {
      const AnkiMiningPayload payload = AnkiMiningPayload(
        expression: 'ポリ',
        glossary: '全部辞書の釈義',
        singleGlossaries: singleGlossaries,
        selectedDictionary: '大辞泉 第二版',
      );
      expect(AnkiHandlebarRenderer.render('{glossary}', payload, context),
          '全部辞書の釈義');
    });
  });

  group('Lapis 默认映射前提（BUG-1035 的放大器）', () {
    test('MainDefinition 仍映射 {glossary-first}——故本修复必须落在该键上', () {
      expect(LapisNoteType.defaultFieldMappings['MainDefinition'],
          '{glossary-first}');
    });
  });
}
