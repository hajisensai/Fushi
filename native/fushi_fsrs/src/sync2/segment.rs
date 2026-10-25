//! 段与 head（设计 §6.1、§7.3、§7.4）。
//!
//! **段**（`devices/<DeviceId>/seg-<first>-<last>.bin`）：一台设备连续 seq 区间的操作，写一次后不可变。
//!
//! ```text
//! 头（明文，参与签名，加密时作 AAD）
//!   "FSG2" | ver u8 | flags u8 (bit0 加密) | collection Id | device Id | first uv | last uv
//!   | prev_chain [32] | last_chain [32]
//! 体  zstd(操作增量编码)，加密时再 XChaCha20-Poly1305(nonce || ct)
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

use super::codec::{DResult, DecodeError, Reader, Writer};
use super::hlc::Hlc;
use super::id::Id;
use super::keys::{verify, CollectionKey, DeviceKey};
use super::op::Op;
use super::vv::{OpId, Vv};

pub const MAGIC: &[u8; 4] = b"FSG2";
pub const VERSION: u8 = 1;
pub const PROTOCOL: u32 = 1;
/// 能读本版本写出的数据所需的最低读者版本（设计 §8）。
pub const MIN_READER: u32 = 1;

/// 切段上限（设计 §6.2）：64 KB 未压缩或 2000 条，先到为准。
pub const SEGMENT_MAX_OPS: usize = 2000;
pub const SEGMENT_MAX_BYTES: usize = 64 * 1024;

pub type Chain = [u8; 32];
pub const CHAIN_ZERO: Chain = [0; 32];

/// 链的下一环。
pub fn chain_next(prev: &Chain, op: &Op) -> Chain {
    let mut h = blake3::Hasher::new();
    h.update(prev);
    h.update(&op.encode());
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
        w.bytes(&op.payload);
    }
    w.into_vec()
}

fn read_body(body: &[u8], device: Id, first: u64, last: u64) -> DResult<Vec<Op>> {
    let mut r = Reader::new(body);
    let n = r.uv()?;
    if n != last - first + 1 {
        return Err(DecodeError("segment op count"));
    }
    let mut out = Vec::with_capacity(n as usize);
    let mut wall = 0i64;
    let mut deps: Arc<Vv> = Arc::new(Vv::new());
    for i in 0..n {
        wall = wall.wrapping_add(r.iv()?);
        let logical = u32::try_from(r.uv()?).map_err(|_| DecodeError("hlc logical"))?;
        match r.u8()? {
            0 if i > 0 => {}
            1 => {
                let v = Vv::read(&mut r)?;
                if v.get(&device) != 0 {
                    return Err(DecodeError("op deps name its own device"));
                }
                deps = Arc::new(v);
            }
            _ => return Err(DecodeError("deps flag")),
        }
        let kind = u16::try_from(r.uv()?).map_err(|_| DecodeError("op kind"))?;
        let schema = u16::try_from(r.uv()?).map_err(|_| DecodeError("op schema"))?;
        let payload: Arc<[u8]> = r.bytes()?.into();
        out.push(Op {
            id: OpId { device, seq: first + i },
            hlc: Hlc { wall, logical, device },
            deps: deps.clone(),
            kind,
            schema,
            payload,
        });
    }
    if !r.is_empty() {
        return Err(DecodeError("trailing bytes in segment body"));
    }
    Ok(out)
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
    let compressed = ruzstd::encoding::compress_to_vec(&write_body(ops)[..], ruzstd::encoding::CompressionLevel::Fastest);
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

/// 只读段头（不验签、不解体）：列目录后按需决定要不要整段处理。
pub fn peek_header(bytes: &[u8]) -> Result<SegmentHeader, SegmentError> {
    Ok(SegmentHeader::read(&mut Reader::new(bytes))?)
}

/// 校验并解开一段：签名（[public]）→ 解密 → 解压 → 解码 → 重算链。
pub fn open(bytes: &[u8], public: &[u8; 32], key: Option<&CollectionKey>) -> Result<Segment, SegmentError> {
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
        k.open(body, &bytes[..head_len]).ok_or(SegmentError::Undecryptable)?
    } else {
        body.to_vec()
    };
    let plain = crate::zstd_decompress(&compressed).map_err(SegmentError::Corrupt)?;
    let ops = read_body(&plain, header.device, header.first, header.last)?;
    let mut chain = header.prev_chain;
    for op in &ops {
        chain = chain_next(&chain, op);
    }
    if chain != header.last_chain {
        return Err(SegmentError::ChainMismatch);
    }
    Ok(Segment { header, ops })
}

/// 按设计 §6.2 的上限把待上传的操作切成段区间（下标区间，左闭右开）。
pub fn split_ranges(ops: &[Op]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut bytes = 0usize;
    for (i, op) in ops.iter().enumerate() {
        let size = op.payload.len() + 24;
        if i > start && (i - start >= SEGMENT_MAX_OPS || bytes + size > SEGMENT_MAX_BYTES) {
            out.push((start, i));
            start = i;
            bytes = 0;
        }
        bytes += size;
    }
    if start < ops.len() {
        out.push((start, ops.len()));
    }
    out
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
    fn split_respects_both_limits() {
        let ops = ops_for(Id([1; 16]), 4500);
        let r = split_ranges(&ops);
        assert!(r.iter().all(|(a, b)| b - a <= SEGMENT_MAX_OPS));
        assert_eq!(r.first().unwrap().0, 0);
        assert_eq!(r.last().unwrap().1, 4500);
    }
}

#[cfg(test)]
mod size_tests {
    use super::*;
    use crate::sync2::id::Key;
    use crate::sync2::op::{tests::sample_log, Body, KIND_LOG, SCHEMA};

    /// 设计 §3.3 / §7.1 的体积量级：一段 2000 条真实形状的复习，压缩后平均每条在 40 字节以内。
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
                }
            })
            .collect();
        let (_, bytes) = pack(Id::ZERO, &ops, CHAIN_ZERO, &DeviceKey::generate(), None).unwrap();
        let per = bytes.len() / ops.len();
        assert!(per <= 40, "{per} bytes per review after compression");
    }
}
