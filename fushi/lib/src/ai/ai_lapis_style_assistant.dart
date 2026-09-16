/// 让 AI 按自然语言描述生成 Lapis 卡片样式。
///
/// 与 `ai_dict_style_assistant.dart` 同构：AI 只产出**配置**——一组
/// [LapisVisualRule]（走可视化编辑器同一条托管区段编译链）加一段用户自由 CSS；
/// 产物只进编辑器草稿，用户看过预览、点保存再由 `LapisTemplateService` 推到
/// Anki。AI 不碰 Anki、不碰模板基线。
///
/// 产出一律先过本地校验：未知字段丢弃、默认值规则丢弃、字段不支持盒模型时把
/// 边框 / 内外边距抹掉（与编辑器控件可见性一致），自由 CSS 经
/// [sanitizeAiLapisCss] 白名单过滤。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_css_sanitizer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// AI 给出的一组样式建议。
class AiLapisStyleSuggestion {
  const AiLapisStyleSuggestion({
    required this.rules,
    this.css = '',
    this.explanation = '',
  });

  /// 已校验的可视化规则，按字段去重（同字段只保留最后一条）。
  final Map<LapisVisualField, LapisVisualRule> rules;

  /// 已过白名单的自由 CSS，空串 = 没有。
  final String css;

  /// AI 对这组改动的一句话说明，直接显示给用户。
  final String explanation;

  bool get isEmpty => rules.isEmpty && css.trim().isEmpty;
}

/// vendored Lapis 模板（`lapis_note_type.dart`）里真实存在的类名 / id。
///
/// 自由 CSS 的选择器必须锚在这些 token 或 [lapisVisualSelector] 的 token 上。
/// 手抄清单而不是运行期从 CSS 里正则抽取，是为了让清单可审、可 diff；守卫测试
/// （`ai_lapis_style_assistant_test.dart`）逐个核对它们仍在模板里。
const List<String> kAiLapisKnownCssTokens = <String>[
  '#lapis',
  '#click',
  '#hint',
  '#pitch-tags',
  '#edge-prev',
  '#edge-next',
  '.card',
  '.nightMode',
  '.mobile',
  '.front-vocab',
  '.vocab',
  '.front-sentence',
  '.sentence',
  '.sentence-alt',
  '.pitch',
  '.pitch-line',
  '.pitch-item',
  '.pitch-low',
  '.pitch-to-drop',
  '.heiban',
  '.atamadaka',
  '.nakadaka',
  '.odaka',
  '.kifuku',
  '.audio-buttons',
  '.audio-buttons-alt',
  '.image',
  '.image-alt',
  '.images-container',
  '.img-popup-container',
  '.img-popup-img',
  '.modal-bg',
  '.def-header',
  '.def-image',
  '.def-info',
  '.definition',
  '.dh-image',
  '.dh-vocab',
  '.main-def',
  '.misc-info',
  '.info',
  '.tags',
  '.tags-container',
  '.top-container',
  '.bot-container',
  '.edge',
  '.freq-dropdown',
  '.freq-list-container',
  '.replay-button',
  '.hidden',
  '.Nsfw',
  '.yomitan-glossary',
  '.dict-group__glossary',
  '.dict-group__glossary--first-line',
  '.dict-group__tag-list',
  '.dict-group__tag',
  '.dict-group__tag--dict',
  '.glossary-text__summary',
];

/// 自由 CSS 允许锚定的全部 token：模板类名清单 + 可视字段选择器里的类名 / id。
List<String> aiLapisCssAllowedSelectors() {
  final Set<String> tokens = <String>{...kAiLapisKnownCssTokens};
  final RegExp simple = RegExp(r'[.#][A-Za-z_][\w-]*');
  for (final LapisVisualField field in LapisVisualField.values) {
    for (final RegExpMatch match in simple.allMatches(
      lapisVisualSelector(field),
    )) {
      tokens.add(match.group(0)!);
    }
  }
  return tokens.toList();
}

/// 只对支持盒模型的字段有意义的属性；其它字段上会被抹掉。
const List<String> _kBoxLayoutProps = <String>[
  'borderWidthPx',
  'borderColorHex',
  'borderRadiusPx',
  'paddingPx',
  'marginBlockPx',
];

/// 系统提示：字段清单从 [LapisVisualField.values] 推导，属性清单对应
/// [LapisVisualRule] 的真实字段。
String buildAiLapisStyleSystemPrompt() {
  final StringBuffer fields = StringBuffer();
  for (final LapisVisualField field in LapisVisualField.values) {
    final List<String> notes = <String>[
      if (field.backOnly) 'back side only',
      if (field.supportsBoxLayout)
        'supports box props'
      else
        'text props only (no border/padding/margin)',
    ];
    fields.writeln(
      '- ${field.wireName}: selector `${lapisVisualSelector(field)}`; '
      '${_fieldSemantics(field)}; ${notes.join(', ')}',
    );
  }
  return '''
You restyle an Anki card that uses the Lapis note type (Japanese vocabulary
cards). The card is rendered by Anki; you only emit a style configuration.
Prefer structured "rules"; use "css" only for things rules cannot express
(hiding a part, font family, spacing between parts, animations off, etc.).

Fields (each is one "field" value):
$fields
Rule props (all optional; omit what should stay unchanged):
- fontScalePercent: integer percent of the default size, 50-250 (100 = unchanged)
- bold: true or false
- alignment: "start", "center" or "end"
- colorHex: "#RRGGBB" text colour
- lineHeightPercent: integer 100-250
- backgroundColorHex: "#RRGGBB"
- borderWidthPx: integer 0-12 (box fields only)
- borderColorHex: "#RRGGBB" (box fields only)
- borderRadiusPx: integer 0-48 (box fields only)
- paddingPx: integer 0-48 (box fields only)
- marginBlockPx: integer 0-48 (box fields only)

CSS constraints:
- Only use the selectors listed above or these Lapis template classes/ids:
  ${kAiLapisKnownCssTokens.join(' ')}
  (descendants of them are fine).
- Never target body, html, *, or bare element selectors.
- Never use @import, url(), expression(), javascript: or script tags.
- Lapis rules have high specificity; add !important when overriding them in css.

Answer with a single JSON object and nothing else:
{"explanation": "...", "rules": [{"field": "<field>", "fontScalePercent": 120, "bold": true}], "css": ""}
- A rule replaces the existing rule for that field entirely, so repeat the
  current values of props the user did not ask to change.
- "explanation" must be written in the same language the user wrote in.
''';
}

String _fieldSemantics(LapisVisualField field) => switch (field) {
  LapisVisualField.expression => 'the target word',
  LapisVisualField.reading => 'reading with pitch accent',
  LapisVisualField.sentence => 'the example sentence',
  LapisVisualField.definitionInfo =>
    'the "definition 1/N" counter label above the definition',
  LapisVisualField.definitionBox => 'the whole definition box',
  LapisVisualField.definitionContent => 'the definition text area',
  LapisVisualField.selectedDefinition => 'the user-selected definition text',
  LapisVisualField.primaryDefinition => 'the main definition',
  LapisVisualField.glossaries => 'the full glossary list',
  LapisVisualField.dictionaryEntry => 'one dictionary entry in a glossary',
  LapisVisualField.dictionaryName => 'the dictionary name inside an entry',
  LapisVisualField.definitionExample => 'example sentences inside a definition',
};

/// 用户侧提示：带上当前规则与自由 CSS，让模型做**相对修改**。
String buildAiLapisStyleUserPrompt({
  required String request,
  required Map<LapisVisualField, LapisVisualRule> currentRules,
  required String currentCss,
}) {
  final StringBuffer buffer = StringBuffer()..writeln('Request: $request');
  final List<Map<String, Object?>> rules = <Map<String, Object?>>[
    for (final MapEntry<LapisVisualField, LapisVisualRule> entry
        in currentRules.entries)
      if (!entry.value.isDefault)
        <String, Object?>{'field': entry.key.wireName, ...entry.value.toJson()},
  ];
  if (rules.isNotEmpty) {
    buffer.writeln('Current rules: ${jsonEncode(rules)}');
  }
  if (currentCss.trim().isNotEmpty) {
    buffer.writeln('Current user CSS:\n$currentCss');
  }
  return buffer.toString();
}

/// 自由 CSS 的白名单过滤（见 [sanitizeAiCss]）。
String sanitizeAiLapisCss(String css) =>
    sanitizeAiCss(css, allowedSelectors: aiLapisCssAllowedSelectors());

/// 解析模型回复。解析不出结构就返回空建议。
///
/// `rules` 既接受 `[{"field": ..., ...}]` 列表，也接受 `{"<field>": {...}}`
/// 键值形（那正是托管区段 CONFIG 的持久化形态，模型看见当前规则后常会照抄）。
AiLapisStyleSuggestion parseAiLapisStyleSuggestion(String reply) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) {
    return const AiLapisStyleSuggestion(
      rules: <LapisVisualField, LapisVisualRule>{},
    );
  }
  final Map<LapisVisualField, LapisVisualRule> rules =
      <LapisVisualField, LapisVisualRule>{};
  final Object? rawRules = decoded['rules'];
  if (rawRules is List) {
    for (final Object? raw in rawRules) {
      if (raw is! Map) {
        continue;
      }
      final LapisVisualField? field = _fieldFromAi(raw['field']);
      if (field == null) {
        continue;
      }
      _addRule(rules, field, raw);
    }
  } else if (rawRules is Map) {
    for (final MapEntry<Object?, Object?> entry in rawRules.entries) {
      final LapisVisualField? field = _fieldFromAi(entry.key);
      final Object? raw = entry.value;
      if (field == null || raw is! Map) {
        continue;
      }
      _addRule(rules, field, raw);
    }
  }
  final Object? rawCss = decoded['css'];
  final String css = rawCss is String ? sanitizeAiLapisCss(rawCss) : '';
  final Object? explanation = decoded['explanation'];
  return AiLapisStyleSuggestion(
    rules: Map<LapisVisualField, LapisVisualRule>.unmodifiable(rules),
    css: css,
    explanation: explanation is String ? explanation.trim() : '',
  );
}

void _addRule(
  Map<LapisVisualField, LapisVisualRule> into,
  LapisVisualField field,
  Map<Object?, Object?> raw,
) {
  final LapisVisualRule? rule = LapisVisualRule.fromJson(
    _normalizeRule(raw, field),
  );
  // 默认值规则等于「没改」，与编辑器 `_updateSelectedRule` 里 remove 的语义一致。
  if (rule == null || rule.isDefault) {
    into.remove(field);
    return;
  }
  into[field] = rule;
}

LapisVisualField? _fieldFromAi(Object? value) {
  if (value is! String) {
    return null;
  }
  final String name = value.trim();
  final LapisVisualField? exact = LapisVisualField.fromWireName(name);
  if (exact != null) {
    return exact;
  }
  // 容忍枚举名 / 大小写差异：模型偶尔回 "definitionBox" 而不是 "definition-box"。
  final String folded = name.toLowerCase().replaceAll(RegExp(r'[-_\s]'), '');
  for (final LapisVisualField field in LapisVisualField.values) {
    if (field.name.toLowerCase() == folded ||
        field.wireName.replaceAll('-', '') == folded) {
      return field;
    }
  }
  return null;
}

/// 把模型给的规则规整成 [LapisVisualRule.fromJson] 认的形态：数字字符串转数、
/// 百分比 / 像素允许小数但取整、颜色补成 `#RRGGBB`，不支持盒模型的字段抹掉
/// 盒属性。
Map<String, dynamic> _normalizeRule(
  Map<Object?, Object?> raw,
  LapisVisualField field,
) {
  final Map<String, dynamic> out = <String, dynamic>{};
  for (final MapEntry<Object?, Object?> entry in raw.entries) {
    final String key = '${entry.key}';
    final Object? value = entry.value;
    switch (key) {
      case 'fontScalePercent':
      case 'lineHeightPercent':
      case 'borderWidthPx':
      case 'borderRadiusPx':
      case 'paddingPx':
      case 'marginBlockPx':
        final int? number = _asInt(value);
        if (number != null) {
          out[key] = number;
        }
      case 'bold':
        if (value is bool) {
          out[key] = value;
        } else if (value is String) {
          out[key] = value.toLowerCase() == 'true';
        }
      case 'alignment':
        if (value is String) {
          out[key] = _normalizeAlignment(value);
        }
      case 'colorHex':
      case 'backgroundColorHex':
      case 'borderColorHex':
        final String? hex = _normalizeHex(value);
        if (hex != null) {
          out[key] = hex;
        }
    }
  }
  if (!field.supportsBoxLayout) {
    for (final String key in _kBoxLayoutProps) {
      out.remove(key);
    }
  }
  return out;
}

int? _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  if (value is String) {
    final double? parsed = double.tryParse(
      value.trim().toLowerCase().replaceAll(RegExp(r'(px|%)$'), ''),
    );
    return parsed?.round();
  }
  return null;
}

String _normalizeAlignment(String value) =>
    switch (value.trim().toLowerCase()) {
      'left' => 'start',
      'right' => 'end',
      final String other => other,
    };

/// `#rgb` / `#rrggbb` / `rrggbb` → `#RRGGBB`；带透明通道或认不出的返回 null
/// （[LapisVisualRule] 只存六位十六进制）。
String? _normalizeHex(Object? value) {
  if (value is! String) {
    return null;
  }
  String hex = value.trim();
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  }
  if (hex.length == 3) {
    hex = hex.split('').map((String c) => '$c$c').join();
  }
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
    return null;
  }
  return '#${hex.toUpperCase()}';
}

/// 把 AI 补充的 CSS 追加到已有自由 CSS 之后：已有内容非空时先空一行。
String appendAiLapisCss(String existing, String addition) {
  final String tail = addition.trim();
  if (tail.isEmpty) {
    return existing;
  }
  final String head = existing.trimRight();
  return head.isEmpty ? tail : '$head\n\n$tail';
}

/// 跑一次「让 AI 帮忙」。失败原样抛 [AiChatFailure]（文案已脱敏），由 UI 转成提示。
Future<AiLapisStyleSuggestion> requestAiLapisStyle({
  required AiChatClient client,
  required AiProviderConfig provider,
  required String request,
  required Map<LapisVisualField, LapisVisualRule> currentRules,
  required String currentCss,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiLapisStyleSystemPrompt()),
      AiChatMessage.user(
        buildAiLapisStyleUserPrompt(
          request: request,
          currentRules: currentRules,
          currentCss: currentCss,
        ),
      ),
    ],
  );
  return parseAiLapisStyleSuggestion(reply);
}
