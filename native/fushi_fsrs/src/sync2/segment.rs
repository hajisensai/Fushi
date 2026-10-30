//! 段与 head（设计 §6.1、§7.3、§7.4）。
//!
//! **段**（`devices/<DeviceId>/seg-<first>-<last>.bin`）：一台设备连续 seq 区间的操作，写一次后不可变。
//!
//! ```text
//! 头（明文，参与签名，加密时作 AAD）
//!   "FSG2" | ver u8 | flags u8 (bit0 加密) | collection Id | device Id | first uv | last uv
//!   | prev_chain [32] | last_chain [32]
//! 体  zstd(操作增量编码)，加密时再 XChaCha20-Poly1305(nonce || ct)：先压后加密（密文不可压）
//!     压缩用官方 zstd 第 [SEGMENT_ZSTD_LEVEL] 档、不带字典（见该常量）；解压走 ruzstd 流式窗口，任何标准帧都读。
//! 尾  Ed25519 签名 [64]，签 blake3(头 || 体)
//! ```
//!
//! **哈希链按操作算**：`h_0 = 0`，`h_n = blake3(h_{n-1} || op_n 的独立编码)`。所以同一 seq 区间的操作
//! 不论切成几段、合并成一段（§7.1），链尾都一样；同一 DeviceId 在同一 seq 上出现两种链值 = 身份分叉（§7.3）。
//!
//! **head**（`devices/<DeviceId>/head-<gen>.json`）：该设备的最新 seq、链尾、段清单、已应用版本向量（ack）、
//! 状态摘要、公钥，整体签名。`gen` 是 head 的代号（每写一次 +1）：只收不发的设备 seq 不动，ack 照样要更新。
//! 读者取 gen 最大且「引用的段都可读」的 head。

use std::sync::Arc;

use serde_json::{json, Value};

use super::codec::{DResult, DecodeError, Reader, StreamError, Writer, ZstdWindow};
use super::hlc::Hlc;
use super::id::Id;
use super::keys::{verify, CollectionKey, DeviceKey};
use super::op::Op;
use super::vv::{OpId, Vv};

pub const MAGIC: &[u8; 4] = b"FSG2";
pub const VERSION: u8 = 1;
/// 协议版本（head 的 `v`）。2 = 2026-10-30 断代：集合根挪到 `v3/`（Dart srs_location_store.dart）、媒体只剩内容寻址 +
/// 分块封装；段与 head 的字节格式没变（v1 位置的段 / head 原样搬进新根，读者照读）。
pub const PROTOCOL: u32 = 2;
/// 能读本版本写出的数据所需的最低读者版本（设计 §8）。读者遇到 head 的 `minReader` 比自己的 [PROTOCOL] 新：不收这台
/// 设备、报需要升级（store/sync2/transport.rs `plan`）。
pub const MIN_READER: u32 = 2;

/// 切段目标（设计 §6.2）：按**压缩后**的体积算，一段约 4 MB。哑存储上一次请求的固定开销远大于传几 MB 的
/// 时间，段越少首次提交 / 新设备追赶越快；增量同步每轮只有几条操作，本来就只出一个小段，由小段合并（§7.1）收拢。
pub const SEGMENT_TARGET_BYTES: u64 = 4 * 1024 * 1024;
/// 每段条数上限：只是解码内存的保险（真实复习压缩后每条几十字节，4 MB 约十万条）。
pub const SEGMENT_MAX_OPS: u64 = 250_000;
/// 每段**解压后**的体积上限（按载荷 + 每条固定开销估计）。只按压缩后体积切时，重复度高的正文（例句、模板
/// 化字段）压缩比能到上百倍，一个 4 MB 的段解开就是几百 MB，读端解一段要同时拿着明文与解出来的操作。
/// 普通内容压缩比几倍，这条上限碰不到；碰到的段在 [Splitter] 交回的体积里按满段记（见 [Splitter::finish]）。
pub const SEGMENT_MAX_RAW_BYTES: u64 = 16 * 1024 * 1024;
/// 段体的 zstd 档位。基准（10 万笔记 / 40 万复习 / 75 万条操作，段体解压后 123 MB）：ruzstd Fastest 26.7 MB；官方 zstd
/// -1 17.8 MB、-3 17.5 MB（0.15 s）、-9 17.2 MB（0.7 s）、-19 14.5 MB（60 s）。-3 之后每多一档只省 1%、耗时翻倍，
/// 手机上首次提交几十万条要按秒计，取 3。不用字典：首次提交 / 合并后的段是几 MB 的大帧，字典只对几百字节的小帧有用，
/// 而小段的绝对体积本来就小；字典一旦用上就成了格式的一部分，永远要随包带着训练那天的那一份。
pub const SEGMENT_ZSTD_LEVEL: i32 = 3;

/// 压一个段体（[SEGMENT_ZSTD_LEVEL]）。只在分配失败这类不可能的情形出错。
fn compress_body(raw: &[u8]) -> Result<Vec<u8>, String> {
    zstd::bulk::compress(raw, SEGMENT_ZSTD_LEVEL).map_err(|e| format!("segment compress: {e}"))
}

/// 估算压缩体积的小块：块内一起压、块间各自压，求和是整段一起压的上界（块越大越准，也越费内存）。
const CHUNK_OPS: usize = 4096;
const CHUNK_RAW: usize = 256 * 1024;

pub type Chain = [u8; 32];
pub const CHAIN_ZERO: Chain = [0; 32];

/// 链的下一环：`blake3(前一环 || 信封 || 载荷哈希)`。按载荷哈希而不是原字节算：彻底清除（§10.5）把载荷换成
/// 它的哈希之后，链值、段签名都照样可验证。
pub fn chain_next(prev: &Chain, op: &Op) -> Chain {
    let mut h = blake3::Hasher::new();
    h.update(prev);
    h.update(&op.envelope());
    h.update(&op.payload_hash());
    *h.finalize().as_bytes()
}

/// 校验失败的分型（设计 §7.4：不应用该段及其后续、告警、等对方重写）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SegmentError {
    /// 截断 / 格式不对 / zstd 解不开（多半是还没传完或被截断）。
    Corrupt(String),
    /// 签名不符（被篡改，或不是那台设备写的）。
    BadSignature,
    /// 链与操作对不上（体被改过）。
    ChainMismatch,
    /// 加密段但没有密钥 / 密钥不对。
    Undecryptable,
}

impl std::fmt::Display for SegmentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SegmentError::Corrupt(m) => write!(f, "corrupt segment: {m}"),
            SegmentError::BadSignature => f.write_str("segment signature mismatch"),
            SegmentError::ChainMismatch => f.write_str("segment hash chain mismatch"),
            SegmentError::Undecryptable => f.write_str("segment cannot be decrypted"),
        }
    }
}

impl From<DecodeError> for SegmentError {
    fn from(e: DecodeError) -> Self {
        SegmentError::Corrupt(e.0.to_owned())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SegmentHeader {
    pub encrypted: bool,
    pub collection: Id,
    pub device: Id,
    pub first: u64,
    pub last: u64,
    pub prev_chain: Chain,
    pub last_chain: Chain,
}

impl SegmentHeader {
    fn write(&self, w: &mut Writer) {
        w.raw(MAGIC);
        w.u8(VERSION);
        w.u8(u8::from(self.encrypted));
        self.collection.write(w);
        self.device.write(w);
        w.uv(self.first);
        w.uv(self.last);
        w.raw(&self.prev_chain);
        w.raw(&self.last_chain);
    }

    fn read(r: &mut Reader<'_>) -> DResult<SegmentHeader> {
        if r.raw(4)? != MAGIC {
            return Err(DecodeError("segment magic"));
        }
        if r.u8()? != VERSION {
            return Err(DecodeError("segment version"));
        }
        let flags = r.u8()?;
        let collection = Id::read(r)?;
        let device = Id::read(r)?;
        let first = r.uv()?;
        let last = r.uv()?;
        if first == 0 || last < first {
            return Err(DecodeError("segment range"));
        }
        let prev_chain: Chain = r.raw(32)?.try_into().map_err(|_| DecodeError("chain"))?;
        let last_chain: Chain = r.raw(32)?.try_into().map_err(|_| DecodeError("chain"))?;
        Ok(SegmentHeader { encrypted: flags & 1 != 0, collection, device, first, last, prev_chain, last_chain })
    }

    /// 文件名（设计 §6.1）。seq 补零到 12 位，按名字排序即按 seq 排序；末尾带链尾的前 8 位十六进制：
    /// 同一 DeviceId 的两个安装（数据目录被复制，§7.3）写出的同区间段名字不同，哑存储上不会互相覆盖。
    pub fn file_name(&self) -> String {
        segment_file_name(self.first, self.last, &chain_tag(&self.last_chain))
    }
}

/// 链值的短标签（文件名用）。
pub fn chain_tag(c: &Chain) -> String {
    c[..4].iter().map(|b| format!("{b:02x}")).collect()
}

pub fn segment_file_name(first: u64, last: u64, tag: &str) -> String {
    format!("seg-{first:012}-{last:012}-{tag}.bin")
}

/// 从文件名解出 (first, last, 标签)。
pub fn parse_segment_file_name(name: &str) -> Option<(u64, u64, String)> {
    let rest = name.strip_prefix("seg-")?.strip_suffix(".bin")?;
    let mut it = rest.splitn(3, '-');
    let (a, b, t) = (it.next()?.parse().ok()?, it.next()?.parse().ok()?, it.next()?);
    (a >= 1 && b >= a && t.len() == 8).then(|| (a, b, t.to_owned()))
}

/// 一段已校验的操作。
#[derive(Debug, Clone)]
pub struct Segment {
    pub header: SegmentHeader,
    pub ops: Vec<Op>,
}

fn write_body(ops: &[Op]) -> Vec<u8> {
    let mut w = Writer::with_capacity(ops.len() * 48);
    w.uv(ops.len() as u64);
    let mut prev_wall = 0i64;
    let mut prev_deps: Option<&Arc<Vv>> = None;
    for op in ops {
        w.iv(op.hlc.wall.wrapping_sub(prev_wall));
        prev_wall = op.hlc.wall;
        w.uv(u64::from(op.hlc.logical));
        let same = prev_deps.is_some_and(|p| Arc::ptr_eq(p, &op.deps) || **p == *op.deps);
        if same {
            w.u8(0);
        } else {
            w.u8(1);
            op.deps.write(&mut w);
        }
        prev_deps = Some(&op.deps);
        w.uv(u64::from(op.kind));
        w.uv(u64::from(op.schema));
        w.bool(op.purged);
        w.bytes(&op.payload);
    }
    w.into_vec()
}

/// 解一条操作（段体里的第 [i] 条；前一条的 wall / deps 是 [prev_wall] / [prev_deps]）。
fn read_op(r: &mut Reader<'_>, device: Id, seq: u64, i: u64, prev_wall: i64, prev_deps: &Arc<Vv>) -> DResult<Op> {
    let wall = prev_wall.wrapping_add(r.iv()?);
    let logical = u32::try_from(r.uv()?).map_err(|_| DecodeError("hlc logical"))?;
    let deps = match r.u8()? {
        0 if i > 0 => prev_deps.clone(),
        1 => {
            let v = Vv::read(r)?;
            if v.get(&device) != 0 {
                return Err(DecodeError("op deps name its own device"));
            }
            Arc::new(v)
        }
        _ => return Err(DecodeError("deps flag")),
    };
    let kind = u16::try_from(r.uv()?).map_err(|_| DecodeError("op kind"))?;
    let schema = u16::try_from(r.uv()?).map_err(|_| DecodeError("op schema"))?;
    let purged = r.bool()?;
    let payload: Arc<[u8]> = r.bytes()?.into();
    if purged && payload.len() != 32 {
        return Err(DecodeError("purged op without payload hash"));
    }
    Ok(Op { id: OpId { device, seq }, hlc: Hlc { wall, logical, device }, deps, kind, schema, payload, purged })
}

impl From<StreamError> for SegmentError {
    fn from(e: StreamError) -> Self {
        SegmentError::Corrupt(e.to_string())
    }
}

/// 流式解开的段体：边解压边逐条解码（[ZstdWindow]），不随段的解压后体积增长。
/// 由 [OpenSegment::ops] / [OpenSegment::verify] 产出；格式错时产出一次 `Err` 后结束。
pub struct OpStream<'s> {
    window: ZstdWindow<'s>,
    device: Id,
    first: u64,
    last: u64,
    /// 段体开头声明的条数（读第一条之前取）。
    n: Option<u64>,
    i: u64,
    wall: i64,
    deps: Arc<Vv>,
    done: bool,
}

impl<'s> OpStream<'s> {
    fn new(compressed: &'s [u8], header: &SegmentHeader) -> Result<OpStream<'s>, SegmentError> {
        Ok(OpStream {
            window: ZstdWindow::new(compressed)?,
            device: header.device,
            first: header.first,
            last: header.last,
            n: None,
            i: 0,
            wall: 0,
            deps: Arc::new(Vv::new()),
            done: false,
        })
    }

    fn step(&mut self) -> Result<Option<Op>, SegmentError> {
        let n = match self.n {
            Some(n) => n,
            None => {
                let n = self.window.parse(|r| r.uv())?;
                if n != self.last - self.first + 1 {
                    return Err(DecodeError("segment op count").into());
                }
                self.n = Some(n);
                n
            }
        };
        if self.i == n {
            if !self.window.at_end()? {
                return Err(DecodeError("trailing bytes in segment body").into());
            }
            return Ok(None);
        }
        let (device, seq, i, wall, deps) = (self.device, self.first + self.i, self.i, self.wall, self.deps.clone());
        let op = self.window.parse(|r| read_op(r, device, seq, i, wall, &deps))?;
        self.wall = op.hlc.wall;
        self.deps = op.deps.clone();
        self.i += 1;
        Ok(Some(op))
    }
}

impl Iterator for OpStream<'_> {
    type Item = Result<Op, SegmentError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        let r = self.step();
        self.done = !matches!(r, Ok(Some(_)));
        r.transpose()
    }
}

/// 打包一段（[ops] 必须是同一设备的连续 seq，[prev_chain] 是 first − 1 处的链值）。
pub fn pack(
    collection: Id,
    ops: &[Op],
    prev_chain: Chain,
    signer: &DeviceKey,
    key: Option<&CollectionKey>,
) -> Result<(SegmentHeader, Vec<u8>), String> {
    let first = ops.first().ok_or("empty segment")?;
    let device = first.id.device;
    let mut chain = prev_chain;
    for (i, op) in ops.iter().enumerate() {
        if op.id.device != device || op.id.seq != first.id.seq + i as u64 {
            return Err("segment ops must be one device's contiguous seqs".into());
        }
        chain = chain_next(&chain, op);
    }
    let header = SegmentHeader {
        encrypted: key.is_some(),
        collection,
        device,
        first: first.id.seq,
        last: first.id.seq + ops.len() as u64 - 1,
        prev_chain,
        last_chain: chain,
    };
    let mut hw = Writer::new();
    header.write(&mut hw);
    let head_bytes = hw.into_vec();
    let compressed = compress_body(&write_body(ops))?;
    let body = match key {
        Some(k) => k.seal(&compressed, &head_bytes),
        None => compressed,
    };
    let mut signed = blake3::Hasher::new();
    signed.update(&head_bytes);
    signed.update(&body);
    let sig = signer.sign(signed.finalize().as_bytes());
    let mut out = head_bytes;
    let mut w = Writer::new();
    w.bytes(&body);
    out.extend_from_slice(&w.into_vec());
    out.extend_from_slice(&sig);
    Ok((header, out))
}

/// 只读段头（不验签、不解体）：列目录后按需决定要不要整段处理。转发件（[RELAY_MAGIC]）读的是里面原段的头。
pub fn peek_header(bytes: &[u8]) -> Result<SegmentHeader, SegmentError> {
    if bytes.starts_with(RELAY_MAGIC) {
        let (_, _, orig_head) = relay_prefix(bytes)?;
        return Ok(SegmentHeader::read(&mut Reader::new(orig_head))?);
    }
    Ok(SegmentHeader::read(&mut Reader::new(bytes))?)
}

// ---------------------------------------------------------------- 转发件（设计 §6.3 反熵，2026-10-29 审查 S-1）

/// 转发件的魔数。转发件 = 别的设备（作者）的一个段，由持有它的设备原样搬到作者自己没去过的位置
/// （`devices/<作者>/rly-<first>-<last>-<tag>.bin`，与原段同名只换前缀：作者若也直接写这个位置，各写各的，互不覆盖）。
///
/// ```text
/// "FSRL" | ver u8 | flags u8 (bit0 用目标位置的密钥封装) | bytes(原段头) | bytes(内层)
/// 内层（封装时 = XChaCha20-Poly1305(nonce || ct)，AAD = 前面的全部字节）
///   = bytes(原段体) | 原签名 [64] | bytes(原段体是密文时：解密后的压缩体；否则空)
/// ```
///
/// 读者照常用**作者**公钥验原签名（签的是 blake3(原段头 || 原段体)，与原段体是不是密文无关），再用原段头里由签名
/// 担保的 `prev_chain` → `last_chain` 校验解出的操作（哈希链承诺了每一条），所以转发者既伪造不了操作、也不需要
/// 原位置的密钥；原段是密文时附带的明文压缩体同样逃不过链校验。目标位置加密时整个内层用目标位置的密钥封装，
/// 明文不会落到加密位置上。
pub const RELAY_MAGIC: &[u8; 4] = b"FSRL";
const RELAY_VERSION: u8 = 1;

/// 转发件的前缀：`(flags, 前缀字节 = AAD, 原段头字节)`。
fn relay_prefix(bytes: &[u8]) -> Result<(u8, &[u8], &[u8]), SegmentError> {
    let mut r = Reader::new(bytes);
    if r.raw(4)? != RELAY_MAGIC {
        return Err(SegmentError::Corrupt("relay magic".into()));
    }
    if r.u8()? != RELAY_VERSION {
        return Err(SegmentError::Corrupt("relay version".into()));
    }
    let flags = r.u8()?;
    let head = r.bytes()?;
    Ok((flags, &bytes[..r.pos], head))
}

/// 转发件里的原段：`(原段完整字节, 原段体是密文时的明文压缩体)`。[key] = 转发件所在位置的密钥。
pub fn relay_unwrap(bytes: &[u8], key: Option<&CollectionKey>) -> Result<(Vec<u8>, Option<Vec<u8>>), SegmentError> {
    let (flags, aad, head) = relay_prefix(bytes)?;
    let mut r = Reader::new(&bytes[aad.len()..]);
    let inner_raw = r.bytes()?;
    if !r.is_empty() {
        return Err(SegmentError::Corrupt("relay trailing bytes".into()));
    }
    let inner = if flags & 1 != 0 {
        let k = key.ok_or(SegmentError::Undecryptable)?;
        std::borrow::Cow::Owned(k.open(inner_raw, aad).ok_or(SegmentError::Undecryptable)?)
    } else {
        std::borrow::Cow::Borrowed(inner_raw)
    };
    let mut r = Reader::new(&inner);
    let body = r.bytes()?;
    let sig = r.raw(64)?;
    let plain = r.bytes()?;
    if !r.is_empty() {
        return Err(SegmentError::Corrupt("relay inner trailing bytes".into()));
    }
    let mut orig = head.to_vec();
    let mut w = Writer::new();
    w.bytes(body);
    orig.extend_from_slice(&w.into_vec());
    orig.extend_from_slice(sig);
    Ok((orig, (!plain.is_empty()).then(|| plain.to_vec())))
}

/// 一个收到的段（原段或转发件）里转发要用的部分：`(原段完整字节, 原段体是密文时的明文压缩体)`。[key] = 它所在
/// 位置的密钥。调用方先验过签名与链。
pub fn relay_parts(bytes: &[u8], key: Option<&CollectionKey>) -> Result<(Vec<u8>, Option<Vec<u8>>), SegmentError> {
    if bytes.starts_with(RELAY_MAGIC) {
        return relay_unwrap(bytes, key);
    }
    let mut r = Reader::new(bytes);
    let header = SegmentHeader::read(&mut r)?;
    let head_len = r.pos;
    let body = r.bytes()?;
    let plain = if header.encrypted {
        let k = key.ok_or(SegmentError::Undecryptable)?;
        Some(k.open(body, &bytes[..head_len]).ok_or(SegmentError::Undecryptable)?)
    } else {
        None
    };
    Ok((bytes.to_vec(), plain))
}

/// 打包一个转发件（[orig] = 原段完整字节，[plain] = 原段体是密文时的明文压缩体；[key] = 目标位置的密钥）。
pub fn relay_pack(orig: &[u8], plain: Option<&[u8]>, key: Option<&CollectionKey>) -> Result<Vec<u8>, String> {
    let mut r = Reader::new(orig);
    let header = SegmentHeader::read(&mut r).map_err(|e| e.to_string())?;
    let head_len = r.pos;
    let body = r.bytes().map_err(|e| e.to_string())?;
    let sig = r.raw(64).map_err(|e| e.to_string())?;
    let plain_body: &[u8] = match (header.encrypted, plain) {
        (true, Some(p)) => p,
        (true, None) => return Err("relay: encrypted segment without its plaintext body".into()),
        (false, _) => &[],
    };
    let mut inner = Writer::new();
    inner.bytes(body);
    inner.raw(sig);
    inner.bytes(plain_body);
    let inner = inner.into_vec();
    let mut w = Writer::new();
    w.raw(RELAY_MAGIC);
    w.u8(RELAY_VERSION);
    w.u8(u8::from(key.is_some()));
    w.bytes(&orig[..head_len]);
    let mut out = w.into_vec();
    let sealed = match key {
        Some(k) => k.seal(&inner, &out),
        None => inner,
    };
    let mut w = Writer::new();
    w.bytes(&sealed);
    out.extend_from_slice(&w.into_vec());
    Ok(out)
}

/// 段文件名对应的转发件文件名（`seg-…` → `rly-…`）。
pub fn relay_file_name(segment_file: &str) -> String {
    match segment_file.strip_prefix("seg-") {
        Some(rest) => format!("rly-{rest}"),
        None => segment_file.to_owned(),
    }
}

/// 验过签、解过密的段：段体仍是压缩的（体积受切段目标约束），操作按需流式解开（[Self::verify] / [Self::ops]）。
pub struct OpenSegment<'a> {
    pub header: SegmentHeader,
    compressed: std::borrow::Cow<'a, [u8]>,
}

/// [OpenSegment::verify] 的结果：链已对上的全部操作，按 seq 升序产出。
pub enum Verified<'a> {
    /// 校验那一遍顺手留下的（解压后不超过 [SEGMENT_MAX_RAW_BYTES] 的段，新切的段都是）。
    Whole(std::vec::IntoIter<Op>),
    /// 太大没留：第二遍流式解（与校验那一遍逐字节相同）。
    Stream(OpStream<'a>),
}

impl Iterator for Verified<'_> {
    type Item = Result<Op, SegmentError>;

    fn next(&mut self) -> Option<Self::Item> {
        match self {
            Verified::Whole(ops) => ops.next().map(Ok),
            Verified::Stream(s) => s.next(),
        }
    }
}

impl OpenSegment<'_> {
    /// 流式解码段体，**不**重算链：只给调用方自己逐条比链的场合（收本机身份的段找分叉点）。
    pub fn ops(&self) -> Result<OpStream<'_>, SegmentError> {
        OpStream::new(&self.compressed, &self.header)
    }

    /// 流式解一遍、重算链，链对上才交回操作。没超过 [SEGMENT_MAX_RAW_BYTES] 的段直接交回这一遍解出的；超过的
    /// （旧版本只按压缩后体积切出的高可压大段，解开能有几百 MB）校验途中就扔掉，交回第二遍的流。所以解一段的
    /// 内存峰值是「一段的上限」与「一个读窗口」中的较大者，与段的解压后体积无关；也不会先投出半段链对不上的操作。
    pub fn verify(&self) -> Result<Verified<'_>, SegmentError> {
        let mut chain = self.header.prev_chain;
        let mut kept: Option<Vec<Op>> = Some(Vec::new());
        let mut kept_raw: u64 = 0;
        for op in self.ops()? {
            let op = op?;
            chain = chain_next(&chain, &op);
            if let Some(k) = kept.as_mut() {
                kept_raw += op.payload.len() as u64 + 24;
                if kept_raw > SEGMENT_MAX_RAW_BYTES {
                    kept = None;
                } else {
                    k.push(op);
                }
            }
        }
        if chain != self.header.last_chain {
            return Err(SegmentError::ChainMismatch);
        }
        Ok(match kept {
            Some(ops) => Verified::Whole(ops.into_iter()),
            None => Verified::Stream(self.ops()?),
        })
    }
}

/// 验签、解密一段（不解压）。
pub fn open_verified<'a>(
    bytes: &'a [u8],
    public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<OpenSegment<'a>, SegmentError> {
    if bytes.starts_with(RELAY_MAGIC) {
        // 转发件：[key] 是转发件所在位置的密钥；原段按作者签名验，密文原段用附带的明文压缩体（链校验兜底）。
        let (orig, plain) = relay_unwrap(bytes, key)?;
        let mut r = Reader::new(&orig);
        let header = SegmentHeader::read(&mut r)?;
        let head_len = r.pos;
        let body = r.bytes()?;
        let sig: [u8; 64] = r.raw(64)?.try_into().map_err(|_| SegmentError::Corrupt("sig".into()))?;
        let mut signed = blake3::Hasher::new();
        signed.update(&orig[..head_len]);
        signed.update(body);
        if !verify(public, signed.finalize().as_bytes(), &sig) {
            return Err(SegmentError::BadSignature);
        }
        let compressed = if header.encrypted {
            plain.ok_or_else(|| SegmentError::Corrupt("relayed encrypted segment without its body".into()))?
        } else {
            body.to_vec()
        };
        return Ok(OpenSegment { header, compressed: std::borrow::Cow::Owned(compressed) });
    }
    let mut r = Reader::new(bytes);
    let header = SegmentHeader::read(&mut r)?;
    let head_len = r.pos;
    let body = r.bytes()?;
    let sig: [u8; 64] = r.raw(64)?.try_into().map_err(|_| SegmentError::Corrupt("sig".into()))?;
    if !r.is_empty() {
        return Err(SegmentError::Corrupt("trailing bytes".into()));
    }
    let mut signed = blake3::Hasher::new();
    signed.update(&bytes[..head_len]);
    signed.update(body);
    if !verify(public, signed.finalize().as_bytes(), &sig) {
        return Err(SegmentError::BadSignature);
    }
    let compressed = if header.encrypted {
        let k = key.ok_or(SegmentError::Undecryptable)?;
        std::borrow::Cow::Owned(k.open(body, &bytes[..head_len]).ok_or(SegmentError::Undecryptable)?)
    } else {
        std::borrow::Cow::Borrowed(body)
    };
    Ok(OpenSegment { header, compressed })
}

/// 校验并整段解开（签名 → 解密 → 解压 → 解码 → 重算链），操作全部放进内存。只给测试这类已知小段的场合；
/// 收段走 [open_verified] + [OpenSegment::verify]，按块处理。
pub fn open(bytes: &[u8], public: &[u8; 32], key: Option<&CollectionKey>) -> Result<Segment, SegmentError> {
    let seg = open_verified(bytes, public, key)?;
    let ops = seg.verify()?.collect::<Result<Vec<Op>, SegmentError>>()?;
    Ok(Segment { header: seg.header, ops })
}

/// 一组操作打成段体后压缩出来的字节数（不含段头、签名、加密开销，那些是每段几十字节的常数）。
pub fn compressed_len(ops: &[Op]) -> u64 {
    let raw = write_body(ops);
    // 压不了（分配失败）就按原长算：只会切得更碎，不会超限。
    compress_body(&raw).map_or(raw.len(), |c| c.len()) as u64
}

/// 按设计 §6.2 的目标把一台设备连续 seq 的操作流式切成段：逐条 [Splitter::push]，最后 [Splitter::finish] 得到
/// `(first, last, 压缩后体积估计)`。不必把整段操作攒在内存里——首次提交几十万条也只占一个小块的内存。
///
/// 切点只落在小块边界上；体积估计是各小块单独压缩之和（上界），所以真实段不超过 [SEGMENT_TARGET_BYTES]，
/// 解压后也不超过 [SEGMENT_MAX_RAW_BYTES]（单条操作本身更大时一条一段）。
#[derive(Default)]
pub struct Splitter {
    chunk: Vec<Op>,
    chunk_raw: usize,
    /// 当前段 `(first, last, 压缩后体积估计, 解压后体积估计)`。
    cur: Option<(u64, u64, u64, u64)>,
    out: Vec<(u64, u64, u64)>,
}

impl Splitter {
    pub fn new() -> Splitter {
        Splitter::default()
    }

    pub fn push(&mut self, op: Op) {
        let raw = op.payload.len() + 24;
        if !self.chunk.is_empty() && (self.chunk.len() >= CHUNK_OPS || self.chunk_raw + raw > CHUNK_RAW) {
            self.flush_chunk();
        }
        self.chunk_raw += raw;
        self.chunk.push(op);
    }

    fn flush_chunk(&mut self) {
        let (Some(head), Some(tail)) = (self.chunk.first(), self.chunk.last()) else { return };
        let (first, last, n) = (head.id.seq, tail.id.seq, self.chunk.len() as u64);
        let bytes = compressed_len(&self.chunk);
        let raw = self.chunk_raw as u64;
        match &mut self.cur {
            Some((a, b, s, w))
                if *s + bytes <= SEGMENT_TARGET_BYTES
                    && *b - *a + 1 + n <= SEGMENT_MAX_OPS
                    && *w + raw <= SEGMENT_MAX_RAW_BYTES =>
            {
                *b = last;
                *s += bytes;
                *w += raw;
            }
            cur => {
                if let Some(done) = cur.replace((first, last, bytes, raw)) {
                    self.out.push(Self::sized(done));
                }
            }
        }
        self.chunk.clear();
        self.chunk_raw = 0;
    }

    /// `(first, last, 体积)`：解压后已过上限一半的段按「满段」（[SEGMENT_TARGET_BYTES] 的一半）记。分层合并
    /// （store/sync2/transport.rs）只看这个数，否则这种压缩后很小的段会每轮被挑出来重切、又切回原样。
    fn sized((a, b, s, w): (u64, u64, u64, u64)) -> (u64, u64, u64) {
        if w >= SEGMENT_MAX_RAW_BYTES / 2 {
            (a, b, s.max(SEGMENT_TARGET_BYTES / 2))
        } else {
            (a, b, s)
        }
    }

    pub fn finish(mut self) -> Vec<(u64, u64, u64)> {
        self.flush_chunk();
        if let Some(done) = self.cur.take() {
            self.out.push(Self::sized(done));
        }
        self.out
    }
}

/// 一次性切一组操作（[Splitter] 的便捷形）。
pub fn split_ranges(ops: &[Op]) -> Vec<(u64, u64, u64)> {
    let mut s = Splitter::new();
    for op in ops {
        s.push(op.clone());
    }
    s.finish()
}

// ---------------------------------------------------------------- head

/// 一台设备的 head。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Head {
    /// head 代号，每写一次 +1（文件名用它，不用 seq）。
    pub gen: u64,
    pub protocol: u32,
    pub min_reader: u32,
    pub collection: Id,
    pub device: Id,
    pub public: [u8; 32],
    /// 该设备已发布的最大 seq（0 = 只发布了身份，还没有操作）。
    pub seq: u64,
    pub chain: Chain,
    /// 已发布的段（升序、首尾相接、覆盖 1..=seq）：(first, last, 链尾标签)。
    pub segments: Vec<(u64, u64, String)>,
    /// 该设备已应用的版本向量（压缩 / 清理以「全部设备的 ack」为准）。
    pub ack: Vv,
    /// 在 [ack] 下的派生状态摘要（确定性自检，设计 §4.5）。
    pub digest: String,
    pub at_ms: i64,
    pub name: String,
}

fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

fn unhex<const N: usize>(s: &str) -> Option<[u8; N]> {
    if s.len() != 2 * N {
        return None;
    }
    let mut out = [0u8; N];
    for i in 0..N {
        out[i] = u8::from_str_radix(s.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

impl Head {
    pub fn file_name(&self) -> String {
        head_file_name(self.gen, &chain_tag(&self.chain))
    }

    /// head 引用的段文件名。
    pub fn segment_files(&self) -> Vec<String> {
        self.segments.iter().map(|(a, b, t)| segment_file_name(*a, *b, t)).collect()
    }

    /// 签名覆盖的规范 JSON（键序固定）。
    fn unsigned_json(&self) -> Value {
        let ack: serde_json::Map<String, Value> =
            self.ack.0.iter().map(|(d, s)| (d.text(), json!(s))).collect();
        json!({
            "gen": self.gen,
            "v": self.protocol,
            "minReader": self.min_reader,
            "collection": self.collection.text(),
            "device": self.device.text(),
            "pub": hex(&self.public),
            "seq": self.seq,
            "chain": hex(&self.chain),
            "segments": self.segments.iter().map(|(a, b, t)| json!([a, b, t])).collect::<Vec<_>>(),
            "ack": ack,
            "digest": self.digest,
            "at": self.at_ms,
            "name": self.name,
        })
    }

    fn signed_bytes(&self) -> Vec<u8> {
        // serde_json 的 Map 默认按键排序（BTreeMap），输出是规范形。
        serde_json::to_vec(&self.unsigned_json()).expect("head json")
    }

    /// 内容签名：除代号与时刻外的全部字段（发布了什么、ack 到哪、摘要、名字）。两个 head 的内容签名相同 =
    /// 对别的设备而言没有任何新信息，不必再发一次（见 `sync2_head` 的「没变就不写」）。
    pub fn content_sig(&self) -> String {
        let mut v = self.unsigned_json();
        if let Some(m) = v.as_object_mut() {
            m.remove("gen");
            m.remove("at");
        }
        hex(blake3::hash(&serde_json::to_vec(&v).expect("head json")).as_bytes())
    }

    pub fn encode(&self, signer: &DeviceKey) -> Vec<u8> {
        let sig = signer.sign(&self.signed_bytes());
        let mut v = self.unsigned_json();
        v["sig"] = json!(hex(&sig));
        serde_json::to_vec(&v).expect("head json")
    }

    /// 解析并验签（用 head 自带的公钥；公钥是否可信由调用方对照设备表判定，设计 §9）。
    pub fn decode(bytes: &[u8]) -> Result<Head, String> {
        let v: Value = serde_json::from_slice(bytes).map_err(|e| format!("bad head: {e}"))?;
        let s = |k: &str| v.get(k).and_then(Value::as_str).ok_or_else(|| format!("head: missing {k}"));
        let u = |k: &str| v.get(k).and_then(Value::as_u64).ok_or_else(|| format!("head: missing {k}"));
        let id = |k: &str| -> Result<Id, String> { Id::parse(s(k)?).ok_or_else(|| format!("head: bad {k}")) };
        let mut segments = Vec::new();
        for x in v.get("segments").and_then(Value::as_array).ok_or("head: missing segments")? {
            let a = x.get(0).and_then(Value::as_u64).ok_or("head: bad segment")?;
            let b = x.get(1).and_then(Value::as_u64).ok_or("head: bad segment")?;
            let t = x.get(2).and_then(Value::as_str).filter(|t| t.len() == 8).ok_or("head: bad segment")?;
            segments.push((a, b, t.to_owned()));
        }
        let mut ack = Vv::new();
        for (k, x) in v.get("ack").and_then(Value::as_object).ok_or("head: missing ack")? {
            let d = Id::parse(k).ok_or("head: bad ack device")?;
            ack.set(d, x.as_u64().ok_or("head: bad ack seq")?);
        }
        let head = Head {
            gen: u("gen")?,
            protocol: u32::try_from(u("v")?).map_err(|_| "head: v")?,
            min_reader: u32::try_from(u("minReader")?).map_err(|_| "head: minReader")?,
            collection: id("collection")?,
            device: id("device")?,
            public: unhex::<32>(s("pub")?).ok_or("head: bad pub")?,
            seq: u("seq")?,
            chain: unhex::<32>(s("chain")?).ok_or("head: bad chain")?,
            segments,
            ack,
            digest: s("digest")?.to_owned(),
            at_ms: v.get("at").and_then(Value::as_i64).ok_or("head: missing at")?,
            name: s("name")?.to_owned(),
        };
        let sig = unhex::<64>(s("sig")?).ok_or("head: bad sig")?;
        if !verify(&head.public, &head.signed_bytes(), &sig) {
            return Err("head signature mismatch".into());
        }
        // 段清单必须首尾相接、覆盖 1..=seq（否则读者无法判断「引用段都可读」）。
        let mut next = 1;
        for &(a, b, _) in &head.segments {
            if a != next || b < a {
                return Err("head: segments not contiguous".into());
            }
            next = b + 1;
        }
        if next != head.seq + 1 {
            return Err("head: segments do not cover seq".into());
        }
        Ok(head)
    }
}

/// head 文件名：代号 + 链尾标签（同一身份的两个安装写同一代号也不互相覆盖）。
pub fn head_file_name(gen: u64, tag: &str) -> String {
    format!("head-{gen:012}-{tag}.json")
}

pub fn parse_head_file_name(name: &str) -> Option<u64> {
    let rest = name.strip_prefix("head-")?.strip_suffix(".json")?;
    rest.split_once('-')?.0.parse().ok()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::sync2::id::Key;
    use crate::sync2::op::{Body, SCHEMA};

    /// 明文段解压后的段体（体积基准用）。
    pub fn raw_body_of(bytes: &[u8]) -> Vec<u8> {
        let mut r = Reader::new(bytes);
        let header = SegmentHeader::read(&mut r).unwrap();
        assert!(!header.encrypted);
        let body = r.bytes().unwrap();
        let mut out = Vec::new();
        let mut d = ruzstd::decoding::StreamingDecoder::new(body).unwrap();
        std::io::Read::read_to_end(&mut d, &mut out).unwrap();
        out
    }

    pub fn ops_for(device: Id, n: u64) -> Vec<Op> {
        let deps = Arc::new(Vv::new());
        (1..=n)
            .map(|seq| Op {
                id: OpId { device, seq },
                hlc: Hlc { wall: 1_000 + seq as i64, logical: 0, device },
                deps: deps.clone(),
                kind: crate::sync2::op::KIND_TAG_ADD,
                schema: SCHEMA,
                payload: Body::TagAdd { note: Key::of("n"), tag: format!("t{seq}") }.encode().into(),
                purged: false,
            })
            .collect()
    }

    #[test]
    fn pack_open_round_trip_plain_and_encrypted() {
        let dev = Id([5; 16]);
        let coll = Id([6; 16]);
        let signer = DeviceKey::generate();
        let ops = ops_for(dev, 50);
        for key in [None, Some(CollectionKey([3; 32]))] {
            let (h, bytes) = pack(coll, &ops, CHAIN_ZERO, &signer, key.as_ref()).unwrap();
            assert_eq!((h.first, h.last), (1, 50));
            let seg = open(&bytes, &signer.public(), key.as_ref()).unwrap();
            assert_eq!(seg.ops, ops);
            assert_eq!(peek_header(&bytes).unwrap(), h);
        }
    }

    #[test]
    fn chain_is_independent_of_how_ops_are_split_into_segments() {
        let dev = Id([5; 16]);
        let signer = DeviceKey::generate();
        let ops = ops_for(dev, 10);
        let (whole, _) = pack(Id::ZERO, &ops, CHAIN_ZERO, &signer, None).unwrap();
        let (a, _) = pack(Id::ZERO, &ops[..4], CHAIN_ZERO, &signer, None).unwrap();
        let (b, _) = pack(Id::ZERO, &ops[4..], a.last_chain, &signer, None).unwrap();
        assert_eq!(whole.last_chain, b.last_chain);
    }

    /// 极易压缩的操作（每条 [size] 字节全零）。
    fn zero_ops(device: Id, n: u64, size: usize) -> Vec<Op> {
        let deps = Arc::new(Vv::new());
        (1..=n)
            .map(|seq| Op {
                id: OpId { device, seq },
                hlc: Hlc { wall: seq as i64, logical: 0, device },
                deps: deps.clone(),
                kind: 9999,
                schema: crate::sync2::op::SCHEMA,
                payload: vec![0u8; size].into(),
                purged: false,
            })
            .collect()
    }

    /// 用任意段头与明文段体签一段（模拟签名者写出自相矛盾的段）。
    fn sign_raw(header: &SegmentHeader, plain: &[u8], signer: &DeviceKey) -> Vec<u8> {
        let mut hw = Writer::new();
        header.write(&mut hw);
        let head_bytes = hw.into_vec();
        let body = ruzstd::encoding::compress_to_vec(plain, ruzstd::encoding::CompressionLevel::Fastest);
        let mut signed = blake3::Hasher::new();
        signed.update(&head_bytes);
        signed.update(&body);
        let sig = signer.sign(signed.finalize().as_bytes());
        let mut out = head_bytes;
        let mut w = Writer::new();
        w.bytes(&body);
        out.extend_from_slice(&w.into_vec());
        out.extend_from_slice(&sig);
        out
    }

    #[test]
    fn oversized_segment_streams_through_a_small_window() {
        // 解压后 ~40 MB、压缩后几十 KB：旧版本只按压缩后体积切出来的那种段。
        let dev = Id([7; 16]);
        let signer = DeviceKey::generate();
        let ops = zero_ops(dev, 400, 100_000);
        let (_, bytes) = pack(Id::ZERO, &ops, CHAIN_ZERO, &signer, None).unwrap();
        assert!(bytes.len() < 1024 * 1024, "{}", bytes.len());
        let seg = open_verified(&bytes, &signer.public(), None).unwrap();
        let Verified::Stream(mut stream) = seg.verify().unwrap() else {
            panic!("an oversized segment must not be kept whole");
        };
        let mut n = 0usize;
        while let Some(op) = stream.next() {
            assert_eq!(op.unwrap(), ops[n]);
            n += 1;
            // 窗口只需装下一条（100 KB）：远小于整段明文。
            assert!(stream.window.window_capacity() <= 512 * 1024, "window grew to {}", stream.window.window_capacity());
        }
        assert_eq!(n, ops.len());
        // 小段校验那一遍就整段留下。
        let small = zero_ops(dev, 10, 1000);
        let (_, bytes) = pack(Id::ZERO, &small, CHAIN_ZERO, &signer, None).unwrap();
        let seg = open_verified(&bytes, &signer.public(), None).unwrap();
        assert!(matches!(seg.verify().unwrap(), Verified::Whole(_)));
    }

    #[test]
    fn oversized_segment_with_a_bad_chain_yields_nothing() {
        let dev = Id([8; 16]);
        let signer = DeviceKey::generate();
        let ops = zero_ops(dev, 400, 100_000);
        let mut header = SegmentHeader {
            encrypted: false,
            collection: Id::ZERO,
            device: dev,
            first: 1,
            last: 400,
            prev_chain: CHAIN_ZERO,
            last_chain: [9; 32],
        };
        let bytes = sign_raw(&header, &write_body(&ops), &signer);
        let seg = open_verified(&bytes, &signer.public(), None).unwrap();
        assert!(matches!(seg.verify(), Err(SegmentError::ChainMismatch)));
        // 段体多一个字节 / 少一条：格式错，不是截断后静默成功。
        header.last_chain = ops.iter().fold(CHAIN_ZERO, |c, op| chain_next(&c, op));
        let mut plain = write_body(&ops);
        plain.push(0);
        let bytes = sign_raw(&header, &plain, &signer);
        assert!(matches!(open(&bytes, &signer.public(), None), Err(SegmentError::Corrupt(_))));
        let bytes = sign_raw(&header, &write_body(&ops[..399]), &signer);
        assert!(matches!(open(&bytes, &signer.public(), None), Err(SegmentError::Corrupt(_))));
        let mut cut = write_body(&ops);
        cut.truncate(cut.len() - 10);
        let bytes = sign_raw(&header, &cut, &signer);
        assert!(matches!(open(&bytes, &signer.public(), None), Err(SegmentError::Corrupt(_))));
        assert_eq!(open(&sign_raw(&header, &write_body(&ops), &signer), &signer.public(), None).unwrap().ops, ops);
    }

    #[test]
    fn tampering_and_truncation_are_classified() {
        let dev = Id([5; 16]);
        let signer = DeviceKey::generate();
        let ops = ops_for(dev, 5);
        let (_, bytes) = pack(Id::ZERO, &ops, CHAIN_ZERO, &signer, None).unwrap();
        for n in 0..bytes.len() {
            assert!(open(&bytes[..n], &signer.public(), None).is_err());
        }
        let mut flipped = bytes.clone();
        let mid = flipped.len() / 2;
        flipped[mid] ^= 1;
        assert_eq!(open(&flipped, &signer.public(), None).unwrap_err(), SegmentError::BadSignature);
        let other = DeviceKey::generate();
        assert_eq!(open(&bytes, &other.public(), None).unwrap_err(), SegmentError::BadSignature);
        let (_, enc) = pack(Id::ZERO, &ops, CHAIN_ZERO, &signer, Some(&CollectionKey([1; 32]))).unwrap();
        assert_eq!(open(&enc, &signer.public(), None).unwrap_err(), SegmentError::Undecryptable);
        assert_eq!(open(&enc, &signer.public(), Some(&CollectionKey([2; 32]))).unwrap_err(), SegmentError::Undecryptable);
    }

    #[test]
    fn head_round_trip_and_signature() {
        let signer = DeviceKey::generate();
        let mut ack = Vv::new();
        ack.set(Id([9; 16]), 4);
        let head = Head {
            gen: 3,
            protocol: PROTOCOL,
            min_reader: MIN_READER,
            collection: Id([1; 16]),
            device: Id([2; 16]),
            public: signer.public(),
            seq: 30,
            chain: [7; 32],
            segments: vec![(1, 10, "aaaaaaaa".into()), (11, 30, "bbbbbbbb".into())],
            ack,
            digest: "abc".into(),
            at_ms: 123,
            name: "Pixel".into(),
        };
        let bytes = head.encode(&signer);
        assert_eq!(Head::decode(&bytes).unwrap(), head);
        let tampered = String::from_utf8(bytes).unwrap().replace("\"seq\":30", "\"seq\":31");
        assert!(Head::decode(tampered.as_bytes()).is_err());
    }

    #[test]
    fn file_names_sort_by_seq() {
        assert_eq!(parse_segment_file_name(&segment_file_name(3, 2000, "0a1b2c3d")), Some((3, 2000, "0a1b2c3d".into())));
        assert!(segment_file_name(9, 9, "ffffffff") < segment_file_name(10, 10, "00000000"));
        assert_eq!(parse_head_file_name(&head_file_name(42, "0a1b2c3d")), Some(42));
        assert_eq!(parse_segment_file_name("seg-1-0-00000000.bin"), None);
    }

    #[test]
    fn split_covers_every_op_contiguously_and_small_batches_stay_one_segment() {
        let ops = ops_for(Id([1; 16]), 4500);
        let r = split_ranges(&ops);
        // 几千条小操作压缩后远不到目标：一段。
        assert_eq!(r.len(), 1);
        assert_eq!((r[0].0, r[0].1), (1, 4500));
        assert!(r[0].2 > 0);
        assert!(split_ranges(&[]).is_empty());
    }

    #[test]
    fn split_cuts_by_compressed_size() {
        // 不可压缩的大载荷：每条 ~100 KB，目标 4 MB → 每段约 40 条，每段估计都不超过目标。
        let dev = Id([2; 16]);
        let deps = Arc::new(Vv::new());
        let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
        let ops: Vec<Op> = (1..=200u64)
            .map(|seq| {
                let payload: Vec<u8> = (0..100_000)
                    .map(|_| {
                        x ^= x << 13;
                        x ^= x >> 7;
                        x ^= x << 17;
                        x as u8
                    })
                    .collect();
                Op {
                    id: OpId { device: dev, seq },
                    hlc: Hlc { wall: seq as i64, logical: 0, device: dev },
                    deps: deps.clone(),
                    kind: 9999,
                    schema: SCHEMA,
                    payload: payload.into(),
                    purged: false,
                }
            })
            .collect();
        let r = split_ranges(&ops);
        assert!(r.len() >= 4 && r.len() <= 6, "{r:?}");
        let mut next = 1;
        for &(a, b, bytes) in &r {
            assert_eq!(a, next);
            assert!(bytes <= SEGMENT_TARGET_BYTES, "{bytes}");
            let (_, packed) = pack(Id::ZERO, &ops[(a - 1) as usize..b as usize], CHAIN_ZERO, &DeviceKey::generate(), None).unwrap();
            assert!((packed.len() as u64) < SEGMENT_TARGET_BYTES + 4096, "{}", packed.len());
            next = b + 1;
        }
        assert_eq!(next, 201);
    }

    #[test]
    fn split_caps_uncompressed_size_and_marks_raw_full_segments_full() {
        // 极易压缩的大载荷：每条 100 KB 全零、共 40 MB，压缩后只有几十 KB。只按压缩后体积切会是一段 40 MB 明文。
        let dev = Id([3; 16]);
        let deps = Arc::new(Vv::new());
        let ops: Vec<Op> = (1..=400u64)
            .map(|seq| Op {
                id: OpId { device: dev, seq },
                hlc: Hlc { wall: seq as i64, logical: 0, device: dev },
                deps: deps.clone(),
                kind: 9999,
                schema: SCHEMA,
                payload: vec![0u8; 100_000].into(),
                purged: false,
            })
            .collect();
        let r = split_ranges(&ops);
        assert!(r.len() >= 3, "{r:?}");
        let mut next = 1;
        for &(a, b, bytes) in &r {
            assert_eq!(a, next);
            let raw: u64 = ops[(a - 1) as usize..b as usize].iter().map(|o| o.payload.len() as u64 + 24).sum();
            assert!(raw <= SEGMENT_MAX_RAW_BYTES, "{raw}");
            let (_, packed) = pack(Id::ZERO, &ops[(a - 1) as usize..b as usize], CHAIN_ZERO, &DeviceKey::generate(), None).unwrap();
            assert!((packed.len() as u64) < SEGMENT_TARGET_BYTES / 8, "压缩后确实很小：{}", packed.len());
            if raw >= SEGMENT_MAX_RAW_BYTES / 2 {
                assert!(bytes >= SEGMENT_TARGET_BYTES / 2, "解压后过半的段按满段记，分层合并不再挑它：{bytes}");
            }
            next = b + 1;
        }
        assert_eq!(next, 401);
    }
}

#[cfg(test)]
mod size_tests {
    use super::*;
    use crate::sync2::id::Key;
    use crate::sync2::op::{tests::sample_log, Body, KIND_LOG, SCHEMA};

    /// 设计 §3.3 / §7.1 的体积量级：一段 2000 条真实形状的复习，压缩后平均每条在 40 字节以内。
    /// [n] 条真实形状的复习（300 张卡轮转）。
    fn sample_reviews(dev: Id, n: u64) -> Vec<Op> {
        let deps = Arc::new(Vv::new());
        let cards: Vec<Id> = (0..300).map(|i| Id::new_v7(1_600_000_000_000 + i)).collect();
        (1..=n)
            .map(|seq| {
                let at = 1_700_000_000_000 + seq as i64 * 9_000;
                let log = crate::sync2::op::LogBody {
                    id: Key::Uuid(Id::new_v7(at as u64)),
                    card: Key::Uuid(cards[(seq * 7 % 300) as usize]),
                    rating: Some(1 + (seq % 4) as i64),
                    at,
                    dur: 3_000 + (seq as i64 * 37) % 9_000,
                    ..sample_log()
                };
                Op {
                    id: OpId { device: dev, seq },
                    hlc: Hlc { wall: at, logical: 0, device: dev },
                    deps: deps.clone(),
                    kind: KIND_LOG,
                    schema: SCHEMA,
                    payload: Body::Log(log).encode().into(),
                    purged: false,
                }
            })
            .collect()
    }

    /// 段压缩往返（2026-10-30 断代）：段体是官方 zstd [SEGMENT_ZSTD_LEVEL] 档的标准帧，读端的 ruzstd 流式窗口解得开、
    /// 明文 / 加密都逐条原样回来；同一批复习比 ruzstd Fastest 小。
    #[test]
    fn segment_bodies_round_trip_through_level_three_zstd() {
        let signer = DeviceKey::generate();
        let ops = sample_reviews(Id::new_v7(1_700_000_000_000), 3000);
        let key = CollectionKey([5u8; 32]);
        for k in [None, Some(&key)] {
            let (header, bytes) = pack(Id::random(), &ops, CHAIN_ZERO, &signer, k).unwrap();
            let back = open(&bytes, &signer.public(), k).unwrap();
            assert_eq!(back.header, header);
            assert_eq!(back.ops, ops);
        }
        let raw = write_body(&ops);
        let fastest = ruzstd::encoding::compress_to_vec(&raw[..], ruzstd::encoding::CompressionLevel::Fastest).len();
        let now = compressed_len(&ops) as usize;
        assert!(now < fastest, "level {SEGMENT_ZSTD_LEVEL}: {now} bytes vs ruzstd fastest {fastest}");
        let mut plain = Vec::new();
        let frame = compress_body(&raw).unwrap();
        let mut d = ruzstd::decoding::StreamingDecoder::new(&frame[..]).unwrap();
        std::io::Read::read_to_end(&mut d, &mut plain).unwrap();
        assert_eq!(plain, raw);
    }

    #[test]
    fn reviews_compress_to_tens_of_bytes_each() {
        let dev = Id::new_v7(1_700_000_000_000);
        let deps = Arc::new(Vv::new());
        let cards: Vec<Id> = (0..300).map(|i| Id::new_v7(1_600_000_000_000 + i)).collect();
        let ops: Vec<Op> = (1..=2000u64)
            .map(|seq| {
                let at = 1_700_000_000_000 + seq as i64 * 9_000;
                let log = crate::sync2::op::LogBody {
                    id: Key::Uuid(Id::new_v7(at as u64)),
                    card: Key::Uuid(cards[(seq * 7 % 300) as usize]),
                    rating: Some(1 + (seq % 4) as i64),
                    at,
                    dur: 3_000 + (seq as i64 * 37) % 9_000,
                    ..sample_log()
                };
                Op {
                    id: OpId { device: dev, seq },
                    hlc: Hlc { wall: at, logical: 0, device: dev },
                    deps: deps.clone(),
                    kind: KIND_LOG,
                    schema: SCHEMA,
                    payload: Body::Log(log).encode().into(),
                    purged: false,
                }
            })
            .collect();
        let (_, bytes) = pack(Id::ZERO, &ops, CHAIN_ZERO, &DeviceKey::generate(), None).unwrap();
        let per = bytes.len() / ops.len();
        assert!(per <= 40, "{per} bytes per review after compression");
        // 体积估计（小块各自压缩之和）是上界，且不离谱。
        let est = compressed_len(&ops);
        assert!(est as usize + 512 >= bytes.len() && (est as usize) < bytes.len() * 2, "{est} vs {}", bytes.len());
    }

    /// 首次提交的量级：20 万条复习切出来只有几段（旧上限 64 KB / 2000 条时是上百段），每段都在目标以内。
    #[test]
    fn a_large_first_commit_is_a_handful_of_segments() {
        let dev = Id::new_v7(1_700_000_000_000);
        let deps = Arc::new(Vv::new());
        let cards: Vec<Id> = (0..5000).map(|i| Id::new_v7(1_600_000_000_000 + i)).collect();
        let mut s = Splitter::new();
        let n = 200_000u64;
        for seq in 1..=n {
            let at = 1_700_000_000_000 + seq as i64 * 9_000;
            let log = crate::sync2::op::LogBody {
                id: Key::Uuid(Id::new_v7(at as u64)),
                card: Key::Uuid(cards[(seq * 7919 % 5000) as usize]),
                rating: Some(1 + (seq % 4) as i64),
                at,
                dur: 3_000 + (seq as i64 * 37) % 9_000,
                ..sample_log()
            };
            s.push(Op {
                id: OpId { device: dev, seq },
                hlc: Hlc { wall: at, logical: 0, device: dev },
                deps: deps.clone(),
                kind: KIND_LOG,
                schema: SCHEMA,
                payload: Body::Log(log).encode().into(),
                purged: false,
            });
        }
        let r = s.finish();
        assert!(r.len() <= 4, "{} segments", r.len());
        assert_eq!(r.first().unwrap().0, 1);
        assert_eq!(r.last().unwrap().1, n);
        assert!(r.iter().all(|&(_, _, b)| b <= SEGMENT_TARGET_BYTES));
    }
}
