import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v60 迁移：`reading_statistics` 增加 `pages_read`（漫画/PDF 的页数维度）。
///
/// 漫画此前只落时长、`characters_read` 恒 0，统计页永远「0 字 0 页」。现在字数
/// （OCR 实义字符，口径与 EPUB 同源）与页数各占一列，两个量纲独立——页数
/// 绝不塞进 characters_read，否则会污染字数口径与阅读速度。
///
/// 打开一个 user_version=59 的库（v59 shape：reading_statistics 无 pages_read），
/// 触发真实的 `if (from < 60)` addColumn，验证：
///  ① 旧统计行原样保留，新列回填 0（Never break userspace）；
///  ② 新列可写，且与字数互不影响；
///  ③ fresh 库由 onCreate 直接建出该列。
///
/// v92 起累加 DAO（addReadingStatistic）已删、legacy 表冻结：这里用同步落地的
/// OVERWRITE 版 [FushiDatabase.setReadingStatistic] 造行（累加用例随 DAO 删除，
/// 新事实进 study_segments）。
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
          // 统计删除墓碑表自 v-早期就在，真实 v59 库必有此表。
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
    expect(db.schemaVersion, 97, reason: 'v60 = reading_statistics.pages_read');

    final List<ReadingStatisticRow> rows = await db.getAllReadingStatistics();
    expect(rows, hasLength(1));
    expect(rows.single.title, '旧書');
    expect(rows.single.charactersRead, 4321, reason: '旧字数原样保留');
    expect(rows.single.readingTimeMs, 600000);
    expect(rows.single.pagesRead, 0, reason: '新列对旧行必须是 0，而不是猜出来的值');
  });

  test('v60：页数与字数各占一列、互不顶替', () async {
    final FushiDatabase db = await openV59Db();

    // 漫画：字数与页数一起落，两个量纲各存各的。
    await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: '漫画',
      dateKey: '2026-07-28',
      charactersRead: 290,
      readingTimeMs: 90000,
      pagesRead: const Value(12),
      lastStatisticModified: 1,
    ));
    // EPUB（迁移来的旧行）：只覆盖字数/时长，页数保持迁移回填的 0——
    // setReadingStatistic 冲突更新刻意不碰 pages_read（wire 契约不带它）。
    await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: '旧書',
      dateKey: '2026-07-01',
      charactersRead: 5321,
      readingTimeMs: 660000,
      lastStatisticModified: 2,
    ));

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

    await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: '漫画',
      dateKey: '2026-07-28',
      charactersRead: 10,
      readingTimeMs: 1000,
      pagesRead: const Value(3),
      lastStatisticModified: 1,
    ));
    expect((await db.getAllReadingStatistics()).single.pagesRead, 3);
  });
}
