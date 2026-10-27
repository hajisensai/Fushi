import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v120（BUG-3543）：srs_field_edits 加前身链接的部分覆盖索引
/// `idx_srs_field_edits_history_from`。只加索引、不动数据；重跑幂等。
///
/// 2026-10-23 起 SRS 表归 Rust 的 srs.db（那边的建表同样带这个索引）：新建的主库没有
/// srs_* 表；这里只验迁移阶梯上的老库（v119，带老 SRS 表）仍补上索引，好让一次性搬迁之前的
/// 读写照常走它。
void main() {
  const String index = 'idx_srs_field_edits_history_from';

  Set<String> indexesOf(sqlite.Database raw) => <String>{
    for (final sqlite.Row row in raw.select(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND tbl_name = 'srs_field_edits'",
    ))
      row['name'] as String,
  };

  test('v119 → v120 建部分索引，查询计划用它；已有的修改记录一行不动', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'srs_history_from_v120',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase fresh = FushiDatabase.atFile(path, isMainProcess: false);
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    // 退回 v119 形态：建出 v117 的老 SRS 表（不带 v120 索引），放两行修改记录（一条前身链接、
    // 一条普通字段）。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    expect(indexesOf(raw), isEmpty, reason: '新库没有 srs_field_edits（归 srs.db）');
    for (final String t in kLegacySrsV117Tables) {
      raw.execute(kLegacySrsTableDdl[t]!);
    }
    expect(indexesOf(raw), isNot(contains(index)));
    raw.execute(
      'INSERT INTO srs_field_edits '
      '(id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) '
      "VALUES ('e1', 'p', 'card', 'new-card', 'historyFrom/old-card', 'w', 1, '{}'), "
      "('e2', 'p', 'card', 'new-card', 'flag', 'w', 2, '{}')",
    );
    raw.execute('PRAGMA user_version = 119');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 136);
    // 与 SrsDbStore 的后继查询同一句 WHERE：读出前身链接，且计划走部分索引（不全表扫描）。
    final List<QueryRow> rows = await migrated
        .customSelect(
          'SELECT entity_id, field_key FROM srs_field_edits '
          'WHERE $kSrsHistoryFromCondition '
          "AND +entity_kind = 'card'",
        )
        .get();
    expect(rows.map((QueryRow r) => r.read<String>('field_key')), <String>[
      'historyFrom/old-card',
    ]);
    final String plan = (await migrated
            .customSelect(
              'EXPLAIN QUERY PLAN SELECT entity_id, field_key '
              'FROM srs_field_edits WHERE $kSrsHistoryFromCondition '
              "AND +entity_kind = 'card'",
            )
            .get())
        .map((QueryRow r) => r.read<String>('detail'))
        .join(' / ');
    expect(plan, contains('COVERING INDEX $index'), reason: plan);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 136);
    expect(indexesOf(probe), contains(index));
    expect(
      probe.select('SELECT COUNT(*) AS n FROM srs_field_edits').first['n'],
      2,
    );

    // 重跑 v120 步（IF NOT EXISTS）：不报错、索引仍在。
    probe.execute('PRAGMA user_version = 119');
    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await reopened.customSelect('SELECT 1').get();
    await reopened.close();
    expect(indexesOf(probe), contains(index));
    expect(probe.select('PRAGMA user_version').first.values.first, 136);
  });
}
