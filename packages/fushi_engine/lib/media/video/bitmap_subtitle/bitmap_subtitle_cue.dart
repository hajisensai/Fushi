/// 位图字幕（PGS / VobSub / DVB）的公共形状：一条 cue = 一段显示区间 + 一张惰性渲染的
/// 位图。整轨转文字、逐句时间表、模糊遮蔽只认这一层，不关心位图来自哪种编码。
///
/// 渲染统一走 [composeBitmapSubtitleImage]：不透明黑底、Alpha 按本 cue 调色板的最大
/// 不透明度归一化（淡入帧也按满不透明渲染）——OCR 只关心字形，黑底上的浅色字最好认。
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:image/image.dart' as img;

/// 单个位图对象 / 区域的边长上限。BD PGS 与 DVB 的对象都不超过 4096（DVB 对象坐标
/// 只有 12 bit，DVD 同样）；码流声明更大的尺寸只可能是损坏数据——照单全收时
/// 65535×65535 的声明会一次分配 4 GB 平面把进程打爆。
const int kBitmapSubtitleMaxDimension = 4096;

/// 码流声明的位图尺寸能否解码：正数且两边都不超过 [kBitmapSubtitleMaxDimension]。
bool isDecodableBitmapSubtitleSize(int width, int height) =>
    width > 0 &&
    height > 0 &&
    width <= kBitmapSubtitleMaxDimension &&
    height <= kBitmapSubtitleMaxDimension;

/// 位图外包框（画布坐标系，像素；right / bottom 为开区间）。
typedef BitmapSubtitleBounds = ({int left, int top, int right, int bottom});

/// 一条位图字幕。实现必须只持有可跨 isolate 复制的数据（渲染在后台 isolate 里做）。
abstract interface class BitmapSubtitleCue {
  /// 相对抽轨时间轴原点（ffmpeg 抽取时已减去容器起点）的毫秒。
  int get startMs;
  int get endMs;

  /// 位图坐标所在的合成画布尺寸；码流没写（0）时为 0，调用方退回视频分辨率。
  int get canvasWidth;
  int get canvasHeight;

  /// 可见位图的并集外包框。
  BitmapSubtitleBounds get bounds;

  /// 强制字幕（DVD `FSTA_DSP`；其它编码恒为 false）。
  bool get forced;

  /// 黑底合成、四周留 [padding] 像素的不透明 RGBA。
  BitmapSubtitleImage renderRgba({int padding = 16});

  /// 与 [renderRgba] 同一张图的 PNG。
  Uint8List renderPng({int padding = 16});
}

/// 一条 cue 渲染出的不透明 RGBA 像素（黑底，[width]×[height]×4 字节）。
class BitmapSubtitleImage {
  const BitmapSubtitleImage({
    required this.rgba,
    required this.width,
    required this.height,
  });

  final Uint8List rgba;
  final int width;
  final int height;

  /// 像素内容指纹：同一张字幕位图（淡入淡出 / 换位置 / 重发而重复显示同一内容）只识别
  /// 一次。
  String get contentKey => '${width}x$height:${sha1.convert(rgba).toString()}';

  /// 编码成 PNG（只在要交给大模型 / 非本机引擎时才需要）。
  Uint8List encodePng() => img.encodePng(toImage());

  img.Image toImage() => img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
  );
}

/// 合成时的一层：一块调色板索引平面贴到画布 ([x], [y])。
///
/// 索引平面按 [stride] 跨行，从 ([sourceX], [sourceY]) 起取 [width]×[height]（PGS 的
/// 对象裁剪就是这样表达的）。[palette] 是 ARGB，下标越界的索引按透明处理。
class BitmapSubtitleLayer {
  const BitmapSubtitleLayer({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.indices,
    required this.stride,
    required this.palette,
    this.sourceX = 0,
    this.sourceY = 0,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final Uint8List indices;
  final int stride;
  final int sourceX;
  final int sourceY;
  final Uint32List palette;
}

/// 若干层的并集外包框；没有任何层时为 (0, 0, 0, 0)。
BitmapSubtitleBounds bitmapSubtitleLayerBounds(
  Iterable<({int x, int y, int width, int height})> layers,
) {
  int l = 1 << 30, t = 1 << 30, r = 0, b = 0;
  bool any = false;
  for (final ({int x, int y, int width, int height}) layer in layers) {
    any = true;
    if (layer.x < l) l = layer.x;
    if (layer.y < t) t = layer.y;
    if (layer.x + layer.width > r) r = layer.x + layer.width;
    if (layer.y + layer.height > b) b = layer.y + layer.height;
  }
  if (!any) return (left: 0, top: 0, right: 0, bottom: 0);
  return (left: l, top: t, right: r, bottom: b);
}

/// 把 [layers] 合成到 [bounds] 外扩 [padding] 的不透明黑底画布上。
///
/// Alpha 按所有层调色板里的最大不透明度归一化：淡入帧（整体半透明）也按满不透明渲染；
/// 调色板全透明时得到纯黑图。半透明像素按 alpha 预乘到黑底上（描边的抗锯齿边缘变暗，
/// 字形主体保持原色）。
img.Image composeBitmapSubtitleImage({
  required BitmapSubtitleBounds bounds,
  required List<BitmapSubtitleLayer> layers,
  int padding = 16,
}) {
  final int w = (bounds.right - bounds.left + padding * 2).clamp(1, 1 << 15);
  final int h = (bounds.bottom - bounds.top + padding * 2).clamp(1, 1 << 15);
  final img.Image canvas = img.Image(width: w, height: h, numChannels: 4)
    ..clear(img.ColorRgba8(0, 0, 0, 255));
  int maxAlpha = 0;
  for (final BitmapSubtitleLayer layer in layers) {
    for (final int argb in layer.palette) {
      final int a = argb >>> 24;
      if (a > maxAlpha) maxAlpha = a;
    }
  }
  if (maxAlpha == 0) return canvas;
  final int originX = bounds.left - padding;
  final int originY = bounds.top - padding;
  for (final BitmapSubtitleLayer layer in layers) {
    final Uint32List palette = layer.palette;
    for (int y = 0; y < layer.height; y++) {
      final int row = (layer.sourceY + y) * layer.stride + layer.sourceX;
      final int cy = layer.y + y - originY;
      if (cy < 0 || cy >= h) continue;
      for (int x = 0; x < layer.width; x++) {
        final int at = row + x;
        if (at >= layer.indices.length) break;
        final int index = layer.indices[at];
        if (index >= palette.length) continue;
        final int argb = palette[index];
        final int a = argb >>> 24;
        if (a == 0) continue;
        final int cx = layer.x + x - originX;
        if (cx < 0 || cx >= w) continue;
        final double k = a >= maxAlpha ? 1 : a / maxAlpha;
        canvas.setPixelRgb(
          cx,
          cy,
          (((argb >> 16) & 0xFF) * k).round(),
          (((argb >> 8) & 0xFF) * k).round(),
          ((argb & 0xFF) * k).round(),
        );
      }
    }
  }
  return canvas;
}

/// [composeBitmapSubtitleImage] 的结果转成 [BitmapSubtitleImage]。
BitmapSubtitleImage bitmapSubtitleImageOf(img.Image canvas) =>
    BitmapSubtitleImage(
      rgba: canvas.getBytes(order: img.ChannelOrder.rgba),
      width: canvas.width,
      height: canvas.height,
    );

/// BT.601 YCbCr（studio range）→ ARGB（DVD / DVB 的 SD 调色板口径）。
int bt601YCbCrToArgb(int yy, int cr, int cb, int alpha) {
  final double y = 1.164 * (yy - 16);
  final double r = y + 1.596 * (cr - 128);
  final double g = y - 0.391 * (cb - 128) - 0.813 * (cr - 128);
  final double b = y + 2.018 * (cb - 128);
  int c(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
  return (alpha << 24) | (c(r) << 16) | (c(g) << 8) | c(b);
}
