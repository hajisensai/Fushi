import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_encoder_buckets.dart';
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

/// 只记录输入形状的编码器会话（warm-up 用）。
class _Recording implements OnnxSession {
  final List<Map<String, OnnxTensor>> calls = <Map<String, OnnxTensor>>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    calls.add(inputs);
    final int n = inputs[AsrModelIo.encoderInputX]!.shape[0];
    return <String, OnnxTensor>{
      AsrModelIo.encoderOutput: OnnxTensor.float32(
        Float32List(n * _encDim),
        <int>[n, 1, _encDim],
      ),
      AsrModelIo.encoderOutputLens: OnnxTensor.float32(Float32List(n), <int>[
        n,
      ]),
    };
  }

  @override
  Future<void> close() async {}
}

class _RecordingFactory implements OnnxSessionFactory {
  final List<_Recording> created = <_Recording>[];

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    final _Recording s = _Recording();
    created.add(s);
    return s;
  }
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

  test('两个 Loop 图会话：一批的行按连续切片对半并行搜，结果按行拼回，与单会话等价', () async {
    final List<List<int>> emitted = <List<int>>[
      <int>[-1, 1, -1, 2, -1],
      <int>[3, -1, -1, -1, -1],
      <int>[-1, -1, 2, -1, -1],
      <int>[1, 1, -1, -1, -1],
      <int>[-1, 3, -1, -1, -1],
    ];
    final List<int> lens = <int>[5, 2, 4, 3, 5];
    final _Greedy single = _Greedy(emitted);
    final AsrTransducerDecoder one = AsrTransducerDecoder(
      encoder: _Encoder(lens),
      decoder: _Never(),
      joiner: _Never(),
      tokens: tokens,
      greedy: single,
    );
    final List<AsrSpeechSegment> segs = lens.map(_seg).toList();
    final List<AsrDecodedSegment> want = await one.decodeBatch(segs);

    // 5 行对半：会话 A 拿 [0,1]（5*1~/2=2），会话 B 拿 [2,3,4]。
    final _Greedy a = _Greedy(emitted.sublist(0, 2));
    final _Greedy b = _Greedy(emitted.sublist(2));
    final AsrTransducerDecoder two = AsrTransducerDecoder(
      encoder: _Encoder(lens),
      decoder: _Never(),
      joiner: _Never(),
      tokens: tokens,
      greedy: a,
      greedyPool: <OnnxSession>[b],
    );
    expect(two.greedySessionCount, 2);
    final List<AsrDecodedSegment> got = await two.decodeBatch(segs);
    expect(a.calls, 1);
    expect(b.calls, 1);
    expect(a.lastInputs![AsrGreedyGraphIo.encoderOut]!.shape, <int>[
      2,
      5,
      _encDim,
    ]);
    expect(a.lastInputs![AsrGreedyGraphIo.encoderOutLens]!.intData, <int>[
      5,
      2,
    ]);
    expect(b.lastInputs![AsrGreedyGraphIo.encoderOut]!.shape, <int>[
      3,
      5,
      _encDim,
    ]);
    expect(b.lastInputs![AsrGreedyGraphIo.encoderOutLens]!.intData, <int>[
      4,
      3,
      5,
    ]);
    expect(got.length, want.length);
    for (int i = 0; i < want.length; i++) {
      expect(got[i].tokens, want[i].tokens, reason: '第 $i 行');
      expect(got[i].tokenOffsetsMs, want[i].tokenOffsetsMs, reason: '第 $i 行');
    }
    // 只有一行时不切片：只用第一个会话。
    final _Greedy a1 = _Greedy(<List<int>>[emitted[0]]);
    final _Greedy b1 = _Greedy(<List<int>>[emitted[0]]);
    final AsrTransducerDecoder oneRow = AsrTransducerDecoder(
      encoder: _Encoder(<int>[5]),
      decoder: _Never(),
      joiner: _Never(),
      tokens: tokens,
      greedy: a1,
      greedyPool: <OnnxSession>[b1],
    );
    await oneRow.decodeBatch(<AsrSpeechSegment>[_seg(5)]);
    expect(a1.calls, 1);
    expect(b1.calls, 0);
  });

  test('warmUp：每个已建静态桶发一次哨兵行空跑（pad 值、x_lens=T_b），不等结果、不重复', () async {
    final _RecordingFactory factory = _RecordingFactory();
    final AsrStaticEncoderPool pool = AsrStaticEncoderPool(
      factory: factory,
      modelPath: 'enc.onnx',
      providers: const <OnnxExecutionProvider>[OnnxExecutionProvider.directml],
      buckets: const <AsrEncoderBucket>[
        AsrEncoderBucket(frames: 5, batch: 2),
        AsrEncoderBucket(frames: 9, batch: 3),
      ],
    );
    final AsrTransducerDecoder d = AsrTransducerDecoder(
      encoder: _Encoder(<int>[1]),
      decoder: _Never(),
      joiner: _Never(),
      tokens: tokens,
      staticEncoders: pool,
    );
    d.warmUp();
    expect(d.warmedBucketCount, 0, reason: '还没建桶');
    await pool.prewarmAll();
    d.warmUp();
    expect(d.warmedBucketCount, 2);
    await Future<void>.delayed(Duration.zero);
    expect(factory.created, hasLength(2));
    final Map<String, OnnxTensor> call = factory.created.first.calls.single;
    expect(call[AsrModelIo.encoderInputX]!.shape, <int>[2, 5, kAsrFeatureDim]);
    // pad 值经 Float32List 落成 float32，比较也按 float32。
    final double pad32 = (Float32List(1)
      ..[0] = AsrTransducerDecoder.kFeaturePadValue)[0];
    expect(
      call[AsrModelIo.encoderInputX]!.floatData!.every(
        (double v) => v == pad32,
      ),
      isTrue,
    );
    expect(call[AsrModelIo.encoderInputXLens]!.intData, <int>[5, 5]);
    expect(
      factory.created.last.calls.single[AsrModelIo.encoderInputX]!.shape,
      <int>[3, 9, kAsrFeatureDim],
    );
    d.warmUp();
    await Future<void>.delayed(Duration.zero);
    expect(
      factory.created.every((_Recording s) => s.calls.length == 1),
      isTrue,
    );
  });
}
