/// 让 AI 按自然语言描述生成词典弹窗样式。
///
/// 与 `ai_text_process_assistant.dart` 同一套纪律：AI 只产出**配置**——一组
/// [DictStyleRule]（走可视化编辑器同一条编译链）加一段补充 CSS；产物只进编辑器
/// 草稿，用户看过预览再决定保不保存。热路径（弹窗渲染）永远是本地代码。
///
/// 产出一律先过本地校验：未知部位 / 空属性的规则丢弃，不合法的单本词典限定抹成
/// 全局，补充 CSS 经 [sanitizeAiDictCss] 白名单过滤。宁可少一条，也不把一条会把
/// 整个弹窗底色改掉的 `body{}` 塞给用户。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_css_sanitizer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';
import 'package:fushi/src/dictionary/dict_style_rules.dart';

/// AI 给出的一组样式建议。
class AiDictStyleSuggestion {
  const AiDictStyleSuggestion({
    required this.rules,
    this.css = '',
    this.explanation = '',
  });

  /// 已校验的可视化规则；同部位 + 同词典名只保留最后一条。
  final List<DictStyleRule> rules;

  /// 已过白名单的补充 CSS，空串 = 没有。
  final String css;

  /// AI 对这组改动的一句话说明，直接显示给用户。
  final String explanation;

  bool get isEmpty => rules.isEmpty && css.trim().isEmpty;
}

/// 补充 CSS 里允许锚定的选择器：全部部位选择器，外加 `summary.dict-label`
/// 的裸类名（模型常只写 `.dict-label`）。
List<String> aiDictCssAllowedSelectors() => <String>[
  for (final DictStylePart part in DictStylePart.values)
    dictStylePartSelector(part),
  '.dict-label',
];

/// 系统提示：部位清单与属性清单都从领域模型推导，加部位 / 加属性时提示词自动跟上。
String buildAiDictStyleSystemPrompt() {
  final StringBuffer parts = StringBuffer();
  for (final DictStylePart part in DictStylePart.values) {
    final String scope = dictStylePartSupportsPerDictionary(part)
        ? 'may be limited to one dictionary via "dictionaryName"'
        : 'global only ("dictionaryName" must be null)';
    parts.writeln(
      '- ${part.name}: selector `${dictStylePartSelector(part)}`; '
      '${_partSemantics(part)}; $scope',
    );
  }
  return '''
You restyle a Japanese dictionary popup. The popup is rendered locally; you only
emit a style configuration. Prefer structured "rules"; use "css" only for things
rules cannot express (spacing, borders, font family, hiding a part, line height).

Parts (each is one "part" value):
$parts
Rule props (all optional; omit what should stay unchanged):
- textColor: "#rrggbb" text colour
- backgroundColor: "#rrggbb" highlight / background colour
- bold, italic, underline: true or false
- fontScale: font size multiplier relative to the inherited size, e.g. 1.2
- cornerRadius: corner radius in pixels, meaningful together with backgroundColor

CSS constraints:
- Only use the selectors listed above (descendants of them are fine).
- Never target body, html, *, or bare element selectors.
- Never use @import, url(), expression(), javascript: or script tags.
- Do not add [data-dictionary] scoping yourself; the app scopes the CSS to the
  dictionary the user is currently editing.

Answer with a single JSON object and nothing else:
{"explanation": "...", "rules": [{"part": "<part name>", "dictionaryName": null, "props": {...}}], "css": ""}
- "rules" replace existing rules for the same part and dictionaryName; keep a rule
  minimal: only the props the user asked to change.
- "explanation" must be written in the same language the user wrote in.
''';
}

String _partSemantics(DictStylePart part) => switch (part) {
  DictStylePart.entryCard => 'the whole entry card',
  DictStylePart.expression => 'the headword',
  DictStylePart.ruby => 'furigana above the headword',
  DictStylePart.expressionTag => 'part-of-speech / word-form tags',
  DictStylePart.deinflectionTag => 'deinflection chain tags',
  DictStylePart.frequency => 'frequency section',
  DictStylePart.pitch => 'pitch accent section',
  DictStylePart.dictionaryLabel => 'dictionary name row (group heading)',
  DictStylePart.glossaryContent => 'glossary body text',
  DictStylePart.glossaryTag => 'glossary tags',
};

/// 用户侧提示：带上当前规则与手写 CSS，让模型做**相对修改**而不是从零重写。
String buildAiDictStyleUserPrompt({
  required String request,
  required List<DictStyleRule> currentRules,
  required String currentCss,
  String? dictionaryName,
  Iterable<String> availableDictionaries = const <String>[],
}) {
  final StringBuffer buffer = StringBuffer()..writeln('Request: $request');
  if (dictionaryName != null && dictionaryName.isNotEmpty) {
    buffer.writeln(
      'The user is editing the style of one dictionary: '
      '${jsonEncode(dictionaryName)}',
    );
  } else {
    buffer.writeln('The user is editing the global style (all dictionaries).');
  }
  final List<String> dictionaries = availableDictionaries.toList();
  if (dictionaries.isNotEmpty) {
    buffer.writeln('Installed dictionaries: ${jsonEncode(dictionaries)}');
  }
  if (currentRules.isNotEmpty) {
    buffer.writeln(
      'Current rules: '
      '${jsonEncode(currentRules.map((DictStyleRule r) => r.toJson()).toList())}',
    );
  }
  if (currentCss.trim().isNotEmpty) {
    buffer.writeln('Current hand-written CSS:\n$currentCss');
  }
  return buffer.toString();
}

/// 把 `#rrggbb` / `#aarrggbb` / `#rgb` 转成 [DictStyleProps] 的 0xAARRGGBB 整数；
/// 已经是整数就原样透传；认不出返回 null。
int? parseAiDictColor(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is! String) {
    return null;
  }
  String hex = value.trim();
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  } else if (hex.toLowerCase().startsWith('0x')) {
    hex = hex.substring(2);
  }
  if (hex.length == 3) {
    hex = hex.split('').map((String c) => '$c$c').join();
  }
  if (hex.length == 6) {
    hex = 'FF$hex';
  }
  if (hex.length != 8 || !RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(hex)) {
    return null;
  }
  return int.parse(hex, radix: 16);
}

/// 补充 CSS 的白名单过滤（见 [sanitizeAiCss]）。
String sanitizeAiDictCss(String css) =>
    sanitizeAiCss(css, allowedSelectors: aiDictCssAllowedSelectors());

/// 解析模型回复。解析不出结构就返回空建议。
///
/// [allowedDictionaries] 是当前已安装词典名；规则里的 `dictionaryName` 不在表内
/// 或部位不支持单本词典时一律抹成全局——模型编出来的词典名不该变成一条打不中
/// 任何东西的规则。
AiDictStyleSuggestion parseAiDictStyleSuggestion(
  String reply, {
  required Iterable<String> allowedDictionaries,
}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) {
    return const AiDictStyleSuggestion(rules: <DictStyleRule>[]);
  }
  final Set<String> dictionaries = allowedDictionaries.toSet();
  List<DictStyleRule> rules = <DictStyleRule>[];
  final Object? rawRules = decoded['rules'];
  if (rawRules is List) {
    for (final Object? raw in rawRules) {
      if (raw is! Map) {
        continue;
      }
      final DictStyleRule? rule = _ruleFromAi(raw, dictionaries);
      if (rule == null) {
        continue;
      }
      // 同部位 + 同词典名后者覆盖前者，与编辑器写回语义一致。
      rules = dictStyleRulesWith(
        rules,
        rule.part,
        rule.dictionaryName,
        rule.props,
      );
    }
  }
  final Object? rawCss = decoded['css'];
  final String css = rawCss is String ? sanitizeAiDictCss(rawCss) : '';
  final Object? explanation = decoded['explanation'];
  return AiDictStyleSuggestion(
    rules: List<DictStyleRule>.unmodifiable(rules),
    css: css,
    explanation: explanation is String ? explanation.trim() : '',
  );
}

DictStyleRule? _ruleFromAi(
  Map<Object?, Object?> raw,
  Set<String> dictionaries,
) {
  final DictStylePart? part = _partFromAi(raw['part']);
  if (part == null) {
    return null;
  }
  final Object? rawProps = raw['props'];
  if (rawProps is! Map) {
    return null;
  }
  final DictStyleProps props = DictStyleProps.fromJson(
    _normalizeProps(rawProps),
  );
  if (props.isEmpty) {
    return null;
  }
  final Object? rawDict = raw['dictionaryName'];
  final String? dictionaryName =
      rawDict is String &&
          rawDict.isNotEmpty &&
          dictionaries.contains(rawDict) &&
          dictStylePartSupportsPerDictionary(part)
      ? rawDict
      : null;
  return DictStyleRule(
    part: part,
    dictionaryName: dictionaryName,
    props: props,
  );
}

DictStylePart? _partFromAi(Object? value) {
  if (value is! String) {
    return null;
  }
  final String name = value.trim();
  for (final DictStylePart part in DictStylePart.values) {
    if (part.name == name) {
      return part;
    }
  }
  // 容忍大小写 / 直接给选择器：模型偶尔回 "GlossaryContent" 或 ".expression"。
  final String lower = name.toLowerCase();
  for (final DictStylePart part in DictStylePart.values) {
    if (part.name.toLowerCase() == lower ||
        dictStylePartSelector(part).toLowerCase() == lower) {
      return part;
    }
  }
  return null;
}

/// 把模型给的 props 规整成 [DictStyleProps.fromJson] 认的形态：颜色字符串转
/// 整数，数字字符串（含 `px` 后缀）转数字，其余原样。
Map<String, dynamic> _normalizeProps(Map<Object?, Object?> raw) {
  final Map<String, dynamic> out = <String, dynamic>{};
  for (final MapEntry<Object?, Object?> entry in raw.entries) {
    final String key = '${entry.key}';
    final Object? value = entry.value;
    switch (key) {
      case 'textColor':
      case 'backgroundColor':
        final int? color = parseAiDictColor(value);
        if (color != null) {
          out[key] = color;
        }
      case 'fontScale':
      case 'cornerRadius':
        final double? number = _asNumber(value);
        if (number != null) {
          out[key] = number;
        }
      case 'bold':
      case 'italic':
      case 'underline':
        if (value is bool) {
          out[key] = value;
        } else if (value is String) {
          final String lower = value.toLowerCase();
          if (lower == 'true' || lower == 'false') {
            out[key] = lower == 'true';
          }
        }
    }
  }
  return out;
}

double? _asNumber(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(
      value.trim().toLowerCase().replaceAll(RegExp(r'(px|em|rem|x)$'), ''),
    );
  }
  return null;
}

/// 把 AI 建议的规则并进已有规则表：同部位 + 同词典名的被替换，其它保留。
List<DictStyleRule> mergeAiDictStyleRules(
  List<DictStyleRule> current,
  List<DictStyleRule> incoming,
) {
  List<DictStyleRule> merged = current;
  for (final DictStyleRule rule in incoming) {
    merged = dictStyleRulesWith(
      merged,
      rule.part,
      rule.dictionaryName,
      rule.props,
    );
  }
  return merged;
}

/// 把 AI 补充的 CSS 追加到已有手写 CSS 之后：已有内容非空时先空一行。
String appendAiCss(String existing, String addition) {
  final String tail = addition.trim();
  if (tail.isEmpty) {
    return existing;
  }
  final String head = existing.trimRight();
  return head.isEmpty ? tail : '$head\n\n$tail';
}

/// 跑一次「让 AI 帮忙」。失败原样抛 [AiChatFailure]（文案已脱敏），由 UI 转成提示。
Future<AiDictStyleSuggestion> requestAiDictStyle({
  required AiChatClient client,
  required AiProviderConfig provider,
  required String request,
  required List<DictStyleRule> currentRules,
  required String currentCss,
  String? dictionaryName,
  Iterable<String> availableDictionaries = const <String>[],
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiDictStyleSystemPrompt()),
      AiChatMessage.user(
        buildAiDictStyleUserPrompt(
          request: request,
          currentRules: currentRules,
          currentCss: currentCss,
          dictionaryName: dictionaryName,
          availableDictionaries: availableDictionaries,
        ),
      ),
    ],
  );
  return parseAiDictStyleSuggestion(
    reply,
    allowedDictionaries: availableDictionaries,
  );
}
