import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// 书籍合集详情页（[MediaCollectionGridDetailPage]）网格拖排 + 长按/右键上下文菜单
/// 真穿库验证：
///  - 长按整卡拖到新坑位 → `getCollectionItems` 的 sortIndex 真写穿（与库页合集行同源）；
///  - 长按原地松手弹上下文菜单（移出 + 打开）→ 移出真调 `removeFromCollection`；
///  - 菜单「打开」真回调 onOpenMember。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<HibikiDatabase> openDb() async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<({HibikiDatabase db, MediaCollectionRow col})> seed() async {
    final HibikiDatabase db = await openDb();
    final int cid = await db.createMediaCollection('C');
    await db.addToCollection(cid, MediaKind.epub, 'k1');
    await db.addToCollection(cid, MediaKind.epub, 'k2');
    await db.addToCollection(cid, MediaKind.epub, 'k3');
    final MediaCollectionRow col = (await db.getMediaCollectionById(cid))!;
    return (db: db, col: col);
  }

  /// 成员卡：纯视觉带 Key 的方块（真实调用方的卡片被详情页包进 IgnorePointer，
  /// 这里给个可定位的 Key 即可）。签名带可选 [onRemoveFromCollection] 注入点（详情页
  /// 会传 `() => _removeMember(row)`，供真实调用方把「移出合集」接进长按对话框）。
  Widget? cardBuilder(String mediaType, String entryKey,
          {VoidCallback? onRemoveFromCollection}) =>
      Container(
        key: ValueKey<String>('member-$entryKey'),
        color: Colors.blue,
        alignment: Alignment.center,
        child: Text(entryKey),
      );

  Widget wrapPage(
    MediaCollectionRow col,
    HibikiDatabase db, {
    void Function(String mediaType, String entryKey)? onOpenMember,
  }) =>
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionGridDetailPage(
            database: db,
            collection: col,
            memberCardBuilder: cardBuilder,
            onOpenMember: onOpenMember,
            onChanged: () {},
          ),
        ),
      );

  testWidgets('长按整卡拖到新坑位 → sortIndex 真写穿 getCollectionItems',
      (WidgetTester tester) async {
    final ({HibikiDatabase db, MediaCollectionRow col}) s = await seed();
    await tester.pumpWidget(wrapPage(s.col, s.db));
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> before =
        await s.db.getCollectionItems(s.col.id);
    expect(before.map((MediaCollectionItemRow r) => r.entryKey).toList(),
        <String>['k1', 'k2', 'k3']);

    // 把 k1 长按拖到 k3 的坑位（同一行横向相邻）。
    final Offset start =
        tester.getCenter(find.byKey(const ValueKey<String>('member-k1')));
    final Offset target =
        tester.getCenter(find.byKey(const ValueKey<String>('member-k3')));
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600)); // 越过长按阈值
    await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> after =
        await s.db.getCollectionItems(s.col.id);
    expect(after.map((MediaCollectionItemRow r) => r.entryKey).toList(),
        <String>['k2', 'k3', 'k1'],
        reason: 'k1 拖到末位后成员序真变（getCollectionItems 按 sortIndex 升序）');
    expect(after.map((MediaCollectionItemRow r) => r.sortIndex).toList(),
        <int>[0, 1, 2],
        reason: 'reorderCollectionItems 应把全表 sortIndex 回写成致密 0..n-1');
  });

  testWidgets('长按原地松手弹菜单（移出 + 打开）；移出真调 removeFromCollection',
      (WidgetTester tester) async {
    final ({HibikiDatabase db, MediaCollectionRow col}) s = await seed();
    await tester.pumpWidget(wrapPage(s.col, s.db, onOpenMember: (_, __) {}));
    await tester.pumpAndSettle();

    final Offset center =
        tester.getCenter(find.byKey(const ValueKey<String>('member-k2')));
    final TestGesture gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up(); // 原地松手（未移动）→ 上下文菜单
    await tester.pumpAndSettle();

    // 菜单含移出 + 打开两项。
    expect(find.text(t.collection_remove_member), findsOneWidget);
    expect(find.text(t.collection_open), findsOneWidget);

    await tester.tap(find.text(t.collection_remove_member));
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> after =
        await s.db.getCollectionItems(s.col.id);
    expect(after.map((MediaCollectionItemRow r) => r.entryKey).toList(),
        <String>['k1', 'k3'],
        reason: '菜单「移出合集」应真把 k2 从合集移除（removeFromCollection）');
  });

  testWidgets('菜单「打开」真回调 onOpenMember', (WidgetTester tester) async {
    final ({HibikiDatabase db, MediaCollectionRow col}) s = await seed();
    final List<String> opened = <String>[];
    await tester.pumpWidget(wrapPage(
      s.col,
      s.db,
      onOpenMember: (String mediaType, String entryKey) =>
          opened.add('$mediaType|$entryKey'),
    ));
    await tester.pumpAndSettle();

    final Offset center =
        tester.getCenter(find.byKey(const ValueKey<String>('member-k2')));
    final TestGesture gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.collection_open));
    await tester.pumpAndSettle();

    expect(opened, <String>['epub|k2'],
        reason: '菜单「打开」应回调 onOpenMember(mediaType, entryKey)');
  });

  testWidgets('筛选态拖拽保序合并：隐藏成员留在原下标（不被挤到表尾）', (WidgetTester tester) async {
    final HibikiDatabase db = await openDb();
    final int cid = await db.createMediaCollection('C');
    for (final String k in <String>['k1', 'k2', 'k3', 'k4', 'k5']) {
      await db.addToCollection(cid, MediaKind.epub, k);
    }
    final MediaCollectionRow col = (await db.getMediaCollectionById(cid))!;

    // 模拟书架标签筛选：k2/k4 被过滤（builder 返回 null → 详情页跳过，不可见）。
    Widget? filteredBuilder(String mediaType, String entryKey,
        {VoidCallback? onRemoveFromCollection}) {
      if (entryKey == 'k2' || entryKey == 'k4') return null;
      return Container(
        key: ValueKey<String>('member-$entryKey'),
        color: Colors.blue,
        alignment: Alignment.center,
        child: Text(entryKey),
      );
    }

    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        home: MediaCollectionGridDetailPage(
          database: db,
          collection: col,
          memberCardBuilder: filteredBuilder,
          onChanged: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 可见成员：k1, k3, k5。把 k1 拖到 k5 的坑位（可见序 0 → 2）。
    final Offset start =
        tester.getCenter(find.byKey(const ValueKey<String>('member-k1')));
    final Offset target =
        tester.getCenter(find.byKey(const ValueKey<String>('member-k5')));
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600)); // 长按起拖
    await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> after =
        await db.getCollectionItems(col.id);
    final List<String> keys =
        after.map((MediaCollectionItemRow r) => r.entryKey).toList();
    // 可见 [k1,k3,k5] → 拖成 [k3,k5,k1]；保序合并回全表，隐藏 k2/k4 原地不动。
    expect(keys, <String>['k3', 'k2', 'k5', 'k4', 'k1'],
        reason: '保序合并：可见槽按新可见序回填，隐藏成员留在原下标');
    expect(keys.indexOf('k2'), 1, reason: '隐藏成员 k2 下标不变（不被挤到表尾）');
    expect(keys.indexOf('k4'), 3, reason: '隐藏成员 k4 下标不变（不被挤到表尾）');
  });

  testWidgets('详情页给成员卡 builder 注入可用的「移出合集」回调（键盘/手柄移出入口）',
      (WidgetTester tester) async {
    final ({HibikiDatabase db, MediaCollectionRow col}) s = await seed();
    final Map<String, VoidCallback> injected = <String, VoidCallback>{};
    Widget? capturingBuilder(String mediaType, String entryKey,
        {VoidCallback? onRemoveFromCollection}) {
      expect(onRemoveFromCollection, isNotNull,
          reason: '详情页必须给每个成员卡注入「移出合集」回调');
      injected['$mediaType|$entryKey'] = onRemoveFromCollection!;
      return Container(
        key: ValueKey<String>('member-$entryKey'),
        color: Colors.blue,
      );
    }

    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        home: MediaCollectionGridDetailPage(
          database: s.db,
          collection: s.col,
          memberCardBuilder: capturingBuilder,
          onChanged: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(injected.containsKey('epub|k2'), isTrue);
    // 调用注入的回调 = 键盘/手柄用户在长按对话框点「移出合集」的等效路径。
    injected['epub|k2']!();
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> after =
        await s.db.getCollectionItems(s.col.id);
    expect(after.map((MediaCollectionItemRow r) => r.entryKey).toList(),
        <String>['k1', 'k3'],
        reason: '注入的移出回调应真把 k2 从合集移除（removeFromCollection）');
  });

  // ── 「删除合集」连同成员本体一起删（复选框，默认不删=只解链老行为）───────────
  Widget wrapPageWithDelete(
    MediaCollectionRow col,
    HibikiDatabase db, {
    Future<void> Function(List<MediaCollectionItemRow> members)?
        onDeleteMembersMedia,
  }) =>
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionGridDetailPage(
            database: db,
            collection: col,
            memberCardBuilder: cardBuilder,
            onChanged: () {},
            onDeleteMembersMedia: onDeleteMembersMedia,
          ),
        ),
      );

  testWidgets('删除合集：未注入删本体回调 → 弹窗无复选框，仅解散容器（老行为零变化）',
      (WidgetTester tester) async {
    final ({HibikiDatabase db, MediaCollectionRow col}) s = await seed();
    await tester.pumpWidget(wrapPage(s.col, s.db)); // 不传 onDeleteMembersMedia
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(t.delete_collection));
    await tester.pumpAndSettle();
    expect(find.text(t.delete_collection_also_books), findsNothing,
        reason: '无删本体回调时不应出现「同时删除其中的书」复选框');

    await tester.tap(find.text(t.delete_collection).last); // 确认删除
    await tester.pumpAndSettle();
    expect(await s.db.getMediaCollectionById(s.col.id), isNull,
        reason: '删合集仍只解散容器（deleteMediaCollection）');
  });

  testWidgets('删除合集：复选框默认不勾 → 回调不触发，只解散容器', (WidgetTester tester) async {
    final ({HibikiDatabase db, MediaCollectionRow col}) s = await seed();
    final List<MediaCollectionItemRow> passed = <MediaCollectionItemRow>[];
    await tester.pumpWidget(wrapPageWithDelete(
      s.col,
      s.db,
      onDeleteMembersMedia: (List<MediaCollectionItemRow> members) async =>
          passed.addAll(members),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(t.delete_collection));
    await tester.pumpAndSettle();
    expect(find.text(t.delete_collection_also_books), findsOneWidget,
        reason: '注入删本体回调后应出现复选框');

    await tester.tap(find.text(t.delete_collection).last); // 不勾直接删
    await tester.pumpAndSettle();
    expect(passed, isEmpty, reason: '未勾选复选框不应删成员本体');
    expect(await s.db.getMediaCollectionById(s.col.id), isNull);
  });

  testWidgets('删除合集：勾选「同时删除其中的书」→ 回调收到全部成员再解散容器', (WidgetTester tester) async {
    final ({HibikiDatabase db, MediaCollectionRow col}) s = await seed();
    final List<String> passed = <String>[];
    await tester.pumpWidget(wrapPageWithDelete(
      s.col,
      s.db,
      onDeleteMembersMedia: (List<MediaCollectionItemRow> members) async =>
          passed.addAll(members.map(
              (MediaCollectionItemRow r) => '${r.mediaType}|${r.entryKey}')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(t.delete_collection));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.delete_collection_also_books)); // 勾选
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.delete_collection).last); // 确认删除
    await tester.pumpAndSettle();

    expect(passed, <String>['epub|k1', 'epub|k2', 'epub|k3'],
        reason: '勾选后应把全部成员按 (mediaType,entryKey) 传给删本体回调');
    expect(await s.db.getMediaCollectionById(s.col.id), isNull,
        reason: '删成员本体后仍解散容器');
  });
}
