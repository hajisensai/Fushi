import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v60 迁移：`reading_statistics` 增加 `pages_read`（漫画/PDF 的页数维度）。
///
/// 漫画此前只落时长、`characters_read` 恒 0，统计页永远「0 字 0 页」。现在字数
/// （OCR 实义字符，口径与 EPUB 同源）与页数各占一列，两个量纲独立累加——页数
/// 绝不塞进 characters_read，否则会污染字数口径与阅读速度。
///
/// 打开一个 user_version=59 的库（v59 shape：reading_statistics 无 pages_read），
/// 触发真实的 `if (from < 60)` addColumn，验证：
///  ① 旧统计行原样保留，新列回填 0（Never break userspace）；
///  ② 新列可写可累加，且与字数互不影响；
///  ③ fresh 库由 onCreate 直接建出该列。
void main() {
  Future<FushiDatabase> openV59Db() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v59 shape：没有 pages_read 列。
          rawDb.execute('''
CREATE TABLE reading_statistics (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  date_key TEXT NOT NULL,
  characters_read INTEGER NOT NULL,
  reading_time_ms INTEGER NOT NULL,
  last_statistic_modified INTEGER NOT NULL,
  UNIQUE (title, date_key)
)
''');
          // 统计删除墓碑表自 v-早期就在；新建统计行会清它，真实 v59 库必有此表。
          rawDb.execute('''
CREATE TABLE statistics_tombstones (
  title TEXT NOT NULL,
  source_type TEXT NOT NULL,
  deleted_at INTEGER NOT NULL,
  PRIMARY KEY (title, source_type)
)
''');
          rawDb.execute(
            'INSERT INTO reading_statistics '
            '(title, date_key, characters_read, reading_time_ms, '
            'last_statistic_modified) '
            "VALUES ('旧書', '2026-07-01', 4321, 600000, 1700000000000)",
          );
          rawDb.execute('PRAGMA user_version = 59');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v60：旧统计行零破坏，pages_read 回填 0', () async {
    final FushiDatabase db = await openV59Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 80, reason: 'v60 = reading_statistics.pages_read');

    final List<ReadingStatisticRow> rows = await db.getAllReadingStatistics();
    expect(rows, hasLength(1));
    expect(rows.single.title, '旧書');
    expect(rows.single.charactersRead, 4321, reason: '旧字数原样保留');
    expect(rows.single.readingTimeMs, 600000);
    expect(rows.single.pagesRead, 0, reason: '新列对旧行必须是 0，而不是猜出来的值');
  });

  test('v60：页数与字数各自独立累加', () async {
    final FushiDatabase db = await openV59Db();

    // 漫画：同一天两段会话，字数与页数分别累加。
    await db.addReadingStatistic(
      title: '漫画',
      dateKey: '2026-07-28',
      charsRead: 200,
      timeMs: 60000,
      pagesRead: 8,
    );
    await db.addReadingStatistic(
      title: '漫画',
      dateKey: '2026-07-28',
      charsRead: 90,
      timeMs: 30000,
      pagesRead: 4,
    );
    // EPUB：不传页数 → 页数保持 0，字数照常涨。
    await db.addReadingStatistic(
      title: '旧書',
      dateKey: '2026-07-01',
      charsRead: 1000,
      timeMs: 60000,
    );

    final List<ReadingStatisticRow> rows = await db.getAllReadingStatistics();
    final ReadingStatisticRow manga =
        rows.firstWhere((ReadingStatisticRow r) => r.title == '漫画');
    final ReadingStatisticRow book =
        rows.firstWhere((ReadingStatisticRow r) => r.title == '旧書');
    expect(manga.charactersRead, 290);
    expect(manga.pagesRead, 12);
    expect(book.charactersRead, 5321);
    expect(book.pagesRead, 0);
  });

  test('v60：fresh 库由 onCreate 直接建出该列（不依赖迁移梯子）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.addReadingStatistic(
      title: '漫画',
      dateKey: '2026-07-28',
      charsRead: 10,
      timeMs: 1000,
      pagesRead: 3,
    );
    expect((await db.getAllReadingStatistics()).single.pagesRead, 3);
  });
}
