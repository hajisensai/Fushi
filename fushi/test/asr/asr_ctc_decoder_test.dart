import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_ctc_decoder.dart';
import 'package:fushi/src/asr/asr_encoder_buckets.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

/// Omnilingual 形态的词表：`<s>`=blank(0)、`<pad>`、`</s>`、`<unk>`、空格 token、字符。
const String _kTokens = '<s> 0\n<pad> 1\n</s> 2\n<unk> 3\n  4\na 5\nb 6\nc 7\n';
const int _kVocab = 8;

/// 每 320 样本一帧。
const int _kFrameSamples = 320;

/// fake CTC 模型：`logits[N, T, V]`，第 r 行第 t 帧的 argmax 由 [plan] 给出；
/// 记录每次 run 的输入形状与前几个样本（核归一化）。
class _CtcSession implements OnnxSession {
  _CtcSession(this.plan);

  final int Function(int row, int frame) plan;
  final List<List<int>> shapes = <List<int>>[];
  final List<Float32List> inputs = <Float32List>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor x = inputs[AsrModelIo.ctcInputX]!;
    expect(x.type, OnnxTensorType.float32);
    expect(x.shape, hasLength(2));
    shapes.add(List<int>.from(x.shape));
    this.inputs.add(x.floatData!);
    final int rows = x.shape[0];
    final int frames = x.shape[1] ~/ _kFrameSamples;
    final Float32List logits = Float32List(rows * frames * _kVocab);
    for (int r = 0; r < rows; r++) {
      for (int t = 0; t < frames; t++) {
        final int base = (r * frames + t) * _kVocab;
        final int target = plan(r, t);
        for (int v = 0; v < _kVocab; v++) {
          logits[base + v] = v == target ? 3 : -3;
        }
      }
    }
    return <String, OnnxTensor>{
      AsrModelIo.ctcOutputLogits: OnnxTensor.float32(logits, <int>[
        rows,
        frames,
        _kVocab,
      ]),
    };
  }

  @override
  Future<void> close() async {}
}

class _Factory implements OnnxSessionFactory {
  _Factory(this.plan);
  final int Function(int row, int frame) plan;
  final List<Map<String, int>?> overrides = <Map<String, int>?>[];
  final List<_CtcSession> created = <_CtcSession>[];

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    overrides.add(freeDimensionOverrides);
    final _CtcSession s = _CtcSession(plan);
    created.add(s);
    return s;
  }
}

/// 3 s 的段，波形是有直流偏置的正弦（归一化后才是零均值）。
AsrSpeechSegment _segment({int seconds = 3, int start = 0}) {
  final Float32List x = Float32List(seconds * kAsrSampleRate);
  for (int i = 0; i < x.length; i++) {
    x[i] = 0.5 + 0.1 * (i % 7 - 3);
  }
  return AsrSpeechSegment(startSample: start, samples: x);
}

/// 帧 0..2 → a，帧 3 → blank，帧 4..5 → b，帧 6 → 空格，帧 7 → c，其余 blank。
int _abcPlan(int row, int t) => switch (t) {
      0 || 1 || 2 => 5,
      4 || 5 => 6,
      6 => 4,
      7 => 7,
      _ => 0,
    };

void main() {
  final AsrTokenTable tokens = AsrTokenTable.parse(_kTokens, blankToken: '<s>');

  test('词表：blank=<s>、pad / </s> / <unk> 都是特殊符号', () {
    expect(tokens.blankId, 0);
    expect(tokens.padId, 1);
    expect(tokens.eosId, 2);
    expect(tokens.unkId, 3);
    expect(tokens.isSpecial(1), isTrue);
    expect(tokens.isSpecial(4), isFalse, reason: '空格 token 要进文本');
    expect(tokens.isSentencePiece, isFalse);
  });

  test('normalizeWaveform：零均值单位方差', () {
    final Float32List y = AsrCtcDecoder.normalizeWaveform(_segment().samples);
    double sum = 0;
    double sq = 0;
    for (final double v in y) {
      sum += v;
      sq += v * v;
    }
    expect(sum / y.length, closeTo(0, 1e-3));
    expect(sq / y.length, closeTo(1, 1e-2));
    expect(AsrCtcDecoder.normalizeWaveform(Float32List(0)), isEmpty);
  });

  test('动态路径：逐段精确长度、归一化后喂入、CTC 折叠、时间 = 帧 × 20 ms', () async {
    final _CtcSession session = _CtcSession(_abcPlan);
    final AsrCtcDecoder d = AsrCtcDecoder(model: session, tokens: tokens);
    final List<AsrDecodedSegment> out = await d.decodeBatch(<AsrSpeechSegment>[
      _segment(seconds: 3),
      _segment(seconds: 2, start: 3 * kAsrSampleRate),
    ]);
    // 一段一次 run，形状 [1, 精确样本数]。
    expect(session.shapes, <List<int>>[
      <int>[1, 3 * kAsrSampleRate],
      <int>[1, 2 * kAsrSampleRate],
    ]);
    // 喂进去的是归一化波形（原始波形均值 0.5）。
    double mean = 0;
    for (final double v in session.inputs.first) {
      mean += v;
    }
    expect(mean / session.inputs.first.length, closeTo(0, 1e-3));
    for (final AsrDecodedSegment s in out) {
      expect(s.tokens, <String>['a', 'b', ' ', 'c']);
      expect(s.tokenOffsetsMs, <int>[0, 80, 120, 140]);
      expect(s.text, 'ab c');
    }
    expect(d.stats.batches, 1);
    expect(d.stats.segments, 2);
    expect(d.stats.paddingRatio, 1.0, reason: '动态路径零 padding');
    expect(d.batchCapFor(kAsrSampleRate), isNull);
    expect(d.bucketKeyFor(kAsrSampleRate), isNull);
  });

  test('静态桶：整批填成 [N_b, S_b]（无哨兵行）、多余行喂零、输出只取真实行', () async {
    final _Factory factory = _Factory(_abcPlan);
    final AsrStaticEncoderPool pool = AsrStaticEncoderPool(
      factory: factory,
      modelPath: 'model.onnx',
      providers: const <OnnxExecutionProvider>[OnnxExecutionProvider.directml],
      buckets: kAsrCtcGpuBuckets,
      batchDimName: kAsrCtcBatchDim,
      timeDimName: kAsrCtcSamplesDim,
    );
    final AsrCtcDecoder d = AsrCtcDecoder(
      model: _CtcSession(_abcPlan),
      tokens: tokens,
      staticSessions: pool,
    );
    // 3 s 段落进 6 s 桶（N=8，无哨兵 → 8 行全真实）。
    expect(d.batchCapFor(3 * kAsrSampleRate), 8);
    expect(d.bucketKeyFor(3 * kAsrSampleRate), 6 * kAsrSampleRate);
    expect(d.bucketKeyFor(20 * kAsrSampleRate), 21 * kAsrSampleRate);
    expect(d.batchCapFor(20 * kAsrSampleRate), 2);
    expect(d.bucketKeyFor(30 * kAsrSampleRate), isNull, reason: '超过最大桶走动态');

    final List<AsrDecodedSegment> out = await d.decodeBatch(<AsrSpeechSegment>[
      _segment(seconds: 3),
      _segment(seconds: 2, start: 3 * kAsrSampleRate),
    ]);
    expect(out, hasLength(2));
    expect(out.first.text, 'ab c');
    expect(factory.overrides.single, <String, int>{
      kAsrCtcBatchDim: 8,
      kAsrCtcSamplesDim: 6 * kAsrSampleRate,
    });
    final _CtcSession bucketSession = factory.created.single;
    expect(bucketSession.shapes.single, <int>[8, 6 * kAsrSampleRate]);
    // 第三行起全零。
    final Float32List x = bucketSession.inputs.single;
    const int cols = 6 * kAsrSampleRate;
    expect(x.sublist(2 * cols, 3 * cols).every((double v) => v == 0), isTrue);
    expect(d.stats.staticBatches, 1);
    expect(d.stats.paddedFrames, 8 * cols ~/ _kFrameSamples);
    expect(d.stats.realFrames, 5 * kAsrSampleRate ~/ _kFrameSamples);
  });

  test('空批抛 ArgumentError；超过桶容量的直接 encode 抛、decodeBatch 自动拆批', () async {
    final _Factory factory = _Factory(_abcPlan);
    final AsrStaticEncoderPool pool = AsrStaticEncoderPool(
      factory: factory,
      modelPath: 'model.onnx',
      providers: const <OnnxExecutionProvider>[OnnxExecutionProvider.directml],
      buckets: kAsrCtcGpuBuckets,
      batchDimName: kAsrCtcBatchDim,
      timeDimName: kAsrCtcSamplesDim,
    );
    final AsrCtcDecoder d = AsrCtcDecoder(
      model: _CtcSession(_abcPlan),
      tokens: tokens,
      staticSessions: pool,
    );
    expect(() => d.encode(const <AsrSpeechSegment>[]), throwsArgumentError);
    final List<AsrSpeechSegment> nine = List<AsrSpeechSegment>.generate(
      9,
      (int i) => _segment(seconds: 1, start: i * kAsrSampleRate),
    );
    expect(() => d.encode(nine), throwsArgumentError);
    final List<AsrDecodedSegment> out = await d.decodeBatch(nine);
    expect(out, hasLength(9));
    expect(factory.created.single.shapes, hasLength(2), reason: '8 + 1 两批');
  });

  test('runLogits：一段一次 run、归一化后喂入、返回完整原始 logits 与帧长', () async {
    final _CtcSession session = _CtcSession(_abcPlan);
    final AsrCtcDecoder d = AsrCtcDecoder(model: session, tokens: tokens);
    final AsrCtcLogits lg = await d.runLogits(_segment(seconds: 3).samples);
    expect(session.shapes, <List<int>>[
      <int>[1, 3 * kAsrSampleRate],
    ]);
    expect(lg.frames, 3 * kAsrSampleRate ~/ _kFrameSamples);
    expect(lg.vocab, _kVocab);
    expect(lg.frameSamples, _kFrameSamples);
    expect(lg.frameMs, 20);
    expect(lg.logits, hasLength(lg.frames * lg.vocab));
    // 帧 0 的目标是 a(5)：该列最大；帧 3 是 blank。
    expect(lg.logits[5], 3);
    expect(lg.logits[3 * _kVocab + 0], 3);
    expect(() => d.runLogits(Float32List(0)), throwsArgumentError);
  });
}
