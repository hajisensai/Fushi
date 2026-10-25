import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _MeasureC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Size,
      Uint32,
      Uint32,
      Uint32,
      Pointer<Double>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _MeasureDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      int,
      int,
      int,
      Pointer<Double>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _FitC =
    Int32 Function(
      Pointer<Int32>,
      Size,
      Pointer<Int32>,
      Size,
      Pointer<Uint32>,
      Size,
      Int32,
      Pointer<Double>,
    );
typedef _FitDart =
    int Function(
      Pointer<Int32>,
      int,
      Pointer<Int32>,
      int,
      Pointer<Uint32>,
      int,
      int,
      Pointer<Double>,
    );
typedef _ScoreC =
    Int32 Function(
      Pointer<Int32>,
      Size,
      Pointer<Int32>,
      Size,
      Pointer<Uint32>,
      Size,
      Int32,
      Int64,
      Int64,
      Double,
      Double,
      Pointer<Double>,
    );
typedef _ScoreDart =
    int Function(
      Pointer<Int32>,
      int,
      Pointer<Int32>,
      int,
      Pointer<Uint32>,
      int,
      int,
      int,
      int,
      double,
      double,
      Pointer<Double>,
    );
typedef _InkC =
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
      Double,
      Double,
      Pointer<Double>,
      Pointer<Int32>,
      Size,
      Pointer<Double>,
      Pointer<Uint8>,
    );
typedef _InkDart =
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
      double,
      double,
      Pointer<Double>,
      Pointer<Int32>,
      int,
      Pointer<Double>,
      Pointer<Uint8>,
    );

/// 一条墨迹行（`ffc_gal_measure_ink`）：纵向 `[top, bottom)`、横向 `[left, right)`，[columns]
/// 是整张（缩放后）图宽度上的逐列墨迹计数。
typedef FfcGalInkRow = ({
  int top,
  int bottom,
  int left,
  int right,
  Int32List columns,
});

/// 一种墨迹模式下的测量结果；[imageWidth] / [imageHeight] 是缩放后的尺寸。
typedef FfcGalInk = ({
  int imageWidth,
  int imageHeight,
  List<FfcGalInkRow> rows,
});

/// 网格拟合结果（`_GridFit`）。
typedef FfcGalGridFit = ({
  int columns,
  int indent,
  double pitch,
  double left,
  double score,
});

/// 一张截图（`decodePng` 布局）的像素输入。
typedef FfcGalPixels = ({
  Uint8List pixels,
  int stride,
  int channels,
  int width,
  int height,
});

/// native/fushi_compute galgame 校准像素扫描域（`ffc_gal_*`）的绑定。只给 Windows 端的
/// galgame 查词校准用（见 galcal.rs）。
class FushiComputeGal {
  FushiComputeGal._(FushiCompute lib)
    : _measure = lib.library.lookupFunction<_MeasureC, _MeasureDart>(
        'ffc_gal_measure_ink',
      ),
      _fit = lib.library.lookupFunction<_FitC, _FitDart>('ffc_gal_fit_sample'),
      _score = lib.library.lookupFunction<_ScoreC, _ScoreDart>('ffc_gal_score'),
      _ink = lib.library.lookupFunction<_InkC, _InkDart>('ffc_gal_ink_search'),
      _lib = lib;

  final _MeasureDart _measure;
  final _FitDart _fit;
  final _ScoreDart _score;
  final _InkDart _ink;
  final FushiCompute _lib;

  static FushiComputeGal? _instance;

  /// 默认库上的绑定；库不可用或缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeGal get instance =>
      _instance ??= bind(FushiCompute.require());

  /// 在指定库上绑定（测试用）。缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeGal bind(FushiCompute lib) {
    try {
      return FushiComputeGal._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('galcal', e.message ?? e);
    }
  }

  /// 6 种墨迹模式（`_InkMode` 顺序）。
  static const int modeCount = 6;

  void _check(String symbol, int status) {
    if (status < 0) {
      throw StateError('fushi_compute $symbol failed: status $status');
    }
  }

  static Pointer<Uint8> _pixelsIn(FfcGalPixels p) {
    final Pointer<Uint8> ptr = NativeScratch.input.reserve(p.pixels.length);
    ptr.asTypedListOutOfLine(p.pixels.length).setAll(0, p.pixels);
    return ptr;
  }

  /// `_measure` 的像素部分：先缩到宽 ≤ 1600（最近邻），再按 6 种墨迹模式各测一次。
  /// [rect] 是搜索框归一化的 ltrb。返回按模式顺序的结果，找不到行的模式为 null。搜索框落到
  /// 图外抛 [RangeError]（同旧 `getPixel` 越界）。
  List<FfcGalInk?> measureInk(
    FfcGalPixels image, {
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    final Pointer<Uint8> src = _pixelsIn(image);
    final Pointer<Double> rect = malloc<Double>(4);
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    try {
      rect[0] = left;
      rect[1] = top;
      rect[2] = right;
      rect[3] = bottom;
      final int status = _measure(
        src,
        image.pixels.length,
        image.stride,
        image.channels,
        image.width,
        image.height,
        rect,
        outPtr,
        outLen,
      );
      if (status == FfcStatus.invalidArgument) {
        throw RangeError('calibration search rect lies outside the capture');
      }
      _check('ffc_gal_measure_ink', status);
      final Pointer<Uint8> blob = outPtr.value;
      final int n = outLen.value;
      try {
        final ByteData view = ByteData.sublistView(
          blob.asTypedListOutOfLine(n),
        );
        int o = 0;
        int next() {
          final int v = view.getInt32(o, Endian.host);
          o += 4;
          return v;
        }

        return <FfcGalInk?>[
          for (int mode = 0; mode < modeCount; mode++)
            if (next() == 0)
              null
            else
              () {
                final int w = next();
                final int h = next();
                final int rows = next();
                return (
                  imageWidth: w,
                  imageHeight: h,
                  rows: <FfcGalInkRow>[
                    for (int r = 0; r < rows; r++)
                      () {
                        final int top = next();
                        final int bottom = next();
                        final int left = next();
                        final int right = next();
                        final Int32List columns = Int32List(w);
                        for (int x = 0; x < w; x++) {
                          columns[x] = next();
                        }
                        return (
                          top: top,
                          bottom: bottom,
                          left: left,
                          right: right,
                          columns: columns,
                        );
                      }(),
                  ],
                );
              }(),
        ];
      } finally {
        _lib.freeBytes(blob, n);
      }
    } finally {
      malloc.free(rect);
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }

  /// 把行描述与文本单元拷进暂存区：`[rows i32×4n][columns i32×n·width][units u32]`。
  ({Pointer<Int32> rows, Pointer<Int32> columns, Pointer<Uint32> units})
  _sampleIn(List<FfcGalInkRow> rows, int width, List<int> units) {
    final int ints = rows.length * 4 + rows.length * width + units.length;
    final Pointer<Int32> base = NativeScratch.input
        .reserve(math.max(4, ints * 4))
        .cast();
    for (int i = 0; i < rows.length; i++) {
      base[i * 4] = rows[i].top;
      base[i * 4 + 1] = rows[i].bottom;
      base[i * 4 + 2] = rows[i].left;
      base[i * 4 + 3] = rows[i].right;
    }
    final Pointer<Int32> columns = base + rows.length * 4;
    for (int i = 0; i < rows.length; i++) {
      columns
          .asTypedListOutOfLine(rows.length * width)
          .setAll(i * width, rows[i].columns);
    }
    final Pointer<Uint32> u = (columns + rows.length * width).cast();
    u.asTypedListOutOfLine(units.length).setAll(0, units);
    return (rows: base, columns: columns, units: u);
  }

  /// `_fitSample`：[units] 是文本的逻辑单元，[hookBreak] = 文本（去尾空白后）含 `\r` / `\n`。
  FfcGalGridFit? fitSample(
    List<FfcGalInkRow> rows,
    int width, {
    required List<int> units,
    required bool hookBreak,
  }) {
    final p = _sampleIn(rows, width, units);
    final Pointer<Double> out = malloc<Double>(5);
    try {
      final int status = _fit(
        p.rows,
        rows.length,
        p.columns,
        width,
        p.units,
        units.length,
        hookBreak ? 1 : 0,
        out,
      );
      _check('ffc_gal_fit_sample', status);
      if (status == 0) return null;
      return (
        columns: out[0].toInt(),
        indent: out[1].toInt(),
        pitch: out[2],
        left: out[3],
        score: out[4],
      );
    } finally {
      malloc.free(out);
    }
  }

  /// `_score(sample, capacity, indent, pitch, origin)`。
  double score(
    List<FfcGalInkRow> rows,
    int width, {
    required List<int> units,
    required bool hookBreak,
    required int capacity,
    required int indent,
    required double pitch,
    required double origin,
  }) {
    final p = _sampleIn(rows, width, units);
    final Pointer<Double> out = malloc<Double>(1);
    try {
      _check(
        'ffc_gal_score',
        _score(
          p.rows,
          rows.length,
          p.columns,
          width,
          p.units,
          units.length,
          hookBreak ? 1 : 0,
          capacity,
          indent,
          pitch,
          origin,
          out,
        ),
      );
      return out.value;
    } finally {
      malloc.free(out);
    }
  }

  /// `_measureInkLine` 的前景色候选 + 字格边界搜索：在裁剪框内取最多的 10 种量化颜色各做
  /// 掩码、去掉跨字格连通块，按锚点处的列投影搜字距 / 起点。[anchors] 是 `(centerX,
  /// cellOffset)`。找不到返回 null。
  ({double score, double left, double pitch, Uint8List mask})? inkSearch(
    FfcGalPixels image, {
    required int x0,
    required int y0,
    required int width,
    required int height,
    required double pitch,
    required double initialLeft,
    required List<({double centerX, int cellOffset})> anchors,
  }) {
    final Pointer<Uint8> src = _pixelsIn(image);
    final int n = anchors.length;
    final Pointer<Double> centers = malloc<Double>(math.max(1, n) + 3);
    final Pointer<Int32> cells = malloc<Int32>(math.max(1, n));
    final Pointer<Uint8> mask = NativeScratch.output.reserve(width * height);
    try {
      for (int i = 0; i < n; i++) {
        centers[i] = anchors[i].centerX;
        cells[i] = anchors[i].cellOffset;
      }
      final Pointer<Double> out = centers + math.max(1, n);
      final int status = _ink(
        src,
        image.pixels.length,
        image.stride,
        image.channels,
        image.width,
        image.height,
        x0,
        y0,
        width,
        height,
        pitch,
        initialLeft,
        centers,
        cells,
        n,
        out,
        mask,
      );
      _check('ffc_gal_ink_search', status);
      if (status == 0) return null;
      return (
        score: out[0],
        left: out[1],
        pitch: out[2],
        mask: Uint8List.fromList(mask.asTypedListOutOfLine(width * height)),
      );
    } finally {
      malloc.free(centers);
      malloc.free(cells);
    }
  }
}
