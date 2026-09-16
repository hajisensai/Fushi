// Lapis 卡片样式 AI 助手的纯函数守卫：解析 / 本地校验 / CSS 白名单 / 提示词覆盖面 /
// 类名清单与 vendored 模板一致。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_lapis_style_assistant.dart';
import 'package:fushi_anki/fushi_anki.dart';

void main() {
  group('parseAiLapisStyleSuggestion', () {
    test('列表形规则：字段、数值取整、颜色规整、对齐别名', () {
      final AiLapisStyleSuggestion suggestion = parseAiLapisStyleSuggestion(
        'Here you go:\n'
        '{"explanation": "例句放大", "rules": ['
        '{"field": "sentence", "fontScalePercent": 125.4, "bold": true,'
        ' "alignment": "left", "colorHex": "#abc", "paddingPx": "8px"}'
        '], "css": ""}',
      );
      expect(suggestion.isEmpty, isFalse);
      expect(suggestion.explanation, '例句放大');
      final LapisVisualRule rule = suggestion.rules[LapisVisualField.sentence]!;
      expect(rule.fontScalePercent, 125);
      expect(rule.bold, isTrue);
      expect(rule.alignment, LapisVisualTextAlign.start);
      expect(rule.colorHex, '#AABBCC');
      expect(rule.paddingPx, 8);
    });

    test('键值形规则（托管区段 CONFIG 同形）也能解析', () {
      final AiLapisStyleSuggestion suggestion = parseAiLapisStyleSuggestion(
        '{"rules": {"definition-box": {"borderWidthPx": 2,'
        ' "borderColorHex": "#ff0000"}}}',
      );
      final LapisVisualRule rule =
          suggestion.rules[LapisVisualField.definitionBox]!;
      expect(rule.borderWidthPx, 2);
      expect(rule.borderColorHex, '#FF0000');
    });

    test('未知字段丢弃；默认值规则不进结果；不支持盒模型的字段抹掉盒属性', () {
      final AiLapisStyleSuggestion suggestion = parseAiLapisStyleSuggestion(
        '{"rules": ['
        '{"field": "footer", "bold": true},'
        '{"field": "reading", "fontScalePercent": 100, "bold": false},'
        '{"field": "expression", "paddingPx": 12, "borderWidthPx": 3},'
        '{"field": "definitionContent", "paddingPx": 12}'
        ']}',
      );
      expect(suggestion.rules.containsKey(LapisVisualField.reading), isFalse);
      expect(
        suggestion.rules.containsKey(LapisVisualField.expression),
        isFalse,
        reason: '词头不支持盒模型，只剩盒属性的规则抹掉后等于默认值',
      );
      expect(
        suggestion.rules[LapisVisualField.definitionContent]!.paddingPx,
        12,
      );
      expect(suggestion.rules, hasLength(1));
    });

    test('带透明度或非法的颜色丢弃该属性', () {
      final AiLapisStyleSuggestion suggestion = parseAiLapisStyleSuggestion(
        '{"rules": [{"field": "expression", "colorHex": "#80ff0000",'
        ' "backgroundColorHex": "blue", "bold": true}]}',
      );
      final LapisVisualRule rule =
          suggestion.rules[LapisVisualField.expression]!;
      expect(rule.colorHex, isNull);
      expect(rule.backgroundColorHex, isNull);
      expect(rule.bold, isTrue);
    });

    test('空 rules 与空 css → isEmpty；非 JSON → isEmpty', () {
      expect(
        parseAiLapisStyleSuggestion('{"rules": [], "css": ""}').isEmpty,
        isTrue,
      );
      expect(parseAiLapisStyleSuggestion('nope').isEmpty, isTrue);
    });
  });

  group('sanitizeAiLapisCss', () {
    test('放行 Lapis 类名 / 可视字段选择器及其后代', () {
      final String css = sanitizeAiLapisCss(
        '.def-info { display: none !important; }\n'
        '#glossaries li[data-dictionary] { margin-bottom: 6px; }\n'
        '.card { font-family: "Noto Sans JP"; }',
      );
      expect(css, contains('.def-info {'));
      expect(css, contains('#glossaries li[data-dictionary] {'));
      expect(css, contains('.card {'));
    });

    test('丢弃 body / html / 通配与危险 token 的块，保留其余', () {
      final String css = sanitizeAiLapisCss(
        'body { background: black; }\n'
        '* { box-sizing: border-box; }\n'
        '@import "x.css";\n'
        '.dh-image { background: url(x.png); }\n'
        '.pitch { color: #333; }',
      );
      expect(css, isNot(contains('body')));
      expect(css, isNot(contains('box-sizing')));
      expect(css, isNot(contains('@import')));
      expect(css, isNot(contains('url(')));
      expect(css, contains('.pitch {\n  color: #333;\n}'));
    });

    test('清单外的类名不放行', () {
      expect(sanitizeAiLapisCss('.made-up { color: red; }'), isEmpty);
    });
  });

  test('kAiLapisKnownCssTokens 里每个 token 都真实存在于 vendored Lapis 模板', () {
    const AnkiNoteTypeTemplate template = LapisNoteType.template;
    final String haystack =
        '${template.css}\n${template.front}\n${template.back}';
    final RegExp ident = RegExp(r'[\w-]');
    for (final String token in kAiLapisKnownCssTokens) {
      final String name = token.substring(1);
      // 类名在 CSS 里以 `.name`、在 HTML 里以 class="name" 出现；id 同理。
      // 只认「后面不再接标识符字符」的出现，防 `.pitch` 被 `.pitch-line` 假阳性。
      final bool found = RegExp(
        '(?:${RegExp.escape(token)}|class="[^"]*\\b${RegExp.escape(name)}|id="${RegExp.escape(name)})(?![\\w-])',
      ).hasMatch(haystack);
      expect(found, isTrue, reason: '$token 不在 Lapis 模板里，清单该更新');
      expect(ident.hasMatch(name), isTrue);
    }
  });

  test('aiLapisCssAllowedSelectors 覆盖全部可视字段选择器里的类名 / id', () {
    final List<String> allowed = aiLapisCssAllowedSelectors();
    for (final LapisVisualField field in LapisVisualField.values) {
      for (final RegExpMatch match in RegExp(
        r'[.#][A-Za-z_][\w-]*',
      ).allMatches(lapisVisualSelector(field))) {
        expect(allowed, contains(match.group(0)));
      }
    }
  });

  group('提示词', () {
    test('系统提示覆盖全部字段 wireName 与选择器，交代盒属性限制', () {
      final String prompt = buildAiLapisStyleSystemPrompt();
      for (final LapisVisualField field in LapisVisualField.values) {
        expect(prompt, contains('- ${field.wireName}:'));
        expect(prompt, contains('`${lapisVisualSelector(field)}`'));
      }
      expect(prompt, contains('fontScalePercent'));
      expect(prompt, contains('marginBlockPx'));
      expect(prompt, contains('box fields only'));
    });

    test('用户提示带上非默认的当前规则与自由 CSS', () {
      final String prompt = buildAiLapisStyleUserPrompt(
        request: '例句放大',
        currentRules: <LapisVisualField, LapisVisualRule>{
          LapisVisualField.sentence: const LapisVisualRule(bold: true),
          LapisVisualField.reading: const LapisVisualRule(),
        },
        currentCss: '.card { color: teal; }',
      );
      expect(prompt, contains('Request: 例句放大'));
      expect(prompt, contains('"field":"sentence"'));
      expect(prompt, isNot(contains('"field":"reading"')));
      expect(prompt, contains('.card { color: teal; }'));
    });
  });

  test('appendAiLapisCss 已有内容后空一行再追加', () {
    expect(appendAiLapisCss('', '.card { x: y; }'), '.card { x: y; }');
    expect(
      appendAiLapisCss('.a { b: c; }\n\n', '.card { x: y; }'),
      '.a { b: c; }\n\n.card { x: y; }',
    );
  });
}
