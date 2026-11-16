//! ID 审计接到新代（G9-7）：`id_audit` 构建的库里，新代库的每条连接都盯住「拿 UUID 文本当 ID 绑定 / 写进 ID 列」。
//!
//! 新代的 ID 列存 [super::derive::Ref]：规范小写带连字符的 UUID 存 16 字节 BLOB，别的文本原样存（`sync2::id::Key`）。所以
//! 拿 UUID **文本**去和 ID 列比较永远查不到、写进去就是另一个值——与协议 3 的 `srs_id` 漏编码（`store/ids.rs` `audit`）
//! 同一类静默错误。协议 3 的审计挂在协议 3 的写连接与 `SrsCore::exec_raw` 上，换代之后生产入口只走 [super::kernel::G4Core]，
//! 那条路一次都不经过，审计版的库等于没审计（`build_windows_dll.ps1 -IdAudit` 的「库里有 `id audit: `」校验也因此失败）。
//!
//! - **哪些列算 ID 列**：新代 schema 里有表把它声明成 `BLOB` 或没写类型（存 [super::derive::Ref] 或字节串）、且没有任何
//!   一张表把同名的列声明成 `TEXT` 的列名（按文本存 ID 的列，如 `held.entity`、`collections.profile_uid`，不算；`id` 在
//!   `op_deps` 等表里是整数——拿 UUID 文本去比整数列一样查不到，照算）。存储扫描只扫声明成 `BLOB` / 无类型的那些格。
//!   表从新代的建表语句里取（[schema::open_in_memory]），不手抄一份列清单，加表 / 加列自动跟上。
//! - **语句**：每条连接装 SQLite trace（[install]），绑定参数展开后的 SQL 里有拿去和 ID 列比较的 UUID 文本字面量就记下来
//!   （判定与协议 3 同一份：`ids::audit::quoted_uuid_with`；`json_extract` / `srs_meta` / `-- ids:text` 照样豁免）。新代没有
//!   `srs_id(` 这一层，所以不用协议 3「整条语句没有 `srs_id(` 就任何字面量都算」那条：按文本存 profile uid / 目录名的列
//!   本来就该绑文本。
//! - **存储**：Dart 经原始通道（`raw_sql`，测试用）写过之后，扫一遍 ID 列里有没有 UUID 形状的文本值。
//! - **报错**：[take] 把这期间记下的问题转成 `id audit: …` 错误，由分发器（每条命令之后，`dispatch.rs`）与原始通道
//!   （`kernel.rs` `exec_raw` / `exec_batch_raw`）交回 Dart。并发的两条命令可能互相取走对方记下的问题——这是调试构建，
//!   只保证「有就报」，不保证报在哪条命令上（协议 3 同口径）。

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, OnceLock};

use rusqlite::Connection;

use super::schema;
use crate::store::ids::audit::{allowed, quoted_uuid_with};

static HITS: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// 新代 schema 的 ID 列：`(表, 列)` 清单（存储扫描用）与列名集合（语句判定用）。见模块说明「哪些列算 ID 列」。
struct Columns {
    cells: Vec<(String, String)>,
    names: BTreeSet<String>,
}

fn columns() -> &'static Columns {
    static COLUMNS: OnceLock<Columns> = OnceLock::new();
    COLUMNS.get_or_init(|| {
        let conn = schema::open_in_memory().expect("gen4 id audit: build the schema in memory");
        let mut stmt = conn
            .prepare(
                "SELECT m.name, p.name, upper(p.type) FROM sqlite_schema m \
                 JOIN pragma_table_info(m.name) p \
                 WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' ORDER BY m.name, p.cid",
            )
            .expect("gen4 id audit: list columns");
        let rows: Vec<(String, String, String)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .expect("gen4 id audit: list columns")
            .collect::<Result<_, _>>()
            .expect("gen4 id audit: list columns");
        let blob = |ty: &str| ty.is_empty() || ty == "BLOB";
        // 列名 → (有表存 Ref, 有表按文本存)。
        let mut seen: BTreeMap<String, (bool, bool)> = BTreeMap::new();
        for (_, col, ty) in &rows {
            let e = seen.entry(col.to_ascii_lowercase()).or_default();
            e.0 |= blob(ty);
            e.1 |= ty == "TEXT";
        }
        let names: BTreeSet<String> = seen
            .into_iter()
            .filter(|(_, (r, t))| *r && !*t)
            .map(|(n, _)| n)
            .collect();
        let cells = rows
            .into_iter()
            .filter(|(_, col, ty)| blob(ty) && names.contains(&col.to_ascii_lowercase()))
            .map(|(t, c, _)| (t, c))
            .collect();
        Columns { cells, names }
    })
}

fn is_id_column(name: &str) -> bool {
    columns().names.contains(&name.to_ascii_lowercase())
}

/// [sql] 里有拿去和新代 ID 列比较的 UUID 文本字面量（豁免见模块说明）。
pub(crate) fn quoted(sql: &str) -> bool {
    quoted_uuid_with(sql, false, is_id_column) && !allowed(sql)
}

/// 给 [conn] 装上语句审计（每条语句执行前看一次绑定参数展开后的 SQL）。
#[allow(deprecated)]
pub(crate) fn install(conn: &mut Connection) {
    // 先把列清单建好：trace 回调里不建库。
    let _ = columns();
    conn.trace(Some(|sql: &str| {
        if quoted(sql) {
            HITS.lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(sql.to_owned());
        }
    }));
}

/// UUID 文本的 GLOB 模式（小写、带连字符：只有这种文本会存成 16 字节）。
fn uuid_glob() -> String {
    let h = "[0-9a-f]";
    [8, 4, 4, 4, 12]
        .iter()
        .map(|n| h.repeat(*n))
        .collect::<Vec<_>>()
        .join("-")
}

/// [c] 上 ID 列里存成文本的 UUID（每列至多报一个）。
pub(crate) fn stored_text(c: &Connection) -> Vec<String> {
    let glob = uuid_glob();
    let mut out = Vec::new();
    for (table, col) in &columns().cells {
        let q = format!(
            "SELECT \"{col}\" FROM \"{table}\" WHERE typeof(\"{col}\") = 'text' AND \"{col}\" GLOB '{glob}' LIMIT 1"
        );
        if let Ok(v) = c.query_row(&q, [], |r| r.get::<_, String>(0)) {
            out.push(format!("{table}.{col} stores text UUID {v}"));
        }
    }
    out
}

/// 取走这期间记下的问题，有就报 `id audit: …`。[stored] 给了连接 = 再扫一遍它的 ID 列（原始通道写过之后）。
pub(crate) fn take(stored: Option<&Connection>) -> Result<(), String> {
    let mut hits = std::mem::take(&mut *HITS.lock().unwrap_or_else(|e| e.into_inner()));
    if let Some(c) = stored {
        hits.extend(stored_text(c));
    }
    if hits.is_empty() {
        return Ok(());
    }
    Err(format!("id audit: {}", hits.join("\n---\n")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::gen4::derive::Ref;
    use crate::sync2::id::Key;

    /// [HITS] 是进程级的：本模块的用例串行跑，互不取走对方的记录。
    static SERIAL: Mutex<()> = Mutex::new(());

    const U: &str = "019a5e4c-0000-7000-8000-00000000abcd";

    fn conn() -> Connection {
        let mut c = schema::open_in_memory().unwrap();
        install(&mut c);
        let _ = take(None);
        c
    }

    #[test]
    fn id_columns_come_from_the_gen4_schema() {
        for c in [
            "id",
            "note_id",
            "deck_id",
            "card",
            "log",
            "device",
            "collection",
            "canon",
        ] {
            assert!(is_id_column(c), "{c}");
        }
        // 按文本存 ID / 名字的列，与整数列。
        for c in [
            "profile_uid",
            "dir",
            "entity",
            "salts",
            "key",
            "col",
            "k",
            "name",
            "kind",
        ] {
            assert!(!is_id_column(c), "{c}");
        }
        assert!(
            columns()
                .cells
                .iter()
                .any(|(t, c)| t == "notes" && c == "id")
        );
    }

    #[test]
    fn a_text_uuid_compared_to_an_id_column_is_reported() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let c = conn();
        c.query_row(
            "SELECT count(*) FROM notes WHERE col = 1 AND id = ?1",
            [U],
            |r| r.get::<_, i64>(0),
        )
        .unwrap();
        let err = take(None).unwrap_err();
        assert!(err.starts_with("id audit: "), "{err}");
        assert!(err.contains(U), "{err}");
        // 按 Ref 绑（16 字节）不报；拿文本和按文本存 uid 的列比也不报。
        c.query_row(
            "SELECT count(*) FROM notes WHERE col = 1 AND id = ?1",
            [Ref::of(&Key::of(U))],
            |r| r.get::<_, i64>(0),
        )
        .unwrap();
        c.query_row(
            "SELECT count(*) FROM collections WHERE profile_uid = ?1",
            [U],
            |r| r.get::<_, i64>(0),
        )
        .unwrap();
        assert_eq!(take(None), Ok(()));
    }

    #[test]
    fn a_text_uuid_stored_in_an_id_column_is_reported_after_a_raw_write() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let c = conn();
        c.execute(
            "INSERT INTO cache_log (col, gen, note) VALUES (1, 1, ?1)",
            [U],
        )
        .unwrap();
        // 语句本身没有比较（INSERT），只有扫存储才看得到。
        assert_eq!(take(None), Ok(()));
        let err = take(Some(&c)).unwrap_err();
        assert!(err.contains("cache_log.note stores text UUID"), "{err}");
        c.execute("DELETE FROM cache_log", []).unwrap();
        c.execute(
            "INSERT INTO cache_log (col, gen, note) VALUES (1, 1, ?1)",
            [Ref::of(&Key::of(U))],
        )
        .unwrap();
        assert_eq!(take(Some(&c)), Ok(()));
    }
}
