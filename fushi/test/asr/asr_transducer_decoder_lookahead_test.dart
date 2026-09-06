import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

/// 词表：0=<blk> 1..8 = 字符，9=<unk>。
const String _tokensText =
    '<blk>\t0\nあ\t1\nい\t2\nう\t3\nえ\t4\nお\t5\nか\t6\nき\t7\nく\t8\n<unk>\t9\n';
const int _vocab = 10;
const int _encDim = 4;
const int _decDim = 3;

class _Encoder implements OnnxSession {
  _Encoder(this.lens);
  final List<int> lens;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final int n = inputs[AsrModelIo.encoderInputX]!.shape[0];
    final int maxLen = lens.reduce(math.max);
    final Float32List out = Float32List(n * maxLen * _encDim);
    for (int i = 0; i < n; i++) {
      for (int t = 0; t < maxLen; t++) {
        final int base = (i * maxLen + t) * _encDim;
        out[base] = i.toDouble();
        out[base + 1] = t.toDouble();
      }
    }
    return <String, OnnxTensor>{
      AsrModelIo.encoderOutput: OnnxTensor.float32(out, <int>[
        n,
        maxLen,
        _encDim,
      ]),
      AsrModelIo.encoderOutputLens: OnnxTensor.float32(
        Float32List.fromList(lens.map((int l) => l.toDouble()).toList()),
        <int>[n],
      ),
    };
  }

  @override
  Future<void> close() async {}
}

class _Decoder implements OnnxSession {
  int calls = 0;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    calls++;
    final OnnxTensor y = inputs[AsrModelIo.decoderInputY]!;
    final int rows = y.shape[0];
    final Float32List out = Float32List(rows * _decDim);
    for (int r = 0; r < rows; r++) {
      out[r * _decDim] = y.intData![r * 2].toDouble();
      out[r * _decDim + 1] = y.intData![r * 2 + 1].toDouble();
    }
    return <String, OnnxTensor>{
      AsrModelIo.decoderOutput: OnnxTensor.float32(out, <int>[rows, _decDim]),
    };
  }

  @override
  Future<void> close() async {}
}

/// 伪随机但确定的 joiner：目标 token 由 (sample, frame, ctx0, ctx1) 哈希决定，
/// 约 70% 帧为 blank、少量 unk——让「发射后上下文变化影响后续帧」这条依赖链真被触发。
class _Joiner implements OnnxSession {
  int calls = 0;
  int rows = 0;

  static int plan(int sample, int frame, int ctx0, int ctx1) {
    final int h =
        (sample * 7919 + frame * 104729 + ctx0 * 31 + ctx1 * 131) & 0x7fffffff;
    final int bucket = h % 100;
    if (bucket < 70) return 0; // blank
    if (bucket < 74) return 9; // unk
    return 1 + (h ~/ 100) % 8;
  }

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    calls++;
    final OnnxTensor enc = inputs[AsrModelIo.joinerInputEncoder]!;
    final OnnxTensor dec = inputs[AsrModelIo.joinerInputDecoder]!;
    final int n = enc.shape[0];
    rows += n;
    final Float32List logit = Float32List(n * _vocab);
    for (int r = 0; r < n; r++) {
      final int target = plan(
        enc.floatData![r * _encDim].round(),
        enc.floatData![r * _encDim + 1].round(),
        dec.floatData![r * _decDim].round(),
        dec.floatData![r * _decDim + 1].round(),
      );
      for (int v = 0; v < _vocab; v++) {
        logit[r * _vocab + v] = v == target ? 5 : -10;
      }
    }
    return <String, OnnxTensor>{
      AsrModelIo.joinerOutputLogit: OnnxTensor.float32(logit, <int>[n, _vocab]),
    };
  }

  @override
  Future<void> close() async {}
}

Future<
  ({
    List<AsrDecodedSegment> out,
    int joinerCalls,
    int joinerRows,
    int decoderCalls,
  })
>
_run(int lookahead, List<int> lens) async {
  final _Joiner joiner = _Joiner();
  final _Decoder decoder = _Decoder();
  final AsrTransducerDecoder d = AsrTransducerDecoder(
    encoder: _Encoder(lens),
    decoder: decoder,
    joiner: joiner,
    tokens: AsrTokenTable.parse(_tokensText),
    lookaheadFrames: lookahead,
  );
  // 样本数只决定 fbank 帧数上界；fake encoder 用 lens 决定真实帧数。
  final List<AsrSpeechSegment> segs = <AsrSpeechSegment>[
    for (final int l in lens)
      AsrSpeechSegment(startSample: 0, samples: Float32List(l * 4 * 160 + 400)),
  ];
  final List<AsrDecodedSegment> out = await d.decodeBatch(segs);
  return (
    out: out,
    joinerCalls: joiner.calls,
    joinerRows: joiner.rows,
    decoderCalls: decoder.calls,
  );
}

void main() {
  test('前瞻 1/3/8/64 的解码结果与逐帧贪心逐字等价，往返次数随前瞻下降', () async {
    final List<int> lens = <int>[137, 64, 200, 1, 91];
    final base = await _run(1, lens);
    // 逐帧：joiner 调用 = 最长帧数。
    expect(base.joinerCalls, 200);
    int lastCalls = base.joinerCalls;
    for (final int k in <int>[3, 8, 64]) {
      final r = await _run(k, lens);
      for (int i = 0; i < lens.length; i++) {
        expect(r.out[i].tokens, base.out[i].tokens, reason: 'k=$k sample $i');
        expect(
          r.out[i].tokenOffsetsMs,
          base.out[i].tokenOffsetsMs,
          reason: 'k=$k sample $i offsets',
        );
      }
      // 往返次数由「发射数 + 剩余帧/K」托底：K 越大越少，到发射数附近饱和。
      expect(r.joinerCalls, lessThanOrEqualTo(lastCalls), reason: 'k=$k');
      expect(r.joinerCalls, lessThan(base.joinerCalls), reason: 'k=$k vs 逐帧');
      lastCalls = r.joinerCalls;
      // 前瞻不会改变发射次数，decoder 调用（按批合并）不会多于逐帧。
      expect(r.decoderCalls, lessThanOrEqualTo(base.decoderCalls));
    }
    // 至少发射了一些 token，否则等价性检查是空的。
    final int emitted = base.out.fold<int>(
      0,
      (int a, AsrDecodedSegment s) => a + s.tokens.length,
    );
    expect(emitted, greaterThan(50));
  });

  test('lookaheadFrames < 1 报错', () {
    expect(
      () => AsrTransducerDecoder(
        encoder: _Encoder(<int>[1]),
        decoder: _Decoder(),
        joiner: _Joiner(),
        tokens: AsrTokenTable.parse(_tokensText),
        lookaheadFrames: 0,
      ),
      throwsArgumentError,
    );
  });
}
