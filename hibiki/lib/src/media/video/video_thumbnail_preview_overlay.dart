import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/video_thumbnail_preview_controller.dart';

/// 把 hover 比例 [fraction]（`[0,1]`）映射成浮层左边缘 x（相对 seek bar 轨道左缘）。
///
/// 浮层中心对准 hover 点：`center = fraction * trackWidth`，左缘 = center − 半宽。
/// 再 clamp 到 `[0, trackWidth - bubbleWidth]` 防止贴左 / 右溢出轨道。轨道比浮层窄
/// （[trackWidth] < [bubbleWidth]）时退化为居中（左缘可负，由调用方容器裁剪）。纯函数。
double thumbnailPreviewLeft(
  double fraction,
  double trackWidth,
  double bubbleWidth,
) {
  final double clampedFraction = fraction.clamp(0.0, 1.0);
  final double center = clampedFraction * trackWidth;
  final double rawLeft = center - bubbleWidth / 2;
  final double maxLeft = trackWidth - bubbleWidth;
  if (maxLeft <= 0) {
    // 轨道比浮层窄：居中（左缘对称溢出，容器层裁剪）。
    return maxLeft / 2;
  }
  return rawLeft.clamp(0.0, maxLeft);
}

/// 把毫秒格式化成 `mm:ss` / `h:mm:ss`（>=1 小时带小时）。负值 clamp 到 0。纯函数。
String formatThumbnailTimestamp(int ms) {
  final int totalSec = (ms < 0 ? 0 : ms) ~/ 1000;
  final int h = totalSec ~/ 3600;
  final int m = (totalSec % 3600) ~/ 60;
  final int s = totalSec % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (h > 0) return '$h:${two(m)}:${two(s)}';
  return '${two(m)}:${two(s)}';
}

/// 视频进度条 hover 缩略图预览浮层（TODO-669，方案 A）。
///
/// 监听 [controller] 的 [ThumbnailPreviewState]，按 [ThumbnailPreviewPhase] 一次
/// switch 渲染：hidden → 不显示；loading → 缩略图（若上帧在）+ spinner + 时间戳；
/// ready → 缩略图 + 时间戳；timestampOnly → 仅时间戳气泡。
///
/// 几何：浮层水平按 [thumbnailPreviewLeft] 锚定到 hover 点（与 seek bar 轨道同坐标
/// 系——调用方在 `Padding(left:16,right:16)` 内放本组件，[trackWidth] 即内宽），
/// 竖直贴在轨道带上方。尺寸 ×[uiScale]（与章节刻度层同源缩放）。
class VideoThumbnailPreviewOverlay extends StatelessWidget {
  const VideoThumbnailPreviewOverlay({
    super.key,
    required this.controller,
    required this.trackWidth,
    required this.bottomOffset,
    required this.colorScheme,
    required this.uiScale,
    this.controlsVisible = true,
  });

  /// 取帧调度器（状态真相源）。
  final VideoThumbnailPreviewController controller;

  /// seek bar 轨道内宽（= 控件宽 − 左右各 16）；水平定位用。
  final double trackWidth;

  /// 浮层底缘距父容器底缘的偏移（= seek bar 轨道带上沿 + gap）。
  final double bottomOffset;

  final ColorScheme colorScheme;

  /// 界面缩放（与章节层 [thickness] ×scale 同源）。
  final double uiScale;

  /// 控制条是否可见；隐藏时浮层一并淡出（hover 无意义）。
  final bool controlsVisible;

  /// 缩略图基准宽度（×uiScale）。
  static const double _baseThumbWidth = 160;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, _) {
        final ThumbnailPreviewState state = controller.state;
        if (!controlsVisible ||
            state.phase == ThumbnailPreviewPhase.hidden ||
            state.fraction == null) {
          return const SizedBox.shrink();
        }

        final double thumbWidth = _baseThumbWidth * uiScale;
        final double bubbleWidth = thumbWidth;
        final double left =
            thumbnailPreviewLeft(state.fraction!, trackWidth, bubbleWidth);

        return Positioned(
          left: left,
          bottom: bottomOffset,
          width: bubbleWidth,
          child: _PreviewBubble(
            state: state,
            thumbWidth: thumbWidth,
            colorScheme: colorScheme,
            uiScale: uiScale,
          ),
        );
      },
    );
  }
}

/// 浮层气泡本体：缩略图（按帧宽高比）+ loading spinner 叠层 + 底部时间戳。
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    required this.state,
    required this.thumbWidth,
    required this.colorScheme,
    required this.uiScale,
  });

  final ThumbnailPreviewState state;
  final double thumbWidth;
  final ColorScheme colorScheme;
  final double uiScale;

  @override
  Widget build(BuildContext context) {
    final bool showThumb = state.image != null;
    final bool showSpinner = state.phase == ThumbnailPreviewPhase.loading;
    final double radius = 6.0 * uiScale;
    final double fontSize = 12.0 * uiScale;

    final List<Widget> children = <Widget>[];

    if (showThumb) {
      final ui.Image image = state.image!;
      final double aspect =
          image.height == 0 ? 16 / 9 : image.width / image.height;
      children.add(
        ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: AspectRatio(
            aspectRatio: aspect <= 0 ? 16 / 9 : aspect,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                RawImage(image: image, fit: BoxFit.cover),
                if (showSpinner)
                  Container(
                    color: colorScheme.scrim.withValues(alpha: 0.35),
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: 20 * uiScale,
                      height: 20 * uiScale,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } else if (showSpinner) {
      // 还没有任何帧（首次 loading）：占位框 + spinner，按 16:9 给个尺寸。
      children.add(
        ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: colorScheme.surface.withValues(alpha: 0.85),
              alignment: Alignment.center,
              child: SizedBox(
                width: 20 * uiScale,
                height: 20 * uiScale,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      );
    }
    // timestampOnly（无帧、无 spinner）只显时间戳气泡。

    children.add(SizedBox(height: 4 * uiScale));
    children.add(
      Container(
        padding: EdgeInsets.symmetric(
          horizontal: 6 * uiScale,
          vertical: 2 * uiScale,
        ),
        decoration: BoxDecoration(
          color: colorScheme.inverseSurface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(4 * uiScale),
        ),
        child: Text(
          formatThumbnailTimestamp(state.targetMs ?? 0),
          style: TextStyle(
            color: colorScheme.onInverseSurface,
            fontSize: fontSize,
            fontFeatures: const <ui.FontFeature>[
              ui.FontFeature.tabularFigures(),
            ],
          ),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );
  }
}
