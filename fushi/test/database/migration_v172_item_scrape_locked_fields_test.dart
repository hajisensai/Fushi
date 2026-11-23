import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v172：`item_scrape_meta.locked_fields`——条目资料的字段锁（书的简介手填后条目
/// 刮削不再覆盖，BUG-5111）。纯加列，存量 NULL = 无锁；按列存在性守卫，重跑幂等。
void main() {
  bool hasColumn(sqlite.Database raw, String table, String column) => raw
      .select('PRAGMA table_info($table)')
      .any((sqlite.Row row) => row['name'] == column);

  test('v171 → v172：加列、存量行原样且无锁；重跑幂等', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'item_scrape_lock_v172',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();

    // 退回 v171 的样子：没有 locked_fields 列，有一行存量刮削资料。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE item_scrape_meta DROP COLUMN locked_fields');
    raw.execute(
      'INSERT INTO item_scrape_meta '
      '(media_type, entry_key, source, summary, scraped_at) '
      "VALUES ('epub', 'b1', 'bangumi', '旧简介', 1)",
    );
    raw.execute('PRAGMA user_version = 171');
    expect(hasColumn(raw, 'item_scrape_meta', 'locked_fields'), isFalse);
    raw.dispose();

    FushiDatabase migrated = FushiDatabase.atFile(path, isMainProcess: false);
    expect(migrated.schemaVersion, 172);
    ItemScrapeMetaRow row = (await migrated.getItemScrapeMeta(
      MediaKind.epub,
      'b1',
    ))!;
    expect(row.summary, '旧简介');
    expect(row.lockedFields, isNull);
    await migrated.close();

    final sqlite.Database again = sqlite.sqlite3.open(path);
    expect(hasColumn(again, 'item_scrape_meta', 'locked_fields'), isTrue);
    again.execute(
      "UPDATE item_scrape_meta SET locked_fields = 'summary' "
      "WHERE entry_key = 'b1'",
    );
    again.execute('PRAGMA user_version = 171');
    again.dispose();

    migrated = FushiDatabase.atFile(path, isMainProcess: false);
    row = (await migrated.getItemScrapeMeta(MediaKind.epub, 'b1'))!;
    expect(row.lockedFields, 'summary', reason: '列已在时跳过，已有锁不丢');
    await migrated.close();
  });
}
