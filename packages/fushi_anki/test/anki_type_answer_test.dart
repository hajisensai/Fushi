// DAgSPc8ixN：Anki 打字输入答案（`{{type:Field}}`）的标记解析、问题面输入框、答案面比对。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

void main() {
  ({String question, String answer}) resolve(
    String question,
    String answer,
    Map<String, String> fields, {
    int ord = 0,
  }) => ankiResolveTypeAnswer(
    question: question,
    answer: answer,
    fields: fields,
    cardOrd: ord,
  );

  test('没有标记时原样返回', () {
    final ({String question, String answer}) r = resolve(
      'Q',
      'A',
      const <String, String>{},
    );
    expect(r.question, 'Q');
    expect(r.answer, 'A');
  });

  test('问题面：第一个标记换成输入框，其余去掉；答案面每个标记都是比对占位', () {
    final ({String question, String answer}) r = resolve(
      'x [[type:Back]] y [[type:Back]]',
      'x [[type:Back]]',
      <String, String>{'Back': ' <i>dog</i>  house '},
    );
    expect(
      RegExp('<input type="text" id="typeans"').allMatches(r.question),
      hasLength(1),
    );
    expect(r.question, isNot(contains('[[type:')));
    expect(r.answer, contains('data-expected="dog house"'));
    expect(r.answer, contains('data-combining="1"'));
    expect(ankiHasTypeAnswerSlot(r.answer), isTrue);
  });

  test('cloze: 取本卡挖空内容；nc: 比对忽略组合附加符号', () {
    final ({String question, String answer}) c = resolve(
      '[[type:cloze:Text]]',
      '[[type:cloze:Text]]',
      <String, String>{'Text': '{{c1::東京}}と{{c2::大阪}}'},
      ord: 1,
    );
    expect(c.answer, contains('data-expected="大阪"'));

    final ({String question, String answer}) n = resolve(
      '[[type:nc:Back]]',
      '[[type:nc:Back]]',
      <String, String>{'Back': 'café'},
    );
    expect(n.answer, contains('data-combining="0"'));
    // e + U+0301（组合尖音符）
    final String filled = ankiFillTypeAnswer(n.answer, 'cafe');
    expect(filled, contains('<span class="typeGood">café</span>'));
  });

  test('字段不存在：两面都写出提示，不抛错', () {
    final ({String question, String answer}) r = resolve(
      '[[type:Nope]]',
      '[[type:Nope]]',
      const <String, String>{},
    );
    expect(r.question, contains('fushi-typeans-error'));
    expect(r.answer, contains('fushi-typeans-error'));
  });

  test('期望答案里的引号 / 尖括号经属性往返不变，比对输出转义', () {
    final ({String question, String answer}) r = resolve(
      '[[type:Back]]',
      '[[type:Back]]',
      <String, String>{'Back': 'a &lt;b&gt; "c"'},
    );
    final String out = ankiFillTypeAnswer(r.answer, '');
    expect(
      out,
      '<code id="typeans" class="fushi-typeans-result">'
      'a &lt;b&gt; "c"</code>',
    );
  });

  test('比对：没打字只显示答案；打对整段 typeGood；打错分上下两行', () {
    expect(
      ankiTypeAnswerComparison('', 'abc'),
      '<code id="typeans" class="fushi-typeans-result">abc</code>',
    );
    expect(
      ankiTypeAnswerComparison(' abc ', 'abc'),
      '<code id="typeans" class="fushi-typeans-result">'
      '<span class="typeGood">abc</span></code>',
    );
    expect(
      ankiTypeAnswerComparison('axc', 'abc'),
      '<code id="typeans" class="fushi-typeans-result">'
      '<span class="typeGood">a</span><span class="typeBad">x</span>'
      '<span class="typeGood">c</span>'
      '<br><span id="typearrow">&darr;</span><br>'
      '<span class="typeGood">a</span><span class="typeMissed">b</span>'
      '<span class="typeGood">c</span></code>',
    );
  });
}
