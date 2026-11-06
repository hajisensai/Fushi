/// SRS 事件库的 Drift 视图（docs/specs/2026-10-23-srs-rust-store.md §5）。
///
/// 表结构由 Rust（native/fushi_fsrs/src/store/schema.rs）建立与升级，这里只声明表让查询构造器
/// 生成 SQL；连接是 fushi_engine `srsDatabaseConnection`（语句在 Rust 的写连接上执行）。
library;

import 'package:drift/drift.dart';

import 'srs_id_type.dart';
import 'srs_tables.dart';

part 'srs_database.g.dart';

@DriftDatabase(
  tables: <Type>[
    SrsEntities,
    SrsFieldEdits,
    SrsReviewLogs,
    SrsUnknownEvents,
    SrsEventLocal,
    SrsLocalState,
    SrsSentBatches,
    SrsNotesCache,
    SrsCardsCache,
    SrsStatReviews,
  ],
)
class SrsDatabase extends _$SrsDatabase {
  SrsDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {},
    onUpgrade: (Migrator m, int from, int to) async {},
  );
}
