import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_dialog.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// Fake 内置 OCR 服务：ocrFolder 返回可由测试手动喂事件的 controller。
class _FakeOcrService implements MangaOcrService {
  _FakeOcrService();

  final bool supported = true;
  final bool ready = true;
  StreamController<MangaOcrVolumeEvent>? volumeController;
  bool ocrCancelled = false;

  @override
  bool get isSupportedPlatform => supported;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
        detectorReady: ready,
        recognizerReady: ready,
        diskBytes: ready ? 50 : 0,
        totalBytes: 50,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<int> deleteModels() async => 0;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) {
    final StreamController<MangaOcrVolumeEvent> c =
        StreamController<MangaOcrVolumeEvent>();
    c.onCancel = () => ocrCancelled = true;
    volumeController = c;
    return c.stream;
  }
}

void main() {
  late FushiDatabase db;
  late Directory imageDir;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    imageDir = Directory.systemTemp.createTempSync('manga_ocr_wizard');
    File(p.join(imageDir.path, 'p001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
  });

  tearDown(() async {
    await db.close();
    if (imageDir.existsSync()) imageDir.deleteSync(recursive: true);
  });

  testWidgets(
      'builtin OCR: progress stream → finished → import called → pops bookKey',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService();
    String? importedPath;
    bool? importedExternal;

    String? poppedResult;
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (BuildContext ctx) => ElevatedButton(
                  onPressed: () async {
                    poppedResult = await showDialog<String>(
                      context: ctx,
                      builder: (_) => MangaOcrWizardDialog(
                        engines: MangaOcrWizardEngines(service: service),
                        db: db,
                        initialImageDir: imageDir.path,
                        importOverride: ({
                          required String path,
                          required bool external,
                          String? title,
                        }) async {
                          importedPath = path;
                          importedExternal = external;
                          return 'bookkey1';
                        },
                      ),
                    );
                  },
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

    // configure 阶段：Run 按钮可用。
    final Finder runBtn =
        find.widgetWithText(FilledButton, t.manga_ocr_wizard_run);
    expect(runBtn, findsOneWidget);
    await tester.tap(runBtn);
    await tester.pump();

    // 喂逐页进度。
    service.volumeController!.add(
      const MangaOcrVolumeEvent.page(pagesDone: 1, pagesTotal: 2),
    );
    await tester.pump();
    expect(find.text(t.manga_ocr_wizard_page_progress(done: 1, total: 2)),
        findsOneWidget);

    // 完成 → 触发落库 → pop。
    final String jsonPath = p.join(imageDir.path, 'manga.json');
    service.volumeController!.add(
      MangaOcrVolumeEvent.finished(pagesTotal: 2, mangaJsonPath: jsonPath),
    );
    await tester.pumpAndSettle();

    expect(importedPath, jsonPath);
    expect(importedExternal, isFalse);
    expect(poppedResult, 'bookkey1');
  });

  testWidgets('cancel during run: cancels stream, no import, back to configure',
      (WidgetTester tester) async {
    final _FakeOcrService service = _FakeOcrService();
    bool importCalled = false;

    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (BuildContext ctx) => ElevatedButton(
                  onPressed: () => showDialog<String>(
                    context: ctx,
                    builder: (_) => MangaOcrWizardDialog(
                      engines: MangaOcrWizardEngines(service: service),
                      db: db,
                      initialImageDir: imageDir.path,
                      importOverride: ({
                        required String path,
                        required bool external,
                        String? title,
                      }) async {
                        importCalled = true;
                        return 'x';
                      },
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

    await tester.tap(find.widgetWithText(FilledButton, t.manga_ocr_wizard_run));
    await tester.pump();
    service.volumeController!.add(
      const MangaOcrVolumeEvent.page(pagesDone: 1, pagesTotal: 3),
    );
    await tester.pump();

    // running 阶段只有一个 Cancel 按钮。
    await tester.tap(find.widgetWithText(TextButton, t.dialog_cancel));
    await tester.pumpAndSettle();

    expect(service.ocrCancelled, isTrue);
    expect(importCalled, isFalse);
    // 回到 configure：Run 按钮再次出现。
    expect(find.widgetWithText(FilledButton, t.manga_ocr_wizard_run),
        findsOneWidget);
  });
}
