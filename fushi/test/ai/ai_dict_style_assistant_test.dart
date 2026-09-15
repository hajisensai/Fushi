// 词典弹窗样式 AI 助手的纯函数守卫：解析 / 本地校验 / CSS 白名单 / 提示词覆盖面。
//
// AI 产物落地前的全部把关都在这里，所以用例围绕「坏输入不得穿透」展开：未知部位、
// 编造的词典名、非法颜色、`body{}`、`@import` 一个都不能进草稿。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_dict_style_assistant.dart';
import 'package:fushi/src/dictionary/dict_style_rules.dart';

void main() {
  group('parseAiDictStyleSuggestion', () {
    test('合法回复：规则、颜色转换、CSS、说明全部解析出来', () {
      final AiDictStyleSuggestion suggestion = parseAiDictStyleSuggestion(
        '''
```json
{
  "explanation": "词头加粗改蓝",
  "rules": [
    {"part": "expression", "dictionaryName": null,
     "props": {"textColor": "#1a73e8", "bold": true, "fontScale": 1.2}}
  ],
  "css": ".glossary-content { line-height: 1.6; }"
}
```
''',
        allowedDictionaries: const <String>['JMdict'],
      );
      expect(suggestion.isEmpty, isFalse);
      expect(suggestion.explanation, '词头加粗改蓝');
      expect(suggestion.rules, hasLength(1));
      final DictStyleRule rule = suggestion.rules.single;
      expect(rule.part, DictStylePart.expression);
      expect(rule.dictionaryName, isNull);
      expect(rule.props.textColor, 0xFF1A73E8);
      expect(rule.props.bold, isTrue);
      expect(rule.props.fontScale, 1.2);
      expect(suggestion.css, contains('.glossary-content {'));
      expect(suggestion.css, contains('line-height: 1.6;'));
    });

    test('未知部位与空 props 的规则被丢弃', () {
      final AiDictStyleSuggestion suggestion = parseAiDictStyleSuggestion(
        '{"rules": ['
        '{"part": "footer", "props": {"bold": true}},'
        '{"part": "pitch", "props": {}},'
        '{"part": "pitch", "props": {"textColor": "not-a-colour"}},'
        '{"part": "ruby", "props": {"italic": true}}'
        ']}',
        allowedDictionaries: const <String>[],
      );
      expect(suggestion.rules, hasLength(1));
      expect(suggestion.rules.single.part, DictStylePart.ruby);
      expect(suggestion.rules.single.props.italic, isTrue);
    });

    test('dictionaryName 不在词典表里或部位不支持单本词典时抹成全局', () {
      final AiDictStyleSuggestion suggestion = parseAiDictStyleSuggestion(
        '{"rules": ['
        '{"part": "glossaryContent", "dictionaryName": "Nope",'
        ' "props": {"bold": true}},'
        '{"part": "expression", "dictionaryName": "JMdict",'
        ' "props": {"underline": true}},'
        '{"part": "glossaryTag", "dictionaryName": "JMdict",'
        ' "props": {"backgroundColor": "#80ff0000", "cornerRadius": "4px"}}'
        ']}',
        allowedDictionaries: const <String>['JMdict'],
      );
      expect(suggestion.rules, hasLength(3));
      final DictStyleRule content = suggestion.rules.firstWhere(
        (DictStyleRule r) => r.part == DictStylePart.glossaryContent,
      );
      expect(content.dictionaryName, isNull, reason: '编造的词典名不得落地');
      final DictStyleRule expression = suggestion.rules.firstWhere(
        (DictStyleRule r) => r.part == DictStylePart.expression,
      );
      expect(expression.dictionaryName, isNull, reason: '词头不支持单本词典');
      final DictStyleRule tag = suggestion.rules.firstWhere(
        (DictStyleRule r) => r.part == DictStylePart.glossaryTag,
      );
      expect(tag.dictionaryName, 'JMdict');
      expect(tag.props.backgroundColor, 0x80FF0000, reason: '#aarrggbb 保留透明度');
      expect(tag.props.cornerRadius, 4.0, reason: '"4px" 也要认');
    });

    test('同部位 + 同词典名的规则后者覆盖前者', () {
      final AiDictStyleSuggestion suggestion = parseAiDictStyleSuggestion(
        '{"rules": ['
        '{"part": "pitch", "props": {"bold": true}},'
        '{"part": "pitch", "props": {"italic": true}}'
        ']}',
        allowedDictionaries: const <String>[],
      );
      expect(suggestion.rules, hasLength(1));
      expect(suggestion.rules.single.props.bold, isNull);
      expect(suggestion.rules.single.props.italic, isTrue);
    });

    test('空 rules 与空 css → isEmpty；非 JSON 回复 → isEmpty', () {
      expect(
        parseAiDictStyleSuggestion(
          '{"explanation": "nothing", "rules": [], "css": "  "}',
          allowedDictionaries: const <String>[],
        ).isEmpty,
        isTrue,
      );
      expect(
        parseAiDictStyleSuggestion(
          'Sorry, I cannot help with that.',
          allowedDictionaries: const <String>[],
        ).isEmpty,
        isTrue,
      );
    });

    test('css 只剩被白名单丢光的块时也算空', () {
      final AiDictStyleSuggestion suggestion = parseAiDictStyleSuggestion(
        '{"rules": [], "css": "body { background: black; }"}',
        allowedDictionaries: const <String>[],
      );
      expect(suggestion.isEmpty, isTrue);
    });
  });

  group('parseAiDictColor', () {
    test('三种十六进制写法与整数透传', () {
      expect(parseAiDictColor('#abc'), 0xFFAABBCC);
      expect(parseAiDictColor('#1A73E8'), 0xFF1A73E8);
      expect(parseAiDictColor('#801a73e8'), 0x801A73E8);
      expect(parseAiDictColor(0xFF000000), 0xFF000000);
      expect(parseAiDictColor('red'), isNull);
      expect(parseAiDictColor('#12345'), isNull);
    });
  });

  group('sanitizeAiDictCss', () {
    test('放行部位选择器及其后代，声明逐行规整', () {
      final String css = sanitizeAiDictCss(
        '.glossary-content{margin-top:4px;font-family:serif}\n'
        '.entry .expression { letter-spacing: 0.05em; }',
      );
      expect(
        css,
        contains(
          '.glossary-content {\n  margin-top:4px;\n  font-family:serif;\n}',
        ),
      );
      expect(css, contains('.entry .expression {'));
    });

    test('丢弃 body / html / 通配 / 裸元素，保留其余块', () {
      final String css = sanitizeAiDictCss(
        'body { background: black; }\n'
        'html { font-size: 20px; }\n'
        '* { margin: 0; }\n'
        'div { padding: 0; }\n'
        '.entry * { color: red; }\n'
        '.pitch-section { display: none; }',
      );
      expect(css, isNot(contains('body')));
      expect(css, isNot(contains('html')));
      expect(css, isNot(contains('margin: 0')));
      expect(css, isNot(contains('padding: 0')));
      expect(css, isNot(contains('color: red')));
      expect(css, contains('.pitch-section {\n  display: none;\n}'));
    });

    test('含 @import / url( / expression( / javascript: 的块整块丢弃', () {
      final String css = sanitizeAiDictCss(
        '@import url("https://evil.example/x.css");\n'
        '.entry { background: url(evil.png); }\n'
        '.expression { width: expression(alert(1)); }\n'
        '.ruby-rt { content: "javascript:void(0)"; }\n'
        '.glossary-tag { font-weight: 600; }',
      );
      expect(css, isNot(contains('@import')));
      expect(css, isNot(contains('url(')));
      expect(css, isNot(contains('expression(')));
      expect(css, isNot(contains('javascript:')));
      expect(css, contains('.glossary-tag {\n  font-weight: 600;\n}'));
    });

    test('选择器逗号列表只保留锚定成功的那几个；前缀撞名不算锚定', () {
      final String css = sanitizeAiDictCss(
        '.entry-card-fake, .entry, p { border: 1px solid #ccc; }',
      );
      expect(css, startsWith('.entry {'));
      expect(css, isNot(contains('.entry-card-fake')));
      expect(css, isNot(contains(', p')));
    });

    test('@media 递归过滤，内部全丢时外壳一起丢', () {
      final String kept = sanitizeAiDictCss(
        '@media (prefers-color-scheme: dark) { .entry { color: #eee; } body { color: red; } }',
      );
      expect(kept, contains('@media (prefers-color-scheme: dark) {'));
      expect(kept, contains('.entry {'));
      expect(kept, isNot(contains('body')));
      final String dropped = sanitizeAiDictCss(
        '@media (max-width: 600px) { body { font-size: 12px; } }',
      );
      expect(dropped, isEmpty);
      expect(
        sanitizeAiDictCss('@font-face { font-family: x; src: local(y); }'),
        isEmpty,
      );
    });

    test('summary.dict-label 的裸类名也能锚定', () {
      expect(
        sanitizeAiDictCss('.dict-label { text-transform: uppercase; }'),
        contains('.dict-label {'),
      );
    });
  });

  group('合并与追加', () {
    test('mergeAiDictStyleRules 替换同部位同词典名、保留其它', () {
      final List<DictStyleRule> current = <DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.expression,
          props: DictStyleProps(bold: true),
        ),
        const DictStyleRule(
          part: DictStylePart.glossaryContent,
          dictionaryName: 'JMdict',
          props: DictStyleProps(italic: true),
        ),
      ];
      final List<DictStyleRule> merged =
          mergeAiDictStyleRules(current, <DictStyleRule>[
            const DictStyleRule(
              part: DictStylePart.expression,
              props: DictStyleProps(textColor: 0xFF0000FF),
            ),
            const DictStyleRule(
              part: DictStylePart.glossaryContent,
              props: DictStyleProps(underline: true),
            ),
          ]);
      expect(merged, hasLength(3));
      final DictStyleRule expression = merged.firstWhere(
        (DictStyleRule r) => r.part == DictStylePart.expression,
      );
      expect(expression.props.bold, isNull, reason: '同部位整条替换');
      expect(expression.props.textColor, 0xFF0000FF);
      expect(
        merged.any(
          (DictStyleRule r) =>
              r.part == DictStylePart.glossaryContent &&
              r.dictionaryName == 'JMdict' &&
              r.props.italic == true,
        ),
        isTrue,
        reason: '不同词典名的规则不受影响',
      );
    });

    test('appendAiCss 已有内容后空一行再追加，空追加原样返回', () {
      expect(
        appendAiCss('', '.entry { color: red; }'),
        '.entry { color: red; }',
      );
      expect(
        appendAiCss('.a { x: y; }\n', '.entry { color: red; }'),
        '.a { x: y; }\n\n.entry { color: red; }',
      );
      expect(appendAiCss('.a { x: y; }', '   '), '.a { x: y; }');
    });
  });

  group('提示词', () {
    test('系统提示覆盖全部部位名与选择器，并交代可否限定单本词典', () {
      final String prompt = buildAiDictStyleSystemPrompt();
      for (final DictStylePart part in DictStylePart.values) {
        expect(prompt, contains('- ${part.name}:'));
        expect(prompt, contains('`${dictStylePartSelector(part)}`'));
      }
      expect(prompt, contains('"dictionaryName"'));
      expect(prompt, contains('textColor'));
      expect(prompt, contains('cornerRadius'));
    });

    test('用户提示带上当前规则、当前 CSS、作用域与词典表', () {
      final String prompt = buildAiDictStyleUserPrompt(
        request: '词头加粗',
        currentRules: <DictStyleRule>[
          const DictStyleRule(
            part: DictStylePart.expression,
            props: DictStyleProps(bold: true),
          ),
        ],
        currentCss: '.entry { color: teal; }',
        dictionaryName: 'JMdict',
        availableDictionaries: const <String>['JMdict', '大辞林'],
      );
      expect(prompt, contains('Request: 词头加粗'));
      expect(prompt, contains('"part":"expression"'));
      expect(prompt, contains('.entry { color: teal; }'));
      expect(prompt, contains('"JMdict"'));
      expect(prompt, contains('大辞林'));
    });
  });
}
