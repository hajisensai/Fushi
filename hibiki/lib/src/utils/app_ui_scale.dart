import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:hibiki/src/utils/spacing.dart';

/// 浏览器式整体界面缩放。
///
/// 与早期实现不同：不再仅改写 [MediaQuery.textScaler] / [Spacing]（那样只会放大
/// 文字和间距，图标、控件、图片纹丝不动）。这里用 [Transform.scale] 对整棵子树做
/// 视觉缩放，同时把 [MediaQuery] 的 size / inset 反算成「缩小后的逻辑画布」，让布局
/// 回流填满整屏——效果等同浏览器缩放：所有东西按同一比例一起放大缩小。
///
/// 注意：阅读器 WebView 也在这层缩放内、跟随整体一起缩放（放大时正文会有轻微栅格
/// 软化，正文字号请用阅读器自带设置）。**不要**单独对 WebView 做反向缩放——那会让
/// WebView 处于原生坐标空间、而其上的划词弹窗/高亮浮层仍在缩放后的 canvas 空间，
/// 两套坐标错位 factor scale，书内查词弹窗与高亮会全部偏位（曾如此回归过）。
class HibikiAppUiScale extends StatelessWidget {
  const HibikiAppUiScale({
    required this.scale,
    required this.child,
    super.key,
  });

  static const double minScale = 0.3;
  static const double defaultScale = 1.0;
  static const double maxScale = 3.0;

  final double scale;
  final Widget child;

  static double normalize(double value) {
    if (value.isNaN || !value.isFinite) return defaultScale;
    return value.clamp(minScale, maxScale).toDouble();
  }

  static bool isDesktopPlatform(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.iOS:
        return false;
    }
  }

  static double automaticScaleForViewport({
    required Size viewport,
    required TargetPlatform platform,
  }) {
    bool positiveFinite(double value) =>
        value.isFinite && !value.isNaN && value > 0;
    if (!positiveFinite(viewport.width) || !positiveFinite(viewport.height)) {
      return defaultScale;
    }

    final bool desktop = isDesktopPlatform(platform);
    final double shortestSide = math.min(viewport.width, viewport.height);
    final double diagonal = math.sqrt(
      viewport.width * viewport.width + viewport.height * viewport.height,
    );

    final double targetShortSide = desktop ? 900.0 : 390.0;
    final double targetDiagonal = desktop ? 1500.0 : 930.0;
    final double sensitivity = desktop ? 0.22 : 0.18;
    final double minAutoScale = desktop ? 0.88 : 0.92;
    final double maxAutoScale = desktop ? 1.16 : 1.12;

    final double shortRatio = shortestSide / targetShortSide;
    final double diagonalRatio = diagonal / targetDiagonal;
    final double blendedRatio = shortRatio * 0.70 + diagonalRatio * 0.30;
    final double raw =
        defaultScale + (blendedRatio - defaultScale) * sensitivity;

    return raw.clamp(minAutoScale, maxAutoScale).toDouble();
  }

  /// 读取最近一层祖先注入的有效缩放系数；无祖先时返回 [defaultScale]。
  static double of(BuildContext context) {
    final _AppUiScaleScope? scope =
        context.dependOnInheritedWidgetOfExactType<_AppUiScaleScope>();
    return scope?.scale ?? defaultScale;
  }

  @override
  Widget build(BuildContext context) {
    final double s = normalize(scale);

    final Widget scoped = _AppUiScaleScope(
      scale: s,
      child: Spacing(
        dataBuilder: (_) => SpacingData.generate(10),
        child: child,
      ),
    );

    if (s == defaultScale) return scoped;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return scoped;
        }
        final Size view = constraints.biggest;
        final Size canvas = view / s;
        final MediaQueryData mq = MediaQuery.of(context);
        // 用 FittedBox(BoxFit.fill) 而非 Transform.scale + OverflowBox：
        // OverflowBox 让 canvas 子树「溢出」自身（box 尺寸只有 view），缩小 (s<1) 时
        // canvas > view，溢出到 view 之外的底部/右侧子树会被 RenderBox.hitTest 的
        // `size.contains(position)` 短路丢弃命中——底栏「看得到点不到」。
        // FittedBox 把 canvas 子树「装进」自身：box 尺寸恒为 view，子树缩放后恰好填满、
        // 绝不溢出，整个可见区都可命中。canvas = view/s 各轴等比，BoxFit.fill 算出的
        // 变换就是均匀 scale = s，与原 Transform 数值等价（WebView 坐标一致性不变）。
        return FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: canvas,
            child: MediaQuery(
              data: _scaleMediaQuery(mq, 1 / s),
              child: scoped,
            ),
          ),
        );
      },
    );
  }
}

/// 在阅读器等需要原生清晰度的全屏子树里「中和」祖先 [HibikiAppUiScale] 的整体缩放。
///
/// 逆变换：把子树重新按**真实视口尺寸**布局、净缩放回到 1.0，使其中的 WebView 平台
/// 视图按原生像素密度渲染（放大不再栅格软化）。正文大小改由阅读器自带字号控制。
///
/// **关键**：必须整棵子树（WebView + 划词弹窗 + 高亮 + 铬层）一起中和——它们处于
/// 同一坐标空间，所以 JS 报的 selectionRect 定位不会错位。**不要**只中和 WebView：
/// 那正是被撤销的 HibikiNativeScale 老坑（只反缩放 WebView、弹窗没跟上 → 错位）。
///
/// 必须从**路由层**包在页面外，使页面 State.context 也落在本中和器之下，辅助方法
/// 经 State.context 读到的 MediaQuery 才是真实几何。
class HibikiAppUiScaleNeutralizer extends StatelessWidget {
  const HibikiAppUiScaleNeutralizer({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double s = HibikiAppUiScale.of(context);
    if (s == HibikiAppUiScale.defaultScale) return child;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        final Size canvas = constraints.biggest; // 祖先给的缩放画布 (view/s)
        final Size view = canvas * s; // 还原真实视口
        final MediaQueryData mq = MediaQuery.of(context);
        return FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: view,
            child: MediaQuery(
              data: _scaleMediaQuery(mq, s), // ×s 还原真实 size/inset
              child: _AppUiScaleScope(
                scale: HibikiAppUiScale.defaultScale, // 子树视角:净缩放=1
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 把 [MediaQueryData] 的几何量按 [factor] 缩放，使 SafeArea / 键盘避让在缩小后的
/// 逻辑画布里仍然正确。
MediaQueryData _scaleMediaQuery(MediaQueryData mq, double factor) {
  return mq.copyWith(
    size: mq.size * factor,
    padding: mq.padding * factor,
    viewPadding: mq.viewPadding * factor,
    viewInsets: mq.viewInsets * factor,
    systemGestureInsets: mq.systemGestureInsets * factor,
  );
}

/// 向后代暴露当前有效缩放系数。
class _AppUiScaleScope extends InheritedWidget {
  const _AppUiScaleScope({
    required this.scale,
    required super.child,
  });

  final double scale;

  @override
  bool updateShouldNotify(_AppUiScaleScope oldWidget) =>
      oldWidget.scale != scale;
}
