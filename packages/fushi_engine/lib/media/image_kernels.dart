/// `img.Image` 与 native/fushi_compute 图像内核（`FushiComputeImage`）之间的适配。
///
/// 缩放与「缩放 + 转模型输入张量」只有原生这一份实现；这里负责把 `package:image` 的
/// 语义边角对齐到内核能吃的形态，结果与 `img.copyResize`（+ `img.copyCrop`）逐位相同：
/// - EXIF 方向不是 1 时先 `bakeOrientation`（`copyResize` 自己也这么做）；
/// - 调色板图先展开成 uint8 并强制最近邻（`copyResize` 对调色板图同样强制最近邻）；
/// - uint8 以外的格式（16 位 / 浮点 / 1～4 位）先 `convert` 成 uint8。旧的纯 Dart 路径对
///   这些格式按 0..255 取值，结果本来就是错的，这里是有意的行为变化；
/// - 多帧图逐帧缩放，元数据（EXIF / ICC / 帧信息）随 `Image.fromResized` 带过去。
///
/// 原生库缺失时 [FushiComputeImage.instance] 抛 [FushiComputeUnavailableError]，不退回。
library;

import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:image/image.dart' as img;

/// 内核能直接吃的 uint8 帧（已转正、无调色板）；[interpolation] 已按调色板规则修正。
({img.Image image, img.Interpolation interpolation}) _kernelReady(
  img.Image src,
  img.Interpolation interpolation, {
  bool bake = true,
}) {
  img.Image image = src;
  img.Interpolation interp = interpolation;
  if (image.hasPalette) {
    interp = img.Interpolation.nearest;
  }
  if (bake &&
      image.exif.imageIfd.hasOrientation &&
      image.exif.imageIfd.orientation != 1) {
    image = img.bakeOrientation(image);
  }
  if (image.hasPalette || image.format != img.Format.uint8) {
    image = image.convert(
      format: img.Format.uint8,
      numChannels: image.numChannels,
    );
  }
  return (image: image, interpolation: interp);
}

FfcInterpolation _ffc(img.Interpolation interpolation) =>
    switch (interpolation) {
      img.Interpolation.nearest => FfcInterpolation.nearest,
      img.Interpolation.linear => FfcInterpolation.linear,
      img.Interpolation.average => FfcInterpolation.average,
      img.Interpolation.cubic => throw ArgumentError.value(
        interpolation,
        'interpolation',
        'cubic is not supported by the native image kernels',
      ),
    };

/// `img.copyResize(crop == null ? src : img.copyCrop(src, crop), width:, height:,
/// interpolation:)` 的原生实现（不保持比例）。
img.Image resizeImageExact(
  img.Image src, {
  ({int x, int y, int width, int height})? crop,
  required int width,
  required int height,
  img.Interpolation interpolation = img.Interpolation.nearest,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('invalid size ${width}x$height');
  }
  img.Image source = src;
  ({int x, int y, int width, int height})? rect = crop;
  if (rect != null &&
      source.exif.imageIfd.hasOrientation &&
      source.exif.imageIfd.orientation != 1) {
    // 旧语义是「先按存储方向裁，再由 copyResize 转正」：裁切只是搬像素，直接用 copyCrop。
    source = img.copyCrop(
      source,
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
    );
    rect = null;
  }
  final ({img.Image image, img.Interpolation interpolation}) ready =
      _kernelReady(source, interpolation);
  final img.Image base = ready.image;
  final FushiComputeImage ops = FushiComputeImage.instance;
  img.Image? first;
  for (final img.Image frame in base.frames) {
    final Uint8List pixels = ops.resize(
      frame.toUint8List(),
      stride: frame.rowStride,
      channels: frame.numChannels,
      cropX: rect?.x ?? 0,
      cropY: rect?.y ?? 0,
      cropWidth: rect?.width ?? frame.width,
      cropHeight: rect?.height ?? frame.height,
      dstWidth: width,
      dstHeight: height,
      interpolation: _ffc(ready.interpolation),
    );
    final img.Image dst = img.Image.fromResized(
      frame,
      width: width,
      height: height,
      noAnimation: true,
    );
    dst.toUint8List().setAll(0, pixels);
    if (first == null) {
      first = dst;
    } else {
      first.addFrame(dst);
    }
  }
  return first!;
}

/// 把 [src]（可选先裁 [crop]）缩放到 [width] × [height] 后转成 CHW float32：
/// `out[c][y][x] = (v / 255 - mean[c]) / std[c]`，[bgr] 时输出通道 0 = B。
///
/// [canvasWidth] × [canvasHeight] 与缩放尺寸不同时把缩放结果按 ([padX], [padY])
/// 合成到 114 灰画布上（`rtdetrPreprocess` 的 letterbox）；[planeWidth] 大于画布宽时
/// 每行右侧填 0（`ppRecPreprocess`）。[bake] 为 false 时不转正 EXIF 方向（调用方在
/// 尺寸已对上时直接读源图像素的旧语义）。
Float32List imageToChw(
  img.Image src, {
  ({int x, int y, int width, int height})? crop,
  required int width,
  required int height,
  img.Interpolation interpolation = img.Interpolation.linear,
  int? canvasWidth,
  int? canvasHeight,
  int padX = 0,
  int padY = 0,
  int? planeWidth,
  required bool bgr,
  List<double> mean = const <double>[0, 0, 0],
  List<double> std = const <double>[1, 1, 1],
  bool bake = true,
}) {
  final ({img.Image image, img.Interpolation interpolation}) ready =
      _kernelReady(src, interpolation, bake: bake);
  final img.Image image = ready.image;
  return FushiComputeImage.instance.resizeToChw(
    image.toUint8List(),
    stride: image.rowStride,
    channels: image.numChannels,
    cropX: crop?.x ?? 0,
    cropY: crop?.y ?? 0,
    cropWidth: crop?.width ?? image.width,
    cropHeight: crop?.height ?? image.height,
    dstWidth: width,
    dstHeight: height,
    interpolation: _ffc(ready.interpolation),
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    padX: padX,
    padY: padY,
    planeWidth: planeWidth,
    bgr: bgr,
    mean: mean,
    std: std,
  );
}

/// [image] 首帧的 uint8 像素（已展开调色板 / 转成 uint8，不转正方向）。
({Uint8List pixels, int stride, int channels, int width, int height})
uint8Pixels(img.Image image) {
  final img.Image ready = image.hasPalette || image.format != img.Format.uint8
      ? image.convert(format: img.Format.uint8, numChannels: image.numChannels)
      : image;
  return (
    pixels: ready.toUint8List(),
    stride: ready.rowStride,
    channels: ready.numChannels,
    width: ready.width,
    height: ready.height,
  );
}

/// 编码图片字节 → JPEG 字节（4:4:4，[quality] 1..100，忽略 alpha），解码与编码都在原生
/// 内核。JPEG 编码器是 `jpeg-encoder`：字节与 `img.encodeJpg` 不同，同质量下 PSNR 相同
/// （2026-10-18 实测 1080×1920 文本帧 q98：49.04 vs 49.05 dB，体积 +0.5%）。坏字节返回 null。
Uint8List? encodeImageAsJpeg(Uint8List bytes, {required int quality}) =>
    FushiComputeImage.instance.toJpeg(bytes, quality: quality);

/// 原生 PNG 解码，像素布局同 `img.decodePng`（灰度 1 通道 / 灰度 + alpha 2 通道 / RGB / RGBA，
/// 调色板展开，不转方向）；不是 PNG 或解不开返回 null。16 位与 1/2/4 位灰度一律给 8 位。
img.Image? decodePngNative(Uint8List bytes) {
  final ({Uint8List pixels, int width, int height, int channels})? d =
      FushiComputeImage.instance.decodePng(bytes);
  if (d == null) return null;
  return img.Image.fromBytes(
    width: d.width,
    height: d.height,
    bytes: d.pixels.buffer,
    bytesOffset: d.pixels.offsetInBytes,
    numChannels: d.channels,
  );
}

/// 原生解码（见 [decodeImageNative]）连同识别出的格式。
({img.Image image, FfcImageFormat format})? decodeImageWithFormat(
  Uint8List bytes, {
  bool orient = true,
}) {
  final FfcDecodedImage? d = FushiComputeImage.instance.decode(
    bytes,
    orient: orient,
  );
  if (d == null) return null;
  return (
    image: img.Image.fromBytes(
      width: d.width,
      height: d.height,
      bytes: d.pixels.buffer,
      bytesOffset: d.pixels.offsetInBytes,
      numChannels: d.channels,
    ),
    format: d.format,
  );
}

/// 图片字节 → uint8 RGB / RGBA 的 `img.Image`（原生内核；`img.decodeImage` 在本仓图像管线里
/// 的唯一替代）。
///
/// - [orient]（默认）时按 EXIF 方向转正，结果不再带方向标记（等价于旧的
///   `bakeOrientation(decodeImage(...))`）。
/// - 灰度展开成 RGB、16 位截成 8 位、调色板展开，多帧格式只取首帧。
/// - JPEG 的像素与旧的 `package:image` 解码有 ±1 的差（3.5～4.8% 的通道值），下游影响见
///   PR #2330；PNG 等无损格式逐字节相同。
/// - 认得 JPEG / PNG / GIF / WebP / BMP / TIFF / TGA / ICO / PNM / AVIF；认不出或坏字节返回 null。
///   AVIF（含 grid 拼图、alpha）的 clap / irot / imir 是 HEIF 的必选显示变换，与 [orient] 无关、
///   总是应用——与 WebView 里显示的页面同一坐标系。
img.Image? decodeImageNative(Uint8List bytes, {bool orient = true}) =>
    decodeImageWithFormat(bytes, orient: orient)?.image;

/// 只读文件头的宽高（[orient] 时按 EXIF 方向换算）与格式；认不出返回 null。
({int width, int height, FfcImageFormat format})? probeImageNative(
  Uint8List bytes, {
  bool orient = true,
}) => FushiComputeImage.instance.probe(bytes, orient: orient);

/// 两张图（编码字节）左图右缘与右图左缘的相似度（0..1，`EpubEdgeMatcher` 用）；任一张解不开
/// 返回 null。解码、按高 [sampleHeight] 最近邻缩放与逐像素比较都在原生内核。
double? edgeSimilarityNative(
  Uint8List left,
  Uint8List right, {
  required int stripWidth,
  required int sampleHeight,
}) => FushiComputeImage.instance.edgeSimilarity(
  left,
  right,
  stripWidth: stripWidth,
  sampleHeight: sampleHeight,
);
