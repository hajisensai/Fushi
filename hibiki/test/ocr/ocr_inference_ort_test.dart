import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/ocr/ocr_inference.dart';
import 'package:hibiki/src/ocr/ocr_inference_ort.dart';

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

  test('non-provider session errors are not hidden by CPU fallback', () async {
    int attempts = 0;

    await expectLater(
      createOcrSessionWithProviderFallback<String>(
        providers: const <OcrExecutionProvider>[
          OcrExecutionProvider.directml,
          OcrExecutionProvider.cpu,
        ],
        create: (List<OcrExecutionProvider> providers) async {
          attempts++;
          throw PlatformException(
            code: 'SESSION_CREATION_ERROR',
            message: 'invalid model',
          );
        },
      ),
      throwsA(
        isA<PlatformException>().having(
            (PlatformException e) => e.code, 'code', 'SESSION_CREATION_ERROR'),
      ),
    );
    expect(attempts, 1);
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
}
