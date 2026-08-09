import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v76 迁移（v39 的另一半）：`lookup_mining_counters` 的 `book_key` 进唯一键，
/// 根治同名不同视频的查词/制卡计数互串。
///
///  - NULL → ''（列改 NOT NULL DEFAULT ''）；
///  - 唯一键 {title,source_type,date_key} → {book_key,title,source_type,date_key}；
///  - 按 title 唯一匹配回填身份（v39 同判据）：book 行 JOIN epub_books、video 行
///    JOIN video_books；同名多条目/无匹配保持 ''。
void main() {
  Future<FushiDatabase> openV75Db() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v75 时代的旧表：book_key 可空、唯一键不含身份。
          rawDb.execute('''
CREATE TABLE lookup_mining_counters (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT,
  title TEXT NOT NULL DEFAULT '',
  source_type TEXT NOT NULL,
  date_key TEXT NOT NULL,
  lookup_count INTEGER NOT NULL DEFAULT 0,
  mine_count INTEGER NOT NULL DEFAULT 0,
  UNIQUE (title, source_type, date_key)
)
''');
          // 回填 JOIN 面（只需 title/身份列；其余列给满足 NOT NULL 的最小集）。
          rawDb.execute('''
CREATE TABLE epub_books (
  book_key TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL
)
''');
          rawDb.execute('''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL
)
''');
          // addLookupCount / addMineCountPerBook 建行时清墓碑要摸这张表。
          rawDb.execute('''
CREATE TABLE statistics_tombstones (
  title TEXT NOT NULL,
  source_type TEXT NOT NULL,
  deleted_at INTEGER NOT NULL,
  PRIMARY KEY (title, source_type)
)
''');
          rawDb.execute(
              "INSERT INTO epub_books (book_key, title) VALUES ('bk-a', '吾輩は猫である')");
          rawDb.execute(
              "INSERT INTO video_books (book_uid, title) VALUES ('uid-u', '独占名视频')");
          // 同名双视频：回填必须放弃（保持 ''），不许瞎猜归属。
          rawDb.execute(
              "INSERT INTO video_books (book_uid, title) VALUES ('uid-1', '同名')");
          rawDb.execute(
              "INSERT INTO video_books (book_uid, title) VALUES ('uid-2', '同名')");

          // 旧计数行：全部 book_key NULL（v76 前部分写入方也确实存过 NULL）。
          rawDb.execute(
              'INSERT INTO lookup_mining_counters (book_key, title, source_type, date_key, lookup_count, mine_count) '
              "VALUES (NULL, '吾輩は猫である', 'book', '2026-08-01', 3, 1)");
          rawDb.execute(
              'INSERT INTO lookup_mining_counters (book_key, title, source_type, date_key, lookup_count, mine_count) '
              "VALUES (NULL, '独占名视频', 'video', '2026-08-01', 5, 2)");
          rawDb.execute(
              'INSERT INTO lookup_mining_counters (book_key, title, source_type, date_key, lookup_count, mine_count) '
              "VALUES (NULL, '同名', 'video', '2026-08-01', 7, 0)");
          rawDb.execute(
              'INSERT INTO lookup_mining_counters (book_key, title, source_type, date_key, lookup_count, mine_count) '
              "VALUES (NULL, '', 'book', '2026-08-01', 11, 0)");
          rawDb.execute('PRAGMA user_version = 75');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v76：NULL 归一 + 唯一匹配回填 + 歧义保 空 + 零丢行', () async {
    final FushiDatabase db = await openV75Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 76,
        reason: 'v76 给 lookup_mining_counters 的 book_key 进唯一键');

    final List<LookupMiningCounterRow> rows =
        await db.getAllLookupMiningCounters();
    expect(rows, hasLength(4), reason: '迁移零丢行');

    LookupMiningCounterRow byTitle(String title) =>
        rows.singleWhere((LookupMiningCounterRow r) => r.title == title);

    expect(byTitle('吾輩は猫である').bookKey, 'bk-a',
        reason: 'book 行按 epub_books.title 唯一匹配回填');
    expect(byTitle('吾輩は猫である').lookupCount, 3, reason: '计数原样保留');
    expect(byTitle('独占名视频').bookKey, 'uid-u',
        reason: 'video 行按 video_books.title 唯一匹配回填');
    expect(byTitle('同名').bookKey, '',
        reason: '同名双视频归属不可判，保持无身份（读取端按 title 回退归并）');
    expect(byTitle('').bookKey, '', reason: '无书查词行保持无身份');
    expect(byTitle('').lookupCount, 11);
  });

  test('v76 后：同名双视频各记各行（唯一键含身份，不再互串）', () async {
    final FushiDatabase db = await openV75Db();

    await db.addLookupCount(
        bookKey: 'uid-1',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-08-02');
    await db.addLookupCount(
        bookKey: 'uid-2',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-08-02');
    await db.addLookupCount(
        bookKey: 'uid-2',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-08-02');

    final List<LookupMiningCounterRow> rows =
        (await db.getAllLookupMiningCounters())
            .where((LookupMiningCounterRow r) => r.dateKey == '2026-08-02')
            .toList();
    expect(rows, hasLength(2), reason: '两个身份两行，不合并');
    expect(
        rows
            .singleWhere((LookupMiningCounterRow r) => r.bookKey == 'uid-1')
            .lookupCount,
        1);
    expect(
        rows
            .singleWhere((LookupMiningCounterRow r) => r.bookKey == 'uid-2')
            .lookupCount,
        2);
  });

  test('v76 后：遗留无身份行与新带身份行并存，各自独立累加', () async {
    final FushiDatabase db = await openV75Db();

    // 迁移后「同名」行是无身份遗留（lookup=7）；新查词带 uid-1。
    await db.addLookupCount(
        bookKey: 'uid-1',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-08-01');

    final List<LookupMiningCounterRow> rows =
        (await db.getAllLookupMiningCounters())
            .where((LookupMiningCounterRow r) =>
                r.title == '同名' && r.dateKey == '2026-08-01')
            .toList();
    expect(rows, hasLength(2), reason: '遗留 空身份 行不被新写入吞并');
    expect(
        rows
            .singleWhere((LookupMiningCounterRow r) => r.bookKey == '')
            .lookupCount,
        7);
    expect(
        rows
            .singleWhere((LookupMiningCounterRow r) => r.bookKey == 'uid-1')
            .lookupCount,
        1);
  });

  test('set*（sync 写回，title 粒度）：wire 不超过本地和绝不塌缩；超过才塌单一权威行', () async {
    final FushiDatabase db = await openV75Db();

    // 造多行：遗留行（lookup=7）+ uid-1 行（lookup=1, mine=2）。
    await db.addLookupCount(
        bookKey: 'uid-1',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-08-01');
    await db.addMineCountPerBook(
        bookKey: 'uid-1',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-08-01',
        delta: 2);

    // wire 合并值 6 ≤ 本地和 8 → 完全 no-op：不塌缩、不动任何行（review-5：
    // sync 自回声每轮都塌一次会把 per-identity 修复周期性回退、tile 震荡）。
    await db.setLookupCount(
        title: '同名', sourceType: 'video', dateKey: '2026-08-01', count: 6);

    List<LookupMiningCounterRow> rows = (await db.getAllLookupMiningCounters())
        .where((LookupMiningCounterRow r) =>
            r.title == '同名' && r.dateKey == '2026-08-01')
        .toList();
    expect(rows, hasLength(2), reason: 'wire 无新知 → per-identity 行原样保留');
    expect(
        rows
            .singleWhere((LookupMiningCounterRow r) => r.bookKey == 'uid-1')
            .lookupCount,
        1);

    // wire 值 10 > 本地和 8 → 才塌成单一 '' 权威行（v39 title 粒度决策）。
    await db.setLookupCount(
        title: '同名', sourceType: 'video', dateKey: '2026-08-01', count: 10);
    rows = (await db.getAllLookupMiningCounters())
        .where((LookupMiningCounterRow r) =>
            r.title == '同名' && r.dateKey == '2026-08-01')
        .toList();
    expect(rows, hasLength(1), reason: 'wire 真的知道更多才塌缩');
    expect(rows.single.bookKey, '', reason: '混桶归因不可判，如实标无身份');
    expect(rows.single.lookupCount, 10);
  });

  test('review3-4：单行身份与 wire 错配时不许行内抬升，塌 空 行如实标未归因', () async {
    final FushiDatabase db = await openV75Db();

    // 本地只有 uid-1 的行（lookup=2）。
    await db.addLookupCount(
        bookKey: 'uid-1',
        title: '错配',
        sourceType: 'video',
        dateKey: '2026-08-03',
        delta: 2);

    // wire 混桶（bookKey null）总量 7 > 本地和 2 → 不许把 7 记到 uid-1 头上。
    await db.setLookupCount(
        title: '错配', sourceType: 'video', dateKey: '2026-08-03', count: 7);

    final List<LookupMiningCounterRow> rows =
        (await db.getAllLookupMiningCounters())
            .where((LookupMiningCounterRow r) => r.title == '错配')
            .toList();
    expect(rows, hasLength(1));
    expect(rows.single.bookKey, '',
        reason: '身份错配 → 塌 空 行，别的视频的查词不得挂到 uid-1 的 tile 上');
    expect(rows.single.lookupCount, 7);

    // 身份一致时仍走行内抬升、身份保留。
    await db.addLookupCount(
        bookKey: 'uid-9',
        title: '一致',
        sourceType: 'video',
        dateKey: '2026-08-03',
        delta: 1);
    await db.setLookupCount(
        bookKey: 'uid-9',
        title: '一致',
        sourceType: 'video',
        dateKey: '2026-08-03',
        count: 5);
    final LookupMiningCounterRow kept = (await db.getAllLookupMiningCounters())
        .singleWhere((LookupMiningCounterRow r) => r.title == '一致');
    expect(kept.bookKey, 'uid-9', reason: '身份一致行内抬升，身份保留');
    expect(kept.lookupCount, 5);
  });

  test('fresh 库由 onCreate 直接建出 v76 键形（含身份唯一键）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.addLookupCount(
        bookKey: 'uid-1',
        title: 'T',
        sourceType: 'video',
        dateKey: '2026-08-01');
    await db.addLookupCount(
        bookKey: 'uid-2',
        title: 'T',
        sourceType: 'video',
        dateKey: '2026-08-01');
    expect(await db.getAllLookupMiningCounters(), hasLength(2));
  });
}
