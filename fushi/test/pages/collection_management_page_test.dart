import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_grouping.dart';
import 'package:fushi/src/pages/implementations/collection_management_page.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「管理合集」页（与「管理标签」对等）：只列本库页域的合集，点按打开详情，
/// 右键带锚点、长按 / ⋯ 不带锚点交给库页的合集菜单，写库后自动重载。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<FushiDatabase> seed() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int books = await db.createMediaCollection('书合集');
    await db.addToCollection(books, MediaKind.epub, 'b1');
    await db.addToCollection(books, MediaKind.epub, 'b2');
    final int videos = await db.createMediaCollection('视频合集');
    await db.addToCollection(videos, MediaKind.video, 'v1');
    return db;
  }

  Future<void> pumpPage(
    WidgetTester tester,
    FushiDatabase db, {
    List<String>? opened,
    List<Offset?>? menuAnchors,
    ValueListenable<Map<int, int>>? counts,
  }) async {
    final ValueListenable<Map<int, int>> displayCounts =
        counts ??
        ValueNotifier<Map<int, int>>(<int, int>{
          for (final MediaCollectionRow c
              in await tester.runAsync(() => db.getAllMediaCollections()) ??
                  const <MediaCollectionRow>[])
            c.id: 2,
        });
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: CollectionManagementPage(
            database: db,
            domain: CollectionShelfDomain.books,
            onOpenCollection: (MediaCollectionRow c) => opened?.add(c.name),
            onShowCollectionMenu: (MediaCollectionRow c) async =>
                menuAnchors?.add(activeContextMenuAnchor),
            displayCounts: displayCounts,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('只列本域合集并显示成员数；点按打开详情', (WidgetTester tester) async {
    final FushiDatabase db = await seed();
    final List<String> opened = <String>[];
    await pumpPage(tester, db, opened: opened);

    expect(find.text('书合集'), findsOneWidget);
    expect(find.text('视频合集'), findsNothing, reason: '视频域合集不进书架的管理页');
    expect(find.text(t.collection_detail_member_count(n: 2)), findsOneWidget);

    await tester.tap(find.text('书合集'));
    await tester.pumpAndSettle();
    expect(opened, <String>['书合集']);
  });

  testWidgets('右键带指针锚点、长按与 ⋯ 不带（库页合集菜单据此分流容器）', (WidgetTester tester) async {
    final FushiDatabase db = await seed();
    final List<Offset?> anchors = <Offset?>[];
    await pumpPage(tester, db, menuAnchors: anchors);

    final Offset row = tester.getCenter(find.text('书合集'));
    final TestGesture mouse = await tester.startGesture(
      row,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();

    await tester.longPress(find.text('书合集'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(t.shelf_toolbar_more));
    await tester.pumpAndSettle();

    expect(anchors, hasLength(3));
    expect(anchors[0], isNotNull);
    expect(anchors[1], isNull);
    expect(anchors[2], isNull);
  });

  testWidgets('合集表写入后自动重载（改名即时反映）', (WidgetTester tester) async {
    final FushiDatabase db = await seed();
    await pumpPage(tester, db);

    final MediaCollectionRow books = (await db.getAllMediaCollections())
        .firstWhere((MediaCollectionRow c) => c.name == '书合集');
    await tester.runAsync(() => db.renameMediaCollection(books.id, '改名后'));
    await tester.pumpAndSettle();

    expect(find.text('改名后'), findsOneWidget);
    expect(find.text('书合集'), findsNothing);
  });

  // BUG：书架合集卡「5 卷」，管理页却是「共 10 项」——管理页数的是
  // media_collection_items 原始行（有声书 SRT 与配对 EPUB 各一行、已删条目的悬空
  // 行、折叠归属被别的合集抢走的成员都算），库页只数折进卡里的显示单元。
  testWidgets('成员数取库页折叠结果，不数原始成员行', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    late int series;
    await tester.runAsync(() async {
      series = await db.createMediaCollection('七つの魔剣が支配する');
      for (int i = 1; i <= 5; i++) {
        await db.addToCollection(series, MediaKind.srt, 'srt$i');
        await db.addToCollection(series, MediaKind.epub, 'epub$i');
      }
    });
    final ValueNotifier<Map<int, int>> counts = ValueNotifier<Map<int, int>>(
      <int, int>{series: 5},
    );
    addTearDown(counts.dispose);
    await pumpPage(tester, db, counts: counts);

    expect(find.text(t.collection_detail_member_count(n: 5)), findsOneWidget);
    expect(find.text(t.collection_detail_member_count(n: 10)), findsNothing);

    // 库页没有它的卡（成员全删 / 全折进别的合集）→ 0，而不是原始行数。
    counts.value = const <int, int>{};
    await tester.pump();
    expect(find.text(t.collection_detail_member_count(n: 0)), findsOneWidget);
  });

  test('collectionDisplayCountsOf 只数合集组的成员、散卡不计', () {
    final MediaCollectionRow c = MediaCollectionRow(
      id: 7,
      name: 'c',
      collectionType: 'collection',
      sortOrder: 0,
      createdAt: 0,
      orderUpdatedAt: 0,
      origin: 'user',
      organizeAliases: '',
    );
    CollectionOrderingItem<int> item(String k) => CollectionOrderingItem<int>(
      mediaType: MediaKind.srt,
      entryKey: k,
      importedAt: 0,
      payload: 0,
    );
    final List<CollectionGroup<int>> groups = groupByCollections<int>(
      items: <CollectionOrderingItem<int>>[item('a'), item('b'), item('c')],
      primaryCollectionIdByEntry: <String, int>{
        MediaKind.srt.compositeKey('a'): 7,
        MediaKind.srt.compositeKey('b'): 7,
      },
      collectionsById: <int, MediaCollectionRow>{7: c},
      memberSortIndex: const <String, int>{},
    );
    expect(collectionDisplayCountsOf<int>(groups), <int, int>{7: 2});
  });

  testWidgets('CollectionDisplayCounts 帧末才写入，同帧多次只落最后一次', (
    WidgetTester tester,
  ) async {
    final CollectionDisplayCounts counts = CollectionDisplayCounts();
    addTearDown(counts.dispose);
    int notified = 0;
    counts.addListener(() => notified++);
    counts.publishCounts(<int, int>{1: 3});
    counts.publishCounts(<int, int>{1: 4});
    expect(counts.value, isEmpty);
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(counts.value, <int, int>{1: 4});
    expect(notified, 1);
  });
}
