/// 播放器原始帧（mpv `screenshot-raw video` 的 BGRA 像素，不经 PNG / JPEG 编码）的
/// 裁剪。
///
/// media_kit 补丁格式 `image/x-fushi-bgra`（见 `ci/patches/hosted/media_kit-1.2.6/
/// PATCHES.md`）：截帧 isolate 拿到 mpv 的 BGRA 缓冲后，直接调用调用方给的变换
/// （[rawVideoFrameCropTransform]）就地裁出搜索区域、转成 RGBA，只把这一小块传回主
/// isolate。智能遮布持续抽帧（播放中每秒约 4 次），整帧在 isolate 之间来回拷贝
/// （1080p 约 8 MB、4K 约 33 MB）与纯 Dart 编码都不可接受。
///
/// 裁剪的字节布局：24 字节小端头（整帧宽、整帧高、裁剪 left、top、宽、高，各
/// uint32）后接 `宽 * 高 * 4` 字节 RGBA（alpha 恒 255），由 [parseRawVideoFrameCrop]
/// 解析。
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:fushi_engine/ocr/ocr_types.dart' show OcrRgbaImage;

/// media_kit 补丁里的原始帧格式名。
const String kRawVideoFrameFormat = 'image/x-fushi-bgra';

/// 裁剪字节头长度。
const int kRawVideoFrameCropHeaderBytes = 24;

/// 补丁在截帧 isolate 上调用的变换：整帧尺寸、行跨度和 mpv 缓冲的视图（只在调用期间
/// 有效），返回要传回主 isolate 的字节。会被发到截帧 isolate，只能捕获可发送的值。
typedef RawVideoFrameTransform =
    Uint8List? Function(int width, int height, int stride, Uint8List bgra);

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

  /// 至少 `height * stride` 字节。
  final Uint8List bgra;
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

/// 整帧比例矩形：整帧转 RGBA（暂停 OCR 识别整帧）。
const Rect kRawVideoFrameWhole = Rect.fromLTRB(0, 0, 1, 1);

/// 整帧转成不透明 RGBA 的截帧变换（暂停 OCR 用，交给补丁在截帧 isolate 上跑）：
/// 不编 PNG，结果经 [parseRawVideoFrameRgba] 交给 OCR 引擎。
Uint8List? rawVideoFrameRgbaTransform(
  int width,
  int height,
  int stride,
  Uint8List bgra,
) => cropRawVideoFrameBytes(
  RawVideoFrame(width: width, height: height, stride: stride, bgra: bgra),
  kRawVideoFrameWhole,
);

/// 解析 [rawVideoFrameRgbaTransform] 的输出：整帧的不透明 RGBA（原字节的视图，不再拷贝）；
/// 字节不合法或不是整帧返回 null。
OcrRgbaImage? parseRawVideoFrameRgba(Uint8List? bytes) {
  final RawVideoFrameCrop? crop = parseRawVideoFrameCrop(bytes);
  if (crop == null ||
      crop.width != crop.frameWidth ||
      crop.height != crop.frameHeight) {
    return null;
  }
  return OcrRgbaImage(rgba: crop.rgba, width: crop.width, height: crop.height);
}

/// 按整帧比例矩形 [fraction] 裁剪的截帧变换（交给补丁在截帧 isolate 上跑）。
///
/// 顶层函数造闭包：闭包只捕获 [fraction]，能安全发到截帧 isolate。
RawVideoFrameTransform rawVideoFrameCropTransform(Rect fraction) =>
    (int width, int height, int stride, Uint8List bgra) =>
        cropRawVideoFrameBytes(
          RawVideoFrame(
            width: width,
            height: height,
            stride: stride,
            bgra: bgra,
          ),
          fraction,
        );

/// 按整帧比例矩形 [fraction] 裁出一块、转成 RGBA，打包成带头的字节（布局见库注释）；
/// 帧数据不完整或裁剪为空返回 null。只拷贝裁剪内的像素。
Uint8List? cropRawVideoFrameBytes(RawVideoFrame frame, Rect fraction) {
  if (frame.width <= 0 ||
      frame.height <= 0 ||
      frame.stride < frame.width * 4 ||
      frame.bgra.length < frame.height * frame.stride) {
    return null;
  }
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
  final Uint8List out = Uint8List(kRawVideoFrameCropHeaderBytes + w * h * 4);
  ByteData.sublistView(out, 0, kRawVideoFrameCropHeaderBytes)
    ..setUint32(0, frame.width, Endian.little)
    ..setUint32(4, frame.height, Endian.little)
    ..setUint32(8, left, Endian.little)
    ..setUint32(12, top, Endian.little)
    ..setUint32(16, w, Endian.little)
    ..setUint32(20, h, Endian.little);
  final Uint8List src = frame.bgra;
  if (Endian.host == Endian.little &&
      src.offsetInBytes % 4 == 0 &&
      frame.stride % 4 == 0) {
    // 按 32 位字换通道：BGRA 小端字 = A<<24|R<<16|G<<8|B → RGBA 小端字 =
    // 0xFF<<24|B<<16|G<<8|R（alpha 置满：mpv 的 bgr0 第四字节未定义）。整帧 1080p
    // 是 200 万像素，逐字节写要多花数倍时间。
    final Uint32List out32 = out.buffer.asUint32List(
      kRawVideoFrameCropHeaderBytes,
      w * h,
    );
    final Uint32List src32 = src.buffer.asUint32List(
      src.offsetInBytes,
      src.length ~/ 4,
    );
    final int strideWords = frame.stride ~/ 4;
    int o = 0;
    for (int y = 0; y < h; y++) {
      int i = (top + y) * strideWords + left;
      for (int x = 0; x < w; x++) {
        final int v = src32[i++];
        out32[o++] =
            0xFF000000 | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF);
      }
    }
    return out;
  }
  int o = kRawVideoFrameCropHeaderBytes;
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
  return out;
}

/// 解析 [cropRawVideoFrameBytes] 的输出（RGBA 是原字节的视图，不再拷贝）；头部缺失、
/// 尺寸非正、越出整帧或数据长度对不上返回 null。
RawVideoFrameCrop? parseRawVideoFrameCrop(Uint8List? bytes) {
  if (bytes == null || bytes.length < kRawVideoFrameCropHeaderBytes) {
    return null;
  }
  final ByteData header = ByteData.sublistView(
    bytes,
    0,
    kRawVideoFrameCropHeaderBytes,
  );
  final int frameWidth = header.getUint32(0, Endian.little);
  final int frameHeight = header.getUint32(4, Endian.little);
  final int left = header.getUint32(8, Endian.little);
  final int top = header.getUint32(12, Endian.little);
  final int width = header.getUint32(16, Endian.little);
  final int height = header.getUint32(20, Endian.little);
  if (width <= 0 ||
      height <= 0 ||
      left + width > frameWidth ||
      top + height > frameHeight) {
    return null;
  }
  final int end = kRawVideoFrameCropHeaderBytes + width * height * 4;
  if (bytes.length != end) return null;
  return RawVideoFrameCrop(
    rgba: Uint8List.sublistView(bytes, kRawVideoFrameCropHeaderBytes, end),
    left: left,
    top: top,
    width: width,
    height: height,
    frameWidth: frameWidth,
    frameHeight: frameHeight,
  );
}

/// [cropRawVideoFrameBytes] + [parseRawVideoFrameCrop]：同一 isolate 内直接裁剪。
RawVideoFrameCrop? cropRawVideoFrame(RawVideoFrame frame, Rect fraction) =>
    parseRawVideoFrameCrop(cropRawVideoFrameBytes(frame, fraction));
