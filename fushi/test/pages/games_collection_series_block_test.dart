import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellContentLayout;
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

import '../helpers/shell_layout.dart';
import '../helpers/test_platform_services.dart';

/// 游戏库系列色块（2026-11-16 所有者「都接上啊横屏海报都得用」）：
/// - 游戏合集有刮削资料（CollectionScrapeMeta）时，合集色块卡与书架合集卡同一个
///   系列色块（[FushiCoverBlockArt.portrait] + 概览 / chip「年份 · N 作」）；
/// - 单个游戏的系列元数据吃 `item_images` 背景图 / 艺术字与 `item_scrape_meta`
///   （只补游戏自己合并资料里缺的项）。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  GalgameEntry entry(
    String id,
    String name, {
    String? releaseDate,
    GalgameMetadataDraft metadata = const GalgameMetadataDraft(),
  }) => GalgameEntry(
    id: id,
    name: name,
    exePath: 'Z:\\missing\\$id.exe',
    workdir: r'Z:\missing',
    addedAt: DateTime(2026),
    releaseDate: releaseDate,
    metadata: metadata,
  );

  ItemScrapeMetaRow itemScrape({
    String? airDate,
    double? rating,
    String? tagsJson,
  }) => ItemScrapeMetaRow(
    mediaType: MediaKind.game.dbValue,
    entryKey: 'g',
    source: 'vndb',
    airDate: airDate,
    rating: rating,
    tagsJson: tagsJson,
    scrapedAt: 1,
  );

  group('itemSeriesMeta', () {
    test('概览 = 标签前两个 · ★ 评分；chip = 年份', () {
      final FushiSeriesMeta? meta = itemSeriesMeta(
        scrape: itemScrape(
          airDate: '2019-07-01',
          rating: 7.6,
          tagsJson: '[{"name":"奇幻"},{"name":"冒险"},{"name":"轻小说"}]',
        ),
        backdrop: null,
      );
      expect(meta, isNotNull);
      expect(meta!.overview, '奇幻 / 冒险 · ★ 7.6');
      expect(meta.chip, '2019');
    });

    test('没有资料行也没有背景图 → null', () {
      expect(itemSeriesMeta(scrape: null, backdrop: null), isNull);
    });

    test('只有背景图也算：概览 / chip 为空', () {
      final FushiSeriesMeta? meta = itemSeriesMeta(
        scrape: null,
        backdrop: MemoryImage(Uint8List(1)),
      );
      expect(meta, isNotNull);
      expect(meta!.backdrop, isNotNull);
      expect(meta.overview, isNull);
      expect(meta.chip, isNull);
    });
  });

  group('galgameSeriesMeta 叠单本刮削数据', () {
    test('合并资料没有标签 / 评分时，只有背景图也非 null 并带背景图', () {
      final FushiSeriesMeta? meta = galgameSeriesMeta(
        entry('g', 'G'),
        backdrop: MemoryImage(Uint8List(1)),
      );
      expect(meta, isNotNull);
      expect(meta!.backdrop, isNotNull);
      expect(meta.overview, isNull);
    });

    test('item_scrape_meta 只补缺项，不覆盖游戏自己的合并资料', () {
      final FushiSeriesMeta? filled = galgameSeriesMeta(
        entry('g', 'G'),
        scrape: itemScrape(
          airDate: '2004-01-30',
          rating: 8.1,
          tagsJson: '[{"name":"纯爱"},{"name":"校园"}]',
        ),
      );
      expect(filled!.overview, '纯爱 / 校园 · ★ 8.1');
      expect(filled.chip, '2004');

      final FushiSeriesMeta? own = galgameSeriesMeta(
        entry(
          'g',
          'G',
          releaseDate: '2010-05-01',
          metadata: const GalgameMetadataDraft(
            tags: <String>['奇幻'],
            score: 9.0,
          ),
        ),
        scrape: itemScrape(
          airDate: '2004-01-30',
          rating: 8.1,
          tagsJson: '[{"name":"纯爱"}]',
        ),
      );
      expect(own!.overview, '奇幻 · ★ 9.0');
      expect(own.chip, '2010');
    });
  });

  testWidgets('GameItemScrapeArt.load：按游戏分桶、只认文件还在的背景图', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final Directory dir = Directory.systemTemp.createTempSync('fushi_game_art');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final File backdrop = File('${dir.path}/b.png')..writeAsBytesSync(<int>[0]);
    await db.replaceItemImagesOfKind(
      mediaType: MediaKind.game,
      entryKey: 'g1',
      kind: MediaImageKind.backdrop,
      images: <({String path, String? sourceUrl})>[
        (path: '${dir.path}/gone.png', sourceUrl: null),
        (path: backdrop.path, sourceUrl: null),
      ],
    );
    final GameItemScrapeArt art = (await tester.runAsync(
      () => GameItemScrapeArt.load(db),
    ))!;
    expect(art.backdropPathById, <String, String>{'g1': backdrop.path});
    final FushiSeriesMeta? meta = art.seriesOf(entry('g1', 'G'));
    expect(meta?.backdrop, isNotNull);
    expect(art.seriesOf(entry('g2', 'H')), isNull);
  });

  testWidgets('有刮削资料的游戏合集：色块画系列色块（竖版 + 概览 / chip）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir = Directory.systemTemp.createTempSync(
      'fushi_game_series_block_',
    );
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tmpDir,
      )
      ..wireDatabaseForTesting(db);
    await appModel.setGalgames(<GalgameEntry>[
      entry('g1', 'ATRI'),
      entry('g2', 'ATRI FD'),
      entry('g3', 'Solo'),
    ]);
    final int cid = await db.createMediaCollection('ATRI 系列');
    await db.addToCollection(cid, MediaKind.game, 'g1');
    await db.addToCollection(cid, MediaKind.game, 'g2');
    await db.upsertCollectionScrapeMeta(
      CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(cid),
        source: 'vndb',
        subjectId: '1',
        title: 'ATRI',
        airDate: const Value<String?>('2020-06-12'),
        rating: const Value<double?>(8.2),
        tagsJson: const Value<String?>(
          '[{"name":"科幻","count":9},{"name":"纯爱","count":5}]',
        ),
        scrapedAt: DateTime(2026, 11, 16),
      ),
    );

    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            theme: shellLayoutTheme(ShellContentLayout.collage),
            home: const FushiFocusRoot(
              child: Scaffold(body: GamesLibraryPage()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      ValueKey<String>('games_collection_card_$cid'),
    );
    expect(card, findsOneWidget);
    final FushiCoverBlock block = tester.widget<FushiCoverBlock>(
      find.descendant(of: card, matching: find.byType(FushiCoverBlock)),
    );
    expect(block.art, FushiCoverBlockArt.portrait);
    expect(block.overview, '科幻 / 纯爱 · ★ 8.2');
    expect(block.chip, '2020 · ${t.game_collection_work_count(n: 2)}');
    await tester.pump(const Duration(seconds: 11));
  });
}
