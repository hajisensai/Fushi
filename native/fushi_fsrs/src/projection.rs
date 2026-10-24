//! 卡片历史的投影（P6，docs/specs/2026-10-23-srs-rust-store.md §7）：记忆状态输入（铁律 A）、优化器训练集、
//! RWKV 回放行。规则只在这里写一份；store/mod.rs 的直读命令在 srs.db 上取日志后调用它们，排程（Dart
//! `SrsCardOps`）经列模式入口 [memory_input_columns] 调用同一份记忆状态规则。
//!
//! 与删除前的 Dart 实现逐条对应（固定向量 packages/fushi_srs/test/memory/fixtures/ 与
//! packages/fushi_engine/test/srs/fixtures/p6_vectors.json.gz 由删除前的 Dart 实现生成）：
//! - 日界（`SrsDayContext.dayIndexOf`）：本地毫秒 = ms + utcOffsetMin·60000 − rolloverHour·3600000，向下取整到天；
//! - elapsed（`srsElapsedDays`）：FSRS-7 / RWKV 小数天，FSRS-6 翻日后的日序号差；
//! - 记忆状态输入（`srsCollectMemoryInput`）：最近一次重置之后的有效评分；第一条是学习类 = 历史完整；
//!   恢复照抄 / 导入锚点为起点（同算法的记忆状态直接用，否则 SM-2 换算）；
//! - RWKV 保留评分（`srsRwkvKeptRatings`）、card_type 与间隔（`srs_rwkv_history.dart`），行布局同
//!   packages/fushi_rwkv 的 `RwkvRows`（80 字节小端；本 crate 不链接 RWKV，只产出字节）。

use serde_json::value::RawValue;

use crate::history::{Extra, Kind, Log, Outcome, Parsed, RType, NONE_I64};

pub const DAY_MS: i64 = 86_400_000;

/// 统计 / 排程的日界（`SrsDayContext`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Day {
    pub utc_offset_min: i64,
    pub rollover_hour: i64,
}

impl Day {
    /// 某一时刻属于哪个日历日（已扣掉翻日时刻）。
    pub fn index(&self, ms: i64) -> i64 {
        let local = ms
            .wrapping_add(self.utc_offset_min.wrapping_mul(60_000))
            .wrapping_sub(self.rollover_hour.wrapping_mul(3_600_000));
        local.div_euclid(DAY_MS)
    }
}

/// 记忆状态用的算法（`SrsAlgorithm` 的 wire 值；与日志 `extra['memAlg']` 比较）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Alg {
    Fsrs6 = 0,
    Fsrs7 = 1,
    Rwkv = 2,
}

impl Alg {
    pub fn from_code(code: i64) -> Result<Self, String> {
        match code {
            0 => Ok(Alg::Fsrs6),
            1 => Ok(Alg::Fsrs7),
            2 => Ok(Alg::Rwkv),
            _ => Err(format!("unknown algorithm code {code}")),
        }
    }
}

/// 日志 `extra['memAlg']`：缺失 / null、某个算法名、别的字符串，或不是字符串（用到时才判坏数据）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemAlg {
    Absent,
    Is(Alg),
    Other,
    Bad,
}

impl MemAlg {
    fn of(raw: Option<&RawValue>) -> Self {
        let Some(raw) = raw else { return MemAlg::Absent };
        match serde_json::from_str::<String>(raw.get()) {
            Ok(s) => match s.as_str() {
                "fsrs6" => MemAlg::Is(Alg::Fsrs6),
                "fsrs7" => MemAlg::Is(Alg::Fsrs7),
                "rwkv" => MemAlg::Is(Alg::Rwkv),
                _ => MemAlg::Other,
            },
            Err(_) => MemAlg::Bad,
        }
    }

    pub fn code(self) -> i64 {
        match self {
            MemAlg::Absent => -1,
            MemAlg::Is(a) => a as i64,
            MemAlg::Other => 3,
            MemAlg::Bad => 4,
        }
    }

    pub fn from_code(code: i64) -> Self {
        match code {
            0 => MemAlg::Is(Alg::Fsrs6),
            1 => MemAlg::Is(Alg::Fsrs7),
            2 => MemAlg::Is(Alg::Rwkv),
            3 => MemAlg::Other,
            4 => MemAlg::Bad,
            _ => MemAlg::Absent,
        }
    }
}

/// 投影规则要的一条**有效**日志（按排序键升序排好）。
#[derive(Debug, Clone)]
pub struct EffLog {
    pub id: String,
    pub kind: Kind,
    pub rtype: RType,
    pub rating: Option<i64>,
    pub at: i64,
    pub dur: i64,
    pub res: Option<Outcome>,
    pub mem_alg: MemAlg,
    pub restore: bool,
    /// 墙钟来源且排序键被钳位（优化器的「时间不确定」）。
    pub time_uncertain: bool,
    pub utc_off: i64,
    /// 日志 `alg` 是 rwkv。
    pub alg_rwkv: bool,
}

impl EffLog {
    pub fn of(log: &Log<'_>, res: &Option<Outcome>, extra: &Extra<'_>, clamped: bool) -> Self {
        EffLog {
            id: log.id.clone().into_owned(),
            kind: log.kind,
            rtype: extra.rtype,
            rating: log.rating,
            at: log.occurred_at,
            dur: extra.dur,
            res: res.clone(),
            mem_alg: MemAlg::of(extra.mem_alg),
            restore: extra.restore,
            time_uncertain: extra.ts_wall && clamped,
            utc_off: extra.utc_off,
            alg_rwkv: extra.alg_rwkv,
        }
    }

    /// `SrsReviewLog.isRatingReview && rating != null`。
    pub fn is_rating(&self) -> bool {
        self.kind == Kind::Review && self.rtype.is_rating() && self.rating.is_some()
    }

    /// `srsIsReset`：manual 且结果是新卡、reps 归零。
    fn is_reset(&self) -> bool {
        self.kind == Kind::Manual
            && self.res.as_ref().is_some_and(|r| r.queue == 0 && r.reps == 0)
    }

    /// `srsIsRestoreState`：「恢复到备份时间点」照抄状态的 manual 日志。
    fn is_restore_state(&self) -> bool {
        self.kind == Kind::Manual && self.res.is_some() && self.restore && !self.is_reset()
    }
}

/// 一份历史的有效日志（排序后），供投影用。
pub fn effective_logs(parsed: &[Parsed<'_>]) -> Vec<EffLog> {
    let logs: Vec<Log<'_>> = parsed.iter().map(|p| p.0.clone()).collect();
    let sel = crate::history::select(&logs);
    let mut out = Vec::with_capacity(sel.order.len());
    for (k, &i) in sel.order.iter().enumerate() {
        let s = sel.status[k];
        if s & crate::history::STATUS_EFFECTIVE != 0 {
            let (log, res, extra) = &parsed[i];
            out.push(EffLog::of(log, res, extra, s & crate::history::STATUS_CLAMPED != 0));
        }
    }
    out
}

/// 交给 FSRS 的记忆状态输入（Dart `SrsMemoryInput`）。
#[derive(Debug, Clone, PartialEq)]
pub struct MemoryInput {
    /// (rating, deltaDays)。
    pub reviews: Vec<(i64, f64)>,
    /// 锚点自带、可直接用的起点 (s, d, sf)。
    pub starting: Option<(f64, f64, f64)>,
    /// 需要 SM-2 换算的起点 (ease 小数, 间隔天数)。
    pub sm2: Option<(f64, f64)>,
    pub complete: bool,
}

/// 两次评分之间的 elapsed（天，`srsElapsedDays`）。
pub fn elapsed_days(alg: Alg, from_ms: i64, to_ms: i64, day: &Day) -> f64 {
    if to_ms <= from_ms {
        return 0.0;
    }
    match alg {
        Alg::Fsrs7 | Alg::Rwkv => (to_ms - from_ms) as f64 / DAY_MS as f64,
        Alg::Fsrs6 => (day.index(to_ms) - day.index(from_ms)) as f64,
    }
}

fn to_reviews(rs: &[&EffLog], previous: Option<i64>, alg: Alg, day: &Day) -> Vec<(i64, f64)> {
    let mut out = Vec::with_capacity(rs.len());
    let mut prev = previous;
    for r in rs {
        let delta = match prev {
            None => 0.0,
            Some(p) => elapsed_days(alg, p, r.at, day),
        };
        out.push((r.rating.expect("rating review"), delta));
        prev = Some(r.at);
    }
    out
}

fn from_anchor(anchor: &EffLog, after: &[&EffLog], alg: Alg, day: &Day) -> Result<MemoryInput, String> {
    let (since, mem, ease, ivl) = match &anchor.res {
        Some(r) => (r.last_reviewed_at.unwrap_or(anchor.at), r.memory, r.ease, r.scheduled_days),
        None => (anchor.at, None, None, 0),
    };
    let reviews = to_reviews(after, Some(since), alg, day);
    // Dart `anchor.extra['memAlg'] as String?`：在这里才转换，不是字符串即坏数据。
    let anchor_alg = match anchor.mem_alg {
        MemAlg::Bad => return Err("bad review log: memAlg is not a string".into()),
        m => m,
    };
    if let Some(m) = mem {
        if anchor_alg == MemAlg::Is(alg) {
            return Ok(MemoryInput { reviews, starting: Some(m), sm2: None, complete: false });
        }
    }
    let ease = ease.unwrap_or(2500) as f64 / 1000.0;
    let ivl = if ivl <= 0 { 1.0 } else { ivl as f64 };
    Ok(MemoryInput { reviews, starting: None, sm2: Some((ease, ivl)), complete: false })
}

/// 收集 S/D 的输入（铁律 A ①～③，`srsCollectMemoryInput`）。[eff] 是排序后的有效日志。
pub fn memory_input(eff: &[EffLog], alg: Alg, day: &Day) -> Result<MemoryInput, String> {
    let start = eff.iter().rposition(EffLog::is_reset).map_or(0, |i| i + 1);
    let window = &eff[start..];
    // 评分在窗口里的下标（「在锚点之后」按排序位置比）。
    let ratings: Vec<usize> = (0..window.len()).filter(|&i| window[i].is_rating()).collect();
    let pick = |from: Option<usize>| -> Vec<&EffLog> {
        ratings
            .iter()
            .filter(|&&i| from.is_none_or(|f| i > f))
            .map(|&i| &window[i])
            .collect()
    };
    // ③′ 恢复照抄的状态。
    if let Some(i) = window.iter().rposition(EffLog::is_restore_state) {
        return from_anchor(&window[i], &pick(Some(i)), alg, day);
    }
    let last_anchor = window.iter().rposition(|l| l.kind == Kind::ImportAnchor);
    if ratings.is_empty() {
        return match last_anchor {
            None => Ok(MemoryInput { reviews: Vec::new(), starting: None, sm2: None, complete: true }),
            Some(a) => from_anchor(&window[a], &[], alg, day),
        };
    }
    if window[ratings[0]].rtype == RType::Learn {
        return Ok(MemoryInput {
            reviews: to_reviews(&pick(None), None, alg, day),
            starting: None,
            sm2: None,
            complete: true,
        });
    }
    match last_anchor {
        None => Ok(MemoryInput {
            reviews: to_reviews(&pick(None), None, alg, day),
            starting: None,
            sm2: None,
            complete: false,
        }),
        Some(a) => from_anchor(&window[a], &pick(Some(a)), alg, day),
    }
}

// ---------------------------------------------------------------- 优化器训练集

/// 一张卡进训练集的条目：(评分时刻, 前缀长度)，以及它的完整评审序列。不进训练集 = None。
///
/// 规则同删除前的 `srsPrepareOptimization` 循环：历史完整且非空；有效评分里去掉「时间不确定」的之后，
/// 条数必须与记忆状态输入的评审条数相同（有可证明时间错误的日志、或重置之前还有评分，整卡不进）。
pub fn optimizer_card(eff: &[EffLog], alg: Alg, day: &Day) -> Result<Option<(Vec<(i64, f64)>, Vec<(i64, usize)>)>, String> {
    let input = memory_input(eff, alg, day)?;
    if !input.complete || input.reviews.is_empty() {
        return Ok(None);
    }
    let ratings: Vec<&EffLog> = eff.iter().filter(|l| l.is_rating() && !l.time_uncertain).collect();
    if ratings.len() != input.reviews.len() {
        return Ok(None);
    }
    let items = (1..input.reviews.len()).map(|i| (ratings[i].at, i + 1)).collect();
    Ok(Some((input.reviews, items)))
}

// ---------------------------------------------------------------- RWKV 回放行

/// `FrwkvReview` 的大小（packages/fushi_rwkv `kFrwkvReviewSize`）。
pub const RWKV_ROW: usize = 80;

const PRESENT_NOTE: u32 = 1;
const PRESENT_DECK: u32 = 1 << 1;
const PRESENT_PRESET: u32 = 1 << 2;
const PRESENT_DURATION: u32 = 1 << 3;
const PRESENT_CARD_TYPE: u32 = 1 << 4;
const PRESENT_DAY_OFFSET: u32 = 1 << 5;
const PRESENT_ELAPSED_DAYS: u32 = 1 << 6;
const PRESENT_ELAPSED_SECONDS: u32 = 1 << 7;

/// 回放保留下来的评分（`srsRwkvKeptRatings`）：重置之后的有效评分，只留最近一次学习序列。下标指向 [eff]。
pub fn rwkv_kept(eff: &[EffLog]) -> Vec<usize> {
    let start = eff.iter().rposition(EffLog::is_reset).map_or(0, |i| i + 1);
    let ratings: Vec<usize> = (start..eff.len()).filter(|&i| eff[i].is_rating()).collect();
    let mut from = 0;
    for i in (1..ratings.len()).rev() {
        if eff[ratings[i]].rtype == RType::Learn && eff[ratings[i - 1]].rtype != RType::Learn {
            from = i;
            break;
        }
    }
    ratings[from..].to_vec()
}

fn type_of(r: RType) -> i64 {
    match r {
        RType::Learn => 1,
        RType::Review => 2,
        RType::Relearn => 3,
        _ => 4,
    }
}

/// 上一条是 review+Again 或 relearn+Again/Hard：同日再次复习的 review 卡算重学（card_type 3）。
fn relearning(rtype: RType, rating: i64) -> bool {
    (rtype == RType::Review && rating == 1) || (rtype == RType::Relearn && (rating == 1 || rating == 2))
}

/// 第 i 条保留评分的 card_type（上游 RwkvReviewState）。
fn card_type(kept: &[&EffLog], i: usize, day: &Day) -> i64 {
    let log = kept[i];
    if i == 0 {
        return if log.rtype == RType::Learn { 0 } else { type_of(log.rtype) };
    }
    let prev = kept[i - 1];
    if log.rtype == RType::Review && day.index(log.at) == day.index(prev.at) {
        return if relearning(prev.rtype, prev.rating.unwrap_or(0)) { 3 } else { 4 };
    }
    type_of(log.rtype)
}

/// 卡 / 笔记 / 牌组 / 预设的 53 位数字 id。
pub type RwkvIds = [i64; 4];

/// 追加一行（`RwkvRows.add`，按 `_addRow` 的规则算 day_offset 与间隔）。
#[allow(clippy::too_many_arguments)]
pub fn push_rwkv_row(
    out: &mut Vec<u8>,
    ids: &RwkvIds,
    ease: i64,
    at: i64,
    previous_at: Option<i64>,
    card_type: i64,
    duration_ms: Option<i64>,
    day: &Day,
) -> Result<(), String> {
    if !(0..=4).contains(&ease) {
        return Err(format!("rwkv ease {ease} must be 0..4"));
    }
    let today = day.index(at);
    let duration = duration_ms.filter(|&d| d > 0);
    let (elapsed_days, elapsed_seconds) = match previous_at {
        None => (-1, -1),
        Some(p) => (
            (today - day.index(p)).clamp(0, 1 << 40),
            ((at.wrapping_sub(p)) / 1000).clamp(0, 1 << 50),
        ),
    };
    let mut present = PRESENT_NOTE
        | PRESENT_DECK
        | PRESENT_PRESET
        | PRESENT_CARD_TYPE
        | PRESENT_DAY_OFFSET
        | PRESENT_ELAPSED_DAYS
        | PRESENT_ELAPSED_SECONDS;
    if duration.is_some() {
        present |= PRESENT_DURATION;
    }
    for v in [
        ids[0],
        ids[1],
        ids[2],
        ids[3],
        duration.unwrap_or(0),
        card_type,
        today,
        elapsed_days,
        elapsed_seconds,
    ] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&present.to_le_bytes());
    out.extend_from_slice(&[ease as u8, 0, 0, 0]);
    Ok(())
}

/// 一张卡的保留评分行（时间顺序 = 排序键顺序），连同每行的评分时刻与保留评分在 [eff] 里的下标。
pub fn rwkv_card_rows(eff: &[EffLog], ids: &RwkvIds, day: &Day) -> Result<(Vec<u8>, Vec<i64>, Vec<usize>), String> {
    let kept_idx = rwkv_kept(eff);
    let kept: Vec<&EffLog> = kept_idx.iter().map(|&i| &eff[i]).collect();
    let mut rows = Vec::with_capacity(kept.len() * RWKV_ROW);
    let mut times = Vec::with_capacity(kept.len());
    for i in 0..kept.len() {
        let log = kept[i];
        push_rwkv_row(
            &mut rows,
            ids,
            log.rating.expect("kept rating"),
            log.at,
            (i > 0).then(|| kept[i - 1].at),
            card_type(&kept, i, day),
            Some(log.dur),
            day,
        )?;
        times.push(log.at);
    }
    Ok((rows, times, kept_idx))
}

/// 最后一条保留评分的摘要（`SrsRwkvLastRating`）：(时刻, 评分, reviewType)。
pub type LastRating = (i64, i64, RType);

/// 「这张卡此刻」的行（`srsRwkvAddNowRow`）：ease 0；[queue] 是卡当前所在队列（0 new … 3 relearning）。
pub fn push_rwkv_now_row(
    out: &mut Vec<u8>,
    ids: &RwkvIds,
    last: Option<LastRating>,
    queue: i64,
    now_ms: i64,
    day: &Day,
) -> Result<(), String> {
    let review_type = match queue {
        2 => RType::Review,
        3 => RType::Relearn,
        _ => RType::Learn,
    };
    let fresh = last.is_none() || queue == 0;
    let card_type = match last {
        _ if fresh => 0,
        Some((at, rating, rtype)) if review_type == RType::Review && day.index(now_ms) == day.index(at) => {
            if relearning(rtype, rating) {
                3
            } else {
                4
            }
        }
        _ => type_of(review_type),
    };
    let previous = if fresh { None } else { last.map(|l| l.0) };
    push_rwkv_row(out, ids, 0, now_ms, previous, card_type, None, day)
}

// ---------------------------------------------------------------- 列模式入口（排程用）

/// 列模式每条有效日志占几个 i64：`[kind, rtype, rating, at, flags, queue, ivl, reps, lastReviewedAt,
/// ease, s, d, sf, memAlg]`，可空列用 [NONE_I64]；flags：1 有结果、2 有记忆状态、4 恢复标记；s/d/sf 是 f64 位。
pub const MEMORY_COLUMN_WORDS: usize = 14;

/// 列模式：一份历史的有效日志（Dart `SrsCardHistory.effective`，已排序）→ 记忆状态输入。
pub fn memory_input_columns(ints: &[i64], alg: Alg, day: &Day) -> Result<MemoryInput, String> {
    if ints.len() % MEMORY_COLUMN_WORDS != 0 {
        return Err("bad memory input layout".into());
    }
    let opt = |v: i64| (v != NONE_I64).then_some(v);
    let eff: Vec<EffLog> = ints
        .chunks_exact(MEMORY_COLUMN_WORDS)
        .map(|c| {
            let flags = c[4];
            EffLog {
                id: String::new(),
                kind: Kind::from_code(c[0]),
                rtype: RType::from_code(c[1]),
                rating: opt(c[2]),
                at: c[3],
                dur: 0,
                res: (flags & 1 != 0).then(|| Outcome {
                    queue: c[5],
                    due_day: None,
                    scheduled_days: c[6],
                    reps: c[7],
                    last_reviewed_at: opt(c[8]),
                    ease: opt(c[9]),
                    memory: (flags & 2 != 0).then(|| {
                        (f64::from_bits(c[10] as u64), f64::from_bits(c[11] as u64), f64::from_bits(c[12] as u64))
                    }),
                }),
                mem_alg: MemAlg::from_code(c[13]),
                restore: flags & 4 != 0,
                time_uncertain: false,
                utc_off: 0,
                alg_rwkv: false,
            }
        })
        .collect();
    memory_input(&eff, alg, day)
}


/// [MemoryInput] 的输出布局（小端）：`[i64 flags][i64 n][f64 × 5: s, d, sf, ease, ivl][i64 rating × n][f64 delta × n]`，
/// flags：1 complete、2 有 starting、4 有 sm2。
pub fn encode_memory_input(m: &MemoryInput) -> Vec<u8> {
    let mut out = Vec::with_capacity(56 + m.reviews.len() * 16);
    let flags = i64::from(m.complete) | if m.starting.is_some() { 2 } else { 0 } | if m.sm2.is_some() { 4 } else { 0 };
    out.extend_from_slice(&flags.to_le_bytes());
    out.extend_from_slice(&(m.reviews.len() as i64).to_le_bytes());
    let (s, d, sf) = m.starting.unwrap_or((0.0, 0.0, 0.0));
    let (ease, ivl) = m.sm2.unwrap_or((0.0, 0.0));
    for v in [s, d, sf, ease, ivl] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    for (r, _) in &m.reviews {
        out.extend_from_slice(&r.to_le_bytes());
    }
    for (_, delta) in &m.reviews {
        out.extend_from_slice(&delta.to_le_bytes());
    }
    out
}

/// 「此刻」行的列模式：每行 `[card, note, deck, preset, lastAt, lastRating, lastRType, queue, now]`
/// （lastAt = [NONE_I64] 表示没有保留评分）。
pub const NOW_ROW_WORDS: usize = 9;

pub fn rwkv_now_rows(ints: &[i64], day: &Day) -> Result<Vec<u8>, String> {
    if ints.len() % NOW_ROW_WORDS != 0 {
        return Err("bad rwkv now-row layout".into());
    }
    let mut out = Vec::with_capacity(ints.len() / NOW_ROW_WORDS * RWKV_ROW);
    for c in ints.chunks_exact(NOW_ROW_WORDS) {
        let last = (c[4] != NONE_I64).then(|| (c[4], c[5], RType::from_code(c[6])));
        push_rwkv_now_row(&mut out, &[c[0], c[1], c[2], c[3]], last, c[7], c[8], day)?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::parse_full;

    fn wire(id: &str, kind: &str, phys: i64, at: i64, extra: &str) -> String {
        format!(r#"{{"id":"{id}","p":"p","card":"c","kind":"{kind}","hlc":"{phys}:0:A","at":{at},"ts":"anchored"{extra}}}"#)
    }

    fn eff(jsons: &[String]) -> Vec<EffLog> {
        let parsed: Vec<_> = jsons.iter().map(|j| parse_full(j, None).unwrap()).collect();
        effective_logs(&parsed)
    }

    const D: Day = Day { utc_offset_min: 0, rollover_hour: 4 };

    #[test]
    fn day_index_floors_before_rollover() {
        assert_eq!(D.index(4 * 3_600_000), 0);
        assert_eq!(D.index(4 * 3_600_000 - 1), -1);
        let jst = Day { utc_offset_min: 540, rollover_hour: 4 };
        assert_eq!(jst.index(0), 0);
        assert_eq!(jst.index(-5 * 3_600_000 - 1), -1);
    }

    #[test]
    fn complete_history_starts_at_learn_and_fsrs6_counts_days() {
        let h = eff(&[
            wire("a", "review", 1, 0, r#","rtype":"learn","rating":3,"res":{"queue":"review"}"#),
            wire("b", "review", 2, DAY_MS * 3 / 2, r#","rtype":"review","rating":3,"res":{"queue":"review"}"#),
        ]);
        let seven = memory_input(&h, Alg::Fsrs7, &D).unwrap();
        assert!(seven.complete);
        assert_eq!(seven.reviews, vec![(3, 0.0), (3, 1.5)]);
        let six = memory_input(&h, Alg::Fsrs6, &D).unwrap();
        assert_eq!(six.reviews[1].1, (D.index(DAY_MS * 3 / 2) - D.index(0)) as f64);
        let (reviews, items) = optimizer_card(&h, Alg::Fsrs7, &D).unwrap().unwrap();
        assert_eq!(reviews.len(), 2);
        assert_eq!(items, vec![(DAY_MS * 3 / 2, 2)]);
    }

    #[test]
    fn anchor_without_same_algorithm_memory_uses_sm2() {
        let h = eff(&[
            wire("a", "importAnchor", 1, 0, r#","res":{"queue":"review","ivl":20,"lastReviewedAt":-1728000000,"ease":2300}"#),
            wire("b", "review", 2, 5 * DAY_MS, r#","rtype":"review","rating":3"#),
        ]);
        let m = memory_input(&h, Alg::Fsrs7, &D).unwrap();
        assert!(!m.complete);
        assert_eq!(m.sm2, Some((2.3, 20.0)));
        assert_eq!(m.reviews, vec![(3, 25.0)]);
        assert!(optimizer_card(&h, Alg::Fsrs7, &D).unwrap().is_none());
    }

    #[test]
    fn bad_mem_alg_is_an_error_only_when_the_anchor_is_used() {
        let anchor = wire("a", "importAnchor", 1, 0, r#","memAlg":5,"res":{"queue":"review"}"#);
        assert!(memory_input(&eff(&[anchor.clone()]), Alg::Fsrs7, &D).is_err());
        let learn = wire("b", "review", 2, 10, r#","rtype":"learn","rating":3"#);
        assert!(memory_input(&eff(&[anchor, learn]), Alg::Fsrs7, &D).unwrap().complete);
    }

    #[test]
    fn rwkv_rows_follow_the_upstream_card_type_rules() {
        let h = eff(&[
            wire("a", "review", 1, 0, r#","rtype":"learn","rating":3"#),
            wire("b", "review", 2, DAY_MS, r#","rtype":"review","rating":1"#),
            wire("c", "review", 3, DAY_MS + 60_000, r#","rtype":"review","rating":3,"dur":1500"#),
        ]);
        let (rows, times, kept) = rwkv_card_rows(&h, &[10, 20, 1, 1], &D).unwrap();
        assert_eq!(kept, vec![0, 1, 2]);
        assert_eq!(times, vec![0, DAY_MS, DAY_MS + 60_000]);
        let field = |row: usize, k: usize| i64::from_le_bytes(rows[row * 80 + 8 * k..row * 80 + 8 * k + 8].try_into().unwrap());
        assert_eq!(field(0, 5), 0);
        assert_eq!(field(0, 7), -1);
        assert_eq!(field(2, 5), 3, "same-day review after review+Again is relearning");
        assert_eq!(field(2, 4), 1500);
        assert_eq!(field(2, 8), 60);
        assert_eq!(rows[2 * 80 + 76], 3);
        let mut now = Vec::new();
        push_rwkv_now_row(&mut now, &[10, 20, 1, 1], Some((DAY_MS + 60_000, 3, RType::Review)), 2, 3 * DAY_MS, &D).unwrap();
        assert_eq!(i64::from_le_bytes(now[56..64].try_into().unwrap()), 2);
        assert_eq!(now[76], 0);
    }

    #[test]
    fn rating_outside_0_to_4_is_an_error_for_rwkv() {
        let h = eff(&[wire("a", "review", 1, 0, r#","rtype":"learn","rating":7"#)]);
        assert!(rwkv_card_rows(&h, &[1, 1, 1, 1], &D).is_err());
    }
}
