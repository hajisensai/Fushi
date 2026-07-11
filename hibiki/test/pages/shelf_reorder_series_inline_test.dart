import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/collections/collection_grouping.dart';
import 'package:hibiki/src/pages/implementations/series_shelf_card.dart';
import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-947 P4 → UI v2 Phase E（统一合集模型重做）：「整理排序」内联展开合集成员守卫——
///  - 成员连续相邻（[unfoldedShelfReorderOrders] 把合集落回首成员下标，回主网格经
///    [groupByCollections] 混排后合集成员重新聚拢在一起）。
///  - 分组视觉：同合集每个成员卡套 [SeriesReorderFrame] 同色边框，首成员叠合集名 header。
///  - 合集成员格挂「移出合集」按钮，散书格不挂。
ShelfReorderItem _item(
  String key, {
  int? groupId,
  Widget? card,
  GroupFrameData? groupFrame,
}) =>
    ShelfReorderItem(
      mediaType: 'epub',
      entryKey: key,
      groupId: groupId,
      card: card ?? const SizedBox(),
      groupFrame: groupFrame,
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('unfoldedShelfReorderOrders 落盘拆分（散书+成员都进 entryOrders，合集落首成员下标）', () {
    test('每条目下标 -> ShelfEntries.sortOrder；每合集 -> 首成员下标', () {
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        _item('A'), // 0 散书
        _item('X1', groupId: 5), // 1 合集5首成员
        _item('X2', groupId: 5), // 2 合集5成员
        _item('B'), // 3 散书
        _item('Y1', groupId: 9), // 4 合集9首成员
      ];
      final split = unfoldedShelfReorderOrders(ordered);
      expect(
        split.entryOrders,
        <({String mediaType, String entryKey, int sortOrder})>[
          (mediaType: 'epub', entryKey: 'A', sortOrder: 0),
          (mediaType: 'epub', entryKey: 'X1', sortOrder: 1),
          (mediaType: 'epub', entryKey: 'X2', sortOrder: 2),
          (mediaType: 'epub', entryKey: 'B', sortOrder: 3),
          (mediaType: 'epub', entryKey: 'Y1', sortOrder: 4),
        ],
      );
      // 合集 sortOrder = 其首个成员的下标（首次出现即最小）。
      expect(split.groupOrders, <({int groupId, int sortOrder})>[
        (groupId: 5, sortOrder: 1),
        (groupId: 9, sortOrder: 4),
      ]);
    });

    test('散书夹在两个同合集成员之间：合集 sortOrder 取更小的成员下标', () {
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        _item('M2', groupId: 3), // 0
        _item('L', groupId: null), // 1 散书被拖进中间
        _item('M1', groupId: 3), // 2
      ];
      final split = unfoldedShelfReorderOrders(ordered);
      expect(split.groupOrders, <({int groupId, int sortOrder})>[
        (groupId: 3, sortOrder: 0),
      ]);
    });
  });

  group('DB 往返：拖散的同合集成员退出重载后重新连续相邻', () {
    late HibikiDatabase db;
    setUp(() {
      db = HibikiDatabase.forTesting(
        NativeDatabase.memory(
          setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
        ),
      );
    });
    tearDown(() => db.close());

    test('用户把散书拖进合集两成员之间；落盘+重分组后成员仍连续、合集落首成员位', () async {
      // 先建一个占位合集，让目标合集初始 sortOrder 非 0，写穿断言才不平凡。
      await db.createMediaCollection('placeholder');
      final int cid = await db.createMediaCollection('S');
      await db.addToCollection(cid, 'epub', 'm1');
      await db.addToCollection(cid, 'epub', 'm2');
      expect((await db.getMediaCollectionById(cid))!.sortOrder, 1,
          reason: '前置：目标合集初始 sortOrder 排在占位合集之后');

      // 用户在内联排序页里把散书 L 拖到合集两成员中间：[m2, L, m1]。
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        _item('m2', groupId: cid),
        _item('L', groupId: null),
        _item('m1', groupId: cid),
      ];
      final split = unfoldedShelfReorderOrders(ordered);
      for (final ({int groupId, int sortOrder}) go in split.groupOrders) {
        await db.updateMediaCollectionSortOrder(go.groupId, go.sortOrder);
      }
      await db.batchUpsertShelfOrder(split.entryOrders);

      // 合集 sortOrder = 首成员(m2)下标 0；散书 L sortOrder = 1；成员 sortOrder 各自下标。
      expect((await db.getMediaCollectionById(cid))!.sortOrder, 0);
      expect((await db.getShelfEntry('epub', 'L'))!.sortOrder, 1);
      expect((await db.getShelfEntry('epub', 'm2'))!.sortOrder, 0);
      expect((await db.getShelfEntry('epub', 'm1'))!.sortOrder, 2);

      // 回主网格：groupByCollections 重分组后合集成员应重新聚拢连续（不再被 L 分隔）。
      final List<ShelfEntryRow> entries = await db.getAllShelfEntries();
      final Map<String, int> itemSortOrder = <String, int>{
        for (final ShelfEntryRow e in entries)
          '${e.mediaType}|${e.entryKey}': e.sortOrder,
      };
      final Map<int, MediaCollectionRow> collectionsById =
          <int, MediaCollectionRow>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.id: c,
      };
      final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
      final List<CollectionOrderingItem<String>> items =
          <CollectionOrderingItem<String>>[
        for (final String key in <String>['m1', 'm2', 'L'])
          CollectionOrderingItem<String>(
            mediaType: 'epub',
            entryKey: key,
            importedAt: 0,
            payload: key,
          ),
      ];
      final List<CollectionGroup<String>> groups = groupByCollections<String>(
        items: items,
        primaryCollectionIdByEntry: primary,
        collectionsById: collectionsById,
        itemSortOrder: itemSortOrder,
      );
      final List<String> flat = <String>[
        for (final CollectionGroup<String> g in groups)
          for (final CollectionOrderingItem<String> it in g.items) it.entryKey,
      ];
      // m1 与 m2 相邻（连续在一块），且都排在散书 L 之前（合集落首成员位 0 < L 的 1）。
      final int im1 = flat.indexOf('m1');
      final int im2 = flat.indexOf('m2');
      expect((im1 - im2).abs(), 1, reason: '同合集成员重载后连续相邻');
      expect(flat.indexOf('L') > im1 && flat.indexOf('L') > im2, isTrue,
          reason: '合集落回首成员位置，排在被拖进来的散书之前');
      // 具体序：[m2, m1, L]（组内按 sortOrder 升序：m2=0, m1=2）。
      expect(flat, <String>['m2', 'm1', 'L']);
    });
  });

  group('内联排序页分组视觉 + 成员移出按钮（散书无）', () {
    Widget host(Widget page) => TranslationProvider(
          child: MaterialApp(home: page),
        );

    ShelfReorderItem framedMember(
      String key,
      int groupId, {
      required bool header,
    }) =>
        _item(
          key,
          groupId: groupId,
          card: Center(child: Text(key)),
          // UI v2：只带框参数，框由 ShelfReorderPage 据此叠加（不再预烘进 card）。
          groupFrame: GroupFrameData(
            color: const Color(0xFF4F8DFD),
            showHeader: header,
            groupName: 'MyCollection',
            memberCount: 2,
          ),
        );

    testWidgets('同合集成员套框、首成员标合集名；成员格有移出按钮、散书格没有', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 800);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(ShelfReorderPage(
        title: 'Edit order',
        cellExtent: 200,
        childAspectRatio: 1,
        initialItems: <ShelfReorderItem>[
          _item('L', card: const Center(child: Text('L'))), // 散书
          framedMember('M1', 7, header: true),
          framedMember('M2', 7, header: false),
        ],
        onPersist: (_) async {},
        onMerge: (_, __) async => 7,
        onRemove: (ShelfReorderItem item) async =>
            const ShelfRemoveResult(removed: true, groupEmptied: false),
      )));
      await tester.pumpAndSettle();

      // 分组框：两个合集成员各套一层 SeriesReorderFrame（视觉组件复用）。
      expect(find.byType(SeriesReorderFrame), findsNWidgets(2),
          reason: '同合集成员逐本套同色分组框');
      // 合集名 header 只在首成员出现一次。
      expect(find.text('MyCollection'), findsOneWidget,
          reason: '首成员叠合集名 header（其余成员不重复标名）');
      // 移出按钮：仅合集成员格挂（groupId 非空），散书格不挂 -> 恰好 2 个。
      expect(find.byIcon(Icons.remove_circle_outline), findsNWidgets(2),
          reason: '合集成员格挂移出按钮，散书格不挂');
      // 三张卡都渲染（散书 + 两成员）。
      expect(find.text('L'), findsOneWidget);
      expect(find.text('M1'), findsOneWidget);
      expect(find.text('M2'), findsOneWidget);
    });

    // TODO-947-② v2：用户报「编辑排序里点减号删除某书后，书籍不回到编辑排序列表」。根因——
    // 旧实现 _onRemoveOutside 移出成员后 removeAt 把整条丢弃，书凭空消失（其实它只是被移出
    // 合集、变回一本散书，本应就地留在列表里）。修复后移出即 copyAsLoose：脱框 + 清 groupId，
    // 条目就地变回无框散书卡留在列表里。本用例守住「移出后书不消失、脱框、不再挂移出按钮」。
    testWidgets('点「移出合集」后成员降级为散书就地留在列表（不消失、脱框）', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 800);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(ShelfReorderPage(
        title: 'Edit order',
        cellExtent: 200,
        childAspectRatio: 1,
        initialItems: <ShelfReorderItem>[
          _item('L', card: const Center(child: Text('L'))),
          framedMember('M1', 7, header: true),
          framedMember('M2', 7, header: false),
        ],
        onPersist: (_) async {},
        onRemove: (ShelfReorderItem item) async =>
            const ShelfRemoveResult(removed: true, groupEmptied: false),
      )));
      await tester.pumpAndSettle();

      expect(find.byType(SeriesReorderFrame), findsNWidgets(2));
      expect(find.byIcon(Icons.remove_circle_outline), findsNWidgets(2));

      // 点第一个成员的「移出合集」按钮。
      await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
      await tester.pumpAndSettle();

      // 被移出的成员脱掉分组框（2 → 1）、不再挂移出按钮（2 → 1）……
      expect(find.byType(SeriesReorderFrame), findsOneWidget,
          reason: '被移出的成员脱掉分组框（变回散书）');
      expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget,
          reason: '散书不再挂移出按钮');
      // ……但三张卡都还在：被移出的书**没有消失**，只是就地变回散书留在编辑排序里。
      expect(find.text('L'), findsOneWidget);
      expect(find.text('M1'), findsOneWidget,
          reason: '移出的书不消失、就地留在编辑排序列表里（原实现 removeAt 让它消失）');
      expect(find.text('M2'), findsOneWidget);
    });

    // TODO-947-③：用户报「那个减号把书籍类型挡住了」。根因——移出按钮原放格子右上角
    // （PositionedDirectional top:0,end:0），正压住书卡封面右上角的类型徽章。修复后按钮改到
    // 封面**右下角**（bottomEnd + 抬过标题 footer）。本用例守住「按钮在这一格的下半 + 右半」，
    // 绝不回到会遮挡右上角类型徽章 / 左上角合集名 header 的顶部。
    testWidgets('移出按钮落在封面右下角（不遮挡右上角类型徽章 / 左上角 header）',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(ShelfReorderPage(
        title: 'Edit order',
        cellExtent: 400, // 单列，方便定位单格几何
        childAspectRatio: 1,
        initialItems: <ShelfReorderItem>[
          framedMember('M1', 7, header: true),
        ],
        onPersist: (_) async {},
        onRemove: (ShelfReorderItem item) async =>
            const ShelfRemoveResult(removed: true, groupEmptied: false),
      )));
      await tester.pumpAndSettle();

      final Rect frame = tester.getRect(find.byType(SeriesReorderFrame));
      final Offset btn =
          tester.getCenter(find.byIcon(Icons.remove_circle_outline));
      expect(btn.dy, greaterThan(frame.center.dy),
          reason: '移出按钮在下半区（不在顶部压类型徽章 / 合集名 header）');
      expect(btn.dx, greaterThan(frame.center.dx), reason: '移出按钮在右半区（右下角）');
    });

    // TODO-947：用户报「编辑排序里看不见边框」。根因——早期只画 2.5px 前景细线，
    // 手机默认 [HibikiAppUiScale] FittedBox 缩小（<1）下压成亚像素而消失。修复后
    // SeriesReorderFrame 用**实心 matte 背景**（同合集色，缩放下仍留可见带宽）+ 实心
    // 3px 边框二者并存，保证任意缩放都看得见分组。本用例守住这两个实心视觉不被改回细线。
    testWidgets('分组框：实心 matte 背景 + ≥3px 同色边框都在（缩放态仍可见的可视化守卫）',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 800);
      addTearDown(tester.view.reset);

      const Color groupColor = Color(0xFF4F8DFD);
      await tester.pumpWidget(host(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 320,
              child: SeriesReorderFrame(
                color: groupColor,
                showHeader: true,
                seriesName: 'S',
                memberCount: 2,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: ColoredBox(color: Color(0xFFB0B8C0)),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 找到承载 matte 背景 + 边框的那个 Container：它 decoration/foregroundDecoration 双非空。
      final Iterable<Container> containers = tester
          .widgetList<Container>(find.descendant(
            of: find.byType(SeriesReorderFrame),
            matching: find.byType(Container),
          ))
          .where((Container c) =>
              c.decoration is BoxDecoration &&
              c.foregroundDecoration is BoxDecoration);
      expect(containers, isNotEmpty,
          reason: '分组框必须同时有背景 matte(decoration) 和边框(foregroundDecoration)');
      final Container frame = containers.first;
      final BoxDecoration bg = frame.decoration! as BoxDecoration;
      final BoxDecoration fg = frame.foregroundDecoration! as BoxDecoration;

      // 背景 matte：实心填充（非透明），色相取自合集色（缩放下留得住的可见带宽，不是细线）。
      expect(bg.color, isNotNull, reason: 'matte 背景必须是实心填充色（细线在缩放下会消失）');
      expect(bg.color!.a, greaterThan(0.0), reason: 'matte 不能全透明');
      expect((bg.color!.r - groupColor.r).abs(), lessThan(0.02),
          reason: 'matte 色相取自合集色（同合集同色 → 读作一叠）');

      // 前景边框：实心、同合集色、宽度 ≥3（早期 2.5px 太细）。
      final BorderSide side = (fg.border! as Border).top;
      expect(side.color, groupColor, reason: '边框用合集色');
      expect(side.width, greaterThanOrEqualTo(3.0),
          reason: '边框 ≥3px（早期 2.5px 在缩放下看不见）');
    });
  });
}
