import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 本地漫画作品页不再有「开始 OCR」：进入阅读器即自动整卷识别
/// （`manga_reader_auto_ocr.dart`）。这条守着作品页只剩「继续阅读」与「OCR 设置」。
class _TestAppModel extends AppModel {
  _TestAppModel(this._db) : super(testPlatformServices());

  final FushiDatabase _db;

  @override
  FushiDatabase get database => _db;
}

Widget _harness(
  AppModel appModel,
  String bookKey,
  MangaOcrJobRegistry registry,
) {
  return ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(testPlatformServices()),
      appProvider.overrideWith((ref) => appModel),
      mangaOcrJobRegistryProvider.overrideWithValue(registry),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: MangaSeriesPage(target: ShelfMangaSeriesTarget(bookKey)),
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('本地漫画作品页没有「开始 OCR」，保留继续阅读与 OCR 设置', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _TestAppModel appModel = _TestAppModel(db);

    final Directory bookDir =
        Directory.systemTemp.createTempSync('manga_series_ocr_entry_');
    addTearDown(() {
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    });
    File(p.join(bookDir.path, 'manga.json')).writeAsStringSync(jsonEncode(
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{
            'url': 'images/p001.jpg',
            'width': 100,
            'height': 150,
            'blocks': <Object?>[],
          },
        ],
      },
    ));
    Directory(p.join(bookDir.path, 'images')).createSync();
    File(p.join(bookDir.path, 'images', 'p001.jpg')).writeAsBytesSync(<int>[1]);

    const String bookKey = 'local ocr entry book';
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();

    await tester.runAsync(() async {
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ));
      await tester.pumpWidget(_harness(appModel, bookKey, registry));
      for (int i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find
            .byKey(const ValueKey<String>('manga_series_open_local'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('manga_series_open_local')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('manga_series_ocr_settings')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('manga_series_run_ocr')),
        findsNothing,
        reason: '识别在进入阅读器时自动开始，作品页不该再有手动入口');
    expect(find.text(t.manga_ocr_wizard_run), findsNothing);
  });
}
