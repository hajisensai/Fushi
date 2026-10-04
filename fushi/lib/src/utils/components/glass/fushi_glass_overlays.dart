import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 浮层族（对话框 / 弹出菜单 / 下拉 / 提示条）的「设计系统分派」包装：构造参数
// 与 Material 原控件逐个同名同型，调用点只改类名。MD3 设计系统下原样构造原控件
// （像素、焦点、语义一字不差）；「玻璃」设计系统下按 iOS 26 形态渲染：对话框是
// 大圆角（32）玻璃 alert、菜单是 GlassMenu 式玻璃面板（行高 44、行尾对勾、
// 细分隔线）、下拉是 pull-down 按钮、提示条是底部居中的玻璃胶囊。交互骨架
// （路由、焦点陷阱、Esc 关闭、方向键在菜单项间移动、Enter / 手柄 A 激活）保持
// 框架原生链路不变。

/// iOS 26 alert 的圆角（大圆角玻璃面板）。
const double _kGlassDialogRadius = 32;

/// iOS 26 alert 内边距基准。
const double _kGlassDialogPad = 22;

/// iOS 26 alert 宽度：纯文字 alert 固定在 270–320 之间。
const double _kGlassAlertMinWidth = 270;
const double _kGlassAlertMaxWidth = 320;

/// 带表单 / 列表等复杂内容的对话框上限（窄到 320 会挤坏内容）。
const double _kGlassDialogFormMaxWidth = 520;

/// 与 Material [Dialog] 相同的默认外边距。
const EdgeInsets _kDialogInsetPadding = EdgeInsets.symmetric(
  horizontal: 40,
  vertical: 24,
);

/// 浮层面板（对话框 / 菜单 / 提示条）的玻璃参数。液态档沿用库 Messages
/// 演示里 `_kMenuGlass` 的 iOS 26 实测值（深色 #262626 @50%、浅色白 @15%、
/// blur 8），但对话框要承载大段文字，玻璃色更厚（深 @82% / 浅 @72%）以保证
/// 可读；磨砂 / 关闭档直接用作用域的实底玻璃。[tint] 为调用方显式背景色。
LiquidGlassSettings _overlayGlassSettings(
  BuildContext context, {
  bool thick = false,
  Color? tint,
}) {
  final LiquidGlassSettings base = fushiGlassSettings(context, tint: tint);
  if (tint != null || glassMaterialOf(context) != FushiGlassMaterial.liquid) {
    return base;
  }
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return base.copyWith(
    glassColor: dark
        ? const Color(0xFF262626).withValues(alpha: thick ? 0.82 : 0.5)
        : Colors.white.withValues(alpha: thick ? 0.72 : 0.15),
    blur: thick ? 14 : 8,
    thickness: dark ? 25 : 18,
  );
}

/// 菜单面板圆角：iOS 26 GlassMenu 32，桌面（macOS 26 菜单）收到 22。
double _menuRadius(BuildContext context) =>
    fushiAppleCompact(context) ? 22 : 32;

/// 菜单行高：iOS 44，桌面 32。
double _menuRowHeight(BuildContext context) =>
    fushiAppleCompact(context) ? 32 : 44;

// ===========================================================================
// 对话框
// ===========================================================================

/// 玻璃对话框外壳：布局语义照抄 Material [Dialog]（键盘让位、外边距、对齐、
/// 尺寸约束、语义角色），表面换成大圆角（32）prominent 玻璃面板。内部垫一层
/// 透明 [Material]，让内容里的 InkWell / ListTile 等仍有墨水宿主。
class _FushiGlassDialogShell extends StatelessWidget {
  const _FushiGlassDialogShell({
    required this.child,
    this.tint,
    this.insetPadding,
    this.alignment,
    this.constraints,
    this.defaultConstraints = const BoxConstraints(minWidth: 280),
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
  final BoxConstraints defaultConstraints;
  final Clip? clipBehavior;
  final SemanticsRole semanticsRole;
  final Duration insetAnimationDuration;
  final Curve insetAnimationCurve;
  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    final DialogThemeData dialogTheme = DialogTheme.of(context);
    final Color? explicitTint = tint != null && tint!.a > 0 ? tint : null;
    final Widget surface = GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      settings: _overlayGlassSettings(context, thick: true, tint: explicitTint),
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
                  constraints ?? dialogTheme.constraints ?? defaultConstraints,
              child: surface,
            ),
          ),
        ),
      ),
    );
  }
}

/// iOS 26 alert 标题：17 semibold，label 色。
TextStyle _glassDialogTitleStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return (theme.textTheme.titleLarge ?? const TextStyle()).copyWith(
    fontSize: fushiAppleCompact(context) ? 15 : 17,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: appleColorsOf(context).label,
  );
}

/// iOS 26 alert 正文：15（桌面 13），label 色（iOS alert 正文不灰）。
TextStyle _glassDialogContentStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: fushiAppleCompact(context) ? 13 : 15,
    color: appleColorsOf(context).label,
    height: 1.35,
  );
}

/// 内容是不是「纯文字」：是的话按 iOS alert 居中排版、宽度收进 270–320；
/// 否则（表单 / 列表 / 自绘）按表单式对话框排版（左对齐、宽度放宽）。
bool _isPlainTextContent(Widget? content) =>
    content == null ||
    content is Text ||
    content is SelectableText ||
    content is RichText;

/// 动作是不是按钮：全部是按钮时才按 iOS 26 alert 排成撑满的胶囊（两个并排、
/// 其余竖排）；夹了 Spacer / 复选框等自定义控件就保留调用方的横排布局。
bool _isAlertButton(Widget w) =>
    w is FushiTextButton ||
    w is FushiFilledButton ||
    w is FushiOutlinedButton ||
    w is TextButton ||
    w is FilledButton ||
    w is ElevatedButton ||
    w is OutlinedButton;

/// iOS 26 alert 的动作区：一个按钮撑满；两个按钮并排等宽；三个及以上竖排。
/// 全部包在 [FushiAlertActionScope] 里，按钮自己画成 alert 胶囊。
Widget _glassAlertActions(BuildContext context, List<Widget> actions) {
  const double gap = 10;
  Widget layout;
  if (actions.length == 2) {
    layout = Row(
      children: <Widget>[
        Expanded(child: actions[0]),
        const SizedBox(width: gap),
        Expanded(child: actions[1]),
      ],
    );
  } else {
    layout = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < actions.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: gap),
          actions[i],
        ],
      ],
    );
  }
  return FushiAlertActionScope(child: layout);
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
  }) : scrollController = null,
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
            insetPadding ??
            const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
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

  /// iOS 26 alert：大圆角玻璃面板，标题 17 semibold 居中、正文居中，动作是
  /// 底部撑满的胶囊（两个并排、多个竖排；主操作强调色、破坏性红字）。内容
  /// 不是纯文字（表单 / 列表）时退成表单式：标题仍居中，内容左对齐、宽度放宽。
  Widget _buildGlass(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final DialogThemeData dialogTheme = DialogTheme.of(context);
    const double pad = _kGlassDialogPad;
    final bool alertText = _isPlainTextContent(content);
    final TextAlign contentAlign = alertText
        ? TextAlign.center
        : TextAlign.start;

    Widget? iconWidget;
    Widget? titleWidget;
    Widget? contentWidget;
    Widget? actionsWidget;

    if (icon != null) {
      iconWidget = Padding(
        padding:
            iconPadding ??
            EdgeInsets.fromLTRB(pad, pad, pad, title != null ? 10 : 0),
        child: Center(
          child: IconTheme(
            data: IconThemeData(
              color: iconColor ?? dialogTheme.iconColor ?? apple.accent,
              size: 30,
            ),
            child: icon!,
          ),
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
              content == null ? pad : 0,
            ),
        child: DefaultTextStyle(
          style:
              titleTextStyle ??
              dialogTheme.titleTextStyle ??
              _glassDialogTitleStyle(context),
          textAlign: TextAlign.center,
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
              title == null && icon == null ? pad : 6,
              pad,
              pad,
            ),
        child: DefaultTextStyle(
          style:
              contentTextStyle ??
              dialogTheme.contentTextStyle ??
              _glassDialogContentStyle(context),
          textAlign: contentAlign,
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            child: content,
          ),
        ),
      );
    }

    final List<Widget>? acts = actions;
    if (acts != null && acts.isNotEmpty) {
      final EdgeInsetsGeometry padding =
          actionsPadding ??
          dialogTheme.actionsPadding ??
          const EdgeInsets.fromLTRB(16, 0, 16, 16);
      if (acts.every(_isAlertButton)) {
        actionsWidget = Padding(
          padding: padding,
          child: _glassAlertActions(context, acts),
        );
      } else {
        final double spacing = (buttonPadding?.horizontal ?? 16) / 2;
        actionsWidget = Padding(
          padding: padding,
          child: OverflowBar(
            alignment: actionsAlignment ?? MainAxisAlignment.end,
            spacing: spacing,
            overflowAlignment:
                actionsOverflowAlignment ?? OverflowBarAlignment.end,
            overflowDirection:
                actionsOverflowDirection ?? VerticalDirection.down,
            overflowSpacing: actionsOverflowButtonSpacing ?? 0,
            children: acts,
          ),
        );
      }
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

    Widget dialogChild = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: columnChildren,
    );
    // 纯文字 alert 宽度固定（iOS 不随文字伸缩）；表单式按内容取宽。
    if (!alertText) dialogChild = IntrinsicWidth(child: dialogChild);
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
      defaultConstraints: alertText
          ? BoxConstraints(
              minWidth: _kGlassAlertMinWidth,
              maxWidth: fushiAppleCompact(context) ? _kGlassAlertMaxWidth : 300,
            )
          : const BoxConstraints(
              minWidth: 300,
              maxWidth: _kGlassDialogFormMaxWidth,
            ),
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
      stepWidth: 20,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 270),
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
                  textAlign: TextAlign.center,
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

/// [SimpleDialogOption] 的设计系统分派版。玻璃下是一条 iOS 菜单式选项行
/// （无底，悬停 / 焦点 / 按下铺中性灰高亮，Enter / 手柄 A 走 ActivateIntent）。
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
    final FushiAppleColors apple = appleColorsOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _AppleMenuRow(
        onTap: onPressed ?? () {},
        enabled: onPressed != null,
        minHeight: _menuRowHeight(context),
        radius: 14,
        padding:
            padding ?? const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            color: onPressed != null ? apple.label : apple.tertiaryLabel,
          ),
          child: child ?? const SizedBox.shrink(),
        ),
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

/// iOS 26 菜单 / 列表选项行：无底，悬停 / 键盘焦点 / 按下时铺一层中性灰
/// （systemFill）圆角高亮，左起内容、[trailing] 在行尾（选中对勾）。自带焦点
/// 节点，[ActivateIntent]（Enter / 手柄 A）与点击都触发 [onTap]。
class _AppleMenuRow extends StatefulWidget {
  const _AppleMenuRow({
    required this.onTap,
    required this.enabled,
    required this.minHeight,
    required this.radius,
    required this.padding,
    required this.child,
    this.trailing,
    this.mouseCursor,
  });

  final VoidCallback onTap;
  final bool enabled;
  final double minHeight;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Widget child;
  final Widget? trailing;
  final MouseCursor? mouseCursor;

  @override
  State<_AppleMenuRow> createState() => _AppleMenuRowState();
}

class _AppleMenuRowState extends State<_AppleMenuRow> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _set(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool enabled = widget.enabled;
    final bool highlight = enabled && (_hovered || _focused || _pressed);
    final Widget body = AnimatedContainer(
      duration: _pressed ? Duration.zero : const Duration(milliseconds: 120),
      constraints: BoxConstraints(minHeight: widget.minHeight),
      padding: widget.padding,
      decoration: BoxDecoration(
        color: highlight
            ? (_pressed ? apple.fill : apple.secondaryFill)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        children: <Widget>[
          Expanded(child: widget.child),
          if (widget.trailing != null) ...<Widget>[
            const SizedBox(width: 12),
            widget.trailing!,
          ],
        ],
      ),
    );
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled
          ? (widget.mouseCursor ?? SystemMouseCursors.click)
          : MouseCursor.defer,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            widget.onTap();
            return null;
          },
        ),
      },
      onShowHoverHighlight: (bool v) => _set(() => _hovered = v),
      onFocusChange: (bool v) => _set(() => _focused = v),
      child: Semantics(
        button: true,
        enabled: enabled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapDown: enabled ? (_) => _set(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => _set(() => _pressed = false) : null,
          onTapCancel: enabled ? () => _set(() => _pressed = false) : null,
          onTap: enabled ? widget.onTap : null,
          child: body,
        ),
      ),
    );
  }
}

/// iOS 26 菜单的组间细分隔线（separator 色，半像素，两侧内缩）。
Widget _appleMenuDivider(BuildContext context, double height) {
  return SizedBox(
    height: height,
    child: Center(
      child: Container(
        height: 0.5,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        color: appleColorsOf(context).separator,
      ),
    ),
  );
}

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

  /// 菜单项换成 iOS 26 GlassMenu 行：[PopupMenuItem]（含 [CheckedPopupMenuItem]
  /// 与仓库的 FushiPopupMenuItem 子类）渲染成整行宽的 [_AppleMenuRow]（行高
  /// 44 / 桌面 32，label 色文字，中性灰高亮），child 原样放进去；选中项
  /// （[CheckedPopupMenuItem.checked] 或 initialValue 对应项）行尾画
  /// `CupertinoIcons.checkmark`。点击语义同 Flutter 的
  /// `PopupMenuItemState.handleTap`（先 onTap 再带 value 关菜单）。
  /// [PopupMenuDivider] → 细分隔线。其它自定义 [PopupMenuEntry] 原样保留。
  Widget _glassEntry(
    BuildContext context,
    PopupMenuEntry<T> entry, {
    required bool highlighted,
  }) {
    final ThemeData theme = Theme.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    if (entry is PopupMenuDivider) {
      return _appleMenuDivider(context, compact ? 9 : 13);
    }
    if (entry is! PopupMenuItem<T>) return entry;
    final PopupMenuItem<T> item = entry;
    final bool checked =
        (item is CheckedPopupMenuItem<T> && item.checked) || highlighted;
    final Color fg = item.enabled ? apple.label : apple.tertiaryLabel;
    final double rowHeight = item.height == kMinInteractiveDimension
        ? _menuRowHeight(context)
        : item.height;
    final double rowRadius = _menuRadius(context) - 8;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _AppleMenuRow(
        onTap: () {
          item.onTap?.call();
          Navigator.pop<T>(context, item.value);
        },
        enabled: item.enabled,
        minHeight: rowHeight,
        radius: rowRadius,
        mouseCursor: item.mouseCursor,
        padding:
            item.padding ??
            EdgeInsets.symmetric(horizontal: compact ? 10 : 14, vertical: 4),
        trailing: checked
            ? FushiIcon(CupertinoIcons.checkmark, size: compact ? 14 : 17, color: fg)
            : null,
        child: IconTheme.merge(
          data: IconThemeData(color: fg, size: compact ? 16 : 20),
          child: DefaultTextStyle.merge(
            style:
                (item.labelTextStyle?.resolve(<WidgetState>{}) ??
                        theme.textTheme.bodyLarge ??
                        const TextStyle())
                    .copyWith(color: fg, fontSize: compact ? 14 : 17),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            child: item.child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final _FushiGlassMenuRoute<T> route = widget.route;
    final int initial = _initialIndex;
    final bool compact = fushiAppleCompact(context);
    final List<Widget> children = <Widget>[
      for (int i = 0; i < route.items.length; i++)
        Focus(
          focusNode: _entryNodes[i],
          child: _glassEntry(
            context,
            route.items[i],
            highlighted: i == initial,
          ),
        ),
    ];
    final double radius = _menuRadius(context);
    final Widget list = ConstrainedBox(
      constraints:
          route.constraints ??
          BoxConstraints(minWidth: compact ? 180 : 220, maxWidth: 300),
      child: IntrinsicWidth(
        stepWidth: 20,
        child: Semantics(
          role: SemanticsRole.menu,
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: route.semanticLabel,
          child: SingleChildScrollView(
            padding:
                route.menuPadding ??
                EdgeInsets.symmetric(vertical: compact ? 6 : 8),
            child: ListBody(children: children),
          ),
        ),
      ),
    );
    return FocusTraversalGroup(
      child: GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context, prominent: true),
        settings: _overlayGlassSettings(context),
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
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
      // 自定义触发器是 iOS plain 按钮（无底，按下变淡），不是玻璃块。
      Widget button = Semantics(
        expanded: _glassExpanded,
        child: FushiPlainButton(
          onPressed: widget.enabled ? showButtonMenu : null,
          borderRadius: BorderRadius.circular(12),
          semanticLabel: tooltip,
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
        // iOS 26 的「更多」是 SF ellipsis。
        child: widget.icon ?? const FushiIcon(CupertinoIcons.ellipsis),
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
/// 全部菜单项收进这一块 iOS 26 GlassMenu 式玻璃里（项仍是 MenuAnchor 的直接
/// 后代，方向键 / Esc / 子菜单行为不变）。菜单项（[MenuItemButton] 等）经
/// [MenuButtonTheme] 改成 iOS 菜单行：行高 44 / 桌面 32、label 色、中性灰
/// 圆角高亮。
class _FushiGlassMenuPanel extends StatelessWidget {
  const _FushiGlassMenuPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final double radius = _menuRadius(context);
    final ButtonStyle rowStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(
        Size(compact ? 180 : 220, _menuRowHeight(context)),
      ),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
      ),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius - 8)),
      ),
      backgroundColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      foregroundColor: WidgetStateProperty.resolveWith(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? apple.tertiaryLabel
            : apple.label,
      ),
      iconColor: WidgetStateProperty.resolveWith(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? apple.tertiaryLabel
            : apple.label,
      ),
      overlayColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        if (states.contains(WidgetState.pressed)) return apple.fill;
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return apple.secondaryFill;
        }
        return null;
      }),
      textStyle: WidgetStatePropertyAll<TextStyle>(
        TextStyle(fontSize: compact ? 14 : 17),
      ),
      splashFactory: NoSplash.splashFactory,
    );
    return GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      settings: _overlayGlassSettings(context),
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: MenuButtonTheme(
          data: MenuButtonThemeData(style: rowStyle),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 8,
              vertical: compact ? 6 : 8,
            ),
            child: IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
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
    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(32))),
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

/// MD3 下拉箭头一律换成 iOS pull-down 的 `chevron.up.chevron.down`；调用方
/// 给的其它图标（或显式隐藏用的空盒子）原样保留。
Widget _pullDownChevron(Widget? icon, double size) {
  final IconData? data = icon is Icon ? icon.icon : null;
  final bool materialArrow =
      data == Icons.arrow_drop_down ||
      data == Icons.expand_more ||
      data == Icons.keyboard_arrow_down ||
      data == Icons.arrow_drop_down_rounded;
  if (icon != null && !materialArrow) return icon;
  return FushiIcon(CupertinoIcons.chevron_up_chevron_down, size: size);
}

/// 玻璃下拉的「字段」按钮，iOS 26 pull-down 形态：
/// - [expanded]（表单里撑满的下拉，含 DropdownButtonFormField）= 与输入框同款
///   的实色字段（tertiarySystemFill 底、圆角 10），当前值 + 行尾
///   `chevron.up.chevron.down`；
/// - 否则是 plain pull-down 按钮：无底的当前值文字 + 小号上下箭头，悬停铺
///   中性灰。
/// 都不是 MD3 下划线框；Enter / 手柄 A / 点击都打开玻璃菜单。
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
  final FushiAppleColors apple = appleColorsOf(context);
  final bool compact = fushiAppleCompact(context);
  final bool enabled = onTap != null;
  final Color fg = enabled ? apple.label : apple.tertiaryLabel;
  final double chevronSize = compact ? 11 : 13;
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
      SizedBox(width: compact ? 4 : 6),
      IconTheme.merge(
        data: IconThemeData(
          color: iconColor ?? (enabled ? apple.secondaryLabel : fg),
          size: chevronSize,
        ),
        child: _pullDownChevron(icon, chevronSize),
      ),
    ],
  );
  Widget field = IconTheme.merge(
    data: IconThemeData(color: fg, size: compact ? 16 : 18),
    child: DefaultTextStyle(
      style:
          (style ??
                  theme.textTheme.bodyLarge?.copyWith(
                    fontSize: compact ? 14 : 17,
                  ) ??
                  const TextStyle())
              .copyWith(color: style?.color ?? fg),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: row,
    ),
  );
  final double minHeight = expanded
      ? (dense || compact ? 36 : 44)
      : (compact ? 28 : 34);
  field = Container(
    constraints: BoxConstraints(minHeight: minHeight),
    padding:
        padding ??
        EdgeInsets.symmetric(horizontal: expanded ? 12 : (compact ? 6 : 8)),
    alignment: expanded ? AlignmentDirectional.centerStart : null,
    decoration: expanded
        ? BoxDecoration(
            color: apple.tertiaryFill,
            borderRadius: BorderRadius.circular(10),
          )
        : null,
    child: field,
  );
  return FushiPlainButton(
    onPressed: onTap,
    focusNode: focusNode,
    autofocus: autofocus,
    borderRadius: BorderRadius.circular(expanded ? 10 : minHeight / 2),
    semanticLabel: semanticLabel.isEmpty ? null : semanticLabel,
    child: field,
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

/// [DropdownButton] 的设计系统分派版。玻璃下是 iOS 26 pull-down 按钮（当前值
/// + `chevron.up.chevron.down`，撑满时是实色字段）+ 玻璃菜单
/// （[DropdownMenuItem] 映射成同值的 [PopupMenuItem]，当前项行尾打勾）。
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

/// [DropdownMenu] 的设计系统分派版。玻璃下是 iOS pull-down 字段（标签 +
/// 当前项）+ 玻璃菜单；不提供输入过滤 / 搜索（仓库调用点都是纯选择）。选中后同步写回
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
    final FushiAppleColors apple = appleColorsOf(context);
    final DropdownMenuEntry<T>? entry = _selectedEntry;
    final Widget current = entry != null
        ? (entry.labelWidget ?? Text(entry.label))
        : Text(
            widget.hintText ?? '',
            style: TextStyle(color: apple.secondaryLabel),
          );
    final Widget value = widget.label == null
        ? current
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DefaultTextStyle.merge(
                style: (theme.textTheme.labelSmall ?? const TextStyle())
                    .copyWith(color: apple.secondaryLabel),
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
            ? widget.trailingIcon
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
                    ? apple.destructive
                    : apple.secondaryLabel,
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
/// MD3 下原样渲染原内容 / 原 [SnackBarAction]（像素不变）；玻璃下是 iOS 26
/// 式 toast：按内容取宽、底部居中的中性玻璃胶囊，动作是胶囊内的强调色 plain
/// 文字按钮，SnackBar 自己的动作槽让空。
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
    final FushiAppleColors apple = appleColorsOf(context);
    // 胶囊按内容取宽并居中（SnackBar 本身撑满宽度，胶囊不跟着撑）；单行时
    // 高 48、圆角 24 正好是全胶囊，多行退成圆角 24 的玻璃块。
    return Center(
      heightFactor: 1,
      child: GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context, prominent: true),
        settings: _overlayGlassSettings(context, thick: true),
        shape: const LiquidRoundedSuperellipse(borderRadius: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, maxWidth: 560),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: 20,
              end: action != null ? 8 : 20,
              top: 4,
              bottom: 4,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  child: DefaultTextStyle(
                    style: (theme.textTheme.bodyMedium ?? const TextStyle())
                        .copyWith(
                          color: apple.label,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                    child: IconTheme.merge(
                      data: IconThemeData(color: apple.secondaryLabel),
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
          ),
        ),
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
/// 下是 [FormField] + [FushiDropdownButton]（iOS 实色 pull-down 字段 + 玻璃
/// 菜单），
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
    final FushiAppleColors apple = appleColorsOf(context);
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
        final Widget? label =
            deco.label ??
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
                    color: error != null
                        ? apple.destructive
                        : apple.secondaryLabel,
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
                    hint:
                        hint ??
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
                    color: error != null
                        ? apple.destructive
                        : apple.secondaryLabel,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
