import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/models/app_font_loader.dart';
import 'package:fushi/src/models/app_ui_font_chain.dart';
import 'package:fushi/src/models/cjk_font_families.dart' show CjkFontStyle;
import 'package:fushi/src/models/content_font_chain.dart';
import 'package:fushi/src/reader/reader_settings.dart' show FontTarget;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiSelectableChip;
import 'package:fushi/i18n/strings.g.dart';

/// 字体库里某个用途下已启用的一个条目，族名已解析。
@immutable
class FontPreviewCandidate {
  const FontPreviewCandidate({required this.family, required this.path});

  /// 引擎里可用的族名；null = 解析失败或还在解析。
  final String? family;

  /// 导入文件路径；null = 系统字体。
  final String? path;
}

/// 用途 → 这个用途**真正会用到**的族名，与各消费端同一语义：
///
/// - 界面 / 正文 / 词典：整条有序链都参与（缺字按序回退）。
/// - 视频字幕：只用第一个可用条目（`AppFontLoader.resolveAndLoad`）。
/// - 游戏浮窗：只用第一个 native DirectWrite 吃得下的条目
///   （`AppFontLoader.resolveForNativeOverlay`，WOFF/WOFF2 跳过）。
///
/// 预览照这个结果渲染，所以「为什么我排第二的字体没生效」在预览里是看得见的。
List<String> effectiveFontTargetFamilies(
  FontTarget target,
  List<FontPreviewCandidate> enabledInOrder,
) {
  final List<String> families = <String>[];
  for (final FontPreviewCandidate candidate in enabledInOrder) {
    final String? family = candidate.family;
    if (family == null || family.isEmpty) continue;
    if (target == FontTarget.gameLookup &&
        !AppFontLoader.nativeOverlayCanUse(candidate.path)) {
      continue;
    }
    if (!families.contains(family)) families.add(family);
    if (fontTargetUsesFirstFontOnly(target)) break;
  }
  return families;
}

/// 这个用途是否只取链上第一款字体（其余条目对它无效）。
bool fontTargetUsesFirstFontOnly(FontTarget target) => switch (target) {
  FontTarget.videoSubtitle || FontTarget.gameLookup => true,
  FontTarget.appUi || FontTarget.body || FontTarget.dictionary => false,
};

/// 各用途的实时样张：照着真实表面的形态画一块缩样，用该用途**实际生效**的字体链
/// 渲染日文。用途与真实消费端一一对应（[FontTarget] 穷尽 switch，新增用途编译报错）。
///
/// 全部是 Flutter 绘制，不起 WebView：字体库页要随勾选、排序即时刷新，WebView 的
/// 字体注入（词典要把整个字体文件内联成 data: URL）重得多，而字形本身两边一致。
class FontTargetPreview extends StatelessWidget {
  const FontTargetPreview({
    required this.target,
    required this.families,
    this.subtitleStyle = VideoSubtitleStyle.defaults,
    this.sampleText,
    super.key,
  });

  final FontTarget target;

  /// [effectiveFontTargetFamilies] 的结果；空 = 该用途没配字体，走系统默认。
  final List<String> families;

  /// 视频字幕样张用的外观（字色 / 字重 / 阴影 / 底板），默认值同播放器。
  final VideoSubtitleStyle subtitleStyle;

  /// 覆盖默认日文样张（系统字体浏览页允许用户输入自己的样字）。
  final String? sampleText;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String hint = families.isEmpty
        ? t.font_preview_default_font
        : target == FontTarget.gameLookup
        ? '${t.font_preview_first_only_hint} ${t.font_preview_game_overlay_hint}'
        : fontTargetUsesFirstFontOnly(target)
        ? t.font_preview_first_only_hint
        : t.font_preview_chain_hint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ClipRRect(
          borderRadius: tokens.radii.cardRadius,
          child: KeyedSubtree(
            key: ValueKey<String>('font-target-preview-${target.name}'),
            child: switch (target) {
              FontTarget.appUi => _AppUiPreview(families: families),
              FontTarget.body => _BodyPreview(
                families: families,
                sampleText: sampleText,
              ),
              FontTarget.dictionary => _DictionaryPreview(families: families),
              FontTarget.videoSubtitle => _SubtitlePreview(
                families: families,
                style: subtitleStyle,
                sampleText: sampleText,
              ),
              FontTarget.gameLookup => _GameOverlayPreview(
                families: families,
                sampleText: sampleText,
              ),
            },
          ),
        ),
        SizedBox(height: tokens.spacing.gap),
        Text(
          families.isEmpty ? hint : '${families.join(' → ')}\n$hint',
          style: tokens.type.metadata.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 内容（日文）文字的样式：主字体 = 链首，回退 = 链余下 + 平台日文字体。
TextStyle _contentStyle(
  TextStyle base,
  List<String> families, {
  CjkFontStyle cjkStyle = CjkFontStyle.sansSerif,
}) {
  final List<String> chain = contentFontFamilies(
    languageTag: 'ja',
    platform: defaultTargetPlatform,
    style: cjkStyle,
    customFamilies: families,
  );
  return base.copyWith(
    fontFamily: families.isEmpty ? null : chain.first,
    fontFamilyFallback: families.isEmpty ? null : chain.skip(1).toList(),
  );
}

class _AppUiPreview extends StatelessWidget {
  const _AppUiPreview({required this.families});

  final List<String> families;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<String> chain = families.isEmpty
        ? const <String>[]
        : appUiFontChain(
            customFamilies: families,
            locale: Localizations.localeOf(context),
            platform: defaultTargetPlatform,
          );
    TextStyle ui(TextStyle? style) => (style ?? const TextStyle()).copyWith(
      fontFamily: chain.isEmpty ? null : chain.first,
      fontFamilyFallback: chain.isEmpty ? null : chain.skip(1).toList(),
    );
    return ColoredBox(
      color: tokens.surfaces.group,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Row(
          children: <Widget>[
            Container(
              width: 44,
              height: 60,
              decoration: BoxDecoration(
                // 样张里的假封面：中性填充（不再是 primaryContainer 彩块）。
                color: fushiNeutralBlockColor(context),
                borderRadius: tokens.radii.controlRadius,
              ),
              alignment: Alignment.center,
              child: Text(
                '猫',
                style: ui(
                  theme.textTheme.titleLarge,
                ).copyWith(color: fushiNeutralSecondaryForeground(context)),
              ),
            ),
            SizedBox(width: tokens.spacing.card),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t.font_preview_ui_sample_title,
                    style: ui(theme.textTheme.titleMedium),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '吾輩は猫である',
                    style: ui(theme.textTheme.bodyMedium),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    t.font_preview_ui_sample_subtitle,
                    style: ui(
                      theme.textTheme.bodySmall,
                    ).copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.card,
                vertical: tokens.spacing.gap,
              ),
              decoration: BoxDecoration(
                color: scheme.primary,
                // 样张按钮跟随设计系统的按钮形状：Apple 是胶囊。
                borderRadius: isGlassDesign(context)
                    ? const BorderRadius.all(Radius.circular(999))
                    : tokens.radii.chipRadius,
              ),
              child: Text(
                t.font_preview_ui_sample_action,
                style: ui(
                  theme.textTheme.labelLarge,
                ).copyWith(color: scheme.onPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一段带振假名的日文：`(基字, 注音)`，注音为 null 即普通文字。
const List<(String, String?)> kJaFontRubySample = <(String, String?)>[
  ('吾輩', 'わがはい'),
  ('は猫である。名前はまだ無い。どこで', null),
  ('生', 'うま'),
  ('れたかとんと', null),
  ('見当', 'けんとう'),
  ('がつかぬ。', null),
];

class _BodyPreview extends StatefulWidget {
  const _BodyPreview({required this.families, this.sampleText});

  final List<String> families;
  final String? sampleText;

  @override
  State<_BodyPreview> createState() => _BodyPreviewState();
}

class _BodyPreviewState extends State<_BodyPreview> {
  bool _vertical = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle body = _contentStyle(
      (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        height: 1.9,
        fontWeight: FontWeight.w400,
      ),
      widget.families,
      cjkStyle: CjkFontStyle.serif,
    );
    final TextStyle ruby = body.copyWith(
      fontSize: (body.fontSize ?? 16) * 0.5,
      height: 1,
    );
    final List<(String, String?)> segments = widget.sampleText == null
        ? kJaFontRubySample
        : <(String, String?)>[(widget.sampleText!, null)];
    return ColoredBox(
      color: tokens.surfaces.card,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              spacing: tokens.spacing.gap,
              children: <Widget>[
                FushiSelectableChip(
                  label: t.font_preview_horizontal,
                  selected: !_vertical,
                  onSelected: (_) => setState(() => _vertical = false),
                ),
                FushiSelectableChip(
                  label: t.font_preview_vertical,
                  selected: _vertical,
                  onSelected: (_) => setState(() => _vertical = true),
                ),
              ],
            ),
            SizedBox(height: tokens.spacing.gap),
            if (_vertical)
              SizedBox(
                height: 176,
                child: FontVerticalSpecimen(
                  segments: segments,
                  style: body,
                  rubyStyle: ruby,
                ),
              )
            else
              FontHorizontalRubySpecimen(
                segments: segments,
                style: body,
                rubyStyle: ruby,
              ),
          ],
        ),
      ),
    );
  }
}

/// 横排带振假名的样张：基字与正文同样式、按基线对齐，注音浮在基字上方的行距
/// 留白里（不撑高行、不挤换行）。字体库样张卡与详情页、正文用途预览共用。
class FontHorizontalRubySpecimen extends StatelessWidget {
  const FontHorizontalRubySpecimen({
    required this.segments,
    required this.style,
    required this.rubyStyle,
    this.maxLines,
    super.key,
  });

  final List<(String, String?)> segments;
  final TextStyle style;
  final TextStyle rubyStyle;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final TextStyle body = style;
    final TextStyle ruby = rubyStyle;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          for (final (String base, String? rt) in segments)
            if (rt == null)
              TextSpan(text: base, style: body)
            else
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Text(base, style: body),
                    Positioned(
                      left: -8,
                      right: -8,
                      top:
                          (body.fontSize ?? 16) *
                              ((body.height ?? 1) - 1) /
                              2 -
                          (ruby.fontSize ?? 8),
                      // 不参与基线：否则 Stack 取最高基线 = 注音的。
                      child: IgnoreBaseline(
                        child: Text(
                          rt,
                          style: ruby,
                          textAlign: TextAlign.center,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

/// 竖排近似：从右往左一列一列排，每字一格，振假名贴在基字右侧。Flutter 没有原生
/// 竖排，这里只为看字形在竖排版面里的观感，不追求 WebView 的标点换形。
class FontVerticalSpecimen extends StatelessWidget {
  const FontVerticalSpecimen({
    required this.segments,
    required this.style,
    required this.rubyStyle,
    super.key,
  });

  final List<(String, String?)> segments;
  final TextStyle style;
  final TextStyle rubyStyle;

  @override
  Widget build(BuildContext context) {
    final double glyph = (style.fontSize ?? 16) * 1.15;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int perColumn = (constraints.maxHeight / glyph).floor().clamp(
          1,
          999,
        );
        final List<(String, String?)> cells = <(String, String?)>[
          for (final (String base, String? rt) in segments)
            // 逐字素切格；注音挂在该段第一格，其余格留空位对齐。
            for (final (int i, String char) in base.characters.indexed)
              (char, i == 0 ? rt : (rt == null ? null : '')),
        ];
        final List<List<(String, String?)>> columns = <List<(String, String?)>>[
          for (int i = 0; i < cells.length; i += perColumn)
            cells.sublist(i, (i + perColumn).clamp(0, cells.length)),
        ];
        return ClipRect(
          child: Row(
            textDirection: TextDirection.rtl,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final List<(String, String?)> column in columns)
                Padding(
                  padding: EdgeInsets.only(left: glyph * 0.35),
                  child: Column(
                    children: <Widget>[
                      for (final (String char, String? rt) in column)
                        SizedBox(
                          height: glyph,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              // 竖排句读挪到字格右上（横排字形在左下）。
                              if (char == '。' || char == '、')
                                Transform.translate(
                                  offset: Offset(glyph * 0.4, -glyph * 0.4),
                                  child: Text(
                                    char,
                                    style: style.copyWith(height: 1),
                                  ),
                                )
                              else
                                Text(char, style: style.copyWith(height: 1)),
                              SizedBox(
                                width: rubyStyle.fontSize ?? 8,
                                child: rt == null || rt.isEmpty
                                    ? null
                                    : Text(
                                        rt.characters.join('\n'),
                                        style: rubyStyle,
                                        softWrap: false,
                                        overflow: TextOverflow.visible,
                                      ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _DictionaryPreview extends StatelessWidget {
  const _DictionaryPreview({required this.families});

  final List<String> families;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    TextStyle content(TextStyle? style) =>
        _contentStyle(style ?? const TextStyle(), families);
    return ColoredBox(
      color: tokens.surfaces.card,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'けんとう',
              style: content(
                theme.textTheme.bodySmall,
              ).copyWith(color: scheme.onSurfaceVariant),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Text('見当', style: content(theme.textTheme.headlineSmall)),
                SizedBox(width: tokens.spacing.gap),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.gap,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    // 词性小徽标：中性底（与 FushiTag 等共享徽标同口径）。
                    color: fushiNeutralTagColors(context).background,
                    borderRadius: tokens.radii.chipRadius,
                  ),
                  child: Text(
                    '名詞',
                    style: content(
                      theme.textTheme.labelSmall,
                    ).copyWith(color: fushiNeutralTagColors(context).foreground),
                  ),
                ),
              ],
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(
              '① 大体の方向や位置。「駅の見当がつかない」\n'
              '② おおよその予想。見込み。「見当違い」',
              style: content(
                theme.textTheme.bodyMedium,
              ).copyWith(color: scheme.onSurface, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

/// 视频字幕样张：仿浏览器扩展「字体、排版与底板」的预览舞台——21:9 的暗色渐变
/// 画面，底部一句日文字幕，字色 / 字重 / 柔和投影 / 底板照播放器当前外观。
class _SubtitlePreview extends StatelessWidget {
  const _SubtitlePreview({
    required this.families,
    required this.style,
    this.sampleText,
  });

  final List<String> families;
  final VideoSubtitleStyle style;
  final String? sampleText;

  // 画面底色是「一帧视频」的示意，不跟随主题：字幕本就叠在任意画面上，
  // 暗色舞台才能如实呈现白字 + 投影的观感（与扩展预览同一组取值）。
  static const LinearGradient _stageGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF35506A), Color(0xFF1A2430), Color(0xFF0D1218)],
    stops: <double>[0, 0.6, 1],
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color textColor = style.textColor ?? Colors.white;
    final Color shadowColor = style.shadowColor ?? Colors.black;
    final Color? boxColor = style.backgroundOpacity > 0
        ? (style.backgroundColor ?? kDefaultSubtitleBackgroundColor).withValues(
            alpha: style.backgroundOpacity,
          )
        : null;
    return AspectRatio(
      aspectRatio: 21 / 9,
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: _stageGradient),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 播放器字号以 1080p 画面高为基准，按舞台高度等比缩放。
            final double scale = constraints.maxHeight / 1080 * 2.2;
            final double fontSize = (style.fontSize * scale).clamp(14, 40);
            final TextStyle text = _contentStyle(
              TextStyle(
                fontSize: fontSize,
                color: textColor,
                fontWeight: FontWeight.values.firstWhere(
                  (FontWeight w) => w.value == style.resolveFontWeight(1),
                  orElse: () => FontWeight.w400,
                ),
                height: 1.35,
                shadows: buildSubtitleSoftShadow(
                  shadowColor,
                  style.resolveShadowThickness(1),
                ),
              ),
              families,
            );
            return Align(
              alignment: const Alignment(0, 0.82),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: boxColor == null
                    ? null
                    : BoxDecoration(
                        color: boxColor,
                        borderRadius: tokens.radii.controlRadius,
                      ),
                child: Text(
                  sampleText ?? 'こんなふうに字幕が表示されます。',
                  style: text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 游戏文本浮窗样张：半透明暗色浮窗叠在一帧「游戏画面」上。
class _GameOverlayPreview extends StatelessWidget {
  const _GameOverlayPreview({required this.families, this.sampleText});

  final List<String> families;
  final String? sampleText;

  static const LinearGradient _sceneGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[Color(0xFF8DB4D9), Color(0xFFE8C6B0), Color(0xFF4A3A48)],
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle line = _contentStyle(
      (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
        color: Colors.white,
        height: 1.5,
      ),
      families,
    );
    return AspectRatio(
      aspectRatio: 16 / 7,
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: _sceneGradient),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(10),
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.62),
              borderRadius: tokens.radii.cardRadius,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '【ミカ】',
                  style: line.copyWith(
                    fontSize: (line.fontSize ?? 16) * 0.8,
                    color: Colors.white70,
                  ),
                ),
                Text(
                  sampleText ?? '「……ねえ、ここで待っていてくれる？すぐ戻るから。」',
                  style: line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
