import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 标签族（Chip / ChoiceChip / FilterChip / ActionChip / InputChip）的「设计系统
// 分派」包装：构造参数与 Material 原控件逐个同名同型（含 `.elevated`），调用点
// 只改类名。MD3 下原样构造原控件；「玻璃」设计系统下渲染 liquid_glass_widgets
// 的 [GlassChip]——它建在 GlassButton 上，自带 GlassFocusRegion（Tab 可达、
// Enter / 手柄 A → ActivateIntent），与全局焦点导航同一条激活链路。
//
// GlassChip 的 label 只收 String：Material 的 label 是 Widget。label 是带
// 文本的 [Text] 时（仓库里的全部调用点）取出文字交给 GlassChip；其它 Widget
// 退到同构的 GlassButton.custom 胶囊（GlassChip 的内部实现），行为一致。
//
// 命名：仓库已有共享组件 `FushiActionChip`（fushi_material_components.dart），
// 所以 ActionChip 的包装叫 [FushiActionChipControl]。

const LiquidShape _chipShape = LiquidRoundedRectangle(borderRadius: 100);

/// 玻璃标签的共用渲染。
///
/// [interactive] 为 false 的是纯展示标签（[Chip] 无删除按钮）：Material 下它
/// 不可聚焦、也不显示禁用态，所以玻璃下用不可交互的 [GlassContainer] 胶囊，
/// 而不是 enabled: false 的按钮（那会半透明成「禁用」）。
Widget _glassChip(
  BuildContext context, {
  required Widget label,
  required bool interactive,
  required bool enabled,
  required VoidCallback? onTap,
  Widget? avatar,
  TextStyle? labelStyle,
  EdgeInsetsGeometry? padding,
  EdgeInsetsGeometry? labelPadding,
  VisualDensity? visualDensity,
  bool selected = false,
  bool showCheckmark = false,
  Color? checkmarkColor,
  Color? selectedColor,
  Color? backgroundColor,
  Color? disabledColor,
  WidgetStateProperty<Color?>? color,
  IconThemeData? iconTheme,
  VoidCallback? onDeleted,
  Widget? deleteIcon,
  Color? deleteIconColor,
  String? deleteButtonTooltipMessage,
  FocusNode? focusNode,
  bool autofocus = false,
  String? tooltip,
}) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme cs = theme.colorScheme;
  final Set<WidgetState> states = <WidgetState>{
    if (selected) WidgetState.selected,
    if (!enabled) WidgetState.disabled,
  };
  final Color? stateFill = color?.resolve(states);
  final Color? tint = selected
      ? null
      : (!enabled ? disabledColor : null) ?? stateFill ?? backgroundColor;
  final Color selectedFill =
      selectedColor ?? (selected ? stateFill : null) ?? cs.secondaryContainer;
  final Color fg = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
  final double iconSize = iconTheme?.size ?? 18;
  final Color iconColor = selected
      ? (checkmarkColor ?? cs.onSecondaryContainer)
      : (iconTheme?.color ?? cs.primary);

  final bool compact =
      visualDensity == VisualDensity.compact ||
      (visualDensity?.vertical ?? 0) < 0;
  final EdgeInsetsGeometry effectivePadding =
      padding ??
      EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 5 : 8);

  final Widget? leading = selected && showCheckmark
      ? Icon(Icons.check, size: iconSize, color: iconColor)
      : avatar;
  final Widget effectiveDeleteIcon =
      deleteIcon ?? Icon(Icons.close, size: iconSize);

  TextStyle textStyle = (theme.textTheme.labelLarge ?? const TextStyle())
      .copyWith(color: fg)
      .merge(labelStyle);
  if (label is Text && label.style != null) {
    textStyle = textStyle.merge(label.style);
  }

  Widget chip;
  final String? text = label is Text ? label.data : null;
  if (!interactive) {
    chip = GlassContainer(
      shape: _chipShape,
      quality: fushiGlassQuality(context),
      settings: tint == null ? null : fushiGlassSettings(context, tint: tint),
      padding: effectivePadding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            IconTheme.merge(
              data: IconThemeData(color: iconColor, size: iconSize),
              child: leading,
            ),
            const SizedBox(width: 6),
          ],
          Padding(
            padding: labelPadding ?? EdgeInsets.zero,
            child: DefaultTextStyle.merge(style: textStyle, child: label),
          ),
        ],
      ),
    );
  } else if (text != null && labelPadding == null) {
    chip = GlassChip(
      label: text,
      icon: leading,
      onTap: enabled ? onTap : null,
      onDeleted: enabled ? onDeleted : null,
      deleteIcon: deleteIconColor == null
          ? effectiveDeleteIcon
          : IconTheme.merge(
              data: IconThemeData(color: deleteIconColor),
              child: effectiveDeleteIcon,
            ),
      deleteIconSize: iconSize,
      iconSize: iconSize,
      iconColor: iconColor,
      labelStyle: textStyle,
      selected: selected,
      selectedColor: selectedFill,
      padding: effectivePadding,
      settings: tint == null ? null : fushiGlassSettings(context, tint: tint),
      quality: fushiGlassQuality(context),
      focusNode: focusNode,
      autofocus: autofocus,
      semanticLabel: text,
    );
  } else {
    Widget content = Padding(
      padding: effectivePadding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            IconTheme.merge(
              data: IconThemeData(color: iconColor, size: iconSize),
              child: leading,
            ),
            const SizedBox(width: 6),
          ],
          Padding(
            padding: labelPadding ?? EdgeInsets.zero,
            child: DefaultTextStyle.merge(style: textStyle, child: label),
          ),
          if (onDeleted != null) ...<Widget>[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: enabled ? onDeleted : null,
              child: IconTheme.merge(
                data: IconThemeData(
                  color: deleteIconColor ?? iconColor,
                  size: iconSize,
                ),
                child: effectiveDeleteIcon,
              ),
            ),
          ],
        ],
      ),
    );
    if (selected) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          color: selectedFill,
          borderRadius: BorderRadius.circular(100),
        ),
        child: content,
      );
    }
    chip = IntrinsicWidth(
      child: IntrinsicHeight(
        child: GlassButton.custom(
          onTap: onTap ?? () {},
          enabled: enabled && (onTap != null || onDeleted != null),
          shape: _chipShape,
          settings: tint == null
              ? null
              : fushiGlassSettings(context, tint: tint),
          quality: fushiGlassQuality(context),
          focusNode: focusNode,
          autofocus: autofocus,
          width: double.infinity,
          height: double.infinity,
          child: content,
        ),
      ),
    );
  }
  if (tooltip != null && tooltip.isNotEmpty) {
    chip = FushiTooltip(message: tooltip, child: chip);
  }
  return chip;
}

/// [Chip] 的设计系统分派版。
class FushiChip extends StatelessWidget {
  const FushiChip({
    super.key,
    this.avatar,
    required this.label,
    this.labelStyle,
    this.labelPadding,
    this.deleteIcon,
    this.onDeleted,
    this.deleteIconColor,
    this.deleteButtonTooltipMessage,
    this.side,
    this.shape,
    this.clipBehavior = Clip.none,
    this.focusNode,
    this.autofocus = false,
    this.color,
    this.backgroundColor,
    this.padding,
    this.visualDensity,
    this.materialTapTargetSize,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.iconTheme,
    this.avatarBoxConstraints,
    this.deleteIconBoxConstraints,
    this.chipAnimationStyle,
    this.mouseCursor,
  });

  final Widget? avatar;
  final Widget label;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? labelPadding;
  final Widget? deleteIcon;
  final VoidCallback? onDeleted;
  final Color? deleteIconColor;
  final String? deleteButtonTooltipMessage;
  final BorderSide? side;
  final OutlinedBorder? shape;
  final Clip clipBehavior;
  final FocusNode? focusNode;
  final bool autofocus;
  final WidgetStateProperty<Color?>? color;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  final VisualDensity? visualDensity;
  final MaterialTapTargetSize? materialTapTargetSize;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final IconThemeData? iconTheme;
  final BoxConstraints? avatarBoxConstraints;
  final BoxConstraints? deleteIconBoxConstraints;
  final ChipAnimationStyle? chipAnimationStyle;
  final MouseCursor? mouseCursor;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return _glassChip(
        context,
        label: label,
        interactive: onDeleted != null,
        enabled: true,
        onTap: null,
        avatar: avatar,
        labelStyle: labelStyle,
        padding: padding,
        labelPadding: labelPadding,
        visualDensity: visualDensity,
        backgroundColor: backgroundColor,
        color: color,
        iconTheme: iconTheme,
        onDeleted: onDeleted,
        deleteIcon: deleteIcon,
        deleteIconColor: deleteIconColor,
        deleteButtonTooltipMessage: deleteButtonTooltipMessage,
        focusNode: focusNode,
        autofocus: autofocus,
      );
    }
    return Chip(
      avatar: avatar,
      label: label,
      labelStyle: labelStyle,
      labelPadding: labelPadding,
      deleteIcon: deleteIcon,
      onDeleted: onDeleted,
      deleteIconColor: deleteIconColor,
      deleteButtonTooltipMessage: deleteButtonTooltipMessage,
      side: side,
      shape: shape,
      clipBehavior: clipBehavior,
      focusNode: focusNode,
      autofocus: autofocus,
      color: color,
      backgroundColor: backgroundColor,
      padding: padding,
      visualDensity: visualDensity,
      materialTapTargetSize: materialTapTargetSize,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      iconTheme: iconTheme,
      avatarBoxConstraints: avatarBoxConstraints,
      deleteIconBoxConstraints: deleteIconBoxConstraints,
      chipAnimationStyle: chipAnimationStyle,
      mouseCursor: mouseCursor,
    );
  }
}

/// [ChoiceChip] 的设计系统分派版（含 `.elevated`）。
class FushiChoiceChip extends StatelessWidget {
  const FushiChoiceChip({
    super.key,
    this.avatar,
    required this.label,
    this.labelStyle,
    this.labelPadding,
    this.onSelected,
    this.pressElevation,
    required this.selected,
    this.selectedColor,
    this.disabledColor,
    this.tooltip,
    this.side,
    this.shape,
    this.clipBehavior = Clip.none,
    this.focusNode,
    this.autofocus = false,
    this.color,
    this.backgroundColor,
    this.padding,
    this.visualDensity,
    this.materialTapTargetSize,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.iconTheme,
    this.selectedShadowColor,
    this.showCheckmark,
    this.checkmarkColor,
    this.avatarBorder = const CircleBorder(),
    this.avatarBoxConstraints,
    this.chipAnimationStyle,
    this.mouseCursor,
  }) : _elevated = false;

  const FushiChoiceChip.elevated({
    super.key,
    this.avatar,
    required this.label,
    this.labelStyle,
    this.labelPadding,
    this.onSelected,
    this.pressElevation,
    required this.selected,
    this.selectedColor,
    this.disabledColor,
    this.tooltip,
    this.side,
    this.shape,
    this.clipBehavior = Clip.none,
    this.focusNode,
    this.autofocus = false,
    this.color,
    this.backgroundColor,
    this.padding,
    this.visualDensity,
    this.materialTapTargetSize,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.iconTheme,
    this.selectedShadowColor,
    this.showCheckmark,
    this.checkmarkColor,
    this.avatarBorder = const CircleBorder(),
    this.avatarBoxConstraints,
    this.chipAnimationStyle,
    this.mouseCursor,
  }) : _elevated = true;

  final Widget? avatar;
  final Widget label;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? labelPadding;
  final ValueChanged<bool>? onSelected;
  final double? pressElevation;
  final bool selected;
  final Color? selectedColor;
  final Color? disabledColor;
  final String? tooltip;
  final BorderSide? side;
  final OutlinedBorder? shape;
  final Clip clipBehavior;
  final FocusNode? focusNode;
  final bool autofocus;
  final WidgetStateProperty<Color?>? color;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  final VisualDensity? visualDensity;
  final MaterialTapTargetSize? materialTapTargetSize;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final IconThemeData? iconTheme;
  final Color? selectedShadowColor;
  final bool? showCheckmark;
  final Color? checkmarkColor;
  final ShapeBorder avatarBorder;
  final BoxConstraints? avatarBoxConstraints;
  final ChipAnimationStyle? chipAnimationStyle;
  final MouseCursor? mouseCursor;
  final bool _elevated;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      final ValueChanged<bool>? select = onSelected;
      return _glassChip(
        context,
        label: label,
        interactive: true,
        enabled: select != null,
        onTap: select == null ? null : () => select(!selected),
        avatar: avatar,
        labelStyle: labelStyle,
        padding: padding,
        labelPadding: labelPadding,
        visualDensity: visualDensity,
        selected: selected,
        // M3 的 ChoiceChip 默认选中时显示对勾。
        showCheckmark: showCheckmark ?? true,
        checkmarkColor: checkmarkColor,
        selectedColor: selectedColor,
        backgroundColor: backgroundColor,
        disabledColor: disabledColor,
        color: color,
        iconTheme: iconTheme,
        focusNode: focusNode,
        autofocus: autofocus,
        tooltip: tooltip,
      );
    }
    if (_elevated) {
      return ChoiceChip.elevated(
        avatar: avatar,
        label: label,
        labelStyle: labelStyle,
        labelPadding: labelPadding,
        onSelected: onSelected,
        pressElevation: pressElevation,
        selected: selected,
        selectedColor: selectedColor,
        disabledColor: disabledColor,
        tooltip: tooltip,
        side: side,
        shape: shape,
        clipBehavior: clipBehavior,
        focusNode: focusNode,
        autofocus: autofocus,
        color: color,
        backgroundColor: backgroundColor,
        padding: padding,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        iconTheme: iconTheme,
        selectedShadowColor: selectedShadowColor,
        showCheckmark: showCheckmark,
        checkmarkColor: checkmarkColor,
        avatarBorder: avatarBorder,
        avatarBoxConstraints: avatarBoxConstraints,
        chipAnimationStyle: chipAnimationStyle,
        mouseCursor: mouseCursor,
      );
    }
    return ChoiceChip(
      avatar: avatar,
      label: label,
      labelStyle: labelStyle,
      labelPadding: labelPadding,
      onSelected: onSelected,
      pressElevation: pressElevation,
      selected: selected,
      selectedColor: selectedColor,
      disabledColor: disabledColor,
      tooltip: tooltip,
      side: side,
      shape: shape,
      clipBehavior: clipBehavior,
      focusNode: focusNode,
      autofocus: autofocus,
      color: color,
      backgroundColor: backgroundColor,
      padding: padding,
      visualDensity: visualDensity,
      materialTapTargetSize: materialTapTargetSize,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      iconTheme: iconTheme,
      selectedShadowColor: selectedShadowColor,
      showCheckmark: showCheckmark,
      checkmarkColor: checkmarkColor,
      avatarBorder: avatarBorder,
      avatarBoxConstraints: avatarBoxConstraints,
      chipAnimationStyle: chipAnimationStyle,
      mouseCursor: mouseCursor,
    );
  }
}

/// [FilterChip] 的设计系统分派版（含 `.elevated`）。
class FushiFilterChip extends StatelessWidget {
  const FushiFilterChip({
    super.key,
    this.avatar,
    required this.label,
    this.labelStyle,
    this.labelPadding,
    this.selected = false,
    required this.onSelected,
    this.deleteIcon,
    this.onDeleted,
    this.deleteIconColor,
    this.deleteButtonTooltipMessage,
    this.pressElevation,
    this.disabledColor,
    this.selectedColor,
    this.tooltip,
    this.side,
    this.shape,
    this.clipBehavior = Clip.none,
    this.focusNode,
    this.autofocus = false,
    this.color,
    this.backgroundColor,
    this.padding,
    this.visualDensity,
    this.materialTapTargetSize,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.iconTheme,
    this.selectedShadowColor,
    this.showCheckmark,
    this.checkmarkColor,
    this.avatarBorder = const CircleBorder(),
    this.avatarBoxConstraints,
    this.deleteIconBoxConstraints,
    this.chipAnimationStyle,
    this.mouseCursor,
  }) : _elevated = false;

  const FushiFilterChip.elevated({
    super.key,
    this.avatar,
    required this.label,
    this.labelStyle,
    this.labelPadding,
    this.selected = false,
    required this.onSelected,
    this.deleteIcon,
    this.onDeleted,
    this.deleteIconColor,
    this.deleteButtonTooltipMessage,
    this.pressElevation,
    this.disabledColor,
    this.selectedColor,
    this.tooltip,
    this.side,
    this.shape,
    this.clipBehavior = Clip.none,
    this.focusNode,
    this.autofocus = false,
    this.color,
    this.backgroundColor,
    this.padding,
    this.visualDensity,
    this.materialTapTargetSize,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.iconTheme,
    this.selectedShadowColor,
    this.showCheckmark,
    this.checkmarkColor,
    this.avatarBorder = const CircleBorder(),
    this.avatarBoxConstraints,
    this.deleteIconBoxConstraints,
    this.chipAnimationStyle,
    this.mouseCursor,
  }) : _elevated = true;

  final Widget? avatar;
  final Widget label;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? labelPadding;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final Widget? deleteIcon;
  final VoidCallback? onDeleted;
  final Color? deleteIconColor;
  final String? deleteButtonTooltipMessage;
  final double? pressElevation;
  final Color? disabledColor;
  final Color? selectedColor;
  final String? tooltip;
  final BorderSide? side;
  final OutlinedBorder? shape;
  final Clip clipBehavior;
  final FocusNode? focusNode;
  final bool autofocus;
  final WidgetStateProperty<Color?>? color;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  final VisualDensity? visualDensity;
  final MaterialTapTargetSize? materialTapTargetSize;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final IconThemeData? iconTheme;
  final Color? selectedShadowColor;
  final bool? showCheckmark;
  final Color? checkmarkColor;
  final ShapeBorder avatarBorder;
  final BoxConstraints? avatarBoxConstraints;
  final BoxConstraints? deleteIconBoxConstraints;
  final ChipAnimationStyle? chipAnimationStyle;
  final MouseCursor? mouseCursor;
  final bool _elevated;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      final ValueChanged<bool>? select = onSelected;
      return _glassChip(
        context,
        label: label,
        interactive: true,
        enabled: select != null,
        onTap: select == null ? null : () => select(!selected),
        avatar: avatar,
        labelStyle: labelStyle,
        padding: padding,
        labelPadding: labelPadding,
        visualDensity: visualDensity,
        selected: selected,
        showCheckmark: showCheckmark ?? true,
        checkmarkColor: checkmarkColor,
        selectedColor: selectedColor,
        backgroundColor: backgroundColor,
        disabledColor: disabledColor,
        color: color,
        iconTheme: iconTheme,
        onDeleted: onDeleted,
        deleteIcon: deleteIcon,
        deleteIconColor: deleteIconColor,
        deleteButtonTooltipMessage: deleteButtonTooltipMessage,
        focusNode: focusNode,
        autofocus: autofocus,
        tooltip: tooltip,
      );
    }
    if (_elevated) {
      return FilterChip.elevated(
        avatar: avatar,
        label: label,
        labelStyle: labelStyle,
        labelPadding: labelPadding,
        selected: selected,
        onSelected: onSelected,
        deleteIcon: deleteIcon,
        onDeleted: onDeleted,
        deleteIconColor: deleteIconColor,
        deleteButtonTooltipMessage: deleteButtonTooltipMessage,
        pressElevation: pressElevation,
        disabledColor: disabledColor,
        selectedColor: selectedColor,
        tooltip: tooltip,
        side: side,
        shape: shape,
        clipBehavior: clipBehavior,
        focusNode: focusNode,
        autofocus: autofocus,
        color: color,
        backgroundColor: backgroundColor,
        padding: padding,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        iconTheme: iconTheme,
        selectedShadowColor: selectedShadowColor,
        showCheckmark: showCheckmark,
        checkmarkColor: checkmarkColor,
        avatarBorder: avatarBorder,
        avatarBoxConstraints: avatarBoxConstraints,
        deleteIconBoxConstraints: deleteIconBoxConstraints,
        chipAnimationStyle: chipAnimationStyle,
        mouseCursor: mouseCursor,
      );
    }
    return FilterChip(
      avatar: avatar,
      label: label,
      labelStyle: labelStyle,
      labelPadding: labelPadding,
      selected: selected,
      onSelected: onSelected,
      deleteIcon: deleteIcon,
      onDeleted: onDeleted,
      deleteIconColor: deleteIconColor,
      deleteButtonTooltipMessage: deleteButtonTooltipMessage,
      pressElevation: pressElevation,
      disabledColor: disabledColor,
      selectedColor: selectedColor,
      tooltip: tooltip,
      side: side,
      shape: shape,
      clipBehavior: clipBehavior,
      focusNode: focusNode,
      autofocus: autofocus,
      color: color,
      backgroundColor: backgroundColor,
      padding: padding,
      visualDensity: visualDensity,
      materialTapTargetSize: materialTapTargetSize,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      iconTheme: iconTheme,
      selectedShadowColor: selectedShadowColor,
      showCheckmark: showCheckmark,
      checkmarkColor: checkmarkColor,
      avatarBorder: avatarBorder,
      avatarBoxConstraints: avatarBoxConstraints,
      deleteIconBoxConstraints: deleteIconBoxConstraints,
      chipAnimationStyle: chipAnimationStyle,
      mouseCursor: mouseCursor,
    );
  }
}

/// [ActionChip] 的设计系统分派版（含 `.elevated`）。仓库已有共享组件
/// `FushiActionChip`，故名 `FushiActionChipControl`。
class FushiActionChipControl extends StatelessWidget {
  const FushiActionChipControl({
    super.key,
    this.avatar,
    required this.label,
    this.labelStyle,
    this.labelPadding,
    this.onPressed,
    this.pressElevation,
    this.tooltip,
    this.side,
    this.shape,
    this.clipBehavior = Clip.none,
    this.focusNode,
    this.autofocus = false,
    this.color,
    this.backgroundColor,
    this.disabledColor,
    this.padding,
    this.visualDensity,
    this.materialTapTargetSize,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.iconTheme,
    this.avatarBoxConstraints,
    this.chipAnimationStyle,
    this.mouseCursor,
  }) : _elevated = false;

  const FushiActionChipControl.elevated({
    super.key,
    this.avatar,
    required this.label,
    this.labelStyle,
    this.labelPadding,
    this.onPressed,
    this.pressElevation,
    this.tooltip,
    this.side,
    this.shape,
    this.clipBehavior = Clip.none,
    this.focusNode,
    this.autofocus = false,
    this.color,
    this.backgroundColor,
    this.disabledColor,
    this.padding,
    this.visualDensity,
    this.materialTapTargetSize,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.iconTheme,
    this.avatarBoxConstraints,
    this.chipAnimationStyle,
    this.mouseCursor,
  }) : _elevated = true;

  final Widget? avatar;
  final Widget label;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? labelPadding;
  final VoidCallback? onPressed;
  final double? pressElevation;
  final String? tooltip;
  final BorderSide? side;
  final OutlinedBorder? shape;
  final Clip clipBehavior;
  final FocusNode? focusNode;
  final bool autofocus;
  final WidgetStateProperty<Color?>? color;
  final Color? backgroundColor;
  final Color? disabledColor;
  final EdgeInsetsGeometry? padding;
  final VisualDensity? visualDensity;
  final MaterialTapTargetSize? materialTapTargetSize;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final IconThemeData? iconTheme;
  final BoxConstraints? avatarBoxConstraints;
  final ChipAnimationStyle? chipAnimationStyle;
  final MouseCursor? mouseCursor;
  final bool _elevated;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return _glassChip(
        context,
        label: label,
        interactive: true,
        enabled: onPressed != null,
        onTap: onPressed,
        avatar: avatar,
        labelStyle: labelStyle,
        padding: padding,
        labelPadding: labelPadding,
        visualDensity: visualDensity,
        backgroundColor: backgroundColor,
        disabledColor: disabledColor,
        color: color,
        iconTheme: iconTheme,
        focusNode: focusNode,
        autofocus: autofocus,
        tooltip: tooltip,
      );
    }
    if (_elevated) {
      return ActionChip.elevated(
        avatar: avatar,
        label: label,
        labelStyle: labelStyle,
        labelPadding: labelPadding,
        onPressed: onPressed,
        pressElevation: pressElevation,
        tooltip: tooltip,
        side: side,
        shape: shape,
        clipBehavior: clipBehavior,
        focusNode: focusNode,
        autofocus: autofocus,
        color: color,
        backgroundColor: backgroundColor,
        disabledColor: disabledColor,
        padding: padding,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        iconTheme: iconTheme,
        avatarBoxConstraints: avatarBoxConstraints,
        chipAnimationStyle: chipAnimationStyle,
        mouseCursor: mouseCursor,
      );
    }
    return ActionChip(
      avatar: avatar,
      label: label,
      labelStyle: labelStyle,
      labelPadding: labelPadding,
      onPressed: onPressed,
      pressElevation: pressElevation,
      tooltip: tooltip,
      side: side,
      shape: shape,
      clipBehavior: clipBehavior,
      focusNode: focusNode,
      autofocus: autofocus,
      color: color,
      backgroundColor: backgroundColor,
      disabledColor: disabledColor,
      padding: padding,
      visualDensity: visualDensity,
      materialTapTargetSize: materialTapTargetSize,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      iconTheme: iconTheme,
      avatarBoxConstraints: avatarBoxConstraints,
      chipAnimationStyle: chipAnimationStyle,
      mouseCursor: mouseCursor,
    );
  }
}

/// [InputChip] 的设计系统分派版。
class FushiInputChip extends StatelessWidget {
  const FushiInputChip({
    super.key,
    this.avatar,
    required this.label,
    this.labelStyle,
    this.labelPadding,
    this.selected = false,
    this.isEnabled = true,
    this.onSelected,
    this.deleteIcon,
    this.onDeleted,
    this.deleteIconColor,
    this.deleteButtonTooltipMessage,
    this.onPressed,
    this.pressElevation,
    this.disabledColor,
    this.selectedColor,
    this.tooltip,
    this.side,
    this.shape,
    this.clipBehavior = Clip.none,
    this.focusNode,
    this.autofocus = false,
    this.color,
    this.backgroundColor,
    this.padding,
    this.visualDensity,
    this.materialTapTargetSize,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.iconTheme,
    this.selectedShadowColor,
    this.showCheckmark,
    this.checkmarkColor,
    this.avatarBorder = const CircleBorder(),
    this.avatarBoxConstraints,
    this.deleteIconBoxConstraints,
    this.chipAnimationStyle,
    this.mouseCursor,
  });

  final Widget? avatar;
  final Widget label;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? labelPadding;
  final bool selected;
  final bool isEnabled;
  final ValueChanged<bool>? onSelected;
  final Widget? deleteIcon;
  final VoidCallback? onDeleted;
  final Color? deleteIconColor;
  final String? deleteButtonTooltipMessage;
  final VoidCallback? onPressed;
  final double? pressElevation;
  final Color? disabledColor;
  final Color? selectedColor;
  final String? tooltip;
  final BorderSide? side;
  final OutlinedBorder? shape;
  final Clip clipBehavior;
  final FocusNode? focusNode;
  final bool autofocus;
  final WidgetStateProperty<Color?>? color;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  final VisualDensity? visualDensity;
  final MaterialTapTargetSize? materialTapTargetSize;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final IconThemeData? iconTheme;
  final Color? selectedShadowColor;
  final bool? showCheckmark;
  final Color? checkmarkColor;
  final ShapeBorder avatarBorder;
  final BoxConstraints? avatarBoxConstraints;
  final BoxConstraints? deleteIconBoxConstraints;
  final ChipAnimationStyle? chipAnimationStyle;
  final MouseCursor? mouseCursor;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      // 与 RawChip 同序：先切换选中，再回调 onPressed。
      final bool tappable =
          isEnabled && (onSelected != null || onPressed != null);
      return _glassChip(
        context,
        label: label,
        interactive: true,
        enabled:
            isEnabled &&
            (onSelected != null || onPressed != null || onDeleted != null),
        onTap: !tappable
            ? null
            : () {
                onSelected?.call(!selected);
                onPressed?.call();
              },
        avatar: avatar,
        labelStyle: labelStyle,
        padding: padding,
        labelPadding: labelPadding,
        visualDensity: visualDensity,
        selected: selected,
        showCheckmark: showCheckmark ?? true,
        checkmarkColor: checkmarkColor,
        selectedColor: selectedColor,
        backgroundColor: backgroundColor,
        disabledColor: disabledColor,
        color: color,
        iconTheme: iconTheme,
        onDeleted: onDeleted,
        deleteIcon: deleteIcon,
        deleteIconColor: deleteIconColor,
        deleteButtonTooltipMessage: deleteButtonTooltipMessage,
        focusNode: focusNode,
        autofocus: autofocus,
        tooltip: tooltip,
      );
    }
    return InputChip(
      avatar: avatar,
      label: label,
      labelStyle: labelStyle,
      labelPadding: labelPadding,
      selected: selected,
      isEnabled: isEnabled,
      onSelected: onSelected,
      deleteIcon: deleteIcon,
      onDeleted: onDeleted,
      deleteIconColor: deleteIconColor,
      deleteButtonTooltipMessage: deleteButtonTooltipMessage,
      onPressed: onPressed,
      pressElevation: pressElevation,
      disabledColor: disabledColor,
      selectedColor: selectedColor,
      tooltip: tooltip,
      side: side,
      shape: shape,
      clipBehavior: clipBehavior,
      focusNode: focusNode,
      autofocus: autofocus,
      color: color,
      backgroundColor: backgroundColor,
      padding: padding,
      visualDensity: visualDensity,
      materialTapTargetSize: materialTapTargetSize,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      iconTheme: iconTheme,
      selectedShadowColor: selectedShadowColor,
      showCheckmark: showCheckmark,
      checkmarkColor: checkmarkColor,
      avatarBorder: avatarBorder,
      avatarBoxConstraints: avatarBoxConstraints,
      deleteIconBoxConstraints: deleteIconBoxConstraints,
      chipAnimationStyle: chipAnimationStyle,
      mouseCursor: mouseCursor,
    );
  }
}
