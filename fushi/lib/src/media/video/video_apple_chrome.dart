import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 视频播放器 chrome 的 Apple（iOS / macOS 26 Liquid Glass）形态：对照 AVKit
// （AVPlayerViewController）/ QuickTime / TV app 的播放控件——
//
// - 底栏是一枚**浮动的透明液态玻璃胶囊**，离播放区边缘 [kVideoAppleChromeEdgeInset]，
//   进度条与按钮行都在胶囊里；按钮无底、白色字形；
// - 顶栏的返回键是一枚玻璃圆钮，右上角的一组动作收进一枚玻璃胶囊；
// - 画面上的 OSD（跳转提示、音量 / 亮度 HUD、长按倍速、小窗三键）都是玻璃；
// - 背后不再铺 MD3 那种重黑渐变，只留很淡的顶 / 底暗化，可读性靠玻璃自己。
//
// 播放器 chrome 永远压在画面上，所以这里的玻璃一律经 [FushiAppleDarkTier] 取深色档
// （浅色 app 里同样是深色玻璃 + 白字）。MD3 / 墨水屏下本文件的组件全部退化成
// 「零像素」：背景层返回 [SizedBox.shrink]，[VideoGlassSurface] 的玻璃底换成空盒、
// 内边距归零——子树结构不随设计系统增删父包装层，只换叶子与参数。

/// 底栏玻璃胶囊离播放区左 / 右 / 底边的距离（iOS 26 浮动控件条的外边距）。
const double kVideoAppleChromeEdgeInset = 16;

/// 胶囊上沿高出进度条轨道中线的距离（按住拖动时轨道加粗到 ~10，仍留出呼吸）。
const double kVideoAppleCapsuleTopPadding = 16;

/// 胶囊下沿低于按钮行下沿的距离。
const double kVideoAppleCapsuleBottomPadding = 2;

/// 胶囊圆角上限（AVKit 底栏是大圆角矩形，不是整条药丸）。
const double kVideoAppleCapsuleMaxRadius = 28;

/// Apple 设计系统下的播放器 chrome 是否生效（墨水屏恒 false，见 [isGlassDesign]）。
bool videoAppleChrome(BuildContext context) => isGlassDesign(context);

/// 播放器 chrome 的玻璃 settings：压在画面上的控件层，取透明液态玻璃
/// （[fushiClearGlassSettings]，[bar] = 大面积浮动条）。iOS / macOS 上画面可能是
/// 原生平台视图（着色器采不到像素），换成带实色兜底的
/// [fushiGlassSettingsOverPlatformView]，与 [fushiGlassOverPlatformView] 配套。
LiquidGlassSettings videoChromeGlassSettings(
  BuildContext context, {
  bool bar = false,
}) {
  if (fushiGlassOverPlatformView(context)) {
    return fushiGlassSettingsOverPlatformView(context);
  }
  return fushiClearGlassSettings(context, bar: bar);
}

/// 一块填满父约束的播放器玻璃（深色档）。[radius] 为 null 时取短边一半（药丸 /
/// 圆形）。只画玻璃本身，不承载交互——放在按钮的**背后**当兄弟层。
class VideoChromeGlass extends StatelessWidget {
  const VideoChromeGlass({super.key, this.radius, this.bar = false});

  /// 圆角；null = 短边一半。
  final double? radius;

  /// 是否用大面积浮动条的玻璃配方（底栏胶囊）。
  final bool bar;

  @override
  Widget build(BuildContext context) {
    return FushiAppleDarkTier(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double half =
              math.min(constraints.maxWidth, constraints.maxHeight) / 2;
          final double r = math.min(radius ?? half, half);
          return GlassContainer(
            useOwnLayer: true,
            quality: fushiGlassQuality(context, prominent: bar),
            settings: videoChromeGlassSettings(context, bar: bar),
            shape: LiquidRoundedSuperellipse(borderRadius: r),
            platformViewBackdrop: fushiGlassOverPlatformView(context),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

/// 给一组控件垫一块玻璃底（顶栏右侧动作胶囊、返回圆钮）。
///
/// 玻璃画在子树**背后**的兄弟层（[Stack] + [Positioned.fill]），子树本身永远挂在
/// 同一个位置：MD3 下玻璃层换成空盒、[padding] 归零，[StackFit.passthrough] 让子树
/// 拿到与不包这一层时完全相同的约束——像素与焦点 / 语义树都不变。
class VideoGlassSurface extends StatelessWidget {
  const VideoGlassSurface({
    super.key,
    required this.enabled,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius,
  });

  /// 是否画玻璃（Apple 设计系统）。
  final bool enabled;

  /// 玻璃内边距（只在 [enabled] 时生效）。
  final EdgeInsets padding;

  /// 圆角；null = 药丸 / 圆形。
  final double? radius;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: enabled
              ? IgnorePointer(child: VideoChromeGlass(radius: radius))
              : const SizedBox.shrink(),
        ),
        Padding(padding: enabled ? padding : EdgeInsets.zero, child: child),
      ],
    );
  }
}

/// 底栏玻璃胶囊的几何：距播放区左 / 右 / 底边的距离与高度（逻辑像素）。
@immutable
class VideoAppleCapsuleGeometry {
  const VideoAppleCapsuleGeometry({
    required this.left,
    required this.right,
    required this.bottom,
    required this.height,
  });

  final double left;
  final double right;
  final double bottom;
  final double height;

  /// 圆角：不超过高度一半，也不超过 [kVideoAppleCapsuleMaxRadius]。
  double get radius => math.min(height / 2, kVideoAppleCapsuleMaxRadius);
}

/// Apple 设计系统下播放器 chrome 的背景层：很淡的顶 / 底暗化 + 底栏玻璃胶囊。
///
/// 挂在 media_kit 控制条**下面**（controls Stack 里排在 `AdaptiveVideoControls`
/// 之前），于是按钮与进度条画在玻璃之上、玻璃采样的是画面。显隐跟随控制条真实
/// 可见性 [visible]，与控制条同速淡入淡出；纯视觉，[IgnorePointer]。MD3 / 墨水屏
/// 下（[enabled] false）整层是一个零尺寸盒。
class VideoAppleChromeBackdrop extends StatelessWidget {
  const VideoAppleChromeBackdrop({
    super.key,
    required this.enabled,
    required this.visible,
    required this.duration,
    required this.capsule,
    required this.showTopScrim,
    required this.showBottomScrim,
  });

  final bool enabled;

  /// 控制条可见性（与 media_kit 控制条同一真相源）。
  final ValueListenable<bool> visible;

  /// 淡入淡出时长（与控制条同速）。
  final Duration duration;

  /// 底栏胶囊几何；null = 不画胶囊（mini 档没有底栏）。
  final VideoAppleCapsuleGeometry? capsule;

  /// 顶栏在时画顶部暗化。
  final bool showTopScrim;

  /// 底栏在时画底部暗化。
  final bool showBottomScrim;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    final VideoAppleCapsuleGeometry? geometry = capsule;
    return IgnorePointer(
      child: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (BuildContext context, bool shown, Widget? child) {
          return AnimatedOpacity(
            opacity: shown ? 1.0 : 0.0,
            duration: einkSafeDuration(context, duration),
            curve: Curves.easeInOut,
            child: child,
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // AVKit 的顶 / 底暗化：只有一层很淡的黑，压住高亮画面让白字不发虚，
            // 不是 MD3 那种 38% 的重渐变。
            if (showTopScrim)
              const Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  height: 120,
                  width: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[Color(0x33000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
            if (showBottomScrim)
              const Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[Color(0x00000000), Color(0x3D000000)],
                      ),
                    ),
                  ),
                ),
              ),
            if (geometry != null)
              Positioned(
                left: geometry.left,
                right: geometry.right,
                bottom: geometry.bottom,
                height: geometry.height,
                child: VideoChromeGlass(radius: geometry.radius, bar: true),
              ),
          ],
        ),
      ),
    );
  }
}

/// 播放器上的玻璃圆钮（小窗居中三键、侧边锁）：无填充色，靠玻璃 + 白色 SF 字形；
/// 按下变淡、可 Tab 聚焦、Enter 触发（[FushiPlainButton]）。
class VideoGlassCircleButton extends StatelessWidget {
  const VideoGlassCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.size,
    this.iconSize,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 圆钮直径。
  final double size;

  /// 字形尺寸；null = 直径的 0.46。
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: VideoGlassSurface(
        enabled: true,
        child: FushiTooltip(
          message: tooltip,
          child: FushiPlainButton(
            onPressed: onPressed,
            semanticLabel: tooltip,
            borderRadius: BorderRadius.circular(size / 2),
            child: SizedBox.square(
              dimension: size,
              child: Center(
                child: FushiIcon(
                  icon,
                  size: iconSize ?? size * 0.46,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 播放器上的玻璃 OSD 胶囊（跳转提示、长按倍速、通知）：深色玻璃 + 白字。
class VideoGlassHud extends StatelessWidget {
  const VideoGlassHud({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    this.radius,
  });

  final Widget child;
  final EdgeInsets padding;

  /// 圆角；null = 药丸。
  final double? radius;

  @override
  Widget build(BuildContext context) {
    return VideoGlassSurface(
      enabled: true,
      radius: radius,
      padding: padding,
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: IconTheme.merge(
          data: const IconThemeData(color: Colors.white),
          child: child,
        ),
      ),
    );
  }
}
