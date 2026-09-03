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
/// 暴露旧在线匹配/重刮入口；canonical 刮削统一从媒体来源页发起。
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

  Widget buildApp() => TranslationProvider(
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

  testWidgets('合集管理菜单不暴露 legacy 刮削入口', (WidgetTester tester) async {
    useSurface(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(
      find.text(t.video_collection_scrape),
      findsNothing,
      reason: '合集在线刮削必须从来源页进入，详情页不得再走 legacy 标题匹配',
    );
    expect(find.text(t.collection_sort_by_season), findsOneWidget);
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
