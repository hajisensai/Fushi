/// 播放器原始帧（mpv `screenshot-raw video` 的 BGRA 像素，不经 PNG / JPEG 编码）。
///
/// media_kit 补丁格式 `image/x-fushi-bgra`：12 字节小端头（宽、高、stride，各 uint32）
/// 后接 `height * stride` 字节 BGRA（见 `ci/patches/hosted/media_kit-1.2.6/PATCHES.md`）。
/// 智能遮布持续抽帧，只要一小块裁剪，纯 Dart 编码整帧（1080p 几百毫秒）不可接受。
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

/// media_kit 补丁里的原始帧格式名。
const String kRawVideoFrameFormat = 'image/x-fushi-bgra';

/// 一帧 BGRA 像素。
class RawVideoFrame {
  const RawVideoFrame({
    required this.width,
    required this.height,
    required this.stride,
    required this.bgra,
  });

  final int width;
  final int height;

  /// 每行字节数（≥ width * 4，可能有对齐填充）。
  final int stride;

  /// `height * stride` 字节。
  final Uint8List bgra;
}

/// 解析补丁格式的字节；头部缺失、尺寸非正或数据长度对不上返回 null。
RawVideoFrame? parseRawVideoFrame(Uint8List? bytes) {
  if (bytes == null || bytes.length < 12) return null;
  final ByteData header = ByteData.sublistView(bytes, 0, 12);
  final int width = header.getUint32(0, Endian.little);
  final int height = header.getUint32(4, Endian.little);
  final int stride = header.getUint32(8, Endian.little);
  if (width <= 0 || height <= 0 || stride < width * 4) return null;
  if (bytes.length - 12 < height * stride) return null;
  return RawVideoFrame(
    width: width,
    height: height,
    stride: stride,
    bgra: Uint8List.sublistView(bytes, 12, 12 + height * stride),
  );
}

/// 一块 RGBA 裁剪（OCR 输入），带它在整帧里的像素位置。
class RawVideoFrameCrop {
  const RawVideoFrameCrop({
    required this.rgba,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.frameWidth,
    required this.frameHeight,
  });

  /// `width * height * 4` 字节 RGBA（alpha 恒 255）。
  final Uint8List rgba;
  final int left;
  final int top;
  final int width;
  final int height;
  final int frameWidth;
  final int frameHeight;

  /// 裁剪内像素矩形 → 整帧归一化（0..1）矩形。
  Rect toFrameFraction(Rect local) => Rect.fromLTRB(
    (left + local.left) / frameWidth,
    (top + local.top) / frameHeight,
    (left + local.right) / frameWidth,
    (top + local.bottom) / frameHeight,
  );
}

/// 按整帧比例矩形 [fraction] 裁出一块并转成 RGBA；裁剪为空返回 null。
///
/// 纯内存拷贝，适合放后台 isolate。
RawVideoFrameCrop? cropRawVideoFrame(RawVideoFrame frame, Rect fraction) {
  final int left = (fraction.left * frame.width).floor().clamp(0, frame.width);
  final int top = (fraction.top * frame.height).floor().clamp(0, frame.height);
  final int right = (fraction.right * frame.width).ceil().clamp(
    left,
    frame.width,
  );
  final int bottom = (fraction.bottom * frame.height).ceil().clamp(
    top,
    frame.height,
  );
  final int w = right - left;
  final int h = bottom - top;
  if (w <= 0 || h <= 0) return null;
  final Uint8List src = frame.bgra;
  final Uint8List out = Uint8List(w * h * 4);
  int o = 0;
  for (int y = 0; y < h; y++) {
    int i = (top + y) * frame.stride + left * 4;
    for (int x = 0; x < w; x++) {
      out[o] = src[i + 2];
      out[o + 1] = src[i + 1];
      out[o + 2] = src[i];
      out[o + 3] = 255;
      o += 4;
      i += 4;
    }
  }
  return RawVideoFrameCrop(
    rgba: out,
    left: left,
    top: top,
    width: w,
    height: h,
    frameWidth: frame.width,
    frameHeight: frame.height,
  );
}
