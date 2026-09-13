import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 作品页「移出漫画书架」（用户 2026-09-13：加入书架应可取消，取消并删除这本
/// 书）：在库态按钮变成「移出」，确认后 DB 行 + 解压目录（含已下载章节）+ 章节
/// 状态一起消失，页面退回未入库态、可再次加入。
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

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library, Directory root)
    : super(testPlatformServices()) {
    // 阶段 C 起作品页读 `mangaDownloadAutoOcr`（经 prefsRepo）：把真仓库挂到同一个
    // 内存 DB 上，否则 `prefsRepo!` 在 build 里炸。
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
    bool recordHistory = true,
    bool waitUntilClosed = true,
    Widget Function()? launchPageBuilder,
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
  await mangaChapterJsonFile(chapterDir).writeAsString(
    jsonEncode(<String, Object?>{
      'pages': <Map<String, Object?>>[
        <String, Object?>{
          'url': 'images/page-000001.jpg',
          'width': 100,
          'height': 150,
          'blocks': <Object?>[],
        },
      ],
    }),
  );
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
    root = await Directory.systemTemp.createTemp('manga_series_rm_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    // deleteBook 的尾活会经 path_provider 找有声书持久目录；测试里没有插件实现
    // 会抛 MissingPluginException，把同一个 try 里后面的解压目录清理一起带掉。
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => p.join(root.path, call.method),
        );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _FakeAdapter(),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('在库态按钮是「移出」；确认后书、下载目录、章节状态一起删，页面退回未入库', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    late String bookKey;
    late String bookUid;
    late String extractDir;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      bookUid = row.uid;
      extractDir = row.extractDir;
      await _writeDownloadedChapter(row.extractDir, '/chapter/1');
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/1',
        lastPage: 3,
        readAt: 1,
      );
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      // 删前先确认「已下载」状态位真的渲染出来了，删后的 findsNothing 才有意义。
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );
    });
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      findsOneWidget,
    );
    expect(await db.getMangaChapterStates(bookUid), isNotEmpty);
    expect(
      find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsNothing,
      reason: '在库态不再显示「加入」',
    );

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      // 与书架长按删除同一个确认框：披露 + 「删除」。
      await _pumpUntil(tester, find.text(t.dialog_delete));
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });

    expect(await db.getEpubBook(bookKey), isNull, reason: 'DB 行已删');
    expect(
      await db.getMangaChapterStates(bookUid),
      isEmpty,
      reason: '章节状态随书级联删',
    );
    expect(
      Directory(extractDir).existsSync(),
      isFalse,
      reason: '解压目录（含已下载章节）已删',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsOneWidget,
      reason: '页面退回未入库态，可再次加入',
    );
    // 章节列表还在：条目本身没丢，只是不在库了。
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      findsNothing,
      reason: '下载状态位随删除清空',
    );
  });

  testWidgets('确认框点取消：什么都不删', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await _pumpUntil(tester, find.text(t.dialog_cancel));
      await tester.tap(find.text(t.dialog_cancel));
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(await db.getEpubBook(bookKey), isNotNull);
    expect(
      find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
      findsOneWidget,
    );
  });
}
