import 'dart:async';
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
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 阅读器内的 OCR 入口已移除（BUG-2461）；本地漫画唯一的整卷 OCR 入口在作品页。
/// 这条守着入口在场、且任务已在跑时不会再弹第二个向导。
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

  testWidgets('本地漫画作品页有「整卷 OCR」入口；任务已在跑时点击不再弹向导', (WidgetTester tester) async {
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
    // 预置一个运行中的任务：点击入口必须直接提示「正在识别」，不得再弹向导。
    final StreamController<MangaOcrBackgroundEvent> source =
        StreamController<MangaOcrBackgroundEvent>();
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    registry.start(
      job: MangaOcrBackgroundJob(
        bookKey: bookKey,
        managedDirectory: bookDir.path,
        engine: MangaOcrEngineId.localOnnx,
        events: source.stream,
      ),
      mangaJsonPath: p.join(bookDir.path, 'manga.json'),
    );

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
            .byKey(const ValueKey<String>('manga_series_run_ocr'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();

    final Finder entry =
        find.byKey(const ValueKey<String>('manga_series_run_ocr'));
    expect(entry, findsOneWidget, reason: '本地漫画的整卷 OCR 入口必须在作品页');
    expect(find.byKey(const ValueKey<String>('manga_series_open_local')),
        findsOneWidget);

    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Dialog), findsNothing,
        reason: '同书已有任务在跑时不得再弹向导（否则会并发两份 OCR 互相覆盖）');

    await tester.runAsync(() async {
      await registry.cancelAll();
      await source.close();
    });
  });
}
