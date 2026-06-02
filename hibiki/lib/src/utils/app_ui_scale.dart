import 'package:flutter/widgets.dart';
import 'package:hibiki/src/utils/spacing.dart';

/// 浏览器式整体界面缩放。
///
/// 与早期实现不同：不再仅改写 [MediaQuery.textScaler] / [Spacing]（那样只会放大
/// 文字和间距，图标、控件、图片纹丝不动）。这里用 [Transform.scale] 对整棵子树做
/// 视觉缩放，同时把 [MediaQuery] 的 size / inset 反算成「缩小后的逻辑画布」，让布局
/// 回流填满整屏——效果等同浏览器缩放：所有东西按同一比例一起放大缩小。
///
/// 平台视图（如阅读器 WebView）若要保持原生清晰渲染，用 [HibikiNativeScale] 包裹，
/// 它会对该子树做 1/scale 反向缩放，使净变换回到单位阵。
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
        return Transform.scale(
          scale: s,
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: canvas.width,
            maxWidth: canvas.width,
            minHeight: canvas.height,
            maxHeight: canvas.height,
            child: SizedBox.fromSize(
              size: canvas,
              child: MediaQuery(
                data: _scaleMediaQuery(mq, 1 / s),
                child: scoped,
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

/// 对子树做 1/scale 反向缩放，使其内部平台视图按原生分辨率渲染、命中测试 1:1。
///
/// 用于阅读器 WebView：外层 [HibikiAppUiScale] 把整屏放大了 s 倍，这里再缩 1/s，
/// 净变换为单位阵——WebView 拿到的逻辑视口 = 真实屏幕逻辑尺寸，EPUB 原生清晰。
/// 必须放在有界约束下（如 [Positioned.fill] 内）。
class HibikiNativeScale extends StatelessWidget {
  const HibikiNativeScale({
    required this.child,
    super.key,
  });

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
        final Size region = constraints.biggest;
        final Size native = region * s;
        final MediaQueryData mq = MediaQuery.of(context);
        return Transform.scale(
          scale: 1 / s,
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: native.width,
            maxWidth: native.width,
            minHeight: native.height,
            maxHeight: native.height,
            child: SizedBox.fromSize(
              size: native,
              child: MediaQuery(
                data: _scaleMediaQuery(mq, s),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
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
