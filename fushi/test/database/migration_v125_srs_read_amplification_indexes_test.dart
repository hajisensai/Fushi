import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v125（SRS 写入路径读放大）：三条索引——
/// - `idx_srs_field_edits_profile_register`：同步冲突角标按 profile 对 (实体, 字段键) 分组；
/// - `idx_srs_notes_cache_type`：笔记类型成员查找；
/// - `idx_srs_notes_cache_pending`：待裁决笔记的部分索引。
/// 只加索引、不动数据；重跑幂等。查询计划用上它们。
///
/// SRS 表从 2026-10-23 起归 Rust 独占的 srs.db（docs/specs/2026-10-23-srs-rust-store.md）：新库的主库里
/// 没有这些表，三条索引在 srs.db 的 schema v2 里建（native/fushi_fsrs/src/store/schema.rs）。主库这一步
/// 只作用于还没搬迁的老库（旧表仍在主库里），这里测的就是它。
void main() {
  const List<String> indexes = <String>[
    'idx_srs_field_edits_profile_register',
    'idx_srs_notes_cache_type',
    'idx_srs_notes_cache_pending',
  ];

  Set<String> indexesOf(sqlite.Database raw) => <String>{
    for (final sqlite.Row row in raw.select(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    ))
      row['name'] as String,
  };

  Future<String> planOf(FushiDatabase db, String sql) async =>
      (await db
              .customSelect(
                'EXPLAIN QUERY PLAN $sql',
                variables: <Variable<Object>>[Variable<String>('p')],
              )
              .get())
          .map((QueryRow r) => r.read<String>('detail'))
          .join(' / ');

  test('v124 → v125 建三条索引，查询计划用它们；数据一行不动；重跑幂等', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'srs_read_amp_v125',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase fresh = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    // 退回 v124 形态：建出老 SRS 表（不带 v125 索引），放几行数据。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    expect(
      indexesOf(raw),
      isNot(contains(indexes.first)),
      reason: '新库的主库里没有 SRS 表（归 srs.db）',
    );
    for (final String t in kLegacySrsV117Tables) {
      raw.execute(kLegacySrsTableDdl[t]!);
    }
    expect(indexesOf(raw).intersection(indexes.toSet()), isEmpty);
    raw.execute(
      'INSERT INTO srs_field_edits '
      '(id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) '
      "VALUES ('e1', 'p', 'note', 'n1', 'f/a', 'w', 1, '{}'), "
      "('e2', 'p', 'note', 'n1', 'f/a', 'w2', 1, '{}')",
    );
    raw.execute(
      'INSERT INTO srs_notes_cache '
      '(id, profile_uid, note_type_id, guid, created_at, pending_decision) '
      "VALUES ('n1', 'p', 't1', 'g1', 1, 1), ('n2', 'p', 't1', 'g2', 2, 0)",
    );
    raw.execute('PRAGMA user_version = 124');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 136);
    final String conflicts = await planOf(
      migrated,
      'SELECT entity_kind, entity_id, field_key FROM srs_field_edits '
      'WHERE profile_uid = ? '
      'GROUP BY entity_kind, entity_id, field_key HAVING COUNT(*) > 1',
    );
    expect(
      conflicts,
      contains('COVERING INDEX idx_srs_field_edits_profile_register'),
      reason: conflicts,
    );
    final String members = await planOf(
      migrated,
      'SELECT id FROM srs_notes_cache WHERE profile_uid = ? '
      "AND note_type_id = 't1'",
    );
    expect(members, contains('idx_srs_notes_cache_type'), reason: members);
    final String pending = await planOf(
      migrated,
      'SELECT COUNT(*) FROM srs_notes_cache WHERE profile_uid = ? '
      'AND pending_decision = 1',
    );
    expect(pending, contains('idx_srs_notes_cache_pending'), reason: pending);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 136);
    expect(indexesOf(probe), containsAll(indexes));
    expect(
      probe.select('SELECT COUNT(*) AS n FROM srs_field_edits').first['n'],
      2,
    );
    expect(
      probe.select('SELECT COUNT(*) AS n FROM srs_notes_cache').first['n'],
      2,
    );

    // 重跑 v125 步（IF NOT EXISTS）：不报错、索引仍在。
    probe.execute('PRAGMA user_version = 124');
    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await reopened.customSelect('SELECT 1').get();
    await reopened.close();
    expect(indexesOf(probe), containsAll(indexes));
    expect(probe.select('PRAGMA user_version').first.values.first, 136);
  });
}
