//! 协议 4 的原生段（设计 §3.3、§4.1）：一台设备连续 seq 的操作，成链、作者签名。
//!
//! ```text
//! 头（明文；签名覆盖；加密时作 AAD）
//!   "FSG4" | ver u8 = 1 | flags u8（bit0 加密；其余必须为 0）| collection[16] | device[16]
//!   | first uv | last uv | prev_chain[32] | last_chain[32]
//! 体  bytes( zstd( n_items uv | 槽 × n_items ) [再 XChaCha20-Poly1305：nonce[24] || 密文+tag] )
//! 尾  Ed25519( blake3(头 || 体) )[64]
//!
//! 槽  tag u8
//!   0 操作  wall 增量 iv（相对上一条操作；段里第一条相对 0）| logical uv
//!           | deps 标志 u8（0 = 与上一条操作相同，段里第一条不许用；1 + Vv）| kind uv | fmt uv | bytes(payload)
//!   1 空洞  count uv（>= 1）| chain_after[32]
//! ```
//!
//! 槽按 seq 升序首尾相接，覆盖的 seq 数之和必须等于 `last - first + 1`。段体只有一种字节形：varint 取最短形；
//! 相邻两个空洞槽拒绝（写者合并）；依赖向量与上一条**操作槽**（跨过中间的空洞）相同时必须写标志 0，wall 增量同样相对它。
//!
//! **空洞** = 这段 seq 的操作已彻底清除（协议 3 的骨架在这里不存在）。`chain_after` 是区间最后一条处的链值：
//! 去掉了信封就没法逐条重算，区间末链值是能把后面的操作接上的最小信息。验链时
//! 操作槽 `chain = chain_next4(chain, op)`，空洞槽 `chain = chain_after`，末尾必须等于 `last_chain`。
//!
//! - 空洞在段边界处截断：一次清除跨过已发布的切段点时，两个段各有一个空洞槽，前一个的 `chain_after` 就是那个段头的
//!   `last_chain`（段头的首尾链值不因清除而变，文件名也不变）。
//! - 空洞处链校验是「重置」而不是「重算」：空洞之前的操作对段尾链值没有承诺，整段的真实性靠**作者的签名**。
//!   所以含空洞的段只能由作者签出；任何「非作者重新打包、靠链接到作者签过的端点来验证」的形态（协议 3 的转发件那种）
//!   都不能含空洞——非作者只能原样转发作者的字节。
//!
//! 与协议 3 的段（魔数 `FSG2`）不通用：协议 3 的解码器在魔数处就拒绝本文件，本文件的解码器同样拒绝 `FSG2`。
//! 原生段里不许出现承袭专属的内容（[super::op::native_allowed]）：写时报错，读到判段损坏。

use std::borrow::Cow;
use std::sync::Arc;

use super::op::{Op4, chain_next4, native_allowed, read_deps, read_kind_fmt};
use super::{bytes_min, iv_min, uv_min};
use crate::sync2::codec::{DResult, DecodeError, Reader, StreamError, Writer, ZstdWindow};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::Id;
use crate::sync2::keys::{CollectionKey, DeviceKey, verify};
use crate::sync2::segment::{Chain, SegmentError, chain_tag, segment_file_name};
use crate::sync2::vv::{OpId, Vv};

pub const MAGIC: &[u8; 4] = b"FSG4";
pub const VERSION: u8 = 1;
/// 段体的 zstd 级别。压缩输出不是契约（解码方向才是）；换级别不改格式。
pub const ZSTD_LEVEL: i32 = 3;
/// 校验一段时留在内存里的操作上限（载荷字节 + 每条固定开销）；超过的第二遍流式解。
pub const KEEP_RAW_BYTES: u64 = 16 * 1024 * 1024;

const F_ENCRYPTED: u8 = 1;
const TAG_OP: u8 = 0;
const TAG_VOID: u8 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeHeader {
    pub encrypted: bool,
    pub collection: Id,
    pub device: Id,
    pub first: u64,
    pub last: u64,
    pub prev_chain: Chain,
    pub last_chain: Chain,
}

impl NativeHeader {
    fn write(&self, w: &mut Writer) {
        w.raw(MAGIC);
        w.u8(VERSION);
        w.u8(if self.encrypted { F_ENCRYPTED } else { 0 });
        self.collection.write(w);
        self.device.write(w);
        w.uv(self.first);
        w.uv(self.last);
        w.raw(&self.prev_chain);
        w.raw(&self.last_chain);
    }

    fn read(r: &mut Reader<'_>) -> DResult<NativeHeader> {
        let flags = read_magic(r, MAGIC, VERSION)?;
        let collection = Id::read(r)?;
        let device = Id::read(r)?;
        let (first, last) = read_range(r)?;
        Ok(NativeHeader {
            encrypted: flags & F_ENCRYPTED != 0,
            collection,
            device,
            first,
            last,
            prev_chain: read_chain(r)?,
            last_chain: read_chain(r)?,
        })
    }

    /// 文件名：与协议 3 同形（`seg-<first>-<last>-<链尾标签>.bin`；设计 §4.1 前缀不变）。
    pub fn file_name(&self) -> String {
        segment_file_name(self.first, self.last, &chain_tag(&self.last_chain))
    }
}

/// 魔数 + 版本 + 标志位（只认 bit0）。
pub(crate) fn read_magic(r: &mut Reader<'_>, magic: &[u8; 4], version: u8) -> DResult<u8> {
    if r.raw(4)? != magic {
        return Err(DecodeError("segment magic"));
    }
    if r.u8()? != version {
        return Err(DecodeError("segment version"));
    }
    let flags = r.u8()?;
    if flags & !F_ENCRYPTED != 0 {
        return Err(DecodeError("segment flags"));
    }
    Ok(flags)
}

pub(crate) fn read_range(r: &mut Reader<'_>) -> DResult<(u64, u64)> {
    let first = uv_min(r)?;
    let last = uv_min(r)?;
    if first == 0 || last < first {
        return Err(DecodeError("segment range"));
    }
    Ok((first, last))
}

pub(crate) fn read_chain(r: &mut Reader<'_>) -> DResult<Chain> {
    r.raw(32)?.try_into().map_err(|_| DecodeError("chain"))
}

/// 流读错误 → 段损坏（解码错误只留原因，与读段头时的报法一致）。
pub(crate) fn stream_err(e: StreamError) -> SegmentError {
    match e {
        StreamError::Decode(e) => SegmentError::Corrupt(e.0.to_owned()),
        StreamError::Zstd(m) => SegmentError::Corrupt(format!("zstd: {m}")),
    }
}

/// 段里的一项。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NativeItem {
    Op(Op4),
    /// [count] 条已清除的操作；[chain_after] 是其中最后一条处的链值。
    Void {
        count: u64,
        chain_after: Chain,
    },
}

impl NativeItem {
    /// 占多少个 seq。
    pub fn span(&self) -> u64 {
        match self {
            NativeItem::Op(_) => 1,
            NativeItem::Void { count, .. } => *count,
        }
    }
}

/// 写一条操作槽的公共部分（原生段与承袭段相同）。
pub(crate) fn write_op_slot(w: &mut Writer, op: &Op4, prev_wall: i64, prev_deps: Option<&Arc<Vv>>) {
    w.iv(op.hlc.wall.wrapping_sub(prev_wall));
    w.uv(u64::from(op.hlc.logical));
    if prev_deps.is_some_and(|p| Arc::ptr_eq(p, &op.deps) || **p == *op.deps) {
        w.u8(0);
    } else {
        w.u8(1);
        op.deps.write(w);
    }
    w.uv(u64::from(op.kind));
    w.uv(u64::from(op.fmt));
    w.bytes(&op.payload);
}

pub(crate) fn read_op_slot(
    r: &mut Reader<'_>,
    id: OpId,
    prev_wall: i64,
    prev_deps: Option<&Arc<Vv>>,
) -> DResult<Op4> {
    let wall = prev_wall.wrapping_add(iv_min(r)?);
    let logical = u32::try_from(uv_min(r)?).map_err(|_| DecodeError("hlc logical"))?;
    let deps = match (r.u8()?, prev_deps) {
        (0, Some(p)) => p.clone(),
        (1, prev) => {
            let deps = read_deps(r, id.device)?;
            if prev.is_some_and(|p| **p == deps) {
                return Err(DecodeError("deps repeated in full"));
            }
            Arc::new(deps)
        }
        _ => return Err(DecodeError("deps flag")),
    };
    let (kind, fmt) = read_kind_fmt(r)?;
    Ok(Op4 {
        id,
        hlc: Hlc {
            wall,
            logical,
            device: id.device,
        },
        deps,
        kind,
        fmt,
        payload: bytes_min(r)?.into(),
    })
}

fn write_body(items: &[NativeItem]) -> Vec<u8> {
    let mut w = Writer::with_capacity(items.len() * 48);
    w.uv(items.len() as u64);
    let mut wall = 0i64;
    let mut deps: Option<&Arc<Vv>> = None;
    for item in items {
        match item {
            NativeItem::Op(op) => {
                w.u8(TAG_OP);
                write_op_slot(&mut w, op, wall, deps);
                wall = op.hlc.wall;
                deps = Some(&op.deps);
            }
            NativeItem::Void { count, chain_after } => {
                w.u8(TAG_VOID);
                w.uv(*count);
                w.raw(chain_after);
            }
        }
    }
    w.into_vec()
}

/// 头 + 体（压缩、可选加密）+ 签名。原生段与承袭段共用。
pub(crate) fn seal(
    head_bytes: Vec<u8>,
    raw_body: &[u8],
    signer: &DeviceKey,
    key: Option<&CollectionKey>,
) -> Result<Vec<u8>, String> {
    let compressed =
        zstd::bulk::compress(raw_body, ZSTD_LEVEL).map_err(|e| format!("segment compress: {e}"))?;
    let body = match key {
        Some(k) => k.seal(&compressed, &head_bytes),
        None => compressed,
    };
    let mut signed = blake3::Hasher::new();
    signed.update(&head_bytes);
    signed.update(&body);
    let sig = signer.sign(signed.finalize().as_bytes());
    let mut w = Writer::with_capacity(head_bytes.len() + body.len() + 80);
    w.raw(&head_bytes);
    w.bytes(&body);
    w.raw(&sig);
    Ok(w.into_vec())
}

/// 验签、解密，交回压缩的段体。[r] 停在头之后。
pub(crate) fn unseal<'a>(
    bytes: &'a [u8],
    mut r: Reader<'a>,
    encrypted: bool,
    public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<Cow<'a, [u8]>, SegmentError> {
    let head_len = r.pos;
    let body = bytes_min(&mut r)?;
    let sig: [u8; 64] = r
        .raw(64)?
        .try_into()
        .map_err(|_| SegmentError::Corrupt("sig".into()))?;
    if !r.is_empty() {
        return Err(SegmentError::Corrupt("trailing bytes".into()));
    }
    let mut signed = blake3::Hasher::new();
    signed.update(&bytes[..head_len]);
    signed.update(body);
    if !verify(public, signed.finalize().as_bytes(), &sig) {
        return Err(SegmentError::BadSignature);
    }
    if !encrypted {
        return Ok(Cow::Borrowed(body));
    }
    let k = key.ok_or(SegmentError::Undecryptable)?;
    Ok(Cow::Owned(
        k.open(body, &bytes[..head_len])
            .ok_or(SegmentError::Undecryptable)?,
    ))
}

/// 打包一段。[items] 从 [first] 起首尾相接；其中的操作必须是 [device] 的、seq 对得上；[prev_chain] 是
/// `first - 1` 处的链值。
pub fn pack_native(
    collection: Id,
    device: Id,
    first: u64,
    items: &[NativeItem],
    prev_chain: Chain,
    signer: &DeviceKey,
    key: Option<&CollectionKey>,
) -> Result<(NativeHeader, Vec<u8>), String> {
    if first == 0 || items.is_empty() {
        return Err("empty segment".into());
    }
    let mut chain = prev_chain;
    let mut seq = first;
    let mut prev_void = false;
    for item in items {
        match item {
            NativeItem::Op(op) => {
                if op.id != (OpId { device, seq }) || op.hlc.device != device {
                    return Err("segment ops must be one device's contiguous seqs".into());
                }
                native_allowed(op)?;
                chain = chain_next4(&chain, op);
                prev_void = false;
            }
            NativeItem::Void { count, chain_after } => {
                if *count == 0 {
                    return Err("empty void".into());
                }
                if prev_void {
                    return Err("adjacent voids must be merged".into());
                }
                chain = *chain_after;
                prev_void = true;
            }
        }
        seq = seq.checked_add(item.span()).ok_or("segment seq overflow")?;
    }
    let header = NativeHeader {
        encrypted: key.is_some(),
        collection,
        device,
        first,
        last: seq - 1,
        prev_chain,
        last_chain: chain,
    };
    let mut hw = Writer::new();
    header.write(&mut hw);
    let bytes = seal(hw.into_vec(), &write_body(items), signer, key)?;
    Ok((header, bytes))
}

/// 只读段头（不验签、不解体）。
pub fn peek_native_header(bytes: &[u8]) -> Result<NativeHeader, SegmentError> {
    Ok(NativeHeader::read(&mut Reader::new(bytes))?)
}

/// 流式解开的段体：边解压边逐项解码，不随段的解压后体积增长。格式错时产出一次 `Err` 后结束。
pub struct ItemStream<'s> {
    window: ZstdWindow<'s>,
    device: Id,
    last: u64,
    /// 段体开头声明的项数（读第一项之前取）。
    n: Option<u64>,
    i: u64,
    seq: u64,
    wall: i64,
    deps: Option<Arc<Vv>>,
    prev_void: bool,
    done: bool,
}

impl<'s> ItemStream<'s> {
    fn new(compressed: &'s [u8], header: &NativeHeader) -> Result<ItemStream<'s>, SegmentError> {
        Ok(ItemStream {
            window: ZstdWindow::new(compressed).map_err(stream_err)?,
            device: header.device,
            last: header.last,
            n: None,
            i: 0,
            seq: header.first,
            wall: 0,
            deps: None,
            prev_void: false,
            done: false,
        })
    }

    fn step(&mut self) -> Result<Option<NativeItem>, SegmentError> {
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
        let item = self
            .window
            .parse(|r| match r.u8()? {
                TAG_OP => Ok(NativeItem::Op(read_op_slot(r, id, wall, deps.as_ref())?)),
                TAG_VOID => {
                    let count = uv_min(r)?;
                    if count == 0 || count > left {
                        return Err(DecodeError("void count"));
                    }
                    if prev_void {
                        return Err(DecodeError("adjacent voids"));
                    }
                    Ok(NativeItem::Void {
                        count,
                        chain_after: read_chain(r)?,
                    })
                }
                _ => Err(DecodeError("segment item tag")),
            })
            .map_err(stream_err)?;
        match &item {
            NativeItem::Op(op) => {
                native_allowed(op).map_err(|m| SegmentError::Corrupt(m.to_owned()))?;
                self.wall = op.hlc.wall;
                self.deps = Some(op.deps.clone());
                self.prev_void = false;
            }
            NativeItem::Void { .. } => self.prev_void = true,
        }
        self.seq += item.span();
        self.i += 1;
        Ok(Some(item))
    }
}

impl Iterator for ItemStream<'_> {
    type Item = Result<NativeItem, SegmentError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        let r = self.step();
        self.done = !matches!(r, Ok(Some(_)));
        r.transpose()
    }
}

/// 验过签、解过密的段：段体仍是压缩的，按需流式解开。
pub struct OpenNative<'a> {
    pub header: NativeHeader,
    compressed: Cow<'a, [u8]>,
}

/// [OpenNative::verify] 的结果：链已对上的全部项，按 seq 升序。
pub enum VerifiedNative<'a> {
    Whole(std::vec::IntoIter<NativeItem>),
    Stream(ItemStream<'a>),
}

impl Iterator for VerifiedNative<'_> {
    type Item = Result<NativeItem, SegmentError>;

    fn next(&mut self) -> Option<Self::Item> {
        match self {
            VerifiedNative::Whole(items) => items.next().map(Ok),
            VerifiedNative::Stream(s) => s.next(),
        }
    }
}

impl OpenNative<'_> {
    /// 流式解码，**不**重算链。
    pub fn items(&self) -> Result<ItemStream<'_>, SegmentError> {
        ItemStream::new(&self.compressed, &self.header)
    }

    /// 流式解一遍、重算链，链对上才交回。不超过 [KEEP_RAW_BYTES] 的段直接交回这一遍解出的，超过的交回第二遍的流：
    /// 不会先投出半段链对不上的操作，内存峰值也不随段的解压后体积增长。
    pub fn verify(&self) -> Result<VerifiedNative<'_>, SegmentError> {
        let mut chain = self.header.prev_chain;
        let mut kept: Option<Vec<NativeItem>> = Some(Vec::new());
        let mut kept_raw: u64 = 0;
        for item in self.items()? {
            let item = item?;
            match &item {
                NativeItem::Op(op) => {
                    chain = chain_next4(&chain, op);
                    kept_raw += op.payload.len() as u64 + 24;
                }
                NativeItem::Void { chain_after, .. } => {
                    chain = *chain_after;
                    kept_raw += 40;
                }
            }
            if let Some(k) = kept.as_mut() {
                if kept_raw > KEEP_RAW_BYTES {
                    kept = None;
                } else {
                    k.push(item);
                }
            }
        }
        if chain != self.header.last_chain {
            return Err(SegmentError::ChainMismatch);
        }
        Ok(match kept {
            Some(items) => VerifiedNative::Whole(items.into_iter()),
            None => VerifiedNative::Stream(self.items()?),
        })
    }
}

/// 验签、解密一段（不解压）。[public] 是作者（段头的 `device`）的公钥。
pub fn open_native_verified<'a>(
    bytes: &'a [u8],
    public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<OpenNative<'a>, SegmentError> {
    let mut r = Reader::new(bytes);
    let header = NativeHeader::read(&mut r)?;
    let compressed = unseal(bytes, r, header.encrypted, public, key)?;
    Ok(OpenNative { header, compressed })
}

/// 校验并整段解开（签名 → 解密 → 解压 → 解码 → 重算链），全部放进内存。给测试这类已知小段的场合。
pub fn open_native(
    bytes: &[u8],
    public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<(NativeHeader, Vec<NativeItem>), SegmentError> {
    let seg = open_native_verified(bytes, public, key)?;
    let items = seg
        .verify()?
        .collect::<Result<Vec<NativeItem>, SegmentError>>()?;
    Ok((seg.header, items))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::gen4::op::tests::{id, imported_log, native_edit, op_of, sample_log};
    use crate::gen4::op::{BODY_FMT, Body4, Edit4, Join4, KIND_RETIRED_MEDIA_AT};
    use crate::gen4::stamp::tests::typical;
    use crate::gen4::{golden, unhex};
    use crate::sync2::id::Key;
    use crate::sync2::op as v3op;
    use crate::sync2::segment as v3;

    pub fn signer() -> DeviceKey {
        DeviceKey::from_seed(&[7; 32])
    }

    pub fn coll() -> Id {
        id(0xc0)
    }

    const DEV: u8 = 0xa1;

    fn bodies() -> Vec<Body4> {
        vec![
            Body4::Entity {
                kind: v3op::EntKind::Note,
                id: Key::Uuid(id(1)),
                data: r#"{"createdAt":1}"#.into(),
            },
            Body4::Edit(native_edit()),
            Body4::Log(sample_log()),
            Body4::TagAdd {
                note: Key::Uuid(id(1)),
                tag: "t".into(),
            },
            Body4::Join(Join4 {
                from: id(0xb0),
                dir: "b".into(),
                salts: vec!["s".into()],
            }),
        ]
    }

    /// seq 1..=5 的操作，后面两条共用同一个依赖向量（走「同上一条」的标志）。
    fn ops() -> Vec<Op4> {
        let mut out: Vec<Op4> = bodies()
            .iter()
            .enumerate()
            .map(|(i, b)| op_of(id(DEV), i as u64 + 1, b))
            .collect();
        let mut deps = Vv::new();
        deps.set(id(0xd2), 9);
        out[3].deps = Arc::new(deps);
        out[4].deps = out[3].deps.clone();
        out
    }

    fn chain_of(prev: Chain, ops: &[Op4]) -> Chain {
        ops.iter().fold(prev, |c, op| chain_next4(&c, op))
    }

    fn items_of(ops: &[Op4]) -> Vec<NativeItem> {
        ops.iter().cloned().map(NativeItem::Op).collect()
    }

    #[test]
    fn round_trip_plain_and_encrypted() {
        let ops = ops();
        let key = CollectionKey([3; 32]);
        for k in [None, Some(&key)] {
            let (header, bytes) =
                pack_native(coll(), id(DEV), 1, &items_of(&ops), [0; 32], &signer(), k).unwrap();
            assert_eq!(header.encrypted, k.is_some());
            assert_eq!((header.first, header.last), (1, 5));
            assert_eq!(header.last_chain, chain_of([0; 32], &ops));
            assert_eq!(peek_native_header(&bytes).unwrap(), header);
            let (h2, items) = open_native(&bytes, &signer().public(), k).unwrap();
            assert_eq!(h2, header);
            assert_eq!(items, items_of(&ops));
        }
    }

    #[test]
    fn voids_keep_the_chain_verifiable() {
        let ops = ops();
        // 1 活、2–3 清除、4 活、5 清除。
        let c1 = chain_of([0; 32], &ops[..1]);
        let c3 = chain_of(c1, &ops[1..3]);
        let c4 = chain_of(c3, &ops[3..4]);
        let c5 = chain_of(c4, &ops[4..5]);
        let items = vec![
            NativeItem::Op(ops[0].clone()),
            NativeItem::Void {
                count: 2,
                chain_after: c3,
            },
            NativeItem::Op(ops[3].clone()),
            NativeItem::Void {
                count: 1,
                chain_after: c5,
            },
        ];
        let (header, bytes) =
            pack_native(coll(), id(DEV), 1, &items, [0; 32], &signer(), None).unwrap();
        // 链尾与没清除时相同：清除不改链。
        assert_eq!(header.last_chain, chain_of([0; 32], &ops));
        assert_eq!(header.last, 5);
        let (_, back) = open_native(&bytes, &signer().public(), None).unwrap();
        assert_eq!(back, items);
        // 整段都是空洞也行（清除到只剩位置）。
        let all = vec![NativeItem::Void {
            count: 5,
            chain_after: c5,
        }];
        let (h, bytes) = pack_native(coll(), id(DEV), 1, &all, [0; 32], &signer(), None).unwrap();
        assert_eq!((h.first, h.last, h.last_chain), (1, 5, c5));
        assert_eq!(
            open_native(&bytes, &signer().public(), None).unwrap().1,
            all
        );
        // 空洞的链值是签名者的陈述，读侧验不了（内容已经没了）：写错了，后面的操作从错的值接下去，链尾跟着变。
        // 所以含空洞的段只能由作者签（见文件头）。
        let mut wrong = items[..3].to_vec();
        wrong[1] = NativeItem::Void {
            count: 2,
            chain_after: [9; 32],
        };
        let (h, bytes) = pack_native(coll(), id(DEV), 1, &wrong, [0; 32], &signer(), None).unwrap();
        assert_eq!(h.last, 4);
        assert_ne!(h.last_chain, c4);
        assert!(open_native(&bytes, &signer().public(), None).is_ok());
    }

    #[test]
    fn pack_refuses_malformed_input() {
        let ops = ops();
        let pack = |first: u64, items: &[NativeItem]| {
            pack_native(coll(), id(DEV), first, items, [0; 32], &signer(), None)
        };
        assert!(pack(1, &[]).is_err());
        assert!(pack(0, &items_of(&ops)).is_err());
        assert!(pack(2, &items_of(&ops)).is_err(), "seq 对不上");
        let mut gap = items_of(&ops);
        gap.remove(1);
        assert!(pack(1, &gap).is_err());
        let void = NativeItem::Void {
            count: 1,
            chain_after: [1; 32],
        };
        assert!(pack(1, &[void.clone(), void.clone()]).is_err(), "相邻空洞");
        assert!(
            pack(
                1,
                &[NativeItem::Void {
                    count: 0,
                    chain_after: [1; 32]
                }]
            )
            .is_err()
        );
        // 承袭专属的内容。
        let stamped = op_of(
            id(DEV),
            1,
            &Body4::Edit(Edit4 {
                stamp: Some(typical()),
                ..native_edit()
            }),
        );
        assert!(pack(1, &[NativeItem::Op(stamped)]).is_err());
        let dedup = op_of(id(DEV), 1, &Body4::Dedup { pairs: vec![] });
        assert!(pack(1, &[NativeItem::Op(dedup)]).is_err());
        let retired = Op4 {
            kind: KIND_RETIRED_MEDIA_AT,
            ..op_of(id(DEV), 1, &Body4::Unknown)
        };
        assert!(pack(1, &[NativeItem::Op(retired)]).is_err());
        let old = Op4 {
            fmt: 1,
            ..ops[0].clone()
        };
        assert!(pack(1, &[NativeItem::Op(old)]).is_err());
        // 别的设备的操作。
        let other = op_of(id(0xee), 1, &bodies()[0]);
        assert!(pack(1, &[NativeItem::Op(other)]).is_err());
    }

    /// 绕过 [pack_native] 的检查，按给定的头与段体拼一段（签名有效）。
    pub fn assemble(
        header: &NativeHeader,
        raw_body: &[u8],
        key: Option<&CollectionKey>,
    ) -> Vec<u8> {
        let mut hw = Writer::new();
        header.write(&mut hw);
        seal(hw.into_vec(), raw_body, &signer(), key).unwrap()
    }

    fn header_for(ops: &[Op4], first: u64, last: u64) -> NativeHeader {
        NativeHeader {
            encrypted: false,
            collection: coll(),
            device: id(DEV),
            first,
            last,
            prev_chain: [0; 32],
            last_chain: chain_of([0; 32], ops),
        }
    }

    fn open_err(bytes: &[u8]) -> SegmentError {
        open_native(bytes, &signer().public(), None).unwrap_err()
    }

    #[test]
    fn open_rejects_tampering() {
        let ops = ops();
        let key = CollectionKey([3; 32]);
        let (_, bytes) = pack_native(
            coll(),
            id(DEV),
            1,
            &items_of(&ops),
            [0; 32],
            &signer(),
            None,
        )
        .unwrap();
        // 换签名者。
        assert_eq!(
            open_native(&bytes, &DeviceKey::from_seed(&[8; 32]).public(), None).unwrap_err(),
            SegmentError::BadSignature
        );
        // 改头、改体、改尾的任何一个字节。
        for at in [5, 40, bytes.len() - 70, bytes.len() - 1] {
            let mut bad = bytes.clone();
            bad[at] ^= 1;
            assert!(
                open_native(&bad, &signer().public(), None).is_err(),
                "byte {at}"
            );
        }
        let mut long = bytes.clone();
        long.push(0);
        assert_eq!(
            open_err(&long),
            SegmentError::Corrupt("trailing bytes".into())
        );
        assert!(open_native(&bytes[..bytes.len() - 1], &signer().public(), None).is_err());
        // 加密段：没密钥 / 密钥不对。
        let (_, sealed) = pack_native(
            coll(),
            id(DEV),
            1,
            &items_of(&ops),
            [0; 32],
            &signer(),
            Some(&key),
        )
        .unwrap();
        assert_eq!(
            open_native(&sealed, &signer().public(), None).unwrap_err(),
            SegmentError::Undecryptable
        );
        assert_eq!(
            open_native(&sealed, &signer().public(), Some(&CollectionKey([4; 32]))).unwrap_err(),
            SegmentError::Undecryptable
        );
        // 链尾写错（签名有效）：链对不上。
        let mut h = header_for(&ops, 1, 5);
        h.last_chain = [1; 32];
        assert_eq!(
            open_err(&assemble(&h, &write_body(&items_of(&ops)), None)),
            SegmentError::ChainMismatch
        );
        // 不认识的标志位、不认识的版本。
        let good = assemble(&header_for(&ops, 1, 5), &write_body(&items_of(&ops)), None);
        assert!(open_native(&good, &signer().public(), None).is_ok());
        let mut flags = good.clone();
        flags[5] = 2;
        assert_eq!(
            open_err(&flags),
            SegmentError::Corrupt("segment flags".into())
        );
        let mut ver = good.clone();
        ver[4] = 2;
        assert_eq!(
            open_err(&ver),
            SegmentError::Corrupt("segment version".into())
        );
    }

    #[test]
    fn open_rejects_bodies_that_do_not_fit_the_header() {
        let ops = ops();
        let body = write_body(&items_of(&ops));
        // 头说 1..=6，体只有 5 条；头说 1..=4，体有 5 条。
        assert!(matches!(
            open_err(&assemble(&header_for(&ops, 1, 6), &body, None)),
            SegmentError::Corrupt(_)
        ));
        assert!(matches!(
            open_err(&assemble(&header_for(&ops, 1, 4), &body, None)),
            SegmentError::Corrupt(_)
        ));
        // 体后面多出字节。
        let mut long = body.clone();
        long.push(0);
        assert_eq!(
            open_err(&assemble(&header_for(&ops, 1, 5), &long, None)),
            SegmentError::Corrupt("trailing bytes in segment body".into())
        );
        // 相邻空洞、空洞条数 0、第一条操作就用「同上一条依赖」。
        let void = |count: u64| {
            let mut w = Writer::new();
            w.u8(TAG_VOID);
            w.uv(count);
            w.raw(&[5; 32]);
            w.into_vec()
        };
        let mut h = header_for(&ops, 1, 2);
        h.last_chain = [5; 32];
        let two = [vec![2u8], void(1), void(1)].concat();
        assert_eq!(
            open_err(&assemble(&h, &two, None)),
            SegmentError::Corrupt("adjacent voids".into())
        );
        let zero = [vec![1u8], void(0)].concat();
        assert_eq!(
            open_err(&assemble(&h, &zero, None)),
            SegmentError::Corrupt("void count".into())
        );
        let merged = [vec![1u8], void(2)].concat();
        assert!(open_native(&assemble(&h, &merged, None), &signer().public(), None).is_ok());
        let mut w = Writer::new();
        w.uv(1);
        w.u8(TAG_OP);
        w.iv(5);
        w.uv(0);
        w.u8(0);
        assert_eq!(
            open_err(&assemble(&header_for(&ops, 1, 1), &w.into_vec(), None)),
            SegmentError::Corrupt("deps flag".into())
        );
        // 不是 zstd。
        let mut hw = Writer::new();
        header_for(&ops, 1, 5).write(&mut hw);
        let head = hw.into_vec();
        let mut signed = blake3::Hasher::new();
        signed.update(&head);
        signed.update(b"not zstd");
        let mut w = Writer::new();
        w.raw(&head);
        w.bytes(b"not zstd");
        w.raw(&signer().sign(signed.finalize().as_bytes()));
        assert!(matches!(open_err(&w.into_vec()), SegmentError::Corrupt(_)));
    }

    /// 读侧同样不收承袭专属的内容：协议 1 的因果数据只能经承袭日志进来。
    #[test]
    fn open_rejects_heritage_only_content() {
        let one = |op: Op4| {
            let mut w = Writer::new();
            w.uv(1);
            w.u8(TAG_OP);
            write_op_slot(&mut w, &op, 0, None);
            let h = header_for(std::slice::from_ref(&op), 1, 1);
            open_err(&assemble(&h, &w.into_vec(), None))
        };
        let stamped = op_of(
            id(DEV),
            1,
            &Body4::Edit(Edit4 {
                stamp: Some(typical()),
                ..native_edit()
            }),
        );
        assert_eq!(
            one(stamped),
            SegmentError::Corrupt("native edit carries a heritage stamp".into())
        );
        assert_eq!(
            one(op_of(id(DEV), 1, &Body4::Dedup { pairs: vec![] })),
            SegmentError::Corrupt("dedup belongs to heritage logs only".into())
        );
        assert_eq!(
            one(Op4 {
                kind: KIND_RETIRED_MEDIA_AT,
                ..op_of(id(DEV), 1, &Body4::Unknown)
            }),
            SegmentError::Corrupt("kind 12 is retired".into())
        );
        // 协议 3 的操作体格式号。
        assert_eq!(
            one(Op4 {
                fmt: 1,
                ..op_of(id(DEV), 1, &Body4::Log(sample_log()))
            }),
            SegmentError::Corrupt("native op body is not protocol 4".into())
        );
        // 不认识的种类、更新的格式号照收（原样保存、原样转发）。
        let unknown = Op4 {
            kind: 4242,
            fmt: BODY_FMT + 3,
            payload: vec![1, 2, 3].into(),
            ..op_of(id(DEV), 1, &Body4::Unknown)
        };
        let mut w = Writer::new();
        w.uv(1);
        w.u8(TAG_OP);
        write_op_slot(&mut w, &unknown, 0, None);
        let h = header_for(std::slice::from_ref(&unknown), 1, 1);
        let (_, items) =
            open_native(&assemble(&h, &w.into_vec(), None), &signer().public(), None).unwrap();
        assert_eq!(items, vec![NativeItem::Op(unknown)]);
    }

    /// 带盐的两种操作走原生段：作者签名、成链，读回逐字节相同。
    #[test]
    fn salt_carriers_travel_in_native_segments() {
        let ops = vec![
            op_of(id(DEV), 1, &Body4::salts(["u-old", "u-older"]).unwrap()),
            op_of(
                id(DEV),
                2,
                &Body4::Join(Join4 {
                    from: id(0xb0),
                    dir: "b".into(),
                    salts: vec!["u-b".into()],
                }),
            ),
        ];
        let (header, bytes) = pack_native(
            coll(),
            id(DEV),
            1,
            &items_of(&ops),
            [0; 32],
            &signer(),
            None,
        )
        .unwrap();
        assert_eq!((header.first, header.last), (1, 2));
        assert_eq!(header.last_chain, chain_of([0; 32], &ops));
        let (_, items) = open_native(&bytes, &signer().public(), None).unwrap();
        assert_eq!(items, items_of(&ops));
        let bodies: Vec<Body4> = ops.iter().map(|op| op.body().unwrap()).collect();
        let want: std::collections::BTreeSet<String> = ["u-b", "u-old", "u-older"]
            .into_iter()
            .map(str::to_owned)
            .collect();
        assert_eq!(crate::gen4::op::salt_union(&bodies), want);
    }

    /// 大段：超过留存上限的走第二遍流式，结果相同。
    #[test]
    fn big_segments_stream() {
        let big = Body4::LegacyUnknown {
            json: "x".repeat(3 * 1024 * 1024),
        };
        let ops: Vec<Op4> = (1..=7).map(|s| op_of(id(DEV), s, &big)).collect();
        let (_, bytes) = pack_native(
            coll(),
            id(DEV),
            1,
            &items_of(&ops),
            [0; 32],
            &signer(),
            None,
        )
        .unwrap();
        let seg = open_native_verified(&bytes, &signer().public(), None).unwrap();
        let v = seg.verify().unwrap();
        assert!(matches!(v, VerifiedNative::Stream(_)));
        let back: Vec<NativeItem> = v.collect::<Result<_, _>>().unwrap();
        assert_eq!(back, items_of(&ops));
    }

    // ------------------------------------------------------------ 与协议 3 互不误读

    fn v3_ops(n: u64) -> Vec<v3op::Op> {
        (1..=n)
            .map(|seq| v3op::Op {
                id: OpId {
                    device: id(DEV),
                    seq,
                },
                hlc: Hlc {
                    wall: 1_700_000_000_000 + seq as i64,
                    logical: 0,
                    device: id(DEV),
                },
                deps: Arc::new(Vv::new()),
                kind: v3op::KIND_TAG_ADD,
                schema: 1,
                payload: v3op::Body::TagAdd {
                    note: Key::Uuid(id(1)),
                    tag: "t".into(),
                }
                .encode()
                .into(),
                purged: false,
            })
            .collect()
    }

    pub fn v3_segment() -> Vec<u8> {
        v3::pack(coll(), &v3_ops(3), [0; 32], &signer(), None)
            .unwrap()
            .1
    }

    /// 所有者的硬要求：旧版本必须被挡住。协议 3 的解码器读到协议 4 的原生段，在魔数处明确拒绝——三个入口都是。
    #[test]
    fn a_protocol_3_decoder_rejects_a_native_segment() {
        let key = CollectionKey([3; 32]);
        for k in [None, Some(&key)] {
            let (_, bytes) =
                pack_native(coll(), id(DEV), 1, &items_of(&ops()), [0; 32], &signer(), k).unwrap();
            let magic = SegmentError::Corrupt("segment magic".into());
            assert_eq!(v3::peek_header(&bytes).unwrap_err(), magic);
            assert_eq!(
                v3::open_verified(&bytes, &signer().public(), k)
                    .err()
                    .unwrap(),
                magic
            );
            assert_eq!(v3::open(&bytes, &signer().public(), k).unwrap_err(), magic);
            // 也不是转发件。
            assert!(!bytes.starts_with(v3::RELAY_MAGIC));
            assert!(v3::relay_unwrap(&bytes, k).is_err());
            // 协议 3 的转发逻辑也包不了它（包之前要读原段头）。
            assert!(v3::relay_pack(&bytes, None, k).is_err());
        }
    }

    #[test]
    fn a_protocol_4_decoder_rejects_a_protocol_3_segment() {
        let bytes = v3_segment();
        assert!(v3::open(&bytes, &signer().public(), None).is_ok());
        let magic = SegmentError::Corrupt("segment magic".into());
        assert_eq!(peek_native_header(&bytes).unwrap_err(), magic);
        assert_eq!(open_err(&bytes), magic);
        // 协议 3 的转发件同样。
        let relay = v3::relay_pack(&bytes, None, None).unwrap();
        assert_eq!(open_err(&relay), magic);
    }

    // ------------------------------------------------------------ 黄金向量

    fn golden_items() -> Vec<NativeItem> {
        let ops = ops();
        let c1 = chain_of([0; 32], &ops[..1]);
        let c3 = chain_of(c1, &ops[1..3]);
        vec![
            NativeItem::Op(ops[0].clone()),
            NativeItem::Void {
                count: 2,
                chain_after: c3,
            },
            NativeItem::Op(ops[3].clone()),
            NativeItem::Op(ops[4].clone()),
        ]
    }

    /// 段体（未压缩）与段头的字节冻结。改了任何一个 = 改了线格式。
    #[test]
    fn golden_body_and_header() {
        let items = golden_items();
        golden("native_body", &write_body(&items), GOLDEN_BODY);
        let (header, _) =
            pack_native(coll(), id(DEV), 1, &items, [0; 32], &signer(), None).unwrap();
        let mut hw = Writer::new();
        header.write(&mut hw);
        golden("native_header", &hw.into_vec(), GOLDEN_HEADER);
    }

    /// 整段文件（解码方向）：冻结的字节必须一直读得出同样的内容。压缩输出不是契约，所以不比编码方向。
    #[test]
    fn golden_files_still_open() {
        let items = golden_items();
        let (h, got) = open_native(&unhex(GOLDEN_FILE), &signer().public(), None).unwrap();
        assert_eq!(got, items);
        assert_eq!((h.first, h.last), (1, 5));
        let key = CollectionKey([3; 32]);
        let (h, got) =
            open_native(&unhex(GOLDEN_FILE_SEALED), &signer().public(), Some(&key)).unwrap();
        assert_eq!(got, items);
        assert!(h.encrypted);
    }

    /// 生成上面两个整段常量用（`cargo test -- --ignored print_golden_native_files --nocapture`）。
    #[test]
    #[ignore]
    fn print_golden_native_files() {
        let items = golden_items();
        let key = CollectionKey([3; 32]);
        for (name, k) in [("native_file", None), ("native_file_sealed", Some(&key))] {
            let (_, bytes) =
                pack_native(coll(), id(DEV), 1, &items, [0; 32], &signer(), k).unwrap();
            println!("GOLDEN {name} {}", crate::gen4::hex(&bytes));
        }
    }

    const GOLDEN_BODY: &str = "040082c0e285e368000101d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2050104220300010101010101010101010101010101010f7b22637265617465644174223a317d010239e787fd7631632b9006c87c296dfc1eb1fe6f2a08a159fa357c2485e20192280006000101d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d20904041300010101010101010101010101010101010174000200000e0415b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b00162010173";
    const GOLDEN_HEADER: &str = "465347340100c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1010500000000000000000000000000000000000000000000000000000000000000009181d4adc66426a9f02a885ecc46d5fb3848a8c1a1ca0f928480ae190b48b782";
    const GOLDEN_FILE: &str = "465347340100c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1010500000000000000000000000000000000000000000000000000000000000000009181d4adc66426a9f02a885ecc46d5fb3848a8c1a1ca0f928480ae190b48b7827428b52ffd20ab5d0300a405040082c0e285e368000101d2050104220300010f7b22637265617465644174223a317d010239e787fd7631632b9006c87c296dfc1eb1fe6f2a08a159fa357c2485e20192280006090404130174000200000e0415b0016201017305007887be9809812181a0331d480245051604788e08000fad565e779833cdb549a2273a1c1227369a9bfb9e1b001829e92470b532d311f70c9e2cd09f44168cd5376b0c18cdb5c17cddd8333e4c0b";
    const GOLDEN_FILE_SEALED: &str = "465347340101c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1010500000000000000000000000000000000000000000000000000000000000000009181d4adc66426a9f02a885ecc46d5fb3848a8c1a1ca0f928480ae190b48b7829c0153ce93315ba01b13c93c6fe034891400d8e19544764de30764841614b5f35f682dafdf9ceba58cfb46264340f253ea8cbd90224d755f69dccf01e143a55e3420e40c8809ffd9152f442b38087543bed5932cddb081b77be9f772058eb668d34e5e11968e66a10063be4ba1c28a3e5e8250311f9cea42fdb6d51cd7504eb801594fdc306c244dfdd6504882c067869a0a2fb8301dc2d0c990ce4d7befef99482fedf033bd623756e8290a201deae75a614e26d33a959accacd333d5e7b1a9ac76408a8ce2754ba46dae79521bcab3d2aeea4c985211f37ae8af145807";

    // 让导入不因只在个别测试里用到而告警。
    #[test]
    fn imported_log_fits_a_native_segment() {
        let mut l = imported_log();
        l.hlc = None;
        l.server_time = None;
        let op = op_of(id(DEV), 1, &Body4::Log(l));
        let (_, bytes) = pack_native(
            coll(),
            id(DEV),
            1,
            &[NativeItem::Op(op.clone())],
            [0; 32],
            &signer(),
            None,
        )
        .unwrap();
        assert_eq!(
            open_native(&bytes, &signer().public(), None).unwrap().1,
            vec![NativeItem::Op(op)]
        );
    }
}
