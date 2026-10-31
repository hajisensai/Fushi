import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v123：`srs_cards_cache.new_position`——新卡出卡位置（卡片修改记录 `newPos` 的
/// 生效值，「按词频重排新卡」写它）。
///
/// 迁移只加一列可空列、不动数据：存量缓存行留 NULL（存量库没有任何位置修改记录，
/// NULL 与事件一致，不必重建缓存）；重跑幂等。
///
/// 2026-10-23 起 SRS 表归 Rust 的 srs.db：新建的主库没有 srs_cards_cache；这里验迁移阶梯上带
/// 老 SRS 表的 v122 库仍补上这一列（一次性搬迁按带这一列的形状搬）。
void main() {
  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  test('v122 → v123 给 srs_cards_cache 加 new_position；存量行留 NULL；重跑幂等', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'srs_new_position_v123',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    expect(columnsOf(raw, 'srs_cards_cache'), isEmpty, reason: '新库没有 SRS 表');
    // 退回 v122 带老 SRS 表的形态：建出老表，去掉 v123 的列。
    for (final String t in kLegacySrsTableDdl.keys) {
      raw.execute(kLegacySrsTableDdl[t]!);
    }
    raw.execute('ALTER TABLE srs_cards_cache DROP COLUMN new_position');
    expect(columnsOf(raw, 'srs_cards_cache'), isNot(contains('new_position')));
    raw.execute(
      'INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id) '
      "VALUES ('c1', 'p1', 'n1', 't1', 'd1')",
    );
    raw.execute('PRAGMA user_version = 122');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 141);
    await migrated.getAllTags();
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 141);
    expect(columnsOf(probe, 'srs_cards_cache'), contains('new_position'));
    expect(
      probe
          .select("SELECT new_position FROM srs_cards_cache WHERE id = 'c1'")
          .first
          .values
          .first,
      isNull,
      reason: '存量缓存行没排过：NULL = 按笔记创建时刻出卡',
    );
    // 重跑 v123 步：列已在，不得报错、不得清数据。
    probe.execute(
      "UPDATE srs_cards_cache SET new_position = 7 WHERE id = 'c1'",
    );
    probe.execute('PRAGMA user_version = 122');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await reopened.getAllTags();
    await reopened.close();
    final sqlite.Database probe2 = sqlite.sqlite3.open(path);
    expect(probe2.select('PRAGMA user_version').first.values.first, 141);
    expect(
      probe2
          .select("SELECT new_position FROM srs_cards_cache WHERE id = 'c1'")
          .first
          .values
          .first,
      7,
    );
    probe2.dispose();
  });
}
