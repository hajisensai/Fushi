import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 浮层族（对话框 / 弹出菜单 / 下拉 / 提示条）的「设计系统分派」包装：构造参数
// 与 Material 原控件逐个同名同型，调用点只改类名。MD3 设计系统下原样构造原控件
// （像素、焦点、语义一字不差）；「玻璃」设计系统下表面换成 liquid_glass_widgets
// 的玻璃容器，交互骨架（路由、焦点陷阱、Esc 关闭、方向键在菜单项间移动、
// Enter / 手柄 A 激活）保持框架原生链路不变。

/// 玻璃对话框圆角（对齐 GlassDialog 的连续曲率观感，比 MD3 的 28 略收）。
const double _kGlassDialogRadius = 24;

/// 玻璃对话框内边距基准（GlassDialog 用 20）。
const double _kGlassDialogPad = 20;

/// 与 Material [Dialog] 相同的默认外边距。
const EdgeInsets _kDialogInsetPadding = EdgeInsets.symmetric(
  horizontal: 40,
  vertical: 24,
);

/// 玻璃菜单圆角。
const double _kGlassMenuRadius = 16;

// ===========================================================================
// 对话框
// ===========================================================================

/// 玻璃对话框外壳：布局语义照抄 Material [Dialog]（键盘让位、外边距、对齐、
/// 尺寸约束、语义角色），表面换成 [GlassContainer]。内部垫一层透明
/// [Material]，让内容里的 InkWell / ListTile 等仍有墨水宿主。
class _FushiGlassDialogShell extends StatelessWidget {
  const _FushiGlassDialogShell({
    required this.child,
    this.tint,
    this.insetPadding,
    this.alignment,
    this.constraints,
    this.clipBehavior,
    this.semanticsRole = SemanticsRole.dialog,
    this.insetAnimationDuration = const Duration(milliseconds: 100),
    this.insetAnimationCurve = Curves.decelerate,
    this.fullscreen = false,
  });

  final Widget child;
  final Color? tint;
  final EdgeInsets? insetPadding;
  final AlignmentGeometry? alignment;
  final BoxConstraints? constraints;
  final Clip? clipBehavior;
  final SemanticsRole semanticsRole;
  final Duration insetAnimationDuration;
  final Curve insetAnimationCurve;
  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final DialogThemeData dialogTheme = DialogTheme.of(context);
    final Color? explicitTint = tint != null && tint!.a > 0 ? tint : null;
    final Widget surface = GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      settings: fushiGlassSettings(
        context,
        tint: explicitTint ?? cs.surfaceContainerHigh,
      ),
      shape: fullscreen
          ? const LiquidRoundedRectangle(borderRadius: 0)
          : const LiquidRoundedSuperellipse(borderRadius: _kGlassDialogRadius),
      clipBehavior: clipBehavior ?? Clip.antiAlias,
      child: Material(type: MaterialType.transparency, child: child),
    );
    if (fullscreen) {
      return Semantics(role: semanticsRole, child: surface);
    }
    final EdgeInsets effectivePadding =
        MediaQuery.viewInsetsOf(context) +
        (insetPadding ?? dialogTheme.insetPadding ?? _kDialogInsetPadding);
    return Semantics(
      role: semanticsRole,
      child: AnimatedPadding(
        padding: effectivePadding,
        duration: insetAnimationDuration,
        curve: insetAnimationCurve,
        child: MediaQuery.removeViewInsets(
          removeLeft: true,
          removeTop: true,
          removeRight: true,
          removeBottom: true,
          context: context,
          child: Align(
            alignment: alignment ?? dialogTheme.alignment ?? Alignment.center,
            child: ConstrainedBox(
              constraints:
                  constraints ??
                  dialogTheme.constraints ??
                  const BoxConstraints(minWidth: 280),
              child: surface,
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle _glassDialogTitleStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return (theme.textTheme.titleLarge ?? const TextStyle()).copyWith(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: theme.colorScheme.onSurface,
  );
}

TextStyle _glassDialogContentStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
    color: theme.colorScheme.onSurfaceVariant,
    height: 1.4,
  );
}

/// [AlertDialog] 的设计系统分派版。
class FushiAlertDialog extends StatelessWidget {
  const FushiAlertDialog({
    super.key,
    this.icon,
    this.iconPadding,
    this.iconColor,
    this.title,
    this.titlePadding,
    this.titleTextStyle,
    this.content,
    this.contentPadding,
    this.contentTextStyle,
    this.actions,
    this.actionsPadding,
    this.actionsAlignment,
    this.actionsOverflowAlignment,
    this.actionsOverflowDirection,
    this.actionsOverflowButtonSpacing,
    this.buttonPadding,
    this.backgroundColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.semanticLabel,
    this.insetPadding,
    this.clipBehavior,
    this.shape,
    this.alignment,
    this.constraints,
    this.scrollable = false,
  })  : scrollController = null,
        actionScrollController = null,
        insetAnimationDuration = const Duration(milliseconds: 100),
        insetAnimationCurve = Curves.decelerate,
        _adaptive = false;

  /// [AlertDialog.adaptive] 的分派版：MD3 下按平台出 Cupertino / Material
  /// 对话框（同原控件），玻璃下与默认构造器同一个玻璃外壳。
  const FushiAlertDialog.adaptive({
    super.key,
    this.icon,
    this.iconPadding,
    this.iconColor,
    this.title,
    this.titlePadding,
    this.titleTextStyle,
    this.content,
    this.contentPadding,
    this.contentTextStyle,
    this.actions,
    this.actionsPadding,
    this.actionsAlignment,
    this.actionsOverflowAlignment,
    this.actionsOverflowDirection,
    this.actionsOverflowButtonSpacing,
    this.buttonPadding,
    this.backgroundColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.semanticLabel,
    this.insetPadding,
    this.clipBehavior,
    this.shape,
    this.alignment,
    this.constraints,
    this.scrollable = false,
    this.scrollController,
    this.actionScrollController,
    this.insetAnimationDuration = const Duration(milliseconds: 100),
    this.insetAnimationCurve = Curves.decelerate,
  }) : _adaptive = true;

  final Widget? icon;
  final EdgeInsetsGeometry? iconPadding;
  final Color? iconColor;
  final Widget? title;
  final EdgeInsetsGeometry? titlePadding;
  final TextStyle? titleTextStyle;
  final Widget? content;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? contentTextStyle;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? actionsPadding;
  final MainAxisAlignment? actionsAlignment;
  final OverflowBarAlignment? actionsOverflowAlignment;
  final VerticalDirection? actionsOverflowDirection;
  final double? actionsOverflowButtonSpacing;
  final EdgeInsetsGeometry? buttonPadding;
  final Color? backgroundColor;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final String? semanticLabel;
  final EdgeInsets? insetPadding;
  final Clip? clipBehavior;
  final ShapeBorder? shape;
  final AlignmentGeometry? alignment;
  final BoxConstraints? constraints;
  final bool scrollable;
  final ScrollController? scrollController;
  final ScrollController? actionScrollController;
  final Duration insetAnimationDuration;
  final Curve insetAnimationCurve;
  final bool _adaptive;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context) && _adaptive) {
      return AlertDialog.adaptive(
        icon: icon,
        iconPadding: iconPadding,
        iconColor: iconColor,
        title: title,
        titlePadding: titlePadding,
        titleTextStyle: titleTextStyle,
        content: content,
        contentPadding: contentPadding,
        contentTextStyle: contentTextStyle,
        actions: actions,
        actionsPadding: actionsPadding,
        actionsAlignment: actionsAlignment,
        actionsOverflowAlignment: actionsOverflowAlignment,
        actionsOverflowDirection: actionsOverflowDirection,
        actionsOverflowButtonSpacing: actionsOverflowButtonSpacing,
        buttonPadding: buttonPadding,
        backgroundColor: backgroundColor,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        semanticLabel: semanticLabel,
        insetPadding:
            insetPadding ?? const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        clipBehavior: clipBehavior,
        shape: shape,
        alignment: alignment,
        constraints: constraints,
        scrollable: scrollable,
        scrollController: scrollController,
        actionScrollController: actionScrollController,
        insetAnimationDuration: insetAnimationDuration,
        insetAnimationCurve: insetAnimationCurve,
      );
    }
    if (!isGlassDesign(context)) {
      return AlertDialog(
        icon: icon,
        iconPadding: iconPadding,
        iconColor: iconColor,
        title: title,
        titlePadding: titlePadding,
        titleTextStyle: titleTextStyle,
        content: content,
        contentPadding: contentPadding,
        contentTextStyle: contentTextStyle,
        actions: actions,
        actionsPadding: actionsPadding,
        actionsAlignment: actionsAlignment,
        actionsOverflowAlignment: actionsOverflowAlignment,
        actionsOverflowDirection: actionsOverflowDirection,
        actionsOverflowButtonSpacing: actionsOverflowButtonSpacing,
        buttonPadding: buttonPadding,
        backgroundColor: backgroundColor,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        semanticLabel: semanticLabel,
        insetPadding: insetPadding,
        clipBehavior: clipBehavior,
        shape: shape,
        alignment: alignment,
        constraints: constraints,
        scrollable: scrollable,
      );
    }
    return _buildGlass(context);
  }

  Widget _buildGlass(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final DialogThemeData dialogTheme = DialogTheme.of(context);
    const double pad = _kGlassDialogPad;

    Widget? iconWidget;
    Widget? titleWidget;
    Widget? contentWidget;
    Widget? actionsWidget;

    if (icon != null) {
      iconWidget = Padding(
        padding:
            iconPadding ??
            EdgeInsets.fromLTRB(
              pad,
              pad,
              pad,
              title != null
                  ? 12
                  : content != null
                  ? 0
                  : pad,
            ),
        child: IconTheme(
          data: IconThemeData(
            color: iconColor ?? dialogTheme.iconColor ?? cs.secondary,
            size: 24,
          ),
          child: icon!,
        ),
      );
    }

    if (title != null) {
      titleWidget = Padding(
        padding:
            titlePadding ??
            EdgeInsets.fromLTRB(
              pad,
              icon == null ? pad : 0,
              pad,
              content == null ? 16 : 0,
            ),
        child: DefaultTextStyle(
          style:
              titleTextStyle ??
              dialogTheme.titleTextStyle ??
              _glassDialogTitleStyle(context),
          textAlign: icon == null ? TextAlign.start : TextAlign.center,
          child: Semantics(
            namesRoute:
                semanticLabel == null &&
                defaultTargetPlatform != TargetPlatform.iOS,
            container: true,
            child: title,
          ),
        ),
      );
    }

    if (content != null) {
      contentWidget = Padding(
        padding:
            contentPadding ??
            EdgeInsets.fromLTRB(
              pad,
              title == null && icon == null ? pad : 12,
              pad,
              pad,
            ),
        child: DefaultTextStyle(
          style:
              contentTextStyle ??
              dialogTheme.contentTextStyle ??
              _glassDialogContentStyle(context),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            child: content,
          ),
        ),
      );
    }

    if (actions != null) {
      final double spacing = (buttonPadding?.horizontal ?? 16) / 2;
      actionsWidget = Padding(
        padding:
            actionsPadding ??
            dialogTheme.actionsPadding ??
            const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: OverflowBar(
          alignment: actionsAlignment ?? MainAxisAlignment.end,
          spacing: spacing,
          overflowAlignment:
              actionsOverflowAlignment ?? OverflowBarAlignment.end,
          overflowDirection: actionsOverflowDirection ?? VerticalDirection.down,
          overflowSpacing: actionsOverflowButtonSpacing ?? 0,
          children: actions!,
        ),
      );
    }

    final List<Widget> columnChildren;
    if (scrollable) {
      columnChildren = <Widget>[
        if (title != null || content != null)
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (iconWidget != null) iconWidget,
                  if (titleWidget != null) titleWidget,
                  if (contentWidget != null) contentWidget,
                ],
              ),
            ),
          ),
        if (actionsWidget != null) actionsWidget,
      ];
    } else {
      columnChildren = <Widget>[
        if (iconWidget != null) iconWidget,
        if (titleWidget != null) titleWidget,
        if (contentWidget != null) Flexible(child: contentWidget),
        if (actionsWidget != null) actionsWidget,
      ];
    }

    Widget dialogChild = IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: columnChildren,
      ),
    );
    if (semanticLabel != null) {
      dialogChild = Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: true,
        label: semanticLabel,
        child: dialogChild,
      );
    }
    return _FushiGlassDialogShell(
      tint: backgroundColor,
      insetPadding: insetPadding,
      alignment: alignment,
      constraints: constraints,
      clipBehavior: clipBehavior,
      semanticsRole: SemanticsRole.alertDialog,
      child: dialogChild,
    );
  }
}

/// [SimpleDialog] 的设计系统分派版。
class FushiSimpleDialog extends StatelessWidget {
  const FushiSimpleDialog({
    super.key,
    this.title,
    this.titlePadding = const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 0.0),
    this.titleTextStyle,
    this.children,
    this.contentPadding = const EdgeInsets.fromLTRB(0.0, 12.0, 0.0, 16.0),
    this.contentTextStyle,
    this.backgroundColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.semanticLabel,
    this.insetPadding,
    this.clipBehavior,
    this.shape,
    this.alignment,
    this.constraints,
  });

  final Widget? title;
  final EdgeInsetsGeometry titlePadding;
  final TextStyle? titleTextStyle;
  final List<Widget>? children;
  final EdgeInsetsGeometry contentPadding;
  final TextStyle? contentTextStyle;
  final Color? backgroundColor;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final String? semanticLabel;
  final EdgeInsets? insetPadding;
  final Clip? clipBehavior;
  final ShapeBorder? shape;
  final AlignmentGeometry? alignment;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return SimpleDialog(
        title: title,
        titlePadding: titlePadding,
        titleTextStyle: titleTextStyle,
        contentPadding: contentPadding,
        contentTextStyle: contentTextStyle,
        backgroundColor: backgroundColor,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        semanticLabel: semanticLabel,
        insetPadding: insetPadding,
        clipBehavior: clipBehavior,
        shape: shape,
        alignment: alignment,
        constraints: constraints,
        children: children,
      );
    }
    final DialogThemeData dialogTheme = DialogTheme.of(context);
    Widget body = IntrinsicWidth(
      stepWidth: 56,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (title != null)
              Padding(
                padding: titlePadding,
                child: DefaultTextStyle(
                  style:
                      titleTextStyle ??
                      dialogTheme.titleTextStyle ??
                      _glassDialogTitleStyle(context),
                  child: Semantics(
                    namesRoute:
                        semanticLabel == null &&
                        defaultTargetPlatform != TargetPlatform.iOS,
                    container: true,
                    child: title,
                  ),
                ),
              ),
            if (children != null)
              Flexible(
                child: SingleChildScrollView(
                  padding: contentPadding,
                  child: DefaultTextStyle(
                    style:
                        contentTextStyle ??
                        dialogTheme.contentTextStyle ??
                        _glassDialogContentStyle(context),
                    child: ListBody(children: children!),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (semanticLabel != null) {
      body = Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: true,
        label: semanticLabel,
        child: body,
      );
    }
    return _FushiGlassDialogShell(
      tint: backgroundColor,
      insetPadding: insetPadding,
      alignment: alignment,
      constraints: constraints,
      clipBehavior: clipBehavior,
      child: body,
    );
  }
}

/// [SimpleDialogOption] 的设计系统分派版。玻璃下是一条透明玻璃行（悬停 /
/// 焦点高亮由玻璃按钮给，Enter / 手柄 A 走同一条 ActivateIntent）。
class FushiSimpleDialogOption extends StatelessWidget {
  const FushiSimpleDialogOption({
    super.key,
    this.onPressed,
    this.padding,
    this.child,
  });

  final VoidCallback? onPressed;
  final EdgeInsets? padding;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return SimpleDialogOption(
        onPressed: onPressed,
        padding: padding,
        child: child,
      );
    }
    return GlassButton.custom(
      onTap: onPressed ?? () {},
      enabled: onPressed != null,
      style: GlassButtonStyle.transparent,
      quality: fushiGlassQuality(context),
      shape: const LiquidRoundedSuperellipse(borderRadius: 12),
      stretch: 0,
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding:
            padding ?? const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
        child: child,
      ),
    );
  }
}

/// [Dialog] 的设计系统分派版（含 `.fullscreen`）。
class FushiDialog extends StatelessWidget {
  const FushiDialog({
    super.key,
    this.backgroundColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.insetAnimationDuration = const Duration(milliseconds: 100),
    this.insetAnimationCurve = Curves.decelerate,
    this.insetPadding,
    this.clipBehavior,
    this.shape,
    this.alignment,
    this.child,
    this.semanticsRole = SemanticsRole.dialog,
    this.constraints,
  }) : _fullscreen = false;

  const FushiDialog.fullscreen({
    super.key,
    this.backgroundColor,
    this.insetAnimationDuration = Duration.zero,
    this.insetAnimationCurve = Curves.decelerate,
    this.child,
    this.semanticsRole = SemanticsRole.dialog,
  }) : elevation = 0,
       shadowColor = null,
       surfaceTintColor = null,
       insetPadding = EdgeInsets.zero,
       clipBehavior = Clip.none,
       shape = null,
       alignment = null,
       constraints = null,
       _fullscreen = true;

  final Color? backgroundColor;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final Duration insetAnimationDuration;
  final Curve insetAnimationCurve;
  final EdgeInsets? insetPadding;
  final Clip? clipBehavior;
  final ShapeBorder? shape;
  final AlignmentGeometry? alignment;
  final Widget? child;
  final SemanticsRole semanticsRole;
  final BoxConstraints? constraints;
  final bool _fullscreen;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      if (_fullscreen) {
        return Dialog.fullscreen(
          backgroundColor: backgroundColor,
          insetAnimationDuration: insetAnimationDuration,
          insetAnimationCurve: insetAnimationCurve,
          semanticsRole: semanticsRole,
          child: child,
        );
      }
      return Dialog(
        backgroundColor: backgroundColor,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        insetAnimationDuration: insetAnimationDuration,
        insetAnimationCurve: insetAnimationCurve,
        insetPadding: insetPadding,
        clipBehavior: clipBehavior,
        shape: shape,
        alignment: alignment,
        semanticsRole: semanticsRole,
        constraints: constraints,
        child: child,
      );
    }
    return _FushiGlassDialogShell(
      tint: backgroundColor,
      insetPadding: insetPadding,
      alignment: alignment,
      constraints: constraints,
      clipBehavior: clipBehavior,
      semanticsRole: semanticsRole,
      insetAnimationDuration: insetAnimationDuration,
      insetAnimationCurve: insetAnimationCurve,
      fullscreen: _fullscreen,
      child: child ?? const SizedBox.shrink(),
    );
  }
}

// ===========================================================================
// 弹出菜单
// ===========================================================================

/// [showMenu] 的设计系统分派版，签名逐参一致。MD3 下原样调 [showMenu]；
/// 玻璃下推一条自绘 [PopupRoute]：菜单面是玻璃，菜单项仍是调用方给的
/// [PopupMenuEntry]（[PopupMenuItem.handleTap] 照常 `Navigator.pop(value)`），
/// 打开时焦点落在 [initialValue] 对应项（否则第一项），方向键沿框架 /
/// 全局焦点引擎在项间移动，Enter / 手柄 A 激活，Esc / 点屏障关闭。
Future<T?> showFushiMenu<T>({
  required BuildContext context,
  RelativeRect? position,
  PopupMenuPositionBuilder? positionBuilder,
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  double? elevation,
  Color? shadowColor,
  Color? surfaceTintColor,
  String? semanticLabel,
  ShapeBorder? shape,
  EdgeInsetsGeometry? menuPadding,
  Color? color,
  bool useRootNavigator = false,
  BoxConstraints? constraints,
  Clip clipBehavior = Clip.none,
  RouteSettings? routeSettings,
  AnimationStyle? popUpAnimationStyle,
  bool? requestFocus,
}) {
  if (!isGlassDesign(context)) {
    return showMenu<T>(
      context: context,
      position: position,
      positionBuilder: positionBuilder,
      items: items,
      initialValue: initialValue,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      semanticLabel: semanticLabel,
      shape: shape,
      menuPadding: menuPadding,
      color: color,
      useRootNavigator: useRootNavigator,
      constraints: constraints,
      clipBehavior: clipBehavior,
      routeSettings: routeSettings,
      popUpAnimationStyle: popUpAnimationStyle,
      requestFocus: requestFocus,
    );
  }
  assert(items.isNotEmpty);
  assert(
    (position != null) != (positionBuilder != null),
    'Either position or positionBuilder must be provided.',
  );
  final NavigatorState navigator = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  );
  final MaterialLocalizations l10n = MaterialLocalizations.of(context);
  return navigator.push(
    _FushiGlassMenuRoute<T>(
      position: position,
      positionBuilder: positionBuilder,
      items: items,
      initialValue: initialValue,
      semanticLabel: semanticLabel ?? l10n.popupMenuLabel,
      barrierLabel: l10n.menuDismissLabel,
      menuPadding: menuPadding,
      constraints: constraints,
      popUpAnimationStyle: popUpAnimationStyle,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      settings: routeSettings,
      requestFocus: requestFocus,
    ),
  );
}

class _FushiGlassMenuRoute<T> extends PopupRoute<T> {
  _FushiGlassMenuRoute({
    required this.position,
    required this.positionBuilder,
    required this.items,
    required this.initialValue,
    required this.semanticLabel,
    required this.barrierLabel,
    required this.menuPadding,
    required this.constraints,
    required this.popUpAnimationStyle,
    required this.capturedThemes,
    super.settings,
    super.requestFocus,
  });

  final RelativeRect? position;
  final PopupMenuPositionBuilder? positionBuilder;
  final List<PopupMenuEntry<T>> items;
  final T? initialValue;
  final String? semanticLabel;
  final EdgeInsetsGeometry? menuPadding;
  final BoxConstraints? constraints;
  final AnimationStyle? popUpAnimationStyle;
  final CapturedThemes capturedThemes;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration =>
      popUpAnimationStyle?.duration ?? const Duration(milliseconds: 180);

  @override
  Duration get reverseTransitionDuration =>
      popUpAnimationStyle?.reverseDuration ?? const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final RelativeRect effective =
            positionBuilder?.call(context, box) ?? position!;
        final Animation<double> curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return CustomSingleChildLayout(
          delegate: _FushiGlassMenuLayout(
            position: effective,
            textDirection: Directionality.of(context),
            padding: MediaQuery.paddingOf(context),
          ),
          child: FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              alignment: Alignment.topCenter,
              scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
              child: capturedThemes.wrap(_FushiGlassMenuBody<T>(route: this)),
            ),
          ),
        );
      },
    );
  }
}

/// 菜单定位：与 Material 弹出菜单同一规则（按钮离哪侧屏幕边近就朝另一侧
/// 展开），再夹进屏幕安全区内 8px。
class _FushiGlassMenuLayout extends SingleChildLayoutDelegate {
  _FushiGlassMenuLayout({
    required this.position,
    required this.textDirection,
    required this.padding,
  });

  final RelativeRect position;
  final TextDirection textDirection;
  final EdgeInsets padding;

  static const double _screenPadding = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(
      constraints.biggest,
    ).deflate(const EdgeInsets.all(_screenPadding) + padding);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x;
    if (position.left > position.right) {
      x = size.width - position.right - childSize.width;
    } else if (position.left < position.right) {
      x = position.left;
    } else {
      x = textDirection == TextDirection.rtl
          ? size.width - position.right - childSize.width
          : position.left;
    }
    double y = position.top;
    final double minX = _screenPadding + padding.left;
    final double maxX =
        size.width - _screenPadding - padding.right - childSize.width;
    final double minY = _screenPadding + padding.top;
    final double maxY =
        size.height - _screenPadding - padding.bottom - childSize.height;
    x = x.clamp(minX, math.max(minX, maxX));
    y = y.clamp(minY, math.max(minY, maxY));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_FushiGlassMenuLayout oldDelegate) {
    return position != oldDelegate.position ||
        textDirection != oldDelegate.textDirection ||
        padding != oldDelegate.padding;
  }
}

class _FushiGlassMenuBody<T> extends StatefulWidget {
  const _FushiGlassMenuBody({required this.route});

  final _FushiGlassMenuRoute<T> route;

  @override
  State<_FushiGlassMenuBody<T>> createState() => _FushiGlassMenuBodyState<T>();
}

class _FushiGlassMenuBodyState<T> extends State<_FushiGlassMenuBody<T>> {
  /// 每个菜单项外包一个不可聚焦的 Focus 节点，只用来在打开后找到「该项里
  /// 第一个可聚焦后代」（PopupMenuItem 的 InkWell），把初始焦点落过去。
  late final List<FocusNode> _entryNodes = <FocusNode>[
    for (int i = 0; i < widget.route.items.length; i++)
      FocusNode(
        debugLabel: 'FushiGlassMenuEntry#$i',
        canRequestFocus: false,
        skipTraversal: true,
      ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusInitial());
  }

  int get _initialIndex {
    final T? initialValue = widget.route.initialValue;
    if (initialValue == null) return -1;
    return widget.route.items.indexWhere(
      (PopupMenuEntry<T> e) => e.represents(initialValue),
    );
  }

  void _focusInitial() {
    if (!mounted || !widget.route.requestFocus) return;
    final int initial = _initialIndex;
    final List<int> order = <int>[
      if (initial >= 0) initial,
      for (int i = 0; i < _entryNodes.length; i++)
        if (i != initial) i,
    ];
    for (final int i in order) {
      final Iterable<FocusNode> targets = _entryNodes[i].traversalDescendants;
      if (targets.isNotEmpty) {
        targets.first.requestFocus();
        return;
      }
    }
  }

  @override
  void dispose() {
    for (final FocusNode node in _entryNodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// 菜单项换成玻璃行：[PopupMenuItem]（含 [CheckedPopupMenuItem] 与仓库的
  /// FushiPopupMenuItem 子类）渲染成整行宽的透明 [GlassButton]，child 原样
  /// 放进去；点击语义同 Flutter 的 `PopupMenuItemState.handleTap`（先 onTap
  /// 再带 value 关菜单）。[PopupMenuDivider] → [GlassDivider]。其它自定义
  /// [PopupMenuEntry] 原样保留。
  Widget _glassEntry(
    BuildContext context,
    PopupMenuEntry<T> entry, {
    required bool highlighted,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    if (entry is PopupMenuDivider) {
      return GlassDivider(height: entry.height, indent: 12, endIndent: 12);
    }
    if (entry is! PopupMenuItem<T>) return entry;
    final PopupMenuItem<T> item = entry;
    final bool checked = item is CheckedPopupMenuItem<T> && item.checked;
    final Color fg =
        item.enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.38);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: GlassButton.custom(
        onTap: () {
          item.onTap?.call();
          Navigator.pop<T>(context, item.value);
        },
        enabled: item.enabled,
        style: highlighted || checked
            ? GlassButtonStyle.filled
            : GlassButtonStyle.transparent,
        quality: fushiGlassQuality(context),
        shape: const LiquidRoundedSuperellipse(borderRadius: 10),
        stretch: 0.15,
        alignment: AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: item.height),
          child: Padding(
            padding: item.padding ??
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: IconTheme.merge(
              data: IconThemeData(color: fg, size: 20),
              child: DefaultTextStyle.merge(
                style: (item.labelTextStyle?.resolve(<WidgetState>{}) ??
                        theme.textTheme.bodyLarge ??
                        const TextStyle())
                    .copyWith(color: fg),
                child: Row(
                  children: <Widget>[
                    if (item is CheckedPopupMenuItem<T>) ...<Widget>[
                      SizedBox(
                        width: 20,
                        child: checked
                            ? Icon(Icons.check, size: 18, color: cs.primary)
                            : null,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(child: item.child ?? const SizedBox.shrink()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final _FushiGlassMenuRoute<T> route = widget.route;
    final int initial = _initialIndex;
    final List<Widget> children = <Widget>[
      for (int i = 0; i < route.items.length; i++)
        Focus(
          focusNode: _entryNodes[i],
          child: _glassEntry(context, route.items[i], highlighted: i == initial),
        ),
    ];
    final Widget list = ConstrainedBox(
      constraints:
          route.constraints ??
          const BoxConstraints(minWidth: 2 * 56, maxWidth: 5 * 56),
      child: IntrinsicWidth(
        stepWidth: 56,
        child: Semantics(
          role: SemanticsRole.menu,
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: route.semanticLabel,
          child: SingleChildScrollView(
            padding:
                route.menuPadding ?? const EdgeInsets.symmetric(vertical: 6),
            child: ListBody(children: children),
          ),
        ),
      ),
    );
    return FocusTraversalGroup(
      child: GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context, prominent: true),
        settings: fushiGlassSettings(context, tint: cs.surfaceContainer),
        shape: const LiquidRoundedSuperellipse(borderRadius: _kGlassMenuRadius),
        clipBehavior: Clip.antiAlias,
        child: Material(type: MaterialType.transparency, child: list),
      ),
    );
  }
}

/// [PopupMenuButton] 的设计系统分派版。**继承** [PopupMenuButton]，State 也是
/// [PopupMenuButtonState] 子类——仓库里 `GlobalKey<PopupMenuButtonState<T>>`
/// + `showButtonMenu()` 的写法（`FushiOverflowMenu`）改名后照常工作。
/// MD3 下 build / showButtonMenu 全走父类；玻璃下按钮是玻璃按钮、菜单走
/// [showFushiMenu] 的玻璃路由（`color` / `shape` / `elevation` 这类 MD3 表面
/// 参数在玻璃下不生效）。
class FushiPopupMenuButton<T> extends PopupMenuButton<T> {
  const FushiPopupMenuButton({
    super.key,
    required super.itemBuilder,
    super.initialValue,
    super.onOpened,
    super.onSelected,
    super.onCanceled,
    super.tooltip,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.padding,
    super.menuPadding,
    super.child,
    super.borderRadius,
    super.splashRadius,
    super.icon,
    super.iconSize,
    super.offset,
    super.enabled,
    super.shape,
    super.color,
    super.iconColor,
    super.enableFeedback,
    super.constraints,
    super.position,
    super.clipBehavior,
    super.useRootNavigator,
    super.popUpAnimationStyle,
    super.routeSettings,
    super.style,
    super.requestFocus,
  });

  @override
  PopupMenuButtonState<T> createState() => _FushiPopupMenuButtonState<T>();
}

class _FushiPopupMenuButtonState<T> extends PopupMenuButtonState<T> {
  bool _glassExpanded = false;

  RelativeRect _glassPosition(BuildContext _, BoxConstraints __) {
    final RenderBox button = context.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(
              context,
              rootNavigator: widget.useRootNavigator,
            ).overlay!.context.findRenderObject()!
            as RenderBox;
    final PopupMenuPosition position =
        widget.position ??
        PopupMenuTheme.of(context).position ??
        PopupMenuPosition.over;
    Offset offset;
    switch (position) {
      case PopupMenuPosition.over:
        offset = widget.offset;
      case PopupMenuPosition.under:
        offset = Offset(0, button.size.height) + widget.offset;
        if (widget.child == null) {
          offset -= Offset(0, widget.padding.vertical / 2);
        }
    }
    return RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(offset, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero) + offset,
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
  }

  @override
  void showButtonMenu() {
    if (!isGlassDesign(context)) {
      super.showButtonMenu();
      return;
    }
    final List<PopupMenuEntry<T>> items = widget.itemBuilder(context);
    if (items.isEmpty) return;
    widget.onOpened?.call();
    setState(() => _glassExpanded = true);
    showFushiMenu<T?>(
      context: context,
      items: items,
      initialValue: widget.initialValue,
      positionBuilder: _glassPosition,
      menuPadding: widget.menuPadding,
      constraints: widget.constraints,
      useRootNavigator: widget.useRootNavigator,
      popUpAnimationStyle: widget.popUpAnimationStyle,
      routeSettings: widget.routeSettings,
      requestFocus: widget.requestFocus,
    ).then<void>((T? newValue) {
      if (!mounted) return;
      setState(() => _glassExpanded = false);
      if (newValue == null) {
        widget.onCanceled?.call();
        return;
      }
      widget.onSelected?.call(newValue);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) return super.build(context);
    final String tooltip =
        widget.tooltip ?? MaterialLocalizations.of(context).showMenuTooltip;
    if (widget.child != null) {
      Widget button = Semantics(
        expanded: _glassExpanded,
        child: GlassButton.custom(
          onTap: showButtonMenu,
          enabled: widget.enabled,
          style: GlassButtonStyle.transparent,
          quality: fushiGlassQuality(context),
          shape: const LiquidRoundedSuperellipse(borderRadius: 12),
          stretch: 0,
          label: tooltip,
          child: widget.child!,
        ),
      );
      if (tooltip.isNotEmpty) {
        button = Tooltip(message: tooltip, child: button);
      }
      return button;
    }
    final PopupMenuThemeData popupMenuTheme = PopupMenuTheme.of(context);
    final IconThemeData iconTheme = IconTheme.of(context);
    return FushiIconButtonControl(
      icon: Semantics(
        expanded: _glassExpanded,
        child: widget.icon ?? Icon(Icons.adaptive.more),
      ),
      padding: widget.padding,
      splashRadius: widget.splashRadius,
      iconSize: widget.iconSize ?? popupMenuTheme.iconSize ?? iconTheme.size,
      color: widget.iconColor ?? popupMenuTheme.iconColor ?? iconTheme.color,
      tooltip: tooltip,
      onPressed: widget.enabled ? showButtonMenu : null,
      enableFeedback: widget.enableFeedback,
      style: widget.style,
    );
  }
}

// ===========================================================================
// MenuAnchor
// ===========================================================================

/// 玻璃菜单面板：MenuAnchor 自己的 Material 面在玻璃下被清成透明无阴影，
/// 全部菜单项收进这一块玻璃里（项仍是 MenuAnchor 的直接后代，方向键 /
/// Esc / 子菜单行为不变）。
class _FushiGlassMenuPanel extends StatelessWidget {
  const _FushiGlassMenuPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      settings: fushiGlassSettings(context, tint: cs.surfaceContainer),
      shape: const LiquidRoundedSuperellipse(borderRadius: _kGlassMenuRadius),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// 玻璃下 MenuAnchor 自身面板的样式：透明、无阴影、零内边距（玻璃面板自带）。
const MenuStyle _kGlassMenuAnchorStyle = MenuStyle(
  backgroundColor: WidgetStatePropertyAll<Color>(Colors.transparent),
  surfaceTintColor: WidgetStatePropertyAll<Color>(Colors.transparent),
  shadowColor: WidgetStatePropertyAll<Color>(Colors.transparent),
  elevation: WidgetStatePropertyAll<double>(0),
  padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.zero),
  shape: WidgetStatePropertyAll<OutlinedBorder>(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(_kGlassMenuRadius)),
    ),
  ),
);

/// [MenuAnchor] 的设计系统分派版。
class FushiMenuAnchor extends StatelessWidget {
  const FushiMenuAnchor({
    super.key,
    this.controller,
    this.childFocusNode,
    this.style,
    this.alignmentOffset = Offset.zero,
    this.reservedPadding,
    this.layerLink,
    this.clipBehavior = Clip.hardEdge,
    @Deprecated(
      'Use consumeOutsideTap instead. '
      'This feature was deprecated after v3.16.0-8.0.pre.',
    )
    this.anchorTapClosesMenu = false,
    this.consumeOutsideTap = false,
    this.onOpen,
    this.onClose,
    this.crossAxisUnconstrained = true,
    this.useRootOverlay = false,
    this.animated = false,
    this.onAnimationStatusChanged,
    required this.menuChildren,
    this.builder,
    this.child,
  });

  final MenuController? controller;
  final FocusNode? childFocusNode;
  final MenuStyle? style;
  final Offset? alignmentOffset;
  final EdgeInsetsGeometry? reservedPadding;
  final LayerLink? layerLink;
  final Clip clipBehavior;
  @Deprecated(
    'Use consumeOutsideTap instead. '
    'This feature was deprecated after v3.16.0-8.0.pre.',
  )
  final bool anchorTapClosesMenu;
  final bool consumeOutsideTap;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;
  final bool crossAxisUnconstrained;
  final bool useRootOverlay;
  final bool animated;
  final ValueChanged<AnimationStatus>? onAnimationStatusChanged;
  final List<Widget> menuChildren;
  final MenuAnchorChildBuilder? builder;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    return MenuAnchor(
      controller: controller,
      childFocusNode: childFocusNode,
      style: glass ? _kGlassMenuAnchorStyle.merge(style) : style,
      alignmentOffset: alignmentOffset,
      reservedPadding: reservedPadding,
      layerLink: layerLink,
      clipBehavior: clipBehavior,
      // ignore: deprecated_member_use
      anchorTapClosesMenu: anchorTapClosesMenu,
      consumeOutsideTap: consumeOutsideTap,
      onOpen: onOpen,
      onClose: onClose,
      crossAxisUnconstrained: crossAxisUnconstrained,
      useRootOverlay: useRootOverlay,
      animated: animated,
      onAnimationStatusChanged: onAnimationStatusChanged,
      menuChildren: glass && menuChildren.isNotEmpty
          ? <Widget>[_FushiGlassMenuPanel(children: menuChildren)]
          : menuChildren,
      builder: builder,
      child: child,
    );
  }
}

// ===========================================================================
// 下拉
// ===========================================================================

/// 玻璃下拉的「字段」按钮：一块填充玻璃，显示当前值 + 下拉箭头，Enter /
/// 手柄 A / 点击都打开玻璃菜单。
Widget _glassDropdownField(
  BuildContext context, {
  required Widget value,
  required VoidCallback? onTap,
  required FocusNode? focusNode,
  required bool autofocus,
  required bool expanded,
  required bool dense,
  required String semanticLabel,
  Widget? leading,
  Widget? icon,
  Color? iconColor,
  double iconSize = 24,
  TextStyle? style,
  AlignmentGeometry alignment = AlignmentDirectional.centerStart,
  EdgeInsetsGeometry? padding,
}) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme cs = theme.colorScheme;
  final bool enabled = onTap != null;
  final Color fg = enabled
      ? cs.onSurface
      : cs.onSurface.withValues(alpha: 0.38);
  final Widget row = Row(
    mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
    children: <Widget>[
      if (leading != null) ...<Widget>[leading, const SizedBox(width: 8)],
      if (expanded)
        Expanded(
          child: Align(alignment: alignment, child: value),
        )
      else
        Flexible(child: value),
      const SizedBox(width: 4),
      icon ?? const Icon(Icons.arrow_drop_down),
    ],
  );
  return GlassButton.custom(
    onTap: onTap ?? () {},
    enabled: enabled,
    style: GlassButtonStyle.filled,
    quality: fushiGlassQuality(context),
    shape: const LiquidRoundedSuperellipse(borderRadius: 14),
    stretch: 0,
    focusNode: focusNode,
    autofocus: autofocus,
    label: semanticLabel,
    alignment: alignment,
    child: IconTheme.merge(
      data: IconThemeData(
        color: iconColor ?? (enabled ? cs.onSurfaceVariant : fg),
        size: iconSize,
      ),
      child: DefaultTextStyle(
        style: (style ?? theme.textTheme.bodyLarge ?? const TextStyle())
            .copyWith(color: style?.color ?? fg),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: dense ? 36 : 44),
          child: Padding(
            padding:
                padding ??
                EdgeInsets.symmetric(horizontal: 14, vertical: dense ? 4 : 8),
            child: row,
          ),
        ),
      ),
    ),
  );
}

/// 以 [anchor] 的渲染盒为锚、菜单至少与锚同宽，向下展开。
PopupMenuPositionBuilder _belowAnchor(BuildContext anchor) {
  return (BuildContext _, BoxConstraints __) {
    final RenderBox box = anchor.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
    final Offset topLeft = box.localToGlobal(
      Offset(0, box.size.height + 4),
      ancestor: overlay,
    );
    return RelativeRect.fromRect(
      topLeft & Size(box.size.width, 0),
      Offset.zero & overlay.size,
    );
  };
}

double _anchorWidth(BuildContext anchor) {
  final RenderObject? box = anchor.findRenderObject();
  return box is RenderBox && box.hasSize ? box.size.width : 0;
}

/// [DropdownButton] 的设计系统分派版。玻璃下是一块玻璃字段 + 玻璃菜单
/// （[DropdownMenuItem] 映射成同值的 [PopupMenuItem]）。
class FushiDropdownButton<T> extends StatefulWidget {
  const FushiDropdownButton({
    super.key,
    required this.items,
    this.selectedItemBuilder,
    this.value,
    this.hint,
    this.disabledHint,
    required this.onChanged,
    this.onTap,
    this.elevation = 8,
    this.style,
    this.underline,
    this.icon,
    this.iconDisabledColor,
    this.iconEnabledColor,
    this.iconSize = 24.0,
    this.isDense = false,
    this.isExpanded = false,
    this.itemHeight = kMinInteractiveDimension,
    this.menuWidth,
    this.focusColor,
    this.focusNode,
    this.autofocus = false,
    this.dropdownColor,
    this.menuMaxHeight,
    this.enableFeedback,
    this.alignment = AlignmentDirectional.centerStart,
    this.borderRadius,
    this.padding,
    this.barrierDismissible = true,
    this.mouseCursor,
    this.dropdownMenuItemMouseCursor,
  });

  final List<DropdownMenuItem<T>>? items;
  final DropdownButtonBuilder? selectedItemBuilder;
  final T? value;
  final Widget? hint;
  final Widget? disabledHint;
  final ValueChanged<T?>? onChanged;
  final VoidCallback? onTap;
  final int elevation;
  final TextStyle? style;
  final Widget? underline;
  final Widget? icon;
  final Color? iconDisabledColor;
  final Color? iconEnabledColor;
  final double iconSize;
  final bool isDense;
  final bool isExpanded;
  final double? itemHeight;
  final double? menuWidth;
  final Color? focusColor;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? dropdownColor;
  final double? menuMaxHeight;
  final bool? enableFeedback;
  final AlignmentGeometry alignment;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool barrierDismissible;
  final MouseCursor? mouseCursor;
  final MouseCursor? dropdownMenuItemMouseCursor;

  @override
  State<FushiDropdownButton<T>> createState() => _FushiDropdownButtonState<T>();
}

class _FushiDropdownButtonState<T> extends State<FushiDropdownButton<T>> {
  bool get _enabled =>
      widget.onChanged != null &&
      widget.items != null &&
      widget.items!.isNotEmpty;

  int get _selectedIndex {
    final List<DropdownMenuItem<T>>? items = widget.items;
    if (items == null || widget.value == null) return -1;
    return items.indexWhere(
      (DropdownMenuItem<T> item) => item.value == widget.value,
    );
  }

  Future<void> _open(BuildContext anchor) async {
    widget.onTap?.call();
    final List<DropdownMenuItem<T>> items = widget.items!;
    final double width = widget.menuWidth ?? _anchorWidth(anchor);
    final _FushiDropdownSelection<T>? picked =
        await showFushiMenu<_FushiDropdownSelection<T>>(
          context: context,
          positionBuilder: _belowAnchor(anchor),
          initialValue: _selectedIndex >= 0
              ? _FushiDropdownSelection<T>(items[_selectedIndex].value)
              : null,
          constraints: BoxConstraints(
            minWidth: width,
            maxWidth: math.max(width, 5 * 56),
            maxHeight: widget.menuMaxHeight ?? double.infinity,
          ),
          items: <PopupMenuEntry<_FushiDropdownSelection<T>>>[
            for (final DropdownMenuItem<T> item in items)
              PopupMenuItem<_FushiDropdownSelection<T>>(
                value: _FushiDropdownSelection<T>(item.value),
                enabled: item.enabled,
                onTap: item.onTap,
                height: widget.itemHeight ?? kMinInteractiveDimension,
                child: item.child,
              ),
          ],
        );
    if (!mounted || picked == null) return;
    widget.onChanged?.call(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return DropdownButton<T>(
        items: widget.items,
        selectedItemBuilder: widget.selectedItemBuilder,
        value: widget.value,
        hint: widget.hint,
        disabledHint: widget.disabledHint,
        onChanged: widget.onChanged,
        onTap: widget.onTap,
        elevation: widget.elevation,
        style: widget.style,
        underline: widget.underline,
        icon: widget.icon,
        iconDisabledColor: widget.iconDisabledColor,
        iconEnabledColor: widget.iconEnabledColor,
        iconSize: widget.iconSize,
        isDense: widget.isDense,
        isExpanded: widget.isExpanded,
        itemHeight: widget.itemHeight,
        menuWidth: widget.menuWidth,
        focusColor: widget.focusColor,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        dropdownColor: widget.dropdownColor,
        menuMaxHeight: widget.menuMaxHeight,
        enableFeedback: widget.enableFeedback,
        alignment: widget.alignment,
        borderRadius: widget.borderRadius,
        padding: widget.padding,
        barrierDismissible: widget.barrierDismissible,
        mouseCursor: widget.mouseCursor,
        dropdownMenuItemMouseCursor: widget.dropdownMenuItemMouseCursor,
      );
    }
    final int index = _selectedIndex;
    Widget value;
    if (index >= 0) {
      value = widget.selectedItemBuilder != null
          ? widget.selectedItemBuilder!(context)[index]
          : widget.items![index].child;
    } else {
      value =
          (_enabled ? widget.hint : (widget.disabledHint ?? widget.hint)) ??
          const SizedBox.shrink();
    }
    return Builder(
      builder: (BuildContext anchor) => _glassDropdownField(
        anchor,
        value: value,
        onTap: _enabled ? () => _open(anchor) : null,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        expanded: widget.isExpanded,
        dense: widget.isDense,
        semanticLabel: '',
        icon: widget.icon,
        iconColor: _enabled
            ? widget.iconEnabledColor
            : widget.iconDisabledColor,
        iconSize: widget.iconSize,
        style: widget.style,
        alignment: widget.alignment,
        padding: widget.padding,
      ),
    );
  }
}

/// 菜单值的盒子：让 `null` 也能是一个可选值（路由返回 null 只表示取消）。
@immutable
class _FushiDropdownSelection<T> {
  const _FushiDropdownSelection(this.value);

  final T? value;

  @override
  bool operator ==(Object other) =>
      other is _FushiDropdownSelection<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// [DropdownMenu] 的设计系统分派版。玻璃下是玻璃字段（标签 + 当前项）+ 玻璃
/// 菜单；不提供输入过滤 / 搜索（仓库调用点都是纯选择）。选中后同步写回
/// [controller]（若给了）并回调 [onSelected]。
class FushiDropdownMenu<T> extends StatefulWidget {
  const FushiDropdownMenu({
    super.key,
    this.enabled = true,
    this.width,
    this.menuHeight,
    this.leadingIcon,
    this.trailingIcon,
    this.showTrailingIcon = true,
    this.trailingIconFocusNode,
    this.label,
    this.hintText,
    this.helperText,
    this.errorText,
    this.selectedTrailingIcon,
    this.enableFilter = false,
    this.enableSearch = true,
    this.keyboardType,
    this.textStyle,
    this.textAlign = TextAlign.start,
    this.inputDecorationTheme,
    this.decorationBuilder,
    this.menuStyle,
    this.controller,
    this.initialSelection,
    this.onSelected,
    this.focusNode,
    this.requestFocusOnTap,
    this.selectOnly = false,
    this.expandedInsets,
    this.filterCallback,
    this.searchCallback,
    this.alignmentOffset,
    required this.dropdownMenuEntries,
    this.inputFormatters,
    this.closeBehavior = DropdownMenuCloseBehavior.all,
    this.maxLines = 1,
    this.textInputAction,
    this.cursorHeight,
    this.restorationId,
    this.menuController,
    this.scrollPadding = const EdgeInsets.all(20.0),
  });

  final bool enabled;
  final double? width;
  final double? menuHeight;
  final Widget? leadingIcon;
  final Widget? trailingIcon;
  final bool showTrailingIcon;
  final FocusNode? trailingIconFocusNode;
  final Widget? label;
  final String? hintText;
  final String? helperText;
  final String? errorText;
  final Widget? selectedTrailingIcon;
  final bool enableFilter;
  final bool enableSearch;
  final TextInputType? keyboardType;
  final TextStyle? textStyle;
  final TextAlign textAlign;
  final Object? inputDecorationTheme;
  final DropdownMenuDecorationBuilder? decorationBuilder;
  final MenuStyle? menuStyle;
  final TextEditingController? controller;
  final T? initialSelection;
  final ValueChanged<T?>? onSelected;
  final FocusNode? focusNode;
  final bool? requestFocusOnTap;
  final bool selectOnly;
  final EdgeInsetsGeometry? expandedInsets;
  final FilterCallback<T>? filterCallback;
  final SearchCallback<T>? searchCallback;
  final Offset? alignmentOffset;
  final List<DropdownMenuEntry<T>> dropdownMenuEntries;
  final List<TextInputFormatter>? inputFormatters;
  final DropdownMenuCloseBehavior closeBehavior;
  final int? maxLines;
  final TextInputAction? textInputAction;
  final double? cursorHeight;
  final String? restorationId;
  final MenuController? menuController;
  final EdgeInsets scrollPadding;

  @override
  State<FushiDropdownMenu<T>> createState() => _FushiDropdownMenuState<T>();
}

class _FushiDropdownMenuState<T> extends State<FushiDropdownMenu<T>> {
  late T? _selected = widget.initialSelection;

  @override
  void didUpdateWidget(FushiDropdownMenu<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSelection != widget.initialSelection) {
      _selected = widget.initialSelection;
    }
  }

  DropdownMenuEntry<T>? get _selectedEntry {
    for (final DropdownMenuEntry<T> e in widget.dropdownMenuEntries) {
      if (e.value == _selected) return e;
    }
    return null;
  }

  Future<void> _open(BuildContext anchor) async {
    final double width = _anchorWidth(anchor);
    final DropdownMenuEntry<T>? current = _selectedEntry;
    final _FushiDropdownSelection<T>? picked =
        await showFushiMenu<_FushiDropdownSelection<T>>(
          context: context,
          positionBuilder: _belowAnchor(anchor),
          initialValue: current == null
              ? null
              : _FushiDropdownSelection<T>(current.value),
          constraints: BoxConstraints(
            minWidth: width,
            maxWidth: math.max(width, 5 * 56),
            maxHeight: widget.menuHeight ?? double.infinity,
          ),
          items: <PopupMenuEntry<_FushiDropdownSelection<T>>>[
            for (final DropdownMenuEntry<T> e in widget.dropdownMenuEntries)
              PopupMenuItem<_FushiDropdownSelection<T>>(
                value: _FushiDropdownSelection<T>(e.value),
                enabled: e.enabled,
                child: Row(
                  children: <Widget>[
                    if (e.leadingIcon != null) ...<Widget>[
                      e.leadingIcon!,
                      const SizedBox(width: 12),
                    ],
                    Expanded(child: e.labelWidget ?? Text(e.label)),
                    if (e.trailingIcon != null) ...<Widget>[
                      const SizedBox(width: 12),
                      e.trailingIcon!,
                    ],
                  ],
                ),
              ),
          ],
        );
    if (!mounted || picked == null) return;
    setState(() => _selected = picked.value);
    final DropdownMenuEntry<T>? entry = _selectedEntry;
    if (widget.controller != null && entry != null) {
      widget.controller!.text = entry.label;
    }
    widget.onSelected?.call(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return DropdownMenu<T>(
        enabled: widget.enabled,
        width: widget.width,
        menuHeight: widget.menuHeight,
        leadingIcon: widget.leadingIcon,
        trailingIcon: widget.trailingIcon,
        showTrailingIcon: widget.showTrailingIcon,
        trailingIconFocusNode: widget.trailingIconFocusNode,
        label: widget.label,
        hintText: widget.hintText,
        helperText: widget.helperText,
        errorText: widget.errorText,
        selectedTrailingIcon: widget.selectedTrailingIcon,
        enableFilter: widget.enableFilter,
        enableSearch: widget.enableSearch,
        keyboardType: widget.keyboardType,
        textStyle: widget.textStyle,
        textAlign: widget.textAlign,
        inputDecorationTheme: widget.inputDecorationTheme,
        decorationBuilder: widget.decorationBuilder,
        menuStyle: widget.menuStyle,
        controller: widget.controller,
        initialSelection: widget.initialSelection,
        onSelected: widget.onSelected,
        focusNode: widget.focusNode,
        requestFocusOnTap: widget.requestFocusOnTap,
        selectOnly: widget.selectOnly,
        expandedInsets: widget.expandedInsets,
        filterCallback: widget.filterCallback,
        searchCallback: widget.searchCallback,
        alignmentOffset: widget.alignmentOffset,
        dropdownMenuEntries: widget.dropdownMenuEntries,
        inputFormatters: widget.inputFormatters,
        closeBehavior: widget.closeBehavior,
        maxLines: widget.maxLines,
        textInputAction: widget.textInputAction,
        cursorHeight: widget.cursorHeight,
        restorationId: widget.restorationId,
        menuController: widget.menuController,
        scrollPadding: widget.scrollPadding,
      );
    }
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final DropdownMenuEntry<T>? entry = _selectedEntry;
    final Widget current = entry != null
        ? (entry.labelWidget ?? Text(entry.label))
        : Text(
            widget.hintText ?? '',
            style: TextStyle(color: cs.onSurfaceVariant),
          );
    final Widget value = widget.label == null
        ? current
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DefaultTextStyle.merge(
                style: (theme.textTheme.labelSmall ?? const TextStyle())
                    .copyWith(color: cs.onSurfaceVariant),
                child: widget.label!,
              ),
              current,
            ],
          );
    final bool expanded = widget.expandedInsets != null;
    Widget field = Builder(
      builder: (BuildContext anchor) => _glassDropdownField(
        anchor,
        value: value,
        onTap: widget.enabled && widget.dropdownMenuEntries.isNotEmpty
            ? () => _open(anchor)
            : null,
        focusNode: widget.focusNode,
        autofocus: false,
        expanded: expanded || widget.width != null,
        dense: false,
        semanticLabel: entry?.label ?? widget.hintText ?? '',
        leading: widget.leadingIcon,
        icon: widget.showTrailingIcon
            ? (widget.trailingIcon ?? const Icon(Icons.arrow_drop_down))
            : const SizedBox.shrink(),
        style: widget.textStyle,
      ),
    );
    if (widget.width != null && !expanded) {
      field = SizedBox(width: widget.width, child: field);
    }
    final String? note = widget.errorText ?? widget.helperText;
    if (note != null) {
      field = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          field,
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Text(
              note,
              style: (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: widget.errorText != null
                    ? cs.error
                    : cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }
    if (expanded) {
      field = Padding(padding: widget.expandedInsets!, child: field);
    }
    return field;
  }
}

// ===========================================================================
// SnackBar
// ===========================================================================

/// [SnackBar] 的设计系统分派版。**必须仍是 SnackBar**（调用点是
/// `ScaffoldMessenger.showSnackBar(...)`，类型签名只收 SnackBar），构造参数
/// 与父类逐个一致。构造时拿不到 context，所以分派推迟到 build：[content]
/// 与 [action] 的 getter 返回包装 widget，各自在 build 时判 [isGlassDesign]——
/// MD3 下原样渲染原内容 / 原 [SnackBarAction]（像素不变）；玻璃下内容进玻璃
/// 胶囊、动作按钮收进胶囊（玻璃文字按钮），SnackBar 自己的动作槽让空。
///
/// SnackBar 自身的 Material 底色要在主题里清成透明（`snackBarTheme`
/// backgroundColor 透明 + elevation 0），否则胶囊外还有一层底。
class FushiSnackBar extends SnackBar {
  const FushiSnackBar({
    super.key,
    required super.content,
    super.backgroundColor,
    super.elevation,
    super.margin,
    super.padding,
    super.width,
    super.shape,
    super.hitTestBehavior,
    super.behavior,
    super.action,
    super.actionOverflowThreshold,
    super.showCloseIcon,
    super.closeIconColor,
    super.duration,
    super.persist,
    super.animation,
    super.onVisible,
    super.dismissDirection,
    super.clipBehavior,
  });

  @override
  Widget get content =>
      _FushiSnackBarContent(content: super.content, action: super.action);

  @override
  SnackBarAction? get action {
    final SnackBarAction? raw = super.action;
    return raw == null ? null : _FushiSnackBarAction(raw);
  }
}

class _FushiSnackBarContent extends StatelessWidget {
  const _FushiSnackBarContent({required this.content, required this.action});

  final Widget content;
  final SnackBarAction? action;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) return content;
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      settings: fushiGlassSettings(context, tint: cs.surfaceContainerHighest),
      shape: const LiquidRoundedSuperellipse(borderRadius: 20),
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: action != null ? 4 : 12,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: DefaultTextStyle(
              style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                color: cs.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: cs.onSurfaceVariant),
                child: content,
              ),
            ),
          ),
          if (action != null) ...<Widget>[
            const SizedBox(width: 8),
            _FushiGlassSnackBarActionButton(action: action!),
          ],
        ],
      ),
    );
  }
}

/// SnackBar 自己动作槽里的那一个：MD3 下原样渲染原 [SnackBarAction]，
/// 玻璃下让空（动作已在玻璃胶囊里）。
class _FushiSnackBarAction extends SnackBarAction {
  _FushiSnackBarAction(this.raw)
    : super(
        textColor: raw.textColor,
        disabledTextColor: raw.disabledTextColor,
        backgroundColor: raw.backgroundColor,
        disabledBackgroundColor: raw.disabledBackgroundColor,
        label: raw.label,
        onPressed: raw.onPressed,
      );

  final SnackBarAction raw;

  @override
  State<SnackBarAction> createState() => _FushiSnackBarActionState();
}

class _FushiSnackBarActionState extends State<SnackBarAction> {
  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return const SizedBox.shrink();
    return (widget as _FushiSnackBarAction).raw;
  }
}

class _FushiGlassSnackBarActionButton extends StatefulWidget {
  const _FushiGlassSnackBarActionButton({required this.action});

  final SnackBarAction action;

  @override
  State<_FushiGlassSnackBarActionButton> createState() =>
      _FushiGlassSnackBarActionButtonState();
}

class _FushiGlassSnackBarActionButtonState
    extends State<_FushiGlassSnackBarActionButton> {
  bool _triggered = false;

  void _handlePressed() {
    if (_triggered) return;
    setState(() => _triggered = true);
    widget.action.onPressed();
    ScaffoldMessenger.of(
      context,
    ).hideCurrentSnackBar(reason: SnackBarClosedReason.action);
  }

  @override
  Widget build(BuildContext context) {
    final Color? textColor = widget.action.textColor;
    return FushiTextButton(
      onPressed: _triggered ? null : _handlePressed,
      style: textColor == null
          ? null
          : ButtonStyle(
              foregroundColor: WidgetStatePropertyAll<Color>(textColor),
            ),
      child: Text(widget.action.label),
    );
  }
}

/// [DropdownButtonFormField] 的设计系统分派版。MD3 下原样构造原控件；玻璃
/// 下是 [FormField] + [FushiDropdownButton]（玻璃字段 + 玻璃菜单），
/// `decoration` 的 labelText / label / hintText / helperText / errorText /
/// prefixIcon / suffixIcon 画在字段周围，validator / onSaved /
/// autovalidateMode 语义与原控件一致。
class FushiDropdownButtonFormField<T> extends StatelessWidget {
  const FushiDropdownButtonFormField({
    super.key,
    required this.items,
    this.selectedItemBuilder,
    @Deprecated('Use initialValue instead.') this.value,
    this.initialValue,
    this.hint,
    this.disabledHint,
    required this.onChanged,
    this.onTap,
    this.elevation = 8,
    this.style,
    this.icon,
    this.iconDisabledColor,
    this.iconEnabledColor,
    this.iconSize = 24.0,
    this.isDense = true,
    this.isExpanded = false,
    this.itemHeight,
    this.focusColor,
    this.focusNode,
    this.autofocus = false,
    this.dropdownColor,
    this.decoration,
    this.onSaved,
    this.validator,
    this.errorBuilder,
    this.forceErrorText,
    this.autovalidateMode,
    this.menuMaxHeight,
    this.enableFeedback,
    this.alignment = AlignmentDirectional.centerStart,
    this.borderRadius,
    this.padding,
    this.barrierDismissible = true,
    this.mouseCursor,
    this.dropdownMenuItemMouseCursor,
  });

  final List<DropdownMenuItem<T>>? items;
  final DropdownButtonBuilder? selectedItemBuilder;
  final T? value;
  final T? initialValue;
  final Widget? hint;
  final Widget? disabledHint;
  final ValueChanged<T?>? onChanged;
  final VoidCallback? onTap;
  final int elevation;
  final TextStyle? style;
  final Widget? icon;
  final Color? iconDisabledColor;
  final Color? iconEnabledColor;
  final double iconSize;
  final bool isDense;
  final bool isExpanded;
  final double? itemHeight;
  final Color? focusColor;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? dropdownColor;
  final InputDecoration? decoration;
  final FormFieldSetter<T>? onSaved;
  final FormFieldValidator<T>? validator;
  final FormFieldErrorBuilder? errorBuilder;
  final String? forceErrorText;
  final AutovalidateMode? autovalidateMode;
  final double? menuMaxHeight;
  final bool? enableFeedback;
  final AlignmentGeometry alignment;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool barrierDismissible;
  final MouseCursor? mouseCursor;
  final MouseCursor? dropdownMenuItemMouseCursor;

  // ignore: deprecated_member_use_from_same_package
  T? get _initial => initialValue ?? value;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return DropdownButtonFormField<T>(
        items: items,
        selectedItemBuilder: selectedItemBuilder,
        initialValue: _initial,
        hint: hint,
        disabledHint: disabledHint,
        onChanged: onChanged,
        onTap: onTap,
        elevation: elevation,
        style: style,
        icon: icon,
        iconDisabledColor: iconDisabledColor,
        iconEnabledColor: iconEnabledColor,
        iconSize: iconSize,
        isDense: isDense,
        isExpanded: isExpanded,
        itemHeight: itemHeight,
        focusColor: focusColor,
        focusNode: focusNode,
        autofocus: autofocus,
        dropdownColor: dropdownColor,
        decoration: decoration,
        onSaved: onSaved,
        validator: validator,
        errorBuilder: errorBuilder,
        forceErrorText: forceErrorText,
        autovalidateMode: autovalidateMode,
        menuMaxHeight: menuMaxHeight,
        enableFeedback: enableFeedback,
        alignment: alignment,
        borderRadius: borderRadius,
        padding: padding,
        barrierDismissible: barrierDismissible,
        mouseCursor: mouseCursor,
        dropdownMenuItemMouseCursor: dropdownMenuItemMouseCursor,
      );
    }
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final InputDecoration deco = decoration ?? const InputDecoration();
    return FormField<T>(
      initialValue: _initial,
      onSaved: onSaved,
      validator: validator,
      errorBuilder: errorBuilder,
      forceErrorText: forceErrorText,
      autovalidateMode: autovalidateMode,
      enabled: deco.enabled && onChanged != null,
      builder: (FormFieldState<T> field) {
        final Widget? label = deco.label ??
            (deco.labelText == null ? null : Text(deco.labelText!));
        final String? error = field.errorText ?? deco.errorText;
        final String? helper = deco.helperText;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (label != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: DefaultTextStyle.merge(
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: error != null ? cs.error : cs.onSurfaceVariant,
                  ),
                  child: label,
                ),
              ),
            Row(
              children: <Widget>[
                if (deco.prefixIcon != null) ...<Widget>[
                  deco.prefixIcon!,
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FushiDropdownButton<T>(
                    items: items,
                    selectedItemBuilder: selectedItemBuilder,
                    value: field.value,
                    hint: hint ??
                        (deco.hintText == null ? null : Text(deco.hintText!)),
                    disabledHint: disabledHint,
                    onChanged: onChanged == null
                        ? null
                        : (T? v) {
                            field.didChange(v);
                            onChanged!(v);
                          },
                    onTap: onTap,
                    style: style,
                    icon: icon,
                    iconDisabledColor: iconDisabledColor,
                    iconEnabledColor: iconEnabledColor,
                    iconSize: iconSize,
                    isDense: isDense,
                    isExpanded: true,
                    itemHeight: itemHeight,
                    focusNode: focusNode,
                    autofocus: autofocus,
                    menuMaxHeight: menuMaxHeight,
                    enableFeedback: enableFeedback,
                    alignment: alignment,
                    padding: padding,
                    barrierDismissible: barrierDismissible,
                  ),
                ),
                if (deco.suffixIcon != null) ...<Widget>[
                  const SizedBox(width: 8),
                  deco.suffixIcon!,
                ],
              ],
            ),
            if (error != null || helper != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 6),
                child: Text(
                  error ?? helper!,
                  maxLines: deco.helperMaxLines ?? deco.errorMaxLines ?? 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: error != null ? cs.error : cs.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
