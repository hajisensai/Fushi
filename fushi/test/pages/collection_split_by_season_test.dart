import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-2489：「按季拆分合集」。
/// ① 多季合集出菜单 → 预览弹窗每季一节（名字可编辑）→ 确认后逐季建新合集、
///   成员按季映射；② 新合集间自动写前传/续作链（source='local' 且绑定
///   targetCollectionId，extras 组不入链）；③「保留原合集」= 成员不动；取消勾选
///   则删除原合集；④ 全程真写穿 DB。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (final (String uid, String title) in const <(String, String)>[
      ('video/s1e1', 'Show S01E01'),
      ('video/s1e2', 'Show S01E02'),
      ('video/s2e1', 'Show S02E01'),
      ('video/pv', 'Show Fan Disc'),
    ]) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/v/$title.mkv'),
      ));
    }
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    for (final String uid in <String>[
      'video/s1e1',
      'video/s1e2',
      'video/s2e1',
      'video/pv',
    ]) {
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
            loadMembers: loadMembers,
            onOpenEpisode: (VideoBookRow _) {},
            onChanged: () {},
          ),
        ),
      );

  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Future<MediaCollectionRow?> collectionByName(String name) async {
    final List<MediaCollectionRow> all = await db.getAllMediaCollections();
    for (final MediaCollectionRow c in all) {
      if (c.name == name) return c;
    }
    return null;
  }

  Future<List<String>> membersOf(int id) async => <String>[
        for (final MediaCollectionItemRow it in await db.getCollectionItems(id))
          it.entryKey,
      ];

  // #792 起拆分入口收进 more_horiz 管理菜单，不再是顶栏独立 IconButton。
  Future<void> openSplitDialog(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.collection_split_by_season).last);
    await tester.pumpAndSettle();
  }

  testWidgets('拆分（保留原合集）：逐季建合集 + 成员按季映射 + 前传/续作链，原合集成员不动',
      (WidgetTester tester) async {
    await pumpWide(tester);

    await openSplitDialog(tester);
    // 预览：三个名字输入框（第1/第2季/PV·特典），默认「原名 组名」。
    expect(find.byKey(const ValueKey<String>('collection-split-name-0')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('collection-split-name-2')),
        findsOneWidget);

    await tester.tap(find.text(t.collection_split_confirm));
    await tester.pumpAndSettle();

    final MediaCollectionRow? s1 = await collectionByName('Show 第 1 季');
    final MediaCollectionRow? s2 = await collectionByName('Show 第 2 季');
    final MediaCollectionRow? extras =
        await collectionByName('Show ${t.collection_group_extras}');
    expect(s1, isNotNull, reason: '第 1 季新合集必须建出');
    expect(s2, isNotNull);
    expect(extras, isNotNull);
    expect(await membersOf(s1!.id), <String>['video/s1e1', 'video/s1e2']);
    expect(await membersOf(s2!.id), <String>['video/s2e1']);
    expect(await membersOf(extras!.id), <String>['video/pv']);

    // 原合集保留且成员不动（成员多归属，拆分只是新增映射）。
    expect(await membersOf(collectionId),
        <String>['video/s1e1', 'video/s1e2', 'video/s2e1', 'video/pv']);

    // 关系链：S1 有 sequel→S2；S2 有 prequel→S1；extras 不入链。
    final List<CollectionRelationRow> r1 =
        await db.getCollectionRelations(s1.id);
    expect(r1.length, 1);
    expect(r1.single.relationType, 'sequel');
    expect(r1.single.targetCollectionId, s2.id);
    expect(r1.single.source, 'local');
    final List<CollectionRelationRow> r2 =
        await db.getCollectionRelations(s2.id);
    expect(r2.single.relationType, 'prequel');
    expect(r2.single.targetCollectionId, s1.id);
    expect(await db.getCollectionRelations(extras.id), isEmpty,
        reason: 'PV·特典组无先后语义，不入前传/续作链');
  });

  testWidgets('拆分（不保留原合集）：原合集被删除', (WidgetTester tester) async {
    await pumpWide(tester);

    await openSplitDialog(tester);
    await tester.tap(find.byKey(
      const ValueKey<String>('collection-split-keep-original'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.collection_split_confirm));
    await tester.pumpAndSettle();

    expect(await db.getMediaCollectionById(collectionId), isNull,
        reason: '取消「保留原合集」→ 原合集删除（只解链，条目仍在）');
    expect((await db.allVideoBooks()).length, 4, reason: '删合集绝不删条目本身');
    expect(await collectionByName('Show 第 1 季'), isNotNull);
  });

  testWidgets('手动调整：勾选集 → 移动到另一组 → 按调整后的归属落盘（BUG-1543）',
      (WidgetTester tester) async {
    await pumpWide(tester);
    await openSplitDialog(tester);

    // 自动分季把 S01E02 放进第 1 季；用户把它挪到第 2 季。
    await tester.tap(
      find.byKey(const ValueKey<String>('collection-split-member-video/s1e2')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.collection_split_selected(n: 1)), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey<String>('collection-split-move-to')));
    await tester.pumpAndSettle();
    // 弹出菜单项与组名输入框同文本，菜单在最上层 → 取 last。
    await tester.tap(find.text('Show 第 2 季').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.collection_split_confirm));
    await tester.pumpAndSettle();

    final MediaCollectionRow? s1 = await collectionByName('Show 第 1 季');
    final MediaCollectionRow? s2 = await collectionByName('Show 第 2 季');
    expect(await membersOf(s1!.id), <String>['video/s1e1'],
        reason: '被挪走的集不能还留在原组');
    expect(await membersOf(s2!.id), <String>['video/s2e1', 'video/s1e2'],
        reason: '手动移动的集追加到目标组尾部');
  });

  testWidgets('手动调整：整组被搬空 → 该组不建合集（空合集在数据模型上不存在）', (WidgetTester tester) async {
    await pumpWide(tester);
    await openSplitDialog(tester);

    // 把第 2 季唯一一集挪进第 1 季，第 2 季组被搬空。
    await tester.tap(
      find.byKey(const ValueKey<String>('collection-split-member-video/s2e1')),
    );
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('collection-split-move-to')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show 第 1 季').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.collection_split_confirm));
    await tester.pumpAndSettle();

    expect(await collectionByName('Show 第 2 季'), isNull, reason: '空组不该建出合集');
    final MediaCollectionRow? s1 = await collectionByName('Show 第 1 季');
    expect(await membersOf(s1!.id),
        <String>['video/s1e1', 'video/s1e2', 'video/s2e1']);
    // 只剩一个真实季 → 无前传/续作可连。
    expect(await db.getCollectionRelations(s1.id), isEmpty);
  });

  testWidgets('单季合集：拆分菜单灰显', (WidgetTester tester) async {
    // 重建单季数据：只留 S01 两集。
    await db.removeFromCollection(collectionId, MediaKind.video, 'video/s2e1');
    await db.removeFromCollection(collectionId, MediaKind.video, 'video/pv');
    await pumpWide(tester);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    final PopupMenuItem<Object?> item = tester.widget<PopupMenuItem<Object?>>(
      find.ancestor(
        of: find.byIcon(Icons.call_split),
        matching: find.byWidgetPredicate(
          (Widget w) => w is PopupMenuItem<Object?>,
        ),
      ),
    );
    expect(item.enabled, isFalse, reason: '单季合集拆分无意义，必须灰显');
  });
}
