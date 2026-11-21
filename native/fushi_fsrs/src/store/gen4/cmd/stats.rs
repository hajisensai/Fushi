//! 复习统计 `stats_report` / `stats_recall` / `stats_rows` 的新代实现（协议 3 `store/stats.rs`，设计 §2.3「统计」）。
//!
//! 统计的原料只有两样：可见卡的卡片缓存行（连同笔记缓存行的创建时刻与出处）与有效复习投影。新代里它们就在缓存层的
//! `cards` / `notes` / `stats` 三张表（列与协议 3 的缓存表相同，`cache.rs`），所以这里只换「从哪读」：同一份解码
//! （`stats::Snapshot::load_with`）、同一份聚合（`stats::report_of` / `recall_of` / `rows_of`），没有第二份统计实现。
//!
//! # 与协议 3 的差别
//!
//! - **ID**：原料里的卡、笔记、牌组、最后一条日志都是规范 ID（缓存层按规范 ID 物化），回包里也是。请求里按 ID 给的
//!   东西（`decks`、`desired` / `deckModels` 的键、`recallDecks`、`recall.ids`）先按同一份别名表归一（[canon_req]），
//!   Dart 手里还拿着旧的带盐牌组 / 卡 ID 时照样对得上。同一个类的几个成员在一张映射表里各给了值：规范 ID 自己给了就
//!   用它的，否则用成员里 ID 的 SQLite 序最小的那个的（确定、与请求里键的先后无关；规则只有 `cmd/mod.rs` `canon_keyed`
//!   一份）。`recall.ids` / `recall.r` 是按位置配对的「卡 → 召回率」表（协议 3 `stats::Ctx` 按位置 zip 成映射，同一个
//!   ID 出现两次时后一个盖前一个），撞键同一条规则：先按协议 3 的方式配成表（同一个原值 ID 后者盖前者），再按类归一，
//!   换回两个等长数组（按规范 ID 的文本序）。
//! - **顺序**：卡片行按卡 ID（`cards` 主键序，协议 3 那句没写 `ORDER BY`、顺序随查询计划）；复习行按 (发生时刻, 日志
//!   ID)（协议 3 只按时刻，同一时刻的先后随计划）。卡片上的浮点和按行序累加，所以与协议 3 的差最多是同一组数换个
//!   顺序相加的末位误差，对拍按 1e-9 的相对误差比。
//! - **原料缓存**（协议 3 `StatsCache`：按 profile + 统计指纹 + 写入代数留一份原料）不在这里：这里每条命令在一个读快照
//!   里现读一份。缓存要知道「写连接上改过原料」，那是分发器与写路径的事，接线时（规划 §2.2 S1）由命令层持有，读
//!   原料仍调 [snapshot_of]。`stats_release` 随缓存一起归命令层。
//!
//! # 代价
//!
//! 两条顺序扫：`cards` 沿主键（`col` 打头）走一遍这个集合的卡、每张卡按主键点读一次笔记行；`stats` 沿主键
//! `(col, at, log)` 顺序走——统计行按发生时刻聚簇，不排序、不解码任何操作体（设计 §2.3）。与协议 3 同阶。

use std::collections::HashSet;

use serde_json::Value;

use super::{profile_of, ref_of, snapshot};
use crate::store::gen4::derive::Index;
use crate::store::gen4::truth::Truth;
use crate::store::stats::{self, Snapshot};

/// 可见卡（连同笔记行的创建时刻与出处）：列与 `stats::Snapshot::load` 的第一条查询一一对应。
const CARDS: &str = "SELECT c.id, c.note_id, c.deck_id, c.queue, c.scheduled_days, c.suspended, \
     c.buried_until_day, c.scheduler, c.due_day, c.due_at, c.stability, c.difficulty, c.last_reviewed_at, c.lapses, \
     c.reps, COALESCE(n.created_at, c.note_created_at), c.last_log_id, n.source_kind, n.source_title \
     FROM cards c LEFT JOIN notes n ON n.col = c.col AND n.id = c.note_id \
     WHERE c.col = ?1 AND c.hidden = 0 ORDER BY c.id";

/// 有效复习投影，按发生时刻：列与 `stats::Snapshot::load` 的第二条查询一一对应。
const REVIEWS: &str = "SELECT card, at, utc_offset_min, rating, kind, duration_ms, prev_due_day, maturity_delta \
     FROM stats WHERE col = ?1 ORDER BY at, log";

/// 集合 [col] 的统计原料，在一个读快照里读（[snapshot]）。
pub(crate) fn snapshot_of(t: &Truth<'_>, col: i64) -> Result<Snapshot, String> {
    snapshot(t, |t| read_snapshot(t, col))
}

fn read_snapshot(t: &Truth<'_>, col: i64) -> Result<Snapshot, String> {
    // 没绑定的集合照旧报错（读的是集合号，profile 本身原料里不留）。
    profile_of(t, col)?;
    Snapshot::load_with(t.conn(), CARDS, REVIEWS, &col)
}

/// `stats_report`：一个范围 + 一个牌组子集的全部聚合值（同协议 3）。
pub fn stats_report(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let (snap, req) = load(t, col, req)?;
    stats::report_of(&snap, &req)
}

/// `stats_recall`：RWKV-Instant 排队的复习卡 `{cards: [[卡, 笔记, 牌组, 最后一条日志 | null]…]}`（同协议 3）。
pub fn stats_recall(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let (snap, req) = load(t, col, req)?;
    stats::recall_of(&snap, &req)
}

/// `stats_rows`：归一化之后逐卡 / 逐条的统计视图（同协议 3，回归向量用）。
pub fn stats_rows(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let (snap, req) = load(t, col, req)?;
    stats::rows_of(&snap, &req)
}

/// 原料与归一后的请求：同一个读快照里读原料、归一请求里的 ID（别名表与原料是同一个版本）。原料经 [snapshot_of]
/// 读——它在已开的事务里直接沿用（[snapshot] 的约定），所以这里与接线后命令层的原料缓存走同一个入口：缓存（协议 3
/// `StatsCache` 的新代对应物，要知道写连接上改没改过原料，归 S1 的命令层）没命中时也调它。
fn load(t: &Truth<'_>, col: i64, req: &Value) -> Result<(Snapshot, Value), String> {
    snapshot(t, |t| {
        let req = canon_req(&Index::new(t, col), req)?;
        Ok((snapshot_of(t, col)?, req))
    })
}

/// 请求里按 ID 给的东西归一成规范 ID（模块文件头「ID」）：`decks` / `recallDecks` 两个数组，`desired` / `deckModels`
/// 两张以牌组为键的表，`recall.ids`（卡，与 `recall.r` 及 `recall.ahead` 里同位置的值配成一张表按同一条撞键规则
/// 归一，模块文件头「ID」）。别的字段原样。
pub(crate) fn canon_req(ix: &Index<'_, '_>, req: &Value) -> Result<Value, String> {
    let canon = |s: &str| -> Result<String, String> { Ok(ix.canonical(&ref_of(s))?.text()) };
    let mut out = req.clone();
    let Some(obj) = out.as_object_mut() else {
        return Ok(out);
    };
    for k in ["decks", "recallDecks"] {
        if let Some(Value::Array(xs)) = obj.get_mut(k) {
            let mut seen: HashSet<String> = HashSet::new();
            let mut canon_xs = Vec::with_capacity(xs.len());
            for x in xs.iter() {
                match x.as_str() {
                    Some(s) => {
                        let c = canon(s)?;
                        if seen.insert(c.clone()) {
                            canon_xs.push(Value::String(c));
                        }
                    }
                    None => canon_xs.push(x.clone()),
                }
            }
            *xs = canon_xs;
        }
    }
    for k in ["desired", "deckModels"] {
        if let Some(Value::Object(m)) = obj.get_mut(k) {
            *m = super::canon_keyed(ix, m)?;
        }
    }
    if let Some(Value::Object(recall)) = obj.get_mut("recall") {
        if let (Some(Value::Array(ids)), Some(Value::Array(rs))) =
            (recall.get("ids"), recall.get("r"))
        {
            // `recall.ahead`：每个将来时刻一个与 `ids` 按位置对齐的数组（协议 3 只读前 RWKV_AHEAD 个，数组以外的跳过）。
            let ahead: Option<Vec<Vec<Value>>> =
                recall.get("ahead").and_then(Value::as_array).map(|a| {
                    a.iter()
                        .filter_map(Value::as_array)
                        .take(stats::RWKV_AHEAD)
                        .cloned()
                        .collect()
                });
            // 协议 3 的读法（`stats::Ctx`）：按位置配对、不是字符串的 ID 跳过、同一个 ID 后者盖前者。一张卡的值
            // = [此刻, 将来时刻…]，整组跟着同一个 ID 走。
            let mut by: serde_json::Map<String, Value> = serde_json::Map::new();
            for (i, (id, r)) in ids.iter().zip(rs).enumerate() {
                if let Some(id) = id.as_str() {
                    let mut row = vec![r.clone()];
                    for at in ahead.iter().flatten() {
                        row.push(at.get(i).cloned().unwrap_or(Value::Null));
                    }
                    by.insert(id.to_owned(), Value::Array(row));
                }
            }
            let keyed = super::canon_keyed(ix, &by)?;
            let n = ahead.as_ref().map_or(0, Vec::len);
            let mut ids = Vec::with_capacity(keyed.len());
            let mut rs = Vec::with_capacity(keyed.len());
            let mut later: Vec<Vec<Value>> = vec![Vec::with_capacity(keyed.len()); n];
            for (k, v) in keyed {
                let row = v.as_array().cloned().unwrap_or_default();
                ids.push(Value::String(k));
                rs.push(row.first().cloned().unwrap_or(Value::Null));
                for (j, at) in later.iter_mut().enumerate() {
                    at.push(row.get(j + 1).cloned().unwrap_or(Value::Null));
                }
            }
            recall.insert("ids".to_owned(), Value::Array(ids));
            recall.insert("r".to_owned(), Value::Array(rs));
            if ahead.is_some() {
                recall.insert(
                    "ahead".to_owned(),
                    Value::Array(later.into_iter().map(Value::Array).collect()),
                );
            }
        }
    }
    Ok(out)
}
