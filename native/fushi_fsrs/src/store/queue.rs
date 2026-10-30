//! 常驻复习队列（按 profile）：牌组计数原料、到期复习候选、学习卡与「今天」的作答日志留在内存里，随写入增量
//! 更新；`study` 命令（store/study.rs）每次排队只读这份状态，不再按子树全部卡聚合 / 扫一遍到期卡。
//!
//! 以前（L2）每次排队：计数原料 `GROUP BY deck_id` 走覆盖索引扫子树全部卡、到期候选顺着到期索引扫全部到期卡
//! 做有界排序，十万张到期卡一次排队约 100 ms，评一张卡就排一次。现在（对齐 Anki v3 queue builder 的「建一次、
//! 答一张改一张」）：
//!
//! - **建**：一个 profile 第一次排队（或换了「今天」、攒的改动太多）时整份扫一遍缓存行与最近 30 天日志
//!   （[Session::build]），之后同一天里只做增量。
//! - **增量的来源**：写连接上装了临时触发器（[StudyHub::install]），`srs_cards_cache` / `srs_review_logs` 的
//!   每次增删改（Rust 的缓存刷新、作答、收段重放，Dart 经执行器直接写的 SQL 一样会触发）把那一行的 id 记进
//!   「待重读」。排队时按 id 重读那几行、先减旧贡献再加新贡献（[Session::reread]）——永远以库里的行为准，
//!   不信写入方报的值，所以 Drift 嵌套事务的 `ROLLBACK TO`、整笔回滚都不会让内存与库分叉：被回滚的行也在
//!   「待重读」里，重读到的就是回滚后的值。
//! - **事务边界**（失效判据）：写连接上的事务没结束时，触发器记下的 id 是「未提交」的；写连接回到 autocommit
//!   （写锁守卫释放时检查，[StudyHub::settle]）才挪进「已提交」。挪动晚于 COMMIT 对别的连接可见（守卫释放在
//!   COMMIT 之后；SQLite 也没有「提交可见的同一刻」的钩子：commit hook 在可见之前、提前挪会让读快照取走 id 却
//!   看不到提交，之后永远漏读），所以排队无论在哪条连接上都**两种 id 都重读**：已提交的取走，未提交的只读不清。
//!   读快照上重读一行未提交的改动读到的是旧值（与快照一致），提交 / 回滚挪进已提交后再按终态重读一遍——重读
//!   以库里的行为准，幂等。以前读快照只重读已提交的：COMMIT 之后、守卫释放之前开的快照看得见新行却不重读它，
//!   这一次排队漏读（集成审查【中低】）。
//! - **整份重建**：会话的日界（今天的日序号、翻日时刻、UTC 偏移）与请求不同（跨日：到期 / 埋卡 / 最近 30 天
//!   都随日变）；或一个 profile 攒的待重读 id 超过 [DIRTY_CAP]（导入、整体重建缓存、大同步收段），不再逐个记。
//! - 牌组树（含每日上限、父子关系、新卡顺序）每次排队照读（只与牌组数有关），改上限立即生效；新卡出卡仍走
//!   部分索引的 `LIMIT 1`（按新卡顺序命中第一张即停）。
//!
//! 到期复习候选按「此刻的可提取度」R = 1/(1 + t/(9S)) 排序，随此刻变化，排不成固定序。每个牌组把候选按稳定度
//! 分块、块上记（稳定度, 上次作答）的上下界，块组成一棵线段树；取最低 R 时按块的 R 下界最优先搜索，下界已高于
//! 当前最好的块整块跳过（[DueIndex::best]）。下界由同一组浮点运算在端点上算出：IEEE 除法 / 加法对每个参数单调，
//! 所以下界对块里每张卡**按 SQL 同一条式子算出的** R 都成立，结果与旧的 `ORDER BY R, id LIMIT 1` 逐张相同
//! （含 R 相等按 id、除以零得 NULL 排最前）。一次取最低只访问少数几块，不随到期卡数线性增长。

use std::cmp::Ordering;
use std::collections::{BTreeSet, BinaryHeap, HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::functions::FunctionFlags;
use rusqlite::{params_from_iter, types::Value as Sql, Connection};
use serde_json::Value;

use crate::projection::Day;
use crate::store::sync2::sql;

const DAY_MS: i64 = 86_400_000;
/// SQLite 变量上限内的 IN 列表分块。
const CHUNK: usize = 400;
/// 一个 profile 攒着的待重读 id 超过这个数就不再逐个记，下次排队整份重建（一次重建约等于重读这么多行）。
pub(crate) const DIRTY_CAP: usize = 20_000;
/// 学习卡的「快到期」窗口（与 study.rs 同一个数）。
pub(crate) const LEARN_AHEAD_MS: i64 = 20 * 60_000;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// ------------------------------------------------------------------ 待重读

/// 触发器记下的行种类（`srs_study_touch` 的第一个参数）。
const TOUCH_CARD: i64 = 0;
const TOUCH_LOG: i64 = 1;
/// 笔记：笔记缓存行、笔记的修改记录、修改记录的服务器时刻（浏览会话 store/browse.rs 用）。
const TOUCH_NOTE: i64 = 2;

/// 一个 profile 写过、还没重读进会话的卡 / 日志 / 笔记 id。
#[derive(Default, Clone, Debug)]
pub(crate) struct Dirty {
    pub(crate) cards: HashSet<String>,
    pub(crate) logs: HashSet<String>,
    pub(crate) notes: HashSet<String>,
    /// 攒满了 [DIRTY_CAP]：不再逐个记，下次整份重建。
    pub(crate) overflow: bool,
}

impl Dirty {
    fn add(&mut self, kind: i64, id: String) {
        if self.overflow {
            return;
        }
        match kind {
            TOUCH_LOG => &mut self.logs,
            TOUCH_NOTE => &mut self.notes,
            _ => &mut self.cards,
        }
        .insert(id);
        if self.cards.len() + self.logs.len() + self.notes.len() > DIRTY_CAP {
            self.overflow = true;
            self.cards = HashSet::new();
            self.logs = HashSet::new();
            self.notes = HashSet::new();
        }
    }

    fn merge(&mut self, o: Dirty) {
        if o.overflow {
            self.overflow = true;
            self.cards = HashSet::new();
            self.logs = HashSet::new();
            self.notes = HashSet::new();
            return;
        }
        for id in o.cards {
            self.add(TOUCH_CARD, id);
        }
        for id in o.logs {
            self.add(TOUCH_LOG, id);
        }
        for id in o.notes {
            self.add(TOUCH_NOTE, id);
        }
    }
}

/// 一个消费方（复习队列 / 浏览会话）的待重读清单：各自取走、互不影响。
#[derive(Default)]
struct Consumer {
    /// 写连接上还没结束的事务里写过的（未提交，或已回滚但写锁还没放）。
    pending: HashMap<String, Dirty>,
    /// 已提交（对读快照可见）、还没重读的。
    committed: HashMap<String, Dirty>,
}

impl Consumer {
    fn settle(&mut self) {
        for (p, d) in std::mem::take(&mut self.pending) {
            self.committed.entry(p).or_default().merge(d);
        }
    }

    /// 取走 [profile] 已提交的待重读；[uncommitted] 时再并上未提交的（不清掉，提交 / 回滚后还要按终态重读）。
    fn take(&mut self, profile: &str, uncommitted: bool) -> Dirty {
        let mut d = self.committed.remove(profile).unwrap_or_default();
        if uncommitted {
            if let Some(p) = self.pending.get(profile) {
                d.merge(p.clone());
            }
        }
        d
    }
}

#[derive(Default)]
struct Touched {
    /// 复习队列：卡与日志。
    study: Consumer,
    /// 浏览会话（store/browse.rs）：卡与笔记。
    browse: Consumer,
}

/// 一个 [crate::store::SrsCore] 的常驻复习队列：待重读清单 + 各 profile 的会话。
#[derive(Default)]
pub(crate) struct StudyHub {
    touched: Mutex<Touched>,
    sessions: Mutex<HashMap<String, Session>>,
    /// 测试：整份重建过几次。
    #[cfg(test)]
    pub(crate) builds: std::sync::atomic::AtomicUsize,
}

/// 写连接上的临时触发器（只在这条连接上、不进库文件、不随备份走）：缓存行与日志的每次增删改记下 id。
const TRIGGERS: &str = "
CREATE TEMP TRIGGER IF NOT EXISTS srs_study_card_ins AFTER INSERT ON main.srs_cards_cache
  BEGIN SELECT srs_study_touch(0, NEW.profile_uid, NEW.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_study_card_upd AFTER UPDATE ON main.srs_cards_cache
  BEGIN SELECT srs_study_touch(0, NEW.profile_uid, NEW.id);
        SELECT srs_study_touch(0, OLD.profile_uid, OLD.id) WHERE OLD.id IS NOT NEW.id OR OLD.profile_uid IS NOT NEW.profile_uid; END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_study_card_del AFTER DELETE ON main.srs_cards_cache
  BEGIN SELECT srs_study_touch(0, OLD.profile_uid, OLD.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_study_log_ins AFTER INSERT ON main.srs_review_log_rows
  BEGIN SELECT srs_study_touch(1, NEW.profile_uid, NEW.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_study_log_upd AFTER UPDATE ON main.srs_review_log_rows
  BEGIN SELECT srs_study_touch(1, NEW.profile_uid, NEW.id);
        SELECT srs_study_touch(1, OLD.profile_uid, OLD.id) WHERE OLD.id IS NOT NEW.id OR OLD.profile_uid IS NOT NEW.profile_uid; END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_study_log_del AFTER DELETE ON main.srs_review_log_rows
  BEGIN SELECT srs_study_touch(1, OLD.profile_uid, OLD.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_browse_note_ins AFTER INSERT ON main.srs_notes_cache
  BEGIN SELECT srs_study_touch(2, NEW.profile_uid, NEW.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_browse_note_upd AFTER UPDATE ON main.srs_notes_cache
  BEGIN SELECT srs_study_touch(2, NEW.profile_uid, NEW.id);
        SELECT srs_study_touch(2, OLD.profile_uid, OLD.id) WHERE OLD.id IS NOT NEW.id OR OLD.profile_uid IS NOT NEW.profile_uid; END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_browse_note_del AFTER DELETE ON main.srs_notes_cache
  BEGIN SELECT srs_study_touch(2, OLD.profile_uid, OLD.id); END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_browse_edit_ins AFTER INSERT ON main.srs_field_edit_rows WHEN NEW.entity_kind = 'note'
  BEGIN SELECT srs_study_touch(2, NEW.profile_uid, NEW.entity_id); END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_browse_edit_upd AFTER UPDATE ON main.srs_field_edit_rows
  BEGIN SELECT srs_study_touch(2, NEW.profile_uid, NEW.entity_id) WHERE NEW.entity_kind = 'note';
        SELECT srs_study_touch(2, OLD.profile_uid, OLD.entity_id) WHERE OLD.entity_kind = 'note'; END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_browse_edit_del AFTER DELETE ON main.srs_field_edit_rows WHEN OLD.entity_kind = 'note'
  BEGIN SELECT srs_study_touch(2, OLD.profile_uid, OLD.entity_id); END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_browse_stamp_ins AFTER INSERT ON main.srs_event_local WHEN NEW.server_time IS NOT NULL
  BEGIN SELECT srs_study_touch(2, f.profile_uid, f.entity_id) FROM main.srs_field_edit_rows f
        WHERE f.id = NEW.event_id AND f.entity_kind = 'note'; END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_browse_stamp_upd AFTER UPDATE ON main.srs_event_local
  WHEN NEW.server_time IS NOT OLD.server_time OR NEW.event_id IS NOT OLD.event_id
  BEGIN SELECT srs_study_touch(2, f.profile_uid, f.entity_id) FROM main.srs_field_edit_rows f
        WHERE f.id IN (NEW.event_id, OLD.event_id) AND f.entity_kind = 'note'; END;
CREATE TEMP TRIGGER IF NOT EXISTS srs_browse_stamp_del AFTER DELETE ON main.srs_event_local WHEN OLD.server_time IS NOT NULL
  BEGIN SELECT srs_study_touch(2, f.profile_uid, f.entity_id) FROM main.srs_field_edit_rows f
        WHERE f.id = OLD.event_id AND f.entity_kind = 'note'; END;
";

impl StudyHub {
    /// 在写连接上装触发器（[crate::store::SrsCore::open] 建表 / 升级之后调）。
    pub(crate) fn install(hub: &Arc<StudyHub>, c: &Connection) -> Result<(), String> {
        let h = Arc::clone(hub);
        c.create_scalar_function("srs_study_touch", 3, FunctionFlags::SQLITE_UTF8, move |ctx| {
            let kind = ctx.get::<i64>(0)?;
            let profile = ctx.get::<String>(1)?;
            let id = ctx.get::<String>(2)?;
            let mut t = lock(&h.touched);
            // 卡两边都要；日志只有复习队列要；笔记只有浏览要。
            if kind != TOUCH_NOTE {
                t.study.pending.entry(profile.clone()).or_default().add(kind, id.clone());
            }
            if kind != TOUCH_LOG {
                t.browse.pending.entry(profile).or_default().add(kind, id);
            }
            Ok(0i64)
        })
        .map_err(sql)?;
        c.execute_batch(TRIGGERS).map_err(sql)
    }

    /// 写连接回到 autocommit（事务已提交或回滚完）：未提交的 id 挪进已提交。写锁守卫释放时调（还持着写锁）。
    pub(crate) fn settle(&self) {
        let mut t = lock(&self.touched);
        t.study.settle();
        t.browse.settle();
    }

    /// 浏览会话（store/browse.rs）取走 [profile] 待重读的卡 / 笔记 id，并上未提交的（只读不清）：口径同
    /// [StudyHub::with_session]——COMMIT 对读连接可见早于 [settle]，只取已提交的会在这个窗口里漏读一次。
    /// [_uncommitted] 留给调用方表态，两种连接现在同一口径。
    pub(crate) fn take_browse(&self, profile: &str, _uncommitted: bool) -> Dirty {
        lock(&self.touched).browse.take(profile, true)
    }

    /// 在 [profile] 的会话上跑 [f]：先取走已提交的待重读 id、并上未提交的（只读不清，见文件头「事务边界」；
    /// [_uncommitted] = [c] 是写连接上还没结束的事务，两种连接现在同一口径，参数留给调用方表态），会话不存在 /
    /// 日界不同 / 攒满了就整份重建，否则只重读那几行。[c] 是这次排队的连接（读快照，或写连接上的 SAVEPOINT）；
    /// 必须在这条连接这次读事务的第一条读之前调（先取 id 再开快照）。重建 / 重读出错时丢掉会话，下次整份重建。
    pub(crate) fn with_session<T>(
        &self,
        c: &Connection,
        profile: &str,
        day: Day,
        today: i64,
        _uncommitted: bool,
        f: impl FnOnce(&Session) -> Result<T, String>,
    ) -> Result<T, String> {
        let mut sessions = lock(&self.sessions);
        let dirty = lock(&self.touched).study.take(profile, true);
        let fresh = match sessions.get(profile) {
            Some(s) => s.day != day || s.today != today || dirty.overflow,
            None => true,
        };
        let ready = if fresh {
            #[cfg(test)]
            self.builds.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            sessions.remove(profile);
            Session::build(c, profile, day, today).map(|s| {
                sessions.insert(profile.to_owned(), s);
            })
        } else {
            let s = sessions.get_mut(profile).expect("checked above");
            s.reread(c, profile, &dirty)
        };
        if let Err(e) = ready {
            sessions.remove(profile);
            return Err(e);
        }
        f(&sessions[profile])
    }
}

// ------------------------------------------------------------------ 日志

/// 一条日志对计数上下文的贡献。
#[derive(Clone, Debug)]
struct Fold {
    slot: Option<usize>,
    card: String,
    at: i64,
    today: bool,
    reviewed: bool,
    introduced: bool,
}

/// 计数上下文里来自日志的部分：最近 30 天每天的复习数、今天已学的新卡 / 已复习的卡 / 全部作答。按日志 id 记
/// 每条的贡献，重读时可以减掉旧的再加新的。
#[derive(Default, Clone, Debug)]
pub(crate) struct LogState {
    last30: Vec<i64>,
    introduced: HashMap<String, u32>,
    reviewed: HashMap<String, u32>,
    /// 今天的作答：日志 id → (卡, 时刻)。
    answers: HashMap<String, (String, i64)>,
    folded: HashMap<String, Fold>,
}

/// 最近 30 天的复习日志（参数：profile, 30 天前的日界, 今天的日界）。
pub(crate) const LOGS_SQL: &str = "SELECT card_id, occurred_at, review_type, \
     CASE WHEN review_type = 'learn' AND occurred_at >= ?3 THEN json END, id \
     FROM srs_review_logs WHERE profile_uid = ?1 AND kind = 'review' AND occurred_at >= ?2";

/// 按 id 重读几条日志（参数同 [LOGS_SQL]，其后是 id）：走主键，profile / 种类 / 时刻只当过滤（`+`），不让 SQLite 改走
/// 区间索引把 30 天日志扫一遍。
pub(crate) fn logs_by_id_sql(n: usize) -> String {
    format!(
        "SELECT card_id, occurred_at, review_type, CASE WHEN review_type = 'learn' AND occurred_at >= ?3 THEN json END, id          FROM srs_review_logs WHERE id IN ({}) AND +profile_uid = ?1 AND +kind = 'review' AND +occurred_at >= ?2",
        marks(n)
    )
}

fn day_start(day: &Day, d: i64) -> i64 {
    d * DAY_MS + day.rollover_hour * 3_600_000 - day.utc_offset_min * 60_000
}

impl LogState {
    pub(crate) fn last30(&self) -> &[i64] {
        &self.last30
    }

    pub(crate) fn introduced(&self, card: &str) -> bool {
        self.introduced.contains_key(card)
    }

    pub(crate) fn reviewed(&self, card: &str) -> bool {
        self.reviewed.contains_key(card)
    }

    /// 今天复习过的卡（去重）。
    pub(crate) fn reviewed_cards(&self) -> impl Iterator<Item = &String> {
        self.reviewed.keys()
    }

    /// 今天新学过的卡（去重）。
    pub(crate) fn introduced_cards(&self) -> impl Iterator<Item = &String> {
        self.introduced.keys()
    }

    /// 今天的全部作答 (卡, 时刻)。
    pub(crate) fn answers(&self) -> impl Iterator<Item = (&String, i64)> {
        self.answers.values().map(|(c, at)| (c, *at))
    }

    /// 整份扫一遍最近 30 天的日志（`idx_srs_review_logs_profile_kind_time` 区间）。
    pub(crate) fn scan(c: &Connection, profile: &str, day: Day, today: i64) -> Result<LogState, String> {
        let mut s = LogState { last30: vec![0; 30], ..LogState::default() };
        let (from, today_start) = (day_start(&day, today - 29), day_start(&day, today));
        let mut stmt = c.prepare_cached(LOGS_SQL).map_err(sql)?;
        let mut q = stmt.query(rusqlite::params![profile, from, today_start]).map_err(sql)?;
        while let Some(r) = q.next().map_err(sql)? {
            s.fold_row(r, day, today, today_start)?;
        }
        Ok(s)
    }

    fn fold_row(&mut self, r: &rusqlite::Row<'_>, day: Day, today: i64, today_start: i64) -> Result<(), String> {
        let at: i64 = r.get(1).map_err(sql)?;
        let d = day.index(at);
        let slot = d - (today - 29);
        let slot = (0..30).contains(&slot).then_some(slot as usize);
        let card: String = r.get(0).map_err(sql)?;
        let id: String = r.get(4).map_err(sql)?;
        let today_log = at >= today_start;
        let (mut reviewed, mut introduced) = (false, false);
        if today_log {
            reviewed = r.get::<_, String>(2).map_err(sql)? == "review";
            if let Some(j) = r.get::<_, Option<String>>(3).map_err(sql)? {
                let v: Value = serde_json::from_str(&j).unwrap_or(Value::Null);
                introduced = v["res"]["reps"].as_f64() == Some(1.0);
            }
        }
        self.apply(id, Fold { slot, card, at, today: today_log, reviewed, introduced });
        Ok(())
    }

    fn apply(&mut self, id: String, f: Fold) {
        if let Some(s) = f.slot {
            self.last30[s] += 1;
        }
        if f.today {
            if f.reviewed {
                *self.reviewed.entry(f.card.clone()).or_default() += 1;
            }
            if f.introduced {
                *self.introduced.entry(f.card.clone()).or_default() += 1;
            }
            self.answers.insert(id.clone(), (f.card.clone(), f.at));
        }
        self.folded.insert(id, f);
    }

    fn unapply(&mut self, id: &str) {
        let Some(f) = self.folded.remove(id) else { return };
        if let Some(s) = f.slot {
            self.last30[s] -= 1;
        }
        let dec = |m: &mut HashMap<String, u32>, k: &str| {
            if let Some(n) = m.get_mut(k) {
                *n -= 1;
                if *n == 0 {
                    m.remove(k);
                }
            }
        };
        if f.today {
            if f.reviewed {
                dec(&mut self.reviewed, &f.card);
            }
            if f.introduced {
                dec(&mut self.introduced, &f.card);
            }
            self.answers.remove(id);
        }
    }

    /// 按 id 重读几条日志：先减掉旧贡献，再按库里的行（不在了 / 不在窗口里 = 没有贡献）加回。
    fn reread(&mut self, c: &Connection, profile: &str, day: Day, today: i64, ids: &HashSet<String>) -> Result<(), String> {
        let (from, today_start) = (day_start(&day, today - 29), day_start(&day, today));
        let all: Vec<&String> = ids.iter().collect();
        for chunk in all.chunks(CHUNK) {
            for id in chunk {
                self.unapply(id);
            }
            let text = logs_by_id_sql(chunk.len());
            let mut stmt = c.prepare_cached(&text).map_err(sql)?;
            let mut args: Vec<Sql> = vec![Sql::Text(profile.to_owned()), Sql::Integer(from), Sql::Integer(today_start)];
            args.extend(chunk.iter().map(|s| Sql::Text((*s).clone())));
            let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
            while let Some(r) = q.next().map_err(sql)? {
                self.fold_row(r, day, today, today_start)?;
            }
        }
        Ok(())
    }
}

fn marks(n: usize) -> String {
    vec!["?"; n].join(", ")
}

// ------------------------------------------------------------------ 卡

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Queue {
    /// learning / relearning。
    Learning,
    Review,
    /// 其余（new 等）：计数里算「新卡可用」。
    Other,
}

/// 一张卡排队要用的列（`srs_cards_cache` 的一行）。
#[derive(Clone, Copy, PartialEq, Debug)]
struct Row {
    deck: u32,
    hidden: bool,
    suspended: bool,
    fushi: bool,
    buried: Option<i64>,
    queue: Queue,
    due_day: Option<i64>,
    due_at: Option<i64>,
    last: Option<i64>,
    stab: Option<f64>,
}

impl Row {
    /// 「可出」（study.rs `LIVE`）：可见、未暂停、归 Fushi 排程、没埋或埋到今天为止。
    fn live(&self, today: i64) -> bool {
        !self.hidden && !self.suspended && self.fushi && self.buried.is_none_or(|b| b <= today)
    }
}

pub(crate) const ROW_COLUMNS: &str = "SELECT id, deck_id, hidden, suspended, scheduler = 'fushi', buried_until_day, queue, due_day, due_at, \
     last_reviewed_at, stability FROM srs_cards_cache";

/// 一个牌组自己（不含子牌组）的计数原料。
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub(crate) struct DeckRaw {
    pub total: i64,
    pub new_avail: i64,
    pub learn: i64,
    pub due: i64,
}

#[derive(Default)]
struct DeckQueue {
    /// hidden = 0 的卡数。
    total: i64,
    new_avail: i64,
    /// 可出的学习 / 重学卡：(COALESCE(due_at, 0), 卡)。
    learning: BTreeSet<(i64, Arc<str>)>,
    due: DueIndex,
}

/// 一个 profile 的常驻队列状态（见文件头）。
pub(crate) struct Session {
    day: Day,
    today: i64,
    ids: Vec<Arc<str>>,
    index: HashMap<Arc<str>, u32>,
    rows: Vec<Option<Row>>,
    deck_names: Vec<Arc<str>>,
    deck_index: HashMap<Arc<str>, u32>,
    decks: Vec<DeckQueue>,
    logs: LogState,
}

/// 一张到期复习候选：(卡, 上次作答, 稳定度)。
pub(crate) type DueCand = (String, Option<i64>, Option<f64>);

impl Session {
    pub(crate) fn logs(&self) -> &LogState {
        &self.logs
    }

    fn card(&mut self, id: &str) -> u32 {
        if let Some(i) = self.index.get(id) {
            return *i;
        }
        let a: Arc<str> = Arc::from(id);
        let i = self.ids.len() as u32;
        self.ids.push(Arc::clone(&a));
        self.rows.push(None);
        self.index.insert(a, i);
        i
    }

    fn deck(&mut self, id: &str) -> u32 {
        if let Some(i) = self.deck_index.get(id) {
            return *i;
        }
        let a: Arc<str> = Arc::from(id);
        let i = self.deck_names.len() as u32;
        self.deck_names.push(Arc::clone(&a));
        self.decks.push(DeckQueue::default());
        self.deck_index.insert(a, i);
        i
    }

    fn read_row(&mut self, r: &rusqlite::Row<'_>) -> Result<(u32, Row), String> {
        let id: String = r.get(0).map_err(sql)?;
        let deck_id: String = r.get(1).map_err(sql)?;
        let queue: String = r.get(6).map_err(sql)?;
        let card = self.card(&id);
        let deck = self.deck(&deck_id);
        Ok((
            card,
            Row {
                deck,
                hidden: r.get(2).map_err(sql)?,
                suspended: r.get(3).map_err(sql)?,
                fushi: r.get(4).map_err(sql)?,
                buried: r.get(5).map_err(sql)?,
                queue: match queue.as_str() {
                    "learning" | "relearning" => Queue::Learning,
                    "review" => Queue::Review,
                    _ => Queue::Other,
                },
                due_day: r.get(7).map_err(sql)?,
                due_at: r.get(8).map_err(sql)?,
                last: r.get(9).map_err(sql)?,
                stab: r.get(10).map_err(sql)?,
            },
        ))
    }

    /// 整份建（一个 profile 的全部缓存行 + 最近 30 天日志）。
    fn build(c: &Connection, profile: &str, day: Day, today: i64) -> Result<Session, String> {
        let mut s = Session {
            day,
            today,
            ids: Vec::new(),
            index: HashMap::new(),
            rows: Vec::new(),
            deck_names: Vec::new(),
            deck_index: HashMap::new(),
            decks: Vec::new(),
            logs: LogState::scan(c, profile, day, today)?,
        };
        // `+profile_uid`：整表顺扫比按 profile 前缀索引逐行回表快（一个 profile 通常就是全表）。
        let mut stmt = c.prepare_cached(&format!("{ROW_COLUMNS} WHERE +profile_uid = ?1")).map_err(sql)?;
        let mut q = stmt.query([profile]).map_err(sql)?;
        let mut due: Vec<Vec<(u32, Option<i64>, Option<f64>)>> = Vec::new();
        while let Some(r) = q.next().map_err(sql)? {
            let (card, row) = s.read_row(r)?;
            s.rows[card as usize] = Some(row);
            if s.place(card, &row, 1) {
                let d = row.deck as usize;
                if due.len() <= d {
                    due.resize_with(d + 1, Vec::new);
                }
                due[d].push((card, row.last, row.stab));
            }
        }
        for (d, entries) in due.into_iter().enumerate() {
            s.decks[d].due = DueIndex::build(entries, &s.ids);
        }
        Ok(s)
    }

    /// 加（[sign] = 1）/ 减（-1）一张卡对所在牌组的贡献；到期复习候选不在这里动，返回它是不是候选。
    fn place(&mut self, card: u32, row: &Row, sign: i64) -> bool {
        let today = self.today;
        let id = Arc::clone(&self.ids[card as usize]);
        let dq = &mut self.decks[row.deck as usize];
        if !row.hidden {
            dq.total += sign;
        }
        if !row.live(today) {
            return false;
        }
        match row.queue {
            Queue::Learning => {
                let k = (row.due_at.unwrap_or(0), id);
                if sign > 0 {
                    dq.learning.insert(k);
                } else {
                    dq.learning.remove(&k);
                }
                false
            }
            Queue::Review => row.due_day.unwrap_or(0) <= today,
            Queue::Other => {
                dq.new_avail += sign;
                false
            }
        }
    }

    /// 按 id 重读写过的卡与日志（见文件头）。
    fn reread(&mut self, c: &Connection, profile: &str, dirty: &Dirty) -> Result<(), String> {
        if !dirty.logs.is_empty() {
            self.logs.reread(c, profile, self.day, self.today, &dirty.logs)?;
        }
        let all: Vec<&String> = dirty.cards.iter().collect();
        for chunk in all.chunks(CHUNK) {
            let mut fetched: HashMap<u32, Row> = HashMap::new();
            {
                let text = format!("{ROW_COLUMNS} WHERE id IN ({}) AND +profile_uid = ?", marks(chunk.len()));
                let mut stmt = c.prepare_cached(&text).map_err(sql)?;
                let mut args: Vec<Sql> = chunk.iter().map(|s| Sql::Text((*s).clone())).collect();
                args.push(Sql::Text(profile.to_owned()));
                let mut q = stmt.query(params_from_iter(args)).map_err(sql)?;
                while let Some(r) = q.next().map_err(sql)? {
                    let (card, row) = self.read_row(r)?;
                    fetched.insert(card, row);
                }
            }
            for id in chunk {
                let card = self.card(id);
                let new = fetched.remove(&card);
                let old = self.rows[card as usize];
                if old == new {
                    continue;
                }
                if let Some(o) = old {
                    if self.place(card, &o, -1) {
                        self.decks[o.deck as usize].due.remove(card, &self.ids);
                    }
                }
                if let Some(n) = new {
                    if self.place(card, &n, 1) {
                        self.decks[n.deck as usize].due.insert(card, n.last, n.stab, &self.ids);
                    }
                }
                self.rows[card as usize] = new;
            }
        }
        Ok(())
    }

    /// 几个牌组各自的计数原料（只给有 hidden = 0 的卡的牌组，与旧 SQL `GROUP BY deck_id` 出不出行一致）；
    /// [decks] 为 None = 全部牌组。
    pub(crate) fn tallies(&self, now: i64, decks: Option<&[String]>) -> HashMap<String, DeckRaw> {
        let limit = now + LEARN_AHEAD_MS;
        let raw = |dq: &DeckQueue| DeckRaw {
            total: dq.total,
            new_avail: dq.new_avail,
            learn: dq.learning.iter().take_while(|(due, _)| *due <= limit).count() as i64,
            due: dq.due.len() as i64,
        };
        let mut out = HashMap::new();
        match decks {
            Some(ids) => {
                for id in ids {
                    if let Some(d) = self.deck_index.get(id.as_str()) {
                        let dq = &self.decks[*d as usize];
                        if dq.total > 0 {
                            out.insert(id.clone(), raw(dq));
                        }
                    }
                }
            }
            None => {
                for (i, dq) in self.decks.iter().enumerate() {
                    if dq.total > 0 {
                        out.insert(self.deck_names[i].to_string(), raw(dq));
                    }
                }
            }
        }
        out
    }

    /// 一组卡所在的牌组与是否隐藏（不在这个 profile 里的卡不给）。
    pub(crate) fn decks_of(&self, ids: &HashSet<String>) -> HashMap<String, (String, bool)> {
        let mut out = HashMap::new();
        for id in ids {
            let Some(i) = self.index.get(id.as_str()) else { continue };
            if let Some(r) = &self.rows[*i as usize] {
                out.insert(id.clone(), (self.deck_names[r.deck as usize].to_string(), r.hidden));
            }
        }
        out
    }

    fn excluded(&self, exclude: &[&str]) -> HashSet<u32> {
        exclude.iter().filter_map(|e| self.index.get(*e).copied()).collect()
    }

    /// 子树里按 (COALESCE(due_at, 0), id) 最早、在 [limit] 之前到期的可出学习卡（排除 [exclude]）：(卡, due_at)。
    pub(crate) fn first_learning(&self, decks: &[&str], limit: i64, exclude: &[&str]) -> Option<(String, Option<i64>)> {
        let ex = self.excluded(exclude);
        let mut best: Option<&(i64, Arc<str>)> = None;
        for d in decks {
            let Some(di) = self.deck_index.get(*d) else { continue };
            let hit = self.decks[*di as usize]
                .learning
                .iter()
                .take_while(|(due, _)| *due <= limit)
                .find(|(_, id)| !self.index.get(id).is_some_and(|i| ex.contains(i)));
            if let Some(h) = hit {
                if best.is_none_or(|b| h < b) {
                    best = Some(h);
                }
            }
        }
        best.map(|(_, id)| {
            let row = self.rows[self.index[id] as usize].expect("learning cards have rows");
            (id.to_string(), row.due_at)
        })
    }

    /// 几个牌组的到期复习卡里此刻可提取度最低的一张（R 相等按 id；排除 [exclude]）。
    pub(crate) fn lowest_due(&self, decks: &[&str], now: i64, exclude: &HashSet<&str>) -> Option<DueCand> {
        let ex: HashSet<u32> = exclude.iter().filter_map(|e| self.index.get(*e).copied()).collect();
        let mut best: Option<(Option<f64>, u32)> = None;
        for d in decks {
            let Some(di) = self.deck_index.get(*d) else { continue };
            best = self.decks[*di as usize].due.best(now, &ex, &self.ids, best);
        }
        best.map(|(_, card)| {
            let row = self.rows[card as usize].expect("due cards have rows");
            (self.ids[card as usize].to_string(), row.last, row.stab)
        })
    }
}

// ------------------------------------------------------------------ 到期复习候选

/// SQL 排序键（study.rs 旧的 `due_sql` 同一条式子，逐个运算同序）：
/// `1.0 / (1.0 + (CASE WHEN last IS NULL THEN 0.0 ELSE (now - last) / 86400000.0 END) / (9.0 * COALESCE(stability, 1.0)))`；
/// SQLite 除以零得 NULL、NaN 存成 NULL。
pub(crate) fn sql_r(now: i64, last: Option<i64>, stab: Option<f64>) -> Option<f64> {
    let t = match last {
        None => 0.0,
        Some(l) => elapsed(now, l) / 86_400_000.0,
    };
    let denom = 9.0 * stab.unwrap_or(1.0);
    if denom == 0.0 {
        return None;
    }
    let v = 1.0 + t / denom;
    if v == 0.0 {
        return None;
    }
    let r = 1.0 / v;
    (!r.is_nan()).then_some(r)
}

/// `now - last`：整数相减（溢出时 SQLite 改用浮点相减），再转浮点。
fn elapsed(now: i64, last: i64) -> f64 {
    match now.checked_sub(last) {
        Some(d) => d as f64,
        None => now as f64 - last as f64,
    }
}

/// 排序：NULL 最前，再按 R 升序，R 相等按 id。
fn key_lt(a: (Option<f64>, u32), b: (Option<f64>, u32), ids: &[Arc<str>]) -> bool {
    let by_r = match (a.0, b.0) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Less,
        (Some(_), None) => Ordering::Greater,
        (Some(x), Some(y)) => x.partial_cmp(&y).unwrap_or(Ordering::Equal),
    };
    by_r.then_with(|| ids[a.1 as usize].cmp(&ids[b.1 as usize])) == Ordering::Less
}

/// 能用块下界的候选：上次作答已知、分母 9·S 有限且为正。
#[derive(Clone, Copy, Debug)]
struct Entry {
    card: u32,
    last: i64,
    s: f64,
}

#[derive(Clone, Copy, Debug)]
struct Bounds {
    n: u32,
    s_min: f64,
    s_max: f64,
    l_min: i64,
    l_max: i64,
}

const EMPTY: Bounds = Bounds { n: 0, s_min: f64::INFINITY, s_max: f64::NEG_INFINITY, l_min: i64::MAX, l_max: i64::MIN };

impl Bounds {
    fn of(es: &[Entry]) -> Bounds {
        let mut b = EMPTY;
        for e in es {
            b.n += 1;
            b.s_min = b.s_min.min(e.s);
            b.s_max = b.s_max.max(e.s);
            b.l_min = b.l_min.min(e.last);
            b.l_max = b.l_max.max(e.last);
        }
        b
    }

    fn join(a: &Bounds, b: &Bounds) -> Bounds {
        Bounds {
            n: a.n + b.n,
            s_min: a.s_min.min(b.s_min),
            s_max: a.s_max.max(b.s_max),
            l_min: a.l_min.min(b.l_min),
            l_max: a.l_max.max(b.l_max),
        }
    }

    /// 块里每张卡按 [sql_r] 算出的 R 的下界；块里可能有 1 + x ≤ 0（上次作答远在此刻之后）的卡 = -∞（必须进去看）。
    /// 端点上做与 [sql_r] 同样的浮点运算：除法 / 加法对每个参数单调，所以端点给出的就是真界，不需要放宽。
    fn r_floor(&self, now: i64) -> f64 {
        let t_hi = elapsed(now, self.l_min) / 86_400_000.0;
        let t_lo = elapsed(now, self.l_max) / 86_400_000.0;
        let (d_min, d_max) = (9.0 * self.s_min, 9.0 * self.s_max);
        let x_hi = if t_hi >= 0.0 { t_hi / d_min } else { t_hi / d_max };
        let x_lo = if t_lo >= 0.0 { t_lo / d_max } else { t_lo / d_min };
        if !(1.0 + x_lo > 0.0) {
            return f64::NEG_INFINITY;
        }
        1.0 / (1.0 + x_hi)
    }
}

/// 一块的卡数。
const BLOCK: usize = 32;

#[derive(Clone, Copy, Debug)]
enum Slot {
    Block(u32),
    Loose,
    NoLast,
    Odd,
}

/// 一个牌组的到期复习候选（见文件头）。
#[derive(Default)]
struct DueIndex {
    blocks: Vec<Vec<Entry>>,
    /// 线段树（下标 1 是根，叶子 `size + 块号`）。
    tree: Vec<Bounds>,
    size: usize,
    /// 建好之后新加进来的可分块候选（逐张算）。
    loose: Vec<Entry>,
    /// 从没作答过的（t = 0，R 恒为 1）：按 id 有序。
    nolast: BTreeSet<(Arc<str>, u32)>,
    /// 其余（分母为零 / 非有限 / 负）：逐张按 SQL 式子算。
    odd: Vec<(u32, Option<i64>, Option<f64>)>,
    at: HashMap<u32, Slot>,
}

enum Class {
    Normal(Entry),
    NoLast,
    Odd,
}

fn classify(card: u32, last: Option<i64>, stab: Option<f64>) -> Class {
    let s = stab.unwrap_or(1.0);
    let denom = 9.0 * s;
    match last {
        Some(l) if denom.is_finite() && denom > 0.0 => Class::Normal(Entry { card, last: l, s }),
        None if denom != 0.0 && !denom.is_nan() => Class::NoLast,
        _ => Class::Odd,
    }
}

/// 最优先搜索的堆项：R 下界小的先出。
struct Item(f64, usize);

impl PartialEq for Item {
    fn eq(&self, o: &Self) -> bool {
        self.cmp(o) == Ordering::Equal
    }
}
impl Eq for Item {}
impl PartialOrd for Item {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for Item {
    fn cmp(&self, o: &Self) -> Ordering {
        o.0.total_cmp(&self.0).then_with(|| o.1.cmp(&self.1))
    }
}

impl DueIndex {
    fn len(&self) -> usize {
        self.at.len()
    }

    fn build(entries: Vec<(u32, Option<i64>, Option<f64>)>, ids: &[Arc<str>]) -> DueIndex {
        let mut ix = DueIndex::default();
        let mut normal = Vec::new();
        for (card, last, stab) in entries {
            match classify(card, last, stab) {
                Class::Normal(e) => normal.push(e),
                Class::NoLast => {
                    ix.nolast.insert((Arc::clone(&ids[card as usize]), card));
                    ix.at.insert(card, Slot::NoLast);
                }
                Class::Odd => {
                    ix.odd.push((card, last, stab));
                    ix.at.insert(card, Slot::Odd);
                }
            }
        }
        ix.layout(normal);
        ix
    }

    /// 按（稳定度, 上次作答）排好分块、建树。
    fn layout(&mut self, mut normal: Vec<Entry>) {
        normal.sort_by(|a, b| a.s.total_cmp(&b.s).then(a.last.cmp(&b.last)));
        self.blocks = normal.chunks(BLOCK).map(<[Entry]>::to_vec).collect();
        self.size = self.blocks.len().max(1).next_power_of_two();
        self.tree = vec![EMPTY; 2 * self.size];
        for (j, b) in self.blocks.iter().enumerate() {
            self.tree[self.size + j] = Bounds::of(b);
            for e in b {
                self.at.insert(e.card, Slot::Block(j as u32));
            }
        }
        for i in (1..self.size).rev() {
            self.tree[i] = Bounds::join(&self.tree[2 * i], &self.tree[2 * i + 1]);
        }
        self.loose.clear();
    }

    fn insert(&mut self, card: u32, last: Option<i64>, stab: Option<f64>, ids: &[Arc<str>]) {
        match classify(card, last, stab) {
            Class::Normal(e) => {
                self.loose.push(e);
                self.at.insert(card, Slot::Loose);
                // 零散的多了就重新分块（摊下来每次插入 O(log n)）。
                if self.loose.len() > 64.max(self.at.len() / 16) {
                    let mut all: Vec<Entry> = self.blocks.drain(..).flatten().collect();
                    all.append(&mut self.loose);
                    self.layout(all);
                }
            }
            Class::NoLast => {
                self.nolast.insert((Arc::clone(&ids[card as usize]), card));
                self.at.insert(card, Slot::NoLast);
            }
            Class::Odd => {
                self.odd.push((card, last, stab));
                self.at.insert(card, Slot::Odd);
            }
        }
    }

    fn remove(&mut self, card: u32, ids: &[Arc<str>]) {
        match self.at.remove(&card) {
            Some(Slot::Block(j)) => {
                let j = j as usize;
                let b = &mut self.blocks[j];
                if let Some(p) = b.iter().position(|e| e.card == card) {
                    b.swap_remove(p);
                }
                let mut i = self.size + j;
                self.tree[i] = Bounds::of(&self.blocks[j]);
                while i > 1 {
                    i /= 2;
                    self.tree[i] = Bounds::join(&self.tree[2 * i], &self.tree[2 * i + 1]);
                }
            }
            Some(Slot::Loose) => {
                if let Some(p) = self.loose.iter().position(|e| e.card == card) {
                    self.loose.swap_remove(p);
                }
            }
            Some(Slot::NoLast) => {
                self.nolast.remove(&(Arc::clone(&ids[card as usize]), card));
            }
            Some(Slot::Odd) => self.odd.retain(|(c, _, _)| *c != card),
            None => {}
        }
    }

    /// [best]（别的牌组已找到的最低）与这个牌组里的候选合起来最低的那张。
    fn best(&self, now: i64, ex: &HashSet<u32>, ids: &[Arc<str>], mut best: Option<(Option<f64>, u32)>) -> Option<(Option<f64>, u32)> {
        let consider = |k: (Option<f64>, u32), best: &mut Option<(Option<f64>, u32)>| {
            if !ex.contains(&k.1) && best.is_none_or(|b| key_lt(k, b, ids)) {
                *best = Some(k);
            }
        };
        for (card, last, stab) in &self.odd {
            consider((sql_r(now, *last, *stab), *card), &mut best);
        }
        if let Some((_, card)) = self.nolast.iter().find(|(_, c)| !ex.contains(c)) {
            consider((Some(1.0), *card), &mut best);
        }
        for e in &self.loose {
            consider((sql_r(now, Some(e.last), Some(e.s)), e.card), &mut best);
        }
        if self.tree.len() > 1 && self.tree[1].n > 0 {
            let mut heap = BinaryHeap::new();
            heap.push(Item(self.tree[1].r_floor(now), 1));
            while let Some(Item(floor, node)) = heap.pop() {
                // 堆顶的下界已经高于当前最好（R 相等还要比 id，不能跳）：剩下的全都不可能更低。
                if let Some((r, _)) = best {
                    if floor > r.unwrap_or(f64::NEG_INFINITY) {
                        break;
                    }
                }
                if node >= self.size {
                    for e in &self.blocks[node - self.size] {
                        consider((sql_r(now, Some(e.last), Some(e.s)), e.card), &mut best);
                    }
                    continue;
                }
                for child in [2 * node, 2 * node + 1] {
                    if self.tree[child].n > 0 {
                        heap.push(Item(self.tree[child].r_floor(now), child));
                    }
                }
            }
        }
        best
    }
}
