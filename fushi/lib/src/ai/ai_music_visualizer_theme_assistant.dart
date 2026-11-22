/// 让 AI 按歌名 / 歌手 / 歌词给全屏歌词动画配一份每首的主题（[AiFeature.musicVisualizerTheme]）。
///
/// 移植 folia-major 的 `api-ts/generate-theme*.ts`（提示词）与 `shared/themeSanitizer.mjs`
/// （本地校验）：模型回明暗两套配色（背景 / 正文 / 强调 / 次要文字）、关键词着色、动画强度、
/// 字体风格。AI 只产出**配置**，热路径（各样式的绘制）永远是本地代码。
///
/// 产出一律先过本地校验（[sanitizeAiMusicVisualizerTheme]）：
/// - 颜色只认 `#rgb` / `#rrggbb`（folia 同款），认不出的回落 folia 的兜底配色；
/// - 背景亮度要与明暗模式相符、正文 / 次要文字 / 强调色对背景的对比度不够就换掉（folia 只在
///   提示词里要求对比度，这里落地前真的量一遍——模型偶尔给出看不清的组合）；
/// - 关键词必须在歌词（纯音乐时是歌名）里出现，且是本地按词着色（`LyricVisualizerTheme`）
///   认得出的形式；最多 [kAiVisualizerMaxWordColors] 个；
/// - 强度 / 字体风格是封闭枚举，认不出的取默认；名字与描述截短。
///
/// folia 的 `lyricsIcons`（Lucide 图标名）不要：本 app 没有这套图标，也没有样式用它。
library;

import 'dart:collection' show LinkedHashMap;
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_music/fushi_music.dart' show LyricLine, LyricTimeline;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';

/// 交给模型的歌词最多这么多字符（folia `lyricsText.slice(0, 2000)`）。
const int kAiVisualizerSourceMaxChars = 2000;

/// 关键词着色最多保留几个（folia 提示词要 10–20 个）。
const int kAiVisualizerMaxWordColors = 24;

/// 主题名 / 描述截到多长（folia：名字 ≤10 字、描述 15–30 字；留余量给非中文）。
const int kAiVisualizerMaxNameChars = 24;
const int kAiVisualizerMaxDescriptionChars = 80;

/// 字体风格（folia `Theme.fontStyle`）。[wire] 落盘（冻结）。
enum AiVisualizerFontStyle {
  sans('sans'),
  serif('serif'),
  mono('mono');

  const AiVisualizerFontStyle(this.wire);

  final String wire;

  static AiVisualizerFontStyle fromWire(Object? value) {
    for (final AiVisualizerFontStyle v in values) {
      if (v.wire == value) return v;
    }
    return sans;
  }

  /// 交给 [LyricVisualizerTheme.fontFamily] 的字体族提示：sans = 不覆盖（app 默认字体），
  /// serif / mono 用平台通用族名，本机没有时 Flutter 自己回落默认字体。
  String? get fontFamily => switch (this) {
    AiVisualizerFontStyle.sans => null,
    AiVisualizerFontStyle.serif => 'serif',
    AiVisualizerFontStyle.mono => 'monospace',
  };
}

/// 一种明暗模式下的配色（folia `Theme` 的颜色部分）。
@immutable
class AiVisualizerThemeVariant {
  const AiVisualizerThemeVariant({
    required this.background,
    required this.text,
    required this.accent,
    required this.secondary,
    this.name = '',
    this.description = '',
    this.wordColors = const <String, Color>{},
  });

  /// folia `backgroundColor`。
  final Color background;

  /// folia `primaryColor`：正文字色。
  final Color text;

  /// folia `accentColor`：正在唱的字 / 强调效果。
  final Color accent;

  /// folia `secondaryColor`：次要文字（歌手 / 专辑 / 译文）。
  final Color secondary;
  final String name;
  final String description;

  /// 关键词 → 颜色（有序：同优先级先写的先匹配，见 [LyricVisualizerTheme.wordColors]）。
  final Map<String, Color> wordColors;

  Map<String, Object?> toJson() => <String, Object?>{
    'backgroundColor': aiVisualizerHex(background),
    'primaryColor': aiVisualizerHex(text),
    'accentColor': aiVisualizerHex(accent),
    'secondaryColor': aiVisualizerHex(secondary),
    'name': name,
    'description': description,
    'wordColors': <Map<String, String>>[
      for (final MapEntry<String, Color> e in wordColors.entries)
        <String, String>{'word': e.key, 'color': aiVisualizerHex(e.value)},
    ],
  };

  @override
  bool operator ==(Object other) =>
      other is AiVisualizerThemeVariant &&
      other.background == background &&
      other.text == text &&
      other.accent == accent &&
      other.secondary == secondary &&
      other.name == name &&
      other.description == description &&
      mapEquals(other.wordColors, wordColors);

  @override
  int get hashCode => Object.hash(
    background,
    text,
    accent,
    secondary,
    name,
    description,
    Object.hashAll(
      wordColors.entries.map(
        (MapEntry<String, Color> e) => Object.hash(e.key, e.value),
      ),
    ),
  );
}

/// AI 给一首歌生成的主题：明暗两套配色 + 强度 + 字体风格。
@immutable
class AiMusicVisualizerTheme {
  const AiMusicVisualizerTheme({
    required this.light,
    required this.dark,
    this.intensity = LyricVisualizerIntensity.normal,
    this.fontStyle = AiVisualizerFontStyle.sans,
  });

  final AiVisualizerThemeVariant light;
  final AiVisualizerThemeVariant dark;
  final LyricVisualizerIntensity intensity;
  final AiVisualizerFontStyle fontStyle;

  AiVisualizerThemeVariant variantFor(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// 换成歌词动画框架的主题契约。folia 主题色对应：primaryColor → 正文 `text`，
  /// accentColor → `primary` 与 `accent`（各样式移植时两种对应都有），其余照名。
  LyricVisualizerTheme toVisualizerTheme(Brightness brightness) {
    final AiVisualizerThemeVariant v = variantFor(brightness);
    return LyricVisualizerTheme(
      wordColors: v.wordColors,
      palette: LyricVisualizerPaletteOverride(
        background: v.background,
        primary: v.accent,
        secondary: v.secondary,
        accent: v.accent,
        text: v.text,
      ),
      intensity: intensity,
      fontFamily: fontStyle.fontFamily,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'light': light.toJson(),
    'dark': dark.toJson(),
    'animationIntensity': intensity.prefValue,
    'fontStyle': fontStyle.wire,
  };

  /// 读本机缓存：与 AI 回复走同一份校验（不再查关键词是否在歌词里——写入时已查过）。
  /// 坏数据返回 null。
  static AiMusicVisualizerTheme? fromJson(Object? json) =>
      json is Map ? sanitizeAiMusicVisualizerTheme(json) : null;

  @override
  bool operator ==(Object other) =>
      other is AiMusicVisualizerTheme &&
      other.light == light &&
      other.dark == dark &&
      other.intensity == intensity &&
      other.fontStyle == fontStyle;

  @override
  int get hashCode => Object.hash(light, dark, intensity, fontStyle);
}

// ── 本地校验（folia themeSanitizer.mjs） ─────────────────────────────────────

/// folia `FALLBACK_LIGHT_THEME` / `FALLBACK_DARK_THEME`。
const AiVisualizerThemeVariant kAiVisualizerFallbackLight =
    AiVisualizerThemeVariant(
      background: Color(0xFFFFFFFF),
      text: Color(0xFF111827),
      accent: Color(0xFF2563EB),
      secondary: Color(0xFF475569),
    );
const AiVisualizerThemeVariant kAiVisualizerFallbackDark =
    AiVisualizerThemeVariant(
      background: Color(0xFF0F172A),
      text: Color(0xFFF8FAFC),
      accent: Color(0xFF7DD3FC),
      secondary: Color(0xFFCBD5E1),
    );

final RegExp _hexColor = RegExp(r'^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$');

/// folia `normalizeHexColorCandidate`：只认 `#rgb` / `#rrggbb`，结果不透明。
Color? parseAiVisualizerColor(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  if (!_hexColor.hasMatch(trimmed)) return null;
  String hex = trimmed.substring(1);
  if (hex.length == 3) {
    hex = hex.split('').map((String c) => '$c$c').join();
  }
  return Color(0xFF000000 | int.parse(hex, radix: 16));
}

/// `#rrggbb`（小写，不透明色）。
String aiVisualizerHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// WCAG 对比度。
double aiVisualizerContrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 正文对背景至少这么高（WCAG AA）；次要文字与强调色放宽一些（folia 要求次要文字 4.5，
/// 但它们字更大 / 只做点缀，3 已能看清，太严会把模型选的味道全换掉）。
const double kAiVisualizerMinTextContrast = 4.5;
const double kAiVisualizerMinSecondaryContrast = 3;
const double kAiVisualizerMinAccentContrast = 2;

/// 明暗模式对背景亮度的要求：亮色模式背景不能太暗，暗色模式背景不能太亮。
const double kAiVisualizerLightMinBackgroundLuminance = 0.35;
const double kAiVisualizerDarkMaxBackgroundLuminance = 0.2;

final RegExp _cjk = RegExp(r'[一-龥぀-ヿ가-힯]');
final RegExp _asciiWord = RegExp(r'\w+');
final RegExp _onlyAsciiWord = RegExp(r'^\w+$');

/// 词首尾的标点 / 引号 / 空白（folia：`word` 是去掉外围标点后的原文）。
final RegExp _edgePunct = RegExp(
  r'''^[\s"'`‘’“”「」『』（）()\[\]{}<>《》【】,.!?;:，。！？；：、…~\-—–]+|[\s"'`‘’“”「」『』（）()\[\]{}<>《》【】,.!?;:，。！？；：、…~\-—–]+$''',
);

/// 把关键词规整成本地按词着色认得出的形式；不在 [source] 里出现的返回 null。
///
/// CJK 关键词按子串查（与 `LyricVisualizerTheme.colorRangesFor` 一致）；其余必须是一个
/// 纯 `\w` 单词（folia 明令不要标点 / 空格 / 短语），按单词匹配、不分大小写。`\w` 之外的
/// 拉丁扩展 / 西里尔字母本地着色认不出，直接丢掉而不是存一个永远不会生效的键。
String? normalizeAiVisualizerWord(
  Object? raw, {
  required String source,
  required Set<String> sourceWords,
}) {
  if (raw is! String) return null;
  final String word = raw.replaceAll(_edgePunct, '').trim();
  if (word.isEmpty || word.length > 24) return null;
  if (_cjk.hasMatch(word)) {
    return source.contains(word) ? word : null;
  }
  if (!_onlyAsciiWord.hasMatch(word)) return null;
  return sourceWords.contains(word.toLowerCase()) ? word : null;
}

Color _opaque(Color c) => c.withValues(alpha: 1);

/// 一种模式的配色校验（folia `sanitizeTheme`，加上真量的亮度 / 对比度约束）。
/// [source] 为 null = 不查关键词出处（读缓存）。
AiVisualizerThemeVariant _sanitizeVariant(
  Object? raw,
  AiVisualizerThemeVariant fallback, {
  required bool dark,
  required String? source,
  required Set<String> sourceWords,
}) {
  final Map<Object?, Object?> m = raw is Map
      ? raw.cast<Object?, Object?>()
      : const <Object?, Object?>{};
  Color background =
      parseAiVisualizerColor(m['backgroundColor']) ?? fallback.background;
  final double bgLum = background.computeLuminance();
  if (dark
      ? bgLum > kAiVisualizerDarkMaxBackgroundLuminance
      : bgLum < kAiVisualizerLightMinBackgroundLuminance) {
    background = fallback.background;
  }
  Color text = parseAiVisualizerColor(m['primaryColor']) ?? fallback.text;
  if (aiVisualizerContrast(text, background) < kAiVisualizerMinTextContrast) {
    text =
        aiVisualizerContrast(fallback.text, background) >=
            kAiVisualizerMinTextContrast
        ? fallback.text
        : (background.computeLuminance() > 0.18
              ? const Color(0xFF000000)
              : const Color(0xFFFFFFFF));
  }
  Color secondary =
      parseAiVisualizerColor(m['secondaryColor']) ?? fallback.secondary;
  if (aiVisualizerContrast(secondary, background) <
      kAiVisualizerMinSecondaryContrast) {
    secondary = _opaque(Color.lerp(background, text, 0.75)!);
  }
  Color accent = parseAiVisualizerColor(m['accentColor']) ?? fallback.accent;
  if (aiVisualizerContrast(accent, background) <
      kAiVisualizerMinAccentContrast) {
    accent =
        aiVisualizerContrast(fallback.accent, background) >=
            kAiVisualizerMinAccentContrast
        ? fallback.accent
        : text;
  }
  final LinkedHashMap<String, Color> words = LinkedHashMap<String, Color>();
  final Set<String> seen = <String>{};
  final Object? rawWords = m['wordColors'];
  if (rawWords is List) {
    for (final Object? entry in rawWords) {
      if (words.length >= kAiVisualizerMaxWordColors) break;
      if (entry is! Map) continue;
      final Object? rawWord = entry['word'];
      final String? word = source == null
          ? (rawWord is String && rawWord.trim().isNotEmpty
                ? rawWord.trim()
                : null)
          : normalizeAiVisualizerWord(
              rawWord,
              source: source,
              sourceWords: sourceWords,
            );
      if (word == null || !seen.add(word.toLowerCase())) continue;
      // folia：词色认不出时用本套的强调色。
      words[word] = parseAiVisualizerColor(entry['color']) ?? accent;
    }
  }
  return AiVisualizerThemeVariant(
    background: background,
    text: text,
    accent: accent,
    secondary: secondary,
    name: _clip(m['name'], kAiVisualizerMaxNameChars),
    description: _clip(m['description'], kAiVisualizerMaxDescriptionChars),
    wordColors: Map<String, Color>.unmodifiable(words),
  );
}

String _clip(Object? value, int max) {
  if (value is! String) return '';
  final String s = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  final List<int> runes = s.runes.toList();
  return runes.length <= max ? s : String.fromCharCodes(runes.take(max));
}

bool _hasAnyColor(Object? raw) =>
    raw is Map &&
    <String>[
      'backgroundColor',
      'primaryColor',
      'accentColor',
      'secondaryColor',
    ].any((String k) => parseAiVisualizerColor(raw[k]) != null);

/// folia `sanitizeDualTheme`：回复 → 已校验的主题。[source] 是交给模型的原文（歌词片段，
/// 纯音乐时是歌名）；给了就要求每个关键词都在里面出现。一个能用的颜色都没有（模型答非所问）
/// 返回 null——那不是「生成了一份兜底主题」，是失败。
///
/// 也接受没分明暗的单套回复（老格式 / 小模型偷懒）：两种模式共用它，再各自按亮度约束修正。
AiMusicVisualizerTheme? sanitizeAiMusicVisualizerTheme(
  Map<Object?, Object?> decoded, {
  String? source,
}) {
  final bool dual = decoded['light'] is Map || decoded['dark'] is Map;
  final Object? rawLight = dual ? decoded['light'] : decoded;
  final Object? rawDark = dual ? decoded['dark'] : decoded;
  if (!_hasAnyColor(rawLight) && !_hasAnyColor(rawDark)) return null;
  final Set<String> sourceWords = source == null
      ? const <String>{}
      : <String>{
          for (final RegExpMatch m in _asciiWord.allMatches(source))
            m[0]!.toLowerCase(),
        };
  // 强度 / 字体：folia 在每套里各有一份；这里取顶层，没有就取任一套里的。
  Object? pick(String key) =>
      decoded[key] ??
      (rawDark is Map ? rawDark[key] : null) ??
      (rawLight is Map ? rawLight[key] : null);
  return AiMusicVisualizerTheme(
    light: _sanitizeVariant(
      rawLight,
      kAiVisualizerFallbackLight,
      dark: false,
      source: source,
      sourceWords: sourceWords,
    ),
    dark: _sanitizeVariant(
      rawDark,
      kAiVisualizerFallbackDark,
      dark: true,
      source: source,
      sourceWords: sourceWords,
    ),
    intensity: LyricVisualizerIntensity.fromPref(
      pick('animationIntensity') as String?,
    ),
    fontStyle: AiVisualizerFontStyle.fromWire(pick('fontStyle')),
  );
}

/// 解析模型回复；解析不出 / 校验后不可用返回 null。
AiMusicVisualizerTheme? parseAiMusicVisualizerTheme(
  String reply, {
  required String source,
}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) return null;
  return sanitizeAiMusicVisualizerTheme(decoded, source: source);
}

// ── 提示词（folia generate-theme_openai.ts） ─────────────────────────────────

/// 交给模型的原文：主歌词逐行（不含翻译 / 和声行），截到 [kAiVisualizerSourceMaxChars]。
/// 没有歌词文本 = 纯音乐（folia `isPureMusic`），返回空串。
String aiVisualizerLyricsSnippet(LyricTimeline? timeline) {
  if (timeline == null) return '';
  final StringBuffer b = StringBuffer();
  for (final LyricLine line in timeline.lines) {
    if (line.isBackground) continue;
    final String text = line.text.trim();
    if (text.isEmpty) continue;
    if (b.isNotEmpty) b.write('\n');
    b.write(text);
    if (b.length >= kAiVisualizerSourceMaxChars) break;
  }
  final String s = b.toString();
  return s.length <= kAiVisualizerSourceMaxChars
      ? s
      : s.substring(0, kAiVisualizerSourceMaxChars);
}

String buildAiMusicVisualizerThemeSystemPrompt() => '''
Analyze the mood of the provided song source text and generate TWO visual theme
configurations for a full-screen animated lyrics view - one for LIGHT mode and
one for DARK mode. Both capture the SAME emotional essence of the song, with
palettes suited to their mode.

SOURCE MODE:
- If "Pure instrumental" is yes, the source text is the song title of an
  instrumental track, not lyrics. Otherwise it is a lyrics snippet.
- Base the mood only on the provided title, artist and source text.

WORKFLOW:
1. Identify 10-20 key emotional standalone words from the source text and give
   each a representative colour in "wordColors".
2. From their emotional direction, build each palette (backgroundColor,
   primaryColor, secondaryColor, accentColor). Word colours must harmonise with
   the palettes.

LIGHT THEME: light backgrounds, but avoid plain white every time (warm creams,
soft pastel blues, pale sage, gentle peach, warm sand, pale lavender...). Text
is a very dark tone matching the background hue, not pure black. accentColor
must be visible on the light background.

DARK THEME: rich dark backgrounds, not pure black (midnight blue, dark forest
green, charcoal, dark plum, deep chocolate, burgundy...). Text is a bright soft
tone matching the hue, not pure white. accentColor must contrast with the dark
background and come from the song's mood rather than generic bright yellow.

BOTH THEMES:
- primaryColor is the main lyric text; it must reach 4.5:1 contrast against
  backgroundColor.
- secondaryColor is secondary text (artist, translations); keep it readable
  (aim for 4.5:1).
- "wordColors" are the same words in both themes; colours may be tuned per mode.

wordColors RULES:
- Each "word" MUST appear verbatim in the source text (after removing
  surrounding punctuation). For Latin-script text each word is ONE complete
  word with no punctuation, apostrophes, hyphens or spaces; skip function words
  (the, a, to, me, and, of, in...). For CJK lyrics short meaningful terms of
  several characters are fine; avoid single particles.
- If the instrumental title is very short, the exact full title may be used.

ALSO DECIDE:
- "animationIntensity": "calm" for gentle / slow / sad songs, "chaotic" for
  aggressive / very energetic ones, otherwise "normal".
- "fontStyle": "serif" for classical / literary / nostalgic moods, "mono" for
  electronic / glitchy / technical moods, otherwise "sans".

Colours are CSS hex strings "#rrggbb" only - no names, rgb(), alpha or
gradients. Theme "name" is at most 10 characters and "description" is one
short first-person sentence of a listener's immediate emotional reaction
(stream-of-consciousness, literary, at most 30 characters for CJK languages),
both written in the language given as "Write names in".

Answer with a single JSON object and nothing else:
{"animationIntensity": "normal", "fontStyle": "sans",
 "light": {"name": "...", "description": "...", "backgroundColor": "#rrggbb",
   "primaryColor": "#rrggbb", "accentColor": "#rrggbb",
   "secondaryColor": "#rrggbb", "wordColors": [{"word": "...", "color": "#rrggbb"}]},
 "dark": {same keys}}
''';

String buildAiMusicVisualizerThemeUserPrompt({
  required String? title,
  required String? artist,
  required String lyricsSnippet,
  required String uiLanguage,
}) {
  final bool instrumental = lyricsSnippet.trim().isEmpty;
  final StringBuffer b = StringBuffer()
    ..writeln('Write names in: $uiLanguage')
    ..writeln('Pure instrumental: ${instrumental ? 'yes' : 'no'}');
  if (title != null && title.trim().isNotEmpty) {
    b.writeln('Song title: ${jsonEncode(title.trim())}');
  }
  if (artist != null && artist.trim().isNotEmpty) {
    b.writeln('Artist: ${jsonEncode(artist.trim())}');
  }
  b
    ..writeln('Source snippet:')
    ..write(instrumental ? (title ?? '').trim() : lyricsSnippet);
  return b.toString();
}

/// 关键词出处：歌词片段；纯音乐时是歌名。
String aiVisualizerWordSource({
  required String? title,
  required String lyricsSnippet,
}) => lyricsSnippet.trim().isEmpty ? (title ?? '').trim() : lyricsSnippet;

/// 跑一次生成。调用方负责「没指派提供商不调这里」（[provider] 必须是解析出来的那一家）。
/// 模型失败原样抛 [AiChatFailure]（文案已脱敏）；回复不可用返回 null。
Future<AiMusicVisualizerTheme?> requestAiMusicVisualizerTheme({
  required AiChatClient client,
  required AiProviderConfig provider,
  required String? title,
  required String? artist,
  required String lyricsSnippet,
  required String uiLanguage,
}) async {
  final String reply = await client.complete(
    provider: provider,
    maxTokens: 4096,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiMusicVisualizerThemeSystemPrompt()),
      AiChatMessage.user(
        buildAiMusicVisualizerThemeUserPrompt(
          title: title,
          artist: artist,
          lyricsSnippet: lyricsSnippet,
          uiLanguage: uiLanguage,
        ),
      ),
    ],
  );
  return parseAiMusicVisualizerTheme(
    reply,
    source: aiVisualizerWordSource(title: title, lyricsSnippet: lyricsSnippet),
  );
}
