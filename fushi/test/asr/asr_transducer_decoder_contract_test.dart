import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

/// `AsrTransducerDecoder` 的两个模型包契约参数：
/// - `contextSize`（MDCC 粤语 decoder `y[N,1]`）；
/// - `indexType`（X-ASR 中文 `x_lens` / `y` 是 int32）。
///
/// fake 会话把「收到的张量类型与形状」原样断言：契约写错时 ORT 会拒绝张量，
/// 这里让它在单测层就红。
const String _kTokens = '<blk>\t0\nあ\t1\nい\t2\n<unk>\t3\n';
const int _kVocab = 4;
const int _kEncDim = 2;
const int _kDecDim = 2;

class _Encoder implements OnnxSession {
  _Encoder(this.expectType);

  final OnnxTensorType expectType;
  final List<OnnxTensorType> seenLensTypes = <OnnxTensorType>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor x = inputs[AsrModelIo.encoderInputX]!;
    final OnnxTensor xl = inputs[AsrModelIo.encoderInputXLens]!;
    seenLensTypes.add(xl.type);
    expect(xl.type, expectType);
    final int n = x.shape[0];
    const int frames = 3;
    final Float32List out = Float32List(n * frames * _kEncDim);
    for (int i = 0; i < n; i++) {
      for (int t = 0; t < frames; t++) {
        out[(i * frames + t) * _kEncDim] = t.toDouble();
      }
    }
    return <String, OnnxTensor>{
      AsrModelIo.encoderOutput: OnnxTensor.float32(out, <int>[
        n,
        frames,
        _kEncDim,
      ]),
      AsrModelIo.encoderOutputLens: OnnxTensor.float32(
        Float32List.fromList(List<double>.filled(n, frames.toDouble())),
        <int>[n],
      ),
    };
  }

  @override
  Future<void> close() async {}
}

/// `decoder_out[r] = [y_last, 0]`：把上下文最后一个 token 带给 joiner。
class _Decoder implements OnnxSession {
  _Decoder({required this.expectType, required this.expectContext});

  final OnnxTensorType expectType;
  final int expectContext;
  final List<List<int>> contexts = <List<int>>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor y = inputs[AsrModelIo.decoderInputY]!;
    expect(y.type, expectType);
    final int rows = y.shape[0];
    expect(y.shape, <int>[rows, expectContext]);
    final List<int> flat = switch (y.type) {
      OnnxTensorType.int64 => y.intData!,
      OnnxTensorType.int32 => y.int32Data!,
      OnnxTensorType.float32 => throw StateError('y 不该是 float'),
    };
    final Float32List out = Float32List(rows * _kDecDim);
    for (int r = 0; r < rows; r++) {
      final List<int> ctx = flat.sublist(
        r * expectContext,
        (r + 1) * expectContext,
      );
      contexts.add(ctx);
      out[r * _kDecDim] = ctx.last.toDouble();
    }
    return <String, OnnxTensor>{
      AsrModelIo.decoderOutput: OnnxTensor.float32(out, <int>[rows, _kDecDim]),
    };
  }

  @override
  Future<void> close() async {}
}

/// 第 0 帧且上下文末尾是 blank → 发 あ(1)；第 1 帧且上下文末尾是 あ → 发 い(2)；
/// 其余 blank。
class _Joiner implements OnnxSession {
  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor enc = inputs[AsrModelIo.joinerInputEncoder]!;
    final OnnxTensor dec = inputs[AsrModelIo.joinerInputDecoder]!;
    final int rows = enc.shape[0];
    final Float32List logit = Float32List(rows * _kVocab);
    for (int r = 0; r < rows; r++) {
      final int frame = enc.floatData![r * _kEncDim].round();
      final int last = dec.floatData![r * _kDecDim].round();
      int target = 0;
      if (frame == 0 && last == 0) target = 1;
      if (frame == 1 && last == 1) target = 2;
      for (int v = 0; v < _kVocab; v++) {
        logit[r * _kVocab + v] = v == target ? 5 : -5;
      }
    }
    return <String, OnnxTensor>{
      AsrModelIo.joinerOutputLogit: OnnxTensor.float32(logit, <int>[
        rows,
        _kVocab,
      ]),
    };
  }

  @override
  Future<void> close() async {}
}

void main() {
  final AsrTokenTable tokens = AsrTokenTable.parse(_kTokens);
  final AsrSpeechSegment segment = AsrSpeechSegment(
    startSample: 0,
    samples: Float32List(kAsrSampleRate),
  );

  test('contextSize=1：y 是 [rows, 1]，上下文只保留最后一个 token，结果不含前置 blank', () async {
    final _Decoder decoder = _Decoder(
      expectType: OnnxTensorType.int64,
      expectContext: 1,
    );
    final AsrTransducerDecoder d = AsrTransducerDecoder(
      encoder: _Encoder(OnnxTensorType.int64),
      decoder: decoder,
      joiner: _Joiner(),
      tokens: tokens,
      contextSize: 1,
    );
    final List<AsrDecodedSegment> out = await d.decodeBatch(<AsrSpeechSegment>[
      segment,
    ]);
    expect(out.single.tokens, <String>['あ', 'い']);
    expect(out.single.tokenOffsetsMs, <int>[0, kAsrEncoderFrameMs]);
    // 初始上下文 [blank]，两次发射各重算一次：[あ]、[い]。
    expect(decoder.contexts, <List<int>>[
      <int>[0],
      <int>[1],
      <int>[2],
    ]);
  });

  test('indexType=int32：x_lens 与 y 都以 int32 张量喂给会话', () async {
    final _Encoder encoder = _Encoder(OnnxTensorType.int32);
    final _Decoder decoder = _Decoder(
      expectType: OnnxTensorType.int32,
      expectContext: 2,
    );
    final AsrTransducerDecoder d = AsrTransducerDecoder(
      encoder: encoder,
      decoder: decoder,
      joiner: _Joiner(),
      tokens: tokens,
      indexType: AsrIndexType.int32,
    );
    final List<AsrDecodedSegment> out = await d.decodeBatch(<AsrSpeechSegment>[
      segment,
    ]);
    expect(out.single.tokens, <String>['あ', 'い']);
    expect(encoder.seenLensTypes, <OnnxTensorType>[OnnxTensorType.int32]);
    expect(decoder.contexts.first, <int>[0, 0]);
    expect(decoder.contexts.last, <int>[1, 2]);
  });

  test('contextSize < 1 拒绝', () {
    expect(
      () => AsrTransducerDecoder(
        encoder: _Encoder(OnnxTensorType.int64),
        decoder: _Decoder(
          expectType: OnnxTensorType.int64,
          expectContext: 2,
        ),
        joiner: _Joiner(),
        tokens: tokens,
        contextSize: 0,
      ),
      throwsArgumentError,
    );
  });
}
