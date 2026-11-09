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
//! - 同一事件的多份副本只算一份（[EventKey]，BUG-4218）：同卡、同 kind、同 HLC（physical, counter, writerId）、
//!   同发生时刻 / 来源 / 评分 / Anki revlog 时刻的日志是同一次真实事件换了 ID 的副本（profile 合并在 BUG-4217
//!   修好前会把一次复习写成两个 ID，事件只追加、永远删不掉）。组里 ID 最小（UTF-16 序）的一条是代表，其余标
//!   [STATUS_DUPLICATE]、不算有效；组里任何一份被撤销，整组（每一份）算撤销。undo 与不认识的 kind 不成组。依据：HLC 每次写日志都由写入者时钟
//!   tick 出来，同写入者内唯一；Anki 导入的 HLC 由 revlog id / 锚点时刻派生；合并 / 跨 profile 导入原样保留 HLC；
//!   恢复备份的重放副本取新 HLC，不与原日志成组；
//!   **Anki 来源的日志不比卡**（BUG-4242）：同一次 Anki 复习的导入日志 ID 由本机卡 ID 派生（`SrsIds.importedRevlogs`），
//!   来源笔记换过模板 / 笔记类型（Lapis 迁到 Fushi 卡片、删光重导时按来源类型恢复）后再导入，同一条 revlog 会落成
//!   血统里另一张卡上的另一条日志。HLC 与发生时刻都由 revlog id 派生、写入者固定，所以在一份历史（一张逻辑卡的
//!   血统）里，HLC / 时刻 / 评分 / 种类都相同的 Anki 日志就是同一次复习，按卡区分只会让它算两遍；
//! - 排序键见 ordering.rs（与字段寄存器共用一份）：(钳位后的物理时间, 计数器, writerId, eventId)，
//!   字符串按 UTF-16 码元比较；
//! - 撤销：undo 日志的 revokes 目标不算有效；不级联；
//! - 等价导入：Anki 导入的评分日志与本机原生评分同评分、Anki revlog 时刻与原生时刻相差 ≤ 1 秒时不算有效
//!   （两条日志之间的判据 [import_equivalent] 也是 Anki 导入器入库前判重的唯一实现）；
//! - 有效 = 已知 kind、不是 undo、没被撤销、不是等价导入、不是副本；
//! - 状态 = 最后一条有结果的有效日志的结果；排程归属 = 最后一条有结果的有效 handOff 的方向，没有 = fushi。

use std::borrow::Cow;
use std::cmp::Ordering;

pub use crate::ordering::{CLOCK_TOLERANCE_MS, cmp_utf16};
use crate::ordering::{SortKey, is_clamped};

use serde::Deserialize;
use serde_json::Value;
use serde_json::value::RawValue;

/// 导入复习与原生复习的等价容差（Dart `srsImportEquivalenceToleranceMs`）。
pub const IMPORT_EQUIVALENCE_TOLERANCE_MS: i64 = 1000;

/// 日志种类（持久化名冻结，见 review_log.dart `SrsLogKind`）。列模式下的编码与 Dart 侧同序。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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

    pub(crate) fn from_code(code: i64) -> Self {
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Origin {
    Fushi,
    Anki,
    Other,
}

/// 选取规则需要的一条日志（两条入口各自解出这一形状）。
#[derive(Debug, Clone)]
pub struct Log<'a> {
    pub id: Cow<'a, str>,
    /// 日志所属的卡（一份历史可以是血统里几张卡的日志之和；同一事件只在同一张卡上成组）。
    pub card: Cow<'a, str>,
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

    /// 同一事件的副本才相等的内容身份；undo / 不认识的 kind 没有（不成组）。
    fn event_key(&self) -> Option<EventKey<'_>> {
        if matches!(self.kind, Kind::Undo | Kind::Unknown) {
            return None;
        }
        Some(EventKey {
            // Anki 来源：同一条 revlog 落在血统里不同的卡上也是同一事件（见文件头）。
            card: if self.origin == Origin::Anki {
                None
            } else {
                Some(&self.card)
            },
            kind: self.kind,
            physical: self.physical,
            counter: self.counter,
            writer: &self.writer,
            occurred_at: self.occurred_at,
            origin: self.origin,
            rating_type: self.rating_type,
            rating: self.rating,
            anki_id: self.anki_id,
        })
    }

    fn sort_key(&self) -> SortKey<'_> {
        SortKey::new(
            self.physical,
            self.counter,
            &self.writer,
            &self.id,
            self.server_time,
        )
    }
}

/// 一次真实事件的内容身份（BUG-4218）：同一事件换了 ID 的副本（profile 合并）在这些字段上逐个相同。
/// HLC 由写入者时钟 tick 出来、同写入者内唯一，Anki 导入的 HLC 由 revlog id / 锚点时刻派生，合并与跨 profile
/// 导入都原样保留；其余字段是副本照抄的内容，只用来再收紧（两条不同事件撞同一 HLC 时不被误并）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct EventKey<'a> {
    /// 日志所属的卡；Anki 来源的日志为 None（同一条 revlog 换卡导入的副本也成组，见文件头）。
    card: Option<&'a str>,
    kind: Kind,
    physical: i64,
    counter: i64,
    writer: &'a str,
    occurred_at: i64,
    origin: Origin,
    rating_type: bool,
    rating: Option<i64>,
    anki_id: Option<i64>,
}

fn cmp_sort_key(a: &Log<'_>, b: &Log<'_>) -> Ordering {
    a.sort_key().cmp(&b.sort_key())
}

/// 导入日志 [imported] 与原生日志 [native] 是不是同一次复习（铁律 B）。只看两条日志自身：
/// 两条都是评分类复习、评分相同、导入日志带 Anki revlog 时刻且与原生日志的发生时刻相差 ≤ 1 秒。
/// 卡片历史选取（[select]）与 Anki 导入器入库前判重（[import_equivalent_any]）都走这一个判据。
pub fn import_equivalent(imported: &Log<'_>, native: &Log<'_>) -> bool {
    imported.rating == native.rating
        && imported.is_rating_review()
        && native.is_rating_review()
        && match imported.anki_id {
            // 与 Dart int 同语义：减法与取绝对值都按 64 位回绕。
            Some(anki_ms) => {
                anki_ms.wrapping_sub(native.occurred_at).wrapping_abs()
                    <= IMPORT_EQUIVALENCE_TOLERANCE_MS
            }
            None => false,
        }
}

/// 选取标记（每条日志一个字节；列模式原样交给 Dart）。
pub const STATUS_EFFECTIVE: u8 = 1;
/// 被某条 undo 撤销。
pub const STATUS_REVOKED: u8 = 2;
/// 被判与原生日志等价的导入日志。
pub const STATUS_EQUIVALENT_IMPORT: u8 = 4;
/// 这条是带撤销目标的 undo（它的 revokes 进 Dart 的 `revoked` 集合，目标不在本历史里也算）。
pub const STATUS_REVOKER: u8 = 8;
/// 排序键的物理部分被钳位（HLC 物理时间超过 S(e) + 10 分钟）。
pub const STATUS_CLAMPED: u8 = 16;
/// 同一事件的副本里不是代表的那几份（[EventKey]：组里 ID 最小的是代表），不算有效。
pub const STATUS_DUPLICATE: u8 = 32;

/// 一份历史的选取结果。下标都指向输入切片。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    /// 去重（同 ID 留最后一条）后按排序键升序的输入下标。同一事件的副本都在，非代表的标 [STATUS_DUPLICATE]。
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
    let mut kept: Vec<usize> = Vec::with_capacity(logs.len());
    if logs.len() <= 32 {
        for (i, l) in logs.iter().enumerate() {
            if !logs[i + 1..].iter().any(|later| later.id == l.id) {
                kept.push(i);
            }
        }
    } else {
        let mut last: std::collections::HashMap<&str, usize> =
            std::collections::HashMap::with_capacity(logs.len());
        for (i, l) in logs.iter().enumerate() {
            last.insert(&l.id, i);
        }
        for (i, l) in logs.iter().enumerate() {
            if last.get(&*l.id) == Some(&i) {
                kept.push(i);
            }
        }
    }

    // 撤销目标：全部 undo 的 revokes（undo 不成组，副本 undo 撤的是同一个目标，取并集即可）。
    let revoked_ids: Vec<&str> = kept
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
    let is_revoked = |l: &Log<'_>| revoked_ids.iter().any(|r| *r == l.id);

    // 同一事件的副本成组（BUG-4218）：root[k] = 组里第一个成员在 kept 里的位置。
    let root: Vec<usize> = event_groups(logs, &kept);
    // 每组的代表（ID 最小，UTF-16 序）与「组里有一份被撤销」。
    let mut best: Vec<usize> = (0..kept.len()).collect();
    let mut group_revoked: Vec<bool> = vec![false; kept.len()];
    for (k, &r) in root.iter().enumerate() {
        let l = &logs[kept[k]];
        if is_revoked(l) {
            group_revoked[r] = true;
        }
        if r != k && cmp_utf16(&l.id, &logs[kept[best[r]]].id) == Ordering::Less {
            best[r] = k;
        }
    }
    // 副本仍留在排序里（标 [STATUS_DUPLICATE]、不算有效）：重放（sync2/replay.rs）要给每条派生日志按它的位置
    // 算一次投影行，投影行才是操作集合的纯函数；撤销 / 副本标记跟着下标一起排。
    let mut paired: Vec<(usize, bool, bool)> = root
        .iter()
        .enumerate()
        .map(|(k, &r)| (kept[k], group_revoked[r], best[r] != k))
        .collect();
    paired.sort_by(|a, b| cmp_sort_key(&logs[a.0], &logs[b.0]));
    let order: Vec<usize> = paired.iter().map(|p| p.0).collect();

    let natives: Vec<&Log<'_>> = order
        .iter()
        .map(|&i| &logs[i])
        .filter(|l| l.origin == Origin::Fushi && l.is_rating_review())
        .collect();

    let mut status = Vec::with_capacity(order.len());
    let mut last_effective = None;
    let mut scheduler_from = None;
    for &(i, revoked, duplicate) in &paired {
        let l = &logs[i];
        let mut s = 0u8;
        if l.kind == Kind::Undo && l.revokes.is_some() {
            s |= STATUS_REVOKER;
        }
        if revoked {
            s |= STATUS_REVOKED;
        }
        if duplicate {
            s |= STATUS_DUPLICATE;
        }
        let equivalent =
            l.origin == Origin::Anki && natives.iter().any(|n| import_equivalent(l, n));
        if equivalent {
            s |= STATUS_EQUIVALENT_IMPORT;
        }
        if is_clamped(l.physical, l.server_time) {
            s |= STATUS_CLAMPED;
        }
        if l.kind != Kind::Unknown && l.kind != Kind::Undo && !revoked && !equivalent && !duplicate
        {
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
    Selection {
        order,
        status,
        last_effective,
        scheduler_from,
    }
}

/// 被撤销的事件里还没被任何 undo 直接点名的那几份副本（输入下标，按排序键升序）。
///
/// 新规则（[select]）下组里任何一份被撤销整组就算撤销，这几份已经不算有效；但只按 ID 认撤销的旧版本客户端（BUG-4218
/// 之前）仍把它们当有效复习——用户在旧客户端上撤销一份、另一份还在，表现为「撤销没生效」。给每一份补一条点名它的
/// undo（srs.db v27，store/sync2/mod.rs `revoke_copies_of_revoked_events`）之后，新旧规则选出的有效集合相同。只取
/// 「整组已撤销」的组：补的 undo 在新规则下不改变任何选取结果，在旧规则下只撤销本来就该撤销的副本。
pub fn unnamed_revoked_copies(logs: &[Log<'_>]) -> Vec<usize> {
    let sel = select(logs);
    let named: Vec<&str> = sel
        .order
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
    sel.order
        .iter()
        .zip(&sel.status)
        .filter(|&(&i, &s)| s & STATUS_REVOKED != 0 && !named.iter().any(|r| *r == logs[i].id))
        .map(|(&i, _)| i)
        .collect()
}

/// [kept]（输入下标）里每条日志所在事件组的根：组里第一个成员在 [kept] 里的位置；不成组的日志是自己。
fn event_groups(logs: &[Log<'_>], kept: &[usize]) -> Vec<usize> {
    let mut root: Vec<usize> = (0..kept.len()).collect();
    if kept.len() <= 32 {
        for k in 0..kept.len() {
            let Some(key) = logs[kept[k]].event_key() else {
                continue;
            };
            if let Some(j) =
                (0..k).find(|&j| root[j] == j && logs[kept[j]].event_key() == Some(key))
            {
                root[k] = j;
            }
        }
    } else {
        let mut first: std::collections::HashMap<EventKey<'_>, usize> =
            std::collections::HashMap::with_capacity(kept.len());
        for (k, &i) in kept.iter().enumerate() {
            if let Some(key) = logs[i].event_key() {
                root[k] = *first.entry(key).or_insert(k);
            }
        }
    }
    root
}

// ---------------------------------------------------------------- 落库形态（JSON）入口

/// 落库 JSON 里选取要读的键（`SrsReviewLog.toJson` 的线格式；别的键忽略）。必填键缺失 / 类型不对
/// 与 Dart `SrsReviewLog.fromJson` 一样判为坏数据。
#[derive(Deserialize)]
struct WireLog<'a> {
    // 与列重复的键（id / p / card / kind / rating / at / rtype / origin / dur）在 srs.db v18 的瘦存里不在 JSON
    // 里（store/slim.rs）：都可缺，缺了从 [LogCols] 补；原文（不是瘦存）缺必需的键照旧报错。
    #[serde(default, borrow)]
    id: Option<Cow<'a, str>>,
    #[serde(default, borrow, rename = "p")]
    _p: Option<Cow<'a, str>>,
    #[serde(default, borrow)]
    card: Option<Cow<'a, str>>,
    #[serde(default, borrow)]
    kind: Option<Cow<'a, str>>,
    #[serde(borrow)]
    hlc: Cow<'a, str>,
    #[serde(default)]
    at: Option<i64>,
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
    // 选取用不到、投影（统计 / 优化器 / RWKV，projection.rs）要读，或 Dart `fromJson` 会做类型转换的键：
    // 类型不对同样判坏数据。
    #[serde(default, borrow)]
    ts: Option<Cow<'a, str>>,
    #[serde(default)]
    dur: Option<i64>,
    #[serde(default, borrow, rename = "params")]
    _params: Option<Cow<'a, str>>,
    #[serde(default, borrow)]
    alg: Option<Cow<'a, str>>,
    #[serde(default, rename = "utcOff")]
    utc_off: Option<i64>,
    #[serde(default, rename = "rollover")]
    _rollover: Option<i64>,
    #[serde(default, rename = "fv")]
    _fv: Option<i64>,
    // `extra` 里投影要看的两个键（Dart 原样保留不认识的键）：导入锚点 / 恢复照抄的记忆状态是哪种算法算的，
    // 以及「恢复到备份时间点」的标记（`srsRestoreLogExtraKey`）。memAlg 只在用到时才要求是字符串（Dart
    // `extra['memAlg'] as String?` 在用到那一刻才转换）。
    #[serde(default, borrow, rename = "memAlg")]
    mem_alg: Option<&'a RawValue>,
    #[serde(default, borrow, rename = "restoreOf")]
    restore_of: Option<&'a RawValue>,
}

/// reviewType（`SrsReviewType`，持久化名冻结）；缺省 manual。列模式下的编码与 Dart 侧同序。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RType {
    Learn = 0,
    Review = 1,
    Relearn = 2,
    Filtered = 3,
    Manual = 4,
    Rescheduled = 5,
    /// 本机不认识的值（Dart 原样保留字符串；所有规则里都与 manual 走同一个分支）。
    Other = 6,
}

impl RType {
    pub fn parse(wire: Option<&str>) -> Self {
        match wire {
            None | Some("manual") => RType::Manual,
            Some("learn") => RType::Learn,
            Some("review") => RType::Review,
            Some("relearn") => RType::Relearn,
            Some("filtered") => RType::Filtered,
            Some("rescheduled") => RType::Rescheduled,
            Some(_) => RType::Other,
        }
    }

    pub fn from_code(code: i64) -> Self {
        match code {
            0 => RType::Learn,
            1 => RType::Review,
            2 => RType::Relearn,
            3 => RType::Filtered,
            4 => RType::Manual,
            5 => RType::Rescheduled,
            _ => RType::Other,
        }
    }

    /// 评分类（learn / review / relearn）。
    pub fn is_rating(self) -> bool {
        matches!(self, RType::Learn | RType::Review | RType::Relearn)
    }
}

/// 投影（projection.rs）要的、选取用不到的那几个字段。
#[derive(Debug, Clone)]
pub struct Extra<'a> {
    pub rtype: RType,
    /// `durationMs`，缺省 0。
    pub dur: i64,
    /// 日志 `alg` 是 rwkv（按回忆率排的复习）。
    pub alg_rwkv: bool,
    /// `utcOffsetMin`，缺省 0。
    pub utc_off: i64,
    /// 时间来源是墙钟（`ts` 不是 anchored；缺省 wall）。
    pub ts_wall: bool,
    /// `extra['memAlg']` 原文（null / 缺失 = None）。
    pub mem_alg: Option<&'a RawValue>,
    /// `extra['restoreOf'] != null`。
    pub restore: bool,
}

/// 一条日志的结果里投影要读的字段（`SrsScheduleResult` 的一部分）。
#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    /// 0 new / 1 learning / 2 review / 3 relearning。
    pub queue: i64,
    pub due_day: Option<i64>,
    pub scheduled_days: i64,
    pub reps: i64,
    pub last_reviewed_at: Option<i64>,
    pub memory: Option<(f64, f64, f64)>,
    pub ease: Option<i64>,
}

impl Outcome {
    fn of(r: &WireResult<'_>) -> Self {
        Outcome {
            queue: queue_code(r.queue.as_deref()),
            due_day: r.due_day,
            scheduled_days: r.ivl.unwrap_or(0),
            reps: r.reps.unwrap_or(0),
            last_reviewed_at: r.last_reviewed_at,
            memory: parse_memory(r.mem.as_ref()),
            ease: r.ease,
        }
    }
}

/// 一条落库日志的全部投影输入：选取字段、结果（没有 / 不是对象 = None）、其余字段。
pub type Parsed<'a> = (Log<'a>, Option<Outcome>, Extra<'a>);

/// 一条落库日志解成 [Parsed]（与 [state_from_json] 同一套坏数据判据）。
pub fn parse_full(json: &str, server_time: Option<i64>) -> Result<Parsed<'_>, String> {
    parse_stored(json, server_time, None)
}

/// [parse_full]，日志可以是瘦存 + 列（[StoredLog]，store/slim.rs `log_row`）：读 `jslim` 与列的读者不经生成列
/// `json`（逐行拼回原文）。
pub fn parse_stored<'a>(
    stored: &'a str,
    server_time: Option<i64>,
    cols: Option<&'a LogCols>,
) -> Result<Parsed<'a>, String> {
    let (log, res, extra) = parse_wire(stored, server_time, cols)?;
    Ok((log, res.as_ref().map(Outcome::of), extra))
}

/// Dart `Hlc.decode`：`<physical>:<counter>:<writerId>`，writerId 可含冒号，只切前两段（字段寄存器同用这一份）。
pub(crate) fn parse_hlc(text: &str) -> Result<(i64, i64, &str), String> {
    let mut it = text.splitn(3, ':');
    let (p, c, w) = match (it.next(), it.next(), it.next()) {
        (Some(p), Some(c), Some(w)) => (p, c, w),
        _ => return Err(format!("bad hlc: {text}")),
    };
    let p: i64 = p.parse().map_err(|_| format!("bad hlc: {text}"))?;
    let c: i64 = c.parse().map_err(|_| format!("bad hlc: {text}"))?;
    Ok((p, c, w))
}

/// 日志行里与 JSON 键重复的列（ID 已解码成文本；`rating` 列 NULL = None）。读 `jslim` + 这些列的读者
/// （store/slim.rs）用它代替拼回的 `json`。
pub struct LogCols {
    pub id: String,
    pub card: String,
    pub kind: String,
    pub rating: Option<i64>,
    pub at: i64,
    pub rtype: String,
    pub origin: String,
    pub dur: i64,
}

/// (落库 JSON 或瘦存 `jslim`, 服务器时刻, 瘦存时同一行的列)。
pub type StoredLog<'a> = (&'a str, Option<i64>, Option<&'a LogCols>);

/// 一条落库日志解成 [Log]，连同解好的结果（与 Dart 一样每条都解：哪条的结果是坏数据都判错）。
fn parse_wire<'a>(
    stored: &'a str,
    server_time: Option<i64>,
    cols: Option<&'a LogCols>,
) -> Result<(Log<'a>, Option<WireResult<'a>>, Extra<'a>), String> {
    // 瘦存 `~<原文没有的键>{…}`：去掉的键从列补，记为原文没有的不补（与 slim::expand 拼回的原文同义）。
    let (json, absent, cols) = match (stored.strip_prefix('~'), cols) {
        (Some(rest), Some(c)) => {
            let brace = rest.find('{').ok_or("bad slim review log")?;
            (&rest[brace..], &rest[..brace], Some(c))
        }
        (Some(_), None) => return Err("slim review log read without its columns".to_owned()),
        (None, _) => (stored, "", None),
    };
    let mut w: WireLog<'a> =
        serde_json::from_str(json).map_err(|e| format!("bad review log: {e}"))?;
    let col = |key: &str| cols.filter(|_| !absent.split(',').any(|a| a == key));
    if let Some(c) = col("id") {
        w.id.get_or_insert(Cow::Borrowed(&c.id));
    }
    if let Some(c) = col("card") {
        w.card.get_or_insert(Cow::Borrowed(&c.card));
    }
    if let Some(c) = col("kind") {
        w.kind.get_or_insert(Cow::Borrowed(&c.kind));
    }
    if let Some(c) = col("at") {
        w.at.get_or_insert(c.at);
    }
    if let Some(c) = col("rtype") {
        w.rtype.get_or_insert(Cow::Borrowed(&c.rtype));
    }
    if let Some(c) = col("origin") {
        w.origin.get_or_insert(Cow::Borrowed(&c.origin));
    }
    if let Some(c) = col("dur") {
        w.dur.get_or_insert(c.dur);
    }
    if let Some(r) = col("rating").and_then(|c| c.rating) {
        w.rating.get_or_insert(r);
    }
    // p 选取用不到：瘦存里缺了不补（原文缺照旧报错）。
    if w._p.is_none() && col("p").is_none() {
        return Err("bad review log: missing field `p`".to_owned());
    }
    let id = w.id.ok_or("bad review log: missing field `id`")?;
    let card = w.card.ok_or("bad review log: missing field `card`")?;
    let kind = w.kind.ok_or("bad review log: missing field `kind`")?;
    let at = w.at.ok_or("bad review log: missing field `at`")?;
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
    let rtype = RType::parse(w.rtype.as_deref());
    let rating_type = rtype.is_rating();
    let extra = Extra {
        rtype,
        dur: w.dur.unwrap_or(0),
        alg_rwkv: w.alg.as_deref() == Some("rwkv"),
        utc_off: w.utc_off.unwrap_or(0),
        ts_wall: w.ts.as_deref() != Some("anchored"),
        mem_alg: w.mem_alg,
        restore: w.restore_of.is_some(),
    };
    Ok((
        Log {
            id,
            card,
            writer,
            physical,
            counter,
            server_time,
            kind: Kind::parse(&kind),
            origin,
            rating_type,
            rating: w.rating,
            anki_id: w.anki_id,
            occurred_at: at,
            revokes: w.revokes,
            has_result: res.is_some(),
        },
        res,
        extra,
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
    let stored: Vec<StoredLog<'_>> = jsons
        .iter()
        .zip(server_times)
        .map(|(j, s)| (*j, *s, None))
        .collect();
    state_from_stored(&stored)
}

/// [state_from_json]，日志可以是瘦存 + 列（[StoredLog]）。
pub fn state_from_stored(stored: &[StoredLog<'_>]) -> Result<State, String> {
    let (logs, results, _) = parse_all(stored)?;
    let sel = select(&logs);
    state_of(sel, logs, results)
}

/// 「成熟」的间隔下限（Dart `kSrsMatureIntervalDays`）。
pub const MATURE_INTERVAL_DAYS: i64 = 21;

/// 有效复习投影的一行（`srs_stat_reviews`；Dart `SrsStatProjection`）。与日界无关：日序号、小时、
/// 提前复习由读方按自己的日界从 [occurred_at] / [utc_off] / [prev_due_day] 算。
#[derive(Debug, Clone, PartialEq)]
pub struct StatRow {
    pub log_id: String,
    pub occurred_at: i64,
    pub utc_off: i64,
    /// 1..4；None = 不是统计复习，只是成熟状态变化（[maturity_delta] ≠ 0）。
    pub rating: Option<i64>,
    /// `SrsStatReviewKind` 下标：0 新卡 / 1 学习 / 2 年轻 / 3 成熟 / 4 重学 / 5 筛选。
    pub kind: i64,
    pub dur: i64,
    /// 按到期日排的复习卡复习：上一条有效结果的到期日（> 当天 = 提前复习）；其余 None。
    pub prev_due_day: Option<i64>,
    /// +1 = 这条之后变成熟，−1 = 掉出成熟，0 = 不变。
    pub maturity_delta: i64,
    /// Anki 导入日志的事件身份（不是 Anki 来源 / 没有 revlog id 时 None）：不在同一份历史里的两张卡（没有血统链接，
    /// 例如删光重导后按来源类型恢复的笔记：旧卡隐藏、新卡可见）各自投影时，统计按它判同一次复习（BUG-4242，
    /// store/caches.rs `refresh_stats`）。不落库。
    pub anki_event: Option<AnkiEvent>,
}

/// 一条 Anki 导入日志的事件身份（[StatRow::anki_event]）：同一条 revlog 不论导入到哪张卡，这些字段都相同
/// （HLC / 发生时刻由 revlog id 派生；评分、复习类型、用时照抄 revlog）。用时一起比，是为了把两个不同 Anki 集合
/// 恰好在同一毫秒有一次同评分复习的情况分开。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AnkiEvent {
    pub anki_id: i64,
    pub physical: i64,
    pub counter: i64,
    pub kind: i64,
    pub rating_type: bool,
    pub rating: Option<i64>,
    pub dur: i64,
}

/// 一份归属组（归属卡 + 归它的前身卡，日志合在一起）的有效复习投影：每条有效日志在分类 / 成熟变化
/// 上看合并历史里的前序有效结果。规则与删除前的 Dart `srsStatProjectionOf` 逐条对应。
pub fn stats_from_json(
    jsons: &[&str],
    server_times: &[Option<i64>],
) -> Result<Vec<StatRow>, String> {
    let stored: Vec<StoredLog<'_>> = jsons
        .iter()
        .zip(server_times)
        .map(|(j, s)| (*j, *s, None))
        .collect();
    stats_from_stored(&stored)
}

/// [stats_from_json]，日志可以是瘦存 + 列（[StoredLog]）。
pub fn stats_from_stored(stored: &[StoredLog<'_>]) -> Result<Vec<StatRow>, String> {
    let (logs, results, extras) = parse_all(stored)?;
    let sel = select(&logs);
    Ok(stat_rows(&sel, &logs, &results, &extras))
}

type ParsedAll<'a> = (Vec<Log<'a>>, Vec<Option<WireResult<'a>>>, Vec<Extra<'a>>);

fn parse_all<'a>(stored: &[StoredLog<'a>]) -> Result<ParsedAll<'a>, String> {
    let mut logs = Vec::with_capacity(stored.len());
    let mut results = Vec::with_capacity(stored.len());
    let mut extras = Vec::with_capacity(stored.len());
    for (j, s, c) in stored {
        let (log, res, extra) = parse_wire(j, *s, *c)?;
        logs.push(log);
        results.push(res);
        extras.push(extra);
    }
    Ok((logs, results, extras))
}

fn stat_rows(
    sel: &Selection,
    logs: &[Log<'_>],
    results: &[Option<WireResult<'_>>],
    extras: &[Extra<'_>],
) -> Vec<StatRow> {
    let mut out = Vec::new();
    // 前序有效结果（`SrsScheduleResult.initial`：新卡、间隔 0、没有到期日）。
    let (mut prev_queue, mut prev_ivl, mut prev_due) = (0i64, 0i64, None::<i64>);
    let mut prev_mature = false;
    for (k, &i) in sel.order.iter().enumerate() {
        if sel.status[k] & STATUS_EFFECTIVE == 0 {
            continue;
        }
        let (log, extra) = (&logs[i], &extras[i]);
        let res = results[i].as_ref().map(Outcome::of);
        let kind = if log.kind == Kind::Review && matches!(log.rating, Some(1..=4)) {
            match extra.rtype {
                RType::Learn => Some(if prev_queue == 0 { 0 } else { 1 }),
                RType::Review => Some(if prev_ivl >= MATURE_INTERVAL_DAYS {
                    3
                } else {
                    2
                }),
                RType::Relearn => Some(4),
                RType::Filtered => Some(5),
                _ => None,
            }
        } else {
            None
        };
        let mut delta = 0;
        if let Some(r) = &res {
            let mature = r.queue == 2 && r.scheduled_days >= MATURE_INTERVAL_DAYS;
            if mature != prev_mature {
                delta = if mature { 1 } else { -1 };
                prev_mature = mature;
            }
        }
        if kind.is_some() || delta != 0 {
            out.push(StatRow {
                log_id: log.id.clone().into_owned(),
                occurred_at: log.occurred_at,
                utc_off: extra.utc_off,
                rating: kind.and(log.rating),
                kind: kind.unwrap_or(0),
                dur: extra.dur.max(0),
                // 按回忆率排的复习（日志 alg = rwkv）不看到期日，无所谓「提前」。
                prev_due_day: if kind.is_some()
                    && !extra.alg_rwkv
                    && extra.rtype == RType::Review
                    && prev_queue == 2
                {
                    prev_due
                } else {
                    None
                },
                maturity_delta: delta,
                anki_event: match (log.origin, log.anki_id) {
                    (Origin::Anki, Some(anki_id)) => Some(AnkiEvent {
                        anki_id,
                        physical: log.physical,
                        counter: log.counter,
                        kind: log.kind as i64,
                        rating_type: log.rating_type,
                        rating: log.rating,
                        dur: extra.dur,
                    }),
                    _ => None,
                },
            });
        }
        if let Some(r) = res {
            prev_queue = r.queue;
            prev_ivl = r.scheduled_days;
            prev_due = r.due_day;
        }
    }
    out
}

fn state_of(
    sel: Selection,
    logs: Vec<Log<'_>>,
    mut results: Vec<Option<WireResult<'_>>>,
) -> Result<State, String> {
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
    let r = results[last]
        .take()
        .expect("last effective log has a result");
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
pub fn states_from_json(
    text: &[u8],
    offs: &[u32],
    servers: &[i64],
    groups: &[u32],
) -> Result<Vec<u8>, String> {
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

/// 列模式每条日志带几个串（[select_columns]：id、writerId、revokes、cardId）。
pub const COLUMN_STRINGS: usize = 4;

/// 列模式批量：第 i 条日志的四个串 = `text[offs[4i]..offs[4i+1]]`（id）、`[4i+1..4i+2]`（writerId）、
/// `[4i+2..4i+3]`（revokes，无则空串且 bits 不带 `1<<7`）、`[4i+3..4i+4]`（cardId）。
///
/// 输出布局（小端）：`[u32 组边界 × (n_groups + 1)][u32 输入下标 × 去重后总数][i32 lastEffective × n_groups]
/// [i32 schedulerFrom × n_groups][u8 STATUS_* × 去重后总数]`；下标都是全局输入下标，-1 = 无。
pub fn select_columns(
    ints: &[i64],
    text: &[u8],
    offs: &[u32],
    groups: &[u32],
) -> Result<Vec<u8>, String> {
    if ints.len() % COLUMN_WORDS != 0 {
        return Err("bad history column layout".to_owned());
    }
    let n_logs = ints.len() / COLUMN_WORDS;
    if offs.len() != n_logs * COLUMN_STRINGS + 1
        || groups.is_empty()
        || *groups.last().unwrap() as usize != n_logs
    {
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
            id: Cow::Borrowed(slice(COLUMN_STRINGS * i)?),
            card: Cow::Borrowed(slice(COLUMN_STRINGS * i + 3)?),
            writer: Cow::Borrowed(slice(COLUMN_STRINGS * i + 1)?),
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
            revokes: (bits & (1 << 7) != 0)
                .then(|| slice(COLUMN_STRINGS * i + 2).map(Cow::Borrowed))
                .transpose()?,
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

/// Anki 导入器入库前判重：第 g 组 = 日志 `groups[g]..groups[g+1]`，组里第一条是导入日志、其余是
/// 这张逻辑卡的原生日志（调用方已筛好来源），第 i 条日志 = `text[offs[i]..offs[i+1]]`（落库 JSON）。
/// 输出每组一个字节：1 = 导入日志与组里某条原生日志等价（[import_equivalent]）。
pub fn import_equivalent_any(text: &[u8], offs: &[u32], groups: &[u32]) -> Result<Vec<u8>, String> {
    let n_logs = offs.len().checked_sub(1).ok_or("bad import batch layout")?;
    if groups.is_empty() || *groups.last().unwrap() as usize != n_logs {
        return Err("bad import batch layout".to_owned());
    }
    let text = std::str::from_utf8(text).map_err(|_| "import batch is not UTF-8".to_owned())?;
    let mut logs: Vec<Log<'_>> = Vec::with_capacity(n_logs);
    for w in offs.windows(2) {
        let (a, b) = (w[0] as usize, w[1] as usize);
        if a > b || b > text.len() || !text.is_char_boundary(a) || !text.is_char_boundary(b) {
            return Err("bad import batch offsets".to_owned());
        }
        logs.push(parse_wire(&text[a..b], None, None)?.0);
    }
    let mut out = Vec::with_capacity(groups.len() - 1);
    for g in groups.windows(2) {
        let (a, b) = (g[0] as usize, g[1] as usize);
        if a >= b || b > n_logs {
            return Err("bad import batch groups".to_owned());
        }
        out.push(u8::from(
            logs[a + 1..b]
                .iter()
                .any(|n| import_equivalent(&logs[a], n)),
        ));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wire(id: &str, kind: &str, hlc: &str, at: i64, extra: &str) -> String {
        format!(
            r#"{{"id":"{id}","p":"p","card":"c","kind":"{kind}","hlc":"{hlc}","at":{at}{extra}}}"#
        )
    }

    #[test]
    fn undo_revokes_and_state_falls_back() {
        let l1 = wire(
            "l1",
            "review",
            "10:0:A",
            10,
            r#","rtype":"review","rating":3,"res":{"queue":"review","dueDay":10}"#,
        );
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
        let a = wire(
            "a",
            "review",
            "1000000:0:A",
            0,
            r#","rtype":"review","res":{"queue":"review","dueDay":1}"#,
        );
        let b = wire(
            "b",
            "review",
            "9000000:0:B",
            0,
            r#","rtype":"review","res":{"queue":"review","dueDay":2}"#,
        );
        let s = state_from_json(&[&a, &b], &[None, Some(0)]).unwrap();
        assert_eq!(s.last_log_id.as_deref(), Some("a"));
    }

    #[test]
    fn malformed_log_is_an_error() {
        assert!(state_from_json(&[r#"{"id":"x"}"#], &[None]).is_err());
        assert!(state_from_json(&[&wire("x", "review", "nohlc", 0, "")], &[None]).is_err());
        assert!(
            state_from_json(
                &[&wire("x", "review", "1:0:A", 0, r#","rating":3.5"#)],
                &[None]
            )
            .is_err()
        );
    }

    // ---- BUG-4218：同一事件的多 ID 副本（profile 合并在 BUG-4217 修好前写出的重复）

    /// 卡 [card] 上一条评分复习（落库 JSON）：rating 3、res 的 dueDay = [due]。
    fn review_on(card: &str, id: &str, hlc: &str, at: i64, due: i64, extra: &str) -> String {
        format!(
            r#"{{"id":"{id}","p":"p","card":"{card}","kind":"review","hlc":"{hlc}","at":{at},"rtype":"review","rating":3,"res":{{"queue":"review","dueDay":{due}}}{extra}}}"#
        )
    }

    fn review(id: &str, hlc: &str, at: i64, due: i64) -> String {
        review_on("c", id, hlc, at, due, "")
    }

    fn selection_of(jsons: &[&str]) -> Selection {
        let logs: Vec<Log<'_>> = jsons
            .iter()
            .map(|j| parse_full(j, None).unwrap().0)
            .collect();
        select(&logs)
    }

    /// [id] 那条日志在选取里的 `STATUS_*` 位（不在排序里 = None）。
    fn status_of(jsons: &[&str], id: &str) -> Option<u8> {
        let logs: Vec<Log<'_>> = jsons
            .iter()
            .map(|j| parse_full(j, None).unwrap().0)
            .collect();
        let sel = select(&logs);
        let at = sel.order.iter().position(|&i| logs[i].id == id)?;
        Some(sel.status[at])
    }

    fn effective_ids(jsons: &[&str]) -> Vec<String> {
        let logs: Vec<Log<'_>> = jsons
            .iter()
            .map(|j| parse_full(j, None).unwrap().0)
            .collect();
        let sel = select(&logs);
        sel.order
            .iter()
            .zip(&sel.status)
            .filter(|(_, s)| **s & STATUS_EFFECTIVE != 0)
            .map(|(&i, _)| logs[i].id.to_string())
            .collect()
    }

    #[test]
    fn duplicate_event_copies_count_once() {
        // 合并写出的两份：内容逐字相同，只有 ID 不同（规则 ID + 兜底 ID / 原 v7 + 兜底 v5）。
        let first = review("l0", "5:0:A", 5, 5);
        let orig = review("b-orig", "10:0:A", 10, 10);
        let copy = review("a-copy", "10:0:A", 10, 10);
        for jsons in [[&first, &orig, &copy], [&copy, &first, &orig]] {
            let jsons: Vec<&str> = jsons.iter().map(|s| s.as_str()).collect();
            // 组里 ID 最小的一条是代表；另一份仍在排序里（重放要给它算投影行），标副本、不算有效。
            assert_eq!(effective_ids(&jsons), ["l0", "a-copy"]);
            assert_eq!(selection_of(&jsons).order.len(), 3);
            assert_eq!(status_of(&jsons, "b-orig"), Some(STATUS_DUPLICATE));
            assert_eq!(status_of(&jsons, "a-copy"), Some(STATUS_EFFECTIVE));
            let s = state_from_json(&jsons, &[None, None, None]).unwrap();
            assert_eq!(s.last_log_id.as_deref(), Some("a-copy"));
            // 统计 / 优化器走同一个选取：这次复习只算一次。
            let rows = stats_from_json(&jsons, &[None, None, None]).unwrap();
            assert_eq!(
                rows.iter().map(|r| r.log_id.as_str()).collect::<Vec<_>>(),
                ["l0", "a-copy"]
            );
            let eff = crate::projection::effective_logs(
                &jsons
                    .iter()
                    .map(|j| parse_full(j, None).unwrap())
                    .collect::<Vec<_>>(),
            );
            assert_eq!(eff.len(), 2);
        }
    }

    #[test]
    fn undoing_either_copy_revokes_the_event() {
        let first = review("l0", "5:0:A", 5, 5);
        let orig = review("b-orig", "10:0:A", 10, 10);
        let copy = review("a-copy", "10:0:A", 10, 10);
        for target in ["b-orig", "a-copy"] {
            let undo = wire(
                "u1",
                "undo",
                "11:0:A",
                11,
                &format!(r#","revokes":"{target}""#),
            );
            let jsons = [first.as_str(), orig.as_str(), copy.as_str(), undo.as_str()];
            assert_eq!(effective_ids(&jsons), ["l0"], "undo {target}");
            let s = state_from_json(&jsons, &[None; 4]).unwrap();
            assert_eq!(s.last_log_id.as_deref(), Some("l0"), "undo {target}");
            assert_eq!(s.due_day, Some(5));
            // 两份都带撤销标记，非代表的那份另带副本标记；undo 本身仍是撤销者。
            assert_eq!(status_of(&jsons, "a-copy"), Some(STATUS_REVOKED));
            assert_eq!(
                status_of(&jsons, "b-orig"),
                Some(STATUS_REVOKED | STATUS_DUPLICATE)
            );
            assert_eq!(status_of(&jsons, "u1"), Some(STATUS_REVOKER));
        }
    }

    #[test]
    fn restore_replay_copy_is_a_new_event() {
        // 恢复备份的重放副本照抄内容但取新 HLC（restore_plan.dart `_replayOf`）：不与被撤销的原日志成组。
        let orig = review("l1", "10:0:A", 10, 10);
        let undo = wire("u1", "undo", "11:0:A", 11, r#","revokes":"l1""#);
        let replay = review_on(
            "c",
            "r1",
            "12:0:A",
            10,
            10,
            r#","restoreOf":"bk","replayOf":"l1""#,
        );
        let jsons = [orig.as_str(), undo.as_str(), replay.as_str()];
        assert_eq!(effective_ids(&jsons), ["r1"]);
        let s = state_from_json(&jsons, &[None; 3]).unwrap();
        assert_eq!(s.last_log_id.as_deref(), Some("r1"));
    }

    #[test]
    fn same_hlc_on_another_card_or_with_other_content_is_not_a_copy() {
        // 血统里另一张卡（前身）上同 HLC 的日志、同 HLC 但评分 / 发生时刻不同的日志，都不是同一事件。
        let mine = review("b", "10:0:A", 10, 10);
        let pred = review_on("pred", "a", "10:0:A", 10, 20, "");
        assert_eq!(effective_ids(&[&mine, &pred]), ["a", "b"]);
        let other_at = review("a", "10:0:A", 11, 20);
        assert_eq!(effective_ids(&[&mine, &other_at]), ["a", "b"]);
        let other_rating = mine
            .replace(r#""rating":3"#, r#""rating":2"#)
            .replace(r#""id":"b""#, r#""id":"a""#);
        assert_eq!(effective_ids(&[&mine, &other_rating]), ["a", "b"]);
    }

    /// 卡 [card] 上一条 Anki 导入的评分复习（HLC / 时刻都由 revlog id [rid] 派生，与导入器同形）。
    fn anki_on(card: &str, id: &str, rid: i64, rating: i64, due: i64) -> String {
        format!(
            r#"{{"id":"{id}","p":"p","card":"{card}","kind":"review","hlc":"{rid}:0:anki","at":{rid},"origin":"anki","ankiId":{rid},"rtype":"review","rating":{rating},"res":{{"queue":"review","dueDay":{due}}}}}"#
        )
    }

    #[test]
    fn anki_revlog_imported_onto_two_cards_of_one_lineage_counts_once() {
        // BUG-4242：Lapis 迁到 Fushi 卡片（新卡继承旧卡历史）后再从 Anki 迁一次，同一条 revlog 落在新卡上又写一份
        // （日志 ID 由卡派生，不同）。血统里两份是同一次复习：只算一份，状态 / 统计 / 重放都只推进一次。
        let on_old = anki_on("lapis", "b-old", 1000, 3, 5);
        let on_new = anki_on("fushi", "a-new", 1000, 3, 5);
        let later = anki_on("lapis", "c-later", 2000, 3, 9);
        let jsons = [on_old.as_str(), on_new.as_str(), later.as_str()];
        assert_eq!(effective_ids(&jsons), ["a-new", "c-later"]);
        assert_eq!(status_of(&jsons, "b-old"), Some(STATUS_DUPLICATE));
        let rows = stats_from_json(&jsons, &[None, None, None]).unwrap();
        assert_eq!(rows.len(), 2);
    }

    #[test]
    fn anki_logs_with_other_rating_or_revlog_or_native_origin_are_not_grouped_across_cards() {
        // 不同 revlog / 评分不同的 Anki 日志照旧各算各的；原生（fushi）日志仍按卡区分（前身卡上同 HLC 的原生日志不是副本）。
        let a = anki_on("lapis", "a", 1000, 3, 5);
        let other_rid = anki_on("fushi", "b", 1001, 3, 5);
        let other_rating = anki_on("fushi", "c", 1000, 2, 5);
        assert_eq!(effective_ids(&[&a, &other_rid]), ["a", "b"]);
        assert_eq!(effective_ids(&[&a, &other_rating]), ["a", "c"]);
        let mine = review("b", "10:0:A", 10, 10);
        let pred = review_on("pred", "a", "10:0:A", 10, 20, "");
        assert_eq!(effective_ids(&[&mine, &pred]), ["a", "b"]);
    }

    #[test]
    fn undo_logs_are_never_grouped() {
        // 两条 undo 撞同一 HLC（不会发生，但 undo 的效果只看 revokes）：各撤各的。
        let l1 = review("l1", "10:0:A", 10, 10);
        let l2 = review("l2", "11:0:A", 11, 11);
        let u1 = wire("u1", "undo", "12:0:A", 12, r#","revokes":"l1""#);
        let u2 = wire("u2", "undo", "12:0:A", 12, r#","revokes":"l2""#);
        assert!(effective_ids(&[&l1, &l2, &u1, &u2]).is_empty());
    }

    #[test]
    fn equivalent_import_rule_still_applies_to_copies() {
        // 原生评分 + 同一条 Anki revlog 的两份导入副本（ankiId 与原生时刻相差 1 秒内）：两份都被判与原生
        // 等价，只有原生那条有效。
        let native = review("n1", "1000:0:A", 1000, 1);
        let anki = |id: &str| {
            format!(
                r#"{{"id":"{id}","p":"p","card":"c","kind":"review","hlc":"1500:0:anki","at":1500,"origin":"anki","ankiId":1500,"rtype":"review","rating":3,"res":{{"queue":"review","dueDay":2}}}}"#
            )
        };
        let (a1, a2) = (anki("y-anki"), anki("x-anki"));
        let jsons = [native.as_str(), a1.as_str(), a2.as_str()];
        assert_eq!(effective_ids(&jsons), ["n1"]);
        assert_eq!(status_of(&jsons, "x-anki"), Some(STATUS_EQUIVALENT_IMPORT));
        assert_eq!(
            status_of(&jsons, "y-anki"),
            Some(STATUS_EQUIVALENT_IMPORT | STATUS_DUPLICATE)
        );
        // 超出 1 秒容差：两份副本仍只算一份，且有效。
        let far = |id: &str| anki(id).replace(r#""ankiId":1500"#, r#""ankiId":2001"#);
        let (f1, f2) = (far("y-anki"), far("x-anki"));
        assert_eq!(effective_ids(&[&native, &f1, &f2]), ["n1", "x-anki"]);
    }

    #[test]
    fn long_histories_group_copies_the_same_way() {
        // > 32 条走哈希表分支：与短历史同一结果。
        let mut owned: Vec<String> = (0..40)
            .map(|k| review(&format!("l{k:02}"), &format!("{}:0:A", 100 + k), 100 + k, k))
            .collect();
        owned.push(review("a-copy", "120:0:A", 120, 20));
        owned.push(wire("u1", "undo", "200:0:A", 200, r#","revokes":"l39""#));
        let jsons: Vec<&str> = owned.iter().map(|s| s.as_str()).collect();
        let eff = effective_ids(&jsons);
        assert_eq!(eff.len(), 39);
        assert!(eff.contains(&"a-copy".to_owned()));
        assert!(!eff.contains(&"l20".to_owned()));
        let s = state_from_json(&jsons, &vec![None; jsons.len()]).unwrap();
        assert_eq!(s.last_log_id.as_deref(), Some("l38"));
    }

    #[test]
    fn column_mode_reads_card_and_groups_copies() {
        // 列模式（Dart SrsCardHistory）：每条日志四个串 id / writerId / revokes / cardId。
        let rows: [(&str, &str, i64, &str); 3] = [
            ("b-orig", "c", 10, ""),
            ("a-copy", "c", 10, ""),
            ("p1", "pred", 10, ""),
        ];
        let mut ints: Vec<i64> = Vec::new();
        let mut text = String::new();
        let mut offs: Vec<u32> = vec![0];
        for (id, card, phys, revokes) in rows {
            // kind review(0) | 评分类 1<<5 | 有结果 1<<6。
            ints.extend_from_slice(&[phys, 0, NONE_I64, phys, NONE_I64, 3, (1 << 5) | (1 << 6)]);
            for part in [id, "A", revokes, card] {
                text.push_str(part);
                offs.push(text.len() as u32);
            }
        }
        let out = select_columns(&ints, text.as_bytes(), &offs, &[0, 3]).unwrap();
        let u32_at = |k: usize| u32::from_le_bytes(out[k * 4..k * 4 + 4].try_into().unwrap());
        // [bounds × 2][order × 3][last][sched][status × 3]：排序 a-copy < b-orig < p1（同 HLC 按 ID）；
        // b-orig 是 a-copy 的副本，前身卡上同 HLC 的 p1 不是。
        assert_eq!(out.len(), 2 * 4 + 3 * 4 + 4 + 4 + 3);
        assert_eq!((u32_at(0), u32_at(1)), (0, 3));
        assert_eq!([u32_at(2), u32_at(3), u32_at(4)], [1, 0, 2]);
        assert_eq!(u32_at(5), 2, "last effective = p1");
        assert_eq!(
            &out[out.len() - 3..],
            [STATUS_EFFECTIVE, STATUS_DUPLICATE, STATUS_EFFECTIVE]
        );
        // 旧布局（三个串）判坏。
        assert!(select_columns(&ints, text.as_bytes(), &offs[..10], &[0, 3]).is_err());
    }
}
