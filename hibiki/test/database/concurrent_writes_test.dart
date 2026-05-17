import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('Concurrent ReadingStatistics writes', () {
    test('50 concurrent addReadingStatistic calls aggregate correctly',
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

    test('concurrent writes to different titles stay independent', () async {
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

  group('Concurrent HourlyLogs writes', () {
    test('50 concurrent addHourlyReadingTime calls aggregate correctly',
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

    test('concurrent writes to different hours stay independent', () async {
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

  group('Concurrent Preferences writes', () {
    test('50 concurrent setPref on same key - last write wins', () async {
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
      final intVal = int.parse(value!);
      expect(intVal, inInclusiveRange(0, n - 1));
    });

    test('concurrent setPref on different keys all persist', () async {
      final db = await _openDb();
      const int n = 30;

      await Future.wait(
        List.generate(n, (i) => db.setPref('key_$i', 'val_$i')),
      );

      final all = await db.getAllPrefs();
      expect(all.length, n);
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

      final z = await db.getPref('z');
      expect(z, '4');
    });
  });

  group('Concurrent ReaderPositions writes', () {
    test('rapid upserts to same book converge', () async {
      final db = await _openDb();
      const int n = 30;

      await Future.wait(
        List.generate(
          n,
          (i) => db.upsertReaderPosition(
            ReaderPositionsCompanion.insert(
              ttuBookId: 1,
              sectionIndex: i % 10,
              normCharOffset: i * 100,
              updatedAt: DateTime.now().millisecondsSinceEpoch + i,
            ),
          ),
        ),
      );

      final row = await db.getReaderPosition(1);
      expect(row, isNotNull);
    });

    test('concurrent upserts to different books all persist', () async {
      final db = await _openDb();
      const int n = 20;

      await Future.wait(
        List.generate(
          n,
          (i) => db.upsertReaderPosition(
            ReaderPositionsCompanion.insert(
              ttuBookId: i,
              sectionIndex: i,
              normCharOffset: i * 100,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ),
        ),
      );

      for (int i = 0; i < n; i++) {
        final row = await db.getReaderPosition(i);
        expect(row, isNotNull, reason: 'book $i should exist');
      }
    });
  });
}
