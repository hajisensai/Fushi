//! 承袭段（设计 §3.1–§3.3）：一台**旧设备**的协议 3 日志转译成协议 4 之后的一段，不成链、由上传者签名。
//!
//! 承袭日志按 `(来源集合, 旧设备, seq)` 定位，每个 seq 一个**槽**。转译（实现拆分 G2）是逐条、确定、只看那一条旧操作
//! 与它的原链值的函数，所以同一个槽不论由哪台升级过的设备上传，字节都相同；这里的解码器只收规范字节（一个槽只有一种字节形），
//! 「同号同字节」的幂等判定才站得住。
//!
//! ```text
//! 头（明文；签名覆盖；加密时作 AAD）
//!   "FSH4" | ver u8 = 1 | flags u8（bit0 加密；其余必须为 0）
//!   | collection[16]（所在集合）| source[16]（来源集合：这段旧日志当初所属的协议 3 集合）
//!   | device[16]（旧设备）| uploader[16]（上传者的设备 ID；签名者）| t_version uv（转译规则的版本，>= 1）
//!   | first uv | last uv | prev_chain[32]（原协议 3 链在 first - 1 处的值）| last_chain[32]（在 last 处的值）
//! 体  bytes( zstd( n_items uv | 项 × n_items ) [再 XChaCha20-Poly1305] )
//! 尾  上传者的 Ed25519( blake3(头 || 体) )[64]
//!
//! 项  tag u8
//!   0 操作      fp[8] | wall 增量 iv | logical uv | deps 标志 u8（0 同上一条 / 1 + 版本向量）| kind uv | fmt uv | bytes(协议 4 操作体)
//!   1 原样件    fp[8] | wall 增量 iv | logical uv | deps 标志 …                          | kind uv | schema uv | bytes(协议 3 操作体原字节)
//!   2 副本记录  fp[8] | wall 增量 iv | logical uv | kind uv | of_device[16] | of_seq uv | has_stamp u8（0 / 1）| [旧戳]
//!   3 空洞      count uv（>= 1）| fp[8] × count
//! ```
//!
//! - `fp` = 这个 seq 处**原协议 3 链值**的前 8 字节。它是分叉判据：同一 `(旧设备, seq)` 的两个槽 `fp` 不同 = 那台旧设备的日志
//!   分叉过，两支都要留、不能互相覆盖。**每个 seq 都带 `fp`，空洞也逐条带**——槽是逐 seq 的纯函数，怎么切段都不丢判据。
//! - wall 增量相对上一个带时间的槽（操作 / 原样件 / 副本记录；跨过空洞），段里第一个相对 0。deps 标志的「上一条」是上一个
//!   操作 / 原样件槽。
//! - **操作**：转译后的协议 4 操作（`fmt >= 4`）。`fmt == 4` 时操作体必须是已知种类的规范字节。
//!   **带盐的种类（14 Join、15 Salts）不许出现在这里**，不论格式号：转译从不产生它们，而承袭段由上传者签名——
//!   盐集合只能经作者自己签的原生日志改（op.rs 文件头「盐集合」）。
//! - **原样件**：转译规则不能逐字节交代清楚的旧操作（不认识的种类、解不开的载荷、`schema` 不是 1、解码再编码不等于原字节的
//!   载荷）。整条原样带过来（[Raw3]），`schema` 保留原值；读者保存、转发。它是「未知字段保留原字节」在承袭方向的出口。
//!   **应用与否跟协议 3 相同**：协议 3 的解码器解得开、种类也认识的（它只读已知前缀、不看 `schema`），派生层按解出的值应用
//!   （实现拆分 G2 给出这个视图）；解不开 / 不认识的不应用。
//! - **副本记录**：旧日志里的副本骨架（协议 3 `Body::Duplicate`）。留下原件的操作号、旧修改记录的旧戳（闭包要用）、
//!   种类与 HLC（按时刻取前缀的读者要用）；骨架的依赖向量与载荷哈希不留。
//! - **空洞**：已彻底清除的旧操作（协议 3 的纯清除骨架、退役的 MediaAt）。只剩位置与 `fp`。
//! - 不成链：转译后的字节重算不出原链。整段的真实性靠上传者的签名；`prev_chain` / `last_chain` 是上传者对原链端点的陈述，
//!   读侧只核对末槽 `fp == last_chain[..8]`。
//! - 一段只含同一个 `t_version` 转出的槽（上传者只有一套转译规则；转存别人上传的槽时按版本分段）。
//!
//! 独立规范编码 [HeritageSlot::encode]（本机存槽、比「同号同字节」用）：
//!
//! ```text
//! device[16] | seq uv | fp[8] | tag u8 | 0 / 1: wall iv | logical uv | 版本向量 | kind uv | fmt uv | bytes(payload)
//!                                      | 2:     wall iv | logical uv | kind uv | of_device[16] | of_seq uv | has_stamp u8 | [旧戳]
//!                                      | 3:     （无）
//! ```

use std::borrow::Cow;
use std::sync::Arc;

use super::op::{
    BODY_FMT, Body4, KIND_JOIN, KIND_RETIRED_MEDIA_AT, KIND_SALTS, Op4, read_deps, read_kind_fmt,
};
use super::segment::{
    read_chain, read_magic, read_op_slot, read_range, seal, stream_err, unseal, write_op_slot,
};
use super::stamp::HeritageStamp;
use super::{bytes_min, iv_min, u16_min, uv_min};
use crate::sync2::codec::{DResult, DecodeError, Reader, Writer, ZstdWindow};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::Id;
use crate::sync2::keys::{CollectionKey, DeviceKey};
use crate::sync2::op as v3;
use crate::sync2::segment::{Chain, SegmentError};
use crate::sync2::vv::{OpId, Vv};

pub const MAGIC: &[u8; 4] = b"FSH4";
pub const VERSION: u8 = 1;

const F_ENCRYPTED: u8 = 1;
const TAG_OP: u8 = 0;
const TAG_RAW3: u8 = 1;
const TAG_ALIAS: u8 = 2;
const TAG_VOID: u8 = 3;

/// 原协议 3 链值的前 8 字节。
pub type Fp = [u8; 8];

pub fn fingerprint(chain: &Chain) -> Fp {
    let mut fp = [0u8; 8];
    fp.copy_from_slice(&chain[..8]);
    fp
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeritageHeader {
    pub encrypted: bool,
    /// 这段所在的集合。
    pub collection: Id,
    /// 来源集合：旧日志当初所属的协议 3 集合。
    pub source: Id,
    /// 旧设备。
    pub device: Id,
    /// 上传者（协议 4 的设备 ID）；段尾是它的签名。
    pub uploader: Id,
    /// 转译规则的版本。
    pub t_version: u32,
    pub first: u64,
    pub last: u64,
    pub prev_chain: Chain,
    pub last_chain: Chain,
}

impl HeritageHeader {
    fn write(&self, w: &mut Writer) {
        w.raw(MAGIC);
        w.u8(VERSION);
        w.u8(if self.encrypted { F_ENCRYPTED } else { 0 });
        self.collection.write(w);
        self.source.write(w);
        self.device.write(w);
        self.uploader.write(w);
        w.uv(u64::from(self.t_version));
        w.uv(self.first);
        w.uv(self.last);
        w.raw(&self.prev_chain);
        w.raw(&self.last_chain);
    }

    fn read(r: &mut Reader<'_>) -> DResult<HeritageHeader> {
        let flags = read_magic(r, MAGIC, VERSION)?;
        let collection = Id::read(r)?;
        let source = Id::read(r)?;
        let device = Id::read(r)?;
        let uploader = Id::read(r)?;
        let t_version = u32::try_from(uv_min(r)?).map_err(|_| DecodeError("t version"))?;
        if t_version == 0 {
            return Err(DecodeError("t version"));
        }
        let (first, last) = read_range(r)?;
        Ok(HeritageHeader {
            encrypted: flags & F_ENCRYPTED != 0,
            collection,
            source,
            device,
            uploader,
            t_version,
            first,
            last,
            prev_chain: read_chain(r)?,
            last_chain: read_chain(r)?,
        })
    }
}

/// 副本记录：这个 seq 的旧操作是 [of] 的副本。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alias {
    /// 旧操作的种类。
    pub kind: u16,
    /// 旧操作的 HLC（时间部分；设备就是旧设备）。
    pub wall: i64,
    pub logical: u32,
    /// 原件。
    pub of: OpId,
    /// 旧修改记录的旧戳（不是修改、或没有旧戳 = None）。
    pub stamp: Option<HeritageStamp>,
}

/// 原样件：一条没转译的协议 3 操作（未清除的）。字段全是协议 3 的原值——载荷**不是**协议 4 的操作体，所以这个类型
/// 没有「按协议 4 解操作体」的入口；要读它只能经 [Raw3::to_v3] 回到协议 3 的类型。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Raw3(
    /// 借用操作的信封布局存放：`fmt` 一格存的是协议 3 的 `schema`。不外露。
    Op4,
);

impl Raw3 {
    /// 协议 3 的一条未清除操作 → 原样件。
    pub fn of_v3(op: &v3::Op) -> Raw3 {
        Raw3(Op4 {
            id: op.id,
            hlc: op.hlc,
            deps: op.deps.clone(),
            kind: op.kind,
            fmt: op.schema,
            payload: op.payload.clone(),
        })
    }

    /// 回到协议 3 的操作（与转译之前的那条逐字段相同）。
    pub fn to_v3(&self) -> v3::Op {
        v3::Op {
            id: self.0.id,
            hlc: self.0.hlc,
            deps: self.0.deps.clone(),
            kind: self.0.kind,
            schema: self.0.fmt,
            payload: self.0.payload.clone(),
            purged: false,
        }
    }

    pub fn id(&self) -> OpId {
        self.0.id
    }

    pub fn hlc(&self) -> Hlc {
        self.0.hlc
    }

    pub fn kind(&self) -> u16 {
        self.0.kind
    }

    /// 协议 3 的 `schema` 原值。
    pub fn schema(&self) -> u16 {
        self.0.fmt
    }

    /// 协议 3 的操作体原字节。
    pub fn payload(&self) -> &[u8] {
        &self.0.payload
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SlotBody {
    /// 转译后的协议 4 操作（`id` 与槽相同）。
    Op(Op4),
    Raw3(Raw3),
    Alias(Alias),
    Void,
}

/// 承袭日志里的一个槽。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeritageSlot {
    /// （旧设备, seq）。
    pub id: OpId,
    pub fp: Fp,
    pub body: SlotBody,
}

fn write_alias_tail(w: &mut Writer, a: &Alias) {
    w.uv(u64::from(a.kind));
    a.of.device.write(w);
    w.uv(a.of.seq);
    match &a.stamp {
        None => w.u8(0),
        Some(s) => {
            w.u8(1);
            s.write(w);
        }
    }
}

fn read_alias_tail(r: &mut Reader<'_>, wall: i64, logical: u32) -> DResult<Alias> {
    let kind = u16_min(r, "alias kind")?;
    let device = Id::read(r)?;
    let seq = uv_min(r)?;
    let stamp = match r.u8()? {
        0 => None,
        1 => Some(HeritageStamp::read(r)?),
        _ => return Err(DecodeError("alias stamp tag")),
    };
    Ok(Alias {
        kind,
        wall,
        logical,
        of: OpId { device, seq },
        stamp,
    })
}

fn read_logical(r: &mut Reader<'_>) -> DResult<u32> {
    u32::try_from(uv_min(r)?).map_err(|_| DecodeError("hlc logical"))
}

fn read_fp(r: &mut Reader<'_>) -> DResult<Fp> {
    r.raw(8)?.try_into().map_err(|_| DecodeError("fp"))
}

/// 操作槽的内容检查（写侧报错、读侧判段损坏）：转译出的操作必须是协议 4 的操作体，本版本格式号下还得是已知种类的规范字节；
/// 退役的 12 与只属于原生日志的 14 / 15（带盐的种类）不论格式号一律拒。
fn check_op(op: &Op4) -> Result<(), &'static str> {
    if op.fmt < BODY_FMT {
        return Err("heritage op body is not protocol 4");
    }
    match op.kind {
        KIND_RETIRED_MEDIA_AT => return Err("kind 12 is retired"),
        KIND_JOIN => return Err("join belongs to native logs only"),
        KIND_SALTS => return Err("salts belong to native logs only"),
        _ => {}
    }
    if op.fmt == BODY_FMT {
        match op.body() {
            Ok(Body4::Unknown) => return Err("heritage op of an unknown kind"),
            Ok(_) => {}
            Err(_) => return Err("heritage op body does not decode"),
        }
    }
    Ok(())
}

impl HeritageSlot {
    pub fn op(fp: Fp, op: Op4) -> HeritageSlot {
        HeritageSlot {
            id: op.id,
            fp,
            body: SlotBody::Op(op),
        }
    }

    pub fn raw3(fp: Fp, raw: Raw3) -> HeritageSlot {
        HeritageSlot {
            id: raw.id(),
            fp,
            body: SlotBody::Raw3(raw),
        }
    }

    pub fn alias(id: OpId, fp: Fp, alias: Alias) -> HeritageSlot {
        HeritageSlot {
            id,
            fp,
            body: SlotBody::Alias(alias),
        }
    }

    pub fn void(id: OpId, fp: Fp) -> HeritageSlot {
        HeritageSlot {
            id,
            fp,
            body: SlotBody::Void,
        }
    }

    /// 槽自洽（操作的身份与槽一致、内容合规）。
    pub fn check(&self) -> Result<(), &'static str> {
        if self.id.seq == 0 {
            return Err("slot seq 0");
        }
        match &self.body {
            SlotBody::Op(op) | SlotBody::Raw3(Raw3(op)) => {
                if op.id != self.id || op.hlc.device != self.id.device {
                    return Err("slot op identity mismatch");
                }
                if op.deps.get(&self.id.device) != 0 {
                    return Err("op deps name its own device");
                }
                if matches!(self.body, SlotBody::Op(_)) {
                    check_op(op)?;
                }
                Ok(())
            }
            // 副本记录不查原件号：旧骨架里写的是什么就是什么（转译对任何旧操作都得有输出）。
            SlotBody::Alias(_) | SlotBody::Void => Ok(()),
        }
    }

    /// 独立规范编码（布局见文件头）。
    pub fn write(&self, w: &mut Writer) {
        self.id.device.write(w);
        w.uv(self.id.seq);
        w.raw(&self.fp);
        match &self.body {
            SlotBody::Op(op) | SlotBody::Raw3(Raw3(op)) => {
                w.u8(if matches!(self.body, SlotBody::Op(_)) {
                    TAG_OP
                } else {
                    TAG_RAW3
                });
                op.hlc.write_time(w);
                op.deps.write(w);
                w.uv(u64::from(op.kind));
                w.uv(u64::from(op.fmt));
                w.bytes(&op.payload);
            }
            SlotBody::Alias(a) => {
                w.u8(TAG_ALIAS);
                w.iv(a.wall);
                w.uv(u64::from(a.logical));
                write_alias_tail(w, a);
            }
            SlotBody::Void => w.u8(TAG_VOID),
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        self.write(&mut w);
        w.into_vec()
    }

    pub fn read(r: &mut Reader<'_>) -> DResult<HeritageSlot> {
        let device = Id::read(r)?;
        let seq = uv_min(r)?;
        let id = OpId { device, seq };
        let fp = read_fp(r)?;
        let tag = r.u8()?;
        let body = match tag {
            TAG_OP | TAG_RAW3 => {
                let wall = iv_min(r)?;
                let logical = read_logical(r)?;
                let deps = read_deps(r, device)?;
                let (kind, fmt) = read_kind_fmt(r)?;
                let op = Op4 {
                    id,
                    hlc: Hlc {
                        wall,
                        logical,
                        device,
                    },
                    deps: Arc::new(deps),
                    kind,
                    fmt,
                    payload: bytes_min(r)?.into(),
                };
                if tag == TAG_OP {
                    SlotBody::Op(op)
                } else {
                    SlotBody::Raw3(Raw3(op))
                }
            }
            TAG_ALIAS => {
                let wall = iv_min(r)?;
                let logical = read_logical(r)?;
                SlotBody::Alias(read_alias_tail(r, wall, logical)?)
            }
            TAG_VOID => SlotBody::Void,
            _ => return Err(DecodeError("slot tag")),
        };
        let slot = HeritageSlot { id, fp, body };
        slot.check().map_err(DecodeError)?;
        Ok(slot)
    }

    /// 槽带的时间（空洞没有）。
    pub fn wall(&self) -> Option<i64> {
        match &self.body {
            SlotBody::Op(op) | SlotBody::Raw3(Raw3(op)) => Some(op.hlc.wall),
            SlotBody::Alias(a) => Some(a.wall),
            SlotBody::Void => None,
        }
    }
}

/// 一段承袭日志的出处（[pack_heritage] 的输入；区间由槽自己决定）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeritageMeta {
    pub collection: Id,
    pub source: Id,
    pub device: Id,
    pub uploader: Id,
    pub t_version: u32,
    /// 原协议 3 链在第一个槽之前、最后一个槽处的值。
    pub prev_chain: Chain,
    pub last_chain: Chain,
}

fn write_body(slots: &[HeritageSlot]) -> Vec<u8> {
    let mut items = 0u64;
    let mut prev_void = false;
    for s in slots {
        let void = matches!(s.body, SlotBody::Void);
        if !(void && prev_void) {
            items += 1;
        }
        prev_void = void;
    }
    let mut w = Writer::with_capacity(slots.len() * 56);
    w.uv(items);
    let mut wall = 0i64;
    let mut deps: Option<&Arc<Vv>> = None;
    let mut i = 0;
    while i < slots.len() {
        let s = &slots[i];
        match &s.body {
            SlotBody::Op(op) | SlotBody::Raw3(Raw3(op)) => {
                w.u8(if matches!(s.body, SlotBody::Op(_)) {
                    TAG_OP
                } else {
                    TAG_RAW3
                });
                w.raw(&s.fp);
                write_op_slot(&mut w, op, wall, deps);
                wall = op.hlc.wall;
                deps = Some(&op.deps);
                i += 1;
            }
            SlotBody::Alias(a) => {
                w.u8(TAG_ALIAS);
                w.raw(&s.fp);
                w.iv(a.wall.wrapping_sub(wall));
                w.uv(u64::from(a.logical));
                write_alias_tail(&mut w, a);
                wall = a.wall;
                i += 1;
            }
            SlotBody::Void => {
                let run = slots[i..]
                    .iter()
                    .take_while(|s| matches!(s.body, SlotBody::Void))
                    .count();
                w.u8(TAG_VOID);
                w.uv(run as u64);
                for s in &slots[i..i + run] {
                    w.raw(&s.fp);
                }
                i += run;
            }
        }
    }
    w.into_vec()
}

/// 打包一段。[slots] 是 [HeritageMeta::device] 的连续 seq；[signer] 是上传者的密钥。
pub fn pack_heritage(
    meta: &HeritageMeta,
    slots: &[HeritageSlot],
    signer: &DeviceKey,
    key: Option<&CollectionKey>,
) -> Result<(HeritageHeader, Vec<u8>), String> {
    let (Some(first), Some(last)) = (slots.first(), slots.last()) else {
        return Err("empty heritage segment".into());
    };
    if meta.t_version == 0 {
        return Err("t version 0".into());
    }
    for (i, s) in slots.iter().enumerate() {
        if s.id.device != meta.device || s.id.seq != first.id.seq + i as u64 {
            return Err("heritage slots must be one device's contiguous seqs".into());
        }
        s.check()?;
    }
    if last.fp != fingerprint(&meta.last_chain) {
        return Err("last slot does not match the chain tail".into());
    }
    let header = HeritageHeader {
        encrypted: key.is_some(),
        collection: meta.collection,
        source: meta.source,
        device: meta.device,
        uploader: meta.uploader,
        t_version: meta.t_version,
        first: first.id.seq,
        last: last.id.seq,
        prev_chain: meta.prev_chain,
        last_chain: meta.last_chain,
    };
    let mut hw = Writer::new();
    header.write(&mut hw);
    let bytes = seal(hw.into_vec(), &write_body(slots), signer, key)?;
    Ok((header, bytes))
}

/// 只读段头（不验签、不解体）。
pub fn peek_heritage_header(bytes: &[u8]) -> Result<HeritageHeader, SegmentError> {
    Ok(HeritageHeader::read(&mut Reader::new(bytes))?)
}

/// 段体里的一项（空洞是一串）。
enum Item {
    Slot(HeritageSlot),
    Voids(Vec<Fp>),
}

/// 流式解开的段体：逐槽产出（空洞一个 seq 一个）。格式错时产出一次 `Err` 后结束。
pub struct SlotStream<'s> {
    window: ZstdWindow<'s>,
    device: Id,
    last: u64,
    tail: Fp,
    n: Option<u64>,
    i: u64,
    seq: u64,
    wall: i64,
    deps: Option<Arc<Vv>>,
    prev_void: bool,
    last_fp: Option<Fp>,
    pending: std::vec::IntoIter<Fp>,
    done: bool,
}

impl<'s> SlotStream<'s> {
    fn new(compressed: &'s [u8], header: &HeritageHeader) -> Result<SlotStream<'s>, SegmentError> {
        Ok(SlotStream {
            window: ZstdWindow::new(compressed).map_err(stream_err)?,
            device: header.device,
            last: header.last,
            tail: fingerprint(&header.last_chain),
            n: None,
            i: 0,
            seq: header.first,
            wall: 0,
            deps: None,
            prev_void: false,
            last_fp: None,
            pending: Vec::new().into_iter(),
            done: false,
        })
    }

    fn emit_void(&mut self, fp: Fp) -> HeritageSlot {
        let id = OpId {
            device: self.device,
            seq: self.seq,
        };
        self.seq += 1;
        self.last_fp = Some(fp);
        HeritageSlot::void(id, fp)
    }

    fn step(&mut self) -> Result<Option<HeritageSlot>, SegmentError> {
        if let Some(fp) = self.pending.next() {
            return Ok(Some(self.emit_void(fp)));
        }
        let left = self.last + 1 - self.seq;
        let n = match self.n {
            Some(n) => n,
            None => {
                let n = self.window.parse(uv_min).map_err(stream_err)?;
                if n == 0 || n > left {
                    return Err(DecodeError("segment item count").into());
                }
                self.n = Some(n);
                n
            }
        };
        if self.i == n {
            if left != 0 {
                return Err(DecodeError("segment items do not cover its range").into());
            }
            if !self.window.at_end().map_err(stream_err)? {
                return Err(DecodeError("trailing bytes in segment body").into());
            }
            if self.last_fp != Some(self.tail) {
                return Err(DecodeError("last slot does not match the chain tail").into());
            }
            return Ok(None);
        }
        if left == 0 {
            return Err(DecodeError("segment items overrun its range").into());
        }
        let id = OpId {
            device: self.device,
            seq: self.seq,
        };
        let (wall, deps, prev_void) = (self.wall, self.deps.clone(), self.prev_void);
        let parsed = self.window.parse(|r| {
            let tag = r.u8()?;
            match tag {
                TAG_OP | TAG_RAW3 => {
                    let fp = read_fp(r)?;
                    let op = read_op_slot(r, id, wall, deps.as_ref())?;
                    let body = if tag == TAG_OP {
                        SlotBody::Op(op)
                    } else {
                        SlotBody::Raw3(Raw3(op))
                    };
                    Ok(Item::Slot(HeritageSlot { id, fp, body }))
                }
                TAG_ALIAS => {
                    let fp = read_fp(r)?;
                    let at = wall.wrapping_add(iv_min(r)?);
                    let logical = read_logical(r)?;
                    Ok(Item::Slot(HeritageSlot::alias(
                        id,
                        fp,
                        read_alias_tail(r, at, logical)?,
                    )))
                }
                TAG_VOID => {
                    let count = uv_min(r)?;
                    if count == 0 || count > left {
                        return Err(DecodeError("void count"));
                    }
                    if prev_void {
                        return Err(DecodeError("adjacent voids"));
                    }
                    let n = usize::try_from(count).map_err(|_| DecodeError("void count"))?;
                    let raw = r.raw(n.checked_mul(8).ok_or(DecodeError("void count"))?)?;
                    Ok(Item::Voids(
                        raw.chunks_exact(8)
                            .map(|c| {
                                let mut fp = [0u8; 8];
                                fp.copy_from_slice(c);
                                fp
                            })
                            .collect(),
                    ))
                }
                _ => Err(DecodeError("segment item tag")),
            }
        });
        let item = parsed.map_err(stream_err)?;
        self.i += 1;
        match item {
            Item::Slot(slot) => {
                slot.check()
                    .map_err(|m| SegmentError::Corrupt(m.to_owned()))?;
                match &slot.body {
                    SlotBody::Op(op) | SlotBody::Raw3(Raw3(op)) => {
                        self.wall = op.hlc.wall;
                        self.deps = Some(op.deps.clone());
                    }
                    SlotBody::Alias(a) => self.wall = a.wall,
                    SlotBody::Void => {}
                }
                self.prev_void = false;
                self.seq += 1;
                self.last_fp = Some(slot.fp);
                Ok(Some(slot))
            }
            Item::Voids(fps) => {
                self.prev_void = true;
                self.pending = fps.into_iter();
                let fp = self.pending.next().ok_or(DecodeError("void count"))?;
                Ok(Some(self.emit_void(fp)))
            }
        }
    }
}

impl Iterator for SlotStream<'_> {
    type Item = Result<HeritageSlot, SegmentError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        let r = self.step();
        self.done = !matches!(r, Ok(Some(_)));
        r.transpose()
    }
}

/// 验过签、解过密的承袭段：段体仍是压缩的，按需流式解开。
pub struct OpenHeritage<'a> {
    pub header: HeritageHeader,
    compressed: Cow<'a, [u8]>,
}

impl OpenHeritage<'_> {
    /// 流式解码。流走到头才算整段合规（覆盖区间、末槽对得上链尾）：调用方要么先整段过一遍，要么把落库放在同一个事务里。
    pub fn slots(&self) -> Result<SlotStream<'_>, SegmentError> {
        SlotStream::new(&self.compressed, &self.header)
    }
}

/// 验签、解密一段（不解压）。[public] 是上传者（段头的 `uploader`）的公钥。
pub fn open_heritage_verified<'a>(
    bytes: &'a [u8],
    public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<OpenHeritage<'a>, SegmentError> {
    let mut r = Reader::new(bytes);
    let header = HeritageHeader::read(&mut r)?;
    let compressed = unseal(bytes, r, header.encrypted, public, key)?;
    Ok(OpenHeritage { header, compressed })
}

/// 校验并整段解开，全部放进内存。给测试这类已知小段的场合。
pub fn open_heritage(
    bytes: &[u8],
    public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<(HeritageHeader, Vec<HeritageSlot>), SegmentError> {
    let seg = open_heritage_verified(bytes, public, key)?;
    let slots = seg
        .slots()?
        .collect::<Result<Vec<HeritageSlot>, SegmentError>>()?;
    Ok((seg.header, slots))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::gen4::op::tests::{id, imported_log, native_edit, op_of};
    use crate::gen4::op::{Edit4, Join4, KIND_EDIT, KIND_LOG};
    use crate::gen4::segment::tests::{coll, signer, v3_segment};
    use crate::gen4::segment::{NativeItem, open_native, pack_native, peek_native_header};
    use crate::gen4::stamp::tests::typical;
    use crate::gen4::{golden, unhex};
    use crate::sync2::segment as v3;
    use proptest::prelude::*;

    /// 旧设备。
    const OLD: u8 = 0x0d;

    fn fp(n: u8) -> Fp {
        [n; 8]
    }

    fn oid(seq: u64) -> OpId {
        OpId {
            device: id(OLD),
            seq,
        }
    }

    fn meta(last_fp: Fp) -> HeritageMeta {
        let mut last_chain = [0x77; 32];
        last_chain[..8].copy_from_slice(&last_fp);
        HeritageMeta {
            collection: coll(),
            source: id(0x5c),
            device: id(OLD),
            uploader: id(0xa1),
            t_version: 1,
            prev_chain: [0x11; 32],
            last_chain,
        }
    }

    /// seq 1..=8：带戳的修改、导入的日志、原样件、副本记录（带戳 / 不带戳）、两个空洞、再一条操作。
    pub fn slots() -> Vec<HeritageSlot> {
        let stamped = Body4::Edit(Edit4 {
            stamp: Some(typical()),
            ..native_edit()
        });
        let raw = Raw3(Op4 {
            kind: 77,
            fmt: 1,
            payload: vec![1, 2, 3].into(),
            ..op_of(id(OLD), 3, &Body4::Unknown)
        });
        vec![
            HeritageSlot::op(fp(1), op_of(id(OLD), 1, &stamped)),
            HeritageSlot::op(fp(2), op_of(id(OLD), 2, &Body4::Log(imported_log()))),
            HeritageSlot::raw3(fp(3), raw),
            HeritageSlot::alias(
                oid(4),
                fp(4),
                Alias {
                    kind: KIND_EDIT,
                    wall: 1_800_000_000_009,
                    logical: 2,
                    of: OpId {
                        device: id(0xee),
                        seq: 40,
                    },
                    stamp: Some(typical()),
                },
            ),
            HeritageSlot::alias(
                oid(5),
                fp(5),
                Alias {
                    kind: KIND_LOG,
                    wall: 1_800_000_000_009,
                    logical: 3,
                    of: OpId {
                        device: id(0xee),
                        seq: 41,
                    },
                    stamp: None,
                },
            ),
            HeritageSlot::void(oid(6), fp(6)),
            HeritageSlot::void(oid(7), fp(7)),
            HeritageSlot::op(
                fp(8),
                op_of(
                    id(OLD),
                    8,
                    &Body4::Dedup {
                        pairs: vec![(
                            5,
                            OpId {
                                device: id(0xee),
                                seq: 41,
                            },
                        )],
                    },
                ),
            ),
        ]
    }

    fn pack(slots: &[HeritageSlot], key: Option<&CollectionKey>) -> Vec<u8> {
        let m = meta(slots.last().unwrap().fp);
        pack_heritage(&m, slots, &signer(), key).unwrap().1
    }

    fn open_err(bytes: &[u8]) -> SegmentError {
        open_heritage(bytes, &signer().public(), None).unwrap_err()
    }

    #[test]
    fn round_trip_plain_and_encrypted() {
        let slots = slots();
        let key = CollectionKey([3; 32]);
        for k in [None, Some(&key)] {
            let m = meta(fp(8));
            let (header, bytes) = pack_heritage(&m, &slots, &signer(), k).unwrap();
            assert_eq!((header.first, header.last), (1, 8));
            assert_eq!(header.encrypted, k.is_some());
            assert_eq!(
                (
                    header.source,
                    header.device,
                    header.uploader,
                    header.t_version
                ),
                (m.source, m.device, m.uploader, 1)
            );
            assert_eq!(peek_heritage_header(&bytes).unwrap(), header);
            let (h2, back) = open_heritage(&bytes, &signer().public(), k).unwrap();
            assert_eq!(h2, header);
            assert_eq!(back, slots);
        }
    }

    /// 槽是逐 seq 的纯函数：同一批槽怎么切段，解出来的槽（与它们的规范编码）都一样。
    #[test]
    fn cutting_does_not_change_slots() {
        let slots = slots();
        let whole: Vec<Vec<u8>> = slots.iter().map(HeritageSlot::encode).collect();
        for cut in 1..slots.len() {
            let mut back = Vec::new();
            for part in [&slots[..cut], &slots[cut..]] {
                let (_, s) = open_heritage(&pack(part, None), &signer().public(), None).unwrap();
                back.extend(s);
            }
            assert_eq!(back, slots, "cut at {cut}");
            let enc: Vec<Vec<u8>> = back.iter().map(HeritageSlot::encode).collect();
            assert_eq!(enc, whole);
        }
    }

    #[test]
    fn standalone_slots_round_trip() {
        for s in slots() {
            let bytes = s.encode();
            let mut r = Reader::new(&bytes);
            assert_eq!(HeritageSlot::read(&mut r).unwrap(), s);
            assert!(r.is_empty());
            for n in 0..bytes.len() {
                assert!(HeritageSlot::read(&mut Reader::new(&bytes[..n])).is_err());
            }
        }
    }

    #[test]
    fn pack_refuses_malformed_input() {
        let slots = slots();
        let m = meta(fp(8));
        let pack = |m: &HeritageMeta, s: &[HeritageSlot]| pack_heritage(m, s, &signer(), None);
        assert!(pack(&m, &[]).is_err());
        // 末槽与链尾对不上。
        assert!(pack(&meta(fp(9)), &slots).is_err());
        assert!(pack(&m, &slots[..7]).is_err());
        // seq 不连续、别的设备。
        let mut gap = slots.clone();
        gap.remove(4);
        assert!(pack(&m, &gap).is_err());
        let other = HeritageMeta {
            device: id(0xee),
            ..m.clone()
        };
        assert!(pack(&other, &slots).is_err());
        assert!(
            pack(
                &HeritageMeta {
                    t_version: 0,
                    ..m.clone()
                },
                &slots
            )
            .is_err()
        );
        // 槽里的操作身份与槽不一致。
        let mut wrong = slots.clone();
        wrong[0] = HeritageSlot {
            id: oid(1),
            fp: fp(1),
            body: SlotBody::Op(op_of(id(OLD), 2, &Body4::Edit(native_edit()))),
        };
        assert_eq!(
            pack(&m, &wrong).unwrap_err(),
            "slot op identity mismatch".to_owned()
        );
        // 操作槽：协议 3 的操作体、不认识的种类、退役的 12、解不开的操作体。
        let bad = |op: Op4| {
            let mut s = slots.clone();
            s[0] = HeritageSlot::op(fp(1), op);
            pack(&m, &s).unwrap_err()
        };
        let good = op_of(id(OLD), 1, &Body4::Edit(native_edit()));
        assert_eq!(
            bad(Op4 {
                fmt: 1,
                ..good.clone()
            }),
            "heritage op body is not protocol 4"
        );
        assert_eq!(
            bad(Op4 {
                kind: 77,
                ..good.clone()
            }),
            "heritage op of an unknown kind"
        );
        assert_eq!(
            bad(Op4 {
                kind: KIND_RETIRED_MEDIA_AT,
                ..good.clone()
            }),
            "kind 12 is retired"
        );
        // 带盐的种类只属于原生日志，不论格式号。
        for (body, why) in salt_carriers() {
            let op = op_of(id(OLD), 1, &body);
            assert_eq!(bad(op.clone()), why);
            assert_eq!(
                bad(Op4 {
                    fmt: BODY_FMT + 1,
                    ..op
                }),
                why
            );
        }
        assert_eq!(
            bad(Op4 {
                payload: vec![0xff].into(),
                ..good.clone()
            }),
            "heritage op body does not decode"
        );
        // 更新的格式号、不认识的种类：以后的转译规则写的，照收。
        let mut s = slots.clone();
        s[0] = HeritageSlot::op(
            fp(1),
            Op4 {
                kind: 77,
                fmt: BODY_FMT + 1,
                ..good.clone()
            },
        );
        assert!(pack(&m, &s).is_ok());
    }

    /// 绕过 [pack_heritage] 的检查拼一段（签名有效）。
    fn assemble(header: &HeritageHeader, raw_body: &[u8]) -> Vec<u8> {
        let mut hw = Writer::new();
        header.write(&mut hw);
        seal(hw.into_vec(), raw_body, &signer(), None).unwrap()
    }

    fn header_for(first: u64, last: u64, last_fp: Fp) -> HeritageHeader {
        let m = meta(last_fp);
        HeritageHeader {
            encrypted: false,
            collection: m.collection,
            source: m.source,
            device: m.device,
            uploader: m.uploader,
            t_version: 1,
            first,
            last,
            prev_chain: m.prev_chain,
            last_chain: m.last_chain,
        }
    }

    #[test]
    fn open_rejects_tampering_and_misfits() {
        let slots = slots();
        let bytes = pack(&slots, None);
        assert_eq!(
            open_heritage(&bytes, &DeviceKey::from_seed(&[8; 32]).public(), None).unwrap_err(),
            SegmentError::BadSignature
        );
        for at in [5, 60, bytes.len() - 70, bytes.len() - 1] {
            let mut bad = bytes.clone();
            bad[at] ^= 1;
            assert!(
                open_heritage(&bad, &signer().public(), None).is_err(),
                "byte {at}"
            );
        }
        let key = CollectionKey([3; 32]);
        let sealed = pack(&slots, Some(&key));
        assert_eq!(
            open_heritage(&sealed, &signer().public(), None).unwrap_err(),
            SegmentError::Undecryptable
        );
        let body = write_body(&slots);
        assert!(
            open_heritage(
                &assemble(&header_for(1, 8, fp(8)), &body),
                &signer().public(),
                None
            )
            .is_ok()
        );
        // 头的区间与体对不上；末槽与链尾对不上；t 版本 0。
        assert!(matches!(
            open_err(&assemble(&header_for(1, 9, fp(8)), &body)),
            SegmentError::Corrupt(_)
        ));
        assert!(matches!(
            open_err(&assemble(&header_for(1, 7, fp(8)), &body)),
            SegmentError::Corrupt(_)
        ));
        assert_eq!(
            open_err(&assemble(&header_for(1, 8, fp(9)), &body)),
            SegmentError::Corrupt("last slot does not match the chain tail".into())
        );
        let mut h = header_for(1, 8, fp(8));
        h.t_version = 0;
        assert_eq!(
            open_err(&assemble(&h, &body)),
            SegmentError::Corrupt("t version".into())
        );
        // 相邻的两串空洞（应当合成一串）。
        let void = |fps: &[Fp]| {
            let mut w = Writer::new();
            w.u8(TAG_VOID);
            w.uv(fps.len() as u64);
            for f in fps {
                w.raw(f);
            }
            w.into_vec()
        };
        let split = [vec![2u8], void(&[fp(1)]), void(&[fp(2)])].concat();
        assert_eq!(
            open_err(&assemble(&header_for(1, 2, fp(2)), &split)),
            SegmentError::Corrupt("adjacent voids".into())
        );
        let merged = [vec![1u8], void(&[fp(1), fp(2)])].concat();
        let (_, got) = open_heritage(
            &assemble(&header_for(1, 2, fp(2)), &merged),
            &signer().public(),
            None,
        )
        .unwrap();
        assert_eq!(
            got,
            vec![
                HeritageSlot::void(oid(1), fp(1)),
                HeritageSlot::void(oid(2), fp(2))
            ]
        );
        // 操作槽里放协议 3 的操作体。
        let old = Op4 {
            fmt: 1,
            ..op_of(id(OLD), 1, &Body4::Edit(native_edit()))
        };
        let mut w = Writer::new();
        w.uv(1);
        w.u8(TAG_OP);
        w.raw(&fp(1));
        write_op_slot(&mut w, &old, 0, None);
        assert_eq!(
            open_err(&assemble(&header_for(1, 1, fp(1)), &w.into_vec())),
            SegmentError::Corrupt("heritage op body is not protocol 4".into())
        );
    }

    /// 带盐的两种操作体与各自的拒绝理由。
    fn salt_carriers() -> [(Body4, &'static str); 2] {
        [
            (
                Body4::Join(Join4 {
                    from: id(0xb0),
                    dir: "b".into(),
                    salts: vec!["u".into()],
                }),
                "join belongs to native logs only",
            ),
            (
                Body4::salts(["u"]).unwrap(),
                "salts belong to native logs only",
            ),
        ]
    }

    /// 读侧同样不收带盐的操作：上传者不能以旧设备的名义改盐集合。
    #[test]
    fn open_rejects_salt_carriers() {
        let one = |op: &Op4| {
            let mut w = Writer::new();
            w.uv(1);
            w.u8(TAG_OP);
            w.raw(&fp(1));
            write_op_slot(&mut w, op, 0, None);
            open_heritage(
                &assemble(&header_for(1, 1, fp(1)), &w.into_vec()),
                &signer().public(),
                None,
            )
        };
        assert!(one(&op_of(id(OLD), 1, &Body4::Edit(native_edit()))).is_ok());
        for (body, why) in salt_carriers() {
            let op = op_of(id(OLD), 1, &body);
            assert_eq!(one(&op).unwrap_err(), SegmentError::Corrupt(why.to_owned()));
            let newer = Op4 {
                fmt: BODY_FMT + 1,
                ..op
            };
            assert_eq!(
                one(&newer).unwrap_err(),
                SegmentError::Corrupt(why.to_owned())
            );
        }
    }

    /// 段体只有一种字节形：同一批槽的另一种写法（依赖向量不用「同上一条」、varint 不取最短）读侧拒绝。
    #[test]
    fn open_rejects_non_canonical_bodies() {
        let a = op_of(id(OLD), 1, &Body4::Edit(native_edit()));
        let b = op_of(id(OLD), 2, &Body4::Edit(native_edit()));
        assert_eq!(a.deps, b.deps);
        let h = header_for(1, 2, fp(2));
        let item = |w: &mut Writer, f: Fp, op: &Op4, prev_wall: i64, deps: Option<&Arc<Vv>>| {
            w.u8(TAG_OP);
            w.raw(&f);
            write_op_slot(w, op, prev_wall, deps);
        };
        let mut w = Writer::new();
        w.uv(2);
        item(&mut w, fp(1), &a, 0, None);
        item(&mut w, fp(2), &b, a.hlc.wall, Some(&a.deps));
        assert!(open_heritage(&assemble(&h, &w.into_vec()), &signer().public(), None).is_ok());
        let mut w = Writer::new();
        w.uv(2);
        item(&mut w, fp(1), &a, 0, None);
        item(&mut w, fp(2), &b, a.hlc.wall, None);
        assert_eq!(
            open_err(&assemble(&h, &w.into_vec())),
            SegmentError::Corrupt("deps repeated in full".into())
        );
        // 项数写成两字节。
        let mut w = Writer::new();
        w.raw(&[0x82, 0x00]);
        item(&mut w, fp(1), &a, 0, None);
        item(&mut w, fp(2), &b, a.hlc.wall, Some(&a.deps));
        assert_eq!(
            open_err(&assemble(&h, &w.into_vec())),
            SegmentError::Corrupt("non-minimal varint".into())
        );
    }

    // ------------------------------------------------------------ 与协议 3、与原生段互不误读

    #[test]
    fn a_protocol_3_decoder_rejects_a_heritage_segment() {
        let key = CollectionKey([3; 32]);
        for k in [None, Some(&key)] {
            let bytes = pack(&slots(), k);
            let magic = SegmentError::Corrupt("segment magic".into());
            assert_eq!(v3::peek_header(&bytes).unwrap_err(), magic);
            assert_eq!(
                v3::open_verified(&bytes, &signer().public(), k)
                    .err()
                    .unwrap(),
                magic
            );
            assert_eq!(v3::open(&bytes, &signer().public(), k).unwrap_err(), magic);
            assert!(v3::relay_unwrap(&bytes, k).is_err());
            assert!(v3::relay_pack(&bytes, None, k).is_err());
        }
    }

    #[test]
    fn heritage_native_and_protocol_3_segments_do_not_mix() {
        let magic = SegmentError::Corrupt("segment magic".into());
        let heritage = pack(&slots(), None);
        assert_eq!(peek_native_header(&heritage).unwrap_err(), magic);
        assert_eq!(
            open_native(&heritage, &signer().public(), None).unwrap_err(),
            magic
        );
        let op = op_of(id(OLD), 1, &Body4::Edit(native_edit()));
        let (_, native) = pack_native(
            coll(),
            id(OLD),
            1,
            &[NativeItem::Op(op)],
            [0; 32],
            &signer(),
            None,
        )
        .unwrap();
        assert_eq!(peek_heritage_header(&native).unwrap_err(), magic);
        assert_eq!(open_err(&native), magic);
        let old = v3_segment();
        assert_eq!(peek_heritage_header(&old).unwrap_err(), magic);
        assert_eq!(open_err(&old), magic);
    }

    // ------------------------------------------------------------ 黄金向量

    /// 段体（未压缩）、段头与每个槽的规范编码冻结。
    #[test]
    fn golden_body_header_and_slots() {
        let slots = slots();
        golden("heritage_body", &write_body(&slots), GOLDEN_BODY);
        let (header, _) = pack_heritage(&meta(fp(8)), &slots, &signer(), None).unwrap();
        let mut hw = Writer::new();
        header.write(&mut hw);
        golden("heritage_header", &hw.into_vec(), GOLDEN_HEADER);
        assert_eq!(slots.len(), GOLDEN_SLOTS.len());
        for (i, s) in slots.iter().enumerate() {
            println!("GOLDEN slot_{i} {}", crate::gen4::hex(&s.encode()));
        }
        for (s, want) in slots.iter().zip(GOLDEN_SLOTS) {
            assert_eq!(crate::gen4::hex(&s.encode()), want);
            assert_eq!(
                &HeritageSlot::read(&mut Reader::new(&unhex(want))).unwrap(),
                s
            );
        }
    }

    /// 整段文件（解码方向）。
    #[test]
    fn golden_files_still_open() {
        let (h, got) = open_heritage(&unhex(GOLDEN_FILE), &signer().public(), None).unwrap();
        assert_eq!(got, slots());
        assert_eq!((h.first, h.last, h.t_version), (1, 8, 1));
        let key = CollectionKey([3; 32]);
        let (h, got) =
            open_heritage(&unhex(GOLDEN_FILE_SEALED), &signer().public(), Some(&key)).unwrap();
        assert_eq!(got, slots());
        assert!(h.encrypted);
    }

    /// 生成上面两个整段常量用（`cargo test -- --ignored print_golden_heritage_files --nocapture`）。
    #[test]
    #[ignore]
    fn print_golden_heritage_files() {
        let key = CollectionKey([3; 32]);
        for (name, k) in [
            ("heritage_file", None),
            ("heritage_file_sealed", Some(&key)),
        ] {
            println!("GOLDEN {name} {}", crate::gen4::hex(&pack(&slots(), k)));
        }
    }

    const GOLDEN_BODY: &str = "0700010101010101010182c0e285e368000101d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d20502045f0300030303030303030303030303030303030104040404040404040404040404040404060822e58d98e8aa9e220304000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01aa4b010fd425b6a1cceda768009a360002020202020202020200000304ce0100212121212121212121212121212121210022222222222222222222222222222222f28e04000682effbf5ab6501018a5e04616e6b6982effbf5ab650085017b22647565446179223a32303135352c2265617365223a323530302c2269766c223a342c226c6170736573223a302c226c61737452657669657765644174223a313734313036313834393030312c227175657565223a22726576696577222c2272657073223a312c227363686564756c6572223a226675736869222c2273746570223a307d82effbf5ab6500beac060103030303030303030200004d01030102030204040404040404040c0202eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee28010304000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01aa4b010fd425b6a1cceda768009a36020505050505050505000303eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee29000302060606060606060607070707070707070008080808080808080100000d041501eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee01050029";
    const GOLDEN_HEADER: &str = "465348340100c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c05c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0da1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a101010811111111111111111111111111111111111111111111111111111111111111110808080808080808777777777777777777777777777777777777777777777777";
    const GOLDEN_SLOTS: [&str; 8] = [
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0101010101010101010082c0e285e3680001d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d20502045f0300030303030303030303030303030303030104040404040404040404040404040404060822e58d98e8aa9e220304000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01aa4b010fd425b6a1cceda768009a36",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0202020202020202020084c0e285e3680001d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050304ce0100212121212121212121212121212121210022222222222222222222222222222222f28e04000682effbf5ab6501018a5e04616e6b6982effbf5ab650085017b22647565446179223a32303135352c2265617365223a323530302c2269766c223a342c226c6170736573223a302c226c61737452657669657765644174223a313734313036313834393030312c227175657565223a22726576696577222c2272657073223a312c227363686564756c6572223a226675736869222c2273746570223a307d82effbf5ab6500beac06",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0303030303030303030186c0e285e3680001d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2054d0103010203",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0404040404040404040292c0e285e3680202eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee28010304000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01aa4b010fd425b6a1cceda768009a36",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0505050505050505050292c0e285e3680303eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee2900",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d06060606060606060603",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d07070707070707070703",
        "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0808080808080808080090c0e285e3680001d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050d041501eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee01050029",
    ];
    const GOLDEN_FILE: &str = "465348340100c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c05c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0da1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a101010811111111111111111111111111111111111111111111111111111111111111110808080808080808777777777777777777777777777777777777777777777777d60228b52ffd601a01650a00f611463b2025a903b8c06d525a8d0e8b40a84d6487c0eb82e4401ef4fcb9ab0514e7af879d03072c40eab62a6ab07d7d77b144ee5e646e0f80d6ee2da54c293b00370033003aa5e6a0f5844404c4834303c382822901e1c0a0a044401a0d08048842dc36656c9ed25f683e2d2b3d2ee2664b9620336e39ddfcf1cc766c64cda1b5aa50d6ff7aef54a5ea2acafa89b7f121cb517ac6e00889373f54ba5f0640002019c79325c899821b674ae6c82b17fe627e6e60682a025fc875da59bfae7f39f5975bfff0c312a75dad19298c6e55bbd445671da6c17a930763ef01bbd5fafdebf25a4e53d65b31d06927debad6a649626e1187b828f9549392b7d816b5184751c696ddc11c9b9ba949a9d65d0fbb4e1dfc6e28e2d65fdf0a591f1500a07390116406b2077ac633fcd08a30ae1320a8670941c464b1514dc2656d32b10bba067a74406cd035d06dd051068607ca1d0ad8658b9d3dd9d2d8f2974c771f3c707d83ca168f5e363e042d679ca654d25ba93b5c1897a5a39c57d1539c0139da68d77bfdb3f53b2d2ad64a3d120a";
    const GOLDEN_FILE_SEALED: &str = "465348340101c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c05c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0da1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a101010811111111111111111111111111111111111111111111111111111111111111110808080808080808777777777777777777777777777777777777777777777777fe024e4a29bc54c1c2b558aabdf7215fd8e6a0727a67032abb1bcd424ffd7bd71f0c22a3521868a73fbb7740c4ecdb4e56485694eea1e6db35a3db5d0af92b560f03f6dd2344cb2dfac0337bfe117abf1195883d981c3a1f8fdb0d41811d558ea17f081103d4bde3635dd347aff331081c7301578768eadbdf4af15b9195c51881149607c1f7572c7930f1b3e0fbc6bf465ef4c1100a8773164763bf77e1ecd39d1016a23073f5b0e892a58edb2b71cbace9b5d1364282d935417bad0ad1994522d8d225bbf954f9741d7ab2029085b7d6d2714755e04d67f521a59bf9ccb9c80e013c503f45a0404b107f6c5bf9f9f9f78900aee70606b9fbdba25df52e11c52fc537c9421debd46e4d5ac05ac1c95d758e75785499d8cd0482f160f16d23750178b3f59691e8011ad3af77349122e4f3fc083c93c0bc740b1ea5ec1408f0a8f8e71efddfe986e176c222432928b9fa98b24c2d765a6ce7be3e64096be4e8407b09725124b6e410556ce2cb9e2f898c5d3ff25c3208ac769574c0ef331dbcf4b7db644be6a2d8bfc0a60fcf470654b34c802c6a8f4a0e1f86dd7743afe5dd93625caf6ef9c0fe83599f8ccf8a3460e0775ce810cbe2da0cf4ae24ee090cf203";

    proptest! {
        /// 槽的规范编码只有一种字节形：从合法字节改一个字节，解得开的重新编码必与原字节相同。
        #[test]
        fn mutated_slots_have_one_byte_form(which in 0usize..8, at in any::<proptest::sample::Index>(), to in any::<u8>()) {
            let mut bytes = slots()[which].encode();
            let i = at.index(bytes.len());
            bytes[i] = to;
            let mut r = Reader::new(&bytes);
            if let Ok(s) = HeritageSlot::read(&mut r) {
                prop_assert_eq!(s.encode(), bytes[..r.pos].to_vec());
            }
        }

        /// 段体同样：改一个字节后还读得出的，重新写出来必与原字节相同。
        #[test]
        fn mutated_bodies_have_one_byte_form(at in any::<proptest::sample::Index>(), to in any::<u8>()) {
            let slots = slots();
            let mut body = write_body(&slots);
            let i = at.index(body.len());
            body[i] = to;
            // 末槽的指纹可能被改到：链尾跟着取，只看字节形。
            for tail in [fp(8), [to; 8]] {
                let h = header_for(1, 8, tail);
                if let Ok((_, got)) = open_heritage(&assemble(&h, &body), &signer().public(), None) {
                    prop_assert_eq!(write_body(&got), body.clone());
                }
            }
        }
    }
}
