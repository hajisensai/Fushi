//! srs.db 的表结构（docs/specs/2026-10-23-srs-rust-store.md §2）。
//!
//! 9 张 `srs_*` 表与主库 Drift 声明（`packages/fushi_core/lib/src/database/tables.dart`，schema v124）
//! 逐列相同：列名、类型、可空、缺省值、主键、索引（含部分索引的 WHERE 原文）。旧库搬迁（§3）按
//! [TABLES] 的列序逐行原样写入，所以列序也是契约的一部分。

/// 本库自己的版本号（`srs_meta.schema`）。迁移阶梯见 [migrate]。
pub const SCHEMA_VERSION: i64 = 9;

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

/// V8：卡片缓存加 `freq_rank`（笔记词频序字段解析出的名次，越小越常见；没有 = NULL。Drift 声明见
/// srs_tables.dart `SrsCardsCache.freqRank`）。牌组「新卡顺序 = 按词频」时出卡按它排。老库加列留空，由 Dart
/// 侧缓存修订号 6 的升级步让内核（store/caches.rs）重算全部笔记缓存填满。
const V8: &str = "ALTER TABLE srs_cards_cache ADD COLUMN freq_rank INTEGER NULL;";

/// V9：复习出卡 / 牌组计数的索引（`SrsDbStore.nextCard` / `_deckTallies` / `_countContext`）。「可出」条件
/// （`_liveSql`：`hidden = 0 AND suspended = 0 AND scheduler = 'fushi'`）与队列写进部分索引的 WHERE，查询里逐字
/// 带着同样的条件才用得上；排序键与 Dart 的 ORDER BY 逐字同一个表达式（`_newCardOrderSql`），牌组、埋到哪天等
/// 过滤列放在键尾，过滤不回表（SQLite 判覆盖要求查询碰到的列都在索引里，部分索引 WHERE 里那几列也不例外，所以
/// 它们也列在键尾——值在这份索引里是常量，只多几个字节）。只加索引、不动数据。
///
/// - 新卡两种顺序（按位置 / 按词频）：profile 之后直接是排序键，子树里几个牌组的新卡按序扫、命中第一张即停，
///   不把子树全部新卡取出来排序（以前每张卡出题都排一遍）。
/// - 学习卡：按 `COALESCE(due_at, 0)` 有序，范围条件「到期」直接是索引区间。
/// - 复习候选：按（牌组, `COALESCE(due_day, 0)`）只扫到期的卡，排序表达式要的列（上次复习、稳定度）与结果列
///   都在索引里（覆盖，不回表）。
///   复习序是「此刻的可提取度」，随此刻变化，无法建成索引序：这里只把候选收窄到到期卡（Rust 侧队列另做）。
/// - 牌组计数：`hidden = 0` 的覆盖索引，按牌组有序，聚合不回表、不另排序。
/// - 计数上下文的日志：（profile, 种类, 时刻）区间扫描，卡 / 类型列在索引里（正文 JSON 只在学习步那几行回表）。
const V9: &str = r#"
CREATE INDEX IF NOT EXISTS idx_srs_cards_cache_new_position ON srs_cards_cache
  (profile_uid, new_position IS NULL, new_position, note_created_at, id, deck_id, buried_until_day,
   queue, hidden, suspended, scheduler)
  WHERE queue = 'new' AND hidden = 0 AND suspended = 0 AND scheduler = 'fushi';
CREATE INDEX IF NOT EXISTS idx_srs_cards_cache_new_freq ON srs_cards_cache
  (profile_uid, freq_rank IS NULL, freq_rank, new_position IS NULL, new_position, note_created_at, id, deck_id,
   buried_until_day, queue, hidden, suspended, scheduler)
  WHERE queue = 'new' AND hidden = 0 AND suspended = 0 AND scheduler = 'fushi';
CREATE INDEX IF NOT EXISTS idx_srs_cards_cache_learning ON srs_cards_cache
  (profile_uid, COALESCE(due_at, 0), id, deck_id, buried_until_day, due_at, queue, hidden, suspended, scheduler)
  WHERE queue IN ('learning', 'relearning') AND hidden = 0 AND suspended = 0 AND scheduler = 'fushi';
CREATE INDEX IF NOT EXISTS idx_srs_cards_cache_review_due ON srs_cards_cache
  (profile_uid, deck_id, COALESCE(due_day, 0), buried_until_day, last_reviewed_at, stability, id, due_at, due_day,
   queue, hidden, suspended, scheduler)
  WHERE queue = 'review' AND hidden = 0 AND suspended = 0 AND scheduler = 'fushi';
CREATE INDEX IF NOT EXISTS idx_srs_cards_cache_tally ON srs_cards_cache
  (profile_uid, deck_id, queue, due_day, due_at, suspended, scheduler, buried_until_day)
  WHERE hidden = 0;
CREATE INDEX IF NOT EXISTS idx_srs_review_logs_profile_kind_time ON srs_review_logs
  (profile_uid, kind, occurred_at, card_id, review_type);
"#;

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
        // V7：MediaAt 操作的投影（媒体对账不再列目录，store/sync2/media.rs）。
        tx.execute_batch(super::sync2::schema::V7).map_err(|e| e.to_string())?;
    }
    if current < 8 {
        let has: bool = tx
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('srs_cards_cache') WHERE name = 'freq_rank'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map_err(|e| e.to_string())?
            > 0;
        if !has {
            tx.execute_batch(V8).map_err(|e| e.to_string())?;
        }
    }
    if current < 9 {
        tx.execute_batch(V9).map_err(|e| e.to_string())?;
    }
    tx.execute(
        "INSERT INTO srs_meta (key, value) VALUES ('schema', ?1) \
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [SCHEMA_VERSION.to_string()],
    )
    .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const V9_INDEXES: [&str; 6] = [
        "idx_srs_cards_cache_new_position",
        "idx_srs_cards_cache_new_freq",
        "idx_srs_cards_cache_learning",
        "idx_srs_cards_cache_review_due",
        "idx_srs_cards_cache_tally",
        "idx_srs_review_logs_profile_kind_time",
    ];

    fn indexes(c: &rusqlite::Connection) -> Vec<String> {
        let mut stmt = c.prepare("SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name").unwrap();
        stmt.query_map([], |r| r.get::<_, String>(0)).unwrap().map(Result::unwrap).collect()
    }

    fn version(c: &rusqlite::Connection) -> String {
        c.query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| r.get(0)).unwrap()
    }

    /// v8 的库升到 v9：补上出卡 / 计数索引；再跑一遍迁移（`current < 9` 的步骤重放）不出错、不重复建。
    #[test]
    fn v8_store_gains_the_queue_indexes_idempotently() {
        let mut c = rusqlite::Connection::open_in_memory().unwrap();
        migrate(&mut c).unwrap();
        assert_eq!(SCHEMA_VERSION, 9);
        assert_eq!(version(&c), "9");
        for i in V9_INDEXES {
            c.execute_batch(&format!("DROP INDEX {i}")).unwrap();
        }
        c.execute("UPDATE srs_meta SET value = '8' WHERE key = 'schema'", []).unwrap();
        migrate(&mut c).unwrap();
        let after = indexes(&c);
        for i in V9_INDEXES {
            assert!(after.contains(&i.to_owned()), "{i} missing after v8 -> v9");
        }
        assert_eq!(version(&c), "9");
        // 中途崩溃重放：索引已在、版本号还是 8。
        c.execute("UPDATE srs_meta SET value = '8' WHERE key = 'schema'", []).unwrap();
        migrate(&mut c).unwrap();
        assert_eq!(indexes(&c), after);
        assert_eq!(version(&c), "9");
    }

    /// 出卡 / 计数查询在大库上的耗时：有 v9 索引 vs 删掉 v9 索引（= v8，计数的全牌组查询按 v8 写法带 `+profile_uid`）。
    /// SQL 逐字取自 `SrsDbStore.nextCard` / `_deckTallies` / `_countContext` 实际发出的语句
    /// （packages/fushi_engine/test/srs/srs_queue_index_plan_test.dart 抓下来的）。手动跑：
    /// `cargo test --release --lib queue_query_bench -- --ignored --nocapture`。
    #[test]
    #[ignore]
    fn queue_query_bench() {
        use rusqlite::types::Value;
        const LIVE: &str = "hidden = 0 AND suspended = 0 AND scheduler = 'fushi' \
            AND (buried_until_day IS NULL OR buried_until_day <= ?)";
        let dir = std::env::temp_dir().join(format!("ffsrs_queue_bench_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let mut c = rusqlite::Connection::open(&path).unwrap();
        c.execute_batch("PRAGMA journal_mode = WAL; PRAGMA cache_size = -65536; PRAGMA mmap_size = 268435456;").unwrap();
        migrate(&mut c).unwrap();
        let (cards, decks, logs) = (100_000usize, 40usize, 300_000usize);
        let today: i64 = 20_000;
        let now: i64 = today * 86_400_000;
        {
            let tx = c.transaction().unwrap();
            {
                let mut ins = tx
                    .prepare(
                        "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, suspended, hidden, \
                         queue, due_day, due_at, stability, last_reviewed_at, note_created_at, new_position, freq_rank) \
                         VALUES (?1, 'p', ?2, 't', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                    )
                    .unwrap();
                let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
                let mut rnd = move || {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    x
                };
                for i in 0..cards {
                    let r = rnd();
                    let q = match r % 100 {
                        0..=59 => "new",
                        60..=89 => "review",
                        90..=94 => "learning",
                        _ => "relearning",
                    };
                    let due_day = (q == "review").then(|| today - 400 + (rnd() % 800) as i64);
                    let due_at = q.ends_with("learning").then(|| now - 3_600_000 + (rnd() % 7_200_000) as i64);
                    let freq = (rnd() % 3 != 0).then(|| (rnd() % 50_000) as i64);
                    let pos = (rnd() % 2 == 0).then(|| i as i64);
                    ins.execute(rusqlite::params![
                        format!("c{i:06}"),
                        format!("n{i:06}"),
                        format!("d{:02}", (r >> 8) as usize % decks),
                        (rnd() % 50 == 0) as i64,
                        (rnd() % 50 == 0) as i64,
                        q,
                        due_day,
                        due_at,
                        (q == "review").then(|| 1.0 + (rnd() % 1000) as f64 / 10.0),
                        (q != "new").then(|| now - (rnd() % 30_000_000_000) as i64),
                        i as i64,
                        pos,
                        freq,
                    ])
                    .unwrap();
                }
                let mut log = tx
                    .prepare(
                        "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, \
                         origin, json) VALUES (?1, 'p', ?2, ?3, 3, ?4, ?5, 'fushi', ?6)",
                    )
                    .unwrap();
                let body = format!("{{\"res\":{{\"reps\":2}},\"pad\":\"{}\"}}", "x".repeat(300));
                for i in 0..logs {
                    let r = rnd();
                    log.execute(rusqlite::params![
                        format!("l{i:07}"),
                        format!("c{:06}", r as usize % cards),
                        if r % 10 == 0 { "manual" } else { "review" },
                        now - (r % (365 * 86_400_000)) as i64,
                        if r % 7 == 0 { "learn" } else { "review" },
                        body,
                    ])
                    .unwrap();
                }
            }
            tx.commit().unwrap();
        }
        let sub: Vec<String> = (0..5).map(|d| format!("d{d:02}")).collect();
        let deck_in = vec!["?"; sub.len()].join(", ");
        let tally = |profile_col: &str, decks: Option<&[String]>| -> (String, Vec<Value>) {
            let mut args: Vec<Value> = vec![
                Value::Integer(today),
                Value::Integer(today),
                Value::Integer(now + 20 * 60_000),
                Value::Integer(today),
                Value::Integer(today),
                Value::Text("p".into()),
            ];
            let filter = decks.map_or(String::new(), |d| {
                args.extend(d.iter().map(|s| Value::Text(s.clone())));
                format!(" AND deck_id IN ({})", vec!["?"; d.len()].join(", "))
            });
            (
                format!(
                    "SELECT deck_id, COUNT(*) AS total, \
                     SUM(CASE WHEN {LIVE} AND queue NOT IN ('learning', 'relearning', 'review') THEN 1 ELSE 0 END) AS new_avail, \
                     SUM(CASE WHEN {LIVE} AND queue IN ('learning', 'relearning') AND COALESCE(due_at, 0) <= ? THEN 1 ELSE 0 END) AS learn, \
                     SUM(CASE WHEN {LIVE} AND queue = 'review' AND COALESCE(due_day, 0) <= ? THEN 1 ELSE 0 END) AS due \
                     FROM srs_cards_cache WHERE {profile_col} = ? AND hidden = 0{filter} GROUP BY deck_id"
                ),
                args,
            )
        };
        let pick = |cond: &str, order: &str, extra: Vec<Value>, order_vars: Vec<Value>| -> (String, Vec<Value>) {
            let mut args = vec![Value::Text("p".into()), Value::Integer(today)];
            args.extend(sub.iter().map(|s| Value::Text(s.clone())));
            args.extend(extra);
            args.extend(order_vars);
            (
                format!(
                    "SELECT id, due_at FROM srs_cards_cache WHERE profile_uid = ? AND {LIVE} AND deck_id IN ({deck_in}) \
                     AND {cond} ORDER BY {order} LIMIT 1"
                ),
                args,
            )
        };
        let queries: Vec<(&str, (String, Vec<Value>), (String, Vec<Value>))> = {
            let new_freq = pick(
                "queue = 'new'",
                "freq_rank IS NULL, freq_rank, new_position IS NULL, new_position, note_created_at, id",
                vec![],
                vec![],
            );
            let new_pos = pick("queue = 'new'", "new_position IS NULL, new_position, note_created_at, id", vec![], vec![]);
            let learning = pick(
                "queue IN ('learning', 'relearning') AND COALESCE(due_at, 0) <= ?",
                "COALESCE(due_at, 0), id",
                vec![Value::Integer(now + 20 * 60_000)],
                vec![],
            );
            let review = pick(
                "queue = 'review' AND COALESCE(due_day, 0) <= ?",
                "1.0 / (1.0 + (CASE WHEN last_reviewed_at IS NULL THEN 0.0 ELSE (? - last_reviewed_at) / 86400000.0 END) \
                 / (9.0 * COALESCE(stability, 1.0))), id",
                vec![Value::Integer(today)],
                vec![Value::Integer(now)],
            );
            let logs30 = (
                "SELECT \"srs_review_logs\".\"occurred_at\" AS \"srs_review_logs.occurred_at\" FROM \"srs_review_logs\" \
                 WHERE (\"srs_review_logs\".\"profile_uid\" = ? AND \"srs_review_logs\".\"kind\" = ?) \
                 AND \"srs_review_logs\".\"occurred_at\" >= ?;"
                    .to_owned(),
                vec![Value::Text("p".into()), Value::Text("review".into()), Value::Integer(now - 29 * 86_400_000)],
            );
            let today_logs = (
                "SELECT card_id, occurred_at, review_type, CASE WHEN review_type = ? THEN json END AS j FROM srs_review_logs \
                 WHERE profile_uid = ? AND kind = ? AND occurred_at >= ? ORDER BY occurred_at"
                    .to_owned(),
                vec![
                    Value::Text("learn".into()),
                    Value::Text("p".into()),
                    Value::Text("review".into()),
                    Value::Integer(now - 86_400_000),
                ],
            );
            vec![
                ("nextCard 新卡(按词频)", new_freq.clone(), new_freq),
                ("nextCard 新卡(按位置)", new_pos.clone(), new_pos),
                ("nextCard 学习卡", learning.clone(), learning),
                ("nextCard 复习候选", review.clone(), review),
                ("计数 子树5个牌组", tally("profile_uid", Some(&sub)), tally("profile_uid", Some(&sub))),
                ("计数 全部牌组", tally("profile_uid", None), tally("+profile_uid", None)),
                ("计数上下文 30天日志", logs30.clone(), logs30),
                ("计数上下文 今天日志", today_logs.clone(), today_logs),
            ]
        };
        let time = |c: &rusqlite::Connection, (sql, args): &(String, Vec<Value>)| -> (f64, usize) {
            let mut stmt = c.prepare(sql).unwrap();
            let mut rows = 0;
            let runs = 20;
            let t0 = std::time::Instant::now();
            for _ in 0..runs {
                rows = stmt.query(rusqlite::params_from_iter(args.iter())).unwrap().mapped(|_| Ok(())).count();
            }
            (t0.elapsed().as_secs_f64() * 1000.0 / runs as f64, rows)
        };
        let after: Vec<(f64, usize)> = queries.iter().map(|q| time(&c, &q.1)).collect();
        for i in V9_INDEXES {
            c.execute_batch(&format!("DROP INDEX {i}")).unwrap();
        }
        let before: Vec<(f64, usize)> = queries.iter().map(|q| time(&c, &q.2)).collect();
        println!("{cards} 张卡 / {decks} 个牌组 / {logs} 条日志；每条查询 20 次取平均");
        for (k, q) in queries.iter().enumerate() {
            println!(
                "{}: v8 {:.3} ms -> v9 {:.3} ms（{} 行）",
                q.0, before[k].0, after[k].0, after[k].1
            );
            assert_eq!(before[k].1, after[k].1, "{}: row count differs", q.0);
        }
        drop(c);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
