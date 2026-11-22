//! 学习 / 出卡类读命令的新代实现（规划 §2.1 G7-4c，S1 接线）：分发器的 `study` 与本机写命令请求带 `study` 时的排队
//! （`dispatch.rs` `local_write_tx`，`answerAndStudy` 走它）都到这里。
//!
//! # 命令清单
//!
//! 协议 3 里「出卡队列 / 牌组树计数 / 新卡挑选 / 学习会话」只有一条命令 **`study`**：牌组列表与复习页顶栏的计数
//! （新 / 学习 / 到期 / 总数、新卡上限与配额、复习预算、调整原因）、下一张与再下一张、RWKV-Instant 合格卡、自定义
//! 学习会话的出卡都在这一条里（请求与结果见 `store/study.rs` 文件头）。别的相邻读已在别处移植：`today_reviews` /
//! `review_grid`（`cmd/reads.rs`）、`stats_recall`（`cmd/stats.rs`）；`stats_release` 随统计原料缓存归命令层。
//!
//! # 一份排队规则、一份常驻会话
//!
//! 计数（Anki v3 limit tree）、新卡配额、出卡顺序、RWKV 规则、自定义学习都只在 `store/study.rs` 里写一次；计数原料、
//! 到期候选、学习卡与今天的作答常驻内存的**会话**只在 `store/queue.rs` 写一次（[Session] / [LogState]，随写入按 id 增量
//! 重读，见那里的文件头）。这里只给新代的「从哪读」（[G4Feed]）与「写入怎么记账」（[install_touch]）：
//!
//! - **会话由命令层持有**：`kernel.rs` 的 [G4Core] 一个打开的库文件一份 [StudyHub]（在它自己的锁里），会话按集合号分
//!   （键 = 集合号的十进制文本）。
//! - **牌组树**：每个规范牌组的定义 + 按类判定活着的写入拼视图（`cmd::deck_tree`，写命令同一份），每次排队照读（只与牌组
//!   数有关，改上限立即生效，同协议 3）；默认牌组取缓存配置（`cmd::default_deck`）。
//! - **卡**：缓存层 `cards` 表（列与 `srs_cards_cache` 相同），经 [G4Tables] 换表名、分区（`col`）、ID 列编码（[Ref]）。会话
//!   整份建时按主键 `(col, id)` 前缀扫一遍，之后按 id 点读重读。新卡「按索引序取第一张」与自定义学习仍是每次一条 SQL
//!   （`store/study.rs`，与协议 3 的会话同口径）。
//! - **日志**（最近 30 天每天的复习数、今天已学的新卡 / 已复习的卡 / 全部作答）：建会话时 `log_ix` 按 `log_at (col, at)`
//!   取窗口里的日志，每个规范日志 ID 一条代表（操作号最小的那份，`cmd::logs_between`，与 `cmd/reads.rs` 按时刻读日志
//!   共用），按 `kind = 'review'` 过滤，拼成协议 3 `LOGS_SQL` 的同几列交给 `LogState::fold`（计数规则同一份）。今天的学习
//!   步日志看 `res.reps`，取按血统重放写回的那份：全部要看的卡**一次**批量重放（`Index::replayed_logs`，连通分量各重放
//!   一遍；以前逐卡调 `replayed_card_logs`，每张卡重放一次它的整个分量）。之后按 id 重读（[G4Feed::reread_logs]）：同一份
//!   代表规则按规范日志 ID 取（`cmd::logs_of_ids`）。
//! - **自定义学习**：「会话里答过」= 会话开始之后有 `kind = 'review'` 日志的卡。会话开始在今天之内时直接取常驻会话的
//!   「今天的作答」（[G4Tables::answered]）；更早的走 `log_at` 区间（同一套日志代表，归一到规范卡，整组编成一个 JSON 参数
//!   由 `json_each` 展开，[card_set]：不随卡数增加绑定变量）。「最近评过重来」读缓存层 `stats`（有效复习投影，主键
//!   `(col, at, log)` 区间）；标签 / 出处读 `notes`。
//!
//! # 写入怎么记账（失效判据）
//!
//! 协议 3 的口径原样搬来：Primary 的**写连接**上装临时触发器（[install_touch]，只在这条连接上、不进库文件），把每次增删改
//! 的行记进 [StudyHub] 的「待重读」（未提交 / 已提交两侧与事务边界的判据见 `store/queue.rs` 文件头「事务边界」；写锁守卫
//! 释放时挪成已提交，`kernel.rs` `Writer` 的 `Drop`）：
//!
//! | 表 | 记什么 | 会话怎么用 |
//! |---|---|---|
//! | `cards`（缓存层卡行） | 卡（规范 ID） | 按 id 重读卡行；这张卡**所在 historyFrom 连通分量**里今天的作答重新折算（重放结果可能变） |
//! | `log_ix`（日志索引，含 `win` 翻转） | 日志（原值 ID） | 归到规范日志 ID，按 ID 重取代表、先减旧贡献再加新的 |
//! | `reg_ix` 里卡的修改（`ekind` = 卡） | 卡（原值 ID） | 同 `cards`：没有卡行的卡（笔记已删）的血统改了也能看见 |
//! | `alias_ix`（别名表，`canon != id` 的行按净变化） | 整份 | 日志 / 卡归到的规范 ID 可能整批变：下次排队整份重建 |
//!
//! 触发器看得到这条连接上的**一切**写：本机写命令（作答、撤销、改字段、`sched`…）、不经 `Session` 的写（`apply {remote}`、
//! `import`、同步一轮的 `ingest` / `ingest_finish` / `retire` / `rotate`、整层重建）——远程写入不必另走「整体失效」，它们
//! 碰到的行一样逐行记下；量大（导入、整层重建、大同步）时攒过 `DIRTY_CAP` 自动变成整份重建。只有 Primary 写（D10），
//! 所以写连接的触发器覆盖全部写入。没有用 `refresh.rs` 的变化类别（[Tally]）判：它只分「内容 / 视图 / RWKV / 统计」
//! 几类、不带 ID，作答本身就落在「统计」类里，按它失效等于每答一张整份重建（换代前的无状态现读就是这个代价，见下）。
//!
//! **Secondary**（查词弹窗等只读辅助进程）没有写连接、看不见触发器：会话带一个印记（`refresh.rs` 的 Secondary 刷新键：
//! 本机修订号 + 缓存层代号 + 绑定指纹，主进程每条改投影的写命令都推进修订号），印记变了整份重建（`dispatch.rs`）。
//!
//! 一次排队的顺序：先取待重读 id（含未提交的，只读不清）再开读快照（`snapshot` 的 `BEGIN` 是延迟的，第一条读才定快照，
//! 所以 [study] 在快照里第一件事就是 [StudyHub::with_feed]）；集合号由分发器在快照之外先读。
//!
//! # 代价（与换代前的无状态现读）
//!
//! 换代后到接线前，每次排队都在一个读快照里整份现读：30 天的日志逐条点读操作体解码（几千次）、今天学过的每张卡各重放一次
//! 整个分量（随今天学卡数平方增长），作答一次一份——「一开始背卡就卡、越背越卡」。现在建会话一次（每天、或攒满之后），之后
//! 每次作答只重读碰到的几行：几张卡行、几条日志的代表、这几张卡所在分量的一次重放。基准见 `study_bench_tests.rs`。
//!
//! 索引：查询用 `INDEXED BY` 钉住与协议 3 v9 逐列相同的部分索引（schema 40015，`cache.rs`；新代库带手写的规划统计
//! `schema.rs` `PLANNER_STATS`，实测规划器会把「新卡按索引序取第一张」改成「按 (牌组, 队列) 取出再排序」）：
//!
//! | 读 | 索引 |
//! |---|---|
//! | 新卡按位置 / 按词频取第一张 | `cards_new_position` / `cards_new_freq`（索引序，命中第一张即停，不排序） |
//! | 建会话 / 按 id 重读卡行 | `cards` 主键 `(col, id)` |
//! | 建会话的最近 30 天日志 / 早于今天开始的自定义学习会话里作答过的卡 | `log_ix.log_at (col, at)` 区间 + 每条按主键读操作体 |
//! | 按规范日志 ID 重读 | `log_ix.log_id (col, id, k)` |
//! | 最近评过重来 | `stats` 主键 `(col, at, log)` 区间 |
//! | 只复习这一作 | `notes_source`（协议 3 v25） |
//!
//! # 与协议 3 的差别（D24「按规范 ID」）
//!
//! - 结果里的牌组、卡（`counts` 的键、`next` / `after` / `eligible`）是规范 ID。请求里的 ID（`deck`、`exclude`、
//!   `rwkv.decks` 的键、`rwkv.cands` 里的卡与牌组）先归一：`rwkv.decks` 同一个类的几个成员各给了设置时按
//!   `cmd::canon_keyed` 的规则取一份；`rwkv.cands` 同一张规范卡给了几次只留第一次。
//! - 一条日志在别名类里有几份（换代前同一次 Anki 复习的两份带盐导入）只算一次：计数上下文按规范日志 ID。
//! - 顺序契约（`cmd/mod.rs` 文件头）：出卡顺序全部由显式的排序键决定（`ORDER BY …, id`，`id` 的 SQLite 序与协议 3 的
//!   编码相同），计数结果是映射；没有依赖落库顺序的地方。

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;

use rusqlite::Connection;
use rusqlite::functions::FunctionFlags;
use rusqlite::types::{FromSql, Value as Sql};
use serde_json::Value;

#[cfg(test)]
use super::deck_tree as tree_of;
use super::{LogReps, deck_tree, default_deck, logs_between, logs_of_ids, ref_of, snapshot};
use crate::projection::Day;
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::store::queue::{Dirty, Feed, LogState, StudyHub, TOUCH_ALL};
use crate::store::study::{self, CardIx, Tables};
use crate::sync2::op::EntKind;

/// `study`：集合 [col] 的一次排队（请求与结果同协议 3 `store/study.rs`，ID 是规范 ID），在 [hub] 里这个集合的常驻会话上。
/// 调用方没开事务就开一个读快照（[snapshot]），开了（写命令请求带 `study`）就在那个事务里，会话连未提交的改动一起重读。
/// [stamp]：Secondary 的「库变没变」印记（模块文件头「写入怎么记账」），Primary 给 None。**集合号由调用方在快照之外
/// 先读好**：会话必须在这次读事务的第一条读之前取走待重读 id。
pub(crate) fn study(
    t: &Truth<'_>,
    hub: &StudyHub,
    col: i64,
    req: &Value,
    stamp: Option<&str>,
) -> Result<Value, String> {
    let (now, day) = study::when(req)?;
    let today = day.index(now);
    snapshot(t, |t| {
        let ix = RefCell::new(Index::new(t, col));
        let mut feed = G4Feed {
            tb: G4Tables { t, ix: &ix, col },
        };
        // 自定义学习「会话里答过」直接读常驻会话的「今天的作答」（`store/study.rs` `run` 把会话的计数上下文交给
        // [G4Tables::answered]）；普通出卡不碰它，不复制整份（HBK-AUDIT-010）。
        hub.with_feed(&mut feed, &col.to_string(), day, today, stamp, |s, feed| {
            let req = canon_req(&ix.borrow(), req)?;
            let default = default_deck(t, &ix.borrow(), col)?;
            let tree = deck_tree(&mut ix.borrow_mut(), default)?;
            study::run_session(s, feed.tables(), tree, &req)
        })
    })
}

/// 测试的对拍基准：不用常驻会话，每次在一个读快照里整份现读（L2 的逐条 SQL `study::SqlSource` + 整段扫日志，换代后
/// 接线前的生产实现）。常驻会话随写入增量维护的结果必须与它相同（`study_tests.rs`）。
#[cfg(test)]
pub(crate) fn study_stateless(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    snapshot(t, |t| {
        let ix = RefCell::new(Index::new(t, col));
        let req = canon_req(&ix.borrow(), req)?;
        let (now, day) = study::when(&req)?;
        let today = day.index(now);
        let default = default_deck(t, &ix.borrow(), col)?;
        let tree = tree_of(&mut ix.borrow_mut(), default)?;
        let logs = scan_logs(t, &mut ix.borrow_mut(), col, day, today)?;
        let tb = G4Tables { t, ix: &ix, col };
        let mut src = study::SqlSource {
            tb: &tb,
            today,
            logs,
        };
        study::run_with(&mut src, tree, &req)
    })
}

/// 测试：集合 [col] 在 [today] 的计数上下文（建会话时的那一份）。
#[cfg(test)]
pub(super) fn log_state(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    col: i64,
    day: Day,
    today: i64,
) -> Result<LogState, String> {
    scan_logs(t, ix, col, day, today)
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

// ---------------------------------------------------------------------- 写入记账

/// [install_touch] 注册的标量函数：`srs4_study_touch(种类, 集合号, ID)`。
const TOUCH_FN: &str = "srs4_study_touch";
/// 别名表的一行进 / 出（`srs4_study_touch` 的种类；第三个参数是这一行 `id:canon` 的十六进制）。
const ALIAS_IN: i64 = 10;
const ALIAS_OUT: i64 = 11;

/// 写连接上的临时触发器（模块文件头「写入怎么记账」的表）：只在这条连接上、不进库文件、不随备份走。`cards` 的 `INSERT OR
/// REPLACE` 只触发 INSERT（没开 recursive_triggers），新旧行同一个 ID，记 NEW 就够。别名表按**净变化**记
/// （[StudyHub::touch_study_net]）：撤销这类命令会让别名表整表重算（全删再按同样的值写回），逐行记就退回成每答一次整份
/// 重建；且只看 `canon != id` 的行：`canon = id` 的行（出现过、没有规则验得上的 ID）与表里没有这一行等价
/// （`Index::canonical` 查不到就是它自己），进出都不改任何 ID 的规范 ID。
fn touch_triggers() -> String {
    let card = EntKind::Card as i64;
    format!(
        "
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_card_ins AFTER INSERT ON main.cards
  BEGIN SELECT {TOUCH_FN}(0, NEW.col, NEW.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_card_upd AFTER UPDATE ON main.cards
  BEGIN SELECT {TOUCH_FN}(0, NEW.col, NEW.id);
        SELECT {TOUCH_FN}(0, OLD.col, OLD.id) WHERE OLD.id IS NOT NEW.id OR OLD.col IS NOT NEW.col; END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_card_del AFTER DELETE ON main.cards
  BEGIN SELECT {TOUCH_FN}(0, OLD.col, OLD.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_log_ins AFTER INSERT ON main.log_ix
  BEGIN SELECT {TOUCH_FN}(1, NEW.col, NEW.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_log_upd AFTER UPDATE ON main.log_ix
  BEGIN SELECT {TOUCH_FN}(1, NEW.col, NEW.id);
        SELECT {TOUCH_FN}(1, OLD.col, OLD.id) WHERE OLD.id IS NOT NEW.id OR OLD.col IS NOT NEW.col; END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_log_del AFTER DELETE ON main.log_ix
  BEGIN SELECT {TOUCH_FN}(1, OLD.col, OLD.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_reg_ins AFTER INSERT ON main.reg_ix WHEN NEW.ekind = {card}
  BEGIN SELECT {TOUCH_FN}(0, NEW.col, NEW.ent); END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_reg_upd AFTER UPDATE ON main.reg_ix
  BEGIN SELECT {TOUCH_FN}(0, NEW.col, NEW.ent) WHERE NEW.ekind = {card};
        SELECT {TOUCH_FN}(0, OLD.col, OLD.ent) WHERE OLD.ekind = {card}; END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_reg_del AFTER DELETE ON main.reg_ix WHEN OLD.ekind = {card}
  BEGIN SELECT {TOUCH_FN}(0, OLD.col, OLD.ent); END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_alias_ins AFTER INSERT ON main.alias_ix WHEN NEW.canon IS NOT NEW.id
  BEGIN SELECT {TOUCH_FN}({ALIAS_IN}, NEW.col, hex(NEW.id) || ':' || hex(NEW.canon)); END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_alias_upd AFTER UPDATE ON main.alias_ix
  BEGIN SELECT {TOUCH_FN}({ALIAS_IN}, NEW.col, hex(NEW.id) || ':' || hex(NEW.canon)) WHERE NEW.canon IS NOT NEW.id;
        SELECT {TOUCH_FN}({ALIAS_OUT}, OLD.col, hex(OLD.id) || ':' || hex(OLD.canon)) WHERE OLD.canon IS NOT OLD.id; END;
CREATE TEMP TRIGGER IF NOT EXISTS g4_study_alias_del AFTER DELETE ON main.alias_ix WHEN OLD.canon IS NOT OLD.id
  BEGIN SELECT {TOUCH_FN}({ALIAS_OUT}, OLD.col, hex(OLD.id) || ':' || hex(OLD.canon)); END;
"
    )
}

/// 在 Primary 的写连接 [c] 上装记账的触发器（`kernel.rs` 开库时调），记进 [hub]。
pub(crate) fn install_touch(hub: &Arc<StudyHub>, c: &Connection) -> Result<(), String> {
    let h = Arc::clone(hub);
    c.create_scalar_function(TOUCH_FN, 3, FunctionFlags::SQLITE_UTF8, move |ctx| {
        let kind = ctx.get::<i64>(0)?;
        let col = ctx.get::<i64>(1)?;
        let id = match ctx.get_raw(2) {
            rusqlite::types::ValueRef::Null => String::new(),
            _ if matches!(kind, ALIAS_IN | ALIAS_OUT) => String::new(),
            v => match Ref::column_result(v) {
                Ok(r) => r.text(),
                // 解不出这行的 ID：记不了单张，记整份重建（宁多不漏），不记空 ID 把这张卡的脏标记丢掉。
                Err(_) => {
                    h.touch_study(TOUCH_ALL, col.to_string(), String::new());
                    return Ok(0i64);
                }
            },
        };
        match kind {
            ALIAS_IN | ALIAS_OUT => {
                let row = ctx.get::<String>(2)?;
                h.touch_study_net(col.to_string(), row, if kind == ALIAS_IN { 1 } else { -1 });
            }
            _ => h.touch_study(kind, col.to_string(), id),
        }
        Ok(0i64)
    })
    .map_err(sql)?;
    c.execute_batch(&touch_triggers()).map_err(sql)
}

// ---------------------------------------------------------------------- 会话的数据来源

/// 新代的会话数据来源（`store/queue.rs` [Feed]）：卡行走 [G4Tables]，日志从 `log_ix` 与操作体拼（模块文件头「日志」）。
struct G4Feed<'a, 't, 'c> {
    tb: G4Tables<'a, 't, 'c>,
}

impl Feed for G4Feed<'_, '_, '_> {
    fn tables(&self) -> &dyn Tables {
        &self.tb
    }

    fn scan_logs(&mut self, day: Day, today: i64) -> Result<LogState, String> {
        let tb = &self.tb;
        scan_logs(tb.t, &mut tb.ix.borrow_mut(), tb.col, day, today)
    }

    /// 触发器记的是原值 ID（`log_ix` / `reg_ix`）：归到规范 ID（会话里的卡与日志都按规范 ID 记）。别名表变了已经是整份
    /// 重建（[install_touch] 的别名表触发器），这里按现在的表归一。
    fn normalize(&mut self, dirty: Dirty) -> Result<Dirty, String> {
        let ix = self.tb.ix.borrow();
        let canon = |s: &String| -> Result<String, String> { Ok(ix.canon(&ref_of(s))?.text()) };
        Ok(Dirty {
            cards: dirty.cards.iter().map(canon).collect::<Result<_, _>>()?,
            logs: dirty.logs.iter().map(canon).collect::<Result<_, _>>()?,
            notes: dirty.notes,
            overflow: dirty.overflow,
        })
    }

    /// 要重折算的日志 = 记下的日志 ∪ 记下的卡上今天的作答 ∪ 这些卡与这些日志的卡所在 historyFrom 连通分量里今天的作答
    /// （分量里任何一处变了，今天学习步日志重放出来的 `res.reps` 都可能变）。按规范日志 ID 重取代表（[logs_of_ids]），一次
    /// 批量重放，先减旧贡献、再按库里现在的加回（[fold_into]）。今天的作答都按卡 / 按日志 ID 查会话里的索引
    /// （[LogState::answers_on] / [LogState::answer_card]），工作量随碰到的卡与日志，不随今天答过几次（HBK-AUDIT-010）。
    fn reread_logs(
        &mut self,
        logs: &mut LogState,
        dirty: &Dirty,
        day: Day,
        today: i64,
    ) -> Result<(), String> {
        if dirty.logs.is_empty() && dirty.cards.is_empty() {
            return Ok(());
        }
        let tb = &self.tb;
        let (from, today_start) = LogState::window(day, today);
        let mut ids: BTreeSet<Ref> = dirty.logs.iter().map(|s| ref_of(s)).collect();
        for card in &dirty.cards {
            ids.extend(logs.answers_on(card).map(|id| ref_of(id)));
        }
        let mut reps = LogReps::new();
        logs_of_ids(tb.t, &tb.ix.borrow(), tb.col, from, &ids, &mut reps)?;
        // 要重放的卡：记下的卡、这批日志里今天的学习步日志的卡，以及（重折算之前）这批日志在会话里记的卡。
        let mut cards: BTreeSet<Ref> = dirty.cards.iter().map(|s| ref_of(s)).collect();
        for id in &ids {
            if let Some(card) = logs.answer_card(&id.text()) {
                cards.insert(ref_of(card));
            }
        }
        cards.extend(learn_cards(&tb.ix.borrow(), &reps, today_start)?);
        let replayed = if cards.is_empty() {
            HashMap::new()
        } else {
            tb.ix.borrow_mut().replayed_logs(&cards)?
        };
        // 分量里别的卡上今天的作答：重放结果也可能变了。
        let more: BTreeSet<Ref> = replayed
            .keys()
            .flat_map(|card| logs.answers_on(card))
            .map(|id| ref_of(id))
            .filter(|id| !ids.contains(id))
            .collect();
        if !more.is_empty() {
            logs_of_ids(tb.t, &tb.ix.borrow(), tb.col, from, &more, &mut reps)?;
            ids.extend(more);
        }
        for id in &ids {
            logs.forget(&id.text());
        }
        fold_into(
            logs,
            &tb.ix.borrow(),
            reps,
            &replayed,
            day,
            today,
            today_start,
        )
    }
}

/// [reps] 里今天的 `kind = 'review'` 学习步日志所在的卡（规范 ID）：它们的 `res.reps` 要看重放写回的那份。
fn learn_cards(
    ix: &Index<'_, '_>,
    reps: &LogReps,
    today_start: i64,
) -> Result<BTreeSet<Ref>, String> {
    let mut out = BTreeSet::new();
    for (_, _, l) in reps.values() {
        if l.kind == "review" && l.rtype == "learn" && l.at >= today_start {
            out.insert(ix.canon(&ref_of(&l.card.text()))?);
        }
    }
    Ok(out)
}

/// 建会话时的计数上下文：窗口里每个规范日志 ID 一条代表（[logs_between]），今天学习步日志的卡一次批量重放。
fn scan_logs(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    col: i64,
    day: Day,
    today: i64,
) -> Result<LogState, String> {
    let (from, today_start) = LogState::window(day, today);
    let mut reps = LogReps::new();
    logs_between(t, ix, col, from, None, &mut reps)?;
    let cards = learn_cards(ix, &reps, today_start)?;
    let replayed = if cards.is_empty() {
        HashMap::new()
    } else {
        ix.replayed_logs(&cards)?
    };
    let mut s = LogState::empty();
    fold_into(&mut s, ix, reps, &replayed, day, today, today_start)?;
    Ok(s)
}

/// 日志代表 [reps] 折进计数上下文 [s]（协议 3 `LogState::scan` 的新代版，计数规则同一份 `LogState::fold`）：只收
/// `kind = 'review'`（协议 3 `LOGS_SQL` 的过滤）；今天的学习步日志取 [replayed]（重放写回的，按规范卡 ID 文本分）里同一个
/// 规范日志 ID 的那份。
fn fold_into(
    s: &mut LogState,
    ix: &Index<'_, '_>,
    reps: LogReps,
    replayed: &HashMap<String, Vec<crate::store::gen4::cache::LogIn>>,
    day: Day,
    today: i64,
    today_start: i64,
) -> Result<(), String> {
    // 今天的学习步日志：规范日志 ID 文本 → 它所在的卡。
    let mut want: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (id, (_, _, l)) in &reps {
        if l.kind == "review" && l.rtype == "learn" && l.at >= today_start {
            let card = ix.canon(&ref_of(&l.card.text()))?.text();
            want.entry(card).or_default().insert(id.text());
        }
    }
    let mut learn: HashMap<String, String> = HashMap::new();
    for (card, ids) in &want {
        for x in replayed.get(card).into_iter().flatten() {
            let id = serde_json::from_str::<Value>(&x.json)
                .ok()
                .and_then(|v| v.get("id").and_then(Value::as_str).map(str::to_owned));
            if let Some(id) = id.filter(|i| ids.contains(i)) {
                learn.insert(id, x.json.clone());
            }
        }
    }
    for (id, (_, k, l)) in reps {
        if l.kind != "review" {
            continue;
        }
        let id = id.text();
        let card = ix.canon(&ref_of(&l.card.text()))?.text();
        let learn_json = if l.rtype == "learn" && l.at >= today_start {
            Some(match learn.remove(&id) {
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
    Ok(())
}

/// 新代缓存层的表（`cards` / `notes` / `stats`，按集合号分区、ID 列存 [Ref]）：`store/study.rs` 的 SQL 落在这里。
struct G4Tables<'a, 't, 'c> {
    t: &'a Truth<'c>,
    ix: &'a RefCell<Index<'t, 'c>>,
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

    /// 钉住部分索引（模块文件头「索引」）。
    fn cards_via(&self, ix: CardIx) -> String {
        match ix {
            CardIx::Rows => "cards INDEXED BY sqlite_autoindex_cards_1".to_owned(),
            _ => format!("cards INDEXED BY cards_{}", ix.suffix()),
        }
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

    /// 会话开始（[since]）之后有 `kind = 'review'` 日志的卡（规范卡），见 [card_set]；没有 = 恒假。会话开始在今天之内
    /// 且有常驻会话（[resident]）：会话「今天的作答」里时刻 ≥ [since] 的（同一套代表、同一个种类过滤）；更早、或测试
    /// 基准（没有常驻会话）：`log_at` 区间（[logs_between]）。
    fn answered(
        &self,
        since: i64,
        resident: Option<&LogState>,
        today_start: i64,
    ) -> Result<(String, Vec<Sql>), String> {
        let mut cards: BTreeSet<Ref> = BTreeSet::new();
        match resident {
            Some(logs) if since >= today_start => {
                for (card, at) in logs.answers() {
                    if at >= since {
                        cards.insert(ref_of(card));
                    }
                }
            }
            _ => {
                let ix = self.ix.borrow();
                let mut reps = LogReps::new();
                logs_between(self.t, &ix, self.col, since, None, &mut reps)?;
                for (_, _, l) in reps.values() {
                    if l.kind == "review" {
                        cards.insert(ix.canon(&ref_of(&l.card.text()))?);
                    }
                }
            }
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
