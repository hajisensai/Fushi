import 'package:flutter/material.dart';

/// TODO-1154：长按倍速跟随徽章。视频画面长按临时加速时，在指针（手指/光标）上方弹一枚
/// 「Nx」圆角气泡并跟手移动（B 站/YouTube 长按倍速观感），取代旧的钉死左上角 OSD。
///
/// 用 [position]（本 widget 所在 Stack 的局部坐标，即手势 `details.localPosition`）驱动一个
/// [Positioned]，再用 [FractionalTranslation] 把气泡水平居中于指针、整体上移避免被遮挡。
/// 抽成独立无状态 widget（渲染仅依赖入参、不碰 State 私有域），便于 widget 测试直接断言
/// 「气泡随 [position] 变化而跟随移动」。放进 [Stack] 使用（自身即一个 [Positioned]）。
class VideoLongPressSpeedBadge extends StatelessWidget {
  const VideoLongPressSpeedBadge({
    super.key,
    required this.position,
    required this.speed,
    required this.surfaceColor,
    required this.textColor,
  });

  /// 跟随锚点：Stack 局部坐标（手势 localPosition）。
  final Offset position;

  /// 当前倍速值（显示为 `N.Nx`）。
  final double speed;

  /// 气泡背景色（复用视频 OSD 表面色）。
  final Color surfaceColor;

  /// 气泡文字/图标色。
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx,
      top: position.dy,
      child: FractionalTranslation(
        // 水平居中于指针（-0.5），竖直整体上移 1.8 身位避开手指/光标。
        translation: const Offset(-0.5, -1.8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.fast_forward, size: 18, color: textColor),
                const SizedBox(width: 6),
                Text(
                  '${speed.toStringAsFixed(1)}x',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
