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

VideoControlPopoverPlacement resolveVideoControlPopoverPlacement({
  required Rect playerBounds,
  required Rect targetRect,
  required double preferredWidth,
  required VideoControlSlot sourceSlot,
  double gap = 8,
  double minWidth = 160,
}) {
  final double availableWidth = math.max(0, playerBounds.width);
  final double resolvedMinWidth = math.min(minWidth, availableWidth);
  final double resolvedPreferredWidth =
      preferredWidth.isFinite ? preferredWidth : availableWidth;
  final double width =
      resolvedPreferredWidth.clamp(resolvedMinWidth, availableWidth).toDouble();

  double left = switch (sourceSlot) {
    VideoControlSlot.bottomLeft => targetRect.left,
    VideoControlSlot.bottomRight => targetRect.right - width,
    _ => targetRect.center.dx - width / 2,
  };
  final double minLeft = playerBounds.left;
  final double maxLeft = playerBounds.right - width;
  left = maxLeft < minLeft ? minLeft : left.clamp(minLeft, maxLeft).toDouble();

  return VideoControlPopoverPlacement(
    left: left,
    top: math.max(playerBounds.top, targetRect.top - gap),
    width: width,
  );
}
