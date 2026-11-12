//! 派生层的索引（设计 §2.2、§2.5、§3.4）：实体、寄存器、日志、旧闭包。全部是真相层（[super::truth]）的函数——
//! [Index::rebuild_all] 清空后从日志重建，结果与逐条维护出来的逐行相同（测试钉死）。
//!
//! # 表
//!
//! - `ent_ix(col, id, k, kind, win)`：身份记录。同一个 ID 可以有多条（两台设备各建了一条）；`win = 1` 的那条是这个
//!   实体的定义：规范 JSON 文本最小的，内容相同取操作号最小的（协议 3 `project_entity` 的规则去掉「谁先到」）。
//! - `reg_ix(col, ekind, ent, key, k, state)`：寄存器的全部写入。`key` 是修改键的紧凑字节形（`gen4::name`）。
//!   `state`：0 = 被别的写入支配（或与另一条写入是同一个 dot、不是代表）；1 = 没被支配、不是胜者；2 = 胜者；
//!   3 = 胜者，且有值不同的并发写入（冲突）。
//! - `log_ix(col, card, at, k, id, win)` + 索引 `log_id(col, id, k)`：日志。同一个日志 ID 的多条取操作号最小的
//!   （`win = 1`；协议 3 是「先到的留」，再靠去重作业收敛到设备 ID 最小的那份）。统计列不在这里：它们是重放的输出，
//!   属于缓存层（设计 §2.7 第 2 条）。
//! - `closure_ix(col, device, upto, ctx)`：每台承袭设备的旧闭包（协议 3 的 `sync2_legacy`，改成可重建）：它日志里全部
//!   旧戳的 dot 与上下文之并；`upto` = 带旧戳的最大 seq。
//!
//! 标签、媒体、彻底清除、被扣住的删除在 [super::weigh]（同一个 [Index]，表与规则见那里）。`reg_ix.state` 另有三个负值
//! （[super::weigh::S_PURGED] / [super::weigh::S_HELD] / [super::weigh::S_DISTRUSTED]）：这条写入不参与寄存器的判定。
//! 笔记的 `tags` 整列表写入不进 `reg_ix`——它是标签 OR-Set 的操作（协议 3 同）。
//!
//! 索引里的 ID 都是操作体里的原值，没有归一成规范 ID：别名是另一张派生表的事（设计 §5.3；§10 第 18 条未决，
//! 不在这一层焊死任何一种答法）。
//!
//! # 冻结的旧判定（设计 §3.4）
//!
//! 谁支配谁、谁是胜者，判据只有 `crate::registers` 那一份（[judge_register]）。这里做的是把操作体拼成它要的行：
//!
//! - 带旧戳的修改：dot、上下文、HLC 都取旧戳的（HLC 用旧戳里那份文本）。
//! - 不带旧戳的修改（协议 3 的原生写入、协议 4 的写入）：dot = (设备, seq)；上下文 = 作者写时见过的每台设备的
//!   前缀，并上那些前缀覆盖到的旧闭包（协议 3 `edit_row_with` 同义）。闭包可能很大，所以不物化：只问「含不含这个
//!   寄存器里别的 dot」，把答案拼成上下文交给判据——判据只用到这些问题。
//! - 同一个 dot 的多条（同一条旧修改被两台设备各迁了一遍、还没认副本）是一次写入：取操作号最小的当代表，
//!   `server_time` 取最小值（协议 3 的 `upsert_server_time`）。
//!
//! 与协议 3 的差别只有一处，是有意的：协议 3 在落库时裁剪（被支配的删掉、上下文按落库那一刻的闭包定死），结果
//! 依赖到达顺序；这里对全集判，与顺序无关。
//!
//! # 用法
//!
//! 真相层每落一条 / 推进一条之后告诉索引：新落的 [Index::add]；被换掉、被清除、认了副本的，改之前的样子
//! [Index::remove]、改之后的样子 [Index::add]。一批做完 [Index::settle]。都在调用方的事务里。

use std::collections::{BTreeMap, BTreeSet, HashMap};

use rusqlite::params;
use rusqlite::types::{FromSql, FromSqlError, FromSqlResult, ToSql, ToSqlOutput, ValueRef};
use serde_json::{Map, Value, json};

use super::schema::{DERIVED_TABLES, sql};
use super::truth::{Entry, Head, Truth};
use super::weigh::{E_LOG, E_MOVE, S_HELD, T_ADD, T_INERT, T_ORDER, T_REMOVE};
use crate::gen4::heritage::SlotBody;
use crate::gen4::name::{read_edit_key, write_edit_key};
use crate::gen4::op::{Body4, Edit4};
use crate::gen4::stamp::{HeritageStamp, SYNTHETIC_PREFIX};
use crate::gen4::translate::applied_body;
use crate::registers::{StoredEdit, judge_register};
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::dvv::Dvv;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::EntKind;
use crate::sync2::vv::{OpId, Vv};

/// `reg_ix.state`：被支配，或是同一个 dot 里不当代表的那条。
pub const R_DOMINATED: i64 = 0;
/// `reg_ix.state`：没被支配，不是胜者。
pub const R_LIVE: i64 = 1;
/// `reg_ix.state`：胜者。
pub const R_WINNER: i64 = 2;
/// `reg_ix.state`：胜者，且有值不同的并发写入。
pub const R_CONFLICT: i64 = 3;

/// 引用（实体、卡、日志的 ID）在索引里的样子：规范 UUID 存 16 字节，其余存文本。
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Ref {
    Uuid([u8; 16]),
    Text(String),
}

impl Ref {
    /// 原样件解出来的引用可能是 UUID 的文本形（`gen4::translate::applied_body`）：先归成唯一的那种。
    pub fn of(k: &Key) -> Ref {
        match Key::of(&k.text()) {
            Key::Uuid(id) => Ref::Uuid(id.0),
            Key::Text(s) => Ref::Text(s),
        }
    }

    pub fn text(&self) -> String {
        match self {
            Ref::Uuid(b) => Id(*b).text(),
            Ref::Text(s) => s.clone(),
        }
    }
}

impl ToSql for Ref {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        Ok(ToSqlOutput::Borrowed(match self {
            Ref::Uuid(b) => ValueRef::Blob(b),
            Ref::Text(s) => ValueRef::Text(s.as_bytes()),
        }))
    }
}

impl FromSql for Ref {
    fn column_result(v: ValueRef<'_>) -> FromSqlResult<Ref> {
        match v {
            ValueRef::Blob(b) => {
                <[u8; 16]>::try_from(b)
                    .map(Ref::Uuid)
                    .map_err(|_| FromSqlError::InvalidBlobSize {
                        expected_size: 16,
                        blob_size: b.len(),
                    })
            }
            ValueRef::Text(t) => std::str::from_utf8(t)
                .map(|s| Ref::Text(s.to_owned()))
                .map_err(|e| FromSqlError::Other(Box::new(e))),
            _ => Err(FromSqlError::InvalidType),
        }
    }
}

/// 一个寄存器：(实体种类, 实体, 修改键的紧凑字节形)。
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct Reg {
    pub(super) ekind: i64,
    pub(super) ent: Ref,
    pub(super) key: Vec<u8>,
}

impl Reg {
    pub(super) fn new(kind: EntKind, entity: &Key, key: &str) -> Reg {
        let mut w = Writer::new();
        write_edit_key(&mut w, key);
        Reg {
            ekind: kind as i64,
            ent: Ref::of(entity),
            key: w.into_vec(),
        }
    }
}

/// 这一条应用成什么（副本记录、空洞、不认识的种类 = 不应用）。
pub(super) fn body_of(e: &Entry) -> Option<Body4> {
    match e.slot() {
        Some(slot) => applied_body(&slot),
        None => e
            .op()
            .and_then(|op| op.body().ok())
            .filter(|b| !matches!(b, Body4::Unknown)),
    }
}

/// 盐的读入点：带盐的种类只有两个——Salts（种类 15，集合自己的初始盐）与 Join（被并入集合带来的盐表）。别处不读盐。
/// 读到的记进 `salt_ix`；集合的盐集合 = 其中**本机信任的作者**写的那些之并（`alias.rs` 的 `settle_salts`；设计 §5.1、
/// `gen4::op` 文件头「盐集合」）。
fn salts_of(body: &Body4) -> Vec<&str> {
    match body {
        Body4::Salts { salts } => salts.iter().map(String::as_str).collect(),
        Body4::Join(j) => j.salts.iter().map(String::as_str).collect(),
        _ => Vec::new(),
    }
}

/// 一台设备的旧闭包，边扫边攒。
#[derive(Default)]
struct Acc {
    upto: u64,
    vv: BTreeMap<String, i64>,
    cloud: BTreeMap<String, BTreeSet<i64>>,
}

impl Acc {
    fn note(&mut self, seq: u64, s: &HeritageStamp) {
        self.upto = self.upto.max(seq);
        for e in s.ctx.entries() {
            if e.vv > 0 {
                let top = self.vv.entry(e.writer.clone()).or_insert(0);
                *top = (*top).max(e.vv as i64);
            }
            if !e.cloud.is_empty() {
                self.cloud
                    .entry(e.writer.clone())
                    .or_default()
                    .extend(e.cloud.iter().map(|&s| s as i64));
            }
        }
        // 合成写入者不进闭包（协议 3 `note_legacy`）。
        if s.seq > 0 && !s.writer.starts_with(SYNTHETIC_PREFIX) {
            self.cloud
                .entry(s.writer.clone())
                .or_default()
                .insert(s.seq);
        }
    }

    fn finish(self) -> (u64, Dvv) {
        let mut d = Dvv::default();
        d.merge(&Dvv {
            vv: self.vv,
            cloud: self.cloud,
        });
        d.drop_writers(SYNTHETIC_PREFIX);
        (self.upto, d)
    }
}

/// [Index::settle] / [Index::rebuild_all] 做了多少。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Settled {
    /// 重判的寄存器。
    pub registers: u64,
    /// 其中写入不止一条、真的过了判据的。
    pub judged: u64,
    /// 重选定义的实体 / 重选代表的日志 ID。
    pub entities: u64,
    pub logs: u64,
    /// 变了的旧闭包。
    pub closures: u64,
    /// 重看了彻底清除的实体、重看了删除该不该扣住的实体、重算了标签的笔记、重判了的媒体名。
    pub purged: u64,
    pub holds: u64,
    pub notes: u64,
    pub media: u64,
    /// 走过的日志条数（只有重建）。
    pub scanned: u64,
    /// 别名表重算后写的行数（没重算 = 0）、重算了语义摘要的实体数。
    pub aliases: u64,
    pub digests: u64,
}

/// 一个集合的派生索引。
pub struct Index<'t, 'c> {
    pub(super) t: &'t Truth<'c>,
    pub(super) col: i64,
    pub(super) regs: BTreeSet<Reg>,
    ents: BTreeSet<Ref>,
    logs: BTreeSet<Ref>,
    /// 这一批碰过的实体（种类, ID）：清除与扣住要重看。
    pub(super) touched: BTreeSet<(i64, Ref)>,
    /// 标签操作变了的笔记、绑定变了的媒体名。
    pub(super) notes: BTreeSet<Ref>,
    pub(super) names: BTreeSet<String>,
    /// 有 Purge 操作进出，或信任状态变了：清除要整体重看。
    pub(super) purge_changed: bool,
    /// 信任状态变了：全部删除重看。
    pub(super) trust_changed: bool,
    /// 还没信任的设备（本机状态，用到时读一次）。
    pub(super) untrusted: Option<BTreeSet<Id>>,
    /// 这一轮收尾里读过的信封。
    pub(super) heads: HashMap<i64, Head>,
    /// 旧戳变了、闭包要重算的设备。
    stale: BTreeSet<Id>,
    /// 有旧戳被拿走过（清除、换版本）：不是单纯往日志末尾添。
    shrunk: bool,
    /// 重建时：边扫边攒的闭包（这时不记上面四个集合）。
    bulk: Option<HashMap<Id, Acc>>,
    closures: Option<HashMap<Id, (u64, Dvv)>>,
    /// 只覆盖了一台设备旧戳的一部分时的闭包（少见），按 (设备, seq) 记。
    partial: HashMap<(Id, u64), Dvv>,
    /// 别名证据变了，别名表要重算（`alias.rs`）。
    pub(super) alias_dirty: bool,
    /// 重算先攒着（[Index::hold_aliases]）。
    pub(super) alias_held: bool,
    /// 带盐的操作进出过，或信任状态变了：盐集合要重算。
    pub(super) salts_dirty: bool,
}

impl<'t, 'c> Index<'t, 'c> {
    pub fn new(t: &'t Truth<'c>, col: i64) -> Index<'t, 'c> {
        Index {
            t,
            col,
            regs: BTreeSet::new(),
            ents: BTreeSet::new(),
            logs: BTreeSet::new(),
            touched: BTreeSet::new(),
            notes: BTreeSet::new(),
            names: BTreeSet::new(),
            purge_changed: false,
            trust_changed: false,
            untrusted: None,
            heads: HashMap::new(),
            stale: BTreeSet::new(),
            shrunk: false,
            bulk: None,
            closures: None,
            partial: HashMap::new(),
            alias_dirty: false,
            alias_held: false,
            salts_dirty: false,
        }
    }

    pub(super) fn writing(&self) -> Result<(), String> {
        if self.t.conn().is_autocommit() {
            return Err("gen4 index: write outside a transaction".to_owned());
        }
        Ok(())
    }

    /// 丢掉内存里的状态（事务回滚之后必须调）。
    pub fn reset(&mut self) {
        let held = self.alias_held;
        *self = Index::new(self.t, self.col);
        self.alias_held = held;
    }

    // ------------------------------------------------------------ 逐条维护

    /// 日志里新有了这一条（或者一条被改成了这个样子）。
    pub fn add(&mut self, e: &Entry) -> Result<(), String> {
        self.touch(e, true)
    }

    /// 日志里的这一条要被换掉 / 清除 / 认成副本了：传改之前的样子。
    pub fn remove(&mut self, e: &Entry) -> Result<(), String> {
        self.touch(e, false)
    }

    fn stamp_changed(&mut self, id: &OpId, s: &HeritageStamp, add: bool) {
        match &mut self.bulk {
            Some(acc) => acc.entry(id.device).or_default().note(id.seq, s),
            None => {
                self.stale.insert(id.device);
                self.shrunk |= !add;
            }
        }
    }

    fn touch(&mut self, e: &Entry, add: bool) -> Result<(), String> {
        self.writing()?;
        if let SlotBody::Alias(a) = &e.body {
            // 副本记录不应用，但它的旧戳算进闭包（协议 3 的副本骨架同理）。
            if let Some(s) = &a.stamp {
                if self.bulk.is_none() {
                    self.alias_stamp(s)?;
                }
                self.stamp_changed(&e.id, s, add);
            }
            return Ok(());
        }
        let Some(body) = body_of(e) else {
            return Ok(());
        };
        let k = self.t.key_of(self.col, &e.id)?.ok_or_else(|| {
            format!(
                "gen4 index: {}:{} is not in this collection",
                e.id.device, e.id.seq
            )
        })?;
        let conn = self.t.conn();
        let bulk = self.bulk.is_some();
        if !bulk {
            self.alias_touch(k, &body, add)?;
        }
        match &body {
            Body4::Entity { kind, id, .. } => {
                let id = Ref::of(id);
                if add {
                    conn.prepare_cached(
                        "INSERT INTO ent_ix (col, id, k, kind, win) VALUES (?1, ?2, ?3, ?4, 1)",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, id, k, *kind as i64])
                    .map_err(sql)?;
                } else {
                    conn.prepare_cached("DELETE FROM ent_ix WHERE col = ?1 AND id = ?2 AND k = ?3")
                        .map_err(sql)?
                        .execute(params![self.col, id, k])
                        .map_err(sql)?;
                }
                if !bulk {
                    self.ents.insert(id);
                }
            }
            Body4::Edit(ed) if ed.kind == EntKind::Note && ed.key == "tags" => {
                // 整列表标签（迁移进来的旧记录）：标签 OR-Set 的操作，不是寄存器。旧戳照样进闭包。
                let note = Ref::of(&ed.entity);
                let mut rows: Vec<(i64, &str)> = Vec::new();
                let parsed = serde_json::from_str::<Value>(&ed.value).ok();
                match &parsed {
                    Some(Value::Array(xs)) => {
                        rows.extend(xs.iter().filter_map(Value::as_str).map(|x| (T_ADD, x)));
                        rows.push((T_ORDER, ""));
                    }
                    _ => rows.push((T_INERT, "")),
                }
                self.tag_rows(&note, k, &rows, add)?;
                if let Some(s) = &ed.stamp {
                    self.stamp_changed(&e.id, s, add);
                }
                if !bulk {
                    self.touched.insert((EntKind::Note as i64, note.clone()));
                    self.notes.insert(note);
                }
            }
            Body4::TagAdd { note, tag } | Body4::TagRemove { note, tag } => {
                let note = Ref::of(note);
                let what = if matches!(body, Body4::TagAdd { .. }) {
                    T_ADD
                } else {
                    T_REMOVE
                };
                self.tag_rows(&note, k, &[(what, tag.as_str())], add)?;
                if !bulk {
                    self.touched.insert((EntKind::Note as i64, note.clone()));
                    self.notes.insert(note);
                }
            }
            Body4::TagOrder { note, .. } => {
                let note = Ref::of(note);
                self.tag_rows(&note, k, &[(T_ORDER, "")], add)?;
                if !bulk {
                    self.touched.insert((EntKind::Note as i64, note.clone()));
                    self.notes.insert(note);
                }
            }
            Body4::Purge { kind, entity } => {
                let ent = Ref::of(entity);
                if add {
                    conn.prepare_cached(
                        "INSERT INTO purge_ix (col, ekind, ent, k, state) VALUES (?1, ?2, ?3, ?4, 1)",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, *kind as i64, ent, k])
                    .map_err(sql)?;
                } else {
                    conn.prepare_cached(
                        "DELETE FROM purge_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND k = ?4",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, *kind as i64, ent, k])
                    .map_err(sql)?;
                }
                if !bulk {
                    self.touched.insert((*kind as i64, ent));
                    self.purge_changed = true;
                }
            }
            Body4::Media { name, .. } => {
                if add {
                    conn.prepare_cached(
                        "INSERT INTO media_ix (col, name, k, state) VALUES (?1, ?2, ?3, ?4)",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, name, k, R_WINNER])
                    .map_err(sql)?;
                } else {
                    conn.prepare_cached(
                        "DELETE FROM media_ix WHERE col = ?1 AND name = ?2 AND k = ?3",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, name, k])
                    .map_err(sql)?;
                }
                if !bulk {
                    self.names.insert(name.clone());
                }
            }
            Body4::Edit(ed) => {
                let reg = Reg::new(ed.kind, &ed.entity, &ed.key);
                // 卡挪进了哪个牌组：牌组那边要知道（协议 3 的 `#move`）。
                if ed.kind == EntKind::Card && ed.key == "deck" {
                    if let Ok(Value::String(d)) = serde_json::from_str::<Value>(&ed.value) {
                        let deck = Ref::of(&Key::of(&d));
                        self.ent_op(EntKind::Deck, &deck, E_MOVE, k, add)?;
                        if !bulk {
                            self.touched.insert((EntKind::Deck as i64, deck));
                        }
                    }
                }
                if !bulk {
                    self.touched.insert((reg.ekind, reg.ent.clone()));
                }
                if add {
                    conn.prepare_cached(
                        "INSERT INTO reg_ix (col, ekind, ent, key, k, state) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, reg.ekind, reg.ent, reg.key, k, R_WINNER])
                    .map_err(sql)?;
                } else {
                    conn.prepare_cached(
                        "DELETE FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND key = ?4 AND k = ?5",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, reg.ekind, reg.ent, reg.key, k])
                    .map_err(sql)?;
                }
                if let Some(s) = &ed.stamp {
                    self.stamp_changed(&e.id, s, add);
                }
                if !bulk {
                    self.regs.insert(reg);
                }
            }
            Body4::Log(l) => {
                let (id, card) = (Ref::of(&l.id), Ref::of(&l.card));
                if let Some(n) = &l.note {
                    let note = Ref::of(n);
                    self.ent_op(EntKind::Note, &note, E_LOG, k, add)?;
                    if !bulk {
                        self.touched.insert((EntKind::Note as i64, note));
                    }
                }
                if !bulk {
                    self.touched.insert((EntKind::Card as i64, card.clone()));
                }
                if add {
                    conn.prepare_cached(
                        "INSERT INTO log_ix (col, card, at, k, id, win) VALUES (?1, ?2, ?3, ?4, ?5, 1)",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, card, l.at, k, id])
                    .map_err(sql)?;
                } else {
                    conn.prepare_cached(
                        "DELETE FROM log_ix WHERE col = ?1 AND card = ?2 AND at = ?3 AND k = ?4",
                    )
                    .map_err(sql)?
                    .execute(params![self.col, card, l.at, k])
                    .map_err(sql)?;
                }
                if !bulk {
                    self.logs.insert(id);
                }
            }
            _ => {}
        }
        let salts = salts_of(&body);
        if !salts.is_empty() {
            if add {
                let mut put = conn
                    .prepare_cached(
                        "INSERT OR IGNORE INTO salt_ix (col, k, salt) VALUES (?1, ?2, ?3)",
                    )
                    .map_err(sql)?;
                for s in salts {
                    put.execute(params![self.col, k, s]).map_err(sql)?;
                }
            } else {
                conn.prepare_cached("DELETE FROM salt_ix WHERE col = ?1 AND k = ?2")
                    .map_err(sql)?
                    .execute(params![self.col, k])
                    .map_err(sql)?;
            }
            self.salts_dirty = true;
        }
        Ok(())
    }

    // ------------------------------------------------------------ 旧闭包

    pub(super) fn closures(&mut self) -> Result<&mut HashMap<Id, (u64, Dvv)>, String> {
        if self.closures.is_none() {
            let mut map = HashMap::new();
            let mut stmt = self
                .t
                .conn()
                .prepare_cached("SELECT device, upto, ctx FROM closure_ix WHERE col = ?1")
                .map_err(sql)?;
            let rows = stmt
                .query_map([self.col], |r| {
                    Ok((
                        r.get::<_, [u8; 16]>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                })
                .map_err(sql)?;
            for row in rows {
                let (device, upto, ctx) = row.map_err(sql)?;
                map.insert(Id(device), (upto as u64, Dvv::parse(&ctx)));
            }
            self.closures = Some(map);
        }
        Ok(self.closures.as_mut().expect("just loaded"))
    }

    /// 一台承袭设备的旧闭包：(带旧戳的最大 seq, 闭包)。没有旧戳 = None。
    pub fn closure(&mut self, device: &Id) -> Result<Option<(u64, Dvv)>, String> {
        Ok(self.closures()?.get(device).cloned())
    }

    /// 把一台设备的闭包记成 [acc] 的结果。返回变没变。
    fn put_closure(&mut self, device: &Id, acc: Acc) -> Result<bool, String> {
        let (upto, ctx) = acc.finish();
        let next = (upto > 0).then_some((upto, ctx));
        let col = self.col;
        let conn = self.t.conn();
        let map = self.closures()?;
        if map.get(device) == next.as_ref() {
            return Ok(false);
        }
        match next {
            Some((upto, ctx)) => {
                conn.prepare_cached(
                    "INSERT OR REPLACE INTO closure_ix (col, device, upto, ctx) VALUES (?1, ?2, ?3, ?4)",
                )
                .map_err(sql)?
                .execute(params![
                    col,
                    device.0.to_vec(),
                    upto as i64,
                    ctx.to_json().to_string()
                ])
                .map_err(sql)?;
                map.insert(*device, (upto, ctx));
            }
            None => {
                conn.prepare_cached("DELETE FROM closure_ix WHERE col = ?1 AND device = ?2")
                    .map_err(sql)?
                    .execute(params![col, device.0.to_vec()])
                    .map_err(sql)?;
                map.remove(device);
            }
        }
        Ok(true)
    }

    /// 作者写的时候见过 [full]（每台设备的前缀），算不算见过 dot `(w, q)`：前缀自己含它，或前缀覆盖到的旧闭包含它
    /// （协议 3 `edit_row_with` + `legacy_closure_with`）。
    fn seen(&mut self, full: &Vv, w: &str, q: i64) -> Result<bool, String> {
        if w.starts_with(SYNTHETIC_PREFIX) {
            return Ok(false);
        }
        if let Some(id) = Id::parse(w).filter(|id| id.text() == w) {
            let s = full.get(&id);
            if s > 0 && q <= s as i64 {
                return Ok(true);
            }
        }
        for (d, &s) in &full.0 {
            let whole = match self.closures()?.get(d) {
                None => continue,
                Some((upto, ctx)) if s >= *upto => {
                    if ctx.contains(w, q) {
                        return Ok(true);
                    }
                    true
                }
                Some(_) => false,
            };
            if whole {
                continue;
            }
            // 只覆盖了这台设备旧戳的一部分：逐条并到 s 为止。
            if !self.partial.contains_key(&(*d, s)) {
                let mut acc = Acc::default();
                self.t.for_each_stamp(self.col, d, s, |seq, stamp| {
                    acc.note(seq, stamp);
                    Ok(())
                })?;
                self.partial.insert((*d, s), acc.finish().1);
            }
            if self.partial[&(*d, s)].contains(w, q) {
                return Ok(true);
            }
        }
        Ok(false)
    }

    // ------------------------------------------------------------ 判定

    pub(super) fn reg_rows(&self, r: &Reg) -> Result<Vec<(i64, i64)>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT k, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND key = ?4 ORDER BY k",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, r.ekind, r.ent, r.key], |x| {
                Ok((x.get(0)?, x.get(1)?))
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    /// 重判一个寄存器，把变了的状态写回去。返回它是不是真的过了判据（写入不止一条）。
    fn judge(&mut self, r: &Reg) -> Result<bool, String> {
        // 被清除的、作者不可信的（负状态，`weigh.rs`）不参与判定，状态原样留着。
        let all = self.reg_rows(r)?;
        let rows: Vec<(i64, i64)> = all
            .iter()
            .copied()
            .filter(|&(_, state)| state >= R_DOMINATED)
            .collect();
        let held: Vec<(i64, i64)> = all
            .iter()
            .copied()
            .filter(|&(_, state)| state == S_HELD)
            .collect();
        let want = if !held.is_empty() {
            // 被并发改动扣住的删除：它自己不生效（不当胜者、不算活着），但它见过的写入照样被它盖掉——扣住只是
            // 「这条删除等人裁决」，不是「当它没写过」（否则一条与别人的修改并发的旧删除会绕过扣住直接生效）。
            let mut both = rows.clone();
            both.extend(&held);
            let first = self.states(&both)?;
            let alive: Vec<(i64, i64)> = rows
                .iter()
                .zip(&first)
                .filter(|&(_, &s)| s != R_DOMINATED)
                .map(|(&row, _)| row)
                .collect();
            let mut second = if alive.len() <= 1 {
                vec![R_WINNER; alive.len()]
            } else {
                self.states(&alive)?
            }
            .into_iter();
            rows.iter()
                .zip(&first)
                .map(|(_, &s)| match s {
                    R_DOMINATED => R_DOMINATED,
                    _ => second.next().unwrap_or(R_DOMINATED),
                })
                .collect()
        } else if rows.len() <= 1 {
            vec![R_WINNER; rows.len()]
        } else {
            self.states(&rows)?
        };
        let conn = self.t.conn();
        for (&(k, have), &want) in rows.iter().zip(&want) {
            if have != want {
                conn.prepare_cached(
                    "UPDATE reg_ix SET state = ?6 WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND key = ?4 AND k = ?5",
                )
                .map_err(sql)?
                .execute(params![self.col, r.ekind, r.ent, r.key, k, want])
                .map_err(sql)?;
            }
        }
        Ok(rows.len() > 1)
    }

    /// 一个寄存器里每条写入的状态（与 [rows] 对齐）。
    fn states(&mut self, rows: &[(i64, i64)]) -> Result<Vec<i64>, String> {
        struct Write {
            id: OpId,
            ed: Edit4,
            wall: i64,
            logical: u32,
            full: Vv,
        }
        let mut writes = Vec::with_capacity(rows.len());
        for &(k, _) in rows {
            let e = self
                .t
                .entry_by_key(k)?
                .ok_or_else(|| format!("gen4 index: register row {k} has no op"))?;
            let (wall, logical, deps) = match &e.body {
                SlotBody::Op(op) => (op.hlc.wall, op.hlc.logical, op.deps.clone()),
                SlotBody::Raw3(raw) => {
                    let v = raw.to_v3();
                    (v.hlc.wall, v.hlc.logical, v.deps)
                }
                _ => return Err(format!("gen4 index: register row {k} is not an op")),
            };
            let Some(Body4::Edit(ed)) = body_of(&e) else {
                return Err(format!("gen4 index: register row {k} is not an edit"));
            };
            // 作者的完整上下文：依赖 + 自己之前的全部（协议 3 `Op::ctx`）。
            let mut full = (*deps).clone();
            full.set(e.id.device, e.id.seq - 1);
            writes.push(Write {
                id: e.id,
                ed,
                wall,
                logical,
                full,
            });
        }
        // 同一个 dot 的并成一次写入：代表取操作号最小的，server_time 取最小值。
        let dot = |w: &Write| match &w.ed.stamp {
            Some(s) => (s.writer.clone(), s.seq),
            None => (w.id.device.text(), w.id.seq as i64),
        };
        let mut by_dot: BTreeMap<(String, i64), (usize, Option<i64>)> = BTreeMap::new();
        for (i, w) in writes.iter().enumerate() {
            let st = w.ed.stamp.as_ref().and_then(|s| s.server_time);
            by_dot
                .entry(dot(w))
                .and_modify(|(rep, min)| {
                    if w.id < writes[*rep].id {
                        *rep = i;
                    }
                    *min = match (*min, st) {
                        (Some(a), Some(b)) => Some(a.min(b)),
                        (a, b) => a.or(b),
                    };
                })
                .or_insert((i, st));
        }
        let mut lines = Vec::with_capacity(by_dot.len());
        for ((writer, seq), &(rep, st)) in &by_dot {
            let w = &writes[rep];
            let (ctx, hlc) = match &w.ed.stamp {
                Some(s) => (s.ctx.to_dvv().to_json(), s.hlc.text()),
                None => {
                    let mut cloud = Map::new();
                    for (ow, oq) in by_dot.keys() {
                        if (ow, oq) != (writer, seq) && self.seen(&w.full, ow, *oq)? {
                            let dots = cloud.entry(ow.clone()).or_insert_with(|| json!([]));
                            dots.as_array_mut().expect("array").push(json!(oq));
                        }
                    }
                    (
                        json!({"vv": {}, "cloud": cloud}),
                        format!("{}:{}:{}", w.wall, w.logical, w.id.device.text()),
                    )
                }
            };
            let mut m = Map::new();
            m.insert("p".into(), json!(""));
            m.insert("k".into(), json!(w.ed.kind.wire()));
            m.insert("e".into(), json!(w.ed.entity.text()));
            m.insert("f".into(), json!(w.ed.key));
            m.insert("w".into(), json!(writer));
            m.insert("s".into(), json!(seq));
            m.insert("ctx".into(), ctx);
            m.insert(
                "v".into(),
                serde_json::from_str::<Value>(&w.ed.value).unwrap_or(Value::Null),
            );
            m.insert("hlc".into(), json!(hlc));
            if w.ed.machine {
                m.insert("m".into(), json!(true));
            }
            lines.push((Value::Object(m).to_string(), st, rep));
        }
        let stored: Vec<StoredEdit<'_>> = lines
            .iter()
            .map(|(j, st, _)| (j.as_str(), *st, None))
            .collect();
        let (live, conflicted) = judge_register(&stored)
            .map_err(|e| format!("gen4 index: register of op {}: {e}", rows[0].0))?;
        let mut out = vec![R_DOMINATED; rows.len()];
        for (n, &i) in live.iter().enumerate() {
            out[lines[i].2] = match (n, conflicted) {
                (0, true) => R_CONFLICT,
                (0, false) => R_WINNER,
                _ => R_LIVE,
            };
        }
        Ok(out)
    }

    /// 写入不止一条的寄存器。
    fn multi_regs(&self) -> Result<Vec<Reg>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT ekind, ent, key FROM reg_ix WHERE col = ?1 GROUP BY ekind, ent, key HAVING COUNT(*) > 1",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([self.col], |r| {
                Ok(Reg {
                    ekind: r.get(0)?,
                    ent: r.get(1)?,
                    key: r.get(2)?,
                })
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    fn multi_ids(&self, table: &str) -> Result<Vec<Ref>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(&format!(
                "SELECT id FROM {table} WHERE col = ?1 GROUP BY id HAVING COUNT(*) > 1"
            ))
            .map_err(sql)?;
        let rows = stmt.query_map([self.col], |r| r.get(0)).map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)
    }

    /// 重选一个实体 ID 的定义。
    fn pick_entity(&mut self, id: &Ref) -> Result<(), String> {
        let conn = self.t.conn();
        let rows: Vec<(i64, i64)> = conn
            .prepare_cached("SELECT k, win FROM ent_ix WHERE col = ?1 AND id = ?2 ORDER BY k")
            .map_err(sql)?
            .query_map(params![self.col, id], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let mut best: Option<((String, OpId), i64)> = None;
        if rows.len() == 1 {
            best = Some(((String::new(), self.t.id_of_key(rows[0].0)?), rows[0].0));
        } else {
            for &(k, _) in &rows {
                let e = self
                    .t
                    .entry_by_key(k)?
                    .ok_or_else(|| format!("gen4 index: entity row {k} has no op"))?;
                let Some(Body4::Entity { kind, id, data }) = body_of(&e) else {
                    return Err(format!("gen4 index: entity row {k} is not an entity"));
                };
                // 协议 3 `project_entity` 比的那份规范文本（集合内 profile 是常量，不参与）。
                let d: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
                let rec = json!({"id": id.text(), "p": "", "k": kind.wire(), "d": d}).to_string();
                let rank = (rec, e.id);
                if best.as_ref().is_none_or(|(b, _)| rank < *b) {
                    best = Some((rank, k));
                }
            }
        }
        for &(k, win) in &rows {
            let want = i64::from(best.as_ref().is_some_and(|(_, b)| *b == k));
            if win != want {
                conn.prepare_cached(
                    "UPDATE ent_ix SET win = ?4 WHERE col = ?1 AND id = ?2 AND k = ?3",
                )
                .map_err(sql)?
                .execute(params![self.col, id, k, want])
                .map_err(sql)?;
            }
        }
        Ok(())
    }

    /// 重选一个日志 ID 的代表：操作号最小的。
    fn pick_log(&mut self, id: &Ref) -> Result<(), String> {
        let conn = self.t.conn();
        let rows: Vec<(i64, Ref, i64, i64)> = conn
            .prepare_cached("SELECT k, card, at, win FROM log_ix WHERE col = ?1 AND id = ?2")
            .map_err(sql)?
            .query_map(params![self.col, id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let mut best: Option<(OpId, i64)> = None;
        for (k, ..) in &rows {
            let op = self.t.id_of_key(*k)?;
            if best.is_none_or(|(b, _)| op < b) {
                best = Some((op, *k));
            }
        }
        for (k, card, at, win) in &rows {
            let want = i64::from(best.is_some_and(|(_, b)| b == *k));
            if *win != want {
                conn.prepare_cached(
                    "UPDATE log_ix SET win = ?5 WHERE col = ?1 AND card = ?2 AND at = ?3 AND k = ?4",
                )
                .map_err(sql)?
                .execute(params![self.col, card, at, k, want])
                .map_err(sql)?;
            }
        }
        Ok(())
    }

    // ------------------------------------------------------------ 收尾与重建

    /// 把 [Index::add] / [Index::remove] 攒下的变化判完：重算变了旧戳的设备的闭包，重判动过的寄存器，重选动过的
    /// 实体 / 日志 ID。闭包变了、或有旧戳被拿走过，就把写入不止一条的寄存器全部重判——不带旧戳的写入见过什么
    /// 依赖闭包（往日志末尾添旧戳而闭包没变时，任何前缀覆盖到的旧戳集合都没变，不用重判）。
    pub fn settle(&mut self) -> Result<Settled, String> {
        self.writing()?;
        let mut out = Settled::default();
        for d in std::mem::take(&mut self.stale) {
            let mut acc = Acc::default();
            self.t.for_each_stamp(self.col, &d, u64::MAX, |seq, s| {
                acc.note(seq, s);
                Ok(())
            })?;
            if self.put_closure(&d, acc)? {
                out.closures += 1;
            }
        }
        self.weigh(false, &mut out)?;
        let mut regs = std::mem::take(&mut self.regs);
        if out.closures > 0 || std::mem::take(&mut self.shrunk) {
            self.partial.clear();
            regs.extend(self.multi_regs()?);
        }
        for r in &regs {
            out.registers += 1;
            if self.judge(r)? {
                out.judged += 1;
            }
        }
        for id in std::mem::take(&mut self.ents) {
            out.entities += 1;
            self.pick_entity(&id)?;
        }
        for id in std::mem::take(&mut self.logs) {
            out.logs += 1;
            self.pick_log(&id)?;
        }
        self.heads.clear();
        out.digests = self.digest_flush()?;
        if std::mem::take(&mut self.salts_dirty) {
            self.settle_salts()?;
        }
        if self.alias_dirty && !self.alias_held {
            out.aliases = self.rebuild_aliases()?;
        }
        Ok(out)
    }

    /// 清空这个集合的派生表，从日志与本机状态（设备信任）重建（设计 §2.5）。不改真相：该清成空洞而还没清的操作
    /// 只是标成「已清除」、不参与任何判定，落库由 [Index::execute_purges] 做。盐集合只增不减：重建只会把带盐操作的盐
    /// 再并一遍。
    pub fn rebuild_all(&mut self) -> Result<Settled, String> {
        self.writing()?;
        let t = self.t;
        let conn = t.conn();
        self.reset();
        // 语义摘要的标脏触发器逐行收一次费，重建不需要（最后整个重算）：先摘掉，收尾时装回。
        super::digest::set_triggers(conn, false)?;
        for table in DERIVED_TABLES {
            conn.execute(&format!("DELETE FROM {table} WHERE col = ?1"), [self.col])
                .map_err(sql)?;
        }
        self.closures = Some(HashMap::new());
        self.bulk = Some(HashMap::new());
        let mut out = Settled::default();
        for d in t.devices(self.col)? {
            t.for_each(self.col, &d.id, 1, |e| {
                out.scanned += 1;
                self.touch(&e, true)
            })?;
        }
        let mut acc: Vec<(Id, Acc)> = self.bulk.take().unwrap_or_default().into_iter().collect();
        acc.sort_by_key(|(d, _)| *d);
        for (d, a) in acc {
            if self.put_closure(&d, a)? {
                out.closures += 1;
            }
        }
        self.weigh(true, &mut out)?;
        let mut regs = std::mem::take(&mut self.regs);
        regs.extend(self.multi_regs()?);
        for r in &regs {
            out.registers += 1;
            if self.judge(r)? {
                out.judged += 1;
            }
        }
        for id in self.multi_ids("ent_ix")? {
            out.entities += 1;
            self.pick_entity(&id)?;
        }
        for id in self.multi_ids("log_ix")? {
            out.logs += 1;
            self.pick_log(&id)?;
        }
        self.heads.clear();
        super::digest::set_triggers(conn, true)?;
        out.digests = self.digest_rebuild()?;
        self.settle_salts()?;
        out.aliases = self.rebuild_aliases()?;
        Ok(out)
    }

    // ------------------------------------------------------------ 读

    /// 一个寄存器的全部写入：(操作号, 状态)，按操作主键升序。
    pub fn register(
        &self,
        kind: EntKind,
        entity: &Key,
        key: &str,
    ) -> Result<Vec<(OpId, i64)>, String> {
        self.reg_rows(&Reg::new(kind, entity, key))?
            .into_iter()
            .map(|(k, state)| Ok((self.t.id_of_key(k)?, state)))
            .collect()
    }

    /// 一个寄存器的生效值（规范 JSON 文本）；没有写入 = None。
    pub fn value(&self, kind: EntKind, entity: &Key, key: &str) -> Result<Option<String>, String> {
        for (k, state) in self.reg_rows(&Reg::new(kind, entity, key))? {
            if state >= R_WINNER {
                return self.t.edit_value(k);
            }
        }
        Ok(None)
    }

    /// 整列读（设计 §2.3）：某类实体全部寄存器的胜者，按 (实体, 键) 序交给 [f]（实体、修改键、值的规范 JSON 文本）。
    /// 返回条数。
    pub fn for_each_winner(
        &self,
        kind: EntKind,
        mut f: impl FnMut(&Ref, &str, &str) -> Result<(), String>,
    ) -> Result<u64, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT ent, key, k FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND state >= ?3 ORDER BY ent, key",
            )
            .map_err(sql)?;
        let mut rows = stmt
            .query(params![self.col, kind as i64, R_WINNER])
            .map_err(sql)?;
        let mut n = 0;
        while let Some(r) = rows.next().map_err(sql)? {
            let ent: Ref = r.get(0).map_err(sql)?;
            let key = match r.get_ref(1).map_err(sql)? {
                ValueRef::Blob(b) => {
                    read_edit_key(&mut Reader::new(b)).map_err(|e| format!("gen4 index: {e}"))?
                }
                _ => return Err("gen4 index: bad register key".to_owned()),
            };
            let k: i64 = r.get(2).map_err(sql)?;
            let value = self
                .t
                .edit_value(k)?
                .ok_or_else(|| format!("gen4 index: register row {k} has no edit"))?;
            f(&ent, &key, &value)?;
            n += 1;
        }
        Ok(n)
    }

    /// 一个实体 ID 的定义：(种类, 定义它的操作)。
    pub fn entity(&self, id: &Key) -> Result<Option<(EntKind, OpId)>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached("SELECT kind, k FROM ent_ix WHERE col = ?1 AND id = ?2 AND win = 1")
            .map_err(sql)?;
        let mut rows = stmt.query(params![self.col, Ref::of(id)]).map_err(sql)?;
        let Some(r) = rows.next().map_err(sql)? else {
            return Ok(None);
        };
        let kind: i64 = r.get(0).map_err(sql)?;
        let kind = EntKind::ALL
            .get(kind as usize)
            .copied()
            .ok_or("gen4 index: bad entity kind")?;
        Ok(Some((kind, self.t.id_of_key(r.get(1).map_err(sql)?)?)))
    }

    /// 一张卡的日志（每个日志 ID 一条），按 (发生时刻, 操作主键) 升序：(发生时刻, 操作号)。
    pub fn logs_of(&self, card: &Key) -> Result<Vec<(i64, OpId)>, String> {
        let mut stmt = self
            .t
            .conn()
            .prepare_cached(
                "SELECT at, k FROM log_ix WHERE col = ?1 AND card = ?2 AND win = 1 ORDER BY at, k",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![self.col, Ref::of(card)], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
            })
            .map_err(sql)?;
        let mut out = Vec::new();
        for row in rows {
            let (at, k) = row.map_err(sql)?;
            out.push((at, self.t.id_of_key(k)?));
        }
        Ok(out)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::sync::Arc;
    use std::time::Instant;

    use proptest::prelude::*;
    use rusqlite::Connection;

    use super::*;
    use crate::gen4::heritage::HeritageSlot;
    use crate::gen4::op::tests::{id, native_edit, sample_log};
    use crate::gen4::op::{Log4, Op4};
    use crate::gen4::stamp::{StampCtx, StampHlc};
    use crate::gen4::translate::T_VERSION;
    use crate::store::gen4::legacy::tests::{T0, migrate, pair, peak_mem_mb, sample};
    use crate::store::gen4::parity::{against_protocol_3, imported};
    use crate::store::gen4::schema::{open, open_in_memory, table_bytes};
    use crate::store::gen4::truth::tests::bound;
    use crate::store::sync2::tests::{Device, P, edit, legacy_library};
    use crate::sync2::hlc::Hlc;

    /// 派生表的全部行，逐行一个字符串（每张表内排好序）。
    pub(crate) fn dump(conn: &Connection, col: i64) -> Vec<String> {
        let mut out = Vec::new();
        for table in DERIVED_TABLES {
            let mut stmt = conn
                .prepare(&format!("SELECT * FROM {table} WHERE col = ?1"))
                .unwrap();
            let n = stmt.column_count();
            let mut lines = Vec::new();
            let mut rows = stmt.query([col]).unwrap();
            while let Some(r) = rows.next().unwrap() {
                let cells: Vec<String> = (0..n)
                    .map(|i| format!("{:?}", r.get::<_, rusqlite::types::Value>(i).unwrap()))
                    .collect();
                lines.push(format!("{table} {}", cells.join(" | ")));
            }
            lines.sort();
            out.extend(lines);
        }
        out
    }

    /// 重建前后派生表逐行相同（重建在一个回滚掉的事务外再做一遍也一样，所以直接原地重建再比）。
    pub(crate) fn assert_rebuild_is_identity(t: &Truth<'_>, col: i64) {
        let before = dump(t.conn(), col);
        t.tx(|t| Index::new(t, col).rebuild_all()).unwrap();
        let after = dump(t.conn(), col);
        assert_eq!(before.len(), after.len());
        for (a, b) in before.iter().zip(&after) {
            assert_eq!(a, b);
        }
    }

    const FIELD: u8 = 4;

    fn field() -> String {
        format!("f/{}", id(FIELD).text())
    }

    pub(crate) fn note() -> Key {
        Key::Uuid(id(3))
    }

    pub(crate) fn vv(deps: &[(u8, u64)]) -> Arc<Vv> {
        let mut v = Vv::new();
        for &(d, s) in deps {
            v.set(id(d), s);
        }
        Arc::new(v)
    }

    pub(crate) fn op(dev: u8, seq: u64, wall: i64, deps: &[(u8, u64)], body: &Body4) -> Op4 {
        Op4::of(
            OpId {
                device: id(dev),
                seq,
            },
            Hlc {
                wall,
                logical: 0,
                device: id(dev),
            },
            vv(deps),
            body,
        )
    }

    fn write(value: &str, stamp: Option<HeritageStamp>) -> Body4 {
        Body4::Edit(Edit4 {
            value: format!("\"{value}\""),
            stamp,
            ..native_edit()
        })
    }

    pub(crate) fn stamp(writer: &str, seq: i64, ctx: &str, physical: i64) -> HeritageStamp {
        HeritageStamp {
            writer: writer.to_owned(),
            seq,
            ctx: StampCtx::parse(ctx),
            hlc: StampHlc::of(&format!("{physical}:0:{writer}")),
            server_time: None,
        }
    }

    /// [states] 等按操作主键列出来的顺序 = 设备第一次在这个库里出现的顺序、再按 seq。
    ///
    /// 原生日志追加一条并告诉索引。
    pub(crate) fn native(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, o: &Op4) {
        t.append_native(col, o).unwrap();
        ix.add(&t.entry(col, &o.id).unwrap().unwrap()).unwrap();
    }

    /// 承袭日志落一个槽并告诉索引。
    pub(crate) fn heritage(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, o: Op4) {
        let fp = [o.id.seq as u8; 8];
        let oid = o.id;
        t.put_heritage(col, &id(0xc0), &HeritageSlot::op(fp, o), T_VERSION)
            .unwrap();
        ix.add(&t.entry(col, &oid).unwrap().unwrap()).unwrap();
    }

    fn states(ix: &Index<'_, '_>) -> Vec<(u8, u64, i64)> {
        ix.register(EntKind::Note, &note(), &field())
            .unwrap()
            .into_iter()
            .map(|(o, s)| (o.device.0[15], o.seq, s))
            .collect()
    }

    pub(crate) fn with<T>(f: impl FnOnce(&Truth<'_>, i64) -> T) -> T {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        f(&t, col)
    }

    /// 旧设备分叉过：两支不管谁先到，派生表逐行相同（真相层按链指纹定日志里是哪一条，`truth.rs` 文件头）。
    #[test]
    fn a_forked_log_gives_the_same_index_whichever_branch_arrived_first() {
        use crate::store::gen4::truth::Put;
        let slot = |seq: u64, fp: u8, value: &str| {
            let s = stamp("w1", seq as i64, r#"{"vv":{}}"#, 100 + seq as i64);
            HeritageSlot::op(
                [fp; 8],
                op(0xd1, seq, seq as i64, &[], &write(value, Some(s))),
            )
        };
        let a = [slot(1, 9, "a1"), slot(2, 9, "a2"), slot(3, 1, "a3")];
        let b = [slot(1, 5, "b1"), slot(2, 12, "b2"), slot(3, 7, "b3")];
        let run = |order: &[&HeritageSlot]| -> (BTreeSet<String>, Option<String>) {
            with(|t, col| {
                let value = t
                    .tx(|t| {
                        let mut ix = Index::new(t, col);
                        for s in order {
                            let before = t.entry(col, &s.id)?;
                            match t.put_heritage(col, &id(0xc0), s, T_VERSION)? {
                                Put::Inserted | Put::Yielded => {
                                    ix.add(&t.entry(col, &s.id)?.expect("put"))?
                                }
                                Put::Replaced => {
                                    ix.remove(&before.expect("replaced"))?;
                                    ix.add(&t.entry(col, &s.id)?.expect("put"))?;
                                }
                                _ => {}
                            }
                            ix.settle()?;
                        }
                        ix.value(EntKind::Note, &note(), &field())
                    })
                    .unwrap();
                let got = canon(t, col);
                assert_rebuild_is_identity(t, col);
                (got, value)
            })
        };
        let first = run(&[&a[0], &a[1], &a[2], &b[0], &b[1], &b[2]]);
        // 日志里是 b1、a2、a3（各操作号上链指纹最小的）；最后一条旧修改见过的只有它自己，按 HLC 是 a3 胜。
        assert_eq!(first.1.as_deref(), Some("\"a3\""));
        assert_eq!(first, run(&[&b[0], &b[1], &b[2], &a[0], &a[1], &a[2]]));
        assert_eq!(first, run(&[&a[0], &b[0], &b[1], &a[1], &b[2], &a[2]]));
    }

    #[test]
    fn concurrent_writes_conflict_and_a_write_that_saw_both_wins() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                // 两台设备谁也没见过谁：都活着，HLC 大的是胜者，值不同 = 冲突。
                native(t, &mut ix, col, &op(0xa1, 1, 100, &[], &write("a", None)));
                native(t, &mut ix, col, &op(0xa2, 1, 200, &[], &write("b", None)));
                ix.settle()?;
                assert_eq!(states(&ix), [(0xa1, 1, R_LIVE), (0xa2, 1, R_CONFLICT)]);
                assert_eq!(
                    ix.value(EntKind::Note, &note(), &field())?,
                    Some("\"b\"".into())
                );
                // 值相同的并发写入不算冲突。
                native(t, &mut ix, col, &op(0xa3, 1, 50, &[], &write("b", None)));
                native(t, &mut ix, col, &op(0xa1, 2, 300, &[], &write("b", None)));
                ix.settle()?;
                // a1 的第 2 条见过自己的第 1 条：支配它；a2、a3 的仍与它并发、值相同。
                assert_eq!(
                    states(&ix),
                    [
                        (0xa1, 1, R_DOMINATED),
                        (0xa1, 2, R_WINNER),
                        (0xa2, 1, R_LIVE),
                        (0xa3, 1, R_LIVE)
                    ]
                );
                // 见过全部的一条：只剩它。HLC 比别人都小也一样——支配先于排序。
                let all = [(0xa1, 2), (0xa2, 1), (0xa3, 1)];
                native(t, &mut ix, col, &op(0xa4, 1, 10, &all, &write("c", None)));
                ix.settle()?;
                assert_eq!(states(&ix).last(), Some(&(0xa4, 1, R_WINNER)));
                assert!(states(&ix)[..4].iter().all(|s| s.2 == R_DOMINATED));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn a_heritage_write_keeps_its_old_dot_and_a_native_write_sees_it_through_the_closure() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                // 旧设备 d1 迁进来两条旧修改：w2 的第 1 条见过 w1 的第 1 条。
                let s1 = stamp("w1", 1, r#"{"vv":{}}"#, 100);
                let s2 = stamp("w2", 1, r#"{"vv":{"w1":1}}"#, 90);
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xd1, 1, 1, &[], &write("old1", Some(s1))),
                );
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xd1, 2, 2, &[], &write("old2", Some(s2))),
                );
                // 另一台旧设备 d2 迁进来一条与它们并发的。
                let s3 = stamp("w3", 7, r#"{"vv":{}}"#, 95);
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xd2, 1, 3, &[], &write("old3", Some(s3))),
                );
                ix.settle()?;
                // 旧 HLC 定胜负（w3 的 95 > w2 的 90），不是操作自己的 HLC。
                assert_eq!(
                    states(&ix),
                    [
                        (0xd1, 1, R_DOMINATED),
                        (0xd1, 2, R_LIVE),
                        (0xd2, 1, R_CONFLICT)
                    ]
                );
                assert_eq!(
                    ix.closure(&id(0xd1))?
                        .map(|(u, c)| (u, c.to_json().to_string())),
                    Some((2, r#"{"vv":{"w1":1,"w2":1}}"#.into()))
                );
                // 原生写入只见过 d1 的第 1 条：闭包只覆盖到一部分（w1），所以它支配 old1、与 old2 / old3 并发。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 1, 500, &[(0xd1, 1)], &write("n1", None)),
                );
                ix.settle()?;
                assert_eq!(
                    states(&ix),
                    [
                        (0xd1, 1, R_DOMINATED),
                        (0xd1, 2, R_LIVE),
                        (0xd2, 1, R_LIVE),
                        (0xa1, 1, R_CONFLICT)
                    ]
                );
                // 见过 d1 全部、d2 全部的原生写入：经闭包支配全部旧写入，经前缀支配 a1 的那条。
                let deps = [(0xa1, 1), (0xd1, 2), (0xd2, 1)];
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa2, 1, 400, &deps, &write("n2", None)),
                );
                ix.settle()?;
                let got = states(&ix);
                assert_eq!(got.last(), Some(&(0xa2, 1, R_WINNER)));
                assert_eq!(got.iter().filter(|s| s.2 == R_DOMINATED).count(), 4);
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn a_later_old_stamp_changes_what_native_writes_have_seen() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                // 原生写入声称见过 d1 的前 2 条，而 d1 的日志本机才收到第 1 条（与这个寄存器无关的一条）。
                let other = Body4::Edit(Edit4 {
                    key: "name".into(),
                    stamp: Some(stamp("w9", 1, r#"{"vv":{}}"#, 1)),
                    ..native_edit()
                });
                heritage(t, &mut ix, col, op(0xd1, 1, 1, &[], &other));
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 1, 500, &[(0xd1, 2)], &write("n", None)),
                );
                let s = stamp("w1", 1, r#"{"vv":{}}"#, 900);
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xd2, 1, 3, &[], &write("old", Some(s.clone()))),
                );
                ix.settle()?;
                // d2 带来的 w1:1 与原生写入并发，旧 HLC 更大：它是胜者。
                assert_eq!(states(&ix), [(0xa1, 1, R_LIVE), (0xd2, 1, R_CONFLICT)]);
                // d1 的第 2 条到了：是同一条旧修改 w1:1 的另一份。原生写入见过 d1 的前 2 条 = 见过 w1:1，
                // 于是 d2 那份也被它支配（同一个 dot）。闭包变了，寄存器跟着重判。
                heritage(t, &mut ix, col, op(0xd1, 2, 2, &[], &write("old", Some(s))));
                let did = ix.settle()?;
                assert_eq!(did.closures, 1);
                assert_eq!(
                    states(&ix),
                    [
                        (0xd1, 2, R_DOMINATED),
                        (0xa1, 1, R_WINNER),
                        (0xd2, 1, R_DOMINATED)
                    ]
                );
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn the_same_old_write_carried_by_two_devices_counts_once() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let mut s = stamp("w1", 1, r#"{"vv":{}}"#, 100);
                s.server_time = Some(70);
                let mut s2 = s.clone();
                s2.server_time = Some(60);
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xd2, 1, 1, &[], &write("same", Some(s))),
                );
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xd1, 1, 2, &[], &write("same", Some(s2))),
                );
                ix.settle()?;
                // 代表是操作号小的那份（设备 ID 小的），另一份不参与；不是冲突。
                let got = ix.register(EntKind::Note, &note(), &field())?;
                let of = |d: u8| got.iter().find(|(o, _)| o.device == id(d)).map(|x| x.1);
                assert_eq!((of(0xd1), of(0xd2)), (Some(R_WINNER), Some(R_DOMINATED)));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn entities_and_logs_pick_one_op_per_id() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let ent = |data: &str| Body4::Entity {
                    kind: EntKind::Note,
                    id: note(),
                    data: data.to_owned(),
                };
                // 同一个 ID 两份内容不同的身份记录：规范文本小的那份是定义，与谁先到无关。
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa2, 1, 1, &[], &ent(r#"{"createdAt":9}"#)),
                );
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, 1, 2, &[], &ent(r#"{"createdAt":5}"#)),
                );
                // 同一条日志两份：操作号小的是代表；一张卡的日志按时刻排。
                let log = |at: i64, n: u8| {
                    Body4::Log(Log4 {
                        id: Key::Uuid(id(n)),
                        card: Key::Uuid(id(0x77)),
                        at,
                        ..sample_log()
                    })
                };
                native(t, &mut ix, col, &op(0xa2, 2, 3, &[], &log(2000, 1)));
                native(t, &mut ix, col, &op(0xa1, 2, 4, &[], &log(2000, 1)));
                native(t, &mut ix, col, &op(0xa2, 3, 5, &[], &log(1000, 2)));
                ix.settle()?;
                let a = |seq| OpId {
                    device: id(0xa1),
                    seq,
                };
                assert_eq!(ix.entity(&note())?, Some((EntKind::Note, a(1))));
                assert_eq!(
                    ix.logs_of(&Key::Uuid(id(0x77)))?,
                    [
                        (
                            1000,
                            OpId {
                                device: id(0xa2),
                                seq: 3
                            }
                        ),
                        (2000, a(2))
                    ]
                );
                // 代表被清除：另一份顶上。
                let gone = t.entry(col, &a(2))?.unwrap();
                ix.remove(&gone)?;
                assert!(t.advance_purge(col, &a(2))?);
                ix.settle()?;
                assert_eq!(ix.logs_of(&Key::Uuid(id(0x77)))?.len(), 2);
                assert_eq!(ix.logs_of(&Key::Uuid(id(0x77)))?[1].1.device, id(0xa2));
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn purging_a_write_rejudges_its_register_and_shrinks_the_closure() {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let s1 = stamp("w1", 1, r#"{"vv":{}}"#, 100);
                let s2 = stamp("w2", 1, r#"{"vv":{"w1":1}}"#, 90);
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xd1, 1, 1, &[], &write("old1", Some(s1))),
                );
                heritage(
                    t,
                    &mut ix,
                    col,
                    op(0xd1, 2, 2, &[], &write("old2", Some(s2))),
                );
                ix.settle()?;
                assert_eq!(states(&ix), [(0xd1, 1, R_DOMINATED), (0xd1, 2, R_WINNER)]);
                // 清掉支配者：被它支配的那条重新成为胜者；空洞不带旧戳，闭包里不再有 w2 的 dot（设计 §10 第 14 条）。
                let target = OpId {
                    device: id(0xd1),
                    seq: 2,
                };
                ix.remove(&t.entry(col, &target)?.unwrap())?;
                assert!(t.advance_purge(col, &target)?);
                ix.add(&t.entry(col, &target)?.unwrap())?;
                ix.settle()?;
                assert_eq!(states(&ix), [(0xd1, 1, R_WINNER)]);
                assert_eq!(
                    ix.closure(&id(0xd1))?
                        .map(|(u, c)| (u, c.to_json().to_string())),
                    Some((1, r#"{"vv":{"w1":1}}"#.into()))
                );
                Ok(())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
        });
    }

    #[test]
    fn writes_outside_a_transaction_are_refused() {
        with(|t, col| {
            let mut ix = Index::new(t, col);
            assert!(ix.settle().unwrap_err().contains("outside a transaction"));
            assert!(
                ix.rebuild_all()
                    .unwrap_err()
                    .contains("outside a transaction")
            );
        });
    }

    /// 一条随机写入：(设备, 带不带旧戳, 旧写入者, 旧上下文见过谁, 依赖见过谁, 时刻, 值)。
    type Step = (u8, bool, u8, Vec<(u8, u8)>, Vec<(u8, u8)>, u16, u8);

    fn arb_steps() -> impl Strategy<Value = Vec<Step>> {
        let pairs = || proptest::collection::vec((0u8..3, 0u8..4), 0..3);
        proptest::collection::vec(
            (
                0u8..3,
                any::<bool>(),
                0u8..3,
                pairs(),
                pairs(),
                0u16..50,
                0u8..3,
            ),
            1..14,
        )
    }

    /// 把 [steps] 变成每台设备的日志（承袭设备 0xd0..、原生设备 0xa0..），各自 seq 从 1 起。
    fn logs_of_steps(steps: &[Step]) -> Vec<(bool, Vec<Op4>)> {
        let mut heritage: BTreeMap<u8, Vec<Op4>> = BTreeMap::new();
        let mut native: BTreeMap<u8, Vec<Op4>> = BTreeMap::new();
        // 每个旧写入者的 seq 各自递增。
        let mut old_seq = [0i64; 3];
        for (dev, stamped, writer, ctx, deps, wall, value) in steps {
            let value = format!("v{value}");
            if *stamped {
                old_seq[*writer as usize] += 1;
                let vv: Map<String, Value> = ctx
                    .iter()
                    .filter(|(_, s)| *s > 0)
                    .map(|(w, s)| (format!("w{w}"), json!(s)))
                    .collect();
                let s = stamp(
                    &format!("w{writer}"),
                    old_seq[*writer as usize],
                    &json!({"vv": vv}).to_string(),
                    i64::from(*wall),
                );
                let log = heritage.entry(0xd0 + dev).or_default();
                let seq = log.len() as u64 + 1;
                log.push(op(0xd0 + dev, seq, 1, &[], &write(&value, Some(s))));
            } else {
                // 依赖：见过承袭设备 / 别的原生设备的前几条（可以超过对方现有的长度——判定不要求依赖已到）。
                let mut seen: Vec<(u8, u64)> = Vec::new();
                for (d, s) in deps.iter().filter(|(_, s)| *s > 0) {
                    seen.push((0xd0 + d, u64::from(*s)));
                    if d != dev {
                        seen.push((0xa0 + d, u64::from(*s)));
                    }
                }
                let log = native.entry(0xa0 + dev).or_default();
                let seq = log.len() as u64 + 1;
                log.push(op(
                    0xa0 + dev,
                    seq,
                    i64::from(*wall),
                    &seen,
                    &write(&value, None),
                ));
            }
        }
        heritage
            .into_values()
            .map(|l| (true, l))
            .chain(native.into_values().map(|l| (false, l)))
            .collect()
    }

    /// 派生表的全部行，操作主键换成操作号（主键里的设备下标取决于设备谁先出现，不同的到达顺序之间不能直接比）。
    pub(crate) fn canon(t: &Truth<'_>, col: i64) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        canon_rows(t, col, &mut |_, row| {
            out.insert(row);
        });
        out
    }

    /// 派生表每张的 (表名, 行数, 各行摘要之和)：行文本与 [canon] 相同，但不把行留在内存里（大库上比两份派生表用；
    /// 和与顺序无关，两边相等 = 同一个行的多重集）。
    pub(crate) fn digest(t: &Truth<'_>, col: i64) -> Vec<(&'static str, u64, u128)> {
        let mut out: Vec<(&'static str, u64, u128)> =
            DERIVED_TABLES.iter().map(|t| (*t, 0, 0)).collect();
        canon_rows(t, col, &mut |table, row| {
            let slot = out.iter_mut().find(|(t, ..)| *t == table).unwrap();
            let h = blake3::hash(row.as_bytes());
            slot.1 += 1;
            slot.2 = slot
                .2
                .wrapping_add(u128::from_le_bytes(h.as_bytes()[..16].try_into().unwrap()));
        });
        out
    }

    fn canon_rows(t: &Truth<'_>, col: i64, f: &mut dyn FnMut(&'static str, String)) {
        for table in DERIVED_TABLES {
            let mut stmt = t
                .conn()
                .prepare(&format!("SELECT * FROM {table} WHERE col = ?1"))
                .unwrap();
            let names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
            let mut rows = stmt.query([col]).unwrap();
            while let Some(r) = rows.next().unwrap() {
                let cells: Vec<String> = names
                    .iter()
                    .enumerate()
                    .filter(|(_, n)| *n != "col")
                    .map(|(i, n)| match n.as_str() {
                        "k" => format!("{:?}", t.id_of_key(r.get(i).unwrap()).unwrap()),
                        _ => format!("{:?}", r.get::<_, rusqlite::types::Value>(i).unwrap()),
                    })
                    .collect();
                f(table, format!("{table} {}", cells.join(" | ")));
            }
        }
    }

    /// 按 [order] 给的顺序把各条日志交错灌进去（每条日志内部保持 seq 序），逐条维护索引；返回派生表。
    pub(crate) fn build(
        logs: &[(bool, Vec<Op4>)],
        order: &[usize],
        settle_each: bool,
    ) -> BTreeSet<String> {
        with(|t, col| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let mut next = vec![0usize; logs.len()];
                let mut turn = 0;
                loop {
                    let open: Vec<usize> = (0..logs.len())
                        .filter(|&i| next[i] < logs[i].1.len())
                        .collect();
                    if open.is_empty() {
                        break;
                    }
                    let pick = open[order[turn % order.len()] % open.len()];
                    turn += 1;
                    let o = &logs[pick].1[next[pick]];
                    next[pick] += 1;
                    if logs[pick].0 {
                        heritage(t, &mut ix, col, o.clone());
                    } else {
                        native(t, &mut ix, col, o);
                    }
                    if settle_each {
                        ix.settle()?;
                    }
                }
                ix.settle()?;
                Ok(())
            })
            .unwrap();
            let incremental = canon(t, col);
            assert_rebuild_is_identity(t, col);
            incremental
        })
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(48))]

        /// 同一批日志，不管各条日志之间怎么交错着到、中途判不判，索引都一样，重建也一样。
        #[test]
        fn any_arrival_order_gives_the_same_index_and_a_rebuild_reproduces_it(
            steps in arb_steps(),
            order_a in proptest::collection::vec(0usize..6, 1..12),
            order_b in proptest::collection::vec(0usize..6, 1..12),
        ) {
            let logs = logs_of_steps(&steps);
            let a = build(&logs, &order_a, true);
            let b = build(&logs, &order_b, false);
            prop_assert_eq!(a, b);
        }
    }

    // ------------------------------------------------------------ 与协议 3 的投影对拍（`parity.rs`）

    #[test]
    fn the_index_agrees_with_the_protocol_3_projection() {
        // 两台设备各写各的、同步收全（legacy.rs `pair`），再各改同一个字段（并发）并同步。
        let (a, b, mut bucket) = pair();
        a.apply(T0 + 100, vec![edit("note", "N1", "f/x", json!("from a"))]);
        b.apply(T0 + 101, vec![edit("note", "N1", "f/x", json!("from b"))]);
        for _ in 0..2 {
            a.sync(&mut bucket, "loc", T0 + 200);
            b.sync(&mut bucket, "loc", T0 + 200);
        }
        // 见过双方之后再改一次：支配前面两条。
        a.apply(T0 + 300, vec![edit("note", "N1", "f/y", json!("after"))]);
        for d in [&a, &b] {
            let (_, diff) = imported(d);
            assert!(diff.is_empty(), "{diff:?}");
        }
        // 从协议 1 迁上来的库：旧戳、旧上下文、旧日志。
        let old = Device::new("g6ix");
        legacy_library(&old);
        migrate(&old);
        for _ in 0..1000 {
            if old.core.sync2_dedup(P, T0).unwrap()["done"] == json!(true) {
                break;
            }
        }
        let (conn, diff) = imported(&old);
        assert!(diff.is_empty(), "{diff:?}");
        let stamped: i64 = conn
            .query_row("SELECT COUNT(*) FROM closure_ix", [], |r| r.get(0))
            .unwrap();
        assert_eq!(stamped, 1);
    }

    /// 真实样本库：[import] 的探针灌好的新代文件（`FUSHI_GEN4_OUT`）上重建索引，报耗时、体积、峰值内存；与旧库的投影
    /// 对拍；量整列读正文（设计 §2.6 的验收线）。
    ///
    /// `FUSHI_GEN4_SAMPLE_DB=<srs.db 的私有拷贝> FUSHI_GEN4_OUT=<gen4_sample_import 灌好的文件>
    ///  cargo test --release --lib gen4_sample_index -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn gen4_sample_index() {
        let (Some(src), Ok(out)) = (sample(), std::env::var("FUSHI_GEN4_OUT")) else {
            println!("FUSHI_GEN4_SAMPLE_DB / FUSHI_GEN4_OUT not set");
            return;
        };
        let (ws0, commit0) = peak_mem_mb();
        println!("SAMPLE index start peak_working_set_mb {ws0:.0} peak_commit_mb {commit0:.0}");
        let dst = open(std::path::Path::new(&out)).unwrap();
        let t = Truth::new(&dst);
        for profile in crate::store::gen4::legacy::profiles(&src).unwrap() {
            let col = t.binding_of(&profile).unwrap().expect("imported").col;
            let started = Instant::now();
            dst.execute_batch("BEGIN IMMEDIATE").unwrap();
            // 别名层的两样输入：盐（迁移时 G4 写的那条 Salts 操作——这里由一台假想的迁移设备写进它的原生日志）
            // 与内置笔记类型表。
            let salts = crate::store::gen4::alias::tests::sample_salts(&src, &profile);
            let migrator = Id([0x6d; 16]);
            if t.last_of(col, &migrator).unwrap() == 0 {
                let body = Body4::salts(salts.iter().cloned()).unwrap();
                let op = Op4::of(
                    OpId {
                        device: migrator,
                        seq: 1,
                    },
                    Hlc {
                        wall: T0,
                        logical: 0,
                        device: migrator,
                    },
                    Arc::new(t.applied(col).unwrap()),
                    &body,
                );
                t.append_native(col, &op).unwrap();
            }
            let mut ix = Index::new(&t, col);
            ix.set_builtins(&crate::store::gen4::alias::tests::golden_builtins())
                .unwrap();
            let did = ix.rebuild_all().unwrap();
            dst.execute_batch("COMMIT").unwrap();
            let rebuild_s = started.elapsed().as_secs_f64();
            // 其中别名表与语义摘要各占多少：各自再单独算一遍（结果相同）。
            let (ws_a, _) = peak_mem_mb();
            dst.execute_batch("BEGIN IMMEDIATE").unwrap();
            let started = Instant::now();
            let alias_rows = ix.rebuild_aliases().unwrap();
            let alias_s = started.elapsed().as_secs_f64();
            let (ws_b, _) = peak_mem_mb();
            let started = Instant::now();
            let digest_units = ix.digest_rebuild().unwrap();
            let digest_s = started.elapsed().as_secs_f64();
            dst.execute_batch("COMMIT").unwrap();
            let started = Instant::now();
            let digest = ix.digest().unwrap();
            println!(
                "SAMPLE alias salts {} rows {alias_rows} s {alias_s:.1} peak_working_set_mb_before {ws_a:.0} after {ws_b:.0} {:?}",
                salts.len(),
                ix.alias_counts().unwrap()
            );
            println!(
                "SAMPLE digest units {digest_units} rebuild_s {digest_s:.1} read_s {:.3} {digest}",
                started.elapsed().as_secs_f64()
            );
            println!("SAMPLE hollowed {}", ix.hollowed().unwrap().len());
            drop(ix);
            let (ws1, commit1) = peak_mem_mb();
            println!(
                "SAMPLE index profile {profile} {did:?} rebuild_s {rebuild_s:.1} peak_working_set_mb {ws1:.0} peak_commit_mb {commit1:.0}"
            );
            for table in DERIVED_TABLES {
                let n: i64 = dst
                    .query_row(
                        &format!("SELECT COUNT(*) FROM {table} WHERE col = ?1"),
                        [col],
                        |r| r.get(0),
                    )
                    .unwrap();
                println!("SAMPLE rows {table} {n}");
            }
            for (state, n) in dst
                .prepare("SELECT state, COUNT(*) FROM reg_ix WHERE col = ?1 GROUP BY state")
                .unwrap()
                .query_map([col], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))
                .unwrap()
                .map(Result::unwrap)
            {
                println!("SAMPLE reg_state {state} {n}");
            }
            // 整列读正文：新（扫胜者 → 逐条取操作体）对旧（browse.rs 的那条顺序扫，只读出来、不判）。各 3 遍。
            let ix = Index::new(&t, col);
            for round in 0..3 {
                let started = Instant::now();
                let (mut n, mut bytes) = (0u64, 0u64);
                ix.for_each_winner(EntKind::Note, |_, key, value| {
                    if key.starts_with("f/") {
                        n += 1;
                        bytes += value.len() as u64;
                    }
                    Ok(())
                })
                .unwrap();
                println!(
                    "SAMPLE column_new round {round} fields {n} bytes {bytes} s {:.3}",
                    started.elapsed().as_secs_f64()
                );
                let started = Instant::now();
                let (mut n, mut bytes) = (0u64, 0u64);
                let mut stmt = src
                    .prepare(
                        "SELECT srs_idt(f.entity_id) AS entity_id, s.server_time, \
                         f.jslim, f.id, f.profile_uid, f.entity_kind, f.entity_id, f.field_key, f.writer_id, f.seq FROM srs_field_edits f \
                         LEFT JOIN srs_event_local s ON s.event_id = f.id WHERE f.entity_kind = 'note' \
                         AND +f.profile_uid = srs_id(?1) ORDER BY f.entity_id",
                    )
                    .unwrap();
                let mut rows = stmt.query([&profile]).unwrap();
                while let Some(r) = rows.next().unwrap() {
                    let key: String = r.get(7).unwrap();
                    if key.starts_with("f/") {
                        n += 1;
                        bytes += r.get_ref(2).unwrap().as_bytes().map_or(0, <[u8]>::len) as u64;
                    }
                }
                println!(
                    "SAMPLE column_old round {round} rows {n} jslim_bytes {bytes} s {:.3}",
                    started.elapsed().as_secs_f64()
                );
            }
            // 对拍。
            let started = Instant::now();
            let diff = against_protocol_3(&src, &profile, &t, col);
            println!("SAMPLE parity differing_kinds {}", diff.len());
            for (what, old_only, new_only) in &diff {
                println!(
                    "SAMPLE parity {what} only_old {} only_new {} e.g. {:?} / {:?}",
                    old_only.len(),
                    new_only.len(),
                    old_only.first(),
                    new_only.first()
                );
            }
            println!("SAMPLE parity_s {:.1}", started.elapsed().as_secs_f64());
        }
        dst.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
            .unwrap();
        println!(
            "SAMPLE file_bytes {}",
            std::fs::metadata(&out).unwrap().len()
        );
        for (name, bytes) in table_bytes(&dst) {
            println!("SAMPLE table {name} {bytes}");
        }
        let (ws2, commit2) = peak_mem_mb();
        println!("SAMPLE index end peak_working_set_mb {ws2:.0} peak_commit_mb {commit2:.0}");
    }
}
