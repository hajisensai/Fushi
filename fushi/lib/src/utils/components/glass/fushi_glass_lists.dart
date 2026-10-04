import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 列表与容器族（ListTile / ExpansionTile / Divider / VerticalDivider / Card /
// Badge）的「设计系统分派」包装：构造参数与 Material 原控件逐个同名同型（含
// 命名构造器），调用点只改类名。MD3 下原样构造原控件；「玻璃」设计系统下渲染
// liquid_glass_widgets 的 [GlassListTile] / [GlassDivider] / [GlassCard] /
// [GlassBadge]。
//
// 命名：仓库已有共享组件 `FushiListTile`（fushi_list_tile.dart）、
// `FushiDivider`（fushi_divider.dart）、`FushiCard` / `FushiBadge`
// （fushi_material_components.dart），所以这四个包装加 `Control` 后缀：
// [FushiListTileControl] / [FushiDividerControl] / [FushiCardControl] /
// [FushiBadgeControl]。

// ───────────────────────────── ListTile ─────────────────────────────

/// [ListTile] 的设计系统分派版。
///
/// 玻璃形态是 [GlassListTile]（自带 GlassFocusRegion：Tab 可达、Enter / 手柄
/// A → ActivateIntent 触发 onTap）。GlassListTile 把 leading 硬塞进 32px 宽的
/// 盒子、只收标题 / 副标题两个槽，所以 leading + 标题 + 副标题由这里按 Material
/// 的几何（minLeadingWidth / horizontalTitleGap / 三行对齐）排成一行交给它的
/// title 槽；选中态用 colorScheme 的 secondaryContainer 玻璃底 + primary 前景，
/// 键盘 / 手柄焦点画 primary 描边（库的焦点高亮只有 8% 灰，远看不出）。
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

class _GlassListTileHost extends StatefulWidget {
  const _GlassListTileHost({required this.config});

  final FushiListTileControl config;

  @override
  State<_GlassListTileHost> createState() => _GlassListTileHostState();
}

class _GlassListTileHostState extends State<_GlassListTileHost> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChanged);
    super.dispose();
  }

  void _onHighlightModeChanged(FocusHighlightMode mode) {
    if (mounted && _focused) setState(() {});
  }

  void _onFocusChange(bool focused) {
    widget.config.onFocusChange?.call(focused);
    if (mounted && focused != _focused) setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final FushiListTileControl c = widget.config;
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextTheme tt = theme.textTheme;
    final ListTileThemeData tileTheme = ListTileTheme.of(context);

    final bool enabled = c.enabled;
    final bool selected = c.selected;
    final bool dense = c.dense ?? tileTheme.dense ?? false;
    final bool threeLine = c.isThreeLine ?? tileTheme.isThreeLine ?? false;
    final Color disabled = cs.onSurface.withValues(alpha: 0.38);
    final Color selectedFg =
        c.selectedColor ?? tileTheme.selectedColor ?? cs.primary;
    final Color titleColor = !enabled
        ? disabled
        : selected
        ? selectedFg
        : (c.textColor ?? tileTheme.textColor ?? cs.onSurface);
    final Color iconColor = !enabled
        ? disabled
        : selected
        ? selectedFg
        : (c.iconColor ?? tileTheme.iconColor ?? cs.onSurfaceVariant);
    final Color subtitleColor = !enabled
        ? disabled
        : (c.textColor ?? tileTheme.textColor ?? cs.onSurfaceVariant);

    final TextStyle titleStyle =
        ((dense ? tt.bodyMedium : tt.bodyLarge) ?? const TextStyle())
            .merge(c.titleTextStyle ?? tileTheme.titleTextStyle)
            .copyWith(color: titleColor);
    final TextStyle subtitleStyle = (tt.bodyMedium ?? const TextStyle())
        .merge(c.subtitleTextStyle ?? tileTheme.subtitleTextStyle)
        .copyWith(color: subtitleColor);
    final TextStyle sideStyle = (tt.labelSmall ?? const TextStyle())
        .merge(
          c.leadingAndTrailingTextStyle ??
              tileTheme.leadingAndTrailingTextStyle,
        )
        .copyWith(color: iconColor);

    Widget decorateSide(Widget child) => IconTheme.merge(
      data: IconThemeData(color: iconColor, size: 24),
      child: DefaultTextStyle.merge(style: sideStyle, child: child),
    );

    final CrossAxisAlignment rowAlignment = switch (c.titleAlignment ??
        tileTheme.titleAlignment) {
      ListTileTitleAlignment.top => CrossAxisAlignment.start,
      ListTileTitleAlignment.bottom => CrossAxisAlignment.end,
      ListTileTitleAlignment.center => CrossAxisAlignment.center,
      _ => threeLine ? CrossAxisAlignment.start : CrossAxisAlignment.center,
    };

    final Widget titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DefaultTextStyle(
          style: titleStyle,
          child: c.title ?? const SizedBox.shrink(),
        ),
        if (c.subtitle != null)
          DefaultTextStyle(style: subtitleStyle, child: c.subtitle!),
      ],
    );
    final Widget body = c.leading == null
        ? titleBlock
        : Row(
            crossAxisAlignment: rowAlignment,
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth:
                      c.minLeadingWidth ?? tileTheme.minLeadingWidth ?? 24,
                ),
                child: decorateSide(c.leading!),
              ),
              SizedBox(
                width:
                    c.horizontalTitleGap ?? tileTheme.horizontalTitleGap ?? 16,
              ),
              Expanded(child: titleBlock),
            ],
          );

    final double verticalPadding =
        c.minVerticalPadding ?? tileTheme.minVerticalPadding ?? (dense ? 4 : 8);
    final EdgeInsetsGeometry padding =
        (c.contentPadding ??
                tileTheme.contentPadding ??
                const EdgeInsetsDirectional.only(start: 16, end: 24))
            .add(EdgeInsets.symmetric(vertical: verticalPadding));
    final VisualDensity density =
        c.visualDensity ?? tileTheme.visualDensity ?? theme.visualDensity;
    final double minHeight =
        (c.minTileHeight ??
            tileTheme.minTileHeight ??
            (dense
                ? (c.subtitle == null ? 48 : (threeLine ? 76 : 64))
                : (c.subtitle == null ? 56 : (threeLine ? 88 : 72)))) +
        density.baseSizeAdjustment.dy;

    Widget tile = GlassListTile(
      title: body,
      trailing: c.trailing == null ? null : decorateSide(c.trailing!),
      onTap: enabled ? c.onTap : null,
      onLongPress: enabled ? c.onLongPress : null,
      contentPadding: padding,
      titleStyle: titleStyle,
      subtitleStyle: subtitleStyle,
    );
    tile = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: tile,
    );

    final ShapeBorder shape =
        c.shape ??
        tileTheme.shape ??
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        );
    final Color? fill = selected
        ? (c.selectedTileColor ??
              tileTheme.selectedTileColor ??
              fushiGlassFill(context, tint: cs.secondaryContainer))
        : (c.tileColor ?? tileTheme.tileColor);
    final bool showFocus =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    tile = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        color: fill ?? Colors.transparent,
      ),
      position: DecorationPosition.background,
      child: ClipPath(
        clipper: ShapeBorderClipper(
          shape: shape,
          textDirection: Directionality.maybeOf(context),
        ),
        child: tile,
      ),
    );
    // 描边层恒在（只换 side）：按焦点增删这一层会让 GlassListTile 换父节点
    // 而重建，它内部的 FocusNode 随之丢失，焦点当场掉出去。
    tile = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: _withSide(
          shape,
          showFocus ? BorderSide(color: cs.primary, width: 2) : BorderSide.none,
        ),
      ),
      child: tile,
    );
    tile = Semantics(selected: selected, enabled: enabled, child: tile);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocusChange,
      child: tile,
    );
  }
}

ShapeBorder _withSide(ShapeBorder shape, BorderSide side) {
  if (shape is OutlinedBorder) return shape.copyWith(side: side);
  return RoundedRectangleBorder(
    borderRadius: const BorderRadius.all(Radius.circular(12)),
    side: side,
  );
}

// ─────────────────────────── ExpansionTile ───────────────────────────

/// [ExpansionTile] 的设计系统分派版。
///
/// 玻璃形态：表头是玻璃列表行（[GlassListTile]，与 [FushiListTileControl]
/// 同一套渲染，Tab 可达、Enter / 手柄 A 展开收起），子项用
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
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ExpansionTileThemeData tileTheme = ExpansionTileTheme.of(context);
    final bool expanded = _controller.isExpanded;
    final bool closed = !expanded && _animation.isDismissed;

    final Color? textColor = expanded
        ? (_c.textColor ?? tileTheme.textColor)
        : (_c.collapsedTextColor ?? tileTheme.collapsedTextColor);
    final Color iconColor = expanded
        ? (_c.iconColor ?? tileTheme.iconColor ?? cs.primary)
        : (_c.collapsedIconColor ??
              tileTheme.collapsedIconColor ??
              cs.onSurfaceVariant);

    final Widget expandIcon = RotationTransition(
      turns: Tween<double>(begin: 0, end: 0.5).animate(_curved),
      child: Icon(Icons.expand_more, color: iconColor),
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
    // 是否套玻璃面板只看「有没有配背景色」（静态），不看当前展开态：按展开态
    // 增删这一层会让表头整棵重挂，Enter 展开后焦点当场丢失。
    final Color? expandedBg = _c.backgroundColor ?? tileTheme.backgroundColor;
    final Color? collapsedBg =
        _c.collapsedBackgroundColor ?? tileTheme.collapsedBackgroundColor;
    if (expandedBg != null || collapsedBg != null) {
      final Color? background = expanded ? expandedBg : collapsedBg;
      result = GlassContainer(
        shape: const LiquidRoundedSuperellipse(borderRadius: 12),
        quality: fushiGlassQuality(context),
        settings: background == null || background.a == 0
            ? null
            : fushiGlassSettings(context, tint: background),
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
    final DividerThemeData dividerTheme = DividerTheme.of(context);
    return GlassDivider(
      height: height ?? dividerTheme.space ?? 16,
      thickness: thickness ?? dividerTheme.thickness ?? 0.5,
      indent: indent ?? dividerTheme.indent ?? 0,
      endIndent: endIndent ?? dividerTheme.endIndent ?? 0,
      color:
          color ??
          dividerTheme.color ??
          Theme.of(context).colorScheme.outlineVariant,
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
    return GlassDivider.vertical(
      // GlassDivider 的 height 在竖直方向上就是占位宽度。
      height: width ?? dividerTheme.space ?? 16,
      thickness: thickness ?? dividerTheme.thickness ?? 0.5,
      indent: indent ?? dividerTheme.indent ?? 0,
      endIndent: endIndent ?? dividerTheme.endIndent ?? 0,
      color:
          color ??
          dividerTheme.color ??
          Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

// ───────────────────────────── Card ─────────────────────────────

enum _CardVariant { elevated, filled, outlined }

/// [Card] 的设计系统分派版（含 `.filled` / `.outlined`）。仓库已有共享组件
/// `FushiCard`，故名 `FushiCardControl`。
///
/// 玻璃形态是 [GlassCard]（零内边距，与 Material Card 一致由 child 自己留白）；
/// color 作为玻璃着色，shape 的圆角映射到超椭圆圆角，outlined 叠一圈
/// outlineVariant 描边。
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

    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final CardThemeData cardTheme = theme.cardTheme;
    final ShapeBorder? effectiveShape = shape ?? cardTheme.shape;
    final double radius = _cornerRadius(effectiveShape) ?? 12;
    final Color? tint =
        color ??
        (_variant == _CardVariant.filled ? cs.surfaceContainerHighest : null);

    Widget card = GlassCard(
      padding: EdgeInsets.zero,
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      quality: fushiGlassQuality(context),
      settings: tint == null ? null : fushiGlassSettings(context, tint: tint),
      clipBehavior: clipBehavior ?? cardTheme.clipBehavior ?? Clip.none,
      child: child,
    );
    final BorderSide? side = _variant == _CardVariant.outlined
        ? BorderSide(color: cs.outlineVariant)
        : (effectiveShape is OutlinedBorder &&
                  effectiveShape.side != BorderSide.none
              ? effectiveShape.side
              : null);
    if (side != null) {
      card = DecoratedBox(
        position: borderOnForeground
            ? DecorationPosition.foreground
            : DecorationPosition.background,
        decoration: ShapeDecoration(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: side,
          ),
        ),
        child: card,
      );
    }
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
