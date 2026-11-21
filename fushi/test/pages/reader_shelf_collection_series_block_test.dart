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

/// 书架 / 漫画库色块布局下的合集卡（2026-11-16 所有者拍板）：合集有刮削资料
/// （CollectionScrapeMeta）或横版背景图时，与视频库系列卡同一个系列色块
/// （[FushiCoverBlockArt.portrait] + 背景图 + 概览「类型 · ★ 评分」+ chip「年份 ·
/// N 卷」）；都没有时保持书封扇形（[FushiCoverBlockArt.book]）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_shelf_cards_pp',
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

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_shelf_cards');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
    epubItems = <MediaItem>[];
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> seedEpub(String bookKey, String title) async {
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
  }

  /// 「Alpha」（散）/「M 系列」{Zeta 1, Zeta 2} /「Omega」（散）。名称排序下合集
  /// 应夹在两本散书中间。返回合集 id。
  Future<int> seedLibrary() async {
    await seedEpub('alphaKey', 'Alpha');
    await seedEpub('zeta1Key', 'Zeta 1');
    await seedEpub('zeta2Key', 'Zeta 2');
    await seedEpub('omegaKey', 'Omega');
    final int cid = await db.createMediaCollection('M Series');
    for (final String key in <String>['zeta1Key', 'zeta2Key']) {
      await db.addToCollection(
        cid,
        MediaKind.epub,
        (await db.resolveEpubBookUid(key))!,
      );
    }
    await prefs.setShelfSortModeName('title');
    return cid;
  }

  Widget buildApp({Set<int> selectedTags = const <int>{}}) => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(epubItems),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
      selectedTagIdsProvider.overrideWith((ref) => selectedTags),
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

  Future<void> pumpPage(
    WidgetTester tester, {
    Set<int> selectedTags = const <int>{},
  }) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(selectedTags: selectedTags));
    await tester.pumpAndSettle();
  }

  Finder collectionCard(int cid) =>
      find.byKey(ValueKey<String>('reader_shelf_collection_card_$cid'));

  FushiCoverBlock collectionBlock(WidgetTester tester, int cid) =>
      tester.widget<FushiCoverBlock>(
        find.descendant(
          of: collectionCard(cid),
          matching: find.byType(FushiCoverBlock),
        ),
      );

  testWidgets('有刮削资料 + 背景图的合集：画系列色块（竖版 + 背景图 + 概览 / chip）', (
    WidgetTester tester,
  ) async {
    final int cid = await seedLibrary();
    await db.upsertCollectionScrapeMeta(
      CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(cid),
        source: 'anilist',
        subjectId: '1',
        title: 'M Series',
        airDate: const Value<String?>('2014-04-01'),
        rating: const Value<double?>(8.8),
        tagsJson: const Value<String?>(
          '[{"name":"日常","count":9},{"name":"喜剧","count":5},'
          '{"name":"校园","count":1}]',
        ),
        scrapedAt: DateTime(2026, 11, 16),
      ),
    );
    final File backdrop = File('${storeDir.path}/${cid}_backdrop.png')
      ..writeAsBytesSync(kTransparentImage);
    await db.replaceMediaImagesForCollection(cid, <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        collectionId: Value<int?>(cid),
        kind: MediaImageKind.backdrop.dbValue,
        path: backdrop.path,
      ),
    ]);
    await pumpPage(tester);
    // 背景图存在性在 [_loadShelfMaps] 里走真实文件 IO（fakeAsync 外完成），放它
    // 跑完再重建。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(collectionCard(cid), findsOneWidget);
    final FushiCoverBlock block = collectionBlock(tester, cid);
    expect(block.art, FushiCoverBlockArt.portrait);
    expect(block.backdrop, isNotNull);
    expect(block.overview, '日常 / 喜剧 · ★ 8.8');
    expect(block.chip, contains('2014'));
    expect(block.chip, contains(t.shelf_collection_volume_count(n: 2)));
    // 成员封面照常进 covers（首个 = 最前那本，余下是叠层）。
    expect(block.covers, hasLength(2));
    // 色块按封面取色（图片加载挂 10 秒超时），fakeAsync 里走完超时再结束。
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('没有刮削资料也没有背景图的合集：保持书封摆法', (WidgetTester tester) async {
    final int cid = await seedLibrary();
    await pumpPage(tester);
    // 背景图存在性在 [_loadShelfMaps] 里走真实文件 IO（fakeAsync 外完成），放它
    // 跑完再重建。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    final FushiCoverBlock block = collectionBlock(tester, cid);
    expect(block.art, FushiCoverBlockArt.book);
    expect(block.backdrop, isNull);
    expect(block.overview, isNull);
    expect(block.chip, isNull);
    await tester.pump(const Duration(seconds: 11));
  });
}
