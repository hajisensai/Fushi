import 'dart:math' as math;

import 'package:flutter/material.dart';

/// macOS 统计页风格的环形进度画笔：底轨 + 进度弧（从 12 点方向顺时针）。
/// 端点圆头，进度裁剪到 [0, 1]。样式全部经参数传入，使 [shouldRepaint] 稳定。
class StatRingPainter extends CustomPainter {
  StatRingPainter({
    required this.fraction,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  /// 进度比例（0..1），越界由构造方裁剪。
  final double fraction;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    if (radius <= 0) return;
    final Offset center = Offset(size.width / 2, size.height / 2);
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    final double clamped = fraction.clamp(0.0, 1.0);
    if (clamped <= 0) return;
    final Paint arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    // 从 12 点方向（-90°）顺时针。
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * clamped,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant StatRingPainter oldDelegate) =>
      fraction != oldDelegate.fraction ||
      color != oldDelegate.color ||
      trackColor != oldDelegate.trackColor ||
      strokeWidth != oldDelegate.strokeWidth;
}

/// 环形进度指标：外圈进度弧 + 圆心的大数值 + 单位/说明。
/// [value] 主数值（如 `62%` 或 `3200`），[caption] 环下方标签（如「字数」）。
class StatRing extends StatelessWidget {
  const StatRing({
    required this.fraction,
    required this.color,
    required this.trackColor,
    required this.value,
    required this.caption,
    super.key,
    this.detail,
    this.size = 96,
    this.strokeWidth = 9,
  });

  final double fraction;
  final Color color;

  /// 底轨颜色（由调用方从主题 surface 角色传入，使本组件不直接绑定 surface 角色）。
  final Color trackColor;

  /// 圆心主数值文本。
  final String value;

  /// 环下方的标签（指标名）。
  final String caption;

  /// 圆心副文本（可空，如目标分母 `/ 5000`）。
  final String? detail;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: StatRingPainter(
              fraction: fraction,
              color: color,
              trackColor: trackColor,
              strokeWidth: strokeWidth,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
