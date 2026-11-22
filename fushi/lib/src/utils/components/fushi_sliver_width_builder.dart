import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

/// [FushiSliverWidthBuilder] 的 builder：只拿到横轴宽度。
typedef FushiSliverWidthWidgetBuilder =
    Widget Function(BuildContext context, double crossAxisExtent);

/// 只按横轴宽度重建的 [SliverLayoutBuilder]（BUG-5253）。
///
/// [SliverLayoutBuilder] 拿整份 [SliverConstraints] 比较，只要有一项变了就重跑
/// builder；而 `scrollOffset` / `remainingPaintExtent` 等每个滚动帧都在变。网格 /
/// 列表类 sliver 的 builder 又总是交出新的 `SliverGrid` / `SliverList`（builder
/// 委托的 `shouldRebuild` 恒为真），结果视口里每一格都在 UI 线程上逐帧重新 build。
///
/// 本组件的 layout 信息只取 [SliverConstraints.crossAxisExtent]：builder 只在下列
/// 情况重跑——首次布局、横轴宽度变了、本 widget 被父级换成新实例、builder 里
/// 依赖的 InheritedWidget 变了（框架照常追踪 builder `context` 上的依赖）。只滚动
/// 时原样保留上次交出的子树。
///
/// 只在 builder **只**依赖横轴宽度时用；还要看主轴余量、滚动位置等的照旧用
/// [SliverLayoutBuilder]。
class FushiSliverWidthBuilder extends AbstractLayoutBuilder<double> {
  const FushiSliverWidthBuilder({required this.builder, super.key});

  @override
  final FushiSliverWidthWidgetBuilder builder;

  @override
  RenderAbstractLayoutBuilderMixin<double, RenderSliver> createRenderObject(
    BuildContext context,
  ) => _RenderFushiSliverWidthBuilder();
}

/// 与 SDK `_RenderSliverLayoutBuilder` 同一套布局 / 绘制 / 命中，只把
/// [layoutInfo] 收窄成横轴宽度。
class _RenderFushiSliverWidthBuilder extends RenderSliver
    with
        RenderObjectWithChildMixin<RenderSliver>,
        RenderObjectWithLayoutCallbackMixin,
        RenderAbstractLayoutBuilderMixin<double, RenderSliver> {
  @override
  double get layoutInfo => constraints.crossAxisExtent;

  @override
  double childMainAxisPosition(RenderObject child) {
    assert(child == this.child);
    return 0;
  }

  @override
  void performLayout() {
    runLayoutCallback();
    child?.layout(constraints, parentUsesSize: true);
    geometry = child?.geometry ?? SliverGeometry.zero;
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    assert(child == this.child);
    // 子节点偏移恒为 (0, 0)，不改 transform。
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child?.geometry?.visible ?? false) {
      context.paintChild(child!, offset);
    }
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    final RenderSliver? sliver = child;
    return sliver != null &&
        sliver.geometry!.hitTestExtent > 0 &&
        sliver.hitTest(
          result,
          mainAxisPosition: mainAxisPosition,
          crossAxisPosition: crossAxisPosition,
        );
  }
}
