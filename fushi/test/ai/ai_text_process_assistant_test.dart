import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_text_process_assistant.dart';
import 'package:fushi/src/mining/galgame_text_process.dart';

const GalTextProcessPipeline _empty = GalTextProcessPipeline();

AiTextProcessSuggestion _parse(String reply, {GalTextProcessPipeline? into}) =>
    parseAiTextProcessSuggestion(reply, into: into ?? _empty);

void main() {
  group('解析 AI 回复', () {
    test('规规矩矩的 JSON', () {
      final AiTextProcessSuggestion suggestion = _parse('''
{"explanation": "去掉重复字符", "steps": [{"kind": "dedupeChars"}]}
''');
      expect(suggestion.explanation, '去掉重复字符');
      expect(suggestion.steps, hasLength(1));
      expect(suggestion.steps.single.kind, GalTextProcessKind.dedupeChars);
      expect(suggestion.steps.single.id, 'dedupeChars');
    });

    test('裹在 ```json 围栏里也能抠出来', () {
      final AiTextProcessSuggestion suggestion = _parse('''
好的，这是规则：

```json
{"explanation": "ok", "steps": [{"kind": "filterDigits"}]}
```

希望有帮助。
''');
      expect(suggestion.steps.single.kind, GalTextProcessKind.filterDigits);
    });

    test('JSON 里带嵌套对象与转义引号时括号配对不会算错', () {
      final AiTextProcessSuggestion suggestion = _parse(
        r'''prose {"explanation": "a \"quoted\" } brace", '''
        r'''"steps": [{"kind": "replace", "pattern": "\\{[^}]*\\}", '''
        r'''"replacement": "", "isRegex": true}]} trailing prose''',
      );
      expect(suggestion.steps, hasLength(1));
      expect(suggestion.steps.single.kind, GalTextProcessKind.replace);
      expect(suggestion.explanation, 'a "quoted" } brace');
    });

    test('参数被原样带过来', () {
      final AiTextProcessSuggestion suggestion = _parse('''
{"steps": [
  {"kind": "takeLines", "lineCount": 3, "fromEnd": true},
  {"kind": "dedupeBlockFixed", "repeatCount": 2},
  {"kind": "filterLineBreaks", "replacement": " "}
]}
''');
      expect(suggestion.steps, hasLength(3));
      expect(suggestion.steps[0].lineCount, 3);
      expect(suggestion.steps[0].fromEnd, isTrue);
      expect(suggestion.steps[1].repeatCount, 2);
      expect(suggestion.steps[2].replacement, ' ');
    });

    test('编译不过的正则整步丢掉，不塞进管线', () {
      final AiTextProcessSuggestion suggestion = _parse('''
{"steps": [
  {"kind": "replace", "pattern": "(", "replacement": "x"},
  {"kind": "filterDigits"}
]}
''');
      expect(suggestion.steps, hasLength(1));
      expect(suggestion.steps.single.kind, GalTextProcessKind.filterDigits);
    });

    test('空匹配式的替换步骤也丢掉（那是个 no-op）', () {
      final AiTextProcessSuggestion suggestion = _parse(
        '{"steps": [{"kind": "replace", "replacement": "x"}]}',
      );
      expect(suggestion.steps, isEmpty);
    });

    test('字面替换不做正则校验', () {
      final AiTextProcessSuggestion suggestion = _parse('''
{"steps": [{"kind": "replace", "pattern": "(", "replacement": "", "isRegex": false}]}
''');
      expect(suggestion.steps, hasLength(1));
      expect(suggestion.steps.single.isRegex, isFalse);
    });

    test('未知 kind 被丢掉，不会退化成某个无关步骤', () {
      final AiTextProcessSuggestion suggestion = _parse('''
{"steps": [{"kind": "translateToEnglish"}, {"kind": "filterDigits"}]}
''');
      expect(suggestion.steps, hasLength(1));
      expect(suggestion.steps.single.kind, GalTextProcessKind.filterDigits);
    });

    test('id 在「已有管线 + 本批新加」里都唯一', () {
      final GalTextProcessPipeline existing = GalTextProcessPipeline(
        steps: <GalTextProcessStep>[
          const GalTextProcessStep(
            id: 'replace',
            kind: GalTextProcessKind.replace,
            pattern: 'a',
          ),
        ],
      );
      final AiTextProcessSuggestion suggestion = _parse('''
{"steps": [
  {"kind": "replace", "pattern": "b", "replacement": ""},
  {"kind": "replace", "pattern": "c", "replacement": ""}
]}
''', into: existing);
      expect(suggestion.steps.map((GalTextProcessStep s) => s.id), <String>[
        'replace#2',
        'replace#3',
      ]);
    });

    test('解析不出结构时返回空建议，不抛', () {
      expect(_parse('抱歉，我不太明白。').steps, isEmpty);
      expect(_parse('{ 这不是 JSON').steps, isEmpty);
      expect(_parse('{"steps": "not a list"}').steps, isEmpty);
      expect(_parse('[]').steps, isEmpty);
      expect(_parse('').steps, isEmpty);
    });

    test('建议出来的步骤真的能跑', () {
      final AiTextProcessSuggestion suggestion = _parse('''
{"steps": [{"kind": "dedupeAscending"}, {"kind": "filterDigits"}]}
''');
      final GalTextProcessPipeline pipeline = GalTextProcessPipeline(
        steps: suggestion.steps,
      );
      expect(pipeline.apply('AABABCABCD'), 'ABCD');
    });
  });

  group('提示词', () {
    test('系统提示列出了全部处理项，加一种新的会自动带上', () {
      final String prompt = buildAiTextProcessSystemPrompt();
      for (final GalTextProcessKind kind in GalTextProcessKind.values) {
        expect(prompt, contains(kind.storageKey), reason: '${kind.name} 没进提示词');
      }
    });

    test('用户提示带上样例与当前输出，且样例经过 JSON 转义', () {
      final String prompt = buildAiTextProcessUserPrompt(
        request: '去掉旁白',
        sampleText: '彼は「あ"い」と言った',
        currentOutput: 'あ"い',
      );
      expect(prompt, contains('去掉旁白'));
      expect(prompt, contains(r'\"'));
      expect(prompt, contains('あ'));
    });

    test('样例与当前输出相同时不重复塞一遍', () {
      final String prompt = buildAiTextProcessUserPrompt(
        request: 'r',
        sampleText: 'same',
        currentOutput: 'same',
      );
      expect(prompt, isNot(contains('already produces')));
    });

    test('没有样例时不写样例行', () {
      final String prompt = buildAiTextProcessUserPrompt(request: 'r');
      expect(prompt, isNot(contains('Sample captured line')));
    });
  });
}
