//! 批量投影（docs/specs/2026-11-03-srs-sync2-bulk-bootstrap.md）：收段投递（transport.rs `Delivery`）把能攒的字段修改
//! 与复习日志攒成一窗，一次落进投影；结果与逐条投影（[super::project]）逐行相同，摘要桶逐位相同（tests_bulk.rs 对拍）。
//!
//! 逐条投影一条字段修改要十几条 SQL：读同寄存器现存行、清除 / 挂起判定、插入、服务器时刻，外加摘要触发器每行把
//! `jslim` 拼回原文再哈希、按桶 UPSERT；新设备收几十万条时这是投递的大头。这里：
//!
//! - **能攒的**：实体「简单」（没有过 `deleted` 写入、没被清除，[Bulk::simple]）上的普通字段修改（不是 `tags`、
//!   不是 `deleted`、不是合成写入者）与卡 / 笔记都简单的复习日志。它们的投影只看同一寄存器的现存行（支配只在同一
//!   (种类, 实体, 字段键) 里比，registers.rs `land`）与同 ID 的行，逐条落与「同一寄存器的一批依次到达一起交给
//!   `land_stored`」结果相同（`land` 本来就按到达顺序逐条判）。记账（`sync2_edit_ops` / `sync2_ent_ops` /
//!   `sync2_log_meta`）照旧逐条当场写。
//! - **当场投、不用先冲**：身份记录、媒体、检查点、不认识的种类，以及简单笔记上的标签操作——它们不读也不写攒着的
//!   那几类行（标签只碰 `tags` 寄存器的合成行，挂起判定在简单实体上直接返回）。
//! - **先冲再当场投**：其余一切（删除、清除、不简单实体上的操作……）。它们可能读攒着的行，先把这一窗落完；投完把
//!   「简单」的判定缓存清掉（删除 / 清除会改变它）。
//!
//! 投影行（`edit_row`：ID、规范文本、写入者）在**到达时**算：v2 写入的 ctx 要并上旧修改记录闭包（`legacy_closure`），
//! 闭包读 `sync2_legacy`，攒着的那几行在内存里并（[Bulk::note_legacy]，与 `note_legacy` 同一算法），算闭包时读内存里的
//! （[Bulk::legacy_row]）。不能挪到冲刷时算：那时 `upto` 已被同一窗里更晚的旧记录推过去，闭包会改走逐条读操作日志的
//! 那一支，遇到已清除的旧记录就与逐条投影不同。
//!
//! 冲刷（[Bulk::flush]）：
//! 1. 旧修改记录闭包（`sync2_legacy`）先写回。攒得很少（< [SMALL_WINDOW]）就逐条落、不切触发器开关（切开关让这条连接上
//!    全部预编译语句失效，窗小时不值）。
//! 2. 按寄存器读现存行；到达的 ID 若已在别的寄存器里、或同一窗里两个寄存器撞了 ID（迁移进来的同一条旧记录被几台设备
//!    各包了一次之类），这几个寄存器整体退回逐条 `land_edit`（按到达顺序，触发器照常）。其余寄存器与它们的 ID、行都不
//!    相交，先后无关。
//! 3. 关掉主库触发器（摘要桶，digest.rs）后按寄存器一次 `land_stored`，删被支配的、插存活的；摘要按触发器同一个行哈希
//!    记增量（[super::digest::Deltas]），最后一次并进桶表。TEMP 触发器（复习队列 / 浏览的待重读，queue.rs）照常触发：
//!    `SQLITE_DBCONFIG_ENABLE_TRIGGER` 关掉时 SQLite 仍执行 TEMP 触发器（tests_bulk.rs 钉住这条）。
//!
//! 缓存（依赖向量行号、「简单」判定、闭包）只在一片（同一个事务）里有效：会话跨片复用投递队列时 [Bulk::reset]。

use std::collections::{BTreeMap, HashMap, HashSet};

use rusqlite::config::DbConfig;
use rusqlite::{params, Connection, OptionalExtension};

use super::digest::Deltas;
use super::{canonical, is_synthetic_writer, sql, Touched};
use crate::registers::{EditCols, StoredEdit, SYNTHETIC_WRITER_PREFIX};
use crate::sync2::dvv::Dvv;
use crate::sync2::id::Id;
use crate::sync2::op::{Body, EditBody, EntKind, LegacyStamp, LogBody, Op};
use crate::sync2::segment::Chain;

/// 一窗最多攒多少条（修改 + 日志）/ 多少载荷字节：冲刷在投递的时间预算里（[super::transport] 的切片按条检查截止
/// 时刻，窗满就在那一条上冲），片尾那一次冲刷不会拖太久。
const WINDOW_OPS: usize = 2048;
const WINDOW_BYTES: usize = 8 * 1024 * 1024;
/// 攒的少于这么多就逐条落（[Bulk::flush]）。
const SMALL_WINDOW: usize = 16;

#[cfg(test)]
thread_local! {
    /// 测试里窗口（与逐条落的门槛）默认压到很小：全部端到端用例都会反复走「窗满批量冲刷」「片尾零头逐条落」
    /// 「冲刷后接着攒」。探针用 [production_window] 换回生产值（测试构建的耗时才有意义）。
    static TEST_WINDOW: std::cell::Cell<(usize, usize)> = const { std::cell::Cell::new((5, 3)) };
    /// 覆盖计数（[Coverage]）：tests_bulk.rs 断言随机世界真的走到了这几条分支。
    static COVERAGE: std::cell::Cell<[usize; 4]> = const { std::cell::Cell::new([0; 4]) };
}

fn window_ops() -> usize {
    #[cfg(test)]
    return TEST_WINDOW.with(|w| w.get().0);
    #[cfg(not(test))]
    WINDOW_OPS
}

fn small_window() -> usize {
    #[cfg(test)]
    return TEST_WINDOW.with(|w| w.get().1);
    #[cfg(not(test))]
    SMALL_WINDOW
}

/// 测试：在 [f] 里用生产的窗口大小。
#[cfg(test)]
pub(crate) fn production_window<T>(f: impl FnOnce() -> T) -> T {
    let before = TEST_WINDOW.with(|w| w.replace((WINDOW_OPS, SMALL_WINDOW)));
    let out = f();
    TEST_WINDOW.with(|w| w.set(before));
    out
}

/// 测试覆盖计数的下标。
#[cfg(test)]
#[derive(Clone, Copy)]
pub(crate) enum Coverage {
    /// 关触发器、按寄存器落的冲刷。
    Batched = 0,
    /// 攒得少、逐条落的冲刷。
    Small = 1,
    /// 撞 ID 退回逐条落的到达。
    Fallback = 2,
    /// 到达时算闭包走了「只覆盖一部分迁移操作」那一支（审查 F1）。
    PartialClosure = 3,
}

#[cfg(test)]
fn covered(k: Coverage) {
    COVERAGE.with(|c| {
        let mut v = c.get();
        v[k as usize] += 1;
        c.set(v);
    });
}

/// 测试：取走覆盖计数（[Coverage] 下标）。
#[cfg(test)]
pub(crate) fn take_coverage() -> [usize; 4] {
    COVERAGE.with(|c| c.replace([0; 4]))
}

#[cfg(test)]
thread_local! {
    /// 测试开关：关掉批量投影（逐条 `project`），对拍用。
    static OFF: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// 测试：在 [f] 里关掉批量投影（逐条投影）。
#[cfg(test)]
pub(crate) fn sequential<T>(f: impl FnOnce() -> T) -> T {
    OFF.with(|o| o.set(true));
    let out = f();
    OFF.with(|o| o.set(false));
    out
}

fn enabled() -> bool {
    #[cfg(test)]
    if OFF.with(|o| o.get()) {
        return false;
    }
    true
}

struct Arrival {
    e: EditBody,
    ent: String,
    server: Option<i64>,
    /// 到达时算好的投影行（[super::edit_row]）：旧修改记录闭包取到达那一刻的，与逐条投递相同。
    row: Row,
}

struct PendingLog {
    lid: String,
    card: String,
    l: LogBody,
    text: String,
}

/// 一台设备的旧修改记录闭包（`sync2_legacy` 一行）在内存里的样子。
struct LegacyRow {
    upto: u64,
    d: Dvv,
    dirty: bool,
}

/// 一条到达的投影行。
struct Row {
    eid: String,
    text: String,
    writer: String,
    seq: i64,
}

/// 现存的修改记录（与 `land_edit` 读的同一组列）。
struct Existing {
    id: String,
    stored: String,
    server: Option<i64>,
    cols: Option<EditCols>,
    profile: String,
}

#[derive(Default)]
pub(crate) struct Bulk {
    deps: HashMap<Vec<u8>, i64>,
    simple: HashMap<(&'static str, String), bool>,
    legacy: BTreeMap<Id, LegacyRow>,
    edits: Vec<Arrival>,
    logs: Vec<PendingLog>,
    log_ids: HashSet<String>,
    bytes: usize,
}

impl Bulk {
    /// 新的一片：缓存作废（片与片之间别的写入可能改了删除 / 清除 / 依赖向量表）。
    pub(crate) fn reset(&mut self) {
        debug_assert!(self.is_empty(), "reset with a window still buffered");
        self.deps.clear();
        self.simple.clear();
        self.legacy.clear();
    }

    /// 没有攒着、没写回的东西。
    pub(crate) fn is_empty(&self) -> bool {
        self.edits.is_empty() && self.logs.is_empty() && self.legacy.values().all(|r| !r.dirty)
    }

    /// 应用一条已过链与因果校验的远端操作：写进操作日志，投影（攒进窗口或当场投）。
    pub(crate) fn apply(&mut self, c: &Connection, profile: &str, op: &Op, chain: &Chain, now: i64, t: &mut Touched) -> Result<(), String> {
        let bytes = op.deps.encode();
        let deps = match self.deps.get(&bytes) {
            Some(&d) => d,
            None => {
                let d = super::intern_deps(c, &bytes)?;
                self.deps.insert(bytes, d);
                d
            }
        };
        {
            super::insert_op_at(c, profile, op, chain, now, deps)?;
        }
        if !enabled() {
            return super::project(c, profile, op, now, true, t);
        }
        match op.body().map_err(|e| e.to_string())? {
            Body::Edit(e) => self.edit(c, profile, op, e, now, t),
            Body::Log(l) => self.log(c, profile, op, l, now, t),
            body @ (Body::TagAdd { .. } | Body::TagRemove { .. } | Body::TagOrder { .. }) => {
                let note = match &body {
                    Body::TagAdd { note, .. } | Body::TagRemove { note, .. } | Body::TagOrder { note, .. } => note.text(),
                    _ => unreachable!(),
                };
                if self.simple(c, profile, "note", &note)? {
                    super::project_body(c, profile, op, body, now, true, t)
                } else {
                    self.immediate(c, profile, op, body, now, t)
                }
            }
            body @ (Body::Entity { .. }
            | Body::Media { .. }
            | Body::MediaAt { .. }
            | Body::Checkpoint { .. }
            | Body::LegacyUnknown { .. }
            | Body::Unknown
            | Body::Purged
            | Body::DeckAlias { .. }) => super::project_body(c, profile, op, body, now, true, t),
            body => self.immediate(c, profile, op, body, now, t),
        }
    }

    /// 先冲掉这一窗，再逐条投；投完「简单」判定作废。
    fn immediate(&mut self, c: &Connection, profile: &str, op: &Op, body: Body, now: i64, t: &mut Touched) -> Result<(), String> {
        self.flush(c, profile, now, t)?;
        let r = match body {
            // 旧修改记录闭包已在 [Bulk::edit] 里记过（刚随冲刷写回）。
            Body::Edit(e) => super::project_edit_noted(c, profile, op, &e, now, true, t),
            body => super::project_body(c, profile, op, body, now, true, t),
        };
        self.simple.clear();
        r
    }

    fn edit(&mut self, c: &Connection, profile: &str, op: &Op, e: EditBody, now: i64, t: &mut Touched) -> Result<(), String> {
        if let Some(l) = &e.legacy {
            self.note_legacy(c, profile, &op.id.device, op.id.seq, l)?;
        }
        let ent = e.entity.text();
        let s = {
            self.simple(c, profile, e.kind.wire(), &ent)?
        };
        if !s {
            return self.immediate(c, profile, op, Body::Edit(e), now, t);
        }
        if e.kind == EntKind::Note && e.key == "tags" {
            // 简单笔记上的整列表标签：只碰 OR-Set 与合成的 `tags` 行，不读攒着的行。
            return super::project_edit_noted(c, profile, op, &e, now, true, t);
        }
        if e.key == "deleted" || e.legacy.as_ref().is_some_and(|l| is_synthetic_writer(&l.writer)) {
            return self.immediate(c, profile, op, Body::Edit(e), now, t);
        }
        {
            super::index_edit(c, profile, op, &e, &ent)?;
        }
        // 投影行在到达时算：v2 写入的 ctx 并上旧修改记录闭包，闭包按此刻的 `sync2_legacy`（攒着、还没写回的那几行
        // 读内存里的，[Bulk::legacy_row]）。冲刷时再算，`upto` 已被同窗更晚的旧记录推过去，会改走逐条读操作日志的
        // 那一支，遇到已清除的旧记录结果就不同（审查 F1）。
        #[cfg(test)]
        let partial_before = super::partial_closures();
        let (eid, v) = super::edit_row_with(profile, op, &e, |vv| super::legacy_closure_with(c, profile, vv, |d| self.legacy_row(c, profile, d)))?;
        #[cfg(test)]
        if super::partial_closures() > partial_before {
            covered(Coverage::PartialClosure);
        }
        let row = Row { text: canonical(&v), writer: v["w"].as_str().unwrap_or_default().to_owned(), seq: v["s"].as_i64().unwrap_or(0), eid };
        self.bytes += op.payload.len();
        let server = e.legacy.as_ref().and_then(|l| l.server_time);
        self.edits.push(Arrival { e, ent, server, row });
        self.full(c, profile, now, t)
    }

    fn log(&mut self, c: &Connection, profile: &str, op: &Op, l: LogBody, now: i64, t: &mut Touched) -> Result<(), String> {
        let card = l.card.text();
        let simple = self.simple(c, profile, "card", &card)?
            && match &l.note {
                Some(n) => self.simple(c, profile, "note", &n.text())?,
                None => true,
            };
        if !simple {
            return self.immediate(c, profile, op, Body::Log(l), now, t);
        }
        let lid = l.id.text();
        super::index_log(c, profile, op, &l, &lid, &card)?;
        // 同一条日志在窗里第二次到：逐条投时它看到第一条已落、什么也不做。
        if self.log_ids.insert(lid.clone()) {
            let text = canonical(&super::log_row(profile, op, &l));
            self.bytes += text.len();
            self.logs.push(PendingLog { lid, card, l, text });
        }
        self.full(c, profile, now, t)
    }

    fn full(&mut self, c: &Connection, profile: &str, now: i64, t: &mut Touched) -> Result<(), String> {
        if self.edits.len() + self.logs.len() >= window_ops() || self.bytes >= WINDOW_BYTES {
            self.flush(c, profile, now, t)?;
        }
        Ok(())
    }

    /// 实体上没有过 `deleted` 写入、也没被清除（一片里缓存；删除 / 清除走 [Bulk::immediate]，投完清缓存）。
    fn simple(&mut self, c: &Connection, profile: &str, kind: &'static str, entity: &str) -> Result<bool, String> {
        let key = (kind, entity.to_owned());
        if let Some(&s) = self.simple.get(&key) {
            return Ok(s);
        }
        let s = !super::semantics::is_purged(c, profile, kind, entity)? && !super::semantics::any_delete(c, profile, kind, entity)?;
        self.simple.insert(key, s);
        Ok(s)
    }

    /// 与 `note_legacy` 同一算法（读出 → 并上这条的旧 ctx 与 dot → 去掉合成写入者），只是留在内存里，冲刷时写回。
    fn note_legacy(&mut self, c: &Connection, profile: &str, device: &Id, seq: u64, l: &LegacyStamp) -> Result<(), String> {
        let row = match self.legacy.entry(*device) {
            std::collections::btree_map::Entry::Occupied(o) => o.into_mut(),
            std::collections::btree_map::Entry::Vacant(v) => {
                let cur: Option<String> = c
                    .prepare_cached("SELECT ctx FROM sync2_legacy WHERE profile_uid = srs_id(?1) AND device = ?2")
                    .map_err(sql)?
                    .query_row(params![profile, device.0.to_vec()], |r| r.get(0))
                    .optional()
                    .map_err(sql)?;
                v.insert(LegacyRow { upto: 0, d: cur.map(|c| Dvv::parse(&c)).unwrap_or_default(), dirty: false })
            }
        };
        row.d.merge(&Dvv::parse(&l.ctx_json));
        if !is_synthetic_writer(&l.writer) {
            row.d.add(&l.writer, l.seq);
        }
        row.d.drop_writers(SYNTHETIC_WRITER_PREFIX);
        row.upto = seq;
        row.dirty = true;
        Ok(())
    }

    /// 一台设备此刻的旧修改记录闭包：攒着的在内存里，否则读表。
    fn legacy_row(&self, c: &Connection, profile: &str, device: &Id) -> Result<Option<(i64, Dvv)>, String> {
        match self.legacy.get(device) {
            Some(r) => Ok(Some((r.upto as i64, r.d.clone()))),
            None => super::stored_legacy(c, profile, device),
        }
    }

    fn write_legacy(&mut self, c: &Connection, profile: &str) -> Result<(), String> {
        for (device, row) in self.legacy.iter_mut().filter(|(_, r)| r.dirty) {
            c.prepare_cached("INSERT OR REPLACE INTO sync2_legacy (profile_uid, device, upto, ctx) VALUES (srs_id(?1), ?2, ?3, ?4)")
                .map_err(sql)?
                .execute(params![profile, device.0.to_vec(), row.upto as i64, row.d.to_json().to_string()])
                .map_err(sql)?;
            row.dirty = false;
        }
        Ok(())
    }

    /// 把这一窗落进投影（见文件头）。
    pub(crate) fn flush(&mut self, c: &Connection, profile: &str, now: i64, t: &mut Touched) -> Result<(), String> {
        self.write_legacy(c, profile)?;
        if self.edits.is_empty() && self.logs.is_empty() {
            return Ok(());
        }
        let edits = std::mem::take(&mut self.edits);
        let logs = std::mem::take(&mut self.logs);
        self.log_ids.clear();
        self.bytes = 0;

        // 攒得很少（多半是「先冲再逐条投」冲出来的）：逐条落，不切触发器开关。切开关会让这条连接上全部预编译
        // 语句失效、下次执行时重编译（审查 F2），窗小时这比省下的触发器开销贵。
        if edits.len() + logs.len() < small_window() {
            #[cfg(test)]
            covered(Coverage::Small);
            for a in &edits {
                let r = &a.row;
                super::land_edit_row(c, profile, &a.e, &r.eid, &r.text, &r.writer, r.seq, a.server, now, t)?;
            }
            for p in &logs {
                land_log(c, profile, p, now, t, None)?;
            }
            return Ok(());
        }
        let rows: Vec<&Row> = edits.iter().map(|a| &a.row).collect();
        // 寄存器（按首次到达的顺序），各自的到达下标。
        let mut regs: Vec<Vec<usize>> = Vec::new();
        let mut reg_of: Vec<usize> = Vec::with_capacity(edits.len());
        let mut by_key: HashMap<(&str, &str, &str), usize> = HashMap::new();
        for (i, a) in edits.iter().enumerate() {
            let r = *by_key.entry((a.e.kind.wire(), a.ent.as_str(), a.e.key.as_str())).or_insert_with(|| {
                regs.push(Vec::new());
                regs.len() - 1
            });
            regs[r].push(i);
            reg_of.push(r);
        }
        let mut fallback = vec![false; regs.len()];
        let mut first_reg: HashMap<&str, usize> = HashMap::new();
        for (i, row) in rows.iter().enumerate() {
            let r = reg_of[i];
            match first_reg.get(row.eid.as_str()) {
                Some(&o) if o != r => {
                    fallback[o] = true;
                    fallback[r] = true;
                }
                Some(_) => {}
                None => {
                    first_reg.insert(&row.eid, r);
                }
            }
        }
        let mut existing: Vec<Vec<Existing>> = Vec::with_capacity(regs.len());
        for (r, arrivals) in regs.iter().enumerate() {
            let a0 = &edits[arrivals[0]];
            let ex = read_existing(c, a0.e.kind.wire(), &a0.ent, &a0.e.key)?;
            for &i in arrivals {
                let eid = rows[i].eid.as_str();
                if ex.iter().any(|x| x.id == eid) {
                    continue;
                }
                // 同 ID 在别的寄存器里：逐条投时它挡住这条到达，且与那个寄存器的删除有先后——两边都逐条投。
                if let Some((k, e, f)) = owner_of(c, eid)? {
                    fallback[r] = true;
                    if let Some(&o) = by_key.get(&(k.as_str(), e.as_str(), f.as_str())) {
                        fallback[o] = true;
                    }
                }
            }
            existing.push(ex);
        }

        // 逐条退回的寄存器：按到达顺序，触发器照常维护摘要。
        for (i, a) in edits.iter().enumerate() {
            if fallback[reg_of[i]] {
                #[cfg(test)]
                covered(Coverage::Fallback);
                let r = &a.row;
                super::land_edit_row(c, profile, &a.e, &r.eid, &r.text, &r.writer, r.seq, a.server, now, t)?;
            }
        }

        #[cfg(test)]
        covered(Coverage::Batched);
        let mut deltas = Deltas::default();
        let off = DigestTriggersOff::new(c)?;
        for (r, arrivals) in regs.iter().enumerate() {
            if !fallback[r] {
                land_register(c, profile, &edits, &rows, arrivals, &existing[r], now, t, &mut deltas)?;
            }
        }
        for p in &logs {
            land_log(c, profile, p, now, t, Some(&mut deltas))?;
        }
        deltas.write(c)?;
        off.restore()
    }
}

fn read_existing(c: &Connection, kind: &str, ent: &str, key: &str) -> Result<Vec<Existing>, String> {
    c.prepare_cached(
        "SELECT srs_idt(f.id) AS id, l.server_time, f.jslim, f.id, f.profile_uid, f.entity_kind, f.entity_id, f.field_key, f.writer_id, f.seq, \
         srs_idt(f.profile_uid) AS p \
         FROM srs_field_edits f LEFT JOIN srs_event_local l ON l.event_id = f.id \
         WHERE f.entity_kind = ?1 AND f.entity_id = srs_id(?2) AND f.field_key = ?3",
    )
    .map_err(sql)?
    .query_map(params![kind, ent, key], |r| {
        let (stored, cols) = crate::store::slim::edit_row(r, 2)?;
        Ok(Existing { id: r.get(0)?, stored, server: r.get(1)?, cols, profile: r.get(10)? })
    })
    .map_err(sql)?
    .collect::<Result<_, _>>()
    .map_err(sql)
}

/// 这个 ID 的修改记录在哪个寄存器（没有 = None）。
fn owner_of(c: &Connection, id: &str) -> Result<Option<(String, String, String)>, String> {
    c.prepare_cached("SELECT entity_kind, srs_idt(entity_id) AS e, field_key FROM srs_field_edits WHERE id = srs_id(?1)")
        .map_err(sql)?
        .query_row([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)
}

/// 一个寄存器的一批到达一次落：与逐条 `land_edit` 相同的落 / 删、服务器时刻、受影响的卡与标记。
#[allow(clippy::too_many_arguments)]
fn land_register(
    c: &Connection,
    profile: &str,
    edits: &[Arrival],
    rows: &[&Row],
    arrivals: &[usize],
    existing: &[Existing],
    now: i64,
    t: &mut Touched,
    deltas: &mut Deltas,
) -> Result<(), String> {
    let n = existing.len();
    let mut items: Vec<StoredEdit<'_>> = existing.iter().map(|x| (x.stored.as_str(), x.server, x.cols.as_ref())).collect();
    items.extend(arrivals.iter().map(|&i| (rows[i].text.as_str(), edits[i].server, None)));
    let (landed, deleted) = crate::registers::land_stored(&items, n)?;
    // 每一项最后还在不在投影里（到达的：落了且没被同窗更晚的到达删掉）。
    let mut alive = vec![true; items.len()];
    for (k, ok) in landed.iter().enumerate() {
        if !ok {
            alive[n + k] = false;
            continue;
        }
        for &d in &deleted[k] {
            alive[d] = false;
            if d >= n {
                t.dominated.push(rows[arrivals[d - n]].eid.clone());
            }
        }
    }
    for (d, x) in existing.iter().enumerate() {
        if alive[d] {
            continue;
        }
        let json: String = c
            .prepare_cached("SELECT json FROM srs_field_edits WHERE id = srs_id(?1)")
            .map_err(sql)?
            .query_row([&x.id], |r| r.get(0))
            .map_err(sql)?;
        c.prepare_cached("DELETE FROM srs_field_edits WHERE id = srs_id(?1)").map_err(sql)?.execute([&x.id]).map_err(sql)?;
        deltas.sub(&x.profile, b'f', &x.id, &json);
        t.dominated.push(x.id.clone());
    }
    for (k, &i) in arrivals.iter().enumerate() {
        if !landed[k] {
            continue;
        }
        let (a, row) = (&edits[i], &rows[i]);
        if alive[n + k] {
            c.prepare_cached(
                "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
                 VALUES (srs_id(?1), srs_id(?2), ?3, srs_id(?4), ?5, srs_id(?6), ?7, srs_edit_pack(?8, ?1, ?2, ?3, ?4, ?5, ?6, ?7))",
            )
            .map_err(sql)?
            .execute(params![row.eid, profile, a.e.kind.wire(), a.ent, a.e.key, row.writer, row.seq, row.text])
            .map_err(sql)?;
            deltas.add(profile, b'f', &row.eid, &row.text);
        } else {
            deltas.touch(profile, &row.eid);
        }
        super::upsert_server_time(c, profile, &row.eid, a.server, now)?;
        if a.e.kind == EntKind::Card {
            if let Some(p) = a.e.key.strip_prefix("historyFrom/") {
                t.cards.insert(a.ent.clone());
                t.cards.insert(p.to_owned());
            }
        }
        t.marks.edit(a.e.kind, &a.ent, &a.e.key);
    }
    Ok(())
}

/// 一条攒着的日志落进投影（与 `project_log` 的投影部分相同：已在就什么也不做）。[deltas] = None：触发器开着，摘要
/// 由触发器维护。
fn land_log(c: &Connection, profile: &str, p: &PendingLog, now: i64, t: &mut Touched, deltas: Option<&mut Deltas>) -> Result<(), String> {
    let exists = c.prepare_cached("SELECT 1 FROM srs_review_logs WHERE id = srs_id(?1)").map_err(sql)?.exists([&p.lid]).map_err(sql)?;
    if exists {
        return Ok(());
    }
    let l = &p.l;
    c.prepare_cached(
        "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, jslim) \
         VALUES (srs_id(?1), srs_id(?2), srs_id(?3), ?4, ?5, ?6, ?7, ?8, ?9, srs_log_pack(?10, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9))",
    )
    .map_err(sql)?
    .execute(params![p.lid, profile, p.card, l.kind, l.rating, l.at, l.rtype, l.origin, l.dur, p.text])
    .map_err(sql)?;
    if let Some(deltas) = deltas {
        deltas.add(profile, b'l', &p.lid, &p.text);
    }
    super::upsert_server_time(c, profile, &p.lid, l.legacy_server_time, now)?;
    t.cards.insert(p.card.clone());
    t.marks.log(&p.card);
    Ok(())
}

/// 关掉这条连接上主库的触发器（摘要桶）；[DigestTriggersOff::restore] 或出错丢弃时打开。TEMP 触发器不受影响。
///
/// 切换这个开关会让这条连接上全部预编译语句失效（SQLite `sqlite3ExpirePreparedStatements`）：下次执行时自动重编译，
/// 但**正执行到一半**的语句再往下走会直接报错。冲刷只在投递的操作边界上调用，那时写连接上没有执行中的语句；
/// 别在遍历某个查询结果的循环里冲刷。
struct DigestTriggersOff<'a> {
    c: &'a Connection,
    on: bool,
}

impl<'a> DigestTriggersOff<'a> {
    fn new(c: &'a Connection) -> Result<Self, String> {
        c.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, false).map_err(sql)?;
        Ok(DigestTriggersOff { c, on: false })
    }

    fn restore(mut self) -> Result<(), String> {
        self.c.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, true).map_err(sql)?;
        // 打开成功才算恢复：失败时丢弃守卫还会再试一次（审查 F3）。
        self.on = true;
        Ok(())
    }
}

impl Drop for DigestTriggersOff<'_> {
    fn drop(&mut self) {
        if !self.on {
            let _ = self.c.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, true);
        }
    }
}
