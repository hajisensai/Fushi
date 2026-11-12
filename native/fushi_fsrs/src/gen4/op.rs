//! 协议 4 的操作（设计 §3.1、§4.1）：信封 + 种类 + 操作体原字节。
//!
//! ```text
//! 信封      device[16] | seq uv | wall iv | logical uv | deps（版本向量）| kind uv | fmt uv
//! 独立编码  信封 | bytes(payload)
//! 链        blake3("fushi-srs-chain/4\n" || 前一环 || 信封 || blake3(payload))
//! ```
//!
//! 与协议 3（`crate::sync2::op`）的差别：
//!
//! - 没有 `purged` 位：协议 4 没有骨架，已清除的区间是空洞（segment.rs / heritage.rs）。
//! - 链带域前缀：协议 4 的信封与协议 3 的字节结构相同，前缀保证两代的链值永远不会相等。
//! - `fmt` 是操作体格式号，本版本写 [BODY_FMT] = 4（协议 3 的 `schema` 恒为 1）。
//! - Edit：键是紧凑形（name.rs）；旧戳是紧凑形（stamp.rs）且**只许出现在承袭日志**（[edit_has_stamp]，原生段拒绝）。
//! - Log：可选字段收进一个位图，等于默认值的不写；作者给的旧 HLC 拆成数字。
//! - 种类 12（协议 3 的 MediaAt）退役、永不复用；13 Dedup 只出现在承袭日志；新增 14 [Body4::Join]。
//!   副本记录与空洞不是种类，是日志里的槽（heritage.rs）。
//!
//! # 格式号与演进规则（冻结）
//!
//! - `fmt < 4`：不是协议 4 的操作体，[Body4::decode] 报错。
//! - `fmt == 4`：操作体必须**恰好**是本文件定义的字节——varint 取最短形、引用取规范形、没有不认识的标志位、没有尾字节。
//!   于是对已知种类 `encode(decode(字节)) == 字节`：一个值只有一种字节形（测试 `fmt_4_bodies_have_one_byte_form`）。
//! - `fmt > 4`：更新的版本写的。只读已知前缀，忽略不认识的标志位与尾部多出来的字节。**以后的版本只许在末尾追加字段并升 `fmt`**
//!   （Log 位图第 17 位起的字段一律排在现有字段之后；Edit 的新字段排在旧戳之后）；不兼容的布局变化只能用新的种类号。
//! - 载荷原字节永远原样保存、原样转发（[Op4::payload]），链与签名按原字节算；不认识的种类同样。
//!
//! 独立编码只给本机与测试用，自己不带魔数；跨代隔离靠段魔数与 head 的形状，用它的容器（导出包、待投递队列）要自带版本标记。

use std::sync::Arc;

use super::name::{read_edit_key, write_edit_key};
use super::stamp::{HeritageStamp, StampHlc};
use super::{bytes_min, iv_min, read_key, read_time, read_vv, str_min, u16_min, uv_min, write_key};
use crate::sync2::codec::{DResult, DecodeError, Reader, Writer};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{EntKind, Intent};
use crate::sync2::segment::Chain;
use crate::sync2::vv::{OpId, Vv};

pub const KIND_ENTITY: u16 = 1;
pub const KIND_EDIT: u16 = 2;
pub const KIND_LOG: u16 = 3;
pub const KIND_TAG_ADD: u16 = 4;
pub const KIND_TAG_REMOVE: u16 = 5;
pub const KIND_CHECKPOINT: u16 = 6;
pub const KIND_PURGE: u16 = 7;
pub const KIND_MEDIA: u16 = 8;
pub const KIND_DECK_ALIAS: u16 = 9;
pub const KIND_LEGACY_UNKNOWN: u16 = 10;
pub const KIND_TAG_ORDER: u16 = 11;
/// 协议 3 的 MediaAt。协议 4 里「某位置有没有某媒体」不再是操作（设计 §4.5）；这个号退役、永不复用。
pub const KIND_RETIRED_MEDIA_AT: u16 = 12;
/// 只出现在承袭日志（旧设备已经得出的去重结论）；新代不再产生。
pub const KIND_DEDUP: u16 = 13;
/// 另一个集合并入本集合（设计 §5.4）。
pub const KIND_JOIN: u16 = 14;

/// 本版本写出的操作体格式号。协议 3 的操作体是 1；4 之前的号永远不属于协议 4。
pub const BODY_FMT: u16 = 4;

/// 链的域前缀。
pub const CHAIN_DOMAIN: &[u8] = b"fushi-srs-chain/4\n";

/// 一条 Dedup 最多带多少对（与协议 3 相同）。
pub const DEDUP_MAX_PAIRS: usize = 20_000;

/// 一条协议 4 的操作。克隆是廉价的（载荷与上下文共享）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Op4 {
    pub id: OpId,
    pub hlc: Hlc,
    /// 作者已应用的**其它设备**的版本向量；作者自己的分量隐含为 `id.seq - 1`。
    pub deps: Arc<Vv>,
    pub kind: u16,
    /// 操作体格式号（[BODY_FMT]）。
    pub fmt: u16,
    /// 操作体原字节。
    pub payload: Arc<[u8]>,
}

impl Op4 {
    /// 信封（不含载荷）的规范编码。
    pub fn envelope(&self) -> Vec<u8> {
        let mut w = Writer::new();
        self.write_envelope(&mut w);
        w.into_vec()
    }

    fn write_envelope(&self, w: &mut Writer) {
        self.id.device.write(w);
        w.uv(self.id.seq);
        self.hlc.write_time(w);
        self.deps.write(w);
        w.uv(u64::from(self.kind));
        w.uv(u64::from(self.fmt));
    }

    pub fn write(&self, w: &mut Writer) {
        self.write_envelope(w);
        w.bytes(&self.payload);
    }

    pub fn read(r: &mut Reader<'_>) -> DResult<Op4> {
        let device = Id::read(r)?;
        let seq = uv_min(r)?;
        if seq == 0 {
            return Err(DecodeError("op seq 0"));
        }
        let hlc = read_time(r, device)?;
        let deps = read_deps(r, device)?;
        let (kind, fmt) = read_kind_fmt(r)?;
        Ok(Op4 {
            id: OpId { device, seq },
            hlc,
            deps: Arc::new(deps),
            kind,
            fmt,
            payload: bytes_min(r)?.into(),
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        self.write(&mut w);
        w.into_vec()
    }

    pub fn body(&self) -> DResult<Body4> {
        Body4::decode(self.kind, self.fmt, &self.payload)
    }

    /// 用本版本的格式号包一个操作体。
    pub fn of(id: OpId, hlc: Hlc, deps: Arc<Vv>, body: &Body4) -> Op4 {
        Op4 {
            id,
            hlc,
            deps,
            kind: body.kind(),
            fmt: BODY_FMT,
            payload: body.encode().into(),
        }
    }
}

/// 依赖向量：不许点名作者自己。
pub(crate) fn read_deps(r: &mut Reader<'_>, device: Id) -> DResult<Vv> {
    let deps = read_vv(r)?;
    if deps.get(&device) != 0 {
        return Err(DecodeError("op deps name its own device"));
    }
    Ok(deps)
}

pub(crate) fn read_kind_fmt(r: &mut Reader<'_>) -> DResult<(u16, u16)> {
    Ok((u16_min(r, "op kind")?, u16_min(r, "op fmt")?))
}

/// 链的下一环：`blake3(域前缀 || 前一环 || 信封 || 载荷哈希)`。
pub fn chain_next4(prev: &Chain, op: &Op4) -> Chain {
    let mut h = blake3::Hasher::new();
    h.update(CHAIN_DOMAIN);
    h.update(prev);
    h.update(&op.envelope());
    h.update(blake3::hash(&op.payload).as_bytes());
    *h.finalize().as_bytes()
}

/// 一次可编辑字段的写入。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit4 {
    pub kind: EntKind,
    pub entity: Key,
    pub key: String,
    /// 规范 JSON 文本。
    pub value: String,
    pub machine: bool,
    /// 时间来源是 anchored（否则 wall）。
    pub anchored: bool,
    /// 旧戳：只有承袭的修改有。
    pub stamp: Option<HeritageStamp>,
}

const EDIT_MACHINE: u8 = 1;
const EDIT_ANCHORED: u8 = 2;
const EDIT_STAMP: u8 = 4;
const EDIT_KNOWN: u8 = 7;

/// 复习日志。字段与协议 3 的 `LogBody` 一一对应；`hlc` / `server_time` 是它的 `legacy_hlc` / `legacy_server_time`
/// （作者给日志的旧 HLC、迁移进来的旧日志的 S(e)），只有承袭的日志有——原生日志的排序键就是操作自己的 HLC。
#[derive(Clone, Debug, PartialEq)]
pub struct Log4 {
    pub id: Key,
    pub card: Key,
    pub note: Option<Key>,
    pub kind: String,
    pub rating: Option<i64>,
    pub revokes: Option<Key>,
    pub at: i64,
    /// 时间来源码（1 = anchored，其余 = wall；协议 3 存整字节，原值保留）。
    pub ts: u8,
    pub origin: String,
    pub rtype: String,
    pub dur: i64,
    pub params: Option<String>,
    pub alg: Option<String>,
    pub utc_off: i64,
    pub rollover: i64,
    pub anki_id: Option<i64>,
    pub fv: i64,
    pub intent: Intent,
    /// [Intent::Absolute] 的结果 JSON 原文。
    pub res: Option<String>,
    /// 不认识的键（JSON 对象原文，`{}` = 没有）。
    pub extra: String,
    pub hlc: Option<StampHlc>,
    pub server_time: Option<i64>,
}

// Log 的位图。位号冻结；17 起留给以后追加的字段（排在现有字段之后）。
const L_NOTE: u64 = 1 << 0;
const L_RATING: u64 = 1 << 1;
const L_REVOKES: u64 = 1 << 2;
const L_PARAMS: u64 = 1 << 3;
const L_ALG: u64 = 1 << 4;
const L_ANKI_ID: u64 = 1 << 5;
const L_RES: u64 = 1 << 6;
const L_EXTRA: u64 = 1 << 7;
const L_HLC: u64 = 1 << 8;
const L_SERVER_TIME: u64 = 1 << 9;
const L_DUR: u64 = 1 << 10;
const L_UTC_OFF: u64 = 1 << 11;
const L_ROLLOVER: u64 = 1 << 12;
const L_FV: u64 = 1 << 13;
const L_TS: u64 = 1 << 14;
/// 旧 HLC 存原文（[StampHlc::Raw]）。
const L_HLC_RAW: u64 = 1 << 15;
/// 旧 HLC 的写入者 == `origin` 文本（导入的日志写入者就是 `anki`）。
const L_HLC_ORIGIN: u64 = 1 << 16;
const L_KNOWN: u64 = (1 << 17) - 1;

/// 省略时的默认值（与 store/sync2/mod.rs `log_body_of` 的默认相同）。
const DEFAULT_ROLLOVER: i64 = 4;
const DEFAULT_FV: i64 = 1;
const EMPTY_EXTRA: &str = "{}";

/// 另一个集合并入本集合。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Join4 {
    /// 被并入集合的集合标识。
    pub from: Id,
    /// 它的位置目录名（`fushi-srs/<它>/`）。
    pub dir: String,
    /// 它的盐集合（出现过的旧 profile uid；按字节严格升序、无重复）。
    pub salts: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Body4 {
    /// 身份记录：创建即不可变（`data` 是规范 JSON）。
    Entity {
        kind: EntKind,
        id: Key,
        data: String,
    },
    Edit(Edit4),
    Log(Log4),
    TagAdd {
        note: Key,
        tag: String,
    },
    TagRemove {
        note: Key,
        tag: String,
    },
    TagOrder {
        note: Key,
        tags: Vec<String>,
    },
    Checkpoint {
        name: String,
        reason: String,
    },
    Purge {
        kind: EntKind,
        entity: Key,
    },
    Media {
        name: String,
        sha256: [u8; 32],
        size: u64,
    },
    DeckAlias {
        from: Key,
        to: Key,
    },
    /// 协议 1 里不认识的事件，原样保存（JSON 原文）。
    LegacyUnknown {
        json: String,
    },
    /// 作者声明自己的这些旧操作（seq）各是另一条操作的副本。作者 seq 严格升序。
    Dedup {
        pairs: Vec<(u64, OpId)>,
    },
    Join(Join4),
    /// 本版本不认识的种类（含退役的 12）：原样保存、原样转发、不应用。
    Unknown,
}

fn ent_kind(code: u8) -> DResult<EntKind> {
    EntKind::ALL
        .get(code as usize)
        .copied()
        .ok_or(DecodeError("entity kind"))
}

impl Body4 {
    /// 种类号。[Body4::Unknown] 没有自己的号（原操作的 `kind` 才是），给 `u16::MAX`。
    pub fn kind(&self) -> u16 {
        match self {
            Body4::Entity { .. } => KIND_ENTITY,
            Body4::Edit(_) => KIND_EDIT,
            Body4::Log(_) => KIND_LOG,
            Body4::TagAdd { .. } => KIND_TAG_ADD,
            Body4::TagRemove { .. } => KIND_TAG_REMOVE,
            Body4::TagOrder { .. } => KIND_TAG_ORDER,
            Body4::Checkpoint { .. } => KIND_CHECKPOINT,
            Body4::Purge { .. } => KIND_PURGE,
            Body4::Media { .. } => KIND_MEDIA,
            Body4::DeckAlias { .. } => KIND_DECK_ALIAS,
            Body4::LegacyUnknown { .. } => KIND_LEGACY_UNKNOWN,
            Body4::Dedup { .. } => KIND_DEDUP,
            Body4::Join(_) => KIND_JOIN,
            Body4::Unknown => u16::MAX,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        match self {
            Body4::Entity { kind, id, data } => {
                w.u8(*kind as u8);
                write_key(&mut w, id);
                w.str(data);
            }
            Body4::Edit(e) => write_edit(&mut w, e),
            Body4::Log(l) => write_log(&mut w, l),
            Body4::TagAdd { note, tag } | Body4::TagRemove { note, tag } => {
                write_key(&mut w, note);
                w.str(tag);
            }
            Body4::TagOrder { note, tags } => {
                write_key(&mut w, note);
                w.uv(tags.len() as u64);
                for t in tags {
                    w.str(t);
                }
            }
            Body4::Checkpoint { name, reason } => {
                w.str(name);
                w.str(reason);
            }
            Body4::Purge { kind, entity } => {
                w.u8(*kind as u8);
                write_key(&mut w, entity);
            }
            Body4::Media { name, sha256, size } => {
                w.str(name);
                w.raw(sha256);
                w.uv(*size);
            }
            Body4::DeckAlias { from, to } => {
                write_key(&mut w, from);
                write_key(&mut w, to);
            }
            Body4::LegacyUnknown { json } => w.str(json),
            Body4::Dedup { pairs } => {
                // 原件设备表（升序、去重）+ (作者 seq 增量, 设备下标, 原件 seq)，按作者 seq 升序。
                let mut pairs = pairs.clone();
                pairs.sort_by_key(|(own, _)| *own);
                let mut devices: Vec<Id> = pairs.iter().map(|(_, o)| o.device).collect();
                devices.sort();
                devices.dedup();
                w.uv(devices.len() as u64);
                for d in &devices {
                    d.write(&mut w);
                }
                w.uv(pairs.len() as u64);
                let mut prev = 0u64;
                for (own, of) in &pairs {
                    w.uv(own - prev);
                    prev = *own;
                    w.uv(devices.binary_search(&of.device).unwrap_or(0) as u64);
                    w.uv(of.seq);
                }
            }
            Body4::Join(j) => {
                j.from.write(&mut w);
                w.str(&j.dir);
                w.uv(j.salts.len() as u64);
                for s in &j.salts {
                    w.str(s);
                }
            }
            Body4::Unknown => {}
        }
        w.into_vec()
    }

    /// 解操作体（规则见文件头「格式号与演进规则」）。不认识的种类给 [Body4::Unknown]。
    pub fn decode(kind: u16, fmt: u16, payload: &[u8]) -> DResult<Body4> {
        if fmt < BODY_FMT {
            return Err(DecodeError("not a protocol 4 op body"));
        }
        // 本版本的格式号：恰好是这些字节。更新的格式号：只读已知前缀。
        let exact = fmt == BODY_FMT;
        let mut r = Reader::new(payload);
        let r = &mut r;
        let body = match kind {
            KIND_ENTITY => Body4::Entity {
                kind: ent_kind(r.u8()?)?,
                id: read_key(r)?,
                data: str_min(r)?.to_owned(),
            },
            KIND_EDIT => Body4::Edit(read_edit(r, exact)?),
            KIND_LOG => Body4::Log(read_log(r, exact)?),
            KIND_TAG_ADD => Body4::TagAdd {
                note: read_key(r)?,
                tag: str_min(r)?.to_owned(),
            },
            KIND_TAG_REMOVE => Body4::TagRemove {
                note: read_key(r)?,
                tag: str_min(r)?.to_owned(),
            },
            KIND_TAG_ORDER => {
                let note = read_key(r)?;
                let n = uv_min(r)?;
                if n > 1 << 16 {
                    return Err(DecodeError("too many tags"));
                }
                let mut tags = Vec::with_capacity(n as usize);
                for _ in 0..n {
                    tags.push(str_min(r)?.to_owned());
                }
                Body4::TagOrder { note, tags }
            }
            KIND_CHECKPOINT => Body4::Checkpoint {
                name: str_min(r)?.to_owned(),
                reason: str_min(r)?.to_owned(),
            },
            KIND_PURGE => Body4::Purge {
                kind: ent_kind(r.u8()?)?,
                entity: read_key(r)?,
            },
            KIND_MEDIA => Body4::Media {
                name: str_min(r)?.to_owned(),
                sha256: r.raw(32)?.try_into().map_err(|_| DecodeError("sha256"))?,
                size: uv_min(r)?,
            },
            KIND_DECK_ALIAS => Body4::DeckAlias {
                from: read_key(r)?,
                to: read_key(r)?,
            },
            KIND_LEGACY_UNKNOWN => Body4::LegacyUnknown {
                json: str_min(r)?.to_owned(),
            },
            KIND_DEDUP => read_dedup(r)?,
            KIND_JOIN => {
                let from = Id::read(r)?;
                let dir = str_min(r)?.to_owned();
                let n = uv_min(r)?;
                if n > 1 << 16 {
                    return Err(DecodeError("too many salts"));
                }
                let mut salts: Vec<String> = Vec::with_capacity(n as usize);
                for _ in 0..n {
                    let s = str_min(r)?;
                    if salts.last().is_some_and(|p| p.as_bytes() >= s.as_bytes()) {
                        return Err(DecodeError("join salts not sorted"));
                    }
                    salts.push(s.to_owned());
                }
                Body4::Join(Join4 { from, dir, salts })
            }
            _ => return Ok(Body4::Unknown),
        };
        if exact && !r.is_empty() {
            return Err(DecodeError("trailing bytes in op body"));
        }
        Ok(body)
    }
}

/// Dedup：设备表严格升序、个个用到；作者 seq 严格升序（增量 >= 1）。
fn read_dedup(r: &mut Reader<'_>) -> DResult<Body4> {
    let nd = uv_min(r)?;
    if nd > 1 << 16 {
        return Err(DecodeError("too many dedup devices"));
    }
    let mut devices: Vec<Id> = Vec::with_capacity(nd as usize);
    for _ in 0..nd {
        let d = Id::read(r)?;
        if devices.last().is_some_and(|p| *p >= d) {
            return Err(DecodeError("dedup devices not sorted"));
        }
        devices.push(d);
    }
    let n = uv_min(r)?;
    if n > DEDUP_MAX_PAIRS as u64 {
        return Err(DecodeError("too many dedup pairs"));
    }
    let mut used = vec![false; devices.len()];
    let mut pairs = Vec::with_capacity(n as usize);
    let mut own = 0u64;
    for _ in 0..n {
        let delta = uv_min(r)?;
        if delta == 0 {
            return Err(DecodeError("dedup seqs not ascending"));
        }
        own = own.checked_add(delta).ok_or(DecodeError("dedup seq"))?;
        let i = usize::try_from(uv_min(r)?).map_err(|_| DecodeError("dedup device"))?;
        let device = *devices.get(i).ok_or(DecodeError("dedup device"))?;
        used[i] = true;
        pairs.push((
            own,
            OpId {
                device,
                seq: uv_min(r)?,
            },
        ));
    }
    if used.contains(&false) {
        return Err(DecodeError("dedup device unused"));
    }
    Ok(Body4::Dedup { pairs })
}

fn write_edit(w: &mut Writer, e: &Edit4) {
    w.u8(e.kind as u8);
    write_key(w, &e.entity);
    write_edit_key(w, &e.key);
    let mut flags = 0;
    if e.machine {
        flags |= EDIT_MACHINE;
    }
    if e.anchored {
        flags |= EDIT_ANCHORED;
    }
    if e.stamp.is_some() {
        flags |= EDIT_STAMP;
    }
    w.u8(flags);
    w.str(&e.value);
    if let Some(s) = &e.stamp {
        s.write(w);
    }
}

fn read_edit(r: &mut Reader<'_>, exact: bool) -> DResult<Edit4> {
    let kind = ent_kind(r.u8()?)?;
    let entity = read_key(r)?;
    let key = read_edit_key(r)?;
    let flags = r.u8()?;
    if exact && flags & !EDIT_KNOWN != 0 {
        return Err(DecodeError("edit flags"));
    }
    let value = str_min(r)?.to_owned();
    let stamp = if flags & EDIT_STAMP != 0 {
        Some(HeritageStamp::read(r)?)
    } else {
        None
    };
    Ok(Edit4 {
        kind,
        entity,
        key,
        value,
        machine: flags & EDIT_MACHINE != 0,
        anchored: flags & EDIT_ANCHORED != 0,
        stamp,
    })
}

/// 一个 Edit 操作体带不带旧戳（只读到标志位）。原生段据此拒收带旧戳的修改：协议 1 的因果数据只存在于承袭日志。
pub fn edit_has_stamp(payload: &[u8]) -> DResult<bool> {
    let mut r = Reader::new(payload);
    ent_kind(r.u8()?)?;
    read_key(&mut r)?;
    read_edit_key(&mut r)?;
    Ok(r.u8()? & EDIT_STAMP != 0)
}

/// 日志种类 / 复习类型 / 来源的紧凑码（持久化名冻结，与协议 3 `crate::sync2::op` 的三张表逐项相同）；表外的写 255 + 文本。
const LOG_KINDS: [&str; 6] = [
    "review",
    "manual",
    "reschedule",
    "importAnchor",
    "handOff",
    "undo",
];
const RTYPES: [&str; 6] = [
    "learn",
    "review",
    "relearn",
    "filtered",
    "manual",
    "rescheduled",
];
const ORIGINS: [&str; 2] = ["fushi", "anki"];

fn write_code(w: &mut Writer, table: &[&str], s: &str) {
    match table.iter().position(|x| *x == s) {
        Some(i) => w.u8(i as u8),
        None => {
            w.u8(255);
            w.str(s);
        }
    }
}

/// 表内的文本只许用码（写成 255 + 文本的拒绝）。
fn read_code(r: &mut Reader<'_>, table: &[&str]) -> DResult<String> {
    let c = r.u8()?;
    if c == 255 {
        let s = str_min(r)?;
        if table.contains(&s) {
            return Err(DecodeError("log code spelled out"));
        }
        return Ok(s.to_owned());
    }
    table
        .get(c as usize)
        .map(|s| (*s).to_owned())
        .ok_or(DecodeError("log code"))
}

fn write_log(w: &mut Writer, l: &Log4) {
    write_key(w, &l.id);
    write_key(w, &l.card);
    let hlc_origin = l.hlc.as_ref().is_some_and(|h| h.same_writer(&l.origin));
    let bits = [
        (l.note.is_some(), L_NOTE),
        (l.rating.is_some(), L_RATING),
        (l.revokes.is_some(), L_REVOKES),
        (l.params.is_some(), L_PARAMS),
        (l.alg.is_some(), L_ALG),
        (l.anki_id.is_some(), L_ANKI_ID),
        (l.res.is_some(), L_RES),
        (l.extra != EMPTY_EXTRA, L_EXTRA),
        (l.hlc.is_some(), L_HLC),
        (l.server_time.is_some(), L_SERVER_TIME),
        (l.dur != 0, L_DUR),
        (l.utc_off != 0, L_UTC_OFF),
        (l.rollover != DEFAULT_ROLLOVER, L_ROLLOVER),
        (l.fv != DEFAULT_FV, L_FV),
        (l.ts != 0, L_TS),
        (l.hlc.as_ref().is_some_and(StampHlc::is_raw), L_HLC_RAW),
        (hlc_origin, L_HLC_ORIGIN),
    ];
    let mask = bits
        .iter()
        .fold(0u64, |m, (on, bit)| if *on { m | bit } else { m });
    w.uv(mask);
    if let Some(k) = &l.note {
        write_key(w, k);
    }
    write_code(w, &LOG_KINDS, &l.kind);
    if let Some(x) = l.rating {
        w.iv(x);
    }
    if let Some(k) = &l.revokes {
        write_key(w, k);
    }
    w.iv(l.at);
    if l.ts != 0 {
        w.u8(l.ts);
    }
    write_code(w, &ORIGINS, &l.origin);
    write_code(w, &RTYPES, &l.rtype);
    if l.dur != 0 {
        w.iv(l.dur);
    }
    if let Some(s) = &l.params {
        w.str(s);
    }
    if let Some(s) = &l.alg {
        w.str(s);
    }
    if l.utc_off != 0 {
        w.iv(l.utc_off);
    }
    if l.rollover != DEFAULT_ROLLOVER {
        w.iv(l.rollover);
    }
    if let Some(x) = l.anki_id {
        w.iv(x);
    }
    if l.fv != DEFAULT_FV {
        w.iv(l.fv);
    }
    match l.intent {
        Intent::Absolute => w.u8(0),
        Intent::Answer => w.u8(1),
        Intent::SetDue { due_day } => {
            w.u8(2);
            w.iv(due_day);
        }
        Intent::Reset => w.u8(3),
        Intent::Reschedule => w.u8(4),
        Intent::HandOff { to_anki } => {
            w.u8(5);
            w.bool(to_anki);
        }
    }
    if let Some(s) = &l.res {
        w.str(s);
    }
    if l.extra != EMPTY_EXTRA {
        w.str(&l.extra);
    }
    if let Some(h) = &l.hlc {
        h.write_body(w, hlc_origin);
    }
    if let Some(s) = l.server_time {
        w.iv(s.wrapping_sub(log_time_base(l.hlc.as_ref())));
    }
}

/// 日志 `server_time` 增量编码的基准：旧 HLC 拆得开时是它的物理时间，否则 0。
fn log_time_base(hlc: Option<&StampHlc>) -> i64 {
    match hlc {
        Some(StampHlc::Parsed { physical, .. }) => *physical,
        _ => 0,
    }
}

/// 置了位的字段不许等于默认值（等于默认 ⇔ 不置位）。
fn non_default<T: PartialEq>(v: T, default: T) -> DResult<T> {
    if v == default {
        return Err(DecodeError("log field spelled out at its default"));
    }
    Ok(v)
}

fn read_log(r: &mut Reader<'_>, exact: bool) -> DResult<Log4> {
    let id = read_key(r)?;
    let card = read_key(r)?;
    let mask = uv_min(r)?;
    if exact && mask & !L_KNOWN != 0 {
        return Err(DecodeError("log mask"));
    }
    let on = |bit: u64| mask & bit != 0;
    let note = if on(L_NOTE) { Some(read_key(r)?) } else { None };
    let kind = read_code(r, &LOG_KINDS)?;
    let rating = if on(L_RATING) { Some(iv_min(r)?) } else { None };
    let revokes = if on(L_REVOKES) {
        Some(read_key(r)?)
    } else {
        None
    };
    let at = iv_min(r)?;
    let ts = if on(L_TS) {
        non_default(r.u8()?, 0)?
    } else {
        0
    };
    let origin = read_code(r, &ORIGINS)?;
    let rtype = read_code(r, &RTYPES)?;
    let dur = if on(L_DUR) {
        non_default(iv_min(r)?, 0)?
    } else {
        0
    };
    let params = if on(L_PARAMS) {
        Some(str_min(r)?.to_owned())
    } else {
        None
    };
    let alg = if on(L_ALG) {
        Some(str_min(r)?.to_owned())
    } else {
        None
    };
    let utc_off = if on(L_UTC_OFF) {
        non_default(iv_min(r)?, 0)?
    } else {
        0
    };
    let rollover = if on(L_ROLLOVER) {
        non_default(iv_min(r)?, DEFAULT_ROLLOVER)?
    } else {
        DEFAULT_ROLLOVER
    };
    let anki_id = if on(L_ANKI_ID) {
        Some(iv_min(r)?)
    } else {
        None
    };
    let fv = if on(L_FV) {
        non_default(iv_min(r)?, DEFAULT_FV)?
    } else {
        DEFAULT_FV
    };
    let intent = match r.u8()? {
        0 => Intent::Absolute,
        1 => Intent::Answer,
        2 => Intent::SetDue {
            due_day: iv_min(r)?,
        },
        3 => Intent::Reset,
        4 => Intent::Reschedule,
        5 => Intent::HandOff { to_anki: r.bool()? },
        _ => return Err(DecodeError("log intent")),
    };
    let res = if on(L_RES) {
        Some(str_min(r)?.to_owned())
    } else {
        None
    };
    let extra = if on(L_EXTRA) {
        non_default(str_min(r)?, EMPTY_EXTRA)?.to_owned()
    } else {
        EMPTY_EXTRA.to_owned()
    };
    let hlc = if on(L_HLC) {
        Some(StampHlc::read_body(
            r,
            on(L_HLC_RAW),
            on(L_HLC_ORIGIN),
            &origin,
        )?)
    } else {
        if on(L_HLC_RAW) || on(L_HLC_ORIGIN) {
            return Err(DecodeError("log hlc flags without an hlc"));
        }
        None
    };
    let server_time = if on(L_SERVER_TIME) {
        Some(iv_min(r)?.wrapping_add(log_time_base(hlc.as_ref())))
    } else {
        None
    };
    Ok(Log4 {
        id,
        card,
        note,
        kind,
        rating,
        revokes,
        at,
        ts,
        origin,
        rtype,
        dur,
        params,
        alg,
        utc_off,
        rollover,
        anki_id,
        fv,
        intent,
        res,
        extra,
        hlc,
        server_time,
    })
}

/// 能不能出现在原生日志里（[super::segment::pack_native] 的写侧检查，读侧同样用它）：
/// 协议 3 的操作体、退役的 12、只属于承袭日志的 13 与带旧戳的修改不能。
pub fn native_allowed(op: &Op4) -> Result<(), &'static str> {
    if op.fmt < BODY_FMT {
        return Err("native op body is not protocol 4");
    }
    match op.kind {
        KIND_RETIRED_MEDIA_AT => Err("kind 12 is retired"),
        KIND_DEDUP => Err("dedup belongs to heritage logs only"),
        KIND_EDIT => match edit_has_stamp(&op.payload) {
            Ok(false) => Ok(()),
            Ok(true) => Err("native edit carries a heritage stamp"),
            Err(_) => Err("native edit does not decode"),
        },
        _ => Ok(()),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::gen4::stamp::tests::{arb_hlc, arb_stamp, typical};
    use crate::gen4::{golden, hex, unhex};
    use crate::sync2::op as v3;
    use proptest::prelude::*;

    pub fn id(b: u8) -> Id {
        Id([b; 16])
    }

    pub fn sample_log() -> Log4 {
        Log4 {
            id: Key::Uuid(id(7)),
            card: Key::Uuid(id(8)),
            note: Some(Key::Uuid(id(9))),
            kind: "review".into(),
            rating: Some(3),
            revokes: None,
            at: 1_700_000_000_000,
            ts: 1,
            origin: "fushi".into(),
            rtype: "review".into(),
            dur: 4200,
            params: Some("fsrs7:abc".into()),
            alg: Some("fsrs7".into()),
            utc_off: 480,
            rollover: 4,
            anki_id: None,
            fv: 1,
            intent: Intent::Answer,
            res: None,
            extra: "{}".into(),
            hlc: None,
            server_time: None,
        }
    }

    /// 样本库里占 94% 的形状：导入的 Anki 复习，旧 HLC 的写入者是 `anki`，带服务器时刻与绝对结果。
    pub fn imported_log() -> Log4 {
        Log4 {
            id: Key::Uuid(id(0x21)),
            card: Key::Uuid(id(0x22)),
            note: None,
            kind: "review".into(),
            rating: Some(3),
            revokes: None,
            at: 1_741_061_848_001,
            ts: 0,
            origin: "anki".into(),
            rtype: "review".into(),
            dur: 6021,
            params: None,
            alg: Some("anki".into()),
            utc_off: 0,
            rollover: 4,
            anki_id: Some(1_741_061_848_001),
            fv: 1,
            intent: Intent::Absolute,
            res: Some(r#"{"dueDay":20155,"ease":2500,"ivl":4,"lapses":0,"lastReviewedAt":1741061849001,"queue":"review","reps":1,"scheduler":"fushi","step":0}"#.into()),
            extra: "{}".into(),
            hlc: Some(StampHlc::of("1741061848001:0:anki")),
            server_time: Some(1_741_061_900_000),
        }
    }

    pub fn native_edit() -> Edit4 {
        Edit4 {
            kind: EntKind::Note,
            entity: Key::Uuid(id(3)),
            key: format!("f/{}", id(4).text()),
            value: r#""単語""#.into(),
            machine: false,
            anchored: true,
            stamp: None,
        }
    }

    pub fn op_of(device: Id, seq: u64, body: &Body4) -> Op4 {
        let mut deps = Vv::new();
        deps.set(id(0xd2), 5);
        Op4::of(
            OpId { device, seq },
            Hlc {
                wall: 1_800_000_000_000 + seq as i64,
                logical: 0,
                device,
            },
            Arc::new(deps),
            body,
        )
    }

    fn all_bodies() -> Vec<Body4> {
        vec![
            Body4::Entity {
                kind: EntKind::Note,
                id: Key::Uuid(id(1)),
                data: r#"{"createdAt":1,"guid":"g","noteTypeId":"t"}"#.into(),
            },
            Body4::Edit(native_edit()),
            Body4::Edit(Edit4 {
                key: "deleted".into(),
                value: "null".into(),
                machine: true,
                anchored: false,
                stamp: Some(typical()),
                ..native_edit()
            }),
            Body4::Log(sample_log()),
            Body4::Log(imported_log()),
            Body4::Log(Log4 {
                kind: "weird".into(),
                rtype: "odd".into(),
                origin: "x".into(),
                intent: Intent::SetDue { due_day: -3 },
                rating: Some(-7),
                rollover: 0,
                fv: 2,
                ts: 9,
                extra: r#"{"memAlg":"fsrs6"}"#.into(),
                hlc: Some(StampHlc::of("+1:0:x")),
                server_time: Some(-1),
                ..sample_log()
            }),
            Body4::TagAdd {
                note: Key::of("n"),
                tag: "t".into(),
            },
            Body4::TagRemove {
                note: Key::of("n"),
                tag: "t".into(),
            },
            Body4::TagOrder {
                note: Key::of("n"),
                tags: vec!["b".into(), "a".into()],
            },
            Body4::Checkpoint {
                name: "a".into(),
                reason: "import".into(),
            },
            Body4::Purge {
                kind: EntKind::Note,
                entity: Key::of("n"),
            },
            Body4::Media {
                name: "a.mp3".into(),
                sha256: [9; 32],
                size: 77,
            },
            Body4::DeckAlias {
                from: Key::of("b"),
                to: Key::of("a"),
            },
            Body4::LegacyUnknown { json: "{}".into() },
            Body4::Dedup {
                pairs: vec![
                    (
                        3,
                        OpId {
                            device: id(5),
                            seq: 9,
                        },
                    ),
                    (
                        4,
                        OpId {
                            device: id(2),
                            seq: 1,
                        },
                    ),
                ],
            },
            Body4::Join(Join4 {
                from: id(0xb0),
                dir: "0192f0aa-0000-7000-8000-00000000000b".into(),
                salts: vec!["a".into(), "b".into()],
            }),
        ]
    }

    #[test]
    fn bodies_round_trip() {
        for b in all_bodies() {
            let bytes = b.encode();
            assert_eq!(Body4::decode(b.kind(), BODY_FMT, &bytes).unwrap(), b);
        }
        assert_eq!(
            Body4::decode(999, BODY_FMT, b"anything").unwrap(),
            Body4::Unknown
        );
        assert_eq!(
            Body4::decode(KIND_RETIRED_MEDIA_AT, BODY_FMT, b"anything").unwrap(),
            Body4::Unknown
        );
    }

    /// 协议 3 的操作体格式号（1）不属于协议 4：拒绝，而不是按新布局硬解。
    #[test]
    fn a_protocol_3_body_format_is_rejected() {
        let bytes = Body4::TagAdd {
            note: Key::of("n"),
            tag: "t".into(),
        }
        .encode();
        for fmt in 0..BODY_FMT {
            assert!(Body4::decode(KIND_TAG_ADD, fmt, &bytes).is_err());
        }
        assert!(Body4::decode(KIND_TAG_ADD, BODY_FMT + 1, &bytes).is_ok());
    }

    /// 未知字段保留原字节：更新版本在末尾追加的字段，本版本读已知前缀，原字节（转发 / 链 / 签名用的）不动。
    #[test]
    fn trailing_fields_from_a_newer_format_are_ignored_and_kept() {
        for b in all_bodies() {
            let known = b.encode();
            let mut bytes = known.clone();
            bytes.extend_from_slice(&[0xde, 0xad, 0xbe, 0xef]);
            assert_eq!(Body4::decode(b.kind(), BODY_FMT + 1, &bytes).unwrap(), b);
            // 本版本的格式号下同样的字节不合法：恰好是定义的字节，不多不少。
            assert!(Body4::decode(b.kind(), BODY_FMT, &bytes).is_err());
            let op = Op4 {
                payload: bytes.clone().into(),
                fmt: BODY_FMT + 1,
                ..op_of(id(1), 1, &b)
            };
            let back = Op4::read(&mut Reader::new(&op.encode())).unwrap();
            assert_eq!(&back.payload[..], &bytes[..]);
            assert_eq!(back.body().unwrap(), b);
        }
        // 不认识的种类同样原样带着。
        let op = Op4 {
            kind: 4242,
            payload: vec![1, 2, 3].into(),
            ..op_of(id(1), 1, &Body4::Unknown)
        };
        let back = Op4::read(&mut Reader::new(&op.encode())).unwrap();
        assert_eq!(back, op);
        assert_eq!(back.body().unwrap(), Body4::Unknown);
    }

    /// 没改布局的种类与协议 3 逐字节相同（转译时载荷原样带过去的依据）。
    #[test]
    fn unchanged_kinds_share_the_protocol_3_layout() {
        let pairs: Vec<(Body4, v3::Body)> = vec![
            (
                Body4::Entity {
                    kind: EntKind::Deck,
                    id: Key::Uuid(id(1)),
                    data: r#"{"createdAt":5}"#.into(),
                },
                v3::Body::Entity {
                    kind: EntKind::Deck,
                    id: Key::Uuid(id(1)),
                    data: r#"{"createdAt":5}"#.into(),
                },
            ),
            (
                Body4::TagAdd {
                    note: Key::Uuid(id(2)),
                    tag: "t".into(),
                },
                v3::Body::TagAdd {
                    note: Key::Uuid(id(2)),
                    tag: "t".into(),
                },
            ),
            (
                Body4::TagRemove {
                    note: Key::Uuid(id(2)),
                    tag: "t".into(),
                },
                v3::Body::TagRemove {
                    note: Key::Uuid(id(2)),
                    tag: "t".into(),
                },
            ),
            (
                Body4::TagOrder {
                    note: Key::Uuid(id(2)),
                    tags: vec!["b".into(), "a".into()],
                },
                v3::Body::TagOrder {
                    note: Key::Uuid(id(2)),
                    tags: vec!["b".into(), "a".into()],
                },
            ),
            (
                Body4::Checkpoint {
                    name: "n".into(),
                    reason: "r".into(),
                },
                v3::Body::Checkpoint {
                    name: "n".into(),
                    reason: "r".into(),
                },
            ),
            (
                Body4::Purge {
                    kind: EntKind::Card,
                    entity: Key::of("x"),
                },
                v3::Body::Purge {
                    kind: EntKind::Card,
                    entity: Key::of("x"),
                },
            ),
            (
                Body4::Media {
                    name: "a.mp3".into(),
                    sha256: [9; 32],
                    size: 77,
                },
                v3::Body::Media {
                    name: "a.mp3".into(),
                    sha256: [9; 32],
                    size: 77,
                },
            ),
            (
                Body4::DeckAlias {
                    from: Key::of("b"),
                    to: Key::of("a"),
                },
                v3::Body::DeckAlias {
                    from: Key::of("b"),
                    to: Key::of("a"),
                },
            ),
            (
                Body4::LegacyUnknown { json: "{}".into() },
                v3::Body::LegacyUnknown { json: "{}".into() },
            ),
            (
                Body4::Dedup {
                    pairs: vec![
                        (
                            3,
                            OpId {
                                device: id(5),
                                seq: 9,
                            },
                        ),
                        (
                            40,
                            OpId {
                                device: id(2),
                                seq: 1,
                            },
                        ),
                    ],
                },
                v3::Body::Dedup {
                    pairs: vec![
                        (
                            3,
                            OpId {
                                device: id(5),
                                seq: 9,
                            },
                        ),
                        (
                            40,
                            OpId {
                                device: id(2),
                                seq: 1,
                            },
                        ),
                    ],
                },
            ),
        ];
        for (b4, b3) in pairs {
            assert_eq!(b4.kind(), b3.kind());
            assert_eq!(b4.encode(), b3.encode());
            assert_eq!(
                Body4::decode(b3.kind(), BODY_FMT, &b3.encode()).unwrap(),
                b4
            );
        }
    }

    /// 日志的三张码表与协议 3 逐项相同（协议 3 的表是私有的：拿它编码出来的字节对）。
    #[test]
    fn log_code_tables_match_protocol_3() {
        let v3_log = |kind: &str, origin: &str, rtype: &str| v3::LogBody {
            id: Key::of("i"),
            card: Key::of("c"),
            note: None,
            kind: kind.into(),
            rating: None,
            revokes: None,
            at: 0,
            ts: 0,
            origin: origin.into(),
            rtype: rtype.into(),
            dur: 0,
            params: None,
            alg: None,
            utc_off: 0,
            rollover: 4,
            anki_id: None,
            fv: 1,
            intent: Intent::Absolute,
            res: None,
            extra: "{}".into(),
            legacy_hlc: None,
            legacy_server_time: None,
        };
        // 协议 3 的布局：id(1+1+1) card(1+1+1) note(1) kind(1) rating(1) revokes(1) at(1) ts(1) origin(1) rtype(1)。
        for (i, k) in LOG_KINDS.iter().enumerate() {
            let b = v3::Body::Log(v3_log(k, "fushi", "learn")).encode();
            assert_eq!(b[7], i as u8, "{k}");
        }
        for (i, o) in ORIGINS.iter().enumerate() {
            let b = v3::Body::Log(v3_log("review", o, "learn")).encode();
            assert_eq!(b[12], i as u8, "{o}");
        }
        for (i, t) in RTYPES.iter().enumerate() {
            let b = v3::Body::Log(v3_log("review", "fushi", t)).encode();
            assert_eq!(b[13], i as u8, "{t}");
        }
        let b = v3::Body::Log(v3_log("nope", "fushi", "learn")).encode();
        assert_eq!(b[7], 255);
    }

    /// 同一个值的另一种写法一律拒绝（本版本格式号）。
    #[test]
    fn non_canonical_spellings_are_rejected() {
        let dec = |kind: u16, bytes: &[u8]| Body4::decode(kind, BODY_FMT, bytes);
        // 引用：UUID 文本形。
        let mut w = Writer::new();
        Key::Text(id(1).text()).write(&mut w);
        w.str("t");
        let loose = w.into_vec();
        assert!(v3::Body::decode(v3::KIND_TAG_ADD, &loose).is_ok());
        assert!(dec(KIND_TAG_ADD, &loose).is_err());
        // 手工构造的文本形引用，编码时归回 16 字节形。
        let b = Body4::TagAdd {
            note: Key::Text(id(1).text()),
            tag: "t".into(),
        };
        assert_eq!(
            dec(KIND_TAG_ADD, &b.encode()).unwrap(),
            Body4::TagAdd {
                note: Key::Uuid(id(1)),
                tag: "t".into()
            }
        );
        // 字符串长度写成非最短的 varint。
        let mut w = Writer::new();
        w.raw(&[0x81, 0x00]);
        w.raw(b"a");
        w.str("r");
        assert!(dec(KIND_CHECKPOINT, &w.into_vec()).is_err());
        // Edit：不认识的标志位。
        let mut bytes = Body4::Edit(native_edit()).encode();
        let at = bytes.len() - r#""単語""#.len() - 2;
        assert_eq!(bytes[at], EDIT_ANCHORED);
        bytes[at] |= 0x40;
        assert!(dec(KIND_EDIT, &bytes).is_err());
        assert_eq!(
            Body4::decode(KIND_EDIT, BODY_FMT + 1, &bytes).unwrap(),
            Body4::Edit(native_edit())
        );
        // Log：置了位却写默认值；不认识的位；表内的码写成文本。
        let base = Log4 {
            note: None,
            rating: None,
            params: None,
            alg: None,
            dur: 0,
            utc_off: 0,
            ts: 0,
            ..sample_log()
        };
        let good = Body4::Log(base.clone()).encode();
        // id(17) card(17) mask(1) kind(1) at(..)。
        assert_eq!(good[34], 0);
        for (bit, spelled) in [(L_DUR, 0i64), (L_UTC_OFF, 0), (L_ROLLOVER, 4), (L_FV, 1)] {
            let mut w = Writer::new();
            write_key(&mut w, &base.id);
            write_key(&mut w, &base.card);
            w.uv(bit);
            w.u8(0);
            w.iv(base.at);
            w.u8(0);
            w.u8(1);
            w.iv(spelled);
            w.u8(1);
            assert_eq!(
                dec(KIND_LOG, &w.into_vec()).unwrap_err(),
                DecodeError("log field spelled out at its default")
            );
        }
        let mut unknown_bit = good.clone();
        unknown_bit.splice(34..35, [0x80, 0x80, 0x08]);
        assert_eq!(
            dec(KIND_LOG, &unknown_bit).unwrap_err(),
            DecodeError("log mask")
        );
        assert_eq!(
            Body4::decode(KIND_LOG, BODY_FMT + 1, &unknown_bit).unwrap(),
            Body4::Log(base.clone())
        );
        let mut spelled = good.clone();
        spelled.splice(35..36, [255u8, 6, b'r', b'e', b'v', b'i', b'e', b'w']);
        assert_eq!(
            dec(KIND_LOG, &spelled).unwrap_err(),
            DecodeError("log code spelled out")
        );
        // Dedup：设备表乱序 / 有没用到的设备 / 作者 seq 不升序。
        let dedup = |devices: &[Id], pairs: &[(u64, u64, u64)]| {
            let mut w = Writer::new();
            w.uv(devices.len() as u64);
            for d in devices {
                d.write(&mut w);
            }
            w.uv(pairs.len() as u64);
            for (delta, i, seq) in pairs {
                w.uv(*delta);
                w.uv(*i);
                w.uv(*seq);
            }
            w.into_vec()
        };
        assert!(dec(KIND_DEDUP, &dedup(&[id(2), id(5)], &[(3, 1, 9), (1, 0, 1)])).is_ok());
        assert!(dec(KIND_DEDUP, &dedup(&[id(5), id(2)], &[(3, 0, 9), (1, 1, 1)])).is_err());
        assert!(dec(KIND_DEDUP, &dedup(&[id(2), id(5)], &[(3, 1, 9)])).is_err());
        assert!(dec(KIND_DEDUP, &dedup(&[id(2)], &[(3, 0, 9), (0, 0, 1)])).is_err());
        // 编码时不按作者 seq 排的输入会被排好。
        let unsorted = Body4::Dedup {
            pairs: vec![
                (
                    9,
                    OpId {
                        device: id(2),
                        seq: 1,
                    },
                ),
                (
                    3,
                    OpId {
                        device: id(5),
                        seq: 7,
                    },
                ),
            ],
        };
        let Body4::Dedup { pairs } = dec(KIND_DEDUP, &unsorted.encode()).unwrap() else {
            panic!("dedup");
        };
        assert_eq!(pairs.iter().map(|p| p.0).collect::<Vec<_>>(), vec![3, 9]);
    }

    #[test]
    fn logs_are_smaller_than_in_protocol_3() {
        let v3_log = |l: &Log4| v3::LogBody {
            id: l.id.clone(),
            card: l.card.clone(),
            note: l.note.clone(),
            kind: l.kind.clone(),
            rating: l.rating,
            revokes: l.revokes.clone(),
            at: l.at,
            ts: l.ts,
            origin: l.origin.clone(),
            rtype: l.rtype.clone(),
            dur: l.dur,
            params: l.params.clone(),
            alg: l.alg.clone(),
            utc_off: l.utc_off,
            rollover: l.rollover,
            anki_id: l.anki_id,
            fv: l.fv,
            intent: l.intent.clone(),
            res: l.res.clone(),
            extra: l.extra.clone(),
            legacy_hlc: l.hlc.as_ref().map(StampHlc::text),
            legacy_server_time: l.server_time,
        };
        // 位图省掉「没有」的标记字节与等于默认值的字段；旧 HLC 文本拆成数字。
        for (l, at_least) in [(sample_log(), 8), (imported_log(), 15)] {
            let new = Body4::Log(l.clone()).encode().len();
            let old = v3::Body::Log(v3_log(&l)).encode().len();
            assert!(new + at_least <= old, "{new} vs {old}");
        }
    }

    #[test]
    fn op_round_trip_and_chain() {
        let op = op_of(id(1), 3, &Body4::Edit(native_edit()));
        let bytes = op.encode();
        assert_eq!(Op4::read(&mut Reader::new(&bytes)).unwrap(), op);
        assert_eq!(&bytes[..op.envelope().len()], &op.envelope()[..]);
        let c1 = chain_next4(&[0; 32], &op);
        // 链只看信封与载荷哈希：换载荷、换 seq 都变。
        let other = Op4 {
            payload: vec![1].into(),
            ..op.clone()
        };
        assert_ne!(chain_next4(&[0; 32], &other), c1);
        let mut e = Vec::new();
        e.extend_from_slice(b"fushi-srs-chain/4\n");
        e.extend_from_slice(&[0; 32]);
        e.extend_from_slice(&op.envelope());
        e.extend_from_slice(blake3::hash(&op.payload).as_bytes());
        assert_eq!(*blake3::hash(&e).as_bytes(), c1);
        // 自己点名自己的依赖、seq 0：拒绝。
        let mut deps = Vv::new();
        deps.set(id(1), 2);
        let bad = Op4 {
            deps: Arc::new(deps),
            ..op.clone()
        };
        assert!(Op4::read(&mut Reader::new(&bad.encode())).is_err());
        let mut zero = op.clone();
        zero.id.seq = 0;
        assert!(Op4::read(&mut Reader::new(&zero.encode())).is_err());
    }

    #[test]
    fn native_logs_refuse_heritage_only_content() {
        assert!(native_allowed(&op_of(id(1), 1, &Body4::Edit(native_edit()))).is_ok());
        assert!(native_allowed(&op_of(id(1), 1, &Body4::Log(sample_log()))).is_ok());
        let stamped = Body4::Edit(Edit4 {
            stamp: Some(typical()),
            ..native_edit()
        });
        assert!(edit_has_stamp(&stamped.encode()).unwrap());
        assert!(!edit_has_stamp(&Body4::Edit(native_edit()).encode()).unwrap());
        assert!(native_allowed(&op_of(id(1), 1, &stamped)).is_err());
        assert!(native_allowed(&op_of(id(1), 1, &Body4::Dedup { pairs: vec![] })).is_err());
        let retired = Op4 {
            kind: KIND_RETIRED_MEDIA_AT,
            ..op_of(id(1), 1, &Body4::Unknown)
        };
        assert!(native_allowed(&retired).is_err());
        let old_fmt = Op4 {
            fmt: 1,
            ..op_of(id(1), 1, &Body4::Log(sample_log()))
        };
        assert!(native_allowed(&old_fmt).is_err());
    }

    /// 黄金向量：每种操作体的字节冻结。改了这里任何一行 = 改了线格式。
    #[test]
    fn golden_bodies() {
        let bodies = all_bodies();
        assert_eq!(bodies.len(), GOLDEN_BODIES.len());
        for (i, b) in bodies.iter().enumerate() {
            println!("GOLDEN body_{i} ({}, \"{}\"),", b.kind(), hex(&b.encode()));
        }
        for (b, (kind, want)) in bodies.iter().zip(GOLDEN_BODIES) {
            assert_eq!((b.kind(), hex(&b.encode()).as_str()), (kind, want));
            // 解码方向：冻结的字节解出同一个值。
            assert_eq!(&Body4::decode(kind, BODY_FMT, &unhex(want)).unwrap(), b);
        }
    }

    pub const GOLDEN_BODIES: [(u16, &str); 16] = [
        (
            1,
            "0300010101010101010101010101010101012b7b22637265617465644174223a312c2267756964223a2267222c226e6f7465547970654964223a2274227d",
        ),
        (
            2,
            "0300030303030303030303030303030303030104040404040404040404040404040404020822e58d98e8aa9e22",
        ),
        (
            2,
            "030003030303030303030303030303030303000764656c6574656405046e756c6c0304000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01aa4b010fd425b6a1cceda768009a36",
        ),
        (
            3,
            "000707070707070707070707070707070700080808080808080808080808080808089b98010009090909090909090909090909090909000680a0abfef962010001d0410966737273373a616263056673727337c00701",
        ),
        (
            3,
            "00212121212121212121212121212121210022222222222222222222222222222222f28e04000682effbf5ab6501018a5e04616e6b6982effbf5ab650085017b22647565446179223a32303135352c2265617365223a323530302c2269766c223a342c226c6170736573223a302c226c61737452657669657765644174223a313734313036313834393030312c227175657565223a22726576696577222c2272657073223a312c227363686564756c6572223a226675736869222c2273746570223a307d82effbf5ab6500beac06",
        ),
        (
            3,
            "000707070707070707070707070707070700080808080808080808080808080808089bff030009090909090909090909090909090909ff0577656972640d80a0abfef96209ff0178ff036f6464d0410966737273373a616263056673727337c00700040205127b226d656d416c67223a226673727336227d062b313a303a7801",
        ),
        (4, "01016e0174"),
        (5, "01016e0174"),
        (11, "01016e0201620161"),
        (6, "016106696d706f7274"),
        (7, "0301016e"),
        (
            8,
            "05612e6d703309090909090909090909090909090909090909090909090909090909090909094d",
        ),
        (9, "010162010161"),
        (10, "027b7d"),
        (
            13,
            "02020202020202020202020202020202020505050505050505050505050505050502030109010001",
        ),
        (
            14,
            "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b02430313932663061612d303030302d373030302d383030302d3030303030303030303030620201610162",
        ),
    ];

    #[test]
    fn golden_op_and_chain() {
        let op = op_of(id(0xa1), 7, &Body4::Edit(native_edit()));
        golden("op", &op.encode(), GOLDEN_OP);
        golden("chain", &chain_next4(&[0; 32], &op), GOLDEN_CHAIN);
        assert_eq!(Op4::read(&mut Reader::new(&unhex(GOLDEN_OP))).unwrap(), op);
    }

    const GOLDEN_OP: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1078ec0e285e3680001d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d20502042d0300030303030303030303030303030303030104040404040404040404040404040404020822e58d98e8aa9e22";
    const GOLDEN_CHAIN: &str = "da0e85ef6f2ef1ec04990c34864708fb1d68c05446c89fbda08df2cddbe482b0";

    fn arb_key() -> impl Strategy<Value = Key> {
        prop_oneof![
            proptest::array::uniform16(any::<u8>()).prop_map(|b| Key::Uuid(Id(b))),
            "[a-z/]{0,8}".prop_map(|s| Key::of(&s)),
        ]
    }

    fn arb_code(table: &'static [&'static str]) -> impl Strategy<Value = String> {
        prop_oneof![
            proptest::sample::select(table).prop_map(str::to_owned),
            "[a-z]{0,5}",
        ]
    }

    pub fn arb_log() -> impl Strategy<Value = Log4> {
        (
            (
                arb_key(),
                arb_key(),
                proptest::option::of(arb_key()),
                arb_code(&LOG_KINDS),
                proptest::option::of(any::<i64>()),
                proptest::option::of(arb_key()),
                any::<i64>(),
                any::<u8>(),
            ),
            (
                arb_code(&ORIGINS),
                arb_code(&RTYPES),
                prop_oneof![Just(0i64), any::<i64>()],
                proptest::option::of("[a-z0-9:]{0,10}"),
                proptest::option::of("[a-z0-9]{0,6}"),
                prop_oneof![Just(0i64), any::<i64>()],
                prop_oneof![Just(4i64), any::<i64>()],
                proptest::option::of(any::<i64>()),
            ),
            (
                prop_oneof![Just(1i64), any::<i64>()],
                prop_oneof![
                    Just(Intent::Absolute),
                    Just(Intent::Answer),
                    any::<i64>().prop_map(|due_day| Intent::SetDue { due_day }),
                    Just(Intent::Reset),
                    Just(Intent::Reschedule),
                    any::<bool>().prop_map(|to_anki| Intent::HandOff { to_anki }),
                ],
                proptest::option::of("\\{[a-z\":0-9,]{0,20}\\}"),
                prop_oneof![Just("{}".to_owned()), "\\{[a-z\":0-9,]{1,20}\\}"],
                proptest::option::of(arb_hlc()),
                proptest::option::of(any::<i64>()),
            ),
        )
            .prop_map(
                |(
                    (id, card, note, kind, rating, revokes, at, ts),
                    (origin, rtype, dur, params, alg, utc_off, rollover, anki_id),
                    (fv, intent, res, extra, hlc, server_time),
                )| Log4 {
                    id,
                    card,
                    note,
                    kind,
                    rating,
                    revokes,
                    at,
                    ts,
                    origin,
                    rtype,
                    dur,
                    params,
                    alg,
                    utc_off,
                    rollover,
                    anki_id,
                    fv,
                    intent,
                    res,
                    extra,
                    hlc,
                    server_time,
                },
            )
    }

    pub fn arb_edit() -> impl Strategy<Value = Edit4> {
        (
            proptest::sample::select(&EntKind::ALL[..]),
            arb_key(),
            prop_oneof![
                "[a-zA-Z/]{0,12}",
                proptest::array::uniform16(any::<u8>()).prop_map(|b| format!("f/{}", Id(b).text())),
            ],
            ".{0,20}",
            any::<bool>(),
            any::<bool>(),
            proptest::option::of(arb_stamp()),
        )
            .prop_map(
                |(kind, entity, key, value, machine, anchored, stamp)| Edit4 {
                    kind,
                    entity,
                    key,
                    value,
                    machine,
                    anchored,
                    stamp,
                },
            )
    }

    proptest! {
        #[test]
        fn any_log_round_trips(l in arb_log()) {
            let b = Body4::Log(l);
            prop_assert_eq!(Body4::decode(KIND_LOG, BODY_FMT, &b.encode()).unwrap(), b);
        }

        #[test]
        fn any_edit_round_trips(e in arb_edit()) {
            let has = e.stamp.is_some();
            let b = Body4::Edit(e);
            let bytes = b.encode();
            prop_assert_eq!(edit_has_stamp(&bytes).unwrap(), has);
            prop_assert_eq!(Body4::decode(KIND_EDIT, BODY_FMT, &bytes).unwrap(), b);
        }

        /// 任意字节当任意种类解：不 panic；解得开的（本版本格式号、已知种类）重新编码必与原字节相同。
        #[test]
        fn fmt_4_bodies_have_one_byte_form(kind in 0u16..16, bytes in proptest::collection::vec(any::<u8>(), 0..120)) {
            if let Ok(b) = Body4::decode(kind, BODY_FMT, &bytes) {
                if b != Body4::Unknown {
                    prop_assert_eq!(b.encode(), bytes.clone());
                }
            }
            let _ = Body4::decode(kind, BODY_FMT + 1, &bytes);
            let _ = Op4::read(&mut Reader::new(&bytes));
            let _ = edit_has_stamp(&bytes);
        }

        /// 同上，但从合法字节出发改一个字节（随机字节几乎走不到深处）。
        #[test]
        fn mutated_bodies_have_one_byte_form(
            which in 0usize..16,
            at in any::<proptest::sample::Index>(),
            to in any::<u8>(),
            log in arb_log(),
            edit in arb_edit(),
        ) {
            let mut bodies = all_bodies();
            bodies.push(Body4::Log(log));
            bodies.push(Body4::Edit(edit));
            let b = &bodies[(which + at.index(3)) % bodies.len()];
            let mut bytes = b.encode();
            if !bytes.is_empty() {
                let i = at.index(bytes.len());
                bytes[i] = to;
            }
            if let Ok(back) = Body4::decode(b.kind(), BODY_FMT, &bytes) {
                prop_assert_eq!(back.encode(), bytes);
            }
        }

        /// 独立编码同样只有一种字节形。
        #[test]
        fn mutated_ops_have_one_byte_form(at in any::<proptest::sample::Index>(), to in any::<u8>()) {
            let mut bytes = op_of(id(1), 300, &Body4::Edit(native_edit())).encode();
            let i = at.index(bytes.len());
            bytes[i] = to;
            let mut r = Reader::new(&bytes);
            if let Ok(op) = Op4::read(&mut r) {
                prop_assert_eq!(op.encode(), bytes[..r.pos].to_vec());
            }
        }
    }
}
