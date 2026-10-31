//! P6 直读命令（docs/specs/2026-10-23-srs-rust-store.md §7）：优化器训练集、RWKV 回放行 / 日志尾巴、
//! 统计页的有效评分列。日志原文与服务器时刻在 srs.db 的**读连接**上一个读事务里取出（WAL 快照：只看已
//! 提交的行，不挡写连接上的作答），在 Rust 里选取、投影（`crate::projection`），只把结果列交回 Dart。
//!
//! 血统（自己 + 全部前身的卡 ID）与数字身份仍由 Dart 给出：血统要字段寄存器内核与修改记录预读，与缓存刷新的
//! `history_states` 同一形态。

use std::collections::{HashMap, HashSet};

use rusqlite::Connection;

use super::SrsCore;
use crate::history::{parse_full, Parsed, NONE_I64};
use crate::projection::{self, Alg, Day, EffLog, RwkvIds, RWKV_ROW};

/// [SrsCore::rwkv_replay] 取哪些行（见那里）。
#[derive(Clone, Copy, Debug, Default)]
pub struct RwkvRange {
    pub rebase_since: Option<i64>,
    pub rows_from: Option<i64>,
}

/// 分歧时刻（[SrsCore::rwkv_replay] 的局部重放）：`touched` 里的卡所在的每份历史，按「只看 rowid ≤ `since`
/// 的日志」与「全部日志」各算一遍保留评分行，第一处不同的时刻（两边在该位置的时刻取小）；全部相同 = None。
/// 行里的数字身份两边一样，比较时用 0。
fn rwkv_divergence(
    groups: &[Vec<String>],
    logs: &LogsByCard,
    rowids: &HashMap<String, Vec<i64>>,
    touched: &HashSet<String>,
    since: i64,
    day: &Day,
) -> Result<Option<i64>, String> {
    let mut diverge: Option<i64> = None;
    let zero: RwkvIds = [0; 4];
    for lineage in groups {
        if !lineage.iter().any(|c| touched.contains(c)) {
            continue;
        }
        let mut old: LogsByCard = HashMap::new();
        for c in lineage {
            if let (Some(rows), Some(ids)) = (logs.get(c), rowids.get(c)) {
                let kept: Vec<(String, Option<i64>)> =
                    rows.iter().zip(ids).filter(|(_, &id)| id <= since).map(|(r, _)| r.clone()).collect();
                old.insert(c.clone(), kept);
            }
        }
        let (new_rows, new_at, _) = projection::rwkv_card_rows(&effective_of(lineage, logs)?, &zero, day)?;
        let (old_rows, old_at, _) = projection::rwkv_card_rows(&effective_of(lineage, &old)?, &zero, day)?;
        let n = new_at.len().max(old_at.len());
        for i in 0..n {
            let same = i < new_at.len()
                && i < old_at.len()
                && new_at[i] == old_at[i]
                && new_rows[i * RWKV_ROW..(i + 1) * RWKV_ROW] == old_rows[i * RWKV_ROW..(i + 1) * RWKV_ROW];
            if same {
                continue;
            }
            let at = match (new_at.get(i), old_at.get(i)) {
                (Some(&a), Some(&b)) => a.min(b),
                (Some(&a), None) | (None, Some(&a)) => a,
                (None, None) => unreachable!("i < max(len)"),
            };
            diverge = Some(diverge.map_or(at, |d| d.min(at)));
            break;
        }
    }
    Ok(diverge)
}

/// 一组卡的全部日志：卡 ID → [(落库 JSON, 服务器时刻)]（同卡内按 rowid）。
type LogsByCard = HashMap<String, Vec<(String, Option<i64>)>>;

pub(super) fn fetch_logs(conn: &Connection, cards: &[&str]) -> Result<LogsByCard, String> {
    let mut logs: LogsByCard = HashMap::with_capacity(cards.len());
    for chunk in cards.chunks(500) {
        let marks = vec!["srs_id(?)"; chunk.len()].join(", ");
        let sql = format!(
            "SELECT srs_idt(l.card_id) AS card_id, l.json, e.server_time FROM srs_review_logs l \
             LEFT JOIN srs_event_local e ON e.event_id = l.id WHERE l.card_id IN ({marks}) ORDER BY l.rowid"
        );
        let mut stmt = conn.prepare_cached(&sql).map_err(|e| e.to_string())?;
        let mut q = stmt
            .query(rusqlite::params_from_iter(chunk.iter()))
            .map_err(|e| e.to_string())?;
        while let Some(row) = q.next().map_err(|e| e.to_string())? {
            let card: String = row.get(0).map_err(|e| e.to_string())?;
            let json: String = row.get(1).map_err(|e| e.to_string())?;
            let st: Option<i64> = row.get(2).map_err(|e| e.to_string())?;
            logs.entry(card).or_default().push((json, st));
        }
    }
    Ok(logs)
}

/// 每份历史的完整血统：调用方给的卡（第一张是这份历史的卡；Dart 只给它自己）连同它的全部前身
/// （store/caches.rs `lineage_ids`），给过的顺序在前、补上的按血统顺序接在后面。
fn expand_lineages(r: &Connection, groups: &[Vec<String>]) -> Result<Vec<Vec<String>>, String> {
    let seeds: Vec<String> = groups.iter().filter_map(|g| g.first().cloned()).collect();
    let mut full = crate::store::caches::lineage_ids(r, &seeds)?.into_iter();
    let mut out = Vec::with_capacity(groups.len());
    for g in groups {
        let mut l = g.clone();
        if !g.is_empty() {
            for id in full.next().unwrap_or_default() {
                if !l.contains(&id) {
                    l.push(id);
                }
            }
        }
        out.push(l);
    }
    Ok(out)
}

/// 血统里出现过的卡（去重，保序）。
pub(super) fn wanted_cards(groups: &[Vec<String>]) -> Vec<&str> {
    let mut wanted: Vec<&str> = Vec::new();
    let mut seen = HashSet::new();
    for g in groups {
        for c in g {
            if seen.insert(c.as_str()) {
                wanted.push(c.as_str());
            }
        }
    }
    wanted
}

/// 一份历史（血统里各卡日志之和）的有效日志。
fn effective_of(lineage: &[String], logs: &LogsByCard) -> Result<Vec<EffLog>, String> {
    let mut parsed: Vec<Parsed<'_>> = Vec::new();
    for c in lineage {
        if let Some(rows) = logs.get(c) {
            for (j, s) in rows {
                parsed.push(parse_full(j, *s)?);
            }
        }
    }
    Ok(projection::effective_logs(&parsed))
}

fn push_i64(out: &mut Vec<u8>, v: i64) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn push_f64(out: &mut Vec<u8>, v: f64) {
    out.extend_from_slice(&v.to_le_bytes());
}

/// 串表：`[u32 偏移 × (n + 1)][UTF-8]`。
fn push_strings<'s>(out: &mut Vec<u8>, strings: impl Iterator<Item = &'s str>) {
    let mut body = String::new();
    let mut offs: Vec<u32> = vec![0];
    for s in strings {
        body.push_str(s);
        offs.push(body.len() as u32);
    }
    for o in offs {
        out.extend_from_slice(&o.to_le_bytes());
    }
    out.extend_from_slice(body.as_bytes());
}

impl SrsCore {
    /// 读连接上一个读事务：多条语句看同一个 WAL 快照。
    fn read_snapshot<T>(&self, body: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
        let r = self.reader()?;
        r.execute_batch("BEGIN").map_err(|e| e.to_string())?;
        let out = body(&r);
        // 只读事务：结束它只是放掉快照。
        let end = r.execute_batch("COMMIT").map_err(|e| e.to_string());
        let out = out?;
        end?;
        Ok(out)
    }

    /// 优化器训练集（`srsPrepareOptimization`）：`groups[g]` 是一张卡（调用方只给卡自己即可，全部前身由
    /// [expand_lineages] 在同一个快照里补齐），`card_ids[g]` 是它的 53 位数字 id。
    ///
    /// 输出（小端，全部 8 字节字）：`[n_seq, n_reviews, n_items]`、`seq_start × (n_seq + 1)`、`seq_card × n_seq`、
    /// `rating × n_reviews`、`delta(f64) × n_reviews`、`(seq, len) × n_items`。序列 = 一张进训练集的卡的完整评审，
    /// 条目 = 它到第 len 次评分为止的前缀；条目按最后一次评分时刻升序（同一时刻按卡的输入顺序、再按评分先后）。
    pub fn optimizer_items(&self, groups: &[Vec<String>], card_ids: &[i64], alg: Alg, day: &Day) -> Result<Vec<u8>, String> {
        if card_ids.len() != groups.len() {
            return Err("optimizer: card id count differs from group count".into());
        }
        let (groups, logs) = self.read_snapshot(|r| {
            let groups = expand_lineages(r, groups)?;
            let logs = fetch_logs(r, &wanted_cards(&groups))?;
            Ok((groups, logs))
        })?;
        let mut seq_start: Vec<i64> = vec![0];
        let mut seq_card: Vec<i64> = Vec::new();
        let mut ratings: Vec<i64> = Vec::new();
        let mut deltas: Vec<f64> = Vec::new();
        // (时刻, 序列, 前缀长度)；稳定排序保住输入顺序。
        let mut items: Vec<(i64, i64, i64)> = Vec::new();
        for (g, lineage) in groups.iter().enumerate() {
            let eff = effective_of(lineage, &logs)?;
            let Some((reviews, card_items)) = projection::optimizer_card(&eff, alg, day)? else {
                continue;
            };
            let seq = seq_card.len() as i64;
            seq_card.push(card_ids[g]);
            for (r, d) in &reviews {
                ratings.push(*r);
                deltas.push(*d);
            }
            seq_start.push(ratings.len() as i64);
            for (at, len) in card_items {
                items.push((at, seq, len as i64));
            }
        }
        items.sort_by_key(|i| i.0);
        let mut out = Vec::with_capacity(24 + (seq_start.len() + seq_card.len() + 2 * ratings.len() + 2 * items.len()) * 8);
        push_i64(&mut out, seq_card.len() as i64);
        push_i64(&mut out, ratings.len() as i64);
        push_i64(&mut out, items.len() as i64);
        seq_start.iter().for_each(|&v| push_i64(&mut out, v));
        seq_card.iter().for_each(|&v| push_i64(&mut out, v));
        ratings.iter().for_each(|&v| push_i64(&mut out, v));
        deltas.iter().for_each(|&v| push_f64(&mut out, v));
        for (_, seq, len) in items {
            push_i64(&mut out, seq);
            push_i64(&mut out, len);
        }
        Ok(out)
    }

    /// RWKV 逐卡（增量追加、排队的此刻行用）：每份历史的保留评分行与摘要。`ids[4g..4g+4]` 是第 g 份的
    /// 卡 / 笔记 / 牌组 / 预设数字 id。
    ///
    /// 输出：`[i64 n_groups]`，每份 `[i64 kept, effectiveRatings, lastAt|NONE, lastRating, lastRType, 0]`，
    /// 全部保留评分行（80 字节 × 总数，份内时间顺序），保留评分的日志 ID 串表。
    pub fn rwkv_cards(&self, groups: &[Vec<String>], ids: &[i64], day: &Day) -> Result<Vec<u8>, String> {
        if ids.len() != groups.len() * 4 {
            return Err("rwkv: id count differs from 4 × group count".into());
        }
        let (groups, logs) = self.read_snapshot(|r| {
            let groups = expand_lineages(r, groups)?;
            let logs = fetch_logs(r, &wanted_cards(&groups))?;
            Ok((groups, logs))
        })?;
        let mut head = Vec::with_capacity(8 + groups.len() * 48);
        let mut rows = Vec::new();
        let mut kept_ids: Vec<String> = Vec::new();
        push_i64(&mut head, groups.len() as i64);
        for (g, lineage) in groups.iter().enumerate() {
            let eff = effective_of(lineage, &logs)?;
            let card: RwkvIds = [ids[4 * g], ids[4 * g + 1], ids[4 * g + 2], ids[4 * g + 3]];
            let (r, _, kept) = projection::rwkv_card_rows(&eff, &card, day)?;
            rows.extend_from_slice(&r);
            push_i64(&mut head, kept.len() as i64);
            push_i64(&mut head, eff.iter().filter(|l| l.is_rating()).count() as i64);
            match kept.last() {
                Some(&i) => {
                    push_i64(&mut head, eff[i].at);
                    push_i64(&mut head, eff[i].rating.unwrap_or(0));
                    push_i64(&mut head, eff[i].rtype as i64);
                }
                None => {
                    push_i64(&mut head, NONE_I64);
                    push_i64(&mut head, 0);
                    push_i64(&mut head, 0);
                }
            }
            push_i64(&mut head, 0);
            kept_ids.extend(kept.iter().map(|&i| eff[i].id.clone()));
        }
        head.extend_from_slice(&rows);
        push_strings(&mut head, kept_ids.iter().map(String::as_str));
        Ok(head)
    }

    /// RWKV 回放行：本 profile 的日志一条语句扫出（指纹与行出自同一个快照），按 `groups`（卡的血统，
    /// 输入顺序 = 同一时刻的先后）产出保留评分行，按评分时刻稳定排序。
    ///
    /// `since`：调用方列卡之前的指纹 maxRowId；rowid 在它之后、却不属于任何一份血统的日志的卡 ID 作为
    /// 「漏掉的卡」返回（列卡之后新建的卡），调用方补上再来一次。
    ///
    /// `range` 选出哪些行：
    /// - `rebase_since = None`（全量）：全部行；
    /// - `rebase_since = Some(s)`（局部重放）：先在同一个快照里算**分歧时刻**——rowid 在 `s` 之后的日志
    ///   碰到的每份历史，比较「只看 rowid ≤ s 的日志」与「全部日志」两种情况下它的保留评分行，第一处
    ///   不同（时刻或行内容）的时刻取最小。只多了不改变任何行的日志时没有分歧。行从 `rows_from`
    ///   （给了的话）起、否则从分歧时刻起取（没有分歧就一行都不取）。调用方据此把 RWKV 状态退到这个
    ///   时刻之前，再追加取出的行，结果与全量回放逐位相同。
    ///
    /// 输出：`[i64 count, maxRowId, lastAt|NONE, n_rows, n_strays, divergeAt|NONE, tailRows]`、
    /// 行（80 字节 × n_rows）、评分时刻（i64 × n_rows）、标签（日志 ID 的 53 位数字 id，i64 × n_rows）、
    /// 漏掉的卡 ID 串表。`lastAt` 是全部保留评分（不只取出的行）里最晚的时刻；`tailRows` 是 rowid 在
    /// `rebase_since` 之后的日志行数（全量时 0），调用方用它核对期间没有删过日志。
    pub fn rwkv_replay(
        &self,
        profile: &str,
        groups: &[Vec<String>],
        ids: &[i64],
        day: &Day,
        since: i64,
        range: RwkvRange,
    ) -> Result<Vec<u8>, String> {
        if ids.len() != groups.len() * 4 {
            return Err("rwkv: id count differs from 4 × group count".into());
        }
        let rebase = range.rebase_since;
        let (groups, count, max_rowid, logs, rowids, strays, tail_rows, touched) = self.read_snapshot(|r| {
            let groups = expand_lineages(r, groups)?;
            let mut member: HashMap<String, Vec<usize>> = HashMap::new();
            for (g, lineage) in groups.iter().enumerate() {
                for c in lineage {
                    member.entry(c.clone()).or_default().push(g);
                }
            }
            let mut stmt = r
                .prepare_cached(
                    "SELECT l.rowid, srs_idt(l.card_id) AS card_id, l.json, e.server_time FROM srs_review_logs l \
                     LEFT JOIN srs_event_local e ON e.event_id = l.id WHERE l.profile_uid = srs_id(?1) ORDER BY l.rowid",
                )
                .map_err(|e| e.to_string())?;
            let mut q = stmt.query([profile]).map_err(|e| e.to_string())?;
            let mut count = 0i64;
            let mut max_rowid = 0i64;
            let mut logs: LogsByCard = HashMap::new();
            let mut rowids: HashMap<String, Vec<i64>> = HashMap::new();
            let mut strays: Vec<String> = Vec::new();
            let mut stray_seen: HashSet<String> = HashSet::new();
            let mut tail_rows = 0i64;
            let mut touched: HashSet<String> = HashSet::new();
            while let Some(row) = q.next().map_err(|e| e.to_string())? {
                let rowid: i64 = row.get(0).map_err(|e| e.to_string())?;
                let card: String = row.get(1).map_err(|e| e.to_string())?;
                count += 1;
                max_rowid = max_rowid.max(rowid);
                let in_tail = rebase.is_some_and(|s| rowid > s);
                if in_tail {
                    tail_rows += 1;
                }
                if !member.contains_key(card.as_str()) {
                    if rowid > since && stray_seen.insert(card.clone()) {
                        strays.push(card);
                    }
                    continue;
                }
                let json: String = row.get(2).map_err(|e| e.to_string())?;
                let st: Option<i64> = row.get(3).map_err(|e| e.to_string())?;
                if rebase.is_some() {
                    rowids.entry(card.clone()).or_default().push(rowid);
                    if in_tail {
                        touched.insert(card.clone());
                    }
                }
                logs.entry(card).or_default().push((json, st));
            }
            drop(q);
            Ok((groups, count, max_rowid, logs, rowids, strays, tail_rows, touched))
        })?;
        let diverge = match rebase {
            Some(s) => rwkv_divergence(&groups, &logs, &rowids, &touched, s, day)?,
            None => None,
        };
        // 取行的起点：全量 = 不设限；局部 = rows_from 或分歧时刻（没有分歧 = 一行不取）。
        let from = match (rebase, range.rows_from) {
            (_, Some(f)) => Some(f),
            (Some(_), None) => Some(diverge.unwrap_or(i64::MAX)),
            (None, None) => None,
        };
        // (时刻, 行, 标签)：按加入顺序收集，稳定排序。
        let mut entries: Vec<(i64, [u8; RWKV_ROW], i64)> = Vec::new();
        let mut last_at: Option<i64> = None;
        for (g, lineage) in groups.iter().enumerate() {
            let eff = effective_of(lineage, &logs)?;
            let card: RwkvIds = [ids[4 * g], ids[4 * g + 1], ids[4 * g + 2], ids[4 * g + 3]];
            let (rows, times, kept) = projection::rwkv_card_rows(&eff, &card, day)?;
            for (k, at) in times.into_iter().enumerate() {
                last_at = Some(last_at.map_or(at, |l| l.max(at)));
                if from.is_some_and(|f| at < f) {
                    continue;
                }
                let mut row = [0u8; RWKV_ROW];
                row.copy_from_slice(&rows[k * RWKV_ROW..(k + 1) * RWKV_ROW]);
                entries.push((at, row, crate::store::schema::anki_numeric_id(&eff[kept[k]].id)));
            }
        }
        entries.sort_by_key(|e| e.0);
        let mut out = Vec::with_capacity(56 + entries.len() * (RWKV_ROW + 16));
        push_i64(&mut out, count);
        push_i64(&mut out, max_rowid);
        push_i64(&mut out, last_at.unwrap_or(NONE_I64));
        push_i64(&mut out, entries.len() as i64);
        push_i64(&mut out, strays.len() as i64);
        push_i64(&mut out, diverge.unwrap_or(NONE_I64));
        push_i64(&mut out, tail_rows);
        for (_, row, _) in &entries {
            out.extend_from_slice(row);
        }
        entries.iter().for_each(|e| push_i64(&mut out, e.0));
        entries.iter().for_each(|e| push_i64(&mut out, e.2));
        push_strings(&mut out, strays.iter().map(String::as_str));
        Ok(out)
    }

    /// RWKV 对齐用的日志指纹与尾巴（同一个快照）：本 profile 的 (行数, 最大 rowid, rowid 在 `since` 之后的行数)；
    /// `with_rows` 时再给出这些新行（按发生时刻、rowid 排序）。
    ///
    /// `incremental`：只数 rowid 在 `since` 之后的行（`+profile_uid` 让 SQLite 走 rowid 范围，O(新增)），
    /// 行数 = 新增行数、最大 rowid = 新增里的最大（没有新增为 0）；调用方在已知的指纹上累加。
    ///
    /// 输出：`[i64 count, maxRowId, newRows, n]`、`at × n`、`kind × n`（1 review、2 undo、0 其它）、
    /// 串表（每行 ID、卡 ID、撤销目标（无则空串）三个一组）。
    pub fn rwkv_log_tail(
        &self,
        profile: &str,
        since: i64,
        with_rows: bool,
        incremental: bool,
    ) -> Result<Vec<u8>, String> {
        #[derive(serde::Deserialize)]
        struct Revokes<'a> {
            #[serde(default, borrow)]
            revokes: Option<std::borrow::Cow<'a, str>>,
        }
        let (count, max_rowid, new_rows, tail) = self.read_snapshot(|r| {
            let (count, max_rowid, new_rows): (i64, i64, i64) = if incremental {
                let (c, m): (i64, i64) = r
                    .query_row(
                        "SELECT COUNT(*), COALESCE(MAX(rowid), 0) FROM srs_review_logs \
                         WHERE rowid > ?2 AND +profile_uid = srs_id(?1)",
                        rusqlite::params![profile, since],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .map_err(|e| e.to_string())?;
                (c, m, c)
            } else {
                r.query_row(
                    "SELECT COUNT(*), COALESCE(MAX(rowid), 0), COALESCE(SUM(rowid > ?2), 0) \
                     FROM srs_review_logs WHERE profile_uid = srs_id(?1)",
                    rusqlite::params![profile, since],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .map_err(|e| e.to_string())?
            };
            let mut tail: Vec<(String, String, i64, i64, String)> = Vec::new();
            if with_rows {
                let mut stmt = r
                    .prepare_cached(
                        "SELECT srs_idt(id) AS id, srs_idt(card_id) AS card_id, kind, occurred_at, json FROM srs_review_logs \
                         WHERE rowid > ?2 AND +profile_uid = srs_id(?1) ORDER BY occurred_at, rowid",
                    )
                    .map_err(|e| e.to_string())?;
                let mut q = stmt.query(rusqlite::params![profile, since]).map_err(|e| e.to_string())?;
                while let Some(row) = q.next().map_err(|e| e.to_string())? {
                    let kind: String = row.get(2).map_err(|e| e.to_string())?;
                    let (code, revokes) = match kind.as_str() {
                        "review" => (1, String::new()),
                        "undo" => {
                            let json: String = row.get(4).map_err(|e| e.to_string())?;
                            let v: Revokes<'_> = serde_json::from_str(&json).map_err(|e| e.to_string())?;
                            (2, v.revokes.map(|c| c.into_owned()).unwrap_or_default())
                        }
                        _ => (0, String::new()),
                    };
                    tail.push((
                        row.get(0).map_err(|e| e.to_string())?,
                        row.get(1).map_err(|e| e.to_string())?,
                        code,
                        row.get(3).map_err(|e| e.to_string())?,
                        revokes,
                    ));
                }
            }
            Ok((count, max_rowid, new_rows, tail))
        })?;
        let mut out = Vec::with_capacity(32 + tail.len() * 56);
        push_i64(&mut out, count);
        push_i64(&mut out, max_rowid);
        push_i64(&mut out, new_rows);
        push_i64(&mut out, tail.len() as i64);
        tail.iter().for_each(|t| push_i64(&mut out, t.3));
        tail.iter().for_each(|t| push_i64(&mut out, t.2));
        push_strings(&mut out, tail.iter().flat_map(|t| [t.0.as_str(), t.1.as_str(), t.4.as_str()]));
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::types::Value;

    fn core(name: &str) -> SrsCore {
        let dir = std::env::temp_dir().join(format!("ffsrs_p6_{name}_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("srs.db");
        let _ = std::fs::remove_file(&p);
        let c = SrsCore::open(&p).unwrap();
        c.legacy_mark_none().unwrap();
        c
    }

    fn insert(c: &SrsCore, id: &str, card: &str, kind: &str, at: i64, json: &str) {
        c.exec(
            "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, jslim) \
             VALUES (srs_id(?1), 'p', srs_id(?2), ?3, NULL, ?4, 'r', 'fushi', 0, ?5)",
            &[
                Value::Text(id.into()),
                Value::Text(card.into()),
                Value::Text(kind.into()),
                Value::Integer(at),
                Value::Text(json.into()),
            ],
            false,
        )
        .unwrap();
    }

    fn log(id: &str, card: &str, phys: i64, at: i64, rest: &str) -> String {
        format!(r#"{{"id":"{id}","p":"p","card":"{card}","kind":"review","hlc":"{phys}:0:A","at":{at},"ts":"anchored"{rest}}}"#)
    }

    fn i64_at(b: &[u8], k: usize) -> i64 {
        i64::from_le_bytes(b[8 * k..8 * k + 8].try_into().unwrap())
    }

    const D: Day = Day { utc_offset_min: 0, rollover_hour: 0 };

    #[test]
    fn optimizer_items_read_the_lineage_and_sort_by_time() {
        let c = core("opt");
        insert(&c, "a1", "pred", "review", 0, &log("a1", "pred", 1, 0, r#","rtype":"learn","rating":3"#));
        insert(&c, "a2", "c1", "review", 86_400_000, &log("a2", "c1", 2, 86_400_000, r#","rtype":"review","rating":3"#));
        insert(&c, "b1", "c2", "review", 1000, &log("b1", "c2", 1, 1000, r#","rtype":"learn","rating":1"#));
        insert(&c, "b2", "c2", "review", 2000, &log("b2", "c2", 2, 2000, r#","rtype":"learn","rating":3"#));
        let out = c
            .optimizer_items(&[vec!["c1".into(), "pred".into()], vec!["c2".into()]], &[11, 22], Alg::Fsrs7, &D)
            .unwrap();
        assert_eq!((i64_at(&out, 0), i64_at(&out, 1), i64_at(&out, 2)), (2, 4, 2));
        // seq_start [0, 2, 4], seq_card [11, 22]
        assert_eq!((i64_at(&out, 3), i64_at(&out, 4), i64_at(&out, 5)), (0, 2, 4));
        assert_eq!((i64_at(&out, 6), i64_at(&out, 7)), (11, 22));
        // items: c2 第二次评分（2000）在 c1 第二次评分（1 天）之前。
        let items = 8 + 4 + 4;
        assert_eq!((i64_at(&out, items), i64_at(&out, items + 1)), (1, 2));
        assert_eq!((i64_at(&out, items + 2), i64_at(&out, items + 3)), (0, 2));
    }

    #[test]
    fn rwkv_replay_fingerprint_matches_the_scan_and_reports_strays() {
        let c = core("rwkv");
        insert(&c, "a1", "c1", "review", 0, &log("a1", "c1", 1, 5000, r#","rtype":"learn","rating":3"#));
        insert(&c, "z1", "c9", "review", 0, &log("z1", "c9", 1, 0, r#","rtype":"learn","rating":3"#));
        insert(&c, "b1", "c2", "review", 0, &log("b1", "c2", 1, 1000, r#","rtype":"learn","rating":4"#));
        let out = c
            .rwkv_replay("p", &[vec!["c1".into()], vec!["c2".into()]], &[1, 2, 3, 4, 5, 6, 7, 8], &D, 1, RwkvRange::default())
            .unwrap();
        assert_eq!((i64_at(&out, 0), i64_at(&out, 1)), (3, 3));
        assert_eq!(i64_at(&out, 2), 5000, "lastAt = latest kept rating");
        assert_eq!((i64_at(&out, 3), i64_at(&out, 4)), (2, 1));
        assert_eq!((i64_at(&out, 5), i64_at(&out, 6)), (NONE_I64, 0), "full replay: no divergence");
        // 按时刻排序：c2（1000）在 c1（5000）前面。
        let rows = 7;
        assert_eq!(i64_at(&out, rows), 5);
        assert_eq!(i64_at(&out, rows + 10), 1);
        let at = 56 + 2 * RWKV_ROW;
        assert_eq!((i64_at(&out, at / 8), i64_at(&out, at / 8 + 1)), (1000, 5000), "rating times");
        let tags = at / 8 + 2;
        assert_eq!(i64_at(&out, tags), crate::store::schema::anki_numeric_id("b1"), "tag = numeric id of the log");
        let strs = at + 4 * 8;
        assert_eq!(&out[strs + 8..], b"c9");
        let tail = c.rwkv_log_tail("p", 1, true, false).unwrap();
        assert_eq!((i64_at(&tail, 0), i64_at(&tail, 1), i64_at(&tail, 2), i64_at(&tail, 3)), (3, 3, 2, 2));
    }

    /// 局部重放：分歧时刻 = 新日志改动的最早一行的时刻；行从那里起取，标签与时刻成对。
    #[test]
    fn rwkv_rebase_finds_the_earliest_changed_row_and_returns_the_rows_from_it() {
        let c = core("rebase");
        let ids = [1, 2, 3, 4, 5, 6, 7, 8];
        let groups = [vec!["c1".to_string()], vec!["c2".to_string()]];
        insert(&c, "a1", "c1", "review", 1000, &log("a1", "c1", 1, 1000, r#","rtype":"learn","rating":3"#));
        insert(&c, "a2", "c1", "review", 9000, &log("a2", "c1", 2, 9000, r#","rtype":"learn","rating":3"#));
        insert(&c, "b1", "c2", "review", 5000, &log("b1", "c2", 3, 5000, r#","rtype":"learn","rating":4"#));
        let base = 3;
        // 晚到的评分：时刻 3000，落在已回放的 a2（9000）与 b1（5000）之前。
        insert(&c, "b0", "c2", "review", 3000, &log("b0", "c2", 4, 3000, r#","rtype":"learn","rating":1"#));
        let range = RwkvRange { rebase_since: Some(base), rows_from: None };
        let out = c.rwkv_replay("p", &groups, &ids, &D, base, range).unwrap();
        assert_eq!(i64_at(&out, 5), 3000, "divergence = the late rating");
        assert_eq!(i64_at(&out, 6), 1, "one log after the base");
        assert_eq!(i64_at(&out, 2), 9000, "lastAt over every kept rating");
        assert_eq!(i64_at(&out, 3), 3, "b0, b1, a2 are at >= 3000");
        let at = (56 + 3 * RWKV_ROW) / 8;
        assert_eq!((i64_at(&out, at), i64_at(&out, at + 1), i64_at(&out, at + 2)), (3000, 5000, 9000));
        let num = crate::store::schema::anki_numeric_id;
        assert_eq!((i64_at(&out, at + 3), i64_at(&out, at + 5)), (num("b0"), num("a2")));
        // 这些行就是全量回放里时刻 ≥ 3000 的那几行（含 b1 因前面多了 b0 而改变的间隔）。
        let full = c.rwkv_replay("p", &groups, &ids, &D, base, RwkvRange::default()).unwrap();
        let rows = |b: &[u8], n: usize, skip: usize| b[56 + skip * RWKV_ROW..56 + (skip + n) * RWKV_ROW].to_vec();
        assert_eq!(i64_at(&full, 3), 4);
        assert_eq!(rows(&out, 3, 0), rows(&full, 3, 1));

        // 指定起点（从检查点重来）：rows_from 优先，分歧照样报出来。
        let range = RwkvRange { rebase_since: Some(base), rows_from: Some(5001) };
        let out = c.rwkv_replay("p", &groups, &ids, &D, base, range).unwrap();
        assert_eq!((i64_at(&out, 5), i64_at(&out, 3)), (3000, 1), "only a2 at >= 5001");

        // 撤销一条更早的评分：分歧在被撤的那条。
        let undo = r#"{"id":"u1","p":"p","card":"c1","kind":"undo","hlc":"5:0:A","at":9500,"ts":"anchored","revokes":"a1"}"#;
        insert(&c, "u1", "c1", "undo", 9500, undo);
        let range = RwkvRange { rebase_since: Some(4), rows_from: None };
        let out = c.rwkv_replay("p", &groups, &ids, &D, 4, range).unwrap();
        assert_eq!(i64_at(&out, 5), 1000, "divergence = the revoked rating");

        // 只多了不改变行的日志：没有分歧，一行不取。
        insert(&c, "s1", "c1", "suspend", 9600, r#"{"id":"s1","p":"p","card":"c1","kind":"suspend","hlc":"6:0:A","at":9600,"ts":"anchored"}"#);
        let range = RwkvRange { rebase_since: Some(5), rows_from: None };
        let out = c.rwkv_replay("p", &groups, &ids, &D, 5, range).unwrap();
        assert_eq!((i64_at(&out, 5), i64_at(&out, 3), i64_at(&out, 6)), (NONE_I64, 0, 1));
    }

    #[test]
    fn rwkv_log_tail_reports_kind_and_revokes_and_counts_incrementally() {
        let c = core("tail");
        insert(&c, "a1", "c1", "review", 10, &log("a1", "c1", 1, 10, r#","rtype":"learn","rating":3"#));
        insert(&c, "b1", "c1", "review", 20, &log("b1", "c1", 2, 20, r#","rtype":"review","rating":4"#));
        let undo = r#"{"id":"u1","p":"p","card":"c1","kind":"undo","hlc":"3:0:A","at":30,"ts":"anchored","revokes":"b1"}"#;
        insert(&c, "u1", "c1", "undo", 30, undo);
        insert(&c, "s1", "c1", "suspend", 40, r#"{"id":"s1","kind":"suspend"}"#);
        let t = c.rwkv_log_tail("p", 1, true, false).unwrap();
        assert_eq!((i64_at(&t, 0), i64_at(&t, 1), i64_at(&t, 2), i64_at(&t, 3)), (4, 4, 3, 3));
        assert_eq!((i64_at(&t, 4), i64_at(&t, 5), i64_at(&t, 6)), (20, 30, 40), "at");
        assert_eq!((i64_at(&t, 7), i64_at(&t, 8), i64_at(&t, 9)), (1, 2, 0), "kind");
        // 串表：9 个串（每行 ID、卡、撤销目标）。
        let strs = 8 * 10;
        let off = |k: usize| u32::from_le_bytes(t[strs + 4 * k..strs + 4 * k + 4].try_into().unwrap()) as usize;
        let body = strs + 4 * 10;
        let s = |k: usize| std::str::from_utf8(&t[body + off(k)..body + off(k + 1)]).unwrap();
        assert_eq!((s(3), s(4), s(5)), ("u1", "c1", "b1"));
        assert_eq!(s(2), "", "评分没有撤销目标");
        let inc = c.rwkv_log_tail("p", 2, false, true).unwrap();
        assert_eq!((i64_at(&inc, 0), i64_at(&inc, 1), i64_at(&inc, 2)), (2, 4, 2), "只数 rowid 2 之后");
        let none = c.rwkv_log_tail("p", 4, false, true).unwrap();
        assert_eq!((i64_at(&none, 0), i64_at(&none, 1)), (0, 0));
    }
}
