//! 复习排队：牌组计数（新 / 学习 / 到期，含每日上限与子树截断）与出卡（下一张、排除它之后的再下一张）。
//!
//! 以前在 Dart（`SrsDbStore._countContext` / `_deckTallies` / `_countTree` / `nextCard` 的 SQL `pick`）：评一张卡
//! 要把计数上下文（牌组树、30 天日志、今天日志、按牌组聚合）整份重建三遍（出下一张、补计数、预取再下一张），
//! 每遍十来次跨 isolate 的 Drift 往返；复习卡按「此刻的可提取度」排序，SQL 只能对全部到期卡建临时 B 树排序。
//! 现在一次命令在一个读快照里算完：
//!
//! - 计数上下文只建一份：牌组树、最近 30 天每天的复习数与今天的作答（同一次日志区间扫描）；
//! - 每个牌组自己的计数原料走覆盖索引 `idx_srs_cards_cache_tally` 按牌组聚合（schema.rs `V9`）；
//! - 牌组树计数对齐 Anki v3 的 limit tree（见 [count_tree]），口径与旧 Dart 逐项相同
//!   （fushi_engine test/srs/srs_study_vectors_test.dart 用旧实现生成的向量钉住）；
//! - 出卡：学习卡 / 新卡仍是一条走索引序的 `LIMIT 1`；复习卡在 Rust 里顺着到期索引扫候选、边扫边留可提取度
//!   最低的一张（top-1），不排序全集；
//! - RWKV-Instant 的牌组：分数由 Dart 侧的 RWKV 服务给（另一个原生库），这里只做排队规则（目标保留率、同日
//!   间隔守卫、每天最少复习数、按 R 升序），与旧 Dart `_instantReviews` 同口径。
//!
//! 请求 `{"deck"?: 根牌组, "now", "utcOff", "rollover", "exclude"?: [卡], "pick"?: bool,
//!        "rwkv"?: {"decks": {牌组: [目标保留率, 每天最少, 间隔次数, 间隔秒数]}, "cands": [[卡, 牌组, 上次作答|null, R]]}}`；
//! 结果 `{"counts": {牌组: [新, 学习, 到期, 总数, 新卡上限, 新卡配额, 复习预算, 缩减原因|null]}, "next", "after", "eligible"}`。
//! 没给 `deck` = 全部牌组（牌组列表）；给了但不在树里 = `counts` 为 null。

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

use rusqlite::{params_from_iter, types::Value as Sql, Connection};
use serde_json::{json, Value};

use crate::projection::Day;
use crate::store::sync2::config::DeckTree;
use crate::store::sync2::sql;

/// 卡「可出」：可见、未暂停、归 Fushi 排程、没埋或埋到期（绑定一个参数：今天）。
const LIVE: &str = "hidden = 0 AND suspended = 0 AND scheduler = 'fushi' AND (buried_until_day IS NULL OR buried_until_day <= ?)";
const DAY_MS: i64 = 86_400_000;
/// 学习卡的「快到期」窗口：20 分钟内到期的学习卡算进学习数（Anki 的 learn ahead）。
const LEARN_AHEAD_MS: i64 = 20 * 60_000;
/// SQLite 变量上限内的 IN 列表分块。
const CHUNK: usize = 400;

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

struct Ctx {
    tree: DeckTree,
    day: Day,
    now: i64,
    today: i64,
    last30: Vec<i64>,
    introduced: HashSet<String>,
    reviewed: HashSet<String>,
    /// 今天的全部作答（卡, 时刻）。
    answers: Vec<(String, i64)>,
}

impl Ctx {
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

/// 计数上下文：牌组树、「今天」、最近 30 天每天的复习数、今天已学的新卡 / 已复习的卡 / 全部作答。
/// 30 天的计数与今天的作答是同一次日志区间扫描（`idx_srs_review_logs_profile_kind_time`，卡 / 类型列在索引里，
/// 正文 JSON 只在今天的学习步那几行回表：判断是不是第一次学）。
fn context(c: &Connection, profile: &str, now: i64, day: Day) -> Result<Ctx, String> {
    let tree = DeckTree::load(c, profile)?;
    let today = day.index(now);
    let mut ctx = Ctx {
        tree,
        day,
        now,
        today,
        last30: vec![0; 30],
        introduced: HashSet::new(),
        reviewed: HashSet::new(),
        answers: Vec::new(),
    };
    let from = ctx.day_start(today - 29);
    let today_start = ctx.day_start(today);
    let mut stmt = c.prepare_cached(LOGS_SQL).map_err(sql)?;
    let mut q = stmt.query(rusqlite::params![profile, from, today_start]).map_err(sql)?;
    while let Some(r) = q.next().map_err(sql)? {
        let at: i64 = r.get(1).map_err(sql)?;
        let d = ctx.day.index(at);
        let slot = d - (today - 29);
        if (0..30).contains(&slot) {
            ctx.last30[slot as usize] += 1;
        }
        if at < today_start {
            continue;
        }
        let card: String = r.get(0).map_err(sql)?;
        let ty: String = r.get(2).map_err(sql)?;
        if ty == "review" {
            ctx.reviewed.insert(card.clone());
        }
        if let Some(j) = r.get::<_, Option<String>>(3).map_err(sql)? {
            let v: Value = serde_json::from_str(&j).unwrap_or(Value::Null);
            if v["res"]["reps"].as_f64() == Some(1.0) {
                ctx.introduced.insert(card.clone());
            }
        }
        ctx.answers.push((card, at));
    }
    Ok(ctx)
}

/// 最近 30 天的复习日志（参数：profile, 30 天前的日界, 今天的日界）。
const LOGS_SQL: &str = "SELECT card_id, occurred_at, review_type, \
     CASE WHEN review_type = 'learn' AND occurred_at >= ?3 THEN json END \
     FROM srs_review_logs WHERE profile_uid = ?1 AND kind = 'review' AND occurred_at >= ?2 \
     ORDER BY occurred_at";

/// 按牌组聚合的计数原料；[decks] = `deck_id IN` 的个数（None = 不限牌组）。
fn tallies_sql(decks: Option<usize>) -> String {
    let deck_sql = decks.map_or(String::new(), |n| format!(" AND deck_id IN ({})", marks(n)));
    format!(
        "SELECT deck_id, COUNT(*), \
         SUM(CASE WHEN {LIVE} AND queue NOT IN ('learning', 'relearning', 'review') THEN 1 ELSE 0 END), \
         SUM(CASE WHEN {LIVE} AND queue IN ('learning', 'relearning') AND COALESCE(due_at, 0) <= ? THEN 1 ELSE 0 END), \
         SUM(CASE WHEN {LIVE} AND queue = 'review' AND COALESCE(due_day, 0) <= ? THEN 1 ELSE 0 END) \
         FROM srs_cards_cache WHERE profile_uid = ? AND hidden = 0{deck_sql} GROUP BY deck_id"
    )
}

/// 学习卡 / 新卡的「按索引序取第一张」。
fn first_sql(decks: usize, condition: &str, order: &str, exclude: usize) -> String {
    let not_in = if exclude == 0 { String::new() } else { format!(" AND id NOT IN ({})", marks(exclude)) };
    format!(
        "SELECT id, due_at FROM srs_cards_cache WHERE profile_uid = ? AND {LIVE} AND deck_id IN ({}) AND {condition}{not_in} ORDER BY {order} LIMIT 1",
        marks(decks)
    )
}

/// 到期复习卡里可提取度最低的 [DUE_TOP] 张（参数：profile, 今天, 牌组…, 今天, 排除…, 此刻）。排序键是 FSRS 遗忘曲线
/// R = (1 + t/(9S))^-1（可提取度低的先出；与旧 Dart 排队同一条式子：除以零得 NULL，升序 NULL 在前）。`ORDER BY … LIMIT` 是 SQLite 的有界排序器（只留 LIMIT 行，
/// 不对全集排序），比逐行交给 Rust 再比快（行步进 + 取 id 文本）：十万张到期卡上一次排队中位 114 → 99 ms。
fn due_sql(decks: usize, exclude: usize) -> String {
    let not_in = if exclude == 0 { String::new() } else { format!(" AND id NOT IN ({})", marks(exclude)) };
    format!(
        "SELECT id, last_reviewed_at, stability FROM srs_cards_cache WHERE profile_uid = ? AND {LIVE} \
         AND deck_id IN ({}) AND queue = 'review' AND COALESCE(due_day, 0) <= ?{not_in} \
         ORDER BY 1.0 / (1.0 + (CASE WHEN last_reviewed_at IS NULL THEN 0.0 ELSE (? - last_reviewed_at) / 86400000.0 END) \
         / (9.0 * COALESCE(stability, 1.0))), id LIMIT {DUE_TOP}",
        marks(decks),
    )
}

const LEARNING_WHERE: &str = "queue IN ('learning', 'relearning') AND COALESCE(due_at, 0) <= ?";
const LEARNING_ORDER: &str = "COALESCE(due_at, 0), id";
const NEW_BY_POSITION: &str = "new_position IS NULL, new_position, note_created_at, id";
const NEW_BY_FREQUENCY: &str = "freq_rank IS NULL, freq_rank, new_position IS NULL, new_position, note_created_at, id";

fn marks(n: usize) -> String {
    vec!["?"; n].join(", ")
}

/// 每个牌组**自己**（不含子牌组）的计数原料，在 SQL 里按牌组聚合（覆盖索引，不回表）。[decks] 为 None 时不限牌组。
fn tallies(c: &Connection, profile: &str, ctx: &Ctx, decks: Option<&[String]>) -> Result<HashMap<String, Tally>, String> {
    let sql_text = tallies_sql(decks.map(<[String]>::len));
    let mut args: Vec<Sql> = vec![
        Sql::Integer(ctx.today),
        Sql::Integer(ctx.today),
        Sql::Integer(ctx.now + LEARN_AHEAD_MS),
        Sql::Integer(ctx.today),
        Sql::Integer(ctx.today),
        Sql::Text(profile.to_owned()),
    ];
    for d in decks.unwrap_or(&[]) {
        args.push(Sql::Text(d.clone()));
    }
    let mut stmt = c.prepare_cached(&sql_text).map_err(sql)?;
    let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
    let mut out = HashMap::new();
    while let Some(r) = q.next().map_err(sql)? {
        out.insert(
            r.get::<_, String>(0).map_err(sql)?,
            Tally {
                total: r.get(1).map_err(sql)?,
                new_avail: r.get(2).map_err(sql)?,
                learn: r.get(3).map_err(sql)?,
                due: r.get(4).map_err(sql)?,
                new_done: 0,
                review_done: 0,
            },
        );
    }
    Ok(out)
}

/// 一组卡所在的牌组与是否隐藏（今天作答过的卡，只有当天那几十上百张：按主键查）。`+profile_uid` 不让 SQLite
/// 改走 profile 前缀索引逐行回表。
fn decks_of(c: &Connection, profile: &str, ids: &HashSet<String>) -> Result<HashMap<String, (String, bool)>, String> {
    let all: Vec<&String> = ids.iter().collect();
    let mut out = HashMap::new();
    for chunk in all.chunks(CHUNK) {
        let sql_text = format!("SELECT id, deck_id, hidden FROM srs_cards_cache WHERE id IN ({}) AND +profile_uid = ?", marks(chunk.len()));
        let mut stmt = c.prepare_cached(&sql_text).map_err(sql)?;
        let mut args: Vec<Sql> = chunk.iter().map(|s| Sql::Text((*s).clone())).collect();
        args.push(Sql::Text(profile.to_owned()));
        let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
        while let Some(r) = q.next().map_err(sql)? {
            out.insert(r.get::<_, String>(0).map_err(sql)?, (r.get::<_, String>(1).map_err(sql)?, r.get::<_, bool>(2).map_err(sql)?));
        }
    }
    Ok(out)
}

/// RWKV-Instant 合格的复习卡（按 R 升序，同 R 按 id）。与旧 Dart `_instantReviews` 同口径：
/// - R ≤ 卡所在牌组的目标保留率才合格；
/// - 同日重复的间隔守卫：今天答过的卡，距上次作答不足 `repeat_seconds` 秒，或这之后 [scope] 里别的卡的作答不足
///   `repeat_reviews` 次 → 暂缓；
/// - 每天最少复习数：某牌组今天复习过的卡加上合格卡仍不到这个数时，从只因 R 高于目标被挡的卡里按 R 升序补足。
fn instant_eligible(
    ctx: &Ctx,
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
        for (other, at) in &ctx.answers {
            if *at > last && other != id && answered_deck.get(other).is_some_and(|(d, _)| scope.contains(d.as_str())) {
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
        for id in &ctx.reviewed {
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
fn count_tree(ctx: &Ctx, tallies: &HashMap<String, Tally>, ids: &[String], root: Option<&str>) -> HashMap<String, Count> {
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
        ctx: &Ctx,
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
        let budget = new_card_budget(int(view, "np", 20), sub.due, &ctx.last30);
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
    profile: &'a str,
    ctx: &'a Ctx,
    root: &'a str,
    sub: &'a [String],
    counts: &'a HashMap<String, Count>,
    instant_decks: HashSet<&'a str>,
    eligible: &'a [(String, String, f64)],
    /// 上一次扫到期复习卡留下的最低几张（按出卡序）与扫的牌组：「下一张」与「再下一张」共用一次扫描。
    due_top: RefCell<Option<(Vec<String>, Vec<DueCand>)>>,
}

/// 一张到期复习候选：(卡, 上次作答, 稳定度)。
type DueCand = (String, Option<i64>, Option<f64>);

/// 一次扫描留下的最低几张：够「下一张 + 再下一张」（后者只多排除前者）。
const DUE_TOP: usize = 2;


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

    /// 子树里一条「可出 + 条件」的候选，按 [order] 取第一张（走对应的部分索引，命中第一张即停）。
    fn first(&self, decks: &[&str], condition: &str, vars: Vec<Sql>, order: &str, exclude: &[&str]) -> Result<Option<(String, Option<i64>)>, String> {
        if decks.is_empty() {
            return Ok(None);
        }
        let sql_text = first_sql(decks.len(), condition, order, exclude.len());
        let mut args: Vec<Sql> = vec![Sql::Text(self.profile.to_owned()), Sql::Integer(self.ctx.today)];
        args.extend(decks.iter().map(|d| Sql::Text((*d).to_owned())));
        args.extend(vars);
        args.extend(exclude.iter().map(|d| Sql::Text((*d).to_owned())));
        let mut stmt = self.c.prepare_cached(&sql_text).map_err(sql)?;
        let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
        match q.next().map_err(sql)? {
            Some(r) => Ok(Some((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?))),
            None => Ok(None),
        }
    }

    /// 到期复习卡里可提取度最低的一张：顺着 `idx_srs_cards_cache_review_due`（牌组, 到期日）只扫到期候选，
    /// 在库里有界排序取最低的 [DUE_TOP] 张（[due_sql]），同一组牌组的下一次（「再下一张」，只多排除前一张）
    /// 直接从留下的里取，不再扫一遍。返回 (卡, 上次作答, 稳定度)。
    fn lowest_due(&self, decks: &[&str], exclude: &HashSet<&str>) -> Result<Option<(String, Option<i64>, Option<f64>)>, String> {
        if decks.is_empty() {
            return Ok(None);
        }
        if let Some((scanned, top)) = self.due_top.borrow().as_ref() {
            if scanned.iter().map(String::as_str).eq(decks.iter().copied()) {
                // 留下的都被排除了不代表没有别的卡：只有一张都没剩时才重扫。
                if let Some(c) = top.iter().find(|c| !exclude.contains(c.0.as_str())) {
                    return Ok(Some(c.clone()));
                }
                if top.len() < DUE_TOP {
                    return Ok(None);
                }
            }
        }
        let ex: Vec<&str> = exclude.iter().copied().collect();
        let sql_text = due_sql(decks.len(), ex.len());
        let mut args: Vec<Sql> = vec![Sql::Text(self.profile.to_owned()), Sql::Integer(self.ctx.today)];
        args.extend(decks.iter().map(|d| Sql::Text((*d).to_owned())));
        args.push(Sql::Integer(self.ctx.today));
        args.extend(ex.iter().map(|d| Sql::Text((*d).to_owned())));
        args.push(Sql::Integer(self.ctx.now));
        let mut stmt = self.c.prepare_cached(&sql_text).map_err(sql)?;
        let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
        let mut top: Vec<DueCand> = Vec::with_capacity(DUE_TOP);
        while let Some(r) = q.next().map_err(sql)? {
            top.push((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?, r.get(2).map_err(sql)?));
        }
        let best = top.first().cloned();
        *self.due_top.borrow_mut() = Some((decks.iter().map(|d| (*d).to_owned()).collect(), top));
        Ok(best)
    }

    /// 下一张：到期的学习卡 → 到期复习卡（可提取度从低到高；RWKV 牌组按 R）→ 新卡（所点牌组的新卡顺序）→
    /// 20 分钟内到期的学习卡。
    fn next(&self, exclude: &[&str]) -> Result<Option<String>, String> {
        let ex: HashSet<&str> = exclude.iter().copied().collect();
        let sub: Vec<&str> = self.sub.iter().map(String::as_str).collect();
        let learning = self.first(
            &sub,
            LEARNING_WHERE,
            vec![Sql::Integer(self.ctx.now + LEARN_AHEAD_MS)],
            LEARNING_ORDER,
            exclude,
        )?;
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
            let due = self.lowest_due(&fsrs_decks, &ex)?;
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
            if let Some((id, _)) = self.first(&decks, "queue = 'new'", Vec::new(), order, exclude)? {
                return Ok(Some(id));
            }
        }
        Ok(learning.map(|(id, _)| id))
    }
}

/// 一次排队（见文件头）。[c] 是一个读快照（或写连接上的同一个事务：作答落库后接着算）。
pub(crate) fn study(c: &Connection, profile: &str, req: &Value) -> Result<Value, String> {
    let now = req.get("now").and_then(Value::as_i64).ok_or("study: missing now")?;
    let day = Day {
        utc_offset_min: req.get("utcOff").and_then(Value::as_i64).ok_or("study: missing utcOff")?,
        rollover_hour: req.get("rollover").and_then(Value::as_i64).ok_or("study: missing rollover")?,
    };
    let ctx = context(c, profile, now, day)?;
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
    let mut t = tallies(c, profile, &ctx, root.map(|_| ids.as_slice()))?;

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
    let mut lookup: HashSet<String> = ctx.introduced.iter().chain(ctx.reviewed.iter()).cloned().collect();
    if rwkv.is_some() {
        lookup.extend(ctx.answers.iter().map(|(id, _)| id.clone()));
    }
    let found = decks_of(c, profile, &lookup)?;
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
        if ctx.introduced.contains(id) {
            x.new_done += 1;
        }
        if ctx.reviewed.contains(id) {
            x.review_done += 1;
        }
    }
    let counts = count_tree(&ctx, &t, &ids, root);
    let (mut next, mut after) = (None, None);
    if let (Some(r), true) = (root, req["pick"] == Value::Bool(true)) {
        let exclude: Vec<String> = req["exclude"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect();
        let picker = Picker {
            c,
            profile,
            ctx: &ctx,
            root: r,
            sub: &ids,
            counts: &counts,
            instant_decks: instant.keys().map(String::as_str).collect(),
            eligible: &eligible,
            due_top: RefCell::new(None),
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
        self.read_visible(|c| study(c, profile, req))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

    /// 排队的每条查询走上 v9 的索引（schema.rs `V9`）：学习卡 / 新卡按索引序取第一张、计数按牌组聚合、日志区间
    /// 扫描都不回表另排序（无 TEMP B-TREE）；复习候选顺着到期索引覆盖扫描，只在 LIMIT 行上有界排序。
    /// 单牌组与多牌组（`deck_id IN` 一个值 / 多个值）、带排除都看。
    #[test]
    fn queue_queries_use_the_v9_indexes() {
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
                uses("learning", &first_sql(decks, LEARNING_WHERE, LEARNING_ORDER, ex), "COVERING INDEX idx_srs_cards_cache_learning", true);
                uses("new(freq)", &first_sql(decks, "queue = 'new'", NEW_BY_FREQUENCY, ex), "idx_srs_cards_cache_new_freq", true);
                uses("new(position)", &first_sql(decks, "queue = 'new'", NEW_BY_POSITION, ex), "idx_srs_cards_cache_new_position", true);
                // 排序键随此刻变，没有索引能给出这个序：在覆盖索引的到期区间上有界排序（LIMIT，见 [due_sql]）。
                uses("review", &due_sql(decks, ex), "COVERING INDEX idx_srs_cards_cache_review_due", false);
            }
            uses("tally", &tallies_sql(Some(decks)), "COVERING INDEX idx_srs_cards_cache_tally", true);
        }
        uses("tally(all)", &tallies_sql(None), "COVERING INDEX idx_srs_cards_cache_tally", true);
        uses("logs", LOGS_SQL, "idx_srs_review_logs_profile_kind_time", true);
        assert!(wrong.is_empty(), "{}", wrong.join("\n\n"));
    }
}
