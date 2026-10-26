import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _CtcC =
    Int32 Function(
      Pointer<Float>,
      Size,
      Uint32,
      Uint32,
      Int32,
      Pointer<Double>,
      Size,
      Pointer<Size>,
    );
typedef _CtcDart =
    int Function(
      Pointer<Float>,
      int,
      int,
      int,
      int,
      Pointer<Double>,
      int,
      Pointer<Size>,
    );
typedef _RtdetrC =
    Int32 Function(
      Pointer<Float>,
      Size,
      Pointer<Float>,
      Size,
      Uint32,
      Uint32,
      Pointer<Double>,
      Double,
      Pointer<Double>,
      Size,
      Pointer<Size>,
    );
typedef _RtdetrDart =
    int Function(
      Pointer<Float>,
      int,
      Pointer<Float>,
      int,
      int,
      int,
      Pointer<Double>,
      double,
      Pointer<Double>,
      int,
      Pointer<Size>,
    );
typedef _RtdetrProcessedC =
    Int32 Function(
      Pointer<Float>,
      Size,
      Pointer<Float>,
      Size,
      Pointer<Double>,
      Double,
      Pointer<Double>,
      Size,
      Pointer<Size>,
    );
typedef _RtdetrProcessedDart =
    int Function(
      Pointer<Float>,
      int,
      Pointer<Float>,
      int,
      Pointer<Double>,
      double,
      Pointer<Double>,
      int,
      Pointer<Size>,
    );
typedef _NmsC =
    Int32 Function(
      Pointer<Double>,
      Size,
      Double,
      Pointer<Uint32>,
      Pointer<Size>,
    );
typedef _NmsDart =
    int Function(Pointer<Double>, int, double, Pointer<Uint32>, Pointer<Size>);
typedef _InsideC =
    Int32 Function(
      Pointer<Double>,
      Size,
      Pointer<Double>,
      Size,
      Pointer<Uint8>,
    );
typedef _InsideDart =
    int Function(Pointer<Double>, int, Pointer<Double>, int, Pointer<Uint8>);
typedef _PanelsC =
    Int32 Function(
      Pointer<Double>,
      Size,
      Double,
      Int32,
      Pointer<Uint32>,
      Pointer<Size>,
    );
typedef _PanelsDart =
    int Function(
      Pointer<Double>,
      int,
      double,
      int,
      Pointer<Uint32>,
      Pointer<Size>,
    );

/// 一个 CTC 吐字 run（`ffc_ocr_ctc_greedy`）：[token] 是词表下标（0 = blank 不会出现），
/// 帧区间 `[frameStart, frameEnd)`；[firstConfidence] 是 run 首帧的置信度，
/// [meanConfidence] 是 run 内逐帧置信度均值（只有 `detailed` 时才算，否则 NaN）。
typedef FfcCtcRun = ({
  int token,
  int frameStart,
  int frameEnd,
  double firstConfidence,
  double meanConfidence,
});

/// 一条检测（`ffc_ocr_rtdetr_*`）：已反变换回原图并夹取的 ltrb、分数；[tag] 在原始导出里
/// 是类别号，在图内后处理导出里是输入下标。
typedef FfcDetection = ({
  double left,
  double top,
  double right,
  double bottom,
  double score,
  int tag,
});

/// `LetterboxTransform` 的 8 个字段（顺序固定）。
typedef FfcLetterbox = ({
  double scaleX,
  double scaleY,
  double padX,
  double padY,
  int srcWidth,
  int srcHeight,
  int dstWidth,
  int dstHeight,
});

/// native/fushi_compute OCR 域（`ffc_ocr_*`）的绑定：PP-OCR CTC 贪心解码、RT-DETR 输出
/// 解码 / 分组 NMS / 内外判定、漫画分格 NMS + 分行排序。逐位复刻旧 Dart 实现（见 ocr.rs）。
///
/// 输入拷进本 isolate 的原生暂存区，输出拷回 Dart 堆（理由同 `FushiComputeImage`）。
class FushiComputeOcr {
  FushiComputeOcr._(FushiCompute lib)
    : _ctc = lib.library.lookupFunction<_CtcC, _CtcDart>('ffc_ocr_ctc_greedy'),
      _rtdetr = lib.library.lookupFunction<_RtdetrC, _RtdetrDart>(
        'ffc_ocr_rtdetr_decode',
      ),
      _rtdetrProcessed = lib.library
          .lookupFunction<_RtdetrProcessedC, _RtdetrProcessedDart>(
            'ffc_ocr_rtdetr_decode_processed',
          ),
      _nms = lib.library.lookupFunction<_NmsC, _NmsDart>(
        'ffc_ocr_class_aware_nms',
      ),
      _inside = lib.library.lookupFunction<_InsideC, _InsideDart>(
        'ffc_ocr_inside_bubbles',
      ),
      _panels = lib.library.lookupFunction<_PanelsC, _PanelsDart>(
        'ffc_ocr_order_panels',
      );

  final _CtcDart _ctc;
  final _RtdetrDart _rtdetr;
  final _RtdetrProcessedDart _rtdetrProcessed;
  final _NmsDart _nms;
  final _InsideDart _inside;
  final _PanelsDart _panels;

  static FushiComputeOcr? _instance;

  /// 默认库上的 OCR 域绑定；库不可用或缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeOcr get instance =>
      _instance ??= bind(FushiCompute.require());

  /// 在指定库上绑定（测试用）。缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeOcr bind(FushiCompute lib) {
    try {
      return FushiComputeOcr._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('ocr', e.message ?? e);
    }
  }

  static const int _ctcFields = 5;
  static const int _detFields = 6;

  void _check(String symbol, int status) {
    if (status != FfcStatus.ok) {
      throw StateError('fushi_compute $symbol failed: status $status');
    }
  }

  static Pointer<Float> _floatsIn(NativeScratch scratch, Float32List v) {
    final Pointer<Float> p = scratch.reserve(math.max(4, v.length * 4)).cast();
    p.asTypedListOutOfLine(v.length).setAll(0, v);
    return p;
  }

  /// CTC 贪心解码 [logits]（[frames]×[vocab] 行主序）：合并相邻重复、去 blank，每个吐字
  /// run 一条。[detailed] 时额外算 run 内逐帧置信度均值，并要求张量全是有限值——否则返回
  /// null（调用方据此抛旧实现的 `StateError`）。
  List<FfcCtcRun>? ctcGreedy(
    Float32List logits,
    int frames,
    int vocab, {
    required bool detailed,
  }) {
    if (vocab <= 0 || frames < 0 || logits.length != frames * vocab) {
      throw ArgumentError(
        'logits has ${logits.length} values, expected ${frames}x$vocab',
      );
    }
    final Pointer<Float> src = _floatsIn(NativeScratch.input, logits);
    final int cap = math.max(1, frames * _ctcFields);
    final Pointer<Double> out = NativeScratch.output.reserve(cap * 8).cast();
    final Pointer<Size> count = malloc<Size>();
    try {
      final int status = _ctc(
        src,
        logits.length,
        frames,
        vocab,
        detailed ? 1 : 0,
        out,
        cap,
        count,
      );
      if (status == FfcStatus.badInput) return null;
      _check('ffc_ocr_ctc_greedy', status);
      final Float64List v = out.asTypedListOutOfLine(count.value * _ctcFields);
      return <FfcCtcRun>[
        for (int i = 0; i < v.length; i += _ctcFields)
          (
            token: v[i].toInt(),
            frameStart: v[i + 1].toInt(),
            frameEnd: v[i + 2].toInt(),
            firstConfidence: v[i + 3],
            meanConfidence: v[i + 4],
          ),
      ];
    } finally {
      malloc.free(count);
    }
  }

  static void _writeTransform(Pointer<Double> p, FfcLetterbox t) {
    p[0] = t.scaleX;
    p[1] = t.scaleY;
    p[2] = t.padX;
    p[3] = t.padY;
    p[4] = t.srcWidth.toDouble();
    p[5] = t.srcHeight.toDouble();
    p[6] = t.dstWidth.toDouble();
    p[7] = t.dstHeight.toDouble();
  }

  static List<FfcDetection> _readDetections(Pointer<Double> out, int count) {
    final Float64List v = out.asTypedListOutOfLine(count * _detFields);
    return <FfcDetection>[
      for (int i = 0; i < v.length; i += _detFields)
        (
          left: v[i],
          top: v[i + 1],
          right: v[i + 2],
          bottom: v[i + 3],
          score: v[i + 4],
          tag: v[i + 5].toInt(),
        ),
    ];
  }

  /// `decodeRtdetrOutputs`：逐 (query, class) sigmoid 过 [scoreThreshold]，cxcywh → xyxy，
  /// 反变换回原图并夹取，去掉零面积。[FfcDetection.tag] = 类别号。
  List<FfcDetection> rtdetrDecode({
    required Float32List logits,
    required Float32List boxes,
    required int queries,
    required int classes,
    required FfcLetterbox transform,
    required double scoreThreshold,
  }) {
    if (logits.length != queries * classes || boxes.length != queries * 4) {
      throw ArgumentError(
        'detector outputs have ${logits.length} logits / ${boxes.length} box '
        'values, expected ${queries}x$classes / ${queries}x4',
      );
    }
    final Pointer<Uint8> input = NativeScratch.input.reserve(
      math.max(4, (logits.length + boxes.length) * 4),
    );
    final Pointer<Float> pl = input.cast();
    final Pointer<Float> pb = pl + logits.length;
    pl.asTypedListOutOfLine(logits.length).setAll(0, logits);
    pb.asTypedListOutOfLine(boxes.length).setAll(0, boxes);
    final int cap = math.max(1, queries * classes * _detFields);
    final Pointer<Double> out = NativeScratch.output.reserve(cap * 8).cast();
    final Pointer<Double> tr = malloc<Double>(8);
    final Pointer<Size> count = malloc<Size>();
    try {
      _writeTransform(tr, transform);
      _check(
        'ffc_ocr_rtdetr_decode',
        _rtdetr(
          pl,
          logits.length,
          pb,
          boxes.length,
          queries,
          classes,
          tr,
          scoreThreshold,
          out,
          cap,
          count,
        ),
      );
      return _readDetections(out, count.value);
    } finally {
      malloc.free(tr);
      malloc.free(count);
    }
  }

  /// `decodeProcessedRtdetrOutputs` 的几何部分：分数过阈值、xyxy 反变换回原图并夹取、去零
  /// 面积。[FfcDetection.tag] = 输入下标（类别由调用方按 `labels[tag]` 取）。
  List<FfcDetection> rtdetrDecodeProcessed({
    required Float32List scores,
    required Float32List boxes,
    required FfcLetterbox transform,
    required double scoreThreshold,
  }) {
    if (boxes.length != scores.length * 4) {
      throw ArgumentError(
        'processed detector boxes have ${boxes.length} values, expected '
        '${scores.length}x4',
      );
    }
    final Pointer<Uint8> input = NativeScratch.input.reserve(
      math.max(4, (scores.length + boxes.length) * 4),
    );
    final Pointer<Float> ps = input.cast();
    final Pointer<Float> pb = ps + scores.length;
    ps.asTypedListOutOfLine(scores.length).setAll(0, scores);
    pb.asTypedListOutOfLine(boxes.length).setAll(0, boxes);
    final int cap = math.max(1, scores.length * _detFields);
    final Pointer<Double> out = NativeScratch.output.reserve(cap * 8).cast();
    final Pointer<Double> tr = malloc<Double>(8);
    final Pointer<Size> count = malloc<Size>();
    try {
      _writeTransform(tr, transform);
      _check(
        'ffc_ocr_rtdetr_decode_processed',
        _rtdetrProcessed(
          ps,
          scores.length,
          pb,
          boxes.length,
          tr,
          scoreThreshold,
          out,
          cap,
          count,
        ),
      );
      return _readDetections(out, count.value);
    } finally {
      malloc.free(tr);
      malloc.free(count);
    }
  }

  /// `applyClassAwareNms`：返回保留的输入下标（按保留顺序）。[detections] 的 [FfcDetection.tag]
  /// 是类别号（0 = 气泡一组，其余文字一组）。
  List<int> classAwareNms(
    List<FfcDetection> detections, {
    required double iouThreshold,
  }) {
    final int n = detections.length;
    if (n == 0) return const <int>[];
    final Pointer<Double> dets = NativeScratch.input
        .reserve(n * _detFields * 8)
        .cast();
    for (int i = 0; i < n; i++) {
      final FfcDetection d = detections[i];
      final int o = i * _detFields;
      dets[o] = d.left;
      dets[o + 1] = d.top;
      dets[o + 2] = d.right;
      dets[o + 3] = d.bottom;
      dets[o + 4] = d.score;
      dets[o + 5] = d.tag.toDouble();
    }
    final Pointer<Uint32> kept = NativeScratch.output.reserve(n * 4).cast();
    final Pointer<Size> count = malloc<Size>();
    try {
      _check(
        'ffc_ocr_class_aware_nms',
        _nms(dets, n, iouThreshold, kept, count),
      );
      return List<int>.of(kept.asTypedListOutOfLine(count.value));
    } finally {
      malloc.free(count);
    }
  }

  /// 对 [targets] 的每个 ltrb 框：中心是否落在 [bubbles] 任一框内（闭区间）。
  List<bool> insideBubbles(
    List<({double left, double top, double right, double bottom})> bubbles,
    List<({double left, double top, double right, double bottom})> targets,
  ) {
    if (targets.isEmpty) return const <bool>[];
    final int total = (bubbles.length + targets.length) * 4;
    final Pointer<Double> buf = NativeScratch.input.reserve(total * 8).cast();
    void put(
      int at,
      List<({double left, double top, double right, double bottom})> rects,
    ) {
      for (int i = 0; i < rects.length; i++) {
        buf[at + i * 4] = rects[i].left;
        buf[at + i * 4 + 1] = rects[i].top;
        buf[at + i * 4 + 2] = rects[i].right;
        buf[at + i * 4 + 3] = rects[i].bottom;
      }
    }

    put(0, bubbles);
    put(bubbles.length * 4, targets);
    final Pointer<Uint8> out = NativeScratch.output.reserve(targets.length);
    _check(
      'ffc_ocr_inside_bubbles',
      _inside(
        buf,
        bubbles.length,
        buf + bubbles.length * 4,
        targets.length,
        out,
      ),
    );
    return <bool>[
      for (final int v in out.asTypedListOutOfLine(targets.length)) v != 0,
    ];
  }

  /// `orderPanelRects`：输入未夹取的 ltrb + 分数，返回输出顺序上的输入下标（调用方取
  /// `input[i].clamp()`）。
  List<int> orderPanels(
    List<({double left, double top, double right, double bottom, double score})>
    rects, {
    required double iouThreshold,
    required bool rtl,
  }) {
    final int n = rects.length;
    if (n == 0) return const <int>[];
    final Pointer<Double> buf = NativeScratch.input.reserve(n * 5 * 8).cast();
    for (int i = 0; i < n; i++) {
      buf[i * 5] = rects[i].left;
      buf[i * 5 + 1] = rects[i].top;
      buf[i * 5 + 2] = rects[i].right;
      buf[i * 5 + 3] = rects[i].bottom;
      buf[i * 5 + 4] = rects[i].score;
    }
    final Pointer<Uint32> order = NativeScratch.output.reserve(n * 4).cast();
    final Pointer<Size> count = malloc<Size>();
    try {
      _check(
        'ffc_ocr_order_panels',
        _panels(buf, n, iouThreshold, rtl ? 1 : 0, order, count),
      );
      return List<int>.of(order.asTypedListOutOfLine(count.value));
    } finally {
      malloc.free(count);
    }
  }
}
