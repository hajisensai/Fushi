import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

/// 缩放插值，取值与 native/fushi_compute/src/image.rs 的 `INTERP_*` 一致，语义同
/// `package:image` 的 `Interpolation`（不支持 cubic）。
enum FfcInterpolation {
  nearest(0),
  linear(1),
  average(2);

  const FfcInterpolation(this.code);

  final int code;
}

typedef _ResizeC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Size,
      Uint32,
      Uint32,
      Uint32,
      Uint32,
      Uint32,
      Pointer<Uint8>,
      Size,
      Uint32,
      Uint32,
      Int32,
    );
typedef _ResizeDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      Pointer<Uint8>,
      int,
      int,
      int,
      int,
    );
typedef _ResizeChwC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Size,
      Uint32,
      Uint32,
      Uint32,
      Uint32,
      Uint32,
      Uint32,
      Uint32,
      Int32,
      Uint32,
      Uint32,
      Int32,
      Int32,
      Uint32,
      Int32,
      Pointer<Double>,
      Pointer<Double>,
      Pointer<Float>,
      Size,
    );
typedef _ResizeChwDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      Pointer<Double>,
      Pointer<Double>,
      Pointer<Float>,
      int,
    );
typedef _ToRgbaC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Uint32,
      Uint32,
      Pointer<Uint8>,
      Size,
    );
typedef _ToRgbaDart =
    int Function(Pointer<Uint8>, int, int, int, int, Pointer<Uint8>, int);
typedef _MosaicC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Uint32,
      Uint32,
      Pointer<Int32>,
      Size,
    );
typedef _MosaicDart =
    int Function(Pointer<Uint8>, int, int, int, int, Pointer<Int32>, int);
typedef _DhashC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Size,
      Uint32,
      Uint32,
      Uint32,
      Pointer<Uint8>,
    );
typedef _DhashDart =
    int Function(Pointer<Uint8>, int, int, int, int, int, Pointer<Uint8>);

typedef _DecodeC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Int32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Uint32>,
    );
typedef _DecodeDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Uint32>,
    );
typedef _ProbeC = Int32 Function(Pointer<Uint8>, Size, Int32, Pointer<Uint32>);
typedef _ProbeDart = int Function(Pointer<Uint8>, int, int, Pointer<Uint32>);
typedef _ToJpegC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ToJpegDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _EdgeC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Uint32,
      Uint32,
      Pointer<Double>,
    );
typedef _EdgeDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      int,
      int,
      Pointer<Double>,
    );
typedef _DbC =
    Int32 Function(
      Pointer<Float>,
      Size,
      Uint32,
      Uint32,
      Double,
      Double,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _DbDart =
    int Function(
      Pointer<Float>,
      int,
      int,
      int,
      double,
      double,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

typedef _DecodePngC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Uint32>,
    );
typedef _DecodePngDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Uint32>,
    );
typedef _CoverSigC = Int32 Function(Pointer<Uint8>, Size, Pointer<Double>);
typedef _CoverSigDart = int Function(Pointer<Uint8>, int, Pointer<Double>);
typedef _CoverCmpC =
    Int32 Function(Pointer<Double>, Pointer<Double>, Pointer<Double>);
typedef _CoverCmpDart =
    int Function(Pointer<Double>, Pointer<Double>, Pointer<Double>);
typedef _AiCropsC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Double,
      Double,
      Pointer<Double>,
      Size,
      Int32,
      Int32,
      Int32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _AiCropsDart =
    int Function(
      Pointer<Uint8>,
      int,
      double,
      double,
      Pointer<Double>,
      int,
      int,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// 解码出的图像格式（与 image.rs 的 `FORMAT_*` 一致）。
enum FfcImageFormat { jpeg, png, gif, webp, bmp, tiff, tga, ico, pnm, avif }

/// [FushiComputeImage.decode] 的结果：行紧排 uint8，[channels] 为 3（RGB）或 4（RGBA）。
typedef FfcDecodedImage = ({
  Uint8List pixels,
  int width,
  int height,
  int channels,
  FfcImageFormat format,
});

/// DB 连通域记录（`ffc_image_db_components`）：外接矩形（含端点）、像素数、概率和，
/// 以种子点为原点的一、二阶矩。
typedef FfcDbComponent = ({
  int minX,
  int minY,
  int maxX,
  int maxY,
  int count,
  double sum,
  double mx,
  double my,
  double mxx,
  double myy,
  double mxy,
});

/// native/fushi_compute 图像域（`ffc_image_*`）的绑定：原始像素缓冲进、原始缓冲出，
/// 不依赖 `package:image`（img.Image 的适配在调用方，见 fushi_engine
/// `media/image_kernels.dart`）。
///
/// 像素约定：uint8、行主序、`stride` 为每行字节数、1～4 通道；1 / 2 通道按
/// `package:image` `PixelUint8` 的 r/g/b/a 读法（见 image.rs）。
///
/// 输入拷进本 isolate 的原生暂存区（[NativeScratch]；不用 leaf 调用直接传 Dart 堆指针：
/// 几十毫秒的 leaf 调用会挡住整个 isolate group 的 GC 安全点），输出写进暂存区后拷回 Dart 堆。
/// 不把原生内存挂 finalizer 直接交出去：这些函数大多跑在 `Isolate.run` 里，结果经
/// `Isolate.exit` 原样移交给调用方 isolate，而工作 isolate 退出时会跑掉它名下的 finalizer，
/// 调用方拿到的就是已释放的内存（实测：同一张字幕位图每次合成出的内容指纹都不同）。
class FushiComputeImage {
  FushiComputeImage._(FushiCompute lib)
    : _resize = lib.library.lookupFunction<_ResizeC, _ResizeDart>(
        'ffc_image_resize',
      ),
      _resizeChw = lib.library.lookupFunction<_ResizeChwC, _ResizeChwDart>(
        'ffc_image_resize_chw',
      ),
      _toRgba = lib.library.lookupFunction<_ToRgbaC, _ToRgbaDart>(
        'ffc_image_to_rgba8',
      ),
      _mosaic = lib.library.lookupFunction<_MosaicC, _MosaicDart>(
        'ffc_image_mosaic_rgba8',
      ),
      _dhash = lib.library.lookupFunction<_DhashC, _DhashDart>(
        'ffc_image_dhash',
      ),
      _decode = lib.library.lookupFunction<_DecodeC, _DecodeDart>(
        'ffc_image_decode',
      ),
      _probe = lib.library.lookupFunction<_ProbeC, _ProbeDart>(
        'ffc_image_probe',
      ),
      _toJpeg = lib.library.lookupFunction<_ToJpegC, _ToJpegDart>(
        'ffc_image_to_jpeg',
      ),
      _edge = lib.library.lookupFunction<_EdgeC, _EdgeDart>(
        'ffc_image_edge_similarity',
      ),
      _db = lib.library.lookupFunction<_DbC, _DbDart>(
        'ffc_image_db_components',
      ),
      _decodePng = lib.library.lookupFunction<_DecodePngC, _DecodePngDart>(
        'ffc_image_decode_png',
      ),
      _coverSig = lib.library.lookupFunction<_CoverSigC, _CoverSigDart>(
        'ffc_image_cover_signature',
      ),
      _coverCmp = lib.library.lookupFunction<_CoverCmpC, _CoverCmpDart>(
        'ffc_image_cover_compare',
      ),
      _aiCrops = lib.library.lookupFunction<_AiCropsC, _AiCropsDart>(
        'ffc_image_ai_crops',
      ),
      _lib = lib;

  final _ResizeDart _resize;
  final _ResizeChwDart _resizeChw;
  final _ToRgbaDart _toRgba;
  final _MosaicDart _mosaic;
  final _DhashDart _dhash;
  final _DecodeDart _decode;
  final _ProbeDart _probe;
  final _ToJpegDart _toJpeg;
  final _EdgeDart _edge;
  final _DbDart _db;
  final _DecodePngDart _decodePng;
  final _CoverSigDart _coverSig;
  final _CoverCmpDart _coverCmp;
  final _AiCropsDart _aiCrops;
  final FushiCompute _lib;

  static FushiComputeImage? _instance;

  /// 默认库上的图像域绑定。库不可用或缺图像域符号抛 [FushiComputeUnavailableError]
  /// （图像内核没有 Dart 回退）。
  static FushiComputeImage get instance =>
      _instance ??= bind(FushiCompute.require());

  /// 在指定库上绑定图像域（测试用）。缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeImage bind(FushiCompute lib) {
    try {
      return FushiComputeImage._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('image', e.message ?? e);
    }
  }

  /// 非 0 状态码：参数已在 Dart 侧校验，走到这里是调用方传了自相矛盾的尺寸 / 缓冲区。
  void _check(String symbol, int status) {
    if (status != FfcStatus.ok) {
      throw StateError('fushi_compute $symbol failed: status $status');
    }
  }

  /// 把输入拷进本 isolate 的输入暂存区（[NativeScratch.input]，不需要释放）。
  static Pointer<Uint8> _copyIn(Uint8List bytes) {
    final Pointer<Uint8> ptr = NativeScratch.input.reserve(bytes.length);
    ptr.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
    return ptr;
  }

  /// 跑 [call] 往输出暂存区里写 [length] 字节，结果拷回 Dart 堆（见类注释）。
  static Uint8List _intoDart(
    int length,
    void Function(Pointer<Uint8> out) call,
  ) {
    final Pointer<Uint8> ptr = NativeScratch.output.reserve(length);
    call(ptr);
    return Uint8List.fromList(ptr.asTypedListOutOfLine(length));
  }

  static void _checkPixels(
    Uint8List pixels,
    int stride,
    int channels,
    int x,
    int y,
    int width,
    int height,
  ) {
    if (channels < 1 || channels > 4) {
      throw ArgumentError.value(channels, 'channels', 'must be 1..4');
    }
    if (width <= 0 || height <= 0 || x < 0 || y < 0) {
      throw ArgumentError('invalid rect ${width}x$height at ($x, $y)');
    }
    if ((x + width) * channels > stride ||
        (y + height - 1) * stride + (x + width) * channels > pixels.length) {
      throw ArgumentError(
        'rect ${width}x$height at ($x, $y) exceeds pixel buffer '
        '(${pixels.length} bytes, stride $stride, $channels ch)',
      );
    }
  }

  /// `copyResize(copyCrop(src, x, y, w, h), width: dstWidth, height: dstHeight,
  /// interpolation: ...)`：返回行紧排、与源同通道数的像素。
  Uint8List resize(
    Uint8List pixels, {
    required int stride,
    required int channels,
    int cropX = 0,
    int cropY = 0,
    required int cropWidth,
    required int cropHeight,
    required int dstWidth,
    required int dstHeight,
    required FfcInterpolation interpolation,
  }) {
    _checkPixels(pixels, stride, channels, cropX, cropY, cropWidth, cropHeight);
    if (dstWidth <= 0 || dstHeight <= 0) {
      throw ArgumentError('invalid target size ${dstWidth}x$dstHeight');
    }
    final int outLen = dstWidth * dstHeight * channels;
    if (interpolation == FfcInterpolation.nearest &&
        dstHeight < cropHeight &&
        channels != 2) {
      // 最近邻缩小只读 dstHeight 行：只把这些行（按与内核相同的 `(y * dy).toInt()` 取）
      // 搬进原生内存，内核在这份紧排缓冲上以 dy = 1 取行，结果逐位相同。宽度恰好不变时
      // 内核走「同尺寸原样拷贝」，1 / 3 / 4 通道下与逐像素读写相同；2 通道不同（Dart 会把
      // 亮度写进第二通道），所以 2 通道不走这条。
      final double dy = cropHeight / dstHeight;
      final int rowBytes = cropWidth * channels;
      final Pointer<Uint8> rows = NativeScratch.input.reserve(
        rowBytes * dstHeight,
      );
      {
        final Uint8List view = rows.asTypedListOutOfLine(rowBytes * dstHeight);
        for (int y = 0; y < dstHeight; y++) {
          final int start =
              (cropY + (y * dy).toInt()) * stride + cropX * channels;
          view.setRange(y * rowBytes, (y + 1) * rowBytes, pixels, start);
        }
        return _intoDart(
          outLen,
          (Pointer<Uint8> out) => _check(
            'ffc_image_resize',
            _resize(
              rows,
              view.length,
              rowBytes,
              channels,
              0,
              0,
              cropWidth,
              dstHeight,
              out,
              outLen,
              dstWidth,
              dstHeight,
              interpolation.code,
            ),
          ),
        );
      }
    }
    final Pointer<Uint8> src = _copyIn(pixels);
    return _intoDart(
      outLen,
      (Pointer<Uint8> out) => _check(
        'ffc_image_resize',
        _resize(
          src,
          pixels.length,
          stride,
          channels,
          cropX,
          cropY,
          cropWidth,
          cropHeight,
          out,
          outLen,
          dstWidth,
          dstHeight,
          interpolation.code,
        ),
      ),
    );
  }

  /// 缩放后转 CHW float32 模型输入：`out[c][y][x] = (v / 255 - mean[c]) / std[c]`，
  /// `c` 为输出通道序（[bgr] 时 0 = B）。
  ///
  /// [canvasWidth] × [canvasHeight]（缺省 = 缩放尺寸）与缩放尺寸不同时走 letterbox：
  /// 缩放结果合成到 114 灰画布的 ([padX], [padY]) 处（同 `compositeImage`）。张量行宽
  /// [planeWidth]（缺省 = 画布宽，右侧填充为 0），共 `3 × 画布高 × 行宽` 个值。
  Float32List resizeToChw(
    Uint8List pixels, {
    required int stride,
    required int channels,
    int cropX = 0,
    int cropY = 0,
    required int cropWidth,
    required int cropHeight,
    required int dstWidth,
    required int dstHeight,
    required FfcInterpolation interpolation,
    int? canvasWidth,
    int? canvasHeight,
    int padX = 0,
    int padY = 0,
    int? planeWidth,
    required bool bgr,
    required List<double> mean,
    required List<double> std,
  }) {
    _checkPixels(pixels, stride, channels, cropX, cropY, cropWidth, cropHeight);
    final int cw = canvasWidth ?? dstWidth;
    final int chh = canvasHeight ?? dstHeight;
    final int pw = planeWidth ?? cw;
    if (dstWidth <= 0 || dstHeight <= 0 || cw <= 0 || chh <= 0 || pw < cw) {
      throw ArgumentError(
        'invalid target ${dstWidth}x$dstHeight on ${cw}x$chh (plane $pw)',
      );
    }
    if (mean.length != 3 || std.length != 3) {
      throw ArgumentError('mean / std must have 3 entries');
    }
    final int n = 3 * chh * pw;
    final Pointer<Float> outPtr = NativeScratch.output.reserve(n * 4).cast();
    final Pointer<Uint8> src = _copyIn(pixels);
    final Pointer<Double> norm = malloc<Double>(6);
    try {
      for (int i = 0; i < 3; i++) {
        norm[i] = mean[i];
        norm[3 + i] = std[i];
      }
      _check(
        'ffc_image_resize_chw',
        _resizeChw(
          src,
          pixels.length,
          stride,
          channels,
          cropX,
          cropY,
          cropWidth,
          cropHeight,
          dstWidth,
          dstHeight,
          interpolation.code,
          cw,
          chh,
          padX,
          padY,
          pw,
          bgr ? 1 : 0,
          norm,
          norm + 3,
          outPtr,
          n,
        ),
      );
      return Float32List.fromList(outPtr.asTypedListOutOfLine(n));
    } finally {
      malloc.free(norm);
    }
  }

  /// 行紧排的 3 / 4 通道像素 → RGBA8888（3 通道补 a = 255）。
  Uint8List toRgba8(Uint8List pixels, int channels, int width, int height) {
    if (channels != 3 && channels != 4) {
      throw ArgumentError.value(channels, 'channels', 'must be 3 or 4');
    }
    _checkPixels(pixels, width * channels, channels, 0, 0, width, height);
    final int outLen = width * height * 4;
    final Pointer<Uint8> src = _copyIn(pixels);
    return _intoDart(
      outLen,
      (Pointer<Uint8> out) => _check(
        'ffc_image_to_rgba8',
        _toRgba(src, pixels.length, channels, width, height, out, outLen),
      ),
    );
  }

  /// 就地给 RGBA8888 缓冲 [rgba] 打码。[rects] 每项是已夹进图像的像素范围
  /// `[x0, x1) × [y0, y1)`，[blockSize] 为块边长。
  void mosaicRgba8(
    Uint8List rgba,
    int width,
    int height,
    int blockSize,
    List<({int x0, int y0, int x1, int y1})> rects,
  ) {
    if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
      throw ArgumentError(
        'expected ${width * height * 4} RGBA bytes for ${width}x$height, '
        'got ${rgba.length}',
      );
    }
    if (blockSize <= 0) throw ArgumentError.value(blockSize, 'blockSize');
    if (rects.isEmpty) return;
    // 只搬被碰到的块所在的矩形带：网格锚在图像原点，带的左 / 上沿取块边界，右 / 下沿取块
    // 边界或图像边，带内网格与整图一致（被图像边截断的块在带里同样被截断）。
    int bandLeft = width, bandTop = height, bandRight = 0, bandBottom = 0;
    int alignedEnd(int end, int limit) =>
        math.min(limit, ((end - 1) ~/ blockSize + 1) * blockSize);
    for (final ({int x0, int y0, int x1, int y1}) r in rects) {
      if (r.x0 < 0 || r.y0 < 0 || r.x1 > width || r.y1 > height) {
        throw ArgumentError('mosaic rect $r outside ${width}x$height');
      }
      if (r.x1 <= r.x0 || r.y1 <= r.y0) {
        throw ArgumentError('empty mosaic rect $r');
      }
      bandLeft = math.min(bandLeft, r.x0 ~/ blockSize * blockSize);
      bandTop = math.min(bandTop, r.y0 ~/ blockSize * blockSize);
      bandRight = math.max(bandRight, alignedEnd(r.x1, width));
      bandBottom = math.max(bandBottom, alignedEnd(r.y1, height));
    }
    final int bw = bandRight - bandLeft;
    final int bh = bandBottom - bandTop;
    final int rowBytes = bw * 4;
    final Pointer<Uint8> buf = NativeScratch.input.reserve(rowBytes * bh);
    final Pointer<Int32> r = malloc<Int32>(rects.length * 4);
    try {
      final Uint8List view = buf.asTypedListOutOfLine(rowBytes * bh);
      for (int y = 0; y < bh; y++) {
        final int from = ((bandTop + y) * width + bandLeft) * 4;
        view.setRange(y * rowBytes, (y + 1) * rowBytes, rgba, from);
      }
      for (int i = 0; i < rects.length; i++) {
        r[i * 4] = rects[i].x0 - bandLeft;
        r[i * 4 + 1] = rects[i].y0 - bandTop;
        r[i * 4 + 2] = rects[i].x1 - bandLeft;
        r[i * 4 + 3] = rects[i].y1 - bandTop;
      }
      _check(
        'ffc_image_mosaic_rgba8',
        _mosaic(buf, view.length, bw, bh, blockSize, r, rects.length),
      );
      for (int y = 0; y < bh; y++) {
        final int to = ((bandTop + y) * width + bandLeft) * 4;
        rgba.setRange(to, to + rowBytes, view, y * rowBytes);
      }
    } finally {
      malloc.free(r);
    }
  }

  /// 64 位 dHash（`coverDHashOfImage` 的位序），8 字节大端。
  Uint8List dHash(
    Uint8List pixels, {
    required int stride,
    required int channels,
    required int width,
    required int height,
  }) {
    _checkPixels(pixels, stride, channels, 0, 0, width, height);
    final Pointer<Uint8> src = _copyIn(pixels);
    final Pointer<Uint8> out = malloc<Uint8>(8);
    try {
      _check(
        'ffc_image_dhash',
        _dhash(src, pixels.length, stride, channels, width, height, out),
      );
      return Uint8List.fromList(out.asTypedListOutOfLine(8));
    } finally {
      malloc.free(out);
    }
  }

  /// 把原生交出的缓冲拷成 Dart 字节并释放。
  Uint8List _takeBytes(Pointer<Pointer<Uint8>> ptr, Pointer<Size> len) {
    final Pointer<Uint8> data = ptr.value;
    final int n = len.value;
    try {
      return Uint8List.fromList(data.asTypedListOutOfLine(n));
    } finally {
      _lib.freeBytes(data, n);
    }
  }

  /// 解码（JPEG / PNG / GIF / WebP / BMP / TIFF / TGA / ICO / PNM / AVIF，多帧取首帧）成 uint8
  /// RGB（不透明）或 RGBA；[orient] 时按 EXIF 方向转正。认不出 / 解不开返回 null。
  FfcDecodedImage? decode(Uint8List bytes, {bool orient = true}) {
    final Pointer<Uint8> src = _copyIn(bytes);
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    final Pointer<Uint32> meta = malloc<Uint32>(4);
    try {
      final int status = _decode(
        src,
        bytes.length,
        orient ? 1 : 0,
        outPtr,
        outLen,
        meta,
      );
      if (status == FfcStatus.badInput) return null;
      _check('ffc_image_decode', status);
      return (
        pixels: _takeBytes(outPtr, outLen),
        width: meta[0],
        height: meta[1],
        channels: meta[2],
        format: FfcImageFormat.values[meta[3] - 1],
      );
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
      malloc.free(meta);
    }
  }

  /// 只读头的宽高（[orient] 时按 EXIF 方向换算）与格式；认不出返回 null。
  ({int width, int height, FfcImageFormat format})? probe(
    Uint8List bytes, {
    bool orient = true,
  }) {
    final Pointer<Uint8> src = _copyIn(bytes);
    final Pointer<Uint32> meta = malloc<Uint32>(3);
    try {
      final int status = _probe(src, bytes.length, orient ? 1 : 0, meta);
      if (status == FfcStatus.badInput) return null;
      _check('ffc_image_probe', status);
      return (
        width: meta[0],
        height: meta[1],
        format: FfcImageFormat.values[meta[2] - 1],
      );
    } finally {
      malloc.free(meta);
    }
  }

  /// 解码（转正）后编码成 JPEG（4:4:4，[quality] 1..100，忽略 alpha）；解不开返回 null。
  Uint8List? toJpeg(Uint8List bytes, {required int quality}) {
    if (quality < 1 || quality > 100) {
      throw ArgumentError.value(quality, 'quality', 'must be 1..100');
    }
    final Pointer<Uint8> src = _copyIn(bytes);
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    try {
      final int status = _toJpeg(src, bytes.length, quality, outPtr, outLen);
      if (status == FfcStatus.badInput) return null;
      _check('ffc_image_to_jpeg', status);
      return _takeBytes(outPtr, outLen);
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }

  /// 两张图（编码字节）左图右缘与右图左缘的相似度（`EpubEdgeMatcher.compareEdges`）；
  /// 任一张解不开返回 null。
  double? edgeSimilarity(
    Uint8List left,
    Uint8List right, {
    required int stripWidth,
    required int sampleHeight,
  }) {
    if (stripWidth < 0 || sampleHeight <= 0) {
      throw ArgumentError('invalid strip $stripWidth / height $sampleHeight');
    }
    // 两份输入不能共用一块暂存区：右图单独 malloc。
    final Pointer<Uint8> l = _copyIn(left);
    final Pointer<Uint8> r = malloc<Uint8>(right.isEmpty ? 1 : right.length);
    final Pointer<Double> out = malloc<Double>();
    try {
      r.asTypedListOutOfLine(right.length).setAll(0, right);
      final int status = _edge(
        l,
        left.length,
        r,
        right.length,
        stripWidth,
        sampleHeight,
        out,
      );
      if (status == FfcStatus.badInput) return null;
      _check('ffc_image_edge_similarity', status);
      return out.value;
    } finally {
      malloc.free(r);
      malloc.free(out);
    }
  }

  /// DB 概率图连通域（4 连通、`> thresh`），滤掉均值 `< boxThresh` 与外接矩形宽 / 高
  /// `< 2` 的域，按扫描序返回（`ppDetPostprocess` 的洪泛部分）。
  List<FfcDbComponent> dbComponents(
    Float32List prob,
    int width,
    int height, {
    required double thresh,
    required double boxThresh,
  }) {
    if (width <= 0 || height <= 0 || prob.length != width * height) {
      throw ArgumentError(
        'prob has ${prob.length} values, expected ${width}x$height',
      );
    }
    final Pointer<Float> src = NativeScratch.input
        .reserve(prob.length * 4)
        .cast();
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    try {
      src.asTypedListOutOfLine(prob.length).setAll(0, prob);
      _check(
        'ffc_image_db_components',
        _db(src, prob.length, width, height, thresh, boxThresh, outPtr, outLen),
      );
      final int bytes = outLen.value;
      final Pointer<Uint8> data = outPtr.value;
      try {
        // 没有连通域时原生交出的是空切片的悬空指针（只按 1 字节对齐）：`cast<Double>()`
        // 的 asTypedList 即便长度 0 也查 8 字节对齐，会抛 ArgumentError。
        if (bytes == 0) return const <FfcDbComponent>[];
        final Float64List v = data.cast<Double>().asTypedListOutOfLine(
          bytes ~/ 8,
        );
        return <FfcDbComponent>[
          for (int i = 0; i + 11 <= v.length; i += 11)
            (
              minX: v[i].toInt(),
              minY: v[i + 1].toInt(),
              maxX: v[i + 2].toInt(),
              maxY: v[i + 3].toInt(),
              count: v[i + 4].toInt(),
              sum: v[i + 5],
              mx: v[i + 6],
              my: v[i + 7],
              mxx: v[i + 8],
              myy: v[i + 9],
              mxy: v[i + 10],
            ),
        ];
      } finally {
        _lib.freeBytes(data, bytes);
      }
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }

  /// 只认 PNG、按 `package:image` `decodePng` 的通道布局解码（灰度 1 通道、灰度 + alpha 2 通道、
  /// RGB 3、RGBA 4；调色板展开），不转方向。不是 PNG / 解不开返回 null。与 `decodePng` 的差别
  /// 只在 16 位与 1/2/4 位灰度（这里一律给 8 位，见 image.rs `decode_png_layout`）。
  ({Uint8List pixels, int width, int height, int channels})? decodePng(
    Uint8List bytes,
  ) {
    final Pointer<Uint8> src = _copyIn(bytes);
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    final Pointer<Uint32> meta = malloc<Uint32>(3);
    try {
      final int status = _decodePng(src, bytes.length, outPtr, outLen, meta);
      if (status == FfcStatus.badInput) return null;
      _check('ffc_image_decode_png', status);
      return (
        pixels: _takeBytes(outPtr, outLen),
        width: meta[0],
        height: meta[1],
        channels: meta[2],
      );
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
      malloc.free(meta);
    }
  }

  /// 封面比对网格边长（image.rs `COVER_GRID`）。
  static const int coverGrid = 32;

  /// 解码（按 EXIF 转正）并算封面比对特征：按面积平均缩成 32×32 灰度（BT.601，0–1，行优先），
  /// 空格子取同行左侧最近的非空格（`cover_compare.dart` 的口径）。解不开返回 null。
  Float64List? coverSignature(Uint8List bytes) {
    final Pointer<Uint8> src = _copyIn(bytes);
    final Pointer<Double> out = malloc<Double>(coverGrid * coverGrid);
    try {
      final int status = _coverSig(src, bytes.length, out);
      if (status == FfcStatus.badInput) return null;
      _check('ffc_image_cover_signature', status);
      return Float64List.fromList(
        out.asTypedListOutOfLine(coverGrid * coverGrid),
      );
    } finally {
      malloc.free(out);
    }
  }

  /// 两份封面特征（各 32×32）的整体 NCC 与「去掉 9×8 粗格均值后」的细节 NCC。
  ({double ncc, double detailNcc}) compareCoverSignatures(
    Float64List a,
    Float64List b,
  ) {
    const int n = coverGrid * coverGrid;
    if (a.length != n || b.length != n) {
      throw ArgumentError('cover signatures must have $n values');
    }
    final Pointer<Double> pa = malloc<Double>(n * 2 + 2);
    try {
      final Pointer<Double> pb = pa + n;
      final Pointer<Double> out = pa + n * 2;
      pa.asTypedListOutOfLine(n).setAll(0, a);
      pb.asTypedListOutOfLine(n).setAll(0, b);
      _check('ffc_image_cover_compare', _coverCmp(pa, pb, out));
      return (ncc: out[0], detailNcc: out[1]);
    } finally {
      malloc.free(pa);
    }
  }

  /// 解码整页（按 EXIF 转正）并裁出 [boxes]（每条 ltrb，坐标系为 [pageWidth]×[pageHeight]，
  /// `<= 0` 时按解码尺寸）：外扩 [padding]，长边超过 [maxSide] 均值缩小、短边不足 [minSide]
  /// 立方放大（`package:image` 的 cubic 逐位复刻），各编码成 PNG。裁不出的块为 null；整页解
  /// 不开返回 null。坐标换算后非有限抛 [UnsupportedError]（同旧 `floor()` / `ceil()`）。
  List<Uint8List?>? aiCrops(
    Uint8List bytes, {
    required double pageWidth,
    required double pageHeight,
    required List<({double left, double top, double right, double bottom})>
    boxes,
    required int padding,
    required int maxSide,
    required int minSide,
  }) {
    final Pointer<Uint8> src = _copyIn(bytes);
    final Pointer<Double> rects = malloc<Double>(math.max(1, boxes.length * 4));
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    try {
      for (int i = 0; i < boxes.length; i++) {
        rects[i * 4] = boxes[i].left;
        rects[i * 4 + 1] = boxes[i].top;
        rects[i * 4 + 2] = boxes[i].right;
        rects[i * 4 + 3] = boxes[i].bottom;
      }
      final int status = _aiCrops(
        src,
        bytes.length,
        pageWidth,
        pageHeight,
        rects,
        boxes.length,
        padding,
        maxSide,
        minSide,
        outPtr,
        outLen,
      );
      if (status == FfcStatus.badInput) return null;
      if (status == FfcStatus.invalidArgument) {
        throw UnsupportedError('Infinity or NaN toInt');
      }
      _check('ffc_image_ai_crops', status);
      final Uint8List blob = _takeBytes(outPtr, outLen);
      final ByteData view = ByteData.sublistView(blob);
      final List<Uint8List?> crops = <Uint8List?>[];
      int o = 0;
      for (int i = 0; i < boxes.length; i++) {
        final int n = view.getUint32(o, Endian.host);
        o += 4;
        if (n == 0xFFFFFFFF) {
          crops.add(null);
          continue;
        }
        crops.add(Uint8List.sublistView(blob, o, o + n));
        o += n;
      }
      return crops;
    } finally {
      malloc.free(rects);
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }
}
