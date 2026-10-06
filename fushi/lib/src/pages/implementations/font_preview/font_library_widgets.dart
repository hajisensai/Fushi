import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_file_metadata.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_specimen.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_target_preview.dart';
import 'package:fushi/src/reader/reader_settings.dart'
    show FontTarget, isFontTargetAvailableOnPlatform;
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

// =============================================================================
// 字体库（设置 › 外观与交互 › 排版 › 字体库）的样张卡、详情面板与样例工具条。
//
// 页面状态（目录行、保存、导入下载）仍在 custom_fonts_page.dart；这里只有纯展示
// 组件，经 [FontLibraryEntryView] 拿到一行字体的全部可视信息，经回调把用户意图
// 交回页面。M3E（饱和 container 色块、形状、弹簧）与 Apple（系统色淡染、
// 发丝线）两套视觉都在这一层分流。
// =============================================================================

/// 字体用途的显示名。穷尽 switch：新增 [FontTarget] 时这里编译报错，逼着补文案，
/// 而不是让新用途悄悄顶着枚举名出现在 UI 上。页面标题、详情页用途按钮共用。
String fontTargetLabel(FontTarget target) => switch (target) {
  FontTarget.appUi => t.font_target_app_ui,
  FontTarget.body => t.font_target_body,
  FontTarget.dictionary => t.font_target_dictionary,
  FontTarget.videoSubtitle => t.font_target_video_subtitle,
  FontTarget.gameLookup => t.font_target_game_lookup,
};

/// 样张卡上用途徽标的短名。
String fontTargetShortLabel(FontTarget target) => switch (target) {
  FontTarget.appUi => t.font_target_app_ui_short,
  FontTarget.body => t.font_target_body_short,
  FontTarget.dictionary => t.font_target_dictionary_short,
  FontTarget.videoSubtitle => t.font_target_video_subtitle_short,
  FontTarget.gameLookup => t.font_target_game_lookup_short,
};

/// 用途图标（徽标与详情页按钮共用）。
IconData fontTargetIcon(FontTarget target) => switch (target) {
  FontTarget.appUi => FushiIcons.widgets,
  FontTarget.body => FushiIcons.books,
  FontTarget.dictionary => FushiIcons.dictionary,
  FontTarget.videoSubtitle => FushiIcons.subtitles,
  FontTarget.gameLookup => FushiIcons.games,
};

/// 本平台真有消费端的用途（gameLookup 只有 Windows 的 native 分层窗消费）。
/// 只影响**显示**：回写仍按 `FontTarget.values` 全量，跨平台同步来的勾选不丢。
List<FontTarget> get visibleFontTargets => <FontTarget>[
  for (final FontTarget target in FontTarget.values)
    if (isFontTargetAvailableOnPlatform(target)) target,
];

/// 卡片布局：多列网格 / 单列列表。
enum FontLibraryLayout { grid, list }

/// 一行字体在字体库里的全部可视信息（页面从目录行 + 解析状态 + 元数据拼出）。
@immutable
class FontLibraryEntryView {
  const FontLibraryEntryView({
    required this.identity,
    required this.name,
    required this.isFile,
    required this.family,
    required this.state,
    required this.targets,
    this.path,
    this.metadata,
    this.missingOnSystem = false,
    this.unsupportedTargets = const <FontTarget, String>{},
  });

  /// 目录行身份（`name\0path`），页面据此找回行。
  final String identity;
  final String name;
  final bool isFile;
  final String? path;

  /// 引擎里可用的族名；只在 [state] 为 ready 时有意义。
  final String? family;
  final FontSpecimenState state;
  final Set<FontTarget> targets;
  final FontFileMetadata? metadata;

  /// 系统字体条目在本机系统字体清单里找不到。
  final bool missingOnSystem;

  /// 这个字体**格式上**用不了的用途 → 原因（WOFF/WOFF2 遇上游戏浮窗）。
  final Map<FontTarget, String> unsupportedTargets;

  String get sourceLabel => isFile ? t.font_source_file : t.font_source_system;

  /// 「字重 / 字面」短描述；读不出元数据时为 null。
  String? get weightsLabel {
    final FontFileMetadata? meta = metadata;
    if (meta == null) return null;
    final (int, int)? range = meta.variableWeightRange;
    if (range != null) {
      return t.font_library_weights_variable(min: range.$1, max: range.$2);
    }
    if (meta.faceCount > 1) {
      return t.font_library_faces_count(n: meta.faceCount);
    }
    return t.font_library_weights_count(n: meta.weightCount);
  }

  /// 卡片副标题：来源 · 格式 · 字重 · 大小。
  String get metaLine => <String>[
    sourceLabel,
    if (metadata != null) metadata!.format,
    if (weightsLabel != null) weightsLabel!,
    if (metadata?.sizeBytes != null) FushiByteFormat.bytes(metadata!.sizeBytes),
  ].join(' · ');
}

/// 样张文字：用户自定义（非空）优先，否则按所选文种取默认句。
String fontLibrarySampleText(FontSampleScript script, String custom) {
  final String trimmed = custom.trim();
  return trimmed.isEmpty ? fontSampleSentence(script) : trimmed;
}

TextStyle _specimenStyle(
  BuildContext context, {
  required String? family,
  required double fontSize,
  double height = 1.35,
  FontWeight? weight,
}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return TextStyle(
    fontFamily: family,
    fontSize: fontSize,
    height: height,
    fontWeight: weight,
    color: isGlassDesign(context)
        ? appleColorsOf(context).label
        : scheme.onSurface,
  );
}

/// 一行字体的样张文字（加载中 = 骨架条，无法加载 = 错误说明）。
class FontSpecimenText extends StatelessWidget {
  const FontSpecimenText({
    required this.entry,
    required this.text,
    required this.fontSize,
    this.maxLines = 2,
    super.key,
  });

  final FontLibraryEntryView entry;
  final String text;
  final double fontSize;
  final int maxLines;

  /// 样张行高倍数（与 [_specimenStyle] 的默认 height 同值）。
  static const double _lineHeight = 1.35;

  /// 样张区固定高度 = [maxLines] 行 × 行高（随系统字号缩放）。
  ///
  /// 切换样例文种（日文 / 中文 / 西文）或自定义样字时，句子在一款字体里可能
  /// 折 1 行、在另一款里折 2 行；不预留高度的话，列表卡片随之忽高忽低，整列
  /// 一起上下跳。高度只由字号与行数决定，与字体、文字内容、加载状态都无关。
  static double reservedHeight(
    BuildContext context, {
    required double fontSize,
    required int maxLines,
  }) =>
      MediaQuery.textScalerOf(context).scale(fontSize) * _lineHeight * maxLines;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: reservedHeight(context, fontSize: fontSize, maxLines: maxLines),
      child: ClipRect(
        child: AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          // 新旧样张叠在左上角交叉淡化，不按两者中较大的尺寸重排。
          layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
            alignment: AlignmentDirectional.topStart,
            children: <Widget>[...previous, if (current != null) current],
          ),
          child: KeyedSubtree(
            key: ValueKey<Object>(
              entry.state == FontSpecimenState.ready
                  ? 'ready|${entry.family}|$text'
                  : entry.state,
            ),
            child: _buildState(context),
          ),
        ),
      ),
    );
  }

  Widget _buildState(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    switch (entry.state) {
      case FontSpecimenState.loading:
        return FushiSkeletonShimmer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiSkeleton.line(widthFactor: 0.9, height: fontSize * 0.7),
              if (maxLines > 1) ...<Widget>[
                const SizedBox(height: 8),
                FushiSkeleton.line(widthFactor: 0.55, height: fontSize * 0.7),
              ],
            ],
          ),
        );
      case FontSpecimenState.unavailable:
        return Row(
          children: <Widget>[
            FushiIcon(FushiIcons.error, size: 18, color: scheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                t.font_preview_font_unavailable,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: scheme.error),
              ),
            ),
          ],
        );
      case FontSpecimenState.ready:
        // 强制 strut：缺字形的字回退到别的字体时，回退字体的 ascent / descent
        // 比例与本字体不同，行盒会被撑高；钉死行高后每行恒为 fontSize × 1.35，
        // 换文种 / 换字体都不改变行距与基线位置。
        return Text(
          text,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          strutStyle: StrutStyle(
            fontFamily: entry.family,
            fontSize: fontSize,
            height: _lineHeight,
            forceStrutHeight: true,
          ),
          style: _specimenStyle(
            context,
            family: entry.family,
            fontSize: fontSize,
            height: _lineHeight,
          ),
        );
    }
  }
}

/// 用途徽标：每个已启用的用途一枚小胶囊（M3E secondaryContainer 色块 / Apple
/// 强调色淡染）；一个都没有时显示一枚描边的「未使用」。
class FontUsageBadges extends StatelessWidget {
  const FontUsageBadges({required this.targets, super.key});

  final Set<FontTarget> targets;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool apple = isGlassDesign(context);
    final List<FontTarget> enabled = <FontTarget>[
      for (final FontTarget target in visibleFontTargets)
        if (targets.contains(target)) target,
    ];
    final TextStyle? label = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.w600,
    );
    Widget pill({
      required String text,
      IconData? icon,
      required Color background,
      required Color foreground,
      Color? border,
    }) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          color: background,
          shape: StadiumBorder(
            side: border == null ? BorderSide.none : BorderSide(color: border),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                FushiIcon(icon, size: 13, color: foreground),
                const SizedBox(width: 4),
              ],
              Text(text, style: label?.copyWith(color: foreground)),
            ],
          ),
        ),
      );
    }

    if (enabled.isEmpty) {
      return pill(
        text: t.font_library_usage_none,
        background: Colors.transparent,
        foreground: apple
            ? appleColorsOf(context).secondaryLabel
            : scheme.onSurfaceVariant,
        border: apple
            ? appleColorsOf(context).separator
            : scheme.outlineVariant,
      );
    }
    final Color background = apple
        ? appleColorsOf(context).accent.withValues(alpha: 0.15)
        : scheme.secondaryContainer;
    final Color foreground = apple
        ? appleColorsOf(context).accent
        : scheme.onSecondaryContainer;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: <Widget>[
        for (final FontTarget target in enabled)
          pill(
            text: fontTargetShortLabel(target),
            icon: fontTargetIcon(target),
            background: background,
            foreground: foreground,
          ),
      ],
    );
  }
}

/// 样张卡：用这款字体渲染一段样例文字，下方是名字、来源 / 字重 / 大小与用途徽标。
///
/// - 点按（Enter / 手柄 A）→ [onOpen] 打开详情；
/// - 右键 / 长按 / 尾部「更多」钮 → [onContextMenu]（菜单定位在指针处，键盘打开时
///   定位在卡片中心）。[allowLongPressMenu] 为 false 时长按留给外层的拖拽重排。
class FontSpecimenCard extends StatefulWidget {
  const FontSpecimenCard({
    required this.entry,
    required this.sampleText,
    required this.layout,
    required this.onOpen,
    required this.onContextMenu,
    this.selected = false,
    this.allowLongPressMenu = true,
    this.showDragHandle = false,
    super.key,
  });

  final FontLibraryEntryView entry;
  final String sampleText;
  final FontLibraryLayout layout;
  final VoidCallback onOpen;
  final void Function(Offset globalPosition) onContextMenu;
  final bool selected;
  final bool allowLongPressMenu;

  /// 列表重排模式：行首画拖拽手柄（整行可拖，手柄只是视觉锚点）。
  final bool showDragHandle;

  @override
  State<FontSpecimenCard> createState() => _FontSpecimenCardState();
}

class _FontSpecimenCardState extends State<FontSpecimenCard> {
  Offset? _lastPointer;

  Offset _center() {
    final RenderObject? box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return box.localToGlobal(box.size.center(Offset.zero));
    }
    return Offset.zero;
  }

  void _openMenu() => widget.onContextMenu(_lastPointer ?? _center());

  void _openMenuFromButton() => widget.onContextMenu(_center());

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool apple = isGlassDesign(context);
    final FontLibraryEntryView entry = widget.entry;
    final bool grid = widget.layout == FontLibraryLayout.grid;

    final TextStyle? nameStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final TextStyle? metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: apple
          ? appleColorsOf(context).secondaryLabel
          : scheme.onSurfaceVariant,
    );

    final Widget moreButton = FushiIconButton(
      icon: FushiIcons.more,
      tooltip: t.font_library_details,
      size: 20,
      onTap: _openMenuFromButton,
    );

    final Widget nameRow = Row(
      children: <Widget>[
        Expanded(
          child: Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: nameStyle,
          ),
        ),
        if (entry.missingOnSystem) ...<Widget>[
          const SizedBox(width: 4),
          FushiTooltip(
            message: t.custom_fonts_system_not_found,
            child: FushiIcon(FushiIcons.warning, size: 18, color: scheme.error),
          ),
        ],
      ],
    );

    final Widget info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        nameRow,
        const SizedBox(height: 2),
        Text(
          entry.metaLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: metaStyle,
        ),
        const SizedBox(height: 8),
        FontUsageBadges(targets: entry.targets),
      ],
    );

    final Widget content;
    if (grid) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: apple
                      ? appleColorsOf(context).tertiaryFill
                      : scheme.surfaceContainerLowest,
                  borderRadius: apple
                      ? const BorderRadius.all(Radius.circular(8))
                      : FushiM3eShape.smallRadius,
                ),
                // 网格单元等高：样张区放不下 3 行时裁掉而不是溢出到信息区。
                child: ClipRect(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: FontSpecimenText(
                        entry: entry,
                        text: widget.sampleText,
                        fontSize: 22,
                        maxLines: 3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 4, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: info),
                moreButton,
              ],
            ),
          ),
        ],
      );
    } else {
      final String glyph = switch (entry.metadata) {
        FontFileMetadata(japanese: true) => 'あ',
        _ when entry.name.contains(RegExp(r'[一-龥]')) => '永',
        _ => 'Aa',
      };
      content = Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (widget.showDragHandle)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 4, top: 20),
                child: FushiTooltip(
                  message: t.custom_fonts_drag_hint,
                  child: const FushiDragHandle(),
                ),
              ),
            _GlyphTile(entry: entry, glyph: glyph),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  nameRow,
                  const SizedBox(height: 4),
                  FontSpecimenText(
                    entry: entry,
                    text: widget.sampleText,
                    fontSize: 19,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    entry.metaLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                  const SizedBox(height: 8),
                  FontUsageBadges(targets: entry.targets),
                ],
              ),
            ),
            moreButton,
          ],
        ),
      );
    }

    return Listener(
      onPointerDown: (PointerDownEvent event) => _lastPointer = event.position,
      child: FushiHoverLift(
        builder: (BuildContext context, bool hovering) => FushiCard(
          key: ValueKey<String>('font-card-surface-${entry.identity}'),
          selected: widget.selected,
          padding: EdgeInsets.zero,
          onTap: widget.onOpen,
          onLongPress: widget.allowLongPressMenu ? _openMenu : null,
          onSecondaryTap: _openMenu,
          child: content,
        ),
      ),
    );
  }
}

/// 列表模式行首的大字块：M3E 是 tertiaryContainer 方圆角色块，Apple 是淡填充。
class _GlyphTile extends StatelessWidget {
  const _GlyphTile({required this.entry, required this.glyph});

  final FontLibraryEntryView entry;
  final String glyph;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final Color background = apple
        ? appleColorsOf(context).tertiaryFill
        : scheme.tertiaryContainer;
    final Color foreground = apple
        ? appleColorsOf(context).label
        : scheme.onTertiaryContainer;
    return SizedBox.square(
      dimension: 64,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.all(Radius.circular(apple ? 12 : 18)),
        ),
        child: Center(
          child: entry.state == FontSpecimenState.ready
              ? Text(
                  glyph,
                  style: _specimenStyle(
                    context,
                    family: entry.family,
                    fontSize: 28,
                    height: 1,
                  ).copyWith(color: foreground),
                )
              : FushiIcon(FushiIcons.font, color: foreground),
        ),
      ),
    );
  }
}

/// 加载中的卡片骨架（与真卡同轮廓）。
class FontSpecimenCardSkeleton extends StatelessWidget {
  const FontSpecimenCardSkeleton({required this.layout, super.key});

  final FontLibraryLayout layout;

  @override
  Widget build(BuildContext context) {
    final bool grid = layout == FontLibraryLayout.grid;
    return FushiSkeletonShimmer(
      child: FushiCard(
        padding: const EdgeInsets.all(14),
        pressScale: false,
        child: grid
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Expanded(child: FushiSkeleton()),
                  const SizedBox(height: 12),
                  FushiSkeleton.line(widthFactor: 0.6, height: 14),
                  const SizedBox(height: 8),
                  FushiSkeleton.line(widthFactor: 0.8),
                ],
              )
            : Row(
                children: <Widget>[
                  const FushiSkeleton(width: 64, height: 64),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        FushiSkeleton.line(widthFactor: 0.5, height: 14),
                        const SizedBox(height: 10),
                        FushiSkeleton.line(widthFactor: 0.9, height: 16),
                        const SizedBox(height: 10),
                        FushiSkeleton.line(widthFactor: 0.7),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 样例文字工具条：文种分段（日文 / 中文 / 西文）+ 可编辑的自定义样例。
class FontSampleToolbar extends StatelessWidget {
  const FontSampleToolbar({
    required this.script,
    required this.onScriptChanged,
    required this.controller,
    required this.onCustomChanged,
    super.key,
  });

  final FontSampleScript script;
  final ValueChanged<FontSampleScript> onScriptChanged;
  final TextEditingController controller;
  final VoidCallback onCustomChanged;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget segments = FushiSegmentedButton<FontSampleScript>(
      key: const ValueKey<String>('font-sample-script'),
      showSelectedIcon: false,
      segments: <ButtonSegment<FontSampleScript>>[
        ButtonSegment<FontSampleScript>(
          value: FontSampleScript.japanese,
          label: Text(t.font_library_filter_japanese),
        ),
        ButtonSegment<FontSampleScript>(
          value: FontSampleScript.chinese,
          label: Text(t.font_library_filter_chinese),
        ),
        ButtonSegment<FontSampleScript>(
          value: FontSampleScript.latin,
          label: Text(t.font_library_sample_latin),
        ),
      ],
      selected: <FontSampleScript>{script},
      onSelectionChanged: (Set<FontSampleScript> value) {
        if (value.isNotEmpty) onScriptChanged(value.first);
      },
    );
    final Widget field = FushiTextField(
      key: const ValueKey<String>('font-sample-custom'),
      controller: controller,
      hintText: t.font_preview_sample_text,
      prefixIcon: const FushiIcon(FushiIcons.textFields),
      clearable: true,
      onClear: onCustomChanged,
      onChanged: (_) => onCustomChanged(),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 640) {
          return Row(
            children: <Widget>[
              segments,
              SizedBox(width: tokens.spacing.gap * 2),
              Expanded(child: field),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            segments,
            SizedBox(height: tokens.spacing.gap),
            field,
          ],
        );
      },
    );
  }
}

/// 详情面板：大号样张（字号滑块 / 横竖排 / 振假名）、字重列表、用途按钮组、
/// 优先级与删除。窄屏装进 bottom sheet，宽屏作为侧板常驻。
class FontLibraryDetailPanel extends StatefulWidget {
  const FontLibraryDetailPanel({
    required this.entry,
    required this.script,
    required this.customSample,
    required this.onToggleTarget,
    required this.onDelete,
    this.onMoveUp,
    this.onMoveDown,
    this.chainPosition,
    this.onClose,
    this.scrollController,
    super.key,
  });

  final FontLibraryEntryView entry;
  final FontSampleScript script;
  final String customSample;
  final ValueChanged<FontTarget> onToggleTarget;
  final VoidCallback onDelete;

  /// null = 已在顶 / 底（按钮置灰）。
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  /// 在整个字体库里的顺位（1 起），决定各用途的回退顺序。
  final int? chainPosition;

  /// 侧板的关闭钮；sheet 里为 null（sheet 自带拖拽条 / 下滑关闭）。
  final VoidCallback? onClose;
  final ScrollController? scrollController;

  @override
  State<FontLibraryDetailPanel> createState() => _FontLibraryDetailPanelState();
}

class _FontLibraryDetailPanelState extends State<FontLibraryDetailPanel> {
  double _fontSize = 28;
  bool _vertical = false;

  Widget _sectionTitle(BuildContext context, String text) {
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text,
        style: apple
            ? FushiDesignTokens.of(context).type.sectionLabel
            : theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final FontLibraryEntryView entry = widget.entry;
    final bool ready = entry.state == FontSpecimenState.ready;

    final String custom = widget.customSample.trim();
    final List<(String, String?)> segments =
        custom.isEmpty && widget.script == FontSampleScript.japanese
        ? kJaFontRubySample
        : <(String, String?)>[
            (fontLibrarySampleText(widget.script, custom), null),
          ];
    // 样张卡是 secondary 饱和色块（Apple 为中性卡）：样张字与字号读数跟随卡片
    // 配对前景，_specimenStyle / labelLarge 自带的页面 onSurface 会盖掉它。
    final Color? onSpecimen = apple
        ? null
        : fushiCardToneColors(context, FushiCardTone.secondary)?.onContainer;
    final TextStyle body = _specimenStyle(
      context,
      family: entry.family,
      fontSize: _fontSize,
      height: 1.9,
    ).copyWith(color: onSpecimen);
    final TextStyle ruby = body.copyWith(fontSize: _fontSize * 0.5, height: 1);

    final Widget header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                entry.name,
                style:
                    (apple
                            ? theme.textTheme.headlineMedium
                            : theme.textTheme.headlineSmall)
                        ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                entry.metaLine,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (widget.onClose != null)
          FushiIconButton(
            icon: FushiIcons.close,
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onTap: widget.onClose,
          ),
      ],
    );

    final Widget specimen = FushiCard(
      tone: apple ? FushiCardTone.neutral : FushiCardTone.secondary,
      pressScale: false,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FushiSegmentedButton<bool>(
                key: const ValueKey<String>('font-detail-orientation'),
                showSelectedIcon: false,
                segments: <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                    value: false,
                    label: Text(t.font_preview_horizontal),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text(t.font_preview_vertical),
                  ),
                ],
                selected: <bool>{_vertical},
                onSelectionChanged: (Set<bool> value) {
                  if (value.isNotEmpty) {
                    setState(() => _vertical = value.first);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              FushiIcon(FushiIcons.fontSize, size: 20),
              const SizedBox(width: 8),
              Text(t.font_library_size_label),
              Expanded(
                child: FushiSlider(
                  key: const ValueKey<String>('font-detail-size'),
                  value: _fontSize,
                  min: 14,
                  max: 72,
                  divisions: 29,
                  label: _fontSize.round().toString(),
                  onChanged: (double value) =>
                      setState(() => _fontSize = value),
                ),
              ),
              SizedBox(
                width: 32,
                child: Text(
                  '${_fontSize.round()}',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: onSpecimen,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 切换文种时日文样张带振假名、中文 / 西文不带，高度不同：新旧样张叠在
          // 左上角交叉淡化，容器高度用弹簧补间过去，下面的字重列表不会瞬间跳位。
          AnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            alignment: AlignmentDirectional.topStart,
            child: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              switchInCurve: FushiMotion.enter,
              switchOutCurve: FushiMotion.exit,
              layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
                alignment: AlignmentDirectional.topStart,
                children: <Widget>[...previous, if (current != null) current],
              ),
              child: !ready
                  ? FontSpecimenText(
                      key: const ValueKey<String>('pending'),
                      entry: entry,
                      text: '',
                      fontSize: 22,
                    )
                  : _vertical
                  ? SizedBox(
                      key: ValueKey<String>('vertical|${widget.script.name}'),
                      height: (_fontSize * 1.15 * 9)
                          .clamp(200.0, 420.0)
                          .toDouble(),
                      child: FontVerticalSpecimen(
                        segments: segments,
                        style: body,
                        rubyStyle: ruby,
                      ),
                    )
                  : Padding(
                      key: ValueKey<String>('horizontal|${widget.script.name}'),
                      padding: EdgeInsets.only(top: _fontSize * 0.3),
                      child: FontHorizontalRubySpecimen(
                        segments: segments,
                        style: body,
                        rubyStyle: ruby,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );

    final List<int> weights =
        entry.metadata?.displayWeights ?? const <int>[400, 700];
    final Widget weightList = FushiCard(
      variant: FushiCardVariant.outlined,
      pressScale: false,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: <Widget>[
          for (final int weight in weights)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 44,
                    child: Text(
                      '$weight',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      ready ? 'Aa 永あア漢 ${entry.name}' : entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _specimenStyle(
                        context,
                        family: ready ? entry.family : null,
                        fontSize: 18,
                        weight: FontWeight
                            .values[((weight ~/ 100) - 1).clamp(0, 8)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    final Widget usage = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final FontTarget target in visibleFontTargets)
          if (entry.unsupportedTargets.containsKey(target))
            // 置灰而非隐藏：用户要知道「这个用途存在，但这个格式用不了」。
            FushiTooltip(
              message: entry.unsupportedTargets[target]!,
              child: FushiToggleButton(
                key: ValueKey<String>('font-detail-target-${target.name}'),
                selected: false,
                onChanged: null,
                icon: FushiIcon(fontTargetIcon(target)),
                label: Text(fontTargetLabel(target)),
              ),
            )
          else
            FushiToggleButton(
              key: ValueKey<String>('font-detail-target-${target.name}'),
              selected: entry.targets.contains(target),
              onChanged: (_) => widget.onToggleTarget(target),
              icon: FushiIcon(fontTargetIcon(target)),
              selectedIcon: const FushiIcon(FushiIcons.check),
              label: Text(fontTargetLabel(target)),
            ),
      ],
    );

    final Widget priority = Row(
      children: <Widget>[
        Expanded(
          child: Text(
            <String>[
              if (widget.chainPosition != null)
                t.font_preview_chain_position(index: widget.chainPosition!),
              t.custom_fonts_drag_hint,
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        FushiIconButton(
          icon: FushiIcons.expandLess,
          tooltip: t.move_up,
          enabled: widget.onMoveUp != null,
          onTap: widget.onMoveUp,
        ),
        FushiIconButton(
          icon: FushiIcons.expandMore,
          tooltip: t.move_down,
          enabled: widget.onMoveDown != null,
          onTap: widget.onMoveDown,
        ),
      ],
    );

    final List<Widget> blocks = <Widget>[
      header,
      if (entry.missingOnSystem)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: FushiInlineNotice(
            severity: FushiNoticeSeverity.warning,
            message: t.custom_fonts_system_not_found,
          ),
        ),
      SizedBox(height: tokens.spacing.card),
      specimen,
      _sectionTitle(context, t.font_library_usage_title),
      usage,
      _sectionTitle(context, t.font_library_weights_title),
      weightList,
      _sectionTitle(context, t.font_library_priority_title),
      priority,
      const SizedBox(height: 12),
      SettingsDangerRow(
        key: const ValueKey<String>('font-detail-delete'),
        title: t.font_library_delete_action,
        icon: FushiIcons.delete,
        onTap: widget.onDelete,
      ),
      if (entry.path != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SelectableText(
            entry.path!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
    ];

    return FushiEntranceScope(
      replayKey: entry.identity,
      child: ListView.builder(
        controller: widget.scrollController,
        // 侧板与页面正文同处一个 PrimaryScrollController 之下：不认领它，
        // 否则两个滚动视图挂到同一控制器上。
        primary: widget.scrollController == null ? false : null,
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.page + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: blocks.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => blocks[index],
        ),
      ),
    );
  }
}

/// 「获取字体」分区的一行入口（M3E 行首形状色块 + 标题）。
class FontLibrarySourceRow extends StatelessWidget {
  const FontLibrarySourceRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.tone = FushiCardTone.secondary,
    super.key,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final FushiCardTone tone;

  @override
  Widget build(BuildContext context) {
    return FushiPressScale(
      child: FushiListItem(
        leading: FushiListLeadingIcon(
          icon,
          shape: FushiLeadingShape.square,
          tone: tone,
        ),
        title: Text(title),
        trailing: const FushiIcon(FushiIcons.chevronRight),
        onTap: onTap,
      ),
    );
  }
}
