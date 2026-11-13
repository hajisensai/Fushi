/// BUG-4479: the desktop reader selects a complete word across OCR line breaks.
/// Uses the production controller cursor path in a real WebView, without
/// coordinate clicks. The fixture image retains the original printed hyphens.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_controller_cursor_scripts.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const List<List<String>> _lines = <List<String>>[
  <String>['Under-', 'stands', 'the tree'],
  <String>['EVERY-', "ONE'S"],
  <String>['well-known', '1990-1995'],
  <String>["EVERYONE'S"],
];

Future<void> _writeFixture(Directory book) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFFFFFFF), BlendMode.src);
  final List<List<Object?>> lineCoords = <List<Object?>>[];
  final List<double> blockWidths = <double>[];
  for (int block = 0; block < _lines.length; block++) {
    lineCoords.add(<Object?>[]);
    double blockWidth = 0;
    for (int line = 0; line < _lines[block].length; line++) {
      final ui.Paragraph paragraph =
          (ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 36))
                ..pushStyle(ui.TextStyle(color: const Color(0xFF000000)))
                ..addText(_lines[block][line]))
              .build()
            ..layout(const ui.ParagraphConstraints(width: 480));
      final double top = 100.0 + block * 250 + line * 48;
      final double width = paragraph.longestLine;
      if (width > blockWidth) blockWidth = width;
      canvas.drawParagraph(paragraph, Offset(100, top));
      lineCoords[block].add(<List<double>>[
        <double>[100, top],
        <double>[100 + width, top],
        <double>[100 + width, top + paragraph.height],
        <double>[100, top + paragraph.height],
      ]);
      paragraph.dispose();
    }
    blockWidths.add(blockWidth);
  }
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(800, 1200);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final Directory images = Directory(p.join(book.path, 'images'))..createSync();
  File(
    p.join(images.path, 'page.png'),
  ).writeAsBytesSync(png!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  File(p.join(book.path, 'manga.json')).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'pages': <Object?>[
        <String, Object?>{
          'url': 'page.png',
          'width': 800,
          'height': 1200,
          'blocks': <Object?>[
            for (int b = 0; b < _lines.length; b++)
              <String, Object?>{
                'box': <num>[
                  100,
                  100 + b * 250,
                  100 + blockWidths[b],
                  100 + b * 250 + _lines[b].length * 48,
                ],
                'vertical': false,
                'font_size': 36,
                'lines': _lines[b],
                'lines_coords': lineCoords[b],
              },
          ],
        },
      ],
    }),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'dehyphenated words share cursor offsets and selection in WebView',
    (WidgetTester tester) async {
      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue);
      FlutterError.onError = testErrorHandler;
      final AppModel appModel = await readyAppModel(tester);
      final bool scanBefore = appModel.scanNonJapaneseText;
      final Directory book = Directory.systemTemp.createTempSync(
        'manga_dehyphenation_',
      );
      await _writeFixture(book);
      const String key = 'manga-dehyphenation-fixture';
      await appModel.database.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: 'OCR dehyphenation',
          epubPath: 'manga.json',
          extractDir: book.path,
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
          format: const Value<String>('manga'),
        ),
      );
      final EpubBookRow row = await (appModel.database.select(
        appModel.database.epubBooks,
      )..where((table) => table.bookKey.equals(key))).getSingle();
      await appModel.database.setMangaReaderOverride(row.uid, <String, Object?>{
        'mode': 'spread',
        'autoMode': false,
        'direction': 'ltr',
        'ocrTrigger': 'manual',
      });
      final NavigatorState nav = appModel.navigatorKey.currentState!;
      try {
        await appModel.setScanNonJapaneseText(true);
        final BuildContext context = nav.context;
        if (!context.mounted) fail('navigator unmounted');
        unawaited(
          nav.push(
            adaptivePageRoute<void>(
              context: context,
              builder: (BuildContext context) =>
                  const FushiAppUiScaleNeutralizer(
                    child: MangaFushiPage(item: null, bookKey: key),
                  ),
            ),
          ),
        );
        for (int i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find.byType(MangaFushiPage).evaluate().isNotEmpty) break;
        }
        expect(find.byType(MangaFushiPage), findsOneWidget);
        final dynamic reader = tester.state(find.byType(MangaFushiPage));
        Object? ready;
        for (int i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          ready = await reader.debugEvaluateJavascript(
            "!!(window.fushiSelection && document.querySelector('.ocr-char'))",
          );
          if (ready == true) break;
        }
        expect(ready, isTrue, reason: 'reader OCR DOM must load');
        final List<Object?> evidence = <Object?>[];
        for (final ({int block, int offset, String char, String word}) probe
            in <({int block, int offset, String char, String word})>[
              (block: 0, offset: 1, char: 'n', word: 'Understands'),
              (block: 0, offset: 5, char: 's', word: 'Understands'),
              (block: 0, offset: 8, char: 'n', word: 'Understands'),
              (block: 0, offset: 12, char: 't', word: 'the'),
              // The existing scanner stops at a standalone apostrophe cell.
              // The unsplit control must select the same word, while both
              // complete block strings below retain the possessive suffix.
              (block: 1, offset: 5, char: 'O', word: 'EVERYONE'),
              (block: 3, offset: 5, char: 'O', word: 'EVERYONE'),
            ]) {
          final String source = MangaControllerCursorScripts.place(
            page: 0,
            block: probe.block,
            utf16: probe.offset,
            color: 'red',
            lookup: true,
          );
          expect(await reader.debugEvaluateJavascript(source), 'lookup');
          final Object? raw = await reader.debugEvaluateJavascript('''
JSON.stringify({
  char: document.querySelector('[data-fushi-ctl-cursor]').textContent,
  text: window.fushiSelection.selection && window.fushiSelection.selection.text,
  blocks: Array.from(document.querySelectorAll('.ocr-box')).map(b => b.textContent)
})''');
          final Map<String, Object?> result =
              (jsonDecode(raw! as String) as Map).cast<String, Object?>();
          expect(result['char'], probe.char);
          expect(result['text'], probe.word);
          expect(result['blocks'], <String>[
            'Understands the tree',
            "EVERYONE'S",
            'well-known 1990-1995',
            "EVERYONE'S",
          ]);
          evidence.add(result);
          debugPrint(
            '[dehyphenation] block=${probe.block} offset=${probe.offset} $raw',
          );
        }
        File(
          p.join(observeScreenshotDir().parent.path, 'dehyphenation-dom.json'),
        ).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(evidence),
        );
        final List<int>? screenshot = await reader.debugCaptureWebView();
        expect(screenshot, isNotEmpty, reason: 'capture real WebView pixels');
        File(
          p.join(observeScreenshotDir().path, 'observe-dehyphenation.png'),
        ).writeAsBytesSync(screenshot!);
      } finally {
        nav.popUntil((Route<Object?> route) => route.isFirst);
        await tester.pump(const Duration(milliseconds: 500));
        await appModel.setScanNonJapaneseText(scanBefore);
        book.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
