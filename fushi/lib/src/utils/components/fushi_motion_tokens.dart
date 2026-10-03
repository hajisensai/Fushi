import 'package:flutter/material.dart';

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

/// Fushi 动效体系（2026-10 UI / 动效重做）的**唯一时长 / 曲线真相源**。
///
/// 设计原则（详见 `docs/specs/2026-10-02-ui-motion-redesign.md`）：
/// - **快进慢出**：进入走 emphasizedDecelerate（起步快、落点柔），退出走
///   emphasizedAccelerate 且时长约为进入的 2/3——用户的注意力在新内容上，旧内容
///   应当尽快让路。
/// - **距离决定时长**：微反馈（按压、勾选）≤ 120ms，组件内状态 ≈ 200ms，
///   跨页 / 大面积 ≈ 300–400ms；超过 500ms 的动画一律视为设计错误。
/// - **两档降级**：墨水屏（连续重绘 = 残影）与系统「减弱动态效果」都经
///   [fushiMotionEnabled] 判定，[fushiMotionDuration] 一处归零，组件不再各自写三元。
abstract final class FushiMotion {
  /// 按压缩放 / 波纹落点这类「手指还没抬起就要看到」的反馈。
  static const Duration micro = Duration(milliseconds: 90);

  /// 小组件状态切换（开关、选中药丸、图标交叉淡化）。
  static const Duration short = Duration(milliseconds: 180);

  /// 组件内中等位移（展开卡片、列表项进场）。
  static const Duration medium = Duration(milliseconds: 280);

  /// 跨页转场与大面积容器变化。
  static const Duration long = Duration(milliseconds: 360);

  /// 退出 / 反向动画的时长（与 [long] 配对）。
  static const Duration longReverse = Duration(milliseconds: 240);

  /// 列表 / 网格逐项进场：相邻两项的错峰间隔。
  static const Duration staggerStep = Duration(milliseconds: 35);

  /// 错峰进场最多错到第几项：再往后的项与第 N 项同时出现，避免长列表
  /// 「一条一条往外蹦」拖慢首屏可用时间。
  static const int staggerMaxItems = 8;

  /// 进入：快起步、柔落点。
  static const Curve enter = Easing.emphasizedDecelerate;

  /// 退出：慢起步、快离场。
  static const Curve exit = Easing.emphasizedAccelerate;

  /// 原地状态变化（颜色、尺寸，不涉及进出场）。
  static const Curve standard = Easing.standard;

  /// 按压回弹：松手时带极轻的过冲（≈2%），比线性回弹多一点「弹性」手感，
  /// 但不会像 easeOutBack 那样明显晃动。
  static const Curve release = _SoftOvershoot();

  /// 按压时卡片缩到的倍数。0.97 是在 160dp 宽封面上肉眼可辨、又不至于让
  /// 封面文字抖动的下限（0.95 时标题行会明显「缩字」）。
  static const double pressScale = 0.97;

  /// 页面级进场的纵向位移（逻辑像素）。
  static const double enterOffset = 16;
}

/// 带约 2% 过冲的减速曲线：`t → 1 + (k+1)(t-1)^3 + k(t-1)^2`，k 取小值。
class _SoftOvershoot extends Curve {
  const _SoftOvershoot();

  static const double _k = 0.6;

  @override
  double transformInternal(double t) {
    final double u = t - 1;
    return u * u * ((_k + 1) * u + _k) + 1;
  }
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
