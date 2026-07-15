import 'package:flutter/widgets.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// `BoxFit.contain` 后视频内容矩形的尺寸（居中，余下为黑边）。这是 mpv/libass 字幕
/// 几何的统一基准：`\pos` 定位（[mapPosFractionToContainer]）与字号/描边/边距缩放
/// （BUG-820）都锚定在**视频帧的显示尺寸**上，而不是播放器容器——窗口比≠视频比
/// （letterbox/pillarbox）时容器高大于视频显示高，按容器缩放会整体偏大。
/// 视频未解码（宽高 <= 0）或容器为空返回 null，调用方回退容器基准（历史行为）。
Size? fitVideoContentSize(int videoW, int videoH, Size containerSize) {
  if (videoW <= 0 || videoH <= 0) return null;
  if (containerSize.width <= 0 || containerSize.height <= 0) return null;

  final double videoAspect = videoW / videoH;
  final double containerAspect = containerSize.width / containerSize.height;
  if (videoAspect > containerAspect) {
    // 视频更宽：左右贴边，上下留黑边（letterbox）。
    return Size(containerSize.width, containerSize.width / videoAspect);
  }
  // 视频更高或等比：上下贴边，左右留黑边（pillarbox）。
  return Size(containerSize.height * videoAspect, containerSize.height);
}

/// 把归一化 `\pos` 分数映射到 overlay 容器内的局部坐标，含 `BoxFit.contain`
/// 的 letterbox/pillarbox 黑边。[videoW]/[videoH] 为视频原始分辨率，[containerSize]
/// 为 overlay 容器尺寸。视频未解码（宽高 <= 0）或容器为空时返回 null，调用方回退。
Offset? mapPosFractionToContainer(
  SubtitlePos posFraction,
  int videoW,
  int videoH,
  Size containerSize,
) {
  final Size? content = fitVideoContentSize(videoW, videoH, containerSize);
  if (content == null) return null;

  final double originX = (containerSize.width - content.width) / 2;
  final double originY = (containerSize.height - content.height) / 2;
  return Offset(
    originX + posFraction.xFraction * content.width,
    originY + posFraction.yFraction * content.height,
  );
}
