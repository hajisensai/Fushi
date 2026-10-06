import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassButton, GlassButtonStyle, LiquidRoundedRectangle;

// 标签族（Chip / ChoiceChip / FilterChip / ActionChip / InputChip）的「设计系统
// 分派」包装：构造参数与 Material 原控件逐个同名同型（含 `.elevated`），调用点
// 只改类名。MD3 下构造原控件，外观由全局 chipTheme 统一（全胶囊、高 32、未选中
// surfaceContainerHigh 无描边、选中 secondaryContainer，FilterChip 带对勾）；
// 「玻璃」设计系统下渲染 iOS 26 的胶囊标签。
//
// 可交互标签是液态玻璃胶囊（用户 2026-10-04：「所有组件都要往液态玻璃靠」）：
// 未选中 = 透明玻璃 + label 色文字，选中 = 强调色着色玻璃 + 反色字，高 32
// （桌面 28），全胶囊、库的按压拉伸；系统降低透明度时回落实色胶囊
// （systemFill / 强调色实底）。纯展示标签恒为实色灰胶囊。可交互的标签自带焦点节点
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
  bool focusable = true,
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

  // 可交互的标签是液态玻璃胶囊（用户 2026-10-04：「所有组件都要往液态玻璃
  // 靠」）：未选中 = 透明玻璃，选中 = 强调色着色玻璃；系统降低透明度（材质
  // off）时回落实色胶囊。纯展示标签恒为实色灰胶囊。
  final bool glass =
      interactive && glassMaterialOf(context) != FushiGlassMaterial.off;
  final bool customUnselected =
      !selected && (stateFill != null || backgroundColor != null);
  Widget chip = _AppleChip(
    interactive: interactive,
    glass: glass,
    glassTint: selected || customUnselected ? fill : null,
    enabled: enabled,
    selected: selected,
    onTap: onTap,
    focusNode: focusNode,
    autofocus: autofocus,
    focusable: focusable,
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
    this.focusable = true,
    this.glass = false,
    this.glassTint,
    this.selected = false,
  });

  final bool interactive;

  /// 选中态（ChoiceChip / FilterChip）：只进语义（读屏「已选中」），外观由
  /// [fill] / [glassTint] 表达。
  final bool selected;

  /// true：画成液态玻璃胶囊（库的 [GlassButton]，带按压拉伸），而不是实色
  /// [fill] 胶囊。
  final bool glass;

  /// 玻璃的着色（选中 = 强调色）；null = 透明玻璃。
  final Color? glassTint;

  /// false：可点但不自带焦点节点——外层已经有焦点目标（共享 chip 在
  /// FushiFocusRoot 里由 FushiFocusTarget 接管焦点与 ActivateIntent），再带一个
  /// 会让 Tab 在同一枚 chip 上停两次。
  final bool focusable;
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
    if (widget.glass && widget.interactive) return _buildGlass(context, apple);
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
    final Widget gesture = Semantics(
      button: true,
      selected: widget.selected,
      enabled: widget.enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: tappable ? (_) => _setPressed(true) : null,
        onTapUp: tappable ? (_) => _setPressed(false) : null,
        onTapCancel: tappable ? () => _setPressed(false) : null,
        onTap: tappable ? widget.onTap : null,
        child: pill,
      ),
    );
    if (!widget.focusable) {
      return MouseRegion(
        cursor: tappable ? SystemMouseCursors.click : MouseCursor.defer,
        child: gesture,
      );
    }
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
      child: gesture,
    );
  }

  /// 液态玻璃形态：外形、按压拉伸与高光交给库的 [GlassButton]（与 GlassChip
  /// 同参：胶囊、interactionScale 1.03、stretch 0.3）；焦点与 [ActivateIntent]
  /// 仍由外层 FocusableActionDetector 接（GlassButton 自己不取焦点），键盘焦点
  /// 画一圈强调色描边。
  Widget _buildGlass(BuildContext context, FushiAppleColors apple) {
    final bool tappable = widget.enabled && widget.onTap != null;
    final BorderRadius radius = BorderRadius.circular(widget.height / 2);
    // GlassButton 的 canRequestFocus: false 不生效：库内 GlassFocusRegion 用
    // FocusableActionDetector 包自己的节点，而 FocusableActionDetector 会按
    // enabled 改写 Focus.canRequestFocus，每枚标签因此多出一个 Tab 停靠点（Tab
    // 落到内层后 Enter 不经外层 ActivateIntent）。焦点只归外层，内层整树排除。
    Widget body = IntrinsicWidth(
      child: IntrinsicHeight(
        child: ExcludeFocus(
          child: GlassButton.custom(
            onTap: tappable ? widget.onTap! : () {},
            enabled: widget.enabled,
            style: widget.glassTint != null
                ? GlassButtonStyle.prominent
                : GlassButtonStyle.filled,
            settings: fushiGlassSettings(context, tint: widget.glassTint),
            quality: fushiGlassQuality(context),
            shape: const LiquidRoundedRectangle(borderRadius: 100),
            interactionScale: 1.03,
            stretch: 0.3,
            canRequestFocus: false,
            excludeFromSemantics: true,
            width: double.infinity,
            height: double.infinity,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.height),
              child: Center(widthFactor: 1, heightFactor: 1, child: widget.child),
            ),
          ),
        ),
      ),
    );
    body = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: _focusHighlight
            ? Border.all(color: apple.accent, width: 2)
            : null,
      ),
      child: body,
    );
    body = Opacity(opacity: widget.enabled ? 1 : 0.4, child: body);
    // GlassButton 排除了自己的语义，读屏的 tap 由这里直接接到 onTap。
    body = Semantics(
      button: true,
      selected: widget.selected,
      enabled: widget.enabled,
      onTap: tappable ? widget.onTap : null,
      child: body,
    );
    if (!widget.focusable) return body;
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
      child: body,
    );
  }
}

/// 共享 chip（`fushi_material_components.dart` 的 FushiSelectableChip /
/// FushiActionChip / FushiTagChip）在 Apple 设计系统下的渲染入口：与
/// [FushiChoiceChip] 等包装同一枚胶囊（可交互时是液态玻璃：未选中透明玻璃 +
/// label 字，选中强调色着色玻璃 + 反色字，高 32 / 桌面 28；降低透明度时回落
/// 实色胶囊）。
///
/// [onTap] 与 [onDeleted] 都为 null 时是纯展示标签（不进焦点链、不显禁用态）。
/// [focusable] 为 false 时不自带焦点节点（调用方外层已有焦点目标）。
Widget fushiAppleChip(
  BuildContext context, {
  required Widget label,
  required VoidCallback? onTap,
  bool selected = false,
  Widget? avatar,
  Color? selectedColor,
  Color? backgroundColor,
  IconThemeData? iconTheme,
  VoidCallback? onDeleted,
  String? tooltip,
  bool focusable = true,
}) {
  return _glassChip(
    context,
    label: label,
    interactive: onTap != null || onDeleted != null,
    enabled: true,
    onTap: onTap,
    avatar: avatar,
    selected: selected,
    selectedColor: selectedColor,
    backgroundColor: backgroundColor,
    iconTheme: iconTheme,
    onDeleted: onDeleted,
    tooltip: tooltip,
    focusable: focusable,
  );
}

/// [Chip] 的设计系统分派版。
class FushiChip extends StatelessWidget implements FushiShapedMenuTrigger {
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

  /// 作菜单触发器时的可视形状：[shape] / chipTheme 的 shape，缺省 MD3 胶囊。
  @override
  ShapeBorder menuTriggerShape(BuildContext context) =>
      shape ?? ChipTheme.of(context).shape ?? const StadiumBorder();

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

/// MD3 / M3E 选中 chip 的前导槽：前导图标 ↔ 对勾原位交叉变形。
///
/// Flutter 的 RawChip 在「有 avatar 且 showCheckmark」时，选中会先按
/// avatarBorder（默认圆形）在 avatar 上叠一层硬编码的 `0x60191919` 深色 scrim
/// （`_kSelectScrimColor`，chip.dart `_paintSelectionOverlay`），再在上面画白色
/// 对勾——视觉上就是图标被套进一枚深灰实心圆盘、图标发白发脏，不是 M3 规范
/// （2026-10-06 统计中心媒体筛选条）。该 scrim 不受 ChipTheme 控制。
///
/// M3 filter chip 规范：选中容器 secondaryContainer，前导图标被对勾**原位**替换，
/// 颜色 onSecondaryContainer。所以有 avatar 的 chip 一律关掉 RawChip 自带对勾，
/// 由这里在同一槽位交叉淡化 + 缩放（M3E shape morph 的轻量形态）：槽宽不变，
/// 选中前后文字不位移；墨水屏 / 减弱动态效果下 [fushiMotionDuration] 归零即瞬切。
Widget fushiChipLeadingCheckSwap(
  BuildContext context, {
  required Widget avatar,
  required bool selected,
  Color? checkColor,
  double checkSize = 18,
}) {
  final Widget current = selected
      ? FushiIcon(
          Icons.check,
          key: const ValueKey<String>('fushi-chip-leading-check'),
          size: checkSize,
          color: checkColor,
        )
      : KeyedSubtree(
          key: const ValueKey<String>('fushi-chip-leading-avatar'),
          child: avatar,
        );
  return AnimatedSwitcher(
    duration: fushiMotionDuration(context, FushiMotion.short),
    switchInCurve: FushiMotion.enter,
    switchOutCurve: FushiMotion.exit,
    transitionBuilder: (Widget child, Animation<double> animation) =>
        FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
            child: child,
          ),
        ),
    child: current,
  );
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
    this.accentColor,
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
    this.accentColor,
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
  /// 强调色（标签 / 合集等彩色 chip）：MD3 选中铺满该色、未选淡色块
  /// （[fushiAccentChipColors]）；Apple 选中用该色作胶囊底。显式给的
  /// selectedColor / backgroundColor / labelStyle 仍优先。
  final Color? accentColor;

  final bool _elevated;

  @override
  Widget build(BuildContext context) {
    final Color? accent = accentColor;
    if (accent == null || isGlassDesign(context) || isEinkTheme(context)) {
      return _build(context);
    }
    return ChipTheme(
      data: fushiAccentChipTheme(context, accent),
      child: Builder(builder: _build),
    );
  }

  Widget _build(BuildContext context) {
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
        selectedColor: selectedColor ?? accentColor,
        backgroundColor: backgroundColor,
        disabledColor: disabledColor,
        color: color,
        iconTheme: iconTheme,
        focusNode: focusNode,
        autofocus: autofocus,
        tooltip: tooltip,
      );
    }
    // 有前导图标且要画对勾时：对勾原位替换图标，不走 RawChip 自带对勾（深色
    // 圆形 scrim，见 [fushiChipLeadingCheckSwap]）。全局 chipTheme 关了对勾时
    // 维持原样（选中只靠填充）。
    final Widget? leading = avatar;
    final bool wantsCheckmark =
        showCheckmark ?? ChipTheme.of(context).showCheckmark ?? true;
    final Widget? effectiveAvatar = leading != null && wantsCheckmark
        ? fushiChipLeadingCheckSwap(
            context,
            avatar: leading,
            selected: selected,
            checkColor: checkmarkColor ?? labelStyle?.color,
          )
        : leading;
    final bool? effectiveShowCheckmark = leading != null && wantsCheckmark
        ? false
        : showCheckmark;
    if (_elevated) {
      return ChoiceChip.elevated(
        avatar: effectiveAvatar,
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
        showCheckmark: effectiveShowCheckmark,
        checkmarkColor: checkmarkColor,
        avatarBorder: avatarBorder,
        avatarBoxConstraints: avatarBoxConstraints,
        chipAnimationStyle: chipAnimationStyle,
        mouseCursor: mouseCursor,
      );
    }
    return ChoiceChip(
      avatar: effectiveAvatar,
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
      showCheckmark: effectiveShowCheckmark,
      checkmarkColor: checkmarkColor,
      avatarBorder: avatarBorder,
      avatarBoxConstraints: avatarBoxConstraints,
      chipAnimationStyle: chipAnimationStyle,
      mouseCursor: mouseCursor,
    );
  }
}

/// [FushiFilterChip] 的语义色调。
enum FushiFilterChipTone {
  /// 普通筛选：选中 = 包含。
  include,

  /// 排除态（三态筛选「未选 → 包含 → 排除」的第三态）：MD3 errorContainer 底 +
  /// 减号；Apple 中性灰底 + destructive 色减号（iOS 不铺饱和红块）。排除态
  /// 恒按「选中」渲染、不画对勾，调用方传不传 [FushiFilterChip.selected] 都行。
  exclude,
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
    this.tone = FushiFilterChipTone.include,
    this.accentColor,
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
    this.tone = FushiFilterChipTone.include,
    this.accentColor,
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

  /// 语义色调，默认 [FushiFilterChipTone.include]（与原 FilterChip 完全一致）。
  final FushiFilterChipTone tone;
  /// 强调色（标签 / 合集等彩色 chip）：MD3 选中铺满该色、未选淡色块
  /// （[fushiAccentChipColors]）；Apple 选中用该色作胶囊底。显式给的
  /// selectedColor / backgroundColor / labelStyle 仍优先。
  final Color? accentColor;

  final bool _elevated;

  @override
  Widget build(BuildContext context) {
    final Color? accent = accentColor;
    if (accent == null || isGlassDesign(context) || isEinkTheme(context)) {
      return _build(context);
    }
    return ChipTheme(
      data: fushiAccentChipTheme(context, accent),
      child: Builder(builder: _build),
    );
  }

  Widget _build(BuildContext context) {
    final bool exclude = tone == FushiFilterChipTone.exclude;
    if (isGlassDesign(context)) {
      final ValueChanged<bool>? select = onSelected;
      // 排除态：不走强调色选中底，换中性灰底 + destructive 减号；选中对勾
      // 会顶掉 avatar，所以排除态不画对勾。
      final FushiAppleColors? apple = exclude ? appleColorsOf(context) : null;
      return _glassChip(
        context,
        label: label,
        interactive: true,
        enabled: select != null,
        onTap: select == null ? null : () => select(!selected),
        avatar: apple != null
            ? (avatar ??
                  FushiIcon(
                    CupertinoIcons.minus,
                    size: 16,
                    color: apple.destructive,
                  ))
            : avatar,
        labelStyle: labelStyle,
        padding: padding,
        labelPadding: labelPadding,
        visualDensity: visualDensity,
        selected: selected && !exclude,
        showCheckmark: exclude ? false : (showCheckmark ?? true),
        checkmarkColor: checkmarkColor,
        selectedColor: selectedColor ?? accentColor,
        backgroundColor: apple != null
            ? (backgroundColor ?? apple.secondaryFill)
            : backgroundColor,
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
    // MD3 filter chip 选中带前导对勾；全局 chipTheme 关掉了对勾（单选 ChoiceChip
    // 靠填充表达），这里在未显式指定时打开。
    // 排除态：errorContainer 底 + onErrorContainer 减号与文字，不画对勾（对勾
    // 会顶掉减号）。
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget? leadingAvatar = exclude
        ? (avatar ??
              FushiIcon(Icons.remove, size: 18, color: scheme.onErrorContainer))
        : avatar;
    final bool effectiveSelected = selected || exclude;
    final Color? effectiveSelectedColor = exclude
        ? (selectedColor ?? scheme.errorContainer)
        : selectedColor;
    final TextStyle? effectiveLabelStyle = exclude
        ? (labelStyle ?? const TextStyle()).copyWith(
            color: labelStyle?.color ?? scheme.onErrorContainer,
          )
        : labelStyle;
    final bool wantsCheckmark = exclude ? false : (showCheckmark ?? true);
    // 有前导图标时对勾原位替换图标，不走 RawChip 自带对勾（深色圆形 scrim，见
    // [fushiChipLeadingCheckSwap]）。
    final Widget? leading = leadingAvatar;
    final Widget? effectiveAvatar = leading != null && wantsCheckmark
        ? fushiChipLeadingCheckSwap(
            context,
            avatar: leading,
            selected: effectiveSelected,
            checkColor: checkmarkColor ?? effectiveLabelStyle?.color,
          )
        : leading;
    final bool effectiveShowCheckmark = wantsCheckmark && leading == null;
    if (_elevated) {
      return FilterChip.elevated(
        avatar: effectiveAvatar,
        label: label,
        labelStyle: effectiveLabelStyle,
        labelPadding: labelPadding,
        selected: effectiveSelected,
        onSelected: onSelected,
        deleteIcon: deleteIcon,
        onDeleted: onDeleted,
        deleteIconColor: deleteIconColor,
        deleteButtonTooltipMessage: deleteButtonTooltipMessage,
        pressElevation: pressElevation,
        disabledColor: disabledColor,
        selectedColor: effectiveSelectedColor,
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
        showCheckmark: effectiveShowCheckmark,
        checkmarkColor: checkmarkColor,
        avatarBorder: avatarBorder,
        avatarBoxConstraints: avatarBoxConstraints,
        deleteIconBoxConstraints: deleteIconBoxConstraints,
        chipAnimationStyle: chipAnimationStyle,
        mouseCursor: mouseCursor,
      );
    }
    return FilterChip(
      avatar: effectiveAvatar,
      label: label,
      labelStyle: effectiveLabelStyle,
      labelPadding: labelPadding,
      selected: effectiveSelected,
      onSelected: onSelected,
      deleteIcon: deleteIcon,
      onDeleted: onDeleted,
      deleteIconColor: deleteIconColor,
      deleteButtonTooltipMessage: deleteButtonTooltipMessage,
      pressElevation: pressElevation,
      disabledColor: disabledColor,
      selectedColor: effectiveSelectedColor,
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
      showCheckmark: effectiveShowCheckmark,
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
