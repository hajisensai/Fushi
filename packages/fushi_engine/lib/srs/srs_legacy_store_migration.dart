/// 一次性搬迁：主库 `fushi.db` 里的 9 张 `srs_*` 表 → Rust 独占的 `srs.db`
/// （docs/specs/2026-10-23-srs-rust-store.md §3）。
///
/// 旧行由 **Dart（Drift）读出**、按页交给 Rust 写：Rust 绝不打开主库（同一进程两份 SQLite 同开
/// 一个文件会在 POSIX 平台上互相清掉文件锁）。整次搬迁是 srs.db 写连接上的一个事务，标记与数据
/// 同时提交；中途崩溃 = srs.db 里什么都没有，下次从头搬。主库的旧表只在标记提交之后才删。
library;

import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 旧表与列序（与 native/fushi_fsrs/src/store/schema.rs `TABLES` 逐项相同，测试钉住）。
const List<(String, List<String>)> kSrsLegacyTables = <(String, List<String>)>[
  (
    'srs_entities',
    <String>['id', 'profile_uid', 'kind', 'payload_json', 'created_at'],
  ),
  (
    'srs_field_edits',
    <String>[
      'id',
      'profile_uid',
      'entity_kind',
      'entity_id',
      'field_key',
      'writer_id',
      'seq',
      'json',
    ],
  ),
  (
    'srs_review_logs',
    <String>[
      'id',
      'profile_uid',
      'card_id',
      'kind',
      'rating',
      'occurred_at',
      'review_type',
      'origin',
      'duration_ms',
      'json',
    ],
  ),
  ('srs_unknown_events', <String>['id', 'profile_uid', 'json']),
  (
    'srs_event_local',
    <String>[
      'event_id',
      'profile_uid',
      'outbox_seq',
      'server_time',
      'received_at',
    ],
  ),
  ('srs_local_state', <String>['profile_uid', 'json']),
  (
    'srs_sent_batches',
    <String>['profile_uid', 'writer_id', 'batch_no', 'bytes'],
  ),
  (
    'srs_notes_cache',
    <String>[
      'id',
      'profile_uid',
      'note_type_id',
      'guid',
      'created_at',
      'deck_id',
      'deleted_at',
      'term_key',
      'reading_key',
      'sort_field',
      'tags_json',
      'pending_decision',
      'updated_at',
    ],
  ),
  (
    'srs_cards_cache',
    <String>[
      'id',
      'profile_uid',
      'note_id',
      'template_id',
      'cloze_ord',
      'deck_id',
      'suspended',
      'buried_until_day',
      'flag',
      'hidden',
      'queue',
      'due_day',
      'due_at',
      'scheduled_days',
      'reps',
      'lapses',
      'stability',
      'difficulty',
      'last_reviewed_at',
      'last_log_id',
      'scheduler',
      'note_created_at',
      'new_position',
    ],
  ),
];

/// 一页的行数。日志行带完整 JSON（几百字节），5000 行一页约 1–3 MB。
const int kSrsLegacyPageRows = 5000;

/// 搬迁结果（日志 / 测试用）。
class SrsLegacyMigration {
  SrsLegacyMigration({required this.migrated, required this.rowsByTable});

  /// 这次真的搬了数据（false = 早已搬过，或主库里本来就没有 SRS 表）。
  final bool migrated;
  final Map<String, int> rowsByTable;
}

/// 把 [db]（主库连接）里残留的 SRS 表搬进 [core]，然后删掉旧表。可重复调用：标记已在就只
/// 补删旧表。必须在任何 `SrsDbStore` 打开 [core] 之前调用。
Future<SrsLegacyMigration> srsMigrateLegacyStore({
  required DatabaseConnectionUser db,
  required SrsCore core,
}) async {
  final Map<String, int> counts = <String, int>{};
  final Set<String> present = await _presentTables(db);
  if (!core.legacyImported) {
    if (!present.contains('srs_entities')) {
      core.legacyMarkNone();
      return SrsLegacyMigration(migrated: false, rowsByTable: counts);
    }
    core.legacyBegin();
    try {
      for (final (String table, List<String> columns) in kSrsLegacyTables) {
        if (!present.contains(table)) continue;
        counts[table] = await _copyTable(db, core, table, columns);
      }
      core.legacyCommit();
    } on Object {
      core.legacyAbort();
      rethrow;
    }
  }
  await _dropLegacyTables(db, present);
  return SrsLegacyMigration(migrated: counts.isNotEmpty, rowsByTable: counts);
}

Future<Set<String>> _presentTables(DatabaseConnectionUser db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'srs\\_%' ESCAPE '\\'",
      )
      .get();
  return <String>{for (final QueryRow r in rows) r.read<String>('name')};
}

Future<int> _copyTable(
  DatabaseConnectionUser db,
  SrsCore core,
  String table,
  List<String> columns,
) async {
  final String select =
      'SELECT rowid AS _rid, ${columns.join(', ')} FROM $table '
      'WHERE rowid > ? ORDER BY rowid LIMIT $kSrsLegacyPageRows';
  final int address = core.address;
  final String? libraryPath = core.libraryPath;
  int last = -1 << 62;
  int total = 0;
  while (true) {
    final List<QueryRow> rows = await db
        .customSelect(
          select,
          variables: <Variable<Object>>[Variable<int>(last)],
        )
        .get();
    if (rows.isEmpty) break;
    final List<List<Object?>> page = <List<Object?>>[
      for (final QueryRow r in rows)
        <Object?>[for (final String c in columns) r.data[c]],
    ];
    last = rows.last.data['_rid']! as int;
    final Uint8List bytes = srsEncodeRows(columns.length, page);
    // 写入可能要几十到几百毫秒：放后台 isolate（句柄线程安全，同一个写事务）。
    await Isolate.run<void>(
      () => SrsCore.fromAddress(
        address,
        libraryPath: libraryPath,
      ).legacyPage(table, bytes),
    );
    total += rows.length;
    if (rows.length < kSrsLegacyPageRows) break;
  }
  return total;
}

Future<void> _dropLegacyTables(
  DatabaseConnectionUser db,
  Set<String> present,
) async {
  final List<String> drop = <String>[
    for (final (String t, _) in kSrsLegacyTables)
      if (present.contains(t)) t,
  ];
  if (drop.isEmpty) return;
  await db.transaction(() async {
    for (final String t in drop) {
      // 索引随表一起删。
      await db.customStatement('DROP TABLE IF EXISTS $t');
    }
  });
}
