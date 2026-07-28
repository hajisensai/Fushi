import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('ReadingStatistics table', () {
    test('addReadingStatistic creates a new row', () async {
      final db = await _openDb();

      await db.addReadingStatistic(
        title: '吾輩は猫である',
        dateKey: '2026-05-16',
        charsRead: 100,
        timeMs: 60000,
      );

      final all = await db.getAllReadingStatistics();
      expect(all, hasLength(1));
      expect(all.single.title, '吾輩は猫である');
      expect(all.single.charactersRead, 100);
      expect(all.single.readingTimeMs, 60000);
    });

    test('addReadingStatistic aggregates into existing day', () async {
      final db = await _openDb();
      await db.addReadingStatistic(
        title: 'Book',
        dateKey: '2026-05-16',
        charsRead: 100,
        timeMs: 10000,
      );

      await db.addReadingStatistic(
        title: 'Book',
        dateKey: '2026-05-16',
        charsRead: 50,
        timeMs: 5000,
      );

      final all = await db.getAllReadingStatistics();
      expect(all, hasLength(1));
      expect(all.single.charactersRead, 150);
      expect(all.single.readingTimeMs, 15000);
    });

    test('pagesRead 默认 0，且与字数各自独立累加（v60）', () async {
      final db = await _openDb();
      // EPUB：只有字数，不传页数 → 页数恒 0。
      await db.addReadingStatistic(
        title: 'Novel',
        dateKey: '2026-07-28',
        charsRead: 800,
        timeMs: 60000,
      );
      // 漫画：字数与页数一起落，两个量纲互不顶替。
      await db.addReadingStatistic(
        title: 'Manga',
        dateKey: '2026-07-28',
        charsRead: 300,
        timeMs: 30000,
        pagesRead: 12,
      );
      await db.addReadingStatistic(
        title: 'Manga',
        dateKey: '2026-07-28',
        charsRead: 120,
        timeMs: 10000,
        pagesRead: 5,
      );

      final List<ReadingStatisticRow> all = await db.getAllReadingStatistics();
      final ReadingStatisticRow novel =
          all.firstWhere((ReadingStatisticRow r) => r.title == 'Novel');
      final ReadingStatisticRow manga =
          all.firstWhere((ReadingStatisticRow r) => r.title == 'Manga');
      expect(novel.pagesRead, 0);
      expect(novel.charactersRead, 800);
      expect(manga.charactersRead, 420);
      expect(manga.pagesRead, 17);
      expect(manga.readingTimeMs, 40000);
    });

    test('different dates create separate rows', () async {
      final db = await _openDb();
      await db.addReadingStatistic(
        title: 'Book',
        dateKey: '2026-05-15',
        charsRead: 100,
        timeMs: 10000,
      );
      await db.addReadingStatistic(
        title: 'Book',
        dateKey: '2026-05-16',
        charsRead: 200,
        timeMs: 20000,
      );

      expect(await db.getAllReadingStatistics(), hasLength(2));
    });

    test('different titles create separate rows on same date', () async {
      final db = await _openDb();
      await db.addReadingStatistic(
        title: 'Book A',
        dateKey: '2026-05-16',
        charsRead: 100,
        timeMs: 10000,
      );
      await db.addReadingStatistic(
        title: 'Book B',
        dateKey: '2026-05-16',
        charsRead: 200,
        timeMs: 20000,
      );

      expect(await db.getAllReadingStatistics(), hasLength(2));
    });
  });

  group('ReadingHourlyLogs table', () {
    test('addHourlyReadingTime creates entry for new hour', () async {
      final db = await _openDb();

      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 14,
        deltaMs: 30000,
      );

      final logs = await db.getHourlyLogsForDate('2026-05-16');
      expect(logs, hasLength(1));
      expect(logs.single.hour, 14);
      expect(logs.single.readingTimeMs, 30000);
    });

    test('addHourlyReadingTime aggregates into same hour', () async {
      final db = await _openDb();
      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 14,
        deltaMs: 10000,
      );

      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 14,
        deltaMs: 5000,
      );

      final logs = await db.getHourlyLogsForDate('2026-05-16');
      expect(logs, hasLength(1));
      expect(logs.single.readingTimeMs, 15000);
    });

    test('different hours create separate logs', () async {
      final db = await _openDb();
      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 10,
        deltaMs: 5000,
      );
      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 11,
        deltaMs: 3000,
      );

      final logs = await db.getHourlyLogsForDate('2026-05-16');
      expect(logs, hasLength(2));
    });

    test('getHourlyLogsForDate returns empty for absent date', () async {
      final db = await _openDb();

      expect(await db.getHourlyLogsForDate('2020-01-01'), isEmpty);
    });
  });
}
