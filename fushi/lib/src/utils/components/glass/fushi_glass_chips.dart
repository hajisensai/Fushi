import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

// 标签族（Chip / ChoiceChip / FilterChip / ActionChip / InputChip）的「设计系统
// 分派」包装：构造参数与 Material 原控件逐个同名同型（含 `.elevated`），调用点
// 只改类名。MD3 下原样构造原控件；「玻璃」设计系统下渲染 iOS 26 的胶囊标签。
//
// iOS 26 的标签是**内容层控件，不是玻璃**（Apple 26：玻璃只给浮在内容上的
// 导航与控件层）：未选中 = systemFill 中性填充 + label 色文字，选中 = 强调色
// 实底 + 白字，高 32（桌面 28），全胶囊、无描边。可交互的标签自带焦点节点
// （Tab 可达、Enter / 手柄 A → ActivateIntent），与全局焦点导航同一条激活链路。
//
// 命名：仓库已有共享组件 `FushiActionChip`（fushi_material_components.dart），
// 所以 ActionChip 的包装叫 [FushiActionChipControl]。

/// 玻璃设计系统的标签渲染。
///
/// [interactive] 为 false 的是纯展示标签（[Chip] 无删除按钮）：Material 下它
/// 不可聚焦、也不显示禁用态，这里同样只画胶囊、不进焦点链。
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
  final FushiAppleColors apple = appleColorsOf(context);
  final bool compact =
      fushiAppleCompact(context) ||
      visualDensity == VisualDensity.compact ||
      (visualDensity?.vertical ?? 0) < 0;
  final Set<WidgetState> states = <WidgetState>{
    if (selected) WidgetState.selected,
    if (!enabled) WidgetState.disabled,
  };
  final Color? stateFill = color?.resolve(states);
  final Color fill = selected
      ? (selectedColor ?? stateFill ?? apple.accent)
      : ((!enabled ? disabledColor : null) ??
            stateFill ??
            backgroundColor ??
            apple.fill);
  // 选中的实底上文字按底色亮度取白 / 黑（默认强调色底恒为白字）；未选中是
  // label 色。
  final Color fg = selected
      ? (fill.a > 0.5 &&
                ThemeData.estimateBrightnessForColor(fill) == Brightness.light
            ? Colors.black
            : Colors.white)
      : apple.label;
  final double iconSize = iconTheme?.size ?? (compact ? 14 : 16);
  final Color iconColor = selected
      ? (checkmarkColor ?? fg)
      : (iconTheme?.color ?? apple.secondaryLabel);

  final double height = compact ? 28 : 32;
  final EdgeInsetsGeometry effectivePadding =
      padding ?? EdgeInsets.symmetric(horizontal: compact ? 10 : 12);

  final Widget? leading = selected && showCheckmark
      ? FushiIcon(CupertinoIcons.checkmark, size: iconSize, color: iconColor)
      : avatar;
  final Widget effectiveDeleteIcon =
      deleteIcon ?? FushiIcon(CupertinoIcons.xmark_circle_fill, size: iconSize);

  TextStyle textStyle = (theme.textTheme.labelLarge ?? const TextStyle())
      .copyWith(
        fontSize: compact ? 13 : 15,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      )
      .merge(labelStyle)
      .copyWith(color: fg);
  if (label is Text && label.style != null) {
    textStyle = textStyle.merge(label.style);
  }

  final Widget content = Padding(
    padding: effectivePadding,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (leading != null) ...<Widget>[
          IconTheme.merge(
            data: IconThemeData(color: iconColor, size: iconSize),
            child: leading,
          ),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Padding(
            padding: labelPadding ?? EdgeInsets.zero,
            child: DefaultTextStyle.merge(
              style: textStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: label,
            ),
          ),
        ),
        if (onDeleted != null) ...<Widget>[
          const SizedBox(width: 4),
          Semantics(
            button: true,
            label: deleteButtonTooltipMessage,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: enabled ? onDeleted : null,
              child: IconTheme.merge(
                data: IconThemeData(
                  color:
                      deleteIconColor ?? (selected ? fg : apple.tertiaryLabel),
                  size: iconSize + 2,
                ),
                child: effectiveDeleteIcon,
              ),
            ),
          ),
        ],
      ],
    ),
  );

  Widget chip = _AppleChip(
    interactive: interactive,
    enabled: enabled,
    onTap: onTap,
    focusNode: focusNode,
    autofocus: autofocus,
    fill: fill,
    height: height,
    child: content,
  );
  if (tooltip != null && tooltip.isNotEmpty) {
    chip = FushiTooltip(message: tooltip, child: chip);
  }
  return chip;
}

/// iOS 26 胶囊标签本体：实色填充、全圆角、按下变淡；可交互时带焦点节点
/// （键盘焦点画一圈强调色焦点环）并把 [ActivateIntent] 接到 [onTap]。
class _AppleChip extends StatefulWidget {
  const _AppleChip({
    required this.interactive,
    required this.enabled,
    required this.onTap,
    required this.focusNode,
    required this.autofocus,
    required this.fill,
    required this.height,
    required this.child,
  });

  final bool interactive;
  final bool enabled;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color fill;
  final double height;
  final Widget child;

  @override
  State<_AppleChip> createState() => _AppleChipState();
}

class _AppleChipState extends State<_AppleChip> {
  bool _pressed = false;
  bool _focusHighlight = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final BorderRadius radius = BorderRadius.circular(widget.height / 2);
    Widget pill = ConstrainedBox(
      constraints: BoxConstraints(minHeight: widget.height),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.fill,
          borderRadius: radius,
          border: _focusHighlight
              ? Border.all(color: apple.accent, width: 2)
              : null,
        ),
        child: Center(widthFactor: 1, heightFactor: 1, child: widget.child),
      ),
    );
    pill = AnimatedOpacity(
      duration: _pressed ? Duration.zero : const Duration(milliseconds: 160),
      opacity: !widget.enabled && widget.interactive
          ? 0.4
          : (_pressed ? 0.6 : 1),
      child: pill,
    );
    if (!widget.interactive) return pill;
    final bool tappable = widget.enabled && widget.onTap != null;
    return FocusableActionDetector(
      enabled: widget.enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: tappable ? SystemMouseCursors.click : MouseCursor.defer,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            if (tappable) widget.onTap!();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (bool value) {
        setState(() => _focusHighlight = value);
      },
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: tappable ? (_) => _setPressed(true) : null,
          onTapUp: tappable ? (_) => _setPressed(false) : null,
          onTapCancel: tappable ? () => _setPressed(false) : null,
          onTap: tappable ? widget.onTap : null,
          child: pill,
        ),
      ),
    );
  }
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
        // iOS 的单选胶囊靠强调色实底表达选中，默认不画对勾（M3 默认画）。
        showCheckmark: showCheckmark ?? false,
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
