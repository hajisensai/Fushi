import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transparent_image/transparent_image.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_art_scrape.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';

/// 合集详情页头部（重设计外壳，2026-11-16 所有者「封面显示位置有问题」「合集样式
/// 都改成这种」）：所有合集都是同一个海报 hero（[MediaPosterDetailHero]）——横版
/// 背景带（合集附加图组里 position 最小且文件还在的那张；没有就封面模糊垫底）与
/// 斜放封面在同一块里，标题下「共 N 项」、类型 / 评分 / 年份胶囊、简介，「编辑
/// 标签」在 hero 的动作行；不再有上下分开的信息卡 + 系列横幅。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpDetail(
    WidgetTester tester,
    FushiDatabase db,
    MediaCollectionRow collection, {
    CollectionArtScrape? artScrape,
  }) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionGridDetailPage(
            database: db,
            collection: collection,
            memberCardBuilder:
                (
                  String mediaType,
                  String entryKey, {
                  VoidCallback? onRemoveFromCollection,
                }) => Text(entryKey),
            onChanged: () {},
            artScrape: artScrape,
          ),
        ),
      ),
    );
    // `_reload` 里背景图存在性走真实文件 IO，fakeAsync 里不会完成（加载转圈
    // 一直转，pumpAndSettle 等不到头）：交替推进假时钟（drift 查询）与真实
    // 异步（文件探测），直到合集信息块出现（加载完成）再收尾。
    final Finder hero = find.byKey(
      const ValueKey<String>('collection_detail_poster_hero'),
    );
    for (int i = 0; i < 50 && hero.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pumpAndSettle();
  }

  testWidgets('有背景图 + 刮削资料：背景带 / 封面 / 胶囊 / 简介在同一个海报 hero 里', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final Directory dir = Directory.systemTemp.createTempSync(
      'fushi_detail_banner',
    );
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final int cid = await db.createMediaCollection('M Series');
    await db.addToCollection(cid, MediaKind.epub, 'u1');
    await db.upsertCollectionScrapeMeta(
      CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(cid),
        source: 'bangumi',
        subjectId: '1',
        title: 'M Series',
        summary: const Value<String?>('一段刮削简介。'),
        airDate: const Value<String?>('2014-04-01'),
        rating: const Value<double?>(8.8),
        tagsJson: const Value<String?>(
          '[{"name":"日常","count":9},{"name":"喜剧","count":5}]',
        ),
        scrapedAt: DateTime(2026, 11, 16),
      ),
    );
    final File backdrop = File('${dir.path}/backdrop.png')
      ..writeAsBytesSync(kTransparentImage);
    await db.replaceMediaImagesForCollection(cid, <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        collectionId: Value<int?>(cid),
        kind: MediaImageKind.backdrop.dbValue,
        path: '${dir.path}/gone.png',
      ),
      MediaImagesCompanion.insert(
        collectionId: Value<int?>(cid),
        kind: MediaImageKind.backdrop.dbValue,
        position: const Value<int>(1),
        path: backdrop.path,
      ),
    ]);
    final MediaCollectionRow collection = (await db.getMediaCollectionById(
      cid,
    ))!;
    await pumpDetail(tester, db, collection);

    final Finder heroKey = find.byKey(
      const ValueKey<String>('collection_detail_poster_hero'),
    );
    expect(heroKey, findsOneWidget);
    final Finder hero = find.descendant(
      of: heroKey,
      matching: find.byType(MediaPosterDetailHero),
    );
    expect(hero, findsOneWidget);
    // 首张（position 0）文件不在，退到下一张还在的。
    final ImageProvider? art = tester
        .widget<MediaPosterDetailHero>(hero)
        .backdrop;
    expect(art, isA<ResizeImage>());
    final ImageProvider inner = (art! as ResizeImage).imageProvider;
    expect((inner as FileImage).file.path, backdrop.path);
    // 背景带与封面在同一个 hero 里。
    for (final String key in <String>[
      'collection-hero-backdrop',
      'collection_detail_header_cover',
      'collection_detail_hero_meta',
      'collection_detail_edit_tags',
    ]) {
      expect(
        find.descendant(
          of: heroKey,
          matching: find.byKey(ValueKey<String>(key)),
        ),
        findsOneWidget,
        reason: key,
      );
    }
    expect(find.text(t.collection_detail_kicker), findsOneWidget);
    expect(find.text('★ 8.8'), findsOneWidget);
    expect(find.text('2014'), findsOneWidget);
    expect(find.text('日常'), findsOneWidget);
    expect(find.text('喜剧'), findsOneWidget);
    expect(find.textContaining('一段刮削简介。'), findsWidgets);
    // 旧的分开两块已退役。
    expect(
      find.byKey(const ValueKey<String>('collection_detail_scrape_banner')),
      findsNothing,
    );
  });

  testWidgets('没有刮削资料也没有背景图：同一个海报 hero，只是没有背景图 / 资料胶囊', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int cid = await db.createMediaCollection('Plain');
    await db.addToCollection(cid, MediaKind.epub, 'u1');
    final MediaCollectionRow collection = (await db.getMediaCollectionById(
      cid,
    ))!;
    await pumpDetail(tester, db, collection);

    final Finder heroKey = find.byKey(
      const ValueKey<String>('collection_detail_poster_hero'),
    );
    expect(heroKey, findsOneWidget);
    final MediaPosterDetailHero hero = tester.widget<MediaPosterDetailHero>(
      find.descendant(
        of: heroKey,
        matching: find.byType(MediaPosterDetailHero),
      ),
    );
    expect(hero.backdrop, isNull);
    expect(hero.summary, isNull);
    expect(hero.pills, isEmpty);
    expect(
      find.descendant(
        of: heroKey,
        matching: find.byKey(
          const ValueKey<String>('collection_detail_edit_tags'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('collection_detail_series_rating')),
      findsNothing,
    );
  });

  group('「获取各卷封面与横幅」下到的系列横幅接 hero 背景带（pr3467 拍板 a）', () {
    late Directory thumbs;

    setUp(() {
      BookArtStore.resetForTesting();
      thumbs = Directory.systemTemp.createTempSync('fushi_detail_art_banner');
    });
    tearDown(() {
      BookArtStore.resetForTesting();
      try {
        thumbs.deleteSync(recursive: true);
      } catch (_) {}
    });

    CollectionArtScrape artFor(FushiDatabase db) => CollectionArtScrape(
      database: db,
      thumbnailsDirectory: thumbs,
      // 门关着也照样显示：横幅已在本地，门只管联网动作的入口。
      servicesEnabled: () => false,
      migrationReadonly: () => false,
    );

    BookArtRecord recordFor(String bookKey, String? bannerKey) => BookArtRecord(
      bookKey: bookKey,
      source: 'mangabaka',
      seriesId: '42',
      seriesTitle: 'S',
      coverSource: 'mangabaka',
      coverUrl: 'https://images.example/$bookKey',
      bannerKey: bannerKey,
      scrapedAt: 1,
    );

    ImageProvider? heroBackdrop(WidgetTester tester) => tester
        .widget<MediaPosterDetailHero>(
          find.descendant(
            of: find.byKey(
              const ValueKey<String>('collection_detail_poster_hero'),
            ),
            matching: find.byType(MediaPosterDetailHero),
          ),
        )
        .backdrop;

    String? backdropPath(ImageProvider? image) => image == null
        ? null
        : ((image as ResizeImage).imageProvider as FileImage).file.path;

    /// 刮削层变更后页面按成员重算横幅（成员 uid → bookKey 走 drift 查询）：
    /// 交替推进假时钟与真实异步，直到背景带变成 [expected]。
    Future<void> settleBackdrop(WidgetTester tester, String? expected) async {
      for (int i = 0; i < 50; i++) {
        if (backdropPath(heroBackdrop(tester)) == expected) return;
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
    }

    Future<void> seedBook(FushiDatabase db, String bookKey, String uid) =>
        db.insertEpubBook(
          EpubBooksCompanion.insert(
            bookKey: bookKey,
            uid: Value<String>(uid),
            title: bookKey,
            epubPath: '/x/$bookKey.cbz',
            extractDir: '/x/$bookKey',
            chapterCount: 1,
            chaptersJson: '[]',
            importedAt: 1000,
          ),
        );

    // 成员行存书 uid（v83），刮削层按 bookKey 记（BUG-5373：曾直接拿 uid 查刮削层）。
    testWidgets('取到横幅后 hero 背景带即时换成它；清除后退回无背景', (WidgetTester tester) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await seedBook(db, 'k1', 'u1');
      await seedBook(db, 'k2', 'u2');
      final int cid = await db.createMediaCollection('Banner Series');
      await db.addToCollection(cid, MediaKind.epub, 'u1');
      await db.addToCollection(cid, MediaKind.epub, 'u2');
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        cid,
      ))!;
      final CollectionArtScrape art = artFor(db);
      await pumpDetail(tester, db, collection, artScrape: art);
      expect(heroBackdrop(tester), isNull);

      // 模拟一次刮削：先写横幅，再写两卷的记录（与刮削服务同一顺序）。
      await tester.runAsync(() async {
        await art.store.writeBanner('mangabaka_42', kTransparentImage);
        await art.store.write(record: recordFor('k1', 'mangabaka_42'));
        await art.store.write(record: recordFor('k2', 'mangabaka_42'));
      });
      final String bannerPath = art.store.bannerPathFor('mangabaka_42');
      await settleBackdrop(tester, bannerPath);
      expect(backdropPath(heroBackdrop(tester)), bannerPath);

      // 清除（逐本 remove，回收孤儿横幅）后不再指向已删的文件。
      await tester.runAsync(() async {
        await art.store.remove('k1');
        await art.store.remove('k2');
      });
      await settleBackdrop(tester, null);
      expect(heroBackdrop(tester), isNull);
    });

    testWidgets('合集自己的背景图优先于下到的横幅', (WidgetTester tester) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await seedBook(db, 'k1', 'u1');
      final int cid = await db.createMediaCollection('Own Backdrop');
      await db.addToCollection(cid, MediaKind.epub, 'u1');
      final File own = File('${thumbs.path}/own.png')
        ..writeAsBytesSync(kTransparentImage);
      await db.replaceMediaImagesForCollection(cid, <MediaImagesCompanion>[
        MediaImagesCompanion.insert(
          collectionId: Value<int?>(cid),
          kind: MediaImageKind.backdrop.dbValue,
          path: own.path,
        ),
      ]);
      final CollectionArtScrape art = artFor(db);
      await tester.runAsync(() async {
        await art.store.writeBanner('mangabaka_42', kTransparentImage);
        await art.store.write(record: recordFor('k1', 'mangabaka_42'));
      });
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        cid,
      ))!;
      await pumpDetail(tester, db, collection, artScrape: art);
      expect(backdropPath(heroBackdrop(tester)), own.path);
    });
  });
}
