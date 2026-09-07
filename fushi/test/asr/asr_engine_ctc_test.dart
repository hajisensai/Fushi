import 'dart:io';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_ctc_decoder.dart';
import 'package:fushi/src/asr/asr_encoder_buckets.dart';
import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_vad.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:path/path.dart' as p;

/// CTC（Omnilingual）包的引擎装载：只建模型 + VAD 两个会话，词表 blank 取
/// `<s>`，GPU 上按样本数建静态桶（`N` / `num_samples`，无哨兵），CPU 不建；
/// fp32 变体受显存门槛约束。
class _FakeSession implements OnnxSession {
  _FakeSession(this.path, this.providers);
  final String path;
  final List<OnnxExecutionProvider> providers;
  bool closed = false;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async =>
      const <String, OnnxTensor>{};

  @override
  Future<void> close() async => closed = true;
}

class _FakeRuntime extends OnnxRuntime {
  @override
  Future<List<OrtProvider>> getAvailableProviders() async =>
      const <OrtProvider>[OrtProvider.CPU];
}

class _FakeFactory extends OrtOnnxSessionFactory {
  _FakeFactory({this.available = const <OnnxExecutionProvider>{}, this.budget})
      : super(runtime: _FakeRuntime());

  final Set<OnnxExecutionProvider> available;
  final int? budget;
  final List<({String path, List<OnnxExecutionProvider> providers})> plain =
      <({String path, List<OnnxExecutionProvider> providers})>[];
  final List<({_FakeSession session, Map<String, int> overrides})> buckets =
      <({_FakeSession session, Map<String, int> overrides})>[];

  @override
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() async =>
      available;

  @override
  Future<int?> deviceMemoryBudgetBytes() async => budget;

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    final _FakeSession s =
        _FakeSession(modelPath, List<OnnxExecutionProvider>.from(providers));
    onProviderResolved?.call(
      OnnxProviderResolution(requested: providers, effective: providers.first),
    );
    if (freeDimensionOverrides != null) {
      buckets.add((session: s, overrides: freeDimensionOverrides));
    } else {
      plain.add((path: p.basename(modelPath), providers: providers));
    }
    return s;
  }
}

void main() {
  late Directory tmp;
  late AsrModelStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asr_engine_ctc_');
    store = AsrModelStore(tmp, kAsrOmnilingualPack);
    for (final AsrModelFile f in kAsrOmnilingualPack.files) {
      if (f.role == AsrModelRole.tokens) {
        store.fileFor(f.role).writeAsStringSync(
              '<s> 0\n<pad> 1\n</s> 2\n<unk> 3\n  4\na 5\n',
            );
      } else {
        store.fileFor(f.role).writeAsBytesSync(<int>[1, 2, 3]);
      }
    }
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('int8 · CPU：只建模型 + VAD，无 decoder/joiner/静态桶，blank=<s>，段上限 20 s',
      () async {
    final _FakeFactory f = _FakeFactory();
    final AsrEngineSessions s = await AsrEngineLoader(factory: f).load(
      store: store,
      variant: AsrEncoderVariant.int8,
      preference: AsrAccelerationPreference.auto,
    );
    expect(s.architecture, AsrModelArchitecture.ctc);
    expect(s.decoder, isNull);
    expect(s.joiner, isNull);
    expect(s.greedy, isNull);
    expect(s.staticEncoders, isNull);
    expect(s.tokens.blankId, 0);
    expect(s.tokens.padId, 1);
    expect(s.maxSegmentMs, kAsrDefaultMaxSegmentMs);
    expect(f.plain.map((e) => e.path),
        <String>['model.int8.onnx', 'silero_vad.onnx']);
    expect(f.plain.first.providers,
        <OnnxExecutionProvider>[OnnxExecutionProvider.cpu]);
    expect(s.newDecoder(), isA<AsrCtcDecoder>());
    await s.close();
    expect(f.buckets, isEmpty);
  });

  test('fp32 · DirectML：模型走 GPU、静态桶钉 N/num_samples、只预热最小桶（预算未知）', () async {
    final _FakeFactory f = _FakeFactory(
      available: const <OnnxExecutionProvider>{OnnxExecutionProvider.directml},
    );
    final AsrEngineSessions s = await AsrEngineLoader(
      factory: f,
      platform: AsrPlatform.windows,
    ).load(
      store: store,
      variant: AsrEncoderVariant.fp32,
      preference: AsrAccelerationPreference.auto,
    );
    expect(s.encoderResolution.effective, OnnxExecutionProvider.directml);
    expect(f.plain.first.path, 'model.onnx');
    expect(s.staticEncoders, isNotNull);
    expect(f.buckets, hasLength(1));
    expect(f.buckets.single.overrides, <String, int>{
      kAsrCtcBatchDim: kAsrCtcGpuBuckets.first.batch,
      kAsrCtcSamplesDim: kAsrCtcGpuBuckets.first.frames,
    });
    expect(f.buckets.single.session.providers, <OnnxExecutionProvider>[
      OnnxExecutionProvider.directml,
    ]);
    // CTC 桶无哨兵行：整批都是真实行。
    expect(
        kAsrCtcGpuBuckets.every((AsrEncoderBucket b) => !b.sentinel), isTrue);
    expect(s.newDecoder(), isA<AsrCtcDecoder>());
    expect(s.newDecoder(), isNot(isA<AsrTransducerDecoder>()));
    await s.close();
    expect(f.buckets.single.session.closed, isTrue);
  });

  test('fp32 · 素材 ≥ 15 min 且预算已知：三个 CTC 桶全预热', () async {
    final _FakeFactory f = _FakeFactory(
      available: const <OnnxExecutionProvider>{OnnxExecutionProvider.directml},
      budget: 32 * 1024 * 1024 * 1024,
    );
    final AsrEngineSessions s = await AsrEngineLoader(
      factory: f,
      platform: AsrPlatform.windows,
    ).load(
      store: store,
      variant: AsrEncoderVariant.fp32,
      preference: AsrAccelerationPreference.auto,
      materialMs: 60 * 60 * 1000,
    );
    expect(f.buckets, hasLength(kAsrCtcGpuBuckets.length));
    await s.close();
  });

  test('recommendAsrEncoderVariant：显存门槛未知 / 不足 → int8，够 → fp32；无门槛不看预算', () {
    const Set<OnnxExecutionProvider> gpu = <OnnxExecutionProvider>{
      OnnxExecutionProvider.directml,
    };
    const int gib = 1024 * 1024 * 1024;
    AsrEncoderVariant f({int? min, int? budget}) => recommendAsrEncoderVariant(
          platform: AsrPlatform.windows,
          available: gpu,
          preference: AsrAccelerationPreference.auto,
          fp32GpuMinBudgetBytes: min,
          budgetBytes: budget,
        );
    expect(f(min: 8 * gib, budget: null), AsrEncoderVariant.int8);
    expect(f(min: 8 * gib, budget: 6 * gib), AsrEncoderVariant.int8);
    expect(f(min: 8 * gib, budget: 8 * gib), AsrEncoderVariant.fp32);
    expect(f(min: 8 * gib, budget: 32 * gib), AsrEncoderVariant.fp32);
    expect(f(min: null, budget: null), AsrEncoderVariant.fp32);
    expect(
      recommendAsrEncoderVariant(
        platform: AsrPlatform.windows,
        available: gpu,
        preference: AsrAccelerationPreference.cpuOnly,
        fp32GpuMinBudgetBytes: 8 * gib,
        budgetBytes: 32 * gib,
      ),
      AsrEncoderVariant.int8,
    );
  });
}
