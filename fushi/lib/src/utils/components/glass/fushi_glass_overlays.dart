import 'dart:math' as math;
import 'package:fushi/src/utils/state_resource_scope.dart';
import 'dart:ui' show SemanticsRole, lerpDouble;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/menu_overlay_scroll_boundary.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_compact_landscape.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_divider.dart';
import 'package:fushi/src/utils/components/fushi_scrollbar.dart';
import 'package:fushi/src/utils/components/fushi_menu_presence.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiDialogAction, FushiDialogHeroIcon, fushiM3eMenuAnimationStyle;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_popup_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_dialog_content_scroll.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
    fushiAppleCompact(context) ? 26 * fushiAppleMacScale(context) : 30;

/// macOS 26 sheet 的圆角。
const double _kSheetRadius = 24;

/// iOS 26 alert 内边距基准。
const double _kGlassDialogPad = 20;

/// sheet 内边距：桌面 20、移动 24。
double _sheetPad(BuildContext context) =>
    fushiAppleCompact(context) ? 20 * fushiAppleMacScale(context) : 24;

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

/// 对话框里滚动条离面板右缘的内缩（逻辑像素）。
const double kFushiDialogScrollbarCrossInset = 8;

/// MD3 对话框的默认圆角（M3 规范 extra-large = 28）。
const double _kMd3DialogCornerRadius = 28;

/// 对话框面板内的滚动条内缩：右缘让出 [kFushiDialogScrollbarCrossInset]，首尾各让出
/// 面板圆角半径，拇指与轨道不再贴着、压过圆角（11-20 反馈 #7：声音选择弹窗的滚动条
/// 贴在圆角外缘一直画到底边）。只改子树的 `ScrollbarThemeData` 两个边距，外观其余
/// 照旧走全局主题；面板内所有自动包上的 / 显式的 [FushiScrollbar] 一并受益。
class FushiDialogScrollbarInset extends StatelessWidget {
  const FushiDialogScrollbarInset({
    super.key,
    required this.cornerRadius,
    required this.child,
  });

  /// 面板圆角半径；≤ 0（全屏）时不内缩首尾。
  final double cornerRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ScrollbarThemeData base = ScrollbarTheme.of(context);
    return ScrollbarTheme(
      data: base.copyWith(
        crossAxisMargin: kFushiDialogScrollbarCrossInset,
        mainAxisMargin: math.max(0, cornerRadius),
      ),
      child: child,
    );
  }
}

/// MD3 对话框面板的圆角半径：调用方 shape > 主题 shape > 规范 28。只认圆角矩形族
/// （其它形状取规范值）。
double _md3DialogCornerRadius(BuildContext context, ShapeBorder? shape) {
  final ShapeBorder? effective = shape ?? DialogTheme.of(context).shape;
  final BorderRadiusGeometry? radius = switch (effective) {
    RoundedRectangleBorder(:final BorderRadiusGeometry borderRadius) =>
      borderRadius,
    RoundedSuperellipseBorder(:final BorderRadiusGeometry borderRadius) =>
      borderRadius,
    ContinuousRectangleBorder(:final BorderRadiusGeometry borderRadius) =>
      borderRadius,
    _ => null,
  };
  if (radius == null) return _kMd3DialogCornerRadius;
  final BorderRadius resolved = radius.resolve(Directionality.maybeOf(context));
  return math.max(resolved.topRight.x, resolved.bottomRight.x);
}

/// 与 Material [Dialog] 相同的默认外边距。
const EdgeInsets _kDialogInsetPadding = EdgeInsets.symmetric(
  horizontal: 40,
  vertical: 24,
);

/// 对话框外边距的单一解析：调用方 > 主题 > Material 默认，横屏矮窗口再经
/// [fushiCompactLandscapeInset] 收紧（拍板台 MANKlxTTpV：横屏手机上下 24+24 的
/// 留白吃掉 ~12% 的屏高）。MD3 与 Apple 外壳共用。
EdgeInsets _resolveDialogInset(BuildContext context, EdgeInsets? insetPadding) {
  return fushiCompactLandscapeInset(
    MediaQuery.sizeOf(context),
    insetPadding ??
        DialogTheme.of(context).insetPadding ??
        _kDialogInsetPadding,
  );
}

/// MD3 对话框默认约束（[_kMd3DialogConstraints]），横屏矮窗口放宽宽度上限
/// （[fushiCompactLandscapeConstraints]）；调用方显式给的约束照用。
BoxConstraints _resolveMd3DialogConstraints(
  BuildContext context,
  BoxConstraints? constraints,
) {
  return constraints ??
      fushiCompactLandscapeConstraints(
        MediaQuery.sizeOf(context),
        _kMd3DialogConstraints,
      );
}

/// 浮层面板（对话框 / 菜单 / 提示条）的玻璃参数。着色器档（standard /
/// premium）取库 iOS 27 预设（[fushiGlassSettings]），但对话框（[thick]）要承载
/// 大段文字，玻璃色更厚（深 #262626 @82% / 浅白 @72%）以保证可读；精简 / 实色档
/// 直接用作用域的玻璃。[tint] 为调用方显式背景色。
LiquidGlassSettings _overlayGlassSettings(
  BuildContext context, {
  bool thick = false,
  Color? tint,
}) {
  // 浮层可能压在 WebView / 原生视图上（歌词模式的「⋯」菜单），采不到背景处
  // 用实色兜底（BUG-3055，见 [fushiGlassPlatformViewFallback]）。
  final LiquidGlassSettings base = fushiGlassSettings(context, tint: tint)
      .copyWith(
        platformViewFallbackColor: fushiGlassPlatformViewFallback(context),
      );
  if (tint != null || !thick || !glassMaterialOf(context).usesShader) {
    return base;
  }
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return base.copyWith(
    glassColor: dark
        ? const Color(0xFF262626).withValues(alpha: 0.82)
        : Colors.white.withValues(alpha: 0.72),
  );
}

// Apple 菜单（用户 2026-11-24 给的真 iOS 27 菜单截图为准）：所有 Apple 弹出
// 菜单（showFushiMenu / FushiPopupMenuButton / 顶栏「⋯」/ FushiMenuAnchor /
// 自建菜单面板）共用这一套面板（[_appleMenuSurface]）与行（[_AppleMenuRow] /
// [FushiAppleMenuItemRow] / [_FushiGlassMenuPanel] 的 MenuButtonTheme）：
// - 行 = [✓ 列][图标][文字（+ 副标题）][行尾：子菜单 › / 快捷键]；勾选项在
//   ✓ 列画 label 色对勾，当前项不铺底；无图标的行文字直接从图标位起；
// - iOS（触屏 / 窄窗）：面板圆角 34、上下内边距 12、宽 250–280；行高 50
//   （带副标题更高）、17 号字、副标题 15 号 secondaryLabel、✓ 列 24、图标 22；
//   按下 / 悬停 / 键盘焦点 = 中性灰全圆角胶囊（左右内缩 12）；分组发丝线左右
//   缩进 24；
// - macOS 26 / 27（宽屏）：面板圆角 12、内边距 5；行高 24、高亮圆角矩形 7、
//   13 号字、✓ 列 16、行左右内边距 8；快捷键在行尾；分组线缩进 10。
// - 高亮：两档都是中性浅灰（[_menuHighlight]），文字保持 label 色。系统
//   macOS 菜单的悬停高亮其实是强调色圆角块 + 白字，用户 2026-11-24 嫌「下拉
//   框还是有强调色」，暂按中性灰，待用户拍板。
// 面板是随「玻璃画质」的厚玻璃（实色档 = 系统实色面）+ 外圈柔和阴影，从锚点
// 形变展开。

/// 菜单面板圆角：与行高亮块同心——R = 高亮圆角 + 内缩。
/// - 窄屏 iOS 27（截图规格）：胶囊半高 25 + 内缩 12 = 37；
/// - 宽屏 macOS 26 / 27 菜单：高亮圆角矩形 7 + 内缩 5 = 12（Tahoe 起菜单比
///   Sequoia 的 6 更圆）。
double _menuRadius(BuildContext context) => fushiAppleCompact(context)
    ? _menuRowRadius(context) + _menuRowInset(context)
    : _menuRowHeight(context) / 2 + _menuRowInset(context);

/// 菜单行高（窄屏 iOS 50；宽屏 macOS 24）。
double _menuRowHeight(BuildContext context) =>
    fushiAppleCompact(context) ? 24 * fushiAppleMacScale(context) : 50;

/// 菜单行高亮块圆角：窄屏 iOS 全圆角胶囊（取半高，带副标题的高行同样全圆）；
/// 宽屏 macOS 圆角矩形 7。
double _menuRowRadius(BuildContext context) =>
    fushiAppleCompact(context) ? 7 * fushiAppleMacScale(context) : 999;

/// 菜单行与面板边缘的内缩（左右与上下同值，保证同心）。
double _menuRowInset(BuildContext context) =>
    fushiAppleCompact(context) ? 5 * fushiAppleMacScale(context) : 12;

/// 菜单行高亮（悬停 / 按下 / 键盘焦点）：中性浅灰，不用强调色（用户
/// 2026-11-24「下拉框还是有强调色」）。深色 white 14% / 浅色 black 8%，按下
/// 再深一档。
Color _menuHighlight(BuildContext context, {bool pressed = false}) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return dark
      ? Colors.white.withValues(alpha: pressed ? 0.20 : 0.14)
      : Colors.black.withValues(alpha: pressed ? 0.12 : 0.08);
}

/// 菜单行字号（iOS 17；macOS 宽窗 14）。
double _menuFontSize(BuildContext context) =>
    fushiAppleCompact(context) ? 13 * fushiAppleMacScale(context) : 17;

/// 菜单面板默认宽度：macOS 菜单 200–280，iOS 上下文菜单 250 起（系统定宽
/// 约 250）。
BoxConstraints _menuConstraints(BuildContext context) =>
    fushiAppleCompact(context)
    ? BoxConstraints(
        minWidth: 200 * fushiAppleMacScale(context),
        maxWidth: 280 * fushiAppleMacScale(context),
      )
    : const BoxConstraints(minWidth: 250, maxWidth: 280);

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
  final double macScale = fushiAppleMacScale(context);
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return CustomPaint(
    // Apple 浮层投影：大半径、很淡、偏移小于模糊半径（面板下沿不出现硬边
    // 灰带）。
    painter: _OuterShadowPainter(
      radius: r,
      color: Colors.black.withValues(
        alpha: (dark ? 0.30 : 0.12) * shadowOpacity.clamp(0.0, 1.0),
      ),
      blur: compact ? 28 * macScale : 44,
      offset: Offset(0, compact ? 6 * macScale : 10),
    ),
    child: GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      settings: glassMaterialOf(context) == FushiGlassMaterial.off
          // 实色档：系统菜单实色面（深 #2C2C2E 抬升底 / 浅纯白），零模糊不透明。
          ? _overlayGlassSettings(context, thick: true).copyWith(
              glassColor: dark ? const Color(0xFF2C2C2E) : Colors.white,
              blur: 0,
            )
          : _overlayGlassSettings(context, thick: true),
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

/// Apple 浮层（对话框 / 进度框 / 桌面 sheet）的投影：一层大半径很淡的环境
/// 投影 + 一层贴边的细接触阴影（macOS / iOS 窗口与 alert 的观感）。偏移远小
/// 于模糊半径，面板下沿不会出现一条偏硬的灰带。
List<BoxShadow> fushiAppleOverlayShadows({required bool dark}) => <BoxShadow>[
  BoxShadow(
    color: Colors.black.withValues(alpha: dark ? 0.30 : 0.10),
    blurRadius: 64,
    spreadRadius: -8,
    offset: const Offset(0, 12),
  ),
  BoxShadow(
    color: Colors.black.withValues(alpha: dark ? 0.20 : 0.05),
    blurRadius: 3,
    offset: const Offset(0, 1),
  ),
];

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
    final Widget child = FushiDialogScrollbarInset(
      cornerRadius: radius,
      child: this.child,
    );
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
          color: Colors.black.withValues(alpha: dark ? 0.32 : 0.12),
          blur: 64,
          offset: const Offset(0, 12),
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
        shadows: fushiAppleOverlayShadows(dark: dark),
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
    this.widenInCompactLandscape = true,
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

  /// 横屏矮窗口是否放宽 [defaultConstraints] 的宽度上限。iOS 纯文字 alert 宽度
  /// 固定（不随窗口伸缩），传 false。
  final bool widenInCompactLandscape;

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
        _resolveDialogInset(context, insetPadding);
    final BoxConstraints effectiveConstraints =
        constraints ??
        (widenInCompactLandscape
            ? fushiCompactLandscapeConstraints(
                MediaQuery.sizeOf(context),
                defaultConstraints,
              )
            : defaultConstraints);
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
              constraints: effectiveConstraints,
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
    fontSize: fushiAppleCompact(context)
        ? 15 * fushiAppleMacScale(context)
        : 17,
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
    fontSize: fushiAppleCompact(context)
        ? 13 * fushiAppleMacScale(context)
        : 15,
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
    this.scrollable,
  }) : scrollController = null,
       actionScrollController = null,
       insetAnimationDuration = const Duration(milliseconds: 100),
       insetAnimationCurve = Curves.decelerate,
       _adaptive = false;

  /// [AlertDialog.adaptive] 的分派版：MD3 下恒为 Material 对话框（`auto` 五平台
  /// 统一 M3E，iOS 不再出 Cupertino 对话框，BUG-3309），只有隐藏的
  /// `FushiDesignSystem.cupertino` 才按平台分派（[useCupertinoAdaptiveControls]）；
  /// 玻璃下（含用户可见的「Cupertino」玻璃设计）与默认构造器同一个玻璃外壳。
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
    this.scrollable,
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

  /// null（默认）= 内容区「装得下原样、装不下就滚」（[FushiDialogContentScroll]）：
  /// 含输入框的对话框在键盘弹出 / 小窗口里不再溢出，调用点不必再手包
  /// `SingleChildScrollView`；吃满剩余高度的内容（列表）布局不变。
  /// true = [AlertDialog.scrollable]（标题与内容一起滚，内容拿无界高度）；
  /// false = 不套任何滚动，内容自己管高度。
  final bool? scrollable;
  final ScrollController? scrollController;
  final ScrollController? actionScrollController;
  final Duration insetAnimationDuration;
  final Curve insetAnimationCurve;
  final bool _adaptive;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context) &&
        _adaptive &&
        useCupertinoAdaptiveControls(context)) {
      return FushiDialogScrollbarInset(
        cornerRadius: _md3DialogCornerRadius(context, shape),
        child: AlertDialog.adaptive(
          icon: _md3HeroIcon(),
          iconPadding: iconPadding,
          iconColor: iconColor,
          title: title,
          titlePadding: titlePadding,
          titleTextStyle: titleTextStyle,
          content: _scrollableContent(),
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
          insetPadding: _resolveDialogInset(context, insetPadding),
          clipBehavior: clipBehavior,
          shape: shape,
          alignment: alignment,
          constraints: _resolveMd3DialogConstraints(context, constraints),
          scrollable: scrollable ?? false,
          scrollController: scrollController,
          actionScrollController: actionScrollController,
          insetAnimationDuration: insetAnimationDuration,
          insetAnimationCurve: insetAnimationCurve,
        ),
      );
    }
    if (!isGlassDesign(context)) {
      return FushiDialogScrollbarInset(
        cornerRadius: _md3DialogCornerRadius(context, shape),
        child: AlertDialog(
          icon: _md3HeroIcon(),
          iconPadding: iconPadding,
          iconColor: iconColor,
          title: title,
          titlePadding: titlePadding,
          titleTextStyle: titleTextStyle,
          content: _scrollableContent(),
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
          insetPadding: _resolveDialogInset(context, insetPadding),
          clipBehavior: clipBehavior,
          shape: shape,
          alignment: alignment,
          constraints: _resolveMd3DialogConstraints(context, constraints),
          scrollable: scrollable ?? false,
        ),
      );
    }
    return _buildGlass(context);
  }

  /// 内容区按 [scrollable] 套滚动外壳（null 才套，见字段注释）。
  Widget? _scrollableContent() {
    final Widget? raw = content;
    if (raw == null || scrollable != null) return raw;
    return FushiDialogContentScroll(child: raw);
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
        child: _scrollableContent()!,
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
    if (scrollable ?? false) {
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
      widenInCompactLandscape: false,
      clipBehavior: clipBehavior,
      semanticsRole: SemanticsRole.alertDialog,
      child: _assemble(head, contentWidget, actionsWidget),
    );
  }

  Widget _buildAppleSheet(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final double pad = _sheetPad(context);
    final bool compact = fushiAppleCompact(context);
    final double macScale = fushiAppleMacScale(context);
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
                    size: compact ? 17 * macScale : 20,
                  ),
                  child: icon!,
                ),
                if (title != null) SizedBox(width: compact ? 8 * macScale : 10),
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
      return FushiDialogScrollbarInset(
        cornerRadius: _md3DialogCornerRadius(context, shape),
        child: SimpleDialog(
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
          insetPadding: _resolveDialogInset(context, insetPadding),
          clipBehavior: clipBehavior,
          shape: shape,
          alignment: alignment,
          constraints: _resolveMd3DialogConstraints(context, constraints),
          children: children,
        ),
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
    final double macScale = fushiAppleMacScale(context);
    // 菜单式选项行：行高 36（桌面）/ 44（移动），悬停 tertiaryFill 圆角底。
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 * macScale : 10),
      child: _AppleMenuRow(
        onTap: onPressed ?? () {},
        enabled: onPressed != null,
        minHeight: compact ? 36 * macScale : 44,
        radius: compact ? 8 * macScale : 12,
        foreground: onPressed != null ? apple.label : apple.tertiaryLabel,
        padding:
            padding ??
            EdgeInsets.symmetric(
              vertical: 6,
              horizontal: compact ? 12 * macScale : 14,
            ),
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
      return FushiDialogScrollbarInset(
        cornerRadius: _md3DialogCornerRadius(context, shape),
        child: Dialog(
          backgroundColor: backgroundColor,
          elevation: elevation,
          shadowColor: shadowColor,
          surfaceTintColor: surfaceTintColor,
          insetAnimationDuration: insetAnimationDuration,
          insetAnimationCurve: insetAnimationCurve,
          insetPadding: _resolveDialogInset(context, insetPadding),
          clipBehavior: clipBehavior,
          shape: shape,
          alignment: alignment,
          semanticsRole: semanticsRole,
          constraints: constraints,
          child: child,
        ),
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

/// Apple 菜单 / 列表选项行：无底，[leading]（行首对勾列）+ 内容。
/// 高亮：悬停 / 按下 / 键盘焦点一律中性浅灰（iOS 全圆角胶囊 / macOS 圆角矩形，[_menuHighlight]），
/// 文字保持 label 色，所有尺寸档都不用强调色。前景色由行自己给（[foreground]），高亮时才能整体反色。
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
    this.leading,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
  });

  final VoidCallback onTap;
  final bool enabled;
  final double minHeight;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color foreground;
  final Widget child;

  /// 行首列（菜单的对勾列，已定宽）；null = 不占位。
  final Widget? leading;
  final FocusNode? focusNode;
  final bool autofocus;
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
    final bool enabled = widget.enabled;
    final bool highlight = enabled && (_hovered || _pressed || _focused);
    final Color background = !highlight
        ? Colors.transparent
        : _menuHighlight(context, pressed: _pressed);
    final Color fg = widget.foreground;
    final Widget body = AnimatedContainer(
      // 高亮跟手：按下瞬时，悬停 / 焦点短渐变。
      duration: _pressed
          ? Duration.zero
          : fushiMotionDuration(context, FushiMotion.micro),
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
          child: Row(
            children: <Widget>[
              ?widget.leading,
              Expanded(child: widget.child),
            ],
          ),
        ),
      ),
    );
    return FocusableActionDetector(
      enabled: enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
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

/// 调用方菜单项里的「两行文字」（`Column[Text, Text]`，或 `Row[…, Column[Text,
/// Text], …]`）在 Apple 菜单里把第二行画成副标题（iOS 15 / macOS 11 号
/// secondaryLabel）。其他形状原样返回。
Widget _appleMenuSubtitle(BuildContext context, Widget child) {
  if (child is Row) {
    final List<Widget> cells = child.children;
    final int at = cells.indexWhere((Widget w) => w is Column);
    if (at < 0) return child;
    return Row(
      key: child.key,
      mainAxisSize: child.mainAxisSize,
      mainAxisAlignment: child.mainAxisAlignment,
      crossAxisAlignment: child.crossAxisAlignment,
      children: <Widget>[
        for (int i = 0; i < cells.length; i++)
          i == at ? _appleMenuSubtitle(context, cells[i]) : cells[i],
      ],
    );
  }
  if (child is! Column ||
      child.children.length != 2 ||
      child.children.any((Widget w) => w is! Text)) {
    return child;
  }
  return Column(
    key: child.key,
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      child.children[0],
      DefaultTextStyle.merge(
        style: _menuSubtitleStyle(context),
        child: child.children[1],
      ),
    ],
  );
}

/// 宽屏 macOS 菜单不画行内图标：调用方 [PopupMenuItem] 里 `Row[图标, 定宽
/// SizedBox, …]` 去掉开头的图标与间距；其他形状原样返回。
Widget _appleMenuStripLeadingIcon(Widget child) {
  if (child is! Row || child.children.length < 3) return child;
  final List<Widget> cells = child.children;
  final Widget first = cells[0];
  final Widget gap = cells[1];
  if (first is! FushiIcon && first is! Icon) return child;
  if (gap is! SizedBox || gap.child != null || gap.width == null) return child;
  return Row(
    key: child.key,
    mainAxisSize: child.mainAxisSize,
    mainAxisAlignment: child.mainAxisAlignment,
    crossAxisAlignment: child.crossAxisAlignment,
    children: cells.sublist(2),
  );
}

/// 菜单副标题字样。
TextStyle _menuSubtitleStyle(BuildContext context) => TextStyle(
  fontSize: fushiAppleCompact(context) ? 11 * fushiAppleMacScale(context) : 15,
  height: 1.25,
  letterSpacing: 0,
  color: appleColorsOf(context).secondaryLabel,
);

/// 菜单行 ✓ 列 / 图标与文字的间距。
double _menuIconGap(BuildContext context) =>
    fushiAppleCompact(context) ? 6 * fushiAppleMacScale(context) : 12;

/// Apple 弹出菜单的公共面板（与 showFushiMenu / FushiMenuAnchor 同一块）：
/// 随「玻璃画质」的厚玻璃（实色档 = 系统实色面）+ 外圈柔和阴影，圆角取菜单
/// 规格（macOS 10 / iOS 24）。自建菜单面板（媒体项右键菜单等）一律用它，
/// 不另画表面。
class FushiAppleMenuSurface extends StatelessWidget {
  const FushiAppleMenuSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _appleMenuSurface(context, child);
}

/// Apple 弹出菜单的公共行（iOS 27 / macOS 27 菜单口径，与 showFushiMenu 同一
/// 行 [_AppleMenuRow]）：[selected] 时行首对勾、文字（+ [subtitle]）在前、
/// [trailing]（子菜单 chevron 等）与图标在行尾；破坏性红字；高亮见
/// [_AppleMenuRow]。行左右内缩由调用方的面板 padding 给（[fushiAppleMenuRowInset]）。
class FushiAppleMenuItemRow extends StatelessWidget {
  const FushiAppleMenuItemRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.subtitle,
    this.destructive = false,
    this.selected = false,
    this.checkColumn = false,
    this.trailing,
    this.focusNode,
    this.autofocus = false,
  });

  /// 同组有勾选项时 true：未勾的行也让出 ✓ 列（文字左缘对齐）。
  final bool checkColumn;
  final IconData? icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onPressed;
  final bool destructive;
  final bool selected;
  final Widget? trailing;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final double macScale = fushiAppleMacScale(context);
    final bool enabled = onPressed != null;
    final Color fg = !enabled
        ? apple.tertiaryLabel
        : (destructive ? apple.destructive : apple.label);
    final String? sub = subtitle;
    final Widget text = sub == null
        ? Text(label, maxLines: 2, overflow: TextOverflow.ellipsis)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _menuSubtitleStyle(context),
              ),
            ],
          );
    final Widget? tail = trailing;
    // 宽屏 macOS 菜单不画行内图标（用户 2026-11-24 拍板），窄屏 iOS 保留。
    final IconData? glyph = compact ? null : icon;
    return _AppleMenuRow(
      onTap: onPressed ?? () {},
      enabled: enabled,
      focusNode: focusNode,
      autofocus: autofocus,
      minHeight: _menuRowHeight(context),
      radius: _menuRowRadius(context),
      foreground: fg,
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: _menuItemPadding(context),
        vertical: compact ? 2 * macScale : 6,
      ),
      leading: checkColumn || selected
          ? Padding(
              padding: EdgeInsetsDirectional.only(end: _menuIconGap(context)),
              child: FushiAppleMenuCheck(checked: selected),
            )
          : null,
      child: IconTheme.merge(
        data: IconThemeData(size: compact ? 15 * macScale : 22),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontSize: _menuFontSize(context),
            height: 1.25,
            letterSpacing: 0,
          ),
          child: Row(
            children: <Widget>[
              if (glyph != null) ...<Widget>[
                FushiIcon(glyph),
                SizedBox(width: _menuIconGap(context)),
              ],
              Expanded(child: text),
              if (tail != null) ...<Widget>[const SizedBox(width: 8), tail],
            ],
          ),
        ),
      ),
    );
  }
}

/// Apple 菜单行与面板的左右内缩（自建菜单面板给行留的边距）。
double fushiAppleMenuRowInset(BuildContext context) => _menuRowInset(context);

/// [FushiMenuAnchor] 菜单项之间的 Apple 组间分隔线（与 showFushiMenu 的
/// [PopupMenuDivider] 同一画法）。只在 Apple 设计系统的菜单里用。
class FushiAppleMenuDivider extends StatelessWidget {
  const FushiAppleMenuDivider({super.key});

  @override
  Widget build(BuildContext context) => _appleMenuDivider(context);
}

/// Apple 菜单的组间细分隔线（separator 色，半像素，两侧内缩）。
Widget _appleMenuDivider(BuildContext context) {
  final bool compact = fushiAppleCompact(context);
  final double macScale = fushiAppleMacScale(context);
  return SizedBox(
    height: compact ? 11 * macScale : 17,
    child: Center(
      child: Container(
        height: 0.5,
        margin: EdgeInsets.symmetric(horizontal: compact ? 10 * macScale : 24),
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
  // 任何时刻至多一个菜单：平台视图（macOS WebView）吞掉点击时旧菜单的遮罩收不到
  // 事件，不先关掉就会一层层叠上去（反馈 U_8sCB0h_f）。
  FushiMenuPresence.instance.dismissAll();
  final _FushiMenuRoute<T> route = _FushiMenuRoute<T>(
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
  );
  // 在场登记由路由自己按生命周期管（install 登记，didComplete / dispose 注销），
  // 不靠 push 返回的 future：菜单开着时整个 Navigator 被销毁，future 不会完成。
  return navigator.push(route).then<T?>((T? value) {
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

  /// [FushiMenuPresence] 的注销回调；null = 未登记 / 已注销。
  VoidCallback? _unregisterPresence;

  void _releasePresence() {
    final VoidCallback? unregister = _unregisterPresence;
    _unregisterPresence = null;
    unregister?.call();
  }

  @override
  void install() {
    super.install();
    _unregisterPresence ??= FushiMenuPresence.instance.register(this);
  }

  @override
  void didComplete(T? result) {
    // 出栈（选中 / 取消 / 被移除）即不在场，退场动效期间不再算菜单开着。
    _releasePresence();
    super.didComplete(result);
  }

  @override
  void dispose() {
    // Navigator 整体销毁时路由只 dispose、不 didComplete：这里兜住，登记不泄漏。
    _releasePresence();
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
          constraints ??
              (apple ? _menuConstraints(context) : _kMd3MenuConstraints),
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
    // Apple（有玻璃面板 [_surface]）：锚点在屏幕后半边时面板末端对齐锚点末端、
    // 向内展开（iOS / macOS 菜单从屏幕边上的按钮往里长，不贴着锚点起始边伸出
    // 去再被屏幕边推回）。MD3 维持起始边对齐。
    final bool apple = _surface != null;
    final bool rtl = _textDirection == TextDirection.rtl;
    final bool inTrailingHalf = rtl
        ? _anchor.center.dx < safe.center.dx
        : _anchor.center.dx > safe.center.dx;
    final bool alignEnd = rtl != (apple && inTrailingHalf);
    double x = alignEnd ? _anchor.right - menu.width : _anchor.left;
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

class _FushiMenuBodyState<T> extends State<_FushiMenuBody<T>>
    with StateResourceScope<_FushiMenuBody<T>> {
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
    schedulePostFrame((_) => _focusInitial());
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
    required bool checkColumn,
  }) {
    final ThemeData theme = Theme.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final double macScale = fushiAppleMacScale(context);
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
    final double iconSize = compact ? 15 * macScale : 22;
    // MD3 的默认行高（48 / kMinInteractiveDimension）换成 Apple 行高；调用方
    // 显式要的更高行照用。
    final double rowHeight = item.height <= kMinInteractiveDimension
        ? _menuRowHeight(context)
        : item.height;
    final Widget content;
    if (data != null) {
      // iOS / macOS 27 菜单：[图标][文字]。
      content = Row(
        children: <Widget>[
          if (data.icon != null && !compact) ...<Widget>[
            FushiIcon(data.icon, size: iconSize),
            SizedBox(width: _menuIconGap(context)),
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
      final Widget raw = item.child ?? const SizedBox.shrink();
      content = _appleMenuSubtitle(
        context,
        compact ? _appleMenuStripLeadingIcon(raw) : raw,
      );
    }
    return Padding(
      // 保留调用方给菜单项的 key（与 M3E PopupMenuItem 同：焦点驱动 / 测试按 key 找项）。
      key: item.key,
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
        foreground: fg,
        mouseCursor: item.mouseCursor,
        padding: EdgeInsetsDirectional.symmetric(
          horizontal: _menuItemPadding(context),
          vertical: compact ? 2 * macScale : 6,
        ),
        // 当前项：行首对勾（label 色，高亮时随行反色），不铺强调色底。
        leading: checkColumn
            ? Padding(
                padding: EdgeInsetsDirectional.only(end: _menuIconGap(context)),
                child: FushiAppleMenuCheck(checked: checked),
              )
            : null,
        child: IconTheme.merge(
          data: IconThemeData(size: iconSize),
          child: DefaultTextStyle.merge(
            style: (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
              fontSize: _menuFontSize(context),
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
    // 当前项的底色必须由 [Material] 承载，不能用 ColoredBox / DecoratedBox：菜单项
    // 里的 InkWell / ListTile 把水波和底色画在**最近的 Material** 上，即菜单容器
    // 那层；中间夹一个不透明的装饰盒就把它们整个盖住（按下无水波，ListTile 的
    // debug 断言「background color or ink splashes may be invisible」）。
    if (isEinkTheme(context)) {
      return Material(color: Theme.of(context).highlightColor, child: entry);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: cs.secondaryContainer,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        child: entry,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final _FushiMenuRoute<T> route = widget.route;
    final int initial = _initialIndex;
    final bool apple = route.apple;
    // 整组有可勾选项（当前值 / CheckedPopupMenuItem / 选中的结构化项）时每行
    // 都让出行首对勾列，文字左缘对齐（iOS / macOS 菜单同）。
    final bool checkColumn =
        apple &&
        (initial >= 0 ||
            route.items.any(
              (PopupMenuEntry<T> e) =>
                  e is CheckedPopupMenuItem<T> ||
                  (e is FushiMenuItemData && (e as FushiMenuItemData).selected),
            ));
    final List<Widget> children = <Widget>[
      for (int i = 0; i < route.items.length; i++)
        Focus(
          focusNode: _entryNodes[i],
          child: apple
              ? _glassEntry(
                  context,
                  route.items[i],
                  highlighted: i == initial,
                  checkColumn: checkColumn,
                )
              : _md3Entry(context, route.items[i], highlighted: i == initial),
        ),
    ];
    final PopupMenuThemeData popupTheme = PopupMenuTheme.of(context);
    final EdgeInsetsGeometry padding =
        route.menuPadding ??
        (apple
            ? EdgeInsets.symmetric(vertical: _menuRowInset(context))
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
/// - Apple：中性灰胶囊 pop-up 按钮（[FushiApplePopUpButtonFace]，`label` 色字 +
///   `chevron.up.chevron.down`，不着强调色）；调用方显式给 [color] 时仍画无底
///   「字 + 双箭头」形态。
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
    if (glass && color == null) {
      // Apple：与其余下拉同一枚中性灰胶囊 pop-up 按钮（不着强调色）。
      return FushiApplePopUpButtonFace(label: label);
    }
    final Color foreground =
        color ??
        (glass
            ? appleColorsOf(context).label
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
            glass
                ? CupertinoIcons.chevron_up_chevron_down
                : FushiIcons.expandMore,
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
        button = FushiTooltip(message: tooltip, child: button);
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
/// 行（与 showFushiMenu 同一规格：中性浅灰高亮、不用强调色；
/// 行高 / 字号 / 内缩见 [_menuRowHeight] 一组）。
class _FushiGlassMenuPanel extends StatefulWidget {
  const _FushiGlassMenuPanel({required this.children});

  final List<Widget> children;

  @override
  State<_FushiGlassMenuPanel> createState() => _FushiGlassMenuPanelState();
}

class _FushiGlassMenuPanelState extends State<_FushiGlassMenuPanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = widget.children;
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final double macScale = fushiAppleMacScale(context);
    bool lit(Set<WidgetState> states) =>
        states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.pressed) ||
        states.contains(WidgetState.focused);
    // 所有尺寸档：中性浅灰高亮（iOS 胶囊 / macOS 圆角矩形），文字保持 label 色。
    Color fg(Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) return apple.tertiaryLabel;
      return apple.label;
    }

    final ButtonStyle rowStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(
        Size(
          _menuConstraints(context).minWidth - 2 * _menuRowInset(context),
          _menuRowHeight(context),
        ),
      ),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: _menuItemPadding(context)),
      ),
      // 桌面 Theme 是 compact 密度：MenuItemButton 会按它把行高 −8、左右内边距
      // −8（行高只剩 16、文字贴面板边），菜单行一律按标准密度量。
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      alignment: AlignmentDirectional.centerStart,
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
        return _menuHighlight(
          context,
          pressed: states.contains(WidgetState.pressed),
        );
      }),
      foregroundColor: WidgetStateProperty.resolveWith(fg),
      iconColor: WidgetStateProperty.resolveWith(fg),
      iconSize: WidgetStatePropertyAll<double>(compact ? 15 * macScale : 22),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      textStyle: WidgetStatePropertyAll<TextStyle>(
        TextStyle(
          fontSize: _menuFontSize(context),
          height: 1.25,
          letterSpacing: 0,
        ),
      ),
      splashFactory: NoSplash.splashFactory,
      animationDuration: Duration.zero,
    );
    final bool checkColumn = children.any(_isCheckableMenuItem);
    final MediaQueryData mq = MediaQuery.of(context);
    // 面板自己限高、内部滚动（不交给 MenuAnchor 外层的滚动视图）：内容再多也
    // 不会长出屏幕、溢出圆角或露出玻璃之外的透明底。
    final double maxHeight = math.max(
      120,
      mq.size.height - mq.padding.vertical - 2 * (_kMenuAnchorGap + 12),
    );
    return _appleMenuSurface(
      context,
      MenuButtonTheme(
        data: MenuButtonThemeData(style: rowStyle),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: maxHeight,
            maxWidth: _menuConstraints(context).maxWidth,
          ),
          child: FushiScrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.symmetric(
                horizontal: _menuRowInset(context),
                vertical: _menuRowInset(context),
              ),
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final Widget child in children)
                      _appleMenuItemButton(
                        context,
                        child,
                        checkColumn: checkColumn,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// macOS / iOS 菜单行的左右内边距（MenuItemButton 与 showFushiMenu 行同值）。
double _menuItemPadding(BuildContext context) =>
    fushiAppleCompact(context) ? 8 * fushiAppleMacScale(context) : 12;

/// 行首对勾列宽（[FushiAppleMenuCheck] 的宽度）。
double _menuCheckSlot(BuildContext context) =>
    fushiAppleCompact(context) ? 16 * fushiAppleMacScale(context) : 24;

/// MenuItemButton 前置图标与文字的间距（material 按 Theme 密度算，这里同算）。
double _menuLabelGap(BuildContext context) =>
    math.max(4, 12 + Theme.of(context).visualDensity.horizontal * 2);

/// Apple 菜单的行首对勾列（MenuAnchor 菜单项的 `leadingIcon`）：[checked] 时
/// 画 ✓（label 色、高亮时随行反色），否则留同宽空位让文字左缘对齐。
class FushiAppleMenuCheck extends StatelessWidget {
  const FushiAppleMenuCheck({super.key, required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: _menuCheckSlot(context),
    child: checked
        ? FushiIcon(
            CupertinoIcons.checkmark,
            size: fushiAppleCompact(context)
                ? 12 * fushiAppleMacScale(context)
                : 17,
          )
        : null,
  );
}

/// Apple 菜单的分组小标题（不可聚焦）：macOS 11 / iOS 13 号 secondaryLabel，
/// 左缘与带 [FushiAppleMenuCheck] 的行文字对齐（[alignWithCheck] = false 时
/// 与无对勾列的行对齐）。
class FushiAppleMenuSectionHeader extends StatelessWidget {
  const FushiAppleMenuSectionHeader(
    this.text, {
    super.key,
    this.alignWithCheck = true,
  });

  final String text;
  final bool alignWithCheck;

  @override
  Widget build(BuildContext context) {
    final bool compact = fushiAppleCompact(context);
    final double macScale = fushiAppleMacScale(context);
    final double start =
        _menuItemPadding(context) +
        (alignWithCheck ? _menuCheckSlot(context) + _menuLabelGap(context) : 0);
    return ExcludeFocus(
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          start,
          compact ? 4 * macScale : 8,
          _menuItemPadding(context),
          compact ? 2 * macScale : 4,
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 11 * macScale : 13,
            fontWeight: compact ? FontWeight.w600 : FontWeight.w400,
            color: appleColorsOf(context).secondaryLabel,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

/// MenuAnchor 菜单项改排成 iOS / macOS 27 菜单行（[_FushiGlassMenuPanel] 对
/// 每个直接子项调用；原项的焦点 / 回调 / 关闭行为一字不差搬过去）：
/// - [MenuItemButton]：行 = [✓ 列][图标][文字][快捷键 / 尾部]（iOS 27 与 macOS
///   菜单都是图标在文字前）；MD3 写法「行尾一个勾 = 选中」改成行首 ✓；同组有
///   勾选项时其余行也让出 ✓ 列。
/// - [CheckboxMenuButton] / [RadioMenuButton]：MD3 的复选框 / 单选圈换成行首
///   对勾列（勾上 = ✓，未勾 = 空位对齐），点击语义照旧（复选按 tristate 轮转、
///   单选选中本值 / toggleable 再点取消），读屏补 checked / 互斥组。
/// - [SubmenuButton]：行尾 `›`（tertiaryLabel），子菜单面板透明化并收进同一块
///   [_FushiGlassMenuPanel]（递归套用本规则）。
Widget _appleMenuItemButton(
  BuildContext context,
  Widget child, {
  required bool checkColumn,
}) {
  final bool compact = fushiAppleCompact(context);
  final double macScale = fushiAppleMacScale(context);
  final FushiAppleColors apple = appleColorsOf(context);
  Widget checkSlot(bool checked) => FushiAppleMenuCheck(checked: checked);
  if (child is FushiDivider || child is Divider) {
    return _appleMenuDivider(context);
  }
  // 调用方给菜单项包的 Actions（手柄 B 关菜单等）：保留外壳、改里面的项。
  if (child is Actions) {
    return Actions(
      key: child.key,
      dispatcher: child.dispatcher,
      actions: child.actions,
      child: _appleMenuItemButton(
        context,
        child.child,
        checkColumn: checkColumn,
      ),
    );
  }
  if (child is MenuItemButton) {
    // 宽屏 macOS 菜单不画行内图标（对勾列除外），窄屏 iOS 保留。
    final Widget? original = child.leadingIcon;
    final Widget? icon = compact && original is! FushiAppleMenuCheck
        ? null
        : original;
    final bool droppedIcon = icon == null && original != null;
    // MD3 写法「行尾一个勾 = 选中」改成行首对勾列。
    final bool trailingCheck =
        icon == null && _isMenuCheckGlyph(child.trailingIcon);
    final Widget? leading;
    final Widget? trailing;
    if (trailingCheck) {
      leading = checkSlot(true);
      trailing = null;
    } else if (icon == null) {
      if (!checkColumn && !droppedIcon) return child;
      // 同组有勾选项：未勾的行也让出对勾列，文字左缘对齐。
      leading = checkColumn ? checkSlot(false) : null;
      trailing = child.trailingIcon;
    } else if (icon is FushiAppleMenuCheck || !checkColumn) {
      return child;
    } else {
      // 同组有勾选项：[✓ 空位][图标][文字]。
      leading = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          checkSlot(false),
          SizedBox(width: _menuIconGap(context)),
          icon,
        ],
      );
      trailing = child.trailingIcon;
    }
    return MenuItemButton(
      key: child.key,
      onPressed: child.onPressed,
      onHover: child.onHover,
      requestFocusOnHover: child.requestFocusOnHover,
      onFocusChange: child.onFocusChange,
      focusNode: child.focusNode,
      autofocus: child.autofocus,
      shortcut: child.shortcut,
      semanticsLabel: child.semanticsLabel,
      style: child.style,
      statesController: child.statesController,
      clipBehavior: child.clipBehavior,
      leadingIcon: leading,
      trailingIcon: trailing,
      closeOnActivate: child.closeOnActivate,
      overflowAxis: child.overflowAxis,
      child: child.child,
    );
  }
  if (child is CheckboxMenuButton) {
    final ValueChanged<bool?>? onChanged = child.onChanged;
    final bool? value = child.value;
    return Semantics(
      checked: value ?? false,
      mixed: child.tristate && value == null,
      child: MenuItemButton(
        key: child.key,
        onPressed: onChanged == null
            ? null
            : () => onChanged(switch (value) {
                false => true,
                true => child.tristate ? null : false,
                null => false,
              }),
        onHover: child.onHover,
        onFocusChange: child.onFocusChange,
        focusNode: child.focusNode,
        shortcut: child.shortcut,
        style: child.style,
        statesController: child.statesController,
        clipBehavior: child.clipBehavior,
        leadingIcon: checkSlot(value ?? false),
        trailingIcon: child.trailingIcon,
        closeOnActivate: child.closeOnActivate,
        child: child.child,
      ),
    );
  }
  if (child is RadioMenuButton) {
    return _appleRadioMenuItem(child, checkSlot);
  }
  if (child is SubmenuButton) {
    return SubmenuButton(
      key: child.key,
      onHover: child.onHover,
      onFocusChange: child.onFocusChange,
      onOpen: child.onOpen,
      onClose: child.onClose,
      controller: child.controller,
      style: child.style,
      menuStyle: _kGlassMenuAnchorStyle,
      alignmentOffset: child.alignmentOffset,
      clipBehavior: child.clipBehavior,
      focusNode: child.focusNode,
      statesController: child.statesController,
      // 宽屏 macOS 菜单不画行内图标；窄屏 iOS 图标在文字前。
      leadingIcon: compact ? null : child.leadingIcon,
      trailingIcon: child.trailingIcon,
      submenuIcon: WidgetStatePropertyAll<Widget?>(
        FushiIcon(
          CupertinoIcons.chevron_forward,
          size: compact ? 11 * macScale : 17,
          color: compact ? apple.secondaryLabel : apple.label,
        ),
      ),
      useRootOverlay: child.useRootOverlay,
      hoverOpenDelay: child.hoverOpenDelay,
      animated: child.animated,
      onAnimationStatusChanged: child.onAnimationStatusChanged,
      menuChildren: <Widget>[
        _FushiGlassMenuPanel(children: child.menuChildren),
      ],
      child: child.child,
    );
  }
  return child;
}

/// 是否为「勾」图标（MD3 菜单项用行尾勾表示选中）。
bool _isMenuCheckGlyph(Widget? w) {
  final IconData? data = w is FushiIcon ? w.icon : (w is Icon ? w.icon : null);
  return data != null &&
      (data == FushiIcons.check ||
          data == CupertinoIcons.checkmark ||
          data == Icons.check);
}

/// 该菜单项是否可勾选（同组有一项可勾选，整组都让出行首对勾列）。
bool _isCheckableMenuItem(Widget child) {
  if (child is Actions) return _isCheckableMenuItem(child.child);
  if (child is CheckboxMenuButton || child is RadioMenuButton) return true;
  if (child is MenuItemButton) {
    return child.leadingIcon is FushiAppleMenuCheck ||
        (child.leadingIcon == null && _isMenuCheckGlyph(child.trailingIcon));
  }
  return false;
}

/// [RadioMenuButton] 的 Apple 行。
///
/// 调用点只能把它当 `RadioMenuButton<dynamic>` 拿到（`is RadioMenuButton` 不带
/// 泛型），按静态类型读 `onChanged` 会触发协变检查：实例上是
/// `(GalLookupSurfaceMode?) => void`，不是 `(dynamic) => void` 的子类型，一读就抛
/// TypeError（Apple 菜单里放带类型的单选项即崩）。所以回调按 [Function] 取出、
/// 用实例自己的 value 调回去，类型由实例保证。
Widget _appleRadioMenuItem(
  RadioMenuButton<Object?> child,
  Widget Function(bool checked) checkSlot,
) {
  final Function? onChanged = (child as dynamic).onChanged as Function?;
  final bool checked = child.value == child.groupValue;
  return Semantics(
    checked: checked,
    inMutuallyExclusiveGroup: true,
    child: MenuItemButton(
      key: child.key,
      onPressed: onChanged == null
          ? null
          : () => Function.apply(onChanged, <Object?>[
              checked && child.toggleable ? null : child.value,
            ]),
      onHover: child.onHover,
      onFocusChange: child.onFocusChange,
      focusNode: child.focusNode,
      shortcut: child.shortcut,
      style: child.style,
      statesController: child.statesController,
      clipBehavior: child.clipBehavior,
      leadingIcon: checkSlot(checked),
      trailingIcon: child.trailingIcon,
      closeOnActivate: child.closeOnActivate,
      child: child.child,
    ),
  );
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
    final MenuAnchorChildBuilder? anchorBuilder = builder;
    // BUG-3359：菜单面板的滚动通知截在锚点这一层，不冒泡进页面（见
    // [MenuOverlayScrollBoundary]）；锚点自身（child / builder 的产物）照常冒泡。
    final Widget menu = MenuAnchor(
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
      builder: anchorBuilder == null
          ? null
          : (BuildContext context, MenuController controller, Widget? child) =>
                MenuOverlayScrollBoundary.anchor(
                  child: anchorBuilder(context, controller, child),
                ),
      child: anchorBuilder == null && child != null
          ? MenuOverlayScrollBoundary.anchor(child: child!)
          : child,
    );
    return MenuOverlayScrollBoundary(child: menu);
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

/// 玻璃下拉的「字段」按钮：公共 pop-up 按钮外观 [FushiApplePopUpButtonFace]
/// （iOS 27 tertiaryFill 灰填充胶囊 / macOS 27 secondaryFill 圆角 6 的 pop-up
/// button，当前值 + 行尾 `chevron.up.chevron.down`），实色内容层控件、不是
/// 玻璃。[expanded]（表单里撑满的下拉，含 DropdownButtonFormField）撑满父级，
/// iOS 非 dense 时高 44 与并排输入框对齐；否则内容自适应宽。底由
/// [FushiPlainButton] 画（悬停 / 按下叠前景色、键盘焦点环），Enter / 手柄 A /
/// 点击都打开统一的 Apple 菜单面板。调用方的 MD3 内边距 / 图标尺寸不沿用。
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
  TextStyle? style,
  AlignmentGeometry alignment = AlignmentDirectional.centerStart,
}) {
  final bool desktop = FushiApplePopUpButtonFace.desktopOf(context);
  final bool enabled = onTap != null;
  final double height = expanded && !desktop && !dense
      ? 44
      : FushiApplePopUpButtonFace.defaultHeightOf(context);
  final double chevronSize = desktop ? 10 * fushiAppleMacScale(context) : 12;
  Widget? chevron = icon == null ? null : _pullDownChevron(icon, chevronSize);
  if (chevron != null && iconColor != null) {
    chevron = IconTheme.merge(
      data: IconThemeData(color: iconColor),
      child: chevron,
    );
  }
  return FushiPlainButton(
    onPressed: onTap,
    focusNode: focusNode,
    autofocus: autofocus,
    borderRadius: FushiApplePopUpButtonFace.radiusOf(context, height),
    fill: FushiApplePopUpButtonFace.fillOf(context),
    semanticLabel: semanticLabel.isEmpty ? null : semanticLabel,
    child: FushiApplePopUpButtonFace(
      labelWidget: value,
      leading: leading,
      chevron: chevron,
      style: style,
      contentAlignment: alignment,
      expand: expanded,
      height: height,
      enabled: enabled,
      paintFill: false,
    ),
  );
}

double _anchorWidth(BuildContext anchor) {
  final RenderObject? box = anchor.findRenderObject();
  return box is RenderBox && box.hasSize ? box.size.width : 0;
}

/// [DropdownButton] 的设计系统分派版。
///
/// @design dual —— MD3 原样 [DropdownButton]；Apple 下按钮本体是公共 pop-up
/// 外观 [FushiApplePopUpButtonFace]（iOS 27 灰填充胶囊 / macOS 27 pop-up
/// button），点开走统一的 Apple 菜单面板（[DropdownMenuItem] 映射成同值的
/// [PopupMenuItem]）。
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
        style: widget.style,
        alignment: widget.alignment,
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

/// [DropdownMenu] 的设计系统分派版。
///
/// @design dual —— Apple 下按钮本体是 [FushiApplePopUpButtonFace]（标签 +
/// 当前项），点开走统一的 Apple 菜单面板；不提供输入过滤 / 搜索（仓库调用点都是纯选择）。选中后同步写回
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

  /// MD3 下带标题的下拉字段：与 [FushiTextFieldControl] 同一条
  /// [fushiMd3FieldDecoration]（填充式边框，标题浮在填充块内）。
  ///
  /// 不经它时 DropdownMenu 落到全局输入框主题的「无描边 OutlineInputBorder」：
  /// 浮起的标题按描边式骑在边框线上，而填充框根本没有可见描边，标题一半露在
  /// 填充块上沿外（反馈 jIlpJV-xW4「文字显示不全」的同类）。尾部箭头留空，由
  /// DropdownMenu 照旧补默认的展开按钮；调用方的 [inputDecorationTheme] 里的
  /// dense / 内边距先并进来，紧凑行内下拉的尺寸不变。
  InputDecoration _md3LabelledDecoration(
    BuildContext context,
    MenuController controller,
  ) {
    final Object? rawTheme = widget.inputDecorationTheme;
    final InputDecorationThemeData? base = rawTheme is InputDecorationTheme
        ? rawTheme.data
        : rawTheme as InputDecorationThemeData?;
    final InputDecoration decoration = InputDecoration(
      label: widget.label,
      hintText: widget.hintText,
      helperText: widget.helperText,
      errorText: widget.errorText,
      prefixIcon: widget.leadingIcon,
      isDense: base?.isDense,
      contentPadding: base?.contentPadding,
    );
    return fushiMd3FieldDecoration(context, decoration) ?? decoration;
  }

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      // BUG-3359：下拉面板是 OverlayPortal 浮层，滚动通知会冒泡进页面（顶栏跟着
      // 收起、下拉被重建后滚回选中项，列表拨不下去）。截在下拉这一层；锚点是本
      // 下拉自己的输入框，它的横向滚动对页面也没有意义，一并截下。
      // 带标题时装饰整份由 [_md3LabelledDecoration] 给（label / hint / helper /
      // error 都在里面）；DropdownMenu 断言 decorationBuilder 与这四个参数互斥。
      // 2026-11 M3E：表单式下拉（没有调用方给的 inputDecorationTheme，即不是
      // 工具条行内档）不带标题也走 M3 填充式装饰；行内档保持原样。
      final DropdownMenuDecorationBuilder? decorationBuilder =
          widget.decorationBuilder ??
          (widget.label == null && widget.inputDecorationTheme != null
              ? null
              : _md3LabelledDecoration);
      final bool ownDecoration =
          widget.decorationBuilder == null && decorationBuilder != null;
      // 活动指示线按焦点 / 悬停 / 错误以 FushiMotion 补间（FushiFieldIndicatorHost）。
      final Widget dropdown = FushiFieldIndicatorHost(
        enabled: widget.enabled,
        error: widget.errorText != null,
        builder: (BuildContext context) => DropdownMenu<T>(
          enabled: widget.enabled,
          width: widget.width,
          menuHeight: widget.menuHeight,
          leadingIcon: widget.leadingIcon,
          trailingIcon: widget.trailingIcon,
          showTrailingIcon: widget.showTrailingIcon,
          trailingIconFocusNode: widget.trailingIconFocusNode,
          label: ownDecoration ? null : widget.label,
          hintText: ownDecoration ? null : widget.hintText,
          helperText: ownDecoration ? null : widget.helperText,
          errorText: ownDecoration ? null : widget.errorText,
          selectedTrailingIcon: widget.selectedTrailingIcon,
          enableFilter: widget.enableFilter,
          enableSearch: widget.enableSearch,
          keyboardType: widget.keyboardType,
          textStyle: widget.textStyle,
          textAlign: widget.textAlign,
          inputDecorationTheme: widget.inputDecorationTheme,
          decorationBuilder: decorationBuilder,
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
        ),
      );
      return MenuOverlayScrollBoundary(child: dropdown);
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

  /// 是否由本组件补一个显式关闭按钮。
  ///
  /// 带动作的 SnackBar 默认 [persist]（`persist ?? action != null`）：不会自己
  /// 消失，而 [showCloseIcon] 默认关——用户只剩「横滑」这一条想不到的路，提示就
  /// 一直钉在底部（反馈 9WaqDjw84y）。凡是常驻的提示条都必须有看得见的关闭入口；
  /// 调用方显式要了原生关闭图标（`showCloseIcon: true`）就不重复画。
  bool get _closable => persist && super.showCloseIcon != true;

  @override
  Widget get content => _FushiSnackBarContent(
    content: super.content,
    action: super.action,
    closable: _closable,
  );

  @override
  SnackBarAction? get action {
    final SnackBarAction? raw = super.action;
    return raw == null ? null : _FushiSnackBarAction(raw, closable: _closable);
  }
}

/// 常驻提示条的关闭按钮（MD3 画在动作槽里动作之后，玻璃画在胶囊内动作之后）。
class _FushiSnackBarCloseButton extends StatelessWidget {
  const _FushiSnackBarCloseButton({required this.glass});

  final bool glass;

  @override
  Widget build(BuildContext context) {
    return FushiIconButtonControl(
      key: const ValueKey<String>('fushi-snackbar-close'),
      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
      onPressed: () => ScaffoldMessenger.of(
        context,
      ).hideCurrentSnackBar(reason: SnackBarClosedReason.dismiss),
      // 显式取提示条底色上的前景色：MD3 提示条底是 inverseSurface，按钮默认
      // 的 onSurfaceVariant 与它同深浅，深色 / 自定义主题下 × 几乎看不见
      // （反馈 eiFcN3DZQ3）。与原生 showCloseIcon 同口径。
      icon: FushiIcon(
        glass ? CupertinoIcons.xmark : FushiIcons.close,
        size: glass ? 17 : 20,
        color: glass
            ? appleColorsOf(context).secondaryLabel
            : SnackBarTheme.of(context).closeIconColor ??
                  Theme.of(context).colorScheme.onInverseSurface,
      ),
    );
  }
}

class _FushiSnackBarContent extends StatelessWidget {
  const _FushiSnackBarContent({
    required this.content,
    required this.action,
    required this.closable,
  });

  final Widget content;
  final SnackBarAction? action;
  final bool closable;

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
              end: action != null || closable ? 8 : 20,
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
                if (closable) const _FushiSnackBarCloseButton(glass: true),
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
  _FushiSnackBarAction(this.raw, {required this.closable})
    : super(
        textColor: raw.textColor,
        disabledTextColor: raw.disabledTextColor,
        backgroundColor: raw.backgroundColor,
        disabledBackgroundColor: raw.disabledBackgroundColor,
        label: raw.label,
        onPressed: raw.onPressed,
      );

  final SnackBarAction raw;
  final bool closable;

  @override
  State<SnackBarAction> createState() => _FushiSnackBarActionState();
}

class _FushiSnackBarActionState extends State<SnackBarAction> {
  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return const SizedBox.shrink();
    final _FushiSnackBarAction action = widget as _FushiSnackBarAction;
    if (!action.closable) return action.raw;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        action.raw,
        const _FushiSnackBarCloseButton(glass: false),
      ],
    );
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
/// 下是 [FormField] + [FushiDropdownButton]（[FushiApplePopUpButtonFace] 按钮
/// + 统一 Apple 菜单面板；@design dual），
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
      return FushiFieldIndicatorHost(
        enabled: onChanged != null,
        error:
            forceErrorText != null ||
            decoration?.errorText != null ||
            decoration?.error != null,
        builder: (BuildContext context) => DropdownButtonFormField<T>(
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
          dropdownColor:
              dropdownColor ?? Theme.of(context).popupMenuTheme.color,
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
        ),
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
