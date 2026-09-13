import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// legacy cover scraper 已退出生产 UI：合集详情的管理菜单和集卡菜单都不得再
/// 暴露旧在线匹配/重刮入口（旧 TMDB 标题匹配 `showCollectionScrapeDialog`）。
///
/// 但「不得走 legacy」 ≠ 「合集不能重刮」：`1637876c64` 把 legacy 入口删掉时
/// **连带删光了合集语境下的一切重刮入口**，用户手上一个刮错的合集在库页和详情页
/// 都成了断头路（来源页的作用域是扫描根，替代不了「重刮这一个合集」）。所以本
/// 守卫是双向的：既钉死 legacy 不复活，也钉死 canonical 入口必须在场——只有否定
/// 断言的守卫，被人把功能整个删光时照样是绿的（BUG-2374）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (final (String uid, String title) in const <(String, String)>[
      ('video/e1', 'Show 01'),
      ('video/e2', 'Show 02'),
    ]) {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: Value(title),
          videoPath: Value('/v/$title.mkv'),
        ),
      );
    }
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e2');
  });

  tearDown(() => db.close());

  Future<List<VideoBookRow>> loadMembers() async {
    final List<MediaCollectionItemRow> items = await db.getCollectionItems(
      collectionId,
    );
    final List<VideoBookRow> all = await db.allVideoBooks();
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow row in all) row.bookUid: row,
    };
    return <VideoBookRow>[
      for (final MediaCollectionItemRow item in items)
        if (byUid[item.entryKey] case final VideoBookRow row) row,
    ];
  }

  Widget buildApp({
    Future<void> Function(MediaCollectionRow collection)? onRescrapeCollection,
  }) =>
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionDetailPage(
            database: db,
            collection: MediaCollectionRow(
              id: collectionId,
              name: 'Show',
              collectionType: 'playlist',
              coverSource: null,
              sortOrder: 0,
              createdAt: 0,
              orderUpdatedAt: 0,
            ),
            loadEpisodes: () async => <CollectionEpisodeSlot>[
              for (final VideoBookRow row in await loadMembers())
                CollectionEpisodeSlot.local(row),
            ],
            onOpenEpisode: (VideoBookRow _) {},
            onChanged: () {},
            onRescrapeCollection: onRescrapeCollection,
          ),
        ),
      );

  void useSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openEpisodeMenu(WidgetTester tester, String uid) async {
    final Finder card = find.byKey(
      ValueKey<String>('collection-episode-row-$uid'),
    );
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(card),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('没有刮削 controller 时不渲染任何重刮入口', (WidgetTester tester) async {
    useSurface(tester);
    // 不注入 onRescrapeCollection = 拿不到刮削 controller 的装配，此时菜单里
    // 一条重刮入口都不该有。
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(
      find.text(t.collection_rescrape),
      findsNothing,
      reason: '没有 controller 就渲染重刮入口 = 点了必然什么都不发生',
    );
    expect(find.text(t.collection_sort_by_season), findsOneWidget);
  });

  testWidgets('注入 controller 后管理菜单必须有 canonical 重刮入口',
      (WidgetTester tester) async {
    useSurface(tester);
    final List<int> rescraped = <int>[];
    await tester.pumpWidget(buildApp(
      onRescrapeCollection: (MediaCollectionRow collection) async =>
          rescraped.add(collection.id),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(
      find.text(t.collection_rescrape),
      findsOneWidget,
      reason: '「重刮这一个合集」是 BUG-1662 的诉求，来源页的扫描根作用域替代不了',
    );

    await tester.tap(find.text(t.collection_rescrape));
    await tester.pumpAndSettle();
    expect(rescraped, <int>[collectionId],
        reason: '菜单项必须真的把当前合集交给注入的重刮实现，不能只是长得像');
  });

  testWidgets('管理菜单提供合集封面设置，且未设封面时不显示恢复默认', (WidgetTester tester) async {
    useSurface(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.text(t.collection_cover_set), findsOneWidget,
        reason: '合集封面此前没有任何用户入口，只有刮削和下载导入会写');
    expect(
      find.text(t.collection_cover_reset),
      findsNothing,
      reason: 'coverPath 为空时没有可恢复的东西，不该占一行菜单',
    );
  });

  testWidgets('集卡菜单不暴露 legacy 条目信息重刮入口', (WidgetTester tester) async {
    useSurface(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await openEpisodeMenu(tester, 'video/e2');

    expect(
      find.text(t.video_scrape_info),
      findsNothing,
      reason: '单集不得再打开带 legacy 重刮/在线匹配动作的旧资料弹窗',
    );
    expect(
      find.text(t.collection_episode_download),
      findsOneWidget,
      reason: '非刮削菜单项不受影响',
    );
  });
}
