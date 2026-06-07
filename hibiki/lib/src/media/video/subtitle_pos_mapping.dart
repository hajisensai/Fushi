import 'package:flutter/widgets.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 把归一化 `\pos` 分数映射到 overlay 容器内的局部坐标，含 `BoxFit.contain`
/// 的 letterbox/pillarbox 黑边。[videoW]/[videoH] 为视频原始分辨率，[containerSize]
/// 为 overlay 容器尺寸。视频未解码（宽高 <= 0）或容器为空时返回 null，调用方回退。
Offset? mapPosFractionToContainer(
  SubtitlePos posFraction,
  int videoW,
  int videoH,
  Size containerSize,
) {
  if (videoW <= 0 || videoH <= 0) return null;
  if (containerSize.width <= 0 || containerSize.height <= 0) return null;

  final double videoAspect = videoW / videoH;
  final double containerAspect = containerSize.width / containerSize.height;

  double contentW;
  double contentH;
  if (videoAspect > containerAspect) {
    // 视频更宽：左右贴边，上下留黑边（letterbox）。
    contentW = containerSize.width;
    contentH = containerSize.width / videoAspect;
  } else {
    // 视频更高或等比：上下贴边，左右留黑边（pillarbox）。
    contentH = containerSize.height;
    contentW = containerSize.height * videoAspect;
  }

  final double originX = (containerSize.width - contentW) / 2;
  final double originY = (containerSize.height - contentH) / 2;
  return Offset(
    originX + posFraction.xFraction * contentW,
    originY + posFraction.yFraction * contentH,
  );
}
