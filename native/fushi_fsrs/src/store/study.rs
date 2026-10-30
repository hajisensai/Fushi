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
//! - 出卡：学习卡 → 到期复习卡（会话里按块下界取此刻可提取度最低的一张，不扫全部到期卡）→ 新卡（部分索引序
//!   `LIMIT 1`，命中第一张即停）→ 20 分钟内到期的学习卡；
//! - RWKV-Instant 的牌组：分数由 Dart 侧的 RWKV 服务给（另一个原生库），这里只做排队规则（目标保留率、同日
//!   间隔守卫、每天最少复习数、按 R 升序），与旧 Dart `_instantReviews` 同口径。
//!
//! 请求 `{"deck"?: 根牌组, "now", "utcOff", "rollover", "exclude"?: [卡], "pick"?: bool,
//!        "rwkv"?: {"decks": {牌组: [目标保留率, 每天最少, 间隔次数, 间隔秒数]}, "cands": [[卡, 牌组, 上次作答|null, R]]}}`；
//! 结果 `{"counts": {牌组: [新, 学习, 到期, 总数, 新卡上限, 新卡配额, 复习预算, 缩减原因|null]}, "next", "after", "eligible"}`。
//! 没给 `deck` = 全部牌组（牌组列表）；给了但不在树里 = `counts` 为 null。

use std::collections::{HashMap, HashSet};

use rusqlite::{params_from_iter, types::Value as Sql, Connection};
use serde_json::{json, Value};

use crate::projection::Day;
use crate::store::queue::{DeckRaw, DueCand, LogState, Session, StudyHub, LEARN_AHEAD_MS};
use crate::store::sync2::config::DeckTree;
use crate::store::sync2::sql;

/// 卡「可出」：可见、未暂停、归 Fushi 排程、没埋或埋到期（绑定一个参数：今天）。与 queue.rs `Row::live` 同一判据。
const LIVE: &str = "hidden = 0 AND suspended = 0 AND scheduler = 'fushi' AND (buried_until_day IS NULL OR buried_until_day <= ?)";
const DAY_MS: i64 = 86_400_000;

/// 一个牌组自己（或整棵子树）的原始卡数与今天的学习量。
#[derive(Clone, Copy, Default, Debug)]
struct Tally {
    total: i64,
    new_avail: i64,
    learn: i64,
    due: i64,
    new_done: i64,
    review_done: i64,
}

impl Tally {
    fn add(&mut self, o: &Tally) {
        self.total += o.total;
        self.new_avail += o.new_avail;
        self.learn += o.learn;
        self.due += o.due;
        self.new_done += o.new_done;
        self.review_done += o.review_done;
    }

    fn of(r: DeckRaw) -> Tally {
        Tally { total: r.total, new_avail: r.new_avail, learn: r.learn, due: r.due, new_done: 0, review_done: 0 }
    }
}

/// 今天的新卡配额（Dart `srsComputeNewCardBudget`）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Budget {
    pub limit: i64,
    pub allowed: i64,
    pub review_budget: i64,
    /// None / "reduced" / "paused"。
    pub reason: Option<&'static str>,
}

/// 新卡数按复习量自动调节：预算 = 最近 30 天有复习的天的日均 × 1.5（不低于上限 × 10；有复习的天不足 7 天
/// 时就是上限 × 10）；到期数 ≤ 预算不缩减，超过 2 倍预算当天不出新卡，其间线性缩减。
pub(crate) fn new_card_budget(limit: i64, due: i64, last30: &[i64]) -> Budget {
    let active: Vec<i64> = last30.iter().copied().filter(|n| *n > 0).collect();
    let floor = limit * 10;
    let budget = if active.len() < 7 {
        floor
    } else {
        let avg = active.iter().sum::<i64>() as f64 / active.len() as f64;
        ((avg * 1.5).round() as i64).max(floor)
    };
    if budget <= 0 || due <= budget {
        return Budget { limit, allowed: limit, review_budget: budget, reason: None };
    }
    if due > budget * 2 {
        return Budget { limit, allowed: 0, review_budget: budget, reason: Some("paused") };
    }
    let factor = 1.0 - (due - budget) as f64 / budget as f64;
    let allowed = ((limit as f64 * factor).floor() as i64).max(0).min(limit);
    Budget { limit, allowed, review_budget: budget, reason: if allowed < limit { Some("reduced") } else { None } }
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

/// 排队读的卡 / 日志数据：生产是常驻会话（[SessionSource]），测试里另有 L2 的逐条 SQL 实现当对拍基准。
trait Source {
    fn logs(&self) -> &LogState;
    /// 每个牌组**自己**（不含子牌组）的计数原料；只给有 hidden = 0 的卡的牌组。[decks] 为 None = 全部牌组。
    fn tallies(&self, now: i64, decks: Option<&[String]>) -> Result<HashMap<String, DeckRaw>, String>;
    /// 一组卡所在的牌组与是否隐藏。
    fn decks_of(&self, ids: &HashSet<String>) -> Result<HashMap<String, (String, bool)>, String>;
    /// 子树里按 (COALESCE(due_at, 0), id) 第一张在 [limit] 前到期的可出学习卡：(卡, due_at)。
    fn first_learning(&self, decks: &[&str], limit: i64, exclude: &[&str]) -> Result<Option<(String, Option<i64>)>, String>;
    /// 几个牌组的到期复习卡里此刻可提取度最低的一张。
    fn lowest_due(&self, decks: &[&str], now: i64, exclude: &HashSet<&str>) -> Result<Option<DueCand>, String>;
}

struct SessionSource<'a>(&'a Session);

impl Source for SessionSource<'_> {
    fn logs(&self) -> &LogState {
        self.0.logs()
    }

    fn tallies(&self, now: i64, decks: Option<&[String]>) -> Result<HashMap<String, DeckRaw>, String> {
        Ok(self.0.tallies(now, decks))
    }

    fn decks_of(&self, ids: &HashSet<String>) -> Result<HashMap<String, (String, bool)>, String> {
        Ok(self.0.decks_of(ids))
    }

    fn first_learning(&self, decks: &[&str], limit: i64, exclude: &[&str]) -> Result<Option<(String, Option<i64>)>, String> {
        Ok(self.0.first_learning(decks, limit, exclude))
    }

    fn lowest_due(&self, decks: &[&str], now: i64, exclude: &HashSet<&str>) -> Result<Option<DueCand>, String> {
        Ok(self.0.lowest_due(decks, now, exclude))
    }
}

/// 新卡的「按索引序取第一张」（`idx_srs_cards_cache_new_*` 部分索引）。
fn first_sql(decks: usize, condition: &str, order: &str, exclude: usize) -> String {
    let not_in = if exclude == 0 { String::new() } else { format!(" AND id NOT IN ({})", marks(exclude)) };
    format!(
        "SELECT id, due_at FROM srs_cards_cache WHERE profile_uid = ? AND {LIVE} AND deck_id IN ({}) AND {condition}{not_in} ORDER BY {order} LIMIT 1",
        marks(decks)
    )
}

const NEW_BY_POSITION: &str = "new_position IS NULL, new_position, note_created_at, id";
const NEW_BY_FREQUENCY: &str = "freq_rank IS NULL, freq_rank, new_position IS NULL, new_position, note_created_at, id";

fn marks(n: usize) -> String {
    vec!["?"; n].join(", ")
}

/// RWKV-Instant 合格的复习卡（按 R 升序，同 R 按 id）。与旧 Dart `_instantReviews` 同口径：
/// - R ≤ 卡所在牌组的目标保留率才合格；
/// - 同日重复的间隔守卫：今天答过的卡，距上次作答不足 `repeat_seconds` 秒，或这之后 [scope] 里别的卡的作答不足
///   `repeat_reviews` 次 → 暂缓；
/// - 每天最少复习数：某牌组今天复习过的卡加上合格卡仍不到这个数时，从只因 R 高于目标被挡的卡里按 R 升序补足。
fn instant_eligible(
    ctx: &Ctx<'_>,
    scope: &HashSet<&str>,
    decks: &HashMap<String, InstantDeck>,
    cands: &[(String, String, Option<i64>, f64)],
    answered_deck: &HashMap<String, (String, bool)>,
) -> Vec<(String, String, f64)> {
    let day_start = ctx.day_start(ctx.today);
    let spaced = |id: &str, last: Option<i64>, q: &InstantDeck| -> bool {
        let Some(last) = last.filter(|l| *l >= day_start) else { return true };
        if ctx.now < last + q.repeat_seconds * 1000 {
            return false;
        }
        if q.repeat_reviews <= 0 {
            return true;
        }
        let mut others = 0;
        for (other, at) in ctx.logs.answers() {
            if at > last && other != id && answered_deck.get(other).is_some_and(|(d, _)| scope.contains(d.as_str())) {
                others += 1;
                if others >= q.repeat_reviews {
                    return true;
                }
            }
        }
        false
    };
    let mut eligible: Vec<(String, String, f64)> = Vec::new();
    let mut above: Vec<(String, String, f64)> = Vec::new();
    for (id, deck, last, r) in cands {
        let Some(q) = decks.get(deck) else { continue };
        if !r.is_finite() || !spaced(id, *last, q) {
            continue;
        }
        if *r > q.target { &mut above } else { &mut eligible }.push((id.clone(), deck.clone(), *r));
    }
    let by_r = |a: &(String, String, f64), b: &(String, String, f64)| a.2.partial_cmp(&b.2).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.0.cmp(&b.0));
    if decks.values().any(|q| q.min_reviews > 0) && !above.is_empty() {
        let mut remaining: HashMap<&str, i64> = decks.iter().filter(|(_, q)| q.min_reviews > 0).map(|(d, q)| (d.as_str(), q.min_reviews)).collect();
        for id in ctx.logs.reviewed_cards() {
            if let Some((d, _)) = answered_deck.get(id) {
                if let Some(left) = remaining.get_mut(d.as_str()) {
                    *left -= 1;
                }
            }
        }
        for (_, d, _) in &eligible {
            if let Some(left) = remaining.get_mut(d.as_str()) {
                *left -= 1;
            }
        }
        above.sort_by(by_r);
        for c in above {
            match remaining.get_mut(c.1.as_str()) {
                Some(left) if *left > 0 => *left -= 1,
                _ => continue,
            }
            eligible.push(c);
        }
    }
    eligible.sort_by(by_r);
    eligible
}

/// 牌组树计数（对齐 Anki v3 的 limit tree，rslib scheduler/queue/limits.rs）：每个牌组的今日剩余上限 = 自己的
/// 每日上限（新卡另按复习量缩减）− 今天整棵子树里已学的新卡 / 已复习的卡；新卡 / 到期数自底向上取
/// min(本牌组剩余上限, 自己的卡 + Σ 子牌组已截断后的数)；学习数不截断；只看 [root] 这棵子树（None = 全部顶层）。
fn count_tree(ctx: &Ctx<'_>, tallies: &HashMap<String, Tally>, ids: &[String], root: Option<&str>) -> HashMap<String, Count> {
    let scope: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let mut children: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut tops: Vec<&str> = Vec::new();
    for id in ids {
        match ctx.parent(id) {
            Some(p) if Some(id.as_str()) != root && scope.contains(p) => children.entry(p).or_default().push(id),
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
        let budget = new_card_budget(int(view, "np", 20), sub.due, ctx.logs.last30());
        let new_remaining = (budget.allowed - sub.new_done).max(0);
        let review_remaining = (int(view, "rp", 200) - sub.review_done).max(0);
        let r = Count {
            sub,
            budget,
            new_remaining,
            review_remaining,
            new_count: new_remaining.min(new_sum),
            review_count: review_remaining.min(review_sum),
            learn_count: learn_sum,
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
    c: &'a Connection,
    src: &'a dyn Source,
    profile: &'a str,
    ctx: &'a Ctx<'a>,
    root: &'a str,
    sub: &'a [String],
    counts: &'a HashMap<String, Count>,
    instant_decks: HashSet<&'a str>,
    eligible: &'a [(String, String, f64)],
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
    fn first_new(&self, decks: &[&str], order: &str, exclude: &[&str]) -> Result<Option<String>, String> {
        if decks.is_empty() {
            return Ok(None);
        }
        let sql_text = first_sql(decks.len(), "queue = 'new'", order, exclude.len());
        let mut args: Vec<Sql> = vec![Sql::Text(self.profile.to_owned()), Sql::Integer(self.ctx.today)];
        args.extend(decks.iter().map(|d| Sql::Text((*d).to_owned())));
        args.extend(exclude.iter().map(|d| Sql::Text((*d).to_owned())));
        let mut stmt = self.c.prepare_cached(&sql_text).map_err(sql)?;
        let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
        match q.next().map_err(sql)? {
            Some(r) => Ok(Some(r.get(0).map_err(sql)?)),
            None => Ok(None),
        }
    }

    /// 下一张：到期的学习卡 → 到期复习卡（可提取度从低到高；RWKV 牌组按 R）→ 新卡（所点牌组的新卡顺序）→
    /// 20 分钟内到期的学习卡。
    fn next(&self, exclude: &[&str]) -> Result<Option<String>, String> {
        let ex: HashSet<&str> = exclude.iter().copied().collect();
        let sub: Vec<&str> = self.sub.iter().map(String::as_str).collect();
        let learning = self.src.first_learning(&sub, self.ctx.now + LEARN_AHEAD_MS, exclude)?;
        if let Some((id, due)) = &learning {
            if due.unwrap_or(0) <= self.ctx.now {
                return Ok(Some(id.clone()));
            }
        }
        let sum = self.counts[self.root];
        if sum.review_count > 0 {
            let instant_best = self
                .eligible
                .iter()
                .find(|(id, deck, _)| !ex.contains(id.as_str()) && self.path_has_room(deck, |c| c.review_remaining));
            let fsrs_decks: Vec<&str> =
                sub.iter().copied().filter(|d| !self.instant_decks.contains(d) && self.path_has_room(d, |c| c.review_remaining)).collect();
            let due = if fsrs_decks.is_empty() { None } else { self.src.lowest_due(&fsrs_decks, self.ctx.now, &ex)? };
            match (instant_best, due) {
                (None, Some((id, _, _))) => return Ok(Some(id)),
                (Some((id, _, _)), None) => return Ok(Some(id.clone())),
                (Some((iid, _, ir)), Some((did, last, s))) => {
                    // 子树里 RWKV 与 FSRS 牌组混排：两边各自的「此刻 R」比，低的先出。
                    let days = last.map_or(0.0, |l| (self.ctx.now - l) as f64 / 86_400_000.0);
                    let fsrs_r = 1.0 / (1.0 + days / (9.0 * s.unwrap_or(1.0)));
                    return Ok(Some(if fsrs_r < *ir { did } else { iid.clone() }));
                }
                (None, None) => {}
            }
        }
        if sum.new_count > 0 {
            let decks: Vec<&str> = sub.iter().copied().filter(|d| self.path_has_room(d, |c| c.new_remaining)).collect();
            let owner = self.ctx.tree.params_owner(self.root).map(|d| &d.view);
            let order = match owner.and_then(|v| v["no"].as_str()) {
                Some("position") => NEW_BY_POSITION,
                _ => NEW_BY_FREQUENCY,
            };
            if let Some(id) = self.first_new(&decks, order, exclude)? {
                return Ok(Some(id));
            }
        }
        Ok(learning.map(|(id, _)| id))
    }
}

/// 请求里的「此刻」与日界。
fn when(req: &Value) -> Result<(i64, Day), String> {
    let now = req.get("now").and_then(Value::as_i64).ok_or("study: missing now")?;
    let day = Day {
        utc_offset_min: req.get("utcOff").and_then(Value::as_i64).ok_or("study: missing utcOff")?,
        rollover_hour: req.get("rollover").and_then(Value::as_i64).ok_or("study: missing rollover")?,
    };
    Ok((now, day))
}

/// 一次排队（见文件头）。[c] 是一个读快照（或写连接上的同一个事务：作答落库后接着算）；[uncommitted] = [c] 是
/// 写连接上还没结束的事务（会话连未提交的改动一起重读，store/queue.rs）。
pub(crate) fn study(c: &Connection, hub: &StudyHub, uncommitted: bool, profile: &str, req: &Value) -> Result<Value, String> {
    let (now, day) = when(req)?;
    hub.with_session(c, profile, day, day.index(now), uncommitted, |s| run(c, &SessionSource(s), profile, req))
}

/// 排队本身：数据从 [src] 取（会话，或测试基准）。
fn run(c: &Connection, src: &dyn Source, profile: &str, req: &Value) -> Result<Value, String> {
    let (now, day) = when(req)?;
    let ctx = Ctx { tree: DeckTree::load(c, profile)?, day, now, today: day.index(now), logs: src.logs() };
    let root = req.get("deck").and_then(Value::as_str);
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
    let scope: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let mut t: HashMap<String, Tally> =
        src.tallies(now, root.map(|_| ids.as_slice()))?.into_iter().map(|(k, v)| (k, Tally::of(v))).collect();

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
                    target: s.get(0).and_then(Value::as_f64).ok_or("study: bad rwkv deck")?,
                    min_reviews: n(1),
                    repeat_reviews: n(2),
                    repeat_seconds: n(3),
                },
            );
        }
        for x in rw["cands"].as_array().into_iter().flatten() {
            let (Some(id), Some(deck), Some(r)) = (x[0].as_str(), x[1].as_str(), x[3].as_f64()) else {
                return Err("study: bad rwkv candidate".into());
            };
            cands.push((id.to_owned(), deck.to_owned(), x[2].as_i64(), r));
        }
    }
    let mut lookup: HashSet<String> = ctx.logs.introduced_cards().chain(ctx.logs.reviewed_cards()).cloned().collect();
    if rwkv.is_some() {
        lookup.extend(ctx.logs.answers().map(|(id, _)| id.clone()));
    }
    let found = src.decks_of(&lookup)?;
    let eligible = if rwkv.is_some() { instant_eligible(&ctx, &scope, &instant, &cands, &found) } else { Vec::new() };
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
        }
    }
    let counts = count_tree(&ctx, &t, &ids, root);
    let (mut next, mut after) = (None, None);
    if let (Some(r), true) = (root, req["pick"] == Value::Bool(true)) {
        let exclude: Vec<String> = req["exclude"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect();
        let picker = Picker {
            c,
            src,
            profile,
            ctx: &ctx,
            root: r,
            sub: &ids,
            counts: &counts,
            instant_decks: instant.keys().map(String::as_str).collect(),
            eligible: &eligible,
        };
        let mut ex: Vec<&str> = exclude.iter().map(String::as_str).collect();
        next = picker.next(&ex)?;
        if let Some(n) = &next {
            ex.push(n);
            after = picker.next(&ex)?;
        }
    }
    let counts_json: serde_json::Map<String, Value> = counts
        .iter()
        .map(|(id, k)| {
            (
                id.clone(),
                json!([k.new_count, k.learn_count, k.review_count, k.sub.total, k.budget.limit, k.budget.allowed, k.budget.review_budget, k.budget.reason]),
            )
        })
        .collect();
    Ok(json!({
        "counts": counts_json,
        "next": next,
        "after": after,
        "eligible": eligible.iter().map(|(id, _, _)| id.clone()).collect::<Vec<_>>(),
    }))
}

impl crate::store::SrsCore {
    /// 只读排队（牌组列表 / 复习页的计数与出卡）：走读连接的快照，不排在同步投递 / 缓存刷新这类长写后面
    /// （Drift 事务开着时照旧在写连接上，看得见未提交的行）。
    pub fn study(&self, profile: &str, req: &Value) -> Result<Value, String> {
        self.read_visible_tx(|c, uncommitted| study(c, &self.study_hub, uncommitted, profile, req))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::queue::{LOGS_SQL, ROW_COLUMNS};
    use crate::store::SrsCore;
    use std::sync::atomic::Ordering as AtomicOrdering;

    /// 与 Dart `srsComputeNewCardBudget` 的几个边界逐项一致（fushi_srs test/new_card_budget_test.dart 同组数）。
    #[test]
    fn budget_matches_dart_rules() {
        // 数据不足（有复习的天 < 7）：预算 = 上限 × 10。
        assert_eq!(new_card_budget(20, 150, &[5; 3]), Budget { limit: 20, allowed: 20, review_budget: 200, reason: None });
        // 超 2 倍预算：暂停。
        assert_eq!(new_card_budget(20, 401, &[0; 30]).reason, Some("paused"));
        assert_eq!(new_card_budget(20, 401, &[0; 30]).allowed, 0);
        // 预算到 2 倍之间线性缩减：300 / 200 → 系数 0.5。
        assert_eq!(new_card_budget(20, 300, &[0; 30]), Budget { limit: 20, allowed: 10, review_budget: 200, reason: Some("reduced") });
        // 日均 100（30 天都有复习）× 1.5 = 150 < 地板 200。
        assert_eq!(new_card_budget(20, 0, &[100; 30]).review_budget, 200);
        // 日均 333 × 1.5 = 499.5 → 四舍五入 500（Dart `round` 远离零）。
        assert_eq!(new_card_budget(20, 0, &[333; 30]).review_budget, 500);
        // 上限 0：预算 0 → 不缩减分支。
        assert_eq!(new_card_budget(0, 10, &[0; 30]), Budget { limit: 0, allowed: 0, review_budget: 0, reason: None });
    }

    /// L2 的逐条 SQL 排队（2026-10-29 搬进常驻会话之前的生产实现，原样保留）：会话实现的对拍基准。每次排队按子树
    /// 聚合计数、顺着到期索引有界排序取最低、日志整段扫。
    mod oracle {
        use super::super::*;

        pub(super) const LEARNING_WHERE: &str = "queue IN ('learning', 'relearning') AND COALESCE(due_at, 0) <= ?";
        pub(super) const LEARNING_ORDER: &str = "COALESCE(due_at, 0), id";

        pub(super) fn tallies_sql(decks: Option<usize>) -> String {
            let deck_sql = decks.map_or(String::new(), |n| format!(" AND deck_id IN ({})", marks(n)));
            format!(
                "SELECT deck_id, COUNT(*), \
                 SUM(CASE WHEN {LIVE} AND queue NOT IN ('learning', 'relearning', 'review') THEN 1 ELSE 0 END), \
                 SUM(CASE WHEN {LIVE} AND queue IN ('learning', 'relearning') AND COALESCE(due_at, 0) <= ? THEN 1 ELSE 0 END), \
                 SUM(CASE WHEN {LIVE} AND queue = 'review' AND COALESCE(due_day, 0) <= ? THEN 1 ELSE 0 END) \
                 FROM srs_cards_cache WHERE profile_uid = ? AND hidden = 0{deck_sql} GROUP BY deck_id"
            )
        }

        pub(super) fn due_sql(decks: usize, exclude: usize) -> String {
            let not_in = if exclude == 0 { String::new() } else { format!(" AND id NOT IN ({})", marks(exclude)) };
            format!(
                "SELECT id, last_reviewed_at, stability FROM srs_cards_cache WHERE profile_uid = ? AND {LIVE} \
                 AND deck_id IN ({}) AND queue = 'review' AND COALESCE(due_day, 0) <= ?{not_in} \
                 ORDER BY 1.0 / (1.0 + (CASE WHEN last_reviewed_at IS NULL THEN 0.0 ELSE (? - last_reviewed_at) / 86400000.0 END) \
                 / (9.0 * COALESCE(stability, 1.0))), id LIMIT 2",
                marks(decks),
            )
        }

        pub(super) struct SqlSource<'a> {
            pub c: &'a Connection,
            pub profile: &'a str,
            pub today: i64,
            pub logs: LogState,
        }

        impl Source for SqlSource<'_> {
            fn logs(&self) -> &LogState {
                &self.logs
            }

            fn tallies(&self, now: i64, decks: Option<&[String]>) -> Result<HashMap<String, DeckRaw>, String> {
                let sql_text = tallies_sql(decks.map(<[String]>::len));
                let mut args: Vec<Sql> = vec![
                    Sql::Integer(self.today),
                    Sql::Integer(self.today),
                    Sql::Integer(now + LEARN_AHEAD_MS),
                    Sql::Integer(self.today),
                    Sql::Integer(self.today),
                    Sql::Text(self.profile.to_owned()),
                ];
                for d in decks.unwrap_or(&[]) {
                    args.push(Sql::Text(d.clone()));
                }
                let mut stmt = self.c.prepare(&sql_text).map_err(sql)?;
                let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
                let mut out = HashMap::new();
                while let Some(r) = q.next().map_err(sql)? {
                    out.insert(
                        r.get::<_, String>(0).map_err(sql)?,
                        DeckRaw { total: r.get(1).map_err(sql)?, new_avail: r.get(2).map_err(sql)?, learn: r.get(3).map_err(sql)?, due: r.get(4).map_err(sql)? },
                    );
                }
                Ok(out)
            }

            fn decks_of(&self, ids: &HashSet<String>) -> Result<HashMap<String, (String, bool)>, String> {
                let all: Vec<&String> = ids.iter().collect();
                let mut out = HashMap::new();
                for chunk in all.chunks(400) {
                    let sql_text = format!("SELECT id, deck_id, hidden FROM srs_cards_cache WHERE id IN ({}) AND +profile_uid = ?", marks(chunk.len()));
                    let mut stmt = self.c.prepare(&sql_text).map_err(sql)?;
                    let mut args: Vec<Sql> = chunk.iter().map(|s| Sql::Text((*s).clone())).collect();
                    args.push(Sql::Text(self.profile.to_owned()));
                    let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
                    while let Some(r) = q.next().map_err(sql)? {
                        out.insert(r.get::<_, String>(0).map_err(sql)?, (r.get::<_, String>(1).map_err(sql)?, r.get::<_, bool>(2).map_err(sql)?));
                    }
                }
                Ok(out)
            }

            fn first_learning(&self, decks: &[&str], limit: i64, exclude: &[&str]) -> Result<Option<(String, Option<i64>)>, String> {
                if decks.is_empty() {
                    return Ok(None);
                }
                let sql_text = first_sql(decks.len(), LEARNING_WHERE, LEARNING_ORDER, exclude.len());
                let mut args: Vec<Sql> = vec![Sql::Text(self.profile.to_owned()), Sql::Integer(self.today)];
                args.extend(decks.iter().map(|d| Sql::Text((*d).to_owned())));
                args.push(Sql::Integer(limit));
                args.extend(exclude.iter().map(|d| Sql::Text((*d).to_owned())));
                let mut stmt = self.c.prepare(&sql_text).map_err(sql)?;
                let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
                match q.next().map_err(sql)? {
                    Some(r) => Ok(Some((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?))),
                    None => Ok(None),
                }
            }

            fn lowest_due(&self, decks: &[&str], now: i64, exclude: &HashSet<&str>) -> Result<Option<DueCand>, String> {
                let ex: Vec<&str> = exclude.iter().copied().collect();
                let sql_text = due_sql(decks.len(), ex.len());
                let mut args: Vec<Sql> = vec![Sql::Text(self.profile.to_owned()), Sql::Integer(self.today)];
                args.extend(decks.iter().map(|d| Sql::Text((*d).to_owned())));
                args.push(Sql::Integer(self.today));
                args.extend(ex.iter().map(|d| Sql::Text((*d).to_owned())));
                args.push(Sql::Integer(now));
                let mut stmt = self.c.prepare(&sql_text).map_err(sql)?;
                let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
                match q.next().map_err(sql)? {
                    Some(r) => Ok(Some((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?, r.get(2).map_err(sql)?))),
                    None => Ok(None),
                }
            }
        }

        /// 用旧实现排一次（每次整段扫日志）。
        pub(super) fn study(c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
            let (now, day) = when(req)?;
            let today = day.index(now);
            let src = SqlSource { c, profile, today, logs: LogState::scan(c, profile, day, today)? };
            run(c, &src, profile, req)
        }
    }

    /// 排队仍在 SQL 里的查询走对应索引：新卡按索引序取第一张（无 TEMP B-TREE）、会话重建的日志区间扫描、
    /// 按 id 重读缓存行 / 日志走主键。
    #[test]
    fn queue_queries_use_their_indexes() {
        let mut c = rusqlite::Connection::open_in_memory().unwrap();
        crate::store::schema::migrate(&mut c).unwrap();
        let plan = |q: &str| -> String {
            let mut stmt = c.prepare(&format!("EXPLAIN QUERY PLAN {q}")).unwrap();
            let n = stmt.parameter_count();
            let rows: Vec<String> =
                stmt.query_map(params_from_iter(std::iter::repeat_n(Sql::Integer(0), n)), |r| r.get::<_, String>(3)).unwrap().map(Result::unwrap).collect();
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
                uses("new(freq)", &first_sql(decks, "queue = 'new'", NEW_BY_FREQUENCY, ex), "idx_srs_cards_cache_new_freq", true);
                uses("new(position)", &first_sql(decks, "queue = 'new'", NEW_BY_POSITION, ex), "idx_srs_cards_cache_new_position", true);
            }
        }
        uses("logs", LOGS_SQL, "idx_srs_review_logs_profile_kind_time", true);
        uses("logs by id", &crate::store::queue::logs_by_id_sql(2), "sqlite_autoindex_srs_review_log_rows_1", false);
        uses("rows by id", &format!("{ROW_COLUMNS} WHERE id IN (?, ?) AND +profile_uid = ?"), "sqlite_autoindex_srs_cards_cache_1", false);
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

    fn exec(core: &SrsCore, sql_text: &str, params: Vec<Sql>) {
        core.exec(sql_text, &params, false).unwrap_or_else(|e| panic!("{sql_text}: {e}"));
    }

    fn edit(core: &SrsCore, n: &mut i64, entity: &str, key: &str, v: Value) {
        *n += 1;
        let json = json!({"p": P, "k": "deck", "e": entity, "f": key, "w": "w", "s": *n, "v": v, "hlc": format!("{}:0:w", 1_700_000_000_000i64 + *n)}).to_string();
        exec(
            core,
            "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) VALUES (?, ?, 'deck', ?, ?, 'w', ?, ?)",
            vec![Sql::Text(format!("e{n}")), Sql::Text(P.into()), Sql::Text(entity.into()), Sql::Text(key.into()), Sql::Integer(*n), Sql::Text(json)],
        );
    }

    /// 一张随机卡（同一组稳定度 / 上次作答取值有限，制造 R 相等按 id 比的情形；含稳定度为零得 NULL、从没作答）。
    fn card_values(rng: &mut Rng, id: &str, today: i64, now: i64) -> Vec<Sql> {
        let deck = *rng.pick(&DECKS);
        let queue = *rng.pick(&["new", "new", "learning", "relearning", "review", "review", "review", "review"]);
        let opt = |rng: &mut Rng, v: i64| if rng.below(6) == 0 { Sql::Null } else { Sql::Integer(v) };
        let due_day = today - 3 + rng.below(6) as i64;
        let due_at = now - 30 * 60_000 + rng.below(4) as i64 * 15 * 60_000;
        let stab = match rng.below(8) {
            0 => Sql::Null,
            1 => Sql::Real(0.0),
            n => Sql::Real([0.5, 1.0, 2.5, 10.0, 40.0, 3.0][n as usize - 2]),
        };
        let last = now - [1, 2, 3, 5, 8, 13][rng.below(6) as usize] * 86_400_000 - [0, 3 * H][rng.below(2) as usize];
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
            Sql::Text(if rng.below(20) == 0 { "anki".into() } else { "fushi".into() }),
            Sql::Integer(rng.below(50) as i64),
            if rng.below(3) == 0 { Sql::Null } else { Sql::Integer(rng.below(40) as i64) },
            if rng.below(3) == 0 { Sql::Null } else { Sql::Integer(rng.below(40) as i64) },
        ]
    }

    const CARD_UPSERT: &str = "INSERT OR REPLACE INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, suspended, buried_until_day, \
         hidden, queue, due_day, due_at, stability, last_reviewed_at, scheduler, note_created_at, new_position, freq_rank) \
         VALUES (?1, ?2, ?1, 't', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)";

    fn log(core: &SrsCore, n: &mut i64, card: &str, at: i64, ty: &str, reps: i64, kind: &str) {
        *n += 1;
        exec(
            core,
            "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, json) VALUES (?, ?, ?, ?, 3, ?, ?, 'local', ?)",
            vec![
                Sql::Text(format!("l{n}")),
                Sql::Text(P.into()),
                Sql::Text(card.into()),
                Sql::Text(kind.into()),
                Sql::Integer(at),
                Sql::Text(ty.into()),
                Sql::Text(json!({"res": {"reps": reps}}).to_string()),
            ],
        );
    }

    /// 比一轮：几个根（含全部牌组）、带 / 不带排除、偶尔带 RWKV 候选；会话结果与旧实现逐项相同。
    /// 返回出了几张非空的「下一张 / 再下一张」（测试自检：对拍不是一直在比空结果）。
    fn compare(core: &SrsCore, rng: &mut Rng, now: i64, day: Day, cards: &[String], step: usize) -> usize {
        let mut picked = 0;
        for root in [None, Some("R"), Some("RA"), Some("RB"), Some("O"), Some("missing")] {
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
                    .map(|_| json!([rng.pick(cards), "O", if rng.below(2) == 0 { Value::Null } else { json!(now - 2 * H) }, rng.below(100) as f64 / 100.0]))
                    .collect();
                req["rwkv"] = json!({"decks": {"O": [0.7, 2, 1, 60]}, "cands": cands});
            }
            let got = core.study(P, &req).unwrap();
            let want = core.read_visible(|c| oracle::study(c, P, &req)).unwrap();
            assert_eq!(got, want, "step {step} root {root:?} req {req}");
            picked += usize::from(!got["next"].is_null()) + usize::from(!got["after"].is_null());
        }
        picked
    }

    /// 常驻会话与旧的逐条 SQL 排队逐步对拍：随机改卡（换队列 / 到期 / 暂停 / 埋 / 隐藏 / 挪牌组 / 稳定度）、加删卡、
    /// 加删日志、改每日上限与新卡顺序、此刻前进（跨日、换翻日时刻 / UTC 偏移）、Drift 式事务里写（事务内排队看得见
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
            exec(&core, "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES (?, ?, 'deck', '{}')", vec![Sql::Text(d.into()), Sql::Text(P.into())]);
        }
        for (d, parent) in [("RA", "R"), ("RA1", "RA"), ("RB", "R")] {
            edit(&core, &mut n, d, "parent", json!(parent));
        }
        for (d, new, review) in [("R", 6, 9), ("RA", 3, 4), ("RA1", 50, 50), ("RB", 20, 2), ("O", 4, 5), ("Z", 5, 5)] {
            edit(&core, &mut n, d, "limits", json!({"new": new, "review": review}));
        }
        let mut day = Day { utc_offset_min: 0, rollover_hour: 4 };
        let mut now = 1_760_000_000_000i64;
        let mut cards: Vec<String> = Vec::new();
        for i in 0..400 {
            let id = format!("c{i:04}");
            exec(&core, CARD_UPSERT, card_values(&mut rng, &id, day.index(now), now));
            cards.push(id);
        }
        for _ in 0..300 {
            let card = rng.pick(&cards).clone();
            let at = now - rng.below(40) as i64 * 86_400_000 / 2 - rng.below(5) as i64 * H;
            log(&core, &mut logs, &card, at, *rng.pick(&["review", "learn", "relearn"]), 1 + rng.below(2) as i64, "review");
        }
        let mut builds_seen = 0;
        let mut picked = 0;
        let mut tx_depth = 0;
        for step in 0..700 {
            let today = day.index(now);
            let mut new_day = false;
            match rng.below(100) {
                0..=29 => {
                    let id = rng.pick(&cards).clone();
                    exec(&core, CARD_UPSERT, card_values(&mut rng, &id, today, now));
                }
                30..=37 => {
                    // 只改一两列（UPDATE 触发器）。
                    let id = rng.pick(&cards).clone();
                    let (col, v) = match rng.below(5) {
                        0 => ("suspended", Sql::Integer(rng.below(2) as i64)),
                        1 => ("buried_until_day", Sql::Integer(today + rng.below(2) as i64)),
                        2 => ("deck_id", Sql::Text((*rng.pick(&DECKS)).into())),
                        3 => ("hidden", Sql::Integer(rng.below(2) as i64)),
                        _ => ("stability", Sql::Real(rng.below(30) as f64 + 0.5)),
                    };
                    exec(&core, &format!("UPDATE srs_cards_cache SET {col} = ? WHERE id = ?"), vec![v, Sql::Text(id)]);
                }
                38..=42 => {
                    let id = format!("c{:04}", cards.len());
                    exec(&core, CARD_UPSERT, card_values(&mut rng, &id, today, now));
                    cards.push(id);
                }
                43..=45 => {
                    let id = rng.pick(&cards).clone();
                    exec(&core, "DELETE FROM srs_cards_cache WHERE id = ?", vec![Sql::Text(id)]);
                }
                46..=60 => {
                    // 作答：今天的日志（第一次学 / 复习），偶尔是别的种类或很久以前的。
                    let card = rng.pick(&cards).clone();
                    let at = now - rng.below(3) as i64 * 60_000 - if rng.below(8) == 0 { 40 * 86_400_000 } else { 0 };
                    let kind = if rng.below(10) == 0 { "manual" } else { "review" };
                    log(&core, &mut logs, &card, at, *rng.pick(&["review", "learn", "relearn"]), 1 + rng.below(2) as i64, kind);
                }
                61..=63 => {
                    let id = format!("l{}", 1 + rng.below(logs as u64));
                    exec(&core, "DELETE FROM srs_review_logs WHERE id = ?", vec![Sql::Text(id)]);
                }
                64..=66 => {
                    let d = *rng.pick(&DECKS);
                    edit(&core, &mut n, d, "limits", json!({"new": rng.below(8), "review": rng.below(12)}));
                }
                67 => {
                    edit(&core, &mut n, "R", "newOrder", json!(*rng.pick(&["position", "frequency"])));
                }
                68..=84 => now += rng.below(90) as i64 * 60_000,
                85..=87 => {
                    now += 20 * H + rng.below(10) as i64 * H;
                    new_day = true;
                }
                88 => {
                    day = Day { utc_offset_min: *rng.pick(&[0, 540, -300]), rollover_hour: *rng.pick(&[0, 4]) };
                    new_day = true;
                }
                89..=94 if tx_depth == 0 => {
                    exec(&core, "BEGIN", vec![]);
                    tx_depth = 1;
                }
                89..=94 => {
                    exec(&core, *rng.pick(&["COMMIT", "ROLLBACK"]), vec![]);
                    tx_depth = 0;
                }
                95..=97 => {
                    // 一段写在 SAVEPOINT 里又回滚掉（Drift 嵌套事务失败）。
                    exec(&core, "SAVEPOINT t", vec![]);
                    let id = rng.pick(&cards).clone();
                    exec(&core, CARD_UPSERT, card_values(&mut rng, &id, today, now));
                    let card = rng.pick(&cards).clone();
                    log(&core, &mut logs, &card, now, "review", 2, "review");
                    picked += compare(&core, &mut rng, now, day, &cards, step);
                    exec(&core, "ROLLBACK TO t", vec![]);
                    exec(&core, "RELEASE t", vec![]);
                }
                _ if step % 233 == 0 => {
                    // 一条语句写超过攒满阈值：下次排队整份重建。
                    exec(
                        &core,
                        "WITH RECURSIVE k(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM k WHERE i < ?) \
                         INSERT OR REPLACE INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, queue, due_day, stability, last_reviewed_at) \
                         SELECT printf('bulk%05d', i), ?, 'n', 't', 'Z', 'review', ?, 1.0 + (i % 7), ? - (i % 11) * 86400000 FROM k",
                        vec![Sql::Integer(crate::store::queue::DIRTY_CAP as i64 + 10), Sql::Text(P.into()), Sql::Integer(today), Sql::Integer(now)],
                    );
                    new_day = true;
                }
                _ => {}
            }
            let before = core.study_hub.builds.load(AtomicOrdering::SeqCst);
            picked += compare(&core, &mut rng, now, day, &cards, step);
            let built = core.study_hub.builds.load(AtomicOrdering::SeqCst) - before;
            if !new_day && step > 0 && day.index(now) == today {
                assert_eq!(built, 0, "step {step}: no rebuild within a day");
            }
            builds_seen += built;
        }
        if tx_depth > 0 {
            exec(&core, "ROLLBACK", vec![]);
        }
        assert!(builds_seen < 60, "rebuilt {builds_seen} times");
        // 700 步 × 6 个根：大多数轮次真的出了卡（不是一直在比空结果）。
        assert!(picked > 3000, "picked {picked}");
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
        exec(&core, "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES ('O', ?, 'deck', '{}')", vec![Sql::Text(P.into())]);
        for (id, stab) in [("weak", 0.5), ("strong", 90.0)] {
            exec(
                &core,
                "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, queue, due_day, stability, last_reviewed_at) VALUES (?, ?, 'n', 't', 'O', 'review', 0, ?, ?)",
                vec![Sql::Text(id.into()), Sql::Text(P.into()), Sql::Real(stab), Sql::Integer(now - 10 * 86_400_000)],
            );
        }
        let day = Day { utc_offset_min: 0, rollover_hour: 0 };
        let lowest = |core: &SrsCore| -> Option<String> {
            // 直接在读连接的快照上排（不经 read_visible：写锁此刻被测试持着也照样走读连接）。
            let r = core.reader().unwrap();
            r.execute_batch("BEGIN").unwrap();
            let got = core.study_hub.with_session(&r, P, day, day.index(now), false, |s| Ok(s.lowest_due(&["O"], now, &HashSet::new()).map(|c| c.0))).unwrap();
            r.execute_batch("ROLLBACK").unwrap();
            got
        };
        assert_eq!(lowest(&core).as_deref(), Some("weak"));
        {
            // 写连接上自动提交一条删除：COMMIT 已对读连接可见，守卫还没释放（没 settle）。
            let w = core.writer().unwrap();
            w.execute("DELETE FROM srs_cards_cache WHERE id = 'weak'", []).unwrap();
            assert!(w.is_autocommit());
            assert_eq!(lowest(&core).as_deref(), Some("strong"), "the committed delete is visible and must be reread");
            // 未提交的改动：读快照重读到的是旧值（与快照一致），也不清掉——提交后再按终态重读。
            w.execute_batch("BEGIN; UPDATE srs_cards_cache SET stability = 0.1 WHERE id = 'strong';").unwrap();
            assert_eq!(lowest(&core).as_deref(), Some("strong"));
            w.execute_batch("INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, queue, due_day, stability, last_reviewed_at) \
                             VALUES ('weaker', 'p', 'n', 't', 'O', 'review', 0, 0.01, 0); COMMIT;").unwrap();
            assert_eq!(lowest(&core).as_deref(), Some("weaker"), "rows committed after an earlier reread are reread again");
        }
        assert_eq!(lowest(&core).as_deref(), Some("weaker"));
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
        exec(&core, "INSERT INTO srs_entities (id, profile_uid, kind, payload_json) VALUES ('O', ?, 'deck', '{}')", vec![Sql::Text(P.into())]);
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
                "INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, deck_id, queue, due_day, stability, last_reviewed_at) VALUES (?, ?, 'n', 't', 'O', 'review', 0, ?, ?)",
                vec![Sql::Text(id.clone()), Sql::Text(P.into()), stab.map_or(Sql::Null, Sql::Real), last.map_or(Sql::Null, Sql::Integer)],
            );
            want.push((crate::store::queue::sql_r(now, last, stab), id));
            let _ = i;
        }
        // 按 SQL 的 ORDER BY 取全序（库里排，不信 Rust 的比较）。
        let order: Vec<String> = core
            .read_visible(|c| {
                let mut stmt = c
                    .prepare(
                        "SELECT id FROM srs_cards_cache ORDER BY 1.0 / (1.0 + (CASE WHEN last_reviewed_at IS NULL THEN 0.0 ELSE (? - last_reviewed_at) / 86400000.0 END) \
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
                    core.study_hub.with_session(c, P, Day { utc_offset_min: 0, rollover_hour: 0 }, Day { utc_offset_min: 0, rollover_hour: 0 }.index(now), false, |s| {
                        let exs: HashSet<&str> = ex.iter().map(String::as_str).collect();
                        Ok(s.lowest_due(&["O"], now, &exs).map(|c| c.0))
                    })
                })
                .unwrap();
            assert_eq!(got.as_deref(), Some(expected.as_str()), "after excluding {} cards (req {req})", ex.len());
            // 一半排除、一半真删（删走增量路径）。
            if ex.len() % 2 == 0 {
                ex.push(expected.clone());
            } else {
                exec(&core, "DELETE FROM srs_cards_cache WHERE id = ?", vec![Sql::Text(expected.clone())]);
            }
        }
        core.close();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
