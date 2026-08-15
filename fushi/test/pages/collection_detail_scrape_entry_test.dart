import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1662 合集刮削入口守卫：
/// ① 详情页管理菜单必须有「刮削资料与封面」（onScrape 注入时），点击真触发回调——
///    此前详情页没有任何刮削入口，「刮错了从详情进来重刮」是断头路；
/// ② 集卡右键菜单必须有「条目信息」（onEpisodeScrapeInfo 注入时），点击带对的集——
///    合集语境下单集刮错了此前没有任何 UI 路径可以重刮；
/// ③ 两个回调都不注入（如日历页只注入合集级）时对应菜单项不出现，不给用户
///    点了没反应的死项。
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
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/v/$title.mkv'),
      ));
    }
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e2');
  });

  tearDown(() => db.close());

  Future<List<VideoBookRow>> loadMembers() async {
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collectionId);
    final List<VideoBookRow> all = await db.allVideoBooks();
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow r in all) r.bookUid: r,
    };
    return <VideoBookRow>[
      for (final MediaCollectionItemRow it in items)
        if (byUid[it.entryKey] case final VideoBookRow row) row,
    ];
  }

  Widget buildApp({
    Future<void> Function()? onScrape,
    Future<void> Function(VideoBookRow episode)? onEpisodeScrapeInfo,
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
            loadMembers: loadMembers,
            onOpenEpisode: (VideoBookRow _) {},
            onChanged: () {},
            onScrape: onScrape,
            onEpisodeScrapeInfo: onEpisodeScrapeInfo,
          ),
        ),
      );

  void useSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Finder cardOf(String uid) =>
      find.byKey(ValueKey<String>('collection-episode-row-$uid'));

  Future<void> openEpisodeMenu(WidgetTester tester, String uid) async {
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(cardOf(uid)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('BUG-1662：管理菜单有「刮削资料与封面」且点击真触发回调', (WidgetTester tester) async {
    useSurface(tester, const Size(1280, 1600));
    int scrapeCalls = 0;
    await tester.pumpWidget(buildApp(onScrape: () async => scrapeCalls++));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text(t.video_collection_scrape), findsOneWidget,
        reason: '注入 onScrape 后管理菜单必须出「刮削资料与封面」——详情页此前'
            '没有任何刮削入口（BUG-1662 断头路）');

    await tester.tap(find.text(t.video_collection_scrape));
    await tester.pumpAndSettle();
    expect(scrapeCalls, 1, reason: '点菜单项必须真触发注入的刮削流程');
  });

  testWidgets('BUG-1662：集卡右键菜单有「条目信息」且回调带对的那一集', (WidgetTester tester) async {
    useSurface(tester, const Size(1280, 1600));
    final List<String> scrapedUids = <String>[];
    await tester.pumpWidget(buildApp(
      onEpisodeScrapeInfo: (VideoBookRow episode) async =>
          scrapedUids.add(episode.bookUid),
    ));
    await tester.pumpAndSettle();

    await openEpisodeMenu(tester, 'video/e2');
    expect(find.text(t.video_scrape_info), findsOneWidget,
        reason: '注入 onEpisodeScrapeInfo 后集卡菜单必须出「条目信息」——合集'
            '语境下单集刮错了此前无路可重刮（BUG-1662）');

    await tester.tap(find.text(t.video_scrape_info));
    await tester.pumpAndSettle();
    expect(scrapedUids, <String>['video/e2'], reason: '回调必须收到被右键的那一集，不能拿错成员');
  });

  testWidgets('BUG-1662：不注入回调时两个菜单项都不出现（不给死项）', (WidgetTester tester) async {
    useSurface(tester, const Size(1280, 1600));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text(t.video_collection_scrape), findsNothing,
        reason: '无 onScrape（如无刮削能力的调用方）不得出死菜单项');
    // 关掉管理菜单再开集卡菜单。
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await openEpisodeMenu(tester, 'video/e1');
    expect(find.text(t.video_scrape_info), findsNothing,
        reason: '无 onEpisodeScrapeInfo 不得出死菜单项');
    expect(find.text(t.collection_episode_download), findsOneWidget,
        reason: '既有菜单项不受影响（菜单本身照常弹出）');
  });
}
