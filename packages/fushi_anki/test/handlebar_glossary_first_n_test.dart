import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// `{glossary-first-<n>}`：前 n 本词典的释义。`{glossary-first}` 只放一本，
/// 一本词典的释义不够用时，用户可以把字段映射换成前两本 / 前三本。
///
/// 与 `{glossary-first}` 同一套「选中优先」（BUG-1035）：长按选中的那本排第一，
/// 其余按弹窗顺序补足。
void main() {
  const Map<String, String> singleGlossaries = <String, String>{
    '三省堂国語辞典 第八版': '<A>',
    '大辞泉 第二版': '<B>',
    '日本語俗語辞書': '<C>',
    '新明解国語辞典': '<D>',
  };

  const AnkiMiningContext context = AnkiMiningContext(sentence: 'ポリが来た！');

  AnkiMiningPayload payloadWith(
    String selected, {
    Map<String, String> glossaries = singleGlossaries,
  }) => AnkiMiningPayload(
    expression: 'ポリ',
    singleGlossaries: glossaries,
    glossaryFirst: glossaries.isEmpty ? '' : glossaries.values.first,
    selectedDictionary: selected,
  );

  String render(String template, AnkiMiningPayload payload) =>
      AnkiHandlebarRenderer.render(template, payload, context);

  group('{glossary-first-<n>}', () {
    test('没选中 → 按弹窗顺序取前 n 本', () {
      expect(render('{glossary-first-2}', payloadWith('')), '<A><B>');
      expect(render('{glossary-first-3}', payloadWith('')), '<A><B><C>');
    });

    test('选中的那本排第一，其余按原顺序补足', () {
      expect(render('{glossary-first-2}', payloadWith('日本語俗語辞書')), '<C><A>');
      expect(render('{glossary-first-3}', payloadWith('日本語俗語辞書')), '<C><A><B>');
    });

    test('选中的已在前 n 本内 → 不重复', () {
      expect(render('{glossary-first-3}', payloadWith('大辞泉 第二版')), '<B><A><C>');
    });

    test('选中名带 [n] 后缀按归一化命中', () {
      expect(
        render('{glossary-first-2}', payloadWith('新明解国語辞典 [4]')),
        '<D><A>',
      );
    });

    test('选中名查不到 → 当作没选中', () {
      expect(render('{glossary-first-2}', payloadWith('存在しない辞典')), '<A><B>');
    });

    test('词典不足 n 本 → 有几本给几本', () {
      expect(
        render(
          '{glossary-first-3}',
          payloadWith('', glossaries: const <String, String>{'X': '<X>'}),
        ),
        '<X>',
      );
    });

    test('singleGlossaries 为空（旧发送端）→ 退回 glossaryFirst', () {
      const AnkiMiningPayload payload = AnkiMiningPayload(
        expression: 'ポリ',
        glossaryFirst: '<legacy>',
      );
      expect(render('{glossary-first-2}', payload), '<legacy>');
    });

    test('前一本与 {glossary-first} 同值', () {
      for (final String selected in <String>['', '日本語俗語辞書']) {
        expect(
          render('{glossary-first-1}', payloadWith(selected)),
          render('{glossary-first}', payloadWith(selected)),
        );
      }
    });

    test('手写模板里溢出 int64 的数字 → 空串，不让整张卡制卡失败', () {
      expect(
        render(
          '<{glossary-first-99999999999999999999}>{expression}',
          payloadWith(''),
        ),
        '<>ポリ',
      );
    });

    test('映射界面提供前两本 / 前三本', () {
      expect(
        AnkiHandlebarOptions.coreOptions,
        containsAll(<String>['{glossary-first-2}', '{glossary-first-3}']),
      );
    });
  });
}
