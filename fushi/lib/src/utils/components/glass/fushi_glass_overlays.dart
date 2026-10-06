import 'dart:math' as math;
import 'dart:ui' show SemanticsRole, lerpDouble;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiDialogAction, FushiDialogHeroIcon, fushiM3eMenuAnimationStyle;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
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

// Apple 下对话框分两种形态（用户 2026-10-04「对话框统一优化」）：
// - 纯文字短提示 = iOS 26 alert：居中标题 / 正文，宽 270–300，圆角 26–30，
//   底部撑满的胶囊动作（两个并排、三个起竖排）；
// - 其余（列表 / 表单 / 选择 / 自绘）= macOS 26 sheet：标题靠左，内容区，
//   底部右对齐的胶囊动作（取消系统灰、确定强调色），圆角 24。
// 两种共用同一块 [FushiAppleDialogPanel]（实色面板 + 柔和大阴影），背后的
// 整屏模糊由 showAppDialog 统一铺。

/// iOS 26 alert 的圆角：移动端 30，桌面 26。
double _alertRadius(BuildContext context) =>
    fushiAppleCompact(context) ? 26 : 30;

/// macOS 26 sheet 的圆角。
const double _kSheetRadius = 24;

/// iOS 26 alert 内边距基准。
const double _kGlassDialogPad = 20;

/// sheet 内边距：桌面 20、移动 24。
double _sheetPad(BuildContext context) => fushiAppleCompact(context) ? 20 : 24;

/// iOS 26 alert 宽度：纯文字 alert 固定在 270–300 之间。
const double _kGlassAlertMinWidth = 270;
const double _kGlassAlertMaxWidth = 300;

/// sheet（表单 / 列表等复杂内容）的宽度范围（窄到 300 会挤坏内容）。
const double _kGlassDialogFormMinWidth = 320;
const double _kGlassDialogFormMaxWidth = 520;

/// MD3 对话框宽度规范（280–560）。
const BoxConstraints _kMd3DialogConstraints = BoxConstraints(
  minWidth: 280,
  maxWidth: 560,
);

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
  // 浮层可能压在 WebView / 原生视图上（歌词模式的「⋯」菜单），采不到背景处
  // 用实色兜底（BUG-2961，见 [fushiGlassPlatformViewFallback]）。
  final LiquidGlassSettings base = fushiGlassSettings(context, tint: tint)
      .copyWith(
        platformViewFallbackColor: fushiGlassPlatformViewFallback(context),
      );
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

// Apple 菜单（用户 2026-10-04「菜单和弹出菜单也统一优化」）：
// - 桌面 = macOS 26 菜单：圆角 11、行高 28、13 号字、行与面板内缩 5、
//   悬停 / 键盘焦点 = 强调色圆角块 + onAccent 文字（macOS 菜单高亮）；
// - 移动 = iOS 26 上下文菜单：厚玻璃、圆角 24、行高 44、17 号字、按下铺
//   系统灰（fill）；
// - 选中项一律行尾对勾（与对话框选择列表同一处）、图标单色、破坏性红字、
//   分隔线细线内缩；面板宽 200–280，外加一圈柔和大阴影。

/// 菜单面板圆角。
double _menuRadius(BuildContext context) =>
    fushiAppleCompact(context) ? 11 : 24;

/// 菜单行高。
double _menuRowHeight(BuildContext context) =>
    fushiAppleCompact(context) ? 28 : 44;

/// 菜单行圆角（悬停 / 按下的高亮块）。
double _menuRowRadius(BuildContext context) =>
    fushiAppleCompact(context) ? 5 : 12;

/// 菜单行与面板边缘的内缩。
double _menuRowInset(BuildContext context) =>
    fushiAppleCompact(context) ? 5 : 8;

/// 菜单面板默认宽度。
const BoxConstraints _kMenuConstraints = BoxConstraints(
  minWidth: 200,
  maxWidth: 280,
);

/// 带结构化文案的菜单项（仓库的 FushiPopupMenuItem 实现它）：Apple 菜单据
/// 此直接画行（图标 / 文案 / 选中对勾 / 破坏性红字），不用 MD3 的 child。
abstract interface class FushiMenuItemData {
  String get label;
  IconData? get icon;

  /// 调用方给的前景色；给了就是破坏性 / 警示项（Apple 下统一画 destructive 红）。
  Color? get color;
  bool get selected;
}

/// Apple 菜单面板：玻璃材质（厚档，压住背后文字）+ 外圈柔和阴影。阴影只画
/// 在面板外（[_OuterShadowPainter]），不透过半透明玻璃把面板本身压暗。
///
/// [radius] / [shadowOpacity] 供变形展开逐帧插值（默认即菜单最终形态）。
Widget _appleMenuSurface(
  BuildContext context,
  Widget child, {
  double? radius,
  double shadowOpacity = 1,
}) {
  final double r = radius ?? _menuRadius(context);
  final bool compact = fushiAppleCompact(context);
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return CustomPaint(
    painter: _OuterShadowPainter(
      radius: r,
      color: Colors.black.withValues(
        alpha: (dark ? 0.45 : 0.18) * shadowOpacity.clamp(0.0, 1.0),
      ),
      blur: compact ? 18 : 32,
      offset: Offset(0, compact ? 6 : 12),
    ),
    child: GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      settings: _overlayGlassSettings(context, thick: true),
      shape: LiquidRoundedSuperellipse(borderRadius: r),
      clipBehavior: Clip.antiAlias,
      child: Material(type: MaterialType.transparency, child: child),
    ),
  );
}

/// 只画在圆角矩形**外面**的模糊阴影。
class _OuterShadowPainter extends CustomPainter {
  const _OuterShadowPainter({
    required this.radius,
    required this.color,
    required this.blur,
    required this.offset,
  });

  final double radius;
  final Color color;
  final double blur;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final Rect bounds = (Offset.zero & size).inflate(
      blur * 3 + offset.distance,
    );
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(bounds),
        Path()..addRRect(shape),
      ),
    );
    canvas.drawRRect(
      shape.shift(offset),
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur / 2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterShadowPainter oldDelegate) =>
      radius != oldDelegate.radius ||
      color != oldDelegate.color ||
      blur != oldDelegate.blur ||
      offset != oldDelegate.offset;
}

// ===========================================================================
// 对话框
// ===========================================================================

/// Apple 设计系统的对话框面板：实色面板（深色 #2C2C2E、浅色白——比页面底
/// 高一级，在模糊过的背景上靠明度与阴影浮起来），0.5px 发丝描边勾出边缘，
/// 两层柔和大阴影（macOS 26 sheet / iOS 26 alert 的浮起感）。玻璃材质开着时
/// 面板留极少一点透明（深 94% / 浅 96%），透出背后的整屏模糊、像一层厚玻璃；
/// 系统降低透明度（off）时完全实心。面板内包 [FushiDialogScope]（列表行改
/// 菜单式选中）与透明 [Material]（内容里的 InkWell 仍有墨水宿主）。
class FushiAppleDialogPanel extends StatelessWidget {
  const FushiAppleDialogPanel({
    super.key,
    required this.child,
    required this.radius,
    this.tint,
    this.clipBehavior = Clip.antiAlias,
    this.liquidGlass = false,
  });

  final Widget child;

  /// 圆角；0 = 全屏对话框（无描边、无阴影）。
  final double radius;

  /// 调用方显式给的面板底色（透明 / null = Apple 默认面板色）。
  final Color? tint;
  final Clip clipBehavior;

  /// 面板用真·液态玻璃（iOS 26 上下文菜单预览 / macOS 26 Quick Look 的厚玻璃：
  /// [GlassContainer] 厚档 + premium 渲染 + 面板外一圈柔和阴影），而不是默认
  /// 的近实色面板。系统降低透明度（off）或全屏（[radius] ≤ 0）时仍画实色面板。
  final bool liquidGlass;

  @override
  Widget build(BuildContext context) {
    final bool dark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final Color? explicitTint = tint != null && tint!.a > 0 ? tint : null;
    final bool solid = glassMaterialOf(context) == FushiGlassMaterial.off;
    if (liquidGlass && !solid && radius > 0) {
      // 阴影只画在面板外（[_OuterShadowPainter]），不透过半透明玻璃把面板
      // 本身压暗；玻璃参数与菜单厚档同一套（深 #262626@82% / 浅白@72%）。
      return CustomPaint(
        painter: _OuterShadowPainter(
          radius: radius,
          color: Colors.black.withValues(alpha: dark ? 0.45 : 0.18),
          blur: 40,
          offset: const Offset(0, 16),
        ),
        child: GlassContainer(
          useOwnLayer: true,
          quality: fushiGlassQuality(context, prominent: true),
          settings: _overlayGlassSettings(
            context,
            thick: true,
            tint: explicitTint,
          ),
          shape: LiquidRoundedSuperellipse(borderRadius: radius),
          clipBehavior: clipBehavior == Clip.none
              ? Clip.antiAlias
              : clipBehavior,
          child: FushiDialogScope(
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      );
    }
    final Color base =
        explicitTint ??
        (dark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF)).withValues(
          alpha: solid ? 1 : (dark ? 0.94 : 0.96),
        );
    final Widget inner = FushiDialogScope(
      child: Material(type: MaterialType.transparency, child: child),
    );
    if (radius <= 0) {
      return ColoredBox(color: base.withValues(alpha: 1), child: inner);
    }
    final BorderRadius borderRadius = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: base,
        shape: RoundedSuperellipseBorder(
          borderRadius: borderRadius,
          side: BorderSide(
            color: dark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.06),
            width: 0.5,
          ),
        ),
        shadows: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.45 : 0.16),
            blurRadius: 48,
            spreadRadius: -4,
            offset: const Offset(0, 20),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.30 : 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRSuperellipse(
        borderRadius: borderRadius,
        clipBehavior: clipBehavior == Clip.none ? Clip.antiAlias : clipBehavior,
        child: inner,
      ),
    );
  }
}

/// Apple 对话框外壳：布局语义照抄 Material [Dialog]（键盘让位、外边距、对齐、
/// 尺寸约束、语义角色），表面换成 [FushiAppleDialogPanel]。
class _FushiGlassDialogShell extends StatelessWidget {
  const _FushiGlassDialogShell({
    required this.child,
    this.radius = _kSheetRadius,
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
  final double radius;
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
    final Widget surface = FushiAppleDialogPanel(
      radius: fullscreen ? 0 : radius,
      tint: tint,
      clipBehavior: clipBehavior ?? Clip.antiAlias,
      child: child,
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
              constraints: constraints ?? defaultConstraints,
              child: surface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple 对话框标题：17 semibold（桌面 15），label 色。alert 与 sheet 同一档。
TextStyle _glassDialogTitleStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return (theme.textTheme.titleLarge ?? const TextStyle()).copyWith(
    fontSize: fushiAppleCompact(context) ? 15 : 17,
    fontWeight: FontWeight.w600,
    height: 1.3,
    letterSpacing: 0,
    color: appleColorsOf(context).label,
  );
}

/// Apple 对话框正文：15（桌面 13），label 色（iOS alert 正文不灰）。
TextStyle _glassDialogContentStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: fushiAppleCompact(context) ? 13 : 15,
    color: appleColorsOf(context).label,
    height: 1.35,
  );
}

/// macOS 26 sheet 的底部动作区：右对齐、间距 8，放不下时右对齐竖排；
/// 文字按钮在 [FushiDialogActionScope] 里画成系统灰胶囊。
Widget _glassSheetActions(
  List<Widget> actions, {
  MainAxisAlignment? alignment,
  OverflowBarAlignment? overflowAlignment,
  VerticalDirection? overflowDirection,
  double? overflowSpacing,
}) {
  return FushiDialogActionScope(
    child: OverflowBar(
      alignment: alignment ?? MainAxisAlignment.end,
      spacing: 8,
      overflowAlignment: overflowAlignment ?? OverflowBarAlignment.end,
      overflowDirection: overflowDirection ?? VerticalDirection.down,
      overflowSpacing: overflowSpacing ?? 8,
      children: actions,
    ),
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
    w is FushiDialogAction ||
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
        icon: _md3HeroIcon(),
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
        constraints: constraints ?? _kMd3DialogConstraints,
        scrollable: scrollable,
        scrollController: scrollController,
        actionScrollController: actionScrollController,
        insetAnimationDuration: insetAnimationDuration,
        insetAnimationCurve: insetAnimationCurve,
      );
    }
    if (!isGlassDesign(context)) {
      return AlertDialog(
        icon: _md3HeroIcon(),
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
        constraints: constraints ?? _kMd3DialogConstraints,
        scrollable: scrollable,
      );
    }
    return _buildGlass(context);
  }

  /// M3E：调用方给的图标包进形状库装饰底（[FushiDialogHeroIcon]，9 瓣饼干 +
  /// secondaryContainer；给了 [iconColor] 时按该色淡染）。已经是 hero 的原样用。
  Widget? _md3HeroIcon() {
    final Widget? raw = icon;
    if (raw == null || raw is FushiDialogHeroIcon) return raw;
    return FushiDialogHeroIcon(color: iconColor, child: raw);
  }

  /// Apple 形态，按内容分两种：
  /// - 纯文字 = iOS 26 alert：标题 / 正文居中，宽 270–300，动作是底部撑满的
  ///   胶囊（两个并排、多个竖排；主操作强调色、取消系统灰、破坏性灰底红字）；
  /// - 其余 = macOS 26 sheet：标题靠左（调用方的 icon 缩成标题左侧的单色小
  ///   图标），内容左对齐，动作右对齐成一排胶囊，宽 320–520。
  Widget _buildGlass(BuildContext context) {
    final bool alertText = _isPlainTextContent(content);
    return alertText ? _buildAppleAlert(context) : _buildAppleSheet(context);
  }

  Widget _wrapTitle(BuildContext context, TextAlign align) {
    return DefaultTextStyle(
      style: titleTextStyle ?? _glassDialogTitleStyle(context),
      textAlign: align,
      child: Semantics(
        namesRoute:
            semanticLabel == null &&
            defaultTargetPlatform != TargetPlatform.iOS,
        container: true,
        child: title!,
      ),
    );
  }

  Widget _wrapContent(BuildContext context, TextAlign align) {
    return DefaultTextStyle(
      style: contentTextStyle ?? _glassDialogContentStyle(context),
      textAlign: align,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        child: content!,
      ),
    );
  }

  /// 把头 / 内容 / 动作三段拼成面板里的列；[scrollable] 时头与内容一起滚。
  Widget _assemble(
    List<Widget> head,
    Widget? contentWidget,
    Widget? actionsWidget,
  ) {
    final List<Widget> columnChildren;
    if (scrollable) {
      columnChildren = <Widget>[
        if (head.isNotEmpty || contentWidget != null)
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ...head,
                  if (contentWidget != null) contentWidget,
                ],
              ),
            ),
          ),
        if (actionsWidget != null) actionsWidget,
      ];
    } else {
      columnChildren = <Widget>[
        ...head,
        if (contentWidget != null) Flexible(child: contentWidget),
        if (actionsWidget != null) actionsWidget,
      ];
    }
    Widget dialogChild = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: columnChildren,
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
    return dialogChild;
  }

  Widget _buildAppleAlert(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    const double pad = _kGlassDialogPad;
    final List<Widget> head = <Widget>[
      if (icon != null)
        Padding(
          padding:
              iconPadding ??
              EdgeInsets.fromLTRB(pad, pad, pad, title != null ? 10 : 0),
          child: Center(
            child: IconTheme(
              data: IconThemeData(color: iconColor ?? apple.label, size: 28),
              child: icon!,
            ),
          ),
        ),
      if (title != null)
        Padding(
          padding:
              titlePadding ??
              EdgeInsets.fromLTRB(
                pad,
                icon == null ? pad + 2 : 0,
                pad,
                content == null ? pad : 0,
              ),
          child: _wrapTitle(context, TextAlign.center),
        ),
    ];
    final Widget? contentWidget = content == null
        ? null
        : Padding(
            padding:
                contentPadding ??
                EdgeInsets.fromLTRB(
                  pad,
                  title == null && icon == null ? pad + 2 : 6,
                  pad,
                  pad,
                ),
            child: _wrapContent(context, TextAlign.center),
          );
    Widget? actionsWidget;
    final List<Widget>? acts = actions;
    if (acts != null && acts.isNotEmpty) {
      final EdgeInsetsGeometry padding =
          actionsPadding ?? const EdgeInsets.fromLTRB(16, 0, 16, 16);
      actionsWidget = Padding(
        padding: padding,
        child: acts.every(_isAlertButton)
            ? _glassAlertActions(context, acts)
            : _glassSheetActions(
                acts,
                alignment: actionsAlignment ?? MainAxisAlignment.center,
                overflowAlignment: actionsOverflowAlignment,
                overflowDirection: actionsOverflowDirection,
                overflowSpacing: actionsOverflowButtonSpacing,
              ),
      );
    }
    return _FushiGlassDialogShell(
      radius: _alertRadius(context),
      tint: backgroundColor,
      insetPadding: insetPadding,
      alignment: alignment,
      constraints: constraints,
      // 纯文字 alert 宽度固定（iOS 不随文字伸缩）。
      defaultConstraints: const BoxConstraints(
        minWidth: _kGlassAlertMinWidth,
        maxWidth: _kGlassAlertMaxWidth,
      ),
      clipBehavior: clipBehavior,
      semanticsRole: SemanticsRole.alertDialog,
      child: _assemble(head, contentWidget, actionsWidget),
    );
  }

  Widget _buildAppleSheet(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final double pad = _sheetPad(context);
    final bool compact = fushiAppleCompact(context);
    final bool hasHead = title != null || icon != null;
    final List<Widget> head = <Widget>[
      if (hasHead)
        Padding(
          padding:
              titlePadding ??
              EdgeInsets.fromLTRB(pad, pad, pad, content == null ? pad : 0),
          child: Row(
            children: <Widget>[
              // 调用方的 icon 不再是左上角彩色方块：缩成标题左侧的单色小图标。
              if (icon != null) ...<Widget>[
                IconTheme(
                  data: IconThemeData(
                    color: iconColor ?? apple.secondaryLabel,
                    size: compact ? 17 : 20,
                  ),
                  child: icon!,
                ),
                if (title != null) SizedBox(width: compact ? 8 : 10),
              ],
              if (title != null)
                Expanded(child: _wrapTitle(context, TextAlign.start)),
            ],
          ),
        ),
    ];
    final Widget? contentWidget = content == null
        ? null
        : Padding(
            padding:
                contentPadding ??
                EdgeInsets.fromLTRB(pad, hasHead ? 12 : pad, pad, pad),
            child: _wrapContent(context, TextAlign.start),
          );
    Widget? actionsWidget;
    final List<Widget>? acts = actions;
    if (acts != null && acts.isNotEmpty) {
      actionsWidget = Padding(
        padding: actionsPadding ?? EdgeInsets.fromLTRB(pad, 0, pad, pad),
        child: _glassSheetActions(
          acts,
          alignment: actionsAlignment,
          overflowAlignment: actionsOverflowAlignment,
          overflowDirection: actionsOverflowDirection,
          overflowSpacing: actionsOverflowButtonSpacing,
        ),
      );
    }
    return _FushiGlassDialogShell(
      radius: _kSheetRadius,
      tint: backgroundColor,
      insetPadding: insetPadding,
      alignment: alignment,
      constraints: constraints,
      defaultConstraints: const BoxConstraints(
        minWidth: _kGlassDialogFormMinWidth,
        maxWidth: _kGlassDialogFormMaxWidth,
      ),
      clipBehavior: clipBehavior,
      semanticsRole: SemanticsRole.alertDialog,
      // 表单式按内容取宽（夹在 320–520 之间）。
      child: IntrinsicWidth(
        child: _assemble(head, contentWidget, actionsWidget),
      ),
    );
  }
}

/// [SimpleDialog] 的默认内边距（与 Material 同值），Apple 下据此判断调用方
/// 有没有改过。
const EdgeInsets _kSimpleDialogTitlePadding = EdgeInsets.fromLTRB(
  24.0,
  24.0,
  24.0,
  0.0,
);
const EdgeInsets _kSimpleDialogContentPadding = EdgeInsets.fromLTRB(
  0.0,
  12.0,
  0.0,
  16.0,
);

/// [SimpleDialog] 的设计系统分派版。
class FushiSimpleDialog extends StatelessWidget {
  const FushiSimpleDialog({
    super.key,
    this.title,
    this.titlePadding = _kSimpleDialogTitlePadding,
    this.titleTextStyle,
    this.children,
    this.contentPadding = _kSimpleDialogContentPadding,
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
        constraints: constraints ?? _kMd3DialogConstraints,
        children: children,
      );
    }
    // macOS 26 sheet 形态的选择列表：标题靠左，下面是菜单式选项行。默认
    // 内边距（Material 的 24 / 12 / 16）换成 sheet 的节奏；调用方显式改过
    // 的照用。
    final double pad = _sheetPad(context);
    final EdgeInsetsGeometry effectiveTitlePadding =
        titlePadding == _kSimpleDialogTitlePadding
        ? EdgeInsets.fromLTRB(pad, pad, pad, 6)
        : titlePadding;
    final EdgeInsetsGeometry effectiveContentPadding =
        contentPadding == _kSimpleDialogContentPadding
        ? EdgeInsets.fromLTRB(0, title == null ? 8 : 0, 0, 8)
        : contentPadding;
    Widget body = IntrinsicWidth(
      stepWidth: 20,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (title != null)
              Padding(
                padding: effectiveTitlePadding,
                child: DefaultTextStyle(
                  style: titleTextStyle ?? _glassDialogTitleStyle(context),
                  textAlign: TextAlign.start,
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
                  padding: effectiveContentPadding,
                  child: DefaultTextStyle(
                    style:
                        contentTextStyle ?? _glassDialogContentStyle(context),
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
      defaultConstraints: const BoxConstraints(minWidth: 280, maxWidth: 440),
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
      // M3E：选项行左右内缩 12、圆角 16 的状态层（不再横贯整个对话框），
      // 文字起点与默认 SimpleDialogOption（左 24）对齐。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Material(
          type: MaterialType.transparency,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          clipBehavior: Clip.antiAlias,
          child: SimpleDialogOption(
            onPressed: onPressed,
            padding:
                padding ??
                const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: child,
          ),
        ),
      );
    }
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    // 菜单式选项行：行高 36（桌面）/ 44（移动），悬停 tertiaryFill 圆角底。
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
      child: _AppleMenuRow(
        onTap: onPressed ?? () {},
        enabled: onPressed != null,
        minHeight: compact ? 36 : 44,
        radius: compact ? 8 : 12,
        foreground: onPressed != null ? apple.label : apple.tertiaryLabel,
        padding:
            padding ??
            EdgeInsets.symmetric(vertical: 6, horizontal: compact ? 12 : 14),
        child: child ?? const SizedBox.shrink(),
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

/// Apple 菜单 / 列表选项行：无底，左起内容、[trailing] 在行尾（选中对勾）。
/// 高亮两种：[accentHighlight]（macOS 菜单）悬停 / 键盘焦点 / 按下铺强调色
/// 圆角块、前景换 onAccent；否则（iOS 菜单、对话框选项）按下铺 fill、悬停 /
/// 焦点铺 tertiaryFill。前景色由行自己给（[foreground]），高亮时才能整体反色。
/// 自带焦点节点，[ActivateIntent]（Enter / 手柄 A）与点击都触发 [onTap]。
class _AppleMenuRow extends StatefulWidget {
  const _AppleMenuRow({
    required this.onTap,
    required this.enabled,
    required this.minHeight,
    required this.radius,
    required this.padding,
    required this.foreground,
    required this.child,
    this.accentHighlight = false,
    this.trailing,
    this.mouseCursor,
  });

  final VoidCallback onTap;
  final bool enabled;
  final double minHeight;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color foreground;
  final bool accentHighlight;
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
    final bool accent = widget.accentHighlight && highlight;
    final Color background = !highlight
        ? Colors.transparent
        : accent
        ? apple.accent
        : (_pressed ? apple.fill : apple.tertiaryFill);
    final Color fg = accent ? apple.onAccent : widget.foreground;
    final Widget body = AnimatedContainer(
      // macOS 菜单高亮是瞬时跟手的，不做渐变。
      duration: _pressed || widget.accentHighlight
          ? Duration.zero
          : const Duration(milliseconds: 120),
      constraints: BoxConstraints(minHeight: widget.minHeight),
      padding: widget.padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      alignment: AlignmentDirectional.centerStart,
      child: IconTheme.merge(
        data: IconThemeData(color: fg),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: fg),
          child: _accentTint(
            accent ? fg : null,
            Row(
              children: <Widget>[
                Expanded(child: widget.child),
                if (widget.trailing != null) ...<Widget>[
                  const SizedBox(width: 12),
                  widget.trailing!,
                ],
              ],
            ),
          ),
        ),
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
        // 内层 GestureDetector 排除了语义，读屏的 tap 由这里直接接到 onTap。
        onTap: enabled ? widget.onTap : null,
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

/// Apple 菜单的组间细分隔线（separator 色，半像素，两侧内缩）。
Widget _appleMenuDivider(BuildContext context) {
  final bool compact = fushiAppleCompact(context);
  return SizedBox(
    height: compact ? 11 : 17,
    child: Center(
      child: Container(
        height: 0.5,
        margin: EdgeInsets.symmetric(horizontal: compact ? 10 : 16),
        color: appleColorsOf(context).separator,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// 菜单定位与展开（用户 2026-10-04「下拉框这些弹出位置也优化一下」）
//
// 两套设计系统同一条定位规则（showFushiMenu / FushiPopupMenuButton /
// FushiOverflowMenu / 各下拉都走这里）：
// - 菜单在触发器**下方 6px** 展开、起始缘对齐触发器起始缘（RTL 对齐右缘），
//   宽度不小于触发器（不超过各自的最大宽度）；**不再盖住触发器**（Material
//   PopupMenuButton 默认 over 会把菜单顶对齐按钮顶）；
// - 下方放不下就翻到上方（同样 6px）；水平越界向内平移；距屏幕 / 窗口边至少
//   8px（再让开系统安全区与软键盘）；两侧都放不下时限高、菜单内滚动。
// - 右键菜单这类「点」锚（≤2px）不留间距，左上角落在点上。
// 动效：Apple = iOS / macOS 26 的「从按钮变形展开」——玻璃面板从触发器的
// 位置、尺寸、圆角出发，弹簧过渡到最终矩形，内容随后淡入；关闭反向收回触发器。
// MD3 = 淡入 + 从锚定边向外的下拉展开（翻到上方时自下而上）。
// 系统「减少动态效果」与墨水屏（fushiMotionEnabled）下直接出现。
// ---------------------------------------------------------------------------

/// 菜单与触发器之间的间距。
const double _kMenuAnchorGap = 6;

/// 菜单与屏幕 / 窗口边（安全区内）的最小距离。
const double _kMenuScreenMargin = 8;

/// 限高滚动时菜单至少保留的高度：锚点上下都只剩一条缝时不硬塞进缝里，
/// 改为在安全区内平移（允许压住触发器），避免菜单只剩一两行。
const double _kMenuMinScrollHeight = 120;

/// 尺寸 ≤ 这个值的锚视为「点」（右键 / 长按位置），不留间距、不变形圆角。
const double _kMenuPointAnchorExtent = 2;

/// Apple 菜单变形的时长：弹簧（见 [_FushiMenuSpringCurve]）在这段时间内
/// 基本静止；收回用更短的缓入。
const Duration _kAppleMenuOpenDuration = Duration(milliseconds: 480);
const Duration _kAppleMenuCloseDuration = Duration(milliseconds: 220);

/// MD3 菜单默认时长（调用方给了 popUpAnimationStyle 就用调用方的）：M3E
/// fast spatial 弹簧展开（[fushiM3eMenuAnimationStyle]）。
final Duration _kMd3MenuOpenDuration = fushiM3eMenuAnimationStyle.duration!;
final Duration _kMd3MenuCloseDuration =
    fushiM3eMenuAnimationStyle.reverseDuration!;

/// MD3 菜单默认宽度（与 Material 弹出菜单一致：112–280）。
const BoxConstraints _kMd3MenuConstraints = BoxConstraints(
  minWidth: 112,
  maxWidth: 280,
);

/// 以 [anchor] 的渲染盒为锚的菜单位置（整块触发器矩形，菜单在其下方 6px
/// 展开、至少与它同宽）。下拉 / 自定义触发器调 [showFushiMenu] 时用它。
PopupMenuPositionBuilder fushiMenuAnchorPosition(
  BuildContext anchor, {
  bool useRootNavigator = false,
}) {
  RelativeRect? last;
  return (BuildContext _, BoxConstraints constraints) {
    final RenderObject? box = anchor.mounted ? anchor.findRenderObject() : null;
    final RenderObject? overlay = anchor.mounted
        ? Navigator.of(
            anchor,
            rootNavigator: useRootNavigator,
          ).overlay?.context.findRenderObject()
        : null;
    // 菜单开着时触发器可能被卸载（列表滚走 / 页面重建）；此后的重新布局
    // 沿用最后一次算出的位置，而不是读已失效的渲染盒。
    if (box is! RenderBox ||
        overlay is! RenderBox ||
        !box.attached ||
        !overlay.attached ||
        !box.hasSize) {
      return last ?? RelativeRect.fromSize(Rect.zero, constraints.biggest);
    }
    final Rect rect = MatrixUtils.transformRect(
      box.getTransformTo(overlay),
      Offset.zero & box.size,
    );
    return last = RelativeRect.fromRect(rect, Offset.zero & overlay.size);
  };
}

/// iOS 26 菜单变形用的弹簧（与 liquid_glass_widgets GlassMenu 同参：
/// stiffness 300、damping 24、mass 1，阻尼比 ≈ 0.69，约 5% 回弹），按
/// [_kAppleMenuOpenDuration] 把时间归一化成曲线。
class _FushiMenuSpringCurve extends Curve {
  const _FushiMenuSpringCurve();

  static const double _stiffness = 300;
  static const double _damping = 24;

  @override
  double transformInternal(double t) {
    final double omega = math.sqrt(_stiffness);
    final double zeta = _damping / (2 * omega);
    final double omegaD = omega * math.sqrt(1 - zeta * zeta);
    final double tau =
        t *
        _kAppleMenuOpenDuration.inMicroseconds /
        Duration.microsecondsPerSecond;
    final double envelope = math.exp(-zeta * omega * tau);
    return 1 -
        envelope *
            (math.cos(omegaD * tau) +
                zeta * omega / omegaD * math.sin(omegaD * tau));
  }
}

/// 菜单宽度至少等于触发器宽度（不超过 [constraints] 的最大宽度）。
BoxConstraints _menuAtLeastAnchorWidth(
  BoxConstraints constraints,
  double anchorWidth,
) {
  if (anchorWidth <= 0) return constraints;
  final double minWidth = math.max(
    constraints.minWidth,
    math.min(anchorWidth, constraints.maxWidth),
  );
  return constraints.copyWith(minWidth: minWidth);
}

/// [showMenu] 的设计系统分派版，签名逐参一致。两套设计系统都推同一条
/// [_FushiMenuRoute]（定位规则见上），区别只在面板与动效：MD3 是 Material
/// 菜单面（参数 / PopupMenuTheme 照用）+ 淡入下拉展开；Apple 是玻璃面板 +
/// 从触发器变形展开。菜单项仍是调用方给的 [PopupMenuEntry]
/// （[PopupMenuItem.handleTap] 照常 `Navigator.pop(value)`），打开时焦点落在
/// [initialValue] 对应项（否则第一项），方向键沿框架 / 全局焦点引擎在项间
/// 移动，Enter / 手柄 A 激活，Esc / 手柄 B / 点屏障关闭；取消关闭后焦点回到
/// 打开前的焦点（键盘打开时就是触发器）。
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
  assert(items.isNotEmpty);
  assert(debugCheckHasMaterialLocalizations(context));
  assert(
    (position != null) != (positionBuilder != null),
    'Either position or positionBuilder must be provided.',
  );
  final bool apple = isGlassDesign(context);
  final MaterialLocalizations l10n = MaterialLocalizations.of(context);
  // 与 showMenu 一致：Apple 平台的 MD3 菜单不读「弹出菜单」标签。
  String? label = semanticLabel;
  if (apple) {
    label ??= l10n.popupMenuLabel;
  } else {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        break;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        label ??= l10n.popupMenuLabel;
    }
  }
  final NavigatorState navigator = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  );
  final FocusNode? returnFocus = FocusManager.instance.primaryFocus;
  // 「键盘 / 手柄打开」= 传统焦点高亮模式下，打开时有具体控件（通常就是
  // 触发器）持有焦点。只有这时才把焦点落进菜单项；鼠标 / 触摸打开不预先
  // 高亮某一项（与 macOS / iOS 原生菜单一致）。
  final bool keyboardOpened =
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional &&
      returnFocus != null &&
      returnFocus is! FocusScopeNode;
  return navigator
      .push(
        _FushiMenuRoute<T>(
          apple: apple,
          appleRadius: apple ? _menuRadius(context) : 0,
          // 墨水屏与系统减弱动效同一入口（fushiMotionEnabled），HBK-AUDIT-042。
          reduceMotion: !fushiMotionEnabled(context),
          focusItemOnOpen: keyboardOpened,
          position: position,
          positionBuilder: positionBuilder,
          items: items,
          initialValue: initialValue,
          elevation: elevation,
          shadowColor: shadowColor,
          surfaceTintColor: surfaceTintColor,
          semanticLabel: label,
          shape: shape,
          menuPadding: menuPadding,
          color: color,
          constraints: constraints,
          clipBehavior: clipBehavior,
          barrierLabel: l10n.menuDismissLabel,
          popUpAnimationStyle: popUpAnimationStyle,
          capturedThemes: InheritedTheme.capture(
            from: context,
            to: navigator.context,
          ),
          settings: routeSettings,
          requestFocus: requestFocus,
        ),
      )
      .then<T?>((T? value) {
        // 取消（Esc / B / 点外面）后把焦点还给打开前的节点：路由出栈时
        // 下层作用域只会恢复「它记得的」焦点，触发器若是被代码 / 手柄聚焦的，
        // 这里显式补一次。选中某项后不抢焦点（选项可能已推了新页面）。
        if (value == null) _restoreMenuReturnFocus(returnFocus);
        return value;
      });
}

void _restoreMenuReturnFocus(FocusNode? node) {
  final BuildContext? ctx = node?.context;
  if (node == null || ctx == null || !ctx.mounted) return;
  if (!node.canRequestFocus || node.hasFocus) return;
  final ModalRoute<Object?>? route = ModalRoute.of(ctx);
  if (route != null && !route.isCurrent) return;
  node.requestFocus();
}

enum _FushiMenuMotion {
  /// Apple：从触发器变形展开。
  morph,

  /// MD3：从锚定边向外的下拉展开。
  reveal,
}

class _FushiMenuRoute<T> extends PopupRoute<T> {
  _FushiMenuRoute({
    required this.apple,
    required this.appleRadius,
    required this.reduceMotion,
    required this.focusItemOnOpen,
    required this.position,
    required this.positionBuilder,
    required this.items,
    required this.initialValue,
    required this.elevation,
    required this.shadowColor,
    required this.surfaceTintColor,
    required this.semanticLabel,
    required this.shape,
    required this.menuPadding,
    required this.color,
    required this.constraints,
    required this.clipBehavior,
    required this.barrierLabel,
    required this.popUpAnimationStyle,
    required this.capturedThemes,
    super.settings,
    super.requestFocus,
  });

  final bool apple;
  final double appleRadius;
  final bool reduceMotion;

  /// 打开时是否把焦点落进菜单项（当前项，否则第一项）。
  final bool focusItemOnOpen;
  final RelativeRect? position;
  final PopupMenuPositionBuilder? positionBuilder;
  final List<PopupMenuEntry<T>> items;
  final T? initialValue;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final String? semanticLabel;
  final ShapeBorder? shape;
  final EdgeInsetsGeometry? menuPadding;
  final Color? color;
  final BoxConstraints? constraints;
  final Clip clipBehavior;
  final AnimationStyle? popUpAnimationStyle;
  final CapturedThemes capturedThemes;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  bool get _noAnimation =>
      reduceMotion || popUpAnimationStyle?.duration == Duration.zero;

  @override
  Duration get transitionDuration {
    if (_noAnimation) return Duration.zero;
    // Apple 的弹簧时长由弹簧本身决定，不吃调用方的 MD3 动效时长。
    if (apple) return _kAppleMenuOpenDuration;
    return popUpAnimationStyle?.duration ?? _kMd3MenuOpenDuration;
  }

  @override
  Duration get reverseTransitionDuration {
    if (_noAnimation) return Duration.zero;
    if (apple) return _kAppleMenuCloseDuration;
    return popUpAnimationStyle?.reverseDuration ?? _kMd3MenuCloseDuration;
  }

  /// 面板几何进度（Apple：弹簧；MD3：展开曲线）。
  CurvedAnimation? _progress;

  /// 内容不透明度。
  CurvedAnimation? _opacity;

  void _ensureCurves(Animation<double> animation) {
    if (_progress != null) return;
    if (apple) {
      _progress = CurvedAnimation(
        parent: animation,
        curve: const _FushiMenuSpringCurve(),
        reverseCurve: Curves.easeInCubic,
      );
      // 面板先长出来、内容随后淡入；收回时内容先消失。
      _opacity = CurvedAnimation(
        parent: animation,
        curve: const Interval(0.12, 0.5, curve: Curves.easeOut),
        reverseCurve: const Interval(0.55, 1, curve: Curves.easeIn),
      );
    } else {
      _progress = CurvedAnimation(
        parent: animation,
        curve: popUpAnimationStyle?.curve ?? fushiM3eMenuAnimationStyle.curve!,
        reverseCurve:
            popUpAnimationStyle?.reverseCurve ??
            fushiM3eMenuAnimationStyle.reverseCurve!,
      );
      // 与 Material 弹出菜单同节奏：前 1/3 淡入，关闭时前 2/3 淡出。
      _opacity = CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 1 / 3),
        reverseCurve: const Interval(0, 2 / 3),
      );
    }
  }

  @override
  void dispose() {
    _progress?.dispose();
    _opacity?.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    _ensureCurves(animation);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final RelativeRect relative =
            positionBuilder?.call(context, box) ?? position!;
        final Rect anchor = relative.toRect(Offset.zero & box.biggest);
        final bool point =
            anchor.width <= _kMenuPointAnchorExtent &&
            anchor.height <= _kMenuPointAnchorExtent;
        final MediaQueryData mq = MediaQuery.of(context);
        // 系统栏与软键盘都要让开：逐边取两者较大值。
        final EdgeInsets safeArea = EdgeInsets.fromLTRB(
          math.max(mq.padding.left, mq.viewInsets.left),
          math.max(mq.padding.top, mq.viewInsets.top),
          math.max(mq.padding.right, mq.viewInsets.right),
          math.max(mq.padding.bottom, mq.viewInsets.bottom),
        );
        final BoxConstraints menuConstraints = _menuAtLeastAnchorWidth(
          constraints ?? (apple ? _kMenuConstraints : _kMd3MenuConstraints),
          point ? 0 : anchor.width,
        );
        final Widget content = FadeTransition(
          opacity: _opacity!,
          child: capturedThemes.wrap(
            _FushiMenuBody<T>(route: this, constraints: menuConstraints),
          ),
        );
        return _FushiMenuLayout(
          anchor: anchor,
          progress: _progress!,
          textDirection: Directionality.of(context),
          safeArea: safeArea,
          motion: apple ? _FushiMenuMotion.morph : _FushiMenuMotion.reveal,
          // 变形起点按胶囊 / 圆角按钮估算（半高，封顶 22），点锚从直角起。
          startRadius: point ? 0 : math.min(anchor.shortestSide / 2, 22),
          endRadius: appleRadius,
          children: <Widget>[
            if (apple)
              capturedThemes.wrap(
                _FushiMenuMorphSurface(
                  progress: _progress!,
                  startRadius: point
                      ? 0
                      : math.min(anchor.shortestSide / 2, 22),
                  endRadius: appleRadius,
                ),
              ),
            content,
          ],
        );
      },
    );
  }
}

/// Apple 菜单变形中的玻璃面板：尺寸由 [_RenderFushiMenuLayout] 按进度给出
/// （触发器矩形 → 最终菜单矩形），圆角同步从触发器圆角插值到菜单圆角，
/// 外圈阴影随进度浮现。
class _FushiMenuMorphSurface extends StatelessWidget {
  const _FushiMenuMorphSurface({
    required this.progress,
    required this.startRadius,
    required this.endRadius,
  });

  final Animation<double> progress;
  final double startRadius;
  final double endRadius;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (BuildContext context, Widget? child) {
        final double t = progress.value.clamp(0.0, 1.0);
        return _appleMenuSurface(
          context,
          const SizedBox.expand(),
          radius: lerpDouble(startRadius, endRadius, t),
          shadowOpacity: t,
        );
      },
    );
  }
}

/// 菜单的定位 + 展开动效布局。子节点：Apple 为 [玻璃面板, 内容]，MD3 为
/// [内容]。内容按最终尺寸布局一次（文字不随动画重排），面板 / 裁剪按进度
/// 插值，所以动画每帧只重新布局一块空面板。
class _FushiMenuLayout extends MultiChildRenderObjectWidget {
  const _FushiMenuLayout({
    required this.anchor,
    required this.progress,
    required this.textDirection,
    required this.safeArea,
    required this.motion,
    required this.startRadius,
    required this.endRadius,
    required super.children,
  });

  final Rect anchor;
  final Animation<double> progress;
  final TextDirection textDirection;
  final EdgeInsets safeArea;
  final _FushiMenuMotion motion;
  final double startRadius;
  final double endRadius;

  @override
  _RenderFushiMenuLayout createRenderObject(BuildContext context) {
    return _RenderFushiMenuLayout(
      anchor: anchor,
      progress: progress,
      textDirection: textDirection,
      safeArea: safeArea,
      motion: motion,
      startRadius: startRadius,
      endRadius: endRadius,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFushiMenuLayout renderObject,
  ) {
    renderObject
      ..anchor = anchor
      ..progress = progress
      ..textDirection = textDirection
      ..safeArea = safeArea
      ..motion = motion
      ..startRadius = startRadius
      ..endRadius = endRadius;
  }
}

class _FushiMenuLayoutParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFushiMenuLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FushiMenuLayoutParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FushiMenuLayoutParentData> {
  _RenderFushiMenuLayout({
    required Rect anchor,
    required Animation<double> progress,
    required TextDirection textDirection,
    required EdgeInsets safeArea,
    required _FushiMenuMotion motion,
    required double startRadius,
    required double endRadius,
  }) : _anchor = anchor,
       _progress = progress,
       _textDirection = textDirection,
       _safeArea = safeArea,
       _motion = motion,
       _startRadius = startRadius,
       _endRadius = endRadius;

  Rect get anchor => _anchor;
  Rect _anchor;
  set anchor(Rect value) {
    if (value == _anchor) return;
    _anchor = value;
    markNeedsLayout();
  }

  Animation<double> get progress => _progress;
  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (identical(value, _progress)) return;
    if (attached) _progress.removeListener(markNeedsLayout);
    _progress = value;
    if (attached) _progress.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  EdgeInsets get safeArea => _safeArea;
  EdgeInsets _safeArea;
  set safeArea(EdgeInsets value) {
    if (value == _safeArea) return;
    _safeArea = value;
    markNeedsLayout();
  }

  _FushiMenuMotion get motion => _motion;
  _FushiMenuMotion _motion;
  set motion(_FushiMenuMotion value) {
    if (value == _motion) return;
    _motion = value;
    markNeedsLayout();
  }

  double get startRadius => _startRadius;
  double _startRadius;
  set startRadius(double value) {
    if (value == _startRadius) return;
    _startRadius = value;
    markNeedsPaint();
  }

  double get endRadius => _endRadius;
  double _endRadius;
  set endRadius(double value) {
    if (value == _endRadius) return;
    _endRadius = value;
    markNeedsPaint();
  }

  /// 菜单最终矩形（本盒坐标）。
  Rect _menuRect = Rect.zero;

  /// 当前帧面板矩形（Apple 变形用）。
  Rect _panelRect = Rect.zero;

  /// 菜单是否翻到了触发器上方。
  bool _above = false;

  final LayerHandle<ClipRRectLayer> _clipRRectLayer =
      LayerHandle<ClipRRectLayer>();
  final LayerHandle<ClipRectLayer> _clipRectLayer =
      LayerHandle<ClipRectLayer>();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FushiMenuLayoutParentData) {
      child.parentData = _FushiMenuLayoutParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _progress.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void dispose() {
    _clipRRectLayer.layer = null;
    _clipRectLayer.layer = null;
    super.dispose();
  }

  RenderBox? get _surface => childCount > 1 ? firstChild : null;
  RenderBox get _content => lastChild!;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    size = constraints.biggest;
    final RenderBox content = _content;
    final Rect safe = Rect.fromLTRB(
      _safeArea.left + _kMenuScreenMargin,
      _safeArea.top + _kMenuScreenMargin,
      math.max(
        _safeArea.left + _kMenuScreenMargin,
        size.width - _safeArea.right - _kMenuScreenMargin,
      ),
      math.max(
        _safeArea.top + _kMenuScreenMargin,
        size.height - _safeArea.bottom - _kMenuScreenMargin,
      ),
    );
    final bool point =
        _anchor.width <= _kMenuPointAnchorExtent &&
        _anchor.height <= _kMenuPointAnchorExtent;
    final double gap = point ? 0 : _kMenuAnchorGap;
    final double spaceBelow = safe.bottom - (_anchor.bottom + gap);
    final double spaceAbove = _anchor.top - gap - safe.top;

    content.layout(
      BoxConstraints(maxWidth: safe.width, maxHeight: safe.height),
      parentUsesSize: true,
    );
    Size menu = content.size;
    final bool fitsBelow = menu.height <= spaceBelow;
    final bool fitsAbove = menu.height <= spaceAbove;
    _above = !fitsBelow && (fitsAbove || spaceAbove > spaceBelow);
    final double room = _above ? spaceAbove : spaceBelow;
    if (menu.height > room &&
        room >= math.min(menu.height, _kMenuMinScrollHeight)) {
      // 两侧都放不下全部：限在较宽裕的一侧，菜单内滚动。
      content.layout(
        BoxConstraints(maxWidth: safe.width, maxHeight: math.max(0, room)),
        parentUsesSize: true,
      );
      menu = content.size;
    }
    double x = _textDirection == TextDirection.rtl
        ? _anchor.right - menu.width
        : _anchor.left;
    double y = _above ? _anchor.top - gap - menu.height : _anchor.bottom + gap;
    x = x.clamp(safe.left, math.max(safe.left, safe.right - menu.width));
    y = y.clamp(safe.top, math.max(safe.top, safe.bottom - menu.height));
    _menuRect = Offset(x, y) & menu;
    (content.parentData! as _FushiMenuLayoutParentData).offset =
        _menuRect.topLeft;

    final RenderBox? surface = _surface;
    if (surface != null) {
      final Rect from = point
          ? Rect.fromLTWH(_anchor.left, _anchor.top, 1, 1)
          : _anchor;
      // 弹簧会略微越过 1（回弹），Rect.lerp 照常外插。
      final Rect r = Rect.lerp(from, _menuRect, _progress.value)!;
      _panelRect = Rect.fromLTWH(
        r.left,
        r.top,
        math.max(1, r.width),
        math.max(1, r.height),
      );
      surface.layout(BoxConstraints.tight(_panelRect.size));
      (surface.parentData! as _FushiMenuLayoutParentData).offset =
          _panelRect.topLeft;
    } else {
      _panelRect = _menuRect;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? surface = _surface;
    if (surface != null) {
      context.paintChild(
        surface,
        offset + (surface.parentData! as _FushiMenuLayoutParentData).offset,
      );
    }
    final RenderBox content = _content;
    final Offset contentOffset =
        (content.parentData! as _FushiMenuLayoutParentData).offset;
    void paintContent(PaintingContext context, Offset offset) {
      context.paintChild(content, offset + contentOffset);
    }

    final double t = _progress.value;
    switch (_motion) {
      case _FushiMenuMotion.morph:
        _clipRectLayer.layer = null;
        if (t == 1 && _panelRect == _menuRect) {
          _clipRRectLayer.layer = null;
          paintContent(context, offset);
          return;
        }
        // 内容按最终位置画，裁进当前帧的面板形状里。
        _clipRRectLayer.layer = context.pushClipRRect(
          needsCompositing,
          offset,
          Offset.zero & size,
          RRect.fromRectAndRadius(
            _panelRect,
            Radius.circular(
              lerpDouble(_startRadius, _endRadius, t.clamp(0.0, 1.0))!,
            ),
          ),
          paintContent,
          oldLayer: _clipRRectLayer.layer,
        );
      case _FushiMenuMotion.reveal:
        _clipRRectLayer.layer = null;
        final double f = t.clamp(0.0, 1.0);
        if (f >= 1) {
          _clipRectLayer.layer = null;
          paintContent(context, offset);
          return;
        }
        // 从锚定边向外展开；横向与远端多留一圈给 Material 阴影。
        const double shadow = 24;
        final double shown = _menuRect.height * f;
        final Rect clip = _above
            ? Rect.fromLTRB(
                _menuRect.left - shadow,
                _menuRect.bottom - shown,
                _menuRect.right + shadow,
                _menuRect.bottom + shadow,
              )
            : Rect.fromLTRB(
                _menuRect.left - shadow,
                _menuRect.top - shadow,
                _menuRect.right + shadow,
                _menuRect.top + shown,
              );
        _clipRectLayer.layer = context.pushClipRect(
          needsCompositing,
          offset,
          clip,
          paintContent,
          oldLayer: _clipRectLayer.layer,
        );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}

class _FushiMenuBody<T> extends StatefulWidget {
  const _FushiMenuBody({required this.route, required this.constraints});

  final _FushiMenuRoute<T> route;

  /// 已并入「至少与触发器同宽」的宽度约束。
  final BoxConstraints constraints;

  @override
  State<_FushiMenuBody<T>> createState() => _FushiMenuBodyState<T>();
}

class _FushiMenuBodyState<T> extends State<_FushiMenuBody<T>> {
  /// 每个菜单项外包一个不可聚焦的 Focus 节点，只用来在打开后找到「该项里
  /// 第一个可聚焦后代」（PopupMenuItem 的 InkWell / Apple 菜单行），把初始
  /// 焦点落过去。
  late final List<FocusNode> _entryNodes = <FocusNode>[
    for (int i = 0; i < widget.route.items.length; i++)
      FocusNode(
        debugLabel: 'FushiMenuEntry#$i',
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
    if (!mounted ||
        !widget.route.requestFocus ||
        !widget.route.focusItemOnOpen) {
      return;
    }
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

  /// 菜单项换成 Apple 菜单行（[_AppleMenuRow]）：[FushiMenuItemData]（仓库
  /// 的 FushiPopupMenuItem）按字段画「单色图标 + 文案」、给了前景色的画成
  /// 破坏性红字；其它 [PopupMenuItem]（含 [CheckedPopupMenuItem]）child 原样
  /// 放进行里、前景色由行统一给（高亮时随之反色）。选中项
  /// （[CheckedPopupMenuItem.checked] / [FushiMenuItemData.selected] /
  /// initialValue 对应项）行尾画 `CupertinoIcons.checkmark`。点击语义同
  /// Flutter 的 `PopupMenuItemState.handleTap`（先带 value 关菜单再 onTap）。
  /// [PopupMenuDivider] → 细分隔线。其它自定义 [PopupMenuEntry] 原样保留。
  Widget _glassEntry(
    BuildContext context,
    PopupMenuEntry<T> entry, {
    required bool highlighted,
  }) {
    final ThemeData theme = Theme.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    if (entry is PopupMenuDivider) return _appleMenuDivider(context);
    if (entry is! PopupMenuItem<T>) return entry;
    final PopupMenuItem<T> item = entry;
    final FushiMenuItemData? data = item is FushiMenuItemData
        ? item as FushiMenuItemData
        : null;
    final bool checked =
        (item is CheckedPopupMenuItem<T> && item.checked) ||
        (data?.selected ?? false) ||
        highlighted;
    Color fg = item.enabled ? apple.label : apple.tertiaryLabel;
    if (item.enabled && data?.color != null) fg = apple.destructive;
    final double iconSize = compact ? 15 : 19;
    // MD3 的默认行高（48 / kMinInteractiveDimension）换成 Apple 行高；调用方
    // 显式要的更高行照用。
    final double rowHeight = item.height <= kMinInteractiveDimension
        ? _menuRowHeight(context)
        : item.height;
    final Widget content;
    if (data != null) {
      content = Row(
        children: <Widget>[
          if (data.icon != null) ...<Widget>[
            FushiIcon(data.icon, size: iconSize),
            SizedBox(width: compact ? 7 : 12),
          ],
          Expanded(
            child: Text(
              data.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else {
      content = item.child ?? const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _menuRowInset(context)),
      child: _AppleMenuRow(
        onTap: () {
          Navigator.pop<T>(context, item.value);
          // 回调可能同步打开新路由，必须先关闭当前菜单。
          item.onTap?.call();
        },
        enabled: item.enabled,
        minHeight: rowHeight,
        radius: _menuRowRadius(context),
        accentHighlight: compact,
        foreground: fg,
        mouseCursor: item.mouseCursor,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 9 : 12,
          vertical: 2,
        ),
        trailing: checked
            ? FushiIcon(CupertinoIcons.checkmark, size: compact ? 13 : 17)
            : null,
        child: IconTheme.merge(
          data: IconThemeData(size: iconSize),
          child: DefaultTextStyle.merge(
            style: (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
              fontSize: compact ? 13 : 17,
              height: 1.25,
              letterSpacing: 0,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            child: content,
          ),
        ),
      ),
    );
  }

  /// MD3（M3 Expressive）菜单项：调用方的 [PopupMenuEntry] 原样放；
  /// initialValue 对应项铺 secondaryContainer 圆角块（左右内缩 4、圆角 12——
  /// M3E 菜单的当前项不再横贯整个容器）；[PopupMenuDivider] 画成左右内缩 12
  /// 的分组线（M3E 的分隔线同样不贯穿容器）。
  Widget _md3Entry(
    BuildContext context,
    PopupMenuEntry<T> entry, {
    required bool highlighted,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (entry is PopupMenuDivider) {
      return SizedBox(
        height: entry.height,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Divider(
              height: 1,
              thickness: entry.thickness ?? 1,
              color: entry.color ?? cs.outlineVariant,
            ),
          ),
        ),
      );
    }
    if (!highlighted) return entry;
    if (isEinkTheme(context)) {
      return ColoredBox(color: Theme.of(context).highlightColor, child: entry);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        child: entry,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final _FushiMenuRoute<T> route = widget.route;
    final int initial = _initialIndex;
    final bool apple = route.apple;
    final bool compact = apple && fushiAppleCompact(context);
    final List<Widget> children = <Widget>[
      for (int i = 0; i < route.items.length; i++)
        Focus(
          focusNode: _entryNodes[i],
          child: apple
              ? _glassEntry(context, route.items[i], highlighted: i == initial)
              : _md3Entry(context, route.items[i], highlighted: i == initial),
        ),
    ];
    final PopupMenuThemeData popupTheme = PopupMenuTheme.of(context);
    final EdgeInsetsGeometry padding =
        route.menuPadding ??
        (apple
            ? EdgeInsets.symmetric(vertical: compact ? 5 : 8)
            : popupTheme.menuPadding ??
                  const EdgeInsets.symmetric(vertical: 8));
    Widget menu = ConstrainedBox(
      constraints: widget.constraints,
      child: IntrinsicWidth(
        stepWidth: apple ? 20 : 56,
        child: Semantics(
          role: SemanticsRole.menu,
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: route.semanticLabel,
          child: SingleChildScrollView(
            padding: padding,
            child: ListBody(children: children),
          ),
        ),
      ),
    );
    if (apple) {
      // 面板（玻璃 + 阴影）由路由单独画、随变形缩放；这里只放内容。
      menu = Material(type: MaterialType.transparency, child: menu);
    } else {
      final ColorScheme cs = Theme.of(context).colorScheme;
      menu = Material(
        shape:
            route.shape ??
            popupTheme.shape ??
            const RoundedRectangleBorder(borderRadius: FushiBorderRadius.menu),
        color: route.color ?? popupTheme.color ?? cs.surfaceContainer,
        clipBehavior: route.clipBehavior,
        type: MaterialType.card,
        elevation: route.elevation ?? popupTheme.elevation ?? 3,
        shadowColor: route.shadowColor ?? popupTheme.shadowColor ?? cs.shadow,
        surfaceTintColor:
            route.surfaceTintColor ??
            popupTheme.surfaceTintColor ??
            Colors.transparent,
        child: menu,
      );
    }
    // 手柄 B 关掉本菜单（焦点随之回触发器），不冒泡成全局「返回」——
    // 全局返回 pop 的是根 Navigator，菜单在嵌套 Navigator 上时会退掉整页。
    return Actions(
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) {
            if (intent.button != GamepadButton.b) return null;
            Navigator.of(context).maybePop();
            return true;
          },
        ),
      },
      child: FocusTraversalGroup(child: menu),
    );
  }
}

/// [PopupMenuButton] 的设计系统分派版。**继承** [PopupMenuButton]，State 也是
/// [PopupMenuButtonState] 子类——仓库里 `GlobalKey<PopupMenuButtonState<T>>`
/// + `showButtonMenu()` 的写法（`FushiOverflowMenu`）改名后照常工作。
/// 两套设计系统的菜单都走 [showFushiMenu]（统一定位：按钮下方 6px、不盖住
/// 按钮；`position` 的 over / under 不再区分）。MD3 下按钮外观走父类 build；
/// 玻璃下按钮是玻璃按钮（`color` / `shape` / `elevation` 这类 MD3 表面参数在
/// 玻璃菜单里不生效）。
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

  /// 标准「文字 + 下拉」触发器（如「传输 ▾」）：触发器是 [FushiMenuLabelTrigger]
  /// ——MD3 主色加粗字 + `expand_more`；Apple 强调色字 +
  /// `chevron.up.chevron.down`（iOS pull-down 按钮）。调用方不再手拼
  /// Text + arrow_drop_down。
  FushiPopupMenuButton.labeled({
    super.key,
    required String label,
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
    super.borderRadius,
    super.splashRadius,
    super.offset,
    super.enabled,
    super.shape,
    super.color,
    super.enableFeedback,
    super.constraints,
    super.position,
    super.clipBehavior,
    super.useRootNavigator,
    super.popUpAnimationStyle,
    super.routeSettings,
    super.style,
    super.requestFocus,
  }) : super(child: FushiMenuLabelTrigger(label: label));

  @override
  PopupMenuButtonState<T> createState() => _FushiPopupMenuButtonState<T>();
}

/// 「文字 + 下拉箭头」菜单触发器的外观（不含点击行为；放进
/// [FushiPopupMenuButton] / `FushiOverflowMenu` 的 `child`）。
/// - MD3：主色 w600 字 + 20 号 `expand_more`，左右 12 / 上下 8；
/// - Apple：强调色 15 号 w500 字 + 13 号 `chevron.up.chevron.down`（iOS 26
///   pull-down 按钮），左右 10 / 上下 6。
class FushiMenuLabelTrigger extends StatelessWidget
    implements FushiShapedMenuTrigger {
  const FushiMenuLabelTrigger({required this.label, this.color, super.key});

  /// MD3 文字按钮形态：全圆角。
  @override
  ShapeBorder menuTriggerShape(BuildContext context) => const StadiumBorder();

  final String label;

  /// 覆盖字与箭头颜色（默认 MD3 primary / Apple accent）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final Color foreground =
        color ??
        (glass
            ? appleColorsOf(context).accent
            : Theme.of(context).colorScheme.primary);
    return Padding(
      padding: glass
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: glass ? 15 : null,
                fontWeight: glass ? FontWeight.w500 : FontWeight.w600,
              ),
            ),
          ),
          SizedBox(width: glass ? 4 : 2),
          FushiIcon(
            glass ? CupertinoIcons.chevron_up_chevron_down : Icons.expand_more,
            size: glass ? 13 : 20,
            color: foreground,
          ),
        ],
      ),
    );
  }
}

class _FushiPopupMenuButtonState<T> extends PopupMenuButtonState<T> {
  bool _glassExpanded = false;
  RelativeRect? _lastPosition;

  /// MD3 自定义触发器的可视形状：调用方显式给的 [PopupMenuButton.borderRadius]
  /// 优先，其次是触发器自己声明的形状（[FushiShapedMenuTrigger]）。都没有时
  /// 返回 null，走框架默认外观。
  ShapeBorder? _materialTriggerShape(BuildContext context) {
    final Widget? child = widget.child;
    if (child == null) return null;
    final BorderRadius? radius = widget.borderRadius;
    if (radius != null) return RoundedRectangleBorder(borderRadius: radius);
    if (child is FushiShapedMenuTrigger) {
      return (child as FushiShapedMenuTrigger).menuTriggerShape(context);
    }
    return null;
  }

  /// MD3 自定义触发器：悬停 / 按压 / 焦点状态层与可视胶囊**同一个形状**、并
  /// 画在触发器**之上**（2026-10-05 用户反馈：书架「阅读状态」筛选 chip 的灰色
  /// 反馈范围与高亮胶囊对不上）。框架 [PopupMenuButton] 把 InkWell 直接包在
  /// child 外：状态层是 child 的外接矩形（未给 borderRadius 时）且画在最近的
  /// Material 上、位于 child 之下——实底胶囊盖住了中间，只在胶囊外的四角露出
  /// 一圈灰。这里把状态层放进一块按同一形状裁剪的透明 Material，叠在 child 上。
  Widget _buildShapedMaterialTrigger(BuildContext context, ShapeBorder shape) {
    final bool enableFeedback =
        widget.enableFeedback ??
        PopupMenuTheme.of(context).enableFeedback ??
        true;
    final NavigationMode mode =
        MediaQuery.maybeNavigationModeOf(context) ?? NavigationMode.traditional;
    final bool canRequestFocus = switch (mode) {
      NavigationMode.traditional => widget.enabled,
      NavigationMode.directional => true,
    };
    final Widget trigger = Stack(
      children: <Widget>[
        widget.child!,
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey<String>('fushi-popup-trigger-ink'),
              customBorder: shape,
              onTap: widget.enabled ? showButtonMenu : null,
              canRequestFocus: canRequestFocus,
              radius: widget.splashRadius,
              enableFeedback: enableFeedback,
            ),
          ),
        ),
      ],
    );
    return Semantics(
      expanded: _glassExpanded,
      child: Tooltip(
        message:
            widget.tooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
        child: trigger,
      ),
    );
  }

  /// 菜单锚 = 按钮矩形（加 [PopupMenuButton.offset]）。图标按钮的点击区比
  /// 可见按钮大一圈 padding，上下各收掉一半，间距按看得见的按钮量。
  RelativeRect _anchorPosition(BuildContext _, BoxConstraints constraints) {
    final RenderObject? button = mounted ? context.findRenderObject() : null;
    final RenderObject? overlay = mounted
        ? Navigator.of(
            context,
            rootNavigator: widget.useRootNavigator,
          ).overlay?.context.findRenderObject()
        : null;
    if (button is! RenderBox ||
        overlay is! RenderBox ||
        !button.attached ||
        !overlay.attached ||
        !button.hasSize) {
      return _lastPosition ??
          RelativeRect.fromSize(Rect.zero, constraints.biggest);
    }
    Rect rect = MatrixUtils.transformRect(
      button.getTransformTo(overlay),
      Offset.zero & button.size,
    ).shift(widget.offset);
    if (widget.child == null) {
      final double inset = widget.padding.vertical / 4;
      if (rect.height > 2 * inset) {
        rect = Rect.fromLTRB(
          rect.left,
          rect.top + inset,
          rect.right,
          rect.bottom - inset,
        );
      }
    }
    return _lastPosition = RelativeRect.fromRect(
      rect,
      Offset.zero & overlay.size,
    );
  }

  @override
  void showButtonMenu() {
    final List<PopupMenuEntry<T>> items = widget.itemBuilder(context);
    if (items.isEmpty) return;
    widget.onOpened?.call();
    setState(() => _glassExpanded = true);
    showFushiMenu<T?>(
      context: context,
      items: items,
      initialValue: widget.initialValue,
      positionBuilder: _anchorPosition,
      elevation: widget.elevation,
      shadowColor: widget.shadowColor,
      surfaceTintColor: widget.surfaceTintColor,
      shape: widget.shape,
      color: widget.color,
      menuPadding: widget.menuPadding,
      constraints: widget.constraints,
      clipBehavior: widget.clipBehavior,
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
    if (!isGlassDesign(context)) {
      final ShapeBorder? shape = _materialTriggerShape(context);
      if (shape == null) return super.build(context);
      return _buildShapedMaterialTrigger(context, shape);
    }
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

/// Apple 菜单面板（MenuAnchor 版）：MenuAnchor 自己的 Material 面在 Apple
/// 下被清成透明无阴影，全部菜单项收进 [_appleMenuSurface] 这一块面板里（项仍
/// 是 MenuAnchor 的直接后代，方向键 / Esc / 子菜单行为不变）。菜单项
/// （[MenuItemButton] 等）经 [MenuButtonTheme] 改成与 showFushiMenu 同一套
/// 行：桌面 macOS 菜单（行高 28、13 号、悬停 / 焦点强调色块 + onAccent 字），
/// 移动 iOS 菜单（行高 44、17 号、按下 fill 灰、焦点 tertiaryFill）。
class _FushiGlassMenuPanel extends StatelessWidget {
  const _FushiGlassMenuPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    bool lit(Set<WidgetState> states) =>
        states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.focused) ||
        states.contains(WidgetState.pressed);
    Color fg(Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) return apple.tertiaryLabel;
      if (compact && lit(states)) return apple.onAccent;
      return apple.label;
    }

    final ButtonStyle rowStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(
        Size(
          _kMenuConstraints.minWidth - 2 * _menuRowInset(context),
          _menuRowHeight(context),
        ),
      ),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: compact ? 9 : 12),
      ),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_menuRowRadius(context)),
        ),
      ),
      backgroundColor: WidgetStateProperty.resolveWith((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.disabled) || !lit(states)) {
          return Colors.transparent;
        }
        if (compact) return apple.accent;
        return states.contains(WidgetState.pressed)
            ? apple.fill
            : apple.tertiaryFill;
      }),
      foregroundColor: WidgetStateProperty.resolveWith(fg),
      iconColor: WidgetStateProperty.resolveWith(fg),
      iconSize: WidgetStatePropertyAll<double>(compact ? 15 : 19),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      textStyle: WidgetStatePropertyAll<TextStyle>(
        TextStyle(fontSize: compact ? 13 : 17, letterSpacing: 0),
      ),
      splashFactory: NoSplash.splashFactory,
      animationDuration: Duration.zero,
    );
    return _appleMenuSurface(
      context,
      MenuButtonTheme(
        data: MenuButtonThemeData(style: rowStyle),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: _menuRowInset(context),
            vertical: compact ? 5 : 8,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: _kMenuConstraints.maxWidth - 2 * _menuRowInset(context),
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
      // Apple 下调用方的 MenuStyle（MD3 底色 / 圆角 / 内边距 / 描边 / 尺寸）
      // 一律不认——面板是 [_FushiGlassMenuPanel] 那块玻璃，MenuAnchor 自己的面
      // 必须透明零边距；只保留决定弹出方位与尺寸上下限的字段（长列表靠
      // maximumSize 限高滚动，下拉靠 minimumSize 对齐触发器宽度）。
      style: glass
          ? _kGlassMenuAnchorStyle.copyWith(
              alignment: style?.alignment,
              minimumSize: style?.minimumSize,
              maximumSize: style?.maximumSize,
              fixedSize: style?.fixedSize,
            )
          : style,
      // 与 showFushiMenu 同一条定位：菜单在锚下方 6px（翻到上方时 MenuAnchor
      // 自己把这 6px 镜像到上方）；调用方显式给了非零偏移就照用。
      alignmentOffset: alignmentOffset == null || alignmentOffset == Offset.zero
          ? const Offset(0, _kMenuAnchorGap)
          : alignmentOffset,
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
/// - [expanded]（表单里撑满的下拉，含 DropdownButtonFormField）= pop-up
///   button bezel：无色透明液态玻璃、圆角 10，当前值 + 行尾
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
    child: field,
  );
  final Widget button = FushiPlainButton(
    onPressed: onTap,
    focusNode: focusNode,
    autofocus: autofocus,
    borderRadius: BorderRadius.circular(expanded ? 10 : minHeight / 2),
    semanticLabel: semanticLabel.isEmpty ? null : semanticLabel,
    child: field,
  );
  // 撑满的表单下拉是 macOS 26 的 pop-up button bezel：控件层，无色透明
  // 液态玻璃（不是 systemFill 灰块）；plain 形态保持无底。
  if (!expanded) return button;
  return fushiClearGlassBezel(context, radius: 10, child: button);
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
          positionBuilder: fushiMenuAnchorPosition(anchor),
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
        dropdownColor:
            widget.dropdownColor ?? Theme.of(context).popupMenuTheme.color,
        menuMaxHeight: widget.menuMaxHeight,
        enableFeedback: widget.enableFeedback,
        alignment: widget.alignment,
        borderRadius:
            widget.borderRadius ?? const BorderRadius.all(Radius.circular(12)),
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
          positionBuilder: fushiMenuAnchorPosition(anchor),
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
        dropdownColor: dropdownColor ?? Theme.of(context).popupMenuTheme.color,
        decoration: fushiMd3FieldDecoration(context, decoration),
        onSaved: onSaved,
        validator: validator,
        errorBuilder: errorBuilder,
        forceErrorText: forceErrorText,
        autovalidateMode: autovalidateMode,
        menuMaxHeight: menuMaxHeight,
        enableFeedback: enableFeedback,
        alignment: alignment,
        borderRadius:
            borderRadius ?? const BorderRadius.all(Radius.circular(12)),
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

/// 强调色高亮行的整行着色：菜单项的文字 / 图标 / 行尾对勾常自带显式颜色
/// （label、强调色），DefaultTextStyle 盖不住——默认单色主题下强调色是黑 /
/// 白，高亮底上就成了黑字黑勾看不见（用户 2026-10-04 报）。高亮时把整行
/// 不透明像素统一染成 [color]（onAccent）；结构恒定，不随高亮增删层。
Widget _accentTint(Color? color, Widget child) => ColorFiltered(
  colorFilter: color == null
      ? const ColorFilter.mode(Colors.transparent, BlendMode.dst)
      : ColorFilter.mode(color, BlendMode.srcIn),
  child: child,
);
