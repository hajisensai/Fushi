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
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 在线书架条目在阅读器里的三条路（设计稿 2026-09-12 §5「阅读器」+ 2026-09-26
/// 补记）：当前章**已下载** → 章目录当本地卷装载、不打源；**未下载** → 在线直读
/// （不落章目录、不入队、不给 OCR 入口）；**直读失败** → 退回「本章未下载」态，
/// 入队按钮在、返回键在。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  int resolveCalls = 0;
  final List<int> fetchedPages = <int>[];

  /// 为真时像真源一样给页表和页图；为假时模拟源不可用。
  bool serve = false;

  static final Uint8List png = Uint8List.fromList(
    img.encodePng(img.Image(width: 60, height: 90)),
  );

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
  }) async {
    resolveCalls++;
    if (!serve) throw StateError('source unavailable');
    return <OnlineMangaPageRef>[
      for (int index = 0; index < 3; index++)
        HttpMangaPageRef(
          index: index,
          url: 'https://example.invalid${chapter.key}/$index.png',
          referer: 'https://example.invalid',
        ),
    ];
  }

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    if (!serve) throw StateError('source unavailable');
    fetchedPages.add(page.index);
    return png;
  }

  @override
  Future<List<int>> fetchCover(
          OnlineMangaLibraryEntry entry, String url) async =>
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

class _MangaTestAppModel extends AppModel {
  _MangaTestAppModel(this._db, this._library, this._temp)
      : super(testPlatformServices());

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final Directory _temp;

  /// 在线直读的页缓存根（`manga_stream_cache/`）落在这里。
  @override
  Directory get temporaryDirectory => _temp;

  @override
  FushiDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) =>
      _library;

  @override
  bool get lowMemoryMode => false;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  String get mangaSpreadPreference => 'auto';
  @override
  String get mangaReadingDirection => 'rtl';
  @override
  int get mangaZoomPercent => 100;
  @override
  int get mangaZoomSensitivity => kMangaZoomSensitivityDefault;
  @override
  String get mangaPageAnimation => MangaPageAnimation.slide.key;
  @override
  bool get mangaTapZonePaging => true;

  // 固定顶栏：测试默认要看得见栏里的按钮（悬浮态默认收起）。
  @override
  bool get mangaChromeFloating => false;
  @override
  bool get mangaVolumeKeyPaging => false;

  // 进入即整卷 OCR（_maybeStartVolumeOcr）开书就读这三项：测试里 prefsRepo 是
  // null，不覆写就在开书后抛 _TypeError。与 manga_fushi_page_test 同口径显式走
  // manual，免得 widget 测试去碰原生 OCR 后端。
  @override
  MangaReaderPreferences get mangaReaderPreferences =>
      const MangaReaderPreferences(ocrTrigger: 'manual');

  @override
  String get mangaOcrEnginePreference => 'local_onnx';

  @override
  String get mangaOcrLensLanguage => 'ja';
}

Widget _harness(AppModel appModel, String bookKey) => ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              child ?? const SizedBox.shrink(),
          home: MangaFushiPage(item: _item(bookKey), bookKey: bookKey),
        ),
      ),
    );

MediaItem _item(String bookKey) => MediaItem(
      mediaIdentifier: 'fushi://book/$bookKey',
      mediaSourceIdentifier: 'reader_manga',
      title: 'Test Manga',
      mediaTypeIdentifier: 'reader',
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
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
  await File(p.join(images.path, 'page-000002.jpg')).writeAsBytes(<int>[2]);
  await mangaChapterJsonFile(chapterDir).writeAsString(jsonEncode(
    <String, Object?>{
      'pages': <Map<String, Object?>>[
        <String, Object?>{
          'url': 'images/page-000001.jpg',
          'width': 100,
          'height': 150,
          'blocks': <Object?>[],
        },
        <String, Object?>{
          'url': 'images/page-000002.jpg',
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
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_reader_online_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _FakeAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('在线条目 + 当前章已下载 → 章目录当本地卷装载，正常渲染', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _MangaTestAppModel appModel =
        _MangaTestAppModel(db, library, root);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      // 新读者从最旧一话（列表末尾 = Chapter 1）开始。
      await _writeDownloadedChapter(row.extractDir, '/chapter/1');

      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('manga_content_ready')),
        findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsNothing,
    );
    expect(adapter.resolveCalls, 0, reason: '已下载的章不打源');
    // 章节选择器入口只有书架在线条目才有。
    final Finder chapters =
        find.byKey(const ValueKey<String>('manga_reader_chapters'));
    expect(chapters, findsOneWidget);
    // 章节按钮在左上，紧跟返回键（不在右侧动作组里；窄窗也不折进 ⋮）。
    final Rect back = tester
        .getRect(find.byKey(const ValueKey<String>('manga_reader_back_button')));
    expect(tester.getRect(chapters).left, closeTo(back.right, 1));
    // 点开是左侧侧栏，不是底部弹层。
    await tester.runAsync(() async {
      await tester.tap(chapters);
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_reader_chapter_drawer')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey<String>('manga_reader_chapter_drawer')),
        findsOneWidget);
    expect(
      tester
          .getRect(find.byKey(const ValueKey<String>('fushi_reader_side_sheet')))
          .left,
      0,
      reason: '章节目录从左侧打开',
    );
    expect(find.byType(BottomSheet), findsNothing);
    // 打开即记「选了这一章」。
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(
      OnlineMangaLibraryEntry.tryParse(after.sourceMetadata)!
          .currentChapter
          ?.key,
      '/chapter/1',
    );
  });

  testWidgets('在线条目 + 当前章未下载且直读失败 → 「本章未下载」态：入队按钮在、返回键在',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _MangaTestAppModel appModel =
        _MangaTestAppModel(db, library, root);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      );
    });
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('manga_content_ready')),
        findsNothing);
    expect(find.byKey(const ValueKey<String>('manga_reader_back_button')),
        findsOneWidget,
        reason: '出口不随内容存亡');
    expect(
      find.byKey(const ValueKey<String>('manga_reader_enqueue_download')),
      findsOneWidget,
    );
    expect(adapter.resolveCalls, 1, reason: '先试了在线直读，源不可用才退到这一态');

    // 点「下载」→ 任务表里出现 queued 行（worker 未启动，行停在 queued）。
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_reader_enqueue_download')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
    final MangaDownloadJobRow? job = await db.findMangaDownloadJob(
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: '/chapter/1',
    );
    expect(job, isNotNull);
    expect(job!.status, MangaDownloadJobStatus.queued);
  });

  testWidgets('在线条目 + 当前章未下载 → 在线直读：不入队、不落章目录、不给 OCR 入口',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    adapter.serve = true;
    final _MangaTestAppModel appModel =
        _MangaTestAppModel(db, library, root);

    late String bookKey;
    late String bookDir;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      bookDir = row.extractDir;
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('manga_content_ready')),
        findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsNothing,
    );
    expect(adapter.resolveCalls, 1);
    expect(adapter.fetchedPages, contains(0), reason: '落点页开书前先取');
    // 直读不产生下载：章目录判据仍是「未下载」，任务表空。真实文件 IO 必须在
    // runAsync 里跑，FakeAsync 区里 await 它会永远挂住。
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    final bool downloaded = (await tester.runAsync(
      () => isChapterDownloaded(after.extractDir, '/chapter/1'),
    ))!;
    expect(downloaded, isFalse);
    expect(
      Directory(p.join(bookDir, 'chapters')).existsSync()
          ? Directory(p.join(bookDir, 'chapters')).listSync()
          : const <FileSystemEntity>[],
      isEmpty,
      reason: '直读页只进临时缓存，不碰章下载目录',
    );
    expect(await db.listMangaDownloadJobs(), isEmpty);
    // 页缓存在 app 临时目录下。
    expect(
      Directory(p.join(root.path, 'manga_stream_cache')).existsSync(),
      isTrue,
    );
    // 开读即记「选了这一章」。
    expect(
      OnlineMangaLibraryEntry.tryParse(after.sourceMetadata)!
          .currentChapter
          ?.key,
      '/chapter/1',
    );
  });

  // 直读章在阅读器内不触发、不接回任何 OCR（设计稿 2026-09-12 §1.2 / §1.3 不变）。
  // 顶栏按钮在窄窗会折进溢出菜单、widget 层断言不稳，所以在源码层钉住每个入口的门。
  test('在线直读章：阅读器内每个 OCR 入口都过 _noChapterOcr 门', () {
    final String source = File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync();
    expect(
      source,
      contains(
          'bool get _noChapterOcr => _chapterNotDownloaded || _streamingChapter;'),
    );
    for (final String head in <String>[
      'bool get _showManualVolumeOcrAction =>',
      'bool get _showRerunVolumeOcrAction =>',
      'Future<void> _rerunVolumeOcr() async {',
      'void _syncVolumeOcrJob() {',
      'Future<void> _maybeStartVolumeOcr({bool userInitiated = false}) async {',
    ]) {
      final int start = source.indexOf(head);
      expect(start, isNonNegative, reason: head);
      expect(
        source.substring(start, start + 400),
        contains('_noChapterOcr'),
        reason: '$head 必须挡住在线直读章',
      );
    }
    // 装载尾部的缓存恢复 / 任务接回 / 进入即识别在直读时整段跳过。
    final int tail = source.indexOf('    if (streaming) return;');
    expect(tail, isNonNegative);
    final String rest = source.substring(tail, tail + 800);
    expect(rest, contains('_recoverIncrementalOcrCache('));
    expect(rest, contains('_maybeStartVolumeOcr()'));
  });
}
