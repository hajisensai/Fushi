import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_dialog.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

class _UnavailableLocalService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => false;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
        detectorReady: false,
        recognizerReady: false,
        downloadedBytes: 0,
        totalBytes: 1,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<void> deleteModels() async {}

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
}

class _FakeLensRunner implements GoogleLensMangaOcrRunner {
  int requests = 0;

  @override
  Future<void> clearCache(String imageDirPath) async {}

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
  }) {
    requests += 1;
    return const Stream<MangaOcrVolumeEvent>.empty();
  }
}

void main() {
  late Directory imageDir;
  late FushiDatabase db;

  setUp(() {
    imageDir = Directory.systemTemp.createTempSync('lens_wizard_');
    File(p.join(imageDir.path, 'page.png')).writeAsBytesSync(<int>[1]);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    if (imageDir.existsSync()) imageDir.deleteSync(recursive: true);
  });

  testWidgets('declining first-use Lens disclosure performs zero Lens requests',
      (WidgetTester tester) async {
    final _FakeLensRunner lens = _FakeLensRunner();
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (BuildContext context) => ElevatedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => MangaOcrWizardDialog(
                      engines: MangaOcrWizardEngines(
                        service: _UnavailableLocalService(),
                        lensRunner: lens,
                        initialEnginePreference: 'google_lens',
                      ),
                      db: db,
                      lensDisclosureGate: (_) async => false,
                      initialImageDir: imageDir.path,
                      importOverride: ({
                        required String path,
                        required bool external,
                        String? title,
                      }) async =>
                          'unused',
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, t.manga_ocr_wizard_run),
    );
    await tester.pumpAndSettle();

    expect(lens.requests, 0);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, t.manga_ocr_wizard_run),
          )
          .onPressed,
      isNotNull,
    );
  });
}
