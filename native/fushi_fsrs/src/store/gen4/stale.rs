//! 协议 3 一侧过期的日志结果（反馈 RhMpA6bn8v）：对拍之前先把协议 3 的日志投影行改回「协议 3 自己的规则作用在
//! 操作集合上」应有的样子，再交给冻结的缓存重建（`dryrun.rs` `old_caches`、测试装置 `parity.rs` `protocol_3_caches`）。
//!
//! # 是哪两类
//!
//! 1. **第一版协议 3 旧重放改写**（单操作或代表相同，两边都无 `sc`）：协议 3 的卡片状态、统计都读日志投影行
//!    （`srs_review_logs.json`）里的结果 `res`；现行规则（`sync2/replay.rs` `fold` 里 `snap.is_none()` 时意图当作
//!    `Absolute`）对没有生效配置快照 `sc` 的日志只照抄作者结果，不重算也不写回。可 2026-10-25 第一版协议 3
//!    （`829a67b942`「Merge PR #2535」20:01 +0800 到带 `7eeb05bc7c` 的 `8d6b9bb568` 20:51 之前）曾在迁移与重放时
//!    按当时的牌组配置改写无 `sc` 日志的投影行；规则改回后没人再改回来。
//! 2. **存量重复日志代表不一致**（同 `log_id` 在 `log_ix` 有多条活跃操作）：协议 3 的 `index_log` / `project_log` 按
//!    「先到先得」写入 `srs_review_logs` 与 `sync2_log_meta`（设备先在本地落了己方那份操作，后续拉到操作号更小的他端
//!    副本时若载荷不逐字节相同——例如各设备所带 `sc` 快照不同、或一侧带 `sc` 一侧不带——`dedup.rs` 不收敛，投影行仍
//!    停留在后到的/败者操作上）；而新代 `log_ix` 的 `pick_log` 总是确定性地选操作号最小者（`win = 1`）。于是协议 3
//!    投影行停在操作号更大的败者副本上，与操作集合函数应有的代表不同；其后的卡片状态与带 `sc` 日志的重放（结果、`kind`、
//!    `maturity_delta`、`prev_due_day`）跟着分叉。
//!
//! 新代的日志是操作本身，缓存层按最小操作号代表重放。两类情况下两侧的差异都不是迁移改错了什么，而是协议 3 这台设备的
//! 投影行偏离了「以协议 3 规则作用在全集（按最小操作号选代表）上」的基准。
//!
//! # 佐证（逐条，只认这两种）
//!
//! - **未走重复代表切换（无更小操作号代表）**：与原 BUG-5250 一致——落库投影行与 `sync2_log_meta` 所指操作都没有 `sc`；
//!   身份键（[IDENTITY]）与 `log_row(操作)` 逐个相同；两边的 `res` 按 JSON 值不同。
//! - **存在更小操作号代表（`log_ix` 中 `win = 1` 的操作号严格小于 `sync2_log_meta` 所指败者操作）**：
//!   1. 落库投影行的身份键（[IDENTITY]）与 `log_row(胜者操作)` 逐个相同；
//!   2. 两者都无 `sc` 时：`res` 或意图与胜者不同；若意图不同，还核对 `sync2_log_meta` 里的意图确来自败者操作原文；
//!   3. 至少一侧带 `sc` 时：仅当代表切换确实改变了 `sc`、意图或 `Intent::Absolute` 的作者 `res` 之一（同 `sc` 且同
//!      意图的非绝对日志即使落库 `res` 被篡改也不认），**且**落库投影行里的 `sc`（以及改动到的意图 / `Absolute` `res`）
//!      确与 `sync2_log_meta` 所指败者操作一致（防磁盘静默篡改）。
//!
//! 同代表或同 `sc` 下带 `sc` 日志结果不对（重放欠着或落库行被改坏）、身份键对不上、找不到操作、操作被清除的，一律不认，
//! 照原样参与对拍，差异照报。
//!
//! # 改回去
//!
//! [heal]：把这些行的 `res`（以及变化的 `sc`）写回 `srs_review_logs`，若意图变化则在影子/SAVEPOINT 中同步更新
//! `sync2_log_meta` 的 `(intent, arg)`，再用协议 3 自己的重放（`replay_cards`）重放受影响卡的归属组。表名不带库名：
//! 干跑里落在遮住 `main` 的临时表上（旧库一个字节不写），测试装置里在 SAVEPOINT 里、比完回滚。

use std::collections::{BTreeSet, HashMap, HashSet};

use rusqlite::{Connection, params};
use serde_json::Value;

use super::derive::Ref;
use super::schema::sql;
use super::truth::Truth;
use crate::store::sync2::{canonical, intent_code, load_op, log_row, replay_cards};
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{Body, Intent, LogBody};
use crate::sync2::replay::SNAPSHOT_KEY;
use crate::sync2::vv::OpId;

/// 投影行与操作逐个比的身份键（佐证第 1/2 条）。
pub(crate) const IDENTITY: [&str; 9] = [
    "id", "card", "kind", "rating", "at", "hlc", "origin", "rtype", "revokes",
];

/// 报告里最多列几条例子。
pub(crate) const EXAMPLES: usize = 8;

/// 一条需要按操作集合规则改回的协议 3 日志结果。
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Stale {
    /// 日志 ID（原值）。
    pub log: String,
    /// 日志所在的卡（原值）。
    pub card: String,
    /// 投影行里的结果（没有 = `Value::Null`）。
    pub stored: Value,
    /// 应采纳的操作里作者给的结果（没有 = `Value::Null`）。
    pub author: Value,
    /// 投影行里的配置快照 `sc`（仅代表切换改变了 `sc` 时有意义）。
    pub stored_sc: Option<Value>,
    /// 应采纳的操作里的配置快照 `sc`。
    pub author_sc: Option<Value>,
    /// `sc` 是否发生变化（决定 [heal] 是否改写 `sc` 键与报告例子格式）。
    pub sc_changed: bool,
    /// 若重复日志代表切换同时改变了意图，给出应采纳的 `(intent, arg)`。
    pub author_intent: Option<(i64, Option<i64>)>,
}

fn sc_of(v: &Value) -> Option<&Value> {
    v.get(SNAPSHOT_KEY).filter(|x| x.is_object())
}

fn has_sc(v: &Value) -> bool {
    sc_of(v).is_some()
}

fn has_table(c: &Connection, name: &str) -> Result<bool, String> {
    c.prepare_cached("SELECT 1 FROM main.sqlite_schema WHERE type = 'table' AND name = ?1")
        .map_err(sql)?
        .exists([name])
        .map_err(sql)
}

fn load_projected_log(
    src: &Connection,
    profile: &str,
    op_id: &OpId,
) -> Result<Option<(LogBody, Value)>, String> {
    let Some(op) = load_op(src, profile, op_id)? else {
        return Ok(None);
    };
    if op.purged {
        return Ok(None);
    }
    let Ok(Body::Log(l)) = Body::decode(op.kind, &op.payload) else {
        return Ok(None);
    };
    let projected = log_row(profile, &op, &l);
    Ok(Some((l, projected)))
}

/// 从新代 `log_ix` 读出所有「败者操作号 -> 最小操作号胜者」映射；没有重复日志的库只做一次 `win = 0` 查询即直接返回空表。
fn dup_winners(t: &Truth<'_>, col: i64) -> Result<HashMap<(Ref, OpId), OpId>, String> {
    let conn = t.conn();
    let losers: Vec<(Ref, i64)> = {
        let mut stmt = conn
            .prepare_cached("SELECT id, k FROM log_ix WHERE col = ?1 AND win = 0")
            .map_err(sql)?;
        let rows = stmt
            .query_map([col], |r| Ok((r.get::<_, Ref>(0)?, r.get::<_, i64>(1)?)))
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)?
    };
    if losers.is_empty() {
        return Ok(HashMap::new());
    }
    let dup_ids: HashSet<Ref> = losers.iter().map(|(id, _)| id.clone()).collect();
    let mut winners: HashMap<Ref, OpId> = HashMap::with_capacity(dup_ids.len());
    {
        let mut stmt = conn
            .prepare_cached("SELECT id, k FROM log_ix WHERE col = ?1 AND win = 1")
            .map_err(sql)?;
        let mut rows = stmt.query([col]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let id: Ref = r.get(0).map_err(sql)?;
            if dup_ids.contains(&id) {
                let op = t.id_of_key(r.get::<_, i64>(1).map_err(sql)?)?;
                winners.insert(id, op);
            }
        }
    }
    let mut out = HashMap::with_capacity(losers.len());
    for (id, k) in losers {
        let loser = t.id_of_key(k)?;
        if let Some(&win) = winners.get(&id) {
            if win < loser {
                out.insert((id, loser), win);
            }
        }
    }
    Ok(out)
}

/// [profile] 里佐证得了的过期或败者代表日志结果（模块文件头「佐证」），按日志 ID 排。读 `main` 的表，只读连接上可用。
pub(crate) fn find(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
) -> Result<Vec<Stale>, String> {
    for table in ["srs_review_logs", "sync2_log_meta", "sync2_ops"] {
        if !has_table(src, table)? {
            return Ok(Vec::new());
        }
    }
    let dups = dup_winners(t, col)?;
    let mut stmt = src
        .prepare(
            "SELECT srs_idt(l.id) AS id, srs_idt(l.card_id) AS card, l.json, m.device, m.seq, m.intent, m.arg \
             FROM main.srs_review_logs l JOIN main.sync2_log_meta m ON m.log_id = l.id \
             WHERE l.profile_uid = srs_id(?1) ORDER BY 1",
        )
        .map_err(sql)?;
    let mut rows = stmt.query([profile]).map_err(sql)?;
    let mut out = Vec::new();
    while let Some(r) = rows.next().map_err(sql)? {
        let id_str: String = r.get(0).map_err(sql)?;
        let card_str: String = r.get(1).map_err(sql)?;
        let json: String = r.get(2).map_err(sql)?;
        let device: Vec<u8> = r.get(3).map_err(sql)?;
        let Ok(device) = <[u8; 16]>::try_from(device.as_slice()) else {
            continue;
        };
        let seq: i64 = r.get(4).map_err(sql)?;
        let Ok(seq) = u64::try_from(seq) else {
            continue;
        };
        let m_intent: i64 = r.get(5).map_err(sql)?;
        let m_arg: Option<i64> = r.get(6).map_err(sql)?;
        let meta_op = OpId {
            device: Id(device),
            seq,
        };
        let win_op = if dups.is_empty() {
            None
        } else {
            dups.get(&(Ref::of(&Key::of(&id_str)), meta_op)).copied()
        };

        let Some(win_op) = win_op else {
            // 原 BUG-5250 快速路径：带 `sc` 的行只在原文里出现时才可能有，先按文本筛。
            if json.contains("\"sc\":{") {
                continue;
            }
            let stored: Value =
                serde_json::from_str(&json).map_err(|e| format!("bad review log: {e}"))?;
            if has_sc(&stored) {
                continue;
            }
            let Some((_, projected)) = load_projected_log(src, profile, &meta_op)? else {
                continue;
            };
            if has_sc(&projected) || IDENTITY.iter().any(|k| stored.get(k) != projected.get(k)) {
                continue;
            }
            let (s, a) = (stored.get("res"), projected.get("res"));
            if s != a {
                out.push(Stale {
                    log: id_str,
                    card: card_str,
                    stored: s.cloned().unwrap_or(Value::Null),
                    author: a.cloned().unwrap_or(Value::Null),
                    stored_sc: None,
                    author_sc: None,
                    sc_changed: false,
                    author_intent: None,
                });
            }
            continue;
        };

        // 重复日志代表不一致路径：协议 3 停在败者 meta_op 上，新代选出了更小的 win_op。
        let stored: Value =
            serde_json::from_str(&json).map_err(|e| format!("bad review log: {e}"))?;
        let Some((win_log, projected)) = load_projected_log(src, profile, &win_op)? else {
            continue;
        };
        if IDENTITY.iter().any(|k| stored.get(k) != projected.get(k)) {
            continue;
        }
        let (s_sc, p_sc) = (sc_of(&stored), sc_of(&projected));
        let win_intent = intent_code(&win_log.intent);
        let intent_diff = (m_intent, m_arg) != win_intent;

        if s_sc.is_none() && p_sc.is_none() {
            let (s, a) = (stored.get("res"), projected.get("res"));
            if s != a || intent_diff {
                if intent_diff {
                    let Some((meta_log, _)) = load_projected_log(src, profile, &meta_op)? else {
                        continue;
                    };
                    if (m_intent, m_arg) != intent_code(&meta_log.intent) {
                        continue;
                    }
                }
                out.push(Stale {
                    log: id_str,
                    card: card_str,
                    stored: s.cloned().unwrap_or(Value::Null),
                    author: a.cloned().unwrap_or(Value::Null),
                    stored_sc: None,
                    author_sc: None,
                    sc_changed: false,
                    author_intent: intent_diff.then_some(win_intent),
                });
            }
            continue;
        }

        let sc_changed = s_sc != p_sc;
        let abs_res_diff = !sc_changed
            && win_log.intent == Intent::Absolute
            && stored.get("res") != projected.get("res");
        if !sc_changed && !intent_diff && !abs_res_diff {
            continue;
        }
        // 核对落库行的 `sc` / `intent` / `Absolute res` 确出自败者操作原文，不替磁盘静默改坏兜底。
        let Some((meta_log, meta_projected)) = load_projected_log(src, profile, &meta_op)? else {
            continue;
        };
        if s_sc != sc_of(&meta_projected)
            || (intent_diff && (m_intent, m_arg) != intent_code(&meta_log.intent))
            || (abs_res_diff && stored.get("res") != meta_projected.get("res"))
        {
            continue;
        }
        let (s, a) = (stored.get("res"), projected.get("res"));
        out.push(Stale {
            log: id_str,
            card: card_str,
            stored: s.cloned().unwrap_or(Value::Null),
            author: a.cloned().unwrap_or(Value::Null),
            stored_sc: s_sc.cloned(),
            author_sc: p_sc.cloned(),
            sc_changed,
            author_intent: intent_diff.then_some(win_intent),
        });
    }
    Ok(out)
}

/// 把 [stale] 的投影行结果（及变化的 `sc` / `sync2_log_meta` 意图）改回胜者操作里的，再用协议 3 的重放重放这些卡
/// 所在的归属组（模块文件头「改回去」）。写的是不带库名的 `srs_review_logs` / `sync2_log_meta`：调用方保证它们是
/// 可以改的那一份（干跑的临时表 / 测试装置的 SAVEPOINT）。
pub(crate) fn heal(c: &Connection, stale: &[Stale]) -> Result<(), String> {
    if stale.is_empty() {
        return Ok(());
    }
    let mut cards = BTreeSet::new();
    for s in stale {
        let json: String = c
            .prepare_cached("SELECT json FROM srs_review_logs WHERE id = srs_id(?1)")
            .map_err(sql)?
            .query_row([&s.log], |r| r.get(0))
            .map_err(sql)?;
        let mut row: Value =
            serde_json::from_str(&json).map_err(|e| format!("bad review log: {e}"))?;
        let Value::Object(m) = &mut row else {
            return Err("bad review log: not an object".into());
        };
        match &s.author {
            Value::Null => m.remove("res"),
            a => m.insert("res".into(), a.clone()),
        };
        if s.sc_changed {
            match &s.author_sc {
                None => m.remove(SNAPSHOT_KEY),
                Some(sc) => m.insert(SNAPSHOT_KEY.into(), sc.clone()),
            };
        }
        c.prepare_cached(
            "UPDATE srs_review_logs SET jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, rating, \
             occurred_at, review_type, origin, duration_ms) WHERE id = srs_id(?1)",
        )
        .map_err(sql)?
        .execute(params![s.log, canonical(&row)])
        .map_err(sql)?;
        if let Some((intent, arg)) = s.author_intent {
            c.prepare_cached(
                "UPDATE sync2_log_meta SET intent = ?2, arg = ?3 WHERE log_id = srs_id(?1)",
            )
            .map_err(sql)?
            .execute(params![s.log, intent, arg])
            .map_err(sql)?;
        }
        cards.insert(s.card.clone());
    }
    replay_cards(c, &cards)?;
    Ok(())
}

fn sc_text(sc: &Option<Value>) -> String {
    sc.as_ref().map_or_else(|| "none".to_owned(), canonical)
}

fn example_text(s: &Stale) -> String {
    if !s.sc_changed && s.author_intent.is_none() {
        return format!(
            "{} {} res: {} -> {}",
            s.log,
            s.card,
            canonical(&s.stored),
            canonical(&s.author)
        );
    }
    let mut line = format!(
        "{} {} sc: {} -> {} res: {} -> {}",
        s.log,
        s.card,
        sc_text(&s.stored_sc),
        sc_text(&s.author_sc),
        canonical(&s.stored),
        canonical(&s.author)
    );
    if let Some((intent, arg)) = s.author_intent {
        line.push_str(&format!(" intent: {intent}/{arg:?}"));
    }
    line
}

/// 报告里的一段：`{"logs", "cards", "examples": ["<日志> <卡> [sc: …] res: <落库> -> <操作>", …]}`（只有 ID 与调度数值）。
pub(crate) fn report(stale: &[Stale]) -> Value {
    let cards: BTreeSet<&str> = stale.iter().map(|s| s.card.as_str()).collect();
    serde_json::json!({
        "logs": stale.len(),
        "cards": cards.len(),
        "examples": stale
            .iter()
            .take(EXAMPLES)
            .map(example_text)
            .collect::<Vec<_>>(),
    })
}
