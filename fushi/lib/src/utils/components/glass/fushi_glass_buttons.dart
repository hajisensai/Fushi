import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 按钮族的「设计系统分派」包装：构造参数与 Material 原控件逐个同名同型，
// 调用点只改类名。MD3 设计系统下原样构造原控件（像素、焦点、语义一字不差）；
// 「玻璃」设计系统下渲染 liquid_glass_widgets 的 [GlassButton]——它自带
// GlassFocusRegion（焦点环 + Enter / 空格 → ActivateIntent），与全局焦点导航
// 和手柄 A 键同一条激活链路。

enum _FushiButtonKind { text, filled, tonal, outlined }

/// 玻璃按钮的共用渲染。[kind] 决定玻璃样式与配色：filled = prominent 主色、
/// tonal = secondaryContainer 着色、outlined = 中性玻璃 + primary 前景、
/// text = 透明玻璃 + primary 前景。[style] 里能映射的字段（前景 / 背景色、
/// 内边距、最小 / 固定尺寸）照用，其余忽略。
Widget _glassButton(
  BuildContext context, {
  required _FushiButtonKind kind,
  required VoidCallback? onPressed,
  required VoidCallback? onLongPress,
  required ValueChanged<bool>? onHover,
  required ValueChanged<bool>? onFocusChange,
  required ButtonStyle? style,
  required FocusNode? focusNode,
  required bool autofocus,
  required Widget? icon,
  required Widget? label,
  required IconAlignment? iconAlignment,
}) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme cs = theme.colorScheme;
  final bool enabled = onPressed != null || onLongPress != null;
  const Set<WidgetState> states = <WidgetState>{};
  final Set<WidgetState> resolveStates =
      enabled ? states : <WidgetState>{WidgetState.disabled};

  final Color? styleBg = style?.backgroundColor?.resolve(resolveStates);
  final Color? styleFg = style?.foregroundColor?.resolve(resolveStates);
  GlassButtonStyle glassStyle;
  Color? tint;
  Color fg;
  switch (kind) {
    case _FushiButtonKind.filled:
      glassStyle = GlassButtonStyle.prominent;
      tint = cs.primary;
      fg = cs.onPrimary;
    case _FushiButtonKind.tonal:
      glassStyle = GlassButtonStyle.filled;
      tint = cs.secondaryContainer;
      fg = cs.onSecondaryContainer;
    case _FushiButtonKind.outlined:
      glassStyle = GlassButtonStyle.filled;
      fg = cs.primary;
    case _FushiButtonKind.text:
      glassStyle = GlassButtonStyle.transparent;
      fg = cs.primary;
  }
  if (styleBg != null && styleBg.a > 0) {
    tint = styleBg;
    if (glassStyle == GlassButtonStyle.transparent) {
      glassStyle = GlassButtonStyle.filled;
    }
  }
  if (styleFg != null) fg = styleFg;
  if (!enabled) fg = cs.onSurface.withValues(alpha: 0.38);

  final EdgeInsetsGeometry padding =
      style?.padding?.resolve(resolveStates) ??
          EdgeInsets.symmetric(
            horizontal: kind == _FushiButtonKind.text ? 12 : 18,
            vertical: 10,
          );
  final Size? minimumSize = style?.minimumSize?.resolve(resolveStates);
  final Size? fixedSize = style?.fixedSize?.resolve(resolveStates);

  final TextStyle textStyle =
      (style?.textStyle?.resolve(resolveStates) ?? theme.textTheme.labelLarge ??
              const TextStyle())
          .copyWith(color: fg);
  Widget content;
  if (icon != null && label != null) {
    final bool trailing = iconAlignment == IconAlignment.end;
    final List<Widget> parts = <Widget>[
      icon,
      const SizedBox(width: 8),
      Flexible(child: label),
    ];
    content = Row(
      mainAxisSize: MainAxisSize.min,
      children: trailing ? parts.reversed.toList() : parts,
    );
  } else {
    content = label ?? icon ?? const SizedBox.shrink();
  }
  content = IconTheme.merge(
    data: IconThemeData(color: fg, size: 18),
    child: DefaultTextStyle.merge(
      style: textStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: Padding(padding: padding, child: content),
    ),
  );
  content = ConstrainedBox(
    constraints: BoxConstraints(
      minWidth: fixedSize?.width ?? minimumSize?.width ?? 48,
      minHeight: fixedSize?.height ?? minimumSize?.height ?? 40,
    ),
    child: Center(widthFactor: 1, heightFactor: 1, child: content),
  );

  Widget button = GlassButton.custom(
    onTap: onPressed ?? () {},
    enabled: enabled,
    style: glassStyle,
    settings: tint == null ? null : fushiGlassSettings(context, tint: tint),
    quality: fushiGlassQuality(context),
    shape: const LiquidRoundedSuperellipse(borderRadius: 20),
    focusNode: focusNode,
    autofocus: autofocus,
    child: content,
  );
  if (onLongPress != null) {
    button = GestureDetector(onLongPress: onLongPress, child: button);
  }
  if (onHover != null) {
    button = MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: button,
    );
  }
  if (onFocusChange != null) {
    button = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: onFocusChange,
      child: button,
    );
  }
  return button;
}

/// [TextButton] 的设计系统分派版。
class FushiTextButton extends StatelessWidget {
  const FushiTextButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
    this.statesController,
    this.isSemanticButton = true,
    required this.child,
  })  : icon = null,
        label = null,
        iconAlignment = null,
        _withIcon = false;

  const FushiTextButton.icon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
    this.statesController,
    this.icon,
    required this.label,
    this.iconAlignment,
  })  : child = null,
        isSemanticButton = true,
        _withIcon = true;

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip? clipBehavior;
  final WidgetStatesController? statesController;
  final bool? isSemanticButton;
  final Widget? child;
  final Widget? icon;
  final Widget? label;
  final IconAlignment? iconAlignment;
  final bool _withIcon;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return _glassButton(
        context,
        kind: _FushiButtonKind.text,
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: onFocusChange,
        style: style,
        focusNode: focusNode,
        autofocus: autofocus,
        icon: icon,
        label: _withIcon ? label : child,
        iconAlignment: iconAlignment,
      );
    }
    if (_withIcon) {
      return TextButton.icon(
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: onFocusChange,
        style: style,
        focusNode: focusNode,
        autofocus: autofocus,
        clipBehavior: clipBehavior,
        statesController: statesController,
        icon: icon,
        label: label!,
        iconAlignment: iconAlignment,
      );
    }
    return TextButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      onHover: onHover,
      onFocusChange: onFocusChange,
      style: style,
      focusNode: focusNode,
      autofocus: autofocus,
      clipBehavior: clipBehavior ?? Clip.none,
      statesController: statesController,
      isSemanticButton: isSemanticButton,
      child: child!,
    );
  }
}

enum _FilledVariant { filled, tonal }

/// [FilledButton] 的设计系统分派版（含 `.icon` / `.tonal` / `.tonalIcon`）。
class FushiFilledButton extends StatelessWidget {
  const FushiFilledButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
    required this.child,
  })  : icon = null,
        label = null,
        iconAlignment = null,
        _withIcon = false,
        _variant = _FilledVariant.filled;

  const FushiFilledButton.icon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
    this.icon,
    required this.label,
    this.iconAlignment,
  })  : child = null,
        _withIcon = true,
        _variant = _FilledVariant.filled;

  const FushiFilledButton.tonal({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
    required this.child,
  })  : icon = null,
        label = null,
        iconAlignment = null,
        _withIcon = false,
        _variant = _FilledVariant.tonal;

  const FushiFilledButton.tonalIcon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
    required Widget this.icon,
    required this.label,
    this.iconAlignment,
  })  : child = null,
        _withIcon = true,
        _variant = _FilledVariant.tonal;

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip clipBehavior;
  final WidgetStatesController? statesController;
  final Widget? child;
  final Widget? icon;
  final Widget? label;
  final IconAlignment? iconAlignment;
  final bool _withIcon;
  final _FilledVariant _variant;

  @override
  Widget build(BuildContext context) {
    final bool tonal = _variant == _FilledVariant.tonal;
    if (isGlassDesign(context)) {
      return _glassButton(
        context,
        kind: tonal ? _FushiButtonKind.tonal : _FushiButtonKind.filled,
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: onFocusChange,
        style: style,
        focusNode: focusNode,
        autofocus: autofocus,
        icon: icon,
        label: _withIcon ? label : child,
        iconAlignment: iconAlignment,
      );
    }
    if (_withIcon) {
      return tonal
          ? FilledButton.tonalIcon(
              onPressed: onPressed,
              onLongPress: onLongPress,
              onHover: onHover,
              onFocusChange: onFocusChange,
              style: style,
              focusNode: focusNode,
              autofocus: autofocus,
              clipBehavior: clipBehavior,
              statesController: statesController,
              icon: icon!,
              label: label!,
              iconAlignment: iconAlignment,
            )
          : FilledButton.icon(
              onPressed: onPressed,
              onLongPress: onLongPress,
              onHover: onHover,
              onFocusChange: onFocusChange,
              style: style,
              focusNode: focusNode,
              autofocus: autofocus,
              clipBehavior: clipBehavior,
              statesController: statesController,
              icon: icon,
              label: label!,
              iconAlignment: iconAlignment,
            );
    }
    return tonal
        ? FilledButton.tonal(
            onPressed: onPressed,
            onLongPress: onLongPress,
            onHover: onHover,
            onFocusChange: onFocusChange,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            clipBehavior: clipBehavior,
            statesController: statesController,
            child: child,
          )
        : FilledButton(
            onPressed: onPressed,
            onLongPress: onLongPress,
            onHover: onHover,
            onFocusChange: onFocusChange,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            clipBehavior: clipBehavior,
            statesController: statesController,
            child: child,
          );
  }
}

/// [OutlinedButton] 的设计系统分派版（含 `.icon`）。
class FushiOutlinedButton extends StatelessWidget {
  const FushiOutlinedButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
    this.statesController,
    required this.child,
  })  : icon = null,
        label = null,
        iconAlignment = null,
        _withIcon = false;

  const FushiOutlinedButton.icon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
    this.statesController,
    this.icon,
    required this.label,
    this.iconAlignment,
  })  : child = null,
        _withIcon = true;

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip? clipBehavior;
  final WidgetStatesController? statesController;
  final Widget? child;
  final Widget? icon;
  final Widget? label;
  final IconAlignment? iconAlignment;
  final bool _withIcon;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return _glassButton(
        context,
        kind: _FushiButtonKind.outlined,
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: onFocusChange,
        style: style,
        focusNode: focusNode,
        autofocus: autofocus,
        icon: icon,
        label: _withIcon ? label : child,
        iconAlignment: iconAlignment,
      );
    }
    if (_withIcon) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: onFocusChange,
        style: style,
        focusNode: focusNode,
        autofocus: autofocus,
        clipBehavior: clipBehavior,
        statesController: statesController,
        icon: icon,
        label: label!,
        iconAlignment: iconAlignment,
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      onHover: onHover,
      onFocusChange: onFocusChange,
      style: style,
      focusNode: focusNode,
      autofocus: autofocus,
      clipBehavior: clipBehavior ?? Clip.none,
      statesController: statesController,
      child: child,
    );
  }
}

enum _IconButtonVariant { standard, filled, filledTonal, outlined }

/// [IconButton] 的设计系统分派版（含 `.filled` / `.filledTonal` / `.outlined`）。
class FushiIconButtonControl extends StatelessWidget {
  const FushiIconButtonControl({
    super.key,
    this.iconSize,
    this.visualDensity,
    this.padding,
    this.alignment,
    this.splashRadius,
    this.color,
    this.focusColor,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.disabledColor,
    required this.onPressed,
    this.onHover,
    this.onLongPress,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.enableFeedback,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    required this.icon,
  }) : _variant = _IconButtonVariant.standard;

  const FushiIconButtonControl.filled({
    super.key,
    this.iconSize,
    this.visualDensity,
    this.padding,
    this.alignment,
    this.splashRadius,
    this.color,
    this.focusColor,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.disabledColor,
    required this.onPressed,
    this.onHover,
    this.onLongPress,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.enableFeedback,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    required this.icon,
  }) : _variant = _IconButtonVariant.filled;

  const FushiIconButtonControl.filledTonal({
    super.key,
    this.iconSize,
    this.visualDensity,
    this.padding,
    this.alignment,
    this.splashRadius,
    this.color,
    this.focusColor,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.disabledColor,
    required this.onPressed,
    this.onHover,
    this.onLongPress,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.enableFeedback,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    required this.icon,
  }) : _variant = _IconButtonVariant.filledTonal;

  const FushiIconButtonControl.outlined({
    super.key,
    this.iconSize,
    this.visualDensity,
    this.padding,
    this.alignment,
    this.splashRadius,
    this.color,
    this.focusColor,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.disabledColor,
    required this.onPressed,
    this.onHover,
    this.onLongPress,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.enableFeedback,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    required this.icon,
  }) : _variant = _IconButtonVariant.outlined;

  final double? iconSize;
  final VisualDensity? visualDensity;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry? alignment;
  final double? splashRadius;
  final Color? color;
  final Color? focusColor;
  final Color? hoverColor;
  final Color? highlightColor;
  final Color? splashColor;
  final Color? disabledColor;
  final VoidCallback? onPressed;
  final ValueChanged<bool>? onHover;
  final VoidCallback? onLongPress;
  final MouseCursor? mouseCursor;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? tooltip;
  final bool? enableFeedback;
  final BoxConstraints? constraints;
  final ButtonStyle? style;
  final bool? isSelected;
  final Widget? selectedIcon;
  final Widget icon;
  final _IconButtonVariant _variant;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    switch (_variant) {
      case _IconButtonVariant.standard:
        return IconButton(
          iconSize: iconSize,
          visualDensity: visualDensity,
          padding: padding,
          alignment: alignment,
          splashRadius: splashRadius,
          color: color,
          focusColor: focusColor,
          hoverColor: hoverColor,
          highlightColor: highlightColor,
          splashColor: splashColor,
          disabledColor: disabledColor,
          onPressed: onPressed,
          onHover: onHover,
          onLongPress: onLongPress,
          mouseCursor: mouseCursor,
          focusNode: focusNode,
          autofocus: autofocus,
          tooltip: tooltip,
          enableFeedback: enableFeedback,
          constraints: constraints,
          style: style,
          isSelected: isSelected,
          selectedIcon: selectedIcon,
          icon: icon,
        );
      case _IconButtonVariant.filled:
        return IconButton.filled(
          iconSize: iconSize,
          visualDensity: visualDensity,
          padding: padding,
          alignment: alignment,
          splashRadius: splashRadius,
          color: color,
          focusColor: focusColor,
          hoverColor: hoverColor,
          highlightColor: highlightColor,
          splashColor: splashColor,
          disabledColor: disabledColor,
          onPressed: onPressed,
          onHover: onHover,
          onLongPress: onLongPress,
          mouseCursor: mouseCursor,
          focusNode: focusNode,
          autofocus: autofocus,
          tooltip: tooltip,
          enableFeedback: enableFeedback,
          constraints: constraints,
          style: style,
          isSelected: isSelected,
          selectedIcon: selectedIcon,
          icon: icon,
        );
      case _IconButtonVariant.filledTonal:
        return IconButton.filledTonal(
          iconSize: iconSize,
          visualDensity: visualDensity,
          padding: padding,
          alignment: alignment,
          splashRadius: splashRadius,
          color: color,
          focusColor: focusColor,
          hoverColor: hoverColor,
          highlightColor: highlightColor,
          splashColor: splashColor,
          disabledColor: disabledColor,
          onPressed: onPressed,
          onHover: onHover,
          onLongPress: onLongPress,
          mouseCursor: mouseCursor,
          focusNode: focusNode,
          autofocus: autofocus,
          tooltip: tooltip,
          enableFeedback: enableFeedback,
          constraints: constraints,
          style: style,
          isSelected: isSelected,
          selectedIcon: selectedIcon,
          icon: icon,
        );
      case _IconButtonVariant.outlined:
        return IconButton.outlined(
          iconSize: iconSize,
          visualDensity: visualDensity,
          padding: padding,
          alignment: alignment,
          splashRadius: splashRadius,
          color: color,
          focusColor: focusColor,
          hoverColor: hoverColor,
          highlightColor: highlightColor,
          splashColor: splashColor,
          disabledColor: disabledColor,
          onPressed: onPressed,
          onHover: onHover,
          onLongPress: onLongPress,
          mouseCursor: mouseCursor,
          focusNode: focusNode,
          autofocus: autofocus,
          tooltip: tooltip,
          enableFeedback: enableFeedback,
          constraints: constraints,
          style: style,
          isSelected: isSelected,
          selectedIcon: selectedIcon,
          icon: icon,
        );
    }
  }

  Widget _buildGlass(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool selected = isSelected ?? false;
    final bool enabled = onPressed != null || onLongPress != null;
    final bool raised =
        _variant != _IconButtonVariant.standard || selected;
    final Set<WidgetState> states = <WidgetState>{
      if (!enabled) WidgetState.disabled,
      if (selected) WidgetState.selected,
    };
    final Color? styleFg = style?.foregroundColor?.resolve(states);
    final Color? styleBg = style?.backgroundColor?.resolve(states);
    Color fg = styleFg ??
        color ??
        switch (_variant) {
          _IconButtonVariant.filled => cs.onPrimary,
          _IconButtonVariant.filledTonal => cs.onSecondaryContainer,
          _ => selected ? cs.primary : cs.onSurfaceVariant,
        };
    if (!enabled) fg = disabledColor ?? cs.onSurface.withValues(alpha: 0.38);
    final Color? tint = styleBg ??
        switch (_variant) {
          _IconButtonVariant.filled => cs.primary,
          _IconButtonVariant.filledTonal => cs.secondaryContainer,
          _ => selected ? cs.secondaryContainer : null,
        };
    final double effectiveIconSize = iconSize ??
        style?.iconSize?.resolve(states) ??
        IconTheme.of(context).size ??
        24;
    final double extent = constraints?.minWidth != null &&
            constraints!.minWidth > 0
        ? constraints!.minWidth
        : (visualDensity == VisualDensity.compact ? 36 : 40);
    Widget button = GlassButton.custom(
      onTap: onPressed ?? () {},
      enabled: enabled,
      style: raised
          ? (_variant == _IconButtonVariant.filled
              ? GlassButtonStyle.prominent
              : GlassButtonStyle.filled)
          : GlassButtonStyle.transparent,
      settings: tint == null ? null : fushiGlassSettings(context, tint: tint),
      quality: fushiGlassQuality(context),
      shape: const LiquidOval(),
      width: extent,
      height: extent,
      focusNode: focusNode,
      autofocus: autofocus,
      label: tooltip ?? '',
      child: IconTheme.merge(
        data: IconThemeData(color: fg, size: effectiveIconSize),
        child: selected && selectedIcon != null ? selectedIcon! : icon,
      ),
    );
    if (onLongPress != null) {
      button = GestureDetector(onLongPress: onLongPress, child: button);
    }
    if (onHover != null) {
      button = MouseRegion(
        onEnter: (_) => onHover!(true),
        onExit: (_) => onHover!(false),
        child: button,
      );
    }
    if (tooltip != null && tooltip!.isNotEmpty) {
      button = Tooltip(message: tooltip, child: button);
    }
    return button;
  }
}
