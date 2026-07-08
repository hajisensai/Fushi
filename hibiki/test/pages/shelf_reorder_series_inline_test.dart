import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/series_shelf_card.dart';
import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';
import 'package:hibiki/src/utils/misc/shelf_ordering.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-947 P4：书架「编辑排序」内联展开合集成员守卫——
///  - 成员连续相邻（[unfoldedShelfReorderOrders] 把系列落回首成员下标，回主网格经
///    groupAndSortShelfEntries 混排后系列成员重新聚拢在一起）。
///  - 分组视觉：同系列每个成员卡套 [SeriesReorderFrame] 同色边框，首成员叠系列名 header。
///  - 系列成员格挂「移出系列」按钮，散书格不挂。
ShelfReorderItem _item(String key, {int? seriesId, Widget? card}) =>
    ShelfReorderItem(
      mediaType: 'epub',
      entryKey: key,
      seriesId: seriesId,
      card: card ?? const SizedBox(),
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('unfoldedShelfReorderOrders 落盘拆分（散书+成员都进 entryOrders，系列落首成员下标）', () {
    test('每条目下标 -> ShelfEntries.sortOrder；每系列 -> 首成员下标', () {
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        _item('A'), // 0 散书
        _item('X1', seriesId: 5), // 1 系列5首成员
        _item('X2', seriesId: 5), // 2 系列5成员
        _item('B'), // 3 散书
        _item('Y1', seriesId: 9), // 4 系列9首成员
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
      // 系列 sortOrder = 其首个成员的下标（首次出现即最小）。
      expect(split.seriesOrders, <({int seriesId, int sortOrder})>[
        (seriesId: 5, sortOrder: 1),
        (seriesId: 9, sortOrder: 4),
      ]);
    });

    test('散书夹在两个同系列成员之间：系列 sortOrder 取更小的成员下标', () {
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        _item('M2', seriesId: 3), // 0
        _item('L', seriesId: null), // 1 散书被拖进中间
        _item('M1', seriesId: 3), // 2
      ];
      final split = unfoldedShelfReorderOrders(ordered);
      expect(split.seriesOrders, <({int seriesId, int sortOrder})>[
        (seriesId: 3, sortOrder: 0),
      ]);
    });
  });

  group('DB 往返：拖散的同系列成员退出重载后重新连续相邻', () {
    late HibikiDatabase db;
    setUp(() {
      db = HibikiDatabase.forTesting(
        NativeDatabase.memory(
          setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
        ),
      );
    });
    tearDown(() => db.close());

    test('用户把散书拖进系列两成员之间；落盘+重分组后成员仍连续、系列落首成员位', () async {
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry('epub', 'm1', sid);
      await db.setSeriesForEntry('epub', 'm2', sid);

      // 用户在内联排序页里把散书 L 拖到系列两成员中间：[m2, L, m1]。
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        _item('m2', seriesId: sid),
        _item('L', seriesId: null),
        _item('m1', seriesId: sid),
      ];
      final split = unfoldedShelfReorderOrders(ordered);
      for (final so in split.seriesOrders) {
        await db.updateSeriesSortOrder(so.seriesId, so.sortOrder);
      }
      await db.batchUpsertShelfOrder(split.entryOrders);

      // 系列 sortOrder = 首成员(m2)下标 0；散书 L sortOrder = 1；成员 sortOrder 各自下标。
      expect((await db.getSeriesById(sid))!.sortOrder, 0);
      expect((await db.getShelfEntry('epub', 'L'))!.sortOrder, 1);
      expect((await db.getShelfEntry('epub', 'm2'))!.sortOrder, 0);
      expect((await db.getShelfEntry('epub', 'm1'))!.sortOrder, 2);

      // 回主网格：重分组后系列成员应重新聚拢连续（不再被 L 分隔）。
      final List<ShelfEntryRow> entries = await db.getAllShelfEntries();
      final List<SeriesRow> series = await db.getAllSeries();
      final Map<int, SeriesRow> seriesById = <int, SeriesRow>{
        for (final SeriesRow s in series) s.id: s,
      };
      final List<ShelfOrderingItem<String>> items = <ShelfOrderingItem<String>>[
        for (final String key in <String>['m1', 'm2', 'L'])
          ShelfOrderingItem<String>(
            mediaType: 'epub',
            entryKey: key,
            importedAt: 0,
            payload: key,
          ),
      ];
      final List<ShelfGroup<String>> groups = groupAndSortShelfEntries<String>(
        items: items,
        shelfEntries: entries,
        seriesById: seriesById,
      );
      final List<String> flat = <String>[
        for (final ShelfGroup<String> g in groups)
          for (final ShelfOrderingItem<String> it in g.items) it.entryKey,
      ];
      // m1 与 m2 相邻（连续在一块），且都排在散书 L 之前（系列落首成员位 0 < L 的 1）。
      final int im1 = flat.indexOf('m1');
      final int im2 = flat.indexOf('m2');
      expect((im1 - im2).abs(), 1, reason: '同系列成员重载后连续相邻');
      expect(flat.indexOf('L') > im1 && flat.indexOf('L') > im2, isTrue,
          reason: '系列落回首成员位置，排在被拖进来的散书之前');
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
      int seriesId, {
      required bool header,
    }) =>
        _item(
          key,
          seriesId: seriesId,
          card: SeriesReorderFrame(
            color: const Color(0xFF4F8DFD),
            showHeader: header,
            seriesName: 'MySeries',
            memberCount: 2,
            child: Center(child: Text(key)),
          ),
        );

    testWidgets('同系列成员套框、首成员标系列名；成员格有移出按钮、散书格没有', (WidgetTester tester) async {
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
            const ShelfRemoveResult(removed: true, seriesEmptied: false),
      )));
      await tester.pumpAndSettle();

      // 分组框：两个系列成员各套一层 SeriesReorderFrame。
      expect(find.byType(SeriesReorderFrame), findsNWidgets(2),
          reason: '同系列成员逐本套同色分组框');
      // 系列名 header 只在首成员出现一次。
      expect(find.text('MySeries'), findsOneWidget,
          reason: '首成员叠系列名 header（其余成员不重复标名）');
      // 移出按钮：仅系列成员格挂（seriesId 非空），散书格不挂 -> 恰好 2 个。
      expect(find.byIcon(Icons.remove_circle_outline), findsNWidgets(2),
          reason: '系列成员格挂移出按钮，散书格不挂');
      // 三张卡都渲染（散书 + 两成员）。
      expect(find.text('L'), findsOneWidget);
      expect(find.text('M1'), findsOneWidget);
      expect(find.text('M2'), findsOneWidget);
    });

    // TODO-947：用户报「编辑排序里看不见边框」。根因——早期只画 2.5px 前景细线，
    // 手机默认 [HibikiAppUiScale] FittedBox 缩小（<1）下压成亚像素而消失。修复后
    // SeriesReorderFrame 用**实心 matte 背景**（同系列色，缩放下仍留可见带宽）+ 实心
    // 3px 边框二者并存，保证任意缩放都看得见分组。本用例守住这两个实心视觉不被改回细线。
    testWidgets('分组框：实心 matte 背景 + ≥3px 同色边框都在（缩放态仍可见的可视化守卫）',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 800);
      addTearDown(tester.view.reset);

      const Color seriesColor = Color(0xFF4F8DFD);
      await tester.pumpWidget(host(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 320,
              child: SeriesReorderFrame(
                color: seriesColor,
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

      // 背景 matte：实心填充（非透明），色相取自系列色（缩放下留得住的可见带宽，不是细线）。
      expect(bg.color, isNotNull, reason: 'matte 背景必须是实心填充色（细线在缩放下会消失）');
      expect(bg.color!.a, greaterThan(0.0), reason: 'matte 不能全透明');
      expect((bg.color!.r - seriesColor.r).abs(), lessThan(0.02),
          reason: 'matte 色相取自系列色（同系列同色 → 读作一叠）');

      // 前景边框：实心、同系列色、宽度 ≥3（早期 2.5px 太细）。
      final BorderSide side = (fg.border! as Border).top;
      expect(side.color, seriesColor, reason: '边框用系列色');
      expect(side.width, greaterThanOrEqualTo(3.0),
          reason: '边框 ≥3px（早期 2.5px 在缩放下看不见）');
    });
  });
}
