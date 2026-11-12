//! 复习统计（统计中心「复习」分区、复习首页、桌面小组件、操作目录 `srs/stats`）：数据与聚合都在这里，Dart 只发一条
//! 粗粒度命令、拿回聚合好的数（对齐 Anki 2.1.50+ 统计页）。
//!
//! - 原料只读 SRS 自己的表：可见卡的卡片缓存（+ 笔记缓存的创建时刻与出处）与有效复习投影 `srs_stat_reviews`（被 undo
//!   撤销的、被判与原生日志等价的导入 Anki 日志都已不在投影里；分类、提前复习所需的上一到期日、成熟变化在投影刷新时
//!   定死，见 caches.rs `refresh_stats`）。原料整份读一次留在内存（[Snapshot]），换范围 / 牌组只重算聚合。
//! - 「今天」与日序号一律走请求带来的日界（[Day]：翻日时刻随 profile、时区用本机偏移，与复习页同一口径）；
//!   「按小时」用日志自己记下的 UTC 偏移（旅行不改历史复习落在几点）。
//! - 可提取度：按卡所在牌组的 FSRS 模型（请求带来的 `[算法, 参数]`，同 `ffsrs_retrievability_batch`）× 距上次复习的
//!   小数天；RWKV-Instant 排队的复习卡用 Dart 交来的 RWKV 此刻回忆率（[Ctx::recall]）。
//!
//! 与删除前的 Dart 实现（packages/fushi_engine/lib/srs/srs_stats.dart `SrsStatsData`，2026-11-10）逐值对应：浮点和
//! 按同样的顺序累加（卡片 = 读出的行序；直方图 = 排序后的值），字符串比较按 UTF-16 码元（Dart `compareTo`），去空白
//! 按 Dart `trim`。对拍向量：packages/fushi_engine/test/srs/fixtures/srs_stats_report_vectors.json.gz。

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use rusqlite::Connection;
use rusqlite::types::ValueRef;
use serde_json::{Map, Value, json};

use crate::projection::{DAY_MS, Day};
use crate::store::SrsCore;
use crate::store::sync2::sql;

const HOUR_MS: i64 = 3_600_000;

/// 成熟卡的间隔门槛（天，与 Anki 一致）。
pub const MATURE_DAYS: i64 = 21;

/// RWKV「接近目标线」的余量（`SrsRwkvNow.nearMargin`）。
const NEAR_MARGIN: f64 = 0.05;

/// 复习分类（`srs_stat_reviews.kind`，Dart `SrsStatReviewKind` 的下标）。
pub const KINDS: usize = 6;
const K_NEW: u8 = 0;
const K_LEARN: u8 = 1;
const K_YOUNG: u8 = 2;
const K_MATURE: u8 = 3;
const K_RELEARN: u8 = 4;

/// 卡片当前状态（卡片计数饼图的分类之一；暂停 / 搁置另算）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    New,
    Learning,
    Relearning,
    Young,
    Mature,
}

impl State {
    fn of(queue: &str, days: i64) -> State {
        match queue {
            "learning" => State::Learning,
            "relearning" => State::Relearning,
            "review" if days >= MATURE_DAYS => State::Mature,
            "review" => State::Young,
            // `SrsQueue.parse`：认不出的按新卡。
            _ => State::New,
        }
    }

    fn is_review(self) -> bool {
        matches!(self, State::Young | State::Mature)
    }

    fn name(self) -> &'static str {
        match self {
            State::New => "newCard",
            State::Learning => "learning",
            State::Relearning => "relearning",
            State::Young => "young",
            State::Mature => "mature",
        }
    }
}

/// 一张可见卡的原料（卡片缓存行）。
#[derive(Debug, Clone)]
struct Card {
    id: String,
    note: String,
    deck: String,
    queue: String,
    days: i64,
    suspended: bool,
    buried_until: Option<i64>,
    fushi: bool,
    due_day: Option<i64>,
    due_at: Option<i64>,
    stab: Option<f64>,
    diff: Option<f64>,
    last: Option<i64>,
    lapses: i64,
    reps: i64,
    added_at: i64,
    last_log: Option<String>,
    /// 出处在 [Snapshot::sources] 里的下标；没有笔记缓存行 = None。
    src: Option<usize>,
}

/// 有效复习投影的一行。
#[derive(Debug, Clone, Copy)]
struct Rev {
    /// 归属卡：< 可见卡数 = [Snapshot::cards] 的下标，其余是不可见的归属卡（[Snapshot::extra]）。
    card: usize,
    at: i64,
    off: i64,
    /// 1..4；None = 只是成熟变化。
    rating: Option<u8>,
    kind: u8,
    dur: i64,
    prev_due: Option<i64>,
    maturity: i64,
}

/// 一份原料（某 profile、某一版数据）。
pub(crate) struct Snapshot {
    profile: String,
    key: String,
    gen: u64,
    cards: Vec<Card>,
    extra: Vec<String>,
    /// 按时刻升序。
    reviews: Vec<Rev>,
    /// 出处字典：(种类, 笔记缓存行的 `source_title`——带系列的出处是系列名、其余是原样标题，caches.rs
    /// `NoteInfo::of`)；种类空串 = 没有出处。
    sources: Vec<(String, String)>,
}

fn opt_text(v: ValueRef<'_>) -> Option<String> {
    match v {
        ValueRef::Text(_) | ValueRef::Blob(_) => super::ids::text(v),
        ValueRef::Integer(x) => Some(x.to_string()),
        _ => None,
    }
}

fn opt_int(v: ValueRef<'_>) -> Option<i64> {
    match v {
        ValueRef::Integer(x) => Some(x),
        ValueRef::Real(x) => Some(x as i64),
        _ => None,
    }
}

fn opt_real(v: ValueRef<'_>) -> Option<f64> {
    match v {
        ValueRef::Integer(x) => Some(x as f64),
        ValueRef::Real(x) => Some(x),
        _ => None,
    }
}

impl Snapshot {
    /// 在一个只读快照里读原料：可见卡（`hidden = 0`，`added_at` = 笔记缓存的创建时刻，没有笔记缓存行时用卡片行上
    /// 记的）、出处字典、有效复习投影（按时刻升序）。
    pub(crate) fn load(c: &Connection, profile: &str) -> Result<Snapshot, String> {
        let mut stmt = c
            .prepare_cached(
                "SELECT c.id, c.note_id, c.deck_id, c.queue, c.scheduled_days, c.suspended, c.buried_until_day, \
                 c.scheduler, c.due_day, c.due_at, c.stability, c.difficulty, c.last_reviewed_at, c.lapses, c.reps, \
                 COALESCE(n.created_at, c.note_created_at), c.last_log_id, n.source_kind, n.source_title \
                 FROM srs_cards_cache c LEFT JOIN srs_notes_cache n ON n.id = c.note_id \
                 WHERE c.profile_uid = srs_id(?1) AND c.hidden = 0",
            )
            .map_err(sql)?;
        let mut it = stmt.query([profile]).map_err(sql)?;
        let mut cards = Vec::new();
        let mut dict: HashMap<(String, String), usize> = HashMap::new();
        let mut sources: Vec<(String, String)> = Vec::new();
        let mut index: HashMap<String, usize> = HashMap::new();
        while let Some(r) = it.next().map_err(sql)? {
            let g = |i: usize| r.get_ref(i).map_err(sql);
            let text =
                |i: usize| -> Result<String, String> { Ok(opt_text(g(i)?).unwrap_or_default()) };
            let int = |i: usize| -> Result<i64, String> { Ok(opt_int(g(i)?).unwrap_or(0)) };
            let src = match opt_text(g(17)?) {
                None => None,
                Some(k) => {
                    let t = opt_text(g(18)?).unwrap_or_default();
                    let next = sources.len();
                    Some(*dict.entry((k.clone(), t.clone())).or_insert_with(|| {
                        sources.push((k, t));
                        next
                    }))
                }
            };
            let card = Card {
                id: text(0)?,
                note: text(1)?,
                deck: text(2)?,
                queue: text(3)?,
                days: int(4)?,
                suspended: int(5)? != 0,
                buried_until: opt_int(g(6)?),
                fushi: text(7)? == "fushi",
                due_day: opt_int(g(8)?),
                due_at: opt_int(g(9)?),
                stab: opt_real(g(10)?),
                diff: opt_real(g(11)?),
                last: opt_int(g(12)?),
                lapses: int(13)?,
                reps: int(14)?,
                added_at: int(15)?,
                last_log: opt_text(g(16)?),
                src,
            };
            index.insert(card.id.clone(), cards.len());
            cards.push(card);
        }
        drop(it);
        let mut stmt = c
            .prepare_cached(
                "SELECT card_id, occurred_at, utc_offset_min, rating, kind, duration_ms, prev_due_day, maturity_delta \
                 FROM srs_stat_reviews WHERE profile_uid = srs_id(?1) ORDER BY occurred_at",
            )
            .map_err(sql)?;
        let mut it = stmt.query([profile]).map_err(sql)?;
        let mut reviews = Vec::new();
        let mut extra: Vec<String> = Vec::new();
        while let Some(r) = it.next().map_err(sql)? {
            let id = super::ids::col(r, 0).map_err(sql)?;
            let next = cards.len() + extra.len();
            let card = *index.entry(id).or_insert_with_key(|id| {
                extra.push(id.clone());
                next
            });
            reviews.push(Rev {
                card,
                at: r.get(1).map_err(sql)?,
                off: r.get(2).map_err(sql)?,
                rating: r
                    .get::<_, Option<i64>>(3)
                    .map_err(sql)?
                    .map(|x| x.clamp(0, 255) as u8),
                kind: r.get::<_, i64>(4).map_err(sql)?.clamp(0, KINDS as i64 - 1) as u8,
                dur: r.get(5).map_err(sql)?,
                prev_due: r.get(6).map_err(sql)?,
                maturity: r.get(7).map_err(sql)?,
            });
        }
        Ok(Snapshot {
            profile: profile.to_owned(),
            key: String::new(),
            gen: 0,
            cards,
            extra,
            reviews,
            sources,
        })
    }

    #[cfg(test)]
    pub(crate) fn sizes(&self) -> (usize, usize) {
        (self.cards.len(), self.reviews.len())
    }
}

/// [SrsCore] 上的统计缓存：最近一份原料 + 写连接上「改过统计原料」的代数。
#[derive(Default)]
pub(crate) struct StatsCache {
    snapshot: Mutex<Option<Arc<Snapshot>>>,
    /// 写连接上的触发器（queue.rs `srs_study_touch`：卡片缓存 / 日志 / 笔记缓存 / 笔记修改记录）每记一次 +1，事务
    /// 结束（[StatsCache::settle]）时若期间记过再 +1：读原料前取代数，取到的与缓存上的不同就重读。
    gen: AtomicU64,
    touched: AtomicBool,
}

impl StatsCache {
    pub(crate) fn touch(&self) {
        self.touched.store(true, Ordering::SeqCst);
        self.gen.fetch_add(1, Ordering::SeqCst);
    }

    pub(crate) fn settle(&self) {
        if self.touched.swap(false, Ordering::SeqCst) {
            self.gen.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[cfg(test)]
    pub(crate) fn generation(&self) -> u64 {
        self.gen.load(Ordering::SeqCst)
    }
}

impl SrsCore {
    fn stats_cache(&self) -> &StatsCache {
        &self.study_hub.stats
    }

    /// [profile] 的原料：缓存上的那份与 [key]（Dart `SrsDbStore.statsFingerprint`）和写入代数都相同就直接用，否则在
    /// 一个只读快照里重读。代数在开快照之前取：读的途中有写入，下次一定重读。
    pub(crate) fn stats_snapshot(&self, profile: &str, key: &str) -> Result<Arc<Snapshot>, String> {
        let cache = self.stats_cache();
        let gen = cache.gen.load(Ordering::SeqCst);
        {
            let s = cache.snapshot.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(s) = s
                .as_ref()
                .filter(|s| s.profile == profile && s.key == key && s.gen == gen)
            {
                return Ok(Arc::clone(s));
            }
        }
        let mut snap = self.read_visible(|c| Snapshot::load(c, profile))?;
        snap.key = key.to_owned();
        snap.gen = gen;
        let snap = Arc::new(snap);
        *cache.snapshot.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&snap));
        Ok(snap)
    }

    /// 丢掉缓存的原料（profile 切走 / 清除后不再留着它的数据）。
    pub(crate) fn stats_release(&self) {
        *self
            .stats_cache()
            .snapshot
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// `stats_report`：一个范围 + 一个牌组子集的全部聚合值（见 [report]）。
    pub(crate) fn stats_report(&self, profile: &str, req: &Value) -> Result<Value, String> {
        let snap = self.stats_snapshot(
            profile,
            req.get("key").and_then(Value::as_str).unwrap_or(""),
        )?;
        let ctx = Ctx::parse(req)?;
        Ok(report(&snap, &ctx, req))
    }

    /// `stats_recall`：RWKV-Instant 排队的复习卡（请求里 `recallDecks` / `recallFallback` 认定的牌组里、复习队列的
    /// 可见卡），按卡片行序：`{cards: [[卡, 笔记, 牌组, 最后一条日志 | null]…]}`。Dart 拿去问 RWKV 此刻的回忆率，再随
    /// `stats_report` 的 `recall` 交回来。
    pub(crate) fn stats_recall(&self, profile: &str, req: &Value) -> Result<Value, String> {
        let snap = self.stats_snapshot(
            profile,
            req.get("key").and_then(Value::as_str).unwrap_or(""),
        )?;
        let ctx = Ctx::parse(req)?;
        let cards: Vec<Value> = snap
            .cards
            .iter()
            .filter(|c| c.queue == "review" && ctx.recall_deck(&c.deck))
            .map(|c| json!([c.id, c.note, c.deck, c.last_log]))
            .collect();
        Ok(json!({ "cards": cards }))
    }

    /// `stats_rows`：归一化之后逐卡 / 逐条的统计视图（与删除前 Dart `SrsStatCard` / `SrsStatReview` /
    /// `SrsStatMaturityEvent` 同一组字段）。只给回归向量（srs_stats_vectors_test）核对归一化本身用；界面不读。
    pub(crate) fn stats_rows(&self, profile: &str, req: &Value) -> Result<Value, String> {
        let snap = self.stats_snapshot(
            profile,
            req.get("key").and_then(Value::as_str).unwrap_or(""),
        )?;
        let ctx = Ctx::parse(req)?;
        let v = View::build(&snap, &ctx, None);
        let id_of = |i: usize| -> &str {
            if i < snap.cards.len() {
                &snap.cards[i].id
            } else {
                &snap.extra[i - snap.cards.len()]
            }
        };
        let cards: Vec<Value> = v
            .cards
            .iter()
            .map(|&i| {
                let c = &snap.cards[i];
                let d = &v.derived[i];
                json!([
                    c.id,
                    c.note,
                    c.deck,
                    d.state.name(),
                    c.suspended,
                    d.buried,
                    c.fushi,
                    c.days,
                    c.due_day,
                    c.due_at,
                    c.stab,
                    c.diff,
                    d.r,
                    c.lapses,
                    c.reps,
                    d.added_day,
                    d.desired,
                    d.by_recall,
                ])
            })
            .collect();
        let reviews: Vec<Value> = v
            .reviews
            .iter()
            .map(|r| {
                json!([
                    id_of(r.card),
                    r.at,
                    r.day,
                    r.hour,
                    r.rating,
                    r.kind,
                    r.dur,
                    r.early
                ])
            })
            .collect();
        let maturity: Vec<Value> = v
            .maturity
            .iter()
            .map(|&(card, day, delta)| json!([id_of(card), day, delta]))
            .collect();
        Ok(json!({
            "today": v.today,
            "cards": cards,
            "reviews": reviews,
            "maturity": maturity,
            "sources": sources_json(&snap, &v),
            "retrievabilityAvailable": ctx.models.is_some(),
        }))
    }
}

// ------------------------------------------------------------------ 请求

/// 一次统计请求的口径：此刻、日界、每个牌组的排程配置（可提取度模型、目标保留率、是否按 RWKV 排队）与 RWKV 回忆率。
struct Ctx {
    now: i64,
    day: Day,
    today: i64,
    /// 可提取度用的 FSRS 模型（`[[算法, 参数]…]` 建好；建不起来的为 None）；None = 排程内核不可用，不算可提取度。
    models: Option<Vec<Option<fsrs::FSRS>>>,
    deck_models: HashMap<String, usize>,
    fallback_model: Option<usize>,
    desired: HashMap<String, f64>,
    fallback_desired: f64,
    recall_decks: HashSet<String>,
    recall_fallback: bool,
    /// RWKV 此刻回忆率（卡 → R，非有限值 = None）；None = RWKV 不可用：没有按回忆率排队的卡。
    recall: Option<HashMap<String, Option<f64>>>,
}

impl Ctx {
    fn parse(req: &Value) -> Result<Ctx, String> {
        let i = |k: &str| {
            req.get(k)
                .and_then(Value::as_i64)
                .ok_or_else(|| format!("stats: missing {k}"))
        };
        let day = Day {
            utc_offset_min: i("utcOff")?,
            rollover_hour: i("rollover")?,
        };
        let now = i("now")?;
        let models = req.get("models").and_then(Value::as_array).map(|ms| {
            ms.iter()
                .map(|m| {
                    let alg = m.get(0).and_then(Value::as_str)?;
                    crate::Algorithm::parse(alg)
                        .ok()
                        .and_then(|a| crate::build_model(a, m.get(1)).ok())
                })
                .collect()
        });
        let index_map = |k: &str| -> HashMap<String, usize> {
            req.get(k)
                .and_then(Value::as_object)
                .map(|m| {
                    m.iter()
                        .filter_map(|(k, v)| Some((k.clone(), v.as_u64()? as usize)))
                        .collect()
                })
                .unwrap_or_default()
        };
        let desired = req
            .get("desired")
            .and_then(Value::as_object)
            .map(|m| {
                m.iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_f64()?)))
                    .collect()
            })
            .unwrap_or_default();
        let strings = |k: &str| -> HashSet<String> {
            req.get(k)
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        };
        let recall = req.get("recall").and_then(Value::as_object).map(|m| {
            let ids = m.get("ids").and_then(Value::as_array);
            let rs = m.get("r").and_then(Value::as_array);
            let mut out = HashMap::new();
            if let (Some(ids), Some(rs)) = (ids, rs) {
                for (id, r) in ids.iter().zip(rs) {
                    if let Some(id) = id.as_str() {
                        out.insert(id.to_owned(), r.as_f64().filter(|x| x.is_finite()));
                    }
                }
            }
            out
        });
        Ok(Ctx {
            now,
            day,
            today: day.index(now),
            models,
            deck_models: index_map("deckModels"),
            fallback_model: req
                .get("fallbackModel")
                .and_then(Value::as_u64)
                .map(|v| v as usize),
            desired,
            fallback_desired: req
                .get("fallbackDesired")
                .and_then(Value::as_f64)
                .unwrap_or(0.9),
            recall_decks: strings("recallDecks"),
            recall_fallback: req.get("recallFallback") == Some(&Value::Bool(true)),
            recall,
        })
    }

    fn recall_deck(&self, deck: &str) -> bool {
        if self.recall_decks.contains(deck) {
            return true;
        }
        // 不在牌组树里的牌组归默认牌组（同 `SrsDeckTree.effectiveDeckOf`）。
        !self.desired.contains_key(deck) && self.recall_fallback
    }

    fn desired_of(&self, deck: &str) -> f64 {
        self.desired
            .get(deck)
            .copied()
            .unwrap_or(self.fallback_desired)
    }

    /// FSRS 可提取度（f32 计算，同 `ffsrs_retrievability_batch`）；新卡、没有记忆状态或上次复习时刻、模型建不起来、
    /// 结果不是有限值 = None。
    fn retrievability(&self, c: &Card, state: State) -> Option<f64> {
        let models = self.models.as_ref()?;
        if state == State::New {
            return None;
        }
        let (s, d, last) = (c.stab?, c.diff?, c.last?);
        let k = self
            .deck_models
            .get(&c.deck)
            .copied()
            .or(self.fallback_model)?;
        let model = models.get(k)?.as_ref()?;
        let memory = crate::Memory {
            s: s as f32,
            d: d as f32,
            sf: None,
        };
        let elapsed = (self.now - last).max(0) as f64 / DAY_MS as f64;
        let r = model.current_retrievability(memory.to_fsrs(), elapsed as f32);
        r.is_finite().then_some(f64::from(r))
    }
}

// ------------------------------------------------------------------ 归一化

/// 一张卡此刻的派生值（与日界 / 排程配置有关的那部分）。
#[derive(Clone, Copy)]
struct Derived {
    state: State,
    buried: bool,
    by_recall: bool,
    r: Option<f64>,
    added_day: i64,
    desired: f64,
}

/// 一条有效评分复习（日序号 / 小时 / 提前复习按请求的日界算）。
#[derive(Clone, Copy)]
struct Review {
    card: usize,
    at: i64,
    day: i64,
    hour: i64,
    rating: u8,
    kind: u8,
    dur: i64,
    early: bool,
}

impl Review {
    fn correct(&self) -> bool {
        self.rating > 1
    }
}

/// 一个牌组子集上的统计视图：选中的可见卡（行序）、它们的复习（时刻升序）与成熟变化。
struct View {
    today: i64,
    now: i64,
    derived: Vec<Derived>,
    cards: Vec<usize>,
    reviews: Vec<Review>,
    /// (卡, 日, ±1)。
    maturity: Vec<(usize, i64, i64)>,
}

impl View {
    /// [decks] = 只看这些牌组里的卡（复习与成熟变化按卡跟随；不可见的归属卡不属于任何牌组）；None = 全部（含归属到
    /// 不可见卡的复习）。
    fn build(s: &Snapshot, ctx: &Ctx, decks: Option<&HashSet<String>>) -> View {
        let derived: Vec<Derived> = s
            .cards
            .iter()
            .map(|c| {
                let state = State::of(&c.queue, c.days);
                let by_recall = ctx.recall.is_some()
                    && state != State::New
                    && c.queue == "review"
                    && ctx.recall_deck(&c.deck);
                let r = if by_recall {
                    ctx.recall
                        .as_ref()
                        .and_then(|m| m.get(&c.id).copied().flatten())
                } else {
                    ctx.retrievability(c, state)
                };
                Derived {
                    state,
                    buried: c.buried_until.is_some_and(|b| b > ctx.today),
                    by_recall,
                    r,
                    added_day: ctx.day.index(c.added_at),
                    desired: ctx.desired_of(&c.deck),
                }
            })
            .collect();
        let selected: Vec<bool> = s
            .cards
            .iter()
            .map(|c| decks.is_none_or(|d| d.contains(&c.deck)))
            .collect();
        let keep = |card: usize| -> bool {
            match decks {
                None => true,
                Some(_) => card < selected.len() && selected[card],
            }
        };
        let cards = (0..s.cards.len()).filter(|&i| selected[i]).collect();
        let mut reviews = Vec::new();
        let mut maturity = Vec::new();
        for r in &s.reviews {
            if !keep(r.card) {
                continue;
            }
            let day = ctx.day.index(r.at);
            if let Some(rating) = r.rating {
                reviews.push(Review {
                    card: r.card,
                    at: r.at,
                    day,
                    hour: (r.at + r.off * 60_000).rem_euclid(DAY_MS) / HOUR_MS,
                    rating,
                    kind: r.kind,
                    dur: r.dur,
                    early: r.prev_due.is_some_and(|p| p > day),
                });
            }
            if r.maturity != 0 {
                maturity.push((r.card, day, r.maturity));
            }
        }
        View {
            today: ctx.today,
            now: ctx.now,
            derived,
            cards,
            reviews,
            maturity,
        }
    }

    fn card<'a>(&'a self, s: &'a Snapshot, i: usize) -> (&'a Card, &'a Derived) {
        (&s.cards[i], &self.derived[i])
    }

    fn between(&self, first: i64, last: i64) -> impl Iterator<Item = &Review> {
        self.reviews
            .iter()
            .filter(move |r| r.day >= first && r.day <= last)
    }

    /// 有数据的最早一天（复习或加卡）；都没有时为今天。
    fn earliest_day(&self) -> i64 {
        let mut d = self.today;
        if let Some(r) = self.reviews.first() {
            d = d.min(r.day);
        }
        for &i in &self.cards {
            d = d.min(self.derived[i].added_day);
        }
        d
    }

    fn first_day_of(&self, range: &str) -> i64 {
        match range {
            "month" => self.today - 29,
            "threeMonths" => self.today - 89,
            "year" => self.today - 364,
            _ => self.today.min(self.earliest_day()),
        }
    }
}

// ------------------------------------------------------------------ 分桶

/// 日历日序号 → (年, 月, 日)（公历，1970-01-01 = 0）。
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// (年, 月, 日) → 日历日序号。
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// [first]..[last] 切桶：≤ 92 天逐日，≤ 400 天逐周（从末日往回数整 7 天，最新一周恒完整），更长按自然月。
fn buckets(first: i64, last: i64) -> (&'static str, Vec<(i64, i64)>) {
    if last < first {
        return ("day", Vec::new());
    }
    let span = last - first + 1;
    if span <= 92 {
        return ("day", (first..=last).map(|d| (d, d)).collect());
    }
    if span <= 400 {
        let mut out = Vec::new();
        let mut end = last;
        while end >= first {
            out.push((first.max(end - 6), end));
            end -= 7;
        }
        out.reverse();
        return ("week", out);
    }
    let mut out = Vec::new();
    let (mut y, mut m, _) = civil_from_days(first);
    loop {
        let start = first.max(days_from_civil(y, m, 1));
        if start > last {
            break;
        }
        let next = if m == 12 {
            days_from_civil(y + 1, 1, 1)
        } else {
            days_from_civil(y, m + 1, 1)
        };
        out.push((start, last.min(next - 1)));
        m += 1;
        if m == 13 {
            m = 1;
            y += 1;
        }
    }
    ("month", out)
}

// ------------------------------------------------------------------ 直方图

fn median(sorted: &[f64]) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let mid = sorted.len() / 2;
    Some(if sorted.len() % 2 == 1 {
        sorted[mid]
    } else {
        (sorted[mid - 1] + sorted[mid]) / 2.0
    })
}

fn empty_hist() -> Value {
    json!({"bins": [], "total": 0, "mean": null, "median": null, "openEnded": false, "sum": 0.0})
}

/// 以「天」为单位的直方图：长尾截在 95 分位（末格「≥」），格宽取 1 / 2 / 5 × 10ⁿ 天里让格数 ≤ 24 的最小者。
fn days_hist(mut v: Vec<f64>) -> Value {
    if v.is_empty() {
        return empty_hist();
    }
    v.sort_by(f64::total_cmp);
    let sum = v.iter().fold(0.0, |a, b| a + b);
    let p95 = v[((v.len() - 1) as f64 * 0.95).floor() as usize];
    let max_v = v[v.len() - 1];
    let top = f64::max(1.0, p95.ceil());
    let mut width;
    let mut pow10 = 1.0;
    'outer: loop {
        for m in [1.0, 2.0, 5.0] {
            width = pow10 * m;
            if top / width <= 24.0 {
                break 'outer;
            }
        }
        pow10 *= 10.0;
    }
    let open = max_v >= top + width;
    let bins = if open {
        (top / width).ceil() as usize + 1
    } else {
        (f64::max(top, max_v) / width).floor() as usize + 1
    };
    let mut counts = vec![0i64; bins];
    for x in &v {
        let i = ((x / width).floor().max(0.0) as usize).min(bins - 1);
        counts[i] += 1;
    }
    json!({
        "bins": (0..bins).map(|i| json!([i as f64 * width, (i + 1) as f64 * width, counts[i]])).collect::<Vec<_>>(),
        "total": v.len(),
        "mean": sum / v.len() as f64,
        "median": median(&v),
        "openEnded": open,
        "sum": sum,
    })
}

/// 0..1 的直方图（[bins] 等宽格，1.0 落进末格）。
fn unit_hist(mut v: Vec<f64>, bins: usize) -> Value {
    if v.is_empty() {
        return empty_hist();
    }
    v.sort_by(f64::total_cmp);
    let mut counts = vec![0i64; bins];
    let mut sum = 0.0;
    for x in &v {
        sum += x;
        counts[((x * bins as f64).floor().max(0.0) as usize).min(bins - 1)] += 1;
    }
    json!({
        "bins": (0..bins).map(|i| json!([i as f64 / bins as f64, (i + 1) as f64 / bins as f64, counts[i]])).collect::<Vec<_>>(),
        "total": v.len(),
        "mean": sum / v.len() as f64,
        "median": median(&v),
        "openEnded": false,
        "sum": sum,
    })
}

// ------------------------------------------------------------------ 字符串（Dart 口径）

/// Dart `String.trim` 认的空白：Unicode White_Space，外加 U+FEFF。
fn dart_trim(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() || c == '\u{FEFF}')
}

/// Dart `String.compareTo`：按 UTF-16 码元比较。
fn dart_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// 制卡来源（按笔记计）：同种类同标题（标题去两侧空白）归一组，按笔记数倒序、种类、标题。带系列的出处按系列名计
/// （「系列 → 集」的上一级，反馈 MCJLSBR5Wg）：系列名在缓存刷新时已写进笔记缓存行的 `source_title`（caches.rs
/// `NoteInfo::of`，与出处分组键 `source_key` 同一个判据 store/browse.rs `source_series`），这里读到的标题就是它，
/// 不再另判一遍。
fn sources_json(s: &Snapshot, v: &View) -> Value {
    let mut order: Vec<(String, String)> = Vec::new();
    let mut counts: HashMap<(String, String), i64> = HashMap::new();
    let mut seen: HashSet<&str> = HashSet::new();
    for &i in &v.cards {
        let c = &s.cards[i];
        if !seen.insert(&c.note) {
            continue;
        }
        let key = match c.src.map(|k| &s.sources[k]) {
            Some((kind, title)) if !kind.is_empty() => (kind.clone(), dart_trim(title).to_owned()),
            _ => (String::new(), String::new()),
        };
        let n = counts.entry(key.clone()).or_insert(0);
        if *n == 0 {
            order.push(key);
        }
        *n += 1;
    }
    let mut out: Vec<(String, String, i64)> = order
        .into_iter()
        .map(|k| {
            let n = counts[&k];
            (k.0, k.1, n)
        })
        .collect();
    out.sort_by(|a, b| {
        b.2.cmp(&a.2)
            .then_with(|| dart_cmp(&a.0, &b.0))
            .then_with(|| dart_cmp(&a.1, &b.1))
    });
    Value::Array(out.into_iter().map(|(k, t, n)| json!([k, t, n])).collect())
}

// ------------------------------------------------------------------ 聚合

/// 一个时间窗的保留率与复习合计：`[年轻答对, 年轻总数, 成熟答对, 成熟总数, 复习数, 用时, 学习天数, 天数]`。
fn window(v: &View, first: i64, last: i64) -> Value {
    let (mut yo, mut ya, mut mo, mut ma, mut n, mut ms) = (0i64, 0i64, 0i64, 0i64, 0i64, 0i64);
    let mut studied: HashSet<i64> = HashSet::new();
    for r in v.between(first, last) {
        n += 1;
        ms += r.dur;
        studied.insert(r.day);
        match r.kind {
            K_YOUNG => {
                ya += 1;
                if r.correct() {
                    yo += 1;
                }
            }
            K_MATURE => {
                ma += 1;
                if r.correct() {
                    mo += 1;
                }
            }
            _ => {}
        }
    }
    json!([
        yo,
        ya,
        mo,
        ma,
        n,
        ms,
        studied.len(),
        (last - first + 1).max(0)
    ])
}

/// 一个范围 + 一个牌组子集的全部聚合值。请求：
///
/// - `range`：`month` / `threeMonths` / `year` / `all`（复习量、用时、按小时、评分按钮、添加、成熟卡增长、范围保留率）；
/// - `decks`：只看这些牌组里的卡（Dart 按牌组树展开好的子树）；缺省 = 全部；
/// - `future`：未来到期看几天（含今天）；缺省 = 最晚到期日（夹在 30..3650）；
/// - `windows`：`{名字: [往前第几天 | null = 最早一天, 往前第几天]}`，各回一个 [window]。
fn report(s: &Snapshot, ctx: &Ctx, req: &Value) -> Value {
    let decks: Option<HashSet<String>> = req.get("decks").and_then(Value::as_array).map(|a| {
        a.iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    });
    let v = View::build(s, ctx, decks.as_ref());
    aggregate(s, &v, ctx.day, ctx.models.is_some(), decks.is_some(), req)
}

/// [report] 的聚合部分：[v] 是已按日界 / 排程配置归一好的视图（单测直接构造）。
fn aggregate(
    s: &Snapshot,
    v: &View,
    day: Day,
    retrievability: bool,
    filtered: bool,
    req: &Value,
) -> Value {
    let today = v.today;
    let range = req.get("range").and_then(Value::as_str).unwrap_or("month");
    let first = v.first_day_of(range);
    let earliest = v.earliest_day();

    // 今日。
    let mut t_ratings = [0i64; 4];
    let mut t_kinds = [0i64; KINDS];
    let (mut t_n, mut t_ms, mut t_early, mut t_mok, mut t_mall) = (0i64, 0i64, 0i64, 0i64, 0i64);
    for r in v.between(today, today) {
        t_n += 1;
        t_ms += r.dur;
        t_ratings[(r.rating as usize).clamp(1, 4) - 1] += 1;
        t_kinds[r.kind as usize] += 1;
        if r.early {
            t_early += 1;
        }
        if r.kind == K_MATURE {
            t_mall += 1;
            if r.correct() {
                t_mok += 1;
            }
        }
    }

    // 日历与打卡。
    let mut by_day: std::collections::BTreeMap<i64, i64> = std::collections::BTreeMap::new();
    for r in &v.reviews {
        *by_day.entry(r.day).or_insert(0) += 1;
    }
    let mut current = 0i64;
    let mut d = if by_day.contains_key(&today) {
        today
    } else {
        today - 1
    };
    while by_day.contains_key(&d) {
        current += 1;
        d -= 1;
    }
    let (mut longest, mut run, mut prev) = (0i64, 0i64, None::<i64>);
    for &x in by_day.keys() {
        run = if prev.is_some_and(|p| x == p + 1) {
            run + 1
        } else {
            1
        };
        longest = longest.max(run);
        prev = Some(x);
    }

    // 未来到期。
    let mut far = 30i64;
    for &i in &v.cards {
        let (c, dv) = v.card(s, i);
        if !c.fushi || c.suspended || !dv.state.is_review() || dv.by_recall {
            continue;
        }
        far = far.max(c.due_day.unwrap_or(today) - today + 1);
    }
    let far = far.min(3650);
    let n = req
        .get("future")
        .and_then(Value::as_i64)
        .unwrap_or(far)
        .max(1) as usize;
    let mut per_day = vec![0i64; n];
    let mut young_day = vec![0i64; n];
    let (mut overdue, mut by_recall, mut load) = (0i64, 0i64, 0.0f64);
    // RWKV 此刻 / 有没有按到期日排队的卡。
    let mut recall_ids: HashSet<usize> = HashSet::new();
    let (mut r_due, mut r_near, mut due_date) = (0i64, 0i64, false);
    for &i in &v.cards {
        let (c, dv) = v.card(s, i);
        if !c.fushi || c.suspended {
            continue;
        }
        if dv.by_recall && dv.state.is_review() {
            by_recall += 1;
            recall_ids.insert(i);
            if let Some(r) = dv.r.filter(|r| r.is_finite()) {
                if r <= dv.desired {
                    r_due += 1;
                } else if r <= dv.desired + NEAR_MARGIN {
                    r_near += 1;
                }
            }
            continue;
        }
        if dv.state != State::New {
            due_date = true;
        }
        let (offset, young) = match dv.state {
            State::New => continue,
            State::Learning | State::Relearning => {
                load += 1.0;
                let at = c.due_at.unwrap_or(v.now);
                ((day.index(at) - today).max(0), true)
            }
            State::Young | State::Mature => {
                load += 1.0 / c.days.max(1) as f64;
                (c.due_day.unwrap_or(today) - today, dv.state == State::Young)
            }
        };
        if offset < 0 {
            overdue += 1;
            continue;
        }
        let o = offset as usize;
        if o >= n {
            continue;
        }
        per_day[o] += 1;
        if young {
            young_day[o] += 1;
        }
    }
    let rwkv_now = if recall_ids.is_empty() {
        Value::Null
    } else {
        let reviewed = v
            .reviews
            .iter()
            .filter(|r| r.day > today - 30 && r.day <= today && recall_ids.contains(&r.card))
            .count();
        json!([recall_ids.len(), r_due, r_near, reviewed as f64 / 30.0])
    };
    let (future_unit, future_spans) = buckets(today, today + n as i64 - 1);
    let future_buckets: Vec<Value> = future_spans
        .iter()
        .map(|&(a, b)| {
            let (lo, hi) = ((a - today) as usize, (b - today) as usize);
            json!([
                a,
                b,
                per_day[lo..=hi].iter().sum::<i64>(),
                young_day[lo..=hi].iter().sum::<i64>()
            ])
        })
        .collect();

    // 范围：复习量 / 用时、成熟卡增长、添加、按小时、按钮。
    let (unit, spans) = buckets(first, today);
    let mut counts = vec![[0i64; KINDS]; spans.len()];
    let mut durs = vec![[0i64; KINDS]; spans.len()];
    let mut hourly = [[0i64; 24]; 2];
    let mut buttons = [[0i64; 4]; 3];
    for r in v.between(first, today) {
        if let Ok(k) = spans.binary_search_by(|&(a, b)| {
            if b < r.day {
                std::cmp::Ordering::Less
            } else if a > r.day {
                std::cmp::Ordering::Greater
            } else {
                std::cmp::Ordering::Equal
            }
        }) {
            counts[k][r.kind as usize] += 1;
            durs[k][r.kind as usize] += r.dur;
        }
        let h = r.hour.clamp(0, 23) as usize;
        hourly[0][h] += 1;
        if r.correct() {
            hourly[1][h] += 1;
        }
        let g = match r.kind {
            K_NEW | K_LEARN | K_RELEARN => Some(0),
            K_YOUNG => Some(1),
            K_MATURE => Some(2),
            _ => None,
        };
        if let Some(g) = g {
            buttons[g][(r.rating as usize).clamp(1, 4) - 1] += 1;
        }
    }
    let mut events: Vec<(i64, i64)> = v.maturity.iter().map(|&(_, d, x)| (d, x)).collect();
    events.sort_by_key(|e| e.0);
    let mut mature_at = Vec::with_capacity(spans.len());
    let (mut running, mut ei) = (0i64, 0usize);
    for &(_, last) in &spans {
        while ei < events.len() && events[ei].0 <= last {
            running += events[ei].1;
            ei += 1;
        }
        mature_at.push(running.max(0));
    }
    let mut added = vec![0i64; spans.len()];
    for &i in &v.cards {
        let a = v.derived[i].added_day;
        if let Some(k) = spans.iter().position(|&(x, y)| a >= x && a <= y) {
            added[k] += 1;
        }
    }

    // 卡片计数、分布、期望保留率。
    let mut cc = [0i64; 7];
    let (mut iv, mut st, mut df, mut rt) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for &i in &v.cards {
        let (c, dv) = v.card(s, i);
        if c.suspended {
            cc[5] += 1;
        } else if dv.buried {
            cc[6] += 1;
        } else {
            cc[match dv.state {
                State::New => 0,
                State::Learning => 1,
                State::Relearning => 2,
                State::Young => 3,
                State::Mature => 4,
            }] += 1;
        }
        if dv.state.is_review() {
            iv.push(c.days as f64);
        }
        if dv.state != State::New {
            if let Some(x) = c.stab {
                st.push(x);
            }
            if let Some(x) = c.diff {
                df.push(((x - 1.0) / 9.0).clamp(0.0, 1.0));
            }
            if let Some(x) = dv.r {
                rt.push(x.clamp(0.0, 1.0));
            }
        }
    }
    let any_review = v.cards.iter().any(|&i| v.derived[i].state.is_review());
    let (mut dsum, mut dn) = (0.0f64, 0usize);
    for &i in &v.cards {
        if any_review && !v.derived[i].state.is_review() {
            continue;
        }
        dsum += v.derived[i].desired;
        dn += 1;
    }

    // 首页 / 小组件。
    let mut today_by_deck: Map<String, Value> = Map::new();
    {
        let mut m: HashMap<&str, i64> = HashMap::new();
        for r in v.between(today, today) {
            if r.card < s.cards.len() && (!filtered || v.cards.binary_search(&r.card).is_ok()) {
                *m.entry(s.cards[r.card].deck.as_str()).or_insert(0) += 1;
            }
        }
        let mut keys: Vec<&&str> = m.keys().collect();
        keys.sort();
        for k in keys {
            today_by_deck.insert((*k).to_owned(), json!(m[*k]));
        }
    }
    let mut learning_due_ats = Vec::new();
    let mut reviews_next_day = 0i64;
    for &i in &v.cards {
        let (c, dv) = v.card(s, i);
        if !c.fushi || c.suspended || dv.buried {
            continue;
        }
        match dv.state {
            State::Learning | State::Relearning => {
                if let Some(at) = c.due_at.filter(|&at| at > v.now) {
                    learning_due_ats.push(at);
                }
            }
            State::Young | State::Mature => {
                if !dv.by_recall && c.due_day == Some(today + 1) {
                    reviews_next_day += 1;
                }
            }
            State::New => {}
        }
    }

    let mut windows = Map::new();
    if let Some(w) = req.get("windows").and_then(Value::as_object) {
        for (name, spec) in w {
            let a = spec.get(0).and_then(Value::as_i64);
            let b = spec.get(1).and_then(Value::as_i64).unwrap_or(0);
            let from = a.map_or(earliest, |a| today - a);
            windows.insert(name.clone(), window(v, from, today - b));
        }
    }

    json!({
        "today": today,
        "empty": v.reviews.is_empty() && v.cards.is_empty(),
        "earliestDay": earliest,
        "firstDay": first,
        "retrievabilityAvailable": retrievability,
        "todayStats": [t_n, t_ms, t_ratings, t_kinds, t_early, t_mok, t_mall],
        "streak": [current, longest],
        "countsByDay": by_day.iter().map(|(d, n)| json!([d, n])).collect::<Vec<_>>(),
        "future": {
            "overdue": overdue,
            "byRecall": by_recall,
            "load": load,
            "perDay": per_day,
            "youngPerDay": young_day,
            "unit": future_unit,
            "buckets": future_buckets,
        },
        "furthestDue": far,
        "rwkvNow": rwkv_now,
        "hasDueDateCards": due_date,
        "reviews": {
            "unit": unit,
            "buckets": spans.iter().enumerate().map(|(k, &(a, b))| json!([a, b, counts[k], durs[k]])).collect::<Vec<_>>(),
        },
        "matureAt": mature_at,
        "added": added,
        "cardCounts": cc,
        "hist": {
            "interval": days_hist(iv),
            "stability": days_hist(st),
            "difficulty": unit_hist(df, 10),
            "retrievability": unit_hist(rt, 20),
        },
        "hourly": [hourly[0], hourly[1]],
        "buttons": buttons,
        "windows": windows,
        "desiredRetention": if dn == 0 { Value::Null } else { json!(dsum / dn as f64) },
        "sources": sources_json(s, v),
        "todayByDeck": today_by_deck,
        "learningDueAts": learning_due_ats,
        "reviewsNextDay": reviews_next_day,
    })
}

#[cfg(test)]
#[path = "stats_tests.rs"]
mod tests;
