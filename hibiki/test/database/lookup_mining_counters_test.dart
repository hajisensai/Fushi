import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-1204: lookup / mining per-book counters (lookup_mining_counters).
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

LookupMiningCounterRow? _rowFor(
  List<LookupMiningCounterRow> rows, {
  required String title,
  required String sourceType,
  required String dateKey,
}) {
  for (final LookupMiningCounterRow r in rows) {
    if (r.title == title &&
        r.sourceType == sourceType &&
        r.dateKey == dateKey) {
      return r;
    }
  }
  return null;
}

void main() {
  group('LookupMiningCounters addLookupCount', () {
    test('accumulates +1 per call on the same (title, source, date)', () async {
      final HibikiDatabase db = await _openDb();
      const String title = 'BookA';
      for (int i = 0; i < 3; i++) {
        await db.addLookupCount(
          bookKey: 'book/A',
          title: title,
          sourceType: 'book',
          dateKey: '2026-07-05',
        );
      }
      final List<LookupMiningCounterRow> rows =
          await db.getLookupMiningCountersBySource('book');
      expect(rows.length, 1);
      final LookupMiningCounterRow row = rows.single;
      expect(row.lookupCount, 3);
      expect(row.mineCount, 0);
      expect(row.bookKey, 'book/A');
      expect(row.title, title);
    });

    test('no-book lookup (title empty, bookKey null) stays global', () async {
      final HibikiDatabase db = await _openDb();
      await db.addLookupCount(sourceType: 'book', dateKey: '2026-07-05');
      await db.addLookupCount(sourceType: 'book', dateKey: '2026-07-05');
      final List<LookupMiningCounterRow> rows =
          await db.getLookupMiningCountersBySource('book');
      expect(rows.length, 1);
      expect(rows.single.title, '');
      expect(rows.single.bookKey, isNull);
      expect(rows.single.lookupCount, 2);
    });

    test('different dates / sources create separate rows', () async {
      final HibikiDatabase db = await _openDb();
      await db.addLookupCount(
          title: 'X', sourceType: 'book', dateKey: '2026-07-05');
      await db.addLookupCount(
          title: 'X', sourceType: 'book', dateKey: '2026-07-06');
      await db.addLookupCount(
          title: 'X', sourceType: 'video', dateKey: '2026-07-05');
      expect((await db.getLookupMiningCountersBySource('book')).length, 2);
      expect((await db.getLookupMiningCountersBySource('video')).length, 1);
    });
  });

  group('LookupMiningCounters addMineCountPerBook', () {
    test('accumulates mineCount independently of lookupCount', () async {
      final HibikiDatabase db = await _openDb();
      await db.addLookupCount(
          bookKey: 'book/A', title: 'A', sourceType: 'book', dateKey: 'd1');
      await db.addMineCountPerBook(
          bookKey: 'book/A', title: 'A', sourceType: 'book', dateKey: 'd1');
      await db.addMineCountPerBook(
          bookKey: 'book/A', title: 'A', sourceType: 'book', dateKey: 'd1');
      final LookupMiningCounterRow row =
          (await db.getLookupMiningCountersBySource('book')).single;
      expect(row.lookupCount, 1);
      expect(row.mineCount, 2);
    });
  });

  group('LookupMiningCounters MAX-union set*', () {
    test('is idempotent: re-applying the same snapshot never double-counts',
        () async {
      final HibikiDatabase db = await _openDb();
      for (int i = 0; i < 2; i++) {
        await db.setLookupCount(
            title: 'A', sourceType: 'book', dateKey: 'd1', count: 7);
        await db.setMineCountPerBook(
            title: 'A', sourceType: 'book', dateKey: 'd1', count: 4);
      }
      final LookupMiningCounterRow row =
          (await db.getLookupMiningCountersBySource('book')).single;
      expect(row.lookupCount, 7);
      expect(row.mineCount, 4);
    });

    test('set only raises to the max, never lowers', () async {
      final HibikiDatabase db = await _openDb();
      await db.setLookupCount(
          title: 'A', sourceType: 'book', dateKey: 'd1', count: 10);
      await db.setLookupCount(
          title: 'A', sourceType: 'book', dateKey: 'd1', count: 3);
      final LookupMiningCounterRow row =
          (await db.getLookupMiningCountersBySource('book')).single;
      expect(row.lookupCount, 10);
    });
  });

  group('LookupMiningCounters aggregation by source/title', () {
    test('getLookupMiningCountersBySource filters by sourceType', () async {
      final HibikiDatabase db = await _openDb();
      await db.addLookupCount(title: 'A', sourceType: 'book', dateKey: 'd1');
      await db.addLookupCount(title: 'V', sourceType: 'video', dateKey: 'd1');
      expect(
          (await db.getLookupMiningCountersBySource('book')).single.title, 'A');
      expect((await db.getLookupMiningCountersBySource('video')).single.title,
          'V');
    });

    test('per-title totals across dates aggregate correctly', () async {
      final HibikiDatabase db = await _openDb();
      await db.addLookupCount(title: 'A', sourceType: 'book', dateKey: 'd1');
      await db.addLookupCount(title: 'A', sourceType: 'book', dateKey: 'd2');
      await db.addMineCountPerBook(
          title: 'A', sourceType: 'book', dateKey: 'd2');
      final List<LookupMiningCounterRow> rows =
          await db.getLookupMiningCountersBySource('book');
      int lookups = 0;
      int mines = 0;
      for (final LookupMiningCounterRow r in rows) {
        if (r.title == 'A') {
          lookups += r.lookupCount;
          mines += r.mineCount;
        }
      }
      expect(lookups, 2);
      expect(mines, 1);
      final LookupMiningCounterRow? d2 =
          _rowFor(rows, title: 'A', sourceType: 'book', dateKey: 'd2');
      expect(d2, isNotNull);
      expect(d2!.lookupCount, 1);
      expect(d2.mineCount, 1);
    });

    test('getAllLookupMiningCounters returns rows across all sources',
        () async {
      final HibikiDatabase db = await _openDb();
      await db.addLookupCount(title: 'A', sourceType: 'book', dateKey: 'd1');
      await db.addLookupCount(title: 'V', sourceType: 'video', dateKey: 'd1');
      final List<LookupMiningCounterRow> all =
          await db.getAllLookupMiningCounters();
      expect(all.length, 2);
      expect(all.map((LookupMiningCounterRow r) => r.sourceType).toSet(),
          <String>{'book', 'video'});
    });
  });
}
