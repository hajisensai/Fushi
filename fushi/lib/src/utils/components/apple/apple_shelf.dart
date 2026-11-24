/// Apple（Cupertino，iOS 27 / macOS 27）横滑货架：Apple Music「主页」/ App Store /
/// Apple TV 的一排横滑条目。音乐推荐、游戏首页「最近玩过」等 Apple 布局共用。
///
/// Apple 专用件：只在 `isGlassDesign` 为真时由 Apple 布局调用；M3E 的横滑行由各页
/// 自己的 `ListView` + `HorizontalDragScrollable` 画，两套由页面层按设计系统分派。
/// 本件是布局 + 动效层（滚动物理、翻页箭头淡入），箭头钮本身走共享
/// [FushiIconButtonControl]（自带两套设计系统）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;

/// 横滑货架：懒构建（[ListView.builder] + 定宽 [itemExtent]），左右贴页边起排、
/// 滑出到屏幕边。iOS 档弹性滚动 + 按条吸附（[stride] = 单条宽 + 间距，歌曲分页列
/// 按整列）；macOS 档触控板横扫走原生惯性，鼠标悬停时两端淡入玻璃圆形箭头，点一下
/// 滚一屏、到头淡出。整排随段进场，内部不逐张错峰（Apple Music 不做）。
class AppleShelf extends StatefulWidget {
  const AppleShelf({
    super.key,
    this.horizontalPadding,
    this.arrowKeyPrefix = 'apple-shelf',
    required this.itemCount,
    required this.itemExtent,
    required this.height,
    required this.itemBuilder,
    this.spacing = 12,
    this.arrowCenter,
  });

  final int itemCount;

  /// 单条的宽（不含间距）。
  final double itemExtent;

  /// 货架高（条目的高）。
  final double height;
  final IndexedWidgetBuilder itemBuilder;
  final double spacing;

  /// macOS 箭头的竖直中心（默认货架正中；封面卡给封面中心）。
  final double? arrowCenter;

  /// 左右页边（货架贴着这条线起排、横滑时滑出到屏幕边）：null = 页面令牌的
  /// `spacing.page`；外层列表已留页边时传 0。
  final double? horizontalPadding;

  /// macOS 翻页箭头的 key 前缀（`<前缀>-prev` / `<前缀>-next`，测试按它找）。
  final String arrowKeyPrefix;

  @override
  State<AppleShelf> createState() => _AppleShelfState();
}

class _AppleShelfState extends State<AppleShelf> {
  final ScrollController _controller = ScrollController();
  bool _hovering = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _page(int direction) {
    if (!_controller.hasClients) return;
    final ScrollPosition p = _controller.position;
    final double stride = widget.itemExtent + widget.spacing;
    final double screen = math.max(
      stride,
      (p.viewportDimension / stride).floor() * stride,
    );
    final double target =
        (((p.pixels + direction * screen) / stride).roundToDouble() * stride)
            .clamp(p.minScrollExtent, p.maxScrollExtent);
    final Duration d = fushiMotionDuration(context, FushiMotion.medium);
    if (d == Duration.zero) {
      _controller.jumpTo(target);
    } else {
      unawaited(
        _controller.animateTo(target, duration: d, curve: FushiMotion.standard),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double pad =
        widget.horizontalPadding ?? FushiDesignTokens.of(context).spacing.page;
    final double stride = widget.itemExtent + widget.spacing;
    final Widget list = HorizontalDragScrollable(
      child: ListView.builder(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: EdgeInsets.symmetric(horizontal: pad),
        physics: m.desktop
            ? null
            : _AppleShelfSnapPhysics(
                stride: stride,
                parent: const BouncingScrollPhysics(),
              ),
        itemExtent: stride,
        itemCount: widget.itemCount,
        itemBuilder: (BuildContext context, int i) => Padding(
          padding: EdgeInsetsDirectional.only(end: widget.spacing),
          child: widget.itemBuilder(context, i),
        ),
      ),
    );
    Widget shelf = SizedBox(height: widget.height, child: list);
    if (!m.desktop) return shelf;
    final double center = widget.arrowCenter ?? widget.height / 2;
    final double size = 32 * m.scale;
    Widget arrow(int direction) => ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, Widget? _) {
        final bool can =
            _controller.hasClients &&
            _controller.position.hasContentDimensions &&
            (direction < 0
                ? _controller.position.pixels >
                      _controller.position.minScrollExtent + 1
                : _controller.position.pixels <
                      _controller.position.maxScrollExtent - 1);
        final bool shown = _hovering && can;
        return IgnorePointer(
          ignoring: !shown,
          child: AnimatedOpacity(
            opacity: shown ? 1 : 0,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: SizedBox.square(
              dimension: size,
              child: FushiIconButtonControl.filledTonal(
                key: ValueKey<String>(
                  '${widget.arrowKeyPrefix}-${direction < 0 ? 'prev' : 'next'}',
                ),
                padding: EdgeInsets.zero,
                iconSize: 16 * m.scale,
                onPressed: () => _page(direction),
                icon: FushiIcon(
                  direction < 0
                      ? FushiIcons.chevronLeft
                      : FushiIcons.chevronRight,
                ),
              ),
            ),
          ),
        );
      },
    );
    shelf = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          shelf,
          // 箭头只给鼠标用：键盘 / 手柄在条目间移焦时列表自己滚到焦点处。
          PositionedDirectional(
            start: pad / 2,
            top: center - size / 2,
            child: ExcludeFocus(child: ExcludeSemantics(child: arrow(-1))),
          ),
          PositionedDirectional(
            end: pad / 2,
            top: center - size / 2,
            child: ExcludeFocus(child: ExcludeSemantics(child: arrow(1))),
          ),
        ],
      ),
    );
    return shelf;
  }
}

/// iOS 档货架的按条吸附：松手后按速度外推一段，再落到最近的整条边界
/// （[stride]）。到两端交给父物理（弹性回弹）。
class _AppleShelfSnapPhysics extends ScrollPhysics {
  const _AppleShelfSnapPhysics({required this.stride, super.parent});

  final double stride;

  @override
  _AppleShelfSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _AppleShelfSnapPhysics(stride: stride, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final Tolerance tolerance = toleranceFor(position);
    // 惯性外推约 0.3 秒的位移（与系统减速的手感相近），再取最近的整条。
    final double projected = position.pixels + velocity * 0.3;
    final double target = ((projected / stride).roundToDouble() * stride).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}
