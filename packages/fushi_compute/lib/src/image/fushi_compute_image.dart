import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../fushi_compute_library.dart';

/// 缩放插值，取值与 native/fushi_compute/src/image.rs 的 `INTERP_*` 一致，语义同
/// `package:image` 的 `Interpolation`（不支持 cubic）。
enum FfcInterpolation {
  nearest(0),
  linear(1),
  average(2);

  const FfcInterpolation(this.code);

  final int code;
}

/// 原生库不可用（没随包 / 打不开 / 缺图像域符号）。图像内核只有原生这一份实现，
/// 这里直接抛，不退回任何 Dart 实现。
class FushiComputeUnavailableError extends Error {
  FushiComputeUnavailableError(this.message);

  final String message;

  @override
  String toString() => 'FushiComputeUnavailableError: $message';
}

/// 原生调用返回了非 0 状态码（见 `FfcStatus`）。参数已在 Dart 侧校验，走到这里说明
/// 调用方传了自相矛盾的尺寸 / 缓冲区，属于编程错误。
class FushiComputeCallError extends Error {
  FushiComputeCallError(this.symbol, this.status);

  final String symbol;
  final int status;

  @override
  String toString() => 'FushiComputeCallError: $symbol returned $status';
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

/// native/fushi_compute 图像域（`ffc_image_*`）的绑定：原始像素缓冲进、原始缓冲出，
/// 不依赖 `package:image`（img.Image 的适配在调用方，见 fushi_engine
/// `media/image_kernels.dart`）。
///
/// 像素约定：uint8、行主序、`stride` 为每行字节数、1～4 通道；1 / 2 通道按
/// `package:image` `PixelUint8` 的 r/g/b/a 读法（见 image.rs）。
///
/// 输入经 malloc 拷进原生内存（不用 leaf 调用直接传 Dart 堆指针：几十毫秒的 leaf 调用会
/// 挡住整个 isolate group 的 GC 安全点）；输出缓冲由原生内存承载、挂 finalizer 交给 Dart，
/// 不再拷回。
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
      );

  final _ResizeDart _resize;
  final _ResizeChwDart _resizeChw;
  final _ToRgbaDart _toRgba;
  final _MosaicDart _mosaic;
  final _DhashDart _dhash;

  /// 图像域用到的全部符号；缺任何一个都视为库不可用。
  static const List<String> symbols = <String>[
    'ffc_image_resize',
    'ffc_image_resize_chw',
    'ffc_image_to_rgba8',
    'ffc_image_mosaic_rgba8',
    'ffc_image_dhash',
  ];

  static FushiComputeImage? _instance;

  /// 默认库（[FushiCompute.instance]）上的图像域绑定；库或符号缺失抛
  /// [FushiComputeUnavailableError]。
  static FushiComputeImage get instance => _instance ??= bind(
    FushiCompute.instance ??
        (throw FushiComputeUnavailableError(
          'fushi_compute native library not found '
          '(set $kFushiComputeLibEnv or ship the platform library)',
        )),
  );

  /// 在指定库上绑定图像域（测试用）。缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeImage bind(FushiCompute lib) {
    for (final String symbol in symbols) {
      if (!lib.providesSymbol(symbol)) {
        throw FushiComputeUnavailableError(
          'fushi_compute at ${lib.libraryPath} lacks $symbol (library too old)',
        );
      }
    }
    return FushiComputeImage._(lib);
  }

  void _check(String symbol, int status) {
    if (status != FfcStatus.ok) throw FushiComputeCallError(symbol, status);
  }

  static Pointer<Uint8> _copyIn(Uint8List bytes) {
    final Pointer<Uint8> ptr = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return ptr;
  }

  /// 原生内存承载的输出缓冲：指针给原生写，列表交给 Dart（GC 时 finalizer 释放）。
  static ({Pointer<Uint8> ptr, Uint8List list}) _ownedBytes(int length) {
    final Pointer<Uint8> ptr = malloc<Uint8>(length);
    return (
      ptr: ptr,
      list: ptr.asTypedList(length, finalizer: malloc.nativeFree),
    );
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
    final ({Pointer<Uint8> ptr, Uint8List list}) out = _ownedBytes(
      dstWidth * dstHeight * channels,
    );
    if (interpolation == FfcInterpolation.nearest &&
        dstHeight < cropHeight &&
        channels != 2) {
      // 最近邻缩小只读 dstHeight 行：只把这些行（按与内核相同的 `(y * dy).toInt()` 取）
      // 搬进原生内存，内核在这份紧排缓冲上以 dy = 1 取行，结果逐位相同。宽度恰好不变时
      // 内核走「同尺寸原样拷贝」，1 / 3 / 4 通道下与逐像素读写相同；2 通道不同（Dart 会把
      // 亮度写进第二通道），所以 2 通道不走这条。
      final double dy = cropHeight / dstHeight;
      final int rowBytes = cropWidth * channels;
      final Pointer<Uint8> rows = malloc<Uint8>(rowBytes * dstHeight);
      try {
        final Uint8List view = rows.asTypedList(rowBytes * dstHeight);
        for (int y = 0; y < dstHeight; y++) {
          final int start =
              (cropY + (y * dy).toInt()) * stride + cropX * channels;
          view.setRange(y * rowBytes, (y + 1) * rowBytes, pixels, start);
        }
        _check(
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
            out.ptr,
            out.list.length,
            dstWidth,
            dstHeight,
            interpolation.code,
          ),
        );
      } finally {
        malloc.free(rows);
      }
      return out.list;
    }
    final Pointer<Uint8> src = _copyIn(pixels);
    try {
      _check(
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
          out.ptr,
          out.list.length,
          dstWidth,
          dstHeight,
          interpolation.code,
        ),
      );
    } finally {
      malloc.free(src);
    }
    return out.list;
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
    final Pointer<Float> outPtr = malloc<Float>(n);
    final Float32List out = outPtr.asTypedList(n, finalizer: malloc.nativeFree);
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
    } finally {
      malloc.free(src);
      malloc.free(norm);
    }
    return out;
  }

  /// 行紧排的 3 / 4 通道像素 → RGBA8888（3 通道补 a = 255）。
  Uint8List toRgba8(Uint8List pixels, int channels, int width, int height) {
    if (channels != 3 && channels != 4) {
      throw ArgumentError.value(channels, 'channels', 'must be 3 or 4');
    }
    _checkPixels(pixels, width * channels, channels, 0, 0, width, height);
    final ({Pointer<Uint8> ptr, Uint8List list}) out = _ownedBytes(
      width * height * 4,
    );
    final Pointer<Uint8> src = _copyIn(pixels);
    try {
      _check(
        'ffc_image_to_rgba8',
        _toRgba(
          src,
          pixels.length,
          channels,
          width,
          height,
          out.ptr,
          out.list.length,
        ),
      );
    } finally {
      malloc.free(src);
    }
    return out.list;
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
    // 只搬被碰到的块所在的行带：网格锚在图像原点，带的上沿取块边界，带内网格与整图一致。
    int bandTop = height;
    int bandBottom = 0;
    for (final ({int x0, int y0, int x1, int y1}) r in rects) {
      if (r.x0 < 0 || r.y0 < 0 || r.x1 > width || r.y1 > height) {
        throw ArgumentError('mosaic rect $r outside ${width}x$height');
      }
      if (r.x1 <= r.x0 || r.y1 <= r.y0) {
        throw ArgumentError('empty mosaic rect $r');
      }
      bandTop = math.min(bandTop, r.y0 ~/ blockSize * blockSize);
      bandBottom = math.max(
        bandBottom,
        math.min(height, ((r.y1 - 1) ~/ blockSize + 1) * blockSize),
      );
    }
    final int start = bandTop * width * 4;
    final int bandBytes = (bandBottom - bandTop) * width * 4;
    final Uint8List band = Uint8List.sublistView(
      rgba,
      start,
      start + bandBytes,
    );
    final Pointer<Uint8> buf = _copyIn(band);
    final Pointer<Int32> r = malloc<Int32>(rects.length * 4);
    try {
      for (int i = 0; i < rects.length; i++) {
        r[i * 4] = rects[i].x0;
        r[i * 4 + 1] = rects[i].y0 - bandTop;
        r[i * 4 + 2] = rects[i].x1;
        r[i * 4 + 3] = rects[i].y1 - bandTop;
      }
      _check(
        'ffc_image_mosaic_rgba8',
        _mosaic(
          buf,
          bandBytes,
          width,
          bandBottom - bandTop,
          blockSize,
          r,
          rects.length,
        ),
      );
      band.setAll(0, buf.asTypedList(bandBytes));
    } finally {
      malloc.free(buf);
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
      return Uint8List.fromList(out.asTypedList(8));
    } finally {
      malloc.free(src);
      malloc.free(out);
    }
  }
}
