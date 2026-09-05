import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_fbank.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

/// 测试词表：0=<blk> 1=あ 2=い 3=う 4=<unk> 5=<sos/eos>。
const String kTokensText =
    '<blk>\t0\nあ\t1\nい\t2\nう\t3\n<unk>\t4\n<sos/eos>\t5\n';
const int kVocab = 6;
const int kEncDim = 4;
const int kDecDim = 3;

/// fake encoder：`encoder_out[i, t] = [i, t, 0, 0]`，帧数由 [lens] 给定。
class FakeEncoderSession implements OnnxSession {
  FakeEncoderSession({required this.lens, this.lensAsFloat = true});

  final List<int> lens;

  /// 模拟 ORT 层把 int64 输出读成 float32。
  final bool lensAsFloat;

  final List<List<int>> xShapes = <List<int>>[];
  final List<List<int>> xLens = <List<int>>[];
  final List<Float32List> xData = <Float32List>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor x = inputs[AsrModelIo.encoderInputX]!;
    final OnnxTensor xl = inputs[AsrModelIo.encoderInputXLens]!;
    expect(x.type, OnnxTensorType.float32);
    expect(xl.type, OnnxTensorType.int64);
    xShapes.add(List<int>.from(x.shape));
    xLens.add(List<int>.from(xl.intData!));
    xData.add(x.floatData!);
    final int n = x.shape[0];
    expect(lens, hasLength(n));
    int maxLen = 0;
    for (final int l in lens) {
      if (l > maxLen) maxLen = l;
    }
    final Float32List out = Float32List(n * maxLen * kEncDim);
    for (int i = 0; i < n; i++) {
      for (int t = 0; t < maxLen; t++) {
        final int base = (i * maxLen + t) * kEncDim;
        out[base] = i.toDouble();
        out[base + 1] = t.toDouble();
      }
    }
    final OnnxTensor lensTensor = lensAsFloat
        ? OnnxTensor.float32(
            Float32List.fromList(lens.map((int l) => l.toDouble()).toList()),
            <int>[n],
          )
        : OnnxTensor.int64(Int64List.fromList(lens), <int>[n]);
    return <String, OnnxTensor>{
      AsrModelIo.encoderOutput: OnnxTensor.float32(out, <int>[
        n,
        maxLen,
        kEncDim,
      ]),
      AsrModelIo.encoderOutputLens: lensTensor,
    };
  }

  @override
  Future<void> close() async {}
}

/// fake decoder：`decoder_out[r] = [y0, y1, 0]`（把上下文原样带给 joiner）。
class FakeDecoderSession implements OnnxSession {
  final List<List<List<int>>> calls = <List<List<int>>>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor y = inputs[AsrModelIo.decoderInputY]!;
    expect(y.type, OnnxTensorType.int64);
    final int rows = y.shape[0];
    expect(y.shape, <int>[rows, 2]);
    final List<List<int>> contexts = <List<int>>[];
    final Float32List out = Float32List(rows * kDecDim);
    for (int r = 0; r < rows; r++) {
      final int y0 = y.intData![r * 2];
      final int y1 = y.intData![r * 2 + 1];
      contexts.add(<int>[y0, y1]);
      out[r * kDecDim] = y0.toDouble();
      out[r * kDecDim + 1] = y1.toDouble();
    }
    calls.add(contexts);
    return <String, OnnxTensor>{
      AsrModelIo.decoderOutput: OnnxTensor.float32(out, <int>[rows, kDecDim]),
    };
  }

  @override
  Future<void> close() async {}
}

/// fake joiner：由测试给出 `(sample, frame, ctx0, ctx1) -> 目标 token`，其余 logit 为 -10。
class FakeJoinerSession implements OnnxSession {
  FakeJoinerSession(this.plan);

  final int Function(int sample, int frame, int ctx0, int ctx1) plan;
  final List<int> rowCounts = <int>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor enc = inputs[AsrModelIo.joinerInputEncoder]!;
    final OnnxTensor dec = inputs[AsrModelIo.joinerInputDecoder]!;
    final int rows = enc.shape[0];
    expect(enc.shape, <int>[rows, kEncDim]);
    expect(dec.shape, <int>[rows, kDecDim]);
    rowCounts.add(rows);
    final Float32List logit = Float32List(rows * kVocab);
    for (int r = 0; r < rows; r++) {
      final int sample = enc.floatData![r * kEncDim].round();
      final int frame = enc.floatData![r * kEncDim + 1].round();
      final int ctx0 = dec.floatData![r * kDecDim].round();
      final int ctx1 = dec.floatData![r * kDecDim + 1].round();
      final int target = plan(sample, frame, ctx0, ctx1);
      for (int v = 0; v < kVocab; v++) {
        logit[r * kVocab + v] = v == target ? 5 : -10;
      }
    }
    return <String, OnnxTensor>{
      AsrModelIo.joinerOutputLogit: OnnxTensor.float32(logit, <int>[
        rows,
        kVocab,
      ]),
    };
  }

  @override
  Future<void> close() async {}
}

AsrSpeechSegment segmentOfSamples(int n, {int start = 0}) =>
    AsrSpeechSegment(startSample: start, samples: Float32List(n));

void main() {
  final AsrTokenTable tokens = AsrTokenTable.parse(kTokensText);

  test('词表解析：blank/unk/eos', () {
    expect(tokens.blankId, 0);
    expect(tokens.unkId, 4);
    expect(tokens.eosId, 5);
    expect(tokens.size, kVocab);
  });

  test('单条：blank/unk 不发射，发射后上下文滑动并重算 decoder，时间戳 = 帧 × 40 ms', () async {
    // 5 个编码帧：t0→あ, t1→blank, t2→い, t3→unk, t4→う。
    final FakeEncoderSession enc = FakeEncoderSession(lens: <int>[5]);
    final FakeDecoderSession dec = FakeDecoderSession();
    final FakeJoinerSession join = FakeJoinerSession(
      (int sample, int frame, int ctx0, int ctx1) => switch (frame) {
        0 => 1,
        2 => 2,
        3 => 4,
        4 => 3,
        _ => 0,
      },
    );
    final AsrTransducerDecoder decoder = AsrTransducerDecoder(
      encoder: enc,
      decoder: dec,
      joiner: join,
      tokens: tokens,
    );
    final List<AsrDecodedSegment> out = await decoder.decodeBatch(
      <AsrSpeechSegment>[segmentOfSamples(1600)],
    );

    expect(out, hasLength(1));
    expect(out.single.tokens, <String>['あ', 'い', 'う']);
    expect(out.single.text, 'あいう');
    expect(out.single.tokenOffsetsMs, <int>[0, 80, 160]);
    // 1600 样本 → 10 帧。
    expect(enc.xShapes.single, <int>[1, 10, 80]);
    expect(enc.xLens.single, <int>[10]);
    // decoder：初始 1 次 + 发射 3 次；上下文依次 [0,0] [0,1] [1,2] [2,3]。
    expect(dec.calls, <List<List<int>>>[
      <List<int>>[
        <int>[0, 0],
      ],
      <List<int>>[
        <int>[0, 1],
      ],
      <List<int>>[
        <int>[1, 2],
      ],
      <List<int>>[
        <int>[2, 3],
      ],
    ]);
    // joiner 每帧一次，每次 1 行。
    expect(join.rowCounts, List<int>.filled(5, 1));
  });

  test(
      '多条 batch：按最长帧数 pad（pad 值 log 1e-10）、x_lens 给真实帧数、'
      '结束的样本不再进 joiner、同帧多条发射合并成一次 decoder 调用', () async {
    // 样本 0：1600 样本 = 10 帧；样本 1：800 样本 = 5 帧。编码后帧数 3 / 2。
    final FakeEncoderSession enc = FakeEncoderSession(lens: <int>[3, 2]);
    final FakeDecoderSession dec = FakeDecoderSession();
    final FakeJoinerSession join = FakeJoinerSession((
      int sample,
      int frame,
      int ctx0,
      int ctx1,
    ) {
      if (sample == 0) {
        return switch (frame) {
          0 => 1,
          2 => 3,
          _ => 0,
        };
      }
      return switch (frame) {
        0 => 2,
        _ => 0,
      };
    });
    final AsrTransducerDecoder decoder = AsrTransducerDecoder(
      encoder: enc,
      decoder: dec,
      joiner: join,
      tokens: tokens,
    );
    final List<AsrDecodedSegment> out = await decoder.decodeBatch(
      <AsrSpeechSegment>[
        segmentOfSamples(1600),
        segmentOfSamples(800, start: 99),
      ],
    );

    expect(out, hasLength(2));
    expect(out[0].tokens, <String>['あ', 'う']);
    expect(out[0].tokenOffsetsMs, <int>[0, 80]);
    expect(out[1].tokens, <String>['い']);
    expect(out[1].tokenOffsetsMs, <int>[0]);

    expect(enc.xShapes.single, <int>[2, 10, 80]);
    expect(enc.xLens.single, <int>[10, 5]);
    final Float32List x = enc.xData.single;
    // 样本 1 的第 5 帧起是 pad。
    const int row1 = 10 * 80;
    for (int k = 5 * 80; k < 10 * 80; k++) {
      expect(x[row1 + k], closeTo(AsrTransducerDecoder.kFeaturePadValue, 1e-6));
    }
    // 样本 1 前 5 帧是真实特征（全零输入 → log(eps) ≈ -15.94，不是 pad 值）。
    expect(x[row1], closeTo(-15.9424, 1e-3));

    // t=0 两条都活跃，t=1 两条，t=2 只剩样本 0。
    expect(join.rowCounts, <int>[2, 2, 1]);
    // decoder：初始（2 行）+ t=0 两条同帧发射合并（2 行）+ t=2 样本 0（1 行）。
    expect(dec.calls, <List<List<int>>>[
      <List<int>>[
        <int>[0, 0],
        <int>[0, 0],
      ],
      <List<int>>[
        <int>[0, 1],
        <int>[0, 2],
      ],
      <List<int>>[
        <int>[1, 3],
      ],
    ]);
  });

  test('encoder_out_lens 以 int64 返回时同样可用', () async {
    final FakeEncoderSession enc = FakeEncoderSession(
      lens: <int>[2],
      lensAsFloat: false,
    );
    final FakeDecoderSession dec = FakeDecoderSession();
    final FakeJoinerSession join = FakeJoinerSession(
      (int sample, int frame, int ctx0, int ctx1) => frame == 1 ? 2 : 0,
    );
    final AsrTransducerDecoder decoder = AsrTransducerDecoder(
      encoder: enc,
      decoder: dec,
      joiner: join,
      tokens: tokens,
    );
    final List<AsrDecodedSegment> out = await decoder.decodeBatch(
      <AsrSpeechSegment>[segmentOfSamples(800)],
    );
    expect(out.single.tokens, <String>['い']);
    expect(out.single.tokenOffsetsMs, <int>[40]);
    expect(join.rowCounts, <int>[1, 1]);
  });

  test('全 blank → 空结果；空输入 → 空列表且不碰模型', () async {
    final FakeEncoderSession enc = FakeEncoderSession(lens: <int>[3]);
    final FakeDecoderSession dec = FakeDecoderSession();
    final FakeJoinerSession join = FakeJoinerSession(
      (int sample, int frame, int ctx0, int ctx1) => 0,
    );
    final AsrTransducerDecoder decoder = AsrTransducerDecoder(
      encoder: enc,
      decoder: dec,
      joiner: join,
      tokens: tokens,
    );
    expect(await decoder.decodeBatch(<AsrSpeechSegment>[]), isEmpty);
    expect(enc.xShapes, isEmpty);

    final List<AsrDecodedSegment> out = await decoder.decodeBatch(
      <AsrSpeechSegment>[segmentOfSamples(1600)],
    );
    expect(out.single.isEmpty, isTrue);
    expect(dec.calls, hasLength(1), reason: '只有初始 decoder_out');
  });

  test('encoder_out_lens 超出 encoder_out 帧数时报错而非静默截断', () async {
    final FakeEncoderSession enc = FakeEncoderSession(lens: <int>[3]);
    final FakeDecoderSession dec = FakeDecoderSession();
    final FakeJoinerSession join = FakeJoinerSession(
      (int sample, int frame, int ctx0, int ctx1) => 0,
    );
    // 用一个把 lens 说成 5 但 encoder_out 只有 3 帧的会话。
    final _LyingLensEncoder lying = _LyingLensEncoder(enc, claimedLen: 5);
    final AsrTransducerDecoder decoder = AsrTransducerDecoder(
      encoder: lying,
      decoder: dec,
      joiner: join,
      tokens: tokens,
      fbank: const AsrFbank(),
    );
    expect(
      () => decoder.decodeBatch(<AsrSpeechSegment>[segmentOfSamples(1600)]),
      throwsStateError,
    );
  });

  test('词表没有 <blk> 时构造即报错', () {
    expect(
      () => AsrTransducerDecoder(
        encoder: FakeEncoderSession(lens: <int>[1]),
        decoder: FakeDecoderSession(),
        joiner: FakeJoinerSession((int s, int f, int a, int b) => 0),
        tokens: AsrTokenTable.parse('a\t0\nb\t1\n'),
      ),
      throwsArgumentError,
    );
  });
}

/// 包一层：把 encoder_out_lens 改成 [claimedLen]。
class _LyingLensEncoder implements OnnxSession {
  _LyingLensEncoder(this.inner, {required this.claimedLen});

  final OnnxSession inner;
  final int claimedLen;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final Map<String, OnnxTensor> out = Map<String, OnnxTensor>.from(
      await inner.run(inputs),
    );
    out[AsrModelIo.encoderOutputLens] = OnnxTensor.float32(
      Float32List.fromList(<double>[claimedLen.toDouble()]),
      <int>[1],
    );
    return out;
  }

  @override
  Future<void> close() => inner.close();
}
