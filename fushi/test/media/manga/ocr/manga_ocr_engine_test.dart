import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';

MangaOcrEngineCapability capability(
  MangaOcrEngineId id, {
  bool supported = true,
  bool ready = true,
}) =>
    MangaOcrEngineCapability(
      id: id,
      supported: supported,
      ready: ready,
      requiresNetwork: id == MangaOcrEngineId.googleLens ||
          id == MangaOcrEngineId.pairedHost,
      uploadsImages: id == MangaOcrEngineId.googleLens ||
          id == MangaOcrEngineId.pairedHost,
      supportsIncremental: id != MangaOcrEngineId.externalMokuro,
    );

void main() {
  test('stable preference keys round-trip without enum indexes', () {
    for (final MangaOcrEnginePreference value
        in MangaOcrEnginePreference.values) {
      expect(MangaOcrEnginePreferenceKey.fromKey(value.key), value);
    }
    expect(
      MangaOcrEnginePreferenceKey.fromKey('future_value'),
      MangaOcrEnginePreference.auto,
    );
  });

  test('automatic route never selects Lens even when it is the only ready one',
      () {
    final MangaOcrEngineId? selected = resolveMangaOcrEngine(
      preference: MangaOcrEnginePreference.auto,
      hasExistingMetadata: false,
      capabilities: <MangaOcrEngineCapability>[
        capability(MangaOcrEngineId.localOnnx, ready: false),
        capability(MangaOcrEngineId.googleLens),
        capability(MangaOcrEngineId.externalMokuro, ready: false),
        capability(MangaOcrEngineId.pairedHost, ready: false),
      ],
    );
    expect(selected, isNull);
  });

  test('automatic route is local, external, then paired host', () {
    final List<MangaOcrEngineCapability> capabilities =
        <MangaOcrEngineCapability>[
      capability(MangaOcrEngineId.localOnnx, ready: false),
      capability(MangaOcrEngineId.googleLens),
      capability(MangaOcrEngineId.externalMokuro),
      capability(MangaOcrEngineId.pairedHost),
    ];
    expect(
      resolveMangaOcrEngine(
        preference: MangaOcrEnginePreference.auto,
        hasExistingMetadata: false,
        capabilities: capabilities,
      ),
      MangaOcrEngineId.externalMokuro,
    );
    capabilities[0] = capability(MangaOcrEngineId.localOnnx);
    expect(
      resolveMangaOcrEngine(
        preference: MangaOcrEnginePreference.auto,
        hasExistingMetadata: false,
        capabilities: capabilities,
      ),
      MangaOcrEngineId.localOnnx,
    );
  });

  test('explicit unavailable engine does not silently fall back', () {
    expect(
      resolveMangaOcrEngine(
        preference: MangaOcrEnginePreference.googleLens,
        hasExistingMetadata: false,
        capabilities: <MangaOcrEngineCapability>[
          capability(MangaOcrEngineId.googleLens, ready: false),
          capability(MangaOcrEngineId.localOnnx),
        ],
      ),
      MangaOcrEngineId.googleLens,
    );
  });

  test('existing OCR metadata skips automatic work', () {
    expect(
      resolveMangaOcrEngine(
        preference: MangaOcrEnginePreference.auto,
        hasExistingMetadata: true,
        capabilities: <MangaOcrEngineCapability>[
          capability(MangaOcrEngineId.localOnnx),
        ],
      ),
      isNull,
    );
  });
}
