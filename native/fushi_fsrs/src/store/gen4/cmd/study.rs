//! 学习 / 出卡类读命令的新代实现（规划 §2.1 G7-4c）。**还没接分发器**：协议 3 的 `study`（`store/study.rs`，经
//! `store/ffi.rs` 的 `"study"` 与作答后顺带排队的两处）原地不动。
//!
//! # 命令清单
//!
//! 协议 3 里「出卡队列 / 牌组树计数 / 新卡挑选 / 学习会话」只有一条命令 **`study`**：牌组列表与复习页顶栏的计数
//! （新 / 学习 / 到期 / 总数、新卡上限与配额、复习预算、调整原因）、下一张与再下一张、RWKV-Instant 合格卡、自定义
//! 学习会话的出卡都在这一条里（请求与结果见 `store/study.rs` 文件头）。别的相邻读已在别处移植：`today_reviews` /
//! `review_grid`（`cmd/reads.rs`）、`stats_recall`（`cmd/stats.rs`）；`stats_release` 随统计原料缓存归命令层。
//!
//! # 一份排队规则
//!
//! 计数（Anki v3 limit tree）、新卡配额、出卡顺序、RWKV 规则、自定义学习都只在 `store/study.rs` 里写一次。这里只换
//! 「从哪读」：
//!
//! - **牌组树**：每个规范牌组的定义 + 按类判定活着的写入拼视图（`cmd::deck_tree`，写命令同一份），再走协议 3 的拼树
//!   规则；默认牌组取缓存配置（`cmd::default_deck`）。
//! - **卡**：缓存层 `cards` 表（列与 `srs_cards_cache` 相同），经 `study::SqlSource`（L2 的逐条 SQL 实现：协议 3 里是
//!   常驻会话的对拍基准）按 [G4Tables] 换表名、分区（`col`）、ID 列编码（[Ref]）。
//! - **日志**（最近 30 天每天的复习数、今天已学的新卡 / 已复习的卡 / 全部作答）：`log_ix` 按 `log_at (col, at)` 取窗口
//!   里的日志，每个规范日志 ID 一条代表（操作号最小的那份，`cmd::logs_between`，与 `cmd/reads.rs` 按时刻读日志共用），
//!   按 `kind = 'review'` 过滤，拼成协议 3 `LOGS_SQL` 的同几列交给 `LogState::fold`（计数规则同一份）。今天的学习步
//!   日志看 `res.reps`，取按血统重放写回的那份（`Index::replayed_card_logs`，与协议 3 落库的、`read` 的 `logs` 相同；
//!   按规范日志 ID 对上），一张卡重放一次。
//! - **自定义学习**：「会话里答过」= 会话开始之后有 `kind = 'review'` 日志的卡（同一套日志代表，归一到规范卡，整组编成
//!   一个 JSON 参数由 `json_each` 展开，[card_set]：不随卡数增加绑定变量）；「最近评过重来」读缓存层 `stats`（有效
//!   复习投影，主键 `(col, at, log)` 区间）；标签 / 出处读 `notes`。
//!
//! # 常驻会话与索引（取舍）
//!
//! 协议 3 生产路径是常驻会话（`store/queue.rs`：计数原料、到期候选、学习卡与今天的作答常驻内存，随写入按 id 增量
//! 重读，靠写连接上的临时触发器记脏）。会话是**命令层的状态**——要知道「写连接上改过哪些行」，那是分发器与写路径的事
//! ——与统计原料缓存一样留到接线（规划 §2.2 S1）由命令层持有；它的数据来源仍是这里同一套表（会话的增量重读按 id 点读
//! `cards` 主键）。这里每条命令在一个读快照里现读，代价与协议 3 的 L2 实现同阶，靠的是与协议 3 v9 逐列相同的部分索引
//! （schema 40015，`cache.rs`）：
//!
//! | 读 | 索引 |
//! |---|---|
//! | 新卡按位置 / 按词频取第一张 | `cards_new_position` / `cards_new_freq`（索引序，命中第一张即停，不排序） |
//! | 学习卡按到期取第一张 | `cards_learning` |
//! | 到期复习候选 | `cards_review_due`（按牌组、到期日区间） |
//! | 每个牌组的计数原料 | `cards_tally`（`hidden = 0` 的覆盖索引，按牌组聚合不回表） |
//! | 卡所在牌组（今天作答过的卡） | `cards` 主键 `(col, id)` |
//! | 最近 30 天日志 / 会话里作答过的卡 | `log_ix.log_at (col, at)` 区间 + 每条按主键读操作体 |
//! | 最近评过重来 | `stats` 主键 `(col, at, log)` 区间 |
//! | 只复习这一作 | `notes_source`（协议 3 v25） |
//!
//! 前五项的查询用 `INDEXED BY` 钉住各自的部分索引（`study::Tables::cards_via`）：新代库带手写的规划统计
//! （`schema.rs` `PLANNER_STATS`），实测规划器会把「新卡按索引序取第一张」改成「按 (牌组, 队列) 取出再排序」、把全部
//! 牌组的计数改走非覆盖的 `cards_deck`——统计只表达形状，分不出 `LIMIT 1` 沿索引序停在第一张的好处。协议 3 的同一批
//! 查询不加提示（SQL 文本不变）。
//!
//! 日志一项比协议 3 贵：协议 3 的日志行有 `kind` / `review_type` 列、覆盖索引不回表；新代 `log_ix` 不带种类，要解每条
//! 操作体（30 天的复习量，一天几百条时是几千次点读）。把种类并进 `log_ix` 会让索引层的逐条维护多一列、所有建
//! `log_ix` 的路径都要改，换来的只是接线前这条无状态路径的常数；接线后常驻会话只在建会话时扫一次、之后按 id 增量重读，
//! 与协议 3 同口径。
//!
//! 自定义学习的「会话里答过」同样逐条解操作体：会话开始（`since`）之后的全部日志，每个规范日志 ID 点读一次——协议 3 是
//! 一条覆盖索引上的子查询。会话开得越早越贵（N 条日志 = N 次点读 + 解码），没有上界；接线时由常驻会话的「今天的作答」
//! 承接（会话按 id 增量维护作答过的卡，不再按区间重扫），在那之前这条无状态路径只适合会话窗口不大的场景。
//!
//! # 与协议 3 的差别（D24「按规范 ID」）
//!
//! - 结果里的牌组、卡（`counts` 的键、`next` / `after` / `eligible`）是规范 ID。请求里的 ID（`deck`、`exclude`、
//!   `rwkv.decks` 的键、`rwkv.cands` 里的卡与牌组）先归一：`rwkv.decks` 同一个类的几个成员各给了设置时按
//!   `cmd::canon_keyed` 的规则取一份；`rwkv.cands` 同一张规范卡给了几次只留第一次。
//! - 一条日志在别名类里有几份（换代前同一次 Anki 复习的两份带盐导入）只算一次：计数上下文按规范日志 ID。
//! - 顺序契约（`cmd/mod.rs` 文件头）：出卡顺序全部由显式的排序键决定（`ORDER BY …, id`，`id` 的 SQLite 序与协议 3 的
//!   编码相同），计数结果是映射；没有依赖落库顺序的地方。

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use rusqlite::types::Value as Sql;
use serde_json::Value;

use super::{LogReps, deck_tree, default_deck, logs_between, ref_of, snapshot};
use crate::gen4::op::Log4;
use crate::projection::Day;
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::truth::Truth;
use crate::store::queue::LogState;
use crate::store::study::{self, CardIx, SqlSource, Tables};

/// `study`：集合 [col] 的一次排队（请求与结果同协议 3 `store/study.rs`，ID 是规范 ID）。在一个读快照里（[snapshot]）。
pub fn study(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let req = canon_req(&ix, req)?;
        let (now, day) = study::when(&req)?;
        let today = day.index(now);
        let default = default_deck(t, &ix, col)?;
        let tree = deck_tree(&mut ix, default)?;
        let logs = log_state(t, &mut ix, col, day, today)?;
        let tb = G4Tables { t, ix: &ix, col };
        let mut src = SqlSource {
            tb: &tb,
            today,
            logs,
        };
        study::run_with(&mut src, tree, &req)
    })
}

/// 请求里的 ID 归一成规范 ID（模块文件头「与协议 3 的差别」）。别的字段原样。
pub(crate) fn canon_req(ix: &Index<'_, '_>, req: &Value) -> Result<Value, String> {
    let canon = |s: &str| -> Result<String, String> { Ok(ix.canonical(&ref_of(s))?.text()) };
    let mut out = req.clone();
    let Some(obj) = out.as_object_mut() else {
        return Ok(out);
    };
    if let Some(Value::String(d)) = obj.get_mut("deck") {
        *d = canon(d)?;
    }
    if let Some(Value::Array(xs)) = obj.get_mut("exclude") {
        for x in xs.iter_mut() {
            if let Some(s) = x.as_str() {
                *x = Value::String(canon(s)?);
            }
        }
    }
    if let Some(Value::Object(rw)) = obj.get_mut("rwkv") {
        if let Some(Value::Object(m)) = rw.get_mut("decks") {
            *m = super::canon_keyed(ix, m)?;
        }
        if let Some(Value::Array(cands)) = rw.get_mut("cands") {
            let mut seen: HashSet<String> = HashSet::new();
            let mut kept = Vec::with_capacity(cands.len());
            for x in cands.drain(..) {
                let mut x = x;
                if let Some(row) = x.as_array_mut() {
                    for i in [0, 1] {
                        if let Some(s) = row.get(i).and_then(Value::as_str) {
                            let c = canon(s)?;
                            row[i] = Value::String(c);
                        }
                    }
                    if let Some(card) = row.first().and_then(Value::as_str) {
                        if !seen.insert(card.to_owned()) {
                            continue;
                        }
                    }
                }
                kept.push(x);
            }
            *cands = kept;
        }
    }
    Ok(out)
}

/// 发生时刻 ≥ [lo] 的 `kind = 'review'` 日志：规范日志 ID → (操作主键, 日志)。每个规范日志 ID 一条代表（[logs_between]，
/// 按时刻读日志的读命令同一份规则），再按种类过滤（协议 3 `LOGS_SQL` 的 `kind = 'review'`）。
fn review_logs(
    t: &Truth<'_>,
    ix: &Index<'_, '_>,
    col: i64,
    lo: i64,
) -> Result<BTreeMap<Ref, (i64, Log4)>, String> {
    let mut reps = LogReps::new();
    logs_between(t, ix, col, lo, None, &mut reps)?;
    Ok(reps
        .into_iter()
        .filter(|(_, (_, _, l))| l.kind == "review")
        .map(|(c, (_, k, l))| (c, (k, l)))
        .collect())
}

/// 排队的计数上下文里来自日志的部分（协议 3 `LogState::scan` 的新代版，计数规则同一份 `LogState::fold`）。
pub(super) fn log_state(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    col: i64,
    day: Day,
    today: i64,
) -> Result<LogState, String> {
    let (from, today_start) = LogState::window(day, today);
    let logs = review_logs(t, ix, col, from)?;
    // 今天的学习步日志要看重放写回的 `res`：按卡重放一次，取出这几条。
    let mut want: BTreeMap<Ref, BTreeSet<String>> = BTreeMap::new();
    for (id, (_, l)) in &logs {
        if l.rtype == "learn" && l.at >= today_start {
            let card = ix.canon(&ref_of(&l.card.text()))?;
            want.entry(card).or_default().insert(id.text());
        }
    }
    let mut replayed: HashMap<String, String> = HashMap::new();
    for (card, ids) in &want {
        for x in ix.replayed_card_logs(card)? {
            let id = serde_json::from_str::<Value>(&x.json)
                .ok()
                .and_then(|v| v.get("id").and_then(Value::as_str).map(str::to_owned));
            if let Some(id) = id.filter(|i| ids.contains(i)) {
                replayed.insert(id, x.json);
            }
        }
    }
    let mut s = LogState::empty();
    for (id, (k, l)) in logs {
        let id = id.text();
        let card = ix.canon(&ref_of(&l.card.text()))?.text();
        let learn_json = if l.rtype == "learn" && l.at >= today_start {
            Some(match replayed.remove(&id) {
                Some(j) => j,
                // 重放里没有（这条日志的代表不落在它自己那张卡的血统里）：取操作里的原值，与协议 3 没被重放过的行相同。
                None => ix.log_at(k)?.json,
            })
        } else {
            None
        };
        s.fold(
            id,
            card,
            l.at,
            &l.rtype,
            learn_json.as_deref(),
            Some(l.dur),
            day,
            today,
            today_start,
        );
    }
    Ok(s)
}

/// 新代缓存层的表（`cards` / `notes` / `stats`，按集合号分区、ID 列存 [Ref]）：`store/study.rs` 的 SQL 落在这里。
struct G4Tables<'a, 't, 'c> {
    t: &'a Truth<'c>,
    ix: &'a Index<'t, 'c>,
    col: i64,
}

/// 「`id` 在这组卡里」：对 `id` 列的条件与它的参数。整组卡编成**一个** JSON 数组参数（`u<十六进制>` = UUID 的 16
/// 字节、`t<文本>` = 文本 ID），由 `json_each` 展开——作答过的卡再多也只占一个绑定变量，不会撞 SQLite 的变量上限
/// （32766；逐卡绑 `?` 时一次自定义学习会话答过的卡超过它整条语句就报错）。
pub(super) fn card_set(cards: &BTreeSet<Ref>) -> (String, Vec<Sql>) {
    let list: Vec<Value> = cards
        .iter()
        .map(|r| {
            Value::String(match r {
                Ref::Uuid(b) => format!("u{}", super::hex(b)),
                Ref::Text(s) => format!("t{s}"),
            })
        })
        .collect();
    (
        "id IN (SELECT CASE substr(value, 1, 1) WHEN 'u' THEN unhex(substr(value, 2)) \
         ELSE substr(value, 2) END FROM json_each(?))"
            .to_owned(),
        vec![Sql::Text(Value::Array(list).to_string())],
    )
}

fn ref_sql(r: Ref) -> Sql {
    match r {
        Ref::Uuid(b) => Sql::Blob(b.to_vec()),
        Ref::Text(s) => Sql::Text(s),
    }
}

impl Tables for G4Tables<'_, '_, '_> {
    fn conn(&self) -> &rusqlite::Connection {
        self.t.conn()
    }

    fn cards(&self) -> &'static str {
        "cards"
    }

    /// 钉住部分索引（模块文件头「常驻会话与索引」）。
    fn cards_via(&self, ix: CardIx) -> String {
        format!("cards INDEXED BY cards_{}", ix.suffix())
    }

    fn notes(&self) -> &'static str {
        "notes"
    }

    fn scope(&self, alias: &str) -> String {
        format!("{alias}col = ?")
    }

    fn scope_by_id(&self) -> &'static str {
        "col = ?"
    }

    fn scope_arg(&self) -> Sql {
        Sql::Integer(self.col)
    }

    fn mark(&self) -> &'static str {
        "?"
    }

    fn id_sel(&self, col: &str) -> String {
        col.to_owned()
    }

    fn id_arg(&self, id: &str) -> Sql {
        ref_sql(ref_of(id))
    }

    fn id_get(&self, r: &rusqlite::Row<'_>, i: usize) -> rusqlite::Result<String> {
        Ok(r.get::<_, Ref>(i)?.text())
    }

    /// 会话开始之后有 `kind = 'review'` 日志的卡（规范卡，[review_logs] 同一套代表），见 [card_set]；没有 = 恒假。
    fn answered(&self, since: i64) -> Result<(String, Vec<Sql>), String> {
        let mut cards: BTreeSet<Ref> = BTreeSet::new();
        for (_, (_, l)) in review_logs(self.t, self.ix, self.col, since)? {
            cards.insert(self.ix.canon(&ref_of(&l.card.text()))?);
        }
        if cards.is_empty() {
            return Ok(("0".to_owned(), Vec::new()));
        }
        Ok(card_set(&cards))
    }

    fn forgotten(&self, from: i64) -> (String, Vec<Sql>) {
        (
            "id IN (SELECT card FROM stats WHERE col = ? AND rating = 1 AND at >= ?)".to_owned(),
            vec![Sql::Integer(self.col), Sql::Integer(from)],
        )
    }
}
