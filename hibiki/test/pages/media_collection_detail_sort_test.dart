import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/media_collection_detail_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 排序交互重设计层次 B1（spec 2026-07-12）：视频合集详情页就地排序。
///
/// 锁死两件事（都断言**真写穿 DB**，不是只动内存）：①AppBar「排序」菜单一键
/// 按名称（natural）/ 按导入时间重排并落盘 sortIndex；②行尾拖柄拖拽重排同样
/// 落盘。sortIndex 是层次 C 的单一顺序真相源——库页合集行与播放器换集读同一
/// `getCollectionItems`，这里落盘即三处同序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    // 三集：加入顺序（= 初始 sortIndex）故意乱序——Beta, 第10话, 第9话。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/beta'),
      title: const Value('Beta'),
      videoPath: const Value('/abs/beta.mp4'),
      importedAt: Value(DateTime(2026, 1, 2)),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/a10'),
      title: const Value('Alpha 第10话'),
      videoPath: const Value('/abs/a10.mp4'),
      importedAt: Value(DateTime(2026, 1, 3)),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/a9'),
      title: const Value('Alpha 第9话'),
      videoPath: const Value('/abs/a9.mp4'),
      importedAt: Value(DateTime(2026, 1, 1)),
    ));
    collectionId = await db.createMediaCollection(
      '某番剧',
      collectionType: 'playlist',
    );
    for (final String uid in <String>['video/beta', 'video/a10', 'video/a9']) {
      await db.addToCollection(collectionId, 'video', uid);
    }
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

  Future<List<String>> persistedOrder() async => <String>[
        for (final MediaCollectionItemRow it
            in await db.getCollectionItems(collectionId))
          it.entryKey,
      ];

  Widget buildApp() => TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionDetailPage(
            database: db,
            collection: MediaCollectionRow(
              id: collectionId,
              name: '某番剧',
              collectionType: 'playlist',
              coverSource: null,
              sortOrder: 0,
              createdAt: 0,
            ),
            loadMembers: loadMembers,
            onOpenEpisode: (VideoBookRow _) {},
            onChanged: () {},
          ),
        ),
      );

  testWidgets('一键「按名称」：natural 序（第9话<第10话）真写穿 sortIndex',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.collection_sort_by_title).last);
    await tester.pumpAndSettle();

    expect(
      await persistedOrder(),
      <String>['video/a9', 'video/a10', 'video/beta'],
      reason: '一键按名称必须 natural 排序并落盘（不是只动内存）',
    );
  });

  testWidgets('一键「按导入时间」：旧→新真写穿 sortIndex', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.collection_sort_by_imported).last);
    await tester.pumpAndSettle();

    expect(
      await persistedOrder(),
      <String>['video/a9', 'video/beta', 'video/a10'],
      reason: '一键按导入时间：旧→新（= 原始加入时序）并落盘',
    );
  });

  testWidgets('拖柄拖拽重排：首集拖到末尾真写穿 sortIndex', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 三行拖柄从上到下 = Beta / 第10话 / 第9话；把首行（Beta）往下拖两行。
    final Finder firstHandle = find.byIcon(Icons.drag_handle).first;
    await tester.timedDrag(
      firstHandle,
      const Offset(0, 170),
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();

    expect(
      await persistedOrder(),
      <String>['video/a10', 'video/a9', 'video/beta'],
      reason: '拖拽后顺序必须落盘 sortIndex（库页行/播放器同源生效）',
    );
  });
}
