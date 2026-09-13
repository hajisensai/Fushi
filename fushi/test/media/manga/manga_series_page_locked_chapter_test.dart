import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// BUG-2479：锁定章（源站要登录并购买）点了不能默默入队然后必败——先弹引导。
///
/// - 点锁定章 → 弹「章节已锁定」，**不**入队；
/// - 「仍然下载」→ 入队；取消 → 不入队；
/// - 适配器给得出登录目标时才有「登录」按钮；
/// - 「下载全部」跳过锁定章。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => throw StateError('the series page must not resolve pages');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw StateError('the series page must not fetch pages');

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

/// 能登录的适配器：登录目标指向一个「浏览器持有 cookie」的运行时。
class _LoginAdapter extends _FakeAdapter implements OnlineMangaLoginCapable {
  @override
  OnlineMangaLoginTarget? loginTarget(OnlineMangaLibraryEntry entry) => (
    runtime: _BrowserCookieRuntime(),
    sourceName: 'Fake',
    baseUrl: 'https://example.org',
  );
}

class _BrowserCookieRuntime implements BrowserCookieMihonRuntime {}

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final List<MediaItem?> opened = <MediaItem?>[];

  @override
  FushiDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;

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
    name: '\u{1F512} Chapter 2',
    number: 2,
    locked: true,
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

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

void main() {
  late Directory root;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_series_locked_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  OnlineMangaLibraryService library(OnlineMangaRuntimeAdapter adapter) =>
      OnlineMangaLibraryService(
        database: db,
        rootDirectory: Directory(p.join(root.path, 'legacy')),
        adapter: adapter,
      );

  Future<MangaDownloadJobRow?> jobFor(String bookKey, String chapterKey) =>
      db.findMangaDownloadJob(
        kind: MangaDownloadJobKind.chapter,
        bookKey: bookKey,
        chapterKey: chapterKey,
      );

  const ValueKey<String> dialogKey = ValueKey<String>(
    'manga_chapter_locked_dialog',
  );
  const ValueKey<String> loginKey = ValueKey<String>(
    'manga_chapter_locked_login',
  );
  const ValueKey<String> appBarLoginKey = ValueKey<String>(
    'manga_series_login',
  );

  Future<String> openPage(
    WidgetTester tester,
    OnlineMangaRuntimeAdapter adapter,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final OnlineMangaLibraryService service = library(adapter);
    final _TestAppModel appModel = _TestAppModel(db, service, root);
    final EpubBookRow row = await service.add(_entry());
    await tester.pumpWidget(_harness(appModel, row.bookKey));
    await _pumpUntil(tester, find.text('Chapter 1'));
    expect(find.text('Chapter 1'), findsOneWidget);
    return row.bookKey;
  }

  testWidgets('点锁定章 → 弹引导、不入队；取消后仍不入队', (WidgetTester tester) async {
    late String bookKey;
    await tester.runAsync(() async {
      bookKey = await openPage(tester, _FakeAdapter());
      await tester.tap(find.text('\u{1F512} Chapter 2'));
      await _settle(tester);
      expect(find.byKey(dialogKey), findsOneWidget);
      // 适配器不给登录目标：没有「登录」按钮。
      expect(find.byKey(loginKey), findsNothing);
      expect(await jobFor(bookKey, '/chapter/2'), isNull);

      await tester.tap(find.text(t.dialog_cancel));
      await _settle(tester);
      expect(find.byKey(dialogKey), findsNothing);
      expect(await jobFor(bookKey, '/chapter/2'), isNull);
    });
  });

  testWidgets('「仍然下载」→ 入队', (WidgetTester tester) async {
    late String bookKey;
    await tester.runAsync(() async {
      bookKey = await openPage(tester, _FakeAdapter());
      await tester.tap(find.text('\u{1F512} Chapter 2'));
      await _settle(tester);
      await tester.tap(find.text(t.manga_chapter_locked_download_anyway));
      await _settle(tester);
    });
    final MangaDownloadJobRow? job = await jobFor(bookKey, '/chapter/2');
    expect(job, isNotNull);
    expect(job!.status, MangaDownloadJobStatus.queued);
  });

  testWidgets('适配器给得出登录目标 → 弹窗带「登录」按钮', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await openPage(tester, _LoginAdapter());
      await tester.tap(find.text('\u{1F512} Chapter 2'));
      await _settle(tester);
      expect(find.byKey(dialogKey), findsOneWidget);
      expect(find.byKey(loginKey), findsOneWidget);
    });
  });

  // BUG-2497：登录入口要在作品页 AppBar 上直接可见，不能只藏在锁章弹窗里。
  testWidgets('适配器给得出登录目标 → AppBar 有「登录」按钮', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await openPage(tester, _LoginAdapter());
      expect(find.byKey(appBarLoginKey), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byKey(appBarLoginKey)).onPressed,
        isNotNull,
      );
    });
  });

  testWidgets('适配器不给登录目标 → AppBar 没有「登录」按钮', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await openPage(tester, _FakeAdapter());
      expect(find.byKey(appBarLoginKey), findsNothing);
    });
  });

  testWidgets('未锁定章不弹窗、直接入队', (WidgetTester tester) async {
    late String bookKey;
    await tester.runAsync(() async {
      bookKey = await openPage(tester, _FakeAdapter());
      await tester.tap(find.text('Chapter 1'));
      await _settle(tester);
      expect(find.byKey(dialogKey), findsNothing);
    });
    expect(
      (await jobFor(bookKey, '/chapter/1'))?.status,
      MangaDownloadJobStatus.queued,
    );
  });

  testWidgets('「下载全部」跳过锁定章', (WidgetTester tester) async {
    late String bookKey;
    await tester.runAsync(() async {
      bookKey = await openPage(tester, _FakeAdapter());
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_download_all')),
      );
      await _settle(tester);
    });
    expect(
      (await jobFor(bookKey, '/chapter/1'))?.status,
      MangaDownloadJobStatus.queued,
    );
    expect(await jobFor(bookKey, '/chapter/2'), isNull, reason: '锁定章不入队');
  });
}
