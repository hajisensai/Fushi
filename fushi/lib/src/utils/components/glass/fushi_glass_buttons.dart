import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 按钮族的「设计系统分派」包装：构造参数与 Material 原控件逐个同名同型，
// 调用点只改类名。MD3 设计系统下原样构造原控件（像素、焦点、语义一字不差）；
// 「玻璃」设计系统下按 iOS 26 的按钮样式渲染：主按钮 / 次按钮是
// liquid_glass_widgets 的 [GlassButton] 玻璃胶囊（自带 GlassFocusRegion：焦点环 +
// Enter → ActivateIntent，与全局焦点导航和手柄 A 键同一条激活链路），文字按钮与
// 默认图标按钮是无底的 plain 按钮（同样走 ActivateIntent）。

enum _FushiButtonKind { text, filled, tonal, outlined }

/// 标记「iOS 26 alert 的动作区」：其中的按钮一律画成撑满宽度的 44 高胶囊——
/// 主操作（FilledButton）强调色玻璃，其余（TextButton / Outlined / Tonal）
/// 中性玻璃；前景色给成 error / destructive 的就是红字破坏性操作。由
/// [FushiAlertDialog] 的玻璃形态在动作区外包一层。
class FushiAlertActionScope extends InheritedWidget {
  const FushiAlertActionScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiAlertActionScope>() !=
      null;

  @override
  bool updateShouldNotify(FushiAlertActionScope oldWidget) => false;
}

/// 桌面（Windows / macOS / Linux）用 macOS 26 的紧凑控件尺寸；移动端用
/// iOS 26 的 44pt 触控尺寸。按 [ThemeData.platform] 判（测试可覆盖）。
bool fushiAppleCompact(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// 玻璃按钮的共用渲染，形态对齐 iOS 26 的按钮样式：
/// - filled = `.glassProminent`：强调色着色的玻璃胶囊，白字 semibold；
/// - tonal / outlined = `.glass`：中性玻璃胶囊，label 色文字；
/// - text = `.plain`：**不是玻璃**，无底纯强调色文字，按下变淡（见
///   [FushiPlainButton]）。调用方给了实底背景色时按着色玻璃画。
///
/// 高度：移动端 44（Messages 的 Edit 胶囊）、桌面 34；圆角恒为全胶囊。
/// [style] 里能映射的字段（前景 / 背景色、内边距、最小 / 固定尺寸、字体）照用，
/// 其余忽略。
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
  final FushiAppleColors apple = appleColorsOf(context);
  final bool compact = fushiAppleCompact(context);
  final bool enabled = onPressed != null || onLongPress != null;
  final Set<WidgetState> resolveStates = enabled
      ? const <WidgetState>{}
      : const <WidgetState>{WidgetState.disabled};

  final Color? styleBg = style?.backgroundColor?.resolve(resolveStates);
  final Color? styleFg = style?.foregroundColor?.resolve(resolveStates);
  final bool customBg = styleBg != null && styleBg.a > 0;
  final bool alertAction = FushiAlertActionScope.of(context);
  final bool plain = kind == _FushiButtonKind.text && !customBg && !alertAction;

  GlassButtonStyle glassStyle = GlassButtonStyle.filled;
  Color? tint;
  Color fg;
  FontWeight weight = FontWeight.w500;
  switch (kind) {
    case _FushiButtonKind.filled:
      glassStyle = GlassButtonStyle.prominent;
      tint = apple.accent;
      fg = Colors.white;
      weight = FontWeight.w600;
    case _FushiButtonKind.tonal:
    case _FushiButtonKind.outlined:
      fg = apple.label;
    case _FushiButtonKind.text:
      // alert 动作区里的取消类按钮是中性胶囊 + label 色字。
      fg = alertAction ? apple.label : apple.accent;
  }
  if (customBg) {
    tint = styleBg;
    if (kind == _FushiButtonKind.text) fg = Colors.white;
  }
  if (styleFg != null) fg = styleFg;
  if (!enabled) {
    // iOS 禁用态：主按钮褪成中性灰玻璃，文字一律 tertiaryLabel。
    fg = apple.tertiaryLabel;
    if (glassStyle == GlassButtonStyle.prominent) {
      glassStyle = GlassButtonStyle.filled;
      tint = null;
    }
  }

  final double height = alertAction ? (compact ? 36 : 48) : (compact ? 34 : 44);
  final EdgeInsetsGeometry padding =
      style?.padding?.resolve(resolveStates) ??
      EdgeInsets.symmetric(
        horizontal: plain ? (compact ? 8 : 10) : (compact ? 14 : 20),
      );
  final Size? minimumSize = style?.minimumSize?.resolve(resolveStates);
  final Size? fixedSize = style?.fixedSize?.resolve(resolveStates);

  final TextStyle textStyle = (theme.textTheme.labelLarge ?? const TextStyle())
      .copyWith(fontSize: compact ? 15 : 17, fontWeight: weight)
      .merge(style?.textStyle?.resolve(resolveStates))
      .copyWith(color: fg);
  Widget content;
  if (icon != null && label != null) {
    final bool trailing = iconAlignment == IconAlignment.end;
    final List<Widget> parts = <Widget>[
      icon,
      SizedBox(width: compact ? 5 : 6),
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
    data: IconThemeData(color: fg, size: compact ? 16 : 19),
    child: DefaultTextStyle.merge(
      style: textStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: Padding(padding: padding, child: content),
    ),
  );
  final double minHeight =
      fixedSize?.height ??
      (minimumSize != null && minimumSize.height > 0
          ? minimumSize.height
          : (plain ? (compact ? 28 : 44) : height));
  content = ConstrainedBox(
    constraints: BoxConstraints(
      minWidth: fixedSize?.width ?? minimumSize?.width ?? (plain ? 0 : height),
      minHeight: alertAction ? height : minHeight,
    ),
    child: Center(widthFactor: 1, heightFactor: 1, child: content),
  );

  if (plain) {
    return FushiPlainButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      onHover: onHover,
      onFocusChange: onFocusChange,
      focusNode: focusNode,
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(minHeight / 2),
      child: content,
    );
  }

  Widget button = GlassButton.custom(
    onTap: onPressed ?? () {},
    enabled: enabled,
    style: glassStyle,
    settings: tint == null ? null : fushiGlassSettings(context, tint: tint),
    quality: fushiGlassQuality(context),
    // 全胶囊：库按 min(宽, 高) / 2 收紧圆角，给一个足够大的值即可。
    shape: const LiquidRoundedSuperellipse(borderRadius: 999),
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

/// iOS 的 `.plain` / `.borderless` 按钮：无底、无玻璃，按下整体变淡
/// （UIButton highlighted 的 alpha），桌面悬停给一层 tertiaryFill 底
/// （macOS 无边框工具栏按钮的 hover）。键盘 / 手柄可达：自带焦点节点，
/// [ActivateIntent]（Enter / 手柄 A）触发 [onPressed]，键盘焦点时画一圈强调色
/// 焦点环。
class FushiPlainButton extends StatefulWidget {
  const FushiPlainButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    required this.borderRadius,
    required this.child,
    this.semanticLabel,
  });

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final FocusNode? focusNode;
  final bool autofocus;
  final BorderRadius borderRadius;
  final String? semanticLabel;
  final Widget child;

  @override
  State<FushiPlainButton> createState() => _FushiPlainButtonState();
}

class _FushiPlainButtonState extends State<FushiPlainButton> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focusHighlight = false;

  bool get _enabled => widget.onPressed != null || widget.onLongPress != null;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool enabled = _enabled;
    Widget body = AnimatedOpacity(
      // 按下立即变淡、松手缓回，与 UIKit 高亮的节奏一致。
      duration: _pressed ? Duration.zero : const Duration(milliseconds: 180),
      opacity: _pressed ? 0.3 : 1,
      child: widget.child,
    );
    body = DecoratedBox(
      decoration: BoxDecoration(
        color: enabled && _hovered && !_pressed
            ? apple.tertiaryFill
            : Colors.transparent,
        borderRadius: widget.borderRadius,
        border: _focusHighlight
            ? Border.all(color: apple.accent, width: 2)
            : null,
      ),
      child: body,
    );
    return FocusableActionDetector(
      enabled: enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      onShowHoverHighlight: (bool value) {
        setState(() => _hovered = value);
        widget.onHover?.call(value);
      },
      onShowFocusHighlight: (bool value) {
        setState(() => _focusHighlight = value);
      },
      onFocusChange: widget.onFocusChange,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => _setPressed(true) : null,
          onTapUp: enabled ? (_) => _setPressed(false) : null,
          onTapCancel: enabled ? () => _setPressed(false) : null,
          onTap: widget.onPressed,
          onLongPress: widget.onLongPress,
          child: body,
        ),
      ),
    );
  }
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
  }) : icon = null,
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
  }) : child = null,
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
  }) : icon = null,
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
  }) : child = null,
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
  }) : icon = null,
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
  }) : child = null,
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
  }) : icon = null,
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
  }) : child = null,
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

  /// iOS 26 图标按钮：
  /// - 默认（[IconButton]）= `.plain`，无底图标（label 色；选中态强调色），
  ///   44 / 36 的触控区，按下变淡——**不是玻璃**；
  /// - `.filled` = 强调色着色玻璃圆钮（`.glassProminent`），白色图标；
  /// - `.filledTonal` / `.outlined` = 中性玻璃圆钮（`.glass`，Messages 顶栏
  ///   那颗 44×44 圆钮），label 色图标。
  Widget _buildGlass(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final bool selected = isSelected ?? false;
    final bool enabled = onPressed != null || onLongPress != null;
    final Set<WidgetState> states = <WidgetState>{
      if (!enabled) WidgetState.disabled,
      if (selected) WidgetState.selected,
    };
    final Color? styleFg = style?.foregroundColor?.resolve(states);
    final Color? styleBg = style?.backgroundColor?.resolve(states);
    final bool raised =
        _variant != _IconButtonVariant.standard ||
        (styleBg != null && styleBg.a > 0);
    final bool prominent = _variant == _IconButtonVariant.filled;
    Color fg =
        styleFg ??
        color ??
        (prominent ? Colors.white : (selected ? apple.accent : apple.label));
    if (!enabled) fg = disabledColor ?? apple.tertiaryLabel;
    final Color? tint = (styleBg != null && styleBg.a > 0)
        ? styleBg
        : (prominent && enabled ? apple.accent : null);
    final double effectiveIconSize =
        iconSize ?? style?.iconSize?.resolve(states) ?? (compact ? 18 : 22);
    final double defaultExtent = compact ? 36 : 44;
    final double extent =
        constraints?.minWidth != null && constraints!.minWidth > 0
        ? constraints!.minWidth
        : (visualDensity == VisualDensity.compact
              ? defaultExtent - 8
              : defaultExtent);
    final Widget glyph = IconTheme.merge(
      data: IconThemeData(color: fg, size: effectiveIconSize),
      child: selected && selectedIcon != null ? selectedIcon! : icon,
    );

    Widget button;
    if (!raised) {
      button = FushiPlainButton(
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: null,
        focusNode: focusNode,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(extent / 2),
        semanticLabel: tooltip,
        child: SizedBox(
          width: extent,
          height: extent,
          child: Center(child: glyph),
        ),
      );
    } else {
      button = GlassButton.custom(
        onTap: onPressed ?? () {},
        enabled: enabled,
        style: tint != null
            ? GlassButtonStyle.prominent
            : GlassButtonStyle.filled,
        settings: tint == null ? null : fushiGlassSettings(context, tint: tint),
        quality: fushiGlassQuality(context),
        shape: const LiquidOval(),
        width: extent,
        height: extent,
        focusNode: focusNode,
        autofocus: autofocus,
        label: tooltip ?? '',
        child: glyph,
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
    }
    if (tooltip != null && tooltip!.isNotEmpty) {
      button = Tooltip(message: tooltip, child: button);
    }
    return button;
  }
}
