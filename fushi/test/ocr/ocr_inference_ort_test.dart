import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ocr/ocr_inference.dart';
import 'package:fushi/src/ocr/ocr_inference_ort.dart';

void main() {
  test('unsupported DirectML provider retries once with CPU', () async {
    final List<List<OcrExecutionProvider>> attempts =
        <List<OcrExecutionProvider>>[];
    final List<OcrProviderResolution> resolutions = <OcrProviderResolution>[];

    final String result = await createOcrSessionWithProviderFallback<String>(
      providers: const <OcrExecutionProvider>[
        OcrExecutionProvider.directml,
        OcrExecutionProvider.cpu,
      ],
      onResolved: resolutions.add,
      create: (List<OcrExecutionProvider> providers) async {
        attempts.add(List<OcrExecutionProvider>.from(providers));
        if (providers.contains(OcrExecutionProvider.directml)) {
          throw PlatformException(
            code: 'INVALID_PROVIDER',
            message: 'Provider is not supported: DIRECT_ML',
          );
        }
        return 'cpu-session';
      },
    );

    expect(result, 'cpu-session');
    expect(
      attempts,
      const <List<OcrExecutionProvider>>[
        <OcrExecutionProvider>[
          OcrExecutionProvider.directml,
          OcrExecutionProvider.cpu,
        ],
        <OcrExecutionProvider>[OcrExecutionProvider.cpu],
      ],
    );
    // BUG-1163：降级不允许静默——回退必须回报一次，且带上可读原因。
    expect(resolutions, hasLength(1));
    expect(resolutions.single.didFallBack, isTrue);
    expect(resolutions.single.effective, OcrExecutionProvider.cpu);
    expect(resolutions.single.requested.first, OcrExecutionProvider.directml);
    expect(resolutions.single.fallbackReason, contains('INVALID_PROVIDER'));
    expect(resolutions.single.fallbackReason, contains('DIRECT_ML'));
  });

  test('successful session reports the provider it actually used', () async {
    final List<OcrProviderResolution> resolutions = <OcrProviderResolution>[];

    await createOcrSessionWithProviderFallback<String>(
      providers: const <OcrExecutionProvider>[
        OcrExecutionProvider.cuda,
        OcrExecutionProvider.cpu,
      ],
      onResolved: resolutions.add,
      create: (List<OcrExecutionProvider> providers) async => 'cuda-session',
    );

    expect(resolutions, hasLength(1),
        reason: '不降级也要回报，否则 UI 无法显示当前在跑什么');
    expect(resolutions.single.didFallBack, isFalse);
    expect(resolutions.single.effective, OcrExecutionProvider.cuda);
    expect(resolutions.single.fallbackReason, isNull);
  });

  test('a throwing observer never breaks session creation', () async {
    final String result = await createOcrSessionWithProviderFallback<String>(
      providers: const <OcrExecutionProvider>[OcrExecutionProvider.cpu],
      onResolved: (OcrProviderResolution resolution) =>
          throw StateError('observer exploded'),
      create: (List<OcrExecutionProvider> providers) async => 'cpu-session',
    );

    expect(result, 'cpu-session');
  });

  // BUG-2050：真 DML EP 接进来之后，DirectML 建不起来的错误码是从 ORT 内部出来
  // 的这三个，一个都不是 INVALID_PROVIDER。原实现按错误码白名单判断，三条全部
  // 直接 rethrow —— 表现为整卷 OCR 报错，而不是退 CPU。
  for (final String code in const <String>[
    'PROVIDER_ERROR', // append EP 阶段，含建不出 D3D12 设备
    'ORT_ERROR', // Ort::Session 构造阶段
    'SESSION_CREATION_ERROR',
  ]) {
    test('BUG-2050 accelerated provider failing with $code falls back to CPU',
        () async {
      final List<List<OcrExecutionProvider>> attempts =
          <List<OcrExecutionProvider>>[];
      final List<OcrProviderResolution> resolutions = <OcrProviderResolution>[];

      final String result = await createOcrSessionWithProviderFallback<String>(
        providers: const <OcrExecutionProvider>[
          OcrExecutionProvider.directml,
          OcrExecutionProvider.cpu,
        ],
        onResolved: resolutions.add,
        create: (List<OcrExecutionProvider> providers) async {
          attempts.add(List<OcrExecutionProvider>.from(providers));
          if (providers.contains(OcrExecutionProvider.directml)) {
            throw PlatformException(code: code, message: 'DML session failed');
          }
          return 'cpu-session';
        },
      );

      expect(result, 'cpu-session');
      expect(attempts, hasLength(2));
      expect(attempts.last, <OcrExecutionProvider>[OcrExecutionProvider.cpu]);
      // BUG-1163：回退必须回报一次并带上可读原因。
      expect(resolutions, hasLength(1));
      expect(resolutions.single.effective, OcrExecutionProvider.cpu);
      expect(resolutions.single.fallbackReason, contains(code));
    });
  }

  test('CPU 那次也失败时抛出的是 CPU 的错误，且只重试一次', () async {
    // 「模型损坏会不会被掩盖」的答案：不会，也不需要按错误码特判。模型真坏，
    // CPU 那次同样建不起来，异常照抛——而且抛的是更有诊断价值的那条。
    final List<List<OcrExecutionProvider>> attempts =
        <List<OcrExecutionProvider>>[];
    final List<OcrProviderResolution> resolutions = <OcrProviderResolution>[];

    await expectLater(
      createOcrSessionWithProviderFallback<String>(
        providers: const <OcrExecutionProvider>[
          OcrExecutionProvider.directml,
          OcrExecutionProvider.cpu,
        ],
        onResolved: resolutions.add,
        create: (List<OcrExecutionProvider> providers) async {
          attempts.add(List<OcrExecutionProvider>.from(providers));
          throw PlatformException(
            code: 'SESSION_CREATION_ERROR',
            message: providers.contains(OcrExecutionProvider.directml)
                ? 'dml load failed'
                : 'invalid model',
          );
        },
      ),
      throwsA(
        isA<PlatformException>()
            .having((PlatformException e) => e.code, 'code',
                'SESSION_CREATION_ERROR')
            .having(
                (PlatformException e) => e.message, 'message', 'invalid model'),
      ),
    );
    expect(attempts, hasLength(2), reason: '只重试一次，不许无界重试');
    expect(resolutions, isEmpty, reason: '没建成会话就不该回报 resolution');
  });

  test('CPU-only request is never retried', () async {
    int attempts = 0;

    await expectLater(
      createOcrSessionWithProviderFallback<String>(
        providers: const <OcrExecutionProvider>[OcrExecutionProvider.cpu],
        create: (List<OcrExecutionProvider> providers) async {
          attempts++;
          throw PlatformException(
            code: 'INVALID_PROVIDER',
            message: 'unexpected CPU rejection',
          );
        },
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(attempts, 1);
  });

  test('single-input model uses the name declared by the ONNX session', () {
    final OcrTensor pixels =
        OcrTensor.float32(Float32List(3), <int>[1, 3, 1, 1]);

    final Map<String, OcrTensor> resolved = resolveOcrSessionInputs(
      inputs: <String, OcrTensor>{'pixel_values': pixels},
      sessionInputNames: const <String>['images'],
    );

    expect(resolved.keys, <String>['images']);
    expect(resolved['images'], same(pixels));
  });

  // 之前这条能力只写在 doc 里：单输入回退分支排在按名匹配之后，永远不可达，
  // 只有硬编码的 pixel_values→images 别名真正生效。上游换个导出把输入命名为
  // `input` / `x` 就会直接失败。
  test('single-input model accepts any exported input name', () {
    final OcrTensor pixels =
        OcrTensor.float32(Float32List(3), <int>[1, 3, 1, 1]);

    for (final String exportedName in <String>['input', 'x', 'pixel_values']) {
      final Map<String, OcrTensor> resolved = resolveOcrSessionInputs(
        inputs: <String, OcrTensor>{'pixel_values': pixels},
        sessionInputNames: <String>[exportedName],
      );
      expect(resolved.keys, <String>[exportedName]);
      expect(resolved[exportedName], same(pixels));
    }
  });

  test('multi-input model never guesses by input order', () {
    final OcrTensor ids = OcrTensor.int64(Int64List(1), <int>[1, 1]);
    final OcrTensor hidden = OcrTensor.float32(Float32List(1), <int>[1, 1, 1]);
    final Map<String, OcrTensor> original = <String, OcrTensor>{
      'input_ids': ids,
      'encoder_hidden_states': hidden,
    };

    final Map<String, OcrTensor> resolved = resolveOcrSessionInputs(
      inputs: original,
      sessionInputNames: const <String>['ids', 'states'],
    );

    expect(resolved, same(original));
  });

  test('detector aliases pixel_values to images and keeps target size', () {
    final OcrTensor pixels =
        OcrTensor.float32(Float32List(3), <int>[1, 3, 1, 1]);
    final OcrTensor targetSize =
        OcrTensor.int64(Int64List.fromList(<int>[1, 1]), <int>[1, 2]);

    final Map<String, OcrTensor> resolved = resolveOcrSessionInputs(
      inputs: <String, OcrTensor>{
        'pixel_values': pixels,
        'orig_target_sizes': targetSize,
      },
      sessionInputNames: const <String>['images', 'orig_target_sizes'],
    );

    expect(resolved.keys, <String>['images', 'orig_target_sizes']);
    expect(resolved['images'], same(pixels));
    expect(resolved['orig_target_sizes'], same(targetSize));
  });

  group('BUG-2050 加速 EP 探测', () {
    // 本 bug 的根因就在这里：DirectML 的可用性**一直是能问到的**（native 侧把
    // `DmlExecutionProvider` 映射成 `DIRECT_ML` 回报出来），原实现却只问 CUDA，
    // DirectML 靠平台分支硬假设。这组测试钉住「问得到」这个事实，防止有人再把
    // 探测退化回单问 CUDA。
    test('运行时报告 DirectML 时探测得到它', () async {
      final OrtOcrSessionFactory factory = OrtOcrSessionFactory(
        runtime: _FakeOnnxRuntime(const <OrtProvider>[
          OrtProvider.CPU,
          OrtProvider.DIRECT_ML,
        ]),
      );

      expect(
        await factory.availableAcceleratedProviders(),
        const <OcrExecutionProvider>{OcrExecutionProvider.directml},
      );
    });

    test('CPU-only 运行时探测出空集（BUG-1968 打包成 CPU archive 时的真实状态）', () async {
      final OrtOcrSessionFactory factory = OrtOcrSessionFactory(
        runtime: _FakeOnnxRuntime(const <OrtProvider>[OrtProvider.CPU]),
      );

      expect(await factory.availableAcceleratedProviders(), isEmpty);
    });

    test('CPU 与本子系统不选的 EP 都不进结果集', () async {
      final OrtOcrSessionFactory factory = OrtOcrSessionFactory(
        runtime: _FakeOnnxRuntime(const <OrtProvider>[
          OrtProvider.CPU,
          OrtProvider.XNNPACK,
          OrtProvider.OPEN_VINO,
          OrtProvider.CUDA,
          OrtProvider.CORE_ML,
        ]),
      );

      // CPU 永远可用、永远是最后一档，不参与探测，所以不该出现在「加速 EP」集合里。
      expect(
        await factory.availableAcceleratedProviders(),
        const <OcrExecutionProvider>{
          OcrExecutionProvider.cuda,
          OcrExecutionProvider.coreml,
        },
      );
    });

    test('探测异常不被吞掉（BUG-1163：探测失败也是一条可观测降级）', () async {
      final OrtOcrSessionFactory factory =
          OrtOcrSessionFactory(runtime: _ThrowingOnnxRuntime());

      await expectLater(
        factory.availableAcceleratedProviders(),
        throwsA(isA<StateError>()),
      );
    });
  });
}

class _FakeOnnxRuntime extends OnnxRuntime {
  _FakeOnnxRuntime(this._providers);

  final List<OrtProvider> _providers;

  @override
  Future<List<OrtProvider>> getAvailableProviders() async => _providers;
}

class _ThrowingOnnxRuntime extends OnnxRuntime {
  @override
  Future<List<OrtProvider>> getAvailableProviders() async =>
      throw StateError('no ORT native');
}
