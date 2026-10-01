import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 视频底栏的三个区，见 [VideoBottomBarSlots]。
enum VideoBottomBarSlotId { left, center, right }

/// 居中传输簇的起点 x：**能居中就居中，放不下就在左右两簇之间的空隙里平移**。
///
/// - 理想位置是几何正中 `(width - centerWidth) / 2`（BUG-257：play 钉在整条底栏
///   正中，与两侧按钮数量无关）。
/// - 中簇不得压进左簇（`>= leftWidth`），也不得压进右簇
///   （`<= width - rightWidth - centerWidth`）。
/// - 空隙比中簇还窄时（调用方已把中簇缩到空隙宽），紧贴左簇右缘。
double videoBottomBarCenterStart({
  required double width,
  required double leftWidth,
  required double centerWidth,
  required double rightWidth,
}) {
  final double ideal = (width - centerWidth) / 2;
  final double minStart = leftWidth;
  final double maxStart = width - rightWidth - centerWidth;
  if (maxStart <= minStart) return minStart;
  return ideal.clamp(minStart, maxStart).toDouble();
}

/// 视频底栏三区布局：左（时间 + bottomLeft 按钮）/ 中（传输簇）/ 右（尾部按钮）。
///
/// 根因（BUG：开字幕列表后底栏按钮叠在一起）：旧实现是三区 `Stack` 绝对定位——
/// `Center(传输簇)` + `Align(centerLeft)` + `Align(centerRight)`，三区互相不知道对方
/// 多宽。播放区被右侧字幕列表挤窄后，居中的传输簇和右簇在同一段 x 上叠画
/// （截图里「+10s」压在音量图标上）。
///
/// 这里换成显式优先级：左右两簇按内容固有宽先拿（右簇上限是左簇用剩的宽），
/// 中簇只拿两簇之间的空隙——宽度够时仍钉几何正中，不够时在空隙里平移
/// （[videoBottomBarCenterStart]），空隙比中簇还窄时等比缩小（[FittedBox]
/// scaleDown），任何宽度下三区都不重叠。
class VideoBottomBarSlots extends StatelessWidget {
  const VideoBottomBarSlots({
    required this.left,
    required this.center,
    required this.right,
    super.key,
  });

  final Widget left;
  final Widget center;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return CustomMultiChildLayout(
      delegate: VideoBottomBarSlotsDelegate(),
      children: <Widget>[
        LayoutId(
          id: VideoBottomBarSlotId.left,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: left,
          ),
        ),
        LayoutId(
          id: VideoBottomBarSlotId.right,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: right,
          ),
        ),
        LayoutId(
          id: VideoBottomBarSlotId.center,
          child: FittedBox(fit: BoxFit.scaleDown, child: center),
        ),
      ],
    );
  }
}

/// [VideoBottomBarSlots] 的排布委托：**布局顺序即优先级**（左 → 右 → 中吃空隙）。
class VideoBottomBarSlotsDelegate extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final double width = size.width;
    final double height = size.height;

    Size take(VideoBottomBarSlotId id, double maxWidth) {
      if (!hasChild(id)) return Size.zero;
      return layoutChild(
        id,
        BoxConstraints.loose(Size(math.max(0.0, maxWidth), height)),
      );
    }

    final Size left = take(VideoBottomBarSlotId.left, width);
    final Size right = take(VideoBottomBarSlotId.right, width - left.width);
    final Size center = take(
      VideoBottomBarSlotId.center,
      width - left.width - right.width,
    );

    void place(VideoBottomBarSlotId id, double x, Size s) {
      if (!hasChild(id)) return;
      positionChild(id, Offset(x, (height - s.height) / 2));
    }

    place(VideoBottomBarSlotId.left, 0, left);
    place(VideoBottomBarSlotId.right, width - right.width, right);
    place(
      VideoBottomBarSlotId.center,
      videoBottomBarCenterStart(
        width: width,
        leftWidth: left.width,
        centerWidth: center.width,
        rightWidth: right.width,
      ),
      center,
    );
  }

  @override
  bool shouldRelayout(VideoBottomBarSlotsDelegate oldDelegate) => false;
}
