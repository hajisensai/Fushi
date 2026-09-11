import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 作品页「先下载再读」（设计稿 2026-09-12 §5）：点未下载的章 → 入队（表里出现
/// queued 行）、不开阅读器；点已下载的章 → 开读、不入队。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
          OnlineMangaLibraryEntry entry) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) =>
      throw StateError('the series page must not resolve pages');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw StateError('the series page must not fetch pages');

  @override
  Future<List<int>> fetchCover(
          OnlineMangaLibraryEntry entry, String url) async =>
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library) : super(testPlatformServices());

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final List<MediaItem?> opened = <MediaItem?>[];

  @override
  FushiDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) =>
      _library;

  /// 开阅读器的副作用（沉浸模式 / wakelock / audio handler）与本测试无关，只记
  /// 「被调了」。
  @override
  Future<void> openMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    bool killOnPop = false,
    bool pushReplacement = false,
    MediaItem? item,
    Bookmark? initialBookmarkJump,
  }) async {
    opened.add(item);
  }
}

Widget _harness(AppModel appModel, String bookKey) => ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: MangaSeriesPage(target: ShelfMangaSeriesTarget(bookKey)),
        ),
      ),
    );

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
  ),
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
];

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: _chapters,
    );

Future<void> _writeDownloadedChapter(String bookDir, String chapterKey) async {
  final Directory chapterDir = mangaChapterDirectory(bookDir, chapterKey);
  final Directory images = mangaChapterImagesDirectory(chapterDir);
  await images.create(recursive: true);
  await File(p.join(images.path, 'page-000001.jpg')).writeAsBytes(<int>[1]);
  await mangaChapterJsonFile(chapterDir).writeAsString(jsonEncode(
    <String, Object?>{
      'pages': <Map<String, Object?>>[
        <String, Object?>{
          'url': 'images/page-000001.jpg',
          'width': 100,
          'height': 150,
          'blocks': <Object?>[],
        },
      ],
    },
  ));
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

void main() {
  late Directory root;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_series_dl_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _FakeAdapter(),
    );
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('点未下载的章 → 表里出现 queued 行，不开阅读器', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(tester, find.text('Chapter 1'));
      expect(find.text('Chapter 1'), findsOneWidget);
      // 两章都没下载：状态位全是「未下载」。
      expect(
        find.byKey(
          const ValueKey<String>('manga_chapter_download_notDownloaded'),
        ),
        findsNWidgets(2),
      );

      await tester.tap(find.text('Chapter 1'));
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    final MangaDownloadJobRow? job = await db.findMangaDownloadJob(
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: '/chapter/1',
    );
    expect(job, isNotNull);
    expect(job!.status, MangaDownloadJobStatus.queued);
    expect(job.autoOcr, isFalse);
    expect(appModel.opened, isEmpty, reason: '没下载就不能开读');
    // 状态位跟着任务表刷新：这一章变成「排队中」。
    await tester.runAsync(() async {
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_queued')),
      );
    });
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_download_queued')),
      findsOneWidget,
    );
  });

  testWidgets('点已下载的章 → 开读、不入队', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await _writeDownloadedChapter(row.extractDir, '/chapter/1');
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );
      expect(
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
        findsOneWidget,
      );

      await tester.tap(find.text('Chapter 1'));
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    expect(appModel.opened, hasLength(1), reason: '已下载 → 直接开读');
    expect(await db.listMangaDownloadJobs(), isEmpty, reason: '已下载不入队');
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(
      OnlineMangaLibraryEntry.tryParse(after.sourceMetadata)!
          .currentChapter
          ?.key,
      '/chapter/1',
      reason: '开读前记下「选了这一章」，阅读器据此定位',
    );
  });
}
