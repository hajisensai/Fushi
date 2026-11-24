/// 歌词动画的全局字幕偏好（folia 的「副字幕内容」`subtitleContentMode`、`hideTranslationSubtitle`、
/// 字幕字体 `subtitleTheme`、`subtitleFontScale`）：宿主从设置读出来放进
/// `LyricVisualizerContext.subtitle`，共享底部字幕与自己排译文的样式（静止 / 莫奈 / 时计）都读它。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';

/// 副字幕显示什么（folia `SubtitleContentMode`）。[prefValue] 落库（冻结，与 folia 同名）。
enum LyricVisualizerSubtitleContent {
  translation('translation'),
  romanization('romanization'),

  /// 罗马音 + 译文两行（罗马音在前：跟唱读的那行领头，译文当注解，folia 同序）。
  both('both'),
  none('none');

  const LyricVisualizerSubtitleContent(this.prefValue);

  final String prefValue;

  static const LyricVisualizerSubtitleContent defaultContent = translation;

  static LyricVisualizerSubtitleContent fromPref(String? value) {
    for (final LyricVisualizerSubtitleContent v in values) {
      if (v.prefValue == value) return v;
    }
    return defaultContent;
  }
}

/// 字幕字体（folia `subtitleTheme`：默认跟随歌词字体，也可单独选）。[prefValue] 落库（冻结）。
enum LyricVisualizerSubtitleFont {
  /// 跟随歌词（含 AI 主题的字体 / 字重）。
  inherit('inherit'),
  sans('sans'),
  serif('serif'),
  mono('mono');

  const LyricVisualizerSubtitleFont(this.prefValue);

  final String prefValue;

  static const LyricVisualizerSubtitleFont defaultFont = inherit;

  static LyricVisualizerSubtitleFont fromPref(String? value) {
    for (final LyricVisualizerSubtitleFont v in values) {
      if (v.prefValue == value) return v;
    }
    return defaultFont;
  }
}

/// 字幕行的来源。
enum LyricVisualizerSubtitleRowKind { translation, romanization }

/// 一行副字幕。
typedef LyricVisualizerSubtitleRow = ({
  LyricVisualizerSubtitleRowKind kind,
  String text,
});

/// 双行时第二行相对第一行的字号 / 透明度 / 字重兜底 / 上间距（em，按第二行自己的字号），folia
/// `subtitleTrackStyle.ts`：共享字幕与自己排字幕的样式（莫奈 / 时计）同一套台阶。
const double kLyricVisualizerSecondarySubtitleSize = 0.88;
const double kLyricVisualizerSecondarySubtitleOpacity = 0.82;
const FontWeight kLyricVisualizerSecondarySubtitleWeight = FontWeight.w400;
const double kLyricVisualizerSecondarySubtitleGapEm = 0.25;

final RegExp _readable = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// 有字母或数字才算可读（folia `hasReadableText`：`//`、`●●●` 这类占位不显示）。
bool lyricVisualizerIsReadableSubtitle(String? text) =>
    text != null && _readable.hasMatch(text);

/// 字幕偏好。
@immutable
class LyricVisualizerSubtitleSettings {
  const LyricVisualizerSubtitleSettings({
    this.content = LyricVisualizerSubtitleContent.translation,
    this.hideTranslation = false,
    this.fontScale = 1,
    this.font = LyricVisualizerSubtitleFont.inherit,
  });

  static const LyricVisualizerSubtitleSettings defaults =
      LyricVisualizerSubtitleSettings();

  static const double minFontScale = 0.6;
  static const double maxFontScale = 2;

  final LyricVisualizerSubtitleContent content;

  /// folia `hideTranslationSubtitle`：整个副字幕（含共享字幕的下一句预览）都不画。
  final bool hideTranslation;

  /// 副字幕字号倍数（叠在歌词字号倍数上）。
  final double fontScale;
  final LyricVisualizerSubtitleFont font;

  /// 副字幕要不要画（隐藏或内容为「无」时不画）。
  bool get showsRows =>
      !hideTranslation && content != LyricVisualizerSubtitleContent.none;

  /// 生效的字号倍数（钳到合法范围）。
  double get effectiveFontScale => fontScale.clamp(minFontScale, maxFontScale);

  /// 一行歌词的副字幕行（folia `resolveLyricSubtitleTracks`）：按 [content] 取译文 / 罗马音 /
  /// 两者（罗马音在前）；不可读的、与原文或上一行重复的不要。
  List<LyricVisualizerSubtitleRow> rowsFor({
    required String lineText,
    required String? translation,
    required String? romanization,
  }) {
    if (!showsRows) return const <LyricVisualizerSubtitleRow>[];
    final List<(LyricVisualizerSubtitleRowKind, String?)> wanted =
        switch (content) {
          LyricVisualizerSubtitleContent.translation =>
            <(LyricVisualizerSubtitleRowKind, String?)>[
              (LyricVisualizerSubtitleRowKind.translation, translation),
            ],
          LyricVisualizerSubtitleContent.romanization =>
            <(LyricVisualizerSubtitleRowKind, String?)>[
              (LyricVisualizerSubtitleRowKind.romanization, romanization),
            ],
          LyricVisualizerSubtitleContent.both =>
            <(LyricVisualizerSubtitleRowKind, String?)>[
              (LyricVisualizerSubtitleRowKind.romanization, romanization),
              (LyricVisualizerSubtitleRowKind.translation, translation),
            ],
          LyricVisualizerSubtitleContent.none =>
            const <(LyricVisualizerSubtitleRowKind, String?)>[],
        };
    final String self = lineText.trim();
    final List<LyricVisualizerSubtitleRow> out = <LyricVisualizerSubtitleRow>[];
    for (final (LyricVisualizerSubtitleRowKind kind, String? raw) in wanted) {
      final String? text = raw?.trim();
      if (!lyricVisualizerIsReadableSubtitle(text)) continue;
      if (text == self) continue;
      if (out.any((LyricVisualizerSubtitleRow r) => r.text == text)) continue;
      out.add((kind: kind, text: text!));
    }
    return out;
  }

  /// 副字幕字体套到 [base] 上：跟随歌词时套主题字体 / 字重；单独选时只换字族（字重按 [base]）。
  TextStyle applyFont(
    TextStyle base,
    LyricVisualizerTheme? theme,
  ) => switch (font) {
    LyricVisualizerSubtitleFont.inherit =>
      theme == null || (theme.fontWeight == null && theme.fontFamily == null)
          ? base
          : base.copyWith(
              fontWeight: theme.fontWeight,
              fontFamily: theme.fontFamily,
            ),
    // 不覆盖字族 = app 默认字体。
    LyricVisualizerSubtitleFont.sans => base,
    LyricVisualizerSubtitleFont.serif => base.copyWith(fontFamily: 'serif'),
    LyricVisualizerSubtitleFont.mono => base.copyWith(fontFamily: 'monospace'),
  };

  LyricVisualizerSubtitleSettings copyWith({
    LyricVisualizerSubtitleContent? content,
    bool? hideTranslation,
    double? fontScale,
    LyricVisualizerSubtitleFont? font,
  }) => LyricVisualizerSubtitleSettings(
    content: content ?? this.content,
    hideTranslation: hideTranslation ?? this.hideTranslation,
    fontScale: fontScale ?? this.fontScale,
    font: font ?? this.font,
  );

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerSubtitleSettings &&
      other.content == content &&
      other.hideTranslation == hideTranslation &&
      other.fontScale == fontScale &&
      other.font == font;

  @override
  int get hashCode => Object.hash(content, hideTranslation, fontScale, font);
}
