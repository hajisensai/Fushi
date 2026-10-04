import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 列表与容器族（ListTile / ExpansionTile / Divider / VerticalDivider / Card /
// Badge）的「设计系统分派」包装：构造参数与 Material 原控件逐个同名同型（含
// 命名构造器），调用点只改类名。MD3 下原样构造原控件；「玻璃」设计系统下按
// Apple 26 的内容层规则渲染：列表行、卡片、分隔线都是**实色**（inset grouped
// 的二级分组底 + 0.5px separator），不是玻璃——玻璃只给浮在内容上的导航与控件
// 层。只有 Badge 仍是 [GlassBadge]。
//
// 命名：仓库已有共享组件 `FushiListTile`（fushi_list_tile.dart）、
// `FushiDivider`（fushi_divider.dart）、`FushiCard` / `FushiBadge`
// （fushi_material_components.dart），所以这四个包装加 `Control` 后缀：
// [FushiListTileControl] / [FushiDividerControl] / [FushiCardControl] /
// [FushiBadgeControl]。

// ─────────────────────── Apple 26 内容层原语 ───────────────────────

/// Apple 26 内容层（inset grouped 列表 / 卡片）的度量，按平台分两档：
/// 触屏（iOS / Android）取 iOS 26 的 inset grouped 尺寸，桌面取 macOS 26 的
/// 紧凑尺寸。按 [ThemeData.platform] 判，测试可经主题覆盖平台。
@immutable
class FushiAppleMetrics {
  const FushiAppleMetrics._({required this.desktop});

  factory FushiAppleMetrics.of(BuildContext context) {
    final TargetPlatform platform = Theme.of(context).platform;
    return FushiAppleMetrics._(
      desktop:
          platform != TargetPlatform.iOS &&
          platform != TargetPlatform.android &&
          platform != TargetPlatform.fuchsia,
    );
  }

  /// 桌面档（macOS / Windows / Linux）。
  final bool desktop;

  /// 列表行最小高：iOS 44pt，macOS 紧凑行 ≈ 38。
  double get rowMinHeight => desktop ? 38 : 44;

  /// 行的水平内边距（两档都是 16，与 iOS inset grouped 一致）。
  double get rowHorizontal => 16;

  /// 行的竖直内边距：只在多行（带副标题）时撑高，单行靠 [rowMinHeight]。
  double get rowVertical => desktop ? 6 : 8;

  /// 行标题字号：iOS body 17，macOS body 13–15 取 15。
  double get titleSize => desktop ? 15 : 17;

  /// 行副标题字号：iOS subheadline 15，macOS 13。
  double get subtitleSize => desktop ? 13 : 15;

  /// 分组标题 / 脚注字号（iOS footnote 13，两档一致）。
  double get footnoteSize => 13;

  /// 行首图标尺寸。
  double get leadingIconSize => desktop ? 18 : 22;

  /// 行首图标与文字的间距。
  double get leadingGap => desktop ? 10 : 14;

  /// 行尾 chevron 尺寸。
  double get chevronSize => desktop ? 13 : 15;

  /// 卡片 / 分组圆角：iOS 26 inset grouped ≈ 24，macOS ≈ 12。
  double get groupRadius => desktop ? 12 : 24;

  /// 分组之间的竖直间距（分组标题在这段间距里）。
  double get groupSpacing => desktop ? 18 : 26;

  /// 设置页行首「彩色圆角方块」图标底的边长。
  double get iconTileSize => desktop ? 22 : 29;

  /// 分组 / 卡片圆角。
  BorderRadius get groupBorderRadius => BorderRadius.circular(groupRadius);

  /// 行标题样式：label 色、常规字重；去掉 MD3 bodyLarge 的 0.5 字距。
  TextStyle titleStyle(BuildContext context) =>
      (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
        fontSize: titleSize,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.25,
        color: appleColorsOf(context).label,
      );

  /// 行副标题样式：secondaryLabel 色。
  TextStyle subtitleStyle(BuildContext context) =>
      (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
        fontSize: subtitleSize,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.3,
        color: appleColorsOf(context).secondaryLabel,
      );

  /// 分组标题 / 脚注样式：13 号 secondaryLabel。
  TextStyle footnoteStyle(BuildContext context) =>
      (Theme.of(context).textTheme.bodySmall ?? const TextStyle()).copyWith(
        fontSize: footnoteSize,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.3,
        color: appleColorsOf(context).secondaryLabel,
      );
}

/// 物理 1px 的细线粗细（Apple 的 hairline：1 / 屏幕缩放，2x 屏即 0.5pt）。
double fushiHairline(BuildContext context) =>
    1 / MediaQuery.devicePixelRatioOf(context);

/// 可导航行的行尾 chevron（`CupertinoIcons.chevron_forward`，tertiaryLabel）。
class FushiAppleChevron extends StatelessWidget {
  const FushiAppleChevron({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    return FushiIcon(
      CupertinoIcons.chevron_forward,
      size: metrics.chevronSize,
      color: appleColorsOf(context).tertiaryLabel,
    );
  }
}

/// Apple 26 的实色可点行：按下 = systemFill 高亮、桌面悬停 = tertiaryFill、
/// 键盘 / 手柄焦点 = 强调色 2px 描边，选中 = secondaryFill 底。
///
/// 焦点契约与 Material 行一致：[focusable] 时自身是一个 Tab 停靠点，Enter /
/// 手柄 A 经 [ActivateIntent] 触发 [onTap]；外层已有焦点目标（FushiFocusTarget）
/// 的调用点传 `focusable: false`，避免一行两个停靠点。树结构恒定：focusable /
/// enabled / selected 只改参数、不增删层，切换时行内子树（Switch 等）不重挂。
class FushiAppleRow extends StatefulWidget {
  const FushiAppleRow({
    required this.child,
    super.key,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.selected = false,
    this.focusable = true,
    this.focusNode,
    this.autofocus = false,
    this.onFocusChange,
    this.borderRadius,
    this.background,
    this.selectedBackground,
    this.mouseCursor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool selected;

  /// false = 行不参与焦点遍历（外层焦点目标负责 Tab / Enter）。
  final bool focusable;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;
  final BorderRadius? borderRadius;

  /// 常态底色；null = 透明（行坐在分组卡上）。
  final Color? background;

  /// 选中底色；null = secondaryFill。
  final Color? selectedBackground;
  final MouseCursor? mouseCursor;

  @override
  State<FushiAppleRow> createState() => _FushiAppleRowState();
}

class _FushiAppleRowState extends State<FushiAppleRow> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focusHighlight = false;

  bool get _interactive =>
      widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool interactive = _interactive;
    final Color background = !interactive
        ? (widget.selected
              ? (widget.selectedBackground ?? apple.secondaryFill)
              : (widget.background ?? Colors.transparent))
        : _pressed
        ? apple.fill
        : widget.selected
        ? (widget.selectedBackground ?? apple.secondaryFill)
        : _hovered
        ? apple.tertiaryFill
        : (widget.background ?? Colors.transparent);
    final BorderRadius radius = widget.borderRadius ?? BorderRadius.zero;
    return FocusableActionDetector(
      enabled: widget.focusable && interactive && widget.onTap != null,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: widget.onFocusChange,
      onShowFocusHighlight: (bool value) {
        if (mounted && value != _focusHighlight) {
          setState(() => _focusHighlight = value);
        }
      },
      onShowHoverHighlight: (bool value) {
        if (mounted && value != _hovered) setState(() => _hovered = value);
      },
      mouseCursor: interactive
          ? (widget.mouseCursor ?? SystemMouseCursors.click)
          : MouseCursor.defer,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (_interactive) widget.onTap?.call();
            return null;
          },
        ),
      },
      child: Semantics(
        button: interactive && widget.onTap != null,
        selected: widget.selected,
        enabled: widget.enabled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: interactive ? (_) => _setPressed(true) : null,
          onTapUp: interactive ? (_) => _setPressed(false) : null,
          onTapCancel: interactive ? () => _setPressed(false) : null,
          onTap: interactive ? widget.onTap : null,
          onLongPress: interactive ? widget.onLongPress : null,
          child: AnimatedContainer(
            // 按下即亮、松开淡出（iOS 单元格的高亮节奏）。
            duration: _pressed
                ? Duration.zero
                : einkSafeDuration(context, const Duration(milliseconds: 200)),
            curve: Curves.easeOut,
            decoration: BoxDecoration(color: background, borderRadius: radius),
            foregroundDecoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: _focusHighlight ? apple.accent : Colors.transparent,
                width: 2,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Apple 的实色卡片 / 分组面：secondarySystemGroupedBackground、连续曲率圆角、
/// 无描边无阴影。内部挂一个透明 [Material]，行内 InkWell 的墨水画在卡片上。
class FushiAppleGroupSurface extends StatelessWidget {
  const FushiAppleGroupSurface({
    required this.child,
    super.key,
    this.color,
    this.borderRadius,
    this.side,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget? child;

  /// null = secondaryGroupedBackground。
  final Color? color;

  /// null = [FushiAppleMetrics.groupBorderRadius]。
  final BorderRadius? borderRadius;
  final BorderSide? side;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius =
        borderRadius ?? FushiAppleMetrics.of(context).groupBorderRadius;
    return Material(
      color: color ?? appleColorsOf(context).secondaryGroupedBackground,
      shape: RoundedSuperellipseBorder(
        borderRadius: radius,
        side: side ?? BorderSide.none,
      ),
      clipBehavior: clipBehavior,
      child: child,
    );
  }
}

/// 实色细分隔线（Apple separator，物理 1px）。
class _AppleHairline extends StatelessWidget {
  const _AppleHairline({
    required this.extent,
    required this.thickness,
    required this.indent,
    required this.endIndent,
    required this.color,
    this.vertical = false,
  });

  final double extent;
  final double thickness;
  final double indent;
  final double endIndent;
  final Color color;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final Widget line = vertical
        ? Container(
            width: thickness,
            margin: EdgeInsetsDirectional.only(top: indent, bottom: endIndent),
            color: color,
          )
        : Container(
            height: thickness,
            margin: EdgeInsetsDirectional.only(start: indent, end: endIndent),
            color: color,
          );
    return vertical
        ? SizedBox(
            width: extent,
            child: Center(child: line),
          )
        : SizedBox(
            height: extent,
            child: Center(child: line),
          );
  }
}

/// 分隔线粗细：调用点给的 ≤ 1 的值（MD3 的 0.5 / 1 细线）一律收成物理 1px，
/// 只有显式更粗的（强调用）照给。
double _hairlineThickness(BuildContext context, double? requested) {
  final double hairline = fushiHairline(context);
  if (requested == null || requested <= 1) return hairline;
  return requested;
}

// ───────────────────────────── ListTile ─────────────────────────────

/// [ListTile] 的设计系统分派版。
///
/// 玻璃设计系统下是 iOS inset grouped 的**实色行**（[FushiAppleRow]，不是
/// 玻璃）：最小高 44（桌面 38）、左右 16、标题 17 / 副标题 15（桌面 15 / 13）、
/// 行首图标强调色、行尾附件 secondaryLabel；按下 = systemFill、选中 =
/// secondaryFill 底 + 强调色前景，键盘 / 手柄焦点画强调色描边。行自身是
/// Tab 停靠点，Enter / 手柄 A → ActivateIntent 触发 onTap。
class FushiListTileControl extends StatelessWidget {
  const FushiListTileControl({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.isThreeLine,
    this.dense,
    this.visualDensity,
    this.shape,
    this.style,
    this.selectedColor,
    this.iconColor,
    this.textColor,
    this.titleTextStyle,
    this.subtitleTextStyle,
    this.leadingAndTrailingTextStyle,
    this.contentPadding,
    this.enabled = true,
    this.onTap,
    this.onLongPress,
    this.onFocusChange,
    this.mouseCursor,
    this.selected = false,
    this.focusColor,
    this.hoverColor,
    this.splashColor,
    this.focusNode,
    this.autofocus = false,
    this.tileColor,
    this.selectedTileColor,
    this.enableFeedback,
    this.horizontalTitleGap,
    this.minVerticalPadding,
    this.minLeadingWidth,
    this.minTileHeight,
    this.titleAlignment,
    this.internalAddSemanticForOnTap = true,
    this.statesController,
  });

  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final bool? isThreeLine;
  final bool? dense;
  final VisualDensity? visualDensity;
  final ShapeBorder? shape;
  final ListTileStyle? style;
  final Color? selectedColor;
  final Color? iconColor;
  final Color? textColor;
  final TextStyle? titleTextStyle;
  final TextStyle? subtitleTextStyle;
  final TextStyle? leadingAndTrailingTextStyle;
  final EdgeInsetsGeometry? contentPadding;
  final bool enabled;
  final GestureTapCallback? onTap;
  final GestureLongPressCallback? onLongPress;
  final ValueChanged<bool>? onFocusChange;
  final MouseCursor? mouseCursor;
  final bool selected;
  final Color? focusColor;
  final Color? hoverColor;
  final Color? splashColor;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? tileColor;
  final Color? selectedTileColor;
  final bool? enableFeedback;
  final double? horizontalTitleGap;
  final double? minVerticalPadding;
  final double? minLeadingWidth;
  final double? minTileHeight;
  final ListTileTitleAlignment? titleAlignment;
  final bool internalAddSemanticForOnTap;
  final WidgetStatesController? statesController;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _GlassListTileHost(config: this);
    return ListTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      isThreeLine: isThreeLine,
      dense: dense,
      visualDensity: visualDensity,
      shape: shape,
      style: style,
      selectedColor: selectedColor,
      iconColor: iconColor,
      textColor: textColor,
      titleTextStyle: titleTextStyle,
      subtitleTextStyle: subtitleTextStyle,
      leadingAndTrailingTextStyle: leadingAndTrailingTextStyle,
      contentPadding: contentPadding,
      enabled: enabled,
      onTap: onTap,
      onLongPress: onLongPress,
      onFocusChange: onFocusChange,
      mouseCursor: mouseCursor,
      selected: selected,
      focusColor: focusColor,
      hoverColor: hoverColor,
      splashColor: splashColor,
      focusNode: focusNode,
      autofocus: autofocus,
      tileColor: tileColor,
      selectedTileColor: selectedTileColor,
      enableFeedback: enableFeedback,
      horizontalTitleGap: horizontalTitleGap,
      minVerticalPadding: minVerticalPadding,
      minLeadingWidth: minLeadingWidth,
      minTileHeight: minTileHeight,
      titleAlignment: titleAlignment,
      internalAddSemanticForOnTap: internalAddSemanticForOnTap,
      statesController: statesController,
    );
  }
}

class _GlassListTileHost extends StatelessWidget {
  const _GlassListTileHost({required this.config});

  final FushiListTileControl config;

  @override
  Widget build(BuildContext context) {
    final FushiListTileControl c = config;
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final ListTileThemeData tileTheme = ListTileTheme.of(context);

    final bool enabled = c.enabled;
    final bool selected = c.selected;
    final bool threeLine = c.isThreeLine ?? tileTheme.isThreeLine ?? false;
    final Color disabled = apple.tertiaryLabel;
    // 选中前景：调用点显式给的 selectedColor 优先，否则强调色（iOS 列表里
    // 「当前项」的勾选 / 文字口径）。
    final Color selectedFg = c.selectedColor ?? apple.accent;
    final Color titleColor = !enabled
        ? disabled
        : selected
        ? selectedFg
        : (c.textColor ?? apple.label);
    final Color subtitleColor = !enabled
        ? disabled
        : (c.textColor ?? apple.secondaryLabel);
    // 行首图标：强调色（iOS 列表图标口径）；行尾附件：secondaryLabel。
    final Color leadingColor = !enabled
        ? disabled
        : selected
        ? selectedFg
        : (c.iconColor ?? apple.accent);
    final Color trailingColor = !enabled
        ? disabled
        : (c.iconColor ?? apple.secondaryLabel);

    final TextStyle titleStyle = metrics
        .titleStyle(context)
        .merge(c.titleTextStyle)
        .copyWith(
          color: titleColor,
          fontWeight: selected ? FontWeight.w600 : null,
        );
    final TextStyle subtitleStyle = metrics
        .subtitleStyle(context)
        .merge(c.subtitleTextStyle)
        .copyWith(color: subtitleColor);
    final TextStyle trailingStyle = metrics
        .titleStyle(context)
        .merge(c.leadingAndTrailingTextStyle)
        .copyWith(color: trailingColor);

    final CrossAxisAlignment rowAlignment = switch (c.titleAlignment ??
        tileTheme.titleAlignment) {
      ListTileTitleAlignment.top => CrossAxisAlignment.start,
      ListTileTitleAlignment.bottom => CrossAxisAlignment.end,
      ListTileTitleAlignment.center => CrossAxisAlignment.center,
      _ => threeLine ? CrossAxisAlignment.start : CrossAxisAlignment.center,
    };

    final Widget titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DefaultTextStyle(
          style: titleStyle,
          child: c.title ?? const SizedBox.shrink(),
        ),
        if (c.subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: DefaultTextStyle(style: subtitleStyle, child: c.subtitle!),
          ),
      ],
    );
    final Widget row = Row(
      crossAxisAlignment: rowAlignment,
      children: <Widget>[
        if (c.leading != null) ...<Widget>[
          ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: c.minLeadingWidth ?? metrics.leadingIconSize + 2,
            ),
            child: IconTheme.merge(
              data: IconThemeData(
                color: leadingColor,
                size: metrics.leadingIconSize,
              ),
              child: DefaultTextStyle.merge(
                style: trailingStyle.copyWith(color: leadingColor),
                child: c.leading!,
              ),
            ),
          ),
          SizedBox(width: c.horizontalTitleGap ?? metrics.leadingGap),
        ],
        Expanded(child: titleBlock),
        if (c.trailing != null) ...<Widget>[
          const SizedBox(width: 8),
          IconTheme.merge(
            data: IconThemeData(color: trailingColor, size: 20),
            child: DefaultTextStyle.merge(
              style: trailingStyle,
              child: c.trailing!,
            ),
          ),
        ],
      ],
    );

    final EdgeInsetsGeometry padding =
        (c.contentPadding ??
                EdgeInsetsDirectional.symmetric(
                  horizontal: metrics.rowHorizontal,
                ))
            .add(
              EdgeInsets.symmetric(
                vertical: c.minVerticalPadding ?? metrics.rowVertical,
              ),
            );
    final double minHeight = c.minTileHeight ?? metrics.rowMinHeight;

    final BorderRadius radius = _cornerRadius(c.shape) != null
        ? BorderRadius.circular(_cornerRadius(c.shape)!)
        : BorderRadius.zero;
    return FushiAppleRow(
      onTap: c.onTap,
      onLongPress: c.onLongPress,
      enabled: enabled,
      selected: selected,
      focusNode: c.focusNode,
      autofocus: c.autofocus,
      onFocusChange: c.onFocusChange,
      mouseCursor: c.mouseCursor,
      borderRadius: radius,
      background: c.tileColor,
      selectedBackground: c.selectedTileColor,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Padding(padding: padding, child: row),
      ),
    );
  }
}

// ─────────────────────────── ExpansionTile ───────────────────────────

/// [ExpansionTile] 的设计系统分派版。
///
/// 玻璃设计系统：表头是实色列表行（与 [FushiListTileControl] 同一套
/// [FushiAppleRow] 渲染，Tab 可达、Enter / 手柄 A 展开收起），行尾是 iOS
/// 披露箭头（chevron_forward 展开时转到朝下），子项用
/// SizeTransition 式的展开动画（ClipRect + Align.heightFactor，时长与曲线取
/// expansionAnimationStyle，默认与 Material 一致的 200ms easeIn）。
/// [ExpansibleController]、initiallyExpanded、maintainState、onExpansionChanged
/// 语义与原控件一致。
class FushiExpansionTile extends StatelessWidget {
  const FushiExpansionTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.onExpansionChanged,
    this.children = const <Widget>[],
    this.trailing,
    this.showTrailingIcon = true,
    this.initiallyExpanded = false,
    this.maintainState = false,
    this.tilePadding,
    this.expandedCrossAxisAlignment,
    this.expandedAlignment,
    this.childrenPadding,
    this.backgroundColor,
    this.collapsedBackgroundColor,
    this.textColor,
    this.collapsedTextColor,
    this.iconColor,
    this.collapsedIconColor,
    this.shape,
    this.collapsedShape,
    this.clipBehavior,
    this.controlAffinity,
    this.controller,
    this.dense,
    this.splashColor,
    this.visualDensity,
    this.minTileHeight,
    this.enableFeedback = true,
    this.enabled = true,
    this.expansionAnimationStyle,
    this.internalAddSemanticForOnTap = false,
    this.statesController,
  });

  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final ValueChanged<bool>? onExpansionChanged;
  final List<Widget> children;
  final Widget? trailing;
  final bool showTrailingIcon;
  final bool initiallyExpanded;
  final bool maintainState;
  final EdgeInsetsGeometry? tilePadding;
  final CrossAxisAlignment? expandedCrossAxisAlignment;
  final AlignmentGeometry? expandedAlignment;
  final EdgeInsetsGeometry? childrenPadding;
  final Color? backgroundColor;
  final Color? collapsedBackgroundColor;
  final Color? textColor;
  final Color? collapsedTextColor;
  final Color? iconColor;
  final Color? collapsedIconColor;
  final ShapeBorder? shape;
  final ShapeBorder? collapsedShape;
  final Clip? clipBehavior;
  final ListTileControlAffinity? controlAffinity;
  final ExpansibleController? controller;
  final bool? dense;
  final Color? splashColor;
  final VisualDensity? visualDensity;
  final double? minTileHeight;
  final bool? enableFeedback;
  final bool enabled;
  final AnimationStyle? expansionAnimationStyle;
  final bool internalAddSemanticForOnTap;
  final WidgetStatesController? statesController;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _GlassExpansionTile(config: this);
    return ExpansionTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      onExpansionChanged: onExpansionChanged,
      trailing: trailing,
      showTrailingIcon: showTrailingIcon,
      initiallyExpanded: initiallyExpanded,
      maintainState: maintainState,
      tilePadding: tilePadding,
      expandedCrossAxisAlignment: expandedCrossAxisAlignment,
      expandedAlignment: expandedAlignment,
      childrenPadding: childrenPadding,
      backgroundColor: backgroundColor,
      collapsedBackgroundColor: collapsedBackgroundColor,
      textColor: textColor,
      collapsedTextColor: collapsedTextColor,
      iconColor: iconColor,
      collapsedIconColor: collapsedIconColor,
      shape: shape,
      collapsedShape: collapsedShape,
      clipBehavior: clipBehavior,
      controlAffinity: controlAffinity,
      controller: controller,
      dense: dense,
      splashColor: splashColor,
      visualDensity: visualDensity,
      minTileHeight: minTileHeight,
      enableFeedback: enableFeedback,
      enabled: enabled,
      expansionAnimationStyle: expansionAnimationStyle,
      internalAddSemanticForOnTap: internalAddSemanticForOnTap,
      statesController: statesController,
      children: children,
    );
  }
}

class _GlassExpansionTile extends StatefulWidget {
  const _GlassExpansionTile({required this.config});

  final FushiExpansionTile config;

  @override
  State<_GlassExpansionTile> createState() => _GlassExpansionTileState();
}

class _GlassExpansionTileState extends State<_GlassExpansionTile>
    with SingleTickerProviderStateMixin {
  static const Duration _kExpand = Duration(milliseconds: 200);

  late ExpansibleController _controller;
  late final AnimationController _animation;
  late CurvedAnimation _curved;

  FushiExpansionTile get _c => widget.config;

  @override
  void initState() {
    super.initState();
    _controller = _c.controller ?? ExpansibleController();
    if (_c.initiallyExpanded) _controller.expand();
    _animation = AnimationController(
      vsync: this,
      duration: _c.expansionAnimationStyle?.duration ?? _kExpand,
      reverseDuration: _c.expansionAnimationStyle?.reverseDuration,
      value: _controller.isExpanded ? 1 : 0,
    );
    _curved = _makeCurve();
    _controller.addListener(_onExpansionChanged);
  }

  CurvedAnimation _makeCurve() => CurvedAnimation(
    parent: _animation,
    curve: _c.expansionAnimationStyle?.curve ?? Curves.easeIn,
    reverseCurve: _c.expansionAnimationStyle?.reverseCurve,
  );

  @override
  void didUpdateWidget(covariant _GlassExpansionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final FushiExpansionTile old = oldWidget.config;
    if (old.controller != _c.controller) {
      _controller.removeListener(_onExpansionChanged);
      if (old.controller == null) _controller.dispose();
      _controller = _c.controller ?? ExpansibleController();
      _controller.addListener(_onExpansionChanged);
    }
    if (old.expansionAnimationStyle != _c.expansionAnimationStyle) {
      _animation.duration = _c.expansionAnimationStyle?.duration ?? _kExpand;
      _animation.reverseDuration = _c.expansionAnimationStyle?.reverseDuration;
      _curved.dispose();
      _curved = _makeCurve();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onExpansionChanged);
    if (_c.controller == null) _controller.dispose();
    _curved.dispose();
    _animation.dispose();
    super.dispose();
  }

  void _onExpansionChanged() {
    if (_controller.isExpanded) {
      _animation.forward();
    } else {
      _animation.reverse().then<void>((_) {
        if (mounted) setState(() {});
      });
    }
    setState(() {});
    _c.onExpansionChanged?.call(_controller.isExpanded);
  }

  void _toggle() {
    if (_controller.isExpanded) {
      _controller.collapse();
    } else {
      _controller.expand();
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final ExpansionTileThemeData tileTheme = ExpansionTileTheme.of(context);
    final bool expanded = _controller.isExpanded;
    final bool closed = !expanded && _animation.isDismissed;

    final Color? textColor = expanded
        ? (_c.textColor ?? tileTheme.textColor)
        : (_c.collapsedTextColor ?? tileTheme.collapsedTextColor);
    // 行首图标与披露箭头分开配色：调用点的 iconColor 只作用于 leading，
    // 披露箭头恒为 tertiaryLabel（iOS 披露指示器口径，展开不变色）。
    final Color? iconColor = expanded
        ? (_c.iconColor ?? tileTheme.iconColor)
        : (_c.collapsedIconColor ?? tileTheme.collapsedIconColor);

    final Widget expandIcon = RotationTransition(
      turns: Tween<double>(begin: 0, end: 0.25).animate(_curved),
      child: FushiIcon(
        CupertinoIcons.chevron_forward,
        size: metrics.chevronSize,
        color: apple.tertiaryLabel,
      ),
    );
    final bool leadingAffinity =
        (_c.controlAffinity ?? ListTileControlAffinity.trailing) ==
        ListTileControlAffinity.leading;
    final Widget? leading = leadingAffinity && _c.showTrailingIcon
        ? expandIcon
        : _c.leading;
    final Widget? trailing =
        _c.trailing ??
        (!leadingAffinity && _c.showTrailingIcon ? expandIcon : null);

    final Widget header = FushiListTileControl(
      leading: leading,
      title: _c.title,
      subtitle: _c.subtitle,
      trailing: trailing,
      onTap: _c.enabled ? _toggle : null,
      enabled: _c.enabled,
      dense: _c.dense,
      visualDensity: _c.visualDensity,
      contentPadding: _c.tilePadding ?? tileTheme.tilePadding,
      minTileHeight: _c.minTileHeight,
      textColor: textColor,
      iconColor: iconColor,
    );

    final Widget body = Align(
      alignment:
          _c.expandedAlignment ??
          tileTheme.expandedAlignment ??
          Alignment.center,
      child: Padding(
        padding:
            _c.childrenPadding ?? tileTheme.childrenPadding ?? EdgeInsets.zero,
        child: Column(
          crossAxisAlignment:
              _c.expandedCrossAxisAlignment ?? CrossAxisAlignment.center,
          children: _c.children,
        ),
      ),
    );
    final bool removeChildren = closed && !_c.maintainState;

    Widget result = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        header,
        ClipRect(
          child: AnimatedBuilder(
            animation: _curved,
            builder: (BuildContext context, Widget? child) => Align(
              alignment: Alignment.topCenter,
              heightFactor: _curved.value,
              child: child,
            ),
            child: removeChildren
                ? null
                : TickerMode(
                    enabled: !closed,
                    child: Offstage(offstage: closed, child: body),
                  ),
          ),
        ),
      ],
    );
    // 是否套实色分组面只看「有没有配背景色」（静态），不看当前展开态：按展开态
    // 增删这一层会让表头整棵重挂，Enter 展开后焦点当场丢失。
    final Color? expandedBg = _c.backgroundColor ?? tileTheme.backgroundColor;
    final Color? collapsedBg =
        _c.collapsedBackgroundColor ?? tileTheme.collapsedBackgroundColor;
    if (expandedBg != null || collapsedBg != null) {
      final Color? background = expanded ? expandedBg : collapsedBg;
      result = FushiAppleGroupSurface(
        color: background == null || background.a == 0
            ? Colors.transparent
            : background,
        borderRadius: _cornerRadius(_c.shape) == null
            ? null
            : BorderRadius.circular(_cornerRadius(_c.shape)!),
        child: result,
      );
    }
    return result;
  }
}

// ───────────────────────────── Divider ─────────────────────────────

/// [Divider] 的设计系统分派版。仓库已有共享组件 `FushiDivider`，故名
/// `FushiDividerControl`。
class FushiDividerControl extends StatelessWidget {
  const FushiDividerControl({
    super.key,
    this.height,
    this.thickness,
    this.indent,
    this.endIndent,
    this.color,
    this.radius,
  });

  final double? height;
  final double? thickness;
  final double? indent;
  final double? endIndent;
  final Color? color;
  final BorderRadiusGeometry? radius;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return Divider(
        height: height,
        thickness: thickness,
        indent: indent,
        endIndent: endIndent,
        color: color,
        radius: radius,
      );
    }
    // 玻璃设计系统：Apple 实色细分隔线（separator 色、物理 1px），不是玻璃。
    final DividerThemeData dividerTheme = DividerTheme.of(context);
    return _AppleHairline(
      extent: height ?? dividerTheme.space ?? 16,
      thickness: _hairlineThickness(
        context,
        thickness ?? dividerTheme.thickness,
      ),
      indent: indent ?? dividerTheme.indent ?? 0,
      endIndent: endIndent ?? dividerTheme.endIndent ?? 0,
      color: color ?? appleColorsOf(context).separator,
    );
  }
}

/// [VerticalDivider] 的设计系统分派版。
class FushiVerticalDivider extends StatelessWidget {
  const FushiVerticalDivider({
    super.key,
    this.width,
    this.thickness,
    this.indent,
    this.endIndent,
    this.color,
    this.radius,
  });

  final double? width;
  final double? thickness;
  final double? indent;
  final double? endIndent;
  final Color? color;
  final BorderRadiusGeometry? radius;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return VerticalDivider(
        width: width,
        thickness: thickness,
        indent: indent,
        endIndent: endIndent,
        color: color,
        radius: radius,
      );
    }
    final DividerThemeData dividerTheme = DividerTheme.of(context);
    return _AppleHairline(
      vertical: true,
      extent: width ?? dividerTheme.space ?? 16,
      thickness: _hairlineThickness(
        context,
        thickness ?? dividerTheme.thickness,
      ),
      indent: indent ?? dividerTheme.indent ?? 0,
      endIndent: endIndent ?? dividerTheme.endIndent ?? 0,
      color: color ?? appleColorsOf(context).separator,
    );
  }
}

// ───────────────────────────── Card ─────────────────────────────

enum _CardVariant { elevated, filled, outlined }

/// [Card] 的设计系统分派版（含 `.filled` / `.outlined`）。仓库已有共享组件
/// `FushiCard`，故名 `FushiCardControl`。
///
/// 玻璃设计系统下是 Apple 的**实色**卡片（[FushiAppleGroupSurface]，不是玻璃）：
/// 底色 secondarySystemGroupedBackground（调用点显式 color 优先）、连续曲率
/// 圆角（调用点显式 shape 的圆角优先，否则 iOS 24 / 桌面 12）、无阴影；
/// outlined 叠一圈 separator 细线。零内边距，与 Material Card 一致由 child 留白。
class FushiCardControl extends StatelessWidget {
  const FushiCardControl({
    super.key,
    this.color,
    this.shadowColor,
    this.surfaceTintColor,
    this.elevation,
    this.shape,
    this.borderOnForeground = true,
    this.margin,
    this.clipBehavior,
    this.child,
    this.semanticContainer = true,
  }) : _variant = _CardVariant.elevated;

  const FushiCardControl.filled({
    super.key,
    this.color,
    this.shadowColor,
    this.surfaceTintColor,
    this.elevation,
    this.shape,
    this.borderOnForeground = true,
    this.margin,
    this.clipBehavior,
    this.child,
    this.semanticContainer = true,
  }) : _variant = _CardVariant.filled;

  const FushiCardControl.outlined({
    super.key,
    this.color,
    this.shadowColor,
    this.surfaceTintColor,
    this.elevation,
    this.shape,
    this.borderOnForeground = true,
    this.margin,
    this.clipBehavior,
    this.child,
    this.semanticContainer = true,
  }) : _variant = _CardVariant.outlined;

  final Color? color;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final double? elevation;
  final ShapeBorder? shape;
  final bool borderOnForeground;
  final EdgeInsetsGeometry? margin;
  final Clip? clipBehavior;
  final Widget? child;
  final bool semanticContainer;
  final _CardVariant _variant;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      switch (_variant) {
        case _CardVariant.elevated:
          return Card(
            color: color,
            shadowColor: shadowColor,
            surfaceTintColor: surfaceTintColor,
            elevation: elevation,
            shape: shape,
            borderOnForeground: borderOnForeground,
            margin: margin,
            clipBehavior: clipBehavior,
            semanticContainer: semanticContainer,
            child: child,
          );
        case _CardVariant.filled:
          return Card.filled(
            color: color,
            shadowColor: shadowColor,
            surfaceTintColor: surfaceTintColor,
            elevation: elevation,
            shape: shape,
            borderOnForeground: borderOnForeground,
            margin: margin,
            clipBehavior: clipBehavior,
            semanticContainer: semanticContainer,
            child: child,
          );
        case _CardVariant.outlined:
          return Card.outlined(
            color: color,
            shadowColor: shadowColor,
            surfaceTintColor: surfaceTintColor,
            elevation: elevation,
            shape: shape,
            borderOnForeground: borderOnForeground,
            margin: margin,
            clipBehavior: clipBehavior,
            semanticContainer: semanticContainer,
            child: child,
          );
      }
    }

    final CardThemeData cardTheme = Theme.of(context).cardTheme;
    final double? explicitRadius = _cornerRadius(shape);
    final ShapeBorder? explicitShape = shape;
    final BorderSide? explicitSide =
        explicitShape is OutlinedBorder && explicitShape.side != BorderSide.none
        ? explicitShape.side
        : null;
    final BorderSide? side = _variant == _CardVariant.outlined
        ? BorderSide(
            color: appleColorsOf(context).separator,
            width: fushiHairline(context),
          )
        : explicitSide;
    Widget card = FushiAppleGroupSurface(
      color: color,
      borderRadius: explicitRadius == null
          ? null
          : BorderRadius.circular(explicitRadius),
      side: side,
      clipBehavior: clipBehavior ?? cardTheme.clipBehavior ?? Clip.none,
      child: child,
    );
    card = Semantics(container: semanticContainer, child: card);
    return Padding(
      padding: margin ?? cardTheme.margin ?? const EdgeInsets.all(4),
      child: card,
    );
  }
}

double? _cornerRadius(ShapeBorder? shape) {
  BorderRadiusGeometry? radius;
  if (shape is RoundedRectangleBorder) radius = shape.borderRadius;
  if (shape is RoundedSuperellipseBorder) radius = shape.borderRadius;
  if (shape is ContinuousRectangleBorder) radius = shape.borderRadius;
  if (radius == null) return null;
  return radius.resolve(TextDirection.ltr).topLeft.x;
}

// ───────────────────────────── Badge ─────────────────────────────

/// [Badge] 的设计系统分派版（含 `.count`）。仓库已有共享组件 `FushiBadge`，
/// 故名 `FushiBadgeControl`。
///
/// 玻璃形态是 [GlassBadge]：无 label → 圆点（`GlassBadge.dot`）；`.count` 或
/// label 是纯数字 [Text] → 计数徽标；其它任意 label → 同位置的玻璃胶囊
/// （[GlassContainer]），保住 label 内容。颜色取 colorScheme 的 error / onError
/// （库默认是 iOS 红 / 绿）。
class FushiBadgeControl extends StatelessWidget {
  const FushiBadgeControl({
    super.key,
    this.backgroundColor,
    this.textColor,
    this.smallSize,
    this.largeSize,
    this.textStyle,
    this.padding,
    this.alignment,
    this.offset,
    this.label,
    this.isLabelVisible = true,
    this.child,
  }) : _count = null,
       _maxCount = 999;

  const FushiBadgeControl.count({
    super.key,
    this.backgroundColor,
    this.textColor,
    this.smallSize,
    this.largeSize,
    this.textStyle,
    this.padding,
    this.alignment,
    this.offset,
    required int count,
    int maxCount = 999,
    this.isLabelVisible = true,
    this.child,
  }) : label = null,
       _count = count,
       _maxCount = maxCount;

  final Color? backgroundColor;
  final Color? textColor;
  final double? smallSize;
  final double? largeSize;
  final TextStyle? textStyle;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry? alignment;
  final Offset? offset;
  final Widget? label;
  final bool isLabelVisible;
  final Widget? child;
  final int? _count;
  final int _maxCount;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      if (_count != null) {
        return Badge.count(
          backgroundColor: backgroundColor,
          textColor: textColor,
          smallSize: smallSize,
          largeSize: largeSize,
          textStyle: textStyle,
          padding: padding,
          alignment: alignment,
          offset: offset,
          count: _count,
          maxCount: _maxCount,
          isLabelVisible: isLabelVisible,
          child: child,
        );
      }
      return Badge(
        backgroundColor: backgroundColor,
        textColor: textColor,
        smallSize: smallSize,
        largeSize: largeSize,
        textStyle: textStyle,
        padding: padding,
        alignment: alignment,
        offset: offset,
        label: label,
        isLabelVisible: isLabelVisible,
        child: child,
      );
    }

    // 结构恒定：child 永远是同一个 Stack 的第 0 个孩子，徽标显隐只增删第 1 个
    // 孩子。GlassBadge 在 count 为 0 时直接返回 child、否则包一层 Stack——直接
    // 用它包 child 会让 isLabelVisible 一切换 child 就整棵重挂（child 里的按钮
    // 当场丢焦点）。所以 GlassBadge 只包一个零尺寸占位，挂在 child 的右上角。
    final Widget base = child ?? const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final BadgeThemeData badgeTheme = theme.badgeTheme;
    final Color bg =
        backgroundColor ??
        badgeTheme.backgroundColor ??
        theme.colorScheme.error;
    final Color fg =
        textColor ?? badgeTheme.textColor ?? theme.colorScheme.onError;
    final GlassQuality quality = fushiGlassQuality(context);

    Widget? badge;
    if (isLabelVisible) {
      final Widget? labelWidget = label;
      int? count = _count;
      if (count == null && labelWidget is Text) {
        count = int.tryParse(labelWidget.data?.trim() ?? '');
      }
      if (count != null) {
        badge = PositionedDirectional(
          top: 0,
          end: 0,
          child: GlassBadge(
            count: count,
            maxCount: _count != null ? _maxCount : 999,
            showZero: true,
            backgroundColor: bg,
            textColor: fg,
            quality: quality,
            child: const SizedBox.shrink(),
          ),
        );
      } else if (labelWidget == null) {
        badge = PositionedDirectional(
          top: 0,
          end: 0,
          child: GlassBadge.dot(
            dotColor: bg,
            quality: quality,
            child: const SizedBox.shrink(),
          ),
        );
      } else {
        badge = PositionedDirectional(
          top: -6,
          end: -6,
          child: GlassContainer(
            shape: const LiquidRoundedSuperellipse(borderRadius: 9),
            quality: quality,
            settings: fushiGlassSettings(context, tint: bg),
            padding:
                padding ??
                badgeTheme.padding ??
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: DefaultTextStyle.merge(
              style: (theme.textTheme.labelSmall ?? const TextStyle())
                  .copyWith(color: fg)
                  .merge(textStyle ?? badgeTheme.textStyle),
              child: labelWidget,
            ),
          ),
        );
      }
    }
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[base, if (badge != null) badge],
    );
  }
}
