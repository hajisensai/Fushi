//! 卡片浏览与 AnkiConnect 兼容层的读命令的新代实现（协议 3 `store/browse.rs` 的 11 个 op：`browse_query` /
//! `browse_rows` / `browse_ids` / `browse_targets` / `browse_close` / `browse_stats` / `browse_counts` /
//! `browse_sources` / `anki_find` / `anki_dupes` / `anki_tags`）。已接分发器（`dispatch.rs`「浏览会话」一节：读连接上
//! 跑，会话表是 `G4Core` 的 `browse`）。
//!
//! 会话、搜索语料、筛选、排序、成行、出处分组、AnkiConnect 的查找 / 查重 / 标签只有一份实现——协议 3 的
//! [crate::store::browse]；那里把「从哪读」抽成了 [Source]，这里只给新代的读法（[G4]）与会话的失效判据。结果的 JSON
//! 与列式形状因此与协议 3 逐键相同。
//!
//! # 读法（[G4]）
//!
//! - 笔记 / 卡片行：缓存层的 `notes` / `cards`（列与协议 3 的缓存表相同，`cache.rs`；ID 列是 [Ref] 存储形，解回文本，
//!   `browse::id_col`）。按 ID 点读走主键 `(col, id)`。
//! - 字段原文、最后改动时刻、出处：每条笔记按类判定活着的修改行（`class.rs` [Index::class_lines]，缓存层物化笔记行的
//!   同一份），连同读命令同一份的合成 `tags` 行（`edit_rows`，最后一次改标签算进最后改动时刻），交给协议 3 同一个
//!   `registers::note_browse_values` / `note_browse_detail`。协议 3 按修改记录表一次顺序扫；
//!   这里每条笔记几次索引点读——全集合装字段（`edited:`、按修改时间排、全文检索第一次）比协议 3 慢一个常数，之后常驻、
//!   随写入按笔记重读，与协议 3 同阶。
//! - `rated:`：统计表 `stats`（有效复习投影，主键 `(col, at, log)` 按时刻聚簇，范围扫）。
//! - `anki_dupes`：笔记行上的查重规范形，`notes_dupe (col, dupe_norm)` 索引（schema 40016 加的，协议 3 v15 的
//!   `idx_srs_notes_cache_dupe`）；牌组范围按 `cards_note` 读可见卡。
//!
//! # 常驻会话的失效：按代号（[Browse::run]）
//!
//! 协议 3 靠写连接上的临时触发器把写过的缓存行 id 记进内存的「待重读」，事务边界另有一套判据。新代的写入一律经
//! `Native::write` / 收段的 `ingest_settle` 走 [Index::settle]，缓存层的刷新在那里**自己记账**（`cache.rs` 文件头
//! 「变更记录」）：每次收尾里行可能变了的笔记记进 `cache_log`、代号 `cache_gen.gen` + 1；整层重建把下限 `floor` 抬到
//! 新代号。变更记录与缓存行同一个事务落库，回滚一起回滚，也看得见别的连接（主进程写入者、收段线程）的提交。
//!
//! 会话记着它对上的代号（`Session::stamp`）。每条命令在**同一个读快照**里：
//!
//! 1. 读 `(gen, floor)`。会话的代号 = gen：什么都不重读。
//! 2. 代号 < floor（中间有过整层重建 / 记录攒多了从旧的一头被截掉）或 > gen（库被换过、或代号不连续），或会话代号
//!    之后变了的笔记多于 [REFRESH_CAP]（按这个会话自己落下的量算，跟得上的会话不受别人累计的写入影响）：整份重建
//!    （协议 3 的 `overflow`）。
//! 3. 否则读 `cache_log` 里代号 > 会话代号的笔记，连同这些笔记在会话里的卡和库里的卡（`cards_note`），交给
//!    `Session::apply` 按 id 重读——以库里的行为准，同协议 3。按笔记记账而不按卡：一张卡的行变了它所属笔记必在
//!    记录里（`cache.rs` 写卡行时记它的笔记），删掉的卡、换了笔记的卡都经「会话里这条笔记的卡」找回来。
//!
//! **在调用方的写事务里读**（连接不在自动提交）：读到的可能是还没提交的代号，之后可能被回滚、同一个代号再被别的内容
//! 提交。所以这时**不推进**会话的代号，并把这次重读的笔记记成「可疑」（[Browse::suspect]）：下一条命令照常按代号重读，
//! 再并上可疑的笔记（回滚掉的改动按库里的行改回来）；在写事务里整份重建的会话代号记成 -1，下一条命令整份重建。
//!
//! 会话表属于一个打开的库文件（命令层持有，换文件就换一份 [Browse]）；代号只在同一个文件里有意义。
//!
//! # ID（D24，规范 ID）
//!
//! 会话里的 ID 都是规范 ID（缓存层按规范 ID 物化），回包里也是。请求里的 ID 先按同一份别名表归一（[canon_req]，与会话
//! 同一个读快照）：笔记类型（及字段、模板）、牌组（`decks` / `deckModels` 的键；同一个类在一张表里有几个键时取规范 ID
//! 自己的，否则成员里 SQLite 序最小的，同 `stats.rs`）、`instant` 的卡、`browse_ids` 的 `find`、`browse_targets` 的
//! `ids`、`anki_dupes` 的笔记类型 / 牌组。搜索语法树里的 `nid:` / `cid:`（AnkiConnect 数字 id）认别名类成员的号：
//! 换代前客户端记下的是带盐原值 ID 的号，按 `columns.rs` 同一个反查换成规范 ID 的号。
//!
//! # 与协议 3 的差别
//!
//! - **ID** 见上。`browse_ids` 的 `find` 里两个 ID 归一到同一行时各自都给出那一行。
//! - **修改时间**（`Column::Modified`、行里的修改时刻）取活着的修改行的 HLC 物理时刻（同协议 3 的判据），但新代的修改
//!   行按类归并（`class.rs`），带盐副本各自的写入并成一份。
//! - 查询结果的代号（`gen`）是进程内递增的号，与协议 3 共用同一个计数器。
//!
//! # 代价
//!
//! 没有写入时每条命令多一次 `cache_gen` 主键点读。有写入时：一次 `cache_log` 主键范围扫（代号 > 会话代号）+ 每条变了的
//! 笔记一次 `cards_note` 点读 + 会话里卡的一遍线性扫（找这些笔记的旧卡，O(会话卡数)，十万张卡约 1 ms）+ 按 id 重读。
//! 整份建会话：`notes` / `cards` 各一次顺序扫（同协议 3）。
//!
//! 取修改行（`edits_with`，`edited:`、按修改时间排序、全文检索首次都走它）每条笔记一次按类判定（[Index::class_lines]）；
//! 要合成 `tags` 行时（不限键、或键里有 `tags`）再加每份成员一次 `tag_ix` / `reg_ix` 查询 + 每条标签操作一次日志点读
//! + 一次按类求标签值（`cmd/mod.rs` `tags_line`）。只要字段键时不拼这一行，不付这份。

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

use rusqlite::OptionalExtension;
use serde_json::Value;

use super::columns::{Table, resolve};
use super::{Files, Sel, canon_keyed, ref_of, snapshot};
use crate::registers::StoredEdit;
use crate::store::browse::{self, Card, Note, Sessions, Source, card_of, note_of};
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::store::queue::Dirty;
use crate::store::schema::anki_numeric_id;
use crate::sync2::op::EntKind;

/// 笔记行的列（与 `browse::NOTE_COLUMNS` 一一对应，ID 列是存储形）。
const NOTE_COLS: &str =
    "id, note_type_id, created_at, sort_field, tags_json, pending_decision, anki_id, dupe_norm";

/// 卡片行的列（与 `browse::CARD_COLUMNS` 一一对应）。
const CARD_COLS: &str = "id, note_id, template_id, cloze_ord, deck_id, suspended, buried_until_day, flag, queue, \
     due_day, due_at, scheduled_days, reps, lapses, stability, difficulty, last_reviewed_at, anki_id";

/// 新代的读法：集合 [col] 的缓存层与索引层，在调用方的读快照里。
pub(super) struct G4<'t, 'c> {
    t: &'t Truth<'c>,
    col: i64,
    ix: RefCell<Index<'t, 'c>>,
}

impl<'t, 'c> G4<'t, 'c> {
    pub(super) fn new(t: &'t Truth<'c>, col: i64) -> G4<'t, 'c> {
        G4 {
            t,
            col,
            ix: RefCell::new(Index::new(t, col)),
        }
    }

    fn refs(ids: &[String]) -> Vec<Ref> {
        ids.iter().map(|s| ref_of(s)).collect()
    }

    /// [q] 的每行第 0 列是一个 ID（存储形），交回文本。
    fn id_list(&self, q: &Sel) -> Result<Vec<String>, String> {
        let mut out = Vec::new();
        q.each(self.t, |r| {
            out.push(r.get::<_, Ref>(0).map_err(sql)?.text());
            Ok(())
        })?;
        Ok(out)
    }

    /// 这几条笔记在库里的卡（含隐藏的；会话按可见与否自己判）。
    fn cards_of(&self, notes: &[String]) -> Result<Vec<String>, String> {
        if notes.is_empty() {
            return Ok(Vec::new());
        }
        let mut q = Sel::of(self.col);
        let ids = q.ids(&Self::refs(notes));
        q.push(&format!(
            "SELECT id FROM cards WHERE col = ?1 AND note_id IN {ids}"
        ));
        self.id_list(&q)
    }
}

impl Source for G4<'_, '_> {
    fn notes(
        &self,
        ids: Option<&[String]>,
        sink: &mut dyn FnMut(Note) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut q = Sel::of(self.col);
        match ids {
            None => q.push(&format!(
                "SELECT {NOTE_COLS} FROM notes WHERE col = ?1 AND deleted_at IS NULL"
            )),
            Some(ids) => {
                let ids = q.ids(&Self::refs(ids));
                q.push(&format!(
                    "SELECT {NOTE_COLS} FROM notes WHERE col = ?1 AND id IN {ids} AND deleted_at IS NULL"
                ));
            }
        }
        q.each(self.t, |r| sink(note_of(r).map_err(sql)?))
    }

    fn cards(
        &self,
        ids: Option<&[String]>,
        sink: &mut dyn FnMut(Card) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut q = Sel::of(self.col);
        match ids {
            None => q.push(&format!(
                "SELECT {CARD_COLS} FROM cards WHERE col = ?1 AND hidden = 0"
            )),
            Some(ids) => {
                let ids = q.ids(&Self::refs(ids));
                q.push(&format!(
                    "SELECT {CARD_COLS} FROM cards WHERE col = ?1 AND id IN {ids} AND hidden = 0"
                ));
            }
        }
        q.each(self.t, |r| sink(card_of(r).map_err(sql)?))
    }

    fn edits(
        &self,
        notes: Option<&[String]>,
        keys: &[String],
        sink: &mut dyn FnMut(&str, &[StoredEdit<'_>]) -> Result<(), String>,
    ) -> Result<(), String> {
        let all: Vec<String>;
        let notes: &[String] = match notes {
            Some(ids) => ids,
            None => {
                let mut q = Sel::of(self.col);
                q.push("SELECT id FROM notes WHERE col = ?1 AND deleted_at IS NULL");
                all = self.id_list(&q)?;
                &all
            }
        };
        let mut ix = self.ix.borrow_mut();
        // 归回的写入者表与规则表在这一条命令里不变（同一个读快照）：按类拼行每条笔记都要它，读一次（同 `cache.rs` 的
        // `cache_pass`），不让每条笔记各读一遍整张表。
        ix.in_read_pass(|ix| edits_with(self.t, ix, notes, keys, sink))
    }

    fn rated(&self, since: i64, rating: Option<i64>) -> Result<Vec<String>, String> {
        let mut q = Sel::of(self.col);
        let since = q.int(since);
        q.push(&format!(
            "SELECT card FROM stats WHERE col = ?1 AND at >= {since} AND rating IS NOT NULL"
        ));
        if let Some(e) = rating {
            let e = q.int(e);
            q.push(&format!(" AND rating = {e}"));
        }
        // 不写 `DISTINCT`：那样计划会改走 `stats_card` 把整个集合按卡走一遍；按时刻范围扫、在这里去重（先出现的在前）。
        let mut seen: HashSet<String> = HashSet::new();
        Ok(self
            .id_list(&q)?
            .into_iter()
            .filter(|c| seen.insert(c.clone()))
            .collect())
    }

    fn dupe_notes(&self, norms: &[String]) -> Result<Vec<(String, String, String)>, String> {
        let mut q = Sel::of(self.col);
        let list = q.text(&Value::from(norms.to_vec()).to_string());
        q.push(&format!(
            "SELECT id, note_type_id, dupe_norm FROM notes WHERE col = ?1 \
             AND dupe_norm IN (SELECT value FROM json_each({list})) AND deleted_at IS NULL"
        ));
        let mut out = Vec::new();
        q.each(self.t, |r| {
            out.push((
                r.get::<_, Ref>(0).map_err(sql)?.text(),
                r.get::<_, Ref>(1).map_err(sql)?.text(),
                r.get(2).map_err(sql)?,
            ));
            Ok(())
        })?;
        Ok(out)
    }

    fn note_decks(&self, notes: &[&str]) -> Result<Vec<(String, String)>, String> {
        let mut q = Sel::of(self.col);
        let refs: Vec<Ref> = notes.iter().map(|s| ref_of(s)).collect();
        let ids = q.ids(&refs);
        q.push(&format!(
            "SELECT note_id, deck_id FROM cards WHERE col = ?1 AND note_id IN {ids} AND hidden = 0"
        ));
        let mut out = Vec::new();
        q.each(self.t, |r| {
            out.push((
                r.get::<_, Ref>(0).map_err(sql)?.text(),
                r.get::<_, Ref>(1).map_err(sql)?.text(),
            ));
            Ok(())
        })?;
        Ok(out)
    }
}

/// [Source::edits] 的本体：[notes] 每条的修改行（[keys] 非空 = 只要这些键的），交给 [sink]。
///
/// 行与读命令同一份（[super::edit_rows]）：按类判定活着的修改行，笔记的 `tags` 是那一行合成行（`hlc` = 最后一条标签
/// 操作，与协议 3 修改记录表 `srs_field_edits` 里的那一行同形）。新代的标签增删是 `tag_ix` 里的 OR-Set 操作，不进寄存器、
/// 不在 [Index::class_lines] 里；只拿寄存器行时 `edited:` 与按修改时间排漏掉最后一次改标签。合成行的键不是 `f/` 开头，
/// 不当字段原文（`registers::note_browse_values`）。
fn edits_with(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    notes: &[String],
    keys: &[String],
    sink: &mut dyn FnMut(&str, &[StoredEdit<'_>]) -> Result<(), String>,
) -> Result<(), String> {
    // 只要字段键时不拼合成 `tags` 行（文件头「代价」）。
    let tags = keys.is_empty() || keys.iter().any(|k| k == "tags");
    for id in notes {
        let rows = super::edit_rows_with(t, ix, EntKind::Note, &ref_of(id), "", tags)?;
        let stored: Vec<StoredEdit<'_>> = rows
            .iter()
            .filter(|(f, _, _)| keys.is_empty() || keys.iter().any(|k| k == f))
            .map(|(_, j, s)| (j.as_str(), *s, None))
            .collect();
        if stored.is_empty() {
            continue;
        }
        sink(id, &stored)?;
    }
    Ok(())
}

/// 新代的浏览会话表：一个打开的库文件一份（命令层持有：`kernel.rs` `G4Core` 的 `browse`，在它自己的锁里）。会话按
/// 集合号分。
#[derive(Default)]
pub struct Browse {
    sessions: Sessions,
    /// 集合 → 在调用方的写事务里重读过的笔记（模块文件头「在调用方的写事务里读」）：下一条命令再重读一遍。
    suspect: HashMap<i64, HashSet<String>>,
}

impl Browse {
    pub fn new() -> Browse {
        Browse::default()
    }

    /// 一条浏览命令（op 见模块文件头）：一条命令一个读快照（`snapshot`）；会话按代号对上库此刻再跑。
    pub fn run(
        &mut self,
        t: &Truth<'_>,
        col: i64,
        op: &str,
        req: &Value,
        files: &mut Files,
    ) -> Result<Value, String> {
        let key = col.to_string();
        match op {
            "browse_close" => {
                let out = self
                    .sessions
                    .close(&key, req.get("owner").and_then(Value::as_str));
                if !self.sessions.has(&key) {
                    self.suspect.remove(&col);
                }
                return Ok(out);
            }
            "browse_stats" => return Ok(self.sessions.stats(&key)),
            "anki_dupes" => {
                // 不碰会话（也不登记持有者）：查的是笔记行上的规范形列。
                return snapshot(t, |t| {
                    let src = G4::new(t, col);
                    let req = canon_req(&src, op, req)?;
                    browse::dupes(&src, &req)
                });
            }
            _ => {}
        }
        let tentative = !t.conn().is_autocommit();
        let Browse { sessions, suspect } = self;
        let suspect = suspect.entry(col).or_default();
        let out = snapshot(t, |t| {
            let src = G4::new(t, col);
            let req = canon_req(&src, op, req)?;
            sessions.run(&key, op, &req, files, &src, &mut |s| {
                refresh(&src, s, tentative, suspect)
            })
        });
        if !sessions.has(&key) {
            // 会话出错被丢掉：可疑的笔记随它作废（下次整份重建）。
            suspect.clear();
        }
        out
    }
}

/// 一个会话一次最多按笔记重读这么多条；落下更多就整份重建（模块文件头「常驻会话的失效」第 2 步；协议 3 浏览的
/// `DIRTY_CAP` 也是按单个会话攒的量算）。
pub(super) const REFRESH_CAP: usize = 4096;

/// 会话 [s] 怎么对上库此刻（模块文件头「常驻会话的失效」）：(待重读的 id 或整份重建, 对上之后的代号)。
fn refresh(
    src: &G4<'_, '_>,
    s: Option<&browse::Session>,
    tentative: bool,
    suspect: &mut HashSet<String>,
) -> Result<(Dirty, i64), String> {
    let (gen, floor): (i64, i64) = src
        .t
        .conn()
        .prepare_cached("SELECT gen, floor FROM cache_gen WHERE col = ?1")
        .map_err(sql)?
        .query_row([src.col], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(sql)?
        .unwrap_or((0, 0));
    let rebuild = |suspect: &mut HashSet<String>| {
        suspect.clear();
        let dirty = Dirty {
            overflow: true,
            ..Dirty::default()
        };
        (dirty, if tentative { -1 } else { gen })
    };
    let Some(s) = s else {
        return Ok(rebuild(suspect));
    };
    let seen = s.stamp();
    if seen < floor || seen > gen {
        return Ok(rebuild(suspect));
    }
    let mut notes: HashSet<String> = suspect.iter().cloned().collect();
    if seen < gen {
        let mut q = Sel::of(src.col);
        let seen_p = q.int(seen);
        // 多读一条就知道超没超上限，不把一大段记录全读出来。
        let cap = q.int(REFRESH_CAP as i64 + 1);
        q.push(&format!(
            "SELECT DISTINCT note FROM cache_log WHERE col = ?1 AND gen > {seen_p} LIMIT {cap}"
        ));
        notes.extend(src.id_list(&q)?);
    }
    if notes.len() > REFRESH_CAP {
        // 这个会话落下的太多（导入、大同步收段）：逐条重读不如整份重建（协议 3 的 `DIRTY_CAP`，按单个会话算）。
        return Ok(rebuild(suspect));
    }
    let mut cards: HashSet<String> = s.cards_of_notes(&notes).into_iter().collect();
    let list: Vec<String> = notes.iter().cloned().collect();
    cards.extend(src.cards_of(&list)?);
    if tentative {
        suspect.extend(notes.iter().cloned());
    } else {
        suspect.clear();
    }
    let dirty = Dirty {
        cards,
        notes,
        ..Dirty::default()
    };
    Ok((dirty, if tentative { seen } else { gen }))
}

/// 请求里按 ID 给的东西归一成规范 ID（模块文件头「ID」）。别的字段原样。
pub(super) fn canon_req(src: &G4<'_, '_>, op: &str, req: &Value) -> Result<Value, String> {
    let ix = src.ix.borrow();
    let canon = |s: &str| -> Result<String, String> { Ok(ix.canonical(&ref_of(s))?.text()) };
    let mut out = req.clone();
    let Some(obj) = out.as_object_mut() else {
        return Ok(out);
    };
    let canon_str = |v: &mut Value| -> Result<(), String> {
        if let Some(s) = v.as_str() {
            *v = Value::String(canon(s)?);
        }
        Ok(())
    };
    if let Some(Value::Array(types)) = obj.get_mut("types") {
        for t in types.iter_mut() {
            for k in ["id", "sort"] {
                if let Some(id) = t.get_mut(k) {
                    canon_str(id)?;
                }
            }
            if let Some(Value::Array(xs)) = t.get_mut("preview") {
                for x in xs.iter_mut() {
                    canon_str(x)?;
                }
            }
            for k in ["fields", "tpls"] {
                if let Some(Value::Array(xs)) = t.get_mut(k) {
                    for x in xs.iter_mut() {
                        if let Some(id) = x.get_mut(0) {
                            canon_str(id)?;
                        }
                    }
                }
            }
        }
    }
    for k in ["decks", "deckModels"] {
        if let Some(Value::Object(m)) = obj.get_mut(k) {
            *m = canon_keyed(&ix, m)?;
        }
    }
    for k in ["instant", "find", "ids"] {
        if let Some(Value::Array(xs)) = obj.get_mut(k) {
            for x in xs.iter_mut() {
                canon_str(x)?;
            }
        }
    }
    if op == "anki_dupes" {
        if let Some(Value::Object(first)) = obj.get_mut("first") {
            // 笔记类型 → 首字段：键按牌组表同一个取舍归一（与键的先后无关），值（字段 ID）再归一。
            let mut m = canon_keyed(&ix, first)?;
            for v in m.values_mut() {
                canon_str(v)?;
            }
            *first = m;
        }
        if let Some(Value::Array(cands)) = obj.get_mut("cands") {
            for c in cands.iter_mut() {
                if let Some(ty) = c.get_mut("type") {
                    canon_str(ty)?;
                }
                if let Some(Value::Array(ds)) = c.get_mut("decks") {
                    for d in ds.iter_mut() {
                        canon_str(d)?;
                    }
                }
            }
        }
    }
    drop(ix);
    if let Some(node) = obj.get_mut("node") {
        canon_numbers(src, node)?;
    }
    if let Some(Value::Array(nodes)) = obj.get_mut("nodes") {
        for node in nodes.iter_mut() {
            canon_numbers(src, node)?;
        }
    }
    Ok(out)
}

/// 语法树里 `nid:` / `cid:` 的数字 id：认别名类成员的号（换成规范 ID 的号，`columns.rs` 同一个反查）；查不到的原样
/// （照样什么都不命中）。
fn canon_numbers(src: &G4<'_, '_>, node: &mut Value) -> Result<(), String> {
    let table = match node.get("t").and_then(Value::as_str) {
        Some("nid") => Some(Table::Notes),
        Some("cid") => Some(Table::Cards),
        _ => None,
    };
    if let Some(table) = table {
        if let Some(Value::Array(xs)) = node.get_mut("v") {
            for x in xs.iter_mut() {
                if let Some(n) = x.as_i64() {
                    if let Some(r) = resolve(src.t, src.col, table, n)? {
                        *x = Value::from(anki_numeric_id(&r.text()));
                    }
                }
            }
        }
        return Ok(());
    }
    match node.get_mut("c") {
        Some(Value::Array(kids)) => {
            for k in kids.iter_mut() {
                canon_numbers(src, k)?;
            }
        }
        Some(k @ Value::Object(_)) => canon_numbers(src, k)?,
        _ => {}
    }
    Ok(())
}
