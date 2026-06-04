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
