/// 进入即整卷识别的真机 E2E：打开一本没识别过的漫画，阅读器自动排整卷任务，
/// 用真实引擎从当前页起识别**全部**页，右上角浮标显示进度，跑完后 manga.json
/// 落盘带 OCR 元数据与真实识别出的文字。
///
/// 引擎：本机有 Windows 系统 OCR（英文语言包）就用它；没有就用 Google Lens
/// 识别合成的「HELLO WORLD / PAGE n」页（隔离数据根里预置上传同意，不涉及任何
/// 用户数据）。
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
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart'
    show MangaOcrProgressBadge;
import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

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

/// 页数够多，任务跑的途中才截得到进度浮标的真实像素（4 页时 Lens 在截图前就跑完）。
const int _pageCount = 24;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('opening a volume recognizes every page with a real engine', (
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
    final bool systemAvailable = await const MethodChannelSystemOcr()
        .isAvailable();
    final String engine = systemAvailable ? 'system_ocr' : 'google_lens';
    debugPrint(
      '[auto-volume-ocr] systemAvailable=$systemAvailable engine=$engine',
    );
    if (!systemAvailable) {
      // 隔离数据根：预置 Lens 上传同意，等价于用户在告知框点了「同意」。
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        kGoogleLensDisclosurePreferenceKey,
        kGoogleLensDisclosureVersion,
      );
    }
    final String engineBefore = appModel.mangaOcrEnginePreference;
    final String languageBefore = appModel.mangaOcrLensLanguage;
    final String spreadBefore = appModel.mangaSpreadPreference;
    final bool floatingBefore = appModel.mangaChromeFloating;
    final Directory bookDir = Directory.systemTemp.createTempSync(
      'manga_auto_volume_ocr_',
    );
    final Directory images = Directory(p.join(bookDir.path, 'images'))
      ..createSync();
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (int index = 0; index < _pageCount; index++) {
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
    final String key =
        'auto-volume-ocr-${DateTime.now().microsecondsSinceEpoch}';
    await appModel.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: 'Auto volume OCR fixture',
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: _pageCount,
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
    });
    final File mangaJson = File(p.join(bookDir.path, 'manga.json'));
    Future<Map<String, Object?>?> finishedPayload() async {
      final Object? decoded = jsonDecode(await mangaJson.readAsString());
      if (decoded is! Map<String, Object?> || decoded['ocr'] == null) {
        return null;
      }
      return decoded;
    }

    final NavigatorState navigator = appModel.navigatorKey.currentState!;
    try {
      await appModel.setMangaOcrEnginePreference(engine);
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
      // 没有任何用户动作：进入阅读器本身就要排上整卷任务并显示进度浮标。
      final Finder badge = find.byKey(
        const ValueKey<String>('manga_ocr_acceleration_label'),
      );
      bool badgeSeen = false;
      Map<String, Object?>? payload;
      for (int attempt = 0; attempt < 360 && payload == null; attempt++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (!badgeSeen && badge.evaluate().isNotEmpty) {
          badgeSeen = true;
          final String text =
              (tester.widget(badge) as MangaOcrProgressBadge).text;
          debugPrint('[auto-volume-ocr] badge="$text"');
          expect(
            (await captureFlutterFrame(
              tester,
              'manga-auto-volume-ocr-running',
            )).saved,
            isTrue,
          );
        }
        payload = await finishedPayload();
      }
      expect(badgeSeen, isTrue, reason: 'Progress badge must be shown');
      expect(payload, isNotNull, reason: 'Whole volume must finish');
      final List<Object?> images = payload!['pages']! as List<Object?>;
      expect(images, hasLength(_pageCount));
      for (int index = 0; index < images.length; index++) {
        final String blocks = jsonEncode(
          (images[index]! as Map<String, Object?>)['blocks'],
        );
        expect(
          blocks,
          contains('PAGE ${index + 1}'),
          reason: 'Page $index must be recognized by real $engine',
        );
      }
      for (
        int attempt = 0;
        attempt < 20 && badge.evaluate().isNotEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(badge, findsNothing, reason: 'Badge must clear once finished');
      expect(
        (await captureFlutterFrame(tester, 'manga-auto-volume-ocr-done')).saved,
        isTrue,
      );
      debugPrint(
        '[auto-volume-ocr] engine=$engine all $_pageCount pages recognized, '
        'manga.json final',
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
