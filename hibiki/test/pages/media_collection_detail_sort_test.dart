import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
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
      importedAt: Value(DateTime(2026, 1, 2).millisecondsSinceEpoch),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/a10'),
      title: const Value('Alpha 第10话'),
      videoPath: const Value('/abs/a10.mp4'),
      importedAt: Value(DateTime(2026, 1, 3).millisecondsSinceEpoch),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/a9'),
      title: const Value('Alpha 第9话'),
      videoPath: const Value('/abs/a9.mp4'),
      importedAt: Value(DateTime(2026, 1, 1).millisecondsSinceEpoch),
    ));
    collectionId = await db.createMediaCollection(
      '某番剧',
      collectionType: 'playlist',
    );
    for (final String uid in <String>['video/beta', 'video/a10', 'video/a9']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
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
              orderUpdatedAt: 0,
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

  testWidgets('整行长按拖拽重排：首集拖到末尾真写穿 sortIndex', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // BUG-778 后拖拽走 HibikiReorderableColumn：触摸 = 长按整行起拖（鼠标即
    // 拖）。三行从上到下 = Beta / 第10话 / 第9话；长按首行（Beta）往下拖两行。
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('Beta')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (int step = 0; step < 5; step++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      await persistedOrder(),
      <String>['video/a10', 'video/a9', 'video/beta'],
      reason: '拖拽后顺序必须落盘 sortIndex（库页行/播放器同源生效）',
    );
  });

  // ── BUG-1194：混合种类合集 ────────────────────────────────────────────
  // 一个合集可同时含 video 与 game/epub 成员（「加入合集」弹窗列全表不按种类过滤；
  // 合集同步/备份合并按 (name, collectionType) 自然键对齐并原样并入对端裸串
  // mediaType）。本页只渲染 video 成员，但落盘必须回写**全表** sortIndex——否则
  // 不可见成员留着旧 sortIndex 与新写的致密 0..n-1 碰撞，跨种类手排顺序被打乱，
  // 还随同事务 bump 的 orderUpdatedAt 以 LWW 赢家身份推给对端。
  group('混合种类合集', () {
    /// 基线交错序：beta / game:g1 / a10 / epub:e1 / a9（非 video 成员夹在 video 之间，
    /// 只回写可见 video 键时它们的相对位置必然被打乱）。
    setUp(() async {
      await db.addToCollection(collectionId, MediaKind.game, 'g1');
      await db.addToCollection(collectionId, MediaKind.epub, 'e1');
      await db.reorderCollectionItems(
        collectionId,
        const <({String mediaType, String entryKey})>[
          (mediaType: 'video', entryKey: 'video/beta'),
          (mediaType: 'game', entryKey: 'g1'),
          (mediaType: 'video', entryKey: 'video/a10'),
          (mediaType: 'epub', entryKey: 'e1'),
          (mediaType: 'video', entryKey: 'video/a9'),
        ],
      );
    });

    /// 全表成员的 `<mediaType>|<entryKey>` 序列（`getCollectionItems` 口径 =
    /// 库页合集行 / 播放器换集 / 网格详情页共读的那一份）。
    Future<List<String>> persistedMembers() async => <String>[
          for (final MediaCollectionItemRow it
              in await db.getCollectionItems(collectionId))
            '${it.mediaType}|${it.entryKey}',
        ];

    /// 落盘后的 sortIndex 序列；必须是致密 0..n-1，有碰撞即说明有成员没被回写。
    Future<List<int>> persistedSortIndices() async => <int>[
          for (final MediaCollectionItemRow it
              in await db.getCollectionItems(collectionId))
            it.sortIndex,
        ];

    /// 三个断言口径一处收口：①成员集合零增减（非 video 成员仍在合集内）；
    /// ②全表 sortIndex 致密无碰撞；③非 video 成员相对 video 的手排位置不被打乱。
    Future<void> expectMixedOrder(List<String> expected) async {
      final List<String> members = await persistedMembers();
      expect(members.length, 5, reason: '排序绝不能增减成员');
      expect(
          members.toSet(),
          <String>{
            'video|video/beta',
            'video|video/a10',
            'video|video/a9',
            'game|g1',
            'epub|e1',
          },
          reason: '非 video 成员（game/epub）必须仍在合集内');
      expect(await persistedSortIndices(), <int>[0, 1, 2, 3, 4],
          reason: 'sortIndex 必须回写成致密 0..n-1；有重复即漏写了不可见成员');
      expect(members, expected, reason: '非 video 成员必须留在其原下标，不被可见 video 序挤走');
    }

    testWidgets('拖拽重排：非 video 成员留在原下标，成员零丢失、sortIndex 无碰撞',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      // 可见三行仍是 Beta / 第10话 / 第9话（非 video 成员不渲染）。首行拖到末尾 →
      // 可见新序 a10 / a9 / beta，依次填回原来的三个 video 槽位（下标 0/2/4）。
      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(find.text('Beta')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      for (int step = 0; step < 5; step++) {
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      await expectMixedOrder(<String>[
        'video|video/a10',
        'game|g1',
        'video|video/a9',
        'epub|e1',
        'video|video/beta',
      ]);
    });

    testWidgets('一键「按名称」：同样只置换 video 槽，非 video 成员原地不动',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.collection_sort_by_title).last);
      await tester.pumpAndSettle();

      // natural 序：第9话 < 第10话 < Beta，填回 video 槽位 0/2/4。
      await expectMixedOrder(<String>[
        'video|video/a9',
        'game|g1',
        'video|video/a10',
        'epub|e1',
        'video|video/beta',
      ]);
    });

    testWidgets('一键「按导入时间」：同样只置换 video 槽，非 video 成员原地不动',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.collection_sort_by_imported).last);
      await tester.pumpAndSettle();

      // 旧→新：a9(1/1) < beta(1/2) < a10(1/3)，填回 video 槽位 0/2/4。
      await expectMixedOrder(<String>[
        'video|video/a9',
        'game|g1',
        'video|video/beta',
        'epub|e1',
        'video|video/a10',
      ]);
    });
  });
}
