import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/utils.dart';

/// 悬浮球停靠的屏幕边。
enum ReaderFloatingBallDock {
  left('left'),
  right('right');

  const ReaderFloatingBallDock(this.id);
  final String id;

  static ReaderFloatingBallDock decode(String raw) =>
      raw == left.id ? left : right;
}

const double kReaderFloatingBallSize = 48;
const double kReaderFloatingBallButtonSize = 40;
const double kReaderFloatingBallGap = 6;
const double kReaderFloatingBallMargin = 8;

/// 收起态整体不透明度：半透明、不抢正文。
const double kReaderFloatingBallIdleOpacity = 0.42;

/// 悬浮球几何：收起 / 展开 / 拖动三态下球与按钮的落点（纯函数，测试直接钉）。
///
/// [viewport] 是阅读正文视口在页面 Stack 里的矩形（已扣掉顶栏 / 底栏 / 系统
/// inset），球永远在其内活动，不会压到 chrome。收起时球向停靠边**外**缩进
/// [tuck]，只露出约 2/3，降低对正文的遮挡；展开时整球回到视口内，按钮在朝向
/// 屏幕中央的半圆弧上环绕球体（包围状），半径随按钮数增长；球靠近视口上下边
/// 时展开态沿边滑到弧能放下的位置，收起再回原位。
class ReaderFloatingBallLayout {
  const ReaderFloatingBallLayout({
    required this.viewport,
    required this.dock,
    required this.verticalFraction,
    required this.actionCount,
    this.ballSize = kReaderFloatingBallSize,
    this.buttonSize = kReaderFloatingBallButtonSize,
    this.gap = kReaderFloatingBallGap,
    this.margin = kReaderFloatingBallMargin,
  });

  final Rect viewport;
  final ReaderFloatingBallDock dock;

  /// 球心在视口高度上的比例 `[0, 1]`（持久化值；越界在这里夹住）。
  final double verticalFraction;
  final int actionCount;
  final double ballSize;
  final double buttonSize;
  final double gap;
  final double margin;

  /// 收起时缩进停靠边外的量。
  double get tuck => ballSize * 0.34;

  /// 停靠边指向屏幕中央的方向：左停靠 +1，右停靠 −1。
  double get inward => dock == ReaderFloatingBallDock.left ? 1 : -1;

  /// 弧半径（球心到按钮中心）：至少让按钮离球一个 gap；按钮多时撑开，保证相邻
  /// 按钮中心的**弦长** 2r·sin(θ/2) ≥ buttonSize + gap（θ = 相邻夹角 π/(n−1)）。
  double get radius {
    final double base = ballSize / 2 + gap + buttonSize / 2;
    if (actionCount <= 1) return base;
    final double halfStep = math.pi / (actionCount - 1) / 2;
    final double byChord = (buttonSize + gap) / (2 * math.sin(halfStep));
    return math.max(base, byChord);
  }

  /// 第 [index] 个按钮在弧上的角度：−π/2（正上）→ +π/2（正下），均分。
  double angleOf(int index) {
    if (actionCount <= 1) return 0;
    return -math.pi / 2 + math.pi * index / (actionCount - 1);
  }

  /// 第 [index] 个按钮中心相对球心的偏移（展开态）。
  Offset buttonOffset(int index) {
    final double a = angleOf(index);
    return Offset(inward * radius * math.cos(a), radius * math.sin(a));
  }

  /// 展开态弧向屏幕中央伸出的距离（从球心量起，到按钮外缘）。
  double get reach => actionCount == 0 ? 0 : radius + buttonSize / 2;

  /// 球的可活动纵向范围（收起态球顶边 top 值）。
  double get minTop => viewport.top + margin;
  double get maxTop => math.max(minTop, viewport.bottom - ballSize - margin);

  /// 收起态球顶边 y（按比例落在活动范围内）。
  double get ballTop {
    final double f = verticalFraction.isFinite
        ? verticalFraction.clamp(0.0, 1.0).toDouble()
        : 0.5;
    return minTop + (maxTop - minTop) * f;
  }

  /// 展开态球顶边 y：弧的上下两端都要落在视口内，不够就沿边滑。
  double get expandedBallTop {
    final double half = math.max(ballSize / 2, reach);
    final double lo = viewport.top + margin + half - ballSize / 2;
    final double hi = viewport.bottom - margin - half - ballSize / 2;
    if (hi < lo) return (lo + hi) / 2;
    return ballTop.clamp(lo, hi).toDouble();
  }

  /// 展开进度 [t]∈[0,1] 下的球顶边 y。
  double ballTopAt(double t) => ballTop + (expandedBallTop - ballTop) * t;

  /// 把任意 top 值反算成持久化比例。
  double fractionForTop(double top) {
    final double span = maxTop - minTop;
    if (span <= 0) return 0.5;
    return ((top - minTop) / span).clamp(0.0, 1.0).toDouble();
  }

  /// 收起态球左边 x：停靠边外缩 [tuck]。
  double get collapsedBallLeft => dock == ReaderFloatingBallDock.left
      ? viewport.left - tuck
      : viewport.right - ballSize + tuck;

  /// 展开态球左边 x：整球回到视口内、贴边留 [margin]。
  double get expandedBallLeft => dock == ReaderFloatingBallDock.left
      ? viewport.left + margin
      : viewport.right - ballSize - margin;

  /// 展开进度 [t]∈[0,1] 下的球左边 x。
  double ballLeftAt(double t) =>
      collapsedBallLeft + (expandedBallLeft - collapsedBallLeft) * t;

  /// 包围盒：以球心为基准，向屏幕中央伸 [reach]、上下各伸 [reach]（不小于
  /// 半球），停靠边一侧只到球边。宽高固定，不随动画变；透明区不吃点击。
  double get halfHeight => math.max(ballSize / 2, reach);
  double get boxHeight => halfHeight * 2;
  double get boxWidth => ballSize / 2 + math.max(ballSize / 2, reach);

  /// 球心在包围盒内的位置。
  Offset get ballCenterInBox => Offset(
    dock == ReaderFloatingBallDock.left
        ? ballSize / 2
        : boxWidth - ballSize / 2,
    halfHeight,
  );

  /// 进度 [t] 下包围盒左上角（球顶边 / 左边经 [ballTopAt] / [ballLeftAt]）。
  Offset boxTopLeftAt(double t) => Offset(
    ballLeftAt(t) + ballSize / 2 - ballCenterInBox.dx,
    ballTopAt(t) + ballSize / 2 - halfHeight,
  );

  /// 松手时按球心落在视口左右哪一半决定停靠边。
  ReaderFloatingBallDock dockForBallLeft(double ballLeft) =>
      ballLeft + ballSize / 2 < viewport.center.dx
      ? ReaderFloatingBallDock.left
      : ReaderFloatingBallDock.right;
}

/// 阅读器悬浮球（球面是 Fushi 图标）。
///
/// 收起：半透明小球停靠在视口左/右边缘（外缩约 1/3），尽量不遮字。点一下：球点亮
/// （主题色描边 + 阴影）并平移回视口内，按钮从球心飞到朝向屏幕中央的半圆弧上
/// 环绕球体（错峰缩放 + 淡入）；再点球收起。拖球可沿边上下挪、也可拖到另一侧
/// 换边，松手吸附到最近边并经 [onDockChanged] 落库。
///
/// 按钮来自阅读器按钮布局的 [ReaderControlSlot.floatingBall] 槽（用户在设置的
/// 布局编辑器里拖），这里只吃现成的 [ReaderHeaderAction]，不知道按钮是什么。
///
/// 返回的是 [Positioned]，**必须**作为页面 Stack 的直接子节点挂载（与底部 chrome
/// 同一约束）；包围盒只覆盖球 + 弧那一块，自带 [RepaintBoundary]（BUG-1692：
/// 整窗图层会让 macOS WebView 收不到鼠标事件）。透明区域不吃点击，正文照常可点。
///
/// 焦点：整层 [ExcludeFocus]——阅读正文是键盘 / 手柄焦点的唯一归宿（TODO-700
/// T8），悬浮球只服务触摸 / 鼠标；键盘用户有顶栏 / 底栏与快捷键。
class ReaderFloatingBall extends StatefulWidget {
  const ReaderFloatingBall({
    required this.viewport,
    required this.actions,
    required this.dock,
    required this.verticalFraction,
    required this.onDockChanged,
    this.backgroundColor,
    this.foregroundColor,
    this.animate = true,
    super.key,
  });

  /// 阅读正文视口在 Stack 坐标系里的矩形（扣掉 chrome / 系统 inset）。
  final Rect viewport;

  /// 展开后环绕球体的按钮（弧上从上到下按此顺序）。
  final List<ReaderHeaderAction> actions;
  final ReaderFloatingBallDock dock;
  final double verticalFraction;

  /// 拖动松手后回调最终停靠边与纵向比例，由页面落库。
  final void Function(ReaderFloatingBallDock dock, double verticalFraction)
  onDockChanged;

  /// 阅读器纸张主题背景 / 前景色；null 回退到 Material 主题。
  final Color? backgroundColor;
  final Color? foregroundColor;

  /// false（墨水屏模式）时所有过渡零时长。
  final bool animate;

  @override
  State<ReaderFloatingBall> createState() => _ReaderFloatingBallState();
}

class _ReaderFloatingBallState extends State<ReaderFloatingBall>
    with SingleTickerProviderStateMixin {
  static const Duration _expandDuration = Duration(milliseconds: 280);
  static const Duration _collapseDuration = Duration(milliseconds: 190);
  static const Duration _snapDuration = Duration(milliseconds: 220);

  late final AnimationController _expand = AnimationController(
    vsync: this,
    duration: widget.animate ? _expandDuration : Duration.zero,
    reverseDuration: widget.animate ? _collapseDuration : Duration.zero,
  );

  late ReaderFloatingBallDock _dock = widget.dock;
  late double _fraction = widget.verticalFraction;

  /// 拖动中：球左上角在 Stack 坐标系里的位置（null = 未在拖）。按手势 delta
  /// 累加，不做全局坐标换算。
  Offset? _dragBallTopLeft;

  bool get _expanded =>
      _expand.status == AnimationStatus.forward ||
      _expand.status == AnimationStatus.completed;

  @override
  void didUpdateWidget(ReaderFloatingBall old) {
    super.didUpdateWidget(old);
    if (old.dock != widget.dock ||
        old.verticalFraction != widget.verticalFraction) {
      // 外部（换书 / 换 profile）重灌持久化值；拖动中不打断手势。
      if (_dragBallTopLeft == null) {
        _dock = widget.dock;
        _fraction = widget.verticalFraction;
      }
    }
    if (old.animate != widget.animate) {
      _expand.duration = widget.animate ? _expandDuration : Duration.zero;
      _expand.reverseDuration = widget.animate
          ? _collapseDuration
          : Duration.zero;
    }
  }

  @override
  void dispose() {
    _expand.dispose();
    super.dispose();
  }

  ReaderFloatingBallLayout _layout() => ReaderFloatingBallLayout(
    viewport: widget.viewport,
    dock: _dock,
    verticalFraction: _fraction,
    actionCount: widget.actions.length,
  );

  void _toggle() {
    if (_expanded) {
      _expand.reverse();
    } else {
      _expand.forward();
    }
  }

  void _onPanStart(ReaderFloatingBallLayout layout) {
    // 拖动一律先收起：按钮跟着球飞没有意义，落点也不好算。
    if (_expanded) _expand.reverse();
    setState(() {
      _dragBallTopLeft = Offset(layout.ballLeftAt(0), layout.ballTop);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final Offset? at = _dragBallTopLeft;
    if (at == null) return;
    setState(() => _dragBallTopLeft = at + d.delta);
  }

  void _onPanEnd(ReaderFloatingBallLayout layout) {
    final Offset? at = _dragBallTopLeft;
    if (at == null) return;
    final ReaderFloatingBallDock dock = layout.dockForBallLeft(at.dx);
    final double fraction = layout.fractionForTop(at.dy);
    setState(() {
      _dragBallTopLeft = null;
      _dock = dock;
      _fraction = fraction;
    });
    widget.onDockChanged(dock, fraction);
  }

  @override
  Widget build(BuildContext context) {
    final ReaderFloatingBallLayout layout = _layout();
    return AnimatedBuilder(
      animation: _expand,
      builder: (BuildContext context, Widget? _) {
        final double t = _expand.value;
        final Offset? drag = _dragBallTopLeft;
        final bool dragging = drag != null;
        // 拖动中：包围盒跟着手指走、只画球；松手后：AnimatedPositioned 吸附到边。
        final Offset boxTopLeft;
        if (dragging) {
          final double top = drag.dy
              .clamp(layout.minTop, layout.maxTop)
              .toDouble();
          boxTopLeft = Offset(
            drag.dx + layout.ballSize / 2 - layout.ballCenterInBox.dx,
            top + layout.ballSize / 2 - layout.halfHeight,
          );
        } else {
          boxTopLeft = layout.boxTopLeftAt(t);
        }
        final Offset ballCenter = layout.ballCenterInBox;
        return AnimatedPositioned(
          duration: dragging || !widget.animate ? Duration.zero : _snapDuration,
          curve: Curves.easeOutCubic,
          left: boxTopLeft.dx,
          top: boxTopLeft.dy,
          width: layout.boxWidth,
          height: layout.boxHeight,
          child: RepaintBoundary(
            child: ExcludeFocus(
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 完全收起（t == 0）或拖动中按钮整个不建：不留零尺寸命中区，
                  // 也不让收起态多画一圈看不见的按钮。
                  if (!dragging && t > 0)
                    for (int i = 0; i < widget.actions.length; i++)
                      _buildArcButton(layout, i, ballCenter),
                  Positioned(
                    left: ballCenter.dx - layout.ballSize / 2,
                    top: ballCenter.dy - layout.ballSize / 2,
                    width: layout.ballSize,
                    height: layout.ballSize,
                    child: _buildBall(layout, progress: t, dragging: dragging),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 弧上第 [index] 颗按钮：从球心飞到弧上落点，错峰（离正上方越远越晚起）。
  Widget _buildArcButton(
    ReaderFloatingBallLayout layout,
    int index,
    Offset ballCenter,
  ) {
    final int n = widget.actions.length;
    // 每颗按钮占总时长里一段错开的区间：起点按序推后、尾部对齐；反向（收起）
    // 沿同一区间反放。
    final double step = n <= 1 ? 0 : 0.35 / (n - 1);
    final double begin = index * step;
    final Interval interval = Interval(
      begin,
      math.min(1, begin + 0.65),
      curve: Curves.easeOutBack,
    );
    final double k = interval.transform(_expand.value);
    final Offset target = layout.buttonOffset(index);
    final Offset center = ballCenter + target * k;
    final double size = layout.buttonSize;
    return Positioned(
      left: center.dx - size / 2,
      top: center.dy - size / 2,
      width: size,
      height: size,
      child: Opacity(
        opacity: k.clamp(0.0, 1.0).toDouble(),
        child: Transform.scale(
          scale: 0.4 + 0.6 * k.clamp(0.0, 1.2),
          child: _ArcButton(
            action: widget.actions[index],
            size: size,
            backgroundColor: widget.backgroundColor,
            foregroundColor: widget.foregroundColor,
          ),
        ),
      ),
    );
  }

  Widget _buildBall(
    ReaderFloatingBallLayout layout, {
    required double progress,
    required bool dragging,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color paperFg = widget.foregroundColor ?? colors.onSurface;
    final double opacity = dragging
        ? 1
        : kReaderFloatingBallIdleOpacity +
              (1 - kReaderFloatingBallIdleOpacity) * progress;
    // 收起：细的前景描边融进正文配色；展开：主题色粗环点亮 + 阴影加深。
    final Color ring = Color.lerp(
      paperFg.withValues(alpha: 0.35),
      colors.primary,
      progress,
    )!;
    return Opacity(
      opacity: opacity,
      child: Semantics(
        button: true,
        label: t.reader_floating_ball,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          onPanStart: (_) => _onPanStart(layout),
          onPanUpdate: _onPanUpdate,
          onPanEnd: (_) => _onPanEnd(layout),
          onPanCancel: () => _onPanEnd(layout),
          child: Tooltip(
            message: t.reader_floating_ball,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ring, width: 1 + 1.5 * progress),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: 0.06 + 0.2 * progress,
                    ),
                    blurRadius: 6 + 8 * progress,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipOval(
                child: Image.asset(
                  kReaderFloatingBallIconAsset,
                  key: const ValueKey<String>(
                    'fushi_reader_floating_ball_icon',
                  ),
                  fit: BoxFit.cover,
                  // 1024² 原图只在 48dp 圆里露脸：按 4× 解码足够，别整帧进缓存。
                  cacheWidth: 192,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 球面贴图：Fushi 应用图标。
const String kReaderFloatingBallIconAsset = 'assets/meta/icon.png';

/// 弧上的一颗圆形按钮：纸张底色 + 前景图标 + 轻阴影，语义与顶栏 / 底栏同一颗
/// [ReaderHeaderAction] 一致。
class _ArcButton extends StatelessWidget {
  const _ArcButton({
    required this.action,
    required this.size,
    this.backgroundColor,
    this.foregroundColor,
  });

  final ReaderHeaderAction action;
  final double size;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color fg = foregroundColor ?? colors.onSurface;
    // 纸张底色上再调 6% 前景色：与正文底色拉开一层，不只靠阴影区分。
    final Color bg = Color.alphaBlend(
      fg.withValues(alpha: 0.06),
      backgroundColor ?? colors.surface,
    );
    return Material(
      key: action.key,
      color: bg,
      shape: const CircleBorder(),
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      clipBehavior: Clip.antiAlias,
      child: Tooltip(
        message: action.label,
        child: Semantics(
          identifier: action.semanticsId,
          button: true,
          child: InkWell(
            onTap: action.onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(action.icon, size: 22, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
