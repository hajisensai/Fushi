/// 漫画制卡卡图裁切：从**原页图**（不是屏幕渲染）裁出一块并按制卡图片质量档缩放编码。
///
/// 坐标系与分镜检测 `PanelRect` / 制卡覆盖项 `MiningImageCrop` 相同：相对
/// `bakeOrientation` 之后原页图的 0..1 归一化矩形。所以「所在分镜」与用户框选都能
/// 原样落进来，不必关心屏幕上的旋转 / 拆页 / 裁边。
///
/// 解码 + 裁切 + 缩放 + 编码是纯 Dart 的同步大循环（一张 2000×3000 的页数百毫秒），
/// 宿主一律经 [cropMangaPageAsync] / [mangaPageOrientedSizeAsync] 送进后台 isolate。
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart' show MiningMosaicRegion;
import 'package:fushi_engine/media/image_mosaic.dart';
import 'package:image/image.dart' as img;

/// 裁出的卡图编码。
enum MangaCropEncoding {
  /// 有损，吃质量档的 JPEG 质量。
  jpeg,

  /// 无损：源页本就是 PNG 时保持 PNG（网点 / 线稿经 JPEG 再压一次会糊）。
  png,
}

/// 一次裁切的产物。
class MangaPageCropResult {
  const MangaPageCropResult({
    required this.bytes,
    required this.encoding,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final MangaCropEncoding encoding;
  final int width;
  final int height;

  /// 落盘扩展名（不带点）。两个 Anki 后端都按扩展名推导媒体类型，必须与真实编码一致。
  String get extension => encoding == MangaCropEncoding.png ? 'png' : 'jpg';
}

/// 原页图在 `bakeOrientation` 之后的像素尺寸；认不出 / 解码失败返回 null。
///
/// JPEG 走快路径：只读头部尺寸 + EXIF 方向（5..8 是转了 90°，宽高互换），不解整图。
/// 其它格式整图解码再 bake，保证与 [cropMangaPage] 用的是同一个坐标系。
({int width, int height})? mangaPageOrientedSize(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  try {
    final img.Decoder? decoder = img.findDecoderForData(bytes);
    if (decoder == null) return null;
    if (decoder is img.JpegDecoder) {
      final img.DecodeInfo? info = decoder.startDecode(bytes);
      if (info != null && info.width > 0 && info.height > 0) {
        final int? orientation = img.decodeJpgExif(bytes)?.imageIfd.orientation;
        final bool swapped =
            orientation != null && orientation >= 5 && orientation <= 8;
        return swapped
            ? (width: info.height, height: info.width)
            : (width: info.width, height: info.height);
      }
    }
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final img.Image oriented = img.bakeOrientation(decoded);
    return (width: oriented.width, height: oriented.height);
  } catch (_) {
    // 嗅探解码器本身就可能对损坏字节抛（GIF 头越界等），与解码失败同一处理。
    return null;
  }
}

/// [mangaPageOrientedSize] 的后台 isolate 变体。
Future<({int width, int height})?> mangaPageOrientedSizeAsync(
  Uint8List bytes,
) =>
    Isolate.run<({int width, int height})?>(() => mangaPageOrientedSize(bytes));

/// 把归一化矩形换成像素矩形：向外取整（宁可多一像素也不切掉边上的字），夹进页面，
/// 并保证至少 1×1。纯函数，便于单测。
({int x, int y, int width, int height}) mangaCropPixelRect({
  required int pageWidth,
  required int pageHeight,
  required double left,
  required double top,
  required double right,
  required double bottom,
}) {
  double unit(double v) => v.isNaN ? 0 : (v < 0 ? 0 : (v > 1 ? 1 : v));
  final double l = math.min(unit(left), unit(right));
  final double r = math.max(unit(left), unit(right));
  final double t = math.min(unit(top), unit(bottom));
  final double b = math.max(unit(top), unit(bottom));
  final int x0 = (l * pageWidth).floor().clamp(0, pageWidth - 1);
  final int y0 = (t * pageHeight).floor().clamp(0, pageHeight - 1);
  final int x1 = (r * pageWidth).ceil().clamp(x0 + 1, pageWidth);
  final int y1 = (b * pageHeight).ceil().clamp(y0 + 1, pageHeight);
  return (x: x0, y: y0, width: x1 - x0, height: y1 - y0);
}

/// 从原页图 [bytes] 裁出归一化矩形 [left]..[bottom]，长边超过 [maxLongEdge] 时等比缩小
/// （只缩不放；0 = 不缩，对应质量档「最高」），再编码。
///
/// [mosaic]：打码区域（相对**未裁切**原页图，与 [left]..[bottom] 同一坐标系），在裁切
/// 之前打到整页上——块大小按整页算，与对话框里整页预览上看到的一致。
///
/// 编码：源是 PNG → PNG；其余 → JPEG（[quality]）。
/// 解码失败（AVIF 等 `package:image` 不认识的格式、损坏字节）返回 null——调用方退回
/// 整页原图，绝不让裁切把一张能用的卡图变成没有图。
MangaPageCropResult? cropMangaPage(
  Uint8List bytes, {
  required double left,
  required double top,
  required double right,
  required double bottom,
  required int maxLongEdge,
  required int quality,
  List<MiningMosaicRegion> mosaic = const <MiningMosaicRegion>[],
}) {
  if (bytes.isEmpty) return null;
  try {
    final img.ImageFormat format = img.findFormatForData(bytes);
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
      return null;
    }
    // 分镜检测与 OCR 都在 bake 之后的图上给坐标，这里必须同一坐标系。
    final img.Image page = applyMosaicToImage(
      img.bakeOrientation(decoded),
      mosaic,
    );
    final ({int x, int y, int width, int height}) rect = mangaCropPixelRect(
      pageWidth: page.width,
      pageHeight: page.height,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
    img.Image out = img.copyCrop(
      page,
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
    );
    final int longEdge = math.max(out.width, out.height);
    if (maxLongEdge > 0 && longEdge > maxLongEdge) {
      final double scale = maxLongEdge / longEdge;
      out = img.copyResize(
        out,
        width: math.max(1, (out.width * scale).round()),
        height: math.max(1, (out.height * scale).round()),
        // 缩小用 average：漫画网点用最近邻 / 双线性缩会出摩尔纹。
        interpolation: img.Interpolation.average,
      );
    }
    final MangaCropEncoding encoding = format == img.ImageFormat.png
        ? MangaCropEncoding.png
        : MangaCropEncoding.jpeg;
    final Uint8List encoded = switch (encoding) {
      MangaCropEncoding.png => img.encodePng(out),
      MangaCropEncoding.jpeg => img.encodeJpg(
        out,
        quality: quality.clamp(1, 100),
      ),
    };
    return MangaPageCropResult(
      bytes: encoded,
      encoding: encoding,
      width: out.width,
      height: out.height,
    );
  } catch (_) {
    return null;
  }
}

/// [cropMangaPage] 的后台 isolate 变体。顶层函数：闭包只捕获参数，不会把宿主的
/// 不可发送对象（State 等）带过 isolate 边界。
Future<MangaPageCropResult?> cropMangaPageAsync(
  Uint8List bytes, {
  required double left,
  required double top,
  required double right,
  required double bottom,
  required int maxLongEdge,
  required int quality,
  List<MiningMosaicRegion> mosaic = const <MiningMosaicRegion>[],
}) {
  final List<MiningMosaicRegion> frozen = List<MiningMosaicRegion>.of(mosaic);
  return Isolate.run<MangaPageCropResult?>(
    () => cropMangaPage(
      bytes,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      maxLongEdge: maxLongEdge,
      quality: quality,
      mosaic: frozen,
    ),
  );
}
