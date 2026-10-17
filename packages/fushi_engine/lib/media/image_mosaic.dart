/// 制卡卡图「打码」：在图像局部打马赛克（像素块取平均）。
///
/// 预览（Flutter 侧解码出的 RGBA）与出卡（`package:image` 解码的原图）走**同一个**
/// 纯函数 [applyMosaicRgba]：块边长按图像长边的固定比例取（[mosaicBlockSizeFor]），
/// 所以缩小的预览图与全尺寸的出卡图打出来的块数、位置一致——用户在对话框里看到的
/// 就是卡上的样子。
///
/// 坐标一律是相对**未裁切原图**的 0..1 归一化矩形（[MiningMosaicRegion]）。
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart' show MiningMosaicRegion;
import 'package:image/image.dart' as img;

/// 马赛克块边长占图像长边的比例：长边 1920 → 40px 一块，糊到看不出细节，又能看出
/// 大致色块（不至于像一块纯色贴纸）。
const double kMosaicBlockFraction = 1 / 48;

/// 块边长下限（像素）：小图上也要真的糊掉。
const int kMosaicMinBlockSize = 4;

/// 这张图打码用的块边长（像素）。
int mosaicBlockSizeFor(int width, int height) {
  final int longEdge = math.max(width, height);
  return math.max(
    kMosaicMinBlockSize,
    (longEdge * kMosaicBlockFraction).round(),
  );
}

/// 归一化区域换成像素范围 `[x0, x1) × [y0, y1)`：向外取整（宁可多糊一像素，也不漏
/// 一条原图边），夹进图像。空区域 / 图像为空返回 null。
({int x0, int y0, int x1, int y1})? mosaicPixelBounds(
  MiningMosaicRegion region,
  int width,
  int height,
) {
  if (width <= 0 || height <= 0) return null;
  final MiningMosaicRegion r = region.clamped();
  final int x0 = (r.left * width).floor().clamp(0, width);
  final int y0 = (r.top * height).floor().clamp(0, height);
  final int x1 = (r.right * width).ceil().clamp(0, width);
  final int y1 = (r.bottom * height).ceil().clamp(0, height);
  if (x1 <= x0 || y1 <= y0) return null;
  return (x0: x0, y0: y0, x1: x1, y1: y1);
}

/// 就地给 RGBA8888 像素缓冲 [rgba]（[width] × [height]，行紧排）打码。
///
/// 网格锚定在图像原点（不随区域起点漂）：块 = `[k·s, (k+1)·s)`，与区域相交的块整块
/// 取平均（四个通道各自平均，平均取自整块原像素，块被图像边缘截断时只取图内部分），
/// 只把落在任一区域内的像素写成平均色。每块只算一次、平均只读原像素，所以多个区域
/// 重叠、先后顺序不同，结果都一样。
///
/// [blockSize] 缺省按 [mosaicBlockSizeFor]。缓冲长度不符时抛 [ArgumentError]。
void applyMosaicRgba(
  Uint8List rgba,
  int width,
  int height,
  List<MiningMosaicRegion> regions, {
  int? blockSize,
}) {
  if (regions.isEmpty || width <= 0 || height <= 0) return;
  if (rgba.length != width * height * 4) {
    throw ArgumentError.value(
      rgba.length,
      'rgba',
      'expected ${width * height * 4} bytes for ${width}x$height',
    );
  }
  final int s = math.max(1, blockSize ?? mosaicBlockSizeFor(width, height));
  final List<({int x0, int y0, int x1, int y1})> bounds =
      <({int x0, int y0, int x1, int y1})>[
        for (final MiningMosaicRegion region in regions)
          if (mosaicPixelBounds(region, width, height)
              case final ({int x0, int y0, int x1, int y1}) b)
            b,
      ];
  if (bounds.isEmpty) return;

  // 收集被任一区域碰到的块（按块坐标去重）。
  final int cols = (width + s - 1) ~/ s;
  final Set<int> cells = <int>{};
  for (final ({int x0, int y0, int x1, int y1}) b in bounds) {
    for (int cy = b.y0 ~/ s; cy * s < b.y1; cy++) {
      for (int cx = b.x0 ~/ s; cx * s < b.x1; cx++) {
        cells.add(cy * cols + cx);
      }
    }
  }

  bool covered(int x, int y) {
    for (final ({int x0, int y0, int x1, int y1}) b in bounds) {
      if (x >= b.x0 && x < b.x1 && y >= b.y0 && y < b.y1) return true;
    }
    return false;
  }

  for (final int cell in cells) {
    final int cx0 = (cell % cols) * s;
    final int cy0 = (cell ~/ cols) * s;
    final int cx1 = math.min(cx0 + s, width);
    final int cy1 = math.min(cy0 + s, height);
    int r = 0, g = 0, bl = 0, a = 0;
    for (int y = cy0; y < cy1; y++) {
      int i = (y * width + cx0) * 4;
      for (int x = cx0; x < cx1; x++, i += 4) {
        r += rgba[i];
        g += rgba[i + 1];
        bl += rgba[i + 2];
        a += rgba[i + 3];
      }
    }
    final int n = (cx1 - cx0) * (cy1 - cy0);
    final int ar = (r / n).round();
    final int ag = (g / n).round();
    final int ab = (bl / n).round();
    final int aa = (a / n).round();
    for (int y = cy0; y < cy1; y++) {
      int i = (y * width + cx0) * 4;
      for (int x = cx0; x < cx1; x++, i += 4) {
        if (!covered(x, y)) continue;
        rgba[i] = ar;
        rgba[i + 1] = ag;
        rgba[i + 2] = ab;
        rgba[i + 3] = aa;
      }
    }
  }
}

/// 给一张已解码的 [image] 打码，返回新图（RGBA8888）。[regions] 为空时原样返回。
img.Image applyMosaicToImage(
  img.Image image,
  List<MiningMosaicRegion> regions,
) {
  if (regions.isEmpty) return image;
  final img.Image rgbaImage =
      image.format == img.Format.uint8 &&
          image.numChannels == 4 &&
          !image.hasPalette
      ? image
      : image.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
  final Uint8List bytes = Uint8List.fromList(
    rgbaImage.getBytes(order: img.ChannelOrder.rgba),
  );
  applyMosaicRgba(bytes, rgbaImage.width, rgbaImage.height, regions);
  return img.Image.fromBytes(
    width: rgbaImage.width,
    height: rgbaImage.height,
    bytes: bytes.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
}

/// [mosaicEncodedImage] 的产物。
class MosaicEncodedImage {
  const MosaicEncodedImage({required this.bytes, required this.isPng});

  final Uint8List bytes;

  /// true = PNG；false = JPEG。落盘扩展名必须跟着它走（Anki 按扩展名判 MIME）。
  final bool isPng;

  String get extension => isPng ? 'png' : 'jpg';
}

/// 解码 [bytes]（转正 EXIF 方向，与漫画裁切同一坐标系）→ 打码 → 重新编码：源是 PNG
/// 编 PNG（无损，后续还会再降采样一次），其余编 JPEG（[jpegQuality]）。
///
/// 解不开返回 null。调用方据此**放弃卡图**，绝不能退回没打码的原图。
MosaicEncodedImage? mosaicEncodedImage(
  Uint8List bytes,
  List<MiningMosaicRegion> regions, {
  int jpegQuality = 92,
}) {
  if (bytes.isEmpty) return null;
  try {
    final img.ImageFormat format = img.findFormatForData(bytes);
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
      return null;
    }
    final img.Image out = applyMosaicToImage(
      img.bakeOrientation(decoded),
      regions,
    );
    final bool png = format == img.ImageFormat.png;
    return MosaicEncodedImage(
      bytes: png
          ? img.encodePng(out)
          : img.encodeJpg(out, quality: jpegQuality.clamp(1, 100)),
      isPng: png,
    );
  } catch (_) {
    return null;
  }
}

/// [mosaicEncodedImage] 的后台 isolate 变体（整图解码 + 编码是纯 Dart CPU 重活）。
Future<MosaicEncodedImage?> mosaicEncodedImageAsync(
  Uint8List bytes,
  List<MiningMosaicRegion> regions, {
  int jpegQuality = 92,
}) {
  final List<MiningMosaicRegion> frozen = List<MiningMosaicRegion>.of(regions);
  return Isolate.run<MosaicEncodedImage?>(
    () => mosaicEncodedImage(bytes, frozen, jpegQuality: jpegQuality),
  );
}
