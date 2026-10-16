/// 「高亮样式」设置页（用户 2026-10-15：「高亮条自定义做成配置，用户自己可自选样式，
/// 并且支持可视化调节」「全部高亮都要能选可以自定义高亮」）。
///
/// 顶部选「应用于」哪类高亮（收藏 / 查词 / 有声书当前句 / 搜索），每类一套独立配置；下面
/// 是实时预览（带振假名的样文，横排 / 竖排可切、可重播落笔动画）、带缩略图的样式选择，以及
/// 粗细 / 浓度 / 笔触抖动 / 盖住振假名 / 落笔动画五项调节。拖滑块只刷新预览，松手才写偏好
/// （写偏好会热替换正文样式表，跟手写会让正文每一帧都重排）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/reader/highlight_stroke_preview.dart';
import 'package:fushi/src/reader/highlight_stroke_style.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart'
    show FushiTypeScale;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 设置项图标（schema 行与本页共用）。
const IconData kHighlightStyleIcon = FushiIcons.outlineColor;

/// 预览里查词 / 有声书 / 搜索三类的示意色（真实颜色随阅读主题与各自的颜色设置，预览只表达
/// 形状与浓度）。收藏用五色圆点切换。
const Map<HighlightKind, Color> kHighlightKindPreviewColors =
    <HighlightKind, Color>{
      HighlightKind.lookup: Color(0xFF4F8EF7),
      HighlightKind.audio: Color(0xFFFF9F43),
      HighlightKind.search: Color(0xFFFFC800),
    };

/// 样式名（设置行副标题、样式块标题共用）。
String highlightStrokeStyleLabel(HighlightStrokeStyle style) => switch (style) {
  HighlightStrokeStyle.classic => t.reader_highlight_style_classic,
  HighlightStrokeStyle.marker => t.reader_highlight_style_marker,
  HighlightStrokeStyle.fluo => t.reader_highlight_style_fluo,
  HighlightStrokeStyle.rough => t.reader_highlight_style_rough,
  HighlightStrokeStyle.under => t.reader_highlight_style_under,
  HighlightStrokeStyle.crayon => t.reader_highlight_style_crayon,
  HighlightStrokeStyle.tape => t.reader_highlight_style_tape,
};

/// 高亮种类名。
String highlightKindLabel(HighlightKind kind) => switch (kind) {
  HighlightKind.favorite => t.reader_highlight_kind_favorite,
  HighlightKind.lookup => t.reader_highlight_kind_lookup,
  HighlightKind.audio => t.reader_highlight_kind_audio,
  HighlightKind.search => t.reader_highlight_kind_search,
};

/// 设置行副标题：哪几类改了样式（「收藏：斜切马克笔 · 有声书：手绘双笔」），全经典时「全部经典」。
/// 「种类：样式」的标点随语言走 i18n（中文全角冒号、其余半角），条目间用语言中立的 ` · `。
String highlightStyleSummary(ReaderFushiSource source) {
  final List<String> parts = <String>[
    for (final HighlightKind kind in HighlightKind.values)
      if (source.highlightStrokeConfig(kind).style.isStroke)
        t.reader_highlight_summary_entry(
          kind: highlightKindLabel(kind),
          style: highlightStrokeStyleLabel(
            source.highlightStrokeConfig(kind).style,
          ),
        ),
  ];
  return parts.isEmpty ? t.reader_highlight_all_classic : parts.join(' · ');
}

String _styleHint(HighlightStrokeStyle style) => switch (style) {
  HighlightStrokeStyle.classic => t.reader_highlight_style_classic_hint,
  HighlightStrokeStyle.marker => t.reader_highlight_style_marker_hint,
  HighlightStrokeStyle.fluo => t.reader_highlight_style_fluo_hint,
  HighlightStrokeStyle.rough => t.reader_highlight_style_rough_hint,
  HighlightStrokeStyle.under => t.reader_highlight_style_under_hint,
  HighlightStrokeStyle.crayon => t.reader_highlight_style_crayon_hint,
  HighlightStrokeStyle.tape => t.reader_highlight_style_tape_hint,
};

class HighlightStylePage extends StatefulWidget {
  const HighlightStylePage({
    super.key,
    required this.source,
    this.paper,
    this.ink,
    this.initiallyVertical = false,
    this.lineHeight = 1.9,
    this.initialKind = HighlightKind.audio,
  });

  final ReaderFushiSource source;

  /// 阅读纸色 / 正文色；null 时用 app 主题的表面色。
  final Color? paper;
  final Color? ink;
  final bool initiallyVertical;
  final double lineHeight;
  final HighlightKind initialKind;

  @override
  State<HighlightStylePage> createState() => _HighlightStylePageState();
}

class _HighlightStylePageState extends State<HighlightStylePage>
    with SingleTickerProviderStateMixin {
  late HighlightKind _kind = widget.initialKind;
  late HighlightStrokeConfig _config = widget.source.highlightStrokeConfig(
    _kind,
  );
  late bool _vertical = widget.initiallyVertical;
  String _favoriteColor = 'yellow';
  int _seedSalt = 0;

  /// 预览框当前的尺寸（LayoutBuilder 维护）：落笔总时长按它排出来的行数算。
  Size? _previewSize;

  /// 预览落笔进度（0–1）。时长不在这里定：每次重播按预览的实际行段由
  /// [HighlightStrokePreviewPainter.sweepDurationFor] 现算（FushiMotion token），
  /// 与正文的落笔节奏一致。
  late final AnimationController _stroke = AnimationController(
    vsync: this,
    value: 1,
  );

  static const double _previewFontSize = 20;
  static const double _previewPadding = 18;

  @override
  void dispose() {
    _stroke.dispose();
    super.dispose();
  }

  Color get _previewColor => _kind == HighlightKind.favorite
      ? kFavoriteHighlightColors[_favoriteColor]!
      : kHighlightKindPreviewColors[_kind]!;

  void _selectKind(HighlightKind kind) {
    setState(() {
      _kind = kind;
      _config = widget.source.highlightStrokeConfig(kind);
    });
  }

  /// 只改预览（拖滑块的每一帧）。
  void _preview(HighlightStrokeConfig next) => setState(() => _config = next);

  /// 改预览并写偏好。
  void _commit(HighlightStrokeConfig next, {bool replay = false}) {
    setState(() => _config = next);
    unawaited(widget.source.setHighlightStrokeConfig(_kind, next));
    if (replay) _replay();
  }

  void _replay() {
    // 墨水屏与系统「减弱动态效果」下不放落笔动画（与正文同一判据）。
    if (!fushiMotionEnabled(context)) {
      _stroke.value = 1;
      return;
    }
    final Size? size = _previewSize;
    if (!_config.style.isStroke || size == null) return;
    final Duration duration = HighlightStrokePreviewPainter.sweepDurationFor(
      sample: kHighlightPreviewSample,
      size: size,
      fontSize: _previewFontSize,
      lineHeight: widget.lineHeight,
      vertical: _vertical,
      padding: _previewPadding,
    );
    if (duration <= Duration.zero) {
      _stroke.value = 1;
      return;
    }
    _stroke.duration = duration;
    _stroke.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color paper = widget.paper ?? cs.surface;
    final Color ink = widget.ink ?? cs.onSurface;
    final bool eink = isEinkTheme(context);
    return AdaptiveSettingsScaffold(
      title: Text(t.reader_highlight_title),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('highlight_style_reset'),
          onPressed: () => _commit(_kind.defaults),
          child: Text(t.reader_highlight_reset),
        ),
      ],
      children: <Widget>[
        _buildKindSelector(context),
        const SizedBox(height: 12),
        _buildPreview(context, paper: paper, ink: ink),
        if (eink)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              t.reader_highlight_eink_notice,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 16),
        _buildStyleGrid(context, paper: paper, ink: ink),
        const SizedBox(height: 16),
        _buildAdjustments(context),
      ],
    );
  }

  Widget _buildKindSelector(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            t.reader_highlight_kind_label,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        SizedBox(
          width: double.infinity,
          // 分段选择一律走 adaptiveSegmentedButton（Material = M3E 胶囊分段、Apple = iOS 分段）。
          child: KeyedSubtree(
            key: const ValueKey<String>('highlight_style_kind'),
            child: adaptiveSegmentedButton<HighlightKind>(
              context: context,
              segments: <ButtonSegment<HighlightKind>>[
                for (final HighlightKind kind in HighlightKind.values)
                  ButtonSegment<HighlightKind>(
                    value: kind,
                    label: Text(highlightKindLabel(kind)),
                  ),
              ],
              selected: <HighlightKind>{_kind},
              onSelectionChanged: (Set<HighlightKind> v) =>
                  _selectKind(v.first),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(
    BuildContext context, {
    required Color paper,
    required Color ink,
  }) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AnimatedContainer(
          key: const ValueKey<String>('highlight_style_preview'),
          duration: duration,
          curve: FushiMotion.standard,
          height: _vertical ? 300 : 210,
          decoration: BoxDecoration(
            color: paper,
            borderRadius: FushiM3eShape.containerLargeRadius,
            border: Border.all(color: ink.withValues(alpha: 0.1)),
          ),
          clipBehavior: Clip.antiAlias,
          child: ExcludeFocus(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                _previewSize = constraints.biggest;
                return AnimatedBuilder(
                  animation: _stroke,
                  builder: (BuildContext context, _) => CustomPaint(
                    painter: HighlightStrokePreviewPainter(
                      sample: kHighlightPreviewSample,
                      config: _config,
                      color: _previewColor,
                      paper: paper,
                      ink: ink,
                      vertical: _vertical,
                      fontSize: _previewFontSize,
                      lineHeight: widget.lineHeight,
                      progress: _stroke.value,
                      padding: _previewPadding,
                      seedSalt: _seedSalt,
                      classicUnderline: _kind == HighlightKind.favorite,
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            KeyedSubtree(
              key: const ValueKey<String>('highlight_style_orientation'),
              child: adaptiveSegmentedButton<bool>(
                context: context,
                segments: <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                    value: false,
                    label: Text(t.reader_highlight_horizontal),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text(t.reader_highlight_vertical),
                  ),
                ],
                selected: <bool>{_vertical},
                onSelectionChanged: (Set<bool> v) =>
                    setState(() => _vertical = v.first),
              ),
            ),
            if (_kind == HighlightKind.favorite)
              FushiTooltip(
                message: t.reader_highlight_preview_color_hint,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final MapEntry<String, Color> e
                        in kFavoriteHighlightColors.entries)
                      _ColorDot(
                        key: ValueKey<String>('highlight_style_color_${e.key}'),
                        color: e.value,
                        selected: e.key == _favoriteColor,
                        semanticLabel: t.reader_highlight_preview_color,
                        onTap: () => setState(() => _favoriteColor = e.key),
                      ),
                  ],
                ),
              ),
            FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('highlight_style_replay'),
              onPressed: _config.style.isStroke
                  ? () {
                      setState(() => _seedSalt++);
                      _replay();
                    }
                  : null,
              icon: const Icon(FushiIcons.replay),
              label: Text(t.reader_highlight_replay),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStyleGrid(
    BuildContext context, {
    required Color paper,
    required Color ink,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 620
            ? 3
            : (constraints.maxWidth >= 300 ? 2 : 1);
        const double gap = 10;
        final double width =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        // 新页面动效（CLAUDE.md 2026-10-04）：样式块错峰进场 + 按压缩放，时长都走
        // FushiMotion，墨水屏 / 减弱动态效果下由组件自己归零。
        return FushiEntranceScope(
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final (int index, HighlightStrokeStyle style)
                  in HighlightStrokeStyle.values.indexed)
                SizedBox(
                  width: width,
                  child: FushiStaggeredEntrance(
                    index: index,
                    child: FushiPressScale(
                      child: _StyleTile(
                        key: ValueKey<String>(
                          'highlight_style_tile_${style.wireName}',
                        ),
                        style: style,
                        selected: style == _config.style,
                        config: _config.copyWith(style: style),
                        color: _previewColor,
                        paper: paper,
                        ink: ink,
                        classicUnderline: _kind == HighlightKind.favorite,
                        onTap: () => _commit(
                          _config.copyWith(style: style),
                          replay: _config.animate,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAdjustments(BuildContext context) {
    final HighlightStrokeStyle style = _config.style;
    String pct(double v) => '${(v * 100).round()}%';
    return AdaptiveSettingsSection(
      children: <Widget>[
        if (style.isStroke)
          AdaptiveSettingsSliderRow(
            key: const ValueKey<String>('highlight_style_thickness'),
            title: t.reader_highlight_thickness,
            readout: '${_config.thickness.toStringAsFixed(2)}×',
            value: _config.thickness,
            min: kHighlightStrokeThicknessMin,
            max: kHighlightStrokeThicknessMax,
            divisions: 20,
            onChanged: (double v) => _preview(_config.copyWith(thickness: v)),
            onChangeEnd: (double v) => _commit(_config.copyWith(thickness: v)),
          ),
        if (style.isStroke)
          AdaptiveSettingsSliderRow(
            key: const ValueKey<String>('highlight_style_opacity'),
            title: t.reader_highlight_opacity,
            readout: pct(_config.opacity),
            value: _config.opacity,
            min: kHighlightStrokeOpacityMin,
            max: kHighlightStrokeOpacityMax,
            divisions: 13,
            onChanged: (double v) => _preview(_config.copyWith(opacity: v)),
            onChangeEnd: (double v) => _commit(_config.copyWith(opacity: v)),
          ),
        if (style.isStroke)
          AdaptiveSettingsSliderRow(
            key: const ValueKey<String>('highlight_style_roughness'),
            title: t.reader_highlight_roughness,
            readout: pct(_config.roughness),
            value: _config.roughness,
            min: kHighlightStrokeRoughnessMin,
            max: kHighlightStrokeRoughnessMax,
            divisions: 10,
            onChanged: (double v) => _preview(_config.copyWith(roughness: v)),
            onChangeEnd: (double v) => _commit(_config.copyWith(roughness: v)),
          ),
        if (style.supportsCoverRuby)
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('highlight_style_cover_ruby'),
            title: t.reader_highlight_cover_ruby,
            subtitle: t.reader_highlight_cover_ruby_hint,
            value: _config.coverRuby,
            onChanged: (bool v) => _commit(_config.copyWith(coverRuby: v)),
          ),
        if (style.isStroke)
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('highlight_style_animate'),
            title: t.reader_highlight_animate,
            subtitle: switch (_kind) {
              HighlightKind.favorite => t.reader_highlight_animate_hint,
              HighlightKind.lookup => t.reader_highlight_animate_lookup_hint,
              HighlightKind.audio => t.reader_highlight_animate_audio_hint,
              HighlightKind.search => t.reader_highlight_animate_search_hint,
            },
            value: _config.animate,
            onChanged: (bool v) =>
                _commit(_config.copyWith(animate: v), replay: v),
          ),
      ],
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.semanticLabel,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AnimatedContainer(
            duration: fushiMotionDuration(context, FushiMotion.short),
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? cs.onSurface : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一个样式选择块：缩略预览 + 名称 + 一句说明。选中时容器变色、圆角收紧（M3E 形状变化）。
class _StyleTile extends StatelessWidget {
  const _StyleTile({
    super.key,
    required this.style,
    required this.selected,
    required this.config,
    required this.color,
    required this.paper,
    required this.ink,
    required this.classicUnderline,
    required this.onTap,
  });

  final HighlightStrokeStyle style;
  final bool selected;
  final HighlightStrokeConfig config;
  final Color color;
  final Color paper;
  final Color ink;
  final bool classicUnderline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    // M3E 形状变化：选中时圆角从卡片档收到列表激活档。
    final BorderRadius radius = BorderRadius.all(
      Radius.circular(selected ? FushiM3eShape.listActive : FushiM3eShape.card),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? cs.secondaryContainer : cs.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: duration,
            curve: FushiMotion.standard,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: selected ? cs.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  height: 52,
                  decoration: BoxDecoration(
                    color: paper,
                    borderRadius: FushiM3eShape.smallRadius,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: CustomPaint(
                    painter: HighlightStrokePreviewPainter(
                      sample: kHighlightTileSample,
                      config: config,
                      color: color,
                      paper: paper,
                      ink: ink,
                      vertical: false,
                      // 缩略图样文与卡片正文同字阶（随主题字号缩放），不写死字号。
                      fontSize:
                          context.fushiType.bodyLarge.fontSize ??
                          FushiTypeScale.bodyLarge.size,
                      lineHeight: 1.6,
                      padding: 12,
                      classicUnderline: classicUnderline,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        highlightStrokeStyleLabel(style),
                        style: text.titleSmall?.copyWith(
                          color: selected
                              ? cs.onSecondaryContainer
                              : cs.onSurface,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(FushiIcons.success, size: 18, color: cs.primary),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _styleHint(style),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: selected
                        ? cs.onSecondaryContainer.withValues(alpha: 0.8)
                        : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
