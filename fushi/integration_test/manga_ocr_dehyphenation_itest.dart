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
  <String>['Under- \t', 'stands', 'the tree'],
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
  final List<List<Object?>> regions = <List<Object?>>[];
  for (int block = 0; block < _lines.length; block++) {
    lineCoords.add(<Object?>[]);
    regions.add(<Object?>[]);
    int rawOffset = 0;
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
      for (int i = 0; i < _lines[block][line].length; i++) {
        if (_lines[block][line][i].trim().isEmpty) continue;
        final ui.TextBox glyph = paragraph.getBoxesForRange(i, i + 1).single;
        regions[block].add(<String, Object?>{
          'box': <double>[
            100 + glyph.left,
            top + glyph.top,
            100 + glyph.right,
            top + glyph.bottom,
          ],
          'utf16_start': rawOffset + i,
          'utf16_end': rawOffset + i + 1,
        });
      }
      rawOffset += _lines[block][line].length;
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
                'regions': regions[b],
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
        final Map<String, dynamic> fixture =
            jsonDecode(File(p.join(book.path, 'manga.json')).readAsStringSync())
                as Map<String, dynamic>;
        final List<dynamic> fixtureBlocks =
            fixture['pages'][0]['blocks'] as List<dynamic>;
        for (final ({
              int block,
              int offset,
              int rawOffset,
              String char,
              String word,
            })
            probe
            in <
              ({int block, int offset, int rawOffset, String char, String word})
            >[
              (
                block: 0,
                offset: 1,
                rawOffset: 1,
                char: 'n',
                word: 'Understands the tree',
              ),
              (
                block: 0,
                offset: 5,
                rawOffset: 8,
                char: 's',
                word: 'Understands the tree',
              ),
              (
                block: 0,
                offset: 8,
                rawOffset: 11,
                char: 'n',
                word: 'Understands the tree',
              ),
              (
                block: 0,
                offset: 12,
                rawOffset: 14,
                char: 't',
                word: 'the tree',
              ),
              // Split and unsplit controls scan the same possessive word.
              // The OCR apostrophe is part of the word, just as in a novel.
              (
                block: 1,
                offset: 5,
                rawOffset: 6,
                char: 'O',
                word: "EVERYONE'S",
              ),
              (
                block: 3,
                offset: 5,
                rawOffset: 5,
                char: 'O',
                word: "EVERYONE'S",
              ),
            ]) {
          final String source = MangaControllerCursorScripts.place(
            page: 0,
            block: probe.block,
            utf16: probe.offset,
            color: 'red',
            lookup: true,
          );
          final Object? raw = await reader.debugEvaluateJavascript('''
JSON.stringify((function(){
 const status = $source;
 const cursor = document.querySelector('[data-fushi-ctl-cursor]');
 return {status: status,
  char: cursor.textContent,
  geometry: [cursor.style.left, cursor.style.top, cursor.style.width, cursor.style.height].map(parseFloat),
  text: window.fushiSelection.selection && window.fushiSelection.selection.text,
  blocks: Array.from(document.querySelectorAll('.ocr-box')).map(b => b.textContent)
 };})())''');
          final Map<String, Object?> result =
              (jsonDecode(raw! as String) as Map).cast<String, Object?>();
          expect(result['char'], probe.char);
          expect(result['status'], 'lookup');
          expect(result['text'], probe.word);
          final Map<String, dynamic> fixtureBlock =
              fixtureBlocks[probe.block] as Map<String, dynamic>;
          final List<dynamic> blockBox = fixtureBlock['box'] as List<dynamic>;
          final Map<String, dynamic> glyph =
              (fixtureBlock['regions'] as List<dynamic>)
                  .cast<Map<String, dynamic>>()
                  .singleWhere(
                    (Map<String, dynamic> r) =>
                        r['utf16_start'] == probe.rawOffset,
                  );
          final List<dynamic> glyphBox = glyph['box'] as List<dynamic>;
          final double width =
              (blockBox[2] as num).toDouble() - (blockBox[0] as num).toDouble();
          final double height =
              (blockBox[3] as num).toDouble() - (blockBox[1] as num).toDouble();
          final List<double> expectedGeometry = <double>[
            ((glyphBox[0] as num) - (blockBox[0] as num)) / width * 100,
            ((glyphBox[1] as num) - (blockBox[1] as num)) / height * 100,
            ((glyphBox[2] as num) - (glyphBox[0] as num)) / width * 100,
            ((glyphBox[3] as num) - (glyphBox[1] as num)) / height * 100,
          ];
          for (int i = 0; i < 4; i++) {
            expect(
              (result['geometry'] as List)[i],
              closeTo(expectedGeometry[i], 0.001),
              reason: 'cursor must retain the printed glyph rectangle',
            );
          }
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
