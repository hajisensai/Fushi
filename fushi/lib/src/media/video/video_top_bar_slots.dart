import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 视频内顶栏的三槽标识（左按钮组 / 标题 / 右按钮组），见 [VideoTopBarSlots]。
enum VideoTopBarSlotId { left, title, right }

/// 视频内顶栏三槽布局：**按钮按需拿宽、标题吃剩余**。
///
/// 根因（2026-08 修复）：顶栏原来直接是 media_kit fork 的一条 `Row`，左按钮组 / 标题 /
/// 右按钮组各自挂一个 `Flexible(flex: 1)`。`Flex` 把可用宽按 flex 因子**平分**成三份，
/// 而 `FlexFit.loose` 的子项用不完的份额**不会回流**给别人 —— 于是右上角按钮组无论窗口
/// 多宽都只拿得到 1/3 顶栏宽，多出来的按钮被裁进组内横滚区（用户看到的「视频名称把
/// 按钮挡住、要横滑才点得到」）。标题项被关掉时旧代码还返回 `Spacer()`（= `FlexFit.tight`），
/// 空白中段照样霸占那 1/3，所以「把名称删掉、中间明明是空的」也救不回按钮。
///
/// 这里换成显式优先级：先满足左槽（返回键等，必达），再满足右槽（功能键），最后把
/// **真正剩下的**宽度交给标题。按钮永远完整可见；标题窄了靠 `maxLines: 1` + ellipsis
/// 优雅截断——即「按钮比名称重要」。两侧按钮组自身仍是可横滚的（页面侧用 `shrinkWrap`
/// ListView 包裹），极窄窗按钮总宽超过整条顶栏时依旧可达、不会被裁没。
///
/// 三槽都必须传：不显示的槽传零尺寸占位（如 `SizedBox.shrink()`），它就不占宽。
class VideoTopBarSlots extends StatelessWidget {
  const VideoTopBarSlots({
    required this.left,
    required this.title,
    required this.right,
    super.key,
  });

  /// 左按钮组（返回键等）：第一优先，按内容固有宽足额分配。
  final Widget left;

  /// 标题：最后布局，只吃两侧按钮组用剩的宽。
  final Widget title;

  /// 右按钮组（功能键）：第二优先，在左槽之后按内容固有宽足额分配。
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return CustomMultiChildLayout(
      delegate: VideoTopBarSlotsDelegate(),
      children: <Widget>[
        LayoutId(id: VideoTopBarSlotId.left, child: left),
        LayoutId(id: VideoTopBarSlotId.right, child: right),
        LayoutId(id: VideoTopBarSlotId.title, child: title),
      ],
    );
  }
}

/// [VideoTopBarSlots] 的排布委托：**布局顺序即优先级**（左按钮 → 右按钮 → 标题吃剩余）。
class VideoTopBarSlotsDelegate extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final double height = size.height;
    double consumed = 0;
    double leftWidth = 0;
    if (hasChild(VideoTopBarSlotId.left)) {
      final Size s = layoutChild(
        VideoTopBarSlotId.left,
        BoxConstraints.loose(Size(size.width, height)),
      );
      leftWidth = s.width;
      consumed += s.width;
      positionChild(VideoTopBarSlotId.left, Offset(0, (height - s.height) / 2));
    }
    if (hasChild(VideoTopBarSlotId.right)) {
      final Size s = layoutChild(
        VideoTopBarSlotId.right,
        BoxConstraints.loose(
          Size(math.max(0.0, size.width - consumed), height),
        ),
      );
      consumed += s.width;
      positionChild(
        VideoTopBarSlotId.right,
        Offset(size.width - s.width, (height - s.height) / 2),
      );
    }
    if (hasChild(VideoTopBarSlotId.title)) {
      final Size s = layoutChild(
        VideoTopBarSlotId.title,
        BoxConstraints.loose(
          Size(math.max(0.0, size.width - consumed), height),
        ),
      );
      positionChild(
        VideoTopBarSlotId.title,
        Offset(leftWidth, (height - s.height) / 2),
      );
    }
  }

  @override
  bool shouldRelayout(VideoTopBarSlotsDelegate oldDelegate) => false;
}
