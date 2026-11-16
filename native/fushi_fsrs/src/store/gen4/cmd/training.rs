//! 逐卡重放与训练集的直读命令的新代实现（规划 §2.1 G7-4f）：协议 3 的 C 直出入口 `ffsrs_store_history_states` /
//! `ffsrs_store_stat_projection`（`store/mod.rs`）与 `ffsrs_store_optimizer_items` / `ffsrs_store_calibration_items` /
//! `ffsrs_store_rwkv_rows` / `ffsrs_store_rwkv_log_tail`（`store/projections.rs`）。**还没接分发器**：C 入口原地不动，接线
//! （规划 §2.2 S1）时入口照旧解码输入页与参数，再按集合号调这里。
//!
//! # 一份规则
//!
//! 投影、训练集、RWKV 行、分歧时刻、输出布局都只写一次：协议 3 的 `history_states_of` / `stat_projection_of`
//! （`store/mod.rs`）、`optimizer_items_of` / `calibration_items_of` / `rwkv_cards_of` / `ReplayScan` /
//! `rwkv_log_tail_of`（`store/projections.rs`）。两边只是往里灌的数据来源不同：
//!
//! - **日志**：协议 3 读 `srs_review_logs` 的落库行（`res` 是协议 3 按血统重放写回的）。新代按血统重放取同一份
//!   （`cache.rs` `Index::replayed_logs`：卡所在的 historyFrom 连通分量整个重放、取它那一段，与缓存层、`read` 的 `logs`
//!   同一份），每个规范日志 ID 一条代表（`card_logs`）。一批最多 [BATCH] 张卡一起重放（整个集合的 RWKV 回放不把全部
//!   日志原文同时留在内存里：每批取出就解析成紧凑形态，BUG-4012）。
//! - **血统展开**（训练集与 RWKV：调用方只给卡自己）：`cmd/lineage.rs` `lineages`（与协议 3 `caches::lineage_ids` 同一个
//!   判定函数，按类读前身链接），合并规则 `projections::expand_with` 同一份。
//! - **rowid**：协议 3 的日志行 rowid（落库序）在新代是操作主键 `log_ix.k`（`ops` 的 `INTEGER PRIMARY KEY`，同样按本机
//!   落库单调增）。指纹（行数、最大序号、某序号之后的行数）数 `log_ix` 里 `win = 1` 的行——每个原值日志 ID 一行，正是
//!   协议 3 日志表一行一条的对应物——走部分索引 `log_k (col, k) WHERE win = 1`（schema 40018）：增量计数与取尾巴是这个
//!   集合里 k 的一段区间，O(新增)，与协议 3 走 rowid 范围同阶。
//!
//! # 与协议 3 的差别（D24「按规范 ID」）
//!
//! - 输入里的卡先归一，一份历史里同一张规范卡只算一次（Dart 手里的血统可能同时有带盐成员与规范 ID）；结果里的日志 ID、
//!   卡 ID（`rwkv_cards` 的保留评分 ID、`rwkv_replay` 的漏掉的卡、`rwkv_log_tail` 的尾巴行）是规范 ID，数字标签
//!   （`anki_numeric_id`）按规范日志 ID 算。
//! - 一条日志在别名类里有几份（换代前同一次 Anki 复习的两份带盐导入）只出一次：重放取代表；`rwkv_log_tail` 的尾巴行只出
//!   代表那一行（类里别的份落在 `since` 之后也不再出一行）。**指纹仍按原值行数**（与 `rwkv_replay` 的 `count` /
//!   `tailRows` 同一口径），调用方的「行数 − 新增 = 上次的行数」核对照旧成立。
//! - 指纹里的「最大序号」是操作主键，不是协议 3 的 rowid：两代库各自的游标，调用方只拿它回传给同一个库（`since` /
//!   `rebase_since`），不跨库比较。
//! - 输入里不存在、或属于别的集合的卡：没有日志，与协议 3 不存在的卡同形。

use std::collections::{BTreeSet, HashMap, HashSet};

use rusqlite::params;

use super::lineage::lineages;
use super::{ref_of, snapshot};
use crate::gen4::op::Body4;
use crate::projection::{Alg, Day};
use crate::store::gen4::cache::LogIn;
use crate::store::gen4::derive::{Index, Ref, body_of};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::store::projections::{
    self, LogsByCard, ReplayScan, RwkvRange, TAIL_UNDO, TailRow, tail_kind,
};
use crate::store::{LogRow, history_states_of, stat_projection_of};

/// 一次一起重放的卡数（`cache.rs` 的批大小）。
const BATCH: usize = 512;

/// `history_states`：每份历史（`groups[g]` = 调用方给的血统，不展开）的当前状态，输出布局同协议 3
/// `SrsCore::history_states`（`history::encode_states`）。
pub fn history_states(t: &Truth<'_>, col: i64, groups: &[Vec<String>]) -> Result<Vec<u8>, String> {
    snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let groups = canon_groups(&ix, groups)?;
        history_states_of(&groups, &log_rows(&mut ix, &groups)?)
    })
}

/// `stat_projection`：有效复习投影（`groups[g]` = 归属组：归属卡在前、再列出归它的前身卡，不展开），输出同协议 3
/// `SrsCore::stat_projection`（9 列行页）。
pub fn stat_projection(t: &Truth<'_>, col: i64, groups: &[Vec<String>]) -> Result<Vec<u8>, String> {
    snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let groups = canon_groups(&ix, groups)?;
        stat_projection_of(&groups, &log_rows(&mut ix, &groups)?)
    })
}

/// `optimizer_items`：优化器训练集（`groups[g]` 是一张卡，全部前身在同一快照里补齐；`card_ids[g]` 是它的数字 id），
/// 输出同协议 3 `SrsCore::optimizer_items`。
pub fn optimizer_items(
    t: &Truth<'_>,
    col: i64,
    groups: &[Vec<String>],
    card_ids: &[i64],
    alg: Alg,
    day: &Day,
) -> Result<Vec<u8>, String> {
    if card_ids.len() != groups.len() {
        return Err("optimizer: card id count differs from group count".into());
    }
    snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let groups = expand(t, col, &ix, groups)?;
        let logs = logs_by_card(&mut ix, &projections::wanted_cards(&groups))?;
        projections::optimizer_items_of(&groups, &logs, card_ids, alg, day)
    })
}

/// `calibration_items`：校准图的训练集与条目元数据（参数同 [optimizer_items]），输出同协议 3
/// `SrsCore::calibration_items`。
pub fn calibration_items(
    t: &Truth<'_>,
    col: i64,
    groups: &[Vec<String>],
    card_ids: &[i64],
    alg: Alg,
    day: &Day,
) -> Result<Vec<u8>, String> {
    if card_ids.len() != groups.len() {
        return Err("calibration: card id count differs from group count".into());
    }
    snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let groups = expand(t, col, &ix, groups)?;
        let logs = logs_by_card(&mut ix, &projections::wanted_cards(&groups))?;
        projections::calibration_items_of(&groups, &logs, card_ids, alg, day)
    })
}

/// `rwkv_rows` 逐卡模式：每份历史的保留评分行与摘要（`ids[4g..4g+4]` = 卡 / 笔记 / 牌组 / 预设数字 id），输出同协议 3
/// `SrsCore::rwkv_cards`。
pub fn rwkv_cards(
    t: &Truth<'_>,
    col: i64,
    groups: &[Vec<String>],
    ids: &[i64],
    day: &Day,
) -> Result<Vec<u8>, String> {
    if ids.len() != groups.len() * 4 {
        return Err("rwkv: id count differs from 4 × group count".into());
    }
    snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let groups = expand(t, col, &ix, groups)?;
        let logs = logs_by_card(&mut ix, &projections::wanted_cards(&groups))?;
        projections::rwkv_cards_of(&groups, &logs, ids, day)
    })
}

/// `rwkv_rows` 回放模式：这个集合的全部日志按落库序扫一遍（指纹与行出自同一个快照），选行与输出同协议 3
/// `SrsCore::rwkv_replay`（`projections::ReplayScan`）。`since` / `range` 里的序号是操作主键（模块文件头「rowid」）。
#[allow(clippy::too_many_arguments)]
pub fn rwkv_replay(
    t: &Truth<'_>,
    col: i64,
    groups: &[Vec<String>],
    ids: &[i64],
    day: &Day,
    since: i64,
    range: RwkvRange,
) -> Result<Vec<u8>, String> {
    if ids.len() != groups.len() * 4 {
        return Err("rwkv: id count differs from 4 × group count".into());
    }
    let scan = snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let mut scan = ReplayScan::new(expand(t, col, &ix, groups)?, since, range);
        // 指纹：每个原值日志 ID 一行，按落库序（`log_k`）。行上的卡按规范 ID 认血统（一张卡的几个成员各算它）。
        let mut canon: HashMap<Ref, String> = HashMap::new();
        let mut stmt = t.conn().prepare_cached(SCAN_SQL).map_err(sql)?;
        let mut q = stmt.query(params![col]).map_err(sql)?;
        while let Some(row) = q.next().map_err(sql)? {
            let k: i64 = row.get(0).map_err(sql)?;
            let card: Ref = row.get(1).map_err(sql)?;
            let c = match canon.get(&card) {
                Some(c) => c,
                None => {
                    let c = ix.canonical(&card)?.text();
                    canon.entry(card).or_insert(c)
                }
            };
            scan.see(k, c);
        }
        drop(q);
        drop(stmt);
        let wanted: Vec<String> = scan.wanted().into_iter().map(str::to_owned).collect();
        let mut logs = std::mem::take(&mut scan.logs);
        each_replayed(&mut ix, &wanted, &mut |card, l| {
            logs.push(card.to_owned(), l.k, &l.json, l.server_time, None)
        })?;
        scan.logs = logs;
        Ok(scan)
    })?;
    scan.finish(ids, day)
}

/// [rwkv_replay] 的扫描语句：这个集合每个原值日志 ID 的那一行，按操作主键（部分索引 `log_k`，不排序）。
pub(super) const SCAN_SQL: &str =
    "SELECT k, card FROM log_ix INDEXED BY log_k WHERE col = ?1 AND win = 1 ORDER BY k";

/// [rwkv_log_tail] 的整表计数（`log_k` 上覆盖扫描这个集合）。
pub(super) const COUNT_SQL: &str = "SELECT COUNT(*), COALESCE(MAX(k), 0), COALESCE(SUM(k > ?2), 0) \
     FROM log_ix INDEXED BY log_k WHERE col = ?1 AND win = 1";

/// [rwkv_log_tail] 的增量计数（`log_k` 上 k 的一段区间，O(新增)）。
pub(super) const COUNT_SINCE_SQL: &str = "SELECT COUNT(*), COALESCE(MAX(k), 0) \
     FROM log_ix INDEXED BY log_k WHERE col = ?1 AND win = 1 AND k > ?2";

/// [rwkv_log_tail] 的尾巴行（`log_k` 上 k 的一段区间，再按发生时刻排这一小段）。
pub(super) const TAIL_SQL: &str = "SELECT k, id, card FROM log_ix INDEXED BY log_k \
     WHERE col = ?1 AND win = 1 AND k > ?2 ORDER BY at, k";

/// 一个原值日志 ID 的 `win = 1` 行（`log_id` 索引）：判别名类的代表用。
const MEMBER_SQL: &str = "SELECT k FROM log_ix WHERE col = ?1 AND id = ?2 AND win = 1";

/// `rwkv_log_tail`：RWKV 对齐用的日志指纹与尾巴（同一个快照），输出同协议 3 `SrsCore::rwkv_log_tail`：(行数, 最大序号,
/// 序号在 `since` 之后的行数)；`with_rows` 时再给出这些新行（按发生时刻、序号排）。`incremental`：只数 `since` 之后的行
/// （行数 = 新增行数、最大序号 = 新增里的最大，没有新增为 0），调用方在已知的指纹上累加。
pub fn rwkv_log_tail(
    t: &Truth<'_>,
    col: i64,
    since: i64,
    with_rows: bool,
    incremental: bool,
) -> Result<Vec<u8>, String> {
    snapshot(t, |t| {
        let conn = t.conn();
        let (count, max_k, new_rows): (i64, i64, i64) = if incremental {
            let (c, m): (i64, i64) = conn
                .prepare_cached(COUNT_SINCE_SQL)
                .map_err(sql)?
                .query_row(params![col, since], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?;
            (c, m, c)
        } else {
            conn.prepare_cached(COUNT_SQL)
                .map_err(sql)?
                .query_row(params![col, since], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })
                .map_err(sql)?
        };
        let mut tail: Vec<TailRow> = Vec::new();
        if with_rows {
            let ix = Index::new(t, col);
            let rows: Vec<(i64, Ref, Ref)> = conn
                .prepare_cached(TAIL_SQL)
                .map_err(sql)?
                .query_map(params![col, since], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (k, id, card) in rows {
                let canon = ix.canonical(&id)?;
                if !is_rep(t, &ix, col, &canon, k)? {
                    continue;
                }
                let Some(e) = t.entry_by_key(k)? else {
                    continue;
                };
                let Some(Body4::Log(l)) = body_of(&e) else {
                    continue;
                };
                let code = tail_kind(&l.kind);
                let revokes = match (&l.revokes, code) {
                    (Some(r), TAIL_UNDO) => ix.canonical(&Ref::of(r))?.text(),
                    _ => String::new(),
                };
                tail.push(TailRow {
                    id: canon.text(),
                    card: ix.canonical(&card)?.text(),
                    code,
                    at: l.at,
                    revokes,
                });
            }
        }
        Ok(projections::rwkv_log_tail_of(count, max_k, new_rows, &tail))
    })
}

/// 操作主键 [k] 的那一行是不是规范日志 ID [canon] 的代表：类里全部份（每个成员的 `win = 1` 行）中操作号最小的那条
/// （`cache.rs` `card_logs` / `cmd::logs_between` 的同一条规则）。类里只有一个成员时它就是。
fn is_rep(
    t: &Truth<'_>,
    ix: &Index<'_, '_>,
    col: i64,
    canon: &Ref,
    k: i64,
) -> Result<bool, String> {
    let class = ix.class_of(canon)?;
    if class.len() == 1 {
        return Ok(true);
    }
    let mine = t.id_of_key(k)?;
    for m in &class {
        let ks: Vec<i64> = t
            .conn()
            .prepare_cached(MEMBER_SQL)
            .map_err(sql)?
            .query_map(params![col, m], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        for other in ks {
            if other != k && t.id_of_key(other)? < mine {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

/// 每份历史里的卡归一成规范 ID，份内去重（保第一次出现的顺序）。
fn canon_groups(ix: &Index<'_, '_>, groups: &[Vec<String>]) -> Result<Vec<Vec<String>>, String> {
    groups
        .iter()
        .map(|g| {
            let mut seen: HashSet<String> = HashSet::new();
            let mut out = Vec::with_capacity(g.len());
            for c in g {
                let c = ix.canonical(&ref_of(c))?.text();
                if seen.insert(c.clone()) {
                    out.push(c);
                }
            }
            Ok(out)
        })
        .collect()
}

/// 归一 + 展开全部前身（协议 3 `expand_lineages` 的同一条合并规则，血统由 `cmd/lineage.rs` 判）。
fn expand(
    t: &Truth<'_>,
    col: i64,
    ix: &Index<'_, '_>,
    groups: &[Vec<String>],
) -> Result<Vec<Vec<String>>, String> {
    let groups = canon_groups(ix, groups)?;
    projections::expand_with(&groups, &mut |seeds| lineages(t, col, seeds))
}

/// [cards]（规范 ID 文本）各自按血统重放写回的日志，逐条交给 [f]（每张卡一次、卡内按操作主键——协议 3 卡内按 rowid）。
/// 每批 [BATCH] 张卡的连通分量一起重放；分量里顺带算出的别的卡记下，不再重放第二次。
fn each_replayed(
    ix: &mut Index<'_, '_>,
    cards: &[String],
    f: &mut dyn FnMut(&str, LogIn) -> Result<(), String>,
) -> Result<(), String> {
    let wanted: HashSet<&str> = cards.iter().map(String::as_str).collect();
    let mut done: HashSet<String> = HashSet::new();
    for chunk in cards.chunks(BATCH) {
        let todo: BTreeSet<Ref> = chunk
            .iter()
            .filter(|c| !done.contains(c.as_str()))
            .map(|c| ref_of(c))
            .collect();
        if todo.is_empty() {
            continue;
        }
        for (card, mut logs) in ix.replayed_logs(&todo)? {
            if !wanted.contains(card.as_str()) || !done.insert(card.clone()) {
                continue;
            }
            logs.sort_by_key(|l| l.k);
            for l in logs {
                f(&card, l)?;
            }
        }
    }
    Ok(())
}

/// 一组卡的日志，解析成紧凑形态（训练集 / RWKV 的输入）。
fn logs_by_card(ix: &mut Index<'_, '_>, cards: &[&str]) -> Result<LogsByCard, String> {
    let cards: Vec<String> = cards.iter().map(|c| (*c).to_owned()).collect();
    let mut logs = LogsByCard::default();
    each_replayed(ix, &cards, &mut |card, l| {
        logs.push(card.to_owned(), l.k, &l.json, l.server_time, None)
    })?;
    Ok(logs)
}

/// 每份历史里各卡的日志行（`history_states_of` / `stat_projection_of` 的输入：原文 JSON + 服务器时刻，没有列）。
fn log_rows(
    ix: &mut Index<'_, '_>,
    groups: &[Vec<String>],
) -> Result<HashMap<String, Vec<LogRow>>, String> {
    let cards: Vec<String> = projections::wanted_cards(groups)
        .into_iter()
        .map(str::to_owned)
        .collect();
    let mut out: HashMap<String, Vec<LogRow>> = HashMap::with_capacity(cards.len());
    each_replayed(ix, &cards, &mut |card, l| {
        out.entry(card.to_owned())
            .or_default()
            .push((l.json, l.server_time, None));
        Ok(())
    })?;
    Ok(out)
}
