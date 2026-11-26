//! 逐卡重放与训练集的直读命令的新代实现（规划 §2.1 G7-4f）：协议 3 的 C 直出入口 `ffsrs_store_history_states` /
//! `ffsrs_store_stat_projection`（`store/mod.rs`）与 `ffsrs_store_optimizer_items` / `ffsrs_store_calibration_items` /
//! `ffsrs_store_rwkv_rows` / `ffsrs_store_rwkv_log_tail`（`store/projections.rs`）。S1b 接线：C 入口（`store/ffi.rs`）照旧
//! 解码输入页与参数，经 `gen4/dispatch.rs` 的「C 直出入口」一节换出集合号（输入页带 profile 行就按它，否则按卡认集合），
//! 在一个读快照里调这里。
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
//! - **rowid**：协议 3 的日志行 rowid 是本机落库序：同步收来的、别的设备早就写下的日志也排在已有的之后，RWKV 才能按
//!   「游标之后的新行」增量对齐。新代的操作主键 `k` = 设备下标 × 2^40 + seq，**不随落库单调**（晚到的、下标小的设备的
//!   日志落在游标之前，增量对齐看不见它，只能靠行数核对退回全量重放），所以不拿它当游标：落库序单独记在本机状态表
//!   `log_seq`（schema 40018，`derive.rs` 随 `log_ix` 逐条维护：一条日志操作第一次进索引时取集合里下一个序号 `n`（从
//!   `SEQ_BASE` + 1 起，见文件头「与协议 3 的差别」），删出索引时删掉；整层重建保留还在的行的序号）。指纹（行数、最大序号、某序号之后的行数）、回放扫描、尾巴都沿 `log_seq`
//!   主键 `(col, n)`：增量计数与取尾巴是 n 的一段区间，O(新增)，与协议 3 走 rowid 范围同阶。
//! - **指纹数的是日志操作**：`log_seq` 一条日志操作一行（同一个原值日志 ID 若有几份操作各算一行，协议 3 的日志表按 ID 只
//!   存一行）。几份同 ID 的操作只在复制出来的旧库各自续写时出现；这样数，指纹只随「落库 / 删出」变，不随 `win` 归属变，
//!   调用方的「行数 − 新增 = 上次的行数」核对照旧成立。
//!
//! # 与协议 3 的差别（D24「按规范 ID」）
//!
//! - 输入里的卡先归一，一份历史里同一张规范卡只算一次（Dart 手里的血统可能同时有带盐成员与规范 ID）；结果里的日志 ID、
//!   卡 ID（`rwkv_cards` 的保留评分 ID、`rwkv_replay` 的漏掉的卡、`rwkv_log_tail` 的尾巴行）是规范 ID，数字标签
//!   （`anki_numeric_id`）按规范日志 ID 算。
//! - 一条日志在别名类里有几份（换代前同一次 Anki 复习的两份带盐导入）只出一次：重放取代表；`rwkv_log_tail` 的尾巴行只出
//!   代表那一行（类里别的份落在 `since` 之后也不再出一行）。**指纹仍按操作行数**（与 `rwkv_replay` 的 `count` /
//!   `tailRows` 同一口径）。
//! - 指纹里的「最大序号」是新代的落库序，不是协议 3 的 rowid：两代库各自的游标，调用方只拿它回传给同一个库（`since` /
//!   `rebase_since`）。RWKV 状态机判快照 / 检查点只看 (行数, 最大序号)、没有库代标记，所以落库序从
//!   `derive.rs` `SEQ_BASE`（2^40）起、与协议 3 的 rowid 空间不相交：换代前留下的主快照指纹必不相等、检查点的
//!   `count - tailRows` 必为 0，第一次对齐必然全量重放（`training_tests.rs`
//!   `protocol_3_checkpoints_and_fingerprints_never_fit_the_new_library` 钉死）。S1 换代时不必删 RWKV 快照目录。
//! - 输入里不存在、或属于别的集合的卡：没有日志，与协议 3 不存在的卡同形。

use std::collections::{BTreeSet, HashMap, HashSet};

use rusqlite::{OptionalExtension, params};

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

/// `rwkv_rows` 末条模式：[cards]（任意 ID，按类归一）各自最后一条 RWKV 保留评分，读缓存层与卡行一起物化的
/// `rwkv_last`（与 [rwkv_cards] 摘要里的 `last` 同一条，测试 `rwkv_last_matches_rwkv_cards_*` 钉住）。
/// 输出 `[n, (时刻|NONE, 评分, 复习类型代码) × n]`，没有保留评分（或没有卡行）的卡是 `NONE, 0, 0`。
///
/// RWKV 打分的查询行只要这一条（`srs_rwkv_service.dart` `_queryRows`）：冷启动分数表是空的、统计又整表重查，
/// 逐卡模式要重放每张卡的全部历史（实测 1.5 万张卡 26～36 秒，BUG-5491），这里是一次按主键的表读。
pub fn rwkv_last(t: &Truth<'_>, col: i64, cards: &[String]) -> Result<Vec<u8>, String> {
    snapshot(t, |t| {
        let ix = Index::new(t, col);
        let mut out = Vec::with_capacity(8 + cards.len() * 24);
        out.extend_from_slice(&(cards.len() as i64).to_le_bytes());
        let mut stmt = t
            .conn()
            .prepare_cached("SELECT at, rating, rtype FROM rwkv_last WHERE col = ?1 AND card = ?2")
            .map_err(sql)?;
        for c in cards {
            let card = ix.canonical(&ref_of(c))?;
            let row: Option<(i64, i64, i64)> = stmt
                .query_row(params![col, card], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })
                .optional()
                .map_err(sql)?;
            let (at, rating, rtype) = row.unwrap_or((crate::history::NONE_I64, 0, 0));
            for v in [at, rating, rtype] {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        Ok(out)
    })
}

/// `rwkv_rows` 回放模式：这个集合的全部日志按本机落库序扫一遍（指纹与行出自同一个快照），选行与输出同协议 3
/// `SrsCore::rwkv_replay`（`projections::ReplayScan`）。`since` / `range` 里的序号是落库序（模块文件头「rowid」）。
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
        // 指纹：每条日志操作一行，按落库序（`log_seq` 主键）。行上的卡按规范 ID 认血统（一张卡的几个成员各算它）；
        // 属于某份血统的行记下 操作主键 → 序号，给重放出来的代表日志标上它的序号。
        let mut canon: HashMap<Ref, String> = HashMap::new();
        let mut seq: HashMap<i64, i64> = HashMap::new();
        let mut stmt = t.conn().prepare_cached(SCAN_SQL).map_err(sql)?;
        let mut q = stmt.query(params![col]).map_err(sql)?;
        while let Some(row) = q.next().map_err(sql)? {
            let n: i64 = row.get(0).map_err(sql)?;
            let k: i64 = row.get(1).map_err(sql)?;
            let card: Ref = row.get(2).map_err(sql)?;
            let c = match canon.get(&card) {
                Some(c) => c,
                None => {
                    let c = ix.canonical(&card)?.text();
                    canon.entry(card).or_insert(c)
                }
            };
            if scan.see(n, c) {
                seq.insert(k, n);
            }
        }
        drop(q);
        drop(stmt);
        drop(canon);
        let wanted: Vec<String> = scan.wanted().into_iter().map(str::to_owned).collect();
        let mut logs = std::mem::take(&mut scan.logs);
        each_replayed(&mut ix, &wanted, &mut |card, mut ls| {
            let mut ranked = Vec::with_capacity(ls.len());
            for l in ls.drain(..) {
                // 代表日志落在这张卡的类里，它那一行就在上面扫到的血统行里。
                let n = *seq
                    .get(&l.k)
                    .ok_or_else(|| format!("gen4 rwkv: log op {} has no arrival order", l.k))?;
                ranked.push((n, l));
            }
            // 卡内按落库序排：协议 3 `ReplayScan` 收进的是 rowid 序。输出不依赖它（`history::select` 自己按日志 ID
            // 去重、按排序键排序，分歧判断只看序号过滤），保留它只为让两代往同一份计算里灌的输入同序。
            ranked.sort_by_key(|(n, _)| *n);
            for (n, l) in ranked {
                logs.push(card.to_owned(), n, l.stored())?;
            }
            Ok(())
        })?;
        scan.logs = logs;
        Ok(scan)
    })?;
    scan.finish(ids, day)
}

/// [rwkv_replay] 的扫描语句：这个集合的每条日志操作，按落库序（`log_seq` 主键，不排序）。
pub(super) const SCAN_SQL: &str = "SELECT n, k, card FROM log_seq WHERE col = ?1 ORDER BY n";

/// [rwkv_log_tail] 的整表计数（沿 `log_seq` 主键走这个集合）。
pub(super) const COUNT_SQL: &str = "SELECT COUNT(*), COALESCE(MAX(n), 0), COALESCE(SUM(n > ?2), 0) \
     FROM log_seq WHERE col = ?1";

/// [rwkv_log_tail] 的增量计数（`log_seq` 主键上 n 的一段区间，O(新增)）。
pub(super) const COUNT_SINCE_SQL: &str =
    "SELECT COUNT(*), COALESCE(MAX(n), 0) FROM log_seq WHERE col = ?1 AND n > ?2";

/// [rwkv_log_tail] 的尾巴行（`log_seq` 主键上 n 的一段区间）。
pub(super) const TAIL_SQL: &str = "SELECT n, k FROM log_seq WHERE col = ?1 AND n > ?2";

/// `rwkv_log_tail`：RWKV 对齐用的日志指纹与尾巴（同一个快照），输出同协议 3 `SrsCore::rwkv_log_tail`：(行数, 最大序号,
/// 序号在 `since` 之后的行数)；`with_rows` 时再给出这些新行里每个规范日志 ID 的代表（按发生时刻、序号排）。
/// `incremental`：只数 `since` 之后的行（行数 = 新增行数、最大序号 = 新增里的最大，没有新增为 0），调用方在已知的指纹上
/// 累加。序号是本机落库序（模块文件头「rowid」）。
///
/// **只适合取增量尾巴**：指纹是 `log_seq` 主键上的一两条语句，但 `with_rows` 的每一行尾巴要再回真相读操作体、归一卡 /
/// 日志 / 撤销目标、对日志类里每个成员各点查一次 `log_id`（[is_rep]），一行 5～8 次点查（协议 3 一条语句）。RWKV 的
/// 调用方（`fushi_rwkv` `sched/machine.rs`）传的 `since` 是上次的最大序号，尾巴只有新增那几行；`since = 0` 加
/// `with_rows` 会随日志总量线性地多次往返——要全量的日志走 [rwkv_replay]（一次扫描 + 按批重放）。
pub fn rwkv_log_tail(
    t: &Truth<'_>,
    col: i64,
    since: i64,
    with_rows: bool,
    incremental: bool,
) -> Result<Vec<u8>, String> {
    snapshot(t, |t| {
        let conn = t.conn();
        let (count, max_n, new_rows): (i64, i64, i64) = if incremental {
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
        let mut tail: Vec<(i64, TailRow)> = Vec::new();
        if with_rows {
            let ix = Index::new(t, col);
            let rows: Vec<(i64, i64)> = conn
                .prepare_cached(TAIL_SQL)
                .map_err(sql)?
                .query_map(params![col, since], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (n, k) in rows {
                let e = t
                    .entry_by_key(k)?
                    .ok_or_else(|| format!("gen4 rwkv: log op {k} is not in the truth"))?;
                let Some(Body4::Log(l)) = body_of(&e) else {
                    return Err(format!("gen4 rwkv: op {k} is not a log"));
                };
                let canon = ix.canonical(&Ref::of(&l.id))?;
                if !is_rep(&ix, &canon, k)? {
                    continue;
                }
                let code = tail_kind(&l.kind);
                let revokes = match (&l.revokes, code) {
                    (Some(r), TAIL_UNDO) => ix.canonical(&Ref::of(r))?.text(),
                    _ => String::new(),
                };
                tail.push((
                    n,
                    TailRow {
                        id: canon.text(),
                        card: ix.canonical(&Ref::of(&l.card))?.text(),
                        code,
                        at: l.at,
                        revokes,
                    },
                ));
            }
            // 协议 3 `ORDER BY occurred_at, rowid`。
            tail.sort_by_key(|(n, r)| (r.at, *n));
        }
        let tail: Vec<TailRow> = tail.into_iter().map(|(_, r)| r).collect();
        Ok(projections::rwkv_log_tail_of(count, max_n, new_rows, &tail))
    })
}

/// 操作主键 [k] 的那条日志操作是不是规范日志 ID [canon] 的代表（`cache.rs` [Index::log_class_rep]，缓存层
/// `card_logs` 同一份「按类取代表」）。同一个原值日志 ID 的别的份（`win = 0`）不是代表。
fn is_rep(ix: &Index<'_, '_>, canon: &Ref, k: i64) -> Result<bool, String> {
    Ok(ix
        .log_class_rep(&ix.class_of(canon)?)?
        .is_some_and(|(x, _, _)| x == k))
}

/// 每份历史里的卡归一成规范 ID，份内去重（保第一次出现的顺序）。去重不改输出（同一张卡的日志重复灌进去，
/// `history::select` 也按日志 ID 去重），只省掉同一张卡的第二次取数。
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

/// [cards]（规范 ID 文本）各自按血统重放写回的日志，每张卡一次交给 [f]（卡内按 (发生时刻, 操作主键)，`card_logs` 的序；
/// 投影与训练集不看输入顺序——同一个日志 ID 只有一份、选取规则自己排序——要协议 3 rowid 序的调用方自己排）。每批
/// [BATCH] 张卡的连通分量一起重放；分量里顺带算出的别的卡记下，不再重放第二次。
fn each_replayed(
    ix: &mut Index<'_, '_>,
    cards: &[String],
    f: &mut dyn FnMut(&str, Vec<LogIn>) -> Result<(), String>,
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
        for (card, logs) in ix.replayed_logs(&todo)? {
            if !wanted.contains(card.as_str()) || !done.insert(card.clone()) {
                continue;
            }
            f(&card, logs)?;
        }
    }
    Ok(())
}

/// 一组卡的日志，解析成紧凑形态（训练集 / RWKV 逐卡的输入；`rowid` 位填操作主键，这几条命令只用它保持卡内次序）。
fn logs_by_card(ix: &mut Index<'_, '_>, cards: &[&str]) -> Result<LogsByCard, String> {
    let cards: Vec<String> = cards.iter().map(|c| (*c).to_owned()).collect();
    let mut logs = LogsByCard::default();
    each_replayed(ix, &cards, &mut |card, ls| {
        for l in ls {
            logs.push(card.to_owned(), l.k, l.stored())?;
        }
        Ok(())
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
    each_replayed(ix, &cards, &mut |card, ls| {
        out.insert(
            card.to_owned(),
            ls.into_iter()
                .map(|l| (l.json, l.server_time, None, l.order_id))
                .collect(),
        );
        Ok(())
    })?;
    Ok(out)
}
