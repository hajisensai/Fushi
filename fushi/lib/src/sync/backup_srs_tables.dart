/// 通用备份里与 SRS 表打交道的唯一一处（docs/specs/2026-10-23-srs-rust-store.md §4 / §6）。
///
/// SRS 的表归 Rust 的 `srs.db`；app 侧只在两种场合碰表名：
/// - **老形态**：2026-10-23 之前的备份 / 还没搬迁的本机主库里，9 张 `srs_*` 表在 `fushi.db` 里
///   （迁移阶梯照旧建出它们，见 fushi_core `kLegacySrsTableDdl`）。导出要剥掉、恢复要识别它们。
/// - **新形态**：经 [SrsDatabase]（语句在 Rust 连接上执行）读 srs.db 里的计数 / profile uid。
///
/// 守卫 `test/build/srs_store_ownership_guard_test.dart` 只放行本文件写 SRS 表名。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart'
    show SrsDatabase, kLegacySrsTableDdl;
import 'package:fushi_srs/fushi_srs.dart' show SrsEntityKind;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// 9 张 SRS 表（老形态下在主库里；新形态下在 srs.db 里）。
final List<String> kSrsTableNames = List<String>.unmodifiable(
  kLegacySrsTableDdl.keys,
);

/// 随备份走的 4 张 SRS 数据表（按 `profiles.uid` 归属）。
const List<String> kSrsDataTableNames = <String>[
  'srs_entities',
  'srs_field_edits',
  'srs_review_logs',
  'srs_unknown_events',
];

/// 5 张 SRS 设备本地表：发件箱顺序 / 本机同步状态 / 已冻结批次 / 两张可重建缓存。
/// 绝不随备份离开本机，恢复后一律清空（SRS 引擎按「无本机状态」换新化身并重建缓存）。
const List<String> kSrsDeviceLocalTableNames = <String>[
  'srs_event_local',
  'srs_local_state',
  'srs_notes_cache',
  'srs_cards_cache',
  'srs_sent_batches',
];

const String _entities = 'srs_entities';

/// SRS 用户笔记的判据（内置行——profile / 牌组 / 笔记类型——由引擎按 uid 派生，不算用户数据）。
final String _userNoteSql = "kind = '${SrsEntityKind.note.wire}'";

String _prefix(String? schema) => schema == null ? '' : '$schema.';

/// [db]（可带 ATTACH 别名 [schema]）里有没有老形态的 SRS 表（以 `srs_entities` 为准）。
Future<bool> hasLegacySrsTables(
  DatabaseConnectionUser db, {
  String? schema,
}) async =>
    await db
        .customSelect(
          'SELECT 1 FROM ${_prefix(schema)}sqlite_master '
          "WHERE type = 'table' AND name = ? LIMIT 1",
          variables: <Variable<Object>>[Variable<String>(_entities)],
        )
        .getSingleOrNull() !=
    null;

Future<Set<String>> _presentSrsTables(DatabaseConnectionUser db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND "
        'name IN (${List<String>.filled(kSrsTableNames.length, '?').join(', ')})',
        variables: <Variable<Object>>[
          for (final String t in kSrsTableNames) Variable<String>(t),
        ],
      )
      .get();
  return <String>{for (final QueryRow r in rows) r.read<String>('name')};
}

/// 删掉 [db]（主库形态）里老形态的全部 SRS 表（连同索引）。不存在的跳过。
Future<void> dropLegacySrsTables(DatabaseConnectionUser db) async {
  for (final String t in await _presentSrsTables(db)) {
    await db.customStatement('DROP TABLE IF EXISTS $t');
  }
}

/// 清空 [db]（主库形态）里老形态的 5 张设备本地 SRS 表（存在的才清）。
Future<void> clearLegacySrsDeviceLocalTables(DatabaseConnectionUser db) async {
  final Set<String> present = await _presentSrsTables(db);
  for (final String t in kSrsDeviceLocalTableNames) {
    if (present.contains(t)) await db.customStatement('DELETE FROM $t');
  }
}

/// SRS 用户笔记数：[db] 是 srs.db 的 [SrsDatabase]，或带老形态 SRS 表的主库。
/// 主库里没有 SRS 表时为 0。
Future<int> srsUserNoteCount(DatabaseConnectionUser db) async {
  if (db is! SrsDatabase && !await hasLegacySrsTables(db)) return 0;
  final QueryRow row = await db
      .customSelect('SELECT COUNT(*) AS c FROM $_entities WHERE $_userNoteSql')
      .getSingle();
  return row.read<int>('c');
}

/// 只读打开的备份主库（老形态）里的 SRS 用户笔记数；没有 SRS 表为 0。
int srsUserNoteCountInLegacyBlob(sqlite.Database db) {
  final sqlite.ResultSet has = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[_entities],
  );
  if (has.isEmpty) return 0;
  return db
          .select('SELECT COUNT(*) AS c FROM $_entities WHERE $_userNoteSql')
          .first['c']
      as int;
}

/// 出现过 SRS 数据的 profile uid：[db] 是 srs.db 的 [SrsDatabase]，或带老形态 SRS 表的主库
/// （没有表时为空）。
Future<Set<String>> srsProfileUids(DatabaseConnectionUser db) async {
  if (db is! SrsDatabase && !await hasLegacySrsTables(db)) {
    return const <String>{};
  }
  final List<QueryRow> rows = await db
      .customSelect('SELECT DISTINCT profile_uid FROM $_entities')
      .get();
  return <String>{for (final QueryRow r in rows) r.read<String>('profile_uid')};
}

/// 主库形态的文件 [path]（`fushi.db` / 解出的备份主库副本，调用方保证此刻没有别的连接）里有没有
/// 老形态的 SRS 表。文件不存在或不是 SQLite 库时为 false。
bool legacySrsTablesInFile(String path) {
  if (!File(path).existsSync()) return false;
  final sqlite.Database db;
  try {
    db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
  } on sqlite.SqliteException {
    return false;
  }
  try {
    return db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[_entities],
    ).isNotEmpty;
  } on sqlite.SqliteException {
    // 不是 SQLite 库（低层测试换进去的不透明字节）：没有 SRS 表。
    return false;
  } finally {
    db.dispose();
  }
}
