import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_encoder_buckets.dart';
import 'package:fushi/src/asr/asr_fbank.dart';
import 'package:fushi/src/asr/asr_greedy_graph.dart' show AsrGreedyGraphIo;
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

const int _encDim = 4;

/// 记录输入形状 / x_lens 的 fake 编码器：`encoder_out_lens = x_lens ~/ 4`。
class _RecordingEncoder implements OnnxSession {
  _RecordingEncoder(this.label);

  final String label;
  final List<List<int>> shapes = <List<int>>[];
  final List<List<int>> lens = <List<int>>[];
  bool closed = false;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor x = inputs[AsrModelIo.encoderInputX]!;
    final OnnxTensor xl = inputs[AsrModelIo.encoderInputXLens]!;
    shapes.add(List<int>.from(x.shape));
    lens.add(List<int>.from(xl.intData!));
    final int n = x.shape[0];
    final int outFrames = x.shape[1] ~/ 4;
    final Float32List out = Float32List(n * outFrames * _encDim);
    for (int i = 0; i < n; i++) {
      for (int t = 0; t < outFrames; t++) {
        out[(i * outFrames + t) * _encDim] = i.toDouble();
      }
    }
    return <String, OnnxTensor>{
      AsrModelIo.encoderOutput: OnnxTensor.float32(out, <int>[
        n,
        outFrames,
        _encDim,
      ]),
      AsrModelIo.encoderOutputLens: OnnxTensor.int64(
        Int64List.fromList(<int>[for (final int l in xl.intData!) l ~/ 4]),
        <int>[n],
      ),
    };
  }

  @override
  Future<void> close() async => closed = true;
}

/// fake 贪心 Loop 图：每行第 0 帧发 token 1，其余 -1；同时记录喂进来的行数。
class _FakeGreedy implements OnnxSession {
  final List<List<int>> encShapes = <List<int>>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor enc = inputs[AsrGreedyGraphIo.encoderOut]!;
    encShapes.add(List<int>.from(enc.shape));
    final int n = enc.shape[0];
    final int t = enc.shape[1];
    final Int64List emitted = Int64List(n * t)..fillRange(0, n * t, -1);
    for (int i = 0; i < n; i++) {
      emitted[i * t] = 1;
    }
    return <String, OnnxTensor>{
      AsrGreedyGraphIo.emitted: OnnxTensor.int64(emitted, <int>[n, t]),
    };
  }

  @override
  Future<void> close() async {}
}

class _Noop implements OnnxSession {
  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async =>
      <String, OnnxTensor>{};

  @override
  Future<void> close() async {}
}

/// 运行期必抛的 fake 会话（模拟 DML 对某静态 shape 的算子缺陷）。
class _ThrowingEncoder implements OnnxSession {
  bool closed = false;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async =>
      throw StateError('Where node failed');

  @override
  Future<void> close() async => closed = true;
}

/// 记录 createSession 参数的 fake 工厂；[failBatches] 里的桶建会话抛错，
/// [throwAtRunBatches] 里的桶建得起来但 run 抛错。
class _FakeFactory implements OnnxSessionFactory {
  _FakeFactory({
    this.failBatches = const <int>{},
    this.throwAtRunBatches = const <int>{},
  });

  final Set<int> failBatches;
  final Set<int> throwAtRunBatches;
  final List<_ThrowingEncoder> throwing = <_ThrowingEncoder>[];
  final List<Map<String, int>?> overrides = <Map<String, int>?>[];
  final List<List<OnnxExecutionProvider>> providers =
      <List<OnnxExecutionProvider>>[];
  final List<_RecordingEncoder> created = <_RecordingEncoder>[];

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    overrides.add(freeDimensionOverrides);
    this.providers.add(providers);
    final int? n = freeDimensionOverrides?[kAsrEncoderBatchDim];
    if (n != null && failBatches.contains(n)) {
      throw StateError('no memory for N=$n');
    }
    if (n != null && throwAtRunBatches.contains(n)) {
      final _ThrowingEncoder t = _ThrowingEncoder();
      throwing.add(t);
      return t;
    }
    final _RecordingEncoder s = _RecordingEncoder('N=$n');
    created.add(s);
    return s;
  }
}

/// createSession 挂起直到 [release] 的 fake 工厂（模拟 3~8 s 的建桶）。
class _SlowFactory implements OnnxSessionFactory {
  final Completer<OnnxSession> _gate = Completer<OnnxSession>();

  void release(OnnxSession session) => _gate.complete(session);

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) => _gate.future;
}

AsrSpeechSegment _segment(int ms) => AsrSpeechSegment(
  startSample: 0,
  samples: Float32List(ms * kAsrSampleRate ~/ 1000),
);

const List<AsrEncoderBucket> _buckets = <AsrEncoderBucket>[
  AsrEncoderBucket(frames: 500, batch: 4),
  AsrEncoderBucket(frames: 1000, batch: 2),
];

void main() {
  final AsrTokenTable tokens = AsrTokenTable.parse(
    '<blk>\t0\nあ\t1\n<unk>\t2\n<sos/eos>\t3\n',
  );

  group('AsrStaticEncoderPool', () {
    test('按帧数选最小能装下的桶；超过最大桶无桶', () {
      final AsrStaticEncoderPool pool = AsrStaticEncoderPool(
        factory: _FakeFactory(),
        modelPath: 'enc.onnx',
        providers: const <OnnxExecutionProvider>[
          OnnxExecutionProvider.directml,
        ],
        buckets: _buckets,
      );
      expect(pool.bucketFor(1)!.frames, 500);
      expect(pool.bucketFor(500)!.frames, 500);
      expect(pool.bucketFor(501)!.frames, 1000);
      expect(pool.bucketFor(1001), isNull);
      expect(pool.batchCapFor(300), 3, reason: '留一行哨兵');
      expect(pool.batchCapFor(900), 1);
      expect(pool.batchCapFor(5000), isNull);
    });

    test('惰性建会话：同桶只建一次、带 N/T 覆盖、不带 CPU 兜底', () async {
      final _FakeFactory factory = _FakeFactory();
      final AsrStaticEncoderPool pool = AsrStaticEncoderPool(
        factory: factory,
        modelPath: 'enc.onnx',
        providers: const <OnnxExecutionProvider>[
          OnnxExecutionProvider.directml,
        ],
        buckets: _buckets,
      );
      final AsrStaticEncoderSession? a = await pool.sessionFor(300);
      final AsrStaticEncoderSession? b = await pool.sessionFor(450);
      expect(a, isNotNull);
      expect(identical(a!.session, b!.session), isTrue);
      expect(factory.overrides, <Map<String, int>>[
        <String, int>{kAsrEncoderBatchDim: 4, kAsrEncoderTimeDim: 500},
      ]);
      expect(factory.providers.single, <OnnxExecutionProvider>[
        OnnxExecutionProvider.directml,
      ]);
      await pool.close();
      expect(factory.created.single.closed, isTrue);
      expect(await pool.sessionFor(300), isNull, reason: '关闭后不再建');
    });

    test('close() 不等还在建的桶；那个桶建成后自己关掉', () async {
      final _SlowFactory factory = _SlowFactory();
      final AsrStaticEncoderPool pool = AsrStaticEncoderPool(
        factory: factory,
        modelPath: 'enc.onnx',
        providers: const <OnnxExecutionProvider>[
          OnnxExecutionProvider.directml,
        ],
        buckets: _buckets,
      );
      final Future<AsrStaticEncoderSession?> building = pool.sessionFor(300);
      bool closed = false;
      final Future<void> closing = pool.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isTrue, reason: 'close() 不能等 3~8 s 的建桶');
      // 建桶完成：会话被池子立刻关掉，调用方拿到 null。
      final _RecordingEncoder late = _RecordingEncoder('late');
      factory.release(late);
      expect(await building, isNull);
      expect(late.closed, isTrue);
      await closing;
    });

    test('建失败的桶记原因、返回 null，不影响其它桶', () async {
      final _FakeFactory factory = _FakeFactory(failBatches: <int>{4});
      final AsrStaticEncoderPool pool = AsrStaticEncoderPool(
        factory: factory,
        modelPath: 'enc.onnx',
        providers: const <OnnxExecutionProvider>[
          OnnxExecutionProvider.directml,
        ],
        buckets: _buckets,
      );
      expect(await pool.sessionFor(300), isNull);
      expect(await pool.sessionFor(300), isNull);
      expect(pool.unavailableReasons.keys.single.batch, 4);
      expect(factory.overrides, hasLength(1), reason: '失败的桶不重试');
      expect((await pool.sessionFor(800))!.bucket.batch, 2);
    });

    test('按显存预算选桶表：≥10 GiB 全桶、6~10 GiB 半桶、<6 GiB 不用、未知按默认', () {
      const int gib = 1024 * 1024 * 1024;
      expect(asrEncoderBucketsForBudget(null), kAsrGpuEncoderBuckets);
      expect(asrEncoderBucketsForBudget(12 * gib), kAsrGpuEncoderBuckets);
      expect(asrEncoderBucketsForBudget(10 * gib), kAsrGpuEncoderBuckets);
      expect(asrEncoderBucketsForBudget(8 * gib), kAsrGpuEncoderBucketsSmall);
      expect(asrEncoderBucketsForBudget(6 * gib), kAsrGpuEncoderBucketsSmall);
      expect(asrEncoderBucketsForBudget(4 * gib), isEmpty);
      // 半桶的每档行数正好是全桶的一半，帧数一致。
      for (int i = 0; i < kAsrGpuEncoderBuckets.length; i++) {
        expect(
          kAsrGpuEncoderBucketsSmall[i].frames,
          kAsrGpuEncoderBuckets[i].frames,
        );
        expect(
          kAsrGpuEncoderBucketsSmall[i].batch * 2,
          kAsrGpuEncoderBuckets[i].batch,
        );
      }
    });

    test('桶表必须按 frames 递增', () {
      expect(
        () => AsrStaticEncoderPool(
          factory: _FakeFactory(),
          modelPath: 'enc.onnx',
          providers: const <OnnxExecutionProvider>[
            OnnxExecutionProvider.directml,
          ],
          buckets: const <AsrEncoderBucket>[
            AsrEncoderBucket(frames: 1000, batch: 2),
            AsrEncoderBucket(frames: 500, batch: 4),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('AsrTransducerDecoder 静态桶路径', () {
    late _FakeFactory factory;
    late _RecordingEncoder dynamicEncoder;
    late _FakeGreedy greedy;
    late AsrTransducerDecoder decoder;

    setUp(() {
      factory = _FakeFactory();
      dynamicEncoder = _RecordingEncoder('dynamic');
      greedy = _FakeGreedy();
      decoder = AsrTransducerDecoder(
        encoder: dynamicEncoder,
        decoder: _Noop(),
        joiner: _Noop(),
        tokens: tokens,
        greedy: greedy,
        staticEncoders: AsrStaticEncoderPool(
          factory: factory,
          modelPath: 'enc.onnx',
          providers: const <OnnxExecutionProvider>[
            OnnxExecutionProvider.directml,
          ],
          buckets: _buckets,
        ),
      );
    });

    test('一批填成桶形状：多出的行 pad 值 + x_lens=T（哨兵），只回真实行', () async {
      // 两段 1 s / 2 s（≈100 / 200 帧）→ 500 帧桶，N=4。
      final List<AsrDecodedSegment> out = await decoder.decodeBatch(
        <AsrSpeechSegment>[_segment(1000), _segment(2000)],
      );
      expect(out, hasLength(2));
      expect(out.every((AsrDecodedSegment d) => d.text == 'あ'), isTrue);
      final _RecordingEncoder fixed = factory.created.single;
      expect(fixed.shapes.single, <int>[4, 500, kAsrFeatureDim]);
      final List<int> lens = fixed.lens.single;
      expect(lens[0], AsrFbank.frameCount(1000 * 16));
      expect(lens[1], AsrFbank.frameCount(2000 * 16));
      expect(lens.sublist(2), <int>[500, 500], reason: '哨兵行 x_lens = T');
      expect(dynamicEncoder.shapes, isEmpty, reason: '有桶时不走动态会话');
      // Loop 图只看到真实的 2 行，帧数是桶的 500/4。
      expect(greedy.encShapes.single, <int>[2, 125, _encDim]);
      expect(decoder.stats.paddedFrames, 4 * 500);
    });

    test('超过桶最大帧数的段走动态会话', () async {
      await decoder.decodeBatch(<AsrSpeechSegment>[_segment(15000)]);
      expect(factory.created, isEmpty);
      expect(dynamicEncoder.shapes.single[0], 1);
    });

    test('行数超过桶容量时拆成多批', () async {
      final List<AsrDecodedSegment> out = await decoder.decodeBatch(
        List<AsrSpeechSegment>.generate(5, (_) => _segment(3000)),
      );
      expect(out, hasLength(5));
      final _RecordingEncoder fixed = factory.created.single;
      // 真实行封顶 3（N=4 留一行哨兵）：5 段 → 3 + 2。
      expect(fixed.shapes, <List<int>>[
        <int>[4, 500, kAsrFeatureDim],
        <int>[4, 500, kAsrFeatureDim],
      ]);
      expect(fixed.lens[0].last, 500);
      expect(fixed.lens[1].sublist(2), <int>[500, 500]);
      expect(decoder.batchCapFor(3000 * 16), 3);
      expect(decoder.batchCapFor(9000 * 16), 1);
      expect(decoder.batchCapFor(15000 * 16), isNull);
    });

    test('桶运行期抛错：标不可用、关会话、本批与后续批都走动态会话', () async {
      factory = _FakeFactory(throwAtRunBatches: <int>{4});
      final AsrStaticEncoderPool pool = AsrStaticEncoderPool(
        factory: factory,
        modelPath: 'enc.onnx',
        providers: const <OnnxExecutionProvider>[
          OnnxExecutionProvider.directml,
        ],
        buckets: _buckets,
      );
      decoder = AsrTransducerDecoder(
        encoder: dynamicEncoder,
        decoder: _Noop(),
        joiner: _Noop(),
        tokens: tokens,
        greedy: greedy,
        staticEncoders: pool,
      );
      final List<AsrDecodedSegment> out = await decoder.decodeBatch(
        <AsrSpeechSegment>[_segment(1000), _segment(1500)],
      );
      expect(out.map((AsrDecodedSegment d) => d.text), <String>['あ', 'あ']);
      expect(dynamicEncoder.shapes.single[0], 2, reason: '本批已回退动态会话');
      expect(pool.unavailableReasons.keys.single.batch, 4);
      expect(factory.throwing.single.closed, isTrue);
      await decoder.decodeBatch(<AsrSpeechSegment>[_segment(1000)]);
      expect(factory.overrides, hasLength(1), reason: '不再重建该桶');
      expect(dynamicEncoder.shapes, hasLength(2));
    });

    test('桶建失败回退动态会话', () async {
      factory = _FakeFactory(failBatches: <int>{4});
      decoder = AsrTransducerDecoder(
        encoder: dynamicEncoder,
        decoder: _Noop(),
        joiner: _Noop(),
        tokens: tokens,
        greedy: greedy,
        staticEncoders: AsrStaticEncoderPool(
          factory: factory,
          modelPath: 'enc.onnx',
          providers: const <OnnxExecutionProvider>[
            OnnxExecutionProvider.directml,
          ],
          buckets: _buckets,
        ),
      );
      final List<AsrDecodedSegment> out = await decoder.decodeBatch(
        <AsrSpeechSegment>[_segment(1000)],
      );
      expect(out.single.text, 'あ');
      expect(dynamicEncoder.shapes.single[0], 1);
    });
  });
}
