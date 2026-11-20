//! 同步运行时的本机状态（规划 §1.3 的 G8-4 那几张表；表见 `schema.rs` 的 `SYNC`）：各位置上各设备最新的 head
//! （`loc_heads`）、本机转发到各位置的文件（`relay_out`）、各位置旧根的清单指纹（`oldroot_fp`）。原生操作的等待缓冲
//! `op_wait` 由收段（`receive.rs`）写，这里只给只读的 [Truth::waiting]。
//!
//! 这些都是「从头对账」的东西（D11）：迁移不带过来，丢了下一轮同步重新列一遍位置就回来，不影响集合内容。所以规则
//! 只求「不倒退、不丢待删的文件」，不求跨设备一致。
//!
//! # 规则
//!
//! - **head 只进不退**（[Truth::put_loc_head]）：同一个位置、同一台设备，代号更大且 seq 不倒退才换；代号相同、内容
//!   相同 = 已有；代号相同而内容不同、或代号更大而 seq 倒退 = [LocHeadPut::Conflict]（同一个作者在一个位置上的两份
//!   head 互相矛盾：作者分叉或位置被改过，交给身份分叉的检测 G8-6），什么都不写；代号更小 = 过时，不写。
//! - **转发两段式删除**（[Truth::relay_sent] / [Truth::relay_supersede] / [Truth::relay_deleted]）：被新转发取代的旧件先标成
//!   待删（`gone = 1`），调用方删掉位置上的文件、回报之后才去掉这一行；删到一半失败、崩溃，下一轮
//!   [Truth::relay_gone] 照样列出来再删。只能去掉待删的行：还在用的转发件不会被一次误报的「删好了」抹掉记账。
//!   同名的件又被转发一次（同名重写）就回到在用。
//! - **旧根指纹**（[Truth::set_oldroot_fp]）：只记最近一次核对的结果，调用方拿 [oldroot_fingerprint] 算出本轮的、与记下的
//!   比，不同就去捡漏（设计 §6.2 第 4 步）。指纹是清单的纯函数，与列出来的顺序无关；同名文件（Google Drive 允许）逐条都算。
//!
//! # 事务
//!
//! 写入全经 [Truth] 的写入守卫（必须在事务里、会话没被毒化、缓存与库同一个版本），报错时调用方回滚并 reset，与真相层
//! 同一个口径（`truth.rs`「会话与事务」）。集合号必须是绑着的集合，位置键不能是空文本。

use rusqlite::{OptionalExtension, params};

use super::schema::sql;
use super::truth::Truth;
use crate::gen4::location::{V4File, device_path, parse_v4_path};
use crate::gen4::op::Op4;
use crate::gen4::recut::{RecutItem, Stub, author_signed, recut4};
use crate::gen4::segment::NativeHeader;
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::id::Id;
use crate::sync2::keys::CollectionKey;
use crate::sync2::segment::{Chain, chain_tag};
use crate::sync2::vv::OpId;

/// 作者签过的一段（一个版本）：从本机日志重切（[Truth::recut_from_log]）要的全部材料——作者签的段头与签名、作者签
/// 的空洞在哪（`(起始 seq, 条数, 区间末链值)`）。收段时落下（[Truth::note_author_version]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthorVersion {
    pub header: NativeHeader,
    pub sig: [u8; 64],
    pub voids: Vec<(u64, u64, Chain)>,
}

impl AuthorVersion {
    fn voided(&self) -> u64 {
        self.voids.iter().map(|v| v.1).sum()
    }
}

fn voids_bytes(voids: &[(u64, u64, Chain)]) -> Vec<u8> {
    let mut w = Writer::new();
    w.uv(voids.len() as u64);
    for (at, n, chain) in voids {
        w.uv(*at);
        w.uv(*n);
        w.raw(chain);
    }
    w.into_vec()
}

fn voids_of(bytes: &[u8]) -> Result<Vec<(u64, u64, Chain)>, String> {
    let bad = |_| "gen4 store: bad author version voids".to_owned();
    let mut r = Reader::new(bytes);
    let n = r.uv().map_err(bad)?;
    let mut out = Vec::new();
    for _ in 0..n {
        let at = r.uv().map_err(bad)?;
        let count = r.uv().map_err(bad)?;
        out.push((at, count, chain32(r.raw(32).map_err(bad)?)?));
    }
    if !r.is_empty() {
        return Err("gen4 store: trailing bytes in author version voids".to_owned());
    }
    Ok(out)
}

/// 从本机日志重切出来、还没签的一段（[Truth::recut_from_log]）：作者签的段头、作者签名与全部项（已核对作者签名）。
#[derive(Clone, Debug)]
pub struct RecutParts {
    pub header: NativeHeader,
    pub author_sig: [u8; 64],
    pub items: Vec<RecutItem>,
    /// 作者公钥（签之前 `recut4` 再核一次）。
    pub author: [u8; 32],
}

/// 一个位置上一台设备最新的 head（只记同步层要的几样）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocHead {
    pub device: Id,
    /// head 的代号（作者每重写一次 head 加一）。
    pub gen: u64,
    /// head 覆盖到的 seq。
    pub seq: u64,
    /// head 引用的段文件名，按 head 里的顺序。
    pub segs: Vec<String>,
}

/// [Truth::put_loc_head] 的结果。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LocHeadPut {
    /// 这台设备在这个位置上第一次有记录。
    Inserted,
    /// 换成了更新的 head。
    Advanced,
    /// 已有一模一样的。
    Same,
    /// 比记下的旧，没写。
    Stale,
    /// 与记下的互相矛盾（同代号不同内容，或代号更大而 seq 倒退），没写。
    Conflict,
}

/// 一个位置上本机转发过的一台作者的文件（`relay_out` 主键前缀；查询计划测试用同一份）。
pub(crate) const RELAY_OUT_OF_SQL: &str = "SELECT name, gen, gone FROM relay_out      WHERE col = ?1 AND loc_key = ?2 AND device = ?3 ORDER BY name";

/// 本机转发到一个位置的一个文件（`relay_out` 的一行）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelayOut {
    /// 作者。
    pub device: Id,
    /// 位置上 `v4/devices/<作者>/` 下的文件名（`rly-…` 中继件、`rhd-…` 转发 head）。
    pub name: String,
    /// 转发时作者 head 的代号。
    pub gen: u64,
    /// 被更新的转发取代、等删。
    pub gone: bool,
}

/// 一个位置旧根上一次核对的结果。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OldRootFp {
    pub fp: [u8; 32],
    /// 核对的时刻（毫秒）。
    pub at: i64,
}

/// 旧根清单里的一个文件（[oldroot_fingerprint] 的输入）。
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct OldRootEntry {
    /// 相对旧根（`v3/`）的路径，`/` 分隔。
    pub path: String,
    pub size: u64,
    /// 传输给得出的修改时刻（毫秒）；给不出 = None。同名重写在大小不变时只能靠它看出来。
    pub modified: Option<i64>,
}

const FP_DOMAIN: &[u8] = b"fushi-srs-oldroot-fp/4\n";

/// 旧根清单的指纹：按 (路径, 大小, 修改时刻) 排序后逐条哈希，与列出来的顺序无关；新文件、删掉的、同名重写（大小或
/// 修改时刻变了）、被删又重建（修改时刻变了）都会让它变。
pub fn oldroot_fingerprint(entries: &[OldRootEntry]) -> [u8; 32] {
    let mut sorted: Vec<&OldRootEntry> = entries.iter().collect();
    sorted.sort();
    let mut h = blake3::Hasher::new();
    h.update(FP_DOMAIN);
    h.update(&(sorted.len() as u64).to_le_bytes());
    for e in sorted {
        h.update(&(e.path.len() as u64).to_le_bytes());
        h.update(e.path.as_bytes());
        h.update(&e.size.to_le_bytes());
        match e.modified {
            Some(m) => {
                h.update(&[1]);
                h.update(&m.to_le_bytes());
            }
            None => {
                h.update(&[0]);
            }
        };
    }
    *h.finalize().as_bytes()
}

/// 等待缓冲里的一项（[Truth::waiting]）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Waiting {
    /// 这一项的第一个操作号。
    pub id: OpId,
    /// 占几个 seq（操作 = 1）。
    pub span: u64,
    /// 这一项之前、之后的链值。
    pub prev: [u8; 32],
    pub chain: [u8; 32],
    /// 操作；空洞 = None。
    pub op: Option<Op4>,
}

/// `op_wait` 的一行：(k, prev, chain, span, op)。
pub(super) type WaitRow = (i64, Vec<u8>, Vec<u8>, i64, Option<Vec<u8>>);

/// `op_wait` 一行里投递判断要的列：(k, prev, chain, span)（不含操作正文）。
pub(super) type WaitKey = (i64, Vec<u8>, Vec<u8>, i64);

/// 一台设备主键区间里的等待项（[Truth::waiting_between]）：主键 `(k, prev, chain)` 上的区间读，只取前四列。
pub(crate) const WAIT_RANGE_SQL: &str =
    "SELECT k, prev, chain, span FROM op_wait WHERE k BETWEEN ?1 AND ?2 ORDER BY k, prev, chain";

/// 一个等待项的操作正文（[Truth::waiting_op]）：主键点查。
pub(crate) const WAIT_OP_SQL: &str =
    "SELECT op FROM op_wait WHERE k = ?1 AND prev = ?2 AND chain = ?3";

/// 一台作者的全部作者签名版本（[Truth::author_versions_of]）：主键前缀，按 (first, last)。
pub(crate) const AUTH_OF_SQL: &str =
    "SELECT head, sig, voids FROM relay_auth WHERE col = ?1 AND device = ?2 ORDER BY first, last";

/// 一台设备的全部剔除记录（[Truth::stubs_of]）：主键区间，按 seq。
pub(crate) const STUBS_OF_SQL: &str =
    "SELECT stub FROM relay_stubs WHERE k BETWEEN ?1 AND ?2 ORDER BY k";

/// 按主键区间删剔除记录（[Truth::keep_stubs_within]）。
pub(crate) const STUBS_DROP_SQL: &str = "DELETE FROM relay_stubs WHERE k BETWEEN ?1 AND ?2";

/// 一台设备的等待项数（[Truth::waiting_count]）。
pub(crate) const WAIT_COUNT_SQL: &str = "SELECT COUNT(*) FROM op_wait WHERE k BETWEEN ?1 AND ?2";

fn u64_of(v: i64, what: &str) -> Result<u64, String> {
    u64::try_from(v).map_err(|_| format!("gen4 store: negative {what}"))
}

fn i64_of(v: u64, what: &str) -> Result<i64, String> {
    i64::try_from(v).map_err(|_| format!("gen4 store: {what} out of range"))
}

pub(super) fn chain32(b: &[u8]) -> Result<[u8; 32], String> {
    b.try_into()
        .map_err(|_| "gen4 store: bad chain value".to_owned())
}

pub(super) fn op_of_bytes(b: &[u8]) -> Result<Op4, String> {
    let mut r = Reader::new(b);
    let op = Op4::read(&mut r).map_err(|e| format!("gen4 store: bad waiting op: {}", e.0))?;
    if !r.is_empty() {
        return Err("gen4 store: trailing bytes after a waiting op".to_owned());
    }
    Ok(op)
}

impl<'c> Truth<'c> {
    fn sync_target(&self, col: i64, loc: &str) -> Result<(), String> {
        if loc.is_empty() {
            return Err("gen4 store: empty location key".to_owned());
        }
        if self.binding(col)?.is_none() {
            return Err(format!("gen4 store: no collection {col}"));
        }
        Ok(())
    }

    // ------------------------------------------------------------ 作者签过的段（重切的材料）

    /// 收下（或重收）作者 [header] 的设备签的一段之后调：记下这一段的作者签名与作者签的空洞（[AuthorVersion]），之后
    /// 本机清除了其中别人的操作、要从日志重切这一段时用（[Truth::recut_from_log]）。同一区间只留一份：作者签的空洞
    /// 最多的那份（作者每次重切只会多挖，空洞多的那份与本机日志对得上的机会不少于旧的；本机落了作者新版里的空洞，
    /// 旧版本就对不上了）。本机状态（`relay_auth`，[super::schema] 的 `SYNC`），不同步、不导出。
    pub(crate) fn note_author_version(&self, col: i64, v: &AuthorVersion) -> Result<(), String> {
        let (first, last) = (
            i64_of(v.header.first, "seq")?,
            i64_of(v.header.last, "seq")?,
        );
        let device = v.header.device;
        if self
            .author_version(col, &device, v.header.first, v.header.last)?
            .is_some_and(|old| old.voided() >= v.voided())
        {
            return Ok(());
        }
        let mut hw = Writer::new();
        v.header.write(&mut hw);
        self.write(|| {
            self.conn()
                .prepare_cached(
                    "INSERT OR REPLACE INTO relay_auth (col, device, first, last, head, sig, voids) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                )
                .map_err(sql)?
                .execute(params![
                    col,
                    &device.0[..],
                    first,
                    last,
                    hw.into_vec(),
                    &v.sig[..],
                    voids_bytes(&v.voids)
                ])
                .map_err(sql)?;
            Ok(())
        })
    }

    /// 记下的作者 [device] 段 `[first, last]` 的那一份（[Truth::note_author_version]）。
    pub(crate) fn author_version(
        &self,
        col: i64,
        device: &Id,
        first: u64,
        last: u64,
    ) -> Result<Option<AuthorVersion>, String> {
        let row: Option<(Vec<u8>, Vec<u8>, Vec<u8>)> = self
            .conn()
            .prepare_cached(
                "SELECT head, sig, voids FROM relay_auth WHERE col = ?1 AND device = ?2 AND first = ?3 AND last = ?4",
            )
            .map_err(sql)?
            .query_row(
                params![
                    col,
                    &device.0[..],
                    i64_of(first, "seq")?,
                    i64_of(last, "seq")?
                ],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()
            .map_err(sql)?;
        row.map(|(head, sig, voids)| {
            let mut r = Reader::new(&head);
            let header = NativeHeader::read(&mut r)
                .map_err(|e| format!("gen4 store: bad author version head: {}", e.0))?;
            Ok(AuthorVersion {
                header,
                sig: sig
                    .try_into()
                    .map_err(|_| "gen4 store: bad author version sig".to_owned())?,
                voids: voids_of(&voids)?,
            })
        })
        .transpose()
    }

    /// 记下一条被挖掉的操作的剔除记录（[Stub]：作者签名覆盖的那部分 + 清掉它的 Purge）。本机清除了别人的操作时
    /// （`Truth::advance_purge`）、收重切件落下别人挖掉的那些时（`receive.rs`）写。本机状态（`relay_stubs`），只给
    /// [Truth::recut_from_log] 用。
    pub(crate) fn put_stub(&self, col: i64, stub: &Stub) -> Result<(), String> {
        self.write(|| {
            let k = self.key_for(col, &stub.id())?;
            self.conn()
                .prepare_cached("INSERT OR REPLACE INTO relay_stubs (k, stub) VALUES (?1, ?2)")
                .map_err(sql)?
                .execute(params![k, stub.encode()])
                .map_err(sql)?;
            Ok(())
        })
    }

    /// 记下的 [device] 第 [seq] 条的剔除记录。
    pub(crate) fn stub_at(&self, col: i64, device: &Id, seq: u64) -> Result<Option<Stub>, String> {
        let id = OpId {
            device: *device,
            seq,
        };
        let Some(k) = self.key_of(col, &id)? else {
            return Ok(None);
        };
        let bytes: Option<Vec<u8>> = self
            .conn()
            .prepare_cached("SELECT stub FROM relay_stubs WHERE k = ?1")
            .map_err(sql)?
            .query_row([k], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let Some(bytes) = bytes else {
            return Ok(None);
        };
        let stub = Stub::decode(&bytes).map_err(|e| format!("gen4 store: bad stub: {}", e.0))?;
        Ok((stub.id() == id).then_some(stub))
    }

    /// 记下的作者 [device] 的全部作者签名版本，按 (first, last) 升序（主键前缀；导出与回收用）。
    pub(crate) fn author_versions_of(
        &self,
        col: i64,
        device: &Id,
    ) -> Result<Vec<AuthorVersion>, String> {
        let rows: Vec<(Vec<u8>, Vec<u8>, Vec<u8>)> = {
            let mut stmt = self.conn().prepare_cached(AUTH_OF_SQL).map_err(sql)?;
            let rows = stmt
                .query_map(params![col, &device.0[..]], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(head, sig, voids)| {
                let mut r = Reader::new(&head);
                let header = NativeHeader::read(&mut r)
                    .map_err(|e| format!("gen4 store: bad author version head: {}", e.0))?;
                Ok(AuthorVersion {
                    header,
                    sig: sig
                        .try_into()
                        .map_err(|_| "gen4 store: bad author version sig".to_owned())?,
                    voids: voids_of(&voids)?,
                })
            })
            .collect()
    }

    /// 记下的设备 [device] 的全部剔除记录，按 seq 升序（`relay_stubs` 主键区间；导出与回收用）。设备在本集合里没有
    /// 设备行 = 空。
    pub(crate) fn stubs_of(&self, col: i64, device: &Id) -> Result<Vec<Stub>, String> {
        let Some(k) = self.key_of(
            col,
            &OpId {
                device: *device,
                seq: 1,
            },
        )?
        else {
            return Ok(Vec::new());
        };
        let (lo, hi) = super::schema::k_range(super::schema::k_dev(k));
        let rows: Vec<Vec<u8>> = {
            let mut stmt = self.conn().prepare_cached(STUBS_OF_SQL).map_err(sql)?;
            let rows = stmt.query_map(params![lo, hi], |r| r.get(0)).map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.iter()
            .map(|b| Stub::decode(b).map_err(|e| format!("gen4 store: bad stub: {}", e.0)))
            .collect()
    }

    /// 删掉作者 [device] 区间 `[first, last]` 的作者签名版本（`cmd/sync_relay.rs` `reclaim_material`：哪个位置都不会再
    /// 要这一段的重切）。
    pub(crate) fn drop_author_version(
        &self,
        col: i64,
        device: &Id,
        first: u64,
        last: u64,
    ) -> Result<(), String> {
        self.write(|| {
            self.conn()
                .prepare_cached(
                    "DELETE FROM relay_auth WHERE col = ?1 AND device = ?2 AND first = ?3 AND last = ?4",
                )
                .map_err(sql)?
                .execute(params![
                    col,
                    &device.0[..],
                    i64_of(first, "seq")?,
                    i64_of(last, "seq")?
                ])
                .map_err(sql)?;
            Ok(())
        })
    }

    /// 设备 [device] 的剔除记录只留 seq 落在 [keep]（闭区间，可乱序、可重叠）里的，其余删掉；返回删了几条。按空白的
    /// 主键区间整段删（语句数随区间数，不随记录数）。
    pub(crate) fn keep_stubs_within(
        &self,
        col: i64,
        device: &Id,
        keep: &[(u64, u64)],
    ) -> Result<u64, String> {
        let Some(k) = self.key_of(
            col,
            &OpId {
                device: *device,
                seq: 1,
            },
        )?
        else {
            return Ok(0);
        };
        let (lo, hi) = super::schema::k_range(super::schema::k_dev(k));
        let mut spans: Vec<(u64, u64)> = keep.iter().copied().filter(|(a, b)| a <= b).collect();
        spans.sort_unstable();
        // 要删的主键区间 = 设备区间减去要留的（合并重叠之后取空白）。
        let mut gaps: Vec<(i64, i64)> = Vec::new();
        let mut next = lo;
        for (a, b) in spans {
            let (ka, kb) = (
                lo | i64_of(a, "seq")?.min(hi - lo),
                lo | i64_of(b, "seq")?.min(hi - lo),
            );
            if ka > next {
                gaps.push((next, ka - 1));
            }
            next = next.max(kb.saturating_add(1));
        }
        if next <= hi {
            gaps.push((next, hi));
        }
        self.write(|| {
            let mut n = 0u64;
            let mut stmt = self.conn().prepare_cached(STUBS_DROP_SQL).map_err(sql)?;
            for (a, b) in gaps {
                n += stmt.execute(params![a, b]).map_err(sql)? as u64;
            }
            Ok(n)
        })
    }

    // ------------------------------------------------------------ loc_heads

    /// 位置 [loc] 上设备 [device] 最新的 head（没记过 = None）。
    pub fn loc_head(&self, col: i64, loc: &str, device: &Id) -> Result<Option<LocHead>, String> {
        let row: Option<(i64, i64, String)> = self
            .conn()
            .prepare_cached(
                "SELECT gen, seq, segs FROM loc_heads WHERE col = ?1 AND loc_key = ?2 AND device = ?3",
            )
            .map_err(sql)?
            .query_row(params![col, loc, &device.0[..]], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .optional()
            .map_err(sql)?;
        row.map(|(gen, seq, segs)| {
            Ok(LocHead {
                device: *device,
                gen: u64_of(gen, "head gen")?,
                seq: u64_of(seq, "head seq")?,
                segs: serde_json::from_str(&segs)
                    .map_err(|e| format!("gen4 store: bad segment list: {e}"))?,
            })
        })
        .transpose()
    }

    /// 位置 [loc] 上记下的全部 head，按设备 ID 字节序。
    pub fn loc_heads(&self, col: i64, loc: &str) -> Result<Vec<LocHead>, String> {
        let rows: Vec<(Vec<u8>, i64, i64, String)> = {
            let mut stmt = self
                .conn()
                .prepare_cached(
                    "SELECT device, gen, seq, segs FROM loc_heads WHERE col = ?1 AND loc_key = ?2 ORDER BY device",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![col, loc], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(device, gen, seq, segs)| {
                Ok(LocHead {
                    device: Id(device
                        .try_into()
                        .map_err(|_| "gen4 store: bad device id".to_owned())?),
                    gen: u64_of(gen, "head gen")?,
                    seq: u64_of(seq, "head seq")?,
                    segs: serde_json::from_str(&segs)
                        .map_err(|e| format!("gen4 store: bad segment list: {e}"))?,
                })
            })
            .collect()
    }

    /// 记下这一轮在位置 [loc] 上读到的 [head]（文件头「head 只进不退」）。
    pub fn put_loc_head(&self, col: i64, loc: &str, head: &LocHead) -> Result<LocHeadPut, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let gen = i64_of(head.gen, "head gen")?;
            let seq = i64_of(head.seq, "head seq")?;
            let segs = serde_json::to_string(&head.segs).map_err(sql)?;
            let put = match self.loc_head(col, loc, &head.device)? {
                None => LocHeadPut::Inserted,
                Some(cur) if cur == *head => return Ok(LocHeadPut::Same),
                Some(cur) if head.gen < cur.gen => return Ok(LocHeadPut::Stale),
                Some(cur) if head.gen == cur.gen || head.seq < cur.seq => {
                    return Ok(LocHeadPut::Conflict);
                }
                Some(_) => LocHeadPut::Advanced,
            };
            self.conn()
                .prepare_cached(
                    "INSERT OR REPLACE INTO loc_heads (col, loc_key, device, gen, seq, segs) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                )
                .map_err(sql)?
                .execute(params![col, loc, &head.device.0[..], gen, seq, segs])
                .map_err(sql)?;
            Ok(put)
        })
    }

    /// 本机不再同步到位置 [loc]（用户移除了它）：去掉这个位置的 head 记录、转发记账、旧根指纹。返回去掉的行数。
    /// 待删的转发件随之忘掉——位置已经不用了，上面的文件不归本机管。`media_at` / `loc_state` 不归这里（G8-3 / G7-2）。
    pub fn forget_location(&self, col: i64, loc: &str) -> Result<u64, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let mut n = 0u64;
            for table in ["loc_heads", "relay_out", "relay_park", "oldroot_fp"] {
                n += self
                    .conn()
                    .prepare_cached(&format!(
                        "DELETE FROM {table} WHERE col = ?1 AND loc_key = ?2"
                    ))
                    .map_err(sql)?
                    .execute(params![col, loc])
                    .map_err(sql)? as u64;
            }
            Ok(n)
        })
    }

    // ------------------------------------------------------------ relay_out

    /// 本机把作者 [device] 的文件 [name] 转发到了位置 [loc]（当时作者 head 的代号 [gen]）。已记过的换成新代号；
    /// 待删的同名件回到在用（同名重写）。返回是否改了库。
    pub fn relay_sent(
        &self,
        col: i64,
        loc: &str,
        device: &Id,
        name: &str,
        gen: u64,
    ) -> Result<bool, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            if name.is_empty() {
                return Err("gen4 store: empty relay file name".to_owned());
            }
            let gen = i64_of(gen, "relay gen")?;
            let n = self
                .conn()
                .prepare_cached(
                    "INSERT INTO relay_out (col, loc_key, device, name, gen, gone) VALUES (?1, ?2, ?3, ?4, ?5, 0) \
                     ON CONFLICT (col, loc_key, device, name) DO UPDATE SET gen = excluded.gen, gone = 0 \
                     WHERE relay_out.gen != excluded.gen OR relay_out.gone != 0",
                )
                .map_err(sql)?
                .execute(params![col, loc, &device.0[..], name, gen])
                .map_err(sql)?;
            Ok(n > 0)
        })
    }

    /// 作者 [device] 在位置 [loc] 上的转发已经换成代号 [gen] 的了：代号更小、还在用的件改成待删，返回它们的文件名
    /// （按名字升序）。调用方删掉位置上的文件后逐个 [Truth::relay_deleted]。
    pub fn relay_supersede(
        &self,
        col: i64,
        loc: &str,
        device: &Id,
        gen: u64,
    ) -> Result<Vec<String>, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let gen = i64_of(gen, "relay gen")?;
            let names: Vec<String> = {
                let mut stmt = self
                    .conn()
                    .prepare_cached(
                        "SELECT name FROM relay_out WHERE col = ?1 AND loc_key = ?2 AND device = ?3 \
                         AND gen < ?4 AND gone = 0 ORDER BY name",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![col, loc, &device.0[..], gen], |r| r.get(0))
                    .map_err(sql)?;
                rows.collect::<rusqlite::Result<_>>().map_err(sql)?
            };
            self.conn()
                .prepare_cached(
                    "UPDATE relay_out SET gone = 1 WHERE col = ?1 AND loc_key = ?2 AND device = ?3 \
                     AND gen < ?4 AND gone = 0",
                )
                .map_err(sql)?
                .execute(params![col, loc, &device.0[..], gen])
                .map_err(sql)?;
            Ok(names)
        })
    }

    /// 位置 [loc] 上本机转发过的全部文件（含待删的），按 (作者, 文件名) 升序。
    pub fn relay_out(&self, col: i64, loc: &str) -> Result<Vec<RelayOut>, String> {
        let rows: Vec<(Vec<u8>, String, i64, i64)> = {
            let mut stmt = self
                .conn()
                .prepare_cached(
                    "SELECT device, name, gen, gone FROM relay_out WHERE col = ?1 AND loc_key = ?2 \
                     ORDER BY device, name",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![col, loc], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(device, name, gen, gone)| {
                Ok(RelayOut {
                    device: Id(device
                        .try_into()
                        .map_err(|_| "gen4 store: bad device id".to_owned())?),
                    name,
                    gen: u64_of(gen, "relay gen")?,
                    gone: gone != 0,
                })
            })
            .collect()
    }

    /// 位置 [loc] 上本机转发过的作者 [device] 的文件（主键前缀 `(col, loc_key, device)`，[RELAY_OUT_OF_SQL]）。
    pub fn relay_out_of(&self, col: i64, loc: &str, device: &Id) -> Result<Vec<RelayOut>, String> {
        let mut stmt = self.conn().prepare_cached(RELAY_OUT_OF_SQL).map_err(sql)?;
        let rows = stmt
            .query_map(params![col, loc, &device.0[..]], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                ))
            })
            .map_err(sql)?;
        let mut out = Vec::new();
        for row in rows {
            let (name, gen, gone) = row.map_err(sql)?;
            out.push(RelayOut {
                device: *device,
                name,
                gen: u64_of(gen, "relay gen")?,
                gone: gone != 0,
            });
        }
        Ok(out)
    }

    /// 本机把作者 [device] 的 [seq] 落成了空洞（`Truth::advance_purge` 调，同一个事务）。转发手里这条内容的两种副本：
    ///
    /// - 本机缓存的作者段（`relay_segs`）里覆盖它的：**重切**（`gen4/recut.rs`）——从本机日志重切这一段（被清除的
    ///   操作换成剔除项，作者签名照样验得过）、用本机的钥匙签出，原地换掉原文。之后照常转发出去，只经本机拿数据的位置
    ///   照样拿得到这位作者其余的操作（本机此后的操作都依赖它们，拿不到就连本机的也投不了）。重切不出来（本机还没有
    ///   身份、没记下这一段的作者签名、这条没有剔除记录……）时整份删掉：删的是转发缓存、不是数据，缺的那一段之后由
    ///   `relay_outbox` 从日志重切或记缺。不往上报错：辅助缓存不能挡住用户的彻底清除。
    /// - 已经转发到各位置上、覆盖它的 `rly-`（`relay_out` 在用的行）改成待删：下一次 `relay_outbox` 把它当缺的、用重切件
    ///   同名重写（`relay_ack` 记回在用，不再删）；重切不出来时 `relay_ack` 交给调用方删掉位置上那份带原文的件
    ///   （两段式删除，同 [Truth::relay_supersede]）。
    pub(crate) fn relay_purged(&self, col: i64, device: &Id, seq: u64) -> Result<(), String> {
        self.write(|| {
            let s = i64::try_from(seq).map_err(|_| "gen4 store: seq out of range")?;
            let kept: Vec<(i64, i64, i64, String, Vec<u8>)> = {
                let mut stmt = self
                    .conn()
                    .prepare_cached(
                        "SELECT id, first, last, tag, piece FROM relay_segs WHERE col = ?1 AND device = ?2 AND first <= ?3 AND last >= ?3",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![col, &device.0[..], s], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                    })
                    .map_err(sql)?;
                rows.collect::<rusqlite::Result<_>>().map_err(sql)?
            };
            for (id, first, last, tag, piece) in kept {
                // 这一份在 [seq] 上本来就没有内容（作者自己重切过、或已是重切件）：不用动。
                if self.relay_piece_carries(col, device, &piece, seq)? == Some(false) {
                    continue;
                }
                let range = (u64_of(first, "seq")?, u64_of(last, "seq")?, tag.as_str());
                let recut = match self.recut_from_log(col, device, range)? {
                    Some(parts) => self.sign_recut(col, &parts, None)?,
                    None => None,
                };
                match recut {
                    Some(bytes) => {
                        self.conn()
                            .prepare_cached("UPDATE relay_segs SET piece = ?2 WHERE id = ?1")
                            .map_err(sql)?
                            .execute(params![id, bytes])
                            .map_err(sql)?;
                    }
                    None => {
                        self.conn()
                            .prepare_cached("DELETE FROM relay_segs WHERE id = ?1")
                            .map_err(sql)?
                            .execute([id])
                            .map_err(sql)?;
                    }
                }
            }
            let rows: Vec<(String, String)> = {
                let mut stmt = self
                    .conn()
                    .prepare_cached(
                        "SELECT loc_key, name FROM relay_out WHERE col = ?1 AND device = ?2 AND gone = 0",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![col, &device.0[..]], |r| Ok((r.get(0)?, r.get(1)?)))
                    .map_err(sql)?;
                rows.collect::<rusqlite::Result<_>>().map_err(sql)?
            };
            for (loc, name) in rows {
                let covers = matches!(
                    parse_v4_path(&device_path(device, &name)),
                    Some(V4File::Relay { first, last, .. }) if first <= seq && seq <= last
                );
                if covers {
                    self.conn()
                        .prepare_cached(
                            "UPDATE relay_out SET gone = 1 WHERE col = ?1 AND loc_key = ?2 AND device = ?3 \
                             AND name = ?4",
                        )
                        .map_err(sql)?
                        .execute(params![col, loc, &device.0[..], name])
                        .map_err(sql)?;
                }
            }
            Ok(())
        })
    }

    /// 转发缓存里作者 [device] 的一份不封装的件 [piece]（`FRL4` / `FRX4`）在 [seq] 上带不带操作的完整内容。解不开
    /// （签名者的公钥本机没有、坏件）= None。
    fn relay_piece_carries(
        &self,
        col: i64,
        device: &Id,
        piece: &[u8],
        seq: u64,
    ) -> Result<Option<bool>, String> {
        let Some(author) = self.device_key(col, device)? else {
            return Ok(None);
        };
        let opened = if piece.starts_with(crate::gen4::recut::MAGIC) {
            let Ok(prefix) = crate::gen4::recut::peek_recut4(piece) else {
                return Ok(None);
            };
            let Some(recutter) = self.device_key(col, &prefix.recutter)? else {
                return Ok(None);
            };
            crate::gen4::recut::open_recut4_items(piece, &author, &recutter, None)
                .map(|(p, items)| (p.header.first, items))
        } else {
            crate::gen4::relay::open_relay4_items(piece, &author, None)
                .map(|(h, items)| (h.first, items))
        };
        let Ok((mut at, items)) = opened else {
            return Ok(None);
        };
        for item in &items {
            let end = at + item.span() - 1;
            if (at..=end).contains(&seq) {
                return Ok(Some(matches!(
                    item,
                    crate::gen4::segment::NativeItem::Op(_)
                )));
            }
            at = end + 1;
        }
        Ok(Some(false))
    }

    /// 用本机的钥匙签出 [parts]（[Truth::recut_from_log] 的结果），按 [dst_key] 封装。本机还没有身份 = None。
    pub(crate) fn sign_recut(
        &self,
        col: i64,
        parts: &RecutParts,
        dst_key: Option<&CollectionKey>,
    ) -> Result<Option<Vec<u8>>, String> {
        let Some(me) = self.self_identity(col)? else {
            return Ok(None);
        };
        Ok(recut4(
            &parts.header,
            &parts.author_sig,
            &parts.items,
            &parts.author,
            &me.key(),
            me.device,
            dst_key,
        )
        .ok())
    }

    /// 从本机日志重切作者 [device] 的段 `[first, last]`（链尾标签 [tag]）：本机记着这一段的作者签名（[AuthorVersion]），
    /// 日志盖得到这一段；作者签的空洞原样照搬，其余每个 seq 本机要么有完整的操作（原样留下），要么有它的剔除记录
    /// （[Truth::put_stub]）；至少挖掉一条；拼出来的项作者签名验得过（拿作者公钥核过，签不出作者不认的件）。都满足
    /// 时交回段头、作者签名与全部项，交 `gen4/recut.rs` 的 `recut4` 签出；否则 None（这一段本机重切不出来）。转发缓存
    /// 原地重切（[Truth::relay_purged]）与缓存里没留这一段时（`cmd/sync_relay.rs` 的 `relay_outbox`）用它。
    pub(crate) fn recut_from_log(
        &self,
        col: i64,
        device: &Id,
        (first, last, tag): (u64, u64, &str),
    ) -> Result<Option<RecutParts>, String> {
        if first == 0 || last < first || self.last_of(col, device)? < last {
            return Ok(None);
        }
        let Some(v) = self.author_version(col, device, first, last)? else {
            return Ok(None);
        };
        if chain_tag(&v.header.last_chain) != tag {
            return Ok(None);
        }
        let Some(author) = self.device_key(col, device)? else {
            return Ok(None);
        };
        let mut slots: Vec<Option<Op4>> = Vec::new();
        self.for_range(col, device, first, last, |e| {
            slots.push(e.op().cloned());
            Ok(())
        })?;
        if slots.len() as u64 != last - first + 1 {
            return Err(format!(
                "gen4 store: {device} log {first}..={last} is not contiguous"
            ));
        }
        let mut items: Vec<RecutItem> = Vec::new();
        let mut stubs = 0usize;
        let mut seq = first;
        while seq <= last {
            if let Some((_, count, chain)) = v.voids.iter().find(|(at, _, _)| *at == seq) {
                if *count == 0 || seq + count - 1 > last {
                    return Ok(None);
                }
                items.push(RecutItem::Void {
                    count: *count,
                    chain_after: *chain,
                });
                seq += count;
                continue;
            }
            match &slots[(seq - first) as usize] {
                Some(op) => items.push(RecutItem::Op(op.clone())),
                None => match self.stub_at(col, device, seq)? {
                    Some(s) => {
                        items.push(RecutItem::Stub(s));
                        stubs += 1;
                    }
                    None => return Ok(None),
                },
            }
            seq += 1;
        }
        if stubs == 0 || !author_signed(&v.header, &v.sig, &items, &author) {
            return Ok(None);
        }
        Ok(Some(RecutParts {
            header: v.header,
            author_sig: v.sig,
            items,
            author,
        }))
    }

    /// 位置 [loc] 上待删的转发件。
    pub fn relay_gone(&self, col: i64, loc: &str) -> Result<Vec<RelayOut>, String> {
        Ok(self
            .relay_out(col, loc)?
            .into_iter()
            .filter(|r| r.gone)
            .collect())
    }

    /// 调用方删掉了位置 [loc] 上的待删件 [name]：去掉这一行。只认待删的行（还在用的、没记过的 = false，什么都不改）。
    pub fn relay_deleted(
        &self,
        col: i64,
        loc: &str,
        device: &Id,
        name: &str,
    ) -> Result<bool, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let n = self
                .conn()
                .prepare_cached(
                    "DELETE FROM relay_out WHERE col = ?1 AND loc_key = ?2 AND device = ?3 AND name = ?4 \
                     AND gone = 1",
                )
                .map_err(sql)?
                .execute(params![col, loc, &device.0[..], name])
                .map_err(sql)?;
            Ok(n > 0)
        })
    }

    // ------------------------------------------------------------ oldroot_fp

    /// 位置 [loc] 旧根上一次核对的结果。
    pub fn oldroot_fp(&self, col: i64, loc: &str) -> Result<Option<OldRootFp>, String> {
        let row: Option<(Vec<u8>, i64)> = self
            .conn()
            .prepare_cached("SELECT fp, at FROM oldroot_fp WHERE col = ?1 AND loc_key = ?2")
            .map_err(sql)?
            .query_row(params![col, loc], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .map_err(sql)?;
        row.map(|(fp, at)| {
            Ok(OldRootFp {
                fp: fp
                    .try_into()
                    .map_err(|_| "gen4 store: bad old-root fingerprint".to_owned())?,
                at,
            })
        })
        .transpose()
    }

    /// 记下这一轮核对位置 [loc] 旧根的结果。返回指纹是否变了（第一次记 = 变了）；没变只更新时刻。
    pub fn set_oldroot_fp(
        &self,
        col: i64,
        loc: &str,
        fp: &[u8; 32],
        at: i64,
    ) -> Result<bool, String> {
        self.write(|| {
            self.sync_target(col, loc)?;
            let changed = self.oldroot_fp(col, loc)?.is_none_or(|cur| cur.fp != *fp);
            self.conn()
                .prepare_cached(
                    "INSERT OR REPLACE INTO oldroot_fp (col, loc_key, fp, at) VALUES (?1, ?2, ?3, ?4)",
                )
                .map_err(sql)?
                .execute(params![col, loc, &fp[..], at])
                .map_err(sql)?;
            Ok(changed)
        })
    }

    // ------------------------------------------------------------ op_wait（只读）

    /// 集合 [col] 的原生等待缓冲，按操作主键升序。
    pub fn waiting(&self, col: i64) -> Result<Vec<Waiting>, String> {
        let rows: Vec<WaitRow> = {
            let mut stmt = self
                .conn()
                .prepare_cached(
                    "SELECT w.k, w.prev, w.chain, w.span, w.op FROM op_wait w JOIN devs d ON d.dev = w.k >> 40 \
                     WHERE d.col = ?1 ORDER BY w.k, w.prev, w.chain",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map([col], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(k, prev, chain, span, op)| {
                Ok(Waiting {
                    id: self.id_of_key(k)?,
                    span: u64_of(span, "span")?,
                    prev: chain32(&prev)?,
                    chain: chain32(&chain)?,
                    op: op.as_deref().map(op_of_bytes).transpose()?,
                })
            })
            .collect()
    }

    /// 一台设备（下标 [dev]）在主键区间 `[from, upto]` 里的等待项，只取判断投不投要的列（不读操作正文），按主键升序。
    /// 收段收尾投递（`receive.rs` `drain_native`）只读到「本机末尾 + 1」为止，所以一片的读取量跟这一片投出的项数走，
    /// 不随整个缓冲变大（[WAIT_RANGE_SQL]）。
    pub(super) fn waiting_between(&self, from: i64, upto: i64) -> Result<Vec<WaitKey>, String> {
        let mut stmt = self.conn().prepare_cached(WAIT_RANGE_SQL).map_err(sql)?;
        let rows = stmt
            .query_map(params![from, upto], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .map_err(sql)?;
        rows.collect::<rusqlite::Result<_>>().map_err(sql)
    }

    /// 等待项 [w] 的操作正文（空洞 = None）。行必须在。
    pub(super) fn waiting_op(&self, w: &WaitKey) -> Result<Option<Op4>, String> {
        let op: Option<Vec<u8>> = self
            .conn()
            .prepare_cached(WAIT_OP_SQL)
            .map_err(sql)?
            .query_row(params![w.0, &w.1, &w.2], |r| r.get(0))
            .map_err(sql)?;
        op.as_deref().map(op_of_bytes).transpose()
    }

    /// 集合 [col] 的原生等待项数（按设备主键区间数，不读、不解操作正文；[WAIT_COUNT_SQL]）。
    pub fn waiting_count(&self, col: i64) -> Result<u64, String> {
        let mut n = 0u64;
        for d in self.devices(col)? {
            let (lo, hi) = super::schema::k_range(d.dev);
            let c: i64 = self
                .conn()
                .prepare_cached(WAIT_COUNT_SQL)
                .map_err(sql)?
                .query_row(params![lo, hi], |r| r.get(0))
                .map_err(sql)?;
            n += u64_of(c, "waiting count")?;
        }
        Ok(n)
    }

    /// 删掉一台设备（下标 [dev]）的全部等待项（它被认成了承袭日志，原生项永远落不下）。
    pub(super) fn drop_waiting_of(&self, dev: i64) -> Result<(), String> {
        let (lo, hi) = super::schema::k_range(dev);
        self.write(|| {
            self.conn()
                .prepare_cached("DELETE FROM op_wait WHERE k BETWEEN ?1 AND ?2")
                .map_err(sql)?
                .execute(params![lo, hi])
                .map_err(sql)
                .map(|_| ())
        })
    }

    // ------------------------------------------------------------ 停用的设备（G8-7）

    /// 集合 [col] 里本机停用了的设备（「这台设备不用了」）：设备 → 停用记录 `{"at", "applied", "headSeq"}`。
    ///
    /// 记在 `srs_meta`（键 [retired_key]，协议 3 `sync2_retired/<profile>/<设备>` 的新代版；不迁移：停用是纯本机的
    /// 收段让步，换代后用户再停用一次即可）。收段（`receive.rs`）把停用设备上的依赖当成已满足——因等它的数据而卡在
    /// 等待缓冲里的操作照常投递（协议 3 `devices.rs` 的 `deps_ready` 同一口径）。主键区间扫（[RETIRED_SQL]）。
    pub fn retired(
        &self,
        col: i64,
    ) -> Result<std::collections::BTreeMap<Id, serde_json::Value>, String> {
        let (lo, hi) = retired_range(col);
        let mut stmt = self.conn().prepare_cached(RETIRED_SQL).map_err(sql)?;
        let rows = stmt
            .query_map(params![lo, hi], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .map_err(sql)?;
        let mut out = std::collections::BTreeMap::new();
        for row in rows {
            let (k, v) = row.map_err(sql)?;
            let Some(device) = k.get(lo.len()..).and_then(Id::parse) else {
                continue;
            };
            // 停用与否只看键在不在（`set_retired` 写键、取消停用删键）；记录体只带显示用的 `at` / `applied` /
            // `headSeq`。记录体读不懂 = `Null`，不当成空记录混过去：`status` 在这台设备的行上报 `warning`
            // （[RETIRED_RECORD_UNREADABLE]），用户取消停用（删键）即可清掉。
            let v = serde_json::from_str::<serde_json::Value>(&v)
                .ok()
                .filter(serde_json::Value::is_object)
                .unwrap_or(serde_json::Value::Null);
            out.insert(device, v);
        }
        Ok(out)
    }

    /// 停用（[record] = Some）/ 取消停用（None）一台设备。必须在事务里。
    pub fn set_retired(
        &self,
        col: i64,
        device: &Id,
        record: Option<&serde_json::Value>,
    ) -> Result<(), String> {
        self.write(|| {
            let key = retired_key(col, device);
            match record {
                Some(v) => self
                    .conn()
                    .prepare_cached(
                        "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
                         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    )
                    .map_err(sql)?
                    .execute(params![key, v.to_string()])
                    .map_err(sql)?,
                None => self
                    .conn()
                    .prepare_cached("DELETE FROM srs_meta WHERE key = ?1")
                    .map_err(sql)?
                    .execute([key])
                    .map_err(sql)?,
            };
            Ok(())
        })
    }
}

/// 停用记录体读不懂时 `status` 设备行的 `warning`（[Truth::retired]）。
pub(crate) const RETIRED_RECORD_UNREADABLE: &str = "retired record unreadable";

/// [Truth::retired] 执行的语句：`srs_meta` 主键上的一段区间（查询计划测试用同一份）。
pub(crate) const RETIRED_SQL: &str =
    "SELECT key, value FROM srs_meta WHERE key >= ?1 AND key < ?2 ORDER BY key";

/// 停用记录的键：`gen4_retired/<col>/<设备>`。
pub(crate) fn retired_key(col: i64, device: &Id) -> String {
    format!("gen4_retired/{col}/{}", device.text())
}

/// 集合 [col] 的停用记录所在的键区间 `[lo, hi)`（`/` 的下一个字符是 `0`）。
pub(crate) fn retired_range(col: i64) -> (String, String) {
    (
        format!("gen4_retired/{col}/"),
        format!("gen4_retired/{col}0"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::op::tests::id;
    use crate::store::gen4::schema::open_in_memory;
    use crate::store::gen4::truth::tests::bound;

    const LOC: &str = "folder:/srs";

    fn head(gen: u64, seq: u64, segs: &[&str]) -> LocHead {
        LocHead {
            device: id(0x21),
            gen,
            seq,
            segs: segs.iter().map(|s| s.to_string()).collect(),
        }
    }

    /// 作者签名的版本按区间记一份，只换成作者签的空洞更多的那份；剔除记录按 (设备, seq) 存取，别的集合 / 设备互不相干。
    #[test]
    fn author_versions_keep_the_most_voided_and_stubs_round_trip() {
        use crate::gen4::segment::tests::{DEV, coll, items_of, ops};
        use crate::gen4::segment::{NativeItem, pack_native};
        use crate::sync2::keys::DeviceKey;
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let a = id(DEV);
        let signer = DeviceKey::from_seed(&[7; 32]);
        let ops = ops();
        let version = |items: &[NativeItem], voids: Vec<(u64, u64, Chain)>| {
            let (header, bytes) = pack_native(coll(), a, 1, items, [0; 32], &signer, None).unwrap();
            let sig = crate::gen4::segment::open_native_verified(&bytes, &signer.public(), None)
                .unwrap()
                .author_sig();
            AuthorVersion { header, sig, voids }
        };
        assert!(t.author_version(col, &a, 1, 5).unwrap().is_none());
        let plain = version(&items_of(&ops), Vec::new());
        t.tx(|t| t.note_author_version(col, &plain)).unwrap();
        assert_eq!(
            t.author_version(col, &a, 1, 5).unwrap().unwrap().sig,
            plain.sig
        );
        // 作者挖掉 seq 2 的那一版：空洞更多，换掉。
        let mut cut = items_of(&ops);
        cut[1] = NativeItem::Void {
            count: 1,
            chain_after: [2; 32],
        };
        let voided = version(&cut, vec![(2, 1, [2; 32])]);
        t.tx(|t| t.note_author_version(col, &voided)).unwrap();
        let got = t.author_version(col, &a, 1, 5).unwrap().unwrap();
        assert_eq!(
            (got.sig, got.voids.clone()),
            (voided.sig, vec![(2, 1, [2; 32])])
        );
        assert_eq!(got.header.last_chain, voided.header.last_chain);
        // 空洞没更多的旧版不覆盖。
        t.tx(|t| t.note_author_version(col, &plain)).unwrap();
        assert_eq!(
            t.author_version(col, &a, 1, 5).unwrap().unwrap().sig,
            voided.sig
        );
        // 区间、设备不同都查不到。
        assert!(t.author_version(col, &a, 1, 4).unwrap().is_none());
        assert!(t.author_version(col, &id(0x22), 1, 5).unwrap().is_none());

        let purge = OpId {
            device: id(0x22),
            seq: 7,
        };
        let stub = Stub::of(&ops[2], purge);
        assert!(t.stub_at(col, &a, 3).unwrap().is_none());
        t.tx(|t| t.put_stub(col, &stub)).unwrap();
        let back = t.stub_at(col, &a, 3).unwrap().unwrap();
        assert_eq!(back.encode(), stub.encode());
        assert!(t.stub_at(col, &a, 4).unwrap().is_none());
    }

    /// 复核 minor：转发缓存里读不了的件（解不开、签名者的公钥本机没有）不让清除失败：整份删掉，清除照常。
    #[test]
    fn an_unreadable_relay_copy_does_not_fail_the_purge() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = crate::store::gen4::native::tests::ready(&t);
        // a 的公钥本机有（件解不开）；u 的没有（签名者不认得）。
        let (a, u) = (id(0x21), id(0x22));
        t.tx(|t| {
            t.set_peer(
                col,
                &crate::store::gen4::truth::Peer {
                    device: a,
                    public: crate::sync2::keys::DeviceKey::from_seed(&[0x21; 32]).public(),
                    name: None,
                    ext: None,
                    head_gen: None,
                    first_seen: None,
                },
            )
            .map(|_| ())
        })
        .unwrap();
        let rows: [(&Id, &[u8]); 4] = [
            (&a, b"FRX4 not a recut"),
            (&a, b"FRL4 not a relay"),
            (&a, b"garbage"),
            (&u, b"FRL4 of a device without a key"),
        ];
        for (i, (dev, piece)) in rows.iter().enumerate() {
            conn.execute(
                "INSERT INTO relay_segs (col, device, first, last, tag, piece) VALUES (?1, ?2, 1, ?3, 'x', ?4)",
                params![col, &dev.0[..], 3 + i as i64, piece],
            )
            .unwrap();
        }
        assert_eq!(t.tx(|t| t.relay_purged(col, &a, 2)), Ok(()));
        assert_eq!(t.tx(|t| t.relay_purged(col, &u, 2)), Ok(()));
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM relay_segs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn a_location_head_only_moves_forward() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let put = |h: &LocHead| t.tx(|t| t.put_loc_head(col, LOC, h)).unwrap();
        assert_eq!(put(&head(2, 10, &["seg-1-10-a"])), LocHeadPut::Inserted);
        assert_eq!(put(&head(2, 10, &["seg-1-10-a"])), LocHeadPut::Same);
        assert_eq!(put(&head(1, 12, &["x"])), LocHeadPut::Stale);
        // 同代号不同内容、代号更大而 seq 倒退：矛盾，不写。
        assert_eq!(put(&head(2, 11, &["seg-1-11-b"])), LocHeadPut::Conflict);
        assert_eq!(put(&head(3, 9, &["seg-1-9-c"])), LocHeadPut::Conflict);
        assert_eq!(
            t.loc_head(col, LOC, &id(0x21)).unwrap(),
            Some(head(2, 10, &["seg-1-10-a"]))
        );
        // 代号更大、seq 不变（合并小段改了清单）：换。
        assert_eq!(put(&head(3, 10, &["seg-1-10-a2"])), LocHeadPut::Advanced);
        assert_eq!(
            put(&head(4, 14, &["seg-1-10-a2", "seg-11-14-d"])),
            LocHeadPut::Advanced
        );
        // 别的位置、别的设备互不相干。
        let other = LocHead {
            device: id(0x22),
            ..head(1, 1, &[])
        };
        assert_eq!(
            t.tx(|t| t.put_loc_head(col, "webdav:x", &other)),
            Ok(LocHeadPut::Inserted)
        );
        assert_eq!(
            t.tx(|t| t.put_loc_head(col, LOC, &other)),
            Ok(LocHeadPut::Inserted)
        );
        assert_eq!(
            t.loc_heads(col, LOC).unwrap(),
            vec![head(4, 14, &["seg-1-10-a2", "seg-11-14-d"]), other.clone()]
        );
        assert_eq!(t.loc_heads(col, "webdav:x").unwrap(), vec![other]);
    }

    #[test]
    fn misuse_is_refused_and_writes_need_a_transaction() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let e = t.put_loc_head(col, LOC, &head(1, 1, &[])).unwrap_err();
        assert!(e.contains("outside a transaction"), "{e}");
        let e = t
            .tx(|t| t.put_loc_head(col + 1, LOC, &head(1, 1, &[])))
            .unwrap_err();
        assert!(e.contains("no collection"), "{e}");
        let e = t
            .tx(|t| t.put_loc_head(col, "", &head(1, 1, &[])))
            .unwrap_err();
        assert!(e.contains("empty location"), "{e}");
        let e = t.tx(|t| t.relay_sent(col, LOC, &id(1), "", 1)).unwrap_err();
        assert!(e.contains("empty relay"), "{e}");
        let e = t
            .tx(|t| t.put_loc_head(col, LOC, &head(u64::MAX, 1, &[])))
            .unwrap_err();
        assert!(e.contains("out of range"), "{e}");
        // 报过错的写入回滚了，什么都没留下。
        assert_eq!(t.loc_heads(col, LOC).unwrap(), vec![]);
    }

    #[test]
    fn a_superseded_relay_stays_until_its_deletion_is_reported() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let a = id(0x31);
        assert_eq!(
            t.tx(|t| t.relay_sent(col, LOC, &a, "rly-1-4-aa", 1)),
            Ok(true)
        );
        assert_eq!(t.tx(|t| t.relay_sent(col, LOC, &a, "rhd-a-1", 1)), Ok(true));
        assert_eq!(
            t.tx(|t| t.relay_sent(col, LOC, &a, "rhd-a-1", 1)),
            Ok(false)
        );
        assert_eq!(
            t.tx(|t| t.relay_sent(col, LOC, &a, "rly-5-9-bb", 2)),
            Ok(true)
        );
        // 还在用的件不能被一次「删好了」抹掉。
        assert_eq!(
            t.tx(|t| t.relay_deleted(col, LOC, &a, "rly-1-4-aa")),
            Ok(false)
        );
        assert_eq!(
            t.tx(|t| t.relay_supersede(col, LOC, &a, 2)),
            Ok(vec!["rhd-a-1".to_owned(), "rly-1-4-aa".to_owned()])
        );
        // 再取代一次不重复列。
        assert_eq!(t.tx(|t| t.relay_supersede(col, LOC, &a, 2)), Ok(vec![]));
        let gone: Vec<String> = t
            .relay_gone(col, LOC)
            .unwrap()
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(gone, vec!["rhd-a-1", "rly-1-4-aa"]);
        // 删了一个、另一个删到一半失败：下一轮照样列出来。
        assert_eq!(t.tx(|t| t.relay_deleted(col, LOC, &a, "rhd-a-1")), Ok(true));
        let gone: Vec<String> = t
            .relay_gone(col, LOC)
            .unwrap()
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(gone, vec!["rly-1-4-aa"]);
        // 同名重写：回到在用。
        assert_eq!(
            t.tx(|t| t.relay_sent(col, LOC, &a, "rly-1-4-aa", 3)),
            Ok(true)
        );
        assert_eq!(t.relay_gone(col, LOC).unwrap(), vec![]);
        assert_eq!(
            t.relay_out(col, LOC).unwrap(),
            vec![
                RelayOut {
                    device: a,
                    name: "rly-1-4-aa".into(),
                    gen: 3,
                    gone: false
                },
                RelayOut {
                    device: a,
                    name: "rly-5-9-bb".into(),
                    gen: 2,
                    gone: false
                },
            ]
        );
    }

    /// 待删记账跨崩溃：标成待删的事务提交之后，调用方没来得及回报就挂了，重开的会话照样列出来。
    #[test]
    fn pending_deletions_survive_a_restart() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-relay-gone");
        let path = dir.0.join("srs4.db");
        let col = {
            let conn = crate::store::gen4::schema::open(&path).unwrap();
            let t = Truth::new(&conn);
            let col = bound(&t);
            t.tx(|t| {
                t.relay_sent(col, LOC, &id(1), "rly-1-2-x", 1)?;
                t.relay_supersede(col, LOC, &id(1), 2)
            })
            .unwrap();
            // 下一笔写到一半没提交（回滚）：待删的行不受影响。
            let r: Result<(), String> = t.tx(|t| {
                t.relay_deleted(col, LOC, &id(1), "rly-1-2-x")?;
                Err("crash".to_owned())
            });
            assert!(r.is_err());
            col
        };
        let conn = crate::store::gen4::schema::open(&path).unwrap();
        let t = Truth::new(&conn);
        let gone: Vec<String> = t
            .relay_gone(col, LOC)
            .unwrap()
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(gone, vec!["rly-1-2-x"]);
    }

    #[test]
    fn the_old_root_fingerprint_is_a_function_of_the_listing() {
        let e = |p: &str, size: u64, m: Option<i64>| OldRootEntry {
            path: p.to_owned(),
            size,
            modified: m,
        };
        let base = vec![
            e("meta.json", 120, Some(5)),
            e("devices/a/head-1.json", 300, Some(7)),
            e("devices/a/seg-1-4-x.bin", 9000, None),
        ];
        let fp = oldroot_fingerprint(&base);
        let mut shuffled = base.clone();
        shuffled.reverse();
        assert_eq!(oldroot_fingerprint(&shuffled), fp);
        let mut variants = Vec::new();
        // 新文件、删掉一个、同名重写（大小 / 时刻）、同名文件出现两份（Google Drive）、围栏被删。
        let mut v = base.clone();
        v.push(e("devices/b/seg-1-1-y.bin", 10, None));
        variants.push(v);
        variants.push(base[1..].to_vec());
        let mut v = base.clone();
        v[2].size = 9001;
        variants.push(v);
        let mut v = base.clone();
        v[1].modified = Some(8);
        variants.push(v);
        let mut v = base.clone();
        v[1].modified = None;
        variants.push(v);
        let mut v = base.clone();
        v.push(base[0].clone());
        variants.push(v);
        variants.push(vec![]);
        for v in &variants {
            assert_ne!(oldroot_fingerprint(v), fp, "{v:?}");
        }
        // 路径拼接不会互相冒充（长度前缀）。
        assert_ne!(
            oldroot_fingerprint(&[e("ab", 1, None), e("c", 1, None)]),
            oldroot_fingerprint(&[e("a", 1, None), e("bc", 1, None)])
        );
    }

    #[test]
    fn the_old_root_check_and_forgetting_a_location() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        assert_eq!(t.oldroot_fp(col, LOC).unwrap(), None);
        assert_eq!(t.tx(|t| t.set_oldroot_fp(col, LOC, &[1; 32], 10)), Ok(true));
        assert_eq!(
            t.tx(|t| t.set_oldroot_fp(col, LOC, &[1; 32], 20)),
            Ok(false)
        );
        assert_eq!(
            t.oldroot_fp(col, LOC).unwrap(),
            Some(OldRootFp {
                fp: [1; 32],
                at: 20
            })
        );
        assert_eq!(t.tx(|t| t.set_oldroot_fp(col, LOC, &[2; 32], 30)), Ok(true));
        t.tx(|t| {
            t.put_loc_head(col, LOC, &head(1, 1, &[]))?;
            t.put_loc_head(col, "other", &head(1, 1, &[]))?;
            t.relay_sent(col, LOC, &id(1), "rly-1-1-z", 1)
        })
        .unwrap();
        assert_eq!(t.tx(|t| t.forget_location(col, LOC)), Ok(3));
        assert_eq!(t.loc_heads(col, LOC).unwrap(), vec![]);
        assert_eq!(t.relay_out(col, LOC).unwrap(), vec![]);
        assert_eq!(t.oldroot_fp(col, LOC).unwrap(), None);
        assert_eq!(t.loc_heads(col, "other").unwrap().len(), 1);
    }
}
