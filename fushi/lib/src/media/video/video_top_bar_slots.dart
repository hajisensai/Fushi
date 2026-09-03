import 'dart:math' as math;

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

/// 视频内顶栏布局：**按钮按需拿宽、标题吃剩余**。
///
/// 根因（2026-08 修复）：顶栏原来直接是 media_kit fork 的一条 `Row`，左按钮组 / 标题 /
/// 右按钮组各自挂一个 `Flexible(flex: 1)`。`Flex` 把可用宽按 flex 因子**平分**成三份，
/// 而 `FlexFit.loose` 的子项用不完的份额**不会回流**给别人 —— 于是右上角按钮组无论窗口
/// 多宽都只拿得到 1/3 顶栏宽，多出来的按钮被裁进组内横滚区（用户看到的「视频名称把
/// 按钮挡住、要横滑才点得到」）。标题项被关掉时旧代码还返回 `Spacer()`（= `FlexFit.tight`），
/// 空白中段照样霸占那 1/3，所以「把名称删掉、中间明明是空的」也救不回按钮。
///
/// 这里换成显式优先级：**四段按钮先按各自内容固有宽足额拿走**，标题最后拿真正剩下的
/// 那点宽度。按钮永远完整可见；标题窄了靠 `maxLines: 1` + ellipsis 优雅截断——即
/// 「按钮比名称重要」。按钮段自身仍是可横滚的（页面侧用 `shrinkWrap` ListView 包裹），
/// 极窄窗按钮总宽超过整条顶栏时依旧可达、不会被裁没。
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
    return CustomMultiChildLayout(
      delegate: VideoTopBarSlotsDelegate(titlePlacement: titlePlacement),
      children: <Widget>[
        LayoutId(id: VideoTopBarSlotId.leftLead, child: leftLead),
        LayoutId(id: VideoTopBarSlotId.leftTail, child: leftTail),
        LayoutId(id: VideoTopBarSlotId.rightLead, child: rightLead),
        LayoutId(id: VideoTopBarSlotId.rightTail, child: rightTail),
        LayoutId(id: VideoTopBarSlotId.title, child: title),
      ],
    );
  }
}

/// [VideoTopBarSlots] 的排布委托：**布局顺序即优先级**（四段按钮 → 标题吃剩余）。
class VideoTopBarSlotsDelegate extends MultiChildLayoutDelegate {
  VideoTopBarSlotsDelegate({
    this.titlePlacement = VideoTopBarTitlePlacement.center,
  });

  final VideoTopBarTitlePlacement titlePlacement;

  /// [positionChild] 要用子尺寸做垂直居中，而 [layoutChild] 每个槽只能调一次，故记账。
  final Map<VideoTopBarSlotId, Size> _sizes = <VideoTopBarSlotId, Size>{};

  @override
  void performLayout(Size size) {
    final double height = size.height;
    _sizes.clear();
    double consumed = 0;

    /// 按剩余宽布局一个槽；槽自身 shrink-wrap，用多少算多少。
    double take(VideoTopBarSlotId id) {
      if (!hasChild(id)) return 0;
      final Size s = layoutChild(
        id,
        BoxConstraints.loose(
          Size(math.max(0.0, size.width - consumed), height),
        ),
      );
      _sizes[id] = s;
      consumed += s.width;
      return s.width;
    }

    // ① 四段按钮先分：它们要多少给多少（上限只有「整条顶栏还剩多少」）。
    final double leftLead = take(VideoTopBarSlotId.leftLead);
    final double leftTail = take(VideoTopBarSlotId.leftTail);
    final double rightLead = take(VideoTopBarSlotId.rightLead);
    final double rightTail = take(VideoTopBarSlotId.rightTail);
    // ② 标题最后分，只拿真正剩下的。
    final double title = take(VideoTopBarSlotId.title);

    /// 槽在顶栏内垂直居中。
    void place(VideoTopBarSlotId id, double x) {
      if (!hasChild(id)) return;
      positionChild(id, Offset(x, (height - _sizeOf(id, height).height) / 2));
    }

    // 左段从左边缘起排；标题若属于左组，就夹在 lead / tail 之间。
    double x = 0;
    place(VideoTopBarSlotId.leftLead, x);
    x += leftLead;
    if (titlePlacement == VideoTopBarTitlePlacement.left) {
      place(VideoTopBarSlotId.title, x);
      x += title;
    }
    place(VideoTopBarSlotId.leftTail, x);
    x += leftTail;
    // 中段标题紧接左段（文本自身靠左对齐），一直伸到右段左缘。
    if (titlePlacement == VideoTopBarTitlePlacement.center) {
      place(VideoTopBarSlotId.title, x);
    }

    // 右段整体右对齐贴右边缘；标题若属于右组，同样夹在 lead / tail 之间。
    final double rightTotal = rightLead +
        rightTail +
        (titlePlacement == VideoTopBarTitlePlacement.right ? title : 0);
    double rx = size.width - rightTotal;
    place(VideoTopBarSlotId.rightLead, rx);
    rx += rightLead;
    if (titlePlacement == VideoTopBarTitlePlacement.right) {
      place(VideoTopBarSlotId.title, rx);
      rx += title;
    }
    place(VideoTopBarSlotId.rightTail, rx);
  }

  Size _sizeOf(VideoTopBarSlotId id, double fallbackHeight) =>
      _sizes[id] ?? Size(0, fallbackHeight);

  @override
  bool shouldRelayout(VideoTopBarSlotsDelegate oldDelegate) =>
      oldDelegate.titlePlacement != titlePlacement;
}
