//! 按集合的两条小读命令（G7-4e）：`binding_get`、`profile_footprint`。**还没接分发器**：协议 3 的
//! `SrsCore::binding_get`（`store/binding.rs`）与 `SrsCore::profile_footprint`（`store/profile_data.rs`）原地不动，
//! 分发器在整批推送里一次切到这里（规划 §2.2 S1）。协议 3 按 profile uid 查，这里按本机集合号（profile → 集合由
//! [Truth::binding_of] 换算，接线时做）。
//!
//! # 形状（与协议 3 逐键相同）
//!
//! - `binding_get` → `{"binding": {"state", "via", "at"} | null}`。存在 `collections` 的 `state / via / at` 三列
//!   （G7-1；迁移由 `carry.rs` 用协议 3 同一份解析搬来），认不出的值当没有记录（[Truth::binding_state]）。
//! - `profile_footprint` → `{"notes", "cards", "reviews", "rows"}`：
//!   - `notes`：没删除的笔记（缓存层 `notes`，`deleted_at IS NULL`；一个别名类一行）；
//!   - `cards`：笔记没删除的卡（缓存层 `cards`，协议 3 同一句 `EXISTS`）；
//!   - `reviews`：全部复习日志，按规范日志 ID 一条（`log_ix` 每个日志 ID 的代表 `win = 1`，再按类去重）——含已删卡的
//!     （协议 3 数 `srs_review_logs` 的全部行，d 项）；
//!   - `rows`：这个集合在库里的总行数（Dart `SrsProfileFootprint.isEmpty` 只看它是不是 0）。协议 3 数各张按 profile 分的
//!     表；新代数各张带 `col` 列的表（集合绑定 `collections` 本身除外：绑了没写过东西的集合仍是空的）、按操作主键寻址的
//!     真相表（`ops` / `op_alias` / `op_voids` / `op_pending` / `op_forks` / `op_wait`，按本集合设备的主键区间）与按设备
//!     下标的 `log_marks`。表清单在库里现查（同协议 3 `profile_tables`），以后加表不用改这里。具体数值与协议 3 不同
//!     （表不同），只有「是不是 0」是契约。
//!
//! # 代价
//!
//! `binding_get` 一次主键点读。`profile_footprint` 本来就是数数：各表沿 `col`（或主键区间）打头的索引计数，与协议 3
//! 的 `COUNT(*)` 同阶；`reviews` 每个日志代表做一次归一（别名表点读）。只在清理 profile 的页面上用，不在热路径。

use std::collections::HashSet;

use rusqlite::params;
use serde_json::{Value, json};

use super::snapshot;
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::schema::{k_range, sql};
use crate::store::gen4::truth::Truth;

/// `binding_get`：集合 [col] 的绑定状态（模块文件头）。一个读快照。
pub fn binding_get(t: &Truth<'_>, col: i64) -> Result<Value, String> {
    snapshot(t, |t| {
        Ok(json!({"binding": t.binding_state(col)?.map(|b| b.json())}))
    })
}

/// `profile_footprint`：集合 [col] 的规模（模块文件头）。一个读快照：几个数出自同一份数据。
pub fn profile_footprint(t: &Truth<'_>, col: i64) -> Result<Value, String> {
    snapshot(t, |t| {
        let conn = t.conn();
        let count = |q: &str| -> Result<i64, String> {
            conn.prepare_cached(q)
                .map_err(sql)?
                .query_row([col], |r| r.get(0))
                .map_err(sql)
        };
        let notes = count("SELECT COUNT(*) FROM notes WHERE col = ?1 AND deleted_at IS NULL")?;
        let cards = count(
            "SELECT COUNT(*) FROM cards c WHERE c.col = ?1 AND EXISTS \
             (SELECT 1 FROM notes n WHERE n.col = c.col AND n.id = c.note_id AND n.deleted_at IS NULL)",
        )?;
        let reviews = reviews(t, col)?;
        let rows = rows(t, col)?;
        Ok(json!({"notes": notes, "cards": cards, "reviews": reviews, "rows": rows}))
    })
}

/// `profile_footprint` 按 profile（分发器接的是这一条）：这个 profile 在本机没有集合（从没在新代里打开过、或已经被
/// `profile_purge` 删掉）= 全 0——库里没有它的任何东西，与 `profile_purge` 对没绑定的 profile 回全 0 同口径。删 profile
/// 的确认框、删完的核对、存量扫描都要能对这种 profile 数数，不能报「没有集合」让删除走不下去。绑定与计数同一个读快照。
pub fn profile_footprint_of(t: &Truth<'_>, profile: &str) -> Result<Value, String> {
    snapshot(t, |t| match t.binding_of(profile)? {
        Some(b) => profile_footprint(t, b.col),
        None => Ok(json!({"notes": 0, "cards": 0, "reviews": 0, "rows": 0})),
    })
}

/// 复习日志条数：每个规范日志 ID 一条。
fn reviews(t: &Truth<'_>, col: i64) -> Result<i64, String> {
    let ix = Index::new(t, col);
    let ids: Vec<Ref> = t
        .conn()
        .prepare_cached("SELECT id FROM log_ix WHERE col = ?1 AND win = 1")
        .map_err(sql)?
        .query_map([col], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut seen: HashSet<Ref> = HashSet::with_capacity(ids.len());
    for id in &ids {
        seen.insert(ix.canonical(id)?);
    }
    Ok(seen.len() as i64)
}

/// 这个集合的总行数（模块文件头 `rows`）。
fn rows(t: &Truth<'_>, col: i64) -> Result<i64, String> {
    let conn = t.conn();
    // 每张表有哪几列里的 `col` / `k` / `dev`（库里现查）。
    let tables: Vec<(String, bool, bool, bool)> = {
        let mut stmt = conn
            .prepare_cached(
                "SELECT m.name, \
                 MAX(p.name = 'col'), MAX(p.name = 'k'), MAX(p.name = 'dev') \
                 FROM sqlite_schema m, pragma_table_info(m.name) p \
                 WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' \
                 AND m.name NOT IN ('collections', 'srs_meta') \
                 GROUP BY m.name ORDER BY m.name",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, bool>(1)?,
                    r.get::<_, bool>(2)?,
                    r.get::<_, bool>(3)?,
                ))
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)?
    };
    let devs: Vec<i64> = t.devices(col)?.into_iter().map(|d| d.dev).collect();
    let mut n = 0i64;
    for (table, has_col, has_k, has_dev) in tables {
        let one = |q: String, a: &[&dyn rusqlite::ToSql]| -> Result<i64, String> {
            conn.prepare(&q)
                .map_err(sql)?
                .query_row(a, |r| r.get::<_, i64>(0))
                .map_err(sql)
        };
        if has_col {
            n += one(
                format!("SELECT COUNT(*) FROM \"{table}\" WHERE col = ?1"),
                &[&col],
            )?;
        } else if has_k {
            for &dev in &devs {
                let (lo, hi) = k_range(dev);
                n += one(
                    format!("SELECT COUNT(*) FROM \"{table}\" WHERE k BETWEEN ?1 AND ?2"),
                    params![lo, hi],
                )?;
            }
        } else if has_dev {
            for &dev in &devs {
                n += one(
                    format!("SELECT COUNT(*) FROM \"{table}\" WHERE dev = ?1"),
                    &[&dev],
                )?;
            }
        }
    }
    Ok(n)
}
