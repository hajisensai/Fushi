/// Real Windows system OCR must process viewed pages without scanning ahead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

Future<Uint8List> _textPage(String text) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(
        color: Colors.black,
        fontSize: 64,
        fontFamily: 'Arial',
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: 760);
  painter.paint(canvas, const Offset(20, 180));
  painter.dispose();
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(800, 1200);
  picture.dispose();
  final ByteData? bytes = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real system OCR caches viewed pages only', (
    WidgetTester tester,
  ) async {
    final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
    await launchFushiTestApp();
    final bool homeReady = await waitForHome(tester);
    FlutterError.onError = testErrorHandler;
    expect(homeReady, isTrue);
    final AppModel appModel = await readyAppModel(tester);
    final bool focusBefore = appModel.experimentalFocusNavigationEnabled;
    await enableFocusNavigation(tester);
    final bool available = await const MethodChannelSystemOcr().isAvailable();
    debugPrint('[visible-ocr] systemAvailable=$available language=en');
    expect(
      available,
      isTrue,
      reason: 'Windows system OCR unavailable: live OCR is not verified',
    );
    final String engineBefore = appModel.mangaOcrEnginePreference;
    final String languageBefore = appModel.mangaOcrLensLanguage;
    final String spreadBefore = appModel.mangaSpreadPreference;
    final bool floatingBefore = appModel.mangaChromeFloating;
    final Directory bookDir = Directory.systemTemp.createTempSync(
      'manga_visible_ocr_',
    );
    final Directory images = Directory(p.join(bookDir.path, 'images'))
      ..createSync();
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (int index = 0; index < 4; index++) {
      final String filename = 'p$index.png';
      File(
        p.join(images.path, filename),
      ).writeAsBytesSync(await _textPage('HELLO WORLD\nPAGE ${index + 1}'));
      pages.add(<String, Object?>{
        'url': filename,
        'width': 800,
        'height': 1200,
        'blocks': <Object?>[],
      });
    }
    File(
      p.join(bookDir.path, 'manga.json'),
    ).writeAsStringSync(jsonEncode(<String, Object?>{'pages': pages}));
    final String key = 'visible-ocr-${DateTime.now().microsecondsSinceEpoch}';
    await appModel.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: 'Visible OCR fixture',
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: 4,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    final EpubBookRow book = await (appModel.database.select(
      appModel.database.epubBooks,
    )..where((table) => table.bookKey.equals(key))).getSingle();
    await appModel.database.setMangaReaderOverride(book.uid, <String, Object?>{
      'mode': 'spread',
      'autoMode': false,
      'direction': 'ltr',
      'ocrTrigger': 'automatic',
      'parallelOcrTasks': 1,
    });
    final Directory cacheDir = Directory(
      p.join(bookDir.path, 'manga_ocr_out', '_pages', 'system_ocr_en'),
    );
    File cache(int index) =>
        File(p.join(cacheDir.path, '${index.toString().padLeft(6, '0')}.json'));
    Future<void> waitForCache(int index) async {
      for (
        int attempt = 0;
        attempt < 120 && !cache(index).existsSync();
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        cache(index).existsSync(),
        isTrue,
        reason: 'Page $index must be recognized by real system OCR',
      );
    }

    final NavigatorState navigator = appModel.navigatorKey.currentState!;
    try {
      await appModel.setMangaOcrEnginePreference('system_ocr');
      await appModel.setMangaOcrLensLanguage('en');
      await appModel.setMangaSpreadPreference('single');
      await appModel.setMangaChromeFloating(false);
      final BuildContext context = navigator.context;
      if (!context.mounted) fail('navigator unmounted');
      unawaited(
        navigator.push(
          adaptivePageRoute<void>(
            context: context,
            builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
              child: MangaFushiPage(item: null, bookKey: key),
            ),
          ),
        ),
      );
      await waitForCache(0);
      expect(cache(1).existsSync(), isFalse);
      expect(cache(2).existsSync(), isFalse);
      expect(cache(3).existsSync(), isFalse);
      expect(await cache(0).readAsString(), contains('HELLO'));
      expect(
        (await captureFlutterFrame(tester, 'manga-visible-ocr-page-one')).saved,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await waitForCache(1);
      expect(cache(2).existsSync(), isFalse);
      expect(cache(3).existsSync(), isFalse);
      expect(await cache(1).readAsString(), contains('HELLO'));
      expect(
        (await captureFlutterFrame(tester, 'manga-visible-ocr-page-two')).saved,
        isTrue,
      );
      debugPrint(
        '[visible-ocr] cached=0,1 unseen=2,3 absent; real HELLO text recognized',
      );
    } finally {
      navigator.popUntil((Route<dynamic> route) => route.isFirst);
      await tester.pump(const Duration(seconds: 1));
      await appModel.setMangaOcrEnginePreference(engineBefore);
      await appModel.setMangaOcrLensLanguage(languageBefore);
      await appModel.setMangaSpreadPreference(spreadBefore);
      await appModel.setMangaChromeFloating(floatingBefore);
      await appModel.setExperimentalFocusNavigationEnabled(focusBefore);
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    }
  });
}
