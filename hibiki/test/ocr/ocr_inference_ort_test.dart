import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/ocr/ocr_inference.dart';
import 'package:hibiki/src/ocr/ocr_inference_ort.dart';

void main() {
  test('unsupported DirectML provider retries once with CPU', () async {
    final List<List<OcrExecutionProvider>> attempts =
        <List<OcrExecutionProvider>>[];

    final String result = await createOcrSessionWithProviderFallback<String>(
      providers: const <OcrExecutionProvider>[
        OcrExecutionProvider.directml,
        OcrExecutionProvider.cpu,
      ],
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
