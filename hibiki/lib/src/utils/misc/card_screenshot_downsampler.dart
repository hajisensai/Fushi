import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// TODO-646 近无损压缩：制卡截图降采样。
///
/// 视频制卡封面在没有 cue GIF 时回退到当前帧截图（media_kit `image/jpeg`，按
/// libmpv 原始解码帧分辨率输出，可能是 1080p / 4K）。Lapis 卡面主图 CSS
/// `max-height:400px`、点图放大灯箱最大 ~1000px，故长边 1000px 已足够清晰，
/// 再大只是浪费媒体库体积。本模块把截图字节解码 → 长边等比缩到 1000px → 重编码
/// 高质量 JPEG（quality 90）。
///
/// 设计要点：
/// - **只缩不放**：长边已 <= [maxLongEdge] 时原样返回入参字节（不解码重编码，
///   避免对小图反复有损转码）。
/// - **解码失败保守回退**：字节非图片 / 解码返回 null 时原样返回入参，绝不让
///   降采样把一张有效截图变成空字节而破坏制卡。
/// - 纯 Dart（`package:image`，无 dart:ui），可在隔离/单测中直接调用，与
///   `epub_edge_matcher.dart` 同范式。

/// 计算等比缩放后的目标尺寸（纯函数，可单测）。
///
/// 返回 `null` 表示无需缩放（长边已 <= [maxLongEdge]，或输入尺寸非法）。
/// 否则返回缩放后的 `(width, height)`，长边恰为 [maxLongEdge]，另一边等比四舍五入
/// 且至少为 1（避免极端宽高比缩成 0）。
({int width, int height})? computeDownsampledSize({
  required int width,
  required int height,
  int maxLongEdge = 1000,
}) {
  if (width <= 0 || height <= 0 || maxLongEdge <= 0) return null;
  final int longEdge = width >= height ? width : height;
  if (longEdge <= maxLongEdge) return null; // 只缩不放。
  final double scale = maxLongEdge / longEdge;
  final int newWidth = (width * scale).round();
  final int newHeight = (height * scale).round();
  return (
    width: newWidth < 1 ? 1 : newWidth,
    height: newHeight < 1 ? 1 : newHeight,
  );
}

/// 把制卡截图 [bytes] 降采样到长边 [maxLongEdge]px，重编码为 JPEG（质量
/// [quality]）。长边已不超限、或解码失败时原样返回 [bytes]（绝不返回空/破坏媒体）。
///
/// TODO-757 压缩开关：默认压缩档（长边 1000px / 质量 90，= TODO-646 现状）。关闭压缩
/// 时调用点传高保真档（长边 2000px / 质量 95）。默认值保持现状，纯函数不读全局偏好。
Uint8List downsampleCardScreenshot(
  Uint8List bytes, {
  int maxLongEdge = 1000,
  int quality = 90,
}) {
  if (bytes.isEmpty) return bytes;
  try {
    // `img.decodeImage` 对损坏字节可能返回 null，也可能在嗅探解码器时抛
    // （如 GIF 头探测越界 RangeError）。两种都视作「不是可处理的截图」，
    // 保守原样返回，绝不让降采样把一张有效封面变成空/异常而破坏制卡。
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final ({int width, int height})? target = computeDownsampledSize(
      width: decoded.width,
      height: decoded.height,
      maxLongEdge: maxLongEdge,
    );
    if (target == null) return bytes; // 已 <= 长边上限，不动。
    final img.Image resized = img.copyResize(
      decoded,
      width: target.width,
      height: target.height,
    );
    return img.encodeJpg(resized, quality: quality);
  } catch (_) {
    return bytes;
  }
}
