//! 协议 3 一侧偏离操作集合规则的日志投影（反馈 RhMpA6bn8v、PR #4245）：对拍之前先把协议 3 的日志投影行改回「协议 3
//! 自己的规则作用在操作集合上」应有的样子，再交给冻结的缓存重建（`dryrun.rs` `old_caches`、测试装置 `parity.rs`
//! `protocol_3_caches`）。
//!
//! # 是哪两类
//!
//! 1. **第一版协议 3 旧重放改写**（日志只有一条活跃操作，两边都无 `sc`）：协议 3 的卡片状态、统计都读日志投影行
//!    （`srs_review_logs.json`）里的结果 `res`；现行规则（`sync2/replay.rs` `fold` 里 `snap.is_none()` 时意图当作
//!    `Absolute`）对没有生效配置快照 `sc` 的日志只照抄作者结果，不重算也不写回。可 2026-10-25 第一版协议 3
//!    （`829a67b942`「Merge PR #2535」20:01 +0800 到带 `7eeb05bc7c` 的 `8d6b9bb568` 20:51 之前）曾在迁移与重放时
//!    按当时的牌组配置改写无 `sc` 日志的投影行；规则改回后没人再改回来。
//! 2. **重复日志停在非代表副本上**（同一个日志 ID 在 `log_ix` 有多条活跃操作）：协议 3 里日志投影是全库唯一一处
//!    依赖到达顺序的地方——`project_log` 只在行不存在时插入、`index_log` 是 `INSERT OR IGNORE`、`upsert_server_time`
//!    也只在插入时调（`store/sync2/mod.rs`），所以投影行、`sync2_log_meta`（意图、卡、笔记、操作号）与 S(e) 都停在
//!    **先到**的那份副本上；`dedup.rs` 只收敛载荷逐字节相同的副本。新代 `derive.rs` `pick_log` 与到达顺序无关，取操作号
//!    最小的（`log_ix.win = 1`）。两份副本可以在载荷的任何一处不同（`sc` 有无 / 不同、意图、作者结果、时长、时区、
//!    参数、HLC、甚至卡），每一处都会让两侧的卡、统计分叉、整份撤回。实体（`project_entity` 按规范文本取小者）与修改
//!    记录（寄存器判据）两侧都与顺序无关，不在此列。
//!
//! 两类的差异都不是迁移改错了什么，而是协议 3 这台设备的投影偏离了「协议 3 规则作用在全集（按最小操作号选代表）上」
//! 的基准。
//!
//! # 佐证（逐条，只认这两种）
//!
//! - **第 1 类**（日志 ID 没有更小操作号的代表）：与 BUG-5250 一致——落库投影行与 `sync2_log_meta` 所指操作都没有
//!   `sc`；身份键（[IDENTITY]）与 `log_row(操作)` 逐个相同；两边的 `res` 按 JSON 值不同。
//! - **第 2 类**（`log_ix` 里 `win = 1` 的操作号 W 严格小于 `sync2_log_meta` 所指的 M，M 也在 `log_ix` 里）：
//!   1. 落库行确出自 M（防磁盘静默改坏）：身份键与 `log_row(M)` 逐个相同、`sc` 相同、`sync2_log_meta` 的意图等于 M 的；
//!      M 的结果由作者给（带 `sc` 的 `Absolute`）时落库 `res` 也必须等于 M 的；下面第 2 条里要换掉的每个键、以及要换
//!      的 S(e)，落库原值也必须是 M 的；
//!   2. 换代表确实改变了什么：`log_row(M)` 与 `log_row(W)` 在 `res` 以外的某个键上不同，或意图、S(e) 不同，或 W 的
//!      结果由作者给（无 `sc` 或 `Absolute`）而落库 `res` 与它不同。M 与 W 除了操作号什么都一样时，落库行与操作的
//!      任何差异都不是换代表能解释的，照原样对拍。
//!
//! 改回的只是「M → W」的差量：`log_row(M)` 与 `log_row(W)` 不同的那些键换成 W 的，两者相同的键保留落库原值（落库行
//! 在那里若被改坏，差异照报）。`res` 在 W 的结果由作者给时换成 W 的，否则留给重放重算。
//!
//! 身份键对不上、找不到操作、操作被清除、M 不在 `log_ix`（新代不认它为活跃操作，属清除 / 作废的口径）的，一律不认，
//! 照原样参与对拍，差异照报。
//!
//! # 改回去
//!
//! [heal]：第 1 类只改 `res`；第 2 类把投影行（列与 JSON）、`sync2_log_meta`（卡、笔记、意图、操作号）与 S(e)
//! （`srs_event_local.server_time`）改成 W 的，再用协议 3 自己的重放（`replay_cards`）重放受影响卡（换卡时新旧两张）
//! 的归属组。表名不带库名：干跑里落在遮住 `main` 的临时表上（旧库一个字节不写），测试装置里在 SAVEPOINT 里、比完回滚。

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

/// 投影行与操作逐个比的身份键（佐证第 1 类、第 2 类第 1 条）。
pub(crate) const IDENTITY: [&str; 9] = [
    "id", "card", "kind", "rating", "at", "hlc", "origin", "rtype", "revokes",
];

/// 报告里最多列几条例子。
pub(crate) const EXAMPLES: usize = 8;

/// 一条需要按操作集合规则改回的协议 3 日志投影。
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Stale {
    /// 日志 ID（原值）。
    pub log: String,
    /// 落库行所在的卡（原值）。
    pub card: String,
    /// 投影行里的结果（没有 = `Value::Null`）。
    pub stored: Value,
    /// 改回后的结果（没有 = `Value::Null`；第 2 类里 W 的结果要重放时就是落库原值，由重放重算）。
    pub author: Value,
    /// 第 2 类：换代表（第 1 类为 `None`）。
    pub swap: Option<Swap>,
}

/// 重复日志从协议 3 先到的副本 M 换成新代的代表 W（模块文件头「是哪两类」第 2 类）。
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Swap {
    /// 投影行所在的 profile（`srs_event_local` 补行要用）。
    pub profile: String,
    /// 协议 3 落库所依的副本 M。
    pub from: OpId,
    /// 新代选的代表 W（操作号最小）。
    pub to: OpId,
    /// 改回后的整行投影 JSON（`res` 已按 [Stale::author] 定好）。
    pub row: Value,
    /// `log_row(M)` 与 `log_row(W)` 不同的键（不含 `res`），排好序。
    pub keys: Vec<String>,
    /// 改前 / 改后的配置快照（`sc` 在 [Swap::keys] 里时报告用）。
    pub sc: (Option<Value>, Option<Value>),
    /// W 的卡与笔记（`sync2_log_meta` 的 `card_id` / `note_id` 总按 W 写）。
    pub to_card: String,
    pub to_note: Option<String>,
    /// W 的 `(intent, arg)`（`sync2_log_meta` 总按 W 写）。
    pub intent: (i64, Option<i64>),
    /// 意图是否变了（报告用）。
    pub intent_changed: bool,
    /// S(e) 变了时 W 的（`None` 在里面 = W 没带，清空）。
    pub server_time: Option<Option<i64>>,
}

fn sc_of(v: &Value) -> Option<&Value> {
    v.get(SNAPSHOT_KEY).filter(|x| x.is_object())
}

fn has_sc(v: &Value) -> bool {
    sc_of(v).is_some()
}

/// 这条日志的结果由作者给（重放照抄、不重算）：无 `sc`（`fold` 里当 `Absolute`）或意图本身是 `Absolute`。
fn author_owned(projected: &Value, l: &LogBody) -> bool {
    !has_sc(projected) || l.intent == Intent::Absolute
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

/// 新代 `log_ix` 里「非代表副本的操作号 → 代表（最小操作号）」：只看有多条的日志 ID；没有重复日志的库只做一次
/// `win = 0` 查询就返回空表。
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

/// [profile] 里佐证得了的过期结果与停在非代表副本上的日志（模块文件头「佐证」），按日志 ID 排。读 `main` 的表，
/// 只读连接上可用。
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
        let id: String = r.get(0).map_err(sql)?;
        let card: String = r.get(1).map_err(sql)?;
        let json: String = r.get(2).map_err(sql)?;
        let device: Vec<u8> = r.get(3).map_err(sql)?;
        let Ok(device) = <[u8; 16]>::try_from(device.as_slice()) else {
            continue;
        };
        let seq: i64 = r.get(4).map_err(sql)?;
        let Ok(seq) = u64::try_from(seq) else {
            continue;
        };
        let meta_intent: (i64, Option<i64>) = (r.get(5).map_err(sql)?, r.get(6).map_err(sql)?);
        let meta_op = OpId {
            device: Id(device),
            seq,
        };
        let win_op = if dups.is_empty() {
            None
        } else {
            dups.get(&(Ref::of(&Key::of(&id)), meta_op)).copied()
        };
        let found = match win_op {
            None => first_kind(src, profile, (id, card), &json, &meta_op)?,
            Some(win_op) => {
                let stored: Value =
                    serde_json::from_str(&json).map_err(|e| format!("bad review log: {e}"))?;
                swapped(
                    src,
                    profile,
                    (id, card),
                    &stored,
                    meta_intent,
                    (meta_op, win_op),
                )?
            }
        };
        out.extend(found);
    }
    Ok(out)
}

/// 第 1 类（BUG-5250）：单代表、两边无 `sc`、身份键相同、`res` 不同。
fn first_kind(
    src: &Connection,
    profile: &str,
    (log, card): (String, String),
    json: &str,
    meta_op: &OpId,
) -> Result<Option<Stale>, String> {
    // 带 `sc` 的行只在原文里出现时才可能有，先按文本筛。
    if json.contains("\"sc\":{") {
        return Ok(None);
    }
    let stored: Value = serde_json::from_str(json).map_err(|e| format!("bad review log: {e}"))?;
    if has_sc(&stored) {
        return Ok(None);
    }
    let Some((_, projected)) = load_projected_log(src, profile, meta_op)? else {
        return Ok(None);
    };
    if has_sc(&projected) || IDENTITY.iter().any(|k| stored.get(k) != projected.get(k)) {
        return Ok(None);
    }
    let (s, a) = (stored.get("res"), projected.get("res"));
    if s == a {
        return Ok(None);
    }
    Ok(Some(Stale {
        log,
        card,
        stored: s.cloned().unwrap_or(Value::Null),
        author: a.cloned().unwrap_or(Value::Null),
        swap: None,
    }))
}

/// 第 2 类：协议 3 停在先到的副本 M 上，新代选了操作号更小的 W（模块文件头「佐证」第 2 类）。
fn swapped(
    src: &Connection,
    profile: &str,
    (log, card): (String, String),
    stored: &Value,
    meta_intent: (i64, Option<i64>),
    (from, to): (OpId, OpId),
) -> Result<Option<Stale>, String> {
    let Some((m_log, m_row)) = load_projected_log(src, profile, &from)? else {
        return Ok(None);
    };
    let Some((w_log, w_row)) = load_projected_log(src, profile, &to)? else {
        return Ok(None);
    };
    // 1. 落库行确出自 M。
    if IDENTITY.iter().any(|k| stored.get(k) != m_row.get(k))
        || sc_of(stored) != sc_of(&m_row)
        || meta_intent != intent_code(&m_log.intent)
        || (has_sc(&m_row)
            && m_log.intent == Intent::Absolute
            && stored.get("res") != m_row.get("res"))
    {
        return Ok(None);
    }
    // 2. 换代表改变了什么：M → W 的差量（不含 `res`）。
    let (Value::Object(m_map), Value::Object(w_map), Value::Object(stored_map)) =
        (&m_row, &w_row, stored)
    else {
        return Ok(None);
    };
    let keys: Vec<String> = m_map
        .keys()
        .chain(w_map.keys())
        .filter(|k| k.as_str() != "res" && m_map.get(*k) != w_map.get(*k))
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    // 要换掉的键，落库原值也必须是 M 的（不替磁盘静默改坏兜底）。
    if keys.iter().any(|k| stored_map.get(k) != m_map.get(k)) {
        return Ok(None);
    }
    let to_intent = intent_code(&w_log.intent);
    let intent_changed = meta_intent != to_intent;
    let server_time =
        (m_log.legacy_server_time != w_log.legacy_server_time).then_some(w_log.legacy_server_time);
    // S(e) 同理：要换时落库的那份必须是 M 的。
    if server_time.is_some() && stored_server_time(src, &log)? != m_log.legacy_server_time {
        return Ok(None);
    }
    let stored_res = stored.get("res").cloned().unwrap_or(Value::Null);
    let author = if author_owned(&w_row, &w_log) {
        w_row.get("res").cloned().unwrap_or(Value::Null)
    } else {
        stored_res.clone()
    };
    if keys.is_empty() && !intent_changed && server_time.is_none() && author == stored_res {
        return Ok(None);
    }
    let mut row = stored_map.clone();
    for k in &keys {
        match w_map.get(k) {
            Some(v) => row.insert(k.clone(), v.clone()),
            None => row.remove(k),
        };
    }
    match &author {
        Value::Null => row.remove("res"),
        a => row.insert("res".into(), a.clone()),
    };
    Ok(Some(Stale {
        log,
        card,
        stored: stored_res,
        author,
        swap: Some(Swap {
            profile: profile.to_owned(),
            from,
            to,
            row: Value::Object(row),
            keys,
            sc: (sc_of(stored).cloned(), sc_of(&w_row).cloned()),
            to_card: w_log.card.text(),
            to_note: w_log.note.as_ref().map(Key::text),
            intent: to_intent,
            intent_changed,
            server_time,
        }),
    }))
}

/// 协议 3 记的这条日志的 S(e)（`srs_event_local.server_time`；没有行 = `None`）。
fn stored_server_time(src: &Connection, log: &str) -> Result<Option<i64>, String> {
    use rusqlite::OptionalExtension;
    Ok(src
        .prepare_cached("SELECT server_time FROM main.srs_event_local WHERE event_id = srs_id(?1)")
        .map_err(sql)?
        .query_row([log], |r| r.get::<_, Option<i64>>(0))
        .optional()
        .map_err(sql)?
        .flatten())
}

/// [stale] 里有没有要改 `sync2_log_meta` 的（干跑据此决定要不要给它建影子）。
pub(crate) fn touches_meta(stale: &[Stale]) -> bool {
    stale.iter().any(|s| s.swap.is_some())
}

/// 同上，`srs_event_local`（S(e)）。
pub(crate) fn touches_server_time(stale: &[Stale]) -> bool {
    stale
        .iter()
        .any(|s| s.swap.as_ref().is_some_and(|w| w.server_time.is_some()))
}

/// 把 [stale] 改回（模块文件头「改回去」），再用协议 3 的重放重放受影响的卡所在的归属组。写的是不带库名的
/// `srs_review_logs` / `sync2_log_meta` / `srs_event_local`：调用方保证它们是可以改的那一份（干跑的临时表 / 测试
/// 装置的 SAVEPOINT）。
pub(crate) fn heal(c: &Connection, stale: &[Stale]) -> Result<(), String> {
    if stale.is_empty() {
        return Ok(());
    }
    let mut cards = BTreeSet::new();
    for s in stale {
        cards.insert(s.card.clone());
        let Some(w) = &s.swap else {
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
            c.prepare_cached(
                "UPDATE srs_review_logs SET jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, rating, \
                 occurred_at, review_type, origin, duration_ms) WHERE id = srs_id(?1)",
            )
            .map_err(sql)?
            .execute(params![s.log, canonical(&row)])
            .map_err(sql)?;
            continue;
        };
        // 存储列与 JSON 一起按改回后的整行写（列与 `project_log` 插入时同源）。
        let text = |k: &str| -> Result<String, String> {
            w.row
                .get(k)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| format!("stale heal: log {} has no {k}", s.log))
        };
        let card = text("card")?;
        let (kind, rtype, origin) = (text("kind")?, text("rtype")?, text("origin")?);
        let rating = w.row.get("rating").and_then(Value::as_i64);
        let at = w
            .row
            .get("at")
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("stale heal: log {} has no at", s.log))?;
        let dur = w.row.get("dur").and_then(Value::as_i64).unwrap_or(0);
        c.prepare_cached(
            "UPDATE srs_review_logs SET card_id = srs_id(?2), kind = ?3, rating = ?4, occurred_at = ?5, \
             review_type = ?6, origin = ?7, duration_ms = ?8, \
             jslim = srs_log_pack(?9, id, profile_uid, srs_id(?2), ?3, ?4, ?5, ?6, ?7, ?8) \
             WHERE id = srs_id(?1)",
        )
        .map_err(sql)?
        .execute(params![
            s.log,
            card,
            kind,
            rating,
            at,
            rtype,
            origin,
            dur,
            canonical(&w.row)
        ])
        .map_err(sql)?;
        c.prepare_cached(
            "UPDATE sync2_log_meta SET card_id = srs_id(?2), note_id = srs_id(?3), intent = ?4, arg = ?5, \
             device = ?6, seq = ?7 WHERE log_id = srs_id(?1)",
        )
        .map_err(sql)?
        .execute(params![
            s.log,
            w.to_card,
            w.to_note,
            w.intent.0,
            w.intent.1,
            w.to.device.0.to_vec(),
            w.to.seq as i64
        ])
        .map_err(sql)?;
        if let Some(st) = w.server_time {
            c.prepare_cached(
                "INSERT INTO srs_event_local (event_id, profile_uid, outbox_seq, server_time, received_at) \
                 VALUES (srs_id(?1), srs_id(?2), NULL, ?3, 0) \
                 ON CONFLICT(event_id) DO UPDATE SET server_time = excluded.server_time",
            )
            .map_err(sql)?
            .execute(params![s.log, w.profile, st])
            .map_err(sql)?;
        }
        cards.insert(card);
    }
    replay_cards(c, &cards)?;
    Ok(())
}

fn sc_text(sc: &Option<Value>) -> String {
    sc.as_ref().map_or_else(|| "none".to_owned(), canonical)
}

fn op_text(id: &OpId) -> String {
    format!("{}:{}", id.device.text(), id.seq)
}

fn example_text(s: &Stale) -> String {
    let res = format!("res: {} -> {}", canonical(&s.stored), canonical(&s.author));
    let Some(w) = &s.swap else {
        return format!("{} {} {res}", s.log, s.card);
    };
    // 只有 ID、键名与调度数值：换了的键只报名字（`sc` 是配置数值，照报改前 / 改后）。
    let mut line = format!(
        "{} {} op: {} -> {} keys: [{}]",
        s.log,
        s.card,
        op_text(&w.from),
        op_text(&w.to),
        w.keys.join(",")
    );
    if w.keys.iter().any(|k| k == SNAPSHOT_KEY) {
        line.push_str(&format!(
            " sc: {} -> {}",
            sc_text(&w.sc.0),
            sc_text(&w.sc.1)
        ));
    }
    line.push(' ');
    line.push_str(&res);
    if w.intent_changed {
        line.push_str(&format!(" intent: {}/{:?}", w.intent.0, w.intent.1));
    }
    if let Some(st) = w.server_time {
        line.push_str(&format!(" serverTime: {st:?}"));
    }
    line
}

/// 报告里的一段：`{"logs", "cards", "swaps", "examples": [...]}`（只有 ID、键名与调度数值）。`swaps` 是其中第 2 类
/// （换代表）的条数。
pub(crate) fn report(stale: &[Stale]) -> Value {
    let cards: BTreeSet<&str> = stale.iter().map(|s| s.card.as_str()).collect();
    serde_json::json!({
        "logs": stale.len(),
        "cards": cards.len(),
        "swaps": stale.iter().filter(|s| s.swap.is_some()).count(),
        "examples": stale
            .iter()
            .take(EXAMPLES)
            .map(example_text)
            .collect::<Vec<_>>(),
    })
}
