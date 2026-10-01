import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 视频内顶栏的槽标识，见 [VideoTopBarSlots]。
///
/// 左右按钮组各拆成 `lead` / `tail` 两段：标题项被用户拖进按钮槽时，它在该槽里的
/// **索引位置**是有语义的（`VideoControlLayout` 会保序），所以标题要能夹在两段按钮
/// 之间显示 —— 但它的**宽度**必须最后才分，不能跟按钮抢。
enum VideoTopBarSlotId { leftLead, leftTail, title, rightLead, rightTail }

/// 标题落在顶栏的哪一段（决定它夹在哪两段按钮之间）。
///
/// 标题项是单实例（`VideoControlItem.isSingleInstance`），整条顶栏最多一个，所以
/// 一个枚举就够描述它的位置。
enum VideoTopBarTitlePlacement {
  /// 夹在 topLeft 组的 lead / tail 两段之间。
  left,

  /// 左右两组按钮之间的中段（默认的 topCenter）。
  center,

  /// 夹在 topRight 组的 lead / tail 两段之间。
  right,
}

/// 按钮组要渲染同一个槽里标题**之前**还是**之后**的那段按钮。
enum VideoTopBarSegment {
  /// 标题之前的按钮（槽里没有标题时就是整组）。
  lead,

  /// 标题之后的按钮（槽里没有标题时为空）。
  tail,
}

/// 四段按钮的分宽：**先保底、再按优先级补足**。
///
/// [floors] 是各段不裁切的最窄宽（`VideoControlBar` 全部收进「⋯」后的宽，见其
/// `computeMinIntrinsicWidth`），[wants] 是各段原样摆下所需的宽；顺序即优先级
/// （leftLead → leftTail → rightLead → rightTail）。
///
/// ① 按优先级逐段先给保底；② 剩下的再按优先级逐段补到 `want`。于是左组按钮再多，
/// 也只能在右组保住「⋯」之后才去吃剩余宽——右组不会再被挤成半个「⋯」或整组消失
/// （BUG-2832 审查）。所有保底加起来都放不下时（真·极窄），第①步按优先级截断，
/// 退化为纯优先级分配，与旧行为一致。
List<double> allocateVideoTopBarButtonWidths({
  required List<double> floors,
  required List<double> wants,
  required double width,
}) {
  assert(floors.length == wants.length);
  final List<double> allocated = List<double>.filled(wants.length, 0);
  double remaining = math.max(0.0, width);
  for (int i = 0; i < wants.length; i++) {
    final double floor = math.min(floors[i], wants[i]);
    allocated[i] = math.min(floor, remaining);
    remaining -= allocated[i];
  }
  for (int i = 0; i < wants.length; i++) {
    final double extra = math.min(wants[i] - allocated[i], remaining);
    if (extra <= 0) continue;
    allocated[i] += extra;
    remaining -= extra;
  }
  return allocated;
}

/// 视频内顶栏布局：**按钮按需拿宽、标题吃剩余**。
///
/// 根因（2026-08 修复）：顶栏原来直接是 media_kit fork 的一条 `Row`，左按钮组 / 标题 /
/// 右按钮组各自挂一个 `Flexible(flex: 1)`。`Flex` 把可用宽按 flex 因子**平分**成三份，
/// 而 `FlexFit.loose` 的子项用不完的份额**不会回流**给别人 —— 于是右上角按钮组无论窗口
/// 多宽都只拿得到 1/3 顶栏宽，多出来的按钮被裁进组内横滚区（用户看到的「视频名称把
/// 按钮挡住、要横滑才点得到」）。标题项被关掉时旧代码还返回 `Spacer()`（= `FlexFit.tight`），
/// 空白中段照样霸占那 1/3，所以「把名称删掉、中间明明是空的」也救不回按钮。
///
/// 这里换成显式优先级：**四段按钮先拿**（[allocateVideoTopBarButtonWidths]：先给每段
/// 保底、再按优先级补足），标题最后拿真正剩下的那点宽度。按钮段是 `VideoControlBar`，
/// 拿到的宽不够原样摆下时按优先级把按钮收进段尾「⋯」——按钮永远完整（BUG-2832）；
/// 标题窄了靠 `maxLines: 1` + ellipsis 优雅截断——即「按钮比名称重要」。
///
/// 五个槽都必须传：不显示的槽传零尺寸占位（如 `SizedBox.shrink()`），它就不占宽。
class VideoTopBarSlots extends StatelessWidget {
  const VideoTopBarSlots({
    required this.leftLead,
    required this.leftTail,
    required this.title,
    required this.rightLead,
    required this.rightTail,
    this.titlePlacement = VideoTopBarTitlePlacement.center,
    super.key,
  });

  /// topLeft 组标题之前的按钮（返回键等）：第一优先。
  final Widget leftLead;

  /// topLeft 组标题之后的按钮（标题不在该组时为空占位）。
  final Widget leftTail;

  /// 标题：最后布局，只吃四段按钮用剩的宽。
  final Widget title;

  /// topRight 组标题之前的按钮。
  final Widget rightLead;

  /// topRight 组标题之后的按钮（标题不在该组时为空占位）。
  final Widget rightTail;

  /// 标题夹在哪两段按钮之间。
  final VideoTopBarTitlePlacement titlePlacement;

  @override
  Widget build(BuildContext context) {
    // 子节点顺序固定：四段按钮（即分宽优先级）→ 标题。
    return _VideoTopBarSlotsLayout(
      titlePlacement: titlePlacement,
      children: <Widget>[leftLead, leftTail, rightLead, rightTail, title],
    );
  }
}

class _VideoTopBarSlotsLayout extends MultiChildRenderObjectWidget {
  const _VideoTopBarSlotsLayout({
    required this.titlePlacement,
    required super.children,
  });

  final VideoTopBarTitlePlacement titlePlacement;

  @override
  _RenderVideoTopBarSlots createRenderObject(BuildContext context) =>
      _RenderVideoTopBarSlots(titlePlacement: titlePlacement);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderVideoTopBarSlots renderObject,
  ) {
    renderObject.titlePlacement = titlePlacement;
  }
}

class _VideoTopBarSlotsParentData extends ContainerBoxParentData<RenderBox> {}

/// 需要读子节点的固有宽来保底，`MultiChildLayoutDelegate` 拿不到，所以是 RenderBox。
class _RenderVideoTopBarSlots extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _VideoTopBarSlotsParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _VideoTopBarSlotsParentData
        > {
  _RenderVideoTopBarSlots({required VideoTopBarTitlePlacement titlePlacement})
    : _titlePlacement = titlePlacement;

  VideoTopBarTitlePlacement _titlePlacement;
  set titlePlacement(VideoTopBarTitlePlacement value) {
    if (value == _titlePlacement) return;
    _titlePlacement = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _VideoTopBarSlotsParentData) {
      child.parentData = _VideoTopBarSlotsParentData();
    }
  }

  List<RenderBox> get _children {
    final List<RenderBox> children = <RenderBox>[];
    RenderBox? child = firstChild;
    while (child != null) {
      children.add(child);
      child = childAfter(child);
    }
    return children;
  }

  /// 四段按钮（按优先级）与标题；子节点数不对时（不应发生）返回 null。
  ({List<RenderBox> buttons, RenderBox title})? get _slots {
    final List<RenderBox> children = _children;
    if (children.length != 5) return null;
    return (buttons: children.sublist(0, 4), title: children[4]);
  }

  /// 量出每段该分多少宽，再按 [layoutChild] 布局；返回各段实际尺寸
  /// （leftLead, leftTail, rightLead, rightTail, title）。
  List<Size> _layoutSlots(Size size, ChildLayouter layoutChild) {
    final ({List<RenderBox> buttons, RenderBox title})? slots = _slots;
    if (slots == null) return const <Size>[];
    final double height = size.height;
    final List<double> allocated = allocateVideoTopBarButtonWidths(
      floors: <double>[
        for (final RenderBox b in slots.buttons) b.getMinIntrinsicWidth(height),
      ],
      wants: <double>[
        for (final RenderBox b in slots.buttons) b.getMaxIntrinsicWidth(height),
      ],
      width: size.width,
    );
    final List<Size> sizes = <Size>[];
    double consumed = 0;
    for (int i = 0; i < slots.buttons.length; i++) {
      final Size s = layoutChild(
        slots.buttons[i],
        BoxConstraints.loose(Size(allocated[i], height)),
      );
      sizes.add(s);
      consumed += s.width;
    }
    sizes.add(
      layoutChild(
        slots.title,
        BoxConstraints.loose(
          Size(math.max(0.0, size.width - consumed), height),
        ),
      ),
    );
    return sizes;
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.biggest;

  @override
  void performLayout() {
    size = constraints.biggest;
    final ({List<RenderBox> buttons, RenderBox title})? slots = _slots;
    if (slots == null) return;
    final List<Size> sizes = _layoutSlots(size, ChildLayoutHelper.layoutChild);
    final double leftLead = sizes[0].width;
    final double leftTail = sizes[1].width;
    final double rightLead = sizes[2].width;
    final double rightTail = sizes[3].width;
    final double title = sizes[4].width;

    /// 槽在顶栏内垂直居中。
    void place(RenderBox child, Size childSize, double x) {
      (child.parentData! as _VideoTopBarSlotsParentData).offset = Offset(
        x,
        (size.height - childSize.height) / 2,
      );
    }

    // 左段从左边缘起排；标题若属于左组，就夹在 lead / tail 之间。
    double x = 0;
    place(slots.buttons[0], sizes[0], x);
    x += leftLead;
    if (_titlePlacement == VideoTopBarTitlePlacement.left) {
      place(slots.title, sizes[4], x);
      x += title;
    }
    place(slots.buttons[1], sizes[1], x);
    x += leftTail;
    // 中段标题紧接左段（文本自身靠左对齐），一直伸到右段左缘。
    if (_titlePlacement == VideoTopBarTitlePlacement.center) {
      place(slots.title, sizes[4], x);
    }

    // 右段整体右对齐贴右边缘；标题若属于右组，同样夹在 lead / tail 之间。
    final bool titleRight = _titlePlacement == VideoTopBarTitlePlacement.right;
    double rx = size.width - (rightLead + rightTail + (titleRight ? title : 0));
    place(slots.buttons[2], sizes[2], rx);
    rx += rightLead;
    if (titleRight) {
      place(slots.title, sizes[4], rx);
      rx += title;
    }
    place(slots.buttons[3], sizes[3], rx);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    double width = 0;
    for (final RenderBox child in _children) {
      width += child.getMinIntrinsicWidth(height);
    }
    return width;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    double width = 0;
    for (final RenderBox child in _children) {
      width += child.getMaxIntrinsicWidth(height);
    }
    return width;
  }

  double _tallestIntrinsic(double width) {
    double height = 0;
    for (final RenderBox child in _children) {
      height = math.max(height, child.getMaxIntrinsicHeight(width));
    }
    return height;
  }

  @override
  double computeMinIntrinsicHeight(double width) => _tallestIntrinsic(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _tallestIntrinsic(width);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
