import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 作品页阶段 C（设计稿 2026-09-12 §1.3 / §2.3 / §5）：「下载全部」、「完成后自动
/// 识别」chip、「识别本章」、「识别全部已下载」、订阅 / 新章自动下载。
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

/// 内置 ONNX 引擎「模型全就绪」的假实现：让 `probeMangaOcrEngines` 判定 localOnnx
/// 可用。任务事件流由记录型注册表替换，这里的 `ocrFolder` 不会被调到。
class _FakeOcrService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
        detectorReady: true,
        recognizerReady: true,
        diskBytes: 1,
        totalBytes: 1,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<int> deleteModels() async => 0;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
}

class _EnqueueRecord {
  const _EnqueueRecord({
    required this.bookKey,
    required this.managedDirectory,
    required this.engine,
    required this.mangaJsonPath,
  });

  final String bookKey;
  final String managedDirectory;
  final MangaOcrEngineId engine;
  final String mangaJsonPath;
}

/// 记录 `enqueue` 的参数；真正排进去的任务换成空事件流（立即结束），不跑真 OCR。
class _RecordingRegistry extends MangaOcrJobRegistry {
  final List<_EnqueueRecord> records = <_EnqueueRecord>[];

  @override
  Future<MangaOcrRunningJob> enqueue({
    required MangaOcrBackgroundJob job,
    required String mangaJsonPath,
  }) {
    records.add(_EnqueueRecord(
      bookKey: job.bookKey,
      managedDirectory: job.managedDirectory,
      engine: job.engine,
      mangaJsonPath: mangaJsonPath,
    ));
    return super.enqueue(
      job: MangaOcrBackgroundJob(
        bookKey: job.bookKey,
        managedDirectory: job.managedDirectory,
        engine: job.engine,
        events: const Stream<MangaOcrBackgroundEvent>.empty(),
      ),
      mangaJsonPath: mangaJsonPath,
    );
  }
}

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library, Directory root)
      : super(testPlatformServices()) {
    // 真 PreferencesRepository 挂在同一个内存 DB 上：chip 的写穿要能在
    // `preferences` 表里查到。
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
  ) =>
      _library;

  /// 出厂默认是 Google Lens（要过上传同意闸门）；这里钉成内置引擎走无交互路径。
  @override
  String get mangaOcrEnginePreference => MangaOcrEnginePreference.localOnnx.key;

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

Widget _harness(
  AppModel appModel,
  String bookKey, {
  required MangaOcrJobRegistry registry,
}) =>
    ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((ref) => appModel),
        mangaOcrJobRegistryProvider.overrideWithValue(registry),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: MangaSeriesPage(
            target: ShelfMangaSeriesTarget(bookKey),
            ocrEnginesOverride: MangaOcrWizardEngines(
              service: _FakeOcrService(),
              initialEnginePreference: 'local_onnx',
              initialLensLanguage: 'ja',
              lensLanguageSetter: (_) async {},
            ),
          ),
        ),
      ),
    );

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/3',
    name: 'Chapter 3',
    number: 3,
    raw: <String, Object?>{'url': '/chapter/3'},
  ),
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

/// 造一章「已下载」：页图 + manga.json。[withBlocks] = 这章已经识别过（blocks 非空）。
Future<void> _writeDownloadedChapter(
  String bookDir,
  String chapterKey, {
  bool withBlocks = false,
}) async {
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
          'blocks': <Object?>[
            if (withBlocks)
              <String, Object?>{
                'box': <int>[0, 0, 10, 10],
                'vertical': false,
                'font_size': 12,
                'lines': <String>['x'],
              },
          ],
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

/// 等异步回调落地 + 推进动画时钟（弹出菜单的开合动画不推 duration 不会结束）。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 某一章行尾的溢出菜单按钮。
Finder _chapterMenu(String chapterName) => find.descendant(
      of: find.ancestor(
        of: find.text(chapterName),
        matching: find.byType(FushiListItem),
      ),
      matching: find.byType(FushiOverflowMenu<String>),
    );

void main() {
  late Directory root;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_series_phase_c_');
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

  void sizeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('下载全部：已下载的不入队、再点一次不重复', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    final _RecordingRegistry registry = _RecordingRegistry();

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await _writeDownloadedChapter(row.extractDir, '/chapter/1');
      await tester.pumpWidget(_harness(appModel, bookKey, registry: registry));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_download_all')),
      );
      await _settle(tester);
    });

    List<MangaDownloadJobRow> jobs = await db.listMangaDownloadJobs();
    expect(jobs, hasLength(2), reason: '三章里已下载的那章不入队');
    expect(
      jobs.map((MangaDownloadJobRow j) => j.chapterKey).toSet(),
      <String>{'/chapter/2', '/chapter/3'},
    );
    for (final MangaDownloadJobRow job in jobs) {
      expect(job.status, MangaDownloadJobStatus.queued);
      expect(job.autoOcr, isFalse, reason: '偏好默认 false');
    }

    await tester.runAsync(() async {
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_queued')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_download_all')),
      );
      await _settle(tester);
    });
    jobs = await db.listMangaDownloadJobs();
    expect(jobs, hasLength(2), reason: '已排队的章不重复入队');
  });

  testWidgets('自动识别 chip：写穿偏好表，随后入队的章 autoOcr=true',
      (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    final _RecordingRegistry registry = _RecordingRegistry();

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await tester.pumpWidget(_harness(appModel, bookKey, registry: registry));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_auto_ocr_chip')),
      );
      expect(appModel.mangaDownloadAutoOcr, isFalse);

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_auto_ocr_chip')),
      );
      await _settle(tester);
    });

    expect(appModel.mangaDownloadAutoOcr, isTrue);
    final String? raw = await db.getPref('manga_download_auto_ocr');
    expect(raw, isNotNull, reason: '偏好必须写穿到 preferences 表，不是只改内存');
    expect(PrefCodec.decode(raw!, false), isTrue);

    await tester.runAsync(() async {
      await tester.tap(find.text('Chapter 1'));
      await _settle(tester);
    });
    final MangaDownloadJobRow? job = await db.findMangaDownloadJob(
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: '/chapter/1',
    );
    expect(job, isNotNull);
    expect(job!.autoOcr, isTrue, reason: '单章入队读 chip 的持久值');
  });

  testWidgets('识别本章：已下载章的菜单里有该项，排一条 localOnnx 任务；未下载章没有',
      (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    final _RecordingRegistry registry = _RecordingRegistry();

    late String bookKey;
    late String bookDir;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      bookDir = row.extractDir;
      await _writeDownloadedChapter(bookDir, '/chapter/1');
      await tester.pumpWidget(_harness(appModel, bookKey, registry: registry));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );

      // 未下载章：菜单里没有「识别本章」。
      await tester.tap(_chapterMenu('Chapter 2'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('manga_chapter_ocr')),
        findsNothing,
      );
      // 关掉菜单。
      await tester.tapAt(const Offset(5, 5));
      await _settle(tester);

      await tester.tap(_chapterMenu('Chapter 1'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('manga_chapter_ocr')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('manga_chapter_ocr')));
      await _settle(tester);
    });

    expect(registry.records, hasLength(1));
    final _EnqueueRecord record = registry.records.single;
    final Directory chapterDir = mangaChapterDirectory(bookDir, '/chapter/1');
    expect(record.bookKey, bookKey);
    expect(record.managedDirectory, chapterDir.path);
    expect(record.engine, MangaOcrEngineId.localOnnx);
    expect(record.mangaJsonPath, mangaChapterJsonFile(chapterDir).path);
  });

  testWidgets('识别全部已下载：只排 blocks 全空的那章', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    final _RecordingRegistry registry = _RecordingRegistry();

    late String bookKey;
    late String bookDir;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      bookDir = row.extractDir;
      await _writeDownloadedChapter(bookDir, '/chapter/1', withBlocks: true);
      await _writeDownloadedChapter(bookDir, '/chapter/2');
      await tester.pumpWidget(_harness(appModel, bookKey, registry: registry));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
        findsNWidgets(2),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_ocr_all_downloaded')),
      );
      await _settle(tester);
    });

    expect(registry.records, hasLength(1), reason: '已识别过的章跳过');
    expect(
      registry.records.single.managedDirectory,
      mangaChapterDirectory(bookDir, '/chapter/2').path,
    );
    expect(registry.records.single.bookKey, bookKey);
  });

  testWidgets('订阅：书签开 → subscribed+autoDownload；菜单关自动下载；书签关两位都关',
      (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    final _RecordingRegistry registry = _RecordingRegistry();

    late String bookKey;
    Future<OnlineMangaLibraryEntry> persisted() async {
      final EpubBookRow row = (await db.getEpubBook(bookKey))!;
      return OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    }

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await tester.pumpWidget(_harness(appModel, bookKey, registry: registry));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_subscribe')),
      );
      expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga_series_more')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_subscribe')),
      );
      await _settle(tester);
    });

    OnlineMangaLibraryEntry entry = await persisted();
    expect(entry.subscribed, isTrue);
    expect(entry.autoDownload, isTrue, reason: '开订阅默认开自动下载');
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_series_more')),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>('manga_series_more')));
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_auto_download')),
      );
      await _settle(tester);
    });
    entry = await persisted();
    expect(entry.subscribed, isTrue);
    expect(entry.autoDownload, isFalse);

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_subscribe')),
      );
      await _settle(tester);
    });
    entry = await persisted();
    expect(entry.subscribed, isFalse);
    expect(entry.autoDownload, isFalse, reason: '关订阅把两位一起关');
    expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_series_more')),
      findsNothing,
    );
  });
}
