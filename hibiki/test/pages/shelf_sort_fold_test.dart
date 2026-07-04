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

      await tester.tap(find.text('LOOSE'));
      await tester.pumpAndSettle();
      expect(entered, isEmpty,
          reason: 'R2: tap loose does not enter/open book');

      await tester.tap(find.text('SERIES'));
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
      await tester.tap(find.text('C0'));
      await tester.pumpAndSettle();
      expect(find.byType(HibikiReorderableGrid), findsOneWidget);
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

      await tester.tap(find.byType(SeriesShelfCard));
      await tester.pumpAndSettle();
      expect(entered, <int>[1],
          reason: 'R4: single-member series still enterable');
    });
  });
}
