import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellContentLayout;
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';
import '../helpers/shell_layout.dart';

/// 书架 / 漫画库色块布局下的**单本**（2026-11-16 所有者「都接上啊横屏海报都得
/// 用」）：条目有自己的刮削资料（`item_scrape_meta`）或横版背景图
/// （`item_images`）时，与合集 / 视频库系列卡同一个系列色块
/// （[FushiCoverBlockArt.portrait] + 背景图 + 概览 / chip），书封当竖版海报；
/// 都没有时保持书封摆法（[FushiCoverBlockArt.book]）。走真实书架页
/// （[ReaderFushiHistoryPage] 的 `_loadShelfMaps` 批量预取 → `_bookCardLayout`
/// → `_shelfCoverBlock`）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_shelf_item_series_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late Directory storeDir;
  late List<MediaItem> epubItems;
  late List<SrtBook> srtBooks;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_shelf_item_series');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
    epubItems = <MediaItem>[];
    srtBooks = <SrtBook>[];
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<String> seedEpub(String bookKey, String title) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '${pathProviderDir.path}/$bookKey.epub',
        extractDir: pathProviderDir.path,
        chapterCount: 1,
        chaptersJson: '["a"]',
        importedAt: 0,
      ),
    );
    epubItems.add(
      MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
        title: title,
        mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
        mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      ),
    );
    return (await db.resolveEpubBookUid(bookKey))!;
  }

  Future<void> seedItemMeta(MediaKind kind, String entryKey) =>
      db.upsertItemScrapeMeta(
        ItemScrapeMetaCompanion.insert(
          mediaType: kind.dbValue,
          entryKey: entryKey,
          source: 'bangumi',
          title: const Value<String?>('x'),
          airDate: const Value<String?>('2019-07-01'),
          rating: const Value<double?>(7.6),
          tagsJson: const Value<String?>(
            '[{"name":"奇幻","count":9},{"name":"冒险","count":5},'
            '{"name":"轻小说","count":1}]',
          ),
          scrapedAt: 1,
        ),
      );

  Widget buildApp() => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(epubItems),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(srtBooks),
      ),
      selectedTagIdsProvider.overrideWith((ref) => const <int>{}),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: shellLayoutTheme(ShellContentLayout.collage),
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            remoteBookClientLoader: () async => null,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await prefs.setShelfSortModeName('title');
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    // 背景图存在性在 `_loadShelfMaps` 里走真实文件 IO（fakeAsync 外完成），放它
    // 跑完再重建。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  }

  FushiCoverBlock blockTitled(WidgetTester tester, String title) =>
      tester.widget<FushiCoverBlock>(
        find.byWidgetPredicate(
          (Widget w) => w is FushiCoverBlock && w.title == title,
        ),
      );

  testWidgets('单本有刮削资料 + 背景图：画系列色块（竖版书封 + 背景图 + 概览 / chip）', (
    WidgetTester tester,
  ) async {
    final String alphaUid = await seedEpub('alphaKey', 'Alpha');
    await seedEpub('omegaKey', 'Omega');
    await seedItemMeta(MediaKind.epub, alphaUid);
    final File backdrop = File('${storeDir.path}/alpha_backdrop.png')
      ..writeAsBytesSync(kTransparentImage);
    await db.replaceItemImagesOfKind(
      mediaType: MediaKind.epub,
      entryKey: alphaUid,
      kind: MediaImageKind.backdrop,
      images: <({String path, String? sourceUrl})>[
        (path: backdrop.path, sourceUrl: null),
      ],
    );
    await pumpPage(tester);

    final FushiCoverBlock alpha = blockTitled(tester, 'Alpha');
    expect(alpha.art, FushiCoverBlockArt.portrait);
    expect(alpha.backdrop, isNotNull);
    expect(alpha.overview, '奇幻 / 冒险 · ★ 7.6');
    expect(alpha.chip, '2019');
    // 书封照常进 covers（系列色块里斜放成竖版海报）。
    expect(alpha.covers, hasLength(1));

    // 没有任何单本刮削数据的书：保持书封摆法。
    final FushiCoverBlock omega = blockTitled(tester, 'Omega');
    expect(omega.art, FushiCoverBlockArt.book);
    expect(omega.backdrop, isNull);
    expect(omega.overview, isNull);
    expect(omega.chip, isNull);
    // 色块按封面取色（图片加载挂 10 秒超时），fakeAsync 里走完超时再结束。
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('背景图文件已不在：只有刮削资料也画系列色块，但不带背景图', (WidgetTester tester) async {
    final String alphaUid = await seedEpub('alphaKey', 'Alpha');
    await seedItemMeta(MediaKind.epub, alphaUid);
    await db.replaceItemImagesOfKind(
      mediaType: MediaKind.epub,
      entryKey: alphaUid,
      kind: MediaImageKind.backdrop,
      images: <({String path, String? sourceUrl})>[
        (path: '${storeDir.path}/gone.png', sourceUrl: null),
      ],
    );
    await pumpPage(tester);

    final FushiCoverBlock alpha = blockTitled(tester, 'Alpha');
    expect(alpha.art, FushiCoverBlockArt.portrait);
    expect(alpha.backdrop, isNull);
    expect(alpha.overview, '奇幻 / 冒险 · ★ 7.6');
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('字幕书：按 (srt, uid) 取单本刮削资料画系列色块', (WidgetTester tester) async {
    srtBooks.add(
      SrtBook()
        ..uid = 'srtbook_1'
        ..title = 'Sigma'
        ..srtPath = '${storeDir.path}/sigma.srt'
        ..importedAt = 0,
    );
    await seedItemMeta(MediaKind.srt, 'srtbook_1');
    await pumpPage(tester);

    final FushiCoverBlock sigma = blockTitled(tester, 'Sigma');
    expect(sigma.art, FushiCoverBlockArt.portrait);
    expect(sigma.overview, '奇幻 / 冒险 · ★ 7.6');
    expect(sigma.chip, '2019');
    await tester.pump(const Duration(seconds: 11));
  });
}
