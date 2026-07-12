import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 书籍合集详情页（[MediaCollectionGridDetailPage]）网格拖排 + 长按/右键上下文菜单
/// 真穿库验证：
///  - 长按整卡拖到新坑位 → `getCollectionItems` 的 sortIndex 真写穿（与库页合集行同源）；
///  - 长按原地松手弹上下文菜单（移出 + 打开）→ 移出真调 `removeFromCollection`；
///  - 菜单「打开」真回调 onOpenMember。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<HibikiDatabase> openDb() async {
    final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<({HibikiDatabase db, MediaCollectionRow col})> seed() async {
    final HibikiDatabase db = await openDb();
    final int cid = await db.createMediaCollection('C');
    await db.addToCollection(cid, 'epub', 'k1');
    await db.addToCollection(cid, 'epub', 'k2');
    await db.addToCollection(cid, 'epub', 'k3');
    final MediaCollectionRow col = (await db.getMediaCollectionById(cid))!;
    return (db: db, col: col);
  }

  /// 成员卡：纯视觉带 Key 的方块（真实调用方的卡片被详情页包进 IgnorePointer，
  /// 这里给个可定位的 Key 即可）。
  Widget? cardBuilder(String mediaType, String entryKey) => Container(
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
}
