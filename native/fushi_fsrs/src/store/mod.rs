//! SRS 事件库：Rust 独占的 `srs.db`（docs/specs/2026-10-23-srs-rust-store.md）。
//!
//! 一条写连接 + 一条读连接，各在一把 Mutex 里：写命令 = 写连接上的一个事务（这把锁就是 SRS 的
//! 写锁），读命令走读连接上的 WAL 快照，不被长写挡住。对象可以从任意线程 / isolate 调用。
//!
//! 只打开 `srs.db`、它的备份快照副本或自己生成的临时文件；绝不打开主库 `fushi.db`（同一进程里
//! Drift 那份 SQLite 与这里自带的一份同开一个文件，会在 POSIX 平台上互相清掉文件锁）。

pub mod ffi;
pub mod rows;
pub mod schema;

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use rusqlite::types::Value;
use rusqlite::{Connection, OpenFlags};

const LEGACY_KEY: &str = "legacy_import";

pub struct SrsCore {
    writer: Mutex<Connection>,
    reader: Mutex<Connection>,
    /// 旧库搬迁的事务开着（写连接上挂着一个 BEGIN）：别的写命令一律拒绝。
    legacy_open: AtomicBool,
}

fn configure(conn: &Connection) -> Result<(), String> {
    conn.busy_timeout(Duration::from_millis(5000))
        .map_err(|e| e.to_string())?;
    conn.execute_batch("PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = OFF;")
        .map_err(|e| e.to_string())
}

impl SrsCore {
    /// 打开（不存在就建）。建表 / 升级在写连接上一个事务里做完才开读连接。
    pub fn open(path: &Path) -> Result<Self, String> {
        let mut writer = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("open {}: {e}", path.display()))?;
        configure(&writer)?;
        let mode: String = writer
            .query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))
            .map_err(|e| e.to_string())?;
        if !mode.eq_ignore_ascii_case("wal") {
            return Err(format!("srs.db journal_mode is {mode}, expected wal"));
        }
        schema::migrate(&mut writer)?;
        let reader = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("open reader {}: {e}", path.display()))?;
        configure(&reader)?;
        Ok(Self {
            writer: Mutex::new(writer),
            reader: Mutex::new(reader),
            legacy_open: AtomicBool::new(false),
        })
    }

    pub(crate) fn writer(&self) -> Result<std::sync::MutexGuard<'_, Connection>, String> {
        self.writer.lock().map_err(|_| "srs writer poisoned".to_string())
    }

    pub(crate) fn reader(&self) -> Result<std::sync::MutexGuard<'_, Connection>, String> {
        self.reader.lock().map_err(|_| "srs reader poisoned".to_string())
    }

    fn meta(conn: &Connection, key: &str) -> Result<Option<String>, String> {
        match conn.query_row("SELECT value FROM srs_meta WHERE key = ?1", [key], |r| r.get(0)) {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    fn set_meta(conn: &Connection, key: &str, value: &str) -> Result<(), String> {
        conn.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    // ------------------------------------------------------------ 旧库搬迁（§3）

    /// 旧主库里的 SRS 数据是否已搬进来（或确认没有要搬的）。
    pub fn legacy_imported(&self) -> Result<bool, String> {
        let w = self.writer()?;
        Ok(Self::meta(&w, LEGACY_KEY)?.is_some())
    }

    /// 开搬迁事务：清空 9 张表（未写标记的库里不该有东西；上一次搬到一半崩溃时 SQLite 已回滚）。
    pub fn legacy_begin(&self) -> Result<(), String> {
        let w = self.writer()?;
        if Self::meta(&w, LEGACY_KEY)?.is_some() {
            return Err("legacy store already imported".into());
        }
        if self.legacy_open.swap(true, Ordering::SeqCst) {
            return Err("legacy import already in progress".into());
        }
        let mut sql = String::from("BEGIN IMMEDIATE;");
        for t in schema::TABLES {
            sql.push_str(&format!("DELETE FROM {};", t.name));
        }
        if let Err(e) = w.execute_batch(&sql) {
            let _ = w.execute_batch("ROLLBACK");
            self.legacy_open.store(false, Ordering::SeqCst);
            return Err(e.to_string());
        }
        Ok(())
    }

    /// 写一页旧表行（列序 = [schema::TABLES] 里该表的列序）。
    pub fn legacy_page(&self, table: &str, page: &[u8]) -> Result<usize, String> {
        if !self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import not started".into());
        }
        let t = schema::table(table).ok_or_else(|| format!("unknown srs table {table}"))?;
        let (n_cols, rows) = rows::decode(page)?;
        if n_cols != t.columns.len() && !rows.is_empty() {
            return Err(format!(
                "{table}: page has {n_cols} columns, expected {}",
                t.columns.len()
            ));
        }
        let w = self.writer()?;
        let marks = vec!["?"; t.columns.len()].join(", ");
        let sql = format!(
            "INSERT INTO {} ({}) VALUES ({marks})",
            t.name,
            t.columns.join(", ")
        );
        let mut stmt = w.prepare_cached(&sql).map_err(|e| e.to_string())?;
        for row in &rows {
            stmt.execute(rusqlite::params_from_iter(row.iter()))
                .map_err(|e| format!("{table}: {e}"))?;
        }
        Ok(rows.len())
    }

    /// 写标记并提交。
    pub fn legacy_commit(&self) -> Result<(), String> {
        if !self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import not started".into());
        }
        let w = self.writer()?;
        let result = Self::set_meta(&w, LEGACY_KEY, "1").and_then(|_| {
            w.execute_batch("COMMIT").map_err(|e| e.to_string())
        });
        if result.is_err() {
            let _ = w.execute_batch("ROLLBACK");
        }
        self.legacy_open.store(false, Ordering::SeqCst);
        result
    }

    pub fn legacy_abort(&self) -> Result<(), String> {
        if !self.legacy_open.swap(false, Ordering::SeqCst) {
            return Ok(());
        }
        let w = self.writer()?;
        w.execute_batch("ROLLBACK").map_err(|e| e.to_string())
    }

    /// 主库里本来就没有 SRS 表（新装）：直接写标记。
    pub fn legacy_mark_none(&self) -> Result<(), String> {
        let w = self.writer()?;
        Self::set_meta(&w, LEGACY_KEY, "0")
    }

    // ------------------------------------------------------------ 备份快照

    /// `VACUUM INTO` 一份一致快照（读连接上做：不挡写）。`strip_device_local` 时在快照里清空
    /// 5 张设备本地表（本机状态、发件箱元信息、留存批次、两张缓存），与通用备份的规则一致。
    pub fn snapshot_into(&self, target: &Path, strip_device_local: bool) -> Result<(), String> {
        if target.exists() {
            return Err(format!("{} already exists", target.display()));
        }
        let target_str = target
            .to_str()
            .ok_or_else(|| "snapshot path is not UTF-8".to_string())?;
        {
            let r = self.reader()?;
            r.execute("VACUUM INTO ?1", [target_str])
                .map_err(|e| e.to_string())?;
        }
        if strip_device_local {
            let snap = Connection::open(target).map_err(|e| e.to_string())?;
            snap.execute_batch(
                "BEGIN; DELETE FROM srs_event_local; DELETE FROM srs_local_state; \
                 DELETE FROM srs_sent_batches; DELETE FROM srs_notes_cache; \
                 DELETE FROM srs_cards_cache; DELETE FROM srs_meta WHERE key = 'legacy_import'; \
                 COMMIT; VACUUM;",
            )
            .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    // ------------------------------------------------------------ 测试 / 诊断

    /// 在读连接上跑一条只读 SQL，结果按 [rows] 编码；第一行是列名（文本）。只给测试与诊断用：
    /// 产品代码一律走粗粒度命令。
    pub fn debug_query(&self, sql: &str, params: &[Value]) -> Result<Vec<u8>, String> {
        let r = self.reader()?;
        let mut stmt = r.prepare(sql).map_err(|e| e.to_string())?;
        if !stmt.readonly() {
            return Err("debug_query only runs read-only statements".into());
        }
        let names: Vec<Value> = stmt
            .column_names()
            .iter()
            .map(|n| Value::Text((*n).to_string()))
            .collect();
        let n = names.len();
        let mut out: Vec<Vec<Value>> = vec![names];
        let mut q = stmt
            .query(rusqlite::params_from_iter(params.iter()))
            .map_err(|e| e.to_string())?;
        while let Some(row) = q.next().map_err(|e| e.to_string())? {
            let mut vals = Vec::with_capacity(n);
            for i in 0..n {
                vals.push(row.get::<_, Value>(i).map_err(|e| e.to_string())?);
            }
            out.push(vals);
        }
        Ok(rows::encode(n, &out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ffsrs_store_{}_{}_{}",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("srs.db")
    }

    fn count(core: &SrsCore, table: &str) -> i64 {
        core.reader()
            .unwrap()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn open_creates_schema_and_is_idempotent() {
        let p = temp("open");
        {
            let core = SrsCore::open(&p).unwrap();
            assert!(!core.legacy_imported().unwrap());
            for t in schema::TABLES {
                assert_eq!(count(&core, t.name), 0);
            }
        }
        let core = SrsCore::open(&p).unwrap();
        let idx: i64 = core
            .reader()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name LIKE 'idx_srs_%'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(idx, 9);
    }

    #[test]
    fn legacy_import_roundtrip_and_rollback() {
        let p = temp("legacy");
        let core = SrsCore::open(&p).unwrap();
        let page = rows::encode(
            3,
            &[
                vec![Value::Text("e1".into()), Value::Text("p".into()), Value::Text("{}".into())],
                vec![Value::Text("e2".into()), Value::Text("p".into()), Value::Text("{\"a\":1}".into())],
            ],
        );
        core.legacy_begin().unwrap();
        assert_eq!(core.legacy_page("srs_unknown_events", &page).unwrap(), 2);
        core.legacy_abort().unwrap();
        assert_eq!(count(&core, "srs_unknown_events"), 0);
        assert!(!core.legacy_imported().unwrap());

        core.legacy_begin().unwrap();
        core.legacy_page("srs_unknown_events", &page).unwrap();
        assert!(core.legacy_page("srs_nope", &page).is_err());
        let bad_cols = rows::encode(2, &[vec![Value::Text("x".into()), Value::Null]]);
        assert!(core.legacy_page("srs_unknown_events", &bad_cols).is_err());
        core.legacy_commit().unwrap();
        assert!(core.legacy_imported().unwrap());
        assert_eq!(count(&core, "srs_unknown_events"), 2);
        assert!(core.legacy_begin().is_err());
    }

    #[test]
    fn snapshot_strips_device_local_tables() {
        let p = temp("snap");
        let core = SrsCore::open(&p).unwrap();
        core.legacy_begin().unwrap();
        core.legacy_page(
            "srs_local_state",
            &rows::encode(2, &[vec![Value::Text("p".into()), Value::Text("{}".into())]]),
        )
        .unwrap();
        core.legacy_page(
            "srs_unknown_events",
            &rows::encode(
                3,
                &[vec![Value::Text("e".into()), Value::Text("p".into()), Value::Text("{}".into())]],
            ),
        )
        .unwrap();
        core.legacy_commit().unwrap();
        let snap = p.with_file_name("snap.db");
        core.snapshot_into(&snap, true).unwrap();
        let s = SrsCore::open(&snap).unwrap();
        assert_eq!(count(&s, "srs_local_state"), 0);
        assert_eq!(count(&s, "srs_unknown_events"), 1);
        assert!(!s.legacy_imported().unwrap());
    }

    #[test]
    fn debug_query_rejects_writes_and_encodes_header() {
        let p = temp("dbg");
        let core = SrsCore::open(&p).unwrap();
        assert!(core.debug_query("DELETE FROM srs_meta", &[]).is_err());
        let out = core
            .debug_query("SELECT key, value FROM srs_meta WHERE key = ?1", &[Value::Text("schema".into())])
            .unwrap();
        let (cols, rows) = rows::decode(&out).unwrap();
        assert_eq!(cols, 2);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0][0], Value::Text("key".into()));
        assert_eq!(rows[1][1], Value::Text("1".into()));
    }
}
