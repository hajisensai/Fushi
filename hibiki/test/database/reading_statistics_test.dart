import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final db = FushiDatabase.forTesting(NativeDatabase.memory());
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
        format: BookFormat.epub,
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
        format: BookFormat.epub,
      );

      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 14,
        deltaMs: 5000,
        format: BookFormat.epub,
      );

      final logs = await db.getHourlyLogsForDate('2026-05-16');
      expect(logs, hasLength(1));
      expect(logs.single.readingTimeMs, 15000);
    });

    test('same hour different formats stay separate rows (v67)', () async {
      final db = await _openDb();
      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 15,
        deltaMs: 1200000,
        format: BookFormat.epub,
      );
      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 15,
        deltaMs: 600000,
        format: BookFormat.manga,
      );

      final logs = await db.getHourlyLogsForDate('2026-05-16');
      expect(logs, hasLength(2));
      final epub = logs.singleWhere((l) => l.format == BookFormat.epub.dbValue);
      final manga =
          logs.singleWhere((l) => l.format == BookFormat.manga.dbValue);
      expect(epub.readingTimeMs, 1200000);
      expect(manga.readingTimeMs, 600000);
    });

    test('unattributed bucket accumulates under empty format', () async {
      final db = await _openDb();
      await db.addUnattributedHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 16,
        deltaMs: 4000,
      );
      await db.addUnattributedHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 16,
        deltaMs: 2000,
      );

      final logs = await db.getHourlyLogsForDate('2026-05-16');
      expect(logs, hasLength(1));
      expect(logs.single.format, '');
      expect(logs.single.readingTimeMs, 6000);
    });

    test('setReadingHourlyLog overwrites per (dateKey, hour, format)',
        () async {
      final db = await _openDb();
      // 模拟未来版本 wire 里的新格式值：必须逐字节透传，不折叠进已知枚举。
      const String futureFormat = 'future_format';
      await db.setReadingHourlyLog(
        dateKey: '2026-05-16',
        hour: 17,
        readingTimeMs: 9000,
        format: 'epub',
      );
      await db.setReadingHourlyLog(
        dateKey: '2026-05-16',
        hour: 17,
        readingTimeMs: 7000,
        format: futureFormat,
      );
      await db.setReadingHourlyLog(
        dateKey: '2026-05-16',
        hour: 17,
        readingTimeMs: 9500,
        format: 'epub',
      );

      final logs = await db.getHourlyLogsForDate('2026-05-16');
      expect(logs, hasLength(2));
      expect(
          logs
              .singleWhere((l) => l.format == BookFormat.epub.dbValue)
              .readingTimeMs,
          9500);
      expect(
        logs.singleWhere((l) => l.format == futureFormat).readingTimeMs,
        7000,
      );
    });

    test('different hours create separate logs', () async {
      final db = await _openDb();
      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 10,
        deltaMs: 5000,
        format: BookFormat.epub,
      );
      await db.addHourlyReadingTime(
        dateKey: '2026-05-16',
        hour: 11,
        deltaMs: 3000,
        format: BookFormat.epub,
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
