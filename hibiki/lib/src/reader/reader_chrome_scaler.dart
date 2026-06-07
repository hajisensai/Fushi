import 'package:flutter/widgets.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

/// 阅读器底栏铬层的「隐形」界面缩放。
///
/// 阅读器整页被 [HibikiAppUiScaleNeutralizer] 中和回 scale=1.0（保证 WebView 原生
/// 清晰、划词弹窗/高亮坐标与 WebView 一致）。底栏是 Stack 里独立的 Positioned 兄弟
/// 层，**不参与 WebView 选区坐标**，可单独按用户「界面大小」放大而不触碰中和铁律。
///
/// 给定自然高度 [baseHeight] 的内容，输出一个高度 `baseHeight*scale`、占满父级宽度、
/// 整体均匀缩放的盒子（图标/文字一起放大，不是只拉高留白）。`scale==1` 时零开销直通。
///
/// **关键**：[scaledHeight] 必须与底栏喂给 WebView/光标/焦点环的底部预留用同一个值，
/// 否则视觉高度与预留高度错位 → 正文被底栏盖住或光标错位。
class ReaderChromeScaler extends StatelessWidget {
  const ReaderChromeScaler({
    required this.scale,
    required this.baseHeight,
    required this.child,
    super.key,
  });

  final double scale;
  final double baseHeight;
  final Widget child;

  /// 缩放后底栏在屏占用的高度（喂给 WebView/光标/焦点环的底部预留必须取此值）。
  static double scaledHeight(double baseHeight, double scale) =>
      baseHeight * HibikiAppUiScale.normalize(scale);

  @override
  Widget build(BuildContext context) {
    final double s = HibikiAppUiScale.normalize(scale);
    if (s == HibikiAppUiScale.defaultScale) return child;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth) return child;
        final double w = constraints.maxWidth;
        // 把自然尺寸内容铺在 (w/s) × baseHeight 的逻辑画布上，再用 FittedBox.fill
        // 装进 w × (baseHeight*s) 的盒子：x 缩放 = w/(w/s) = s，y 缩放 =
        // (baseHeight*s)/baseHeight = s，均匀放大且占满宽度、绝不横向溢出。
        return SizedBox(
          width: w,
          height: baseHeight * s,
          child: FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: w / s,
              height: baseHeight,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
