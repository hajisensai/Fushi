import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transparent_image/transparent_image.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
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
    MediaCollectionRow collection,
  ) async {
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
}
