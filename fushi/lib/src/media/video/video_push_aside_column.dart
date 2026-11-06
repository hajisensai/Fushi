import 'package:flutter/widgets.dart';

/// 视频页 push-aside 布局：`Row[画面格, 侧栏列]`，侧栏列宽在 0 ↔ [width] 之间动画伸缩。
///
/// **侧栏列**（BUG-3888 第一段）：取代原先的
/// `AnimatedSize(child: SizedBox(width: open ? w : 0, child: open ? 面板 : null))`——
///
/// - 那个写法**关闭时面板当帧卸载**，`AnimatedSize` 只是把一块空白从 w 收到 0，露出页面
///   底色（亮色主题下一条白带）。这里收起动画全程保留面板（只是不接指针），动画走完
///   （[AnimationStatus.dismissed]）才卸载。
/// - 面板子树在动画期间约束恒为 [width]（[OverflowBox] + [ClipRect] 裁出当前列宽），
///   只在开 / 关那一刻 build，动画帧里既不重建也不重新排版。
///
/// **画面格宽度在动画期间冻结**（BUG-3888 第二段）：动画开始时画面格多宽，整段动画就
/// 按多宽排版，动画结束（含零时长、中途反向后回到原态）才一次性换成新宽度：
///
/// - 展开：画面保持满宽，滑入的面板盖住它右侧那一条（超出画面格的部分被裁掉，命中也
///   不越界）；
/// - 收起：画面保持窄宽，面板滑出后露出的那条由 [gapColor]（= 面板整列底色）填满，
///   不露页面底色。
///
/// 为什么要冻结：Windows（Impeller / ANGLE + 合成器内 HDR 引擎）上，视频外部纹理只要
/// **每帧以不同的尺寸或缩放**绘制，`FlutterCompositorPresentLayers` 就会阻塞
/// 100～500 ms（present 被卡住，raster 编码本身 <50 ms，同期其它线程无事件）。同一套条件
/// （profile、边播边开关、不录 timeline、2864x1766、dpr 2）各 10 次关列表的 maxRaster：
/// 逐帧挤压（修复前）67～319 ms、10/10 超 50 ms；画面宽度不变只裁（本做法）9～42 ms；
/// 宽度不变但用 Transform 逐帧缩放 212～423 ms——触发条件是纹理的绘制尺寸在变，
/// 与布局本身无关。引擎 / 驱动侧具体卡在哪还没坐实（见 docs/bugs 的 BUG-3888），
/// 坐实并修掉之后可以恢复平滑挤压。
///
/// 冻结只针对开 / 关动画本身：窗口尺寸变化（含进出全屏）或面板宽度变化（拖拽把手）
/// 发生在动画途中时，立即放弃冻结、按实际宽度排版。
class VideoPushAsideRow extends StatefulWidget {
  const VideoPushAsideRow({
    super.key,
    required this.open,
    required this.width,
    required this.duration,
    required this.content,
    required this.builder,
    required this.gapColor,
    required this.curve,
  });

  /// 侧栏是否打开（动画目标）。
  final bool open;

  /// 打开后的列宽（含安全区）。面板内容始终按这个宽度排版。
  final double width;

  /// 伸缩时长；为 [Duration.zero] 时（墨水屏 / 减弱动态效果）直接跳到终态。
  final Duration duration;

  final Curve curve;

  /// 画面格（视频 + 它上面的字幕 / 控制条）。
  final Widget content;

  /// 面板内容。只在本控件自身 build 时调用（父级重建 / 开关切换），动画帧不调用。
  final WidgetBuilder builder;

  /// 收起动画里画面（冻结在窄宽）与滑出中的列之间那条的填充色：传面板整列底色，
  /// 看起来就是面板还在原处。
  final Color gapColor;

  @override
  State<VideoPushAsideRow> createState() => _VideoPushAsideRowState();
}

/// 一段开 / 关动画开始时的几何。行宽或面板宽度与它不符（窗口 / 全屏 / 拖拽）就失效。
class _FrozenContent {
  const _FrozenContent({
    required this.contentWidth,
    required this.rowWidth,
    required this.panelWidth,
  });

  final double contentWidth;
  final double rowWidth;
  final double panelWidth;

  bool matches(double row, double panel) =>
      row == rowWidth && panel == panelWidth;
}

class _VideoPushAsideRowState extends State<VideoPushAsideRow>
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

  _FrozenContent? _frozen;

  /// 解冻信号：只让画面格那层 [AnimatedBuilder] 重排，面板不重建。
  final ValueNotifier<int> _unfrozen = ValueNotifier<int>(0);

  /// 最近一次排版时的行宽 / 画面格宽 / 面板宽：开关那一刻据此冻结。
  double? _lastRowWidth;
  double? _lastContentWidth;
  double? _lastPanelWidth;

  void _onStatus(AnimationStatus status) {
    // 动画走完（含中途反向后回到原态）：解冻，画面一次性换成终态宽度。收起走完还要
    // 把面板卸载（rebuild 一次，走 [build] 的 dismissed 分支）；展开走完只通知画面格
    // 重排，不重建面板。其余帧只由 AnimatedBuilder 改列宽。
    if (!mounted) return;
    if (status == AnimationStatus.dismissed) {
      setState(() => _frozen = null);
    } else if (status == AnimationStatus.completed && _frozen != null) {
      _frozen = null;
      _unfrozen.value++;
    }
  }

  @override
  void didUpdateWidget(VideoPushAsideRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (oldWidget.curve != widget.curve) {
      _curved.dispose();
      _curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    }
    if (oldWidget.open != widget.open) {
      // 中途反向：沿用这段动画最初冻结的宽度，回到原态时与它相等，不跳。
      final double? row = _lastRowWidth;
      final double? content = _lastContentWidth;
      final double? panel = _lastPanelWidth;
      if (_frozen == null && row != null && content != null && panel != null) {
        _frozen = _FrozenContent(
          contentWidth: content,
          rowWidth: row,
          panelWidth: panel,
        );
      }
      if (widget.open) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
      // 零时长时上面已同步走到终态（状态回调里解冻）；这里兜一次，避免残留冻结。
      if (!_controller.isAnimating) _frozen = null;
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    _unfrozen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool mountPanel = !_controller.isDismissed;
    final Widget? panel = mountPanel
        ? IgnorePointer(
            // 收起中的面板只是视觉残留，不接指针（光标 / 查词 / 拖拽都不该在它上面发生）。
            ignoring: !widget.open,
            child: widget.builder(context),
          )
        : null;
    final Widget content = widget.content;
    final Widget gap = ColoredBox(color: widget.gapColor);
    return LayoutBuilder(
      builder: (BuildContext _, BoxConstraints constraints) {
        final double rowWidth = constraints.maxWidth;
        final double panelWidth = widget.width;
        return AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[_curved, _unfrozen]),
          builder: (BuildContext _, Widget? __) {
            final double columnWidth = mountPanel
                ? panelWidth * _curved.value
                : 0;
            final double cellWidth = (rowWidth - columnWidth).clamp(
              0.0,
              rowWidth,
            );
            final _FrozenContent? frozen = _frozen;
            double contentWidth = cellWidth;
            if (frozen != null) {
              if (_controller.isAnimating &&
                  frozen.matches(rowWidth, panelWidth)) {
                contentWidth = frozen.contentWidth;
              } else {
                // 窗口 / 全屏 / 拖拽改宽发生在动画途中：按实际宽度，本段动画不再冻结。
                _frozen = null;
              }
            }
            _lastRowWidth = rowWidth;
            _lastContentWidth = contentWidth;
            _lastPanelWidth = panelWidth;
            final bool overflowing = contentWidth > cellWidth;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: cellWidth,
                  // 树形恒定（画面在 Stack 第一个槽里不动）：冻结 / 解冻只改尺寸，
                  // 不重挂画面子树（WebView / 平台视图重挂会重载，见 BUG-3704）。
                  child: Stack(
                    // 展开中画面比格子宽：裁到格子（被面板盖住的那条本来就看不见）；
                    // 平时不裁，保持原先画面格不裁剪的行为。
                    clipBehavior: overflowing ? Clip.hardEdge : Clip.none,
                    children: <Widget>[
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: contentWidth,
                        child: content,
                      ),
                      Positioned(
                        left: contentWidth,
                        top: 0,
                        bottom: 0,
                        width: overflowing ? 0 : cellWidth - contentWidth,
                        child: gap,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: columnWidth,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: panelWidth,
                      maxWidth: panelWidth,
                      child: panel,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
