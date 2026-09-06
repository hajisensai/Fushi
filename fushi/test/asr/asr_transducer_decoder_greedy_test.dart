import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_greedy_graph.dart' show AsrGreedyGraphIo;
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

const String _tokensText = '<blk>\t0\nあ\t1\nい\t2\nう\t3\n<unk>\t4\n';
const int _encDim = 4;

class _Encoder implements OnnxSession {
  _Encoder(this.lens);
  final List<int> lens;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final int n = inputs[AsrModelIo.encoderInputX]!.shape[0];
    int maxLen = 0;
    for (final int l in lens) {
      if (l > maxLen) maxLen = l;
    }
    return <String, OnnxTensor>{
      AsrModelIo.encoderOutput: OnnxTensor.float32(
        Float32List(n * maxLen * _encDim),
        <int>[n, maxLen, _encDim],
      ),
      AsrModelIo.encoderOutputLens: OnnxTensor.float32(
        Float32List.fromList(lens.map((int l) => l.toDouble()).toList()),
        <int>[n],
      ),
    };
  }

  @override
  Future<void> close() async {}
}

class _Never implements OnnxSession {
  int calls = 0;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    calls++;
    throw StateError('Loop 图路径下不该调 decoder/joiner');
  }

  @override
  Future<void> close() async {}
}

/// 假 Loop 图会话：按 [emitted] 返回 [N,T]（模拟 ORT 层把 int64 读成 float）。
class _Greedy implements OnnxSession {
  _Greedy(this.emitted, {this.asFloat = true});
  final List<List<int>> emitted;
  final bool asFloat;
  Map<String, OnnxTensor>? lastInputs;
  int calls = 0;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    calls++;
    lastInputs = inputs;
    final int n = emitted.length;
    final int t = emitted.first.length;
    final List<int> flat = <int>[for (final List<int> row in emitted) ...row];
    return <String, OnnxTensor>{
      AsrGreedyGraphIo.emitted: asFloat
          ? OnnxTensor.float32(
              Float32List.fromList(flat.map((int v) => v.toDouble()).toList()),
              <int>[n, t],
            )
          : OnnxTensor.int64(Int64List.fromList(flat), <int>[n, t]),
    };
  }

  @override
  Future<void> close() async {}
}

AsrSpeechSegment _seg(int frames) => AsrSpeechSegment(
  startSample: 0,
  samples: Float32List(frames * 4 * 160 + 400),
);

void main() {
  final AsrTokenTable tokens = AsrTokenTable.parse(_tokensText);

  test('Loop 图路径：一次调用，按 emitted 还原 token/时间，不碰 decoder/joiner', () async {
    final _Greedy greedy = _Greedy(<List<int>>[
      <int>[-1, 1, -1, 2, -1],
      <int>[3, -1, -1, -1, -1],
    ]);
    final _Never decoder = _Never();
    final _Never joiner = _Never();
    final AsrTransducerDecoder d = AsrTransducerDecoder(
      encoder: _Encoder(<int>[5, 2]),
      decoder: decoder,
      joiner: joiner,
      tokens: tokens,
      greedy: greedy,
    );
    expect(d.usesGreedyGraph, isTrue);
    final List<AsrDecodedSegment> out = await d.decodeBatch(<AsrSpeechSegment>[
      _seg(5),
      _seg(2),
    ]);
    expect(greedy.calls, 1);
    expect(decoder.calls, 0);
    expect(joiner.calls, 0);
    expect(out[0].tokens, <String>['あ', 'い']);
    expect(out[0].tokenOffsetsMs, <int>[40, 120]);
    expect(out[1].tokens, <String>['う']);
    expect(out[1].tokenOffsetsMs, <int>[0]);
    // 输入按 Loop 图 IO 名给：encoder_out [N,T,D] float32 + encoder_out_lens int64。
    final Map<String, OnnxTensor> inputs = greedy.lastInputs!;
    expect(inputs[AsrGreedyGraphIo.encoderOut]!.shape, <int>[2, 5, _encDim]);
    expect(inputs[AsrGreedyGraphIo.encoderOutLens]!.type, OnnxTensorType.int64);
    expect(inputs[AsrGreedyGraphIo.encoderOutLens]!.intData, <int>[5, 2]);
  });

  test('超出 encoder_out_lens 的帧即便 emitted 非 -1 也忽略；int64 输出同样可读', () async {
    final _Greedy greedy = _Greedy(<List<int>>[
      <int>[1, 2, 3, 3], // 长度只有 2：后两帧不算
    ], asFloat: false);
    final AsrTransducerDecoder d = AsrTransducerDecoder(
      encoder: _Encoder(<int>[2]),
      decoder: _Never(),
      joiner: _Never(),
      tokens: tokens,
      greedy: greedy,
    );
    // fake encoder 输出 maxLen=2 帧，但 emitted 给了 4 列 → 形状不符必须报错。
    await expectLater(
      d.decodeBatch(<AsrSpeechSegment>[_seg(2)]),
      throwsA(isA<StateError>()),
    );
  });

  test('emitted 形状与 batch/帧数一致时按长度截断', () async {
    final _Greedy greedy = _Greedy(<List<int>>[
      <int>[1, 2, 3],
      <int>[2, -1, 1],
    ], asFloat: false);
    final AsrTransducerDecoder d = AsrTransducerDecoder(
      encoder: _Encoder(<int>[3, 1]),
      decoder: _Never(),
      joiner: _Never(),
      tokens: tokens,
      greedy: greedy,
    );
    final List<AsrDecodedSegment> out = await d.decodeBatch(<AsrSpeechSegment>[
      _seg(3),
      _seg(1),
    ]);
    expect(out[0].tokens, <String>['あ', 'い', 'う']);
    expect(out[1].tokens, <String>['い'], reason: '第二条只有 1 帧');
  });

  test('没有 Loop 图会话时走逐帧路径', () {
    final AsrTransducerDecoder d = AsrTransducerDecoder(
      encoder: _Encoder(<int>[1]),
      decoder: _Never(),
      joiner: _Never(),
      tokens: tokens,
    );
    expect(d.usesGreedyGraph, isFalse);
  });
}
