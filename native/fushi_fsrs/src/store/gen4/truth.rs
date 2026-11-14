//! 真相层：每台设备一条从 1 起连续的日志，落在 `ops` / `op_alias` / `op_voids` 三张表里（设计 §2.1、§2.2、§3.2）。
//!
//! 两种日志：
//!
//! - **承袭日志**（`devs.kind = 1`）：旧设备的协议 3 日志经转译 T 得到的槽（操作 / 原样件 / 副本记录 / 空洞），每个槽带
//!   8 字节原链指纹。不成链；首尾与中途的完整原链值记在 `log_marks`（承袭段头要用）。
//! - **原生日志**（`devs.kind = 0`）：协议 4 的操作，成链（`devs.tail` 是末尾的链值）。被清除的操作成为空洞，空洞区间
//!   记区间末的链值（附录 B 第 9 条），于是链可以越过空洞接着算。
//!
//! # 槽的落库规则（设计 §3.2，所有者 2026-11-12 批准的那三条在这里接）
//!
//! [Truth::put_heritage] 收一个槽：
//!
//! | 本机这个操作号 | 结果 |
//! |---|---|
//! | 没有，且正好接在末尾 | 收什么留什么（[Put::Inserted]） |
//! | 没有，前面还缺 | 报错——前面缺一段的槽走 [Truth::put_pending] |
//! | 有，链指纹不同 | 那台旧设备分叉过：另一支存进 `op_forks`，本机的不动（[Put::Fork]） |
//! | 有，链指纹相同，逐字节相同 | [Put::Same] |
//! | 有，链指纹相同，一边完整、一边是空洞 / 副本记录（或空洞对副本记录） | **本机的不动**（[Put::Kept]）。本机的槽只由本机自己应用 Purge / Dedup 推进（[Truth::advance_purge] / [Truth::advance_dedup]） |
//! | 有，链指纹相同，同秩而内容不同，来的 T 版本更高 | 换成来的（[Put::Replaced]） |
//! | 同上，来的 T 版本更低 | 本机的不动（[Put::Kept]） |
//! | 同上，T 版本相同 | 异常：报错、不落库 |
//!
//! 「完整 < 空洞 < 副本记录」的并（`gen4::translate::join_slots`）只用在本机还**没应用**的槽上：待投递的与分叉的另一支
//! （它们没有被本机的 Purge / Dedup 推进过，同一个 `(操作号, 链指纹)` 来了两份就留靠后的）。
//!
//! # 待投递（设计 §3.1 末、§10 第 12 条）
//!
//! 前面缺一段的槽存进 `op_pending`，带一个「前一环的链指纹」`prev_fp`：
//!
//! - 迁移时旧代读入器能在协议 3 的口径下验出「这条紧接在上一条之后」（`chain_next(上一条的链值, 这条) == 它声明的链值`）
//!   的，`prev_fp` = 上一条的链指纹；验不出的（前面缺着）是空。
//! - [Truth::pending_ready] 只交出「正好接在本机末尾、且 `prev_fp` 等于本机末尾那个槽的链指纹」的待投递槽。
//!   `prev_fp` 为空的永远不自己投递：转译之后已经没有办法重算协议 3 的链，它只能等同一个操作号经承袭段到达——
//!   那时链指纹相同就是确认（待投递行删掉），不同就是分叉的一支（挪进 `op_forks`）。
//! - 因果上该不该投（依赖是否齐）不在这一层，是同步轮的事。
//!
//! # 会话与事务
//!
//! [Truth] 在内存里缓存设备下标、名字表、每条日志的末尾。所有写入必须在事务里（[Truth::tx]，或调用方自己开的事务）；
//! 事务回滚后缓存可能领先于库，必须 [Truth::reset]（[Truth::tx] 出错时自动做）。一次写入报错后，这个会话在 reset 之前
//! 拒绝再写。

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::sync::Arc;

use rusqlite::{Connection, OptionalExtension, Row, params};

use super::pack::{self, F_RAW3, Names, tv_bits, tv_of};
use super::schema::{in_tx, k_dev, k_range, k_seq, opk, sql};
use crate::gen4::heritage::{Alias, Fp, HeritageSlot, Raw3, SlotBody, fingerprint};
use crate::gen4::name::{read_name, write_name};
use crate::gen4::op::{Body4, Edit4, KIND_EDIT, Op4, chain_next4, native_allowed};
use crate::gen4::stamp::HeritageStamp;
use crate::gen4::translate::{Joined, applied_body, dedup_slot, join_slots};
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::Id;
use crate::sync2::op as v3;
use crate::sync2::segment::{CHAIN_ZERO, Chain};
use crate::sync2::vv::{OpId, Vv};

/// `devs.kind`：原生日志。
pub const DEV_NATIVE: i64 = 0;
/// `devs.kind`：承袭日志。
pub const DEV_HERITAGE: i64 = 1;

/// `op_alias.flags` / `op_voids.flags`：这个槽现在的样子是本机自己应用 Purge / Dedup 推进出来的（不是收来的）。
const A_LOCAL: i64 = 1;
/// `op_alias.flags`：`stamp` 一列存的是旧戳的线格式规范字节（内部化后读不回原值时的退路）。
const A_STAMP_WIRE: i64 = 2;

/// 原生日志每隔这么多条记一个链值（`log_marks`），[Truth::chain_at] 最多从这里往后折这么多条。
pub const MARK_EVERY: u64 = 1024;

const CACHE_MAX: usize = 65_536;

/// [Truth::put_heritage] / [Truth::put_pending] 的结果。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Put {
    /// 接在日志末尾，落库了。
    Inserted,
    /// 本机已有逐字节相同的一份。
    Same,
    /// 本机已有同一个操作号、同一个链指纹的槽，来的这份不改它。
    Kept,
    /// 来的这份（更高的 T 版本）换掉了本机的。派生层要重算这个操作号。
    Replaced,
    /// 链指纹与本机的不同：记成分叉的另一支。
    Fork,
    /// 前面还缺：进了待投递。
    Pending,
}

/// 日志里的一条：承袭日志的槽，或原生日志的操作 / 空洞。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: OpId,
    /// 原链指纹。原生日志没有。
    pub fp: Option<Fp>,
    /// 转译 T 的版本（原生日志恒为 1）。
    pub tv: u32,
    /// 这个空洞 / 副本记录是本机自己应用 Purge / Dedup 推进出来的。
    pub local: bool,
    pub body: SlotBody,
}

impl Entry {
    /// 承袭日志的槽（原生日志的条目没有）。
    pub fn slot(&self) -> Option<HeritageSlot> {
        self.fp.map(|fp| HeritageSlot {
            id: self.id,
            fp,
            body: self.body.clone(),
        })
    }

    /// 操作（原样件、副本记录、空洞没有）。
    pub fn op(&self) -> Option<&Op4> {
        match &self.body {
            SlotBody::Op(op) => Some(op),
            _ => None,
        }
    }

    pub fn is_whole(&self) -> bool {
        matches!(self.body, SlotBody::Op(_) | SlotBody::Raw3(_))
    }
}

/// 没应用的槽：待投递的，或分叉的另一支。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parked {
    pub slot: HeritageSlot,
    pub tv: u32,
    /// 前一环的链指纹（只有待投递的、且验得出的才有）。
    pub prev_fp: Option<Fp>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DevInfo {
    pub dev: i64,
    pub id: Id,
    /// 空 = 只被别的操作点过名，还没见过它的日志。
    pub kind: Option<i64>,
    /// 承袭日志的来源集合（原协议 3 集合标识）。
    pub src: Option<Id>,
    /// 日志末尾的 seq（0 = 一条都没有）。
    pub last: u64,
}

/// profile ↔ 集合的绑定（设计 §5.1）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub col: i64,
    pub profile: String,
    /// 集合标识。
    pub collection: Id,
    /// 位置目录名。
    pub dir: String,
    /// 盐集合（这个集合里出现过的旧 uid）。它是派生值：= 操作集合里所有带盐操作的并（设计 §5.1；所有者 2026-11-12：
    /// 初始盐由迁移的那台设备写的一条专门操作携带，`Join` 带被并入集合的盐，两者取并，只增不减）。这一列只是那个并的
    /// 缓存，读入点只有派生层应用操作的那一处（[Truth::add_salts]）。
    pub salts: BTreeSet<String>,
}

#[derive(Clone)]
struct DevRow {
    col: i64,
    id: Id,
    kind: Option<i64>,
    src: Option<Id>,
    tail: Option<Chain>,
    last: Option<u64>,
    parked: Option<bool>,
}

#[derive(Default)]
struct State {
    poisoned: bool,
    dev_ix: HashMap<(i64, Id), i64>,
    devs: HashMap<i64, DevRow>,
    writer_ix: HashMap<String, u64>,
    writer_name: HashMap<u64, String>,
    snap_ix: HashMap<[u8; 32], u64>,
    snap_body: HashMap<u64, String>,
    deps_ix: HashMap<Vec<u8>, i64>,
    deps_vv: HashMap<i64, Arc<Vv>>,
}

/// 新代库上的一个读写会话。
pub struct Truth<'c> {
    conn: &'c Connection,
    st: RefCell<State>,
    no_deps: Arc<Vv>,
}

struct N<'a, 'c>(&'a Truth<'c>);

impl Names for N<'_, '_> {
    fn writer_id(&mut self, name: &str) -> Result<u64, String> {
        self.0.writer_id(name)
    }

    fn writer_name(&mut self, id: u64) -> Result<String, String> {
        self.0.writer_name(id)
    }

    fn snapshot_id(&mut self, body: &str) -> Result<u64, String> {
        self.0.snapshot_id(body)
    }

    fn snapshot_body(&mut self, id: u64) -> Result<String, String> {
        self.0.snapshot_body(id)
    }
}

fn id_of(b: &[u8]) -> Result<Id, String> {
    b.try_into()
        .map(Id)
        .map_err(|_| "gen4 store: bad id blob".to_owned())
}

fn fp_of(b: &[u8]) -> Result<Fp, String> {
    b.try_into()
        .map_err(|_| "gen4 store: bad fingerprint blob".to_owned())
}

fn chain_of(b: &[u8]) -> Result<Chain, String> {
    b.try_into()
        .map_err(|_| "gen4 store: bad chain blob".to_owned())
}

fn slot_of(bytes: &[u8]) -> Result<HeritageSlot, String> {
    let mut r = Reader::new(bytes);
    let slot = HeritageSlot::read(&mut r).map_err(|e| format!("gen4 store: parked slot: {e}"))?;
    if !r.is_empty() {
        return Err("gen4 store: parked slot has trailing bytes".to_owned());
    }
    Ok(slot)
}

struct OpRow {
    k: i64,
    wall: i64,
    logical: i64,
    deps: i64,
    kind: i64,
    fmt: i64,
    flags: i64,
    body: Vec<u8>,
    aux: Option<Vec<u8>>,
    fp: Option<Vec<u8>>,
}

fn op_row(r: &Row<'_>) -> rusqlite::Result<OpRow> {
    Ok(OpRow {
        k: r.get(0)?,
        wall: r.get(1)?,
        logical: r.get(2)?,
        deps: r.get(3)?,
        kind: r.get(4)?,
        fmt: r.get(5)?,
        flags: r.get(6)?,
        body: r.get(7)?,
        aux: r.get(8)?,
        fp: r.get(9)?,
    })
}

struct AliasRow {
    k: i64,
    kind: i64,
    wall: i64,
    logical: i64,
    of_dev: i64,
    of_seq: i64,
    flags: i64,
    stamp: Option<Vec<u8>>,
    fp: Vec<u8>,
}

fn alias_row(r: &Row<'_>) -> rusqlite::Result<AliasRow> {
    Ok(AliasRow {
        k: r.get(0)?,
        kind: r.get(1)?,
        wall: r.get(2)?,
        logical: r.get(3)?,
        of_dev: r.get(4)?,
        of_seq: r.get(5)?,
        flags: r.get(6)?,
        stamp: r.get(7)?,
        fp: r.get(8)?,
    })
}

struct VoidRun {
    k: i64,
    n: u64,
    flags: i64,
    /// 承袭日志：每个 seq 8 字节链指纹，按 seq 拼接。
    fps: Option<Vec<u8>>,
    /// 原生日志：区间末的链值。
    chain: Option<Vec<u8>>,
}

fn void_row(r: &Row<'_>) -> rusqlite::Result<VoidRun> {
    Ok(VoidRun {
        k: r.get(0)?,
        n: r.get::<_, i64>(1)? as u64,
        flags: r.get(2)?,
        fps: r.get(3)?,
        chain: r.get(4)?,
    })
}

impl VoidRun {
    fn end(&self) -> u64 {
        k_seq(self.k) + self.n - 1
    }
}

/// 没应用的槽（待投递 / 分叉的另一支）同一个 `(操作号, 链指纹)` 来了第二份：该把存着的换成什么（不用换 = None）。
fn merge_parked(
    have: Option<(HeritageSlot, u32)>,
    slot: &HeritageSlot,
    tv: u32,
) -> Result<Option<(HeritageSlot, u32)>, String> {
    let Some((have, have_tv)) = have else {
        return Ok(Some((slot.clone(), tv)));
    };
    if have == *slot {
        return Ok((tv > have_tv).then_some((have, tv)));
    }
    if tv != have_tv {
        return Ok((tv > have_tv).then(|| (slot.clone(), tv)));
    }
    match join_slots(&have, slot) {
        Joined::One(s) if s == have => Ok(None),
        Joined::One(s) => Ok(Some((s, tv))),
        Joined::Fork | Joined::Conflict => Err(format!(
            "gen4 store: two different slots for {}:{} from the same translator version",
            slot.id.device, slot.id.seq
        )),
    }
}

impl<'c> Truth<'c> {
    pub fn new(conn: &'c Connection) -> Truth<'c> {
        conn.set_prepared_statement_cache_capacity(128);
        Truth {
            conn,
            st: RefCell::new(State::default()),
            no_deps: Arc::new(Vv::new()),
        }
    }

    pub fn conn(&self) -> &'c Connection {
        self.conn
    }

    /// 丢掉内存里的缓存（事务回滚之后必须调）。
    pub fn reset(&self) {
        *self.st.borrow_mut() = State::default();
    }

    /// 在一个事务里跑 [f]；出错整笔回滚并 [Truth::reset]。可以嵌套。
    pub fn tx<T>(&self, f: impl FnOnce(&Truth<'c>) -> Result<T, String>) -> Result<T, String> {
        let r = in_tx(self.conn, |_| f(self));
        if r.is_err() {
            self.reset();
        }
        r
    }

    fn write<T>(&self, f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
        if self.st.borrow().poisoned {
            return Err(
                "gen4 store: an earlier write failed; roll back and reset first".to_owned(),
            );
        }
        if self.conn.is_autocommit() {
            return Err("gen4 store: write outside a transaction".to_owned());
        }
        let r = f();
        if r.is_err() {
            self.st.borrow_mut().poisoned = true;
        }
        r
    }

    // ------------------------------------------------------------ 绑定

    fn binding_where(
        &self,
        clause: &str,
        arg: &dyn rusqlite::ToSql,
    ) -> Result<Option<Binding>, String> {
        let row = self
            .conn
            .prepare_cached(&format!(
                "SELECT col, profile_uid, collection, dir, salts FROM collections WHERE {clause} = ?1"
            ))
            .map_err(sql)?
            .query_row([arg], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Vec<u8>>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                ))
            })
            .optional()
            .map_err(sql)?;
        let Some((col, profile, collection, dir, salts)) = row else {
            return Ok(None);
        };
        Ok(Some(Binding {
            col,
            profile,
            collection: id_of(&collection)?,
            dir,
            salts: serde_json::from_str(&salts)
                .map_err(|e| format!("gen4 store: bad salts for collection {col}: {e}"))?,
        }))
    }

    /// 这个 profile 绑定的集合（没绑过 = None）。
    pub fn binding_of(&self, profile: &str) -> Result<Option<Binding>, String> {
        self.binding_where("profile_uid", &profile)
    }

    pub fn binding(&self, col: i64) -> Result<Option<Binding>, String> {
        self.binding_where("col", &col)
    }

    /// 把 profile 绑到一个集合上，返回本机集合号。同一个 profile 再绑同一个集合是幂等的；一个 profile 只能绑一个集合，
    /// 一个集合只能绑一个 profile（设计 §5.1：同机两个 profile 不能绑定同一个集合）。改绑定是身份接线（G9）的事。
    pub fn bind(&self, profile: &str, collection: &Id, dir: &str) -> Result<i64, String> {
        self.write(|| {
            if let Some(b) = self.binding_of(profile)? {
                if b.collection == *collection && b.dir == dir {
                    return Ok(b.col);
                }
                return Err(format!(
                    "gen4 store: profile {profile} is already bound to collection {}",
                    b.collection
                ));
            }
            if let Some(b) = self.binding_where("collection", &collection.0.as_slice())? {
                return Err(format!(
                    "gen4 store: collection {collection} is already bound to profile {}",
                    b.profile
                ));
            }
            self.conn
                .prepare_cached(
                    "INSERT INTO collections (profile_uid, collection, dir, salts) VALUES (?1, ?2, ?3, '[]')",
                )
                .map_err(sql)?
                .execute(params![profile, collection.0.as_slice(), dir])
                .map_err(sql)?;
            Ok(self.conn.last_insert_rowid())
        })
    }

    /// 往盐集合里加（只增不减）。返回有没有变。调用方只有一处：派生层应用到一条带盐的操作时。
    pub fn add_salts(&self, col: i64, salts: &[&str]) -> Result<bool, String> {
        self.write(|| {
            let mut b = self
                .binding(col)?
                .ok_or_else(|| format!("gen4 store: no collection {col}"))?;
            let before = b.salts.len();
            b.salts.extend(salts.iter().map(|s| (*s).to_owned()));
            if b.salts.len() == before {
                return Ok(false);
            }
            let text = serde_json::to_string(&b.salts).map_err(sql)?;
            self.conn
                .prepare_cached("UPDATE collections SET salts = ?2 WHERE col = ?1")
                .map_err(sql)?
                .execute(params![col, text])
                .map_err(sql)?;
            Ok(true)
        })
    }

    // ------------------------------------------------------------ 设备

    fn cache_dev(&self, dev: i64, row: DevRow) {
        let mut st = self.st.borrow_mut();
        st.dev_ix.insert((row.col, row.id), dev);
        st.devs.insert(dev, row);
    }

    fn dev_find(&self, col: i64, id: &Id) -> Result<Option<i64>, String> {
        if let Some(&d) = self.st.borrow().dev_ix.get(&(col, *id)) {
            return Ok(Some(d));
        }
        let row = self
            .conn
            .prepare_cached("SELECT dev, kind, src, tail FROM devs WHERE col = ?1 AND id = ?2")
            .map_err(sql)?
            .query_row(params![col, id.0.as_slice()], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, Option<i64>>(1)?,
                    r.get::<_, Option<Vec<u8>>>(2)?,
                    r.get::<_, Option<Vec<u8>>>(3)?,
                ))
            })
            .optional()
            .map_err(sql)?;
        let Some((dev, kind, src, tail)) = row else {
            return Ok(None);
        };
        self.cache_dev(
            dev,
            DevRow {
                col,
                id: *id,
                kind,
                src: src.as_deref().map(id_of).transpose()?,
                tail: tail.as_deref().map(chain_of).transpose()?,
                last: None,
                parked: None,
            },
        );
        Ok(Some(dev))
    }

    /// 设备的下标（没有就登记一个，种类未知）。
    fn dev(&self, col: i64, id: &Id) -> Result<i64, String> {
        if let Some(d) = self.dev_find(col, id)? {
            return Ok(d);
        }
        if self.binding(col)?.is_none() {
            return Err(format!("gen4 store: no collection {col}"));
        }
        self.conn
            .prepare_cached("INSERT INTO devs (col, id) VALUES (?1, ?2)")
            .map_err(sql)?
            .execute(params![col, id.0.as_slice()])
            .map_err(sql)?;
        let dev = self.conn.last_insert_rowid();
        opk(dev, 1)?;
        self.cache_dev(
            dev,
            DevRow {
                col,
                id: *id,
                kind: None,
                src: None,
                tail: None,
                last: Some(0),
                parked: Some(false),
            },
        );
        Ok(dev)
    }

    fn dev_row(&self, dev: i64) -> Result<DevRow, String> {
        if let Some(r) = self.st.borrow().devs.get(&dev) {
            return Ok(r.clone());
        }
        let (col, id, kind, src, tail) = self
            .conn
            .prepare_cached("SELECT col, id, kind, src, tail FROM devs WHERE dev = ?1")
            .map_err(sql)?
            .query_row([dev], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, Vec<u8>>(1)?,
                    r.get::<_, Option<i64>>(2)?,
                    r.get::<_, Option<Vec<u8>>>(3)?,
                    r.get::<_, Option<Vec<u8>>>(4)?,
                ))
            })
            .optional()
            .map_err(sql)?
            .ok_or_else(|| format!("gen4 store: no device {dev}"))?;
        let row = DevRow {
            col,
            id: id_of(&id)?,
            kind,
            src: src.as_deref().map(id_of).transpose()?,
            tail: tail.as_deref().map(chain_of).transpose()?,
            last: None,
            parked: None,
        };
        self.cache_dev(dev, row.clone());
        Ok(row)
    }

    fn with_dev(&self, dev: i64, f: impl FnOnce(&mut DevRow)) -> Result<(), String> {
        self.dev_row(dev)?;
        f(self
            .st
            .borrow_mut()
            .devs
            .get_mut(&dev)
            .expect("device row was just cached"));
        Ok(())
    }

    /// 这台设备的日志是哪一种：第一次见到它的日志时定下来，之后不能变。
    fn claim(&self, dev: i64, kind: i64, src: Option<&Id>) -> Result<(), String> {
        let row = self.dev_row(dev)?;
        match row.kind {
            Some(k) if k != kind => Err(format!(
                "gen4 store: device {} already has a {} log",
                row.id,
                if k == DEV_NATIVE {
                    "native"
                } else {
                    "heritage"
                }
            )),
            Some(_) if kind == DEV_HERITAGE && row.src.as_ref() != src => Err(format!(
                "gen4 store: heritage device {} belongs to another source collection",
                row.id
            )),
            Some(_) => Ok(()),
            None => {
                self.conn
                    .prepare_cached("UPDATE devs SET kind = ?2, src = ?3 WHERE dev = ?1")
                    .map_err(sql)?
                    .execute(params![dev, kind, src.map(|s| s.0.to_vec())])
                    .map_err(sql)?;
                self.with_dev(dev, |d| {
                    d.kind = Some(kind);
                    d.src = src.copied();
                })
            }
        }
    }

    fn last(&self, dev: i64) -> Result<u64, String> {
        if let Some(n) = self.dev_row(dev)?.last {
            return Ok(n);
        }
        let (lo, hi) = k_range(dev);
        let mut n = 0u64;
        for q in [
            "SELECT MAX(k) FROM ops WHERE k BETWEEN ?1 AND ?2",
            "SELECT MAX(k) FROM op_alias WHERE k BETWEEN ?1 AND ?2",
        ] {
            let k: Option<i64> = self
                .conn
                .prepare_cached(q)
                .map_err(sql)?
                .query_row(params![lo, hi], |r| r.get(0))
                .map_err(sql)?;
            n = n.max(k.map_or(0, k_seq));
        }
        if let Some(run) = self.run_at_or_before(dev, k_seq(hi))? {
            n = n.max(run.end());
        }
        self.with_dev(dev, |d| d.last = Some(n))?;
        Ok(n)
    }

    /// 这个集合里登记过的设备（按下标升序）。
    pub fn devices(&self, col: i64) -> Result<Vec<DevInfo>, String> {
        let devs: Vec<i64> = {
            let mut stmt = self
                .conn
                .prepare_cached("SELECT dev FROM devs WHERE col = ?1 ORDER BY dev")
                .map_err(sql)?;
            let rows = stmt.query_map([col], |r| r.get(0)).map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        let mut out = Vec::with_capacity(devs.len());
        for dev in devs {
            let row = self.dev_row(dev)?;
            out.push(DevInfo {
                dev,
                id: row.id,
                kind: row.kind,
                src: row.src,
                last: self.last(dev)?,
            });
        }
        Ok(out)
    }

    /// 本机已应用的版本向量（每台设备日志的末尾）。
    pub fn applied(&self, col: i64) -> Result<Vv, String> {
        let mut vv = Vv::new();
        for d in self.devices(col)? {
            if d.last > 0 {
                vv.0.insert(d.id, d.last);
            }
        }
        Ok(vv)
    }

    /// 一台设备日志的末尾（没见过 = 0）。
    pub fn last_of(&self, col: i64, device: &Id) -> Result<u64, String> {
        match self.dev_find(col, device)? {
            Some(dev) => self.last(dev),
            None => Ok(0),
        }
    }

    // ------------------------------------------------------------ 内部化表

    fn writer_id(&self, name: &str) -> Result<u64, String> {
        if let Some(&i) = self.st.borrow().writer_ix.get(name) {
            return Ok(i);
        }
        let mut w = Writer::new();
        write_name(&mut w, name);
        let bytes = w.into_vec();
        let found: Option<i64> = self
            .conn
            .prepare_cached("SELECT id FROM writers WHERE name = ?1")
            .map_err(sql)?
            .query_row([&bytes], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let id = match found {
            Some(i) => i,
            None => {
                self.conn
                    .prepare_cached("INSERT INTO writers (name) VALUES (?1)")
                    .map_err(sql)?
                    .execute([&bytes])
                    .map_err(sql)?;
                self.conn.last_insert_rowid()
            }
        } as u64;
        let mut st = self.st.borrow_mut();
        if st.writer_ix.len() >= CACHE_MAX {
            st.writer_ix.clear();
            st.writer_name.clear();
        }
        st.writer_ix.insert(name.to_owned(), id);
        st.writer_name.insert(id, name.to_owned());
        Ok(id)
    }

    fn writer_name(&self, id: u64) -> Result<String, String> {
        if let Some(n) = self.st.borrow().writer_name.get(&id) {
            return Ok(n.clone());
        }
        let bytes: Vec<u8> = self
            .conn
            .prepare_cached("SELECT name FROM writers WHERE id = ?1")
            .map_err(sql)?
            .query_row([id as i64], |r| r.get(0))
            .optional()
            .map_err(sql)?
            .ok_or_else(|| format!("gen4 store: no writer {id}"))?;
        let mut r = Reader::new(&bytes);
        let name = read_name(&mut r).map_err(|e| format!("gen4 store: writer {id}: {e}"))?;
        if !r.is_empty() {
            return Err(format!("gen4 store: writer {id} has trailing bytes"));
        }
        let mut st = self.st.borrow_mut();
        if st.writer_name.len() >= CACHE_MAX {
            st.writer_ix.clear();
            st.writer_name.clear();
        }
        st.writer_ix.insert(name.clone(), id);
        st.writer_name.insert(id, name.clone());
        Ok(name)
    }

    fn snapshot_id(&self, body: &str) -> Result<u64, String> {
        let key = *blake3::hash(body.as_bytes()).as_bytes();
        if let Some(&i) = self.st.borrow().snap_ix.get(&key) {
            return Ok(i);
        }
        let found: Option<i64> = self
            .conn
            .prepare_cached("SELECT id FROM snapshots WHERE body = ?1")
            .map_err(sql)?
            .query_row([body], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let id = match found {
            Some(i) => i,
            None => {
                self.conn
                    .prepare_cached("INSERT INTO snapshots (body) VALUES (?1)")
                    .map_err(sql)?
                    .execute([body])
                    .map_err(sql)?;
                self.conn.last_insert_rowid()
            }
        } as u64;
        let mut st = self.st.borrow_mut();
        if st.snap_ix.len() >= 4096 {
            st.snap_ix.clear();
            st.snap_body.clear();
        }
        st.snap_ix.insert(key, id);
        st.snap_body.insert(id, body.to_owned());
        Ok(id)
    }

    fn snapshot_body(&self, id: u64) -> Result<String, String> {
        if let Some(b) = self.st.borrow().snap_body.get(&id) {
            return Ok(b.clone());
        }
        let body: String = self
            .conn
            .prepare_cached("SELECT body FROM snapshots WHERE id = ?1")
            .map_err(sql)?
            .query_row([id as i64], |r| r.get(0))
            .optional()
            .map_err(sql)?
            .ok_or_else(|| format!("gen4 store: no snapshot {id}"))?;
        let mut st = self.st.borrow_mut();
        if st.snap_body.len() >= 4096 {
            st.snap_ix.clear();
            st.snap_body.clear();
        }
        st.snap_body.insert(id, body.clone());
        Ok(body)
    }

    /// 依赖向量 → 内部化的号（空向量 = 0，不占行）。存的是 `(设备下标, seq)` 按下标升序。
    fn deps_id(&self, col: i64, deps: &Vv) -> Result<i64, String> {
        if deps.0.is_empty() {
            return Ok(0);
        }
        let mut items: Vec<(i64, u64)> = Vec::with_capacity(deps.0.len());
        for (id, &seq) in &deps.0 {
            items.push((self.dev(col, id)?, seq));
        }
        items.sort_unstable();
        let mut w = Writer::new();
        w.uv(items.len() as u64);
        for (d, s) in items {
            w.uv(d as u64);
            w.uv(s);
        }
        let bytes = w.into_vec();
        if let Some(&i) = self.st.borrow().deps_ix.get(&bytes) {
            return Ok(i);
        }
        let found: Option<i64> = self
            .conn
            .prepare_cached("SELECT id FROM op_deps WHERE bytes = ?1")
            .map_err(sql)?
            .query_row([&bytes], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let id = match found {
            Some(i) => i,
            None => {
                self.conn
                    .prepare_cached("INSERT INTO op_deps (bytes) VALUES (?1)")
                    .map_err(sql)?
                    .execute([&bytes])
                    .map_err(sql)?;
                self.conn.last_insert_rowid()
            }
        };
        let mut st = self.st.borrow_mut();
        if st.deps_ix.len() >= CACHE_MAX {
            st.deps_ix.clear();
        }
        st.deps_ix.insert(bytes, id);
        Ok(id)
    }

    fn deps_of(&self, id: i64) -> Result<Arc<Vv>, String> {
        if id == 0 {
            return Ok(self.no_deps.clone());
        }
        if let Some(v) = self.st.borrow().deps_vv.get(&id) {
            return Ok(v.clone());
        }
        let bytes: Vec<u8> = self
            .conn
            .prepare_cached("SELECT bytes FROM op_deps WHERE id = ?1")
            .map_err(sql)?
            .query_row([id], |r| r.get(0))
            .optional()
            .map_err(sql)?
            .ok_or_else(|| format!("gen4 store: no deps {id}"))?;
        let bad = |e: crate::sync2::codec::DecodeError| format!("gen4 store: deps {id}: {e}");
        let mut r = Reader::new(&bytes);
        let n = r.uv().map_err(bad)?;
        let mut vv = Vv::new();
        for _ in 0..n {
            let dev = r.uv().map_err(bad)? as i64;
            let seq = r.uv().map_err(bad)?;
            vv.0.insert(self.dev_row(dev)?.id, seq);
        }
        if !r.is_empty() {
            return Err(format!("gen4 store: deps {id} has trailing bytes"));
        }
        let vv = Arc::new(vv);
        let mut st = self.st.borrow_mut();
        if st.deps_vv.len() >= CACHE_MAX {
            st.deps_vv.clear();
        }
        st.deps_vv.insert(id, vv.clone());
        Ok(vv)
    }

    // ------------------------------------------------------------ 读

    fn op_entry(&self, row: OpRow) -> Result<Entry, String> {
        let dev = self.dev_row(k_dev(row.k))?;
        let id = OpId {
            device: dev.id,
            seq: k_seq(row.k),
        };
        let payload = pack::unpack_payload(row.flags, &row.body, row.aux.as_deref(), &mut N(self))?;
        let hlc = Hlc {
            wall: row.wall,
            logical: row.logical as u32,
            device: dev.id,
        };
        let deps = self.deps_of(row.deps)?;
        let body = if row.flags & F_RAW3 != 0 {
            SlotBody::Raw3(Raw3::of_v3(&v3::Op {
                id,
                hlc,
                deps,
                kind: row.kind as u16,
                schema: row.fmt as u16,
                payload: payload.into(),
                purged: false,
            }))
        } else {
            SlotBody::Op(Op4 {
                id,
                hlc,
                deps,
                kind: row.kind as u16,
                fmt: row.fmt as u16,
                payload: payload.into(),
            })
        };
        Ok(Entry {
            id,
            fp: row.fp.as_deref().map(fp_of).transpose()?,
            tv: tv_of(row.flags),
            local: false,
            body,
        })
    }

    fn alias_entry(&self, row: AliasRow) -> Result<Entry, String> {
        let dev = self.dev_row(k_dev(row.k))?;
        let of = self.dev_row(row.of_dev)?.id;
        let stamp = match &row.stamp {
            None => None,
            Some(b) if row.flags & A_STAMP_WIRE != 0 => {
                let mut r = Reader::new(b);
                let s = HeritageStamp::read(&mut r)
                    .map_err(|e| format!("gen4 store: stored alias stamp: {e}"))?;
                if !r.is_empty() {
                    return Err("gen4 store: stored alias stamp has trailing bytes".to_owned());
                }
                Some(s)
            }
            Some(b) => Some(pack::unpack_stamp(b, &mut N(self))?),
        };
        Ok(Entry {
            id: OpId {
                device: dev.id,
                seq: k_seq(row.k),
            },
            fp: Some(fp_of(&row.fp)?),
            tv: tv_of(row.flags),
            local: row.flags & A_LOCAL != 0,
            body: SlotBody::Alias(Alias {
                kind: row.kind as u16,
                wall: row.wall,
                logical: row.logical as u32,
                of: OpId {
                    device: of,
                    seq: row.of_seq as u64,
                },
                stamp,
            }),
        })
    }

    fn void_entry(&self, run: &VoidRun, seq: u64) -> Result<Entry, String> {
        let dev = self.dev_row(k_dev(run.k))?;
        let fp = match &run.fps {
            None => None,
            Some(f) => {
                let i = ((seq - k_seq(run.k)) * 8) as usize;
                Some(fp_of(f.get(i..i + 8).ok_or_else(|| {
                    "gen4 store: void run has too few fingerprints".to_owned()
                })?)?)
            }
        };
        Ok(Entry {
            id: OpId {
                device: dev.id,
                seq,
            },
            fp,
            tv: tv_of(run.flags),
            local: run.flags & A_LOCAL != 0,
            body: SlotBody::Void,
        })
    }

    /// 起点不晚于 [seq] 的最后一个空洞区间（不一定盖得到 [seq]）。
    fn run_at_or_before(&self, dev: i64, seq: u64) -> Result<Option<VoidRun>, String> {
        let (lo, _) = k_range(dev);
        self.conn
            .prepare_cached(
                "SELECT k, n, flags, fps, chain FROM op_voids WHERE k BETWEEN ?1 AND ?2 ORDER BY k DESC LIMIT 1",
            )
            .map_err(sql)?
            .query_row(params![lo, opk(dev, seq)?], void_row)
            .optional()
            .map_err(sql)
    }

    fn entry_at(&self, dev: i64, seq: u64) -> Result<Option<Entry>, String> {
        let k = opk(dev, seq)?;
        let op = self
            .conn
            .prepare_cached(
                "SELECT k, wall, logical, deps, kind, fmt, flags, body, aux, fp FROM ops WHERE k = ?1",
            )
            .map_err(sql)?
            .query_row([k], op_row)
            .optional()
            .map_err(sql)?;
        if let Some(row) = op {
            return self.op_entry(row).map(Some);
        }
        let alias = self
            .conn
            .prepare_cached(
                "SELECT k, kind, wall, logical, of_dev, of_seq, flags, stamp, fp FROM op_alias WHERE k = ?1",
            )
            .map_err(sql)?
            .query_row([k], alias_row)
            .optional()
            .map_err(sql)?;
        if let Some(row) = alias {
            return self.alias_entry(row).map(Some);
        }
        match self.run_at_or_before(dev, seq)? {
            Some(run) if seq <= run.end() => self.void_entry(&run, seq).map(Some),
            _ => Ok(None),
        }
    }

    /// 日志里的一条（主支；分叉的另一支见 [Truth::forks]）。
    pub fn entry(&self, col: i64, id: &OpId) -> Result<Option<Entry>, String> {
        match self.dev_find(col, &id.device)? {
            Some(dev) if id.seq >= 1 && id.seq <= self.last(dev)? => self.entry_at(dev, id.seq),
            _ => Ok(None),
        }
    }

    // ------------------------------------------------------------ 读：派生层用的按主键访问

    /// 操作号 → 主键（本机没见过这台设备 = None）。
    pub(crate) fn key_of(&self, col: i64, id: &OpId) -> Result<Option<i64>, String> {
        match self.dev_find(col, &id.device)? {
            Some(dev) => opk(dev, id.seq).map(Some),
            None => Ok(None),
        }
    }

    /// 主键 → 操作号。
    pub(crate) fn id_of_key(&self, k: i64) -> Result<OpId, String> {
        Ok(OpId {
            device: self.dev_row(k_dev(k))?.id,
            seq: k_seq(k),
        })
    }

    /// 主键 → 日志里的那一条。
    pub(crate) fn entry_by_key(&self, k: i64) -> Result<Option<Entry>, String> {
        self.entry_at(k_dev(k), k_seq(k))
    }

    /// 修改操作的字段值（规范 JSON 文本）。只读 `ops` 一行的主体、不还原旧戳（整列读正文的路径，设计 §2.3）；
    /// 不是完整的修改操作 = None。
    pub(crate) fn edit_value(&self, k: i64) -> Result<Option<String>, String> {
        let row: Option<(i64, i64, i64, Vec<u8>)> = self
            .conn
            .prepare_cached("SELECT kind, fmt, flags, body FROM ops WHERE k = ?1")
            .map_err(sql)?
            .query_row([k], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .optional()
            .map_err(sql)?;
        let Some((kind, fmt, flags, body)) = row else {
            return Ok(None);
        };
        if kind != i64::from(KIND_EDIT) {
            return Ok(None);
        }
        if flags & F_RAW3 != 0 {
            // 原样件：协议 3 的载荷，走完整的还原。
            let e = self.entry_by_key(k)?;
            return Ok(e
                .and_then(|e| e.slot())
                .and_then(|s| applied_body(&s))
                .and_then(|b| match b {
                    Body4::Edit(e) => Some(e.value),
                    _ => None,
                }));
        }
        let main = pack::main_bytes(flags, &body)?;
        match Body4::decode(KIND_EDIT, fmt as u16, &main) {
            Ok(Body4::Edit(e)) => Ok(Some(e.value)),
            _ => Ok(None),
        }
    }

    /// 一台设备日志里 seq ≤ [upto] 的旧戳：承袭的修改（含原样件里的）与副本记录各自带的那个。先给操作上的、再给
    /// 副本记录上的，各按 seq 升序。派生层重建旧闭包用（设计 §3.4）。
    pub(crate) fn for_each_stamp(
        &self,
        col: i64,
        device: &Id,
        upto: u64,
        mut f: impl FnMut(u64, &HeritageStamp) -> Result<(), String>,
    ) -> Result<(), String> {
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(());
        };
        if upto == 0 {
            return Ok(());
        }
        let (lo, top) = k_range(dev);
        let hi = if upto >= k_seq(top) {
            top
        } else {
            opk(dev, upto)?
        };
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT k, wall, logical, deps, kind, fmt, flags, body, aux, fp FROM ops                  WHERE k BETWEEN ?1 AND ?2 AND kind = ?3 ORDER BY k",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![lo, hi, i64::from(KIND_EDIT)], op_row)
            .map_err(sql)?;
        for row in rows {
            let e = self.op_entry(row.map_err(sql)?)?;
            let body = match e.slot() {
                Some(slot) => applied_body(&slot),
                None => e.op().and_then(|op| op.body().ok()),
            };
            if let Some(Body4::Edit(Edit4 { stamp: Some(s), .. })) = body {
                f(e.id.seq, &s)?;
            }
        }
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT k, kind, wall, logical, of_dev, of_seq, flags, stamp, fp FROM op_alias                  WHERE k BETWEEN ?1 AND ?2 AND stamp IS NOT NULL ORDER BY k",
            )
            .map_err(sql)?;
        let rows = stmt.query_map(params![lo, hi], alias_row).map_err(sql)?;
        for row in rows {
            let e = self.alias_entry(row.map_err(sql)?)?;
            if let SlotBody::Alias(Alias { stamp: Some(s), .. }) = &e.body {
                f(e.id.seq, s)?;
            }
        }
        Ok(())
    }

    /// 按 seq 升序走一台设备的日志（从 [from] 起）。[f] 里不要改正在走的这条日志。
    pub fn for_each(
        &self,
        col: i64,
        device: &Id,
        from: u64,
        mut f: impl FnMut(Entry) -> Result<(), String>,
    ) -> Result<(), String> {
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(());
        };
        let from = from.max(1);
        let lo = opk(dev, from)?;
        let (_, hi) = k_range(dev);
        // 起点在 [from] 之前、但盖到它的空洞区间也要走到。
        let run_lo = match self.run_at_or_before(dev, from)? {
            Some(run) if from <= run.end() => run.k,
            _ => lo,
        };
        let mut op_stmt = self
            .conn
            .prepare(
                "SELECT k, wall, logical, deps, kind, fmt, flags, body, aux, fp FROM ops WHERE k BETWEEN ?1 AND ?2 ORDER BY k",
            )
            .map_err(sql)?;
        let mut alias_stmt = self
            .conn
            .prepare(
                "SELECT k, kind, wall, logical, of_dev, of_seq, flags, stamp, fp FROM op_alias WHERE k BETWEEN ?1 AND ?2 ORDER BY k",
            )
            .map_err(sql)?;
        let mut void_stmt = self
            .conn
            .prepare(
                "SELECT k, n, flags, fps, chain FROM op_voids WHERE k BETWEEN ?1 AND ?2 ORDER BY k",
            )
            .map_err(sql)?;
        let mut ops = op_stmt.query_map(params![lo, hi], op_row).map_err(sql)?;
        let mut aliases = alias_stmt
            .query_map(params![lo, hi], alias_row)
            .map_err(sql)?;
        let mut voids = void_stmt
            .query_map(params![run_lo, hi], void_row)
            .map_err(sql)?;
        let mut o = ops.next().transpose().map_err(sql)?;
        let mut a = aliases.next().transpose().map_err(sql)?;
        let mut v = voids.next().transpose().map_err(sql)?;
        loop {
            let ko = o.as_ref().map(|r| r.k);
            let ka = a.as_ref().map(|r| r.k);
            let kv = v.as_ref().map(|r| r.k);
            let Some(min) = [ko, ka, kv].into_iter().flatten().min() else {
                return Ok(());
            };
            if ko == Some(min) {
                let row = o.take().expect("peeked row");
                o = ops.next().transpose().map_err(sql)?;
                f(self.op_entry(row)?)?;
            } else if ka == Some(min) {
                let row = a.take().expect("peeked row");
                a = aliases.next().transpose().map_err(sql)?;
                f(self.alias_entry(row)?)?;
            } else {
                let run = v.take().expect("peeked row");
                v = voids.next().transpose().map_err(sql)?;
                for seq in k_seq(run.k).max(from)..=run.end() {
                    f(self.void_entry(&run, seq)?)?;
                }
            }
        }
    }

    /// 核对一个集合的每条日志都是从 1 起、不重不漏的连续前缀，每个槽自洽。返回条数。
    pub fn audit(&self, col: i64) -> Result<u64, String> {
        let mut total = 0u64;
        for d in self.devices(col)? {
            let mut next = 1u64;
            self.for_each(col, &d.id, 1, |e| {
                if e.id.seq != next {
                    return Err(format!(
                        "gen4 store: {} log has {} where {next} should be",
                        d.id, e.id.seq
                    ));
                }
                if e.fp.is_some() != (d.kind == Some(DEV_HERITAGE)) {
                    return Err(format!(
                        "gen4 store: {}:{next} does not belong in this kind of log",
                        d.id
                    ));
                }
                if let Some(slot) = e.slot() {
                    slot.check()
                        .map_err(|m| format!("gen4 store: {}:{next} {m}", d.id))?;
                }
                next += 1;
                Ok(())
            })?;
            if next - 1 != d.last {
                return Err(format!(
                    "gen4 store: {} log ends at {} but {} was expected",
                    d.id,
                    next - 1,
                    d.last
                ));
            }
            total += d.last;
        }
        Ok(total)
    }

    // ------------------------------------------------------------ 写（内部）

    fn insert_op(
        &self,
        col: i64,
        dev: i64,
        op: &Op4,
        raw3: bool,
        fp: Option<&Fp>,
        tv: u32,
    ) -> Result<(), String> {
        let p = pack::pack_payload(op.kind, op.fmt, &op.payload, raw3, &mut N(self))?;
        let flags = p.flags | if raw3 { F_RAW3 } else { 0 } | tv_bits(tv);
        let deps = self.deps_id(col, &op.deps)?;
        self.conn
            .prepare_cached(
                "INSERT INTO ops (k, wall, logical, deps, kind, fmt, flags, body, aux, fp) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            )
            .map_err(sql)?
            .execute(params![
                opk(dev, op.id.seq)?,
                op.hlc.wall,
                op.hlc.logical,
                deps,
                op.kind,
                op.fmt,
                flags,
                p.body,
                p.aux,
                fp.map(|f| f.to_vec()),
            ])
            .map_err(sql)?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_alias(
        &self,
        col: i64,
        dev: i64,
        seq: u64,
        a: &Alias,
        fp: &Fp,
        tv: u32,
        local: bool,
    ) -> Result<(), String> {
        let of_dev = self.dev(col, &a.of.device)?;
        let mut flags = tv_bits(tv) | if local { A_LOCAL } else { 0 };
        let stamp = match &a.stamp {
            None => None,
            Some(s) => {
                // 写时核对：内部化后读不回原值的，存线格式的规范字节。
                let packed = pack::pack_stamp(s, &mut N(self))?;
                if pack::unpack_stamp(&packed, &mut N(self)).as_ref() == Ok(s) {
                    Some(packed)
                } else {
                    flags |= A_STAMP_WIRE;
                    Some(s.encode())
                }
            }
        };
        self.conn
            .prepare_cached(
                "INSERT INTO op_alias (k, kind, wall, logical, of_dev, of_seq, flags, stamp, fp) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )
            .map_err(sql)?
            .execute(params![
                opk(dev, seq)?,
                a.kind,
                a.wall,
                a.logical,
                of_dev,
                a.of.seq as i64,
                flags,
                stamp,
                fp.to_vec(),
            ])
            .map_err(sql)?;
        Ok(())
    }

    /// 写一个空洞区间，并与两侧同样标志的相邻区间合并。
    fn insert_void_run(
        &self,
        dev: i64,
        first: u64,
        n: u64,
        fps: Option<Vec<u8>>,
        chain: Option<Chain>,
        flags: i64,
    ) -> Result<(), String> {
        let mut k = opk(dev, first)?;
        let mut len = n;
        let mut fps = fps;
        let mut chain = chain.map(|c| c.to_vec());
        let mergeable = |run: &VoidRun, fps: &Option<Vec<u8>>| {
            run.flags == flags && run.fps.is_some() == fps.is_some()
        };
        if first > 1 {
            if let Some(left) = self.run_at_or_before(dev, first - 1)? {
                if left.end() + 1 == first && mergeable(&left, &fps) {
                    self.delete_run(left.k)?;
                    k = left.k;
                    len += left.n;
                    fps = match (left.fps, fps) {
                        (Some(mut l), Some(r)) => {
                            l.extend_from_slice(&r);
                            Some(l)
                        }
                        _ => None,
                    };
                }
            }
        }
        if let Ok(rk) = opk(dev, first + n) {
            let right = self
                .conn
                .prepare_cached("SELECT k, n, flags, fps, chain FROM op_voids WHERE k = ?1")
                .map_err(sql)?
                .query_row([rk], void_row)
                .optional()
                .map_err(sql)?;
            if let Some(right) = right {
                if mergeable(&right, &fps) {
                    self.delete_run(right.k)?;
                    len += right.n;
                    fps = match (fps, right.fps) {
                        (Some(mut l), Some(r)) => {
                            l.extend_from_slice(&r);
                            Some(l)
                        }
                        _ => None,
                    };
                    chain = right.chain;
                }
            }
        }
        self.conn
            .prepare_cached(
                "INSERT INTO op_voids (k, n, flags, fps, chain) VALUES (?1, ?2, ?3, ?4, ?5)",
            )
            .map_err(sql)?
            .execute(params![k, len as i64, flags, fps, chain])
            .map_err(sql)?;
        Ok(())
    }

    fn delete_run(&self, k: i64) -> Result<(), String> {
        self.conn
            .prepare_cached("DELETE FROM op_voids WHERE k = ?1")
            .map_err(sql)?
            .execute([k])
            .map_err(sql)?;
        Ok(())
    }

    /// 删掉一个操作号上的操作 / 原样件 / 副本记录行（空洞区间不动）。
    fn delete_at(&self, dev: i64, seq: u64) -> Result<(), String> {
        let k = opk(dev, seq)?;
        for q in [
            "DELETE FROM ops WHERE k = ?1",
            "DELETE FROM op_alias WHERE k = ?1",
        ] {
            self.conn
                .prepare_cached(q)
                .map_err(sql)?
                .execute([k])
                .map_err(sql)?;
        }
        Ok(())
    }

    fn store_slot(
        &self,
        col: i64,
        dev: i64,
        slot: &HeritageSlot,
        tv: u32,
        local: bool,
    ) -> Result<(), String> {
        match &slot.body {
            SlotBody::Op(op) => self.insert_op(col, dev, op, false, Some(&slot.fp), tv),
            SlotBody::Raw3(raw) => {
                let v = raw.to_v3();
                let op = Op4 {
                    id: v.id,
                    hlc: v.hlc,
                    deps: v.deps,
                    kind: v.kind,
                    fmt: v.schema,
                    payload: v.payload,
                };
                self.insert_op(col, dev, &op, true, Some(&slot.fp), tv)
            }
            SlotBody::Alias(a) => self.insert_alias(col, dev, slot.id.seq, a, &slot.fp, tv, local),
            SlotBody::Void => self.insert_void_run(
                dev,
                slot.id.seq,
                1,
                Some(slot.fp.to_vec()),
                None,
                tv_bits(tv) | if local { A_LOCAL } else { 0 },
            ),
        }
    }

    fn has_parked(&self, dev: i64) -> Result<bool, String> {
        if let Some(p) = self.dev_row(dev)?.parked {
            return Ok(p);
        }
        let (lo, hi) = k_range(dev);
        let p: bool = self
            .conn
            .prepare_cached("SELECT EXISTS(SELECT 1 FROM op_pending WHERE k BETWEEN ?1 AND ?2)")
            .map_err(sql)?
            .query_row(params![lo, hi], |r| r.get(0))
            .map_err(sql)?;
        self.with_dev(dev, |d| d.parked = Some(p))?;
        Ok(p)
    }

    /// 一个操作号落进了日志：同号的待投递行，链指纹相同的是确认（删掉），不同的是分叉的一支（挪进 `op_forks`）。
    fn settle_pending(&self, dev: i64, seq: u64, fp: &Fp) -> Result<(), String> {
        if !self.has_parked(dev)? {
            return Ok(());
        }
        let k = opk(dev, seq)?;
        self.conn
            .prepare_cached("DELETE FROM op_pending WHERE k = ?1 AND fp = ?2")
            .map_err(sql)?
            .execute(params![k, fp.to_vec()])
            .map_err(sql)?;
        self.conn
            .prepare_cached(
                "INSERT OR IGNORE INTO op_forks (k, fp, tv, slot) SELECT k, fp, tv, slot FROM op_pending WHERE k = ?1",
            )
            .map_err(sql)?
            .execute([k])
            .map_err(sql)?;
        self.conn
            .prepare_cached("DELETE FROM op_pending WHERE k = ?1")
            .map_err(sql)?
            .execute([k])
            .map_err(sql)?;
        self.with_dev(dev, |d| d.parked = None)
    }

    fn put_fork(&self, dev: i64, slot: &HeritageSlot, tv: u32) -> Result<(), String> {
        let k = opk(dev, slot.id.seq)?;
        let have = self
            .conn
            .prepare_cached("SELECT tv, slot FROM op_forks WHERE k = ?1 AND fp = ?2")
            .map_err(sql)?
            .query_row(params![k, slot.fp.to_vec()], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
            })
            .optional()
            .map_err(sql)?;
        let have = match have {
            Some((t, bytes)) => Some((slot_of(&bytes)?, t as u32)),
            None => None,
        };
        if let Some((s, t)) = merge_parked(have, slot, tv)? {
            self.conn
                .prepare_cached(
                    "INSERT OR REPLACE INTO op_forks (k, fp, tv, slot) VALUES (?1, ?2, ?3, ?4)",
                )
                .map_err(sql)?
                .execute(params![k, s.fp.to_vec(), t, s.encode()])
                .map_err(sql)?;
        }
        Ok(())
    }

    fn heritage_dev(
        &self,
        col: i64,
        src: &Id,
        slot: &HeritageSlot,
        tv: u32,
    ) -> Result<i64, String> {
        slot.check()
            .map_err(|m| format!("gen4 store: slot {}:{} {m}", slot.id.device, slot.id.seq))?;
        if tv == 0 {
            return Err("gen4 store: translator version 0".to_owned());
        }
        let dev = self.dev(col, &slot.id.device)?;
        self.claim(dev, DEV_HERITAGE, Some(src))?;
        Ok(dev)
    }

    fn put_applied(&self, col: i64, dev: i64, slot: &HeritageSlot, tv: u32) -> Result<Put, String> {
        let last = self.last(dev)?;
        let seq = slot.id.seq;
        if seq > last + 1 {
            return Err(format!(
                "gen4 store: slot {}:{seq} leaves a gap after {last}",
                slot.id.device
            ));
        }
        if seq == last + 1 {
            self.store_slot(col, dev, slot, tv, false)?;
            self.with_dev(dev, |d| d.last = Some(seq))?;
            self.settle_pending(dev, seq, &slot.fp)?;
            return Ok(Put::Inserted);
        }
        let have = self
            .entry_at(dev, seq)?
            .ok_or_else(|| format!("gen4 store: {} log has a hole at {seq}", slot.id.device))?;
        let have_slot = have
            .slot()
            .ok_or("gen4 store: heritage log holds a native entry")?;
        match join_slots(&have_slot, slot) {
            Joined::Fork => {
                self.put_fork(dev, slot, tv)?;
                Ok(Put::Fork)
            }
            Joined::One(_) if have_slot == *slot => {
                if tv > have.tv {
                    self.relabel(dev, seq, tv)?;
                }
                Ok(Put::Same)
            }
            // 秩不同：本机的槽只由本机自己推进。
            Joined::One(_) => Ok(Put::Kept),
            Joined::Conflict if tv > have.tv => {
                self.delete_at(dev, seq)?;
                self.store_slot(col, dev, slot, tv, have.local)?;
                Ok(Put::Replaced)
            }
            Joined::Conflict if tv < have.tv => Ok(Put::Kept),
            Joined::Conflict => Err(format!(
                "gen4 store: two different slots for {}:{seq} from translator version {tv}",
                slot.id.device
            )),
        }
    }

    /// 逐字节相同的槽由更高的 T 版本又转出了一遍：把标签抬上去（空洞没有内容，不抬）。
    fn relabel(&self, dev: i64, seq: u64, tv: u32) -> Result<(), String> {
        let k = opk(dev, seq)?;
        for q in [
            "UPDATE ops SET flags = (flags & 15) | ?2 WHERE k = ?1",
            "UPDATE op_alias SET flags = (flags & 15) | ?2 WHERE k = ?1",
        ] {
            self.conn
                .prepare_cached(q)
                .map_err(sql)?
                .execute(params![k, tv_bits(tv)])
                .map_err(sql)?;
        }
        Ok(())
    }

    // ------------------------------------------------------------ 写：承袭日志

    /// 收一个承袭槽（规则见文件头）。[src] = 这条旧日志的来源集合，[tv] = 转出它的 T 版本。
    pub fn put_heritage(
        &self,
        col: i64,
        src: &Id,
        slot: &HeritageSlot,
        tv: u32,
    ) -> Result<Put, String> {
        self.write(|| {
            let dev = self.heritage_dev(col, src, slot, tv)?;
            self.put_applied(col, dev, slot, tv)
        })
    }

    /// 收一个前面还缺的槽。已经在日志范围里的操作号按 [Truth::put_heritage] 的规则处理。
    pub fn put_pending(
        &self,
        col: i64,
        src: &Id,
        slot: &HeritageSlot,
        tv: u32,
        prev_fp: Option<Fp>,
    ) -> Result<Put, String> {
        self.write(|| {
            let dev = self.heritage_dev(col, src, slot, tv)?;
            if slot.id.seq <= self.last(dev)? {
                return self.put_applied(col, dev, slot, tv);
            }
            let k = opk(dev, slot.id.seq)?;
            let have = self
                .conn
                .prepare_cached("SELECT tv, slot, prev_fp FROM op_pending WHERE k = ?1 AND fp = ?2")
                .map_err(sql)?
                .query_row(params![k, slot.fp.to_vec()], |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, Vec<u8>>(1)?,
                        r.get::<_, Option<Vec<u8>>>(2)?,
                    ))
                })
                .optional()
                .map_err(sql)?;
            let (have, have_prev) = match have {
                Some((t, bytes, prev)) => (Some((slot_of(&bytes)?, t as u32)), prev),
                None => (None, None),
            };
            let have_prev = have_prev.as_deref().map(fp_of).transpose()?;
            if let (Some(a), Some(b)) = (have_prev, prev_fp) {
                if a != b {
                    return Err(format!(
                        "gen4 store: pending {}:{} names two different predecessors",
                        slot.id.device, slot.id.seq
                    ));
                }
            }
            let prev = prev_fp.or(have_prev);
            let merged = merge_parked(have, slot, tv)?;
            if merged.is_some() || prev != have_prev {
                let (s, t) = match merged {
                    Some(m) => m,
                    None => {
                        // 槽没变，只是补上了前一环的链指纹。
                        self.conn
                            .prepare_cached("UPDATE op_pending SET prev_fp = ?3 WHERE k = ?1 AND fp = ?2")
                            .map_err(sql)?
                            .execute(params![k, slot.fp.to_vec(), prev.map(|f| f.to_vec())])
                            .map_err(sql)?;
                        return Ok(Put::Pending);
                    }
                };
                self.conn
                    .prepare_cached(
                        "INSERT OR REPLACE INTO op_pending (k, fp, prev_fp, tv, slot) VALUES (?1, ?2, ?3, ?4, ?5)",
                    )
                    .map_err(sql)?
                    .execute(params![
                        k,
                        s.fp.to_vec(),
                        prev.map(|f| f.to_vec()),
                        t,
                        s.encode()
                    ])
                    .map_err(sql)?;
                self.with_dev(dev, |d| d.parked = Some(true))?;
            }
            Ok(Put::Pending)
        })
    }

    /// 正好接在这台设备日志末尾、且验得出「前一环就是本机末尾那个槽」的待投递槽。交给调用方（同步轮）判断因果上
    /// 该不该投；投 = 再调 [Truth::put_heritage]。
    pub fn pending_ready(&self, col: i64, device: &Id) -> Result<Option<Parked>, String> {
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(None);
        };
        if !self.has_parked(dev)? {
            return Ok(None);
        }
        let last = self.last(dev)?;
        let tail_fp = if last == 0 {
            fingerprint(&CHAIN_ZERO)
        } else {
            self.entry_at(dev, last)?
                .and_then(|e| e.fp)
                .ok_or("gen4 store: heritage log tail has no fingerprint")?
        };
        let rows: Vec<(i64, Vec<u8>)> = {
            let mut stmt = self
                .conn
                .prepare_cached(
                    "SELECT tv, slot FROM op_pending WHERE k = ?1 AND prev_fp = ?2 ORDER BY fp",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![opk(dev, last + 1)?, tail_fp.to_vec()], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        match rows.as_slice() {
            [] => Ok(None),
            [(tv, bytes)] => Ok(Some(Parked {
                slot: slot_of(bytes)?,
                tv: *tv as u32,
                prev_fp: Some(tail_fp),
            })),
            // 两条不同的操作都声称接在同一个槽后面：那台旧设备从这里分叉了，哪一支都不自己投。
            _ => Ok(None),
        }
    }

    fn parked(&self, col: i64, table: &str, prev: &str) -> Result<Vec<Parked>, String> {
        let rows: Vec<(i64, Vec<u8>, Option<Vec<u8>>)> = {
            let mut stmt = self
                .conn
                .prepare_cached(&format!(
                    "SELECT p.tv, p.slot, {prev} FROM {table} p JOIN devs d ON d.dev = p.k >> 40 \
                     WHERE d.col = ?1 ORDER BY p.k, p.fp"
                ))
                .map_err(sql)?;
            let rows = stmt
                .query_map([col], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(tv, bytes, prev)| {
                Ok(Parked {
                    slot: slot_of(&bytes)?,
                    tv: tv as u32,
                    prev_fp: prev.as_deref().map(fp_of).transpose()?,
                })
            })
            .collect()
    }

    /// 待投递的槽（按操作号、链指纹升序）。
    pub fn pending(&self, col: i64) -> Result<Vec<Parked>, String> {
        self.parked(col, "op_pending", "p.prev_fp")
    }

    /// 分叉的另一支（链指纹与本机日志里同号的槽不同的槽）。
    pub fn forks(&self, col: i64) -> Result<Vec<Parked>, String> {
        self.parked(col, "op_forks", "NULL")
    }

    /// 承袭日志某处的完整原链值（承袭段头要首尾两处的）。必须与那个槽的链指纹相符。
    pub fn set_mark(&self, col: i64, device: &Id, seq: u64, chain: &Chain) -> Result<(), String> {
        self.write(|| {
            let dev = self
                .dev_find(col, device)?
                .ok_or_else(|| format!("gen4 store: no device {device}"))?;
            if self.dev_row(dev)?.kind != Some(DEV_HERITAGE) {
                return Err(format!("gen4 store: {device} has no heritage log"));
            }
            let fp = match self.entry(
                col,
                &OpId {
                    device: *device,
                    seq,
                },
            )? {
                Some(e) => e.fp,
                None => None,
            };
            if fp != Some(fingerprint(chain)) {
                return Err(format!(
                    "gen4 store: chain value for {device}:{seq} does not match its slot"
                ));
            }
            self.put_mark(dev, seq, chain)
        })
    }

    fn put_mark(&self, dev: i64, seq: u64, chain: &Chain) -> Result<(), String> {
        self.conn
            .prepare_cached(
                "INSERT OR REPLACE INTO log_marks (dev, seq, chain) VALUES (?1, ?2, ?3)",
            )
            .map_err(sql)?
            .execute(params![dev, seq as i64, chain.to_vec()])
            .map_err(sql)?;
        Ok(())
    }

    /// 一条日志上记着的链值（seq 升序）。
    pub fn marks(&self, col: i64, device: &Id) -> Result<Vec<(u64, Chain)>, String> {
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(Vec::new());
        };
        let rows: Vec<(i64, Vec<u8>)> = {
            let mut stmt = self
                .conn
                .prepare_cached("SELECT seq, chain FROM log_marks WHERE dev = ?1 ORDER BY seq")
                .map_err(sql)?;
            let rows = stmt
                .query_map([dev], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(seq, chain)| Ok((seq as u64, chain_of(&chain)?)))
            .collect()
    }

    // ------------------------------------------------------------ 写：本机推进槽

    /// 本机执行了一条 Purge、目标是 [target]：完整内容 → 空洞（`gen4::translate::purge_slot` 的落库版；原生日志的
    /// 操作同理，空洞记下该处的链值）。已经是空洞 / 副本记录、或本机没有这个操作号的不动。返回有没有变。
    ///
    /// 执行不执行一条 Purge 由调用方按本机的信任状态决定（设计 §3.2）；这里只管落库。
    pub fn advance_purge(&self, col: i64, target: &OpId) -> Result<bool, String> {
        self.write(|| {
            let Some(dev) = self.dev_find(col, &target.device)? else {
                return Ok(false);
            };
            let Some(e) = self.entry(col, target)? else {
                return Ok(false);
            };
            if !e.is_whole() {
                return Ok(false);
            }
            match e.fp {
                Some(fp) => {
                    self.delete_at(dev, target.seq)?;
                    self.insert_void_run(
                        dev,
                        target.seq,
                        1,
                        Some(fp.to_vec()),
                        None,
                        tv_bits(e.tv) | A_LOCAL,
                    )?;
                }
                None => {
                    let chain = self.chain_at_dev(dev, target.seq)?;
                    self.delete_at(dev, target.seq)?;
                    self.insert_void_run(dev, target.seq, 1, None, Some(chain), A_LOCAL)?;
                }
            }
            Ok(true)
        })
    }

    /// 本机执行了一条 Dedup、其中一对说 [target] 是 [of] 的副本：完整内容 → 副本记录（`gen4::translate::dedup_slot`
    /// 的落库版）。已经是空洞 / 副本记录、或本机没有这个操作号的不动。返回有没有变。只有承袭日志有副本。
    pub fn advance_dedup(&self, col: i64, target: &OpId, of: &OpId) -> Result<bool, String> {
        self.write(|| {
            let Some(dev) = self.dev_find(col, &target.device)? else {
                return Ok(false);
            };
            let Some(e) = self.entry(col, target)? else {
                return Ok(false);
            };
            if !e.is_whole() {
                return Ok(false);
            }
            let slot = e.slot().ok_or_else(|| {
                format!(
                    "gen4 store: {}:{} is a native op; only heritage ops have duplicates",
                    target.device, target.seq
                )
            })?;
            let next = dedup_slot(&slot, *of).map_err(|m| {
                format!("gen4 store: dedup of {}:{}: {m}", target.device, target.seq)
            })?;
            let SlotBody::Alias(a) = &next.body else {
                return Err("gen4 store: dedup did not produce a duplicate record".to_owned());
            };
            self.delete_at(dev, target.seq)?;
            self.insert_alias(col, dev, target.seq, a, &slot.fp, e.tv, true)?;
            Ok(true)
        })
    }

    // ------------------------------------------------------------ 写：原生日志

    fn set_tail(&self, dev: i64, seq: u64, chain: &Chain) -> Result<(), String> {
        self.conn
            .prepare_cached("UPDATE devs SET tail = ?2 WHERE dev = ?1")
            .map_err(sql)?
            .execute(params![dev, chain.to_vec()])
            .map_err(sql)?;
        self.with_dev(dev, |d| {
            d.tail = Some(*chain);
            d.last = Some(seq);
        })
    }

    /// 往一台设备的原生日志末尾追加一条操作（本机自己写的、或从原生段里收的）。返回该处的链值——收段的一侧拿它与
    /// 段里声明的链值比。
    pub fn append_native(&self, col: i64, op: &Op4) -> Result<Chain, String> {
        self.write(|| {
            native_allowed(op)
                .map_err(|m| format!("gen4 store: {}:{} {m}", op.id.device, op.id.seq))?;
            if op.hlc.device != op.id.device || op.deps.get(&op.id.device) != 0 {
                return Err(format!(
                    "gen4 store: {}:{} envelope names the wrong device",
                    op.id.device, op.id.seq
                ));
            }
            let dev = self.dev(col, &op.id.device)?;
            self.claim(dev, DEV_NATIVE, None)?;
            let last = self.last(dev)?;
            if op.id.seq != last + 1 {
                return Err(format!(
                    "gen4 store: native op {}:{} does not follow {last}",
                    op.id.device, op.id.seq
                ));
            }
            let tail = self.dev_row(dev)?.tail.unwrap_or(CHAIN_ZERO);
            let chain = chain_next4(&tail, op);
            self.insert_op(col, dev, op, false, None, 1)?;
            self.set_tail(dev, op.id.seq, &chain)?;
            if op.id.seq % MARK_EVERY == 0 {
                self.put_mark(dev, op.id.seq, &chain)?;
            }
            Ok(chain)
        })
    }

    /// 往一台设备的原生日志末尾追加一段空洞（原生段里作者签出的空洞：条数 + 区间末的链值，附录 B 第 9 条）。
    pub fn append_native_void(
        &self,
        col: i64,
        device: &Id,
        n: u64,
        chain_after: &Chain,
    ) -> Result<(), String> {
        self.write(|| {
            if n == 0 {
                return Err("gen4 store: empty void run".to_owned());
            }
            let dev = self.dev(col, device)?;
            self.claim(dev, DEV_NATIVE, None)?;
            let last = self.last(dev)?;
            self.insert_void_run(dev, last + 1, n, None, Some(*chain_after), 0)?;
            self.set_tail(dev, last + n, chain_after)
        })
    }

    /// 原生日志在 [seq] 处的链值（0 = 链的起点）。空洞区间里只有区间末有链值。
    pub fn chain_at(&self, col: i64, device: &Id, seq: u64) -> Result<Chain, String> {
        if seq == 0 {
            return Ok(CHAIN_ZERO);
        }
        let dev = self
            .dev_find(col, device)?
            .ok_or_else(|| format!("gen4 store: no device {device}"))?;
        self.chain_at_dev(dev, seq)
    }

    fn chain_at_dev(&self, dev: i64, seq: u64) -> Result<Chain, String> {
        let row = self.dev_row(dev)?;
        if row.kind != Some(DEV_NATIVE) {
            return Err(format!("gen4 store: {} has no native log", row.id));
        }
        let last = self.last(dev)?;
        if seq == 0 || seq > last {
            return Err(format!("gen4 store: {} log has no entry {seq}", row.id));
        }
        if seq == last {
            if let Some(t) = row.tail {
                return Ok(t);
            }
        }
        let mark = self
            .conn
            .prepare_cached("SELECT seq, chain FROM log_marks WHERE dev = ?1 AND seq <= ?2 ORDER BY seq DESC LIMIT 1")
            .map_err(sql)?
            .query_row(params![dev, seq as i64], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
            })
            .optional()
            .map_err(sql)?;
        let (mut at, mut chain) = match mark {
            Some((s, c)) => (s as u64, chain_of(&c)?),
            None => (0, CHAIN_ZERO),
        };
        if let Some(run) = self.run_at_or_before(dev, seq)? {
            if run.end() > seq {
                return Err(format!(
                    "gen4 store: {}:{seq} is inside a void run; only its end has a chain value",
                    row.id
                ));
            }
            if run.end() > at {
                at = run.end();
                chain = chain_of(run.chain.as_deref().ok_or_else(|| {
                    "gen4 store: native void run without its chain value".to_owned()
                })?)?;
            }
        }
        for s in at + 1..=seq {
            let e = self
                .entry_at(dev, s)?
                .ok_or_else(|| format!("gen4 store: {} log has a hole at {s}", row.id))?;
            let op = e
                .op()
                .ok_or("gen4 store: native log holds something that is not an op")?;
            chain = chain_next4(&chain, op);
        }
        Ok(chain)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use proptest::prelude::*;

    use super::*;
    use crate::gen4::heritage::tests::slots;
    use crate::gen4::op::tests::{id, native_edit, op_of};
    use crate::gen4::op::{Body4, Edit4};
    use crate::gen4::translate::tests::arb_op3;
    use crate::gen4::translate::{purge_slot, translate};
    use crate::store::gen4::schema::open_in_memory;

    /// [slots] 用的旧设备。
    const OLD: u8 = 0x0d;
    const P: &str = "0193a1b2-0000-7000-8000-00000000beef";

    fn src() -> Id {
        id(0x5c)
    }

    fn oid(seq: u64) -> OpId {
        OpId {
            device: id(OLD),
            seq,
        }
    }

    pub(crate) fn bound(t: &Truth<'_>) -> i64 {
        t.tx(|t| t.bind(P, &id(0xc0), "dir")).unwrap()
    }

    fn put(t: &Truth<'_>, col: i64, slot: &HeritageSlot, tv: u32) -> Result<Put, String> {
        t.tx(|t| t.put_heritage(col, &src(), slot, tv))
    }

    fn all(t: &Truth<'_>, col: i64, device: &Id) -> Vec<Entry> {
        let mut out = Vec::new();
        t.for_each(col, device, 1, |e| {
            out.push(e);
            Ok(())
        })
        .unwrap();
        out
    }

    fn count(conn: &Connection, table: &str) -> i64 {
        conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap()
    }

    /// 同一个操作号、同一个链指纹、内容不同的另一条修改。
    fn other_edit(slot: &HeritageSlot, value: &str) -> HeritageSlot {
        let body = Body4::Edit(Edit4 {
            value: value.to_owned(),
            ..native_edit()
        });
        HeritageSlot::op(slot.fp, op_of(slot.id.device, slot.id.seq, &body))
    }

    #[test]
    fn every_kind_of_slot_reads_back_byte_for_byte() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let want = slots();
        for s in &want {
            assert_eq!(put(&t, col, s, 1), Ok(Put::Inserted));
        }
        // 另开一个会话读：不靠写入时的缓存。
        let t = Truth::new(&conn);
        let got = all(&t, col, &id(OLD));
        assert_eq!(got.len(), want.len());
        for (e, s) in got.iter().zip(&want) {
            assert_eq!(e.slot().unwrap().encode(), s.encode());
            assert_eq!((e.tv, e.local), (1, false));
            assert_eq!(t.entry(col, &s.id).unwrap().as_ref(), Some(e));
        }
        assert_eq!(t.audit(col).unwrap(), want.len() as u64);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 8);
        // 两个相邻的空洞存成一个区间；副本记录点名的设备登记了下标但没有日志。
        assert_eq!(
            (
                count(&conn, "ops"),
                count(&conn, "op_alias"),
                count(&conn, "op_voids")
            ),
            (4, 2, 1)
        );
        let devs = t.devices(col).unwrap();
        let old = devs.iter().find(|d| d.id == id(OLD)).unwrap();
        assert_eq!(
            (old.kind, old.src, old.last),
            (Some(DEV_HERITAGE), Some(src()), 8)
        );
        let named = devs.iter().find(|d| d.id == id(0xee)).unwrap();
        assert_eq!((named.kind, named.last), (None, 0));
        assert_eq!(t.applied(col).unwrap().0.len(), 1);
        // 从中间读起，包括从空洞区间的中间读起。
        for from in 1..=8u64 {
            let mut seqs = Vec::new();
            t.for_each(col, &id(OLD), from, |e| {
                seqs.push(e.id.seq);
                Ok(())
            })
            .unwrap();
            assert_eq!(seqs, (from..=8).collect::<Vec<_>>());
        }
        // 重放一遍是幂等的。
        for s in &want {
            assert_eq!(put(&t, col, s, 1), Ok(Put::Same));
        }
        assert_eq!(all(&t, col, &id(OLD)), got);
    }

    #[test]
    fn a_gap_is_refused_and_a_log_keeps_its_kind_and_source() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        assert!(put(&t, col, &s[1], 1).unwrap_err().contains("leaves a gap"));
        assert_eq!(put(&t, col, &s[0], 1), Ok(Put::Inserted));
        assert!(put(&t, col, &s[2], 1).unwrap_err().contains("leaves a gap"));
        // 出错的那一笔整个回滚，会话还能用。
        assert_eq!(put(&t, col, &s[1], 1), Ok(Put::Inserted));
        // 同一台旧设备不能又属于另一个来源集合，也不能又有原生日志。
        let e = t
            .tx(|t| t.put_heritage(col, &id(0x5d), &s[2], 1))
            .unwrap_err();
        assert!(e.contains("another source collection"), "{e}");
        let native = op_of(id(OLD), 3, &Body4::Edit(native_edit()));
        let e = t.tx(|t| t.append_native(col, &native)).unwrap_err();
        assert!(e.contains("already has a heritage log"), "{e}");
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 2);
        // 事务之外不许写。
        let e = t.put_heritage(col, &src(), &s[2], 1).unwrap_err();
        assert!(e.contains("outside a transaction"), "{e}");
    }

    #[test]
    fn a_received_void_or_duplicate_record_never_changes_a_whole_local_slot() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 1).unwrap();
        }
        let before = all(&t, col, &id(OLD));
        // 本机完整，来的是空洞 / 副本记录：本机不动。
        let void = purge_slot(&s[0]);
        let dup = dedup_slot(
            &s[0],
            OpId {
                device: id(0xee),
                seq: 9,
            },
        )
        .unwrap();
        assert_eq!(put(&t, col, &void, 1), Ok(Put::Kept));
        assert_eq!(put(&t, col, &dup, 1), Ok(Put::Kept));
        // 本机是空洞（seq 6），来的是完整内容 / 副本记录：本机不动（内容已经没了；副本记录要本机自己应用 Dedup 才有）。
        let whole = other_edit(&s[5], "\"back\"");
        assert_eq!(put(&t, col, &whole, 1), Ok(Put::Kept));
        let dup6 = dedup_slot(
            &whole,
            OpId {
                device: id(0xee),
                seq: 9,
            },
        )
        .unwrap();
        assert_eq!(put(&t, col, &dup6, 1), Ok(Put::Kept));
        // 本机是副本记录（seq 4），来的是空洞：本机不动。
        assert_eq!(
            put(&t, col, &HeritageSlot::void(s[3].id, s[3].fp), 1),
            Ok(Put::Kept)
        );
        assert_eq!(all(&t, col, &id(OLD)), before);
        assert_eq!(count(&conn, "op_forks"), 0);
    }

    #[test]
    fn same_rank_and_different_bytes_is_settled_by_the_translator_version() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 2).unwrap();
        }
        let other = other_edit(&s[0], "\"other\"");
        // 同一个 T 版本：异常，不落库。
        let e = put(&t, col, &other, 2).unwrap_err();
        assert!(e.contains("two different slots"), "{e}");
        assert_eq!(
            t.entry(col, &s[0].id).unwrap().unwrap().slot().unwrap(),
            s[0]
        );
        // 更低的版本：本机不动。
        assert_eq!(put(&t, col, &other, 1), Ok(Put::Kept));
        assert_eq!(
            t.entry(col, &s[0].id).unwrap().unwrap().slot().unwrap(),
            s[0]
        );
        // 更高的版本：换成来的。
        assert_eq!(put(&t, col, &other, 3), Ok(Put::Replaced));
        let e = t.entry(col, &s[0].id).unwrap().unwrap();
        assert_eq!((e.slot().unwrap(), e.tv), (other.clone(), 3));
        // 逐字节相同、版本更高：只抬标签。
        assert_eq!(put(&t, col, &s[1], 5), Ok(Put::Same));
        assert_eq!(t.entry(col, &s[1].id).unwrap().unwrap().tv, 5);
        assert_eq!(put(&t, col, &s[3], 5), Ok(Put::Same));
        assert_eq!(t.entry(col, &s[3].id).unwrap().unwrap().tv, 5);
        assert_eq!(t.audit(col).unwrap(), 8);
    }

    #[test]
    fn a_different_fingerprint_is_a_fork_and_both_branches_are_kept() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 1).unwrap();
        }
        let before = all(&t, col, &id(OLD));
        let mut branch = other_edit(&s[0], "\"branch\"");
        branch.fp = [0xfb; 8];
        assert_eq!(put(&t, col, &branch, 1), Ok(Put::Fork));
        assert_eq!(put(&t, col, &branch, 1), Ok(Put::Fork));
        assert_eq!(all(&t, col, &id(OLD)), before);
        assert_eq!(
            t.forks(col).unwrap(),
            vec![Parked {
                slot: branch.clone(),
                tv: 1,
                prev_fp: None
            }]
        );
        // 分叉的那一支没有被本机推进过：同一支来了空洞，留靠后的。
        assert_eq!(put(&t, col, &purge_slot(&branch), 1), Ok(Put::Fork));
        assert_eq!(t.forks(col).unwrap()[0].slot, purge_slot(&branch));
        assert_eq!(put(&t, col, &branch, 1), Ok(Put::Fork));
        assert_eq!(t.forks(col).unwrap()[0].slot, purge_slot(&branch));
    }

    #[test]
    fn only_the_local_purge_and_dedup_advance_a_slot() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 1).unwrap();
        }
        let of = OpId {
            device: id(0xee),
            seq: 77,
        };
        // seq 5（副本记录）旁边的 seq 6、7 是收来的空洞；把 seq 8、seq 1 清除，seq 2 认成副本。
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(8))), Ok(true));
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(1))), Ok(true));
        assert_eq!(t.tx(|t| t.advance_dedup(col, &oid(2), &of)), Ok(true));
        // 第二次、对空洞 / 副本记录、对没有的操作号：不动。
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(8))), Ok(false));
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(4))), Ok(false));
        assert_eq!(t.tx(|t| t.advance_dedup(col, &oid(6), &of)), Ok(false));
        assert_eq!(t.tx(|t| t.advance_dedup(col, &oid(2), &oid(3))), Ok(false));
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(9))), Ok(false));
        assert_eq!(
            t.tx(|t| t.advance_purge(
                col,
                &OpId {
                    device: id(0x99),
                    seq: 1
                }
            )),
            Ok(false)
        );
        let got = all(&t, col, &id(OLD));
        let want = [
            purge_slot(&s[0]),
            dedup_slot(&s[1], of).unwrap(),
            s[2].clone(),
            s[3].clone(),
            s[4].clone(),
            s[5].clone(),
            s[6].clone(),
            purge_slot(&s[7]),
        ];
        for (e, w) in got.iter().zip(&want) {
            assert_eq!(e.slot().unwrap().encode(), w.encode());
        }
        assert_eq!(
            got.iter().map(|e| e.local).collect::<Vec<_>>(),
            [true, true, false, false, false, false, false, true]
        );
        // 本机清出来的空洞与收来的空洞不并成一个区间（标志不同）：1、6–7、8 三个区间。
        assert_eq!(count(&conn, "op_voids"), 3);
        assert_eq!(t.audit(col).unwrap(), 8);
        // 原样件也能清除。
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(3))), Ok(true));
        assert_eq!(count(&conn, "ops"), 0);
    }

    #[test]
    fn a_dedup_that_protocol_3_would_fail_leaves_the_slot_alone() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        // 种类认识、载荷解不开的原样件：协议 3 的 `Op::duplicate` 在这里报错，应用那条 Dedup 的一轮整个失败。
        let raw = Raw3::of_v3(&v3::Op {
            id: oid(1),
            hlc: Hlc {
                wall: 1,
                logical: 0,
                device: id(OLD),
            },
            deps: Arc::new(Vv::new()),
            kind: v3::KIND_EDIT,
            schema: 1,
            payload: vec![0xff].into(),
            purged: false,
        });
        let slot = HeritageSlot::raw3([1; 8], raw);
        assert_eq!(put(&t, col, &slot, 1), Ok(Put::Inserted));
        let e = t
            .tx(|t| t.advance_dedup(col, &oid(1), &oid(2)))
            .unwrap_err();
        assert!(e.contains("dedup of"), "{e}");
        let got = t.entry(col, &oid(1)).unwrap().unwrap();
        assert_eq!((got.slot().unwrap(), got.local), (slot, false));
    }

    #[test]
    fn void_runs_merge_on_both_sides() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let whole: Vec<HeritageSlot> = (1..=7u64)
            .map(|seq| {
                HeritageSlot::op(
                    [seq as u8; 8],
                    op_of(id(OLD), seq, &Body4::Edit(native_edit())),
                )
            })
            .collect();
        for x in &whole {
            put(&t, col, x, 1).unwrap();
        }
        for seq in [2, 4, 6, 3, 5] {
            assert_eq!(t.tx(|t| t.advance_purge(col, &oid(seq))), Ok(true));
            assert_eq!(t.audit(col).unwrap(), 7);
        }
        assert_eq!(count(&conn, "op_voids"), 1);
        let (k, n, fps): (i64, i64, Vec<u8>) = conn
            .query_row("SELECT k, n, fps FROM op_voids", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap();
        assert_eq!((k_seq(k), n), (2, 5));
        assert_eq!(fps, (2..=6u8).flat_map(|b| [b; 8]).collect::<Vec<_>>());
        let got = all(&t, col, &id(OLD));
        for (e, w) in got.iter().zip(&whole) {
            let want = if (2..=6).contains(&w.id.seq) {
                purge_slot(w)
            } else {
                w.clone()
            };
            assert_eq!(e.slot().unwrap(), want);
        }
        // 另开会话：末尾从表里算出来。
        let t = Truth::new(&conn);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 7);
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(7))), Ok(true));
        let t = Truth::new(&conn);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 7);
        assert_eq!(count(&conn, "op_voids"), 1);
    }

    #[test]
    fn pending_slots_wait_for_their_prefix_and_are_confirmed_by_fingerprint() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        let pend = |slot: &HeritageSlot, prev: Option<Fp>| {
            t.tx(|t| t.put_pending(col, &src(), slot, 1, prev))
        };
        assert_eq!(put(&t, col, &s[0], 1), Ok(Put::Inserted));
        // 3（验不出前一环）、4（验得出接在 3 后面）、5 的一支分叉。
        assert_eq!(pend(&s[2], None), Ok(Put::Pending));
        assert_eq!(pend(&s[3], Some(s[2].fp)), Ok(Put::Pending));
        let mut branch = s[4].clone();
        branch.fp = [0xfb; 8];
        assert_eq!(pend(&branch, None), Ok(Put::Pending));
        assert_eq!(pend(&s[2], None), Ok(Put::Pending));
        assert_eq!(t.pending(col).unwrap().len(), 3);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 1);
        // 没有哪条正好接在末尾。
        assert_eq!(t.pending_ready(col, &id(OLD)).unwrap(), None);
        // 2 到了：3 正好接在末尾，但它验不出前一环，不自己投。
        assert_eq!(put(&t, col, &s[1], 1), Ok(Put::Inserted));
        assert_eq!(t.pending_ready(col, &id(OLD)).unwrap(), None);
        // 之后补上了「3 的前一环是 2」：可以投了。
        assert_eq!(pend(&s[2], Some(s[1].fp)), Ok(Put::Pending));
        let ready = t.pending_ready(col, &id(OLD)).unwrap().unwrap();
        assert_eq!(
            (ready.slot.clone(), ready.prev_fp),
            (s[2].clone(), Some(s[1].fp))
        );
        // 说它接在另一个槽后面：矛盾，报错。
        let e = pend(&s[2], Some([9; 8])).unwrap_err();
        assert!(e.contains("two different predecessors"), "{e}");
        assert_eq!(put(&t, col, &ready.slot, ready.tv), Ok(Put::Inserted));
        // 3 落库的同时它的待投递行确认掉了；4 接着可以投。
        assert_eq!(t.pending(col).unwrap().len(), 2);
        let ready = t.pending_ready(col, &id(OLD)).unwrap().unwrap();
        assert_eq!(ready.slot, s[3]);
        assert_eq!(put(&t, col, &ready.slot, 1), Ok(Put::Inserted));
        // 5 经承袭段到达：链指纹不同的那条待投递是分叉的一支。
        assert_eq!(t.pending_ready(col, &id(OLD)).unwrap(), None);
        assert_eq!(put(&t, col, &s[4], 1), Ok(Put::Inserted));
        assert_eq!(t.pending(col).unwrap(), Vec::new());
        assert_eq!(
            t.forks(col).unwrap(),
            vec![Parked {
                slot: branch,
                tv: 1,
                prev_fp: None
            }]
        );
        // 已经在日志里的操作号再当待投递来：同指纹 = 残留。
        assert_eq!(pend(&s[4], None), Ok(Put::Same));
        assert_eq!(t.pending(col).unwrap(), Vec::new());
        // 第一条也可以是待投递来的：前一环是链的起点。
        let col2 = t.tx(|t| t.bind("other", &id(0xc1), "dir2")).unwrap();
        t.tx(|t| t.put_pending(col2, &src(), &s[0], 1, Some(fingerprint(&CHAIN_ZERO))))
            .unwrap();
        assert_eq!(t.pending_ready(col2, &id(OLD)).unwrap().unwrap().slot, s[0]);
        // 两个集合互不相干。
        assert_eq!(t.last_of(col2, &id(OLD)).unwrap(), 0);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 5);
    }

    #[test]
    fn marks_must_match_the_slot_they_name() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 1).unwrap();
        }
        let mut chain = [0x77u8; 32];
        chain[..8].copy_from_slice(&s[7].fp);
        t.tx(|t| t.set_mark(col, &id(OLD), 8, &chain)).unwrap();
        // 空洞处也有链指纹。
        let mut at6 = [0x66u8; 32];
        at6[..8].copy_from_slice(&s[5].fp);
        t.tx(|t| t.set_mark(col, &id(OLD), 6, &at6)).unwrap();
        assert_eq!(t.marks(col, &id(OLD)).unwrap(), vec![(6, at6), (8, chain)]);
        let e = t.tx(|t| t.set_mark(col, &id(OLD), 7, &chain)).unwrap_err();
        assert!(e.contains("does not match its slot"), "{e}");
        let e = t.tx(|t| t.set_mark(col, &id(OLD), 9, &chain)).unwrap_err();
        assert!(e.contains("does not match its slot"), "{e}");
    }

    fn native(seq: u64, value: &str) -> Op4 {
        op_of(
            id(0xa1),
            seq,
            &Body4::Edit(Edit4 {
                value: value.to_owned(),
                ..native_edit()
            }),
        )
    }

    #[test]
    fn a_native_log_chains_and_keeps_chaining_across_purged_ops() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let dev = id(0xa1);
        let n = MARK_EVERY + 40;
        let mut chains = vec![CHAIN_ZERO];
        t.tx(|t| {
            for seq in 1..=n {
                let op = native(seq, &format!("\"v{seq}\""));
                let want = chain_next4(chains.last().unwrap(), &op);
                assert_eq!(t.append_native(col, &op)?, want);
                chains.push(want);
            }
            Ok(())
        })
        .unwrap();
        let e = t
            .tx(|t| t.append_native(col, &native(n + 2, "\"x\"")))
            .unwrap_err();
        assert!(e.contains("does not follow"), "{e}");
        // 带旧戳的修改、Dedup 进不了原生日志。
        let stamped = op_of(
            dev,
            n + 1,
            &Body4::Edit(Edit4 {
                stamp: Some(crate::gen4::stamp::tests::typical()),
                ..native_edit()
            }),
        );
        assert!(t.tx(|t| t.append_native(col, &stamped)).is_err());
        let check = |t: &Truth<'_>| {
            for seq in [
                0,
                1,
                2,
                7,
                MARK_EVERY - 1,
                MARK_EVERY,
                MARK_EVERY + 1,
                n - 1,
                n,
            ] {
                assert_eq!(
                    t.chain_at(col, &dev, seq).unwrap(),
                    chains[seq as usize],
                    "{seq}"
                );
            }
        };
        check(&t);
        check(&Truth::new(&conn));
        assert_eq!(
            t.marks(col, &dev).unwrap(),
            vec![(MARK_EVERY, chains[MARK_EVERY as usize])]
        );
        let got = all(&t, col, &dev);
        assert_eq!(got.len() as u64, n);
        assert!(got.iter().all(|e| e.fp.is_none() && e.op().is_some()));
        assert_eq!(got[4].op().unwrap(), &native(5, "\"v5\""));
        // 清除中间的、末尾的、相邻的：链值不变，空洞里只有区间末有链值。
        for seq in [5, 6, n, 3] {
            assert_eq!(
                t.tx(|t| t.advance_purge(col, &OpId { device: dev, seq })),
                Ok(true)
            );
        }
        let t = Truth::new(&conn);
        for seq in [1, 2, 3, 4, 6, 7, 8, MARK_EVERY + 1, n - 1, n] {
            assert_eq!(
                t.chain_at(col, &dev, seq).unwrap(),
                chains[seq as usize],
                "{seq}"
            );
        }
        let e = t.chain_at(col, &dev, 5).unwrap_err();
        assert!(e.contains("inside a void run"), "{e}");
        assert_eq!(t.audit(col).unwrap(), n);
        assert_eq!(count(&conn, "op_voids"), 3);
        // 接着写：链从末尾（哪怕末尾是空洞）接上。
        let op = native(n + 1, "\"next\"");
        let want = chain_next4(&chains[n as usize], &op);
        assert_eq!(t.tx(|t| t.append_native(col, &op)), Ok(want));
        // 收来的空洞区间：条数 + 区间末的链值。
        let after = [0x42u8; 32];
        t.tx(|t| t.append_native_void(col, &dev, 3, &after))
            .unwrap();
        assert_eq!(t.last_of(col, &dev).unwrap(), n + 4);
        assert_eq!(t.chain_at(col, &dev, n + 4).unwrap(), after);
        let op = native(n + 5, "\"after the void\"");
        assert_eq!(
            t.tx(|t| t.append_native(col, &op)),
            Ok(chain_next4(&after, &op))
        );
        assert_eq!(Truth::new(&conn).audit(col).unwrap(), n + 5);
        // 原生日志没有副本。
        let e = t
            .tx(|t| {
                t.advance_dedup(
                    col,
                    &OpId {
                        device: dev,
                        seq: 1,
                    },
                    &oid(1),
                )
            })
            .unwrap_err();
        assert!(e.contains("native op"), "{e}");
    }

    #[test]
    fn bindings_are_one_to_one_and_salts_only_grow() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        assert_eq!(t.tx(|t| t.bind(P, &id(0xc0), "dir")), Ok(col));
        assert!(
            t.tx(|t| t.bind(P, &id(0xc1), "dir"))
                .unwrap_err()
                .contains("already bound")
        );
        assert!(
            t.tx(|t| t.bind("p2", &id(0xc0), "dir"))
                .unwrap_err()
                .contains("already bound")
        );
        assert_eq!(t.tx(|t| t.add_salts(col, &["u2", "u1"])), Ok(true));
        assert_eq!(t.tx(|t| t.add_salts(col, &["u1"])), Ok(false));
        let b = t.binding_of(P).unwrap().unwrap();
        assert_eq!(
            (
                b.col,
                b.collection,
                b.dir.as_str(),
                b.salts.into_iter().collect::<Vec<_>>()
            ),
            (col, id(0xc0), "dir", vec!["u1".to_owned(), "u2".to_owned()])
        );
        assert_eq!(t.binding_of("nobody").unwrap(), None);
        // 没绑定的集合号收不了东西。
        let e = t
            .tx(|t| t.put_heritage(col + 9, &src(), &slots()[0], 1))
            .unwrap_err();
        assert!(e.contains("no collection"), "{e}");
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(64))]

        /// 任意旧操作转出来的槽，存进去读出来逐字节相同；任意一批本机推进之后仍是「转译 + 推进」的结果。
        #[test]
        fn any_translated_log_reads_back_byte_for_byte(
            ops in proptest::collection::vec(arb_op3(), 1..40),
            purge in proptest::collection::vec(any::<prop::sample::Index>(), 0..6),
        ) {
            let device = id(OLD);
            let mut want = Vec::new();
            for mut op in ops {
                let seq = want.len() as u64 + 1;
                op.id = OpId { device, seq };
                op.hlc.device = device;
                let chain = *blake3::hash(&seq.to_le_bytes()).as_bytes();
                if let Ok(slot) = translate(&op, &chain) {
                    want.push(slot);
                }
            }
            let conn = open_in_memory().unwrap();
            let t = Truth::new(&conn);
            let col = bound(&t);
            t.tx(|t| {
                for s in &want {
                    t.put_heritage(col, &src(), s, 1)?;
                }
                Ok(())
            }).unwrap();
            for ix in purge {
                if want.is_empty() {
                    break;
                }
                let i = ix.index(want.len());
                let changed = t.tx(|t| t.advance_purge(col, &want[i].id)).unwrap();
                prop_assert_eq!(changed, purge_slot(&want[i]) != want[i]);
                want[i] = purge_slot(&want[i]);
            }
            let t = Truth::new(&conn);
            let got = all(&t, col, &device);
            prop_assert_eq!(got.len(), want.len());
            for (e, s) in got.iter().zip(&want) {
                prop_assert_eq!(e.slot().unwrap().encode(), s.encode());
            }
            prop_assert_eq!(t.audit(col).unwrap(), want.len() as u64);
        }
    }
}
