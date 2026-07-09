import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/series_shelf_card.dart';
import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';
import 'package:hibiki/src/utils/components/hibiki_reorderable_grid.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-947 fold-series sort-page guards (R1/R2/R4).
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(home: child),
      );

  group('R1 splitShelfReorderOrders folded-index split', () {
    test('series card -> seriesOrders, loose -> entryOrders, shared index', () {
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        const ShelfReorderItem(
          mediaType: 'series',
          entryKey: 'series_5',
          seriesId: 5,
          seriesCardId: 5,
          card: SizedBox(),
        ),
        const ShelfReorderItem(
          mediaType: 'epub',
          entryKey: 'bookA',
          card: SizedBox(),
        ),
        const ShelfReorderItem(
          mediaType: 'series',
          entryKey: 'series_9',
          seriesId: 9,
          seriesCardId: 9,
          card: SizedBox(),
        ),
        const ShelfReorderItem(
          mediaType: 'srt',
          entryKey: 'uidB',
          card: SizedBox(),
        ),
      ];
      final split = splitShelfReorderOrders(ordered);
      expect(split.seriesOrders, <({int seriesId, int sortOrder})>[
        (seriesId: 5, sortOrder: 0),
        (seriesId: 9, sortOrder: 2),
      ]);
      expect(
          split.entryOrders,
          <({String mediaType, String entryKey, int sortOrder})>[
            (mediaType: 'epub', entryKey: 'bookA', sortOrder: 1),
            (mediaType: 'srt', entryKey: 'uidB', sortOrder: 3),
          ]);
    });
  });

  group('R1 DB write-through (same primitives as _persistShelfOrder)', () {
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
        'folded reorder: series card index -> Series.sortOrder, loose -> ShelfEntries.sortOrder',
        () async {
      final int sid = await db.createSeries('S');
      final List<ShelfReorderItem> ordered = <ShelfReorderItem>[
        const ShelfReorderItem(
            mediaType: 'epub', entryKey: 'bookA', card: SizedBox()),
        ShelfReorderItem(
          mediaType: 'series',
          entryKey: 'series_$sid',
          seriesId: sid,
          seriesCardId: sid,
          card: const SizedBox(),
        ),
      ];
      final split = splitShelfReorderOrders(ordered);
      for (final so in split.seriesOrders) {
        await db.updateSeriesSortOrder(so.seriesId, so.sortOrder);
      }
      await db.batchUpsertShelfOrder(split.entryOrders);

      final SeriesRow? row = await db.getSeriesById(sid);
      expect(row!.sortOrder, 1,
          reason: 'series card index -> Series.sortOrder');
      final ShelfEntryRow? entry = await db.getShelfEntry('epub', 'bookA');
      expect(entry!.sortOrder, 0,
          reason: 'loose index -> ShelfEntries.sortOrder');
    });

    test('member reorder writes ShelfEntries.sortOrder, membership untouched',
        () async {
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry('epub', 'm1', sid);
      await db.setSeriesForEntry('epub', 'm2', sid);
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
      expect((await db.getShelfEntry('epub', 'm1'))!.seriesId, sid);
      expect((await db.getShelfEntry('epub', 'm2'))!.seriesId, sid);
    });

    test(
        'move member out: only that entry seriesId=NULL, others sortOrder unshifted',
        () async {
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry('epub', 'm1', sid);
      await db.setSeriesForEntry('epub', 'm2', sid);
      await db.upsertShelfOrder('epub', 'loose', 7);

      await db.setSeriesForEntry('epub', 'm1', null);
      expect((await db.getShelfEntry('epub', 'm1'))!.seriesId, isNull);
      expect((await db.getShelfEntry('epub', 'm2'))!.seriesId, sid);
      expect((await db.getShelfEntry('epub', 'loose'))!.sortOrder, 7,
          reason: 'move-out does not shift other books sortOrder (stable key)');
    });
  });

  group('R2 sort-mode tap enters member view only for a series card', () {
    testWidgets('tap series card -> onEnterSeries(id); tap loose does not',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 700);
      addTearDown(tester.view.reset);

      final List<int> entered = <int>[];
      await tester.pumpWidget(
        wrap(Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => ShelfReorderPage(
              title: 'Edit order',
              cellExtent: 200,
              childAspectRatio: 1,
              initialItems: const <ShelfReorderItem>[
                ShelfReorderItem(
                  mediaType: 'series',
                  entryKey: 'series_42',
                  seriesId: 42,
                  seriesCardId: 42,
                  card: Center(child: Text('SERIES')),
                ),
                ShelfReorderItem(
                  mediaType: 'epub',
                  entryKey: 'bookA',
                  card: Center(child: Text('LOOSE')),
                ),
              ],
              onPersist: (_) async {},
              onEnterSeries: (int id) async => entered.add(id),
              rebuildItems: () async => const <ShelfReorderItem>[],
            ),
          ),
        )),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('LOOSE'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(entered, isEmpty,
          reason: 'R2: tap loose does not enter/open book');

      await tester.tap(find.text('SERIES'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(entered, <int>[42],
          reason: 'R2: tap series card enters member view');
    });

    testWidgets(
        'no onActivate -> grid ignores tap (pure-drag regression guard)',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 700);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrap(Scaffold(
          body: HibikiReorderableGrid(
            itemCount: 2,
            cellExtent: 200,
            childAspectRatio: 1,
            keyForIndex: (int i) => ValueKey<int>(i),
            itemBuilder: (_, int i) => Center(child: Text('C$i')),
            onReorder: (_, __) {},
          ),
        )),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('C0'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(HibikiReorderableGrid), findsOneWidget);
    });
  });

  group('H1 folded reorder flushed before entering series (no silent loss)',
      () {
    testWidgets(
        'dirty reorder -> tap series persists NEW order before onEnterSeries',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 700);
      addTearDown(tester.view.reset);

      // 事件时间线：折叠层拖动重排 -> 点进系列 -> 返回 rebuild。断言 persist 发生在 enter
      // 之前且落的是新序（不是 initialItems 旧序），否则返回后 rebuild 会静默丢弃重排。
      final List<String> events = <String>[];
      List<String>? persistedOrder;

      await tester.pumpWidget(
        wrap(Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => ShelfReorderPage(
              title: 'Edit order',
              cellExtent: 200,
              childAspectRatio: 1,
              initialItems: const <ShelfReorderItem>[
                ShelfReorderItem(
                  mediaType: 'series',
                  entryKey: 'series_7',
                  seriesId: 7,
                  seriesCardId: 7,
                  card: Center(child: Text('SERIES')),
                ),
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
                events.add('persist');
                persistedOrder = <String>[
                  for (final ShelfReorderItem it in ordered) it.entryKey,
                ];
              },
              onEnterSeries: (int id) async => events.add('enter:$id'),
              // 返回后 rebuild 读「DB」序：这里回放已落盘的新序，模拟真实 _loadShelfOrder。
              rebuildItems: () async {
                events.add('rebuild');
                return <ShelfReorderItem>[
                  for (final String key in persistedOrder ?? const <String>[])
                    ShelfReorderItem(
                      mediaType: key.startsWith('series_') ? 'series' : 'epub',
                      entryKey: key,
                      seriesId: key.startsWith('series_') ? 7 : null,
                      seriesCardId: key.startsWith('series_') ? 7 : null,
                      card: const SizedBox(),
                    ),
                ];
              },
            ),
          ),
        )),
      );
      await tester.pumpAndSettle();

      // 拿到真实网格实例，直接驱动它的 onReorder/onActivate —— 这些正是页面的私有
      // _onReorder/_onActivate（不靠脆弱的坐标拖拽几何）。
      final HibikiReorderableGrid grid = tester
          .widget<HibikiReorderableGrid>(find.byType(HibikiReorderableGrid));

      // 折叠层拖动：把 bookB(2) 移到最前(0)。新序应为 [bookB, series_7, bookA]，_dirty=true。
      grid.onReorder(2, 0);
      await tester.pump();

      // 点进系列卡（现位于 index 1）。onActivate 静态类型为 void 回调（页面的
      // Future<void> _onActivate 被赋给它），不能 await 其返回值；触发后用 pumpAndSettle
      // 抽干页面内部 await 链。
      grid.onActivate!(1);
      await tester.pumpAndSettle();

      // persist 必须在 enter 之前发生（H1 根因：不先落盘则返回后 rebuild 用旧序覆盖）。
      expect(events, <String>['persist', 'enter:7', 'rebuild'],
          reason:
              'H1: dirty folded reorder must be flushed BEFORE entering the '
              'series so the return-side rebuild reads the new DB order');
      // 落盘的是重排后的新序，不是 initialItems 旧序。
      expect(persistedOrder, <String>['bookB', 'series_7', 'bookA'],
          reason: 'H1: persisted order is the in-memory reordered order');
    });

    testWidgets('clean (not dirty) tap does NOT persist before entering',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 700);
      addTearDown(tester.view.reset);

      final List<String> events = <String>[];
      await tester.pumpWidget(
        wrap(Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => ShelfReorderPage(
              title: 'Edit order',
              cellExtent: 200,
              childAspectRatio: 1,
              initialItems: const <ShelfReorderItem>[
                ShelfReorderItem(
                  mediaType: 'series',
                  entryKey: 'series_3',
                  seriesId: 3,
                  seriesCardId: 3,
                  card: Center(child: Text('SERIES')),
                ),
              ],
              onPersist: (_) async => events.add('persist'),
              onEnterSeries: (int id) async => events.add('enter:$id'),
              rebuildItems: () async => const <ShelfReorderItem>[],
            ),
          ),
        )),
      );
      await tester.pumpAndSettle();

      final HibikiReorderableGrid grid = tester
          .widget<HibikiReorderableGrid>(find.byType(HibikiReorderableGrid));
      // 未拖动 => _dirty=false => 进系列前不做无谓落盘（避免空写）。
      grid.onActivate!(0);
      await tester.pumpAndSettle();
      expect(events, <String>['enter:3'],
          reason:
              'no reorder means no flush before entering (avoids empty write)');
    });
  });

  group('R4 single-member series still folds / enters', () {
    testWidgets('single series card (single-member series) is still enterable',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 700);
      addTearDown(tester.view.reset);

      final List<int> entered = <int>[];
      await tester.pumpWidget(
        wrap(Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => ShelfReorderPage(
              title: 'Edit order',
              cellExtent: 200,
              childAspectRatio: 1,
              initialItems: <ShelfReorderItem>[
                ShelfReorderItem(
                  mediaType: 'series',
                  entryKey: 'series_1',
                  seriesId: 1,
                  seriesCardId: 1,
                  card: SeriesShelfCard(
                    name: 'Solo',
                    itemCount: 1,
                    slotAspectRatio: 1,
                    covers: const <Widget>[ColoredBox(color: Colors.blue)],
                    onTap: () {},
                  ),
                ),
              ],
              onPersist: (_) async {},
              onEnterSeries: (int id) async => entered.add(id),
              rebuildItems: () async => const <ShelfReorderItem>[],
            ),
          ),
        )),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SeriesShelfCard), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(entered, <int>[1],
          reason: 'R4: single-member series still enterable');
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
