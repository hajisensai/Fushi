import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/sync/screen_ocr_lens_engine.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/sync/fushi_screen_ocr_host.dart';

/// 记下每次逐页识别的语言与字节。
class _FakeLens implements GoogleLensMangaOcrRunner {
  final List<(Uint8List, String)> calls = <(Uint8List, String)>[];

  @override
  Future<MokuroImage> recognizePageBytes(
    Uint8List source, {
    required String relativeUrl,
    required String language,
  }) async {
    calls.add((source, language));
    return MokuroImage(
      url: relativeUrl,
      size: const MokuroSize(1, 1),
      blocks: const <MokuroBlock>[],
    );
  }

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
    required String language,
    MangaOcrPageFocus? focus,
  }) => throw UnimplementedError();

  @override
  Future<void> clearCache(String imageDirPath) => throw UnimplementedError();
}

void main() {
  test('only an explicit Google Lens preference selects Lens', () {
    final ScreenOcrExternalEngine lens = GoogleLensScreenOcrEngine(
      runner: _FakeLens(),
      language: 'ja',
      hasConsent: () async => true,
      requestConsent: () {},
    );
    for (final MangaOcrEnginePreference preference
        in MangaOcrEnginePreference.values) {
      final ScreenOcrExternalEngine? picked = selectScreenOcrEngine(
        enginePreferenceKey: preference.key,
        lens: () => lens,
      );
      expect(
        picked,
        preference == MangaOcrEnginePreference.googleLens ? lens : isNull,
        reason: preference.key,
      );
    }
  });

  test(
    'without consent: blocked, asks once per check, never uploads',
    () async {
      final _FakeLens runner = _FakeLens();
      bool consent = false;
      int asked = 0;
      final GoogleLensScreenOcrEngine engine = GoogleLensScreenOcrEngine(
        runner: runner,
        language: 'ja',
        hasConsent: () async => consent,
        requestConsent: () => asked++,
      );

      expect(await engine.blockedReason(), kScreenOcrLensConsentReason);
      expect(asked, 1);
      expect(runner.calls, isEmpty);

      consent = true;
      expect(await engine.blockedReason(), isNull);
      expect(asked, 1);
    },
  );

  test('recognize sends the frame with the host Lens language', () async {
    final _FakeLens runner = _FakeLens();
    final GoogleLensScreenOcrEngine engine = GoogleLensScreenOcrEngine(
      runner: runner,
      language: 'zh',
      hasConsent: () async => true,
      requestConsent: () {},
    );
    final Uint8List frame = Uint8List.fromList(<int>[1, 2, 3]);
    await engine.recognize(frame);
    expect(runner.calls.single.$1, frame);
    expect(runner.calls.single.$2, 'zh');
    expect(engine.id, 'googleLens');
  });
}
