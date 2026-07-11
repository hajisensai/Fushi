import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';
import 'package:hibiki/src/utils/components/hibiki_reorderable_grid.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 原 TODO-947 折叠系列卡整理页守卫（R1/R2/R4/H1）。UI v2 Phase E 统一合集模型重做
/// 后，折叠系列卡模式整体死亡：[ShelfReorderItem] 的 seriesCardId、[ShelfReorderPage]
/// 的 onEnterSeries / rebuildItems、纯函数 splitShelfReorderOrders 均已删除——整理页
/// 只剩「合集成员内联展开」一种形态，点格子不再进入任何成员子页（R2/R4/H1 的
/// 「点系列卡进子页 / 进前落盘」语义随之消亡，对应 test 块删除）。本文件改写为对新
/// 等价行为的守护：
///  - [unfoldedShelfReorderOrders] 落盘契约（合集 sortOrder = 首成员下标；每条目下标
///    即 entry sortOrder）；
///  - 与 _persistShelfOrder 同原语的 DB 写穿（updateMediaCollectionSortOrder +
///    batchUpsertShelfOrder），排序写不动合集归属；移出成员不动其它条目 sortOrder；
///  - 整理页不再传 onActivate（格子点击无进入语义，纯拖拽回归守卫）；
///  - TODO-1228 自动保存语义（无确认 ✓、返回即落盘）原样保留。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(home: child),
      );

  group('unfoldedShelfReorderOrders 落盘契约（groupOrders = 合集首成员下标）', () {
    test('混合媒体：每条目下标 -> entry sortOrder；每合集 -> 首成员下标', () {
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        const ShelfReorderItem(
            mediaType: 'epub', entryKey: 'bookA', card: SizedBox()),
        const ShelfReorderItem(
            mediaType: 'epub', entryKey: 'x1', groupId: 5, card: SizedBox()),
        const ShelfReorderItem(
            mediaType: 'srt', entryKey: 'uidB', card: SizedBox()),
        const ShelfReorderItem(
            mediaType: 'video', entryKey: 'v1', groupId: 9, card: SizedBox()),
        const ShelfReorderItem(
            mediaType: 'epub', entryKey: 'x2', groupId: 5, card: SizedBox()),
      ];
      final split = unfoldedShelfReorderOrders(ordered);
      expect(
        split.entryOrders,
        <({String mediaType, String entryKey, int sortOrder})>[
          (mediaType: 'epub', entryKey: 'bookA', sortOrder: 0),
          (mediaType: 'epub', entryKey: 'x1', sortOrder: 1),
          (mediaType: 'srt', entryKey: 'uidB', sortOrder: 2),
          (mediaType: 'video', entryKey: 'v1', sortOrder: 3),
          (mediaType: 'epub', entryKey: 'x2', sortOrder: 4),
        ],
        reason: '散条目与合集成员一视同仁：下标即 ShelfEntries.sortOrder',
      );
      // 合集 sortOrder = 首个成员下标（首次出现即最小）。
      expect(split.groupOrders, <({int groupId, int sortOrder})>[
        (groupId: 5, sortOrder: 1),
        (groupId: 9, sortOrder: 3),
      ]);
    });

    test('全散条目 -> groupOrders 为空（无合集不写 MediaCollections）', () {
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        const ShelfReorderItem(
            mediaType: 'epub', entryKey: 'a', card: SizedBox()),
        const ShelfReorderItem(
            mediaType: 'srt', entryKey: 'b', card: SizedBox()),
      ];
      final split = unfoldedShelfReorderOrders(ordered);
      expect(split.groupOrders, isEmpty);
      expect(split.entryOrders.length, 2);
    });
  });

  group('DB 写穿（与 _persistShelfOrder 同原语）', () {
    late HibikiDatabase db;
    setUp(() {
      db = HibikiDatabase.forTesting(
        NativeDatabase.memory(
          setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
        ),
      );
    });
    tearDown(() => db.close());

    test(
        '整理序落盘：合集首成员下标 -> MediaCollections.sortOrder，散条目 -> ShelfEntries.sortOrder',
        () async {
      final int cid = await db.createMediaCollection('S');
      await db.addToCollection(cid, 'epub', 'm1');
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        const ShelfReorderItem(
            mediaType: 'epub', entryKey: 'bookA', card: SizedBox()),
        ShelfReorderItem(
            mediaType: 'epub',
            entryKey: 'm1',
            groupId: cid,
            card: const SizedBox()),
      ];
      final split = unfoldedShelfReorderOrders(ordered);
      for (final ({int groupId, int sortOrder}) go in split.groupOrders) {
        await db.updateMediaCollectionSortOrder(go.groupId, go.sortOrder);
      }
      await db.batchUpsertShelfOrder(split.entryOrders);

      expect((await db.getMediaCollectionById(cid))!.sortOrder, 1,
          reason: '合集首成员下标 -> MediaCollections.sortOrder');
      expect((await db.getShelfEntry('epub', 'bookA'))!.sortOrder, 0,
          reason: 'loose index -> ShelfEntries.sortOrder');
      expect((await db.getShelfEntry('epub', 'm1'))!.sortOrder, 1,
          reason: '成员下标同样落 ShelfEntries.sortOrder');
    });

    test('成员重排只写 ShelfEntries.sortOrder，合集归属不动', () async {
      final int cid = await db.createMediaCollection('S');
      await db.addToCollection(cid, 'epub', 'm1');
      await db.addToCollection(cid, 'epub', 'm2');
      await db.batchUpsertShelfOrder(<({
        String mediaType,
        String entryKey,
        int sortOrder
      })>[
        (mediaType: 'epub', entryKey: 'm2', sortOrder: 0),
        (mediaType: 'epub', entryKey: 'm1', sortOrder: 1),
      ]);
      expect((await db.getShelfEntry('epub', 'm2'))!.sortOrder, 0);
      expect((await db.getShelfEntry('epub', 'm1'))!.sortOrder, 1);
      final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
      expect(primary['epub|m1'], cid, reason: '排序写不动合集归属');
      expect(primary['epub|m2'], cid, reason: '排序写不动合集归属');
    });

    test('移出成员：只动该成员归属；其它条目 sortOrder 不动、未清空的合集不删', () async {
      final int cid = await db.createMediaCollection('S');
      await db.addToCollection(cid, 'epub', 'm1');
      await db.addToCollection(cid, 'epub', 'm2');
      await db.upsertShelfOrder('epub', 'loose', 7);

      await db.removeFromCollection(cid, 'epub', 'm1');
      final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
      expect(primary.containsKey('epub|m1'), isFalse, reason: '被移出的成员不再有合集归属');
      expect(primary['epub|m2'], cid, reason: '其余成员归属不动');
      expect((await db.getShelfEntry('epub', 'loose'))!.sortOrder, 7,
          reason:
              'move-out does not shift other entries sortOrder (stable key)');
      expect(await db.getMediaCollectionById(cid), isNotNull,
          reason: '未清空的合集不被删');
    });
  });

  group('整理页格子点击无进入语义（纯拖拽回归守卫）', () {
    testWidgets('页面不传 onActivate；点格子不触发任何进入行为', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 700);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrap(ShelfReorderPage(
          title: 'Edit order',
          cellExtent: 200,
          childAspectRatio: 1,
          initialItems: const <ShelfReorderItem>[
            ShelfReorderItem(
              mediaType: 'epub',
              entryKey: 'member',
              groupId: 42,
              card: Center(child: Text('MEMBER')),
            ),
            ShelfReorderItem(
              mediaType: 'epub',
              entryKey: 'bookA',
              card: Center(child: Text('LOOSE')),
            ),
          ],
          onPersist: (_) async {},
        )),
      );
      await tester.pumpAndSettle();

      // 折叠系列卡模式已删：整理页不再给网格接 onActivate（点格子无进入语义）。
      final HibikiReorderableGrid grid = tester
          .widget<HibikiReorderableGrid>(find.byType(HibikiReorderableGrid));
      expect(grid.onActivate, isNull,
          reason: '整理页无成员子页可进，onActivate 必须为 null（纯拖拽）');

      // 点合集成员格 / 散卡格都不产生任何导航或崩溃，页面原地不动。
      await tester.tap(find.text('MEMBER'), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('LOOSE'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(ShelfReorderPage), findsOneWidget);
    });
  });

  group('TODO-1228 auto-save semantics: no confirm check, exit persists', () {
    testWidgets(
        'AppBar has no Icons.check action; back (maybePop) persists dirty '
        'order and pops', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 700);
      addTearDown(tester.view.reset);

      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      List<String>? persistedOrder;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: SizedBox()),
          ),
        ),
      );
      navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => ShelfReorderPage(
          title: 'Edit order',
          cellExtent: 200,
          childAspectRatio: 1,
          initialItems: const <ShelfReorderItem>[
            ShelfReorderItem(
              mediaType: 'epub',
              entryKey: 'bookA',
              card: Center(child: Text('BOOKA')),
            ),
            ShelfReorderItem(
              mediaType: 'epub',
              entryKey: 'bookB',
              card: Center(child: Text('BOOKB')),
            ),
          ],
          onPersist: (List<ShelfReorderItem> ordered) async {
            persistedOrder = <String>[
              for (final ShelfReorderItem it in ordered) it.entryKey,
            ];
          },
        ),
      ));
      await tester.pumpAndSettle();

      // TODO-1228：确认 ✓ 纯装饰（所有退出路径都经 PopScope 自动落盘，无丢弃路径），
      // 已删除——重排页 AppBar 不得再出现 check 动作，防止暗示「不点就不保存」。
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
        reason:
            'TODO-1228: decorative confirm check removed; exits always save',
      );

      // 拖动重排置脏，再走返回路径（系统返回 / AppBar back 同经 maybePop ->
      // PopScope(canPop:false) -> _finish 落盘后真正 pop）。
      final HibikiReorderableGrid grid = tester
          .widget<HibikiReorderableGrid>(find.byType(HibikiReorderableGrid));
      grid.onReorder(1, 0);
      await tester.pump();

      await navKey.currentState!.maybePop();
      await tester.pumpAndSettle();

      expect(persistedOrder, <String>['bookB', 'bookA'],
          reason: 'back exit auto-saves the reordered order (no confirm)');
      expect(find.byType(ShelfReorderPage), findsNothing,
          reason: 'page actually pops after persisting');
    });
  });
}
