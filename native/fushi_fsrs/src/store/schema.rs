//! srs.db 的表结构（docs/specs/2026-10-23-srs-rust-store.md §2）。
//!
//! 9 张 `srs_*` 表与主库 Drift 声明（`packages/fushi_core/lib/src/database/tables.dart`，schema v124）
//! 逐列相同：列名、类型、可空、缺省值、主键、索引（含部分索引的 WHERE 原文）。旧库搬迁（§3）按
//! [TABLES] 的列序逐行原样写入，所以列序也是契约的一部分。

/// 本库自己的版本号（`srs_meta.schema`）。迁移阶梯见 [migrate]。
pub const SCHEMA_VERSION: i64 = 7;

/// 前身链接的部分索引条件；与 `kSrsHistoryFromCondition`（database_srs.part.dart）逐字一致，
/// 查询里的 WHERE 必须写成同一个表达式才用得上这个索引。
pub const HISTORY_FROM_CONDITION: &str = "substr(field_key, 1, 12) = 'historyFrom/'";

/// 一张旧表：名字与列序（搬迁页的行按这个顺序编码）。
pub struct Table {
    pub name: &'static str,
    pub columns: &'static [&'static str],
}

pub const TABLES: &[Table] = &[
    Table {
        name: "srs_entities",
        columns: &["id", "profile_uid", "kind", "payload_json", "created_at"],
    },
    Table {
        name: "srs_field_edits",
        columns: &[
            "id", "profile_uid", "entity_kind", "entity_id", "field_key", "writer_id", "seq", "json",
        ],
    },
    Table {
        name: "srs_review_logs",
        columns: &[
            "id", "profile_uid", "card_id", "kind", "rating", "occurred_at", "review_type", "origin",
            "duration_ms", "json",
        ],
    },
    Table {
        name: "srs_unknown_events",
        columns: &["id", "profile_uid", "json"],
    },
    Table {
        name: "srs_event_local",
        columns: &["event_id", "profile_uid", "outbox_seq", "server_time", "received_at"],
    },
    Table {
        name: "srs_local_state",
        columns: &["profile_uid", "json"],
    },
    Table {
        name: "srs_sent_batches",
        columns: &["profile_uid", "writer_id", "batch_no", "bytes"],
    },
    Table {
        name: "srs_notes_cache",
        columns: &[
            "id", "profile_uid", "note_type_id", "guid", "created_at", "deck_id", "deleted_at",
            "term_key", "reading_key", "sort_field", "tags_json", "pending_decision", "updated_at",
        ],
    },
    Table {
        name: "srs_cards_cache",
        columns: &[
            "id", "profile_uid", "note_id", "template_id", "cloze_ord", "deck_id", "suspended",
            "buried_until_day", "flag", "hidden", "queue", "due_day", "due_at", "scheduled_days",
            "reps", "lapses", "stability", "difficulty", "last_reviewed_at", "last_log_id",
            "scheduler", "note_created_at", "new_position",
        ],
    },
];

/// 按名字找表（搬迁页校验用）。
pub fn table(name: &str) -> Option<&'static Table> {
    TABLES.iter().find(|t| t.name == name)
}

const V1: &str = r#"
CREATE TABLE IF NOT EXISTS srs_meta (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS srs_entities (
  id TEXT NOT NULL,
  profile_uid TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS srs_field_edits (
  id TEXT NOT NULL,
  profile_uid TEXT NOT NULL,
  entity_kind TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  field_key TEXT NOT NULL,
  writer_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  json TEXT NOT NULL,
  PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS srs_review_logs (
  id TEXT NOT NULL,
  profile_uid TEXT NOT NULL,
  card_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  rating INTEGER NULL,
  occurred_at INTEGER NOT NULL,
  review_type TEXT NOT NULL,
  origin TEXT NOT NULL,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  json TEXT NOT NULL,
  PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS srs_unknown_events (
  id TEXT NOT NULL,
  profile_uid TEXT NOT NULL,
  json TEXT NOT NULL,
  PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS srs_event_local (
  event_id TEXT NOT NULL,
  profile_uid TEXT NOT NULL,
  outbox_seq INTEGER NULL,
  server_time INTEGER NULL,
  received_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (event_id)
);
CREATE TABLE IF NOT EXISTS srs_local_state (
  profile_uid TEXT NOT NULL,
  json TEXT NOT NULL,
  PRIMARY KEY (profile_uid)
);
CREATE TABLE IF NOT EXISTS srs_sent_batches (
  profile_uid TEXT NOT NULL,
  writer_id TEXT NOT NULL,
  batch_no INTEGER NOT NULL,
  bytes BLOB NOT NULL,
  PRIMARY KEY (profile_uid, writer_id, batch_no)
);
CREATE TABLE IF NOT EXISTS srs_notes_cache (
  id TEXT NOT NULL,
  profile_uid TEXT NOT NULL,
  note_type_id TEXT NOT NULL,
  guid TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  deck_id TEXT NULL,
  deleted_at INTEGER NULL,
  term_key TEXT NOT NULL DEFAULT '',
  reading_key TEXT NOT NULL DEFAULT '',
  sort_field TEXT NOT NULL DEFAULT '',
  tags_json TEXT NOT NULL DEFAULT '[]',
  pending_decision INTEGER NOT NULL DEFAULT 0 CHECK (pending_decision IN (0, 1)),
  updated_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS srs_cards_cache (
  id TEXT NOT NULL,
  profile_uid TEXT NOT NULL,
  note_id TEXT NOT NULL,
  template_id TEXT NOT NULL,
  cloze_ord INTEGER NOT NULL DEFAULT 0,
  deck_id TEXT NOT NULL,
  suspended INTEGER NOT NULL DEFAULT 0 CHECK (suspended IN (0, 1)),
  buried_until_day INTEGER NULL,
  flag INTEGER NOT NULL DEFAULT 0,
  hidden INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0, 1)),
  queue TEXT NOT NULL DEFAULT 'new',
  due_day INTEGER NULL,
  due_at INTEGER NULL,
  scheduled_days INTEGER NOT NULL DEFAULT 0,
  reps INTEGER NOT NULL DEFAULT 0,
  lapses INTEGER NOT NULL DEFAULT 0,
  stability REAL NULL,
  difficulty REAL NULL,
  last_reviewed_at INTEGER NULL,
  last_log_id TEXT NULL,
  scheduler TEXT NOT NULL DEFAULT 'fushi',
  note_created_at INTEGER NOT NULL DEFAULT 0,
  new_position INTEGER NULL,
  PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS idx_srs_entities_profile_kind ON srs_entities (profile_uid, kind);
CREATE INDEX IF NOT EXISTS idx_srs_field_edits_entity ON srs_field_edits (entity_kind, entity_id);
CREATE INDEX IF NOT EXISTS idx_srs_review_logs_card ON srs_review_logs (card_id);
CREATE INDEX IF NOT EXISTS idx_srs_review_logs_profile_time ON srs_review_logs (profile_uid, occurred_at);
CREATE INDEX IF NOT EXISTS idx_srs_event_local_outbox ON srs_event_local (profile_uid, outbox_seq);
CREATE INDEX IF NOT EXISTS idx_srs_notes_cache_term ON srs_notes_cache (profile_uid, term_key);
CREATE INDEX IF NOT EXISTS idx_srs_cards_cache_note ON srs_cards_cache (note_id);
CREATE INDEX IF NOT EXISTS idx_srs_cards_cache_queue ON srs_cards_cache (profile_uid, deck_id, queue, due_day);
"#;

/// V2（与主库 v125 同一批，写入路径的读放大）：① 同步冲突角标按 profile 对（实体, 字段键）分组只扫索引；
/// ② 笔记类型的成员查找；③ 待裁决笔记的部分索引。只加索引、不动数据。
const V2: &str = r#"
CREATE INDEX IF NOT EXISTS idx_srs_field_edits_profile_register ON srs_field_edits (profile_uid, entity_kind, entity_id, field_key);
CREATE INDEX IF NOT EXISTS idx_srs_notes_cache_type ON srs_notes_cache (profile_uid, note_type_id);
CREATE INDEX IF NOT EXISTS idx_srs_notes_cache_pending ON srs_notes_cache (profile_uid) WHERE pending_decision = 1;
"#;

/// V3：有效复习投影 `srs_stat_reviews`（本机可重建缓存，不同步、不进备份；Drift 声明见
/// packages/fushi_core/lib/src/database/srs_tables.dart `SrsStatReviews`）。一条有效复习日志一行，
/// `card_id` 是归属卡（`SrsDbStore._refreshStatProjection`）。老库建空表，由 Dart 侧缓存修订号 2 的
/// 升级步填满。
const V3: &str = r#"
CREATE TABLE IF NOT EXISTS srs_stat_reviews (
  log_id TEXT NOT NULL,
  profile_uid TEXT NOT NULL,
  card_id TEXT NOT NULL,
  occurred_at INTEGER NOT NULL,
  utc_offset_min INTEGER NOT NULL DEFAULT 0,
  rating INTEGER NULL,
  kind INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  prev_due_day INTEGER NULL,
  maturity_delta INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (log_id)
);
CREATE INDEX IF NOT EXISTS idx_srs_stat_reviews_profile_time ON srs_stat_reviews (profile_uid, occurred_at);
CREATE INDEX IF NOT EXISTS idx_srs_stat_reviews_card ON srs_stat_reviews (card_id);
"#;

/// V4：笔记缓存加 `media_refs`（这条笔记当前字段引用的媒体文件名，换行分隔；Drift 声明见 srs_tables.dart
/// `SrsNotesCache.mediaRefs`）。老库加列留空，由 Dart 侧缓存修订号 3 的升级步重算全部笔记缓存填满。
const V4: &str = "ALTER TABLE srs_notes_cache ADD COLUMN media_refs TEXT NOT NULL DEFAULT '';";

/// V7：卡片缓存加 `freq_rank`（笔记词频序字段解析出的名次，越小越常见；没有 = NULL。Drift 声明见
/// srs_tables.dart `SrsCardsCache.freqRank`）。牌组「新卡顺序 = 按词频」时出卡按它排。老库加列留空，由 Dart
/// 侧缓存修订号 6 的升级步重算全部笔记缓存填满。
const V7: &str = "ALTER TABLE srs_cards_cache ADD COLUMN freq_rank INTEGER NULL;";

/// 建表 / 升级到 [SCHEMA_VERSION]。在一个事务里做；版本只升不降（库比本程序新 = 打开失败，
/// 免得旧版本写坏新版本的库）。
pub fn migrate(conn: &mut rusqlite::Connection) -> Result<(), String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS srs_meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);",
    )
    .map_err(|e| e.to_string())?;
    let current: i64 = tx
        .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
            r.get::<_, String>(0)
        })
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    if current > SCHEMA_VERSION {
        return Err(format!(
            "srs.db schema {current} is newer than this build ({SCHEMA_VERSION})"
        ));
    }
    if current < 1 {
        tx.execute_batch(V1).map_err(|e| e.to_string())?;
        tx.execute_batch(&format!(
            "CREATE INDEX IF NOT EXISTS idx_srs_field_edits_history_from \
             ON srs_field_edits (field_key, entity_kind, entity_id) WHERE {HISTORY_FROM_CONDITION};"
        ))
        .map_err(|e| e.to_string())?;
    }
    if current < 2 {
        tx.execute_batch(V2).map_err(|e| e.to_string())?;
    }
    if current < 3 {
        tx.execute_batch(V3).map_err(|e| e.to_string())?;
    }
    if current < 4 {
        // ALTER 不带 IF NOT EXISTS：按列是否已在再加（与前几步的 CREATE … IF NOT EXISTS 一样可重放）。
        let has: bool = tx
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('srs_notes_cache') WHERE name = 'media_refs'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map_err(|e| e.to_string())?
            > 0;
        if !has {
            tx.execute_batch(V4).map_err(|e| e.to_string())?;
        }
    }
    if current < 5 {
        // V5：同步 v2 的事实表与元数据（store/sync2/schema.rs）。旧表不动：它们从此是 ops 的投影。
        tx.execute_batch(super::sync2::schema::V5).map_err(|e| e.to_string())?;
    }
    if current < 6 {
        // V6：本机切段点记下压缩后体积（按体积切段与分层合并用，store/sync2/transport.rs）。老段留 0 = 未知，
        // 合并时补算。
        let has: bool = tx
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('sync2_segments') WHERE name = 'bytes'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map_err(|e| e.to_string())?
            > 0;
        if !has {
            tx.execute_batch(super::sync2::schema::V6).map_err(|e| e.to_string())?;
        }
    }
    if current < 7 {
        let has: bool = tx
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('srs_cards_cache') WHERE name = 'freq_rank'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map_err(|e| e.to_string())?
            > 0;
        if !has {
            tx.execute_batch(V7).map_err(|e| e.to_string())?;
        }
    }
    tx.execute(
        "INSERT INTO srs_meta (key, value) VALUES ('schema', ?1) \
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [SCHEMA_VERSION.to_string()],
    )
    .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())
}
