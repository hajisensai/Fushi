//! 复习排队：牌组计数（新 / 学习 / 到期，含每日上限与子树截断）与出卡（下一张、排除它之后的再下一张）。
//!
//! 以前在 Dart（`SrsDbStore._countContext` / `_deckTallies` / `_countTree` / `nextCard` 的 SQL `pick`）：评一张卡
//! 要把计数上下文整份重建三遍、每遍十来次跨 isolate 的 Drift 往返。L2 搬进 Rust 后一次命令算完，但每次排队仍按
//! 子树全部卡聚合计数、顺着到期索引扫全部到期卡（十万张到期卡约 100 ms）。现在计数原料、到期复习候选、学习卡与
//! 今天的作答常驻内存（store/queue.rs 的会话，随写入按 id 增量重读），一次排队：
//!
//! - 牌组树每次照读（只与牌组数有关：改每日上限、挪牌组立即生效）；
//! - 每个牌组自己的计数原料、今天已学 / 已复习的卡、最近 30 天每天的复习数直接取会话里的；
//! - 牌组树计数对齐 Anki v3 的 limit tree（见 [count_tree]），口径与旧 Dart 逐项相同
//!   （fushi_engine test/srs/srs_study_vectors_test.dart 用旧实现生成的向量钉住；本文件的测试拿 L2 的逐条 SQL
//!   实现当基准，随机写入 / 跨日 / 回滚下逐步对拍）；
//! - 出卡：到期的学习卡 → 复习卡与新卡（两者的先后按所点牌组的「新卡与复习」[NewMix]：缺省复习全部在前；
//!   复习卡按「复习顺序」[ReviewOrder]，缺省是会话里按块下界取此刻可提取度最低的一张，其余顺序走会话里按静态键
//!   懒建的有序索引，都不扫全部到期卡；新卡走部分索引序 `LIMIT 1`，命中第一张即停）→ 20 分钟内到期的学习卡。
//!   这两项与新卡顺序一样随参数继承取所点牌组的 own 祖先；own 祖先按 RWKV 排程时整棵子树的复习顺序固定按 R。
//!   自定义学习（[CustomPicker]）不受这两项影响；
//! - RWKV-Instant 的牌组：分数由 Dart 侧的 RWKV 服务给（另一个原生库），是**今天结束时刻**的 R——R 到今天结束
//!   会降到目标保留率以下的卡就是「今天到期」，与 FSRS 按天到期同一粒度，计数、出卡都用它，但**不**当新卡负荷：
//!   RWKV 牌组不按复习量调整新卡（恒为每日新卡上限），也不计入 FSRS 祖先的负荷；这里只做排队规则（目标保留率、
//!   同日间隔守卫、每天最少复习数、按 R 升序），与旧 Dart `_instantReviews` 同口径。
//!
//! 请求 `{"deck"?: 根牌组, "now", "utcOff", "rollover", "exclude"?: [卡], "pick"?: bool,
//!        "rwkv"?: {"decks": {牌组: [目标保留率, 每天最少, 间隔次数, 间隔秒数]}, "cands": [[卡, 牌组, 上次作答|null, R]]}}`；
//! 结果 `{"counts": {牌组: [新, 学习, 到期, 总数, 新卡上限, 新卡配额, 复习预算, 调整原因|null]}, "next", "after", "eligible", "wakeIn"}`
//! （调整原因 = Dart `SrsNewCardBudgetReason` 的名字：reduced / paused / increased；`wakeIn` = 出卡排空时
//! 距最早又排得出卡还有多少毫秒，null = 没有不靠写入就会到来的时刻，见 [Picker::wake]）。
//! 牌组设置里影响计数的「新卡计划」（`newPlan`）与 RWKV 的「忽略每日复习上限」（`rwkvQueue.ignoreLimit`）都从牌组树读
//! （[NewCardPlan::of] / `DeckTree::ignores_review_limit`）；按 RWKV 排程的牌组（`DeckTree::uses_rwkv`，看参数归属
//! 祖先的算法）新卡计划不生效，复习预算为 0、调整原因为 null。
//! 每日复习上限与 RWKV「每天最少复习数」按牌组的「每日上限单位」（`limitUnit`：作答次数 / 卡片数 / 分钟，见
//! [LimitUnit]）统计今天已用的量，同样从牌组树读。
//! 没给 `deck` = 全部牌组（牌组列表）；给了但不在树里 = `counts` 为 null。

use std::collections::{HashMap, HashSet};

use rusqlite::{Connection, params_from_iter, types::Value as Sql};
use serde_json::{Value, json};

use crate::projection::Day;
use crate::store::queue::{DeckRaw, DueCand, LEARN_AHEAD_MS, LogState, Session, StudyHub};
use crate::store::sync2::config::DeckTree;
use crate::store::sync2::sql;

/// 卡「可出」：可见、未暂停、归 Fushi 排程、没埋或埋到期（绑定一个参数：今天）。与 queue.rs `Row::live` 同一判据。
const LIVE: &str = "hidden = 0 AND suspended = 0 AND scheduler = 'fushi' AND (buried_until_day IS NULL OR buried_until_day <= ?)";
const DAY_MS: i64 = 86_400_000;
/// 「忽略每日复习上限」的牌组这一层的剩余复习额度（实际出卡数由合格的卡数决定）。
const UNLIMITED_REVIEWS: i64 = 1 << 30;

/// 复习顺序（牌组寄存器 `reviewOrder`，视图键 `ro`；Dart `SrsReviewCardOrder`）。除 R 以外都是静态键（store/
/// queue.rs `order_key`），同键按当天哈希 h(卡, 今天) 断平、再按 id：
///
/// | wire | 排序（升序） | Anki `reviewOrder` 导出 / 导入 |
/// |---|---|---|
/// | `retrievability` | 此刻 R（NULL 最前），同 R 按 id | 7 / 其余 |
/// | `dueDate` | (到期日, h, id) | 0 / 0、1、2 |
/// | `difficulty` | (D 为空, −D, h, id)：最难的先出 | 5 / 5 |
/// | `intervalAscending` | (间隔天数, h, id) | 3 / 3 |
/// | `random` | (h, id) | 8 / 8 |
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub(crate) enum ReviewOrder {
    #[default]
    Retrievability,
    DueDate,
    Difficulty,
    IntervalAscending,
    Random,
}

impl ReviewOrder {
    /// 不认识 / 没写 = 缺省（可提取度从低到高，加这项设置之前的行为）。
    pub(crate) fn from_wire(wire: Option<&str>) -> ReviewOrder {
        match wire {
            Some("dueDate") => ReviewOrder::DueDate,
            Some("difficulty") => ReviewOrder::Difficulty,
            Some("intervalAscending") => ReviewOrder::IntervalAscending,
            Some("random") => ReviewOrder::Random,
            _ => ReviewOrder::Retrievability,
        }
    }
}

/// 新卡与复习怎么排（牌组寄存器 `newMix`，视图键 `mx`；Dart `SrsNewCardMix`）。三种都是到期的学习卡最先、
/// 20 分钟内到期的学习卡最后兜底。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum NewMix {
    /// 复习全部出完再出新卡（缺省，加这项设置之前的行为；Anki 1）。
    #[default]
    AfterReviews,
    /// 新卡先出，新卡上限用完或没有新卡了再出复习（Anki 2）。
    BeforeReviews,
    /// 按今天的总量均匀穿插（Anki 0），见 [Picker::next]。
    Mixed,
}

impl NewMix {
    /// 不认识 / 没写 = 缺省（复习之后）。
    pub(crate) fn from_wire(wire: Option<&str>) -> NewMix {
        match wire {
            Some("beforeReviews") => NewMix::BeforeReviews,
            Some("mixed") => NewMix::Mixed,
            _ => NewMix::AfterReviews,
        }
    }
}

/// 每日复习上限（`rp`）与 RWKV「每天最少复习数」（`rwkvQueue.minReviews`）按什么计（牌组寄存器 `limitUnit`，
/// 视图键 `lu`；Dart `SrsLimitUnit`）。三种都只看今天的**复习作答**（`review_type = 'review'` 的日志：作答时卡在
/// 复习队列；新卡第一次学、学习 / 重学步长上的作答不算），记在卡**现在**所在的牌组上，隐藏的卡不算（与以前的
/// 「今天已复习的卡」同一批日志）：
///
/// | wire | 今天已用 | 剩余 |
/// |---|---|---|
/// | `reviews`（缺省，没写过的存量牌组也是它） | 复习作答条数（同一张卡答几次算几次；Anki 的 review limit 也是按复习队列的作答逐次计） | 上限 − 已用 |
/// | `cards` | 复习过的不同卡片数（加这项设置之前的口径） | 上限 − 已用 |
/// | `minutes` | 复习作答用时之和，上限单位是分钟 | 已用 < 上限：不截；否则 0（到了就停，不预估以后的耗时） |
///
/// 上限是牌组自己的值（不随参数继承），单位也是；「每天最少」随参数继承，用参数归属牌组的单位。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum LimitUnit {
    #[default]
    Reviews,
    Cards,
    Minutes,
}

impl LimitUnit {
    /// 不认识 / 没写 = 缺省（作答次数）。
    pub(crate) fn from_wire(wire: Option<&str>) -> LimitUnit {
        match wire {
            Some("cards") => LimitUnit::Cards,
            Some("minutes") => LimitUnit::Minutes,
            _ => LimitUnit::Reviews,
        }
    }

    /// 牌组视图里写的单位。
    fn of_view(view: &Value) -> LimitUnit {
        LimitUnit::from_wire(view["lu"].as_str())
    }

    /// 按这个单位，[t]（一个牌组自己或整棵子树）今天已用了多少（分钟单位下是毫秒，与 [Self::limit_in_usage] 同量纲）。
    fn used(self, t: &Tally) -> i64 {
        match self {
            LimitUnit::Reviews => t.review_answers,
            LimitUnit::Cards => t.review_done,
            LimitUnit::Minutes => t.review_ms,
        }
    }

    /// 上限 [limit]（用户写的数）换成 [Self::used] 的量纲。
    fn limit_in_usage(self, limit: i64) -> i64 {
        match self {
            LimitUnit::Minutes => limit.saturating_mul(60_000),
            _ => limit,
        }
    }

    /// 上限 [limit] 下 [t] 今天还剩的复习额度，按**卡**计（排队、计数逐张扣）：次数 / 卡片数 = 上限 − 已用（每出
    /// 一张至少用掉一次作答，所以按次数剩下的也是还能出的卡数上界）；分钟 = 没用满就不截，用满了为 0。
    fn review_room(self, limit: i64, t: &Tally) -> i64 {
        let left = self.limit_in_usage(limit) - self.used(t);
        match self {
            LimitUnit::Minutes if left > 0 => UNLIMITED_REVIEWS,
            LimitUnit::Minutes => 0,
            _ => left.max(0),
        }
    }

    /// 分钟单位下上限 [limit] 减去 [t] 今天的复习用时还剩几分钟（不足一分钟按一分钟，用满为 0）；其余单位 None。
    /// 与 [Self::review_room] 同一个「已用 / 上限」口径：剩余 > 0 ⇔ 这一层不截复习卡。
    fn minutes_left(self, limit: i64, t: &Tally) -> Option<i64> {
        match self {
            LimitUnit::Minutes => {
                let left = (self.limit_in_usage(limit) - self.used(t)).max(0);
                Some((left + 59_999) / 60_000)
            }
            _ => None,
        }
    }
}

/// 出的一张是哪一类（「再下一张」按它虚拟扣掉一张的计数）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Learning,
    Review,
    New,
}

/// 一个牌组自己（或整棵子树）的原始卡数与今天的学习量。
#[derive(Clone, Copy, Default, Debug)]
struct Tally {
    total: i64,
    new_avail: i64,
    learn: i64,
    due: i64,
    new_done: i64,
    /// 今天复习过的不同卡片数。
    review_done: i64,
    /// 今天的复习作答条数（[LimitUnit::Reviews]）。
    review_answers: i64,
    /// 今天复习作答的用时之和，毫秒（[LimitUnit::Minutes]）。
    review_ms: i64,
    /// 新卡按复习量调节时拿来和预算比的「今天的复习量」（[new_card_budget] 的 `due`）：今天已复习 + 现在剩余到期，
    /// 按这个牌组的每日复习上限截断；RWKV 牌组恒为 0（合格的卡不是负荷信号，不推高 FSRS 祖先，见 [run]）。
    load: i64,
}

impl Tally {
    fn add(&mut self, o: &Tally) {
        self.total += o.total;
        self.new_avail += o.new_avail;
        self.learn += o.learn;
        self.due += o.due;
        self.new_done += o.new_done;
        self.review_done += o.review_done;
        self.review_answers += o.review_answers;
        self.review_ms += o.review_ms;
        self.load += o.load;
    }

    fn of(r: DeckRaw) -> Tally {
        Tally {
            total: r.total,
            new_avail: r.new_avail,
            learn: r.learn,
            due: r.due,
            new_done: 0,
            review_done: 0,
            review_answers: 0,
            review_ms: 0,
            load: r.due,
        }
    }
}

/// 今天的新卡配额（Dart 侧只剩结果类型 `SrsNewCardBudget`，规则只在这里）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Budget {
    pub limit: i64,
    pub allowed: i64,
    pub review_budget: i64,
    /// None / "reduced" / "paused" / "increased"（Dart `SrsNewCardBudgetReason` 的名字）。
    pub reason: Option<&'static str>,
}

/// 新卡计划（牌组自己的 `newPlan` 寄存器，物化视图键 `npl`；Dart 值对象 `SrsNewCardPlan`）：缺项 / 坏值回落
/// 默认，越界的夹到合法范围，与 `SrsNewCardPlan.fromValue` 同一条规则。缺省 = 按复习量只减不增、预算 150%，
/// 与加这项设置之前的行为相同。
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct NewCardPlan {
    pub auto_load: bool,
    pub budget_percent: i64,
    pub boost_percent: i64,
}

impl NewCardPlan {
    pub const DEFAULT_BUDGET_PERCENT: i64 = 150;
    pub const MIN_BUDGET_PERCENT: i64 = 50;
    pub const MAX_BUDGET_PERCENT: i64 = 1000;
    pub const MAX_BOOST_PERCENT: i64 = 200;

    pub fn of(v: &Value) -> NewCardPlan {
        let read = |k: &str, fallback: i64, lo: i64, hi: i64| {
            v.get(k)
                .and_then(Value::as_i64)
                .map_or(fallback, |n| n.clamp(lo, hi))
        };
        if !v.is_object() {
            return NewCardPlan::default();
        }
        NewCardPlan {
            auto_load: v.get("auto") != Some(&Value::Bool(false)),
            budget_percent: read(
                "budget",
                Self::DEFAULT_BUDGET_PERCENT,
                Self::MIN_BUDGET_PERCENT,
                Self::MAX_BUDGET_PERCENT,
            ),
            boost_percent: read("boost", 0, 0, Self::MAX_BOOST_PERCENT),
        }
    }
}

impl Default for NewCardPlan {
    fn default() -> Self {
        NewCardPlan {
            auto_load: true,
            budget_percent: Self::DEFAULT_BUDGET_PERCENT,
            boost_percent: 0,
        }
    }
}

/// 新卡数按复习量自动调节（[NewCardPlan::auto_load] 关掉时恒为每日上限、预算记 0）：
/// - 预算 = 最近 30 天有复习的天的日均 × `budget_percent`%（四舍五入，远离零），不低于上限 × 10；有复习的天
///   不足 7 天时就是上限 × 10；
/// - 到期数 ≤ 预算不变；超过 2 倍预算当天不出新卡；其间线性缩减；
/// - 到期数 < 预算一半且 `boost_percent` > 0：从一半预算到 0 线性增加，最多 +boost_percent%（"increased"）。
pub(crate) fn new_card_budget(limit: i64, due: i64, last30: &[i64], plan: NewCardPlan) -> Budget {
    let result = |allowed: i64, review_budget: i64, reason: Option<&'static str>| Budget {
        limit,
        allowed,
        review_budget,
        reason,
    };
    if !plan.auto_load {
        return result(limit, 0, None);
    }
    let active: Vec<i64> = last30.iter().copied().filter(|n| *n > 0).collect();
    let floor = limit * 10;
    let budget = if active.len() < 7 {
        floor
    } else {
        let avg = active.iter().sum::<i64>() as f64 / active.len() as f64;
        ((avg * plan.budget_percent as f64 / 100.0).round() as i64).max(floor)
    };
    if budget <= 0 {
        return result(limit, budget, None);
    }
    if due > budget * 2 {
        return result(0, budget, Some("paused"));
    }
    if due > budget {
        let factor = 1.0 - (due - budget) as f64 / budget as f64;
        let allowed = ((limit as f64 * factor).floor() as i64).max(0).min(limit);
        return result(
            allowed,
            budget,
            if allowed < limit {
                Some("reduced")
            } else {
                None
            },
        );
    }
    let half = budget as f64 / 2.0;
    if plan.boost_percent > 0 && (due as f64) < half {
        let share = 1.0 - due as f64 / half;
        let allowed = limit + ((limit * plan.boost_percent) as f64 / 100.0 * share).floor() as i64;
        if allowed > limit {
            return result(allowed, budget, Some("increased"));
        }
    }
    result(limit, budget, None)
}

/// 牌组树里一个节点的计数。
#[derive(Clone, Copy, Debug)]
struct Count {
    sub: Tally,
    budget: Budget,
    new_remaining: i64,
    review_remaining: i64,
    new_count: i64,
    review_count: i64,
    learn_count: i64,
    /// 牌组按分钟计复习上限（[LimitUnit::Minutes]，且这一层没开「忽略每日复习上限」）时今天还剩的复习分钟
    /// （[LimitUnit::minutes_left]）；其余单位为 None。分钟单位下 [Self::review_count] 是「没用满就不截」后的全部
    /// 合格 / 到期卡（可能成千），牌组列表的到期一格改显示这个剩余量。
    review_minutes_left: Option<i64>,
}

/// RWKV-Instant 一个牌组的排队设置：目标保留率与 `SrsRwkvQueueSettings`。
#[derive(Clone, Copy, Debug)]
struct InstantDeck {
    target: f64,
    min_reviews: i64,
    repeat_reviews: i64,
    repeat_seconds: i64,
}

/// 一次排队的上下文：牌组树、「今天」、日志里来的那部分（会话常驻的，或测试基准每次扫的）。
struct Ctx<'a> {
    tree: DeckTree,
    day: Day,
    now: i64,
    today: i64,
    logs: &'a LogState,
}

impl Ctx<'_> {
    fn day_start(&self, day: i64) -> i64 {
        day * DAY_MS + self.day.rollover_hour * 3_600_000 - self.day.utc_offset_min * 60_000
    }

    fn parent(&self, id: &str) -> Option<&str> {
        self.tree.decks.get(id).and_then(|d| d.parent.as_deref())
    }
}

fn int(v: &Value, k: &str, d: i64) -> i64 {
    v.get(k).and_then(Value::as_i64).unwrap_or(d)
}

/// 排队里仍走 SQL 的查询（新卡按索引序取第一张、自定义学习、[SqlSource]）落在哪张表、按什么分区、ID 怎么进出：
/// 协议 3 是 `srs_cards_cache` / `srs_notes_cache` 按 profile 分区、ID 列经 `srs_id` / `srs_idt` 编解码（[P3Tables]）；
/// 新代是缓存层的 `cards` / `notes` 按集合号分区、ID 列存 `Ref`（`store/gen4/cmd/study.rs`）。排队规则只有本文件这一份。
pub(crate) trait Tables {
    fn conn(&self) -> &Connection;
    /// 卡片缓存表名。
    fn cards(&self) -> &'static str;
    /// 排队的那几条按索引设计的查询里卡片表的写法（[CardIx]）：协议 3 就是表名（查询计划交给 SQLite，`schema.rs` v9
    /// 的注释与 [tests] 的计划测试钉住）；新代钉住对应的部分索引（`INDEXED BY`）——新代库带手写的规划统计，「按牌组 +
    /// 队列取出再排序」与「沿新卡索引序取第一张」在统计上看不出谁便宜，不能交给规划器猜。
    fn cards_via(&self, ix: CardIx) -> String;
    /// 笔记缓存表名。
    fn notes(&self) -> &'static str;
    /// 分区条件（[alias] = 列名前缀，如 `"n."`；绑定一个参数 [Tables::scope_arg]）。
    fn scope(&self, alias: &str) -> String;
    /// 按 id 点读时的分区条件（同样绑定 [Tables::scope_arg]）：协议 3 写成 `+profile_uid` 只当过滤、让 SQLite 走 id 主键；
    /// 新代主键是 (col, id)，照常写。
    fn scope_by_id(&self) -> &'static str;
    fn scope_arg(&self) -> Sql;
    /// 一个 ID 参数的占位符。
    fn mark(&self) -> &'static str;
    /// 结果里取文本 ID 的列表达式（[col] = 列名）。
    fn id_sel(&self, col: &str) -> String;
    /// 一个 ID 参数的值。
    fn id_arg(&self, id: &str) -> Sql;
    /// 读出 [Tables::id_sel] 那一列的文本 ID。
    fn id_get(&self, r: &rusqlite::Row<'_>, i: usize) -> rusqlite::Result<String>;
    /// 自定义学习「卡在 [since] 之后有作答日志」：对 `id` 列的条件与它的参数。[resident] = 常驻会话的计数上下文（测试
    /// 基准没有），[today_start] = 它「今天的作答」从哪一刻起（[LogState::window] 的第二项）：实现可以直接读它，不再
    /// 另查日志（新代）。
    fn answered(
        &self,
        since: i64,
        resident: Option<&LogState>,
        today_start: i64,
    ) -> Result<(String, Vec<Sql>), String>;
    /// 自定义学习「卡在 [from] 之后有评『重来』的有效复习」：对 `id` 列的条件与它的参数。
    fn forgotten(&self, from: i64) -> (String, Vec<Sql>);
}

/// 排队查询各自为之设计的部分索引（协议 3 `schema.rs` v9 的 `idx_srs_cards_cache_*`，新代 `cache.rs` 的 `cards_*`）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CardIx {
    NewPosition,
    NewFreq,
    /// 下面三个只有测试基准 [SqlSource] 用（生产的学习卡 / 到期卡 / 计数原料来自常驻会话）。
    #[cfg(test)]
    Learning,
    #[cfg(test)]
    ReviewDue,
    #[cfg(test)]
    Tally,
    /// 常驻会话整份建 / 按 id 重读卡行（`store/queue.rs`）：走主键。新代的主键 `(col, id)` 是表本身（WITHOUT ROWID），
    /// 规划器会挑一个按 `col` 开头的二级索引（`cards_anki`）再逐行回表、`NOT INDEXED` 也拦不住，所以按主键的自动索引名
    /// `sqlite_autoindex_cards_1` 钉住（`cmd/study_tests.rs` 的计划测试看着它）。
    Rows,
}

impl CardIx {
    /// 去掉表名前缀的索引名（`new_position` …）。
    pub(crate) fn suffix(self) -> &'static str {
        match self {
            CardIx::NewPosition => "new_position",
            CardIx::NewFreq => "new_freq",
            #[cfg(test)]
            CardIx::Learning => "learning",
            #[cfg(test)]
            CardIx::ReviewDue => "review_due",
            #[cfg(test)]
            CardIx::Tally => "tally",
            CardIx::Rows => "rows",
        }
    }
}

/// 协议 3 的表（profile 分区）。
pub(crate) struct P3Tables<'a> {
    pub c: &'a Connection,
    pub profile: &'a str,
}

impl Tables for P3Tables<'_> {
    fn conn(&self) -> &Connection {
        self.c
    }

    fn cards(&self) -> &'static str {
        "srs_cards_cache"
    }

    fn cards_via(&self, _ix: CardIx) -> String {
        self.cards().to_owned()
    }

    fn notes(&self) -> &'static str {
        "srs_notes_cache"
    }

    fn scope(&self, alias: &str) -> String {
        format!("{alias}profile_uid = srs_id(?)")
    }

    fn scope_by_id(&self) -> &'static str {
        "+profile_uid = srs_id(?)"
    }

    fn scope_arg(&self) -> Sql {
        Sql::Text(self.profile.to_owned())
    }

    fn mark(&self) -> &'static str {
        // ID 列表（store/ids.rs）：srs_id 对非 UUID 的值原样返回。
        "srs_id(?)"
    }

    fn id_sel(&self, col: &str) -> String {
        format!("srs_idt({col})")
    }

    fn id_arg(&self, id: &str) -> Sql {
        Sql::Text(id.to_owned())
    }

    fn id_get(&self, r: &rusqlite::Row<'_>, i: usize) -> rusqlite::Result<String> {
        r.get(i)
    }

    fn answered(
        &self,
        since: i64,
        _resident: Option<&LogState>,
        _today_start: i64,
    ) -> Result<(String, Vec<Sql>), String> {
        Ok((
            "id IN (SELECT card_id FROM srs_review_logs WHERE profile_uid = srs_id(?) AND kind = 'review' AND occurred_at >= ?)"
                .to_owned(),
            vec![self.scope_arg(), Sql::Integer(since)],
        ))
    }

    fn forgotten(&self, from: i64) -> (String, Vec<Sql>) {
        (
            "id IN (SELECT card_id FROM srs_stat_reviews WHERE profile_uid = srs_id(?) AND rating = 1 AND occurred_at >= ?)"
                .to_owned(),
            vec![self.scope_arg(), Sql::Integer(from)],
        )
    }
}

/// 排队读的卡 / 日志数据：生产是常驻会话（[SessionSource]，协议 3 与新代 `store/gen4/cmd/study.rs` 同一份）；
/// [SqlSource] 是 L2 的逐条 SQL 实现（只在测试里当会话的对拍基准）。
trait Source {
    /// 新卡 / 自定义学习那几条 SQL 落在哪。
    fn tables(&self) -> &dyn Tables;
    fn logs(&self) -> &LogState;
    /// 常驻会话的计数上下文（[Tables::answered] 可直接读它）；测试基准（[SqlSource]）没有。
    fn resident(&self) -> Option<&LogState>;
    /// 每个牌组**自己**（不含子牌组）的计数原料；只给有 hidden = 0 的卡的牌组。[decks] 为 None = 全部牌组。
    fn tallies(
        &self,
        now: i64,
        decks: Option<&[String]>,
    ) -> Result<HashMap<String, DeckRaw>, String>;
    /// 一组卡所在的牌组与是否隐藏。
    fn decks_of(&self, ids: &HashSet<String>) -> Result<HashMap<String, (String, bool)>, String>;
    /// 子树里按 (COALESCE(due_at, 0), id) 第一张在 [limit] 前到期的可出学习卡：(卡, due_at)。
    fn first_learning(
        &self,
        decks: &[&str],
        limit: i64,
        exclude: &[&str],
    ) -> Result<Option<(String, Option<i64>)>, String>;
    /// 几个牌组的到期复习卡里按 [order] 排第一的一张（R 顺序 = 此刻可提取度最低）。
    fn first_due(
        &self,
        decks: &[&str],
        order: ReviewOrder,
        now: i64,
        exclude: &HashSet<&str>,
    ) -> Result<Option<DueCand>, String>;
    /// [first_due] 按 [order] 出卡之前调：会话按需建这个顺序的索引（读完牌组树才知道要哪种顺序，而会话必须在
    /// 这次读事务的第一条读之前取到，所以不能在开会话时就建）；测试基准什么都不用做。
    fn ensure_order(&mut self, order: ReviewOrder);
}

struct SessionSource<'a>(&'a mut Session, &'a dyn Tables);

impl Source for SessionSource<'_> {
    fn tables(&self) -> &dyn Tables {
        self.1
    }

    fn logs(&self) -> &LogState {
        self.0.logs()
    }

    fn resident(&self) -> Option<&LogState> {
        Some(self.0.logs())
    }

    fn tallies(
        &self,
        now: i64,
        decks: Option<&[String]>,
    ) -> Result<HashMap<String, DeckRaw>, String> {
        Ok(self.0.tallies(now, decks))
    }

    fn decks_of(&self, ids: &HashSet<String>) -> Result<HashMap<String, (String, bool)>, String> {
        Ok(self.0.decks_of(ids))
    }

    fn first_learning(
        &self,
        decks: &[&str],
        limit: i64,
        exclude: &[&str],
    ) -> Result<Option<(String, Option<i64>)>, String> {
        Ok(self.0.first_learning(decks, limit, exclude))
    }

    fn first_due(
        &self,
        decks: &[&str],
        order: ReviewOrder,
        now: i64,
        exclude: &HashSet<&str>,
    ) -> Result<Option<DueCand>, String> {
        self.0.first_due(decks, order, now, exclude)
    }

    fn ensure_order(&mut self, order: ReviewOrder) {
        self.0.ensure_order(order);
    }
}

/// 新卡的「按索引序取第一张」（`idx_srs_cards_cache_new_*` 部分索引）。
/// 参数：分区、今天、[decks] 个牌组、条件里的参数、[exclude] 个卡。[ix] = 这个顺序的部分索引。
fn first_sql(
    tb: &dyn Tables,
    ix: CardIx,
    decks: usize,
    condition: &str,
    order: &str,
    exclude: usize,
) -> String {
    let not_in = if exclude == 0 {
        String::new()
    } else {
        format!(" AND id NOT IN ({})", marks(tb, exclude))
    };
    format!(
        "SELECT {}, due_at FROM {} WHERE {} AND {LIVE} AND deck_id IN ({}) AND {condition}{not_in} ORDER BY {order} LIMIT 1",
        tb.id_sel("id"),
        tb.cards_via(ix),
        tb.scope(""),
        marks(tb, decks)
    )
}

pub(crate) const NEW_BY_POSITION: &str = "new_position IS NULL, new_position, note_created_at, id";
pub(crate) const NEW_BY_FREQUENCY: &str =
    "freq_rank IS NULL, freq_rank, new_position IS NULL, new_position, note_created_at, id";

fn marks(tb: &dyn Tables, n: usize) -> String {
    vec![tb.mark(); n].join(", ")
}

/// 学习卡「在给定时刻前到期」（绑定一个参数）与它们的出卡顺序。
#[cfg(test)]
const LEARNING_WHERE: &str = "queue IN ('learning', 'relearning') AND COALESCE(due_at, 0) <= ?";
#[cfg(test)]
const LEARNING_ORDER: &str = "COALESCE(due_at, 0), id";

/// 每个牌组自己的计数原料（参数：今天 ×2、学习卡的到期界、今天 ×2、分区，再是 [decks] 个牌组）。
#[cfg(test)]
fn tallies_sql(tb: &dyn Tables, decks: Option<usize>) -> String {
    let deck_sql = decks.map_or(String::new(), |n| {
        format!(" AND deck_id IN ({})", marks(tb, n))
    });
    format!(
        "SELECT {} AS deck_id, COUNT(*), \
         SUM(CASE WHEN {LIVE} AND queue NOT IN ('learning', 'relearning', 'review') THEN 1 ELSE 0 END), \
         SUM(CASE WHEN {LIVE} AND queue IN ('learning', 'relearning') AND COALESCE(due_at, 0) <= ? THEN 1 ELSE 0 END), \
         SUM(CASE WHEN {LIVE} AND queue = 'review' AND COALESCE(due_day, 0) <= ? THEN 1 ELSE 0 END) \
         FROM {} WHERE {} AND hidden = 0{deck_sql} GROUP BY deck_id",
        tb.id_sel("deck_id"),
        tb.cards_via(CardIx::Tally),
        tb.scope(""),
    )
}

/// R 顺序的到期复习卡（参数：分区、今天、[decks] 个牌组、今天、[exclude] 个卡、此刻）。
#[cfg(test)]
fn due_sql(tb: &dyn Tables, decks: usize, exclude: usize) -> String {
    let not_in = if exclude == 0 {
        String::new()
    } else {
        format!(" AND id NOT IN ({})", marks(tb, exclude))
    };
    format!(
        "SELECT {}, last_reviewed_at, stability FROM {} WHERE {} AND {LIVE} \
         AND deck_id IN ({}) AND queue = 'review' AND COALESCE(due_day, 0) <= ?{not_in} \
         ORDER BY 1.0 / (1.0 + (CASE WHEN last_reviewed_at IS NULL THEN 0.0 ELSE (? - last_reviewed_at) / 86400000.0 END) \
         / (9.0 * COALESCE(stability, 1.0))), id LIMIT 2",
        tb.id_sel("id"),
        tb.cards_via(CardIx::ReviewDue),
        tb.scope(""),
        marks(tb, decks),
    )
}

/// 子树里全部到期复习候选（不排序）：id、上次作答、稳定度、到期日、间隔、难度（参数同 [due_sql]，没有此刻）。
#[cfg(test)]
fn due_all_sql(tb: &dyn Tables, decks: usize, exclude: usize) -> String {
    let not_in = if exclude == 0 {
        String::new()
    } else {
        format!(" AND id NOT IN ({})", marks(tb, exclude))
    };
    format!(
        "SELECT {}, last_reviewed_at, stability, due_day, scheduled_days, difficulty FROM {} \
         WHERE {} AND {LIVE} \
         AND deck_id IN ({}) AND queue = 'review' AND COALESCE(due_day, 0) <= ?{not_in}",
        tb.id_sel("id"),
        tb.cards_via(CardIx::ReviewDue),
        tb.scope(""),
        marks(tb, decks),
    )
}

/// L2 的逐条 SQL 排队（2026-10-29 搬进常驻会话之前的生产实现）：每次排队按子树聚合计数、顺着到期索引有界排序取
/// 最低、日志由调用方整段扫好（[LogState]）。只留作测试的对拍基准：协议 3 与新代（`store/gen4/cmd/study.rs`，
/// 2026-11 接线进常驻会话之前每条命令在读快照里用它）的会话都拿它对拍。
#[cfg(test)]
pub(crate) struct SqlSource<'a> {
    pub tb: &'a dyn Tables,
    pub today: i64,
    pub logs: LogState,
}

#[cfg(test)]
impl Source for SqlSource<'_> {
    fn tables(&self) -> &dyn Tables {
        self.tb
    }

    fn logs(&self) -> &LogState {
        &self.logs
    }

    fn resident(&self) -> Option<&LogState> {
        None
    }

    fn tallies(
        &self,
        now: i64,
        decks: Option<&[String]>,
    ) -> Result<HashMap<String, DeckRaw>, String> {
        let tb = self.tb;
        let sql_text = tallies_sql(tb, decks.map(<[String]>::len));
        let mut args: Vec<Sql> = vec![
            Sql::Integer(self.today),
            Sql::Integer(self.today),
            Sql::Integer(now + LEARN_AHEAD_MS),
            Sql::Integer(self.today),
            Sql::Integer(self.today),
            tb.scope_arg(),
        ];
        for d in decks.unwrap_or(&[]) {
            args.push(tb.id_arg(d));
        }
        let mut stmt = tb.conn().prepare_cached(&sql_text).map_err(sql)?;
        let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
        let mut out = HashMap::new();
        while let Some(r) = q.next().map_err(sql)? {
            out.insert(
                tb.id_get(r, 0).map_err(sql)?,
                DeckRaw {
                    total: r.get(1).map_err(sql)?,
                    new_avail: r.get(2).map_err(sql)?,
                    learn: r.get(3).map_err(sql)?,
                    due: r.get(4).map_err(sql)?,
                },
            );
        }
        Ok(out)
    }

    fn decks_of(&self, ids: &HashSet<String>) -> Result<HashMap<String, (String, bool)>, String> {
        let tb = self.tb;
        let all: Vec<&String> = ids.iter().collect();
        let mut out = HashMap::new();
        for chunk in all.chunks(400) {
            let sql_text = format!(
                "SELECT {} AS id, {} AS deck_id, hidden FROM {} WHERE id IN ({}) AND {}",
                tb.id_sel("id"),
                tb.id_sel("deck_id"),
                tb.cards(),
                marks(tb, chunk.len()),
                tb.scope_by_id(),
            );
            let mut stmt = tb.conn().prepare_cached(&sql_text).map_err(sql)?;
            let mut args: Vec<Sql> = chunk.iter().map(|s| tb.id_arg(s)).collect();
            args.push(tb.scope_arg());
            let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
            while let Some(r) = q.next().map_err(sql)? {
                out.insert(
                    tb.id_get(r, 0).map_err(sql)?,
                    (
                        tb.id_get(r, 1).map_err(sql)?,
                        r.get::<_, bool>(2).map_err(sql)?,
                    ),
                );
            }
        }
        Ok(out)
    }

    fn first_learning(
        &self,
        decks: &[&str],
        limit: i64,
        exclude: &[&str],
    ) -> Result<Option<(String, Option<i64>)>, String> {
        if decks.is_empty() {
            return Ok(None);
        }
        let tb = self.tb;
        let sql_text = first_sql(
            tb,
            CardIx::Learning,
            decks.len(),
            LEARNING_WHERE,
            LEARNING_ORDER,
            exclude.len(),
        );
        let mut args: Vec<Sql> = vec![tb.scope_arg(), Sql::Integer(self.today)];
        args.extend(decks.iter().map(|d| tb.id_arg(d)));
        args.push(Sql::Integer(limit));
        args.extend(exclude.iter().map(|d| tb.id_arg(d)));
        let mut stmt = tb.conn().prepare_cached(&sql_text).map_err(sql)?;
        let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
        match q.next().map_err(sql)? {
            Some(r) => Ok(Some((
                tb.id_get(r, 0).map_err(sql)?,
                r.get(1).map_err(sql)?,
            ))),
            None => Ok(None),
        }
    }

    fn first_due(
        &self,
        decks: &[&str],
        order: ReviewOrder,
        now: i64,
        exclude: &HashSet<&str>,
    ) -> Result<Option<DueCand>, String> {
        if order != ReviewOrder::Retrievability {
            return self.first_by_key(decks, order, exclude);
        }
        let tb = self.tb;
        let ex: Vec<&str> = exclude.iter().copied().collect();
        let sql_text = due_sql(tb, decks.len(), ex.len());
        let mut args: Vec<Sql> = vec![tb.scope_arg(), Sql::Integer(self.today)];
        args.extend(decks.iter().map(|d| tb.id_arg(d)));
        args.push(Sql::Integer(self.today));
        args.extend(ex.iter().map(|d| tb.id_arg(d)));
        args.push(Sql::Integer(now));
        let mut stmt = tb.conn().prepare_cached(&sql_text).map_err(sql)?;
        let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
        match q.next().map_err(sql)? {
            Some(r) => Ok(Some((
                tb.id_get(r, 0).map_err(sql)?,
                r.get(1).map_err(sql)?,
                r.get(2).map_err(sql)?,
            ))),
            None => Ok(None),
        }
    }

    fn ensure_order(&mut self, _order: ReviewOrder) {}
}

#[cfg(test)]
impl SqlSource<'_> {
    /// R 以外的复习顺序：把全部到期候选读出来（当天哈希在 SQL 里算不了），按（键, id）取最小。
    pub(crate) fn first_by_key(
        &self,
        decks: &[&str],
        order: ReviewOrder,
        exclude: &HashSet<&str>,
    ) -> Result<Option<DueCand>, String> {
        let tb = self.tb;
        let ex: Vec<&str> = exclude.iter().copied().collect();
        let sql_text = due_all_sql(tb, decks.len(), ex.len());
        let mut args: Vec<Sql> = vec![tb.scope_arg(), Sql::Integer(self.today)];
        args.extend(decks.iter().map(|d| tb.id_arg(d)));
        args.push(Sql::Integer(self.today));
        args.extend(ex.iter().map(|d| tb.id_arg(d)));
        let mut stmt = tb.conn().prepare_cached(&sql_text).map_err(sql)?;
        let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
        let mut best: Option<(crate::store::queue::OrdKey, String, DueCand)> = None;
        while let Some(r) = q.next().map_err(sql)? {
            let id: String = tb.id_get(r, 0).map_err(sql)?;
            let key = crate::store::queue::order_key(
                order,
                &id,
                self.today,
                r.get(3).map_err(sql)?,
                r.get(4).map_err(sql)?,
                r.get::<_, Option<f64>>(5).map_err(sql)?.map(|d| d as f32),
            );
            if best.as_ref().is_none_or(|(k, i, _)| (key, &id) < (*k, i)) {
                let cand = (id.clone(), r.get(1).map_err(sql)?, r.get(2).map_err(sql)?);
                best = Some((key, id, cand));
            }
        }
        Ok(best.map(|(_, _, c)| c))
    }
}

/// RWKV-Instant 合格的复习卡（按 R 升序，同 R 按 id）。与旧 Dart `_instantReviews` 同口径：
/// - R ≤ 卡所在牌组的目标保留率才合格；
/// - 同日重复的间隔守卫：今天答过的卡，距上次作答不足 `repeat_seconds` 秒，或这之后共用这套设置（同一个参数归属
///   牌组）的牌组里别的卡的作答不足 `repeat_reviews` 次 → 暂缓。只看牌组树、不看这次排队的范围：以前数的是请求
///   子树里的作答，牌组列表（全部牌组）把别的牌组的作答也算进去、判合格，点进那个牌组排队却只数子树、判暂缓——
///   列表上显示到期、复习页一张都不出（应用内反馈 ys9tMVHj3S）；
/// - 每天最少复习数：共用一套设置（同一个参数归属牌组）的牌组今天已用的量（按归属牌组的 [LimitUnit]）加上合格卡
///   仍不到这个数时，从只因 R 高于目标被挡的卡里按 R 升序补足。
///
/// 第二项 = 只差间隔守卫的时间那一半的卡（卡, 牌组, 守卫解除时刻）：作答次数那一半已满足、R 也不挡（不高于目标，或
/// 牌组开了「每天最少复习数」可能补上）。它们不靠任何写入、到点就合格——复习页排空后据此定时重排（[Picker::wake]）。
/// 只差作答次数的不算：那要别的卡被答过，等多久都不会自己解除。
fn instant_eligible(
    ctx: &Ctx<'_>,
    decks: &HashMap<String, InstantDeck>,
    cands: &[(String, String, Option<i64>, f64)],
    answered_deck: &HashMap<String, (String, bool)>,
) -> (Vec<(String, String, f64)>, Vec<(String, String, i64)>) {
    let day_start = ctx.day_start(ctx.today);
    // 参数归属牌组（设置所在的 own 祖先）：间隔守卫数作答、「每天最少」记配额都按它分组。
    // 不在牌组树里的牌组按默认牌组算（`DeckTree::effective`），与 Dart `_minimumTopUp` 分组同一口径。
    let owner = |d: &str| {
        let e = ctx.tree.effective(d);
        ctx.tree.params_owner_id(&e).unwrap_or(&e).to_owned()
    };
    let mut owners: HashMap<String, String> = HashMap::new();
    let mut owner_of = |d: &str| -> String {
        owners
            .entry(d.to_owned())
            .or_insert_with(|| owner(d))
            .clone()
    };
    // 今天的作答（卡, 时刻, 所在牌组的参数归属牌组），间隔守卫用；不在这个 profile 里的卡不算。
    let answers: Vec<(&String, i64, String)> = ctx
        .logs
        .answers()
        .filter_map(|(c, at)| {
            answered_deck
                .get(c)
                .map(|(d, _)| (c, at, owner_of(d.as_str())))
        })
        .collect();
    let spaced = |id: &str, group: &str, last: Option<i64>, q: &InstantDeck| -> Spacing {
        let Some(last) = last.filter(|l| *l >= day_start) else {
            return Spacing::Ready;
        };
        let reviews_ok = q.repeat_reviews <= 0 || {
            let mut others = 0;
            answers.iter().any(|(other, at, o)| {
                if *at > last && other.as_str() != id && o == group {
                    others += 1;
                }
                others >= q.repeat_reviews
            })
        };
        let release = last + q.repeat_seconds * 1000;
        match (reviews_ok, ctx.now < release) {
            (false, _) => Spacing::Blocked,
            (true, true) => Spacing::Until(release),
            (true, false) => Spacing::Ready,
        }
    };
    let mut eligible: Vec<(String, String, f64)> = Vec::new();
    let mut above: Vec<(String, String, f64)> = Vec::new();
    let mut held: Vec<(String, String, i64)> = Vec::new();
    for (id, deck, last, r) in cands {
        let Some(q) = decks.get(deck) else { continue };
        if !r.is_finite() {
            continue;
        }
        match spaced(id, &owner_of(deck), *last, q) {
            Spacing::Ready => {}
            Spacing::Until(at) => {
                if *r <= q.target || q.min_reviews > 0 {
                    held.push((id.clone(), deck.clone(), at));
                }
                continue;
            }
            Spacing::Blocked => continue,
        }
        if *r > q.target {
            &mut above
        } else {
            &mut eligible
        }
        .push((id.clone(), deck.clone(), *r));
    }
    let by_r = |a: &(String, String, f64), b: &(String, String, f64)| {
        a.2.partial_cmp(&b.2)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.0.cmp(&b.0))
    };
    if decks.values().any(|q| q.min_reviews > 0) && !above.is_empty() {
        // 配额按参数归属牌组（设置所在的 own 祖先）记：随参数继承的子牌组共用设置，也共用这一份「每天最少」，
        // 不是每个子牌组各补一份（Anki 导入的牌组常有几十个继承同一预设的子牌组）。
        // 配额按归属牌组的单位（[LimitUnit]）记：次数 / 卡片数下今天复习过的卡按作答条数 / 1 张扣，合格卡与补上的
        // 卡各扣 1；分钟下只扣今天复习已用的时长（毫秒），没用满就把高于目标的卡全部按 R 升序补上（不预估以后的
        // 耗时），用满了一张也不补。
        let unit_of = |o: &str| {
            ctx.tree
                .decks
                .get(o)
                .map_or(LimitUnit::default(), |n| LimitUnit::of_view(&n.view))
        };
        let mut remaining: HashMap<String, (LimitUnit, i64)> = HashMap::new();
        for (d, q) in decks.iter().filter(|(_, q)| q.min_reviews > 0) {
            let o = owner(d);
            let unit = unit_of(&o);
            remaining.insert(o, (unit, unit.limit_in_usage(q.min_reviews)));
        }
        let mut quota_of: HashMap<String, String> = HashMap::new();
        // [amount]：按单位要扣多少（None = 新出的一张：次数 / 卡片数扣 1，分钟扣 0）。
        let mut take = |d: &str, amount: Option<(i64, i64)>, only_if_left: bool| -> bool {
            let o = quota_of.entry(d.to_owned()).or_insert_with(|| owner(d));
            match remaining.get_mut(o.as_str()) {
                Some((unit, left)) if !only_if_left || *left > 0 => {
                    *left -= match (*unit, amount) {
                        (LimitUnit::Reviews, Some((answers, _))) => answers,
                        (LimitUnit::Minutes, Some((_, ms))) => ms,
                        (LimitUnit::Minutes, None) => 0,
                        _ => 1,
                    };
                    true
                }
                _ => false,
            }
        };
        for id in ctx.logs.reviewed_cards() {
            if let Some((d, _)) = answered_deck.get(id) {
                take(
                    d,
                    Some((ctx.logs.review_answers(id), ctx.logs.review_ms(id))),
                    false,
                );
            }
        }
        for (_, d, _) in &eligible {
            take(d, None, false);
        }
        above.sort_by(by_r);
        for c in above {
            if take(&c.1, None, true) {
                eligible.push(c);
            }
        }
    }
    eligible.sort_by(by_r);
    (eligible, held)
}

/// RWKV 同日间隔守卫对一张卡的判定（[instant_eligible]）。
enum Spacing {
    /// 不受守卫限制（今天没答过，或两半都已满足）。
    Ready,
    /// 作答次数已够，只差时间：到这个时刻（毫秒）解除。
    Until(i64),
    /// 之后别的卡的作答次数不够：要等别的卡被答过，不会自己解除。
    Blocked,
}

/// 牌组树计数（对齐 Anki v3 的 limit tree，rslib scheduler/queue/limits.rs）：每个牌组的今日剩余上限 = 自己的
/// 每日上限（新卡另按复习量缩减）− 今天整棵子树里已学的新卡 / 已复习的卡；新卡 / 到期数自底向上取
/// min(本牌组剩余上限, 自己的卡 + Σ 子牌组已截断后的数)；学习数不截断；只看 [root] 这棵子树（None = 全部顶层）。
fn count_tree(
    ctx: &Ctx<'_>,
    tallies: &HashMap<String, Tally>,
    ids: &[String],
    root: Option<&str>,
) -> HashMap<String, Count> {
    let scope: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let mut children: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut tops: Vec<&str> = Vec::new();
    for id in ids {
        match ctx.parent(id) {
            Some(p) if Some(id.as_str()) != root && scope.contains(p) => {
                children.entry(p).or_default().push(id)
            }
            _ => tops.push(id),
        }
    }
    fn visit<'a>(
        id: &'a str,
        ctx: &Ctx<'_>,
        tallies: &HashMap<String, Tally>,
        children: &HashMap<&'a str, Vec<&'a str>>,
        out: &mut HashMap<String, Count>,
    ) -> Count {
        let own = tallies.get(id).copied().unwrap_or_default();
        let mut sub = own;
        let (mut new_sum, mut review_sum, mut learn_sum) = (own.new_avail, own.due, own.learn);
        for c in children.get(id).into_iter().flatten() {
            let cc = visit(c, ctx, tallies, children, out);
            sub.add(&cc.sub);
            new_sum += cc.new_count;
            review_sum += cc.review_count;
            learn_sum += cc.learn_count;
        }
        let view = &ctx.tree.decks[id].view;
        // 新卡计划与每日上限一样只看牌组自己的值（不随参数继承）。
        let plan = NewCardPlan::of(&view["npl"]);
        // RWKV 的到期 / 合格卡不是负荷信号：按复习量调整对它不生效（寄存器值照存，切回 FSRS 恢复）。算法按参数归属
        // 祖先判（与 `ignores_review_limit` 同一口径），不看请求里的 `rwkv.decks`（只有装了 RWKV 运行时的宿主才带）。
        let plan = if ctx.tree.uses_rwkv(id) {
            NewCardPlan {
                auto_load: false,
                ..plan
            }
        } else {
            plan
        };
        let budget = new_card_budget(int(view, "np", 20), sub.load, ctx.logs.last30(), plan);
        // 自定义学习「提升今日上限」：只对今天、只加在这个牌组自己这一层（子牌组的上限照旧截）。
        let (ext_new, ext_review) = today_extension(&view["ext"], ctx.today);
        let new_remaining = (budget.allowed + ext_new - sub.new_done).max(0);
        // RWKV 牌组开了「忽略每日复习上限」（上游 Anki 的 Ignore review limit）：按 R 合格的卡全部出，这一层不截断
        // （祖先没开的照样按自己的上限截）。
        // 已用按牌组自己的单位（[LimitUnit]）对整棵子树统计，与以前「子树里已复习的卡」同一个汇总口径。
        let (review_remaining, review_minutes_left) = if ctx.tree.ignores_review_limit(id) {
            (UNLIMITED_REVIEWS, None)
        } else {
            let unit = LimitUnit::of_view(view);
            let limit = int(view, "rp", 200) + ext_review;
            (
                unit.review_room(limit, &sub),
                unit.minutes_left(limit, &sub),
            )
        };
        let r = Count {
            sub,
            budget,
            new_remaining,
            review_remaining,
            new_count: new_remaining.min(new_sum),
            review_count: review_remaining.min(review_sum),
            learn_count: learn_sum,
            review_minutes_left,
        };
        out.insert(id.to_owned(), r);
        r
    }
    let mut out = HashMap::new();
    for id in tops {
        visit(id, ctx, tallies, &children, &mut out);
    }
    out
}

struct Picker<'a> {
    src: &'a dyn Source,
    ctx: &'a Ctx<'a>,
    root: &'a str,
    sub: &'a [String],
    counts: &'a HashMap<String, Count>,
    instant_decks: HashSet<&'a str>,
    eligible: &'a [(String, String, f64)],
    /// 所点牌组的复习顺序（[DeckTree::review_order]；FSRS 一路用，RWKV 一路恒按 R）。
    order: ReviewOrder,
    /// 所点牌组的新卡与复习怎么排（[DeckTree::new_mix]）。
    mix: NewMix,
}

/// [NewMix::Mixed]：按今天的总量均匀穿插（Bresenham 式，不在会话里记状态）。[nd] / [rd] = 所点牌组子树今天已学的
/// 新卡 / 已复习的卡，[nr] / [rr] = 根上还剩的新卡 / 复习数（都已算上「再下一张」虚拟出掉的那张）。设
/// N = nd + nr、R = rd + rr、L = N + R、i = nd + rd：当且仅当 (i + 1)·N ≥ (nd + 1)·L 时这一张出新卡——第 k 张新卡
/// 落在 ⌈k·L/N⌉ − 1 号位上，N = 2、R = 6 时是 RRRNRRRN。
fn mixed_wants_new(nd: i64, rd: i64, nr: i64, rr: i64) -> bool {
    let n = i128::from(nd) + i128::from(nr);
    let l = n + i128::from(rd) + i128::from(rr);
    let i = i128::from(nd) + i128::from(rd);
    (i + 1) * n >= (i128::from(nd) + 1) * l
}

impl Picker<'_> {
    /// 一张卡能出，当且仅当它所在牌组到所点牌组这一路上每一层都还有剩余上限（层层上限构成层状拟阵，按任何
    /// 顺序贪心取都恰好取到根的计数，列表数字与实际出卡一致）。
    fn path_has_room(&self, deck: &str, remaining: fn(&Count) -> i64) -> bool {
        let mut cur = Some(deck);
        let mut guard = 0;
        while let Some(d) = cur {
            if guard >= 64 {
                break;
            }
            guard += 1;
            match self.counts.get(d) {
                Some(c) if remaining(c) > 0 => {}
                _ => return false,
            }
            if d == self.root {
                return true;
            }
            cur = self.ctx.parent(d);
        }
        false
    }

    /// 子树里按新卡顺序的第一张可出新卡（走对应的部分索引，命中第一张即停）。
    fn first_new(
        &self,
        decks: &[&str],
        (order, ix): (&str, CardIx),
        exclude: &[&str],
    ) -> Result<Option<String>, String> {
        if decks.is_empty() {
            return Ok(None);
        }
        let tb = self.src.tables();
        let sql_text = first_sql(tb, ix, decks.len(), "queue = 'new'", order, exclude.len());
        let mut args: Vec<Sql> = vec![tb.scope_arg(), Sql::Integer(self.ctx.today)];
        args.extend(decks.iter().map(|d| tb.id_arg(d)));
        args.extend(exclude.iter().map(|d| tb.id_arg(d)));
        let mut stmt = tb.conn().prepare_cached(&sql_text).map_err(sql)?;
        let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
        match q.next().map_err(sql)? {
            Some(r) => Ok(Some(tb.id_get(r, 0).map_err(sql)?)),
            None => Ok(None),
        }
    }

    /// 下一张到期复习卡：FSRS 一路按复习顺序取队首，RWKV 一路按 R 取队首（[Picker::eligible] 已按 R 升序），
    /// 两个队首再比「此刻 R」，低的先出。
    fn review(&self, sub: &[&str], ex: &HashSet<&str>) -> Result<Option<String>, String> {
        let instant_best = self.eligible.iter().find(|(id, deck, _)| {
            !ex.contains(id.as_str()) && self.path_has_room(deck, |c| c.review_remaining)
        });
        let fsrs_decks: Vec<&str> = sub
            .iter()
            .copied()
            .filter(|d| {
                !self.instant_decks.contains(d) && self.path_has_room(d, |c| c.review_remaining)
            })
            .collect();
        let due = if fsrs_decks.is_empty() {
            None
        } else {
            self.src
                .first_due(&fsrs_decks, self.order, self.ctx.now, ex)?
        };
        Ok(match (instant_best, due) {
            (None, Some((id, _, _))) => Some(id),
            (Some((id, _, _)), None) => Some(id.clone()),
            (Some((iid, _, ir)), Some((did, last, s))) => {
                // 子树里 RWKV 与 FSRS 牌组混排：两边各自的「此刻 R」比，低的先出。
                let days = last.map_or(0.0, |l| (self.ctx.now - l) as f64 / 86_400_000.0);
                let fsrs_r = 1.0 / (1.0 + days / (9.0 * s.unwrap_or(1.0)));
                Some(if fsrs_r < *ir { did } else { iid.clone() })
            }
            (None, None) => None,
        })
    }

    /// 下一张新卡（所点牌组的新卡顺序）。
    fn new_card(&self, sub: &[&str], exclude: &[&str]) -> Result<Option<String>, String> {
        let decks: Vec<&str> = sub
            .iter()
            .copied()
            .filter(|d| self.path_has_room(d, |c| c.new_remaining))
            .collect();
        let owner = self.ctx.tree.params_owner(self.root).map(|d| &d.view);
        let order = match owner.and_then(|v| v["no"].as_str()) {
            Some("position") => (NEW_BY_POSITION, CardIx::NewPosition),
            _ => (NEW_BY_FREQUENCY, CardIx::NewFreq),
        };
        self.first_new(&decks, order, exclude)
    }

    /// 下一张：到期的学习卡 → 复习卡与新卡（先后按 [Picker::mix]；复习卡按 [Picker::order]）→ 20 分钟内到期的
    /// 学习卡。[v] = 已虚拟出掉的（新卡, 复习）张数：算「再下一张」时按「下一张」的类别给 (1, 0) / (0, 1)，根上的
    /// 剩余数与均匀穿插的进度都扣掉它（新卡上限只剩 1、下一张已是新卡时，再下一张不再出新卡）。各层的
    /// [Picker::path_has_room] 没有虚拟扣减（同一张在子牌组那层的上限也只剩 1 时，再下一张仍可能越过它；下一次
    /// 真排队时按实际计数纠正），这里不扩大范围。
    fn next(&self, exclude: &[&str], v: (i64, i64)) -> Result<Option<(String, Kind)>, String> {
        let ex: HashSet<&str> = exclude.iter().copied().collect();
        let sub: Vec<&str> = self.sub.iter().map(String::as_str).collect();
        let learning = self
            .src
            .first_learning(&sub, self.ctx.now + LEARN_AHEAD_MS, exclude)?;
        if let Some((id, due)) = &learning {
            if due.unwrap_or(0) <= self.ctx.now {
                return Ok(Some((id.clone(), Kind::Learning)));
            }
        }
        let sum = self.counts[self.root];
        let new_left = (sum.new_count - v.0).max(0);
        let review_left = (sum.review_count - v.1).max(0);
        let new_first = match self.mix {
            NewMix::AfterReviews => false,
            NewMix::BeforeReviews => true,
            NewMix::Mixed => mixed_wants_new(
                sum.sub.new_done + v.0,
                sum.sub.review_done + v.1,
                new_left,
                review_left,
            ),
        };
        let kinds = if new_first {
            [Kind::New, Kind::Review]
        } else {
            [Kind::Review, Kind::New]
        };
        // 选中的那一类没有可出的卡时退到另一类。
        for kind in kinds {
            let hit = match kind {
                Kind::Review if review_left > 0 => self.review(&sub, &ex)?,
                Kind::New if new_left > 0 => self.new_card(&sub, exclude)?,
                _ => None,
            };
            if let Some(id) = hit {
                return Ok(Some((id, kind)));
            }
        }
        Ok(learning.map(|(id, _)| (id, Kind::Learning)))
    }

    /// [Picker::next] 一张都排不出时，最早哪一刻（毫秒）不靠任何写入就又排得出——复习页「复习完」据此定时重排、
    /// 亮出「继续」，排程本身不变（应用内反馈 LAk5vHGWUe：RWKV 间隔守卫暂缓的卡几十秒后合格，页面却一直停在
    /// 「复习完」，退出后牌组又显示有卡）。只看随时间自己变化的两样：
    /// - 学习卡：最早的那张进入 [LEARN_AHEAD_MS] 提前窗口的时刻（到期时刻 − 窗口）；
    /// - RWKV：只差间隔守卫时间那一半、所在路径还有复习额度的卡的解除时刻（[instant_eligible] 的第二项）。
    ///
    /// FSRS 复习卡按天到期、新卡按天放额度，都只在跨日时变（跨日整份重排，不在这里）。只给晚于此刻的时刻：到点重排
    /// 若因别的原因（例如「每天最少」的配额已满）仍排不出，那一项不会再被报出来，不会空转。
    fn wake(
        &self,
        exclude: &[&str],
        held: &[(String, String, i64)],
    ) -> Result<Option<i64>, String> {
        let sub: Vec<&str> = self.sub.iter().map(String::as_str).collect();
        let learning = self
            .src
            .first_learning(&sub, i64::MAX, exclude)?
            .map(|(_, due)| due.unwrap_or(0) - LEARN_AHEAD_MS);
        let ex: HashSet<&str> = exclude.iter().copied().collect();
        let instant = held
            .iter()
            .filter(|(id, deck, _)| {
                !ex.contains(id.as_str()) && self.path_has_room(deck, |c| c.review_remaining)
            })
            .map(|(_, _, at)| *at)
            .min();
        Ok([learning, instant]
            .into_iter()
            .flatten()
            .filter(|at| *at > self.ctx.now)
            .min())
    }
}

/// 牌组寄存器 `extendLimits`（视图键 `ext`，`{"day": 日序, "new": n, "review": n}`）里今天的追加量：
/// Anki「自定义学习 → 提升今日新卡 / 复习上限」。不是今天写的不算（第二天自动失效，不用清）。
pub(crate) fn today_extension(v: &Value, today: i64) -> (i64, i64) {
    if v.get("day").and_then(Value::as_i64) != Some(today) {
        return (0, 0);
    }
    let n = |k: &str| {
        v.get(k)
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .clamp(0, MAX_EXTENSION)
    };
    (n("new"), n("review"))
}

/// 一天的上限追加量上限（与牌组设置里每日上限的输入范围同量级）。
pub(crate) const MAX_EXTENSION: i64 = 9999;

/// 自定义学习的临时会话（Anki Custom Study 里不改上限的几种）。不建筛选牌组、不挪卡、不改任何设置：只在排队时
/// 换一套选卡条件，作答照常写日志、照常按 FSRS 排程（与 Anki 筛选牌组默认的「按作答重新排程」同义）。会话本身
/// 无状态：「这次会话里答过的卡」= 子树里 [since] 之后有作答日志的卡；会话结束什么都不用清。
///
/// 请求 `"custom": {"since": 会话开始时刻, "mode": "forgotten" | "ahead" | "filter", "days"?: n, "limit"?: n,
/// "states"?: ["new" | "learning" | "review" | "due"], "tags"?: [标签], "source"?: 出处键}`：
/// - forgotten：最近 [days] 天（含今天）里评过「重来」的卡；
/// - ahead：[days] 天内到期（今天之后）的复习卡，按到期先后；
/// - filter：按卡片状态（空 = 不限）、笔记标签（空 = 不限；不分大小写，`a` 也匹配层级标签 `a::b`）与出处（浏览页
///   出处视图「只复习这一作」：笔记缓存行 `source_key` 整值相等，srs.db v25；与 `src:"<键>"` 同一个键）。
///
/// 出卡：会话里答过、现在到期的学习卡 → 还没答过的候选（最多 [limit] 张，按会话里已答的卡数扣）→ 20 分钟内到期
/// 的会话学习卡。结果另带 `"custom": {"left": 剩余候选, "learn": 会话学习卡}`。
struct CustomStudy {
    since: i64,
    mode: CustomMode,
    days: i64,
    limit: i64,
    states: Vec<String>,
    tags: Vec<String>,
    /// 只出这个出处（作品）的卡；None = 不限。
    source: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum CustomMode {
    Forgotten,
    Ahead,
    Filter,
}

/// 自定义学习一次最多出的卡（与 Anki 自定义学习的输入上限同量级）。
const MAX_CUSTOM_CARDS: i64 = 9999;

impl CustomStudy {
    fn of(v: &Value) -> Result<CustomStudy, String> {
        let mode = match v.get("mode").and_then(Value::as_str) {
            Some("forgotten") => CustomMode::Forgotten,
            Some("ahead") => CustomMode::Ahead,
            Some("filter") => CustomMode::Filter,
            m => return Err(format!("study: bad custom mode {m:?}")),
        };
        let strs = |k: &str| -> Vec<String> {
            v.get(k)
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        };
        let source = match v.get("source") {
            None | Some(Value::Null) => None,
            Some(Value::String(k)) if !k.is_empty() => Some(k.clone()),
            Some(x) => return Err(format!("study: bad custom source {x}")),
        };
        Ok(CustomStudy {
            source,
            since: v
                .get("since")
                .and_then(Value::as_i64)
                .ok_or("study: missing custom.since")?,
            mode,
            days: v
                .get("days")
                .and_then(Value::as_i64)
                .unwrap_or(1)
                .clamp(1, 3650),
            limit: v
                .get("limit")
                .and_then(Value::as_i64)
                .unwrap_or(100)
                .clamp(0, MAX_CUSTOM_CARDS),
            states: strs("states"),
            tags: strs("tags")
                .into_iter()
                .map(|t| t.trim().to_lowercase())
                .filter(|t| !t.is_empty())
                .collect(),
        })
    }
}

/// 自定义学习的出卡（见 [CustomStudy]）。
struct CustomPicker<'a> {
    tb: &'a dyn Tables,
    ctx: &'a Ctx<'a>,
    decks: &'a [String],
    cu: &'a CustomStudy,
    /// 子树里会话开始之后有作答日志的卡：对 `id` 列的条件与它的参数（[Tables::answered]，一次排队算一次）。
    answered: (String, Vec<Sql>),
}

impl CustomPicker<'_> {
    fn base_args(&self) -> Vec<Sql> {
        let mut a = vec![self.tb.scope_arg(), Sql::Integer(self.ctx.today)];
        a.extend(self.decks.iter().map(|d| self.tb.id_arg(d)));
        a
    }

    fn base(&self) -> String {
        format!(
            "FROM {} WHERE {} AND {LIVE} AND deck_id IN ({})",
            self.tb.cards(),
            self.tb.scope(""),
            marks(self.tb, self.decks.len())
        )
    }

    /// 会话里答过、仍在学习 / 重学队列的卡：(卡, due_at)，按到期先后。
    fn learning(&self) -> Result<Vec<(String, i64)>, String> {
        let q = format!(
            "SELECT {}, COALESCE(due_at, 0) {} AND queue IN ('learning', 'relearning') AND {} ORDER BY COALESCE(due_at, 0), id",
            self.tb.id_sel("id"),
            self.base(),
            self.answered.0
        );
        let mut args = self.base_args();
        args.extend(self.answered.1.iter().cloned());
        let mut stmt = self.tb.conn().prepare_cached(&q).map_err(sql)?;
        let rows = stmt
            .query_map(params_from_iter(args), |r| {
                Ok((self.tb.id_get(r, 0)?, r.get::<_, i64>(1)?))
            })
            .map_err(sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sql)
    }

    /// 子树里会话开始之后答过的卡数（扣 [CustomStudy::limit]）。
    fn done(&self) -> Result<i64, String> {
        let q = format!(
            "SELECT COUNT(*) FROM {} WHERE {} AND deck_id IN ({}) AND {}",
            self.tb.cards(),
            self.tb.scope(""),
            marks(self.tb, self.decks.len()),
            self.answered.0
        );
        let mut args: Vec<Sql> = vec![self.tb.scope_arg()];
        args.extend(self.decks.iter().map(|d| self.tb.id_arg(d)));
        args.extend(self.answered.1.iter().cloned());
        self.tb
            .conn()
            .query_row(&q, params_from_iter(args), |r| r.get(0))
            .map_err(sql)
    }

    /// 候选条件、它的参数与顺序（不含「会话里没答过」与排除）。
    fn condition(&self) -> (String, Vec<Sql>, &'static str) {
        let today = self.ctx.today;
        match self.cu.mode {
            CustomMode::Forgotten => {
                let from = self.ctx.day_start(today - self.cu.days + 1);
                let (forgot, args) = self.tb.forgotten(from);
                (
                    format!("queue <> 'new' AND {forgot}"),
                    args,
                    "last_reviewed_at, id",
                )
            }
            CustomMode::Ahead => (
                "queue = 'review' AND due_day > ? AND due_day <= ?".to_owned(),
                vec![Sql::Integer(today), Sql::Integer(today + self.cu.days)],
                "due_day, id",
            ),
            CustomMode::Filter => {
                let mut parts: Vec<String> = Vec::new();
                let mut args: Vec<Sql> = Vec::new();
                let mut states: Vec<String> = Vec::new();
                for s in &self.cu.states {
                    match s.as_str() {
                        "new" => states
                            .push("queue NOT IN ('learning', 'relearning', 'review')".to_owned()),
                        "learning" => states.push("queue IN ('learning', 'relearning')".to_owned()),
                        "review" => states.push("queue = 'review'".to_owned()),
                        "due" => {
                            states.push(
                                "(queue = 'review' AND COALESCE(due_day, 0) <= ?)".to_owned(),
                            );
                            args.push(Sql::Integer(today));
                        }
                        _ => {}
                    }
                }
                if !states.is_empty() {
                    parts.push(format!("({})", states.join(" OR ")));
                }
                if !self.cu.tags.is_empty() {
                    let each = vec![
                        "(lower(t.value) = ? OR lower(t.value) LIKE ? ESCAPE '\\')";
                        self.cu.tags.len()
                    ]
                    .join(" OR ");
                    parts.push(format!(
                        "note_id IN (SELECT n.id FROM {} n, json_each(n.tags_json) t WHERE {} AND ({each}))",
                        self.tb.notes(),
                        self.tb.scope("n.")
                    ));
                    args.push(self.tb.scope_arg());
                    for t in &self.cu.tags {
                        let escaped = t
                            .replace('\\', "\\\\")
                            .replace('%', "\\%")
                            .replace('_', "\\_");
                        args.push(Sql::Text(t.clone()));
                        args.push(Sql::Text(format!("{escaped}::%")));
                    }
                }
                if let Some(key) = &self.cu.source {
                    parts.push(format!(
                        "note_id IN (SELECT n.id FROM {} n WHERE {} AND n.deleted_at IS NULL AND n.source_key = ?)",
                        self.tb.notes(),
                        self.tb.scope("n.")
                    ));
                    args.push(self.tb.scope_arg());
                    args.push(Sql::Text(key.clone()));
                }
                let cond = if parts.is_empty() {
                    "1".to_owned()
                } else {
                    parts.join(" AND ")
                };
                (
                    cond,
                    args,
                    "queue NOT IN ('learning', 'relearning', 'review'), COALESCE(due_day, 0), new_position IS NULL, new_position, note_created_at, id",
                )
            }
        }
    }

    /// 还没答过的候选（[ids]：Some((列表, true)) = 只在这些卡里找，Some((列表, false)) = 排除这些卡）：按顺序
    /// 第一张与总数（数到 [cap] 为止）。
    fn candidates(
        &self,
        ids: Option<(&[&str], bool)>,
        cap: i64,
    ) -> Result<(Option<String>, i64), String> {
        let id_filter = match ids {
            Some((l, true)) if l.is_empty() => return Ok((None, 0)),
            Some((l, keep)) if !l.is_empty() => format!(
                " AND id {}IN ({})",
                if keep { "" } else { "NOT " },
                marks(self.tb, l.len())
            ),
            _ => String::new(),
        };
        let (cond, cond_args, order) = self.condition();
        let tail = format!(
            "{} AND {cond} AND NOT {}{id_filter}",
            self.base(),
            self.answered.0
        );
        let mut args = self.base_args();
        args.extend(cond_args);
        args.extend(self.answered.1.iter().cloned());
        args.extend(
            ids.into_iter()
                .flat_map(|(l, _)| l.iter())
                .map(|e| self.tb.id_arg(e)),
        );
        let first: Option<String> = {
            let mut stmt = self
                .tb
                .conn()
                .prepare_cached(&format!(
                    "SELECT {} {tail} ORDER BY {order} LIMIT 1",
                    self.tb.id_sel("id")
                ))
                .map_err(sql)?;
            let mut q = stmt.query(params_from_iter(args.clone())).map_err(sql)?;
            match q.next().map_err(sql)? {
                Some(r) => Some(self.tb.id_get(r, 0).map_err(sql)?),
                None => None,
            }
        };
        let mut count_args = args;
        count_args.push(Sql::Integer(cap.max(0)));
        let count: i64 = self
            .tb
            .conn()
            .query_row(
                &format!("SELECT COUNT(*) FROM (SELECT 1 {tail} LIMIT ?)"),
                params_from_iter(count_args),
                |r| r.get(0),
            )
            .map_err(sql)?;
        Ok((first, count))
    }

    /// (下一张, 再下一张, 剩余候选, 会话学习卡数)。
    fn pick(&self, exclude: &[&str]) -> Result<(Option<String>, Option<String>, i64, i64), String> {
        let learning = self.learning()?;
        let room = (self.cu.limit - self.done()?).max(0);
        let (_, left) = self.candidates(None, room)?;
        let ahead = self.ctx.now + LEARN_AHEAD_MS;
        let next_of = |ex: &[&str]| -> Result<Option<String>, String> {
            let free = |id: &str| !ex.contains(&id);
            if let Some((id, _)) = learning
                .iter()
                .find(|(id, due)| *due <= self.ctx.now && free(id))
            {
                return Ok(Some(id.clone()));
            }
            // 被排除的卡里还是候选的（复习页排除的是正在显示 / 预取、马上要答的卡）先占掉 [room]，免得多出。
            if room > 0 && left > 0 {
                let (_, held) = self.candidates(Some((ex, true)), room)?;
                if room - held > 0 {
                    let (first, _) = self.candidates(Some((ex, false)), 1)?;
                    if first.is_some() {
                        return Ok(first);
                    }
                }
            }
            Ok(learning
                .iter()
                .find(|(id, due)| *due <= ahead && free(id))
                .map(|(id, _)| id.clone()))
        };
        let mut ex: Vec<&str> = exclude.to_vec();
        let next = next_of(&ex)?;
        let mut after = None;
        if let Some(n) = &next {
            ex.push(n);
            after = next_of(&ex)?;
        }
        let learn = learning.iter().filter(|(_, due)| *due <= ahead).count() as i64;
        Ok((next, after, left, learn))
    }
}

/// 请求里的「此刻」与日界。
pub(crate) fn when(req: &Value) -> Result<(i64, Day), String> {
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("study: missing now")?;
    let day = Day {
        utc_offset_min: req
            .get("utcOff")
            .and_then(Value::as_i64)
            .ok_or("study: missing utcOff")?,
        rollover_hour: req
            .get("rollover")
            .and_then(Value::as_i64)
            .ok_or("study: missing rollover")?,
    };
    Ok((now, day))
}

/// 一次排队（见文件头）。[c] 是一个读快照（或写连接上的同一个事务：作答落库后接着算）；[uncommitted] = [c] 是
/// 写连接上还没结束的事务（会话连未提交的改动一起重读，store/queue.rs）。
pub(crate) fn study(
    c: &Connection,
    hub: &StudyHub,
    uncommitted: bool,
    profile: &str,
    req: &Value,
) -> Result<Value, String> {
    let (now, day) = when(req)?;
    hub.with_session(c, profile, day, day.index(now), uncommitted, |s| {
        let tree = DeckTree::load(c, profile)?;
        run(&mut SessionSource(s, &P3Tables { c, profile }), tree, req)
    })
}

/// 测试基准的排队：数据从 [SqlSource] 取，牌组树 [tree] 由调用方在同一个读快照里读好（ID 与 [src] 同一口径）。
#[cfg(test)]
pub(crate) fn run_with(
    src: &mut SqlSource<'_>,
    tree: DeckTree,
    req: &Value,
) -> Result<Value, String> {
    run(src, tree, req)
}

/// 在常驻会话 [s] 上排队；新卡 / 自定义学习那几条 SQL 落在 [tb]（新代 `store/gen4/cmd/study.rs`：缓存层的表）。
pub(crate) fn run_session(
    s: &mut Session,
    tb: &dyn Tables,
    tree: DeckTree,
    req: &Value,
) -> Result<Value, String> {
    run(&mut SessionSource(s, tb), tree, req)
}

fn run(src: &mut dyn Source, tree: DeckTree, req: &Value) -> Result<Value, String> {
    let (now, day) = when(req)?;
    let root = req.get("deck").and_then(Value::as_str);
    // 出卡顺序随所点牌组的 own 祖先（读完牌组树才知道）；要出卡、不是自定义学习时才让会话建这个顺序的索引。
    let (order, mix) = root.map_or((ReviewOrder::default(), NewMix::default()), |r| {
        (tree.review_order(r), tree.new_mix(r))
    });
    let picks =
        req["pick"] == Value::Bool(true) && !req.get("custom").is_some_and(Value::is_object);
    if root.is_some() && picks {
        src.ensure_order(order);
    }
    let src: &dyn Source = src;
    let ctx = Ctx {
        tree,
        day,
        now,
        today: day.index(now),
        logs: src.logs(),
    };
    if root.is_some_and(|r| !ctx.tree.decks.contains_key(r)) {
        return Ok(json!({"counts": null, "next": null, "after": null, "eligible": []}));
    }
    let ids: Vec<String> = match root {
        Some(r) => ctx.tree.subtree(r),
        None => {
            let mut v: Vec<String> = ctx.tree.decks.keys().cloned().collect();
            v.sort();
            v
        }
    };
    let mut t: HashMap<String, Tally> = src
        .tallies(now, root.map(|_| ids.as_slice()))?
        .into_iter()
        .map(|(k, v)| (k, Tally::of(v)))
        .collect();

    // RWKV-Instant：Dart 给目标保留率 / 排队设置与候选分数；排队规则在这里。
    let mut instant: HashMap<String, InstantDeck> = HashMap::new();
    let mut cands: Vec<(String, String, Option<i64>, f64)> = Vec::new();
    let rwkv = req.get("rwkv").filter(|v| v.is_object());
    if let Some(rw) = rwkv {
        for (d, s) in rw["decks"].as_object().into_iter().flatten() {
            let n = |i: usize| s.get(i).and_then(Value::as_i64).unwrap_or(0);
            instant.insert(
                d.clone(),
                InstantDeck {
                    target: s
                        .get(0)
                        .and_then(Value::as_f64)
                        .ok_or("study: bad rwkv deck")?,
                    min_reviews: n(1),
                    repeat_reviews: n(2),
                    repeat_seconds: n(3),
                },
            );
        }
        for x in rw["cands"].as_array().into_iter().flatten() {
            let (Some(id), Some(deck), Some(r)) = (x[0].as_str(), x[1].as_str(), x[3].as_f64())
            else {
                return Err("study: bad rwkv candidate".into());
            };
            cands.push((id.to_owned(), deck.to_owned(), x[2].as_i64(), r));
        }
    }
    let mut lookup: HashSet<String> = ctx
        .logs
        .introduced_cards()
        .chain(ctx.logs.reviewed_cards())
        .cloned()
        .collect();
    if rwkv.is_some() {
        lookup.extend(ctx.logs.answers().map(|(id, _)| id.clone()));
    }
    let found = src.decks_of(&lookup)?;
    let (eligible, held) = if rwkv.is_some() {
        instant_eligible(&ctx, &instant, &cands, &found)
    } else {
        (Vec::new(), Vec::new())
    };
    if rwkv.is_some() {
        for d in instant.keys() {
            if let Some(x) = t.get_mut(d) {
                x.due = 0;
            }
        }
        for (_, d, _) in &eligible {
            if let Some(x) = t.get_mut(d) {
                x.due += 1;
            }
        }
    }
    // 今天已学的新卡 / 已复习的卡补进各自牌组的计数（隐藏的卡不算）。
    for (id, (deck, hidden)) in &found {
        if *hidden {
            continue;
        }
        let Some(x) = t.get_mut(deck) else { continue };
        if ctx.logs.introduced(id) {
            x.new_done += 1;
        }
        if ctx.logs.reviewed(id) {
            x.review_done += 1;
            x.review_answers += ctx.logs.review_answers(id);
            x.review_ms += ctx.logs.review_ms(id);
        }
    }
    // 新卡负荷（只算 FSRS；RWKV 不贡献负荷）：到期数是「还剩多少」，随作答减少，单拿它和预算比，复习做到一半
    // 「暂停」就会自己解除。改按今天实际要做的复习量：已复习 + 剩余到期，不超过这个牌组今天的复习上限——超出上限的
    // 部分今天本来也不会出。RWKV 牌组的合格卡不是负荷信号，记 0，免得经子树累加推高 FSRS 祖先的负荷
    // （「忽略每日复习上限」只有 RWKV 牌组才可能开，所以这里不用再看它）。
    for (d, x) in t.iter_mut() {
        if ctx.tree.uses_rwkv(d) {
            x.load = 0;
            continue;
        }
        let mut load = x.due + x.review_done;
        if let Some(node) = ctx.tree.decks.get(d.as_str()) {
            let (_, ext_review) = today_extension(&node.view["ext"], ctx.today);
            let limit = int(&node.view, "rp", 200) + ext_review;
            // 负荷上界 = 已复习的卡 + 按牌组单位今天还会出的卡（[LimitUnit::review_room] 同一规则）：卡片数下保持
            // 「上限」本身（加单位之前的口径，已复习超过上限时也按上限）；次数下同一张卡多答的那几次也占额度，但
            // 已复习的卡照算、不会因为多答而让负荷变负；分钟下全天不截：时长上限不折成张数（不预估以后每张用多久），
            // 给不出一个不随作答变化的张数上界——「用满后只剩已复习的」会让负荷在用满那一刻从 到期 + 已复习 掉到
            // 已复习，「暂停」当天自己解除，正是上面要避免的；与复习上限设得很大的牌组同口径。
            let cap = match LimitUnit::of_view(&node.view) {
                LimitUnit::Cards => limit,
                LimitUnit::Reviews => x.review_done + (limit - x.review_answers).max(0),
                LimitUnit::Minutes => load,
            };
            load = load.min(cap);
        }
        x.load = load;
    }
    let counts = count_tree(&ctx, &t, &ids, root);
    let (mut next, mut after) = (None, None);
    // 出卡排空时，最早什么时候不靠任何写入就又排得出（距 [now] 的毫秒数；[Picker::wake]）。
    let mut wake_in: Option<i64> = None;
    let mut custom_out = Value::Null;
    let custom = match req.get("custom").filter(|v| v.is_object()) {
        Some(v) => Some(CustomStudy::of(v)?),
        None => None,
    };
    if let (Some(_), Some(cu)) = (root, &custom) {
        // 自定义学习：不看每日上限、不出卡上的 RWKV 规则（[CustomStudy]）；计数照常给（牌组列表 / 复习页顶栏）。
        let exclude: Vec<String> = req["exclude"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect();
        let ex: Vec<&str> = exclude.iter().map(String::as_str).collect();
        let picker = CustomPicker {
            tb: src.tables(),
            ctx: &ctx,
            decks: &ids,
            cu,
            answered: src.tables().answered(
                cu.since,
                src.resident(),
                LogState::window(ctx.day, ctx.today).1,
            )?,
        };
        let (n, a, left, learn) = picker.pick(&ex)?;
        if req["pick"] == Value::Bool(true) {
            (next, after) = (n, a);
        }
        custom_out = json!({"left": left, "learn": learn});
    } else if let (Some(r), true) = (root, req["pick"] == Value::Bool(true)) {
        let exclude: Vec<String> = req["exclude"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect();
        let picker = Picker {
            src,
            ctx: &ctx,
            root: r,
            sub: &ids,
            counts: &counts,
            instant_decks: instant.keys().map(String::as_str).collect(),
            eligible: &eligible,
            order,
            mix,
        };
        let mut ex: Vec<&str> = exclude.iter().map(String::as_str).collect();
        let first = picker.next(&ex, (0, 0))?;
        if let Some((n, kind)) = &first {
            ex.push(n);
            let v = match kind {
                Kind::New => (1, 0),
                Kind::Review => (0, 1),
                Kind::Learning => (0, 0),
            };
            after = picker.next(&ex, v)?.map(|(id, _)| id);
        } else {
            wake_in = picker.wake(&ex, &held)?.map(|at| at - now);
        }
        next = first.map(|(id, _)| id);
    }
    let counts_json: serde_json::Map<String, Value> = counts
        .iter()
        .map(|(id, k)| {
            let row = json!([
                k.new_count,
                k.learn_count,
                k.review_count,
                k.sub.total,
                k.budget.limit,
                k.budget.allowed,
                k.budget.review_budget,
                k.budget.reason,
                k.review_minutes_left
            ]);
            (id.clone(), row)
        })
        .collect();
    Ok(json!({
        "counts": counts_json,
        "next": next,
        "after": after,
        "eligible": eligible.iter().map(|(id, _, _)| id.clone()).collect::<Vec<_>>(),
        "custom": custom_out,
        "wakeIn": wake_in,
    }))
}

impl crate::store::SrsCore {
    /// 只读排队（牌组列表 / 复习页的计数与出卡）：走读连接的快照，不排在同步投递 / 缓存刷新这类长写后面
    /// （旧库搬迁的事务开着时在写连接上读，看得见未提交的行，[crate::store::SrsCore::read_visible_tx]）。
    #[cfg(test)]
    pub fn study(&self, profile: &str, req: &Value) -> Result<Value, String> {
        self.read_visible_tx(|c, uncommitted| study(c, &self.study_hub, uncommitted, profile, req))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::SrsCore;
    use crate::store::queue::{LOGS_SQL, ROW_COLUMNS};
    use std::sync::atomic::Ordering as AtomicOrdering;

    /// 缺省新卡计划下与旧 Dart `srsComputeNewCardBudget`（已删）的边界逐项一致。
    #[test]
    fn budget_matches_dart_rules() {
        let d = NewCardPlan::default();
        // 数据不足（有复习的天 < 7）：预算 = 上限 × 10。
        assert_eq!(
            new_card_budget(20, 150, &[5; 3], d),
            Budget {
                limit: 20,
                allowed: 20,
                review_budget: 200,
                reason: None
            }
        );
        assert_eq!(new_card_budget(20, 100, &[50], d).allowed, 20);
        // 超 2 倍预算：暂停。
        assert_eq!(new_card_budget(20, 401, &[0; 30], d).reason, Some("paused"));
        assert_eq!(new_card_budget(20, 401, &[0; 30], d).allowed, 0);
        // 预算到 2 倍之间线性缩减：300 / 200 → 系数 0.5。
        assert_eq!(
            new_card_budget(20, 300, &[0; 30], d),
            Budget {
                limit: 20,
                allowed: 10,
                review_budget: 200,
                reason: Some("reduced")
            }
        );
        // 日均 100（30 天都有复习）× 1.5 = 150 < 地板 200。
        assert_eq!(new_card_budget(20, 0, &[100; 30], d).review_budget, 200);
        // 日均 333 × 1.5 = 499.5 → 四舍五入 500（Dart `round` 远离零）。
        assert_eq!(new_card_budget(20, 0, &[333; 30], d).review_budget, 500);
        // 只按有复习的天平均：隔天 300 → 预算 450。
        let alt: Vec<i64> = (0..30).map(|i| if i % 2 == 0 { 300 } else { 0 }).collect();
        assert_eq!(
            new_card_budget(20, 250, &alt, d),
            Budget {
                limit: 20,
                allowed: 20,
                review_budget: 450,
                reason: None
            }
        );
        // 上限 0：预算 0 → 不缩减分支。
        assert_eq!(
            new_card_budget(0, 10, &[0; 30], d),
            Budget {
                limit: 0,
                allowed: 0,
                review_budget: 0,
                reason: None
            }
        );
    }

    /// 新卡计划（PR #2663 原写在已删的 Dart 计数路径上）：关掉按复习量调整、预算百分比、复习少时多出。
    #[test]
    fn budget_follows_the_new_card_plan() {
        let steady = [100i64; 30];
        let plan = |auto_load: bool, budget_percent: i64, boost_percent: i64| NewCardPlan {
            auto_load,
            budget_percent,
            boost_percent,
        };
        // 关掉：到期再多也按每日上限出，预算记 0。
        assert_eq!(
            new_card_budget(20, 5000, &steady, plan(false, 150, 0)),
            Budget {
                limit: 20,
                allowed: 20,
                review_budget: 0,
                reason: None
            }
        );
        // 预算 100%：日均 100 → 预算 max(100, 5 × 10) = 100；到期 150 → 系数 0.5 → 2。
        assert_eq!(
            new_card_budget(5, 150, &steady, plan(true, 100, 0)),
            Budget {
                limit: 5,
                allowed: 2,
                review_budget: 100,
                reason: Some("reduced")
            }
        );
        // 预算 300%：同样的到期量不再缩减。
        assert_eq!(
            new_card_budget(5, 150, &steady, plan(true, 300, 0)),
            Budget {
                limit: 5,
                allowed: 5,
                review_budget: 300,
                reason: None
            }
        );
        // 多出 50%：0 到期 → 10 + 5；一半预算（75 / 150）处不加；其间线性（20 → share 0.733 → +3.67 → +3）。
        assert_eq!(
            new_card_budget(10, 0, &steady, plan(true, 150, 50)),
            Budget {
                limit: 10,
                allowed: 15,
                review_budget: 150,
                reason: Some("increased")
            }
        );
        assert_eq!(
            new_card_budget(10, 75, &steady, plan(true, 150, 50)),
            Budget {
                limit: 10,
                allowed: 10,
                review_budget: 150,
                reason: None
            }
        );
        assert_eq!(
            new_card_budget(10, 20, &steady, plan(true, 150, 50)).allowed,
            13
        );
        // 多出的量向下取整到 0 时不报 increased。
        assert_eq!(
            new_card_budget(1, 70, &steady, plan(true, 150, 10)),
            Budget {
                limit: 1,
                allowed: 1,
                review_budget: 150,
                reason: None
            }
        );
        // 数据不足时同样按上限 × 10 的预算多出。
        assert_eq!(
            new_card_budget(10, 0, &[], plan(true, 150, 200)).allowed,
            30
        );
    }

    /// `npl` 视图值 → 计划：与 Dart `SrsNewCardPlan.fromValue` 同规则（缺项 / 坏值回落，越界夹住）。
    #[test]
    fn new_card_plan_parses_like_dart() {
        assert_eq!(NewCardPlan::of(&Value::Null), NewCardPlan::default());
        assert_eq!(NewCardPlan::of(&json!("x")), NewCardPlan::default());
        assert_eq!(
            NewCardPlan::of(&json!({"auto": "x", "budget": 5, "boost": 99999})),
            NewCardPlan {
                auto_load: true,
                budget_percent: NewCardPlan::MIN_BUDGET_PERCENT,
                boost_percent: NewCardPlan::MAX_BOOST_PERCENT
            }
        );
        assert_eq!(
            NewCardPlan::of(&json!({"auto": false, "budget": 200, "boost": 30})),
            NewCardPlan {
                auto_load: false,
                budget_percent: 200,
                boost_percent: 30
            }
        );
        assert_eq!(
            NewCardPlan::of(&json!({"budget": 1.5, "boost": -3})),
            NewCardPlan {
                auto_load: true,
                budget_percent: 150,
                boost_percent: 0
            }
        );
    }

    /// L2 的逐条 SQL 排队（[SqlSource]）：会话实现的对拍基准。
    mod oracle {
        use super::super::*;

        /// 用旧实现排一次（每次整段扫日志；[SqlSource]）。
        pub(super) fn study(c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
            let (now, day) = when(req)?;
            let today = day.index(now);
            let tb = P3Tables { c, profile };
            let mut src = SqlSource {
                tb: &tb,
                today,
                logs: LogState::scan(c, profile, day, today)?,
            };
            let tree = DeckTree::load(c, profile)?;
            run(&mut src, tree, req)
        }
    }

    /// 排队仍在 SQL 里的查询走对应索引：新卡按索引序取第一张（无 TEMP B-TREE）、会话重建的日志区间扫描、
    /// 按 id 重读缓存行 / 日志走主键。
    #[test]
    fn queue_queries_use_their_indexes() {
        let mut c = rusqlite::Connection::open_in_memory().unwrap();
        crate::store::schema::migrate(&mut c).unwrap();
        let tb = P3Tables { c: &c, profile: P };
        let tb: &dyn Tables = &tb;
        let plan = |q: &str| -> String {
            let mut stmt = c.prepare(&format!("EXPLAIN QUERY PLAN {q}")).unwrap();
            let n = stmt.parameter_count();
            let rows: Vec<String> = stmt
                .query_map(
                    params_from_iter(std::iter::repeat_n(Sql::Integer(0), n)),
                    |r| r.get::<_, String>(3),
                )
                .unwrap()
                .map(Result::unwrap)
                .collect();
            rows.join("\n")
        };
        let mut wrong = Vec::new();
        let mut uses = |label: &str, q: &str, index: &str, sorted: bool| {
            let p = plan(q);
            if !p.contains(index) {
                wrong.push(format!("{label}: want {index}\n{p}"));
            }
            if sorted && p.contains("TEMP B-TREE") {
                wrong.push(format!("{label}: want no TEMP B-TREE\n{p}"));
            }
        };
        for decks in [1, 3] {
            for ex in [0, 2] {
                uses(
                    "new(freq)",
                    &first_sql(
                        tb,
                        CardIx::NewFreq,
                        decks,
                        "queue = 'new'",
                        NEW_BY_FREQUENCY,
                        ex,
                    ),
                    "idx_srs_cards_cache_new_freq",
                    true,
                );
                uses(
                    "new(position)",
                    &first_sql(
                        tb,
                        CardIx::NewPosition,
                        decks,
                        "queue = 'new'",
                        NEW_BY_POSITION,
                        ex,
                    ),
                    "idx_srs_cards_cache_new_position",
                    true,
                );
            }
        }
        uses(
            "logs",
            LOGS_SQL,
            "idx_srs_review_logs_profile_kind_time",
            true,
        );
        uses(
            "logs by id",
            &crate::store::queue::logs_by_id_sql(2),
            "sqlite_autoindex_srs_review_logs_1",
            false,
        );
        uses(
            "rows by id",
            &format!("{ROW_COLUMNS} WHERE id IN (?, ?) AND +profile_uid = srs_id(?)"),
            "sqlite_autoindex_srs_cards_cache_1",
            false,
        );
        assert!(wrong.is_empty(), "{}", wrong.join("\n\n"));
    }

    /// 可复现的伪随机数（xorshift）。
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }

        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }

        fn pick<'a, T>(&mut self, xs: &'a [T]) -> &'a T {
            &xs[self.below(xs.len() as u64) as usize]
        }
    }

    const P: &str = "p";
    const DECKS: [&str; 6] = ["R", "RA", "RA1", "RB", "O", "Z"];
    const H: i64 = 3_600_000;

    /// 测试写入的落点：[SrsCore] = 原始通道（每条语句各自提交）；[Connection] = 测试攥着的写连接（上面开着一笔
    /// 事务——内核写命令在它的 SAVEPOINT 里落库后接着排队的形态；原始通道不许把事务留到调用之后）。
    trait Target {
        fn run(&self, sql: &str, params: &[Sql]) -> Result<Vec<u8>, String>;
    }

    impl Target for SrsCore {
        fn run(&self, sql: &str, params: &[Sql]) -> Result<Vec<u8>, String> {
            self.exec_raw(sql, params, false)
        }
    }

    impl Target for Connection {
        fn run(&self, sql: &str, params: &[Sql]) -> Result<Vec<u8>, String> {
            SrsCore::exec_on(self, sql, params, false)
        }
    }

    fn exec<T: Target + ?Sized>(core: &T, sql_text: &str, params: Vec<Sql>) {
        core.run(sql_text, &params)
            .unwrap_or_else(|e| panic!("{sql_text}: {e}"));
    }

    fn edit<T: Target + ?Sized>(core: &T, n: &mut i64, entity: &str, key: &str, v: Value) {
        *n += 1;
        let json = json!({"p": P, "k": "deck", "e": entity, "f": key, "w": "w", "s": *n, "v": v, "hlc": format!("{}:0:w", 1_700_000_000_000i64 + *n)}).to_string();
        exec(
            core,
            "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) VALUES (srs_id(?), srs_id(?), 'deck', srs_id(?), ?, 'w', ?, ?)",
            vec![
                Sql::Text(format!("e{n}")),
                Sql::Text(P.into()),
                Sql::Text(entity.into()),
                Sql::Text(key.into()),
                Sql::Integer(*n),
                Sql::Text(json),
            ],
        );
    }

    /// 一张随机卡（同一组稳定度 / 上次作答取值有限，制造 R 相等按 id 比的情形；含稳定度为零得 NULL、从没作答）。
    fn card_values(rng: &mut Rng, id: &str, today: i64, now: i64) -> Vec<Sql> {
        let deck = *rng.pick(&DECKS);
        let queue = *rng.pick(&[
            "new",
            "new",
            "learning",
            "relearning",
            "review",
            "review",
            "review",
            "review",
        ]);
        let opt = |rng: &mut Rng, v: i64| {
            if rng.below(6) == 0 {
                Sql::Null
            } else {
                Sql::Integer(v)
            }
        };
        let due_day = today - 3 + rng.below(6) as i64;
        let due_at = now - 30 * 60_000 + rng.below(4) as i64 * 15 * 60_000;
        let stab = match rng.below(8) {
            0 => Sql::Null,
            1 => Sql::Real(0.0),
            n => Sql::Real([0.5, 1.0, 2.5, 10.0, 40.0, 3.0][n as usize - 2]),
        };
        let last = now
            - [1, 2, 3, 5, 8, 13][rng.below(6) as usize] * 86_400_000
            - [0, 3 * H][rng.below(2) as usize];
        let buried = match rng.below(10) {
            0 => Sql::Integer(today),
            1 => Sql::Integer(today + 1),
            2 => Sql::Integer(today - 1),
            _ => Sql::Null,
        };
        vec![
            Sql::Text(id.into()),
            Sql::Text(P.into()),
            Sql::Text(deck.into()),
            Sql::Integer((rng.below(12) == 0) as i64),
            buried,
            Sql::Integer((rng.below(15) == 0) as i64),
            Sql::Text(queue.into()),
            opt(rng, due_day),
            opt(rng, due_at),
            stab,
            opt(rng, last),
            Sql::Text(if rng.below(20) == 0 {
                "anki".into()
            } else {
                "fushi".into()
            }),
            Sql::Integer(rng.below(50) as i64),
            if rng.below(3) == 0 {
                Sql::Null
            } else {
                Sql::Integer(rng.below(40) as i64)
            },
            if rng.below(3) == 0 {
                Sql::Null
            } else {
                Sql::Integer(rng.below(40) as i64)
            },
        ]
    }

    const CARD_UPSERT: &str = "INSERT OR REPLACE INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, suspended, buried_until_day, \
         hidden, queue, due_day, due_at, stability, last_reviewed_at, scheduler, note_created_at, new_position, freq_rank) \
         VALUES (srs_id(?1), srs_id(?2), srs_id(?1), 't', srs_id(?3), ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)";

    /// [CARD_UPSERT] 再加间隔天数（?16）与难度（?17）：复习顺序的静态键要用。
    const CARD_UPSERT_ORDERED: &str = "INSERT OR REPLACE INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, suspended, buried_until_day, \
         hidden, queue, due_day, due_at, stability, last_reviewed_at, scheduler, note_created_at, new_position, freq_rank, scheduled_days, difficulty) \
         VALUES (srs_id(?1), srs_id(?2), srs_id(?1), 't', srs_id(?3), ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)";

    /// [card_values] 加上间隔天数与难度（取值有限，制造同键按当天哈希断平；含难度为空）。
    fn card_values_ordered(rng: &mut Rng, id: &str, today: i64, now: i64) -> Vec<Sql> {
        let mut v = card_values(rng, id, today, now);
        v.push(Sql::Integer(rng.below(4) as i64));
        v.push(match rng.below(5) {
            0 => Sql::Null,
            n => Sql::Real([2.0, 5.5, 5.5, 9.0][n as usize - 1]),
        });
        v
    }

    fn log<T: Target + ?Sized>(
        core: &T,
        n: &mut i64,
        card: &str,
        at: i64,
        ty: &str,
        reps: i64,
        kind: &str,
    ) {
        // 用时随序号变（0 ~ 84 秒）：分钟单位的已用时长在随机对拍里也有增有减。
        let ms = (*n % 13) * 7_000;
        log_ms(core, n, card, at, ty, reps, kind, ms);
    }

    /// [log]，指定作答用时（`duration_ms`）。
    #[allow(clippy::too_many_arguments)]
    fn log_ms<T: Target + ?Sized>(
        core: &T,
        n: &mut i64,
        card: &str,
        at: i64,
        ty: &str,
        reps: i64,
        kind: &str,
        ms: i64,
    ) {
        *n += 1;
        exec(
            core,
            "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, jslim) VALUES (srs_id(?), srs_id(?), srs_id(?), ?, 3, ?, ?, 'local', ?, ?)",
            vec![
                Sql::Text(format!("l{n}")),
                Sql::Text(P.into()),
                Sql::Text(card.into()),
                Sql::Text(kind.into()),
                Sql::Integer(at),
                Sql::Text(ty.into()),
                Sql::Integer(ms),
                Sql::Text(json!({"res": {"reps": reps}}).to_string()),
            ],
        );
    }

    /// 比一轮：几个根（含全部牌组）、带 / 不带排除、偶尔带 RWKV 候选；会话结果与旧实现逐项相同。
    /// 返回出了几张非空的「下一张 / 再下一张」（测试自检：对拍不是一直在比空结果）。
    /// [held]：测试攥着写连接、上面开着事务时给它——两边都在这条连接上算（看得见未提交的行），就是内核写命令在
    /// 自己的 SAVEPOINT 里落库后接着排队的形态；否则走 [SrsCore::study]（读连接的已提交快照）。
    fn compare(
        core: &SrsCore,
        held: Option<&Connection>,
        rng: &mut Rng,
        now: i64,
        day: Day,
        cards: &[String],
        step: usize,
    ) -> usize {
        let mut picked = 0;
        for root in [
            None,
            Some("R"),
            Some("RA"),
            Some("RB"),
            Some("O"),
            Some("missing"),
        ] {
            let mut req = json!({"now": now, "utcOff": day.utc_offset_min, "rollover": day.rollover_hour, "pick": true});
            if let Some(r) = root {
                req["deck"] = json!(r);
            }
            if rng.below(2) == 0 && !cards.is_empty() {
                let ex: Vec<&String> = (0..1 + rng.below(3)).map(|_| rng.pick(cards)).collect();
                req["exclude"] = json!(ex);
            }
            if rng.below(3) == 0 && !cards.is_empty() {
                let cands: Vec<Value> = (0..4)
                    .map(|_| {
                        json!([
                            rng.pick(cards),
                            "O",
                            if rng.below(2) == 0 {
                                Value::Null
                            } else {
                                json!(now - 2 * H)
                            },
                            rng.below(100) as f64 / 100.0
                        ])
                    })
                    .collect();
                req["rwkv"] = json!({"decks": {"O": [0.7, 2, 1, 60]}, "cands": cands});
            }
            let (got, want) = match held {
                Some(c) => (
                    study(c, &core.study_hub, true, P, &req).unwrap(),
                    oracle::study(c, P, &req).unwrap(),
                ),
                None => (
                    core.study(P, &req).unwrap(),
                    core.read_visible(|c| oracle::study(c, P, &req)).unwrap(),
                ),
            };
            assert_eq!(got, want, "step {step} root {root:?} req {req}");
            picked += usize::from(!got["next"].is_null()) + usize::from(!got["after"].is_null());
        }
        // 复习顺序索引：不经每日上限（上限常把复习挡成 0），直接拿会话的顺序索引与 SQL 全量排序比队首。索引按天
        // 懒建一次，之后只靠增量重读维护，所以这里比的是增量维护的结果。
        let today = day.index(now);
        for order in [
            ReviewOrder::DueDate,
            ReviewOrder::Difficulty,
            ReviewOrder::IntervalAscending,
            ReviewOrder::Random,
        ] {
            let ex: Vec<&str> = if cards.is_empty() {
                Vec::new()
            } else {
                (0..rng.below(3))
                    .map(|_| rng.pick(cards).as_str())
                    .collect()
            };
            let ex: HashSet<&str> = ex.into_iter().collect();
            let session_first = |c: &Connection, unc: bool| {
                core.study_hub.with_session(c, P, day, today, unc, |s| {
                    s.ensure_order(order);
                    s.first_due(&DECKS, order, now, &ex)
                })
            };
            let sql_first = |c: &Connection| {
                let tb = P3Tables { c, profile: P };
                let src = SqlSource {
                    tb: &tb,
                    today,
                    logs: LogState::default(),
                };
                src.first_by_key(&DECKS, order, &ex)
            };
            let (got, want) = match held {
                Some(c) => (session_first(c, true).unwrap(), sql_first(c).unwrap()),
                None => (
                    core.read_visible_tx(session_first).unwrap(),
                    core.read_visible(sql_first).unwrap(),
                ),
            };
            assert_eq!(
                got, want,
                "step {step} first due by {order:?}, exclude {ex:?}"
            );
            picked += usize::from(got.is_some());
        }
        picked
    }

    /// 常驻会话与旧的逐条 SQL 排队逐步对拍：随机改卡（换队列 / 到期 / 暂停 / 埋 / 隐藏 / 挪牌组 / 稳定度）、加删卡、
    /// 加删日志、改每日上限与新卡顺序、此刻前进（跨日、换翻日时刻 / UTC 偏移）、写连接上开着事务时写（事务内排队看得见
    /// 未提交的行；提交、整笔回滚、`ROLLBACK TO` 回滚一段）、一次写超过攒满阈值。每步每个根都与旧实现结果相同；
    /// 同一个日界里只建一次会话（增量），跨日 / 攒满才重建。
    #[test]
    fn resident_session_matches_the_sql_queue() {
        let dir = std::env::temp_dir().join(format!("ffsrs_study_session_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
        let mut n = 0i64;
        let mut logs = 0i64;
        for d in DECKS {
            exec(
                &core,
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
                vec![Sql::Text(d.into()), Sql::Text(P.into())],
            );
        }
        for (d, parent) in [("RA", "R"), ("RA1", "RA"), ("RB", "R")] {
            edit(&core, &mut n, d, "parent", json!(parent));
        }
        for (d, new, review) in [
            ("R", 6, 9),
            ("RA", 3, 4),
            ("RA1", 50, 50),
            ("RB", 20, 2),
            ("O", 4, 5),
            ("Z", 5, 5),
        ] {
            edit(
                &core,
                &mut n,
                d,
                "limits",
                json!({"new": new, "review": review}),
            );
        }
        // 出卡顺序（复习顺序 / 新卡与复习）跟参数归属走：R、O 是 FSRS 顶层，RA 自己一份参数（RA1 随 RA，RB 随 R）；
        // 没写算法的牌组按 RWKV，复习顺序恒为 R。下面随机改这几项、偶尔把 R 切成 RWKV。
        for d in ["R", "O", "RA"] {
            edit(&core, &mut n, d, "algorithm", json!({"alg": "fsrs6"}));
        }
        edit(&core, &mut n, "RA", "paramsMode", json!("own"));
        let mut day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let mut now = 1_760_000_000_000i64;
        let mut cards: Vec<String> = Vec::new();
        for i in 0..400 {
            let id = format!("c{i:04}");
            exec(
                &core,
                CARD_UPSERT_ORDERED,
                card_values_ordered(&mut rng, &id, day.index(now), now),
            );
            cards.push(id);
        }
        for _ in 0..300 {
            let card = rng.pick(&cards).clone();
            let at = now - rng.below(40) as i64 * 86_400_000 / 2 - rng.below(5) as i64 * H;
            log(
                &core,
                &mut logs,
                &card,
                at,
                *rng.pick(&["review", "learn", "relearn"]),
                1 + rng.below(2) as i64,
                "review",
            );
        }
        let mut builds_seen = 0;
        let mut picked = 0;
        // 攥着的写连接：上面开着一笔事务（跨若干步）。平时为空，每条写入走原始通道各自提交。
        let mut held: Option<crate::store::Conn<'_>> = None;
        macro_rules! on {
            () => {
                match held.as_deref() {
                    Some(c) => c as &dyn Target,
                    None => &core as &dyn Target,
                }
            };
        }
        for step in 0..700 {
            let today = day.index(now);
            let mut new_day = false;
            match rng.below(100) {
                0..=29 => {
                    let id = rng.pick(&cards).clone();
                    exec(
                        on!(),
                        CARD_UPSERT_ORDERED,
                        card_values_ordered(&mut rng, &id, today, now),
                    );
                }
                30..=37 => {
                    // 只改一两列（UPDATE 触发器）。
                    let id = rng.pick(&cards).clone();
                    let (col, v) = match rng.below(8) {
                        0 => ("suspended", Sql::Integer(rng.below(2) as i64)),
                        1 => (
                            "buried_until_day",
                            Sql::Integer(today + rng.below(2) as i64),
                        ),
                        2 => ("deck_id", Sql::Text((*rng.pick(&DECKS)).into())),
                        3 => ("hidden", Sql::Integer(rng.below(2) as i64)),
                        // 复习顺序的键变了：顺序索引要按旧键删、新键加。
                        4 => ("difficulty", Sql::Real(rng.below(10) as f64 + 0.5)),
                        5 => ("scheduled_days", Sql::Integer(rng.below(4) as i64)),
                        6 => ("due_day", Sql::Integer(today - 2 + rng.below(4) as i64)),
                        _ => ("stability", Sql::Real(rng.below(30) as f64 + 0.5)),
                    };
                    exec(
                        on!(),
                        &format!("UPDATE srs_cards_cache SET {col} = ? WHERE id = srs_id(?)"),
                        vec![v, Sql::Text(id)],
                    );
                }
                38..=42 => {
                    let id = format!("c{:04}", cards.len());
                    exec(
                        on!(),
                        CARD_UPSERT_ORDERED,
                        card_values_ordered(&mut rng, &id, today, now),
                    );
                    cards.push(id);
                }
                43..=45 => {
                    let id = rng.pick(&cards).clone();
                    exec(
                        on!(),
                        "DELETE FROM srs_cards_cache WHERE id = srs_id(?)",
                        vec![Sql::Text(id)],
                    );
                }
                46..=60 => {
                    // 作答：今天的日志（第一次学 / 复习），偶尔是别的种类或很久以前的。
                    let card = rng.pick(&cards).clone();
                    let at = now
                        - rng.below(3) as i64 * 60_000
                        - if rng.below(8) == 0 {
                            40 * 86_400_000
                        } else {
                            0
                        };
                    let kind = if rng.below(10) == 0 {
                        "manual"
                    } else {
                        "review"
                    };
                    log(
                        on!(),
                        &mut logs,
                        &card,
                        at,
                        *rng.pick(&["review", "learn", "relearn"]),
                        1 + rng.below(2) as i64,
                        kind,
                    );
                }
                61..=63 => {
                    let id = format!("l{}", 1 + rng.below(logs as u64));
                    exec(
                        on!(),
                        "DELETE FROM srs_review_logs WHERE id = srs_id(?)",
                        vec![Sql::Text(id)],
                    );
                }
                64..=66 => {
                    let d = *rng.pick(&DECKS);
                    if rng.below(3) == 0 {
                        // 上限单位（含不认识的值、非字符串的坏值）：O 是带「每天最少」的 RWKV 归属牌组。
                        edit(
                            on!(),
                            &mut n,
                            d,
                            "limitUnit",
                            match rng.below(5) {
                                0 => json!("reviews"),
                                1 => json!("cards"),
                                2 => json!("minutes"),
                                3 => json!("bogus"),
                                _ => json!(7),
                            },
                        );
                    } else {
                        edit(
                            on!(),
                            &mut n,
                            d,
                            "limits",
                            json!({"new": rng.below(8), "review": rng.below(12)}),
                        );
                    }
                }
                67 => {
                    edit(
                        on!(),
                        &mut n,
                        "R",
                        "newOrder",
                        json!(*rng.pick(&["position", "frequency"])),
                    );
                }
                68..=71 => {
                    // 出卡顺序：复习顺序（含不认识的值）/ 新卡与复习，偶尔把 R 在 FSRS 与 RWKV 之间切。
                    let d = *rng.pick(&["R", "O", "RA"]);
                    match rng.below(5) {
                        0 | 1 => edit(
                            on!(),
                            &mut n,
                            d,
                            "reviewOrder",
                            json!(*rng.pick(&[
                                "retrievability",
                                "dueDate",
                                "difficulty",
                                "intervalAscending",
                                "random",
                                "bogus",
                            ])),
                        ),
                        2 | 3 => edit(
                            on!(),
                            &mut n,
                            d,
                            "newMix",
                            json!(*rng.pick(&["afterReviews", "beforeReviews", "mixed", "bogus"])),
                        ),
                        _ => edit(
                            on!(),
                            &mut n,
                            "R",
                            "algorithm",
                            json!({"alg": *rng.pick(&["fsrs6", "rwkv"])}),
                        ),
                    }
                }
                72..=84 => now += rng.below(90) as i64 * 60_000,
                85..=87 => {
                    now += 20 * H + rng.below(10) as i64 * H;
                    new_day = true;
                }
                88 => {
                    day = Day {
                        utc_offset_min: *rng.pick(&[0, 540, -300]),
                        rollover_hour: *rng.pick(&[0, 4]),
                    };
                    new_day = true;
                }
                89..=94 if held.is_none() => {
                    let w = core.writer().unwrap();
                    w.execute_batch("BEGIN").unwrap();
                    held = Some(w);
                }
                89..=94 => {
                    let w = held.take().unwrap();
                    w.execute_batch(*rng.pick(&["COMMIT", "ROLLBACK"])).unwrap();
                }
                95..=97 => {
                    // 一段写在 SAVEPOINT 里又回滚掉（写命令中途出错）。外面没开事务时这个 SAVEPOINT 自成一笔。
                    let own = held.is_none();
                    if own {
                        held = Some(core.writer().unwrap());
                    }
                    exec(on!(), "SAVEPOINT t", vec![]);
                    let id = rng.pick(&cards).clone();
                    exec(
                        on!(),
                        CARD_UPSERT_ORDERED,
                        card_values_ordered(&mut rng, &id, today, now),
                    );
                    let card = rng.pick(&cards).clone();
                    log(on!(), &mut logs, &card, now, "review", 2, "review");
                    picked += compare(&core, held.as_deref(), &mut rng, now, day, &cards, step);
                    exec(on!(), "ROLLBACK TO t", vec![]);
                    exec(on!(), "RELEASE t", vec![]);
                    if own {
                        held = None;
                    }
                }
                _ if step % 233 == 0 => {
                    // 一条语句写超过攒满阈值：下次排队整份重建。
                    exec(
                        on!(),
                        "WITH RECURSIVE k(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM k WHERE i < ?) \
                         INSERT OR REPLACE INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, queue, due_day, stability, last_reviewed_at) \
                         SELECT printf('bulk%05d', i), ?, 'n', 't', 'Z', 'review', ?, 1.0 + (i % 7), ? - (i % 11) * 86400000 FROM k",
                        vec![
                            Sql::Integer(crate::store::queue::DIRTY_CAP as i64 + 10),
                            Sql::Text(P.into()),
                            Sql::Integer(today),
                            Sql::Integer(now),
                        ],
                    );
                    new_day = true;
                }
                _ => {}
            }
            let before = core.study_hub.builds.load(AtomicOrdering::SeqCst);
            picked += compare(&core, held.as_deref(), &mut rng, now, day, &cards, step);
            let built = core.study_hub.builds.load(AtomicOrdering::SeqCst) - before;
            if !new_day && step > 0 && day.index(now) == today {
                assert_eq!(built, 0, "step {step}: no rebuild within a day");
            }
            builds_seen += built;
        }
        if let Some(w) = held.take() {
            w.execute_batch("ROLLBACK").unwrap();
        }
        assert!(builds_seen < 60, "rebuilt {builds_seen} times");
        // 700 步 × 6 个根：大多数轮次真的出了卡（不是一直在比空结果）。
        assert!(picked > 3000, "picked {picked}");
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 新卡计划与「忽略每日复习上限」从牌组寄存器（`newPlan` / `rwkvQueue`）读进排队计数（PR #2663：以前只写在
    /// 已删的 Dart 计数路径上，设置能存、出卡不认）。
    /// - `rwkvQueue.ignoreLimit: true` 的 RWKV 牌组：到期卡全部计入，不按每日复习上限截；
    /// - 同样写了 true 的 FSRS 牌组、没有这个键的旧 RWKV 牌组：照旧截断；
    /// - `newPlan.boost`：没有到期复习时新卡配额按比例多出，原因是 "increased"；`auto: false` 时恒为每日上限。
    #[test]
    fn study_counts_read_new_plan_and_ignore_limit_from_deck_registers() {
        let dir = std::env::temp_dir().join(format!("ffsrs_study_plan_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let now = 1_760_000_000_000i64;
        let today = day.index(now);
        let mut n = 0i64;
        let decks = ["IGN", "OLD", "FS", "BOOST", "OFF", "RBOOST"];
        for d in decks {
            exec(
                &core,
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
                vec![Sql::Text(d.into()), Sql::Text(P.into())],
            );
            edit(&core, &mut n, d, "limits", json!({"new": 10, "review": 2}));
        }
        let ignore = json!({"minReviews": 0, "repeatReviews": 5, "repeatSeconds": 30, "refreshEvery": 1, "ignoreLimit": true});
        edit(&core, &mut n, "IGN", "rwkvQueue", ignore.clone());
        edit(
            &core,
            &mut n,
            "OLD",
            "rwkvQueue",
            json!({"minReviews": 0, "repeatReviews": 5, "repeatSeconds": 30, "refreshEvery": 1}),
        );
        edit(
            &core,
            &mut n,
            "FS",
            "algorithm",
            json!({"alg": "fsrs7", "auto": false}),
        );
        edit(&core, &mut n, "FS", "rwkvQueue", ignore);
        // 按复习量调整新卡只对 FSRS 牌组生效：BOOST / OFF 显式设成 FSRS；RBOOST 没写算法 = 缺省 RWKV，写了同样的
        // 新卡计划也不调整。
        for d in ["BOOST", "OFF"] {
            edit(
                &core,
                &mut n,
                d,
                "algorithm",
                json!({"alg": "fsrs7", "auto": false}),
            );
        }
        edit(
            &core,
            &mut n,
            "BOOST",
            "newPlan",
            json!({"auto": true, "budget": 150, "boost": 50}),
        );
        edit(
            &core,
            &mut n,
            "OFF",
            "newPlan",
            json!({"auto": false, "budget": 150, "boost": 50}),
        );
        edit(
            &core,
            &mut n,
            "RBOOST",
            "newPlan",
            json!({"auto": true, "budget": 150, "boost": 50}),
        );
        let mut k = 0;
        let mut card = |deck: &str, queue: &str| {
            k += 1;
            let id = format!("{deck}-{k:03}");
            exec(
                &core,
                CARD_UPSERT,
                vec![
                    Sql::Text(id),
                    Sql::Text(P.into()),
                    Sql::Text(deck.into()),
                    Sql::Integer(0),
                    Sql::Null,
                    Sql::Integer(0),
                    Sql::Text(queue.into()),
                    Sql::Integer(today - 1),
                    Sql::Null,
                    Sql::Real(2.0),
                    Sql::Integer(now - 5 * DAY_MS),
                    Sql::Text("fushi".into()),
                    Sql::Integer(k),
                    Sql::Integer(k),
                    Sql::Null,
                ],
            );
        };
        for d in ["IGN", "OLD", "FS"] {
            for _ in 0..7 {
                card(d, "review");
            }
        }
        for d in ["BOOST", "OFF", "RBOOST"] {
            for _ in 0..30 {
                card(d, "new");
            }
        }
        let req = json!({"now": now, "utcOff": day.utc_offset_min, "rollover": day.rollover_hour});
        let got = core.study(P, &req).unwrap();
        // 与逐条 SQL 的旧实现（同一个 count_tree）对拍，确认会话路径也走了同样的读法。
        assert_eq!(
            got,
            core.read_visible(|c| oracle::study(c, P, &req)).unwrap()
        );
        let row = |d: &str| got["counts"][d].clone();
        // [新, 学习, 到期, 总数, 新卡上限, 新卡配额, 复习预算, 原因, 剩余复习分钟]
        assert_eq!(row("IGN")[2], json!(7), "忽略上限：7 张到期全部计入");
        assert_eq!(
            row("OLD")[2],
            json!(2),
            "旧牌组没有 ignoreLimit 键：上限照旧生效"
        );
        assert_eq!(row("FS")[2], json!(2), "FSRS 牌组不认 ignoreLimit");
        // 没有复习日志：预算 = 10 × 10 = 100；到期 0 → 多出 50%。
        assert_eq!(
            row("BOOST"),
            json!([15, 0, 0, 30, 10, 15, 100, "increased", null])
        );
        assert_eq!(row("OFF"), json!([10, 0, 0, 30, 10, 10, 0, null, null]));
        // RWKV 牌组：寄存器里的 boost 50% 照存，但不按复习量调整——恒为每日新卡上限、复习预算 0、没有原因。
        assert_eq!(row("RBOOST"), json!([10, 0, 0, 30, 10, 10, 0, null, null]));
        // 今天已复习过 2 张之后：旧牌组没有剩余额度、不再出复习卡；忽略上限的牌组照出。
        let mut logs = 0i64;
        for d in ["IGN", "OLD"] {
            for i in 1..=2 {
                log(
                    &core,
                    &mut logs,
                    &format!("{d}-{:03}", if d == "IGN" { i } else { 7 + i }),
                    now - 60_000,
                    "review",
                    3,
                    "review",
                );
            }
        }
        for (d, want_next, want_due) in [("IGN", true, json!(7)), ("OLD", false, json!(0))] {
            let r = core
                .study(
                    P,
                    &json!({"now": now, "utcOff": 0, "rollover": 4, "deck": d, "pick": true}),
                )
                .unwrap();
            assert_eq!(r["counts"][d][2], want_due, "{d}");
            assert_eq!(!r["next"].is_null(), want_next, "{d}: {r}");
        }
        // FSRS 与 RWKV 混在同一棵子树里：父行的到期 = FSRS 子牌组的到期（FS 的 2 张，按 FS 自己的上限截）+ RWKV
        // 今天到期（合格）的卡；RWKV 等就绪（pending）时只有 FSRS 那部分。
        exec(
            &core,
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
            vec![Sql::Text("MIX".into()), Sql::Text(P.into())],
        );
        edit(&core, &mut n, "IGN", "parent", json!("MIX"));
        edit(&core, &mut n, "FS", "parent", json!("MIX"));
        // 挂到 MIX 下以后参数归属变成 MIX：FS 设成自己的参数（仍是 FSRS、照旧按自己的上限截），IGN 跟 MIX（缺省 RWKV），
        // 「忽略每日复习上限」写到 MIX 上。
        edit(&core, &mut n, "FS", "paramsMode", json!("own"));
        edit(
            &core,
            &mut n,
            "MIX",
            "rwkvQueue",
            json!({"minReviews": 0, "repeatReviews": 5, "repeatSeconds": 30, "refreshEvery": 1, "ignoreLimit": true}),
        );
        let cands = json!([["IGN-003", "IGN", null, 0.5]]);
        for (req, want_due) in [
            (
                json!({"now": now, "utcOff": 0, "rollover": 4, "rwkv": {"decks": {"IGN": [0.9, 0, 5, 30]}, "cands": [], "pending": true}}),
                2,
            ),
            (
                json!({"now": now, "utcOff": 0, "rollover": 4, "rwkv": {"decks": {"IGN": [0.9, 0, 5, 30]}, "cands": cands}}),
                3,
            ),
        ] {
            let got = core.study(P, &req).unwrap();
            assert_eq!(
                got,
                core.read_visible(|c| oracle::study(c, P, &req)).unwrap()
            );
            assert_eq!(got["counts"]["MIX"][2], json!(want_due), "{got}");
            assert_eq!(got["counts"]["MIX"].as_array().unwrap().len(), 9, "{got}");
        }
        // RWKV 牌组不按复习量调整新卡：合格的卡（RWKV 的「今天到期」）不是负荷信号，再多也不缩减 / 暂停新卡。
        // 新卡上限 1：FSRS 下预算 = 10、负荷超过 20 就暂停；RWKV 下恒为 1、复习预算 0。
        for d in ["OLD", "IGN"] {
            edit(&core, &mut n, d, "limits", json!({"new": 1, "review": 3}));
            for _ in 0..25 {
                card(d, "review");
            }
        }
        let cands: Vec<Value> = core
            .read_visible(|c| {
                let mut stmt = c.prepare("SELECT srs_idt(id), srs_idt(deck_id) FROM srs_cards_cache WHERE deck_id IN (srs_id('OLD'), srs_id('IGN'))").map_err(sql)?;
                let rows = stmt.query_map([], |r| Ok(json!([r.get::<_, String>(0)?, r.get::<_, String>(1)?, null, 0.5]))).map_err(sql)?;
                rows.collect::<Result<Vec<Value>, _>>().map_err(sql)
            })
            .unwrap();
        assert!(cands.len() >= 64, "{}", cands.len());
        let req = json!({"now": now, "utcOff": 0, "rollover": 4, "rwkv": {"decks": {"OLD": [0.9, 0, 0, 0], "IGN": [0.9, 0, 0, 0]}, "cands": cands}});
        let got = core.study(P, &req).unwrap();
        assert_eq!(
            got,
            core.read_visible(|c| oracle::study(c, P, &req)).unwrap()
        );
        // OLD：32 张合格，新卡照常 1 张，不算复习预算。
        assert_eq!(got["counts"]["OLD"][5], json!(1), "{got}");
        assert_eq!(got["counts"]["OLD"][6], json!(0), "{got}");
        assert_eq!(got["counts"]["OLD"][7], Value::Null, "{got}");
        // IGN 忽略每日复习上限：32 张合格 + 已复习 2 张，RWKV 合格卡再多也不暂停新卡。
        assert_eq!(got["counts"]["IGN"][5], json!(1), "{got}");
        assert_eq!(got["counts"]["IGN"][6], json!(0), "{got}");
        assert_eq!(got["counts"]["IGN"][7], Value::Null, "{got}");
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// FSRS 牌组「到期较多暂停出新卡」的负荷 = 今天已复习 + 现在剩余到期，按每日复习上限截断（RWKV 牌组不算负荷）：
    /// - 到期远超今天的复习上限：超出上限的部分今天不会出，不算负荷，新卡照常出（以前按全部到期数比，直接暂停）；
    /// - 复习做到一半：剩余到期减少，但已复习的照算，负荷不降，「暂停」不会在一天里自己解除。
    #[test]
    fn fsrs_new_card_load_counts_reviewed_today_plus_due_capped_by_review_limit() {
        let dir =
            std::env::temp_dir().join(format!("ffsrs_study_fsrs_load_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let now = 1_760_000_000_000i64;
        let today = day.index(now);
        let mut n = 0i64;
        // 新卡上限 1 → 预算 = 10（没有复习历史），负荷超过 20 才暂停、10~20 之间缩减。
        for (d, review_limit) in [("CAP", 3), ("FULL", 30)] {
            exec(
                &core,
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
                vec![Sql::Text(d.into()), Sql::Text(P.into())],
            );
            edit(
                &core,
                &mut n,
                d,
                "limits",
                json!({"new": 1, "review": review_limit}),
            );
            edit(
                &core,
                &mut n,
                d,
                "algorithm",
                json!({"alg": "fsrs7", "auto": false}),
            );
        }
        let card = |id: &str, deck: &str, queue: &str, due_day: i64, k: i64| {
            exec(
                &core,
                CARD_UPSERT,
                vec![
                    Sql::Text(id.into()),
                    Sql::Text(P.into()),
                    Sql::Text(deck.into()),
                    Sql::Integer(0),
                    Sql::Null,
                    Sql::Integer(0),
                    Sql::Text(queue.into()),
                    Sql::Integer(due_day),
                    Sql::Null,
                    Sql::Real(2.0),
                    Sql::Integer(now - 5 * DAY_MS),
                    Sql::Text("fushi".into()),
                    Sql::Integer(k),
                    Sql::Integer(k),
                    Sql::Null,
                ],
            );
        };
        for d in ["CAP", "FULL"] {
            for k in 0..25 {
                card(&format!("{d}-r{k:02}"), d, "review", today - 1, k);
            }
            for k in 0..5 {
                card(&format!("{d}-n{k:02}"), d, "new", today, 100 + k);
            }
        }
        let study = |req: &Value| -> Value {
            let got = core.study(P, req).unwrap();
            assert_eq!(
                got,
                core.read_visible(|c| oracle::study(c, P, req)).unwrap(),
                "{req}"
            );
            got
        };
        let req = json!({"now": now, "utcOff": day.utc_offset_min, "rollover": day.rollover_hour});
        let got = study(&req);
        // [新, 学习, 到期, 总数, 新卡上限, 新卡配额, 复习预算, 原因, 剩余复习分钟]
        // CAP：25 张到期，今天最多复习 3 张 → 负荷 3 ≤ 预算 10，新卡照常 1 张。
        assert_eq!(
            got["counts"]["CAP"],
            json!([1, 0, 3, 30, 1, 1, 10, null, null]),
            "{got}"
        );
        // FULL：25 张到期都在上限 30 以内 → 负荷 25 > 2 × 10，暂停。
        assert_eq!(
            got["counts"]["FULL"],
            json!([0, 0, 25, 30, 1, 0, 10, "paused", null]),
            "{got}"
        );
        // FULL 复习了 10 张（排到以后）：剩余到期 15，但已复习 10 张照算 → 负荷仍是 25，照旧暂停
        // （以前只看剩余到期 15，暂停变成缩减，一天里自己解除）。
        let mut logs = 0i64;
        for k in 0..10 {
            let id = format!("FULL-r{k:02}");
            log(&core, &mut logs, &id, now - 60_000, "review", 3, "review");
            card(&id, "FULL", "review", today + 5, k);
        }
        let got = study(&req);
        assert_eq!(
            got["counts"]["FULL"],
            json!([0, 0, 15, 30, 1, 0, 10, "paused", null]),
            "{got}"
        );
        assert_eq!(got["counts"]["CAP"][7], Value::Null, "{got}");
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 每日上限的单位（`limitUnit`，[LimitUnit]）：
    /// - reviews（缺省 / 坏值）按今天的复习作答条数、cards 按复习过的不同卡、minutes 按复习作答用时；学习 / 重学 /
    ///   新卡的作答与昨天的作答都不算；
    /// - 父子牌组各按自己的单位统计整棵子树的已用量；
    /// - minutes 没用满不截、用满了不再出复习卡，新卡负荷也跟着按「今天还会出的」算；
    /// - 跨日已用量清零；RWKV「忽略每日复习上限」照旧不截。
    #[test]
    fn review_limit_units_count_answers_cards_or_minutes() {
        let dir = std::env::temp_dir().join(format!("ffsrs_study_units_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let now = 1_760_000_000_000i64;
        let today = day.index(now);
        let mut n = 0i64;
        let deck = |n: &mut i64, d: &str, unit: Option<Value>, review: i64| {
            exec(
                &core,
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
                vec![Sql::Text(d.into()), Sql::Text(P.into())],
            );
            edit(&core, n, d, "limits", json!({"new": 0, "review": review}));
            edit(
                &core,
                n,
                d,
                "algorithm",
                json!({"alg": "fsrs7", "auto": false}),
            );
            if let Some(u) = unit {
                edit(&core, n, d, "limitUnit", u);
            }
        };
        let card = |id: &str, d: &str, queue: &str, due_day: i64, k: i64| {
            exec(
                &core,
                CARD_UPSERT,
                vec![
                    Sql::Text(id.into()),
                    Sql::Text(P.into()),
                    Sql::Text(d.into()),
                    Sql::Integer(0),
                    Sql::Null,
                    Sql::Integer(0),
                    Sql::Text(queue.into()),
                    Sql::Integer(due_day),
                    Sql::Null,
                    Sql::Real(2.0),
                    Sql::Integer(now - 5 * DAY_MS),
                    Sql::Text("fushi".into()),
                    Sql::Integer(k),
                    Sql::Integer(k),
                    Sql::Null,
                ],
            );
        };
        let study = |req: &Value| -> Value {
            let got = core.study(P, req).unwrap();
            assert_eq!(
                got,
                core.read_visible(|c| oracle::study(c, P, req)).unwrap(),
                "{req}"
            );
            got
        };
        // 每个牌组：10 张到期复习卡 + 今天答过的 A（复习作答 3 次，各 60 秒）、B（1 次 60 秒）、L（学习作答 10 分钟、
        // 重学作答 10 分钟，都不算）、Y（昨天的复习作答，不算）。已用：次数 4、卡片 2、时长 4 分钟。
        let mut logs = 0i64;
        let mut k = 0i64;
        let mut fill = |logs: &mut i64, d: &str| {
            for i in 0..10 {
                k += 1;
                card(&format!("{d}-due{i}"), d, "review", today - 1, k);
            }
            for (c, queue) in [
                ("A", "review"),
                ("B", "review"),
                ("L", "review"),
                ("Y", "review"),
            ] {
                k += 1;
                card(&format!("{d}-{c}"), d, queue, today + 5, k);
            }
            for _ in 0..3 {
                log_ms(
                    &core,
                    logs,
                    &format!("{d}-A"),
                    now - 600_000,
                    "review",
                    3,
                    "review",
                    60_000,
                );
            }
            log_ms(
                &core,
                logs,
                &format!("{d}-B"),
                now - 600_000,
                "review",
                3,
                "review",
                60_000,
            );
            log_ms(
                &core,
                logs,
                &format!("{d}-L"),
                now - 600_000,
                "learn",
                1,
                "review",
                600_000,
            );
            log_ms(
                &core,
                logs,
                &format!("{d}-L"),
                now - 500_000,
                "relearn",
                2,
                "review",
                600_000,
            );
            log_ms(
                &core,
                logs,
                &format!("{d}-Y"),
                now - DAY_MS,
                "review",
                3,
                "review",
                600_000,
            );
        };
        deck(&mut n, "UR", None, 5);
        deck(&mut n, "UB", Some(json!(42)), 5);
        deck(&mut n, "UC", Some(json!("cards")), 5);
        deck(&mut n, "UM", Some(json!("minutes")), 5);
        for d in ["UR", "UB", "UC", "UM"] {
            fill(&mut logs, d);
        }
        let req = json!({"now": now, "utcOff": 0, "rollover": 4});
        let got = study(&req);
        let due = |got: &Value, d: &str| got["counts"][d][2].as_i64().unwrap();
        assert_eq!(due(&got, "UR"), 1, "次数：5 − 4：{got}");
        assert_eq!(due(&got, "UB"), 1, "坏值按次数：{got}");
        assert_eq!(due(&got, "UC"), 3, "卡片数：5 − 2：{got}");
        assert_eq!(due(&got, "UM"), 10, "时长：4 分钟 < 5 分钟，不截：{got}");
        // 剩余复习分钟（第 9 列）：只有分钟单位有值，其余单位为 null。
        let minutes = |got: &Value, d: &str| got["counts"][d][8].clone();
        assert_eq!(minutes(&got, "UM"), json!(1), "5 − 4 = 1 分钟：{got}");
        for d in ["UR", "UB", "UC"] {
            assert_eq!(minutes(&got, d), Value::Null, "{d}：{got}");
        }
        // 出卡与计数一致：次数用完的牌组不再出复习卡。
        let pick = |d: &str| {
            study(&json!({"now": now, "utcOff": 0, "rollover": 4, "deck": d, "pick": true}))["next"]
                .clone()
        };
        assert!(!pick("UM").is_null());
        // 再各答一次（60 秒）：次数 5 用满、卡片 3、时长 5 分钟用满。
        for d in ["UR", "UC", "UM"] {
            log_ms(
                &core,
                &mut logs,
                &format!("{d}-due0"),
                now - 60_000,
                "review",
                3,
                "review",
                60_000,
            );
            card(&format!("{d}-due0"), d, "review", today + 5, 0);
        }
        let got = study(&req);
        assert_eq!(due(&got, "UR"), 0, "{got}");
        assert_eq!(due(&got, "UC"), 2, "{got}");
        assert_eq!(due(&got, "UM"), 0, "时长用满：{got}");
        assert_eq!(minutes(&got, "UM"), json!(0), "{got}");
        assert!(pick("UR").is_null());
        assert!(pick("UM").is_null());
        // 跨日：已用清零。
        let tomorrow = now + DAY_MS;
        let got = study(&json!({"now": tomorrow, "utcOff": 0, "rollover": 4}));
        assert_eq!(due(&got, "UR"), 5, "{got}");
        assert_eq!(due(&got, "UC"), 5, "{got}");
        assert_eq!(due(&got, "UM"), 9, "{got}");
        assert_eq!(minutes(&got, "UM"), json!(5), "{got}");

        // 父子牌组：各按自己的单位统计整棵子树。PR（次数，上限 6）下挂 PC（卡片数，上限 100）：子树已用 次数 4 /
        // 卡片 2 → PC 剩 98 张（到期 10 全出），PR 剩 2 次 → 父行 2。PM（分钟，上限 4）下挂 QC（卡片数）：子树用了
        // 4 分钟 → 父行 0，子牌组自己照出。
        deck(&mut n, "PR", None, 6);
        deck(&mut n, "PC", Some(json!("cards")), 100);
        deck(&mut n, "PM", Some(json!("minutes")), 4);
        deck(&mut n, "QC", Some(json!("cards")), 100);
        edit(&core, &mut n, "PC", "parent", json!("PR"));
        edit(&core, &mut n, "QC", "parent", json!("PM"));
        fill(&mut logs, "PC");
        fill(&mut logs, "QC");
        let got = study(&req);
        assert_eq!(due(&got, "PC"), 10, "{got}");
        assert_eq!(due(&got, "PR"), 2, "{got}");
        assert_eq!(due(&got, "QC"), 10, "{got}");
        assert_eq!(due(&got, "PM"), 0, "{got}");
        assert_eq!(minutes(&got, "PM"), json!(0), "整棵子树用了 4 分钟：{got}");
        assert_eq!(minutes(&got, "QC"), Value::Null, "{got}");

        // 分钟单位下的新卡负荷全天同一口径（到期 + 已复习，不截）：25 张 > 2 × 预算 10 → 暂停；时长用满后复习
        // 不再出，但负荷仍是 24 + 1 = 25，暂停不会在当天自己解除、新卡配额仍为 0。
        deck(&mut n, "NM", Some(json!("minutes")), 1);
        edit(
            &core,
            &mut n,
            "NM",
            "limits",
            json!({"new": 1, "review": 1}),
        );
        for i in 0..25 {
            card(&format!("NM-due{i}"), "NM", "review", today - 1, 500 + i);
        }
        card("NM-new", "NM", "new", today, 600);
        let got = study(&req);
        assert_eq!(got["counts"]["NM"][7], json!("paused"), "{got}");
        assert_eq!(got["counts"]["NM"][5], json!(0), "{got}");
        log_ms(
            &core,
            &mut logs,
            "NM-due0",
            now - 60_000,
            "review",
            3,
            "review",
            60_000,
        );
        card("NM-due0", "NM", "review", today + 5, 500);
        let got = study(&req);
        assert_eq!(got["counts"]["NM"][2], json!(0), "{got}");
        assert_eq!(got["counts"]["NM"][7], json!("paused"), "{got}");
        assert_eq!(got["counts"]["NM"][5], json!(0), "{got}");
        // 次数单位：同一张卡答的次数超过上限时负荷 = 已复习的 1 张（不变负、不误判成「复习少，多出新卡」）。
        deck(&mut n, "NR", None, 2);
        edit(
            &core,
            &mut n,
            "NR",
            "limits",
            json!({"new": 1, "review": 2}),
        );
        edit(
            &core,
            &mut n,
            "NR",
            "newPlan",
            json!({"auto": true, "budget": 150, "boost": 200}),
        );
        for i in 0..25 {
            card(&format!("NR-due{i}"), "NR", "review", today - 1, 700 + i);
        }
        card("NR-new", "NR", "new", today, 800);
        card("NR-done", "NR", "review", today + 5, 801);
        for _ in 0..5 {
            log_ms(
                &core,
                &mut logs,
                "NR-done",
                now - 60_000,
                "review",
                3,
                "review",
                1_000,
            );
        }
        let got = study(&req);
        // [新, 学习, 到期, 总数, 新卡上限, 新卡配额, 复习预算, 原因, 剩余复习分钟]：预算 10，负荷 1 → 多出 floor(2 × 0.8) = 1 张；
        // 负荷若算成 2 − 5 + 1 = −2 会多出 floor(2 × 1.4) = 2 张。
        assert_eq!(got["counts"]["NR"][2], json!(0), "{got}");
        assert_eq!(got["counts"]["NR"][5], json!(2), "{got}");
        assert_eq!(got["counts"]["NR"][7], json!("increased"), "{got}");
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// RWKV「每天最少复习数」按归属牌组的单位记配额：次数下今天复习过的卡按作答条数扣、卡片数下按张扣；分钟下
    /// 今天复习已用时长没到就把高于目标的卡全部补上，到了一张也不补。「忽略每日复习上限」在分钟单位下照旧不截。
    #[test]
    fn rwkv_minimum_follows_the_owner_limit_unit() {
        let dir =
            std::env::temp_dir().join(format!("ffsrs_study_units_rwkv_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let now = 1_760_000_000_000i64;
        let today = day.index(now);
        let mut n = 0i64;
        let mut logs = 0i64;
        let mut k = 0i64;
        let mut cands: HashMap<&str, Vec<Value>> = HashMap::new();
        // RWKV 牌组（没写算法 = 缺省 RWKV），上限 100，每天最少 3。今天：X 复习作答 2 次各 60 秒。
        // 子牌组 RWC 随 RW* 继承（共用配额、用归属牌组的单位，即使自己写了别的单位）。
        for (d, unit) in [
            ("RWR", json!("reviews")),
            ("RWC", json!("cards")),
            ("RWM", json!("minutes")),
            ("RWI", json!("minutes")),
        ] {
            exec(
                &core,
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
                vec![Sql::Text(d.into()), Sql::Text(P.into())],
            );
            edit(&core, &mut n, d, "limits", json!({"new": 0, "review": 100}));
            edit(&core, &mut n, d, "limitUnit", unit);
            edit(
                &core,
                &mut n,
                d,
                "rwkvQueue",
                json!({"minReviews": 3, "repeatReviews": 0, "repeatSeconds": 0, "ignoreLimit": d == "RWI"}),
            );
            let child = format!("{d}-kid");
            exec(
                &core,
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
                vec![Sql::Text(child.clone()), Sql::Text(P.into())],
            );
            edit(&core, &mut n, &child, "parent", json!(d));
            edit(&core, &mut n, &child, "limitUnit", json!("cards"));
            for i in 0..6 {
                k += 1;
                let id = format!("{d}-c{i}");
                let home = if i % 2 == 0 {
                    d.to_owned()
                } else {
                    child.clone()
                };
                exec(
                    &core,
                    CARD_UPSERT,
                    vec![
                        Sql::Text(id.clone()),
                        Sql::Text(P.into()),
                        Sql::Text(home.clone()),
                        Sql::Integer(0),
                        Sql::Null,
                        Sql::Integer(0),
                        Sql::Text("review".into()),
                        Sql::Integer(today + 3),
                        Sql::Null,
                        Sql::Real(2.0),
                        Sql::Integer(now - 5 * DAY_MS),
                        Sql::Text("fushi".into()),
                        Sql::Integer(k),
                        Sql::Integer(k),
                        Sql::Null,
                    ],
                );
                if i > 0 {
                    // R 都高于目标 0.9（本不该出），c1 最低。
                    cands.entry(d).or_default().push(json!([
                        id,
                        home,
                        null,
                        0.9 + i as f64 / 100.0
                    ]));
                }
            }
            for _ in 0..2 {
                log_ms(
                    &core,
                    &mut logs,
                    &format!("{d}-c0"),
                    now - 600_000,
                    "review",
                    3,
                    "review",
                    60_000,
                );
            }
        }
        let study = |d: &str| -> Value {
            let kid = format!("{d}-kid");
            let mut decks = serde_json::Map::new();
            decks.insert(d.to_owned(), json!([0.9, 3, 0, 0]));
            decks.insert(kid, json!([0.9, 3, 0, 0]));
            let req = json!({"now": now, "utcOff": 0, "rollover": 4, "deck": d, "pick": true,
                "rwkv": {"decks": decks, "cands": cands[d]}});
            let got = core.study(P, &req).unwrap();
            assert_eq!(
                got,
                core.read_visible(|c| oracle::study(c, P, &req)).unwrap(),
                "{req}"
            );
            got
        };
        let due = |got: &Value, d: &str| got["counts"][d][2].as_i64().unwrap();
        // 次数：3 − 2 = 1 张；卡片数：3 − 1 = 2 张；分钟：2 分钟 < 3 分钟 → 5 张全补。
        assert_eq!(due(&study("RWR"), "RWR"), 1);
        assert_eq!(due(&study("RWC"), "RWC"), 2);
        assert_eq!(due(&study("RWM"), "RWM"), 5);
        assert_eq!(due(&study("RWI"), "RWI"), 5);
        // 补上的按 R 升序：卡片数下是 c1、c2（子牌组与归属牌组共用一份配额）。
        let eligible: Vec<String> = study("RWC")["eligible"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e.as_str().unwrap().to_owned())
            .collect();
        assert_eq!(eligible, ["RWC-c1", "RWC-c2"]);
        // 分钟单位再复习 60 秒：用满 3 分钟 → 一张也不补；「忽略每日复习上限」的 RWI 同样不再补（最少已满足），
        // 但它的上限不截。
        for d in ["RWM", "RWI"] {
            log_ms(
                &core,
                &mut logs,
                &format!("{d}-c0"),
                now - 300_000,
                "review",
                3,
                "review",
                60_000,
            );
        }
        assert_eq!(due(&study("RWM"), "RWM"), 0);
        assert_eq!(due(&study("RWI"), "RWI"), 0);
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// RWKV 子牌组（自己管参数）挂在 FSRS 父牌组下：RWKV 的合格卡不是负荷信号，也不能经 `Tally::add` 累加进 FSRS
    /// 祖先的负荷、让父层暂停后再经 `new_remaining` 逐层截住子牌组的新卡；全是 FSRS 的同构子树照旧暂停。
    #[test]
    fn rwkv_child_load_not_counted_by_fsrs_ancestor() {
        let dir = std::env::temp_dir().join(format!(
            "ffsrs_study_rwkv_child_load_{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let now = 1_760_000_000_000i64;
        let today = day.index(now);
        let mut n = 0i64;
        // PAR / QAR：FSRS 父牌组，新卡上限 1 → 预算 = 10（没有复习历史），负荷超过 20 就暂停。
        // RC：PAR 下自己管参数的 RWKV 子牌组（开「忽略每日复习上限」）；QC：QAR 下自己管参数的 FSRS 子牌组（对照）。
        for d in ["PAR", "RC", "QAR", "QC"] {
            exec(
                &core,
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
                vec![Sql::Text(d.into()), Sql::Text(P.into())],
            );
            edit(&core, &mut n, d, "limits", json!({"new": 1, "review": 200}));
        }
        for d in ["PAR", "QAR", "QC"] {
            edit(
                &core,
                &mut n,
                d,
                "algorithm",
                json!({"alg": "fsrs7", "auto": false}),
            );
        }
        edit(&core, &mut n, "RC", "parent", json!("PAR"));
        edit(&core, &mut n, "QC", "parent", json!("QAR"));
        for d in ["RC", "QC"] {
            edit(&core, &mut n, d, "paramsMode", json!("own"));
        }
        edit(
            &core,
            &mut n,
            "RC",
            "rwkvQueue",
            json!({"minReviews": 0, "repeatReviews": 5, "repeatSeconds": 30, "refreshEvery": 1, "ignoreLimit": true}),
        );
        let mut k = 0i64;
        let mut cands: Vec<Value> = Vec::new();
        for d in ["RC", "QC"] {
            for _ in 0..40 {
                k += 1;
                let id = format!("{d}-{k:03}");
                exec(
                    &core,
                    CARD_UPSERT,
                    vec![
                        Sql::Text(id.clone()),
                        Sql::Text(P.into()),
                        Sql::Text(d.into()),
                        Sql::Integer(0),
                        Sql::Null,
                        Sql::Integer(0),
                        Sql::Text("review".into()),
                        Sql::Integer(today - 1),
                        Sql::Null,
                        Sql::Real(2.0),
                        Sql::Integer(now - 5 * DAY_MS),
                        Sql::Text("fushi".into()),
                        Sql::Integer(k),
                        Sql::Integer(k),
                        Sql::Null,
                    ],
                );
                if d == "RC" {
                    cands.push(json!([id, d, null, 0.5]));
                }
            }
        }
        let req = json!({"now": now, "utcOff": 0, "rollover": 4, "rwkv": {"decks": {"RC": [0.9, 0, 0, 0]}, "cands": cands}});
        let got = core.study(P, &req).unwrap();
        assert_eq!(
            got,
            core.read_visible(|c| oracle::study(c, P, &req)).unwrap()
        );
        // [新, 学习, 到期, 总数, 新卡上限, 新卡配额, 复习预算, 原因, 剩余复习分钟]
        assert_eq!(
            got["counts"]["RC"][2],
            json!(40),
            "RWKV 子牌组 40 张合格：{got}"
        );
        assert_eq!(got["counts"]["RC"][5], json!(1), "{got}");
        assert_eq!(got["counts"]["RC"][7], Value::Null, "{got}");
        // 修复前：PAR 的负荷 = RC 的 40 张 > 2 × 10 → paused、配额 0。
        assert_eq!(got["counts"]["PAR"][5], json!(1), "{got}");
        assert_eq!(got["counts"]["PAR"][7], Value::Null, "{got}");
        // 对照：FSRS 子树 40 张到期照旧累加进 FSRS 父牌组 → 暂停。
        assert_eq!(got["counts"]["QC"][7], json!("paused"), "{got}");
        assert_eq!(got["counts"]["QAR"][5], json!(0), "{got}");
        assert_eq!(got["counts"]["QAR"][7], json!("paused"), "{got}");
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 集成审查【中低】：写锁守卫释放（settle）晚于 COMMIT 可见。COMMIT 之后、守卫还持着时在读连接上排队：快照看得见
    /// 新行，触发器记下的 id 还在「未提交」里——以前读路径只重读已提交的，这一次排队按旧会话出卡（漏读一次）。
    #[test]
    fn a_snapshot_read_between_commit_and_settle_rereads_the_touched_rows() {
        let now = 1_760_000_000_000i64;
        let dir = std::env::temp_dir().join(format!("ffsrs_settle_window_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        exec(
            &core,
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES ('O', srs_id(?), 'deck', '{}')",
            vec![Sql::Text(P.into())],
        );
        for (id, stab) in [("weak", 0.5), ("strong", 90.0)] {
            exec(
                &core,
                "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, queue, due_day, stability, last_reviewed_at) VALUES (srs_id(?), srs_id(?), 'n', 't', 'O', 'review', 0, ?, ?)",
                vec![
                    Sql::Text(id.into()),
                    Sql::Text(P.into()),
                    Sql::Real(stab),
                    Sql::Integer(now - 10 * 86_400_000),
                ],
            );
        }
        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 0,
        };
        let lowest = |core: &SrsCore| -> Option<String> {
            // 直接在读连接的快照上排（不经 read_visible：写锁此刻被测试持着也照样走读连接）。
            let r = core.reader().unwrap();
            r.execute_batch("BEGIN").unwrap();
            let got = core
                .study_hub
                .with_session(&r, P, day, day.index(now), false, |s| {
                    Ok(s.lowest_due(&["O"], now, &HashSet::new()).map(|c| c.0))
                })
                .unwrap();
            r.execute_batch("ROLLBACK").unwrap();
            got
        };
        assert_eq!(lowest(&core).as_deref(), Some("weak"));
        {
            // 写连接上自动提交一条删除：COMMIT 已对读连接可见，守卫还没释放（没 settle）。
            let w = core.writer().unwrap();
            w.execute("DELETE FROM srs_cards_cache WHERE id = 'weak'", [])
                .unwrap();
            assert!(w.is_autocommit());
            assert_eq!(
                lowest(&core).as_deref(),
                Some("strong"),
                "the committed delete is visible and must be reread"
            );
            // 未提交的改动：读快照重读到的是旧值（与快照一致），也不清掉——提交后再按终态重读。
            w.execute_batch(
                "BEGIN; UPDATE srs_cards_cache SET stability = 0.1 WHERE id = 'strong';",
            )
            .unwrap();
            assert_eq!(lowest(&core).as_deref(), Some("strong"));
            w.execute_batch("INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, queue, due_day, stability, last_reviewed_at) \
                             VALUES ('weaker', 'p', 'n', 't', 'O', 'review', 0, 0.01, 0); COMMIT;").unwrap();
            assert_eq!(
                lowest(&core).as_deref(),
                Some("weaker"),
                "rows committed after an earlier reread are reread again"
            );
        }
        assert_eq!(lowest(&core).as_deref(), Some("weaker"));
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 自定义学习：提升今日上限只对今天生效；提前复习 / 复习忘记的卡 / 按状态与标签的临时会话按条件出卡、扣上限、
    /// 会话里答过的卡不再出（学习卡到期照样回来），排除的卡占名额。
    #[test]
    fn custom_study_sessions() {
        let dir = std::env::temp_dir().join(format!("ffsrs_custom_study_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        let mut n = 0i64;
        let mut logs = 0i64;
        for d in ["R", "RA"] {
            exec(
                &core,
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
                vec![Sql::Text(d.into()), Sql::Text(P.into())],
            );
        }
        edit(&core, &mut n, "RA", "parent", json!("R"));
        edit(&core, &mut n, "R", "limits", json!({"new": 1, "review": 1}));
        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let now = 1_760_000_000_000i64;
        let today = day.index(now);
        let card = |id: &str,
                    deck: &str,
                    queue: &str,
                    due_day: Option<i64>,
                    due_at: Option<i64>,
                    pos: i64| {
            let opt = |v: Option<i64>| v.map_or(Sql::Null, Sql::Integer);
            exec(
                &core,
                CARD_UPSERT,
                vec![
                    Sql::Text(id.into()),
                    Sql::Text(P.into()),
                    Sql::Text(deck.into()),
                    Sql::Integer(0),
                    Sql::Null,
                    Sql::Integer(0),
                    Sql::Text(queue.into()),
                    opt(due_day),
                    opt(due_at),
                    Sql::Real(5.0),
                    Sql::Integer(now - 3 * 86_400_000),
                    Sql::Text("fushi".into()),
                    Sql::Integer(pos),
                    Sql::Integer(pos),
                    Sql::Null,
                ],
            );
        };
        card("n1", "R", "new", None, None, 1);
        card("n2", "RA", "new", None, None, 2);
        card("n3", "R", "new", None, None, 3);
        card("r1", "R", "review", Some(today), None, 10);
        card("r2", "RA", "review", Some(today + 2), None, 11);
        card("r3", "R", "review", Some(today + 5), None, 12);
        card("f1", "RA", "review", Some(today + 9), None, 13);
        exec(
            &core,
            "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at, tags_json) VALUES (srs_id('n3'), srs_id(?1), 'T', 'g3', 1, '[\"Grammar::N1\"]'), (srs_id('n1'), srs_id(?1), 'T', 'g1', 1, '[\"grammarian\"]')",
            vec![Sql::Text(P.into())],
        );
        exec(
            &core,
            "INSERT INTO srs_stat_reviews (log_id, profile_uid, card_id, occurred_at, rating) VALUES (srs_id('s1'), srs_id(?1), srs_id('f1'), ?2, 1), (srs_id('s2'), srs_id(?1), srs_id('r3'), ?3, 1)",
            vec![
                Sql::Text(P.into()),
                Sql::Integer(now - 86_400_000),
                Sql::Integer(now - 10 * 86_400_000),
            ],
        );
        let base = json!({"now": now, "utcOff": 0, "rollover": 4, "deck": "R", "pick": true});
        let study = |extra: Value| -> Value {
            let mut req = base.clone();
            for (k, v) in extra.as_object().unwrap() {
                req[k] = v.clone();
            }
            core.study(P, &req).unwrap()
        };

        // 提升今日上限：今天的追加加在这一层；昨天写的不算。
        assert_eq!(study(json!({}))["counts"]["R"][0], json!(1));
        edit(
            &core,
            &mut n,
            "R",
            "extendLimits",
            json!({"day": today - 1, "new": 5, "review": 5}),
        );
        assert_eq!(study(json!({}))["counts"]["R"][0], json!(1));
        edit(
            &core,
            &mut n,
            "R",
            "extendLimits",
            json!({"day": today, "new": 2, "review": 0}),
        );
        assert_eq!(study(json!({}))["counts"]["R"][0], json!(3));

        let since = now - 60_000;
        let custom = |c: Value| study(json!({"custom": c}));
        // 提前复习 3 天：只有 r2（今天到期的 r1 不算「提前」，+5 天的 r3 超出）。
        let r = custom(json!({"since": since, "mode": "ahead", "days": 3}));
        assert_eq!(
            (r["next"].clone(), r["after"].clone(), r["custom"].clone()),
            (json!("r2"), Value::Null, json!({"left": 1, "learn": 0}))
        );
        // 复习忘记的卡：2 天内评过「重来」的只有 f1。
        let r = custom(json!({"since": since, "mode": "forgotten", "days": 2}));
        assert_eq!(
            (r["next"].clone(), r["after"].clone()),
            (json!("f1"), Value::Null)
        );
        // 按状态：新卡按新卡顺序；上限 2；排除的卡占名额。
        let r = custom(json!({"since": since, "mode": "filter", "states": ["new"], "limit": 2}));
        assert_eq!(
            (
                r["next"].clone(),
                r["after"].clone(),
                r["custom"]["left"].clone()
            ),
            (json!("n1"), json!("n2"), json!(2))
        );
        let r = study(
            json!({"custom": {"since": since, "mode": "filter", "states": ["new"], "limit": 2}, "exclude": ["n1"]}),
        );
        assert_eq!(
            (r["next"].clone(), r["after"].clone()),
            (json!("n2"), Value::Null)
        );
        // 按标签：不分大小写、匹配层级子标签，不匹配只是前缀相同的别的标签。
        let r = custom(json!({"since": since, "mode": "filter", "tags": ["grammar"]}));
        assert_eq!(
            (r["next"].clone(), r["after"].clone()),
            (json!("n3"), Value::Null)
        );
        // 状态 due：今天到期的复习卡。
        let r = custom(json!({"since": since, "mode": "filter", "states": ["due"]}));
        assert_eq!(
            (r["next"].clone(), r["after"].clone()),
            (json!("r1"), Value::Null)
        );

        // 会话里答过 r2 → 不再出、扣名额；答过 n1 后它进了学习队列且已到期 → 先出它。
        log(&core, &mut logs, "r2", now - 1_000, "review", 3, "review");
        let r = custom(json!({"since": since, "mode": "ahead", "days": 3}));
        assert_eq!(
            (r["next"].clone(), r["custom"].clone()),
            (Value::Null, json!({"left": 0, "learn": 0}))
        );
        log(&core, &mut logs, "n1", now - 1_000, "learn", 1, "review");
        card("n1", "R", "learning", None, Some(now - 10), 1);
        // 子树里会话开始后答过 r2、n1 两张：上限 3 还剩 1。
        let r = custom(json!({"since": since, "mode": "filter", "states": ["new"], "limit": 3}));
        assert_eq!(
            (r["next"].clone(), r["after"].clone(), r["custom"].clone()),
            (json!("n1"), json!("n2"), json!({"left": 1, "learn": 1}))
        );
        // 名额用完：只剩会话学习卡。
        let r = custom(json!({"since": since, "mode": "filter", "states": ["new"], "limit": 2}));
        assert_eq!(
            (r["next"].clone(), r["after"].clone()),
            (json!("n1"), Value::Null)
        );
        // 按出处（只复习这一作，会话从此刻开始）：笔记缓存行的出处键整值相等，可与状态叠加；别的作品、没有出处的笔记不出。
        exec(
            &core,
            "UPDATE srs_notes_cache SET source_key = 'book:b1' WHERE id = srs_id('n3')",
            vec![],
        );
        exec(
            &core,
            "INSERT INTO srs_notes_cache (id, profile_uid, note_type_id, guid, created_at, source_key) VALUES (srs_id('r3'), srs_id(?1), 'T', 'g4', 1, 'book:b1'), (srs_id('r2'), srs_id(?1), 'T', 'g5', 1, 'book:b2')",
            vec![Sql::Text(P.into())],
        );
        let r = custom(json!({"since": now, "mode": "filter", "source": "book:b1", "limit": 10}));
        assert_eq!(
            (
                r["next"].clone(),
                r["after"].clone(),
                r["custom"]["left"].clone()
            ),
            (json!("r3"), json!("n3"), json!(2))
        );
        let r = custom(
            json!({"since": now, "mode": "filter", "source": "book:b1", "states": ["review"]}),
        );
        assert_eq!(
            (r["next"].clone(), r["after"].clone()),
            (json!("r3"), Value::Null)
        );
        let r = custom(json!({"since": now, "mode": "filter", "source": "book:none"}));
        assert_eq!(r["next"], Value::Null);
        assert!(core.study(P, &json!({"now": now, "utcOff": 0, "rollover": 4, "deck": "R", "custom": {"since": 0, "mode": "filter", "source": ""}})).is_err());
        // 会话开始前的作答不算会话里答过。
        let r = custom(json!({"since": now, "mode": "ahead", "days": 3}));
        assert_eq!(r["next"], json!("r2"));
        assert!(core.study(P, &json!({"now": now, "utcOff": 0, "rollover": 4, "deck": "R", "custom": {"since": 0, "mode": "bogus"}})).is_err());
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 到期候选的块下界剪枝与逐张比相同：几千张卡里大量 R 相等（同稳定度 / 同上次作答）、上次作答在此刻之后（t < 0）、
    /// 分母为零（NULL 排最前）；逐张删掉当前最低再取，序列与按 SQL 式子全排序一致。
    #[test]
    fn due_index_pops_in_sql_order() {
        let mut rng = Rng(42);
        let now = 1_760_000_000_000i64;
        let dir = std::env::temp_dir().join(format!("ffsrs_due_index_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("srs.db");
        let _ = std::fs::remove_file(&path);
        let core = SrsCore::open(&path).unwrap();
        exec(
            &core,
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES ('O', srs_id(?), 'deck', '{}')",
            vec![Sql::Text(P.into())],
        );
        let mut want: Vec<(Option<f64>, String)> = Vec::new();
        for i in 0..3000 {
            let id = format!("d{:05}", rng.below(1_000_000));
            if want.iter().any(|(_, x)| *x == id) {
                continue;
            }
            let stab = match rng.below(20) {
                0 => None,
                1 => Some(0.0),
                2 => Some(-1.0),
                _ => Some([0.3, 1.0, 4.0, 4.0, 17.5, 90.0][rng.below(6) as usize]),
            };
            let last = match rng.below(15) {
                0 => None,
                1 => Some(now + 3 * 86_400_000),
                _ => Some(now - (rng.below(60) as i64) * 86_400_000 / 3),
            };
            exec(
                &core,
                "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, queue, due_day, stability, last_reviewed_at) VALUES (srs_id(?), srs_id(?), 'n', 't', 'O', 'review', 0, ?, ?)",
                vec![
                    Sql::Text(id.clone()),
                    Sql::Text(P.into()),
                    stab.map_or(Sql::Null, Sql::Real),
                    last.map_or(Sql::Null, Sql::Integer),
                ],
            );
            want.push((crate::store::queue::sql_r(now, last, stab), id));
            let _ = i;
        }
        // 按 SQL 的 ORDER BY 取全序（库里排，不信 Rust 的比较）。
        let order: Vec<String> = core
            .read_visible(|c| {
                let mut stmt = c
                    .prepare(
                        "SELECT srs_idt(id) FROM srs_cards_cache ORDER BY 1.0 / (1.0 + (CASE WHEN last_reviewed_at IS NULL THEN 0.0 ELSE (? - last_reviewed_at) / 86400000.0 END) \
                         / (9.0 * COALESCE(stability, 1.0))), id",
                    )
                    .map_err(sql)?;
                let v = stmt.query_map([now], |r| r.get::<_, String>(0)).map_err(sql)?.map(Result::unwrap).collect();
                Ok(v)
            })
            .unwrap();
        let mut ex: Vec<String> = Vec::new();
        for expected in order.iter().take(400) {
            let req = json!({"now": now, "utcOff": 0, "rollover": 0, "deck": "O", "pick": true, "exclude": ex});
            // 上限放到很大（复习上限 200 会挡住）：直接问会话。
            let got = core
                .read_visible(|c| {
                    core.study_hub.with_session(
                        c,
                        P,
                        Day {
                            utc_offset_min: 0,
                            rollover_hour: 0,
                        },
                        Day {
                            utc_offset_min: 0,
                            rollover_hour: 0,
                        }
                        .index(now),
                        false,
                        |s| {
                            let exs: HashSet<&str> = ex.iter().map(String::as_str).collect();
                            Ok(s.lowest_due(&["O"], now, &exs).map(|c| c.0))
                        },
                    )
                })
                .unwrap();
            assert_eq!(
                got.as_deref(),
                Some(expected.as_str()),
                "after excluding {} cards (req {req})",
                ex.len()
            );
            // 一半排除、一半真删（删走增量路径）。
            if ex.len() % 2 == 0 {
                ex.push(expected.clone());
            } else {
                exec(
                    &core,
                    "DELETE FROM srs_cards_cache WHERE id = srs_id(?)",
                    vec![Sql::Text(expected.clone())],
                );
            }
        }
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }
    // ------------------------------------------------------------ 出卡顺序（复习顺序 / 新卡与复习）

    /// 出卡顺序测试的小库：一个 profile、手写的牌组与卡。
    struct OrderLab {
        core: SrsCore,
        dir: std::path::PathBuf,
        n: i64,
        logs: i64,
        now: i64,
        day: Day,
    }

    impl OrderLab {
        fn new(tag: &str) -> OrderLab {
            // 同一个 tag 可能被并行的两个测试同时用（mix_run）：再加一个进程内序号。
            static SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
            let seq = SEQ.fetch_add(1, AtomicOrdering::SeqCst);
            let dir = std::env::temp_dir()
                .join(format!("ffsrs_order_{tag}_{}_{seq}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("srs.db");
            let _ = std::fs::remove_file(&path);
            OrderLab {
                core: SrsCore::open(&path).unwrap(),
                dir,
                n: 0,
                logs: 0,
                now: 1_760_000_000_000,
                day: Day {
                    utc_offset_min: 0,
                    rollover_hour: 4,
                },
            }
        }

        fn today(&self) -> i64 {
            self.day.index(self.now)
        }

        /// 一个牌组：[parent]、算法（"rwkv" / "fsrs6"）、是否自己一份参数（顶层恒为 own）。
        fn deck(&mut self, id: &str, parent: Option<&str>, alg: &str, own: bool) {
            exec(
                &self.core,
                "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (srs_id(?), srs_id(?), 'deck', '{}')",
                vec![Sql::Text(id.into()), Sql::Text(P.into())],
            );
            if let Some(p) = parent {
                self.set(id, "parent", json!(p));
            }
            if own {
                self.set(id, "paramsMode", json!("own"));
            }
            self.set(id, "algorithm", json!({"alg": alg}));
            self.set(id, "newPlan", json!({"auto": false}));
        }

        fn set(&mut self, deck: &str, key: &str, v: Value) {
            edit(&self.core, &mut self.n, deck, key, v);
        }

        /// 一张到期复习卡：到期日（相对今天）、间隔、难度、上次作答在几天前、稳定度。
        #[allow(clippy::too_many_arguments)]
        fn review(
            &self,
            id: &str,
            deck: &str,
            due: i64,
            ivl: i64,
            d: Option<f64>,
            ago_days: i64,
            stab: f64,
        ) {
            exec(
                &self.core,
                CARD_UPSERT_ORDERED,
                vec![
                    Sql::Text(id.into()),
                    Sql::Text(P.into()),
                    Sql::Text(deck.into()),
                    Sql::Integer(0),
                    Sql::Null,
                    Sql::Integer(0),
                    Sql::Text("review".into()),
                    Sql::Integer(self.today() + due),
                    Sql::Null,
                    Sql::Real(stab),
                    Sql::Integer(self.now - ago_days * 86_400_000),
                    Sql::Text("fushi".into()),
                    Sql::Integer(0),
                    Sql::Integer(0),
                    Sql::Null,
                    Sql::Integer(ivl),
                    d.map_or(Sql::Null, Sql::Real),
                ],
            );
        }

        fn new_card(&self, id: &str, deck: &str, pos: i64) {
            exec(
                &self.core,
                CARD_UPSERT_ORDERED,
                vec![
                    Sql::Text(id.into()),
                    Sql::Text(P.into()),
                    Sql::Text(deck.into()),
                    Sql::Integer(0),
                    Sql::Null,
                    Sql::Integer(0),
                    Sql::Text("new".into()),
                    Sql::Null,
                    Sql::Null,
                    Sql::Null,
                    Sql::Null,
                    Sql::Text("fushi".into()),
                    Sql::Integer(pos),
                    Sql::Integer(pos),
                    Sql::Integer(pos),
                    Sql::Integer(0),
                    Sql::Null,
                ],
            );
        }

        /// 排一次（出卡）；同时与 L2 基准对拍。
        fn pick(&self, deck: &str, exclude: &[String], rwkv: Option<&Value>) -> Value {
            let mut req = json!({"now": self.now, "utcOff": 0, "rollover": 4, "deck": deck, "pick": true, "exclude": exclude});
            if let Some(r) = rwkv {
                req["rwkv"] = r.clone();
            }
            let got = self.core.study(P, &req).unwrap();
            let want = self
                .core
                .read_visible(|c| oracle::study(c, P, &req))
                .unwrap();
            assert_eq!(got, want, "session vs SQL baseline, req {req}");
            got
        }

        /// 不作答、逐张排除得到的出卡序列。
        fn sequence(&self, deck: &str, rwkv: Option<&Value>) -> Vec<String> {
            let mut ex: Vec<String> = Vec::new();
            while let Some(id) = self.pick(deck, &ex, rwkv)["next"].as_str() {
                ex.push(id.to_owned());
                assert!(ex.len() < 100, "runaway sequence");
            }
            ex
        }

        /// 作答一张：写今天的日志（新卡 = 第一次学，否则复习），卡挪到五天后到期。
        fn answer(&mut self, id: &str) {
            let new = id.starts_with('n');
            log(
                &self.core,
                &mut self.logs,
                id,
                self.now,
                if new { "learn" } else { "review" },
                if new { 1 } else { 2 },
                "review",
            );
            exec(
                &self.core,
                "UPDATE srs_cards_cache SET queue = 'review', due_day = ? WHERE id = srs_id(?)",
                vec![Sql::Integer(self.today() + 5), Sql::Text(id.into())],
            );
        }

        fn close(self) {
            self.core.close();
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// 复习顺序表里的一张卡：(id, 到期日相对今天, 间隔, 难度, 几天前作答, 稳定度)。
    type OrderCard = (&'static str, i64, i64, Option<f64>, i64, f64);

    const ORDER_CARDS: [OrderCard; 7] = [
        ("a", -3, 10, Some(5.0), 10, 2.0),
        ("b", -1, 3, Some(9.0), 1, 10.0),
        ("c", -1, 3, None, 4, 1.0),
        ("d", 0, 7, Some(2.0), 30, 5.0),
        ("e", -1, 3, Some(9.0), 2, 3.0),
        ("f", 0, 1, Some(7.5), 6, 0.5),
        ("g", -3, 7, None, 3, 8.0),
    ];

    /// 按（主键, 当天哈希, id）排好的卡 id。
    fn by_key(today: i64, prim: impl Fn(&OrderCard) -> (i64, i64)) -> Vec<String> {
        let mut v: Vec<&OrderCard> = ORDER_CARDS.iter().collect();
        v.sort_by_key(|c| (prim(c), crate::store::queue::day_hash(c.0, today), c.0));
        v.iter().map(|c| c.0.to_owned()).collect()
    }

    /// 缺省顺序：此刻 R 升序、同 R 按 id。
    fn by_r(now: i64) -> Vec<String> {
        let mut v: Vec<(f64, &str)> = ORDER_CARDS
            .iter()
            .map(|c| {
                let r = crate::store::queue::sql_r(now, Some(now - c.4 * 86_400_000), Some(c.5));
                (r.unwrap(), c.0)
            })
            .collect();
        v.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(b.1)));
        v.iter().map(|c| c.1.to_owned()).collect()
    }

    /// 五种复习顺序各自的出卡序列逐张对：同到期日（a/g、b/c/e、d/f）、同间隔（b/c/e、d/g）、同难度（b/e）按当天
    /// 哈希断平，难度为空的（c、g）排最后；没写 / 不认识的值 = 缺省（R 升序），与加这项设置之前逐张相同。
    #[test]
    fn review_order_picks_follow_each_option() {
        let mut lab = OrderLab::new("each");
        lab.deck("F", None, "fsrs6", true);
        lab.set("F", "limits", json!({"new": 0, "review": 1000}));
        for c in ORDER_CARDS {
            lab.review(c.0, "F", c.1, c.2, c.3, c.4, c.5);
        }
        let today = lab.today();
        let by_d = |c: &OrderCard| match c.3 {
            Some(d) => (0, -(d * 100.0) as i64),
            None => (1, 0),
        };
        let r_order = by_r(lab.now);
        assert_eq!(lab.sequence("F", None), r_order, "unset = retrievability");
        for (wire, want) in [
            ("retrievability", r_order.clone()),
            ("bogus", r_order.clone()),
            ("dueDate", by_key(today, |c| (c.1, 0))),
            ("difficulty", by_key(today, by_d)),
            ("intervalAscending", by_key(today, |c| (c.2, 0))),
            ("random", by_key(today, |_| (0, 0))),
        ] {
            lab.set("F", "reviewOrder", json!(wire));
            assert_eq!(lab.sequence("F", None), want, "reviewOrder {wire}");
        }
        // 手写的主键：难度从高到低、空难度最后。
        let d = by_key(today, by_d);
        assert_eq!(
            &d[..2].iter().map(String::as_str).collect::<HashSet<_>>(),
            &HashSet::from(["b", "e"])
        );
        assert_eq!(&d[2..5], &["f", "a", "d"]);
        assert_eq!(
            &d[5..].iter().map(String::as_str).collect::<HashSet<_>>(),
            &HashSet::from(["c", "g"])
        );
        lab.close();
    }

    /// 随机顺序：同一天里不变（此刻前进也不变），第二天换一组（当天哈希里的日序号变了）。
    #[test]
    fn random_review_order_is_stable_within_a_day_and_changes_next_day() {
        let mut lab = OrderLab::new("random");
        lab.deck("F", None, "fsrs6", true);
        lab.set("F", "limits", json!({"new": 0, "review": 1000}));
        for c in ORDER_CARDS {
            lab.review(c.0, "F", c.1, c.2, c.3, c.4, c.5);
        }
        lab.set("F", "reviewOrder", json!("random"));
        let today = lab.today();
        let first = lab.sequence("F", None);
        assert_eq!(first, by_key(today, |_| (0, 0)));
        lab.now += 3 * H;
        assert_eq!(lab.today(), today);
        assert_eq!(lab.sequence("F", None), first, "same day, same order");
        lab.now += 24 * H;
        assert_eq!(lab.today(), today + 1);
        let next_day = lab.sequence("F", None);
        assert_eq!(next_day, by_key(today + 1, |_| (0, 0)));
        assert_ne!(next_day, first, "a new day reshuffles");
        lab.close();
    }

    /// 参数归属祖先按 RWKV 排程：从它出卡时整棵子树（含自己一份参数的 FSRS 子牌组）都按 R，寄存器里的复习顺序
    /// 照存不认；直接点那个 FSRS 子牌组时按它自己的复习顺序。
    #[test]
    fn rwkv_owner_forces_retrievability_for_whole_subtree() {
        let mut lab = OrderLab::new("rwkv_root");
        lab.deck("W", None, "rwkv", true);
        lab.deck("WF", Some("W"), "fsrs6", true);
        for d in ["W", "WF"] {
            lab.set(d, "limits", json!({"new": 0, "review": 1000}));
            lab.set(d, "reviewOrder", json!("difficulty"));
        }
        for c in ORDER_CARDS {
            lab.review(c.0, "WF", c.1, c.2, c.3, c.4, c.5);
        }
        let today = lab.today();
        assert_eq!(lab.sequence("W", None), by_r(lab.now));
        let by_d = by_key(today, |c| match c.3 {
            Some(d) => (0, -(d * 100.0) as i64),
            None => (1, 0),
        });
        assert_eq!(lab.sequence("WF", None), by_d);
        lab.close();
    }

    /// FSRS 根（按难度）下混着 RWKV 子牌组：FSRS 一路按难度取队首、RWKV 一路按 R 取队首，两个队首比此刻 R。
    #[test]
    fn fsrs_root_mixed_with_rwkv_subdeck_merges_by_r() {
        let mut lab = OrderLab::new("mixed_rwkv");
        lab.deck("F", None, "fsrs6", true);
        lab.deck("FR", Some("F"), "rwkv", true);
        lab.set("F", "reviewOrder", json!("difficulty"));
        // R = 1 / (1 + t / 9S)：a 0.5（难度 9）、b 0.2（难度 5）。
        lab.review("a", "F", -1, 3, Some(9.0), 9, 1.0);
        lab.review("b", "F", -1, 3, Some(5.0), 36, 1.0);
        lab.review("x", "FR", -1, 3, Some(1.0), 1, 1.0);
        lab.review("y", "FR", -1, 3, Some(1.0), 1, 1.0);
        let rwkv = json!({"decks": {"FR": [0.9, 0, 0, 0]}, "cands": [["x", "FR", null, 0.3], ["y", "FR", null, 0.6]]});
        assert_eq!(lab.sequence("F", Some(&rwkv)), ["x", "a", "b", "y"]);
        lab.close();
    }

    /// 新卡与复习：N = 2、R = 6，逐张真作答（今天已学 / 已复习随之变）。每一步的「再下一张」都等于真作答之后的
    /// 下一张（虚拟扣掉了下一张那一类）。
    fn mix_run(mix: &str, new_limit: i64) -> Vec<char> {
        let mut lab = OrderLab::new(&format!("mix_{mix}_{new_limit}"));
        lab.deck("F", None, "fsrs6", true);
        lab.set("F", "limits", json!({"new": new_limit, "review": 6}));
        lab.set("F", "newMix", json!(mix));
        lab.new_card("n1", "F", 1);
        lab.new_card("n2", "F", 2);
        for i in 1..=6 {
            lab.review(&format!("r{i}"), "F", -1, i, Some(5.0), i, 1.0);
        }
        let mut seq = Vec::new();
        let mut predicted: Option<Value> = None;
        loop {
            let got = lab.pick("F", &[], None);
            if let Some(p) = predicted.take() {
                assert_eq!(
                    got["next"],
                    p,
                    "{mix}: after == next once answered (step {})",
                    seq.len()
                );
            }
            let Some(id) = got["next"].as_str().map(str::to_owned) else {
                break;
            };
            predicted = Some(got["after"].clone());
            seq.push(if id.starts_with('n') { 'N' } else { 'R' });
            lab.answer(&id);
            assert!(seq.len() < 20);
        }
        lab.close();
        seq
    }

    #[test]
    fn new_mix_sequences() {
        let s = |v: Vec<char>| v.into_iter().collect::<String>();
        assert_eq!(s(mix_run("mixed", 2)), "RRRNRRRN");
        assert_eq!(s(mix_run("beforeReviews", 2)), "NNRRRRRR");
        assert_eq!(s(mix_run("afterReviews", 2)), "RRRRRRNN");
        assert_eq!(s(mix_run("bogus", 2)), "RRRRRRNN");
        // 新卡上限 0：混排退成纯复习。
        assert_eq!(s(mix_run("mixed", 0)), "RRRRRR");

        // 选中的那一类没有可出的卡时退到另一类：混排第一张该出复习，复习全被排除 → 出新卡；新卡全被排除 → 出复习。
        let mut lab = OrderLab::new("mix_fallback");
        lab.deck("F", None, "fsrs6", true);
        lab.set("F", "limits", json!({"new": 2, "review": 6}));
        lab.set("F", "newMix", json!("mixed"));
        lab.new_card("n1", "F", 1);
        lab.new_card("n2", "F", 2);
        for i in 1..=6 {
            lab.review(&format!("r{i}"), "F", -1, i, Some(5.0), i, 1.0);
        }
        let reviews: Vec<String> = (1..=6).map(|i| format!("r{i}")).collect();
        assert_eq!(lab.pick("F", &reviews, None)["next"], json!("n1"));
        lab.set("F", "newMix", json!("beforeReviews"));
        let news = vec!["n1".to_owned(), "n2".to_owned()];
        assert!(
            lab.pick("F", &news, None)["next"]
                .as_str()
                .unwrap()
                .starts_with('r')
        );
        lab.close();
    }

    /// 「再下一张」虚拟扣掉「下一张」：新卡先出、新卡上限只剩 1 时，下一张是新卡，再下一张不能再是新卡。
    #[test]
    fn after_respects_virtual_counts() {
        let mut lab = OrderLab::new("after_virtual");
        lab.deck("F", None, "fsrs6", true);
        lab.set("F", "limits", json!({"new": 1, "review": 6}));
        lab.set("F", "newMix", json!("beforeReviews"));
        lab.new_card("n1", "F", 1);
        lab.new_card("n2", "F", 2);
        lab.review("r1", "F", -1, 1, Some(5.0), 3, 1.0);
        let got = lab.pick("F", &[], None);
        assert_eq!(got["next"], json!("n1"));
        assert_eq!(got["after"], json!("r1"));
        lab.close();
        // 混排下每一步的再下一张 = 真作答后的下一张（mix_run 里逐步断言）。
        assert_eq!(mix_run("mixed", 2).len(), 8);
    }

    /// 应用内反馈 ys9tMVHj3S：RWKV 的同日间隔守卫只按牌组树分组（共用一套设置的牌组）数「之后别的卡的作答」，
    /// 不随这次排队的范围变——以前数请求子树里的作答，牌组列表（全部牌组）把别的牌组的作答算进去判合格、显示到期，
    /// 点进那个牌组排队却只数子树、判暂缓，复习页一张都不出，退出后列表上的到期数还在。
    #[test]
    fn rwkv_repeat_guard_counts_the_settings_group_not_the_request_scope() {
        let mut lab = OrderLab::new("rwkv_repeat_scope");
        // RW 自己管参数，RWA / RWB 随它继承（同一组设置）；OT 是另一组设置的 RWKV 牌组。
        lab.deck("RW", None, "rwkv", true);
        lab.deck("RWA", Some("RW"), "rwkv", false);
        lab.deck("RWB", Some("RW"), "rwkv", false);
        lab.deck("OT", None, "rwkv", true);
        lab.review("r1", "RWA", -1, 1, Some(5.0), 3, 1.0);
        for i in 1..=5 {
            lab.review(&format!("b{i}"), "RWB", -1, 1, Some(5.0), 3, 1.0);
            lab.review(&format!("o{i}"), "OT", -1, 1, Some(5.0), 3, 1.0);
        }
        let answered_at = lab.now;
        lab.answer("r1");
        // 之后在另一组设置的牌组里答了 5 张：不算 r1 的间隔。
        lab.now += 60_000;
        for i in 1..=5 {
            lab.answer(&format!("o{i}"));
        }
        lab.now += 60_000;
        let q = json!([0.9, 0, 5, 30]);
        let rwkv = json!({
            "decks": {"RW": q, "RWA": q, "RWB": q, "OT": q},
            "cands": [["r1", "RWA", answered_at, 0.3]],
        });
        let list = |lab: &OrderLab| -> Value {
            let req = json!({"now": lab.now, "utcOff": 0, "rollover": 4, "rwkv": rwkv});
            let got = lab.core.study(P, &req).unwrap();
            let want = lab
                .core
                .read_visible(|c| oracle::study(c, P, &req))
                .unwrap();
            assert_eq!(got, want, "session vs SQL baseline, req {req}");
            got
        };
        // [新, 学习, 到期, ...]
        let listed = list(&lab);
        let picked = lab.pick("RWA", &[], Some(&rwkv));
        assert_eq!(listed["counts"]["RWA"][2], json!(0), "{listed}");
        assert_eq!(picked["counts"]["RWA"][2], json!(0), "{picked}");
        assert_eq!(picked["next"], Value::Null, "{picked}");
        // 同一组设置里（RWA 子树之外的兄弟牌组）又答了 5 张：r1 已隔开，列表与复习页都出它。
        for i in 1..=5 {
            lab.answer(&format!("b{i}"));
        }
        lab.now += 60_000;
        let listed = list(&lab);
        let picked = lab.pick("RWA", &[], Some(&rwkv));
        assert_eq!(listed["counts"]["RWA"][2], json!(1), "{listed}");
        assert_eq!(listed["counts"]["RW"][2], json!(1), "{listed}");
        assert_eq!(picked["counts"]["RWA"][2], json!(1), "{picked}");
        assert_eq!(picked["next"], json!("r1"), "{picked}");
        lab.close();
    }

    /// 应用内反馈 LAk5vHGWUe：RWKV 间隔守卫只差时间那一半时，排空的结果要带上「多久之后又排得出」（`wakeIn`），
    /// 复习页据此定时重排、亮出「继续」；到点同一次排队就出这张。只差作答次数的（等多久都不会自己解除）不报。
    #[test]
    fn study_reports_when_a_time_held_rwkv_card_comes_back() {
        let mut lab = OrderLab::new("rwkv_wake");
        lab.deck("RW", None, "rwkv", true);
        lab.review("r1", "RW", -1, 1, Some(5.0), 3, 1.0);
        for i in 1..=5 {
            lab.review(&format!("b{i}"), "RW", -1, 1, Some(5.0), 3, 1.0);
        }
        let t0 = lab.now;
        lab.answer("r1");
        lab.now += 1_000;
        for i in 1..=4 {
            lab.answer(&format!("b{i}"));
        }
        let rwkv = json!({
            "decks": {"RW": [0.9, 0, 5, 30]},
            "cands": [["r1", "RW", t0, 0.3]],
        });
        // 之后别的卡只答了 4 张：作答次数那一半不够，到点也不会自己合格。
        lab.now = t0 + 10_000;
        let got = lab.pick("RW", &[], Some(&rwkv));
        assert_eq!(got["next"], Value::Null, "{got}");
        assert_eq!(got["wakeIn"], Value::Null, "{got}");
        // 第 5 张答完：只差时间，30 秒守卫在 t0 + 30 s 解除。
        lab.answer("b5");
        lab.now = t0 + 12_000;
        let got = lab.pick("RW", &[], Some(&rwkv));
        assert_eq!(got["next"], Value::Null, "{got}");
        assert_eq!(got["wakeIn"], json!(18_000), "{got}");
        // 被排除的卡不算。
        let got = lab.pick("RW", &["r1".to_owned()], Some(&rwkv));
        assert_eq!(got["wakeIn"], Value::Null, "{got}");
        // R 高于目标、也没有「每天最少」可补：到点也不出，不报。
        let above = json!({"decks": {"RW": [0.9, 0, 5, 30]}, "cands": [["r1", "RW", t0, 0.95]]});
        assert_eq!(lab.pick("RW", &[], Some(&above))["wakeIn"], Value::Null);
        // 到点：同一次排队就出它。
        lab.now = t0 + 30_000;
        let got = lab.pick("RW", &[], Some(&rwkv));
        assert_eq!(got["next"], json!("r1"), "{got}");
        assert_eq!(got["wakeIn"], Value::Null, "{got}");
        lab.close();
    }

    /// 同上，FSRS 学习卡：排空时最早那张学习卡进入 20 分钟提前窗口的时刻；窗口内的照常直接出。
    #[test]
    fn study_reports_when_a_learning_card_enters_the_learn_ahead_window() {
        let mut lab = OrderLab::new("learning_wake");
        lab.deck("F", None, "fsrs6", true);
        lab.review("l1", "F", 0, 1, Some(5.0), 0, 1.0);
        lab.review("l2", "F", 0, 1, Some(5.0), 0, 1.0);
        let learn = |lab: &OrderLab, id: &str, due_at: i64| {
            exec(
                &lab.core,
                "UPDATE srs_cards_cache SET queue = 'learning', due_day = NULL, due_at = ? WHERE id = srs_id(?)",
                vec![Sql::Integer(due_at), Sql::Text(id.into())],
            );
        };
        learn(&lab, "l1", lab.now + 50 * 60_000);
        learn(&lab, "l2", lab.now + 40 * 60_000);
        let got = lab.pick("F", &[], None);
        assert_eq!(got["next"], Value::Null, "{got}");
        assert_eq!(got["wakeIn"], json!(20 * 60_000), "{got}");
        lab.now += 20 * 60_000;
        let got = lab.pick("F", &[], None);
        assert_eq!(got["next"], json!("l2"), "{got}");
        assert_eq!(got["wakeIn"], Value::Null, "{got}");
        lab.close();
    }
}
