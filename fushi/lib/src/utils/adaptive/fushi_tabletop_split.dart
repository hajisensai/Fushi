import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/adaptive/fushi_fold_posture.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 桌面姿态（[FushiFoldPosture.tabletop]）下按横向折痕把区域切成上下两块：
/// [top] 放折痕上方，[bottomBuilder] 的内容放折痕下方；其它姿态原样只渲染 [top]。
///
/// 对齐 Android「Make your app fold aware」指南的桌面模式：内容（视频画面）留在
/// 立起来的上半屏，操作控件落到平放的下半屏，折痕本身不放任何内容。
///
/// [top] 用 [GlobalKey] 挂在固定位置，姿态切换只改父级布局不重建它（视频
/// surface、WebView 等重量级子树不会因为合上 / 打开折叠屏被销毁重建）。
///
/// 折痕矩形是**窗口坐标**，本组件不一定铺满窗口（上方可能有标题栏 / 横幅），所以
/// 帧后读一次自身的全局原点换算成本地坐标；原点变化时才重建。
class FushiTabletopSplit extends StatefulWidget {
  const FushiTabletopSplit({
    required this.top,
    required this.bottomBuilder,
    super.key,
    this.enabled = true,
    this.minTopHeight = 120,
    this.minBottomHeight = 96,
  });

  final Widget top;
  final WidgetBuilder bottomBuilder;

  /// false 时恒按平板 / 普通屏处理（例如小窗、画中画、系统接管 chrome 时）。
  final bool enabled;

  /// 折痕上下两块的最小高度；任一块放不下就不切分（折痕贴边的窗口没法用）。
  final double minTopHeight;
  final double minBottomHeight;

  @override
  State<FushiTabletopSplit> createState() => _FushiTabletopSplitState();
}

/// 本地坐标下的切分结果：折痕上沿与折痕高度（逻辑像素）。
@immutable
class FushiTabletopSplitGeometry {
  const FushiTabletopSplitGeometry({
    required this.topHeight,
    required this.hingeHeight,
  });

  final double topHeight;
  final double hingeHeight;

  @override
  bool operator ==(Object other) =>
      other is FushiTabletopSplitGeometry &&
      other.topHeight == topHeight &&
      other.hingeHeight == hingeHeight;

  @override
  int get hashCode => Object.hash(topHeight, hingeHeight);
}

/// 把窗口坐标的折痕换算成区域内的上下切分（纯函数，单测用）。
///
/// [origin] 是区域左上角的窗口坐标，[size] 是区域尺寸。折痕不在区域内、或任一块
/// 低于最小高度时返回 null（不切分）。
FushiTabletopSplitGeometry? resolveFushiTabletopSplit({
  required FushiFoldState fold,
  required Offset origin,
  required Size size,
  double minTopHeight = 120,
  double minBottomHeight = 96,
}) {
  final Rect? hinge = fold.hinge;
  if (!fold.isTabletop || hinge == null) return null;
  final double top = hinge.top - origin.dy;
  final double hingeHeight = hinge.height;
  final double bottom = size.height - top - hingeHeight;
  if (top < minTopHeight || bottom < minBottomHeight) return null;
  return FushiTabletopSplitGeometry(topHeight: top, hingeHeight: hingeHeight);
}

class _FushiTabletopSplitState extends State<FushiTabletopSplit> {
  final GlobalKey _topKey = GlobalKey(debugLabel: 'fushi-tabletop-top');
  Offset _origin = Offset.zero;

  void _scheduleOriginProbe() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final RenderObject? box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      final Offset origin = box.localToGlobal(Offset.zero);
      if (origin != _origin) setState(() => _origin = origin);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget top = KeyedSubtree(key: _topKey, child: widget.top);
    if (!widget.enabled) return top;
    final FushiFoldState fold = FushiFoldState.of(context);
    if (!fold.isTabletop) return top;
    _scheduleOriginProbe();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final FushiTabletopSplitGeometry? split = resolveFushiTabletopSplit(
          fold: fold,
          origin: _origin,
          size: constraints.biggest,
          minTopHeight: widget.minTopHeight,
          minBottomHeight: widget.minBottomHeight,
        );
        if (split == null) return top;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(height: split.topHeight, child: top),
            SizedBox(height: split.hingeHeight),
            Expanded(
              child: _TabletopBottomEntrance(
                child: Builder(builder: widget.bottomBuilder),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 下半屏面板进场：从折痕方向上滑 + 淡入；时长走 [fushiMotionDuration]
/// （墨水屏 / 系统「减弱动态效果」下归零）。
class _TabletopBottomEntrance extends StatelessWidget {
  const _TabletopBottomEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.enter,
      builder: (BuildContext context, double t, Widget? child) {
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * FushiMotion.enterOffset),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
