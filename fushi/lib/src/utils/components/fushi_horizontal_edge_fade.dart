import 'package:material_ui/material_ui.dart';

/// 横向滚动行两端的渐隐（M3E：横滑行溢出窗口边缘时柔和淡出，而不是被
/// 一刀切掉，同时暗示「还能横滑」）。
///
/// 只在**真的还有内容**的那一侧淡：读子树里横向滚动视图的 [ScrollMetrics]——
/// `extentBefore > 0` 才淡左端，`extentAfter > 0` 才淡右端。没溢出、停在起点 /
/// 终点时首尾项完整可见，不会被渐隐吃掉一截（HBK-AUDIT-019：原先恒定淡掉两端，
/// 筛选行的第一枚 chip 一进页就是半透明的）。
///
/// 用 [ShaderMask] 实现：不改版面、不接指针。只认直属（depth 0）、方向为
/// [axis] 的滚动。[axis] 传 [Axis.vertical] 时淡的是上 / 下两端（对话框里定高
/// 滚动列表溢出时柔和淡出，而不是被硬切一刀）。
class FushiHorizontalEdgeFade extends StatefulWidget {
  const FushiHorizontalEdgeFade({
    required this.child,
    this.extent = 24,
    this.axis = Axis.horizontal,
    super.key,
  });

  final Widget child;

  /// 跟踪并渐隐的滚动方向。
  final Axis axis;

  /// 每一侧渐隐的宽度（逻辑 px）。
  final double extent;

  @override
  State<FushiHorizontalEdgeFade> createState() =>
      _FushiHorizontalEdgeFadeState();
}

class _FushiHorizontalEdgeFadeState extends State<FushiHorizontalEdgeFade> {
  bool _fadeStart = false;
  bool _fadeEnd = false;

  bool _track(ScrollMetrics metrics, int depth) {
    if (depth != 0 || metrics.axis != widget.axis) return false;
    final bool start = metrics.extentBefore > 0.5;
    final bool end = metrics.extentAfter > 0.5;
    if (start != _fadeStart || end != _fadeEnd) {
      // 指标通知可能在布局阶段发出（首帧 / 内容变宽）：本帧末再改。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (start == _fadeStart && end == _fadeEnd) return;
        setState(() {
          _fadeStart = start;
          _fadeEnd = end;
        });
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bool vertical = widget.axis == Axis.vertical;
    final bool rtl =
        !vertical && Directionality.of(context) == TextDirection.rtl;
    // 「起点 / 终点」是滚动方向上的，RTL 下起点在右边。
    final bool fadeLeft = rtl ? _fadeEnd : _fadeStart;
    final bool fadeRight = rtl ? _fadeStart : _fadeEnd;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (ScrollMetricsNotification n) =>
          _track(n.metrics, n.depth),
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification n) => _track(n.metrics, n.depth),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect bounds) {
            final double width = vertical ? bounds.height : bounds.width;
            if ((!fadeLeft && !fadeRight) || width <= widget.extent * 2) {
              return const LinearGradient(
                colors: <Color>[Colors.black, Colors.black],
              ).createShader(bounds);
            }
            final double edge = widget.extent / width;
            return LinearGradient(
              begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
              end: vertical ? Alignment.bottomCenter : Alignment.centerRight,
              colors: <Color>[
                fadeLeft ? const Color(0x00000000) : const Color(0xFF000000),
                fadeLeft ? const Color(0x80000000) : const Color(0xFF000000),
                const Color(0xFF000000),
                const Color(0xFF000000),
                fadeRight ? const Color(0x80000000) : const Color(0xFF000000),
                fadeRight ? const Color(0x00000000) : const Color(0xFF000000),
              ],
              stops: <double>[0, edge / 2, edge, 1 - edge, 1 - edge / 2, 1],
            ).createShader(bounds);
          },
          child: widget.child,
        ),
      ),
    );
  }
}
