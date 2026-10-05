import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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
/// [tuck]，只露出约 2/3，降低对正文的遮挡；展开时整球回到视口内，按钮在球的
/// **正上方竖排**（第一列与球同一条竖轴），球落在第一列的最下方；列放不下时展开态
/// 把球沿边往下滑到整列能放下的位置，收起再回原位。
///
/// 视口矮到一列装不下全部按钮时（横屏手机：视口高 250～300、槽里放 5～6 颗），
/// 按钮**向屏幕中央方向换列**，保持竖排形态：每列最多 [perColumn] 颗，超出的排
/// 到下一列，列距与竖向间距同为 [pitch]；所有列**底对齐**——每列的最下一颗都与
/// 第一列末颗同高（紧贴球顶那一行），因此列高永远不超过第一列，只要第一列放得
/// 下，后续列就一定放得下。
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

  /// 相邻两颗按钮中心的竖向间距，也是相邻两列的横向间距。
  double get pitch => buttonSize + gap;

  /// 每列最多放几颗：视口扣掉上下 [margin] 与球本身后，球顶以上还剩的高度能
  /// 容纳几个 [pitch]（每颗 = 一个 gap + 一颗按钮）。至少为 1——视口矮到连一颗
  /// 都放不下（极端小视口，高度 < 2·margin + ballSize + pitch = 110）时退化成
  /// 每列一颗、球钉在视口底部，按钮上缘会越出视口；这种尺寸下正文本身已不可读，
  /// 不再为它另设形态。
  int get perColumn {
    final double available = viewport.height - 2 * margin - ballSize;
    if (available.isNaN || available < pitch) return 1;
    if (available.isInfinite) return math.max(1, actionCount);
    // 1e-9 吸收浮点误差：恰好整除时不因 45.999… 少放一颗。
    return math.max(1, (available / pitch + 1e-9).floor());
  }

  /// 展开态的列数（无按钮时为 0）。
  int get columnCount =>
      actionCount <= 0 ? 0 : (actionCount + perColumn - 1) ~/ perColumn;

  /// 最高一列的按钮数（= 第一列的颗数）。
  int get rowCount => math.min(math.max(actionCount, 0), perColumn);

  /// 新列的横向展开方向：朝屏幕中央（左停靠往右 +1，右停靠往左 -1）。
  double get columnDirection => dock == ReaderFloatingBallDock.left ? 1 : -1;

  /// 第 [index] 个按钮中心相对球心的偏移（展开态）。
  ///
  /// 按「离球由近到远」编槽位 `slot = actionCount - 1 - index`（列表末颗离球
  /// 最近，与错峰动画「离球近的先飞出」同序）：先把第一列自下而上填满
  /// [perColumn] 颗，再往中央方向的下一列，同样自下而上。于是一列放得下时
  /// 列表顺序就是从上到下、末颗紧贴球顶（隔一个 gap）、与球同一竖轴——与单列
  /// 形态完全一致。
  Offset buttonOffset(int index) {
    final int slot = actionCount - 1 - index;
    final int column = slot ~/ perColumn;
    final int row = slot % perColumn;
    final double nearest = ballSize / 2 + gap + buttonSize / 2;
    return Offset(columnDirection * column * pitch, -(nearest + row * pitch));
  }

  /// 展开态按钮区从球心向上伸出的距离（到最高一列最上面一颗按钮的上缘）。
  double get reach => actionCount <= 0 ? 0 : ballSize / 2 + rowCount * pitch;

  /// 展开态按钮区从球心向中央方向伸出的横向距离（不小于半球）。
  double get sideReach => columnCount <= 1
      ? ballSize / 2
      : math.max(ballSize / 2, (columnCount - 1) * pitch + buttonSize / 2);

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

  /// 展开态球顶边 y：最高一列的顶端要落在视口内，不够就把球沿边往下滑。按
  /// [perColumn] 换列后列高不超过视口，这里总能放下；只有 [perColumn] 退化成
  /// 1 的极端小视口才会走到 `maxTop < lo`，此时优先保住球（收起入口）在视口底部。
  double get expandedBallTop {
    final double lo = viewport.top + margin + reach - ballSize / 2;
    if (maxTop < lo) return maxTop;
    return ballTop.clamp(lo, maxTop).toDouble();
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

  /// 包围盒：宽 = 停靠边一侧半球 + 中央一侧 [sideReach]（单列时即球径，按钮比
  /// 球细、同轴居中；多列时随列数加宽）；高 = 球心以上 [reach]（不小于半球）+
  /// 下半球。宽高固定，不随动画变；透明区不吃点击。
  double get aboveCenter => math.max(ballSize / 2, reach);
  double get boxHeight => aboveCenter + ballSize / 2;
  double get boxWidth => ballSize / 2 + sideReach;

  /// 球心在包围盒内的位置：盒底、靠停靠边一侧（左停靠贴盒左、右停靠贴盒右）。
  Offset get ballCenterInBox => Offset(
    dock == ReaderFloatingBallDock.left ? ballSize / 2 : sideReach,
    aboveCenter,
  );

  /// 进度 [t] 下包围盒左上角（球顶边 / 左边经 [ballTopAt] / [ballLeftAt]）。
  Offset boxTopLeftAt(double t) => Offset(
    ballLeftAt(t) + ballSize / 2 - ballCenterInBox.dx,
    ballTopAt(t) + ballSize / 2 - ballCenterInBox.dy,
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
/// （主题色描边 + 阴影）并平移回视口内，按钮从球心向上飞出、在球正上方竖排成
/// 一列（错峰缩放 + 淡入，离球近的先起），球在列的最下方；视口太矮一列放不下时
/// 向屏幕中央方向续排第二列（及后续列），见 [ReaderFloatingBallLayout]；再点球收起。拖球可沿边上下挪、也可拖到另一侧
/// 换边，松手吸附到最近边并经 [onDockChanged] 落库。
///
/// 唯一的挂载点是根上的应用内悬浮球宿主（`AppFloatingBallHost`）；按钮由它按
/// 设置 → 悬浮球 里当前场景的勾选给出，这里只吃现成的 [ReaderHeaderAction]，
/// 不知道按钮是什么。
///
/// 返回的是 [Positioned]，**必须**作为页面 Stack 的直接子节点挂载（与底部 chrome
/// 同一约束）；包围盒只覆盖球 + 按钮列那一块，自带 [RepaintBoundary]（BUG-1692：
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

  /// 展开后在球上方竖排的按钮（单列时从上到下按此顺序，末颗紧挨球；换列规则
  /// 见 [ReaderFloatingBallLayout.buttonOffset]）。
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

  /// 松手后正在吸附回边（只有这段位置变化要补间）。
  ///
  /// 旧实现给包围盒的**任何**位置变化都补 220ms：进视频页时沉浸式隐藏系统栏 /
  /// 横竖屏切换让视口一变，球就从中间一路动画回原位（用户 2026-09-30「加载视频，
  /// 会让悬浮球从中间回到刚才的位置」）。视口变化应当直接落位，只有拖动松手的
  /// 吸附是用户想看到的那一下动画。
  bool _snapping = false;

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
      _snapping = widget.animate;
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
            top + layout.ballSize / 2 - layout.ballCenterInBox.dy,
          );
        } else {
          boxTopLeft = layout.boxTopLeftAt(t);
        }
        final Offset ballCenter = layout.ballCenterInBox;
        return AnimatedPositioned(
          duration: _snapping && !dragging ? _snapDuration : Duration.zero,
          curve: FushiSpringCurve.spatial,
          onEnd: () {
            if (_snapping) setState(() => _snapping = false);
          },
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
                      _buildColumnButton(layout, i, ballCenter),
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

  /// 第 [index] 颗按钮：从球心飞到落点，错峰（槽位离球越远越晚起，多列时
  /// 第一列先于后续列）。
  Widget _buildColumnButton(
    ReaderFloatingBallLayout layout,
    int index,
    Offset ballCenter,
  ) {
    final int n = widget.actions.length;
    // 每颗按钮占总时长里一段错开的区间：起点按序推后、尾部对齐；反向（收起）
    // 沿同一区间反放。
    final double step = n <= 1 ? 0 : 0.35 / (n - 1);
    final double begin = (n - 1 - index) * step;
    final Interval interval = Interval(
      begin,
      math.min(1, begin + 0.65),
      curve: FushiSpringCurve.spatialFast,
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
          child: _ColumnButton(
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
          child: FushiTooltip(
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

/// 列中的一颗圆形按钮：纸张底色 + 前景图标 + 轻阴影，语义与顶栏 / 底栏同一颗
/// [ReaderHeaderAction] 一致。
class _ColumnButton extends StatelessWidget {
  const _ColumnButton({
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
    if (isGlassDesign(context)) return _buildGlass(context);
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
      child: FushiTooltip(
        message: action.label,
        child: Semantics(
          identifier: action.semanticsId,
          button: true,
          child: InkWell(
            onTap: action.onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: FushiIcon(action.icon, size: 22, color: fg),
            ),
          ),
        ),
      ),
    );
  }

  /// Apple：浮在正文上的控件层 = 液态玻璃圆钮（iOS 26 悬浮按钮），按下变淡、
  /// 无水波。玻璃填充跟随 app 亮暗（不是纸张色），所以字形取 app 的 label 色，
  /// 而不是纸张前景色——深色 app + 浅色纸张时纸张前景（黑）压在深色玻璃上看不见。
  /// iOS / macOS 的正文是原生 WebView 平台视图，库的着色器路径采不到它的像素，
  /// 走 BackdropFilter 回退（[GlassContainer.platformViewBackdrop]）。
  Widget _buildGlass(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    return SizedBox.square(
      key: action.key,
      dimension: size,
      child: GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        settings: fushiGlassSettingsOverPlatformView(context),
        shape: const LiquidOval(),
        platformViewBackdrop: fushiGlassOverPlatformView(context),
        child: FushiTooltip(
          message: action.label,
          child: Semantics(
            identifier: action.semanticsId,
            button: true,
            child: FushiPlainButton(
              onPressed: action.onPressed,
              borderRadius: BorderRadius.circular(size / 2),
              child: SizedBox.square(
                dimension: size,
                child: FushiIcon(action.icon, size: 22, color: apple.label),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
