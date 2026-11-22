//! 协议 3 一侧过期的日志结果（反馈 RhMpA6bn8v）：对拍之前先把协议 3 的日志投影行改回「协议 3 自己的规则作用在
//! 操作集合上」应有的样子，再交给冻结的缓存重建（`dryrun.rs` `old_caches`、测试装置 `parity.rs` `protocol_3_caches`）。
//!
//! # 是哪一类
//!
//! 协议 3 的卡片状态、统计都读日志投影行（`srs_review_logs.json`）里的结果 `res`；派生日志的结果由重放写回
//! （`store/sync2/mod.rs` `replay_cards`）。**没有生效配置快照 `sc` 的日志**（迁移进协议 3 之前的旧日志、旧备份并入的
//! 日志）现在的规则是「按作者结果照抄」（`sync2/replay.rs` 文件头、`fold` 里 `snap.is_none()` 时意图当作
//! `Absolute`）：重放既不重算它，也不把它写回。可 2026-10-25 第一版协议 3（`829a67b942`「Merge PR #2535」20:01 +0800，
//! 到带 `7eeb05bc7c` 的 `8d6b9bb568` 20:51 之前；develop 第一父链上首个带协议 3 的 `85b2b259a8` 已含 `7eeb05bc7c`）在迁移
//! 与每次重放时用**当时的**牌组配置重算全部派生日志，没有 `sc` 的也算、也写回；规则
//! 改了之后，这些被改写过的投影行再没人改回来——重放把投影行里的（改写过的）结果当作者结果照抄。于是：
//!
//! - 这条日志的投影行结果 ≠ 它自己操作里作者给的结果（例：间隔按改过的保留率算长了、f32 按最短十进制写）；
//! - 之后带 `sc` 的复习在重放时以它为前一状态，结果、统计分类（`kind`）、成熟变化（`maturity_delta`）跟着不同。
//!
//! 新代的日志是操作本身（`Log4.res` = 作者给的结果原文），缓存层从操作重放，所以给出的是作者结果。两侧的差别不是迁移
//! 改了什么，而是协议 3 这台设备的投影行不再是它自己操作集合的函数（同一批操作在别的设备上投影出来就是作者结果）。
//!
//! # 佐证（逐条，只认这一种）
//!
//! 一行算「过期」当且仅当：
//!
//! 1. 落库的投影行与它的操作（`sync2_log_meta` 记的 (设备, seq)，经 `load_op` 读回，配置快照已拼回）都**没有** `sc`
//!    ——现行重放对它只照抄、从不写回，所以投影行的结果只能等于操作里的；
//! 2. 投影行是这条操作投影出来的：身份键（[IDENTITY]：日志 ID、卡、种类、评分、发生时刻、HLC、来源、评分类型、撤销谁）
//!    与 `log_row(操作)` 逐个相同；
//! 3. 两边的 `res` 不同（按 JSON 值比，f32 的两种十进制写法也算不同：协议 3 读侧按值读）。
//!
//! 带 `sc` 的日志结果不对（重放欠着）、身份键对不上、找不到操作、操作被清除的，一律不认，照原样参与对拍，差异照报。
//!
//! # 改回去
//!
//! [heal]：把这几行的 `res` 换成操作里的（与协议 3 在一台新设备上收这些操作时投影出的相同），再用协议 3 自己的重放
//! （`replay_cards`）重放这些卡所在的归属组——之后带 `sc` 的派生日志按改回的前一状态重算。表名不带库名：干跑里落在
//! 遮住 `main` 的临时表上（旧库一个字节不写），测试装置里在 SAVEPOINT 里、比完回滚。
//!
//! 对用户的影响：迁移之后这些卡按作者结果（与同一批操作在别的设备上相同）排程，报告的 `oldSideStaleResults` 列出条数、
//! 卡数与前几条「日志 卡 res: 落库 -> 操作」。

use std::collections::BTreeSet;

use rusqlite::{Connection, params};
use serde_json::Value;

use super::schema::sql;
use crate::store::sync2::{canonical, load_op, log_row, replay_cards};
use crate::sync2::id::Id;
use crate::sync2::op::Body;
use crate::sync2::replay::SNAPSHOT_KEY;
use crate::sync2::vv::OpId;

/// 投影行与操作逐个比的身份键（佐证第 2 条）。
pub(crate) const IDENTITY: [&str; 9] = [
    "id", "card", "kind", "rating", "at", "hlc", "origin", "rtype", "revokes",
];

/// 报告里最多列几条例子。
pub(crate) const EXAMPLES: usize = 8;

/// 一条过期的日志结果。
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Stale {
    /// 日志 ID（原值）。
    pub log: String,
    /// 日志所在的卡（原值）。
    pub card: String,
    /// 投影行里的结果（没有 = `Value::Null`）。
    pub stored: Value,
    /// 操作里作者给的结果（没有 = `Value::Null`）。
    pub author: Value,
}

fn has_sc(v: &Value) -> bool {
    v.get(SNAPSHOT_KEY).is_some_and(Value::is_object)
}

fn has_table(c: &Connection, name: &str) -> Result<bool, String> {
    c.prepare_cached("SELECT 1 FROM main.sqlite_schema WHERE type = 'table' AND name = ?1")
        .map_err(sql)?
        .exists([name])
        .map_err(sql)
}

/// [profile] 里佐证得了的过期日志结果（模块文件头「佐证」），按日志 ID 排。读 `main` 的表，只读连接上可用。
pub(crate) fn find(src: &Connection, profile: &str) -> Result<Vec<Stale>, String> {
    for t in ["srs_review_logs", "sync2_log_meta", "sync2_ops"] {
        if !has_table(src, t)? {
            return Ok(Vec::new());
        }
    }
    let mut stmt = src
        .prepare(
            "SELECT srs_idt(l.id) AS id, srs_idt(l.card_id) AS card, l.json, m.device, m.seq \
             FROM main.srs_review_logs l JOIN main.sync2_log_meta m ON m.log_id = l.id \
             WHERE l.profile_uid = srs_id(?1) ORDER BY 1",
        )
        .map_err(sql)?;
    let mut rows = stmt.query([profile]).map_err(sql)?;
    let mut out = Vec::new();
    while let Some(r) = rows.next().map_err(sql)? {
        let json: String = r.get(2).map_err(sql)?;
        // 带 `sc` 的行不在这一类里（快照只在原文里出现时才可能有，先按文本筛，省得逐行解析）。
        if json.contains("\"sc\":{") {
            continue;
        }
        let stored: Value =
            serde_json::from_str(&json).map_err(|e| format!("bad review log: {e}"))?;
        if has_sc(&stored) {
            continue;
        }
        let device: Vec<u8> = r.get(3).map_err(sql)?;
        let Ok(device) = <[u8; 16]>::try_from(device.as_slice()) else {
            continue;
        };
        let seq: i64 = r.get(4).map_err(sql)?;
        let Ok(seq) = u64::try_from(seq) else {
            continue;
        };
        let Some(op) = load_op(
            src,
            profile,
            &OpId {
                device: Id(device),
                seq,
            },
        )?
        else {
            continue;
        };
        if op.purged {
            continue;
        }
        let Ok(Body::Log(l)) = Body::decode(op.kind, &op.payload) else {
            continue;
        };
        let projected = log_row(profile, &op, &l);
        if has_sc(&projected) || IDENTITY.iter().any(|k| stored.get(k) != projected.get(k)) {
            continue;
        }
        let (s, a) = (stored.get("res"), projected.get("res"));
        if s != a {
            out.push(Stale {
                log: r.get(0).map_err(sql)?,
                card: r.get(1).map_err(sql)?,
                stored: s.cloned().unwrap_or(Value::Null),
                author: a.cloned().unwrap_or(Value::Null),
            });
        }
    }
    Ok(out)
}

/// 把 [stale] 的投影行结果改回操作里的，再用协议 3 的重放重放这些卡所在的归属组（模块文件头「改回去」）。写的是不带
/// 库名的 `srs_review_logs`：调用方保证它是可以改的那一份（干跑的临时表 / 测试装置的 SAVEPOINT）。
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
        c.prepare_cached(
            "UPDATE srs_review_logs SET jslim = srs_log_pack(?2, id, profile_uid, card_id, kind, rating, \
             occurred_at, review_type, origin, duration_ms) WHERE id = srs_id(?1)",
        )
        .map_err(sql)?
        .execute(params![s.log, canonical(&row)])
        .map_err(sql)?;
        cards.insert(s.card.clone());
    }
    replay_cards(c, &cards)?;
    Ok(())
}

/// 报告里的一段：`{"logs", "cards", "examples": ["<日志> <卡> res: <落库> -> <操作>", …]}`（只有 ID 与调度数值）。
pub(crate) fn report(stale: &[Stale]) -> Value {
    let cards: BTreeSet<&str> = stale.iter().map(|s| s.card.as_str()).collect();
    serde_json::json!({
        "logs": stale.len(),
        "cards": cards.len(),
        "examples": stale
            .iter()
            .take(EXAMPLES)
            .map(|s| format!("{} {} res: {} -> {}", s.log, s.card, canonical(&s.stored), canonical(&s.author)))
            .collect::<Vec<_>>(),
    })
}
