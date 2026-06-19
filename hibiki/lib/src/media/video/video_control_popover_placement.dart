import 'dart:math' as math;
import 'dart:ui';

import 'package:hibiki/src/media/video/video_control_customization.dart';

class VideoControlPopoverPlacement {
  const VideoControlPopoverPlacement({
    required this.left,
    required this.top,
    required this.width,
  });

  final double left;
  final double top;
  final double width;

  double get right => left + width;
}

/// 浮层（音量 / 倍速轻浮层）相对触发按钮的弹出方向（TODO-560）。
///
/// 触发按钮可被用户放进 9 槽位的任一可见槽（底栏 L/C/R、顶栏 L/C/R、左 / 右浮动侧栏）。
/// 浮层必须朝**画面内侧**弹，才不会被屏幕边缘裁切、且与按钮真实位置相连：
/// - 底栏按钮 → 向上弹（[up]）；
/// - 顶栏按钮 → 向下弹（[down]）；
/// - 左侧栏按钮 → 向右弹（[right]）；右侧栏按钮 → 向左弹（[left]）。
///
/// 这是把「恒向上」的旧行为（底栏假设）替换为按槽位自适应的核心枚举：[up] 对应旧
/// 行为，其它三向是顶栏 / 侧栏新增。
enum VideoControlPopoverDirection { up, down, left, right }

/// 按触发按钮所在槽位决定浮层弹出方向（TODO-560 纯函数，供单测）。
///
/// 未知 / 隐藏 / null 槽位退回 [VideoControlPopoverDirection.up]（与旧底栏默认一致，
/// 不引入回归）。
VideoControlPopoverDirection videoControlPopoverDirectionForSlot(
  VideoControlSlot? slot,
) {
  switch (slot) {
    case VideoControlSlot.topLeft:
    case VideoControlSlot.topCenter:
    case VideoControlSlot.topRight:
      return VideoControlPopoverDirection.down;
    case VideoControlSlot.screenLeft:
      return VideoControlPopoverDirection.right;
    case VideoControlSlot.screenRight:
      return VideoControlPopoverDirection.left;
    case VideoControlSlot.bottomLeft:
    case VideoControlSlot.bottomCenter:
    case VideoControlSlot.bottomRight:
    case VideoControlSlot.hidden:
    case null:
      return VideoControlPopoverDirection.up;
  }
}

VideoControlPopoverPlacement resolveVideoControlPopoverPlacement({
  required Rect playerBounds,
  required Rect targetRect,
  required double preferredWidth,
  required VideoControlSlot sourceSlot,
  double gap = 8,
  double minWidth = 160,
  double height = 0,
}) {
  final double availableWidth = math.max(0, playerBounds.width);
  final double resolvedMinWidth = math.min(minWidth, availableWidth);
  final double resolvedPreferredWidth =
      preferredWidth.isFinite ? preferredWidth : availableWidth;
  final double width =
      resolvedPreferredWidth.clamp(resolvedMinWidth, availableWidth).toDouble();

  final VideoControlPopoverDirection direction =
      videoControlPopoverDirectionForSlot(sourceSlot);

  // 横向落点：底/顶栏按槽位左 / 中 / 右对齐；左 / 右侧栏紧贴按钮内侧外缘。
  double left = switch (sourceSlot) {
    VideoControlSlot.bottomLeft || VideoControlSlot.topLeft => targetRect.left,
    VideoControlSlot.bottomRight ||
    VideoControlSlot.topRight =>
      targetRect.right - width,
    VideoControlSlot.screenLeft => targetRect.right + gap,
    VideoControlSlot.screenRight => targetRect.left - gap - width,
    _ => targetRect.center.dx - width / 2,
  };
  final double minLeft = playerBounds.left;
  final double maxLeft = playerBounds.right - width;
  left = maxLeft < minLeft ? minLeft : left.clamp(minLeft, maxLeft).toDouble();

  // 竖向落点：向上弹时浮层底贴按钮顶（top = 按钮顶 - gap - 高），向下弹时浮层顶贴
  // 按钮底（top = 按钮底 + gap），侧栏弹时与按钮垂直居中。高未知（height==0）时退回
  // 旧的「按钮顶 - gap」近似（实际渲染由 CompositedTransformFollower 的 anchor 决定，
  // top 仅供越界判断与单测断言方向）。
  final double resolvedHeight = math.max(0, height);
  double top = switch (direction) {
    VideoControlPopoverDirection.up => targetRect.top - gap - resolvedHeight,
    VideoControlPopoverDirection.down => targetRect.bottom + gap,
    VideoControlPopoverDirection.left ||
    VideoControlPopoverDirection.right =>
      targetRect.center.dy - resolvedHeight / 2,
  };
  final double minTop = playerBounds.top;
  final double maxTop = playerBounds.bottom - resolvedHeight;
  top = maxTop < minTop ? minTop : top.clamp(minTop, maxTop).toDouble();

  return VideoControlPopoverPlacement(
    left: left,
    top: top,
    width: width,
  );
}
