import 'package:flutter/widgets.dart';

/// 视频页 push-aside 侧栏列（字幕跳转列表）：列宽在 0 ↔ [width] 之间动画伸缩，
/// 画面列随之被挤窄 / 还原。
///
/// 取代原先的 `AnimatedSize(child: SizedBox(width: open ? w : 0, child: open ? 面板 : null))`，
/// 那个写法有两处问题（BUG-3888 续）：
///
/// - **关闭时面板内容当帧卸载**，`AnimatedSize` 只是把一块空白从 w 收到 0——露出的
///   是页面底色（亮色主题下一条白带）随宽度收缩。这里在收起动画全程保留面板（只是
///   不接指针），动画走完（[AnimationStatus.dismissed]）才卸载。
/// - 子树在动画期间的约束固定为 [width]（[OverflowBox] + [ClipRect] 裁出当前列宽），
///   面板只在开 / 关那一刻 build，动画帧里既不重建也不重新排版。
class VideoPushAsideColumn extends StatefulWidget {
  const VideoPushAsideColumn({
    super.key,
    required this.open,
    required this.width,
    required this.duration,
    required this.builder,
    required this.curve,
  });

  /// 侧栏是否打开（动画目标）。
  final bool open;

  /// 打开后的列宽（含安全区）。面板内容始终按这个宽度排版。
  final double width;

  /// 伸缩时长；为 [Duration.zero] 时（墨水屏 / 减弱动态效果）直接跳到终态。
  final Duration duration;

  final Curve curve;

  /// 面板内容。只在本控件自身 build 时调用（父级重建 / 开关切换），动画帧不调用。
  final WidgetBuilder builder;

  @override
  State<VideoPushAsideColumn> createState() => _VideoPushAsideColumnState();
}

class _VideoPushAsideColumnState extends State<VideoPushAsideColumn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.open ? 1 : 0,
  )..addStatusListener(_onStatus);

  late CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: widget.curve,
  );

  void _onStatus(AnimationStatus status) {
    // 收起走完：把面板卸载（rebuild 一次，走 [build] 的 dismissed 分支）。展开只会
    // 从 [didUpdateWidget] 发起，那之后本来就会 build；其余帧只由 AnimatedBuilder 改列宽。
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(VideoPushAsideColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (oldWidget.curve != widget.curve) {
      _curved.dispose();
      _curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    }
    if (oldWidget.open != widget.open) {
      if (widget.open) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isDismissed) return const SizedBox(width: 0);
    final double width = widget.width;
    final Widget panel = IgnorePointer(
      // 收起中的面板只是视觉残留，不接指针（光标 / 查词 / 拖拽都不该在它上面发生）。
      ignoring: !widget.open,
      child: widget.builder(context),
    );
    return AnimatedBuilder(
      animation: _curved,
      child: panel,
      builder: (BuildContext _, Widget? child) {
        final double columnWidth = width * _curved.value;
        return SizedBox(
          width: columnWidth,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: width,
              maxWidth: width,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
