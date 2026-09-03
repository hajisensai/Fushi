import 'package:flutter/material.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

/// 卡片悬浮抬升：鼠标移入时轻微放大，并把 hover 态交给 [builder]，由调用方决定
/// 还要不要顺带加深阴影/描边。
///
/// 抽出来的原因：这套动效原本只长在 [GalgamePosterCard] 里（全 app 唯一一处
/// `AnimatedScale`），书架 / 漫画 / 视频库的卡片都只有 `InkWell` 水波纹、鼠标
/// 悬停毫无反馈。把它复制到各库页会得到 N 份互相漂移的实现，所以先收成一个壳。
///
/// 两处降级是 [GalgamePosterCard] 原实现缺的，推广前必须补上——否则动效铺开
/// 之后这两类设备/偏好会明显变差：
/// - **墨水屏**（[isEinkTheme]）：持续缩放会不断触发整屏重绘刷屏，直接关掉动效，
///   hover 反馈交给 builder 自己（通常改成描边）。
/// - **减弱动态效果**（`MediaQuery.disableAnimations`，系统无障碍开关）：同样
///   关掉缩放，但 hover 状态照常传给 builder，静态反馈保留。
///
/// 触屏平台上 [MouseRegion] 本就不会触发，无需按平台分流。
class FushiHoverLift extends StatefulWidget {
  const FushiHoverLift({
    super.key,
    required this.builder,
    this.enabled = true,
    this.scale = kFushiHoverLiftScale,
  });

  /// 拿到当前 hover 态自行构建内容。hover 态在 [enabled] 为 false 时恒为 false。
  final Widget Function(BuildContext context, bool hovering) builder;

  /// false 时既不建 [MouseRegion] 也不缩放（例如多选态、或调用方不想要动效）。
  final bool enabled;

  /// 悬停时的缩放倍数。默认与游戏库既有观感一致。
  final double scale;

  @override
  State<FushiHoverLift> createState() => _FushiHoverLiftState();
}

/// 悬停缩放倍数：与 `docs/design/galgame-library-reina-visual-parity.md` 里定的
/// 游戏库观感一致，推广到其余库页时不另立数值。
const double kFushiHoverLiftScale = 1.05;

/// 悬停动画时长（游戏库既有实现的落地值）。
const Duration kFushiHoverLiftDuration = Duration(milliseconds: 120);

class _FushiHoverLiftState extends State<FushiHoverLift> {
  bool _hovering = false;

  void _setHover(bool value) {
    if (_hovering == value) return;
    setState(() => _hovering = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      // 保证 builder 拿到的 hover 态与「没有 MouseRegion」一致。
      if (_hovering) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _setHover(false);
        });
      }
      return widget.builder(context, false);
    }
    final bool reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final bool animate = !reduceMotion && !isEinkTheme(context);
    final Widget content = widget.builder(context, _hovering);
    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: animate
          ? AnimatedScale(
              scale: _hovering ? widget.scale : 1.0,
              duration: kFushiHoverLiftDuration,
              curve: Curves.easeOut,
              child: content,
            )
          : content,
    );
  }
}
