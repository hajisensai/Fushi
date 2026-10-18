// OCR 后段 / 分格排序回归用例：在确定性合成张量上跑公开 API，产出摘要；测试比对
// ocr_kernel_vectors.dart 里钉住的值（由改用原生实现**之前**的纯 Dart 实现生成）。
//
// 覆盖：CTC 贪心解码（scored / positioned / detailed 三条路径，含并列最大值、概率行与
// logits 行、-0.0、非有限值）、RT-DETR 两种导出的解码、分组 NMS（>32 个检测走
// 双枢轴快排、含同分并列）、内外判定、分格 NMS + 分行排序。
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';
import 'package:fushi_engine/ocr/ocr_glyph_boxes.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:fushi_engine/ocr/text_detector.dart';

import 'synthetic_images.dart';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// 摘要累加器：double 按位、int 按 64 位、字符串按 UTF-8 带长度。
class _Digest {
  final BytesBuilder _b = BytesBuilder(copy: false);
  final ByteData _scratch = ByteData(8);

  void f(double? v) {
    if (v == null) {
      i(-0x7ff0dead);
      return;
    }
    _scratch.setFloat64(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List()));
  }

  void i(int v) {
    _scratch.setInt64(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List()));
  }

  void s(String v) {
    final List<int> u = utf8.encode(v);
    i(u.length);
    _b.add(u);
  }

  void rect(OcrRect r) {
    f(r.left);
    f(r.top);
    f(r.right);
    f(r.bottom);
  }

  String done() => _sha(_b.takeBytes());
}

/// CTC 词表：blank + 混合 BMP / 代理对 / 多字符项 + 空格。
List<String> _vocab(int size) {
  final List<String> v = <String>[''];
  for (int i = 1; i < size - 1; i++) {
    if (i % 17 == 0) {
      v.add(String.fromCharCode(0x1F600 + i % 50)); // 代理对
    } else if (i % 29 == 0) {
      v.add('ab');
    } else {
      v.add(String.fromCharCode(0x3041 + i % 4000));
    }
  }
  v.add(' ');
  return v;
}

double _unit(SynthRng rng) => rng.below(1 << 20) / (1 << 20);

/// [frames]×[vocab] 的输出张量。[kind]：0 = logits（[-8,8]），1 = 概率行（softmax），
/// 2 = 混合（偶数帧概率、奇数帧 logits），3 = 概率行里夹并列最大与 -0.0。
/// 帧序列按「同一 token 连续几帧 / blank / 换 token」随机游走，保证有重复与 run。
Float32List _ctcTensor(int frames, int vocab, int kind, int seed) {
  final SynthRng rng = SynthRng(seed);
  final Float32List out = Float32List(frames * vocab);
  int current = 0;
  for (int t = 0; t < frames; t++) {
    final int roll = rng.below(10);
    if (roll < 3) {
      current = 0;
    } else if (roll < 7) {
      current = 1 + rng.below(vocab - 1);
    } // 其余保持上一帧
    final int base = t * vocab;
    final bool prob = kind == 1 || kind == 3 || (kind == 2 && t.isEven);
    if (!prob) {
      for (int v = 0; v < vocab; v++) {
        out[base + v] = _unit(rng) * 16 - 8;
      }
      out[base + current] = 8 + _unit(rng) * 4;
      if (rng.below(5) == 0) {
        // 并列最大：先出现的下标胜。
        final int other = rng.below(vocab);
        out[base + other] = out[base + current];
      }
    } else {
      double sum = 0;
      final Float64List raw = Float64List(vocab);
      for (int v = 0; v < vocab; v++) {
        raw[v] = math.exp(_unit(rng) * 6 - 3);
      }
      raw[current] += vocab * (1 + _unit(rng) * 3);
      for (int v = 0; v < vocab; v++) {
        sum += raw[v];
      }
      for (int v = 0; v < vocab; v++) {
        out[base + v] = raw[v] / sum;
      }
      if (kind == 3) {
        if (rng.below(3) == 0) out[base + rng.below(vocab)] = -0.0;
        if (rng.below(4) == 0) {
          out[base + rng.below(vocab)] = out[base + current];
        }
        if (rng.below(6) == 0) {
          // 越出概率区间一点点：分支改走 logits 分母。
          out[base + rng.below(vocab)] = 1.0001;
        }
      }
    }
  }
  return out;
}

class _FixedSession implements OcrSession {
  _FixedSession(this.output);

  final OcrTensor output;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async =>
      <String, OcrTensor>{'logits': output};

  @override
  Future<void> close() async {}
}

void _digestPositioned(
  _Digest d,
  ({String text, double? confidence, List<OcrLineToken> tokens}) r,
) {
  d.s(r.text);
  d.f(r.confidence);
  d.i(r.tokens.length);
  for (final OcrLineToken t in r.tokens) {
    d.i(t.start);
    d.i(t.end);
    d.f(t.left);
    d.f(t.right);
  }
}

void _digestDetailed(_Digest d, PpOcrLineRecognition r) {
  d.s(r.text);
  d.i(r.lineWidth);
  d.i(r.lineHeight);
  d.i(r.contentWidth);
  d.i(r.inputWidth);
  d.i(r.tokens.length);
  for (final PpOcrCtcToken t in r.tokens) {
    d.i(t.tokenId);
    d.s(t.text);
    d.i(t.frameStart);
    d.i(t.frameEndExclusive);
    d.f(t.inputLeft);
    d.f(t.inputRight);
    d.f(t.left);
    d.f(t.right);
    d.f(t.confidence);
  }
}

void _digestRaw(_Digest d, List<RawDetection> list) {
  d.i(list.length);
  for (final RawDetection r in list) {
    d.rect(r.rect);
    d.f(r.score);
    d.i(r.classId);
  }
}

void _digestRegions(_Digest d, List<DetectedTextRegion> list) {
  d.i(list.length);
  for (final DetectedTextRegion r in list) {
    d.rect(r.rect);
    d.f(r.score);
    d.i(r.classId);
    d.i(r.insideBubble ? 1 : 0);
  }
}

Float32List _rtdetrLogits(int queries, int classes, SynthRng rng) {
  final Float32List l = Float32List(queries * classes);
  for (int i = 0; i < l.length; i++) {
    // 大多数很低，少数过 0.3，一些落在弱档 [0.02, 0.3)。
    final int roll = rng.below(10);
    l[i] = roll < 6
        ? -6 + _unit(rng) * 2
        : (roll < 8 ? -3.5 + _unit(rng) * 2.5 : -0.5 + _unit(rng) * 4);
  }
  return l;
}

Float32List _rtdetrBoxes(int queries, SynthRng rng) {
  final Float32List b = Float32List(queries * 4);
  for (int q = 0; q < queries; q++) {
    if (q > 0 && rng.below(6) == 0) {
      // 与前一个 query 几乎重合：喂 NMS。
      for (int k = 0; k < 4; k++) {
        b[q * 4 + k] = b[(q - 1) * 4 + k] + (_unit(rng) - 0.5) * 0.004;
      }
      continue;
    }
    b[q * 4] = -0.05 + _unit(rng) * 1.1;
    b[q * 4 + 1] = -0.05 + _unit(rng) * 1.1;
    b[q * 4 + 2] = _unit(rng) * 0.4;
    b[q * 4 + 3] = rng.below(15) == 0 ? 0 : _unit(rng) * 0.3;
  }
  return b;
}

List<PanelRect> _panels(int n, SynthRng rng) => <PanelRect>[
  for (int i = 0; i < n; i++)
    () {
      final double l = -0.1 + _unit(rng) * 1.0;
      final double t = -0.1 + _unit(rng) * 1.0;
      final double w = rng.below(12) == 0 ? 0 : _unit(rng) * 0.6;
      final double h = _unit(rng) * 0.5;
      // 同分并列（量化到 0.05）。
      final double score = (rng.below(20) + 1) / 20;
      return PanelRect(
        left: l,
        top: t,
        right: l + w,
        bottom: t + h,
        score: score,
      );
    }(),
];

/// 用例名 → 产出摘要。
Map<String, FutureOr<String> Function()> ocrKernelCases() {
  final Map<String, FutureOr<String> Function()> cases =
      <String, FutureOr<String> Function()>{};

  // ---- CTC ----
  for (final (int frames, int vocab, int kind, int seed)
      in <(int, int, int, int)>[
        (1, 3, 0, 1),
        (40, 37, 0, 2),
        (40, 37, 1, 3),
        (64, 37, 2, 4),
        (64, 37, 3, 5),
        (80, 211, 3, 6),
        (25, 18710, 1, 7),
        (25, 18710, 0, 8),
      ]) {
    final String tag = 't$frames-v$vocab-k$kind';
    final List<String> vocabList = _vocab(vocab);
    final Float32List data = _ctcTensor(frames, vocab, kind, seed);
    cases['ctc/scored/$tag'] = () {
      final _Digest d = _Digest();
      final ({String text, double? confidence}) r = ctcGreedyDecodeScored(
        data,
        frames,
        vocab,
        vocabList,
      );
      d.s(r.text);
      d.f(r.confidence);
      d.s(ctcGreedyDecode(data, frames, vocab, vocabList));
      return d.done();
    };
    for (final (int lineW, int contentW, int inputW) in <(int, int, int)>[
      (200, 320, 320),
      (900, 400, 400),
      (90, 150, 320),
      (60, 0, 320),
    ]) {
      cases['ctc/positioned/$tag/$lineW-$contentW-$inputW'] = () {
        final _Digest d = _Digest();
        _digestPositioned(
          d,
          ctcGreedyDecodePositioned(
            data,
            frames,
            vocab,
            vocabList,
            lineWidth: lineW,
            contentWidth: contentW,
            inputWidth: inputW,
          ),
        );
        return d.done();
      };
    }
    for (final (int w, int h) in <(int, int)>[(200, 48), (30, 60), (900, 40)]) {
      cases['ctc/detailed/$tag/${w}x$h'] = () async {
        final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
          _FixedSession(OcrTensor.float32(data, <int>[1, frames, vocab])),
          vocab: vocabList,
        );
        final _Digest d = _Digest();
        _digestDetailed(
          d,
          await rec.recognizeLineDetailed(synthImage(w, h, 3, seed)),
        );
        final PpOcrPositionedLine p = await rec.recognizeLinePositioned(
          synthImage(w, h, 3, seed),
        );
        _digestPositioned(d, (
          text: p.text,
          confidence: p.confidence,
          tokens: p.tokens,
        ));
        return d.done();
      };
    }
  }
  // 非有限值：详细路径抛，热路径照常解码（NaN 不比任何值大）。
  for (final (String name, double bad) in <(String, double)>[
    ('nan', double.nan),
    ('inf', double.infinity),
    ('-inf', double.negativeInfinity),
  ]) {
    cases['ctc/nonfinite/$name'] = () async {
      const int frames = 30;
      const int vocab = 37;
      final Float32List data = _ctcTensor(frames, vocab, 2, 99);
      data[5 * vocab] = bad; // 帧 5 的 blank 位
      data[11 * vocab + 7] = bad;
      final List<String> vocabList = _vocab(vocab);
      final _Digest d = _Digest();
      final ({String text, double? confidence}) r = ctcGreedyDecodeScored(
        data,
        frames,
        vocab,
        vocabList,
      );
      d.s(r.text);
      d.f(r.confidence);
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        _FixedSession(OcrTensor.float32(data, <int>[1, frames, vocab])),
        vocab: vocabList,
      );
      try {
        await rec.recognizeLineDetailed(synthImage(120, 48, 3, 1));
        d.s('no-throw');
      } on StateError catch (e) {
        d.s(e.message);
      }
      return d.done();
    };
  }

  // ---- RT-DETR ----
  for (final (int srcW, int srcH, bool aspect, int seed)
      in <(int, int, bool, int)>[
        (1200, 1700, false, 11),
        (1200, 1700, true, 12),
        (640, 640, false, 13),
        (2000, 900, true, 14),
      ]) {
    final String tag = '${srcW}x$srcH-${aspect ? 'lb' : 'sq'}';
    final LetterboxTransform tr = computeLetterbox(
      srcW,
      srcH,
      preserveAspect: aspect,
    );
    final SynthRng rng = SynthRng(seed);
    final Float32List logits = _rtdetrLogits(300, 3, rng);
    final Float32List boxes = _rtdetrBoxes(300, rng);
    for (final double threshold in <double>[0.3, 0.02]) {
      cases['rtdetr/raw/$tag/$threshold'] = () {
        final _Digest d = _Digest();
        final List<RawDetection> raw = decodeRtdetrOutputs(
          logits: logits,
          boxes: boxes,
          transform: tr,
          scoreThreshold: threshold,
        );
        _digestRaw(d, raw);
        final List<RawDetection> strong = <RawDetection>[
          for (final RawDetection r in raw)
            if (r.score >= 0.3) r,
        ];
        final List<RawDetection> kept = applyClassAwareNms(strong);
        _digestRaw(d, kept);
        _digestRaw(d, applyClassAwareNms(raw, iouThreshold: 0.4));
        final PageDetections page = buildPageDetections(
          kept,
          weakDetections: <RawDetection>[
            for (final RawDetection r in raw)
              if (r.score < 0.3) r,
          ],
        );
        _digestRegions(d, page.textRegions);
        d.i(page.bubbles.length);
        for (final OcrRect b in page.bubbles) {
          d.rect(b);
        }
        _digestRegions(d, page.weakTextRegions);
        return d.done();
      };
    }
    // 图内后处理导出：scores / labels（三种数值型）/ xyxy boxes。
    for (final String labelKind in <String>['f32', 'i64', 'i32']) {
      cases['rtdetr/processed/$tag/$labelKind'] = () {
        final SynthRng r2 = SynthRng(seed + 100);
        const int n = 300;
        final Float32List scores = Float32List(n);
        final Float32List xyxy = Float32List(n * 4);
        final List<num> labels;
        final List<double> fl = <double>[];
        for (int i = 0; i < n; i++) {
          scores[i] = r2.below(4) == 0
              ? 0.5
              : _unit(r2) * (r2.below(3) == 0 ? 1 : 0.35);
          final double x = -20 + _unit(r2) * 680;
          final double y = -20 + _unit(r2) * 680;
          xyxy[i * 4] = x;
          xyxy[i * 4 + 1] = y;
          xyxy[i * 4 + 2] = x + (r2.below(10) == 0 ? -3 : _unit(r2) * 200);
          xyxy[i * 4 + 3] = y + _unit(r2) * 150;
          fl.add(r2.below(3) + (r2.below(5) == 0 ? 0.4 : 0.0));
        }
        switch (labelKind) {
          case 'f32':
            labels = Float32List.fromList(fl);
          case 'i64':
            labels = Int64List.fromList(<int>[
              for (final double v in fl) v.round(),
            ]);
          default:
            labels = Int32List.fromList(<int>[
              for (final double v in fl) v.round(),
            ]);
        }
        final _Digest d = _Digest();
        final List<RawDetection> raw = decodeProcessedRtdetrOutputs(
          scores: scores,
          labels: labels,
          boxes: xyxy,
          transform: tr,
          scoreThreshold: 0.02,
        );
        _digestRaw(d, raw);
        final List<RawDetection> kept = applyClassAwareNms(<RawDetection>[
          for (final RawDetection r in raw)
            if (r.score >= 0.3) r,
        ]);
        _digestRaw(d, kept);
        final PageDetections page = buildPageDetections(kept);
        _digestRegions(d, page.textRegions);
        d.i(page.bubbles.length);
        return d.done();
      };
    }
  }
  cases['rtdetr/processed/shape-mismatch'] = () {
    final _Digest d = _Digest();
    try {
      decodeProcessedRtdetrOutputs(
        scores: Float32List(3),
        labels: const <num>[0, 1],
        boxes: Float32List(12),
        transform: computeLetterbox(10, 10),
      );
      d.s('no-throw');
    } on StateError catch (e) {
      d.s(e.message);
    }
    return d.done();
  };

  // ---- 分格排序 ----
  for (final int n in <int>[0, 1, 5, 31, 33, 80]) {
    for (final PanelReadingDirection dir in PanelReadingDirection.values) {
      cases['panels/order/$n/${dir.name}'] = () {
        final List<PanelRect> input = _panels(n, SynthRng(500 + n));
        final List<PanelRect> out = orderPanelRects(input, direction: dir);
        final _Digest d = _Digest();
        d.i(out.length);
        for (final PanelRect p in out) {
          d.f(p.left);
          d.f(p.top);
          d.f(p.right);
          d.f(p.bottom);
          d.f(p.score);
        }
        return d.done();
      };
    }
  }
  return cases;
}

/// 生成向量时用：把整张表打印成 Dart 源码。
Future<void> printOcrKernelVectors() async {
  for (final MapEntry<String, FutureOr<String> Function()> e
      in ocrKernelCases().entries) {
    // ignore: avoid_print
    print("  '${e.key}': '${await e.value()}',");
  }
}
