// 自定义主题 AI 助手的纯函数守卫：解析 / 本地校验 / 合并语义 / 提示词覆盖面。
//
// AI 产物落地前的全部把关都在这里，所以用例围绕「坏输入不得穿透」展开：认不出的
// 角色名、非法颜色、不该带透明度的角色带了 alpha，一个都不能进草稿；没给的角色
// 必须原样保留用户已有的覆盖值。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_theme_assistant.dart';
import 'package:fushi/src/models/theme_notifier.dart' show CustomThemeEntry;

void main() {
  group('parseAiThemeSuggestion', () {
    test('合法回复：颜色、名字、中性灰开关、说明全部解析出来', () {
      final AiThemeSuggestion suggestion = parseAiThemeSuggestion('''
```json
{
  "explanation": "暖色纸张配深绿主题色",
  "name": "暖纸",
  "neutralDerived": true,
  "colors": {
    "accent": "#2E7D32",
    "readerBackground": "#faf6ef",
    "readerText": "#cc3b2f2f",
    "selection": "#402E7D32"
  }
}
```
''');
      expect(suggestion.isEmpty, isFalse);
      expect(suggestion.explanation, '暖色纸张配深绿主题色');
      expect(suggestion.name, '暖纸');
      expect(suggestion.neutralDerived, isTrue);
      expect(suggestion.colors, hasLength(4));
      expect(suggestion.colors[AiThemeRole.accent], 0xFF2E7D32);
      expect(suggestion.colors[AiThemeRole.readerBackground], 0xFFFAF6EF);
      expect(
        suggestion.colors[AiThemeRole.readerText],
        0xCC3B2F2F,
        reason: '正文字色允许透明度，#aarrggbb 原样保留',
      );
      expect(suggestion.colors[AiThemeRole.selection], 0x402E7D32);
    });

    test('认不出的角色与非法颜色被丢弃；角色名容忍大小写', () {
      final AiThemeSuggestion suggestion = parseAiThemeSuggestion(
        '{"colors": {'
        '"footer": "#000000",'
        '"accent": "not-a-colour",'
        '"Link": "#123456",'
        '"readerbackground": 12'
        '}}',
      );
      expect(suggestion.colors.keys, <AiThemeRole>[AiThemeRole.link]);
      expect(suggestion.colors[AiThemeRole.link], 0xFF123456);
    });

    test('不允许透明度的角色被强制不透明', () {
      final AiThemeSuggestion suggestion = parseAiThemeSuggestion(
        '{"colors": {'
        '"surface": "#80FFFFFF",'
        '"readerBackground": "#00202020",'
        '"audioHighlight": "#40FFEB3B"'
        '}}',
      );
      expect(suggestion.colors[AiThemeRole.surface], 0xFFFFFFFF);
      expect(suggestion.colors[AiThemeRole.readerBackground], 0xFF202020);
      expect(
        suggestion.colors[AiThemeRole.audioHighlight],
        0x40FFEB3B,
        reason: '有声书高亮叠在正文上，透明度必须保留',
      );
    });

    test('空名字 / 非布尔 neutralDerived / 非 JSON 回复都退化成空建议', () {
      expect(
        parseAiThemeSuggestion(
          '{"name": "  ", "neutralDerived": "yes"}',
        ).isEmpty,
        isTrue,
      );
      expect(parseAiThemeSuggestion('sorry, no').isEmpty, isTrue);
      expect(parseAiThemeSuggestion('[1, 2]').isEmpty, isTrue);
    });
  });

  group('AiThemeSuggestion.applyTo', () {
    const CustomThemeEntry base = CustomThemeEntry(
      id: 'ct-1',
      name: '',
      seed: 0xFF1F4959,
      primaryColor: null,
      surfaceColor: 0xFFF3F3F3,
      fontColor: 0xFF111111,
      linkColor: 0xFF0B57D0,
      followSystemAccent: true,
      neutralDerived: false,
    );

    test('只覆盖 AI 给出的角色，其余覆盖值与开关原样保留', () {
      const AiThemeSuggestion suggestion = AiThemeSuggestion(
        colors: <AiThemeRole, int>{
          AiThemeRole.readerBackground: 0xFFFAF6EF,
          AiThemeRole.link: 0xFF006E1C,
        },
      );
      final CustomThemeEntry merged = suggestion.applyTo(base);
      expect(merged.id, 'ct-1');
      expect(merged.bgColor, 0xFFFAF6EF);
      expect(merged.linkColor, 0xFF006E1C);
      expect(merged.surfaceColor, 0xFFF3F3F3, reason: '没给的角色不动');
      expect(merged.fontColor, 0xFF111111);
      expect(merged.followSystemAccent, isTrue);
      expect(merged.neutralDerived, isFalse);
      // 没给主题色：seed 与 primaryColor 都不动，自动调色调语义保持。
      expect(merged.seed, 0xFF1F4959);
      expect(merged.primaryColor, isNull);
    });

    test('给了主题色：seed 与 primaryColor 同时写成它（所见即所得）', () {
      const AiThemeSuggestion suggestion = AiThemeSuggestion(
        colors: <AiThemeRole, int>{AiThemeRole.accent: 0xFF2E7D32},
        neutralDerived: true,
      );
      final CustomThemeEntry merged = suggestion.applyTo(base);
      expect(merged.seed, 0xFF2E7D32);
      expect(merged.primaryColor, 0xFF2E7D32);
      expect(merged.neutralDerived, isTrue);
    });

    test('建议的名字只在用户还没起名时采用', () {
      const AiThemeSuggestion suggestion = AiThemeSuggestion(name: '暖纸');
      expect(suggestion.applyTo(base).name, '暖纸');
      const CustomThemeEntry named = CustomThemeEntry(
        id: 'ct-2',
        name: '我的主题',
        seed: 0xFF1F4959,
      );
      expect(suggestion.applyTo(named).name, '我的主题');
    });
  });

  group('提示词', () {
    test('系统提示覆盖每个角色，并钉死 JSON 形状', () {
      final String prompt = buildAiThemeSystemPrompt();
      for (final AiThemeRole role in AiThemeRole.values) {
        expect(prompt, contains('- ${role.name}:'));
      }
      expect(prompt, contains('"colors"'));
      expect(prompt, contains('"neutralDerived"'));
      expect(prompt, contains('"explanation"'));
    });

    test('用户提示带上当前每个角色的值（null = 跟随主题）与预览明暗', () {
      const CustomThemeEntry current = CustomThemeEntry(
        id: 'ct-1',
        name: '夜读',
        seed: 0xFF1F4959,
        primaryColor: 0xFF2E7D32,
        bgColor: 0xFF202020,
      );
      final String prompt = buildAiThemeUserPrompt(
        request: '链接更亮一点',
        current: current,
        darkMode: true,
        audioHighlight: 0x40FFEB3B,
      );
      expect(prompt, contains('Request: 链接更亮一点'));
      expect(prompt, contains('Preview brightness: dark'));
      expect(prompt, contains('"accent":"#ff2e7d32"'));
      expect(prompt, contains('"readerBackground":"#ff202020"'));
      expect(prompt, contains('"audioHighlight":"#40ffeb3b"'));
      expect(prompt, contains('"surface":null'));
      expect(prompt, contains('Current theme name: "夜读"'));
    });
  });
}
