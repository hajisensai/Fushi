//! 协议 4 的重切中继件（第四波 K2 引入、第五波根治，交接 §33「转发里的副本」与第五波「重切件根治」）：转发者把一个
//! 作者段里**本机已彻底清除**的操作挖掉、再转发的那一份。
//!
//! ```text
//! "FRX4" | ver u8 = 2 | flags u8（bit0 内层用目标位置的密钥封装；其余必须为 0）
//!   | bytes(原段头) | 作者签名[64] | recutter[16] | bytes(内层)
//! 内层（封装时 = XChaCha20-Poly1305：nonce[24] || 密文+tag，AAD = 前面的全部字节）
//!   = bytes(明文压缩体) | 重切者签名[64]
//! 明文压缩体 = zstd( n_items uv | 槽 × n_items )
//!   槽 0 操作、1 空洞：与原生段相同（[super::segment]；wall 增量与「同上一条」依赖只跨操作槽，剔除槽不算）
//!   槽 2 剔除：wall iv | logical uv | deps（版本向量）| kind uv | fmt uv | 载荷哈希[32] | 清除目标 | purge = device[16] seq uv
//! 重切者签名 = Ed25519(重切者, blake3("fushi-srs-recut/4\n" || 原段头 || 作者签名 || recutter || 明文压缩体))
//! ```
//!
//! # 为什么要有它
//!
//! 作者签名覆盖整段（[super::segment]、[super::relay]），转发者不能把操作改成空洞再冒作者的签名。只靠「不搬」，一台
//! 设备清除了别人写的内容之后，只经它转发拿数据的位置就再也拿不到那位作者这一段——而清除者自己此后每条操作的依赖都
//! 点着那位作者的 seq，那些位置上的设备连清除者的后续操作都投不了（第四波第三轮复核的 major）。重切件让清除者把被清除
//! 的操作挖掉再转发：区间、文件名、段头都与原段相同，读者按同名 `rly-` 拉到它。
//!
//! # 信任口径（第五波根治）
//!
//! 原生段的作者签名覆盖**逐项摘要**（[super::segment] 文件头「签名」）。被挖掉的操作在重切件里留着它的摘要输入——
//! 信封、载荷哈希、作者签进摘要的清除目标（[super::op::purge_targets_v1]）——所以读者：
//!
//! 1. 用**作者公钥验作者的原签名**（逐项摘要照算，剔除槽的摘要等于原操作的摘要）：段头（区间、首尾链值）与留下的
//!    每一条操作都是作者签过的原件，被挖掉的每一项都对应作者签过的一条操作，作者签的空洞原样留着；
//! 2. 从 `prev_chain` **逐条重算链**到 `last_chain`（剔除槽用信封 + 载荷哈希算，与原操作同一环），重切者造不出「只带
//!    链值的重置空洞」——格式里没有重切者自己的空洞，只有作者签的空洞槽（摘要在作者的签名里）；
//! 3. 每个剔除槽带着重切者声称清掉它的那条 **Purge**（`purge`）：读者本机有了那条操作（已落库或在等待缓冲里），它确是
//!    Purge、目标在这一项的清除目标里、这一项的作者写它时没见过它、它的作者本机不拒绝，才算数（`store/gen4/receive.rs`）。
//!    重切者只对「挖掉哪些」负责，挖掉的必须是一条已生效的 Purge 管得到的。
//!
//! 重切者的签名只是问责（谁挖的）；读者另外只收本机信任的重切者签的件（同承袭段的上传者，D20），作为纵深防御。
//! 与上一版（`ver = 1`）的差别：上一版空洞之前的操作只由重切者担保、区间与链尾靠作者 head 的段清单核对（只核 4 字节
//! 标签，还会因为各位置切点不同一直判「没列出」）。`ver = 1` 从没发布，读到一律按损坏拒（`recut version`）。
//!
//! 剔除槽对明文的「猜测确认」（载荷哈希）不比段头里明文的链值多泄露什么（链值本来就是明文操作的哈希）。
//!
//! 与中继件 `FRL4`、原生段 `FSG4` 互不误读：魔数不同；`open_any4` 不认本格式（作者签名的入口不会把它当作者签的段）。

use std::borrow::Cow;
use std::sync::Arc;

use super::op::{
    KIND_DEDUP, KIND_RETIRED_MEDIA_AT, MAX_OP_PAYLOAD, Op4, PurgeTargets, chain_next4,
    chain_next4_parts, native_allowed, read_purge_targets, write_purge_targets,
};
use super::segment::{
    MAX_BODY_RAW, NativeHeader, NativeItem, OpenNative, SignedDigest, TAG_OP, TAG_VOID, ZSTD_LEVEL,
    item_digest, op_digest_parts, read_chain, read_op_slot, stream_err, void_digest, write_op_slot,
};
use super::{bytes_min, iv_min, read_vv, uv_min};
use crate::sync2::codec::{DResult, DecodeError, Reader, Writer, ZstdWindow};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::Id;
use crate::sync2::keys::{CollectionKey, DeviceKey, verify};
use crate::sync2::segment::{Chain, SegmentError};
use crate::sync2::vv::{OpId, Vv};

pub const MAGIC: &[u8; 4] = b"FRX4";
pub const VERSION: u8 = 2;
/// 重切者签名原文的域前缀：与段签名、head 签名不会互相冒充。
const SIGN_DOMAIN: &[u8] = b"fushi-srs-recut/4\n";

const F_SEALED: u8 = 1;
const TAG_STUB: u8 = 2;

/// 被挖掉的一条操作：作者签名覆盖的那部分（信封、载荷哈希、清除目标）+ 重切者声称清掉它的 Purge。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stub {
    /// 信封（载荷为空：只用它的 `id` / `hlc` / `deps` / `kind` / `fmt`）。
    pub op: Op4,
    pub payload_hash: [u8; 32],
    /// 作者签进摘要的清除目标（[super::op::purge_targets_v1]）。
    pub targets: PurgeTargets,
    /// 清掉它的那条 Purge（重切者声称；读者核对）。
    pub purge: OpId,
}

impl Stub {
    /// 把一条完整的操作挖掉：留下摘要输入，记下清掉它的 [purge]。
    pub fn of(op: &Op4, purge: OpId) -> Stub {
        Stub {
            op: Op4 {
                payload: Arc::from(&[][..]),
                ..op.clone()
            },
            payload_hash: *blake3::hash(&op.payload).as_bytes(),
            targets: super::op::purge_targets_v1(op),
            purge,
        }
    }

    pub fn id(&self) -> OpId {
        self.op.id
    }

    /// 原操作在作者签名里的摘要。
    pub fn digest(&self) -> [u8; 32] {
        op_digest_parts(&self.op.envelope(), &self.payload_hash, &self.targets)
    }

    /// 原操作的那一环链值。
    pub fn chain_next(&self, prev: &Chain) -> Chain {
        chain_next4_parts(prev, &self.op.envelope(), &self.payload_hash)
    }

    /// 这条 Purge 管得到原操作：是同集合的 Purge、目标在清除目标里、原操作的作者写它时没见过 [purge]。
    /// [purge_target] = 那条 Purge 的 (种类, 实体)（调用方解好的）。
    pub fn covered_by(
        &self,
        purge_id: &OpId,
        purge_target: &(crate::sync2::op::EntKind, crate::sync2::id::Key),
    ) -> bool {
        let norm = (
            purge_target.0,
            crate::sync2::id::Key::of(&purge_target.1.text()),
        );
        *purge_id == self.purge
            && self.targets.contains(&norm)
            && super::op::purge_unseen_by(&self.op, purge_id)
    }

    /// 独立编码（本机存 `relay_stubs` 用）：`信封 | bytes(空) | 载荷哈希[32] | 清除目标 | purge device[16] | purge seq uv`。
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        self.op.write(&mut w);
        w.raw(&self.payload_hash);
        write_purge_targets(&mut w, &self.targets);
        self.purge.device.write(&mut w);
        w.uv(self.purge.seq);
        w.into_vec()
    }

    pub fn decode(bytes: &[u8]) -> DResult<Stub> {
        let mut r = Reader::new(bytes);
        let op = Op4::read(&mut r)?;
        if !op.payload.is_empty() {
            return Err(DecodeError("stub carries a payload"));
        }
        let payload_hash = read32(&mut r)?;
        let targets = read_purge_targets(&mut r)?;
        let purge = read_opid(&mut r)?;
        if !r.is_empty() {
            return Err(DecodeError("stub trailing bytes"));
        }
        Ok(Stub {
            op,
            payload_hash,
            targets,
            purge,
        })
    }

    /// 段里的剔除槽（`device` / `seq` 由位置给出）。
    fn write_slot(&self, w: &mut Writer) {
        w.iv(self.op.hlc.wall);
        w.uv(u64::from(self.op.hlc.logical));
        self.op.deps.write(w);
        w.uv(u64::from(self.op.kind));
        w.uv(u64::from(self.op.fmt));
        w.raw(&self.payload_hash);
        write_purge_targets(w, &self.targets);
        self.purge.device.write(w);
        w.uv(self.purge.seq);
    }

    fn read_slot(r: &mut Reader<'_>, id: OpId) -> DResult<Stub> {
        let wall = iv_min(r)?;
        let logical = u32::try_from(uv_min(r)?).map_err(|_| DecodeError("hlc logical"))?;
        let deps = read_vv(r)?;
        if deps.get(&id.device) != 0 {
            return Err(DecodeError("op deps name its own device"));
        }
        let kind = u16::try_from(uv_min(r)?).map_err(|_| DecodeError("op kind"))?;
        let fmt = u16::try_from(uv_min(r)?).map_err(|_| DecodeError("op fmt"))?;
        let payload_hash = read32(r)?;
        let targets = read_purge_targets(r)?;
        let purge = read_opid(r)?;
        Ok(Stub {
            op: Op4 {
                id,
                hlc: Hlc {
                    wall,
                    logical,
                    device: id.device,
                },
                deps: Arc::new(deps),
                kind,
                fmt,
                payload: Arc::from(&[][..]),
            },
            payload_hash,
            targets,
            purge,
        })
    }
}

fn read32(r: &mut Reader<'_>) -> DResult<[u8; 32]> {
    r.raw(32)?
        .try_into()
        .map_err(|_| DecodeError("truncated hash"))
}

fn read_opid(r: &mut Reader<'_>) -> DResult<OpId> {
    let device = Id::read(r)?;
    let seq = uv_min(r)?;
    if seq == 0 {
        return Err(DecodeError("purge seq 0"));
    }
    Ok(OpId { device, seq })
}

/// 重切件里的一项。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecutItem {
    /// 作者签过的原件。
    Op(Op4),
    /// 作者签的空洞（原段里就有）。
    Void { count: u64, chain_after: Chain },
    /// 重切者挖掉的一条操作。
    Stub(Stub),
}

impl RecutItem {
    pub fn span(&self) -> u64 {
        match self {
            RecutItem::Void { count, .. } => *count,
            _ => 1,
        }
    }

    /// 原段里这一项在作者签名里的摘要。
    fn digest(&self) -> [u8; 32] {
        match self {
            RecutItem::Op(op) => item_digest(&NativeItem::Op(op.clone())),
            RecutItem::Void { count, chain_after } => void_digest(*count, chain_after),
            RecutItem::Stub(s) => s.digest(),
        }
    }

    fn chain_next(&self, prev: &Chain) -> Chain {
        match self {
            RecutItem::Op(op) => chain_next4(prev, op),
            RecutItem::Void { chain_after, .. } => *chain_after,
            RecutItem::Stub(s) => s.chain_next(prev),
        }
    }
}

impl From<NativeItem> for RecutItem {
    fn from(item: NativeItem) -> RecutItem {
        match item {
            NativeItem::Op(op) => RecutItem::Op(op),
            NativeItem::Void { count, chain_after } => RecutItem::Void { count, chain_after },
        }
    }
}

/// 重切件的明文前缀（不验签、不解内层）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecutPrefix {
    /// 内层是否用所在位置的密钥封装。
    pub sealed: bool,
    /// 原段头（未验签前只能当提示用）。
    pub header: NativeHeader,
    /// 重切者（签名的设备）。
    pub recutter: Id,
}

/// 读前缀：`(前缀, 作者签名, 前缀字节长度 = 封装时的 AAD, 原段头字节)`。
fn read_prefix(bytes: &[u8]) -> Result<(RecutPrefix, [u8; 64], usize, &[u8]), SegmentError> {
    let mut r = Reader::new(bytes);
    if r.raw(4)? != MAGIC {
        return Err(SegmentError::Corrupt("recut magic".into()));
    }
    if r.u8()? != VERSION {
        return Err(SegmentError::Corrupt("recut version".into()));
    }
    let flags = r.u8()?;
    if flags & !F_SEALED != 0 {
        return Err(SegmentError::Corrupt("recut flags".into()));
    }
    let head = bytes_min(&mut r)?;
    let mut hr = Reader::new(head);
    let header = NativeHeader::read(&mut hr)?;
    if !hr.is_empty() {
        return Err(SegmentError::Corrupt("recut head trailing bytes".into()));
    }
    let author_sig: [u8; 64] = r
        .raw(64)?
        .try_into()
        .map_err(|_| SegmentError::Corrupt("recut author sig".into()))?;
    let recutter = Id::read(&mut r)?;
    let prefix = RecutPrefix {
        sealed: flags & F_SEALED != 0,
        header,
        recutter,
    };
    Ok((prefix, author_sig, r.pos, head))
}

/// 只读重切件的前缀（不验签、不解内层）。
pub fn peek_recut4(bytes: &[u8]) -> Result<RecutPrefix, SegmentError> {
    Ok(read_prefix(bytes)?.0)
}

fn recut_digest(head: &[u8], author_sig: &[u8; 64], recutter: &Id, compressed: &[u8]) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(SIGN_DOMAIN);
    h.update(head);
    h.update(author_sig);
    h.update(&recutter.0);
    h.update(compressed);
    *h.finalize().as_bytes()
}

fn head_bytes(header: &NativeHeader) -> Vec<u8> {
    let mut hw = Writer::new();
    header.write(&mut hw);
    hw.into_vec()
}

fn assemble(
    head: &[u8],
    author_sig: &[u8; 64],
    recutter: &Id,
    compressed: &[u8],
    sig: &[u8; 64],
    dst_key: Option<&CollectionKey>,
) -> Vec<u8> {
    let mut inner = Writer::with_capacity(compressed.len() + 80);
    inner.bytes(compressed);
    inner.raw(sig);
    let inner = inner.into_vec();
    let mut w = Writer::with_capacity(head.len() + inner.len() + 128);
    w.raw(MAGIC);
    w.u8(VERSION);
    w.u8(if dst_key.is_some() { F_SEALED } else { 0 });
    w.bytes(head);
    w.raw(author_sig);
    recutter.write(&mut w);
    let mut out = w.into_vec();
    let sealed = match dst_key {
        Some(k) => k.seal(&inner, &out),
        None => inner,
    };
    let mut w = Writer::with_capacity(sealed.len() + 8);
    w.bytes(&sealed);
    out.extend_from_slice(&w.into_vec());
    out
}

fn write_items(items: &[RecutItem]) -> Vec<u8> {
    let mut w = Writer::with_capacity(items.len() * 64);
    w.uv(items.len() as u64);
    let mut wall = 0i64;
    let mut deps: Option<&Arc<Vv>> = None;
    for item in items {
        match item {
            RecutItem::Op(op) => {
                w.u8(TAG_OP);
                write_op_slot(&mut w, op, wall, deps);
                wall = op.hlc.wall;
                deps = Some(&op.deps);
            }
            RecutItem::Void { count, chain_after } => {
                w.u8(TAG_VOID);
                w.uv(*count);
                w.raw(chain_after);
            }
            RecutItem::Stub(s) => {
                w.u8(TAG_STUB);
                s.write_slot(&mut w);
            }
        }
    }
    w.into_vec()
}

/// 解压、逐项解码（结构上的合规在 [check] 里核）。
fn read_items(compressed: &[u8], header: &NativeHeader) -> Result<Vec<RecutItem>, SegmentError> {
    let mut window = ZstdWindow::new(compressed)
        .map_err(stream_err)?
        .limit(MAX_BODY_RAW);
    let span = header.last + 1 - header.first;
    let n = window.parse(uv_min).map_err(stream_err)?;
    if n == 0 || n > span {
        return Err(SegmentError::Corrupt("recut item count".into()));
    }
    let mut out: Vec<RecutItem> = Vec::with_capacity(n as usize);
    let mut seq = header.first;
    let mut wall = 0i64;
    let mut deps: Option<Arc<Vv>> = None;
    for _ in 0..n {
        if seq > header.last {
            return Err(SegmentError::Corrupt(
                "recut items overrun the range".into(),
            ));
        }
        let id = OpId {
            device: header.device,
            seq,
        };
        let left = header.last + 1 - seq;
        let prev = deps.clone();
        let item = window
            .parse(|r| match r.u8()? {
                TAG_OP => Ok(RecutItem::Op(read_op_slot(
                    r,
                    id,
                    wall,
                    prev.as_ref(),
                    MAX_OP_PAYLOAD,
                )?)),
                TAG_VOID => {
                    let count = uv_min(r)?;
                    if count == 0 || count > left {
                        return Err(DecodeError("void count"));
                    }
                    Ok(RecutItem::Void {
                        count,
                        chain_after: read_chain(r)?,
                    })
                }
                TAG_STUB => Ok(RecutItem::Stub(Stub::read_slot(r, id)?)),
                _ => Err(DecodeError("recut item tag")),
            })
            .map_err(stream_err)?;
        if let RecutItem::Op(op) = &item {
            wall = op.hlc.wall;
            deps = Some(op.deps.clone());
        }
        seq += item.span();
        out.push(item);
    }
    if !window.at_end().map_err(stream_err)? {
        return Err(SegmentError::Corrupt("recut trailing bytes in body".into()));
    }
    Ok(out)
}

/// 结构核对（写读两侧同一份）：从 [header] 的 `first` 起首尾相接地盖满到 `last`，操作 / 剔除项是作者的、seq 对得上、
/// 原生日志允许的；作者签的空洞没有相邻的（作者写时已合并）；至少一个剔除项（没有剔除的段没有重切的理由，原样转发
/// 作者签的那份）；剔除项带着非空的清除目标与一条别的操作号的 Purge；逐条重算的链与段头的 `last_chain` 相同。
/// 交回作者签名的原文（[SignedDigest]）。
fn check(head: &[u8], header: &NativeHeader, items: &[RecutItem]) -> Result<[u8; 32], String> {
    if header.first == 0 || items.is_empty() {
        return Err("recut: empty segment".into());
    }
    let mut chain = header.prev_chain;
    let mut seq = header.first;
    let mut prev_void = false;
    let mut stubs = 0usize;
    let mut digest = SignedDigest::new(head);
    for item in items {
        match item {
            RecutItem::Op(op) => {
                own(header, seq, op)?;
                native_allowed(op)?;
                prev_void = false;
            }
            RecutItem::Stub(s) => {
                own(header, seq, &s.op)?;
                if s.op.fmt < super::op::BODY_FMT
                    || s.op.kind == KIND_RETIRED_MEDIA_AT
                    || s.op.kind == KIND_DEDUP
                {
                    return Err("recut: a stub of an op no native log carries".into());
                }
                if s.targets.is_empty() {
                    return Err("recut: a stub no purge can reach".into());
                }
                if s.purge == s.op.id {
                    return Err("recut: a stub purged by itself".into());
                }
                stubs += 1;
                prev_void = false;
            }
            RecutItem::Void { count, .. } => {
                if *count == 0 {
                    return Err("recut: empty void".into());
                }
                if prev_void {
                    return Err("recut: adjacent voids must be merged".into());
                }
                prev_void = true;
            }
        }
        chain = item.chain_next(&chain);
        digest.push(&item.digest());
        seq = seq.checked_add(item.span()).ok_or("recut: seq overflow")?;
    }
    if seq - 1 != header.last {
        return Err("recut: items do not cover the segment's range".into());
    }
    if stubs == 0 {
        return Err("recut: nothing stubbed".into());
    }
    if chain != header.last_chain {
        return Err("recut: chain does not end at the segment's last chain".into());
    }
    Ok(digest.finish())
}

fn own(header: &NativeHeader, seq: u64, op: &Op4) -> Result<(), String> {
    if op.id
        != (OpId {
            device: header.device,
            seq,
        })
        || op.hlc.device != header.device
        || op.deps.get(&header.device) != 0
    {
        return Err("recut: ops must be the author's contiguous seqs".into());
    }
    Ok(())
}

/// 重切一段：[header] / [author_sig] = 作者签的原段头与签名（区间、首尾链值不变），[items] = 原段的全部项，其中本机
/// 清除过的操作已换成剔除项（[stub_one]），[author_public] = 作者公钥（签之前先核作者签名对得上，签不出作者不认的件），
/// [recutter] / [recutter_id] = 本机的签名钥匙与设备 ID，[dst_key] = 目标位置的密钥（存进本机转发缓存时为 None）。
pub fn recut4(
    header: &NativeHeader,
    author_sig: &[u8; 64],
    items: &[RecutItem],
    author_public: &[u8; 32],
    recutter: &DeviceKey,
    recutter_id: Id,
    dst_key: Option<&CollectionKey>,
) -> Result<Vec<u8>, String> {
    let head = head_bytes(header);
    let digest = check(&head, header, items)?;
    if !verify(author_public, &digest, author_sig) {
        return Err("recut: the items are not what the author signed".into());
    }
    let raw = write_items(items);
    if raw.len() as u64 > MAX_BODY_RAW {
        return Err("recut: body over MAX_BODY_RAW".into());
    }
    let compressed =
        zstd::bulk::compress(&raw, ZSTD_LEVEL).map_err(|e| format!("recut compress: {e}"))?;
    let sig = recutter.sign(&recut_digest(&head, author_sig, &recutter_id, &compressed));
    Ok(assemble(
        &head,
        author_sig,
        &recutter_id,
        &compressed,
        &sig,
        dst_key,
    ))
}

/// [items] 拼成的重切件作者认不认：结构合规（[check]）且作者签名验得过。从本机日志拼的件签之前先问它
/// （`store/gen4/sync_state.rs` `recut_from_log`）。
pub fn author_signed(
    header: &NativeHeader,
    author_sig: &[u8; 64],
    items: &[RecutItem],
    author_public: &[u8; 32],
) -> bool {
    check(&head_bytes(header), header, items)
        .is_ok_and(|digest| verify(author_public, &digest, author_sig))
}

/// 验过两个签名、链与结构的重切件。
#[derive(Debug, Clone)]
pub struct OpenRecut<'a> {
    /// 作者签过的段头。
    pub header: NativeHeader,
    pub author_sig: [u8; 64],
    pub recutter: Id,
    /// 这份字节本身落盘时是否用所在位置的密钥封装（同 `OpenNative::stored_sealed`）。
    pub stored_sealed: bool,
    pub items: Vec<RecutItem>,
    compressed: Cow<'a, [u8]>,
    sig: [u8; 64],
}

impl OpenRecut<'_> {
    /// 读者落库用的项：剔除项落成一条的空洞（链值是原操作那一环，读者自己算的），连同它的剔除记录。
    pub fn landing_items(&self) -> Vec<(NativeItem, Option<Stub>)> {
        let mut chain = self.header.prev_chain;
        self.items
            .iter()
            .map(|item| {
                let after = item.chain_next(&chain);
                chain = after;
                match item {
                    RecutItem::Op(op) => (NativeItem::Op(op.clone()), None),
                    RecutItem::Void { count, chain_after } => (
                        NativeItem::Void {
                            count: *count,
                            chain_after: *chain_after,
                        },
                        None,
                    ),
                    RecutItem::Stub(s) => (
                        NativeItem::Void {
                            count: 1,
                            chain_after: after,
                        },
                        Some(s.clone()),
                    ),
                }
            })
            .collect()
    }
}

/// 解开、验**重切者**签名、结构、链与**作者**签名。[author_public] 是段头 `device` 的公钥，[recutter_public] 是前缀里
/// `recutter` 的公钥（调用方先按 [peek_recut4] 取设备、核对信任），[key] 是它所在位置的密钥。
pub fn open_recut4<'a>(
    bytes: &'a [u8],
    author_public: &[u8; 32],
    recutter_public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<OpenRecut<'a>, SegmentError> {
    let (prefix, author_sig, aad_len, head) = read_prefix(bytes)?;
    let mut r = Reader::new(&bytes[aad_len..]);
    let inner_raw = bytes_min(&mut r)?;
    if !r.is_empty() {
        return Err(SegmentError::Corrupt("recut trailing bytes".into()));
    }
    let inner: Cow<'a, [u8]> = if prefix.sealed {
        let k = key.ok_or(SegmentError::Undecryptable)?;
        Cow::Owned(
            k.open(inner_raw, &bytes[..aad_len])
                .ok_or(SegmentError::Undecryptable)?,
        )
    } else {
        Cow::Borrowed(inner_raw)
    };
    let (start, end, sig) = {
        let mut ir = Reader::new(&inner);
        let plain = bytes_min(&mut ir)?;
        let end = ir.pos;
        let start = end - plain.len();
        let sig: [u8; 64] = ir
            .raw(64)?
            .try_into()
            .map_err(|_| SegmentError::Corrupt("recut sig".into()))?;
        if !ir.is_empty() {
            return Err(SegmentError::Corrupt("recut inner trailing bytes".into()));
        }
        (start, end, sig)
    };
    if !verify(
        recutter_public,
        &recut_digest(head, &author_sig, &prefix.recutter, &inner[start..end]),
        &sig,
    ) {
        return Err(SegmentError::BadSignature);
    }
    let compressed: Cow<'a, [u8]> = match inner {
        Cow::Borrowed(b) => Cow::Borrowed(&b[start..end]),
        Cow::Owned(mut v) => {
            v.truncate(end);
            v.drain(..start);
            Cow::Owned(v)
        }
    };
    let items = read_items(&compressed, &prefix.header)?;
    let digest = match check(head, &prefix.header, &items) {
        Ok(d) => d,
        Err(m) if m.contains("chain") => return Err(SegmentError::ChainMismatch),
        Err(m) => return Err(SegmentError::Corrupt(m)),
    };
    if !verify(author_public, &digest, &author_sig) {
        return Err(SegmentError::BadSignature);
    }
    Ok(OpenRecut {
        header: prefix.header,
        author_sig,
        recutter: prefix.recutter,
        stored_sealed: prefix.sealed,
        items,
        compressed,
        sig,
    })
}

/// 换一把目标钥匙再包（两个签名都不变）。[src_key] = [bytes] 所在位置的密钥。
pub fn rewrap_recut4(
    bytes: &[u8],
    author_public: &[u8; 32],
    recutter_public: &[u8; 32],
    src_key: Option<&CollectionKey>,
    dst_key: Option<&CollectionKey>,
) -> Result<Vec<u8>, SegmentError> {
    let open = open_recut4(bytes, author_public, recutter_public, src_key)?;
    Ok(assemble(
        &head_bytes(&open.header),
        &open.author_sig,
        &open.recutter,
        &open.compressed,
        &open.sig,
        dst_key,
    ))
}

/// 测试与转发缓存核对共用的简写：前缀 + 读者落库用的项（剔除项落成一条的空洞）。
pub fn open_recut4_items(
    bytes: &[u8],
    author_public: &[u8; 32],
    recutter_public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<(RecutPrefix, Vec<NativeItem>), SegmentError> {
    let prefix = peek_recut4(bytes)?;
    let open = open_recut4(bytes, author_public, recutter_public, key)?;
    Ok((
        prefix,
        open.landing_items().into_iter().map(|(i, _)| i).collect(),
    ))
}

/// 作者签的一段（原生段 / 中继件）的项换成重切项：段头、作者签名与全部项，交 [stub_one] 挖。
pub fn from_native(open: &OpenNative<'_>) -> Result<Vec<RecutItem>, SegmentError> {
    open.verify()?
        .map(|i| i.map(RecutItem::from))
        .collect::<Result<Vec<RecutItem>, SegmentError>>()
}

/// 把 [items]（从 [first] 起）里 seq = [seq] 的那条操作换成剔除项（清掉它的是 [purge]）。那里已经不是完整的操作
/// （作者的空洞、已剔除）、或不在这段里 = None（不用重切）。
pub fn stub_one(items: &[RecutItem], first: u64, seq: u64, purge: OpId) -> Option<Vec<RecutItem>> {
    let mut at = first;
    let mut hit = false;
    let out = items
        .iter()
        .map(|item| {
            let here = at;
            at += item.span();
            match item {
                RecutItem::Op(op) if here == seq => {
                    hit = true;
                    RecutItem::Stub(Stub::of(op, purge))
                }
                other => other.clone(),
            }
        })
        .collect();
    hit.then_some(out)
}

/// 测试用：不做任何核对、按给定的段头、作者签名与项直接签一份重切件——恶意重切者能做到的全部（别的模块的测试用它
/// 造伪件，看读者拒不拒）。
#[cfg(test)]
pub(crate) fn sign_unchecked(
    header: &NativeHeader,
    author_sig: &[u8; 64],
    items: &[RecutItem],
    recutter: &DeviceKey,
    recutter_id: Id,
) -> Vec<u8> {
    let head = head_bytes(header);
    let compressed = zstd::bulk::compress(&write_items(items), ZSTD_LEVEL).unwrap();
    let sig = recutter.sign(&recut_digest(&head, author_sig, &recutter_id, &compressed));
    assemble(&head, author_sig, &recutter_id, &compressed, &sig, None)
}

/// 测试用：项的链（[RecutItem] 逐条重算，同读者）。
#[cfg(test)]
pub(crate) fn chain_through(prev: Chain, items: &[RecutItem]) -> Chain {
    items.iter().fold(prev, |c, i| i.chain_next(&c))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::op::tests::id;
    use crate::gen4::op::{Body4, purge_targets_v1};
    use crate::gen4::relay::{open_any4, wrap_relay4};
    use crate::gen4::segment::tests::{DEV, chain_of, coll, items_of, ops, signer};
    use crate::gen4::segment::{open_native, open_native_verified, pack_native};
    use crate::sync2::op::EntKind;

    fn k1() -> CollectionKey {
        CollectionKey([5; 32])
    }

    fn k2() -> CollectionKey {
        CollectionKey([6; 32])
    }

    /// 与作者（`segment::tests::signer`，种子 7）不同的钥匙：作者公钥验不过重切者签名。
    fn recutter() -> DeviceKey {
        DeviceKey::from_seed(&[0x5b; 32])
    }

    const RC: u8 = 0xb7;
    const PURGER: u8 = 0xe4;

    fn author() -> [u8; 32] {
        signer().public()
    }

    fn purge() -> OpId {
        OpId {
            device: id(PURGER),
            seq: 3,
        }
    }

    /// 原段（五条操作）、作者签名，与把第 [seq] 条挖掉之后的项。第 2 条是修改、第 4 条是加标签（有清除目标）。
    fn original_and_stubbed(seq: u64) -> (NativeHeader, [u8; 64], Vec<RecutItem>, Vec<RecutItem>) {
        let items = items_of(&ops());
        let (header, bytes) =
            pack_native(coll(), id(DEV), 1, &items, [0; 32], &signer(), None).unwrap();
        let open = open_native_verified(&bytes, &author(), None).unwrap();
        let sig = open.author_sig();
        let all = from_native(&open).unwrap();
        let stubbed = stub_one(&all, 1, seq, purge()).unwrap();
        (header, sig, all, stubbed)
    }

    fn cut(
        h: &NativeHeader,
        s: &[u8; 64],
        items: &[RecutItem],
        dk: Option<&CollectionKey>,
    ) -> Vec<u8> {
        recut4(h, s, items, &author(), &recutter(), id(RC), dk).unwrap()
    }

    fn open<'a>(
        bytes: &'a [u8],
        dk: Option<&CollectionKey>,
    ) -> Result<OpenRecut<'a>, SegmentError> {
        open_recut4(bytes, &author(), &recutter().public(), dk)
    }

    /// 重切后区间与段头不变，读出的项就是挖过的那些；明文 / 封装两种都对，换钥匙再包两个签名都不变。
    #[test]
    fn a_recut_keeps_the_range_and_round_trips_under_any_key() {
        for seq in [2, 4] {
            let (header, sig, _, stubbed) = original_and_stubbed(seq);
            for dk in [None, Some(&k1())] {
                let bytes = cut(&header, &sig, &stubbed, dk);
                assert!(bytes.starts_with(MAGIC));
                let p = peek_recut4(&bytes).unwrap();
                assert_eq!(
                    (p.sealed, &p.header, p.recutter),
                    (dk.is_some(), &header, id(RC))
                );
                let o = open(&bytes, dk).unwrap();
                assert_eq!(o.items, stubbed);
                assert_eq!(o.author_sig, sig);
                let again = rewrap_recut4(&bytes, &author(), &recutter().public(), dk, Some(&k2()))
                    .unwrap();
                assert_eq!(open(&again, Some(&k2())).unwrap().items, stubbed);
                let plain =
                    rewrap_recut4(&again, &author(), &recutter().public(), Some(&k2()), None)
                        .unwrap();
                assert_eq!(
                    plain,
                    cut(&header, &sig, &stubbed, None),
                    "the same bytes whatever hands it went through"
                );
            }
        }
    }

    /// 读者落库用的项：剔除项是一条的空洞，链值就是原操作那一环（不是重切者填的）。
    #[test]
    fn landing_items_chain_through_the_stubs() {
        let ops = ops();
        let (header, sig, _, stubbed) = original_and_stubbed(2);
        let bytes = cut(&header, &sig, &stubbed, None);
        let o = open(&bytes, None).unwrap();
        let land = o.landing_items();
        assert_eq!(land.len(), 5);
        assert_eq!(
            land[1].0,
            NativeItem::Void {
                count: 1,
                chain_after: chain_of([0; 32], &ops[..2]),
            }
        );
        assert_eq!(land[1].1.as_ref().map(Stub::id), Some(ops[1].id));
        assert_eq!(land[0].0, NativeItem::Op(ops[0].clone()));
    }

    /// 根治的核心：重切者换不了留下的任何一条操作（作者签名验不过），也造不出作者没签过的空洞、改不了剔除项的
    /// 清除目标，换不了段头（区间、链尾）。重切者自己的签名是好的也没用。
    #[test]
    fn the_author_signature_binds_every_kept_op_and_every_stub() {
        let ops = ops();
        let (header, sig, all, stubbed) = original_and_stubbed(2);
        // 绕开 recut4 的作者签名自检，按给定的项与段头直接签一份重切件（恶意重切者能做到的全部）。
        let forge = |h: &NativeHeader, items: &[RecutItem]| -> Vec<u8> {
            let head = head_bytes(h);
            let compressed = zstd::bulk::compress(&write_items(items), ZSTD_LEVEL).unwrap();
            let rs = recutter().sign(&recut_digest(&head, &sig, &id(RC), &compressed));
            assemble(&head, &sig, &id(RC), &compressed, &rs, None)
        };
        assert!(
            open(&forge(&header, &stubbed), None).is_ok(),
            "the honest one"
        );
        // 1. 留下的操作换成别的内容（同信封、载荷不同），链尾跟着改成新链的值：作者签名不认。
        let forged_op = crate::gen4::op::tests::op_of(
            id(DEV),
            1,
            &Body4::Entity {
                kind: EntKind::Note,
                id: crate::sync2::id::Key::Uuid(id(1)),
                data: r#"{"createdAt":999,"FORGED":1}"#.into(),
            },
        );
        assert_eq!(forged_op.envelope(), ops[0].envelope());
        let mut changed = stubbed.clone();
        changed[0] = RecutItem::Op(forged_op);
        let mut h = header.clone();
        h.last_chain = changed.iter().fold(h.prev_chain, |c, i| i.chain_next(&c));
        assert_eq!(
            open(&forge(&h, &changed), None).err(),
            Some(SegmentError::BadSignature)
        );
        // 链尾不改：链就对不上。
        assert_eq!(
            open(&forge(&header, &changed), None).err(),
            Some(SegmentError::ChainMismatch)
        );
        // 2. 一条操作换成「只带链值的重置空洞」：作者没签过这个空洞。
        let mut reset = stubbed.clone();
        reset[2] = RecutItem::Void {
            count: 1,
            chain_after: chain_of([0; 32], &ops[..3]),
        };
        assert_eq!(
            open(&forge(&header, &reset), None).err(),
            Some(SegmentError::BadSignature)
        );
        // 3. 剔除项的清除目标改成别的实体（好让一条不相干的 Purge 管得到它）：作者签进摘要的不是它。
        let mut retarget = stubbed.clone();
        if let RecutItem::Stub(s) = &mut retarget[1] {
            s.targets = [(EntKind::Deck, crate::sync2::id::Key::Uuid(id(0x77)))].into();
        }
        assert_eq!(
            open(&forge(&header, &retarget), None).err(),
            Some(SegmentError::BadSignature)
        );
        // 4. 段头的区间往后伸、链尾填新的（伪造作者没写到的 seq）：作者签名不认。
        let mut longer = all.clone();
        let mut extra = ops[4].clone();
        extra.id.seq = 6;
        extra.payload = Arc::from(&b"FUTURE"[..]);
        longer.push(RecutItem::Op(extra));
        let longer = stub_one(&longer, 1, 2, purge()).unwrap();
        let mut h6 = header.clone();
        h6.last = 6;
        h6.last_chain = longer.iter().fold(h6.prev_chain, |c, i| i.chain_next(&c));
        assert_eq!(
            open(&forge(&h6, &longer), None).err(),
            Some(SegmentError::BadSignature)
        );
        // 5. 剔除项换了声称的 Purge：不在作者签名里，作者签名照样验得过（Purge 由读者核对，`receive.rs`）。
        let mut other_purge = stubbed.clone();
        if let RecutItem::Stub(s) = &mut other_purge[1] {
            s.purge = OpId {
                device: id(0x31),
                seq: 9,
            };
        }
        assert!(open(&forge(&header, &other_purge), None).is_ok());
    }

    /// 重切件只认重切者的签名：作者公钥当重切者公钥验不过；内容被改（留着原签名）验不过；前缀里换重切者 ID 验不过；
    /// 作者签名的入口不认它。
    #[test]
    fn only_the_recutters_signature_opens_it() {
        let (header, sig, all, stubbed) = original_and_stubbed(2);
        let bytes = cut(&header, &sig, &stubbed, None);
        assert_eq!(
            open_recut4(&bytes, &author(), &author(), None).err(),
            Some(SegmentError::BadSignature)
        );
        assert!(open_any4(&bytes, &recutter().public(), None).is_err());
        assert!(wrap_relay4(&bytes, &recutter().public(), None, None).is_err());
        // 伪造体：把原段的内容原样塞进重切件、留着重切者对挖过版的签名。
        let (_, _, aad, _) = read_prefix(&bytes).unwrap();
        let rs: Vec<u8> = bytes[bytes.len() - 64..].to_vec();
        let mut fake = bytes[..aad].to_vec();
        let forged = zstd::bulk::compress(&write_items(&all), ZSTD_LEVEL).unwrap();
        let mut inner = Writer::new();
        inner.bytes(&forged);
        inner.raw(&rs);
        let mut w = Writer::new();
        w.bytes(&inner.into_vec());
        fake.extend_from_slice(&w.into_vec());
        assert_eq!(open(&fake, None).err(), Some(SegmentError::BadSignature));
        // 换重切者 ID：前缀里的 16 字节就在 AAD 末尾。
        let mut other = bytes.clone();
        other[aad - 1] ^= 1;
        assert_eq!(open(&other, None).err(), Some(SegmentError::BadSignature));
        // 封装的件没钥匙解不开，拿错钥匙同样。
        let sealed = cut(&header, &sig, &stubbed, Some(&k1()));
        assert_eq!(open(&sealed, None).err(), Some(SegmentError::Undecryptable));
        assert_eq!(
            open(&sealed, Some(&k2())).err(),
            Some(SegmentError::Undecryptable)
        );
    }

    /// 写的一侧拒：没有剔除（不用重切）、清除目标为空的操作（没有 Purge 管得到）、盖不满区间、操作不是作者的、
    /// 项不是作者签过的。
    #[test]
    fn recut_refuses_what_is_not_a_recut_of_that_segment() {
        let (header, sig, all, stubbed) = original_and_stubbed(4);
        let r = |h: &NativeHeader, i: &[RecutItem]| {
            recut4(h, &sig, i, &author(), &recutter(), id(RC), None)
        };
        assert!(r(&header, &all).is_err(), "nothing stubbed");
        // 第 1 条是身份记录：清除碰不到它。
        assert!(purge_targets_v1(&ops()[0]).is_empty());
        let entity = stub_one(&all, 1, 1, purge()).unwrap();
        assert!(r(&header, &entity).is_err(), "no purge reaches it");
        assert!(r(&header, &stubbed[..4]).is_err(), "range");
        let mut other = header.clone();
        other.device = id(0x99);
        assert!(r(&other, &stubbed).is_err(), "not the author's ops");
        let mut forged = stubbed.clone();
        if let RecutItem::Op(op) = &mut forged[0] {
            op.hlc.logical += 1;
        }
        let mut h = header.clone();
        h.last_chain = forged.iter().fold(h.prev_chain, |c, i| i.chain_next(&c));
        assert!(r(&h, &forged).is_err(), "not what the author signed");
        assert!(
            stub_one(&stubbed, 1, 4, purge()).is_none(),
            "already a stub"
        );
        assert!(
            stub_one(&stubbed, 1, 9, purge()).is_none(),
            "not in the segment"
        );
    }

    /// 作者自己签的空洞在重切件里原样留着（摘要在作者签名里），挖掉别的操作照样验得过。
    #[test]
    fn the_authors_own_voids_survive_a_recut() {
        let ops = ops();
        let items = vec![
            NativeItem::Op(ops[0].clone()),
            NativeItem::Op(ops[1].clone()),
            NativeItem::Void {
                count: 1,
                chain_after: chain_of([0; 32], &ops[..3]),
            },
            NativeItem::Op(ops[3].clone()),
            NativeItem::Op(ops[4].clone()),
        ];
        let (header, bytes) =
            pack_native(coll(), id(DEV), 1, &items, [0; 32], &signer(), None).unwrap();
        let o = open_native_verified(&bytes, &author(), None).unwrap();
        let all = from_native(&o).unwrap();
        let stubbed = stub_one(&all, 1, 4, purge()).unwrap();
        let piece = cut(&header, &o.author_sig(), &stubbed, None);
        let back = open(&piece, None).unwrap();
        assert_eq!(back.items, stubbed);
        assert_eq!(open_native(&bytes, &author(), None).unwrap().1, items);
    }

    /// 剔除记录的独立编码往返；清除判定：目标对得上、作者没见过、是它声称的那条。
    #[test]
    fn stubs_round_trip_and_know_which_purge_covers_them() {
        let ops = ops();
        let s = Stub::of(&ops[3], purge());
        assert_eq!(Stub::decode(&s.encode()).unwrap(), s);
        let Ok(Body4::TagAdd { note, .. }) = ops[3].body() else {
            panic!("tag op")
        };
        let target = (EntKind::Note, note.clone());
        assert!(s.covered_by(&purge(), &target));
        assert!(
            !s.covered_by(&purge(), &(EntKind::Deck, note)),
            "another entity"
        );
        let other = OpId {
            device: id(0x31),
            seq: 3,
        };
        assert!(!s.covered_by(&other, &target), "not the one it names");
        // 作者写它时已经见过这条 Purge（依赖里有）= 清除之后的写入，管不到。
        let mut seen = ops[3].clone();
        let mut deps = (*seen.deps).clone();
        deps.set(id(PURGER), 3);
        seen.deps = Arc::new(deps);
        assert!(!Stub::of(&seen, purge()).covered_by(&purge(), &target));
        let mut long = s.encode();
        long.push(0);
        assert!(Stub::decode(&long).is_err());
    }

    /// 解码严格：魔数 / 版本（上一版 `ver = 1` 一律拒）/ 标志位 / 尾随字节。
    #[test]
    fn open_is_strict() {
        let (header, sig, _, stubbed) = original_and_stubbed(2);
        let bytes = cut(&header, &sig, &stubbed, None);
        let mut b = bytes.clone();
        b[0] = b'Z';
        assert!(open(&b, None).is_err());
        let mut b = bytes.clone();
        b[4] = 1;
        assert_eq!(
            open(&b, None).err(),
            Some(SegmentError::Corrupt("recut version".into()))
        );
        let mut b = bytes.clone();
        b[5] = 2;
        assert!(open(&b, None).is_err());
        let mut b = bytes.clone();
        b.push(0);
        assert!(open(&b, None).is_err());
    }
}
