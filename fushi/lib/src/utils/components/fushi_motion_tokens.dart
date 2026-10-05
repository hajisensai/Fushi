import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

const Duration fushiMd3StateDuration = Durations.short4;
const Curve fushiMd3StateCurve = Easing.standard;

const AnimationStyle fushiMd3DialogAnimationStyle = AnimationStyle(
  curve: Easing.emphasizedDecelerate,
  duration: Durations.medium2,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.short4,
);

const AnimationStyle fushiMd3SheetAnimationStyle = AnimationStyle(
  curve: Easing.emphasizedDecelerate,
  duration: Durations.medium4,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.medium1,
);

const AnimationStyle fushiMd3MenuAnimationStyle = AnimationStyle(
  curve: Easing.emphasizedDecelerate,
  duration: Durations.short4,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.short2,
);

/// 主题 / 明暗切换时 MaterialApp 整套颜色的过渡（2026-10 动效重做）。
const AnimationStyle fushiThemeAnimationStyle = AnimationStyle(
  curve: Easing.standard,
  duration: Duration(milliseconds: 280),
);

// =============================================================================
// M3 Expressive 动效物理（2026-10-05 动效统一为 M3E）
//
// 真相源：Material 3 Expressive 的 motion physics——一切运动都是弹簧，按「改了
// 什么」分两类、按「多大面积」分三档：
// - spatial（位置 / 尺寸 / 缩放 / 旋转 / 形状变形）：欠阻尼，允许轻微过冲回弹；
// - effects（颜色 / 透明度 / 模糊）：临界阻尼，**绝不过冲**（透明度 > 1 会断言）。
// - fast（小组件：按钮、开关、图标）/ default（局部区域：卡片展开、侧板）/
//   slow（整屏：页面、全屏 sheet）。
//
// 数值取自 material-components-android `motion/res/values/tokens.xml` 与 Compose
// `MotionScheme.expressive()`（两者一致）：
//
// | token          | dampingRatio | stiffness |
// |----------------|--------------|-----------|
// | spatialFast    | 0.6          | 800       |
// | spatialDefault | 0.8          | 380       |
// | spatialSlow    | 0.8          | 200       |
// | effectsFast    | 1.0          | 3800      |
// | effectsDefault | 1.0          | 1600      |
// | effectsSlow    | 1.0          | 800       |
//
// Apple 设计系统走同一套 API，映射到 SwiftUI 的「感知时长 + bounce」弹簧
// （`.snappy` / `.smooth` 一族，见 [FushiMotionScheme.apple]）。
//
// 降级：墨水屏与系统「减弱动态效果」经 [fushiMotionEnabled] 判定，
// [FushiMotionScheme.of] 返回的方案里所有时长归零、弹簧动画直接落到终值。
// =============================================================================

/// 一个弹簧 token：阻尼比 + 刚度（质量恒为 1，与 M3 规范同口径）。
///
/// 三种用法：
/// - 显式控制器：`controller.fushiSpringTo(1, spring)` 走真实
///   [SpringSimulation]，打断时保留速度（M3E 弹簧的意义所在）；
/// - 隐式动画（`AnimatedContainer` 等只收 duration + curve 的 API）：
///   [duration] + [curve]，曲线是同一个弹簧按落定时长归一化后的形状；
/// - 物理参数直取：[description] / [simulation]。
@immutable
class FushiSpringSpec {
  const FushiSpringSpec({
    required this.dampingRatio,
    required this.stiffness,
    this.enabled = true,
  });

  /// 由 SwiftUI 式的「感知时长 + bounce」构造（Apple 设计系统用）。与
  /// [SpringDescription.withDurationAndBounce] 同一换算：
  /// `stiffness = (2π / duration)²`，`dampingRatio = 1 - bounce`。
  factory FushiSpringSpec.perceptual({
    required double durationSeconds,
    double bounce = 0,
  }) {
    final double omega = 2 * math.pi / durationSeconds;
    return FushiSpringSpec(dampingRatio: 1 - bounce, stiffness: omega * omega);
  }

  final double dampingRatio;
  final double stiffness;

  /// false = 已按「减弱动态效果 / 墨水屏」降级：[duration] 为零、
  /// [AnimationControllerFushiSpring.fushiSpringTo] 直接跳到终值。
  final bool enabled;

  /// 判定「落定」的容差：距终点不超过全程的 1%。再往后的尾巴肉眼不可辨，
  /// 算进时长只会让隐式动画的 duration 虚长。
  static const double settleTolerance = 0.01;

  /// 物理描述（mass = 1）。
  SpringDescription get description => SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: stiffness,
    ratio: dampingRatio,
  );

  /// 从 [from] 到 [to] 的弹簧模拟，[velocity] 为初速度（单位/秒）。
  SpringSimulation simulation(double from, double to, {double velocity = 0}) {
    final double distance = (to - from).abs();
    return SpringSimulation(
      description,
      from,
      to,
      velocity,
      tolerance: Tolerance(
        distance: math.max(distance * 0.001, 1e-4),
        velocity: math.max(distance * 0.01, 1e-3),
      ),
      // 落定时精确落到终点：否则控制器停在 end ± 容差处，unbounded 的缩放 /
      // 位移会永远差一丝。
      snapToEnd: true,
    );
  }

  /// 从静止走完全程到「落定」（[settleTolerance]）所需时间；降级时为零。
  Duration get duration {
    if (!enabled) return Duration.zero;
    final double seconds =
        fushiSpringSettleTime(dampingRatio) / math.sqrt(stiffness);
    return Duration(microseconds: (seconds * 1e6).round());
  }

  /// 归一化弹簧曲线，配合 [duration] 给隐式动画用。spatial 弹簧（阻尼比 < 1）
  /// 的曲线会过冲，**不能**驱动透明度——透明度一律用 effects token。
  Curve get curve => FushiSpringCurve(dampingRatio: dampingRatio);

  /// 降级版本（时长归零）。
  FushiSpringSpec get reduced => FushiSpringSpec(
    dampingRatio: dampingRatio,
    stiffness: stiffness,
    enabled: false,
  );

  @override
  bool operator ==(Object other) =>
      other is FushiSpringSpec &&
      other.dampingRatio == dampingRatio &&
      other.stiffness == stiffness &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(dampingRatio, stiffness, enabled);

  @override
  String toString() =>
      'FushiSpringSpec(ζ=$dampingRatio, k=$stiffness${enabled ? '' : ', reduced'})';
}

/// M3 Expressive 的六个弹簧 token（Material 设计系统；常量，可在 const 上下文
/// 与无 BuildContext 处直接用）。需要随设计系统 / 降级切换时用
/// [FushiMotionScheme.of]。
abstract final class FushiSprings {
  static const FushiSpringSpec spatialFast = FushiSpringSpec(
    dampingRatio: 0.6,
    stiffness: 800,
  );
  static const FushiSpringSpec spatialDefault = FushiSpringSpec(
    dampingRatio: 0.8,
    stiffness: 380,
  );
  static const FushiSpringSpec spatialSlow = FushiSpringSpec(
    dampingRatio: 0.8,
    stiffness: 200,
  );
  static const FushiSpringSpec effectsFast = FushiSpringSpec(
    dampingRatio: 1,
    stiffness: 3800,
  );
  static const FushiSpringSpec effectsDefault = FushiSpringSpec(
    dampingRatio: 1,
    stiffness: 1600,
  );
  static const FushiSpringSpec effectsSlow = FushiSpringSpec(
    dampingRatio: 1,
    stiffness: 800,
  );
}

/// 一套动效方案：六个弹簧 token 按设计系统映射、按降级开关归零。
///
/// ```dart
/// final FushiMotionScheme m = context.fushiMotion;
/// AnimatedContainer(
///   duration: m.spatialDefault.duration,
///   curve: m.spatialDefault.curve,
///   ...
/// );
/// _controller.fushiSpringTo(1, m.spatialFast);
/// ```
@immutable
class FushiMotionScheme {
  const FushiMotionScheme({
    required this.spatialFast,
    required this.spatialDefault,
    required this.spatialSlow,
    required this.effectsFast,
    required this.effectsDefault,
    required this.effectsSlow,
  });

  /// Material 设计系统：M3 Expressive 弹簧。
  static const FushiMotionScheme expressive = FushiMotionScheme(
    spatialFast: FushiSprings.spatialFast,
    spatialDefault: FushiSprings.spatialDefault,
    spatialSlow: FushiSprings.spatialSlow,
    effectsFast: FushiSprings.effectsFast,
    effectsDefault: FushiSprings.effectsDefault,
    effectsSlow: FushiSprings.effectsSlow,
  );

  /// Apple 设计系统：SwiftUI 的感知时长弹簧。spatial 走 `.snappy` 口径
  /// （bounce 0.1–0.15，几乎看不出回弹，是 iOS 的克制手感），effects 走
  /// `.smooth`（bounce 0）。数值是 (2π/d)² 的换算结果，见
  /// [FushiSpringSpec.perceptual]。
  static const FushiMotionScheme apple = FushiMotionScheme(
    // d = 0.35 s, bounce 0.15
    spatialFast: FushiSpringSpec(dampingRatio: 0.85, stiffness: 322.27),
    // d = 0.5 s, bounce 0.15（SwiftUI .snappy）
    spatialDefault: FushiSpringSpec(dampingRatio: 0.85, stiffness: 157.91),
    // d = 0.6 s, bounce 0.1
    spatialSlow: FushiSpringSpec(dampingRatio: 0.9, stiffness: 109.66),
    // d = 0.15 s, bounce 0
    effectsFast: FushiSpringSpec(dampingRatio: 1, stiffness: 1754.60),
    // d = 0.2 s, bounce 0
    effectsDefault: FushiSpringSpec(dampingRatio: 1, stiffness: 986.96),
    // d = 0.3 s, bounce 0（SwiftUI .smooth 的短档）
    effectsSlow: FushiSpringSpec(dampingRatio: 1, stiffness: 438.65),
  );

  final FushiSpringSpec spatialFast;
  final FushiSpringSpec spatialDefault;
  final FushiSpringSpec spatialSlow;
  final FushiSpringSpec effectsFast;
  final FushiSpringSpec effectsDefault;
  final FushiSpringSpec effectsSlow;

  /// 是否播放动效（降级后为 false）。
  bool get enabled => spatialDefault.enabled;

  /// 所有 token 降级（时长归零）。
  FushiMotionScheme get reduced => FushiMotionScheme(
    spatialFast: spatialFast.reduced,
    spatialDefault: spatialDefault.reduced,
    spatialSlow: spatialSlow.reduced,
    effectsFast: effectsFast.reduced,
    effectsDefault: effectsDefault.reduced,
    effectsSlow: effectsSlow.reduced,
  );

  /// 当前上下文的方案：Apple 设计系统 → [apple]，其余 → [expressive]；
  /// 墨水屏 / 减弱动态效果 → 对应方案的 [reduced]。
  static FushiMotionScheme of(BuildContext context) {
    final FushiMotionScheme base = isGlassDesign(context) ? apple : expressive;
    return fushiMotionEnabled(context) ? base : base.reduced;
  }
}

/// `context.fushiMotion` 简写。
extension FushiMotionContext on BuildContext {
  FushiMotionScheme get fushiMotion => FushiMotionScheme.of(this);
}

/// 显式控制器的弹簧驱动。
extension AnimationControllerFushiSpring on AnimationController {
  /// 以 [spring] 把控制器推到 [target]；[velocity] 缺省时**沿用当前速度**
  /// （打断进行中的动画不会「急停再起步」）。降级 token 直接落到终值。
  TickerFuture fushiSpringTo(
    double target,
    FushiSpringSpec spring, {
    double? velocity,
  }) {
    if (!spring.enabled) {
      value = target;
      return TickerFuture.complete();
    }
    return animateWith(
      spring.simulation(value, target, velocity: velocity ?? this.velocity),
    );
  }
}

/// 归一化弹簧曲线：阻尼比为 [dampingRatio]、自然频率为 1 的弹簧从 0 走向 1，
/// 时间轴按「落定时间」（1% 容差）缩放到 [0, 1]。曲线形状只取决于阻尼比，
/// 刚度只决定 [FushiSpringSpec.duration]。
///
/// 落定点残余的 ≤1% 用线性补偿抹掉，保证 `transform(1) == 1` 连续。
/// 阻尼比 < 1 时过冲（0.8 ≈ 1.5%、0.6 ≈ 9.5%），只给 spatial 用。
@immutable
class FushiSpringCurve extends Curve {
  const FushiSpringCurve({
    required this.dampingRatio,
    this.stiffness,
    this.duration,
  }) : assert(dampingRatio > 0, 'dampingRatio must be positive');

  /// M3E spatial fast（ζ 0.6）：小组件的弹性位移 / 缩放 / 形变。
  static const FushiSpringCurve spatialFast = FushiSpringCurve(
    dampingRatio: 0.6,
  );

  /// M3E spatial default / slow（ζ 0.8）：区域与整屏位移。
  static const FushiSpringCurve spatial = FushiSpringCurve(dampingRatio: 0.8);

  /// M3E effects（ζ 1，临界阻尼，不过冲）：颜色 / 透明度，以及任何不允许
  /// 越界的插值（Opacity、Color.lerp 外推会出错）。
  static const FushiSpringCurve effects = FushiSpringCurve(dampingRatio: 1);

  final double dampingRatio;

  /// 与 [duration] 同时给出时按**物理时间**取样：曲线 t ∈ [0,1] 对应
  /// [duration] 内的真实弹簧位移（刚度 [stiffness]、质量 1），残差线性抹平。
  /// 省略时按阻尼比的落定时间归一化（形状只取决于阻尼比）。
  final double? stiffness;
  final Duration? duration;

  @override
  double transformInternal(double t) {
    final double? k = stiffness;
    final Duration? d = duration;
    if (k != null && d != null) {
      final double span = math.sqrt(k) * d.inMicroseconds / 1e6;
      final double end = _unitSpring(dampingRatio, span);
      return _unitSpring(dampingRatio, t * span) + (1 - end) * t;
    }
    final double settle = fushiSpringSettleTime(dampingRatio);
    final double end = _unitSpring(dampingRatio, settle);
    return _unitSpring(dampingRatio, t * settle) + (1 - end) * t;
  }

  @override
  bool operator ==(Object other) =>
      other is FushiSpringCurve &&
      other.dampingRatio == dampingRatio &&
      other.stiffness == stiffness &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(dampingRatio, stiffness, duration);

  @override
  String toString() => 'FushiSpringCurve(ζ=$dampingRatio)';
}

/// 自然频率 ω = 1、初速 0 的弹簧从 0 到 1 的位移（闭式解）。
double _unitSpring(double zeta, double s) {
  if (s <= 0) return 0;
  if ((zeta - 1).abs() < 1e-9) {
    return 1 - math.exp(-s) * (1 + s);
  }
  if (zeta < 1) {
    final double wd = math.sqrt(1 - zeta * zeta);
    return 1 -
        math.exp(-zeta * s) * (math.cos(wd * s) + zeta / wd * math.sin(wd * s));
  }
  final double root = math.sqrt(zeta * zeta - 1);
  final double r1 = -zeta + root;
  final double r2 = -zeta - root;
  return 1 - (r2 * math.exp(r1 * s) - r1 * math.exp(r2 * s)) / (r2 - r1);
}

final Map<double, double> _settleCache = <double, double>{};

/// 自然频率 ω = 1 的弹簧（阻尼比 [dampingRatio]）进入并停留在终点
/// [FushiSpringSpec.settleTolerance] 以内的时刻（无量纲；实际秒数 = 它 / √k）。
double fushiSpringSettleTime(double dampingRatio) {
  return _settleCache.putIfAbsent(dampingRatio, () {
    const double step = 0.005;
    const double limit = 60;
    double last = 0;
    for (double s = 0; s < limit; s += step) {
      if ((_unitSpring(dampingRatio, s) - 1).abs() >
          FushiSpringSpec.settleTolerance) {
        last = s;
      }
    }
    return last + step;
  });
}

// =============================================================================
// 兼容层：时长 + 曲线常量（const 上下文 / 只收 Duration + Curve 的 API 用）。
// 全部由上面的弹簧 token 推导；常量值与 [FushiSpringSpec.duration] 的计算值由
// test/widgets/fushi_motion_tokens_test.dart 钉住。新代码优先用
// [FushiMotionScheme.of] / [FushiSprings]。
// =============================================================================

/// 临界阻尼弹簧曲线的时间反演：慢起步、快离场（退出 / 让路用）。
class _SpringExit extends Curve {
  const _SpringExit();

  @override
  double transformInternal(double t) =>
      1 - FushiSpringCurve.effects.transform(1 - t);
}

/// Fushi 动效的兼容常量（2026-10 动效重做时的时长 / 曲线体系，2026-10-05
/// 起全部由 M3E 弹簧 token 推导）。
///
/// 设计原则（详见 `docs/specs/2026-10-02-ui-motion-redesign.md`）：
/// - **一切皆弹簧**：时长 = 对应弹簧落定到 1% 的时间，曲线 = 同一弹簧的归一化
///   形状；需要保留速度 / 可打断的地方直接用 [FushiSprings] +
///   [AnimationControllerFushiSpring.fushiSpringTo]。
/// - **spatial 可回弹、effects 不过冲**：[enter] / [standard] / [exit] 都是
///   临界阻尼形状，可安全驱动透明度；只有 [release] 带回弹。
/// - **两档降级**：墨水屏与系统「减弱动态效果」都经 [fushiMotionEnabled]
///   判定，[fushiMotionDuration] 一处归零。
abstract final class FushiMotion {
  /// effects fast（ζ1 / k3800 ≈ 108ms）：按压、波纹落点、图标交叉淡化。
  static const Duration micro = Duration(milliseconds: 110);

  /// effects default（ζ1 / k1600 ≈ 166ms）：小组件状态切换。
  static const Duration short = Duration(milliseconds: 165);

  /// spatial default（ζ0.8 / k380 ≈ 326ms）：组件内中等位移、列表项进场。
  static const Duration medium = Duration(milliseconds: 325);

  /// spatial slow（ζ0.8 / k200 ≈ 449ms）：跨页转场与大面积容器变化。
  static const Duration long = Duration(milliseconds: 450);

  /// effects slow（ζ1 / k800 ≈ 235ms）：退出 / 反向（与 [long] 配对）。
  static const Duration longReverse = Duration(milliseconds: 235);

  /// 列表 / 网格逐项进场：相邻两项的错峰间隔。
  static const Duration staggerStep = Duration(milliseconds: 35);

  /// 错峰进场最多错到第几项：再往后的项与第 N 项同时出现，避免长列表
  /// 「一条一条往外蹦」拖慢首屏可用时间。
  static const int staggerMaxItems = 8;

  /// 进入：临界阻尼弹簧形状（快起步、柔落点，不过冲，可驱动透明度）。
  static const Curve enter = FushiSpringCurve.effects;

  /// 退出：[enter] 的时间反演（慢起步、快离场）。
  static const Curve exit = _SpringExit();

  /// 原地状态变化（颜色、尺寸）：同 [enter]。
  static const Curve standard = FushiSpringCurve.effects;

  /// 按压回弹：M3E spatial fast（ζ0.6）弹簧形状，松手时带弹性过冲。
  /// **只用于缩放 / 位移**，不能驱动透明度。
  static const Curve release = FushiSpringCurve.spatialFast;

  /// 按压时卡片缩到的倍数。0.97 是在 160dp 宽封面上肉眼可辨、又不至于让
  /// 封面文字抖动的下限（0.95 时标题行会明显「缩字」）。
  static const double pressScale = 0.97;

  /// 页面级进场的纵向位移（逻辑像素）。
  static const double enterOffset = 16;
}

/// 当前上下文是否播放装饰性动效：墨水屏与系统「减弱动态效果」下都为 false。
///
/// 只管**装饰性**动效（按压缩放、进场、转场位移）；承载语义的状态变化（选中色、
/// 展开 / 收起后的最终几何）仍然要发生，只是瞬间到位。
bool fushiMotionEnabled(BuildContext context) {
  if (isEinkTheme(context)) return false;
  return !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
}

/// [fushiMotionEnabled] 为 false 时归零，否则原样返回 [duration]。
Duration fushiMotionDuration(BuildContext context, Duration duration) {
  return fushiMotionEnabled(context) ? duration : Duration.zero;
}
