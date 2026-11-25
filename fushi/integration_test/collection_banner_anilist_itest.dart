import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/metadata/book_art_scrape_service.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/shelf_collection_open_request.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart'
    show BookArtDecision;
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// AniList 横幅回落的真 app 复测（真网络：MangaBaka / AniList / Bangumi）。
///
/// 《ブルーピリオド》：MangaBaka 系列 2238 没有横幅、记着 AniList 107237（有横幅）；
/// Bangumi 系列条目 217833。
/// 1. 合集详情页焦点驱动「获取各卷封面与横幅」→ MangaBaka 匹配 → 横幅按 AniList id 取，
///    hero 背景带换成它；
/// 2. 清掉后钉死 Bangumi 系列重跑（Bangumi 没有横幅）→ 横幅按 AniList 名字搜、唯一严格
///    同名条目取；
/// 3. 对照：《ホリミヤ》MangaBaka 自己有横幅，不走 AniList。
const String _title = 'ブルーピリオド';
const String _author = '山口つばさ';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('合集横幅：MangaBaka 没有时回落 AniList（id 直取 / Bangumi 后按名搜）', (
    WidgetTester tester,
  ) async {
    UpdateChecker.disableAutoCheckForTesting = true;
    // app 启动会换掉 FlutterError.onError；不还原的话任何 expect 失败都卡死在
    // tearDown（报不出真实失败）。与 bluray_disc_menu_itest 同一范式。
    final FlutterExceptionHandler? errorHandler = FlutterError.onError;
    addTearDown(() => FlutterError.onError = errorHandler);
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    FlutterError.onError = errorHandler;
    await readyAppModel(tester);
    // Tab 遍历前置条件（BUG-1106）：不开焦点导航，合成 Tab 一步都走不动。
    final AppModel appModel = await enableFocusNavigation(tester);
    final FushiDatabase db = appModel.database;

    Future<String> seed(String key, String title, String author) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: title,
          epubPath: '/nonexistent/$key.cbz',
          extractDir: '/nonexistent/$key',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
          author: Value<String?>(author),
          format: const Value<String>('manga'),
        ),
      );
      return (await db.resolveEpubBookUid(key))!;
    }

    // 每跑一次用新键：同一 RunId 的隔离根会复用，旧库里已有的书键会撞 UNIQUE。
    final int run = DateTime.now().millisecondsSinceEpoch;
    final List<String> keys = <String>['bp1_$run', 'bp2_$run', 'bp3_$run'];
    final int collectionId = await db.createMediaCollection(_title);
    for (int i = 0; i < keys.length; i++) {
      final String uid = await seed(keys[i], '$_title ${i + 1}', _author);
      await db.addToCollection(collectionId, MediaKind.epub, uid);
    }
    final BookArtStore store = BookArtStore.of(appModel.thumbnailsDirectory);

    Future<bool> pumpUntil(bool Function() done, int seconds) async {
      for (int i = 0; i < seconds * 4; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (done()) return true;
      }
      return false;
    }

    // ── 打开合集详情页（与首页 / 追踪卡同一出口：切漫画库 tab + 打开请求）──
    HomePage.debugSelectTab!(HomeTab.manga);
    await tester.pump(const Duration(seconds: 2));
    requestShelfCollectionOpen(collectionId: collectionId, manga: true);
    final Finder detail = find.byType(MediaCollectionGridDetailPage);
    expect(await pumpUntil(() => detail.evaluate().isNotEmpty, 30), isTrue);
    final Finder scrapeButton = find.byKey(
      const ValueKey<String>('collection_detail_art_scrape'),
    );
    expect(
      await pumpUntil(() => scrapeButton.evaluate().isNotEmpty, 20),
      isTrue,
    );
    await captureFlutterFrame(tester, '01-before');

    // ── 1. 焦点驱动按「获取各卷封面与横幅」（Enter）──
    final FocusDriver driver = FocusDriver(tester);
    expect(await driver.focusWidget(scrapeButton), isTrue);
    await driver.activate();
    final Finder summary = find.byKey(
      const ValueKey<String>('collection_art_scrape_summary'),
    );
    expect(
      await pumpUntil(() => summary.evaluate().isNotEmpty, 120),
      isTrue,
      reason: '结果面板应在 120s 内出现（真网络）',
    );
    await tester.pump(const Duration(seconds: 1));
    await captureFlutterFrame(tester, '02-result-dialog');
    final BookArtRecord? r1 = store.recordFor(keys.first);
    debugPrint(
      '[banner-itest] run1 source=${r1?.source} series=${r1?.seriesId} '
      'banner=${r1?.bannerKey} ${r1?.bannerWidth}x${r1?.bannerHeight} '
      'url=${r1?.bannerUrl} cover=${r1?.coverSource}',
    );
    expect(r1?.source, BookArtSource.mangabaka.wire);
    expect(r1?.seriesId, '2238');
    expect(r1?.bannerKey, 'anilist_107237');
    expect(r1?.bannerUrl, contains('anilist.co'));
    expect((r1?.bannerWidth ?? 0) > (r1?.bannerHeight ?? 0) * 1.6, isTrue);
    expect(File(store.bannerPathFor('anilist_107237')).existsSync(), isTrue);

    await driver.back(); // 关结果面板
    expect(await pumpUntil(() => summary.evaluate().isEmpty, 10), isTrue);
    await tester.pump(const Duration(seconds: 2));
    final ObserveShot hero1 = await captureFlutterFrame(
      tester,
      '03-hero-anilist',
    );
    expect(hero1.nonBlank, isTrue);

    // ── 2. 清掉，钉死 Bangumi 系列重跑：横幅只能从 AniList 按名搜到 ──
    for (final String k in keys) {
      await store.remove(k);
    }
    expect(store.backdropForCollection(keys), isNull);
    final String groupKey = parseBookSeriesKey('$_title 1')!.key;
    final BookArtScrapeService svc = BookArtScrapeService(
      database: db,
      store: store,
    );
    final BookArtRunResult run2;
    try {
      run2 =
          await tester.runAsync(
                () => svc.run(
                  keys,
                  pins: <String, BookArtSeriesPin>{
                    groupKey: const BookArtSeriesPin(
                      source: BookArtSource.bangumi,
                      id: '217833',
                    ),
                  },
                  recordUndo: false,
                ),
              )
              as BookArtRunResult;
    } finally {
      svc.close();
    }
    final BookArtSeriesPlan plan2 = run2.series.single;
    final BookArtRecord? r2 = store.recordFor(keys.first);
    debugPrint(
      '[banner-itest] run2 source=${plan2.source} series=${plan2.seriesId} '
      'banner=${plan2.banner?.source} key=${r2?.bannerKey} '
      'written=${run2.count(BookArtBookOutcome.written)} errors=${plan2.errors}',
    );
    expect(plan2.source, BookArtSource.bangumi);
    expect(plan2.banner?.source, BookArtSource.anilist);
    expect(r2?.bannerKey, 'anilist_107237');
    await tester.pump(const Duration(seconds: 2));
    final ObserveShot hero2 = await captureFlutterFrame(
      tester,
      '04-hero-bangumi',
    );
    expect(hero2.nonBlank, isTrue);

    // ── 3. 对照：MangaBaka 自己有横幅时不走 AniList ──
    final List<String> hori = <String>['hm1_$run', 'hm2_$run'];
    for (int i = 0; i < hori.length; i++) {
      await seed(hori[i], 'ホリミヤ ${i + 1}', 'HERO');
    }
    final BookArtScrapeService svc3 = BookArtScrapeService(
      database: db,
      store: store,
    );
    final BookArtRunResult run3;
    try {
      run3 =
          await tester.runAsync(() => svc3.run(hori, recordUndo: false))
              as BookArtRunResult;
    } finally {
      svc3.close();
    }
    final BookArtSeriesPlan plan3 = run3.series.single;
    debugPrint(
      '[banner-itest] run3 decision=${plan3.decision} source=${plan3.source} '
      'series=${plan3.seriesId} banner=${plan3.banner?.source} '
      'key=${store.recordFor(hori.first)?.bannerKey} errors=${plan3.errors}',
    );
    if (plan3.decision == BookArtDecision.accepted) {
      expect(plan3.banner?.source, BookArtSource.mangabaka);
      expect(store.recordFor(hori.first)?.bannerKey, startsWith('mangabaka_'));
    } else {
      // 双语书名只到待确认：不写，自然也没有横幅（与 AniList 无关）。
      expect(store.recordFor(hori.first)?.bannerKey, isNull);
    }
  });
}
