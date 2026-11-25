import 'package:flutter/rendering.dart' show RenderOpacity;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
// 库没导出这两个 scope，但它们正是库给「整棵子树的玻璃一起显隐」留的合法通道
// （GlassMaterialize / 导航壳都走它）；公开的 GlassMaterializeTransition 只有 iOS
// 「先清内容、后散玻璃」的错峰编排，chrome 显隐要内容与玻璃底同一条进度。
// ignore: implementation_imports
import 'package:liquid_glass_widgets/src/renderer/glass_materialize_scope.dart'
    show GlassMaterializeScope;
// ignore: implementation_imports
import 'package:liquid_glass_widgets/src/renderer/liquid_glass_self_scale_scope.dart'
    show LiquidGlassSelfScaleScope;

// chrome（顶栏 / 底栏 / 播放器控制条 / OSD）显隐淡入淡出的玻璃安全通道。
//
// 液态玻璃是 BackdropFilter + 着色器：祖先一旦有 `Opacity` / `FadeTransition` /
// `AnimatedOpacity`（不透明度 < 1 时推一层 OpacityLayer = saveLayer），玻璃的
// backdrop 采到的就只是这层 saveLayer 自己（空的），而不是后面的正文 / 画面——
// 于是淡出时图标照常变淡，玻璃底却变成一团没有内容的灰色模糊胶囊，透明度归零
// 那一帧才整块消失；淡入第一帧同理是一块形状不对的灰底（用户 2026-11-24 录屏：
// 阅读器顶栏胶囊收起「有点怪」、视频控件「会闪」）。
//
// 正确做法（liquid_glass_widgets 的 GlassMaterializeScope 文档）：玻璃走着色器
// 自己的 `visibility` 统一缩放，玻璃里的内容走库包在内容外的 Opacity（玻璃的
// 兄弟层，不是 BackdropFilter 的祖先），玻璃之外的普通内容各自包
// [FushiGlassPresenceFade]——整棵子树没有一层 Opacity 压在玻璃上面。
//
// 本文件是纯动效 / 合成层，与设计系统无关：M3E 与实色档（[glassMaterialOf] ==
// off）下没有玻璃，[fushiChromeFade] 直接给普通 Opacity，像素与旧实现一致。

/// 当前上下文下 chrome 子树里会不会有液态玻璃（Apple 设计系统且玻璃画质不是
/// 实色档）。为 true 时整棵 chrome 不能被 Opacity 包住。
bool fushiChromeHasGlass(BuildContext context) =>
    isGlassDesign(context) &&
    glassMaterialOf(context) != FushiGlassMaterial.off;

/// 把 [child] 整体淡到 [opacity]（0 = 隐藏，1 = 完整）：有玻璃时走
/// [FushiGlassPresence]（玻璃与内容同一条进度），否则普通 [Opacity]。
/// 签名与 media_kit 控制条的 `VideoControlsFadeBuilder` 一致，可直接传过去。
Widget fushiChromeFade(BuildContext context, double opacity, Widget child) {
  if (fushiChromeHasGlass(context)) {
    return FushiGlassPresence(presence: opacity, child: child);
  }
  return Opacity(opacity: opacity.clamp(0.0, 1.0), child: child);
}

/// [FadeTransition] 的玻璃安全版：按 [opacity] 动画走 [fushiChromeFade]。
class FushiChromeFadeTransition extends StatelessWidget {
  const FushiChromeFadeTransition({
    super.key,
    required this.opacity,
    required this.child,
  });

  final Animation<double> opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: opacity,
      child: child,
      builder: (BuildContext context, Widget? child) =>
          fushiChromeFade(context, opacity.value, child!),
    );
  }
}

/// 子树里所有玻璃（着色器 visibility）与玻璃内容一起显隐到 [presence]，玻璃之外
/// 的普通内容读 [FushiGlassPresenceFade]。不推任何 OpacityLayer。
///
/// [presence] 为 1 时库的 scope 是惰性的（设置原样返回、内容 Opacity 在 255 时
/// 不合成），静止的 chrome 不多付一层。为 0 时库的各渲染档都跳过玻璃绘制。
class FushiGlassPresence extends StatelessWidget {
  const FushiGlassPresence({
    super.key,
    required this.presence,
    required this.child,
  });

  final double presence;
  final Widget child;

  /// 最近一层 [FushiGlassPresence] 的进度；没有时 null（不在显隐动画的子树里）。
  static double? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_FushiGlassPresenceScope>()
      ?.presence;

  @override
  Widget build(BuildContext context) {
    final double p = presence.clamp(0.0, 1.0);
    return GlassMaterializeScope(
      glassProgress: p,
      contentOpacity: p,
      contentSigma: 0,
      child: _FushiGlassPresenceScope(presence: p, child: child),
    );
  }
}

class _FushiGlassPresenceScope extends InheritedWidget {
  const _FushiGlassPresenceScope({
    required this.presence,
    required super.child,
  });

  final double presence;

  @override
  bool updateShouldNotify(_FushiGlassPresenceScope oldWidget) =>
      presence != oldWidget.presence;
}

/// chrome 里**不含玻璃**的普通内容（玻璃底的兄弟层文字 / 按钮、播放器标题与
/// 底栏控件、暗化渐变）：在 [FushiGlassPresence] 下按它的进度淡，之外原样返回。
/// 子树里绝不能再有玻璃（否则又是 Opacity 压玻璃）。
///
/// 静止（进度 1）时不合成：与库的 GlassControlledOpacity 同理，只在不透明度
/// 是小数时才推 OpacityLayer。
class FushiGlassPresenceFade extends StatelessWidget {
  const FushiGlassPresenceFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double? p = FushiGlassPresence.maybeOf(context);
    if (p == null) return child;
    return _PresenceOpacity(opacity: p, child: child);
  }
}

class _PresenceOpacity extends SingleChildRenderObjectWidget {
  const _PresenceOpacity({required this.opacity, required super.child});

  final double opacity;

  @override
  RenderOpacity createRenderObject(BuildContext context) =>
      _RenderPresenceOpacity(opacity: opacity);

  @override
  void updateRenderObject(BuildContext context, RenderOpacity renderObject) {
    renderObject.opacity = opacity;
  }
}

class _RenderPresenceOpacity extends RenderOpacity {
  _RenderPresenceOpacity({required super.opacity});

  @override
  bool get alwaysNeedsCompositing =>
      super.alwaysNeedsCompositing && Color.getAlphaFromOpacity(opacity) < 255;
}

/// 玻璃 chrome 自己缩放时（显隐的轻微缩放）告诉玻璃：背景没跟着缩，着色器跟
/// 实时变换走，不要冻结 UV（否则缩小中的玻璃形状停在缩放开始时的位置）。
/// 祖先若已声明自缩放则沿用（库的 OR 约定）。
Widget fushiGlassSelfScale(
  BuildContext context, {
  required bool scaling,
  required Widget child,
}) => LiquidGlassSelfScaleScope(
  selfScaled: LiquidGlassSelfScaleScope.of(context) || scaling,
  child: child,
);
