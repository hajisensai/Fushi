import 'package:flutter/material.dart';

/// 横向滚动行两端的渐隐（M3E：横滑行溢出窗口边缘时柔和淡出，而不是被
/// 一刀切掉，同时暗示「还能横滑」）。
///
/// 用 [ShaderMask] 把左右各 [extent] 的内容按 smoothstep 曲线淡到透明：不改
/// 版面、不接指针。横滑行自带的左右页边距（通常 ≥ [extent]）落在渐隐区里，
/// 停在起点 / 终点时首尾卡片基本不受影响。
class FushiHorizontalEdgeFade extends StatelessWidget {
  const FushiHorizontalEdgeFade({
    required this.child,
    this.extent = 24,
    super.key,
  });

  final Widget child;

  /// 每一侧渐隐的宽度（逻辑 px）。
  final double extent;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) {
        final double width = bounds.width;
        if (width <= extent * 2) {
          return const LinearGradient(
            colors: <Color>[Colors.black, Colors.black],
          ).createShader(bounds);
        }
        final double edge = extent / width;
        return LinearGradient(
          colors: const <Color>[
            Color(0x00000000),
            Color(0x80000000),
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0x80000000),
            Color(0x00000000),
          ],
          stops: <double>[0, edge / 2, edge, 1 - edge, 1 - edge / 2, 1],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}
