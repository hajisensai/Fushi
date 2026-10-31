import 'dart:async';
import 'dart:math' as math;

import 'dart:ui' show SemanticsRole;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveIndicator;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiLinearProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart'
    show FushiTextFieldControl;
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// ===========================================================================
// M3 Expressive 浮层（对话框 / 底部弹层 / 菜单）的共享原语与标准模板
// （用户 2026-10-05「对话框和底部弹窗也统一成 m3e」）。
//
// - 动效：对话框 = 弹簧缩放 + 淡入（[FushiDialogRoute]，由 showAppDialog 统一
//   推）；底部弹层 / 菜单 = 近临界阻尼弹簧（无可见过冲，避免弹层底边露缝）。
//   墨水屏与系统「减弱动态效果」下全部瞬间到位。
// - 形状：M3E 形状库里的「饼干 / 花瓣 / 太阳」装饰形（[FushiExpressiveShape]），
//   对话框图标 hero 用它做底（[FushiDialogHeroIcon]）。
// - 模板：确认 / 文本输入 / 单选 / 多选 / 进度五种标准对话框，全部经
//   showAppDialog + FushiAlertDialog / FushiSimpleDialog：Material 设计系统出
//   M3E，Apple 设计系统自动出 iOS alert / macOS sheet（同一 API）。
// ===========================================================================

// M3 Expressive 浮层动效（用户 2026-10-05「对话框和底部弹窗也统一成 m3e」）：
// 进场走弹簧（[FushiSpringCurve]），退场走 emphasizedAccelerate 快速收回。
// - 对话框：expressive default spatial（stiffness 380、阻尼 0.72，约 4% 回弹），
//   由 FushiDialogRoute 用作缩放曲线（淡入另走 emphasizedDecelerate 前 40%）；
// - 底部弹层：近临界阻尼（0.92，过冲 < 0.2%，弹层底边不离开屏幕底）；
// - 菜单：fast spatial（stiffness 800、阻尼 0.9），下拉展开不越界。

/// 对话框进场时长（弹簧在此时长内基本静止）。
const Duration fushiDialogEnterDuration = Duration(milliseconds: 450);

const AnimationStyle fushiM3eDialogAnimationStyle = AnimationStyle(
  curve: FushiSpringCurve(
    stiffness: 380,
    dampingRatio: 0.72,
    duration: fushiDialogEnterDuration,
  ),
  duration: fushiDialogEnterDuration,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Duration(milliseconds: 180),
);

const AnimationStyle fushiM3eSheetAnimationStyle = AnimationStyle(
  curve: FushiSpringCurve(
    stiffness: 380,
    dampingRatio: 0.92,
    duration: Duration(milliseconds: 420),
  ),
  duration: Duration(milliseconds: 420),
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.medium1,
);

const AnimationStyle fushiM3eMenuAnimationStyle = AnimationStyle(
  curve: FushiSpringCurve(
    stiffness: 800,
    dampingRatio: 0.9,
    duration: Duration(milliseconds: 300),
  ),
  duration: Duration(milliseconds: 300),
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.short2,
);

/// Apple 设计系统的对话框进出场：只淡入淡出、不缩放（iOS 26 / macOS 26 的
/// alert 不弹簧放大），曲线是临界阻尼弹簧（Apple effects default：刚度
/// 986.96、阻尼比 1，约 0.21 秒落定，绝不过冲）。[FushiDialogRoute] 在 Apple
/// 下自动换用它。
const AnimationStyle fushiAppleDialogAnimationStyle = AnimationStyle(
  curve: FushiSpringCurve(
    stiffness: 986.96,
    dampingRatio: 1,
    duration: Duration(milliseconds: 220),
  ),
  duration: Duration(milliseconds: 220),
  reverseCurve: FushiSpringCurve(
    stiffness: 986.96,
    dampingRatio: 1,
    duration: Duration(milliseconds: 220),
  ),
  reverseDuration: Duration(milliseconds: 180),
);

/// Apple 设计系统的底部弹层进场：临界阻尼弹簧（SwiftUI 感知时长 0.4 秒、
/// bounce 0 → 刚度 (2π/0.4)² ≈ 246.74），没有 M3E 的近临界回弹。
const AnimationStyle fushiAppleSheetAnimationStyle = AnimationStyle(
  curve: FushiSpringCurve(
    stiffness: 246.74,
    dampingRatio: 1,
    duration: Duration(milliseconds: 420),
  ),
  duration: Duration(milliseconds: 420),
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.medium1,
);

/// 当前设计系统的底部弹层动效：Apple → [fushiAppleSheetAnimationStyle]，
/// 其余 → [fushiM3eSheetAnimationStyle]。系统「减弱动态效果」由调用方处理。
AnimationStyle fushiSheetAnimationStyleOf(BuildContext context) {
  return isGlassDesign(context)
      ? fushiAppleSheetAnimationStyle
      : fushiM3eSheetAnimationStyle;
}

/// 把一个弹簧（[stiffness]、阻尼比 [dampingRatio]、质量 1）按 [duration] 归一化
/// 成 [Curve]：t=1 时弹簧应已基本静止（时长取到弹簧 settle 之后）。欠阻尼时
/// 中途会越过 1（回弹），调用方自己决定能否承受过冲。进场曲线用它代替定时
/// 缓动，是 M3E「spring 物理动效」在 [AnimationStyle] 体系里的落点。
class FushiSpringCurve extends Curve {
  const FushiSpringCurve({
    required this.stiffness,
    required this.dampingRatio,
    required this.duration,
  }) : assert(dampingRatio > 0);

  final double stiffness;
  final double dampingRatio;
  final Duration duration;

  @override
  double transform(double t) {
    // 弹簧在 t=1 时只是「基本」静止（残差 < 1%）；端点钉死，免得路由完成后
    // 停在 0.997 这类值上。
    if (t == 0.0 || t == 1.0) return t;
    return transformInternal(t);
  }

  @override
  double transformInternal(double t) {
    final double omega = math.sqrt(stiffness);
    final double tau =
        t * duration.inMicroseconds / Duration.microsecondsPerSecond;
    final double zeta = dampingRatio;
    if (zeta >= 1) {
      return 1 - (1 + omega * tau) * math.exp(-omega * tau);
    }
    final double omegaD = omega * math.sqrt(1 - zeta * zeta);
    final double envelope = math.exp(-zeta * omega * tau);
    return 1 -
        envelope *
            (math.cos(omegaD * tau) +
                zeta * omega / omegaD * math.sin(omegaD * tau));
  }
}

/// M3E 浮层动效的时长与弹簧参数（唯一真相源）。
abstract final class FushiOverlayMotion {
  /// 对话框进场缩放起点。
  static const double dialogScaleFrom = 0.86;

  /// 对话框退场缩放终点（略缩、快速淡出）。
  static const double dialogScaleTo = 0.94;

  /// hero 图标进场的弹簧（与对话框同一条）。
  static Curve get heroSpring => fushiM3eDialogAnimationStyle.curve!;
  static Duration get heroDuration => fushiM3eDialogAnimationStyle.duration!;
}

/// M3 规范的模态遮罩：scrim @32%。墨水屏交回框架默认（black54，面板边界靠
/// 遮罩明暗区分）。
Color fushiModalScrimColor(BuildContext context) {
  if (isEinkTheme(context)) return Colors.black54;
  return Theme.of(context).colorScheme.scrim.withValues(alpha: 0.32);
}

/// M3E 对话框路由：[DialogRoute] 的全部语义（安全区、主题捕获、遮罩、Esc
/// 关闭、焦点闭环、命名路由语义）原样保留，只把进出场换成「弹簧缩放 + 淡入」：
/// 进场按 [animationStyle] 的弹簧曲线从 [FushiOverlayMotion.dialogScaleFrom]
/// 弹到 1（带轻微回弹），淡入只占前 40%；退场缩到
/// [FushiOverlayMotion.dialogScaleTo] 并快速淡出。[reduceMotion]（墨水屏 /
/// 减弱动态效果）时无动画。Apple 设计系统（按 [context] 判定）下不缩放、不
/// 回弹：改用 [fushiAppleDialogAnimationStyle] 整体淡入淡出。
class FushiDialogRoute<T> extends DialogRoute<T> {
  FushiDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.requestFocus,
    super.anchorPoint,
    super.traversalEdgeBehavior,
    super.fullscreenDialog,
    AnimationStyle animationStyle = fushiM3eDialogAnimationStyle,
    this.reduceMotion = false,
  }) : _apple = isGlassDesign(context),
       _style = _resolveStyle(context, reduceMotion, animationStyle),
       super(
         animationStyle: _resolveStyle(context, reduceMotion, animationStyle),
       );

  final bool reduceMotion;

  /// 推路由时的设计系统：Apple 只淡入淡出（不缩放）。
  final bool _apple;
  final AnimationStyle _style;

  static AnimationStyle _resolveStyle(
    BuildContext context,
    bool reduceMotion,
    AnimationStyle animationStyle,
  ) {
    if (reduceMotion) return AnimationStyle.noAnimation;
    return isGlassDesign(context)
        ? fushiAppleDialogAnimationStyle
        : animationStyle;
  }

  @override
  Duration get reverseTransitionDuration =>
      _style.reverseDuration ?? transitionDuration;

  CurvedAnimation? _scale;
  CurvedAnimation? _fade;
  Animation<double>? _parent;

  void _ensure(Animation<double> animation) {
    if (_parent == animation) return;
    _scale?.dispose();
    _fade?.dispose();
    _parent = animation;
    _scale = CurvedAnimation(
      parent: animation,
      curve: _style.curve ?? Easing.emphasizedDecelerate,
      reverseCurve: _style.reverseCurve ?? Easing.emphasizedAccelerate,
    );
    _fade = CurvedAnimation(
      parent: animation,
      curve: _apple
          ? (_style.curve ?? Easing.emphasizedDecelerate)
          : const Interval(0, 0.4, curve: Easing.emphasizedDecelerate),
      reverseCurve: _style.reverseCurve ?? Easing.emphasizedAccelerate,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion) return child;
    _ensure(animation);
    final CurvedAnimation scale = _scale!;
    final CurvedAnimation fade = _fade!;
    if (_apple) {
      // Apple：只淡入淡出，没有缩放弹出。
      return AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (BuildContext context, Widget? child) =>
            Opacity(opacity: fade.value.clamp(0.0, 1.0), child: child),
      );
    }
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (BuildContext context, Widget? child) {
        final bool reversing = animation.status == AnimationStatus.reverse;
        final double from = reversing
            ? FushiOverlayMotion.dialogScaleTo
            : FushiOverlayMotion.dialogScaleFrom;
        final double s = from + (1 - from) * scale.value;
        return Opacity(
          opacity: fade.value.clamp(0.0, 1.0),
          child: Transform.scale(scale: s, child: child),
        );
      },
    );
  }

  @override
  void dispose() {
    _scale?.dispose();
    _fade?.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 底部弹层（Material / M3E）
// ---------------------------------------------------------------------------

/// 宽于此（逻辑像素）时 adaptiveModalSheet 不再从底部抽出，而是居中浮动面板。
const double kFushiSheetWideBreakpoint = 600;

/// 窗口高度低于此（横屏手机）时，宽屏浮动面板把竖向留白收紧，给内容多留高度。
const double kFushiSheetShortWindowHeight = 500;

/// 窄屏两档高度：半屏档占屏高比例。
const double kFushiSheetHalfFraction = 0.55;

/// 窄屏两档高度：展开档 / 一般封顶占屏高比例（留出状态栏）。
const double kFushiSheetFullFraction = 0.92;

/// M3E 底部弹层本体（窄屏）：自绘拖动条、软键盘抬升、高度封顶与可选两档高度。
/// 只在拖动条区域接两档手势；内容区的滚动不受影响。
class FushiM3eSheetBody extends StatefulWidget {
  const FushiM3eSheetBody({
    super.key,
    required this.child,
    this.showDragHandle = true,
    this.expandable = false,
    this.dragToDismiss = true,
  });

  final Widget child;
  final bool showDragHandle;
  final bool expandable;

  /// 拖动条在收起档下拉是否关闭弹层（`adaptiveModalSheet` 的 isDismissible）；
  /// false 时下拉只收回展开档，不关闭。
  final bool dragToDismiss;

  @override
  State<FushiM3eSheetBody> createState() => _FushiM3eSheetBodyState();
}

class _FushiM3eSheetBodyState extends State<FushiM3eSheetBody> {
  bool _expanded = false;
  double _dragDy = 0;

  void _onDragEnd(DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;
    final double dy = _dragDy;
    _dragDy = 0;
    if (dy < -40 || velocity < -600) {
      if (!_expanded) setState(() => _expanded = true);
    } else if (dy > 40 || velocity > 600) {
      if (_expanded) {
        setState(() => _expanded = false);
      } else if (widget.dragToDismiss) {
        Navigator.of(context).maybePop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double screenH = media.size.height;
    final double cap = widget.expandable && !_expanded
        ? screenH * kFushiSheetHalfFraction
        : screenH * kFushiSheetFullFraction;
    Widget handle = Semantics(
      button: widget.expandable,
      label: widget.expandable
          ? MaterialLocalizations.of(context).expansionTileCollapsedHint
          : null,
      child: SizedBox(
        height: kMinInteractiveDimension,
        child: Center(
          child: AnimatedContainer(
            duration: fushiMotionDuration(context, FushiMotion.short),
            width: _expanded ? 48 : 32,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: const BorderRadius.all(Radius.circular(2)),
            ),
          ),
        ),
      ),
    );
    if (widget.expandable) {
      handle = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (DragUpdateDetails d) =>
            _dragDy += d.primaryDelta ?? 0,
        onVerticalDragEnd: _onDragEnd,
        onTap: () => setState(() => _expanded = !_expanded),
        child: handle,
      );
    }
    Widget body = widget.showDragHandle
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              handle,
              Flexible(child: widget.child),
            ],
          )
        : widget.child;
    body = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: cap),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: fushiM3eSheetAnimationStyle.curve!,
      child: body,
      builder: (BuildContext context, double maxHeight, Widget? child) {
        final Widget capped = ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: child,
        );
        // 展开档撑满档高（内容少也不回缩），收起 / 普通档随内容。
        return widget.expandable && _expanded
            ? SizedBox(height: maxHeight, child: capped)
            : capped;
      },
    );
    // 软键盘弹出：整块弹层抬到键盘上方（BottomSheet 自己不让位）。
    return AnimatedPadding(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: body,
      ),
    );
  }
}

/// M3E 宽屏弹层：居中浮动面板（圆角 28、最宽 640、最高 86% 屏高），
/// surfaceContainerLow 底（毛玻璃档换玻璃表面）；内容外包 [FushiDialogScope]。
class FushiM3eFloatingSheet extends StatelessWidget {
  const FushiM3eFloatingSheet({
    super.key,
    required this.child,
    this.frosted = false,
  });

  final Widget child;
  final bool frosted;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MediaQueryData media = MediaQuery.of(context);
    final bool eink = isEinkTheme(context);
    const BorderRadius radius = BorderRadius.all(Radius.circular(28));
    // 横屏手机弹出软键盘后整窗只剩 ~180dp：上下各 24 的留白再吃掉 48，面板就几乎
    // 没有可用高度。矮窗口把竖向留白收到 8。
    final double verticalMargin =
        media.size.height < kFushiSheetShortWindowHeight ? 8 : 24;
    final Widget content = Material(
      type: MaterialType.transparency,
      child: FushiDialogScope(child: child),
    );
    final Widget surface = frosted
        ? FushiGlassSurface(
            borderRadius: radius,
            baseColor: FushiDesignTokens.of(context).surfaces.group,
            child: content,
          )
        : Material(
            color: cs.surfaceContainerLow,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
            ),
            clipBehavior: Clip.antiAlias,
            child: content,
          );
    return Semantics(
      role: SemanticsRole.dialog,
      child: AnimatedPadding(
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        padding:
            media.viewInsets +
            EdgeInsets.symmetric(horizontal: 24, vertical: verticalMargin),
        child: MediaQuery.removeViewInsets(
          context: context,
          removeLeft: true,
          removeTop: true,
          removeRight: true,
          removeBottom: true,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: math.min(480, media.size.width - 48),
                maxWidth: 640,
                maxHeight: media.size.height * 0.86,
              ),
              child: surface,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// M3E 形状库（装饰形）
// ---------------------------------------------------------------------------

/// M3E 形状库里用作装饰底的几种形状（官方 [MaterialShapes] 的子集，见
/// [FushiExpressiveShape.polygon]）。
enum FushiExpressiveShape {
  /// 圆。
  circle,

  /// 4 瓣饼干（四叶草式圆角方）。
  cookie4,

  /// 6 瓣饼干。
  cookie6,

  /// 9 瓣饼干（M3E 加载指示器 / 图标底最常见的那一枚）。
  cookie9,

  /// 8 瓣花。
  flower,

  /// 太阳（12 个浅尖角）。
  sunny,
}

/// [FushiExpressiveShape] 对应的官方 M3E 形状。
extension FushiExpressiveShapePolygon on FushiExpressiveShape {
  RoundedPolygon get polygon => switch (this) {
    FushiExpressiveShape.circle => MaterialShapes.circle,
    FushiExpressiveShape.cookie4 => MaterialShapes.cookie4Sided,
    FushiExpressiveShape.cookie6 => MaterialShapes.cookie6Sided,
    FushiExpressiveShape.cookie9 => MaterialShapes.cookie9Sided,
    FushiExpressiveShape.flower => MaterialShapes.flower,
    FushiExpressiveShape.sunny => MaterialShapes.sunny,
  };
}

/// 把 [FushiExpressiveShape] 画成 [OutlinedBorder]，可直接给 [ShapeDecoration]
/// / [Material.shape] / 裁剪用。[rotation] 为弧度。
class FushiExpressiveShapeBorder extends OutlinedBorder {
  const FushiExpressiveShapeBorder(this.shape, {super.side, this.rotation = 0});

  final FushiExpressiveShape shape;
  final double rotation;

  Path _path(Rect rect) {
    if (shape == FushiExpressiveShape.circle) {
      return Path()..addOval(rect);
    }
    final Path path = MaterialShapeBorder(
      shape: shape.polygon,
      squash: 1,
    ).getOuterPath(rect);
    if (rotation == 0) return path;
    final Offset c = rect.center;
    final Matrix4 spin = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..rotateZ(rotation)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    return path.transform(spin.storage);
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    canvas.drawPath(_path(rect.deflate(side.width / 2)), side.toPaint());
  }

  @override
  ShapeBorder scale(double t) => FushiExpressiveShapeBorder(
    shape,
    side: side.scale(t),
    rotation: rotation,
  );

  @override
  FushiExpressiveShapeBorder copyWith({
    BorderSide? side,
    FushiExpressiveShape? shape,
    double? rotation,
  }) => FushiExpressiveShapeBorder(
    shape ?? this.shape,
    side: side ?? this.side,
    rotation: rotation ?? this.rotation,
  );

  @override
  bool operator ==(Object other) =>
      other is FushiExpressiveShapeBorder &&
      other.shape == shape &&
      other.side == side &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(shape, side, rotation);
}

/// 对话框图标 hero 的色调。
enum FushiHeroTone {
  /// secondaryContainer 底（默认）。
  neutral,

  /// primaryContainer 底（强调 / 成功）。
  primary,

  /// tertiaryContainer 底（提示 / 新功能）。
  tertiary,

  /// errorContainer 底（破坏性操作 / 错误）。
  destructive,
}

/// M3E 对话框图标 hero：[size] 见方的形状库装饰底（默认 9 瓣饼干）+ 居中图标，
/// 进场时弹簧放大并轻转（减弱动态效果下静止）。Apple 设计系统下退化成单色
/// 图标（iOS / macOS 的 alert 不画装饰底）。
class FushiDialogHeroIcon extends StatelessWidget {
  const FushiDialogHeroIcon({
    super.key,
    this.icon,
    this.child,
    this.tone = FushiHeroTone.neutral,
    this.shape = FushiExpressiveShape.cookie9,
    this.size = 64,
    this.color,
  }) : assert(icon != null || child != null);

  final IconData? icon;

  /// 调用方自带的图标 widget（[icon] 为空时用）；颜色 / 尺寸经 [IconTheme] 给。
  final Widget? child;
  final FushiHeroTone tone;
  final FushiExpressiveShape shape;
  final double size;

  /// 调用方显式给的前景色（如 `iconColor: cs.error`）：底色取它的 16% 淡染，
  /// 优先于 [tone]。
  final Color? color;

  (Color, Color) _colors(ColorScheme cs) {
    if (color != null) {
      return (
        Color.alphaBlend(color!.withValues(alpha: 0.16), cs.surface),
        color!,
      );
    }
    return switch (tone) {
      FushiHeroTone.neutral => (cs.secondaryContainer, cs.onSecondaryContainer),
      FushiHeroTone.primary => (cs.primaryContainer, cs.onPrimaryContainer),
      FushiHeroTone.tertiary => (cs.tertiaryContainer, cs.onTertiaryContainer),
      FushiHeroTone.destructive => (cs.errorContainer, cs.onErrorContainer),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget glyph = icon != null ? FushiIcon(icon) : child!;
    if (isGlassDesign(context)) {
      return IconTheme.merge(
        data: IconThemeData(
          size: 28,
          color:
              color ??
              (tone == FushiHeroTone.destructive
                  ? appleColorsOf(context).destructive
                  : cs.primary),
        ),
        child: glyph,
      );
    }
    final (Color bg, Color fg) = _colors(cs);
    final bool eink = isEinkTheme(context);
    // 对话框的图标槽给的是横向撑满的紧约束：不居中的话饼干形会被拉成一条横带。
    final Widget body = Center(
      widthFactor: 1,
      heightFactor: 1,
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: eink ? cs.surface : bg,
            shape: FushiExpressiveShapeBorder(
              shape,
              side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
            ),
          ),
          child: Center(
            child: IconTheme.merge(
              data: IconThemeData(
                size: size * 0.44,
                color: eink ? cs.onSurface : fg,
              ),
              child: glyph,
            ),
          ),
        ),
      ),
    );
    // BUG-3211：[AlertDialog] 把 icon 槽放进 `CrossAxisAlignment.stretch` 的 Column，
    // 给的是**紧**宽约束——裸 `SizedBox.square` 会被撑成「满宽 × size 高」，饼干被
    // 拉成横贯对话框的黄色波浪条、图标缩在正中（用户报「顶部奇怪的 99」）。外包
    // Center 把紧约束放松，底板才真是 [size] 见方。
    if (!fushiMotionEnabled(context)) return Center(child: body);
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: FushiOverlayMotion.heroDuration,
        curve: FushiOverlayMotion.heroSpring,
        child: body,
        builder: (BuildContext context, double v, Widget? child) =>
            Transform.rotate(
              angle: (1 - v) * -0.35,
              child: Transform.scale(scale: 0.5 + 0.5 * v, child: child),
            ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 标准模板
// ---------------------------------------------------------------------------

/// 动作按钮的语义：决定 M3E 下的按钮变体（主操作 filled、次要 text、破坏性
/// error filled）与 Apple 下的胶囊样式。
enum FushiDialogActionKind { primary, secondary, destructive }

/// 一枚标准对话框动作按钮。所有模板都经它出按钮，调用方手搓对话框时也可以
/// 直接用（等价于设计系统分派的 adaptiveDialogAction）。
///
/// [countdown] 非空时按钮带强制倒计时：倒计时内置灰、标签显示「标签 (剩余秒数)」，
/// 归零后才可点。倒计时是本组件自身的能力而不是另一种按钮类型——Apple 设计系统的
/// [FushiAlertDialog] 只按「是不是标准动作键」决定 alert 胶囊排布，倒计时键必须
/// 与其它动作键同型，才不会被当成自定义控件退回横排。
class FushiDialogAction extends StatelessWidget {
  const FushiDialogAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = FushiDialogActionKind.secondary,
    this.autofocus = false,
    this.countdown,
  });

  final String label;
  final VoidCallback? onPressed;
  final FushiDialogActionKind kind;
  final bool autofocus;

  /// 强制等待时长；null 或不大于零 = 普通按钮。
  final Duration? countdown;

  @override
  Widget build(BuildContext context) {
    final Duration? delay = countdown;
    if (delay != null && delay > Duration.zero) {
      return _FushiDialogActionCountdown(
        delay: delay,
        builder: (BuildContext context, int remaining) => _buildButton(
          context,
          label: remaining > 0 ? '$label ($remaining)' : label,
          onPressed: remaining > 0 ? null : onPressed,
        ),
      );
    }
    return _buildButton(context, label: label, onPressed: onPressed);
  }

  Widget _buildButton(
    BuildContext context, {
    required String label,
    required VoidCallback? onPressed,
  }) {
    final Widget text = Text(label);
    switch (kind) {
      case FushiDialogActionKind.primary:
        return FushiFilledButton(
          onPressed: onPressed,
          autofocus: autofocus,
          child: text,
        );
      case FushiDialogActionKind.destructive:
        if (isGlassDesign(context)) {
          return FushiFilledButton.tonal(
            onPressed: onPressed,
            autofocus: autofocus,
            style: FilledButton.styleFrom(
              foregroundColor: appleColorsOf(context).destructive,
            ),
            child: text,
          );
        }
        final ColorScheme cs = Theme.of(context).colorScheme;
        return FushiFilledButton(
          onPressed: onPressed,
          autofocus: autofocus,
          style: FilledButton.styleFrom(
            backgroundColor: cs.error,
            foregroundColor: cs.onError,
          ),
          child: text,
        );
      case FushiDialogActionKind.secondary:
        return FushiTextButton(
          onPressed: onPressed,
          autofocus: autofocus,
          child: text,
        );
    }
  }
}

/// 标准确认对话框：图标 hero（可选）+ 标题 + 说明 + 「取消 / 确认」。返回 true
/// = 确认；取消、点遮罩、Esc / 手柄 B 都返回 false。[destructive] 时确认键是
/// error 色、hero 是 errorContainer 底。Enter 直接确认（确认键 autofocus）。
///
/// [confirmDelay] 非空时确认键先置灰、标签尾挂剩余秒数，倒计时归零才可点——
/// 给「容易手滑、事后难找回」的操作强制留一个停顿；此时焦点落在取消键上，
/// Enter 不会把倒计时绕过去。
Future<bool> showFushiConfirmDialog({
  required BuildContext context,
  required String title,
  String? message,
  Widget? content,
  String? confirmLabel,
  String? cancelLabel,
  IconData? icon,
  bool destructive = false,
  bool barrierDismissible = true,
  Duration? confirmDelay,
}) async {
  final FushiDialogActionKind confirmKind = destructive
      ? FushiDialogActionKind.destructive
      : FushiDialogActionKind.primary;
  final bool delayed = confirmDelay != null && confirmDelay > Duration.zero;
  final bool? result = await showAppDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: icon == null
          ? null
          : FushiDialogHeroIcon(
              icon: icon,
              tone: destructive
                  ? FushiHeroTone.destructive
                  : FushiHeroTone.neutral,
            ),
      title: Text(title),
      content: content ?? (message == null ? null : Text(message)),
      actions: <Widget>[
        FushiDialogAction(
          label: cancelLabel ?? t.dialog_cancel,
          autofocus: delayed,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        if (delayed)
          FushiDialogAction(
            key: const ValueKey<String>('fushi-confirm-countdown-action'),
            label: confirmLabel ?? t.dialog_ok,
            kind: confirmKind,
            countdown: confirmDelay,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          )
        else
          FushiDialogAction(
            label: confirmLabel ?? t.dialog_ok,
            kind: confirmKind,
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
      ],
    ),
  );
  return result ?? false;
}

/// [FushiDialogAction.countdown] 的倒计时状态：按整秒走 [Timer.periodic]，每秒
/// 用剩余秒数重建按钮。不随系统「减弱动态效果」归零——这是交互闸门，不是动效。
class _FushiDialogActionCountdown extends StatefulWidget {
  const _FushiDialogActionCountdown({
    required this.delay,
    required this.builder,
  });

  final Duration delay;
  final Widget Function(BuildContext context, int remaining) builder;

  @override
  State<_FushiDialogActionCountdown> createState() =>
      _FushiDialogActionCountdownState();
}

class _FushiDialogActionCountdownState
    extends State<_FushiDialogActionCountdown> {
  late int _remaining = (widget.delay.inMilliseconds / 1000).ceil();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_remaining > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
        if (!mounted) return;
        setState(() => _remaining--);
        if (_remaining <= 0) timer.cancel();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _remaining);
}

/// 标准文本输入对话框。返回 null = 取消；否则返回（默认 trim 后的）文本。
/// [validator] 返回非空字符串时在输入框下显示错误并禁止确认；[allowEmpty]
/// 为 false 时空文本确认键置灰。Enter 提交（多行输入除外）。
Future<String?> showFushiTextInputDialog({
  required BuildContext context,
  required String title,
  String? message,
  String initialValue = '',
  String? labelText,
  String? hintText,
  String? confirmLabel,
  String? cancelLabel,
  IconData? icon,
  bool allowEmpty = false,
  bool trim = true,
  bool obscureText = false,
  int maxLines = 1,
  TextInputType? keyboardType,
  String? Function(String value)? validator,
}) {
  return showAppDialog<String>(
    context: context,
    builder: (_) => _FushiTextInputDialog(
      title: title,
      message: message,
      initialValue: initialValue,
      labelText: labelText,
      hintText: hintText,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      icon: icon,
      allowEmpty: allowEmpty,
      trim: trim,
      obscureText: obscureText,
      maxLines: maxLines,
      keyboardType: keyboardType,
      validator: validator,
    ),
  );
}

class _FushiTextInputDialog extends StatefulWidget {
  const _FushiTextInputDialog({
    required this.title,
    required this.message,
    required this.initialValue,
    required this.labelText,
    required this.hintText,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.icon,
    required this.allowEmpty,
    required this.trim,
    required this.obscureText,
    required this.maxLines,
    required this.keyboardType,
    required this.validator,
  });

  final String title;
  final String? message;
  final String initialValue;
  final String? labelText;
  final String? hintText;
  final String? confirmLabel;
  final String? cancelLabel;
  final IconData? icon;
  final bool allowEmpty;
  final bool trim;
  final bool obscureText;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? Function(String value)? validator;

  @override
  State<_FushiTextInputDialog> createState() => _FushiTextInputDialogState();
}

class _FushiTextInputDialogState extends State<_FushiTextInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initialValue.length,
        );

  String get _value => widget.trim ? _controller.text.trim() : _controller.text;

  String? get _error => widget.validator?.call(_value);

  bool get _canSubmit =>
      (widget.allowEmpty || _value.isNotEmpty) && _error == null;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop(_value);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String? error = _controller.text.isEmpty ? null : _error;
    final bool multiline = widget.maxLines != 1;
    return FushiAlertDialog(
      icon: widget.icon == null ? null : FushiDialogHeroIcon(icon: widget.icon),
      title: Text(widget.title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.message != null) ...<Widget>[
            Text(widget.message!),
            const SizedBox(height: 16),
          ],
          FushiTextFieldControl(
            controller: _controller,
            autofocus: true,
            obscureText: widget.obscureText,
            maxLines: widget.maxLines,
            keyboardType:
                widget.keyboardType ??
                (multiline ? TextInputType.multiline : TextInputType.text),
            textInputAction: multiline
                ? TextInputAction.newline
                : TextInputAction.done,
            onSubmitted: multiline ? null : (_) => _submit(),
            decoration: InputDecoration(
              labelText: widget.labelText,
              hintText: widget.hintText,
              errorText: error,
              border: const OutlineInputBorder(),
            ),
          ),
          if (error != null && isGlassDesign(context))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                error,
                style: FushiAppleMetrics.of(
                  context,
                ).footnoteStyle(context).copyWith(color: cs.error),
              ),
            ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: widget.cancelLabel ?? t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          label: widget.confirmLabel ?? t.dialog_ok,
          kind: FushiDialogActionKind.primary,
          onPressed: _canSubmit ? _submit : null,
        ),
      ],
    );
  }
}

/// 选择对话框的一项。
@immutable
class FushiChoiceOption<T> {
  const FushiChoiceOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.icon,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  final bool enabled;
}

/// 标准单选对话框：点一项即选中并关闭（Enter / 手柄 A 同）。返回 null = 取消。
/// 当前项（[selected]）是 M3E 选中态：secondaryContainer 胶囊底 + 行首对勾；
/// 打开时焦点落在当前项。
Future<T?> showFushiChoiceDialog<T>({
  required BuildContext context,
  required String title,
  required List<FushiChoiceOption<T>> options,
  T? selected,
  String? message,
  IconData? icon,
}) {
  return showAppDialog<T>(
    context: context,
    builder: (BuildContext dialogContext) => FushiSimpleDialog(
      title: _choiceTitle(dialogContext, title, icon),
      children: <Widget>[
        if (message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(message),
          ),
        for (final FushiChoiceOption<T> option in options)
          FushiChoiceRow(
            label: option.label,
            subtitle: option.subtitle,
            icon: option.icon,
            selected: option.value == selected,
            autofocus: option.value == selected,
            onTap: option.enabled
                ? () => Navigator.of(dialogContext).pop(option.value)
                : null,
          ),
      ],
    ),
  );
}

Widget _choiceTitle(BuildContext context, String title, IconData? icon) {
  if (icon == null || isGlassDesign(context)) return Text(title);
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      FushiDialogHeroIcon(icon: icon, size: 56),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center),
    ],
  );
}

/// 标准多选对话框：勾选若干项后按确认。返回 null = 取消；否则返回选中集合。
/// [minSelected] 未达到时确认键置灰。
Future<Set<T>?> showFushiMultiChoiceDialog<T>({
  required BuildContext context,
  required String title,
  required List<FushiChoiceOption<T>> options,
  Set<T> initial = const <Never>{},
  String? message,
  String? confirmLabel,
  String? cancelLabel,
  int minSelected = 0,
}) {
  return showAppDialog<Set<T>>(
    context: context,
    builder: (_) => _FushiMultiChoiceDialog<T>(
      title: title,
      options: options,
      initial: initial,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      minSelected: minSelected,
    ),
  );
}

class _FushiMultiChoiceDialog<T> extends StatefulWidget {
  const _FushiMultiChoiceDialog({
    required this.title,
    required this.options,
    required this.initial,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.minSelected,
  });

  final String title;
  final List<FushiChoiceOption<T>> options;
  final Set<T> initial;
  final String? message;
  final String? confirmLabel;
  final String? cancelLabel;
  final int minSelected;

  @override
  State<_FushiMultiChoiceDialog<T>> createState() =>
      _FushiMultiChoiceDialogState<T>();
}

class _FushiMultiChoiceDialogState<T>
    extends State<_FushiMultiChoiceDialog<T>> {
  late final Set<T> _selected = <T>{...widget.initial};

  @override
  Widget build(BuildContext context) {
    final bool canSubmit = _selected.length >= widget.minSelected;
    return FushiAlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(widget.message!),
            ),
          for (final FushiChoiceOption<T> option in widget.options)
            FushiChoiceRow(
              label: option.label,
              subtitle: option.subtitle,
              icon: option.icon,
              selected: _selected.contains(option.value),
              multiSelect: true,
              onTap: option.enabled
                  ? () => setState(() {
                      if (!_selected.remove(option.value)) {
                        _selected.add(option.value);
                      }
                    })
                  : null,
            ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: widget.cancelLabel ?? t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          label: widget.confirmLabel ?? t.dialog_ok,
          kind: FushiDialogActionKind.primary,
          onPressed: canSubmit
              ? () => Navigator.of(context).pop(<T>{..._selected})
              : null,
        ),
      ],
    );
  }
}

/// 选择类对话框 / 菜单式列表的一行。M3E：左右内缩 12、圆角 16 的行，选中 =
/// secondaryContainer 胶囊底 + onSecondaryContainer 前景 + 对勾（单选在行首、
/// 多选是勾选框）；悬停 / 焦点 = onSurface 状态层。Apple：菜单式选项行
/// （[FushiSimpleDialogOption]），选中项行尾对勾。Enter / 手柄 A 激活。
class FushiChoiceRow extends StatelessWidget {
  const FushiChoiceRow({
    super.key,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.selected = false,
    this.multiSelect = false,
    this.autofocus = false,
  });

  final String label;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final bool multiSelect;
  final bool autofocus;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    if (isGlassDesign(context)) {
      final FushiAppleColors apple = appleColorsOf(context);
      return Semantics(
        selected: selected,
        child: FushiSimpleDialogOption(
          onPressed: onTap,
          child: Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                FushiIcon(icon, size: 19),
                const SizedBox(width: 12),
              ],
              Expanded(child: _labels(theme, null)),
              if (selected)
                FushiIcon(FushiIcons.check, size: 18, color: apple.accent),
            ],
          ),
        ),
      );
    }
    final bool eink = isEinkTheme(context);
    final Color fg = selected && !eink ? cs.onSecondaryContainer : cs.onSurface;
    final BorderRadius radius = BorderRadius.circular(selected ? 28 : 16);
    final Widget leading = multiSelect
        ? IgnorePointer(
            child: ExcludeFocus(
              child: Checkbox(value: selected, onChanged: (_) {}),
            ),
          )
        : AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            transitionBuilder: (Widget child, Animation<double> a) =>
                ScaleTransition(scale: a, child: child),
            child: selected
                ? FushiIcon(
                    FushiIcons.check,
                    key: const ValueKey<bool>(true),
                    size: 22,
                    color: fg,
                  )
                : (icon != null
                      ? FushiIcon(
                          icon,
                          key: const ValueKey<bool>(false),
                          size: 22,
                          color: cs.onSurfaceVariant,
                        )
                      : const SizedBox(key: ValueKey<bool>(false), width: 22)),
          );
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: !multiSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        child: AnimatedContainer(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          decoration: BoxDecoration(
            color: selected
                ? (eink ? cs.surface : cs.secondaryContainer)
                : Colors.transparent,
            borderRadius: radius,
            border: selected && eink ? Border.all(color: cs.onSurface) : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              autofocus: autofocus,
              onTap: onTap,
              borderRadius: radius,
              hoverColor: cs.onSurface.withValues(alpha: 0.08),
              focusColor: cs.onSurface.withValues(alpha: 0.12),
              highlightColor: cs.onSurface.withValues(alpha: 0.1),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Opacity(
                    opacity: onTap == null ? 0.38 : 1,
                    child: Row(
                      children: <Widget>[
                        leading,
                        const SizedBox(width: 16),
                        Expanded(child: _labels(theme, fg)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _labels(ThemeData theme, Color? fg) {
    final TextTheme tt = theme.textTheme;
    final Widget title = Text(
      label,
      style: (tt.bodyLarge ?? const TextStyle()).copyWith(
        color: fg,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    if (subtitle == null) return title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        title,
        Text(
          subtitle!,
          style: (tt.bodyMedium ?? const TextStyle()).copyWith(
            color:
                fg?.withValues(alpha: 0.78) ??
                theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 进度对话框的句柄：任务结束时调用 [close]（可在对话框还没挂上之前调用，
/// 会在挂上后立刻关闭）。[progress] 写 0..1 显示确定进度，写 null 显示不定态；
/// [message] 更新说明文字。
class FushiProgressDialogHandle {
  FushiProgressDialogHandle._({double? initialProgress, String? message})
    : progress = ValueNotifier<double?>(initialProgress),
      message = ValueNotifier<String?>(message);

  final ValueNotifier<double?> progress;
  final ValueNotifier<String?> message;

  VoidCallback? _dismiss;
  bool _closed = false;
  final Completer<void> _done = Completer<void>();

  /// 对话框关闭（[close] / 取消）后完成。
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    _dismiss?.call();
  }

  void _finish() {
    _closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

/// 标准进度对话框：标题 + 说明 + M3E 波浪进度条（确定态）/ 形状变形加载
/// 指示器（不定态）；Apple 下是系统细进度条 / 菊花。不可点遮罩关闭；给了
/// [onCancel] 时带「取消」键（Esc / 手柄 B 同），否则只能由 [FushiProgressDialogHandle.close] 关。
FushiProgressDialogHandle showFushiProgressDialog({
  required BuildContext context,
  required String title,
  String? message,
  double? initialProgress,
  VoidCallback? onCancel,
  String? cancelLabel,
}) {
  final FushiProgressDialogHandle handle = FushiProgressDialogHandle._(
    initialProgress: initialProgress,
    message: message,
  );
  unawaited(
    showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FushiProgressDialog(
        handle: handle,
        title: title,
        onCancel: onCancel,
        cancelLabel: cancelLabel,
      ),
    ).whenComplete(handle._finish),
  );
  return handle;
}

class _FushiProgressDialog extends StatefulWidget {
  const _FushiProgressDialog({
    required this.handle,
    required this.title,
    required this.onCancel,
    required this.cancelLabel,
  });

  final FushiProgressDialogHandle handle;
  final String title;
  final VoidCallback? onCancel;
  final String? cancelLabel;

  @override
  State<_FushiProgressDialog> createState() => _FushiProgressDialogState();
}

class _FushiProgressDialogState extends State<_FushiProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.handle._dismiss = _pop;
    if (widget.handle.isClosed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pop());
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  void _pop() {
    if (!mounted) return;
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    // 在栈顶时走 pop（带退场动效；pop 不经 PopScope 拦截），被别的路由压住时
    // 直接摘掉。
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  void _cancel() {
    widget.onCancel?.call();
    widget.handle.close();
  }

  @override
  void dispose() {
    widget.handle._dismiss = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool cancellable = widget.onCancel != null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop && cancellable) _cancel();
      },
      child: FushiAlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ValueListenableBuilder<String?>(
              valueListenable: widget.handle.message,
              builder: (BuildContext context, String? text, _) => text == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(text),
                    ),
            ),
            ValueListenableBuilder<double?>(
              valueListenable: widget.handle.progress,
              builder: (BuildContext context, double? value, _) {
                if (value == null) {
                  return Center(child: adaptiveIndicator(context: context));
                }
                return Row(
                  children: <Widget>[
                    Expanded(
                      child: FushiLinearProgressIndicator(
                        value: value.clamp(0.0, 1.0),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${(value.clamp(0.0, 1.0) * 100).round()}%',
                      style: TextStyle(
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        actions: cancellable
            ? <Widget>[
                FushiDialogAction(
                  label: widget.cancelLabel ?? t.dialog_cancel,
                  onPressed: _cancel,
                ),
              ]
            : null,
      ),
    );
  }
}
