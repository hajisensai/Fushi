import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

/// 对话框内容区「装得下就原样、装不下就滚」的外壳（[FushiAlertDialog] 的
/// `scrollable` 不传时默认套上）。
///
/// 为什么不直接 `scrollable: true`：[AlertDialog.scrollable] 把内容放进无界高度的
/// [SingleChildScrollView]，内容里一旦有「吃满剩余高度」的子树（`Expanded` /
/// 不 shrinkWrap 的 `ListView` / `Column(mainAxisSize: max)`）就布局断言。而只给
/// 有界高度时，固定高度的内容（几行输入框）在键盘弹出 / 小窗口里放不下就
/// RenderFlex 溢出——这正是调用点各自手包 `SingleChildScrollView` 的原因。
///
/// 这里按内容的布局行为分两类，判据来自真实布局而不是猜子树类型：
/// - **固定高度**（在更大的上限下高度不变）：按自然高度布局，超出视口就滚，
///   聚焦的输入框经 [RenderObject.showOnScreen] 自动滚进可见区；
/// - **吃满型**（上限放大它就跟着放大）：照旧给视口高度，与不套外壳时逐像素一致。
///
/// 视口高度由外层 [_DialogViewportProbe] 在布局时记下，内层
/// [_RenderDialogFitOrGrow] 隔着 [SingleChildScrollView]（它给子节点无界高度）读取；
/// 视口高度变了由外层在 layout callback 里把内层标脏。整条链只用
/// [SingleChildScrollView] 自带的固有尺寸透传，[AlertDialog] 外层的
/// `IntrinsicWidth` 照常可用（`LayoutBuilder` 不支持固有尺寸，不能用）。
class FushiDialogContentScroll extends StatefulWidget {
  const FushiDialogContentScroll({super.key, required this.child});

  final Widget child;

  @override
  State<FushiDialogContentScroll> createState() =>
      _FushiDialogContentScrollState();
}

class _FushiDialogContentScrollState extends State<FushiDialogContentScroll> {
  final _DialogViewportExtent _extent = _DialogViewportExtent();

  @override
  Widget build(BuildContext context) {
    return _DialogViewportProbe(
      extent: _extent,
      child: SingleChildScrollView(
        // 不接路由外的 PrimaryScrollController（那是底下页面的）。
        primary: false,
        child: _DialogFitOrGrow(
          extent: _extent,
          // 判「吃满型」时放大到的上限：整窗高的若干倍。小窗口里固定内容本来就
          // 可能比窗口高（这正是要滚的情形），上限必须远高于它才分得清；比这还高
          // 的固定内容不是正常的对话框布局。
          probeExtent: MediaQuery.sizeOf(context).height * _kProbeWindowFactor,
          child: widget.child,
        ),
      ),
    );
  }
}

/// 判吃满型时的放大上限 = 整窗高 × 它（见 [_DialogFitOrGrow.probeExtent]）。
const double _kProbeWindowFactor = 4;

/// 外层探针与内层盒共享的视口高度。
class _DialogViewportExtent {
  double height = double.infinity;
  _RenderDialogFitOrGrow? content;
}

class _DialogViewportProbe extends SingleChildRenderObjectWidget {
  const _DialogViewportProbe({required this.extent, super.child});

  final _DialogViewportExtent extent;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDialogViewportProbe(extent);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDialogViewportProbe renderObject,
  ) {
    renderObject.extent = extent;
  }
}

class _RenderDialogViewportProbe extends RenderProxyBox {
  _RenderDialogViewportProbe(this.extent);

  _DialogViewportExtent extent;

  @override
  void performLayout() {
    final double height = constraints.maxHeight;
    if (height != extent.height) {
      extent.height = height;
      final _RenderDialogFitOrGrow? content = extent.content;
      if (content != null) {
        // 内层隔着滚动视口拿到的永远是无界约束，约束不变它不会重排；视口高度
        // 变了在这里显式标脏（layout callback 内允许改本子树）。
        invokeLayoutCallback<BoxConstraints>(
          (BoxConstraints _) => content.markNeedsLayout(),
        );
      }
    }
    super.performLayout();
  }
}

class _DialogFitOrGrow extends SingleChildRenderObjectWidget {
  const _DialogFitOrGrow({
    required this.extent,
    required this.probeExtent,
    super.child,
  });

  final _DialogViewportExtent extent;
  final double probeExtent;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDialogFitOrGrow(extent: extent, probeExtent: probeExtent);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDialogFitOrGrow renderObject,
  ) {
    renderObject
      ..extent = extent
      ..probeExtent = probeExtent;
  }
}

class _RenderDialogFitOrGrow extends RenderProxyBox {
  _RenderDialogFitOrGrow({
    required _DialogViewportExtent extent,
    required double probeExtent,
  }) : _extent = extent,
       _probeExtent = probeExtent;

  /// 高度差小于它算「填满了上限」（布局取整误差）。
  static const double _kFillTolerance = 0.5;

  _DialogViewportExtent _extent;
  set extent(_DialogViewportExtent value) {
    if (identical(value, _extent)) return;
    if (identical(_extent.content, this)) _extent.content = null;
    _extent = value;
    if (attached) _extent.content = this;
    markNeedsLayout();
  }

  double _probeExtent;
  set probeExtent(double value) {
    if (value == _probeExtent) return;
    _probeExtent = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _extent.content = this;
  }

  @override
  void detach() {
    if (identical(_extent.content, this)) _extent.content = null;
    super.detach();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final double viewport = _extent.height;
    if (!viewport.isFinite || constraints.hasBoundedHeight) {
      // 外层本来就无界（调用方 scrollable: true 等）或不在滚动视口里：原样透传。
      child.layout(constraints, parentUsesSize: true);
      size = constraints.constrain(child.size);
      return;
    }
    final BoxConstraints fit = constraints.copyWith(
      maxHeight: math.max(viewport, constraints.minHeight),
    );
    child.layout(fit, parentUsesSize: true);
    if (child.size.height >= fit.maxHeight - _kFillTolerance) {
      // 正好顶满视口：要么是吃满型，要么是固定内容放不下。放大上限再量一次。
      final double probe = math.max(viewport * 2, _probeExtent);
      child.layout(
        constraints.copyWith(maxHeight: probe),
        parentUsesSize: true,
      );
      if (child.size.height >= probe - _kFillTolerance) {
        // 跟着上限一起变大 = 吃满型：回到视口高度，与不套外壳时一致。
        child.layout(fit, parentUsesSize: true);
      }
    }
    size = constraints.constrain(child.size);
  }
}
