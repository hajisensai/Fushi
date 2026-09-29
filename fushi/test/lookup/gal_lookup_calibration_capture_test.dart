import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/galgame_window_gif.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: 1,
  heightPx: 1,
  dpi: 96,
);
const WindowCaptureMetadata _metadata = WindowCaptureMetadata(
  capturedHwnd: 77,
  capturedPid: 1234,
  clientLeftPx: -300,
  clientTopPx: 90,
  clientWidthPx: 1,
  clientHeightPx: 1,
  imageWidthPx: 1,
  imageHeightPx: 1,
  dpi: 96,
  clientAreaComplete: true,
  capturedAtTickMs: 400,
);

Uint8List _png() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
);

Map<String, Object?> _presentationMetadata() => <String, Object?>{
  ..._metadata.toJson(),
  'capturedHwnd': 88,
  'capturedPid': 4567,
  'sourceHwnd': 77,
  'sourcePid': 1234,
  'presentationHwnd': 88,
  'presentationPid': 4567,
  'usedPresentationCapture': true,
  'presentationViewportComplete': true,
  'clientAreaComplete': false,
  'clientWidthPx': 3,
  'clientHeightPx': 2,
  'sourceViewportWidthPx': 2,
  'sourceViewportHeightPx': 2,
  'destinationViewportWidthPx': 1,
  'destinationViewportHeightPx': 1,
};

GalLookupCalibrationCaptureSnapshot _snapshot({
  int epoch = 10,
  String id = 'entry-1',
  int seq = 5,
  String thread = 'body',
  String text = 'Synthetic sample',
  int hwnd = 77,
  int pid = 1234,
  GalLookupReferenceClientV1 client = _client,
  String source = 'engine:body',
}) => GalLookupCalibrationCaptureSnapshot(
  sourceText: text,
  referenceClient: client,
  exePath: r'c:\synthetic\game.exe',
  exeSha256: _sha,
  sessionEpoch: epoch,
  occurrenceId: id,
  sourceSequence: seq,
  targetHwnd: hwnd,
  targetPid: pid,
  selectedThreadKey: thread,
  sourceIdentity: source,
);

class _Lease implements GalHookCaptureLease {
  _Lease(this.onRelease);
  final void Function() onRelease;

  @override
  Future<void> release() async => onRelease();
}

Matcher throwsCaptureFailure(GalLookupCalibrationCaptureFailure failure) =>
    throwsA(
      isA<GalLookupCalibrationCaptureException>().having(
        (GalLookupCalibrationCaptureException error) => error.failure,
        'failure',
        failure,
      ),
    );

void main() {
  test(
    'cropped Magpie image keeps source mapping across save and reload',
    () async {
      final Map<String, Object?> fields = <String, Object?>{
        ..._presentationMetadata(),
        'sourceClientLeftPx': -10,
        'sourceClientTopPx': 5,
        'sourceClientWidthPx': 4,
        'sourceClientHeightPx': 4,
        'sourceClientDpi': 120,
        'sourceViewportLeftPx': -9,
        'sourceViewportTopPx': 7,
        'sourceViewportWidthPx': 2,
        'sourceViewportHeightPx': 1,
      };
      final GalLookupCalibrationCaptureSnapshot before = _snapshot(
        client: const GalLookupReferenceClientV1(
          widthPx: 4,
          heightPx: 4,
          dpi: 120,
        ),
      );
      final GalLookupCalibrationCapture sample =
          await captureGalLookupCalibrationSample(
            readSnapshot: () => before,
            acquireLease: () async => null,
            captureWindow: (_) async => WindowCaptureResult(
              pngBytes: _png(),
              metadata: WindowCaptureMetadata.tryFromMap(fields),
            ),
          );
      expect(sample.referenceClient, _client);
      final GalLookupCalibrationCapture restored =
          GalLookupCalibrationCapture.tryFromJson(sample.toJson())!;
      expect(restored.captureMetadata!.hasSourceClientMapping, isTrue);
      expect(restored.captureMetadata!.sourceViewportLeftPx, -9);
      expect(restored.captureMetadata!.sourceClientDpi, 120);
      for (final Map<String, Object?> invalid in [
        <String, Object?>{'sourceClientDpi': 96},
        <String, Object?>{'sourceClientWidthPx': 5},
        <String, Object?>{'sourceViewportTopPx': 4},
      ]) {
        await expectLater(
          captureGalLookupCalibrationSample(
            readSnapshot: () => before,
            acquireLease: () async => null,
            captureWindow: (_) async => WindowCaptureResult(
              pngBytes: _png(),
              metadata: WindowCaptureMetadata.tryFromMap({
                ...fields,
                ...invalid,
              }),
            ),
          ),
          throwsCaptureFailure(
            GalLookupCalibrationCaptureFailure.clientMappingUnavailable,
          ),
        );
      }
    },
  );

  test(
    'Magpie viewport keeps actual capture identity and survives disk reload',
    () async {
      final WindowCaptureMetadata metadata = WindowCaptureMetadata.tryFromMap(
        _presentationMetadata(),
      )!;
      expect(metadata.isCompleteClient, isFalse);
      final GalLookupCalibrationCapture sample =
          await captureGalLookupCalibrationSample(
            readSnapshot: () => _snapshot(
              client: const GalLookupReferenceClientV1(
                widthPx: 4,
                heightPx: 4,
                dpi: 96,
              ),
            ),
            acquireLease: () async => null,
            captureWindow: (_) async =>
                WindowCaptureResult(pngBytes: _png(), metadata: metadata),
          );
      expect(sample.referenceClient, _client);
      expect(sample.targetHwnd, 77);
      expect(sample.captureMetadata!.capturedHwnd, 88);
      final GalLookupCalibrationCapture restored =
          GalLookupCalibrationCapture.tryFromJson(sample.toJson())!;
      expect(restored.captureMetadata!.sourcePid, 1234);
      expect(restored.captureMetadata!.presentationPid, 4567);
      expect(restored.referenceClient, _client);
    },
  );

  for (final MapEntry<String, Object> invalid in <String, Object>{
    'sourceHwnd': 78,
    'sourcePid': 1235,
    'presentationHwnd': 89,
    'presentationPid': 4568,
    'presentationViewportComplete': false,
    'sourceViewportWidthPx': 3,
    'destinationViewportWidthPx': 2,
    'usedPresentationCapture': 'true',
  }.entries) {
    test('rejects invalid Magpie ${invalid.key}', () async {
      final Map<String, Object?> fields = _presentationMetadata()
        ..[invalid.key] = invalid.value;
      await expectLater(
        captureGalLookupCalibrationSample(
          readSnapshot: _snapshot,
          acquireLease: () async => null,
          captureWindow: (_) async => WindowCaptureResult(
            pngBytes: _png(),
            metadata: WindowCaptureMetadata.tryFromMap(fields),
          ),
        ),
        throwsCaptureFailure(
          GalLookupCalibrationCaptureFailure.clientMappingUnavailable,
        ),
      );
    });
  }

  test(
    'captures full client and freezes bytes with round-trip identity',
    () async {
      final List<String> order = <String>[];
      final Uint8List original = _png();
      final GalLookupCalibrationCapture sample =
          await captureGalLookupCalibrationSample(
            readSnapshot: _snapshot,
            captureWindow: (int hwnd) async {
              expect(hwnd, 77);
              order.add('capture');
              return WindowCaptureResult(
                pngBytes: original,
                metadata: _metadata,
              );
            },
            acquireLease: () async {
              order.add('hide');
              return _Lease(() => order.add('restore'));
            },
          );
      expect(order, <String>['hide', 'capture', 'restore']);
      original[0] = 0;
      expect(sample.pngBytes[0], 137);
      expect(() => sample.pngBytes[0] = 0, throwsUnsupportedError);
      final GalLookupCalibrationCapture? restored =
          GalLookupCalibrationCapture.tryFromJson(sample.toJson());
      expect(restored, isNotNull);
      expect(restored!.occurrenceId, 'entry-1');
      expect(restored.sourceSequence, 5);
      expect(restored.captureMetadata!.clientLeftPx, -300);
      expect(restored.pngBytes, sample.pngBytes);
    },
  );

  final Map<String, GalLookupCalibrationCaptureSnapshot> changed =
      <String, GalLookupCalibrationCaptureSnapshot>{
        'session': _snapshot(epoch: 11),
        'selected thread': _snapshot(thread: 'other'),
        'same text new occurrence': _snapshot(id: 'entry-2'),
        'same row changed text': _snapshot(text: 'Synthetic extension'),
        'folded seq': _snapshot(seq: 6),
        'target HWND': _snapshot(hwnd: 78),
        'target PID': _snapshot(pid: 1235),
        'client resize': _snapshot(
          client: const GalLookupReferenceClientV1(
            widthPx: 2,
            heightPx: 1,
            dpi: 96,
          ),
        ),
        'source identity': _snapshot(source: 'engine:other'),
      };
  for (final MapEntry<String, GalLookupCalibrationCaptureSnapshot> change
      in changed.entries) {
    test(
      'rejects ${change.key} changed while capturing and restores',
      () async {
        GalLookupCalibrationCaptureSnapshot current = _snapshot();
        bool released = false;
        await expectLater(
          captureGalLookupCalibrationSample(
            readSnapshot: () => current,
            acquireLease: () async => _Lease(() => released = true),
            captureWindow: (int hwnd) async {
              current = change.value;
              return WindowCaptureResult(pngBytes: _png(), metadata: _metadata);
            },
          ),
          throwsCaptureFailure(GalLookupCalibrationCaptureFailure.sceneChanged),
        );
        expect(released, isTrue);
      },
    );
  }

  test('scene changed during hide never starts WGC', () async {
    GalLookupCalibrationCaptureSnapshot current = _snapshot();
    bool released = false;
    await expectLater(
      captureGalLookupCalibrationSample(
        readSnapshot: () => current,
        acquireLease: () async {
          current = _snapshot(id: 'replacement');
          return _Lease(() => released = true);
        },
        captureWindow: (_) async => throw TestFailure('must not capture'),
      ),
      throwsCaptureFailure(GalLookupCalibrationCaptureFailure.sceneChanged),
    );
    expect(released, isTrue);
  });

  test('no attached surface needs no invented lease', () async {
    final GalLookupCalibrationCapture sample =
        await captureGalLookupCalibrationSample(
          readSnapshot: _snapshot,
          acquireLease: () async => null,
          captureWindow: (_) async =>
              WindowCaptureResult(pngBytes: _png(), metadata: _metadata),
        );
    expect(sample.sourceText, 'Synthetic sample');
  });

  test(
    'accepts Magpie source pixels when presentation size is different',
    () async {
      const GalLookupReferenceClientV1 presentation =
          GalLookupReferenceClientV1(widthPx: 2, heightPx: 2, dpi: 96);
      const WindowCaptureMetadata sourceMetadata = WindowCaptureMetadata(
        capturedHwnd: 77,
        capturedPid: 1234,
        clientLeftPx: 0,
        clientTopPx: 0,
        clientWidthPx: 1,
        clientHeightPx: 1,
        imageWidthPx: 1,
        imageHeightPx: 1,
        dpi: 96,
        clientAreaComplete: true,
        capturedAtTickMs: 401,
      );
      final GalLookupCalibrationCapture sample =
          await captureGalLookupCalibrationSample(
            readSnapshot: () => _snapshot(client: presentation),
            acquireLease: () async => null,
            captureWindow: (_) async =>
                WindowCaptureResult(pngBytes: _png(), metadata: sourceMetadata),
          );
      expect(sample.referenceClient.widthPx, 1);
      expect(sample.referenceClient.heightPx, 1);
      expect(sample.captureMetadata, sourceMetadata);
    },
  );

  test('capture failure releases lease', () async {
    bool released = false;
    await expectLater(
      captureGalLookupCalibrationSample(
        readSnapshot: _snapshot,
        acquireLease: () async => _Lease(() => released = true),
        captureWindow: (_) async => throw StateError('WGC failed'),
      ),
      throwsCaptureFailure(
        GalLookupCalibrationCaptureFailure.windowCaptureFailed,
      ),
    );
    expect(released, isTrue);
  });

  test('native capture reason and metadata survive capture failure', () async {
    await expectLater(
      captureGalLookupCalibrationSample(
        readSnapshot: _snapshot,
        acquireLease: () async => null,
        captureWindow: (_) async => const WindowCaptureResult(
          error: 'capture timed out',
          captureReason: 'no_frame',
          metadata: _metadata,
          diagnostics: 'private platform detail; CreateForWindow hr=0x80070057',
        ),
      ),
      throwsA(
        isA<GalLookupCalibrationCaptureException>()
            .having(
              (GalLookupCalibrationCaptureException error) => error.failure,
              'failure',
              GalLookupCalibrationCaptureFailure.windowCaptureFailed,
            )
            .having(
              (GalLookupCalibrationCaptureException error) =>
                  error.captureReason,
              'captureReason',
              'no_frame',
            )
            .having(
              (GalLookupCalibrationCaptureException error) =>
                  error.captureErrorCodes,
              'numeric error codes only',
              <String>['0x80070057'],
            )
            .having(
              (GalLookupCalibrationCaptureException error) =>
                  error.captureMetadata?.capturedHwnd,
              'capturedHwnd',
              77,
            ),
      ),
    );
  });

  test('known Magpie viewport failure gets its own capture category', () async {
    await expectLater(
      captureGalLookupCalibrationSample(
        readSnapshot: _snapshot,
        acquireLease: () async => null,
        captureWindow: (_) async => const WindowCaptureResult(
          error: 'presentation viewport unavailable',
          captureReason: 'presentation_viewport_unavailable',
          metadata: _metadata,
        ),
      ),
      throwsA(
        isA<GalLookupCalibrationCaptureException>()
            .having(
              (GalLookupCalibrationCaptureException error) => error.failure,
              'failure',
              GalLookupCalibrationCaptureFailure.surfaceMappingUnavailable,
            )
            .having(
              (GalLookupCalibrationCaptureException error) =>
                  error.captureReason,
              'captureReason',
              'presentation_viewport_unavailable',
            ),
      ),
    );
  });

  test(
    'mapping failure during snapshot still releases the capture lease',
    () async {
      int reads = 0;
      bool released = false;
      bool captured = false;
      await expectLater(
        captureGalLookupCalibrationSample(
          readSnapshot: () {
            if (++reads == 1) return _snapshot();
            throw const GalLookupCalibrationCaptureException(
              GalLookupCalibrationCaptureFailure.surfaceMappingUnavailable,
              captureReason: 'magpie_source_viewport_invalid',
            );
          },
          acquireLease: () async => _Lease(() => released = true),
          captureWindow: (_) async {
            captured = true;
            return WindowCaptureResult(pngBytes: _png(), metadata: _metadata);
          },
        ),
        throwsCaptureFailure(
          GalLookupCalibrationCaptureFailure.surfaceMappingUnavailable,
        ),
      );
      expect(captured, isFalse);
      expect(released, isTrue);
    },
  );

  test(
    'mapping failure from lease acquisition is preserved before capture',
    () async {
      bool captured = false;
      await expectLater(
        captureGalLookupCalibrationSample(
          readSnapshot: _snapshot,
          acquireLease: () async {
            throw const GalLookupCalibrationCaptureException(
              GalLookupCalibrationCaptureFailure.surfaceMappingUnavailable,
              captureReason: 'target_mapping_unavailable',
            );
          },
          captureWindow: (_) async {
            captured = true;
            return WindowCaptureResult(pngBytes: _png(), metadata: _metadata);
          },
        ),
        throwsCaptureFailure(
          GalLookupCalibrationCaptureFailure.surfaceMappingUnavailable,
        ),
      );
      expect(captured, isFalse);
    },
  );

  test('empty source remains invalid instead of mapping failure', () async {
    await expectLater(
      captureGalLookupCalibrationSample(
        readSnapshot: () => _snapshot(text: ''),
        acquireLease: () async => null,
        captureWindow: (_) async => throw TestFailure('must not capture'),
      ),
      throwsCaptureFailure(GalLookupCalibrationCaptureFailure.invalidSource),
    );
  });

  test('failed restore does not publish sample', () async {
    await expectLater(
      captureGalLookupCalibrationSample(
        readSnapshot: _snapshot,
        acquireLease: () async =>
            _Lease(() => throw StateError('restore failed')),
        captureWindow: (_) async =>
            WindowCaptureResult(pngBytes: _png(), metadata: _metadata),
      ),
      throwsCaptureFailure(GalLookupCalibrationCaptureFailure.restoreFailed),
    );
  });

  test(
    'legacy capture has no coordinate proof, normal screenshot still works',
    () async {
      final WindowCaptureResult legacy = WindowCaptureResult(pngBytes: _png());
      expect(legacy.ok, isTrue);
      await expectLater(
        captureGalLookupCalibrationSample(
          readSnapshot: _snapshot,
          acquireLease: () async => null,
          captureWindow: (_) async => legacy,
        ),
        throwsCaptureFailure(
          GalLookupCalibrationCaptureFailure.clientMappingUnavailable,
        ),
      );
    },
  );

  for (final MapEntry<String, Object> invalid in <String, Object>{
    'clientAreaComplete': false,
    'capturedHwnd': 78,
    'capturedPid': 1235,
    'imageWidthPx': 2,
    'clientHeightPx': 2,
    'dpi': 144.0,
  }.entries) {
    test('rejects native ${invalid.key} mapping mismatch', () async {
      final Map<String, Object?> map = _metadata.toJson()
        ..[invalid.key] = invalid.value;
      await expectLater(
        captureGalLookupCalibrationSample(
          readSnapshot: _snapshot,
          acquireLease: () async => null,
          captureWindow: (_) async => WindowCaptureResult(
            pngBytes: _png(),
            metadata: WindowCaptureMetadata.tryFromMap(map),
          ),
        ),
        throwsCaptureFailure(
          GalLookupCalibrationCaptureFailure.clientMappingUnavailable,
        ),
      );
    });
  }

  test('rejects oversized screenshot before retaining it', () async {
    await expectLater(
      captureGalLookupCalibrationSample(
        readSnapshot: _snapshot,
        acquireLease: () async => null,
        captureWindow: (_) async => WindowCaptureResult(
          pngBytes: Uint8List(GalLookupCalibrationCapture.maxPngBytes + 1),
          metadata: _metadata,
        ),
      ),
      throwsCaptureFailure(GalLookupCalibrationCaptureFailure.imageTooLarge),
    );
  });

  test('rejects PNG header dimensions that disagree with mapping', () async {
    final Uint8List png = _png();
    ByteData.sublistView(png).setUint32(16, 2);
    await expectLater(
      captureGalLookupCalibrationSample(
        readSnapshot: _snapshot,
        acquireLease: () async => null,
        captureWindow: (_) async =>
            WindowCaptureResult(pngBytes: png, metadata: _metadata),
      ),
      throwsCaptureFailure(
        GalLookupCalibrationCaptureFailure.imageDimensionsInvalid,
      ),
    );
  });

  test(
    'disk parser rejects missing geometry, wrong types and oversized text',
    () async {
      final GalLookupCalibrationCapture sample =
          await captureGalLookupCalibrationSample(
            readSnapshot: _snapshot,
            acquireLease: () async => null,
            captureWindow: (_) async =>
                WindowCaptureResult(pngBytes: _png(), metadata: _metadata),
          );
      for (final MapEntry<String, Object?> invalid in <String, Object?>{
        'captureMetadata': null,
        'sessionEpoch': '10',
        'pngBase64': '!invalid!',
        'exeSha256': 'bad',
        'sourceText': 'x' * (GalLookupCalibrationCapture.maxTextLength + 1),
      }.entries) {
        final Map<String, Object?> json = sample.toJson()
          ..[invalid.key] = invalid.value;
        expect(
          GalLookupCalibrationCapture.tryFromJson(json),
          isNull,
          reason: invalid.key,
        );
      }
    },
  );
}
