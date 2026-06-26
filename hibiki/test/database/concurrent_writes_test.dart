import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

// These tests verify that Drift's transaction-based read-modify-write
// correctly serializes interleaved async operations on a single isolate.
// This matches the app's real usage pattern (single-isolate DB access).
void main() {
  group('Interleaved ReadingStatistics writes', () {
    test('50 interleaved addReadingStatistic calls aggregate correctly',
        () async {
      final db = await _openDb();
      const int n = 50;
      const int charsPerCall = 10;
      const int msPerCall = 1000;

      await Future.wait(
        List.generate(
          n,
          (_) => db.addReadingStatistic(
            title: 'Book',
            dateKey: '2026-05-17',
            charsRead: charsPerCall,
            timeMs: msPerCall,
          ),
        ),
      );

      final all = await db.getAllReadingStatistics();
      expect(all, hasLength(1));
      expect(all.single.charactersRead, n * charsPerCall);
      expect(all.single.readingTimeMs, n * msPerCall);
    });

    test('interleaved writes to different titles stay independent', () async {
      final db = await _openDb();
      const int n = 20;

      await Future.wait([
        for (int i = 0; i < n; i++)
          db.addReadingStatistic(
            title: 'Book A',
            dateKey: '2026-05-17',
            charsRead: 5,
            timeMs: 500,
          ),
        for (int i = 0; i < n; i++)
          db.addReadingStatistic(
            title: 'Book B',
            dateKey: '2026-05-17',
            charsRead: 3,
            timeMs: 300,
          ),
      ]);

      final all = await db.getAllReadingStatistics();
      expect(all, hasLength(2));

      final bookA = all.firstWhere((s) => s.title == 'Book A');
      final bookB = all.firstWhere((s) => s.title == 'Book B');
      expect(bookA.charactersRead, n * 5);
      expect(bookB.charactersRead, n * 3);
    });
  });

  group('Interleaved HourlyLogs writes', () {
    test('50 interleaved addHourlyReadingTime calls aggregate correctly',
        () async {
      final db = await _openDb();
      const int n = 50;
      const int msPerCall = 200;

      await Future.wait(
        List.generate(
          n,
          (_) => db.addHourlyReadingTime(
            dateKey: '2026-05-17',
            hour: 14,
            deltaMs: msPerCall,
          ),
        ),
      );

      final logs = await db.getHourlyLogsForDate('2026-05-17');
      expect(logs, hasLength(1));
      expect(logs.single.readingTimeMs, n * msPerCall);
    });

    test('interleaved writes to different hours stay independent', () async {
      final db = await _openDb();
      const int n = 20;

      await Future.wait([
        for (int i = 0; i < n; i++)
          db.addHourlyReadingTime(
            dateKey: '2026-05-17',
            hour: 10,
            deltaMs: 100,
          ),
        for (int i = 0; i < n; i++)
          db.addHourlyReadingTime(
            dateKey: '2026-05-17',
            hour: 11,
            deltaMs: 200,
          ),
      ]);

      final logs = await db.getHourlyLogsForDate('2026-05-17');
      expect(logs, hasLength(2));

      final h10 = logs.firstWhere((l) => l.hour == 10);
      final h11 = logs.firstWhere((l) => l.hour == 11);
      expect(h10.readingTimeMs, n * 100);
      expect(h11.readingTimeMs, n * 200);
    });
  });

  group('Interleaved Preferences writes', () {
    test('50 interleaved setPref on same key produces valid final value',
        () async {
      final db = await _openDb();
      const int n = 50;

      await Future.wait(
        List.generate(
          n,
          (i) => db.setPref('counter', '$i'),
        ),
      );

      final value = await db.getPref('counter');
      expect(value, isNotNull);
      // Verify the value is a parseable integer and not corrupted
      expect(int.tryParse(value!), isNotNull,
          reason: 'value must be a valid integer string, not corrupted');
      // Only one row should exist — upsert should not duplicate
      final all = await db.getAllPrefs();
      expect(all.keys.where((k) => k == 'counter').length, 1);
    });

    test('interleaved setPref on different keys all persist', () async {
      final db = await _openDb();
      const int n = 30;

      await Future.wait(
        List.generate(n, (i) => db.setPref('key_$i', 'val_$i')),
      );

      final all = await db.getAllPrefs();
      // Exclude the prefs_version row: every setPref now auto-bumps the
      // cross-process change counter (TODO-855), adding one bookkeeping row on
      // top of the n user keys.
      final userKeys = all.keys
          .where((String k) => k != HibikiDatabase.prefsVersionKey)
          .toList();
      expect(userKeys.length, n);
      for (int i = 0; i < n; i++) {
        expect(all['key_$i'], 'val_$i');
      }
    });

    test('interleaved set and delete does not corrupt', () async {
      final db = await _openDb();

      await Future.wait([
        db.setPref('x', '1'),
        db.setPref('y', '2'),
        db.deletePref('x'),
        db.setPref('x', '3'),
        db.deletePref('y'),
        db.setPref('z', '4'),
      ]);

      final all = await db.getAllPrefs();
      // z is always set last with no competing delete
      expect(all['z'], '4');
      // x and y depend on execution order; verify no corruption
      for (final key in ['x', 'y']) {
        final v = all[key];
        expect(v == null || int.tryParse(v) != null, isTrue,
            reason: '$key must be absent or a valid integer, got: $v');
      }
    });
  });

  group('Interleaved ReaderPositions writes', () {
    test('rapid upserts to same book converge to the last writer', () async {
      final db = await _openDb();
      const int n = 30;
      // HBK-AUDIT-144: deterministic, strictly-increasing values per writer so
      // the converged row can be asserted (not just non-null). upsertReaderPosition
      // is an unconditional insert-or-replace on a single serialized connection,
      // so the last submitted write (i == n-1) executes last and must win.
      const int baseUpdatedAt = 1700000000000;

      await Future.wait(
        List.generate(
          n,
          (i) => db.upsertReaderPosition(
            ReaderPositionsCompanion.insert(
              bookKey: 'book-1',
              sectionIndex: i % 10,
              normCharOffset: i * 100,
              updatedAt: baseUpdatedAt + i,
            ),
          ),
        ),
      );

      final row = await db.getReaderPosition('book-1');
      expect(row, isNotNull);
      // Last-write-wins: the final row reflects the i == n-1 writer's values.
      expect(row!.sectionIndex, (n - 1) % 10);
      expect(row.normCharOffset, (n - 1) * 100);
      expect(row.updatedAt, baseUpdatedAt + (n - 1));
    });

    test('interleaved upserts to different books all persist', () async {
      final db = await _openDb();
      const int n = 20;

      await Future.wait(
        List.generate(
          n,
          (i) => db.upsertReaderPosition(
            ReaderPositionsCompanion.insert(
              bookKey: 'book-$i',
              sectionIndex: i,
              normCharOffset: i * 100,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ),
        ),
      );

      for (int i = 0; i < n; i++) {
        final row = await db.getReaderPosition('book-$i');
        expect(row, isNotNull, reason: 'book $i should exist');
      }
    });
  });
}
