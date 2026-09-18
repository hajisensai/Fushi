/// 让 AI 按自然语言描述生成自定义主题配色。
///
/// 与 `ai_dict_style_assistant.dart` 同一套纪律：AI 只产出**配置**——一组按编辑页
/// 角色命名的颜色（主题色 / 界面底色 / 阅读器正文与背景 / 链接 / 选区 / 有声书
/// 高亮 / 三个派生色微调）加两个布尔开关；产物只进编辑页草稿，用户看过预览后仍要
/// 自己按「应用」才落进主题列表。热路径（ColorScheme 派生、阅读器渲染）永远是本地
/// 代码，没指派提供商时编辑页与没有 AI 完全一致。
///
/// 产出一律先过本地校验：认不出的角色名丢弃、非法颜色丢弃、不允许透明度的角色被
/// 强制不透明——模型偶尔会给页面底色一个半透明值，落地就是整页发灰。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_dict_style_assistant.dart'
    show parseAiDictColor;
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';
import 'package:fushi/src/models/theme_notifier.dart' show CustomThemeEntry;

/// 编辑页里可改的颜色角色。与 `custom_theme_page.dart` 的私有 `_ThemeRole`
/// 一一对应；这里单独定义是为了让提示词 / 解析层不依赖 UI 文件，并且角色名就是
/// 模型回复 JSON 里的键名（提示词与解析共用同一份 [name]，加角色不会漏一边）。
enum AiThemeRole {
  /// 主题色：写进条目的 `seed` 与钉死的 `primaryColor`。
  accent,

  /// 界面底色（页面 / 卡片 / 菜单）→ `surfaceColor`。
  surface,

  /// 阅读器正文字色 → `fontColor`。
  readerText,

  /// 阅读器页面背景 → `bgColor`。
  readerBackground,

  /// 书内链接 → `linkColor`。
  link,

  /// 查词选区高亮 → `selectionColor`。
  selection,

  /// 有声书当前句高亮 → `sentenceAudioHighlightColor`（全局偏好）。
  audioHighlight,

  /// ColorScheme.secondary → `secondaryColor`。
  secondary,

  /// ColorScheme.tertiary → `tertiaryColor`。
  tertiary,

  /// ColorScheme.primaryContainer → `containerColor`。
  container;

  /// 允许透明度的角色：叠在正文上的高亮类与正文字色（旧数据里有带 alpha 的）。
  /// 与编辑页选色器的 `enableAlpha` 同一份判据。
  bool get allowsAlpha => switch (this) {
    AiThemeRole.readerText ||
    AiThemeRole.selection ||
    AiThemeRole.audioHighlight => true,
    _ => false,
  };

  static AiThemeRole? fromAi(Object? value) {
    if (value is! String) {
      return null;
    }
    final String lower = value.trim().toLowerCase();
    for (final AiThemeRole role in AiThemeRole.values) {
      if (role.name.toLowerCase() == lower) {
        return role;
      }
    }
    return null;
  }
}

/// AI 给出的一组主题改动。所有字段都是「可选覆盖」：null / 缺省 = 不动。
class AiThemeSuggestion {
  const AiThemeSuggestion({
    this.colors = const <AiThemeRole, int>{},
    this.name,
    this.neutralDerived,
    this.explanation = '',
  });

  /// 已校验的角色 → 0xAARRGGBB。
  final Map<AiThemeRole, int> colors;

  /// 建议的主题名；只在用户还没起名时采用（见 [applyTo]）。
  final String? name;

  /// 派生色是否走中性灰。
  final bool? neutralDerived;

  /// AI 对这组改动的一句话说明，直接显示给用户。
  final String explanation;

  bool get isEmpty =>
      colors.isEmpty && neutralDerived == null && (name?.isEmpty ?? true);

  /// 把建议并到当前草稿条目上：只覆盖 AI 给出的角色，其余原样保留。
  ///
  /// 主题色是「所见即所得」语义：AI 选的就是最终 primary，所以同时写 `seed`
  /// 与 `primaryColor`（编辑页读到 `primaryColor != null` 会把「按明暗自动调色调」
  /// 关掉）；没给主题色时两者都不动，自动调色调开关随之保持。
  CustomThemeEntry applyTo(CustomThemeEntry base) {
    int? pick(AiThemeRole role, int? current) => colors[role] ?? current;
    final int? accent = colors[AiThemeRole.accent];
    final String trimmedName = name?.trim() ?? '';
    return CustomThemeEntry(
      id: base.id,
      name: base.name.trim().isEmpty && trimmedName.isNotEmpty
          ? trimmedName
          : base.name,
      seed: accent ?? base.seed,
      primaryColor: accent ?? base.primaryColor,
      surfaceColor: pick(AiThemeRole.surface, base.surfaceColor),
      fontColor: pick(AiThemeRole.readerText, base.fontColor),
      bgColor: pick(AiThemeRole.readerBackground, base.bgColor),
      linkColor: pick(AiThemeRole.link, base.linkColor),
      selectionColor: pick(AiThemeRole.selection, base.selectionColor),
      sentenceAudioHighlightColor: pick(
        AiThemeRole.audioHighlight,
        base.sentenceAudioHighlightColor,
      ),
      secondaryColor: pick(AiThemeRole.secondary, base.secondaryColor),
      tertiaryColor: pick(AiThemeRole.tertiary, base.tertiaryColor),
      containerColor: pick(AiThemeRole.container, base.containerColor),
      followSystemAccent: base.followSystemAccent,
      neutralDerived: neutralDerived ?? base.neutralDerived,
    );
  }
}

String _roleSemantics(AiThemeRole role) => switch (role) {
  AiThemeRole.accent =>
    'accent colour: buttons, links in the UI, active tabs; also the seed the '
        'rest of the palette is derived from. Opaque only.',
  AiThemeRole.surface =>
    'UI background: pages, cards, menus (the other neutral levels are derived '
        'from it). Opaque only. Omit to keep it derived from the accent.',
  AiThemeRole.readerText =>
    'reader body text colour (also reader chrome icons and dictionary popup '
        'text). May carry alpha.',
  AiThemeRole.readerBackground =>
    'reader page background (also reader chrome and dictionary popup '
        'background). Opaque only.',
  AiThemeRole.link =>
    'in-book hyperlinks and selection drag handles. Opaque only.',
  AiThemeRole.selection =>
    'lookup selection highlight painted over text; usually translucent.',
  AiThemeRole.audioHighlight =>
    'audiobook current-sentence highlight painted over text; usually '
        'translucent.',
  AiThemeRole.secondary =>
    'ColorScheme.secondary: tags, badges, selected list items. Opaque only. '
        'Omit unless the user asks to fine-tune it.',
  AiThemeRole.tertiary =>
    'ColorScheme.tertiary: collection and statistics accents. Opaque only. '
        'Omit unless the user asks to fine-tune it.',
  AiThemeRole.container =>
    'ColorScheme.primaryContainer: switch tracks, FAB, playback bar. Opaque '
        'only. Omit unless the user asks to fine-tune it.',
};

/// 系统提示：角色清单从 [AiThemeRole] 推导，加角色时提示词自动跟上。
String buildAiThemeSystemPrompt() {
  final StringBuffer roles = StringBuffer();
  for (final AiThemeRole role in AiThemeRole.values) {
    roles.writeln('- ${role.name}: ${_roleSemantics(role)}');
  }
  return '''
You design colour themes for a Japanese reading app (e-book reader, video
player, dictionary popups). The app renders everything locally; you only emit a
colour configuration. Every colour role is optional: include a role only when
the user's request needs it to change, and leave the rest out so it keeps
following the theme. For a request like "make me a warm sepia theme" set the
roles that define the look (accent, surface, readerText, readerBackground);
for "make the links greener" set only link.

Colour roles (each is a key of "colors"):
$roles
Rules:
- Colours are CSS hex strings: "#rrggbb", or "#aarrggbb" for roles that may
  carry alpha. Never use names, rgb(), hsl() or gradients.
- Keep text readable: body text against the reader background and the accent
  against the UI background should reach at least 4.5:1 and 3:1 contrast.
- The theme is previewed in the brightness given in the request; if the user
  does not name a mode, design for that brightness.
- "neutralDerived": true makes derived colours (tags, selected rows, menus)
  neutral grey instead of tinted with the accent; include it only when the
  request implies it.
- "name": a short theme name (at most 3 words, in the user's language) only
  when the user asks for a whole new theme; omit it for small tweaks.

Answer with a single JSON object and nothing else:
{"explanation": "...", "name": null, "neutralDerived": null, "colors": {"accent": "#rrggbb", ...}}
- "explanation" is one sentence, written in the same language the user wrote in.
''';
}

String _hex(int argb) => '#${argb.toRadixString(16).padLeft(8, '0')}';

/// 用户侧提示：带上当前草稿的每个角色（覆盖值或「跟随主题」），让模型做**相对
/// 修改**而不是从零重写。
String buildAiThemeUserPrompt({
  required String request,
  required CustomThemeEntry current,
  required bool darkMode,
  int? audioHighlight,
}) {
  final Map<String, Object?> state = <String, Object?>{
    AiThemeRole.accent.name: _hex(current.primaryColor ?? current.seed),
    AiThemeRole.surface.name: _hexOrNull(current.surfaceColor),
    AiThemeRole.readerText.name: _hexOrNull(current.fontColor),
    AiThemeRole.readerBackground.name: _hexOrNull(current.bgColor),
    AiThemeRole.link.name: _hexOrNull(current.linkColor),
    AiThemeRole.selection.name: _hexOrNull(current.selectionColor),
    AiThemeRole.audioHighlight.name: _hexOrNull(
      audioHighlight ?? current.sentenceAudioHighlightColor,
    ),
    AiThemeRole.secondary.name: _hexOrNull(current.secondaryColor),
    AiThemeRole.tertiary.name: _hexOrNull(current.tertiaryColor),
    AiThemeRole.container.name: _hexOrNull(current.containerColor),
  };
  final StringBuffer buffer = StringBuffer()
    ..writeln('Request: $request')
    ..writeln('Preview brightness: ${darkMode ? 'dark' : 'light'}')
    ..writeln(
      'Current colours (null = follows the theme, derived from accent): '
      '${jsonEncode(state)}',
    )
    ..writeln('Current neutralDerived: ${current.neutralDerived}');
  if (current.name.trim().isNotEmpty) {
    buffer.writeln('Current theme name: ${jsonEncode(current.name.trim())}');
  }
  return buffer.toString();
}

String? _hexOrNull(int? argb) => argb == null ? null : _hex(argb);

/// 解析模型回复。解析不出结构就返回空建议。
///
/// 颜色经 [parseAiDictColor]（`#rgb` / `#rrggbb` / `#aarrggbb`），不允许透明度的
/// 角色一律抹成不透明；认不出的角色 / 颜色整条丢弃，宁可少改一个也不把坏值塞进
/// 草稿。
AiThemeSuggestion parseAiThemeSuggestion(String reply) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) {
    return const AiThemeSuggestion();
  }
  final Map<AiThemeRole, int> colors = <AiThemeRole, int>{};
  final Object? rawColors = decoded['colors'];
  if (rawColors is Map) {
    rawColors.forEach((Object? key, Object? value) {
      final AiThemeRole? role = AiThemeRole.fromAi(key);
      if (role == null) {
        return;
      }
      // 只认 hex 字符串：提示词就是这么要求的，裸整数（模型偶尔回 12 / 0）
      // 不是颜色，透传进来只会变成一块近黑。
      final int? argb = value is String ? parseAiDictColor(value) : null;
      if (argb == null) {
        return;
      }
      colors[role] = role.allowsAlpha ? argb : (argb | 0xFF000000);
    });
  }
  final Object? rawName = decoded['name'];
  final String? name = rawName is String && rawName.trim().isNotEmpty
      ? rawName.trim()
      : null;
  final Object? rawNeutral = decoded['neutralDerived'];
  final Object? explanation = decoded['explanation'];
  return AiThemeSuggestion(
    colors: Map<AiThemeRole, int>.unmodifiable(colors),
    name: name,
    neutralDerived: rawNeutral is bool ? rawNeutral : null,
    explanation: explanation is String ? explanation.trim() : '',
  );
}

/// 跑一次「让 AI 帮忙」。失败原样抛 [AiChatFailure]（文案已脱敏），由 UI 转成提示。
Future<AiThemeSuggestion> requestAiTheme({
  required AiChatClient client,
  required AiProviderConfig provider,
  required String request,
  required CustomThemeEntry current,
  required bool darkMode,
  int? audioHighlight,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiThemeSystemPrompt()),
      AiChatMessage.user(
        buildAiThemeUserPrompt(
          request: request,
          current: current,
          darkMode: darkMode,
          audioHighlight: audioHighlight,
        ),
      ),
    ],
  );
  return parseAiThemeSuggestion(reply);
}
