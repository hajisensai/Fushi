//! 卡片历史内核（铁律 A / B）：复习日志 → 有效日志选取 → 卡片当前排程状态。
//!
//! 设计见 docs/specs/2026-10-23-srs-rust-core.md「第一阶段」。这是 SRS 胖核心搬进 Rust 的第一块：
//! 选取规则只在这里写一份，Dart 的 `SrsCardHistory`（packages/fushi_srs/lib/src/valid_logs.dart）
//! 只是它的视图。两个批量入口，一次 FFI 调用处理一整批历史（一次缓存刷新 / 一次统计取数）：
//!
//! - [states_from_json]：落库形态（canonical JSON 原文 + 服务器时刻）→ 每份历史的当前状态。
//!   缓存刷新走这条：日志不在 Dart 侧解码，Dart 只拿到写缓存行要的那几列。
//! - [select_columns]：Dart 内存里已有的 `SrsReviewLog`（按列打包）→ 排序与每条日志的选取标记。
//!   撤销 / 评分 / 恢复 / 统计这些本来就要整条日志对象的调用方走这条。
//!
//! 规则与旧 Dart 实现逐条对应（固定向量 packages/fushi_srs/test/history/fixtures/ 由删除前的 Dart
//! 实现生成，两条入口都必须逐条一致）：
//! - 同一份历史里同 ID 的日志只留最后一条（Dart `Map` 去重语义）；
//! - 排序键 = (钳位后的物理时间, 计数器, writerId, eventId)，钳位 = min(HLC 物理部分, S(e) + 10 分钟)；
//!   字符串按 **UTF-16 码元**比较（Dart `String.compareTo`），不是 Rust 默认的码点序；
//! - 撤销：undo 日志的 revokes 目标不算有效；不级联；
//! - 等价导入：Anki 导入的评分日志与本机原生评分同评分、Anki revlog 时刻与原生时刻相差 ≤ 1 秒时不算有效；
//! - 有效 = 已知 kind、不是 undo、没被撤销、不是等价导入；
//! - 状态 = 最后一条有结果的有效日志的结果；排程归属 = 最后一条有结果的有效 handOff 的方向，没有 = fushi。

use std::borrow::Cow;
use std::cmp::Ordering;

use serde::Deserialize;
use serde_json::value::RawValue;
use serde_json::Value;

/// 排序与 HLC 推进共用的容差（Dart `srsClockToleranceMs`）：S(e) 之后最多 10 分钟。
pub const CLOCK_TOLERANCE_MS: i64 = 10 * 60 * 1000;

/// 导入复习与原生复习的等价容差（Dart `srsImportEquivalenceToleranceMs`）。
pub const IMPORT_EQUIVALENCE_TOLERANCE_MS: i64 = 1000;

/// 日志种类（持久化名冻结，见 review_log.dart `SrsLogKind`）。列模式下的编码与 Dart 侧同序。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Review = 0,
    Manual = 1,
    Reschedule = 2,
    ImportAnchor = 3,
    HandOff = 4,
    Undo = 5,
    Unknown = 6,
}

impl Kind {
    fn parse(wire: &str) -> Self {
        match wire {
            "review" => Kind::Review,
            "manual" => Kind::Manual,
            "reschedule" => Kind::Reschedule,
            "importAnchor" => Kind::ImportAnchor,
            "handOff" => Kind::HandOff,
            "undo" => Kind::Undo,
            _ => Kind::Unknown,
        }
    }

    fn from_code(code: i64) -> Self {
        match code {
            0 => Kind::Review,
            1 => Kind::Manual,
            2 => Kind::Reschedule,
            3 => Kind::ImportAnchor,
            4 => Kind::HandOff,
            5 => Kind::Undo,
            _ => Kind::Unknown,
        }
    }
}

/// 日志来源（`SrsLogOrigin`）：只有 fushi / anki 两个值参与规则，别的值两边都不算。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    Fushi,
    Anki,
    Other,
}

/// 选取规则需要的一条日志（两条入口各自解出这一形状）。
#[derive(Debug, Clone)]
pub struct Log<'a> {
    pub id: Cow<'a, str>,
    pub writer: Cow<'a, str>,
    pub physical: i64,
    pub counter: i64,
    pub server_time: Option<i64>,
    pub kind: Kind,
    pub origin: Origin,
    /// reviewType 是评分类（learn / review / relearn）。
    pub rating_type: bool,
    pub rating: Option<i64>,
    pub anki_id: Option<i64>,
    pub occurred_at: i64,
    pub revokes: Option<Cow<'a, str>>,
    pub has_result: bool,
}

impl Log<'_> {
    fn is_rating_review(&self) -> bool {
        self.kind == Kind::Review && self.rating_type
    }

    fn sort_physical(&self) -> i64 {
        match self.server_time {
            Some(s) => self.physical.min(s.saturating_add(CLOCK_TOLERANCE_MS)),
            None => self.physical,
        }
    }
}

/// Dart `String.compareTo`：按 UTF-16 码元比较。与码点序只在「增补平面字符 vs U+E000..U+FFFF」处不同。
pub fn cmp_utf16(a: &str, b: &str) -> Ordering {
    if a.is_ascii() && b.is_ascii() {
        return a.as_bytes().cmp(b.as_bytes());
    }
    a.encode_utf16().cmp(b.encode_utf16())
}

fn cmp_sort_key(a: &Log<'_>, b: &Log<'_>) -> Ordering {
    a.sort_physical()
        .cmp(&b.sort_physical())
        .then(a.counter.cmp(&b.counter))
        .then_with(|| cmp_utf16(&a.writer, &b.writer))
        .then_with(|| cmp_utf16(&a.id, &b.id))
}

/// 选取标记（每条日志一个字节；列模式原样交给 Dart）。
pub const STATUS_EFFECTIVE: u8 = 1;
/// 被某条 undo 撤销。
pub const STATUS_REVOKED: u8 = 2;
/// 被判与原生日志等价的导入日志。
pub const STATUS_EQUIVALENT_IMPORT: u8 = 4;
/// 这条是带撤销目标的 undo（它的 revokes 进 Dart 的 `revoked` 集合，目标不在本历史里也算）。
pub const STATUS_REVOKER: u8 = 8;

/// 一份历史的选取结果。下标都指向输入切片。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    /// 去重（同 ID 留最后一条）后按排序键升序的输入下标。
    pub order: Vec<usize>,
    /// 与 [Selection::order] 一一对应的 `STATUS_*` 位。
    pub status: Vec<u8>,
    /// 最后一条有结果的有效日志。
    pub last_effective: Option<usize>,
    /// 决定排程归属的那条 handOff（最后一条有结果的有效 handOff）。
    pub scheduler_from: Option<usize>,
}

/// 选取（铁律 B）。
pub fn select(logs: &[Log<'_>]) -> Selection {
    // 同 ID 留最后一条。历史一般十几条，线性查找比建哈希表快。
    let mut order: Vec<usize> = Vec::with_capacity(logs.len());
    if logs.len() <= 32 {
        for (i, l) in logs.iter().enumerate() {
            if !logs[i + 1..].iter().any(|later| later.id == l.id) {
                order.push(i);
            }
        }
    } else {
        let mut last: std::collections::HashMap<&str, usize> = std::collections::HashMap::with_capacity(logs.len());
        for (i, l) in logs.iter().enumerate() {
            last.insert(&l.id, i);
        }
        for (i, l) in logs.iter().enumerate() {
            if last.get(&*l.id) == Some(&i) {
                order.push(i);
            }
        }
    }
    order.sort_by(|&a, &b| cmp_sort_key(&logs[a], &logs[b]));

    let revoked_ids: Vec<&str> = order
        .iter()
        .filter_map(|&i| {
            let l = &logs[i];
            if l.kind == Kind::Undo {
                l.revokes.as_deref()
            } else {
                None
            }
        })
        .collect();
    let natives: Vec<&Log<'_>> = order
        .iter()
        .map(|&i| &logs[i])
        .filter(|l| l.origin == Origin::Fushi && l.is_rating_review())
        .collect();

    let mut status = Vec::with_capacity(order.len());
    let mut last_effective = None;
    let mut scheduler_from = None;
    for &i in &order {
        let l = &logs[i];
        let mut s = 0u8;
        if l.kind == Kind::Undo && l.revokes.is_some() {
            s |= STATUS_REVOKER;
        }
        let revoked = revoked_ids.iter().any(|r| *r == l.id);
        if revoked {
            s |= STATUS_REVOKED;
        }
        let equivalent = l.origin == Origin::Anki
            && l.is_rating_review()
            && match l.anki_id {
                Some(anki_ms) => natives.iter().any(|n| {
                    l.rating == n.rating && (anki_ms - n.occurred_at).abs() <= IMPORT_EQUIVALENCE_TOLERANCE_MS
                }),
                None => false,
            };
        if equivalent {
            s |= STATUS_EQUIVALENT_IMPORT;
        }
        if l.kind != Kind::Unknown && l.kind != Kind::Undo && !revoked && !equivalent {
            s |= STATUS_EFFECTIVE;
            if l.has_result {
                last_effective = Some(i);
                if l.kind == Kind::HandOff {
                    scheduler_from = Some(i);
                }
            }
        }
        status.push(s);
    }
    Selection { order, status, last_effective, scheduler_from }
}

// ---------------------------------------------------------------- 落库形态（JSON）入口

/// 落库 JSON 里选取要读的键（`SrsReviewLog.toJson` 的线格式；别的键忽略）。必填键缺失 / 类型不对
/// 与 Dart `SrsReviewLog.fromJson` 一样判为坏数据。
#[derive(Deserialize)]
struct WireLog<'a> {
    #[serde(borrow)]
    id: Cow<'a, str>,
    #[serde(borrow)]
    p: Cow<'a, str>,
    #[serde(borrow)]
    card: Cow<'a, str>,
    #[serde(borrow)]
    kind: Cow<'a, str>,
    #[serde(borrow)]
    hlc: Cow<'a, str>,
    at: i64,
    #[serde(default, borrow)]
    origin: Option<Cow<'a, str>>,
    #[serde(default, borrow)]
    rtype: Option<Cow<'a, str>>,
    #[serde(default)]
    rating: Option<i64>,
    #[serde(default, borrow)]
    revokes: Option<Cow<'a, str>>,
    #[serde(default, rename = "ankiId")]
    anki_id: Option<i64>,
    #[serde(default, borrow)]
    res: Option<&'a RawValue>,
    // 选取用不到、但 Dart `fromJson` 会做类型转换的键：类型不对同样判坏数据。
    #[serde(default, borrow, rename = "ts")]
    _ts: Option<Cow<'a, str>>,
    #[serde(default, rename = "dur")]
    _dur: Option<i64>,
    #[serde(default, borrow, rename = "params")]
    _params: Option<Cow<'a, str>>,
    #[serde(default, borrow, rename = "alg")]
    _alg: Option<Cow<'a, str>>,
    #[serde(default, rename = "utcOff")]
    _utc_off: Option<i64>,
    #[serde(default, rename = "rollover")]
    _rollover: Option<i64>,
    #[serde(default, rename = "fv")]
    _fv: Option<i64>,
}

/// Dart `Hlc.decode`：`<physical>:<counter>:<writerId>`，writerId 可含冒号，只切前两段。
fn parse_hlc(text: &str) -> Result<(i64, i64, &str), String> {
    let mut it = text.splitn(3, ':');
    let (p, c, w) = match (it.next(), it.next(), it.next()) {
        (Some(p), Some(c), Some(w)) => (p, c, w),
        _ => return Err(format!("bad hlc: {text}")),
    };
    let p: i64 = p.parse().map_err(|_| format!("bad hlc: {text}"))?;
    let c: i64 = c.parse().map_err(|_| format!("bad hlc: {text}"))?;
    Ok((p, c, w))
}

/// 一条落库日志解成 [Log]，连同解好的结果（与 Dart 一样每条都解：哪条的结果是坏数据都判错）。
fn parse_wire<'a>(json: &'a str, server_time: Option<i64>) -> Result<(Log<'a>, Option<WireResult<'a>>), String> {
    let w: WireLog<'a> = serde_json::from_str(json).map_err(|e| format!("bad review log: {e}"))?;
    let _ = (&w.p, &w.card);
    let (physical, counter, writer) = match w.hlc {
        Cow::Borrowed(s) => {
            let (p, c, wr) = parse_hlc(s)?;
            (p, c, Cow::Borrowed(wr))
        }
        Cow::Owned(s) => {
            let (p, c, wr) = parse_hlc(&s)?;
            (p, c, Cow::Owned(wr.to_owned()))
        }
    };
    // Dart：`res is Map ? fromJson : null`——不是对象就当没有结果。
    let res = match w.res {
        Some(r) if r.get().starts_with('{') => Some(parse_result(r)?),
        _ => None,
    };
    let origin = match w.origin.as_deref() {
        None | Some("fushi") => Origin::Fushi,
        Some("anki") => Origin::Anki,
        Some(_) => Origin::Other,
    };
    // reviewType 缺省 manual（不是评分类）。
    let rating_type = matches!(w.rtype.as_deref(), Some("learn" | "review" | "relearn"));
    Ok((
        Log {
            id: w.id,
            writer,
            physical,
            counter,
            server_time,
            kind: Kind::parse(&w.kind),
            origin,
            rating_type,
            rating: w.rating,
            anki_id: w.anki_id,
            occurred_at: w.at,
            revokes: w.revokes,
            has_result: res.is_some(),
        },
        res,
    ))
}

/// 卡片当前排程状态（`SrsScheduleResult` 的全部字段；缓存行只用其中一部分）。
#[derive(Debug, Clone, PartialEq)]
pub struct State {
    /// 0 new / 1 learning / 2 review / 3 relearning（`SrsQueue` 同序）。
    pub queue: i64,
    pub due_day: Option<i64>,
    pub due_at: Option<i64>,
    pub scheduled_days: i64,
    pub learning_step: i64,
    /// (stability, difficulty, stabilityFast)。
    pub memory: Option<(f64, f64, f64)>,
    pub last_reviewed_at: Option<i64>,
    pub reps: i64,
    pub lapses: i64,
    pub ease: Option<i64>,
    /// 排程归属（覆盖了结果里自带的 scheduler，见 Dart `SrsCardHistory.state`）。
    pub scheduler: String,
    /// 最后一条有结果的有效日志 ID（缓存行的 lastLogId）。
    pub last_log_id: Option<String>,
}

#[derive(Deserialize)]
struct WireResult<'a> {
    #[serde(default, borrow)]
    queue: Option<Cow<'a, str>>,
    #[serde(default, rename = "dueDay")]
    due_day: Option<i64>,
    #[serde(default, rename = "dueAt")]
    due_at: Option<i64>,
    #[serde(default)]
    ivl: Option<i64>,
    #[serde(default)]
    step: Option<i64>,
    #[serde(default)]
    mem: Option<Value>,
    #[serde(default, rename = "lastReviewedAt")]
    last_reviewed_at: Option<i64>,
    #[serde(default)]
    reps: Option<i64>,
    #[serde(default)]
    lapses: Option<i64>,
    #[serde(default, borrow)]
    scheduler: Option<Cow<'a, str>>,
    #[serde(default)]
    ease: Option<i64>,
}

fn queue_code(wire: Option<&str>) -> i64 {
    match wire {
        Some("learning") => 1,
        Some("review") => 2,
        Some("relearning") => 3,
        _ => 0,
    }
}

/// Dart `SrsMemory.fromJson`：不是对象 / s、d 不是数 → 没有记忆状态；sf 缺省 = s。
fn parse_memory(v: Option<&Value>) -> Option<(f64, f64, f64)> {
    let m = v?.as_object()?;
    let s = m.get("s")?.as_f64()?;
    let d = m.get("d")?.as_f64()?;
    let sf = m.get("sf").and_then(Value::as_f64).unwrap_or(s);
    Some((s, d, sf))
}

fn parse_result<'a>(raw: &'a RawValue) -> Result<WireResult<'a>, String> {
    serde_json::from_str(raw.get()).map_err(|e| format!("bad review result: {e}"))
}

/// 一份历史（落库 JSON + 各自的服务器时刻）的当前状态。
pub fn state_from_json(jsons: &[&str], server_times: &[Option<i64>]) -> Result<State, String> {
    let mut logs = Vec::with_capacity(jsons.len());
    let mut results: Vec<Option<WireResult<'_>>> = Vec::with_capacity(jsons.len());
    for (j, s) in jsons.iter().zip(server_times) {
        let (log, res) = parse_wire(j, *s)?;
        logs.push(log);
        results.push(res);
    }
    let sel = select(&logs);
    let scheduler = sel
        .scheduler_from
        .and_then(|i| results[i].as_ref().and_then(|r| r.scheduler.as_deref()))
        .unwrap_or("fushi")
        .to_owned();
    let Some(last) = sel.last_effective else {
        return Ok(State {
            queue: 0,
            due_day: None,
            due_at: None,
            scheduled_days: 0,
            learning_step: 0,
            memory: None,
            last_reviewed_at: None,
            reps: 0,
            lapses: 0,
            ease: None,
            scheduler,
            last_log_id: None,
        });
    };
    let r = results[last].take().expect("last effective log has a result");
    Ok(State {
        queue: queue_code(r.queue.as_deref()),
        due_day: r.due_day,
        due_at: r.due_at,
        scheduled_days: r.ivl.unwrap_or(0),
        learning_step: r.step.unwrap_or(0),
        memory: parse_memory(r.mem.as_ref()),
        last_reviewed_at: r.last_reviewed_at,
        reps: r.reps.unwrap_or(0),
        lapses: r.lapses.unwrap_or(0),
        ease: r.ease,
        scheduler,
        last_log_id: Some(logs[last].id.clone().into_owned()),
    })
}

/// 「没有服务器时刻」在 i64 列里的哨兵（与 Dart 侧同值）。
pub const NONE_I64: i64 = i64::MIN;

fn opt(v: i64) -> Option<i64> {
    (v != NONE_I64).then_some(v)
}

/// 每份历史的状态记录占几个 i64（[encode_states] 的布局，Dart 侧按同一布局读）。
pub const STATE_WORDS: usize = 14;

/// 批量：第 g 份历史 = 日志 `groups[g]..groups[g+1]`，第 i 条日志 = `text[offs[i]..offs[i+1]]`，
/// 服务器时刻 `servers[i]`（[NONE_I64] = 未知）。
///
/// 输出布局（小端）：`[STATE_WORDS × i64 × n_groups][u32 串偏移 × (2·n_groups + 1)][UTF-8 串]`，
/// 每份历史两个串：lastLogId、scheduler。i64 记录：
/// `[flags, queue, dueDay, dueAt, ivl, step, reps, lapses, lastReviewedAt, ease, s, d, sf, 0]`，
/// flags 位：1 有 lastLogId、2 dueDay、4 dueAt、8 记忆状态、16 lastReviewedAt、32 ease；s/d/sf 是 f64 位。
pub fn states_from_json(text: &[u8], offs: &[u32], servers: &[i64], groups: &[u32]) -> Result<Vec<u8>, String> {
    let n_logs = servers.len();
    if offs.len() != n_logs + 1 || groups.is_empty() || *groups.last().unwrap() as usize != n_logs {
        return Err("bad history batch layout".to_owned());
    }
    let text = std::str::from_utf8(text).map_err(|_| "history batch is not UTF-8".to_owned())?;
    let mut jsons: Vec<&str> = Vec::with_capacity(n_logs);
    for w in offs.windows(2) {
        let (a, b) = (w[0] as usize, w[1] as usize);
        if a > b || b > text.len() || !text.is_char_boundary(a) || !text.is_char_boundary(b) {
            return Err("bad history batch offsets".to_owned());
        }
        jsons.push(&text[a..b]);
    }
    let server_times: Vec<Option<i64>> = servers.iter().map(|&s| opt(s)).collect();
    let mut states = Vec::with_capacity(groups.len() - 1);
    for g in groups.windows(2) {
        let (a, b) = (g[0] as usize, g[1] as usize);
        if a > b || b > n_logs {
            return Err("bad history batch groups".to_owned());
        }
        states.push(state_from_json(&jsons[a..b], &server_times[a..b])?);
    }
    Ok(encode_states(&states))
}

pub fn encode_states(states: &[State]) -> Vec<u8> {
    let mut out = Vec::with_capacity(states.len() * (STATE_WORDS * 8 + 48));
    for s in states {
        let mut flags = 0i64;
        if s.last_log_id.is_some() {
            flags |= 1;
        }
        if s.due_day.is_some() {
            flags |= 2;
        }
        if s.due_at.is_some() {
            flags |= 4;
        }
        if s.memory.is_some() {
            flags |= 8;
        }
        if s.last_reviewed_at.is_some() {
            flags |= 16;
        }
        if s.ease.is_some() {
            flags |= 32;
        }
        let (ms, md, msf) = s.memory.unwrap_or((0.0, 0.0, 0.0));
        let words: [i64; STATE_WORDS] = [
            flags,
            s.queue,
            s.due_day.unwrap_or(0),
            s.due_at.unwrap_or(0),
            s.scheduled_days,
            s.learning_step,
            s.reps,
            s.lapses,
            s.last_reviewed_at.unwrap_or(0),
            s.ease.unwrap_or(0),
            ms.to_bits() as i64,
            md.to_bits() as i64,
            msf.to_bits() as i64,
            0,
        ];
        for w in words {
            out.extend_from_slice(&w.to_le_bytes());
        }
    }
    let mut body = String::new();
    let mut offsets: Vec<u32> = Vec::with_capacity(states.len() * 2 + 1);
    offsets.push(0);
    for s in states {
        body.push_str(s.last_log_id.as_deref().unwrap_or(""));
        offsets.push(body.len() as u32);
        body.push_str(&s.scheduler);
        offsets.push(body.len() as u32);
    }
    for o in offsets {
        out.extend_from_slice(&o.to_le_bytes());
    }
    out.extend_from_slice(body.as_bytes());
    out
}

// ---------------------------------------------------------------- 列模式入口

/// 列模式每条日志占几个 i64：`[physical, counter, serverTime, occurredAt, ankiId, rating, bits]`，
/// 可空列用 [NONE_I64]。bits：低 3 位 kind（[Kind] 编码）、`<<3` 两位 origin（0 fushi / 1 anki /
/// 2 其它）、`1<<5` 评分类 reviewType、`1<<6` 有结果、`1<<7` 有 revokes。
pub const COLUMN_WORDS: usize = 7;

/// 列模式批量：第 i 条日志的三个串 = `text[offs[3i]..offs[3i+1]]`（id）、`[3i+1..3i+2]`（writerId）、
/// `[3i+2..3i+3]`（revokes，无则空串且 bits 不带 `1<<7`）。
///
/// 输出布局（小端）：`[u32 组边界 × (n_groups + 1)][u32 输入下标 × 去重后总数][i32 lastEffective × n_groups]
/// [i32 schedulerFrom × n_groups][u8 STATUS_* × 去重后总数]`；下标都是全局输入下标，-1 = 无。
pub fn select_columns(ints: &[i64], text: &[u8], offs: &[u32], groups: &[u32]) -> Result<Vec<u8>, String> {
    if ints.len() % COLUMN_WORDS != 0 {
        return Err("bad history column layout".to_owned());
    }
    let n_logs = ints.len() / COLUMN_WORDS;
    if offs.len() != n_logs * 3 + 1 || groups.is_empty() || *groups.last().unwrap() as usize != n_logs {
        return Err("bad history column layout".to_owned());
    }
    let text = std::str::from_utf8(text).map_err(|_| "history columns are not UTF-8".to_owned())?;
    let slice = |k: usize| -> Result<&str, String> {
        let (a, b) = (offs[k] as usize, offs[k + 1] as usize);
        if a > b || b > text.len() || !text.is_char_boundary(a) || !text.is_char_boundary(b) {
            return Err("bad history column offsets".to_owned());
        }
        Ok(&text[a..b])
    };
    let mut logs: Vec<Log<'_>> = Vec::with_capacity(n_logs);
    for i in 0..n_logs {
        let c = &ints[i * COLUMN_WORDS..(i + 1) * COLUMN_WORDS];
        let bits = c[6];
        logs.push(Log {
            id: Cow::Borrowed(slice(3 * i)?),
            writer: Cow::Borrowed(slice(3 * i + 1)?),
            physical: c[0],
            counter: c[1],
            server_time: opt(c[2]),
            kind: Kind::from_code(bits & 7),
            origin: match (bits >> 3) & 3 {
                0 => Origin::Fushi,
                1 => Origin::Anki,
                _ => Origin::Other,
            },
            rating_type: bits & (1 << 5) != 0,
            rating: opt(c[5]),
            anki_id: opt(c[4]),
            occurred_at: c[3],
            revokes: (bits & (1 << 7) != 0).then(|| slice(3 * i + 2).map(Cow::Borrowed)).transpose()?,
            has_result: bits & (1 << 6) != 0,
        });
    }
    let n_groups = groups.len() - 1;
    let mut bounds: Vec<u32> = Vec::with_capacity(n_groups + 1);
    let mut order: Vec<u32> = Vec::with_capacity(n_logs);
    let mut status: Vec<u8> = Vec::with_capacity(n_logs);
    let mut last: Vec<i32> = Vec::with_capacity(n_groups);
    let mut sched: Vec<i32> = Vec::with_capacity(n_groups);
    bounds.push(0);
    for g in groups.windows(2) {
        let (a, b) = (g[0] as usize, g[1] as usize);
        if a > b || b > n_logs {
            return Err("bad history column groups".to_owned());
        }
        let sel = select(&logs[a..b]);
        order.extend(sel.order.iter().map(|&i| (a + i) as u32));
        status.extend_from_slice(&sel.status);
        bounds.push(order.len() as u32);
        last.push(sel.last_effective.map_or(-1, |i| (a + i) as i32));
        sched.push(sel.scheduler_from.map_or(-1, |i| (a + i) as i32));
    }
    let mut out = Vec::with_capacity(bounds.len() * 4 + order.len() * 5 + n_groups * 8);
    for v in bounds {
        out.extend_from_slice(&v.to_le_bytes());
    }
    for v in order {
        out.extend_from_slice(&v.to_le_bytes());
    }
    for v in last {
        out.extend_from_slice(&v.to_le_bytes());
    }
    for v in sched {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&status);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wire(id: &str, kind: &str, hlc: &str, at: i64, extra: &str) -> String {
        format!(r#"{{"id":"{id}","p":"p","card":"c","kind":"{kind}","hlc":"{hlc}","at":{at}{extra}}}"#)
    }

    #[test]
    fn utf16_order_differs_from_code_point_order() {
        // U+1D4E7 的高代理 0xD835 < U+FF21：UTF-16 序在前，码点序在后。
        assert_eq!(cmp_utf16("\u{1D4E7}", "\u{FF21}"), Ordering::Less);
        assert_eq!("\u{1D4E7}".cmp("\u{FF21}"), Ordering::Greater);
    }

    #[test]
    fn undo_revokes_and_state_falls_back() {
        let l1 = wire("l1", "review", "10:0:A", 10, r#","rtype":"review","rating":3,"res":{"queue":"review","dueDay":10}"#);
        let u1 = wire("u1", "undo", "11:0:A", 11, r#","revokes":"l1""#);
        let s = state_from_json(&[&u1, &l1], &[None, None]).unwrap();
        assert_eq!(s.last_log_id, None);
        assert_eq!(s.queue, 0);
        let s = state_from_json(&[&l1], &[None]).unwrap();
        assert_eq!(s.last_log_id.as_deref(), Some("l1"));
        assert_eq!((s.queue, s.due_day), (2, Some(10)));
    }

    #[test]
    fn server_time_clamps_sort_key() {
        // b 的 HLC 更晚，但 S(b) + 10 分钟早于 a：钳位后 b 排在 a 前面，a 是最后一条。
        let a = wire("a", "review", "1000000:0:A", 0, r#","rtype":"review","res":{"queue":"review","dueDay":1}"#);
        let b = wire("b", "review", "9000000:0:B", 0, r#","rtype":"review","res":{"queue":"review","dueDay":2}"#);
        let s = state_from_json(&[&a, &b], &[None, Some(0)]).unwrap();
        assert_eq!(s.last_log_id.as_deref(), Some("a"));
    }

    #[test]
    fn malformed_log_is_an_error() {
        assert!(state_from_json(&[r#"{"id":"x"}"#], &[None]).is_err());
        assert!(state_from_json(&[&wire("x", "review", "nohlc", 0, "")], &[None]).is_err());
        assert!(state_from_json(&[&wire("x", "review", "1:0:A", 0, r#","rating":3.5"#)], &[None]).is_err());
    }
}
