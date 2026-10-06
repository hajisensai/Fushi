import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_color_roles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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

/// 球本体的 M3E FAB 形状：收起是圆角方块（FAB 56/16 按 48 等比 ≈ 14），展开
/// 变形成正圆关闭钮（FAB menu 的 close button）。
const double kReaderFloatingBallCollapsedRadius = 14;

/// 单列时按钮旁标签胶囊：与按钮的间距、高度、最大宽度（含内边距）。
const double kReaderFloatingBallLabelGap = 8;
const double kReaderFloatingBallLabelHeight = 32;
const double kReaderFloatingBallLabelMaxWidth = 200;
const double kReaderFloatingBallLabelPadding = 12;

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
    this.labelReach = 0,
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

  /// 单列时按钮旁标签胶囊的最大宽度（含内边距）；0 = 不显示标签。多列时标签会
  /// 压到相邻列上，一律不显示（[showsLabels]）。
  final double labelReach;

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

  /// 展开态按钮旁是否显示标签胶囊（M3E FAB menu 的「圆钮 + 标签」）。
  bool get showsLabels => labelReach > 0 && columnCount == 1;

  /// 标签胶囊从球心向中央方向伸出的横向距离（不显示标签时为 0）。
  double get labelExtent => showsLabels
      ? buttonSize / 2 + kReaderFloatingBallLabelGap + labelReach
      : 0;

  /// 展开态按钮区从球心向中央方向伸出的横向距离（不小于半球；单列带标签时
  /// 包住最宽的标签胶囊）。
  double get sideReach => columnCount <= 1
      ? math.max(ballSize / 2, labelExtent)
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

/// 阅读器 / 应用内悬浮球（M3 Expressive FAB menu 形态）。
///
/// 收起：半透明的 primaryContainer 圆角方块 FAB（球面是 Fushi 吉祥物）停靠在视口
/// 左/右边缘（外缩约 1/3），尽量不遮字。点一下：球平移回视口内、阴影加深，并像
/// M3E FAB menu 的开合钮一样**变形**成 primary 正圆关闭钮（吉祥物旋出、关闭图标
/// 旋入）；按钮（secondaryContainer tonal 小圆钮）从球心向上按 spring 错峰飞出、
/// 在球正上方竖排成一列，单列时每颗旁边带标签胶囊；视口太矮一列放不下时向屏幕
/// 中央方向续排第二列（及后续列，不带标签），见 [ReaderFloatingBallLayout]；再点
/// 球收起。拖球可沿边上下挪、也可拖到另一侧换边，松手吸附到最近边并经
/// [onDockChanged] 落库。
///
/// 颜色全部取当前主题 [ColorScheme]（随预设 / 明暗 / 纯黑变化）；Apple 设计系统
/// 是液态玻璃圆球与圆钮；墨水屏降级为描边、无填色、无阴影、无动画。
///
/// 唯一的挂载点是根上的应用内悬浮球宿主（`AppFloatingBallHost`）；按钮由它按
/// 设置 → 悬浮球 里当前场景的勾选给出，这里只吃现成的 [ReaderHeaderAction]，
/// 不知道按钮是什么。
///
/// 返回的是 [Positioned]，**必须**作为页面 Stack 的直接子节点挂载（与底部 chrome
/// 同一约束）；包围盒只覆盖球 + 按钮列那一块，自带 [RepaintBoundary]（BUG-1692：
/// 整窗图层会让 macOS WebView 收不到鼠标事件）。透明区域不吃点击，正文照常可点。
///
/// 焦点：收起态整层 [ExcludeFocus]——阅读正文是键盘 / 手柄焦点的唯一归宿
/// （TODO-700 T8），收起的球不进遍历、不抢焦点。展开后按钮进入焦点遍历（一个
/// [FocusTraversalGroup]，方向键 / Tab / 手柄可在按钮间移动）；键盘操作下展开时
/// 焦点落到离球最近的按钮，Esc / 手柄 B 收起并把焦点还给展开前的持有者。
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

  /// 旧接口：阅读器纸张主题背景 / 前景色。M3E 版只认当前主题 [ColorScheme]
  /// （用户 2026-10-06「悬浮球按钮适配主题色」），这两个参数不再参与配色，
  /// 保留只为不破坏调用方。
  final Color? backgroundColor;
  final Color? foregroundColor;

  /// false（墨水屏模式）时所有过渡零时长。
  final bool animate;

  @override
  State<ReaderFloatingBall> createState() => _ReaderFloatingBallState();
}

class _ReaderFloatingBallState extends State<ReaderFloatingBall>
    with SingleTickerProviderStateMixin {
  // 与原生系统球同一组时长（Android FloatingBallService / Windows / macOS
  // 的 EXPAND / COLLAPSE / SNAP）；曲线是 M3E spatial 弹簧。
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

  /// 按钮的焦点节点（与 [ReaderFloatingBall.actions] 一一对应）。
  final List<FocusNode> _itemFocus = <FocusNode>[];

  /// 键盘展开前的焦点持有者：收起时把焦点还给它。
  FocusNode? _restoreFocus;

  /// 单列时标签胶囊的宽度（与 actions 一一对应，含内边距）；空 = 不显示标签。
  List<double> _labelWidths = const <double>[];

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
    for (final FocusNode node in _itemFocus) {
      node.dispose();
    }
    super.dispose();
  }

  void _syncFocusNodes() {
    while (_itemFocus.length < widget.actions.length) {
      _itemFocus.add(
        FocusNode(debugLabel: 'ReaderFloatingBall.item${_itemFocus.length}'),
      );
    }
    while (_itemFocus.length > widget.actions.length) {
      _itemFocus.removeLast().dispose();
    }
  }

  ReaderFloatingBallLayout _layout() => ReaderFloatingBallLayout(
    viewport: widget.viewport,
    dock: _dock,
    verticalFraction: _fraction,
    actionCount: widget.actions.length,
    labelReach: _labelWidths.isEmpty
        ? 0
        : _labelWidths.reduce((double a, double b) => math.max(a, b)),
  );

  void _toggle() {
    if (_expanded) {
      _collapse();
    } else {
      _open();
    }
  }

  void _open() {
    if (_expanded) return;
    _expand.forward();
    // 键盘 / 手柄在用（traditional 高亮模式）：焦点进离球最近的按钮，可以直接
    // 方向键遍历；触摸 / 鼠标展开不动焦点，正文照旧持有键盘。
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) {
      return;
    }
    _restoreFocus = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_expanded || _itemFocus.isEmpty) return;
      _itemFocus.last.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _collapse() {
    if (!_expanded) return;
    final bool ownsFocus = _itemFocus.any((FocusNode node) => node.hasFocus);
    _expand.reverse();
    final FocusNode? back = _restoreFocus;
    _restoreFocus = null;
    if (!ownsFocus) return;
    if (back != null && back.context != null && back.canRequestFocus) {
      back.requestFocus();
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  void _onPanStart(ReaderFloatingBallLayout layout) {
    // 拖动一律先收起：按钮跟着球飞没有意义，落点也不好算。
    if (_expanded) _collapse();
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

  /// 标签文字样式（M3E label large；颜色由胶囊给）。
  TextStyle _labelStyle(BuildContext context) => context.fushiType.labelLarge;

  /// 单列时每颗按钮的标签胶囊宽度；多列 / 视口太窄 / 没有按钮时返回空表。
  List<double> _measureLabels(BuildContext context) {
    final int n = widget.actions.length;
    if (n == 0) return const <double>[];
    // 先按无标签几何判列数：多列时标签会压到相邻列，不显示。
    final ReaderFloatingBallLayout bare = ReaderFloatingBallLayout(
      viewport: widget.viewport,
      dock: _dock,
      verticalFraction: _fraction,
      actionCount: n,
    );
    if (bare.columnCount != 1) return const <double>[];
    final double available =
        widget.viewport.width -
        2 * bare.margin -
        bare.buttonSize -
        kReaderFloatingBallLabelGap;
    final double cap = math.min(kReaderFloatingBallLabelMaxWidth, available);
    // 连一颗短标签都放不下（极窄窗口）：只留圆钮。
    if (cap < 2 * kReaderFloatingBallLabelPadding + 24) {
      return const <double>[];
    }
    final TextStyle style = _labelStyle(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection direction = Directionality.of(context);
    final List<double> widths = <double>[];
    for (final ReaderHeaderAction action in widget.actions) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: action.label, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final double width = painter.width;
      painter.dispose();
      widths.add(
        math.min(
          cap,
          (width + 2 * kReaderFloatingBallLabelPadding).ceilToDouble(),
        ),
      );
    }
    return widths;
  }

  @override
  Widget build(BuildContext context) {
    _syncFocusNodes();
    _labelWidths = _measureLabels(context);
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
        final bool menuLive = !dragging && t > 0;
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
              excluding: !(menuLive && _expanded),
              child: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.escape): _collapse,
                  const SingleActivator(LogicalKeyboardKey.gameButtonB):
                      _collapse,
                },
                child: FocusTraversalGroup(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      // 完全收起（t == 0）或拖动中按钮整个不建：不留零尺寸命中区，
                      // 也不让收起态多画一圈看不见的按钮。
                      if (menuLive && layout.showsLabels)
                        for (int i = 0; i < _labelWidths.length; i++)
                          _buildLabel(layout, i, ballCenter),
                      if (menuLive)
                        for (int i = 0; i < widget.actions.length; i++)
                          _buildColumnButton(layout, i, ballCenter),
                      Positioned(
                        left: ballCenter.dx - layout.ballSize / 2,
                        top: ballCenter.dy - layout.ballSize / 2,
                        width: layout.ballSize,
                        height: layout.ballSize,
                        child: _buildBall(
                          layout,
                          progress: t,
                          dragging: dragging,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 第 [index] 颗按钮的错峰进度：每颗按钮占总时长里一段错开的区间，起点按
  /// 槽位离球由近到远推后、尾部对齐；反向（收起）沿同一区间反放。弹簧曲线会
  /// 过冲（> 1），位移 / 缩放用原值，透明度截在 0..1。
  double _stagger(int index) {
    final int n = widget.actions.length;
    final double step = n <= 1 ? 0 : 0.35 / (n - 1);
    final double begin = (n - 1 - index) * step;
    final Interval interval = Interval(
      begin,
      math.min(1, begin + 0.65),
      curve: FushiSpringCurve.spatialFast,
    );
    return interval.transform(_expand.value);
  }

  /// 第 [index] 颗按钮：从球心飞到落点，错峰（槽位离球越远越晚起，多列时
  /// 第一列先于后续列）。
  Widget _buildColumnButton(
    ReaderFloatingBallLayout layout,
    int index,
    Offset ballCenter,
  ) {
    final double k = _stagger(index);
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
            focusNode: _itemFocus[index],
          ),
        ),
      ),
    );
  }

  /// 第 [index] 颗按钮旁的标签胶囊（单列才有）：贴在按钮朝屏幕中央的一侧，与
  /// 按钮同一个错峰进度，从按钮那一侧横向弹出。点标签 = 点按钮。
  Widget _buildLabel(
    ReaderFloatingBallLayout layout,
    int index,
    Offset ballCenter,
  ) {
    final double k = _stagger(index);
    final Offset target = layout.buttonOffset(index);
    final Offset center = ballCenter + target * k;
    final double width = _labelWidths[index];
    const double height = kReaderFloatingBallLabelHeight;
    final bool towardRight = layout.dock == ReaderFloatingBallDock.left;
    final double near = layout.buttonSize / 2 + kReaderFloatingBallLabelGap;
    final double left = towardRight
        ? center.dx + near
        : center.dx - near - width;
    final ReaderHeaderAction action = widget.actions[index];
    return Positioned(
      left: left,
      top: center.dy - height / 2,
      width: width,
      height: height,
      child: Opacity(
        opacity: k.clamp(0.0, 1.0).toDouble(),
        child: Transform.scale(
          scale: 0.6 + 0.4 * k.clamp(0.0, 1.2),
          alignment: towardRight ? Alignment.centerLeft : Alignment.centerRight,
          // 无障碍名已由按钮本身给出，标签只是同一个动作的第二个点击面。
          child: ExcludeSemantics(
            child: _LabelCapsule(
              label: action.label,
              style: _labelStyle(context),
              onPressed: action.onPressed,
            ),
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
    final double opacity = dragging
        ? 1
        : kReaderFloatingBallIdleOpacity +
              (1 - kReaderFloatingBallIdleOpacity) * progress;
    return Opacity(
      opacity: opacity,
      child: Semantics(
        button: true,
        expanded: _expanded,
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
            child: _BallFace(
              size: layout.ballSize,
              progress: progress,
              dragging: dragging,
              eink: !widget.animate,
            ),
          ),
        ),
      ),
    );
  }
}

/// 球面贴图：Fushi 吉祥物（透明底前景，与启动页同一张），叠在主题色 FAB 上。
const String kReaderFloatingBallIconAsset = 'assets/meta/splash_foreground.png';

/// 吉祥物在球里的放大倍数：原图 432² 里吉祥物只占中间约一半，放大后宽约占球
/// 径的 80%。原生系统球（Android / 桌面球面 PNG）用同一个值。
const double kReaderFloatingBallMascotScale = 1.55;

/// 球本体：M3E FAB。
///
/// - Material：primaryContainer 圆角方块 + 吉祥物 → 展开变形为 primary 正圆 +
///   关闭图标（形状 / 颜色走 spatial 弹簧，吉祥物与图标旋转交叉淡入），阴影按
///   M3E elevation level 1 → 3；
/// - Apple：液态玻璃圆球（不做形变），吉祥物 → label 色关闭图标；
/// - 墨水屏：surface 底 + onSurface 描边，无阴影。
class _BallFace extends StatelessWidget {
  const _BallFace({
    required this.size,
    required this.progress,
    required this.dragging,
    required this.eink,
  });

  final double size;
  final double progress;
  final bool dragging;
  final bool eink;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final bool einkMode = eink || isEinkTheme(context);
    // 形变走 spatial 弹簧（可轻微过冲）；颜色 / 透明度截在 0..1。
    final double s = FushiSpringCurve.spatial.transform(
      progress.clamp(0.0, 1.0).toDouble(),
    );
    final double c = s.clamp(0.0, 1.0).toDouble();

    final Color closeColor;
    final Widget surface;
    if (apple) {
      closeColor = appleColorsOf(context).label;
      surface = GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        settings: fushiGlassSettingsOverPlatformView(context),
        shape: const LiquidOval(),
        platformViewBackdrop: fushiGlassOverPlatformView(context),
        child: SizedBox.square(dimension: size),
      );
    } else {
      final Color container = einkMode
          ? cs.surface
          : Color.lerp(cs.primaryContainer, cs.primary, c)!;
      closeColor = einkMode
          ? cs.onSurface
          : Color.lerp(cs.onPrimaryContainer, cs.onPrimary, c)!;
      final double radius =
          (kReaderFloatingBallCollapsedRadius +
                  (size / 2 - kReaderFloatingBallCollapsedRadius) * s)
              .clamp(0.0, size / 2)
              .toDouble();
      surface = Material(
        color: container,
        shadowColor: cs.shadow,
        // M3E elevation：收起 level 1、展开 / 拖动 level 3。
        elevation: einkMode ? 0 : (dragging ? 6 : 1 + 5 * c),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: einkMode
              ? BorderSide(color: cs.onSurface, width: 1.5)
              : BorderSide.none,
        ),
        child: SizedBox.square(dimension: size),
      );
    }

    return SizedBox.square(
      key: const ValueKey<String>('fushi_reader_floating_ball_icon'),
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          surface,
          // 吉祥物：收起态的球面；展开时旋出淡出（仍建着，拖动 / 点击命中不变）。
          IgnorePointer(
            child: Opacity(
              opacity: 1 - c,
              child: Transform.rotate(
                angle: c * math.pi / 2,
                child: ClipOval(
                  child: Transform.scale(
                    scale: kReaderFloatingBallMascotScale,
                    child: Image.asset(
                      kReaderFloatingBallIconAsset,
                      fit: BoxFit.contain,
                      // 432² 原图只在 48dp 球里露脸：按 4× 解码足够，别整帧进缓存。
                      cacheWidth: 192,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (c > 0)
            IgnorePointer(
              child: Opacity(
                opacity: c,
                child: Transform.rotate(
                  angle: (c - 1) * math.pi / 2,
                  child: Center(
                    child: FushiIcon(
                      FushiIcons.close,
                      size: 22,
                      color: closeColor,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 列中的一颗按钮：M3E tonal 小圆钮（secondaryContainer + onSecondaryContainer
/// 图标、level 1 阴影、按下 / 悬停 / 聚焦状态层、按下 spring 缩放），语义与
/// 顶栏 / 底栏同一颗 [ReaderHeaderAction] 一致。墨水屏：surface 底 + 描边、
/// 无阴影。
class _ColumnButton extends StatelessWidget {
  const _ColumnButton({
    required this.action,
    required this.size,
    required this.focusNode,
  });

  final ReaderHeaderAction action;
  final double size;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color bg = eink ? cs.surface : cs.secondaryContainer;
    final Color fg = eink ? cs.onSurface : cs.onSecondaryContainer;
    return FushiPressScale(
      enabled: !eink,
      child: Material(
        key: action.key,
        color: bg,
        shape: CircleBorder(
          side: eink
              ? BorderSide(color: cs.onSurface, width: 1.5)
              : BorderSide.none,
        ),
        elevation: eink ? 0 : 1,
        shadowColor: cs.shadow,
        clipBehavior: Clip.antiAlias,
        child: FushiTooltip(
          message: action.tooltipText,
          child: Semantics(
            identifier: action.semanticsId,
            button: true,
            child: InkWell(
              focusNode: focusNode,
              onTap: action.onPressed,
              overlayColor: FushiStateLayer.overlay(fg),
              child: SizedBox(
                width: size,
                height: size,
                child: FushiIcon(action.icon, size: 22, color: fg),
              ),
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
          message: action.tooltipText,
          child: Semantics(
            identifier: action.semanticsId,
            button: true,
            child: FushiPlainButton(
              onPressed: action.onPressed,
              focusNode: focusNode,
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

/// 按钮旁的标签胶囊（M3E FAB menu 的文字面）：Material 是 secondaryContainer
/// 全圆角胶囊 + labelLarge；Apple 是液态玻璃胶囊 + label 色文字；墨水屏是描边
/// 胶囊。点胶囊 = 点同一颗按钮（不参与焦点遍历，焦点只在圆钮上）。
class _LabelCapsule extends StatelessWidget {
  const _LabelCapsule({
    required this.label,
    required this.style,
    required this.onPressed,
  });

  final String label;
  final TextStyle style;
  final VoidCallback? onPressed;

  Widget _text(Color color) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: kReaderFloatingBallLabelPadding,
    ),
    child: Center(
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: style.copyWith(color: color),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      final FushiAppleColors apple = appleColorsOf(context);
      return GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        settings: fushiGlassSettingsOverPlatformView(context),
        shape: const LiquidRoundedSuperellipse(borderRadius: 999),
        platformViewBackdrop: fushiGlassOverPlatformView(context),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: _text(apple.label),
        ),
      );
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    return Material(
      color: eink ? cs.surface : cs.secondaryContainer,
      shape: StadiumBorder(
        side: eink
            ? BorderSide(color: cs.onSurface, width: 1.5)
            : BorderSide.none,
      ),
      elevation: eink ? 0 : 1,
      shadowColor: cs.shadow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: _text(eink ? cs.onSurface : cs.onSecondaryContainer),
      ),
    );
  }
}
