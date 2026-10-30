//! 日志 / 修改记录投影按操作存（srs.db schema v17，2026-10-30 磁盘占用）。
//!
//! 投影行的 `json`（Dart `SrsReviewLog.toJson` / `SrsFieldEdit.toJson` 的线格式）几乎完全是它那条操作的另一种写法：
//! [super::log_row] / [super::edit_row] 从操作推出来。以前每行把这段文字原样再存一遍（10 万卡库约 280 MB，加上
//! 行内重复的键）。现在存储表（[LOGS].table / [EDITS].table）只存定长列、指向操作的 `(op_dev, op_seq)`，与
//! **推导结果里不同的那几个键**（`x`，规范 JSON 对象；通常为空）：
//!
//! - 修改记录的 `ctx` 并上了投影那一刻的旧修改记录闭包（库状态，不是操作的函数）——闭包非空时记成覆盖键；
//! - 重放改写的日志 `res`——与作者原值不同时记成覆盖键；
//! - 推不出来的行（迁移进来、还没有操作的旧行，Dart 改写过的行，原文不是规范 JSON 的行）`op_dev` 为 NULL，`x` 是原文。
//!
//! 存法只在落库时定，且**逐字验证**：`推导 ∪ 覆盖` 的规范 JSON 必须与原文逐字节相同，否则存原文。读侧一律经同名视图
//! （`srs_review_logs` / `srs_field_edits`，列与旧表相同，另带 `rowid`）：`json` 列由 SQL 函数 [`sync2_proj`] 当场
//! 拼回原文。Dart 的全部读法（查询构造器、导出、备份快照、跨库合并、按 rowid 分页）不变；写视图的走 INSTEAD OF
//! 触发器落成原文行。摘要触发器挂在存储表上、按拼回的原文算行哈希，所以摘要与 v16 逐位相同。
//!
//! 被指向的操作必须不变：改写操作载荷（彻底清除）或删掉操作（换身份重签发）之前先把指向它的行写回原文
//! （[materialize]）。行指向的操作不在时视图报错（[`sync2_proj_lost`]），不悄悄给出空串。

use rusqlite::functions::{Context, FunctionFlags};
use rusqlite::{params, Connection};
use serde_json::{Map, Value};

use super::{canonical, edit_row_with, load_op, log_row, op_of_row, snapshots, sql};
use crate::sync2::dvv::Dvv;
use crate::sync2::id::Id;
use crate::sync2::op::{Body, Op};
use crate::sync2::vv::OpId;

/// 一张按操作存的投影：对外的视图名（就是 v16 及以前的表名）、存储表、存储表的定长列 DDL（不含指针与 `x`）。
pub(crate) struct Proj {
    pub view: &'static str,
    pub table: &'static str,
    pub cols: &'static [(&'static str, &'static str)],
}

pub(crate) const LOGS: Proj = Proj {
    view: "srs_review_logs",
    table: "srs_review_log_rows",
    cols: &[
        ("id", "TEXT NOT NULL"),
        ("profile_uid", "TEXT NOT NULL"),
        ("card_id", "TEXT NOT NULL"),
        ("kind", "TEXT NOT NULL"),
        ("rating", "INTEGER NULL"),
        ("occurred_at", "INTEGER NOT NULL"),
        ("review_type", "TEXT NOT NULL"),
        ("origin", "TEXT NOT NULL"),
        ("duration_ms", "INTEGER NOT NULL DEFAULT 0"),
    ],
};

pub(crate) const EDITS: Proj = Proj {
    view: "srs_field_edits",
    table: "srs_field_edit_rows",
    cols: &[
        ("id", "TEXT NOT NULL"),
        ("profile_uid", "TEXT NOT NULL"),
        ("entity_kind", "TEXT NOT NULL"),
        ("entity_id", "TEXT NOT NULL"),
        ("field_key", "TEXT NOT NULL"),
        ("writer_id", "TEXT NOT NULL"),
        ("seq", "INTEGER NOT NULL"),
    ],
};

pub(crate) const ALL: [&Proj; 2] = [&LOGS, &EDITS];

impl Proj {
    fn names(&self) -> Vec<&'static str> {
        self.cols.iter().map(|(n, _)| *n).collect()
    }

    /// 某一侧（表别名 / `NEW` / `OLD`）这一行的原文表达式。
    pub(crate) fn json_expr(&self, side: &str) -> String {
        format!(
            "CASE WHEN {side}.op_dev IS NULL THEN {side}.x ELSE COALESCE((SELECT sync2_proj({side}.x, o.profile_uid, o.device, \
             o.seq, o.wall, o.logical, d.vv, o.kind, o.schema, o.payload, o.sc_at, \
             (SELECT b.body FROM sync2_snapshots b WHERE b.hash = o.sc)) FROM sync2_ops o JOIN sync2_deps d ON d.id = o.deps \
             WHERE o.profile_uid = {side}.profile_uid AND o.device = {side}.op_dev AND o.seq = {side}.op_seq), \
             sync2_proj_lost({side}.id)) END"
        )
    }

    fn table_ddl(&self) -> String {
        let cols: Vec<String> = self.cols.iter().map(|(n, t)| format!("{n} {t}")).collect();
        format!(
            "CREATE TABLE IF NOT EXISTS {} ({}, op_dev BLOB NULL, op_seq INTEGER NULL, x TEXT NULL, \
             CHECK (op_dev IS NOT NULL OR x IS NOT NULL), PRIMARY KEY (id));",
            self.table,
            cols.join(", ")
        )
    }

    /// 视图与写视图的 INSTEAD OF 触发器（可重放）。写视图的一律落成原文行（Dart 改写字段值、旧库搬迁）。
    fn view_ddl(&self) -> String {
        let (view, table) = (self.view, self.table);
        let names = self.names();
        let list = names.join(", ");
        // 视图列没有默认值：省略的列按存储表的默认值补。
        let new_vals: Vec<String> = self
            .cols
            .iter()
            .map(|(n, t)| match t.split_once("DEFAULT ") {
                Some((_, d)) => format!("COALESCE(NEW.{n}, {d})"),
                None => format!("NEW.{n}"),
            })
            .collect();
        let sets: Vec<String> = names.iter().map(|n| format!("{n} = NEW.{n}")).collect();
        format!(
            "DROP VIEW IF EXISTS {view};
             CREATE VIEW {view} AS SELECT t.rowid AS rowid, {cols}, {json} AS json FROM {table} t;
             CREATE TRIGGER {view}_ins INSTEAD OF INSERT ON {view} BEGIN
               INSERT INTO {table} ({list}, op_dev, op_seq, x) VALUES ({new_vals}, NULL, NULL, NEW.json); END;
             CREATE TRIGGER {view}_upd INSTEAD OF UPDATE ON {view} BEGIN
               UPDATE {table} SET {sets},
                 op_dev = CASE WHEN NEW.json IS OLD.json THEN op_dev END,
                 op_seq = CASE WHEN NEW.json IS OLD.json THEN op_seq END,
                 x = CASE WHEN NEW.json IS OLD.json THEN x ELSE NEW.json END
               WHERE id = OLD.id; END;
             CREATE TRIGGER {view}_del INSTEAD OF DELETE ON {view} BEGIN DELETE FROM {table} WHERE id = OLD.id; END;",
            cols = names.iter().map(|n| format!("t.{n}")).collect::<Vec<_>>().join(", "),
            json = self.json_expr("t"),
            new_vals = new_vals.join(", "),
            sets = sets.join(", "),
        )
    }
}

// ---------------------------------------------------------------- 推导与存法

/// 一条内容操作推出的投影行（修改记录按空的旧闭包推）。
pub(crate) fn derive(profile: &str, op: &Op) -> Result<Value, String> {
    match op.body().map_err(|e| format!("{e:?}"))? {
        Body::Log(l) => Ok(log_row(profile, op, &l)),
        Body::Edit(e) => Ok(edit_row_with(profile, op, &e, Dvv::default()).1),
        _ => Err("projection row points at a non-content op".into()),
    }
}

/// `推导 ∪ 覆盖键` 的规范 JSON。
pub(crate) fn expand(derived: &Value, x: Option<&str>) -> Result<String, String> {
    let Value::Object(d) = derived else { return Err("derived row is not an object".into()) };
    let mut m: Map<String, Value> = d.clone();
    if let Some(x) = x {
        let Ok(Value::Object(o)) = serde_json::from_str::<Value>(x) else { return Err("bad projection overrides".into()) };
        m.extend(o);
    }
    Ok(canonical(&Value::Object(m)))
}

/// 原文 [text] 相对推导结果的覆盖键：`Some(None)` = 完全推得出；`Some(Some(x))` = 记 x；`None` = 推不出（原文少了
/// 推导里的键、不是规范 JSON 等），只能存原文。结果一律逐字验证过。
pub(crate) fn overrides(text: &str, derived: &Value) -> Option<Option<String>> {
    let Ok(Value::Object(m)) = serde_json::from_str::<Value>(text) else { return None };
    let Value::Object(d) = derived else { return None };
    if d.keys().any(|k| !m.contains_key(k)) {
        return None;
    }
    let diff: Map<String, Value> = m.into_iter().filter(|(k, v)| d.get(k) != Some(v)).collect();
    let x = (!diff.is_empty()).then(|| canonical(&Value::Object(diff)));
    (expand(derived, x.as_deref()).ok()? == text).then_some(x)
}

/// 一行的存法：`(op_dev, op_seq, x)`。
pub(crate) type Form = (Option<Vec<u8>>, Option<i64>, Option<String>);

/// 原文 [text]（由 [op] 投影出来，或之后被重放改写）该怎么存。
pub(crate) fn form_of(profile: &str, op: Option<&Op>, text: &str) -> Form {
    if let Some(op) = op {
        if let Some(x) = derive(profile, op).ok().and_then(|d| overrides(text, &d)) {
            return (Some(op.id.device.0.to_vec()), Some(op.id.seq as i64), x);
        }
    }
    (None, None, Some(text.to_owned()))
}

/// 已有一行改写原文（重放写 `res`）：仍按它指向的操作存。
pub(crate) fn set_text(conn: &Connection, p: &Proj, id: &str, text: &str) -> Result<(), String> {
    let row: Option<(String, Option<Vec<u8>>, Option<i64>)> = conn
        .prepare_cached(&format!("SELECT profile_uid, op_dev, op_seq FROM {} WHERE id = ?1", p.table))
        .map_err(sql)?
        .query_row([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map(Some)
        .or_else(|e| if e == rusqlite::Error::QueryReturnedNoRows { Ok(None) } else { Err(e) })
        .map_err(sql)?;
    let Some((profile, dev, seq)) = row else { return Ok(()) };
    let op = match (dev, seq) {
        (Some(d), Some(s)) => load_op(conn, &profile, &op_id(d, s)?)?,
        _ => None,
    };
    let (d, s, x) = form_of(&profile, op.as_ref(), text);
    conn.prepare_cached(&format!("UPDATE {} SET op_dev = ?2, op_seq = ?3, x = ?4 WHERE id = ?1", p.table))
        .map_err(sql)?
        .execute(params![id, d, s, x])
        .map_err(sql)?;
    Ok(())
}

/// [op] 的载荷要被改写 / 操作要被删掉：指向它的投影行先写回原文。
pub(crate) fn materialize(conn: &Connection, profile: &str, op: &Op) -> Result<(), String> {
    let (p, id) = match op.body() {
        Ok(Body::Log(l)) => (&LOGS, l.id.text()),
        Ok(Body::Edit(e)) => (&EDITS, edit_row_with(profile, op, &e, Dvv::default()).0),
        _ => return Ok(()),
    };
    conn.prepare_cached(&format!(
        "UPDATE {table} SET x = (SELECT json FROM {view} WHERE id = ?1), op_dev = NULL, op_seq = NULL \
         WHERE id = ?1 AND op_dev = ?2 AND op_seq = ?3",
        table = p.table,
        view = p.view
    ))
    .map_err(sql)?
    .execute(params![id, op.id.device.0.to_vec(), op.id.seq as i64])
    .map_err(sql)?;
    Ok(())
}

fn op_id(dev: Vec<u8>, seq: i64) -> Result<OpId, String> {
    Ok(OpId { device: Id(dev.try_into().map_err(|_| "bad device".to_string())?), seq: seq as u64 })
}

// ---------------------------------------------------------------- SQL 函数

fn udf_err(e: String) -> rusqlite::Error {
    rusqlite::Error::UserFunctionError(e.into())
}

fn proj_udf(ctx: &Context<'_>) -> rusqlite::Result<String> {
    let x: Option<String> = ctx.get(0)?;
    let profile: String = ctx.get(1)?;
    let id = op_id(ctx.get(2)?, ctx.get(3)?).map_err(udf_err)?;
    let vv: Vec<u8> = ctx.get(6)?;
    let at: Option<i64> = ctx.get(10)?;
    let body: Option<String> = ctx.get(11)?;
    let payload = snapshots::splice(ctx.get(9)?, body.as_deref(), at).map_err(udf_err)?;
    let op = op_of_row(&id, ctx.get(4)?, ctx.get(5)?, &vv, ctx.get(7)?, ctx.get(8)?, payload, false).map_err(udf_err)?;
    expand(&derive(&profile, &op).map_err(udf_err)?, x.as_deref()).map_err(udf_err)
}

/// 视图与摘要触发器用的 SQL 函数（每条连接打开时注册，与摘要函数同处）。
pub fn register(conn: &Connection) -> rusqlite::Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC | FunctionFlags::SQLITE_INNOCUOUS;
    conn.create_scalar_function("sync2_proj", 12, flags, proj_udf)?;
    conn.create_scalar_function("sync2_proj_lost", 1, flags, |ctx| -> rusqlite::Result<String> {
        let id: String = ctx.get(0)?;
        Err(udf_err(format!("projection row {id} points at a missing op")))
    })?;
    Ok(())
}

// ---------------------------------------------------------------- v17 升级

/// 旧表换成「存储表 + 同名视图」，再把推得出的行改成按操作存（可重放：已换过的跳过，已按操作存的不再动）。
/// 摘要触发器由调用方随后重装（[super::digest::install]）；行原文不变，桶不用重建。
pub(crate) fn migrate(c: &Connection) -> Result<(), String> {
    for p in ALL {
        let is_table: bool = c
            .query_row("SELECT type = 'table' FROM sqlite_master WHERE name = ?1", [p.view], |r| r.get(0))
            .unwrap_or(false);
        c.execute_batch(&p.table_ddl()).map_err(sql)?;
        if is_table {
            let indexes: Vec<String> = c
                .prepare("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ?1 AND sql IS NOT NULL")
                .map_err(sql)?
                .query_map([p.view], |r| r.get(0))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            let list = p.names().join(", ");
            c.execute_batch(&format!(
                "INSERT INTO {table} (rowid, {list}, op_dev, op_seq, x) SELECT rowid, {list}, NULL, NULL, json FROM {view} ORDER BY rowid;
                 DROP TABLE {view};",
                table = p.table,
                view = p.view
            ))
            .map_err(sql)?;
            for ix in indexes {
                c.execute_batch(&retarget(&ix, p.view, p.table)?).map_err(sql)?;
            }
        }
        c.execute_batch(&p.view_ddl()).map_err(sql)?;
    }
    compact(c, &LOGS, "sync2_log_meta", "log_id")?;
    compact(c, &EDITS, "sync2_edit_ops", "edit_id")?;
    Ok(())
}

/// 升级阶梯里 v17 之前的步骤在已经是 v17 形状的库上重放（标回旧版本号的库）：建在旧表名上的索引改建到存储表上，
/// 每一步照旧可重放。还是旧形状的库原样返回。
pub(crate) fn redirect(c: &Connection, ddl: &str) -> String {
    let mut out = ddl.to_owned();
    for p in ALL {
        let reshaped = c.query_row("SELECT 1 FROM sqlite_master WHERE type = 'view' AND name = ?1", [p.view], |_| Ok(())).is_ok();
        if !reshaped {
            continue;
        }
        let needle = format!(" ON {}", p.view);
        let mut acc = String::with_capacity(out.len());
        let mut rest = out.as_str();
        while let Some(i) = rest.find(&needle) {
            let after = &rest[i + needle.len()..];
            acc.push_str(&rest[..i]);
            if after.starts_with(|ch: char| ch.is_whitespace() || ch == '(') {
                acc.push_str(&format!(" ON {}", p.table));
            } else {
                acc.push_str(&needle);
            }
            rest = after;
        }
        acc.push_str(rest);
        out = acc;
    }
    out
}

/// 索引 DDL 里的 `ON <旧表>` 换成存储表（名字后面跟空白或括号）。
fn retarget(ddl: &str, from: &str, to: &str) -> Result<String, String> {
    let needle = format!(" ON {from}");
    let at = ddl
        .match_indices(&needle)
        .map(|(i, _)| i)
        .find(|&i| ddl[i + needle.len()..].starts_with(|ch: char| ch.is_whitespace() || ch == '('))
        .ok_or_else(|| format!("cannot retarget index: {ddl}"))?;
    Ok(format!("{} ON {to}{}", &ddl[..at], &ddl[at + needle.len()..]))
}

/// 原文行里推得出的改成按操作存（操作经日志元数据 / 修改记录映射找）。按 rowid 分页，不整表进内存。
fn compact(c: &Connection, p: &Proj, map: &str, key: &str) -> Result<(), String> {
    let mut after = 0i64;
    loop {
        let page: Vec<(i64, String, String, Vec<u8>, i64)> = c
            .prepare_cached(&format!(
                "SELECT t.rowid, t.profile_uid, t.x, m.device, m.seq FROM {table} t JOIN {map} m ON m.{key} = t.id \
                 WHERE t.rowid > ?1 AND t.op_dev IS NULL ORDER BY t.rowid LIMIT 2000",
                table = p.table
            ))
            .map_err(sql)?
            .query_map([after], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let Some(last) = page.last() else { return Ok(()) };
        after = last.0;
        for (rowid, profile, text, dev, seq) in page {
            let Some(op) = load_op(c, &profile, &op_id(dev, seq)?)? else { continue };
            let (d, s, x) = form_of(&profile, Some(&op), &text);
            if d.is_some() {
                c.prepare_cached(&format!("UPDATE {} SET op_dev = ?2, op_seq = ?3, x = ?4 WHERE rowid = ?1", p.table))
                    .map_err(sql)?
                    .execute(params![rowid, d, s, x])
                    .map_err(sql)?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn overrides_reproduce_the_text_byte_for_byte() {
        let d = json!({"id": "a", "res": {"ivl": 1}, "ctx": {"vv": {}}, "n": 0.8});
        let text = canonical(&d);
        assert_eq!(overrides(&text, &d), Some(None));
        let changed = canonical(&json!({"id": "a", "res": {"ivl": 3}, "ctx": {"vv": {}}, "n": 0.8}));
        let x = overrides(&changed, &d).unwrap().unwrap();
        assert_eq!(x, r#"{"res":{"ivl":3}}"#);
        assert_eq!(expand(&d, Some(&x)).unwrap(), changed);
        // 多出来的键也是覆盖键；少了推导里的键、不是规范 JSON：推不出。
        let extra = canonical(&json!({"id": "a", "res": {"ivl": 1}, "ctx": {"vv": {}}, "n": 0.8, "z": 1}));
        assert_eq!(overrides(&extra, &d), Some(Some(r#"{"z":1}"#.into())));
        assert_eq!(overrides(r#"{"id":"a"}"#, &d), None);
        assert_eq!(overrides(&format!(" {text}"), &d), None);
    }
}
