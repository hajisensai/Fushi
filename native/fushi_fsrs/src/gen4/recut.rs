//! 协议 4 的重切中继件（第四波 K2，交接 §28「转发件被清除之后」）：转发者把一个作者段里**本机已彻底清除**的操作换成
//! 空洞、用**自己**的钥匙签出的那一份。
//!
//! ```text
//! "FRX4" | ver u8 = 1 | flags u8（bit0 内层用目标位置的密钥封装；其余必须为 0）| bytes(原段头) | recutter[16] | bytes(内层)
//! 内层（封装时 = XChaCha20-Poly1305：nonce[24] || 密文+tag，AAD = 前面的全部字节）
//!   = bytes(重切后的明文压缩体) | 重切者签名[64]
//! 签名 = Ed25519(重切者, blake3("fushi-srs-recut/4\n" || 原段头 || recutter || 明文压缩体))
//! ```
//!
//! # 为什么要有它
//!
//! 作者签名覆盖整段明文（[super::segment]、[super::relay]），转发者改不出空洞，只能原样搬或不搬。只靠「不搬」，一台设备
//! 清除了别人写的内容之后，只经它转发拿数据的位置就再也拿不到那位作者这一段——而清除者自己此后每条操作的依赖都点着
//! 那位作者的 seq，那些位置上的设备连清除者的后续操作都投不了（第三轮复核的 major）。重切件让清除者把空洞「重切」
//! 进那一段再转发：区间、文件名、段头的首尾链值都与原段相同（[super::segment] 文件头：空洞在段边界截断、首尾链值不因
//! 清除而变），读者按同名 `rly-` 拉到它，照原生段的规则落库（空洞落成空洞，本机已有的完整操作不因此被清掉）。
//!
//! # 信任口径
//!
//! 重切件的段头与内容由**重切者**签名担保，不是作者：空洞处的链值读侧验不了，空洞之前的操作对段尾链值也没有承诺
//! （[super::segment] 文件头）。读者（收段侧 `store/gen4/receive.rs`）因此要两样：
//!
//! 1. 重切者是**本机信任的**设备（没记过公钥 = 等它的 head，信任表里有它的行 = 等确认，同承袭段的上传者，D20）；
//! 2. 区间与链尾是**作者自己签过的**：本机记下的作者最新 head（`plan` 读到的，直接读到与被转发来的都算）的段清单里
//!    正好有 `(first, last, 链尾标签)` 这一段；`last` 正好是那份 head 的末端时，完整链值也要等于 head 的 `chain`。
//!    否则 `Defer::Unlisted`（作者的 head 还没读到时下一轮再试）。这一条封住了「以作者的名义写进作者还没写到的 seq」
//!    「编一个作者没签过的区间或链尾」——没有它，受信的重切者能抢占作者以后的日志，让所有读者上作者的日志分叉。
//!
//! **残余风险（如实记下，交接 §28）**：在作者列出的区间里，空洞之前的那些操作仍只由重切者担保——重切者可以把它们换成
//! 任意内容，末尾放一个空洞、链值填作者的真链尾，读者核不出来，伪造的内容以作者的 HLC 进冲突裁决，日后吊销重切者也
//! 撤不回。所以重切件给受信设备的权力**超过** Purge（Purge 只能把已有内容挖成空洞），只是被限制在作者已发布的区间里；
//! 链尾标签只有 4 字节，区间末不是 head 末端时，作者签名对链尾的承诺只有这 4 字节。根治要让读者从 `prev_chain` 一路
//! 重算到作者签的链尾：空洞对每条被挖掉的操作带「信封 + 载荷哈希」（`chain_next4` 的输入，链定义不变）、重切件里不再
//! 允许只带链值的重置空洞；前提是清除者在挖空之前把这两样存下（现在的日志空洞只留区间末链值，`recut_from_log` 拿不到），
//! 要动 schema，留给后续（交接 §28「没做」）。作者自己签的段到了之后，链值不接 = 分叉，照常报给 G8-6。
//!
//! 与中继件 `FRL4`、原生段 `FSG4` 互不误读：魔数不同；`open_any4` 不认本格式（作者签名的入口不会把它当作者签的段）。

use std::borrow::Cow;

use super::bytes_min;
use super::op::{chain_next4, native_allowed};
use super::segment::{NativeHeader, NativeItem, OpenNative, ZSTD_LEVEL, write_body};
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::id::Id;
use crate::sync2::keys::{CollectionKey, DeviceKey, verify};
use crate::sync2::segment::SegmentError;
use crate::sync2::vv::OpId;

pub const MAGIC: &[u8; 4] = b"FRX4";
pub const VERSION: u8 = 1;
/// 重切者签名原文的域前缀：与段签名、head 签名不会互相冒充。
const SIGN_DOMAIN: &[u8] = b"fushi-srs-recut/4\n";

const F_SEALED: u8 = 1;

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

/// 读前缀：`(前缀, 前缀字节长度 = 封装时的 AAD, 原段头字节)`。
fn read_prefix(bytes: &[u8]) -> Result<(RecutPrefix, usize, &[u8]), SegmentError> {
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
    let recutter = Id::read(&mut r)?;
    let prefix = RecutPrefix {
        sealed: flags & F_SEALED != 0,
        header,
        recutter,
    };
    Ok((prefix, r.pos, head))
}

/// 只读重切件的前缀（不验签、不解内层）。
pub fn peek_recut4(bytes: &[u8]) -> Result<RecutPrefix, SegmentError> {
    Ok(read_prefix(bytes)?.0)
}

fn digest(head: &[u8], recutter: &Id, compressed: &[u8]) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(SIGN_DOMAIN);
    h.update(head);
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
    recutter: &Id,
    compressed: &[u8],
    sig: &[u8; 64],
    dst_key: Option<&CollectionKey>,
) -> Vec<u8> {
    let mut inner = Writer::with_capacity(compressed.len() + 80);
    inner.bytes(compressed);
    inner.raw(sig);
    let inner = inner.into_vec();
    let mut w = Writer::with_capacity(head.len() + inner.len() + 64);
    w.raw(MAGIC);
    w.u8(VERSION);
    w.u8(if dst_key.is_some() { F_SEALED } else { 0 });
    w.bytes(head);
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

/// 核对重切后的项：从 [header] 的 `first` 起首尾相接地盖满到 `last`，操作是作者的、seq 对得上、原生日志允许的，
/// 没有相邻空洞，至少一个空洞（没有空洞的段没有重切的理由，原样转发作者签的那份），重算的链与段头的 `last_chain` 相同。
fn check(header: &NativeHeader, items: &[NativeItem]) -> Result<(), String> {
    if header.first == 0 || items.is_empty() {
        return Err("recut: empty segment".into());
    }
    let mut chain = header.prev_chain;
    let mut seq = header.first;
    let mut prev_void = false;
    let mut voids = 0usize;
    for item in items {
        match item {
            NativeItem::Op(op) => {
                if op.id
                    != (OpId {
                        device: header.device,
                        seq,
                    })
                    || op.hlc.device != header.device
                {
                    return Err("recut: ops must be the author's contiguous seqs".into());
                }
                native_allowed(op)?;
                chain = chain_next4(&chain, op);
                prev_void = false;
            }
            NativeItem::Void { count, chain_after } => {
                if *count == 0 {
                    return Err("recut: empty void".into());
                }
                if prev_void {
                    return Err("recut: adjacent voids must be merged".into());
                }
                chain = *chain_after;
                prev_void = true;
                voids += 1;
            }
        }
        seq = seq.checked_add(item.span()).ok_or("recut: seq overflow")?;
    }
    if seq - 1 != header.last {
        return Err("recut: items do not cover the segment's range".into());
    }
    if voids == 0 {
        return Err("recut: nothing voided".into());
    }
    if chain != header.last_chain {
        return Err("recut: chain does not end at the segment's last chain".into());
    }
    Ok(())
}

/// 重切一段：[header] = 原段头（区间、首尾链值不变），[items] = 已把本机清除过的操作换成空洞（相邻空洞已合并）的全部项，
/// [recutter] / [recutter_id] = 本机的签名钥匙与设备 ID，[dst_key] = 目标位置的密钥（存进本机转发缓存时为 None）。
pub fn recut4(
    header: &NativeHeader,
    items: &[NativeItem],
    recutter: &DeviceKey,
    recutter_id: Id,
    dst_key: Option<&CollectionKey>,
) -> Result<Vec<u8>, String> {
    check(header, items)?;
    let compressed = zstd::bulk::compress(&write_body(items), ZSTD_LEVEL)
        .map_err(|e| format!("recut compress: {e}"))?;
    let head = head_bytes(header);
    let sig = recutter.sign(&digest(&head, &recutter_id, &compressed));
    Ok(assemble(&head, &recutter_id, &compressed, &sig, dst_key))
}

/// 解开、验**重切者**签名（不解压）。[recutter_public] 是前缀里 `recutter` 的公钥（调用方先按 [peek_recut4] 取设备、
/// 核对信任），[key] 是它所在位置的密钥。交回的段与 `open_native_verified` 同型：调用方照常 `verify()` 重算链。
pub fn open_recut4<'a>(
    bytes: &'a [u8],
    recutter_public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<OpenNative<'a>, SegmentError> {
    let (prefix, aad_len, head) = read_prefix(bytes)?;
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
        &digest(head, &prefix.recutter, &inner[start..end]),
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
    Ok(OpenNative::vouched(
        prefix.header,
        compressed,
        sig,
        prefix.sealed,
    ))
}

/// 换一把目标钥匙再包（验签 + 重算链之后；签名不变，仍是原重切者的）。[src_key] = [bytes] 所在位置的密钥。
pub fn rewrap_recut4(
    bytes: &[u8],
    recutter_public: &[u8; 32],
    src_key: Option<&CollectionKey>,
    dst_key: Option<&CollectionKey>,
) -> Result<Vec<u8>, SegmentError> {
    let recutter = peek_recut4(bytes)?.recutter;
    let open = open_recut4(bytes, recutter_public, src_key)?;
    open.verify()?;
    let (head, compressed, sig) = open.signed_parts();
    Ok(assemble(&head, &recutter, compressed, sig, dst_key))
}

/// 重切件的完整校验结果（测试与调用方共用的简写）：前缀 + 全部项。
pub fn open_recut4_items(
    bytes: &[u8],
    recutter_public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<(RecutPrefix, Vec<NativeItem>), SegmentError> {
    let prefix = peek_recut4(bytes)?;
    let seg = open_recut4(bytes, recutter_public, key)?;
    let items = seg
        .verify()?
        .collect::<Result<Vec<NativeItem>, SegmentError>>()?;
    Ok((prefix, items))
}

/// 把 [items]（从 [first] 起）里 seq = [seq] 的那条操作换成空洞，与两侧的空洞合并（[super::segment]：相邻空洞写者
/// 合并）。[prev_chain] = `first - 1` 处的链值。那里本来就是空洞、或不在这段里 = None（不用重切）。
pub fn void_one(
    items: &[NativeItem],
    first: u64,
    prev_chain: crate::sync2::segment::Chain,
    seq: u64,
) -> Option<Vec<NativeItem>> {
    let mut out: Vec<NativeItem> = Vec::with_capacity(items.len());
    let mut chain = prev_chain;
    let mut at = first;
    let mut hit = false;
    for item in items {
        let next = match item {
            NativeItem::Op(op) => chain_next4(&chain, op),
            NativeItem::Void { chain_after, .. } => *chain_after,
        };
        let voided = match item {
            NativeItem::Op(_) if at == seq => {
                hit = true;
                Some(1)
            }
            NativeItem::Op(_) => None,
            NativeItem::Void { count, .. } => Some(*count),
        };
        match (voided, out.last_mut()) {
            (
                Some(n),
                Some(NativeItem::Void {
                    count,
                    chain_after: c,
                }),
            ) => {
                *count += n;
                *c = next;
            }
            (Some(n), _) => out.push(NativeItem::Void {
                count: n,
                chain_after: next,
            }),
            (None, _) => out.push(item.clone()),
        }
        chain = next;
        at += item.span();
    }
    hit.then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::op::tests::id;
    use crate::gen4::relay::{open_any4, wrap_relay4};
    use crate::gen4::segment::tests::{DEV, chain_of, coll, items_of, ops, signer};
    use crate::gen4::segment::{open_native, pack_native};

    fn k1() -> CollectionKey {
        CollectionKey([5; 32])
    }

    fn k2() -> CollectionKey {
        CollectionKey([6; 32])
    }

    /// 与作者（`segment::tests::signer`，种子 7）不同的钥匙：作者公钥验不过重切件。
    fn recutter() -> DeviceKey {
        DeviceKey::from_seed(&[0x5b; 32])
    }

    const RC: u8 = 0xb7;

    /// 原段（五条操作）与把第 [seq] 条换成空洞之后的项。
    fn original_and_voided(seq: u64) -> (NativeHeader, Vec<NativeItem>, Vec<NativeItem>) {
        let items = items_of(&ops());
        let (header, _) =
            pack_native(coll(), id(DEV), 1, &items, [0; 32], &signer(), None).unwrap();
        let voided = void_one(&items, 1, [0; 32], seq).unwrap();
        (header, items, voided)
    }

    /// 重切后区间与首尾链值不变，读出的项就是换掉的那些；明文 / 封装两种都对，换钥匙再包签名不变。
    #[test]
    fn a_recut_keeps_the_range_and_chains_and_round_trips_under_any_key() {
        for seq in 1..=5 {
            let (header, _, voided) = original_and_voided(seq);
            assert_eq!(voided.iter().map(NativeItem::span).sum::<u64>(), 5);
            for dk in [None, Some(&k1())] {
                let bytes = recut4(&header, &voided, &recutter(), id(RC), dk).unwrap();
                assert!(bytes.starts_with(MAGIC));
                let p = peek_recut4(&bytes).unwrap();
                assert_eq!(
                    (p.sealed, &p.header, p.recutter),
                    (dk.is_some(), &header, id(RC))
                );
                let (_, back) = open_recut4_items(&bytes, &recutter().public(), dk).unwrap();
                assert_eq!(back, voided);
                let again = rewrap_recut4(&bytes, &recutter().public(), dk, Some(&k2())).unwrap();
                let (_, back) =
                    open_recut4_items(&again, &recutter().public(), Some(&k2())).unwrap();
                assert_eq!(back, voided);
                let plain = rewrap_recut4(&again, &recutter().public(), Some(&k2()), None).unwrap();
                assert_eq!(
                    plain,
                    recut4(&header, &voided, &recutter(), id(RC), None).unwrap(),
                    "the same bytes whatever hands it went through"
                );
            }
        }
    }

    /// 相邻空洞合并：第 2、3 条依次清除，得到一个两条的空洞，链值是第 3 条处的。
    #[test]
    fn voiding_next_to_a_void_merges_them() {
        let ops = ops();
        let items = items_of(&ops);
        let one = void_one(&items, 1, [0; 32], 2).unwrap();
        let two = void_one(&one, 1, [0; 32], 3).unwrap();
        assert_eq!(
            two[1],
            NativeItem::Void {
                count: 2,
                chain_after: chain_of([0; 32], &ops[..3]),
            }
        );
        assert_eq!(two.len(), 4);
        assert!(void_one(&two, 1, [0; 32], 2).is_none(), "already a void");
        assert!(
            void_one(&two, 1, [0; 32], 9).is_none(),
            "not in the segment"
        );
    }

    /// 重切件只认重切者的签名：作者公钥、别的钥匙验不过；内容被改（重新压缩一份伪造的体、留着原签名）验不过；
    /// 前缀里换一个重切者 ID 验不过（ID 在签名里）；作者签名的入口不认它。
    #[test]
    fn only_the_recutters_signature_opens_it() {
        let (header, items, voided) = original_and_voided(2);
        let bytes = recut4(&header, &voided, &recutter(), id(RC), None).unwrap();
        assert_eq!(
            open_recut4(&bytes, &signer().public(), None).err(),
            Some(SegmentError::BadSignature)
        );
        assert!(open_any4(&bytes, &recutter().public(), None).is_err());
        assert!(wrap_relay4(&bytes, &recutter().public(), None, None).is_err());
        // 伪造体：把原段的内容原样塞进重切件、留着重切者对空洞版的签名。
        let mut fake = bytes.clone();
        let sig: Vec<u8> = bytes[bytes.len() - 64..].to_vec();
        let forged = zstd::bulk::compress(&write_body(&items), ZSTD_LEVEL).unwrap();
        let (_, aad, _) = read_prefix(&bytes).unwrap();
        fake.truncate(aad);
        let mut inner = Writer::new();
        inner.bytes(&forged);
        inner.raw(&sig);
        let mut w = Writer::new();
        w.bytes(&inner.into_vec());
        fake.extend_from_slice(&w.into_vec());
        assert_eq!(
            open_recut4(&fake, &recutter().public(), None).err(),
            Some(SegmentError::BadSignature)
        );
        // 换重切者 ID：前缀里的 16 字节就在 AAD 末尾。
        let mut other = bytes.clone();
        other[aad - 1] ^= 1;
        assert_eq!(
            open_recut4(&other, &recutter().public(), None).err(),
            Some(SegmentError::BadSignature)
        );
        // 封装的件没钥匙解不开，拿错钥匙同样。
        let sealed = recut4(&header, &voided, &recutter(), id(RC), Some(&k1())).unwrap();
        assert_eq!(
            open_recut4(&sealed, &recutter().public(), None).err(),
            Some(SegmentError::Undecryptable)
        );
        assert_eq!(
            open_recut4(&sealed, &recutter().public(), Some(&k2())).err(),
            Some(SegmentError::Undecryptable)
        );
    }

    /// 写的一侧拒：没有空洞（不用重切）、链接不上段头、盖不满区间、相邻空洞没合并、操作不是作者的。
    #[test]
    fn recut_refuses_what_is_not_a_recut_of_that_segment() {
        let (header, items, voided) = original_and_voided(3);
        let r = |h: &NativeHeader, i: &[NativeItem]| recut4(h, i, &recutter(), id(RC), None);
        assert!(r(&header, &items).is_err(), "nothing voided");
        let mut wrong = voided.clone();
        if let NativeItem::Void { chain_after, .. } = &mut wrong[2] {
            *chain_after = [9; 32];
        }
        assert!(r(&header, &wrong).is_err(), "chain");
        assert!(r(&header, &voided[..4]).is_err(), "range");
        let split = vec![
            items[0].clone(),
            items[1].clone(),
            NativeItem::Void {
                count: 1,
                chain_after: chain_of([0; 32], &ops()[..3]),
            },
            NativeItem::Void {
                count: 1,
                chain_after: chain_of([0; 32], &ops()[..4]),
            },
            items[4].clone(),
        ];
        assert!(r(&header, &split).is_err(), "adjacent voids");
        let mut other = header.clone();
        other.device = id(0x99);
        assert!(r(&other, &voided).is_err(), "not the author's ops");
    }

    /// 读者照原生段的规则解：重切件里的项与原段在活的操作上逐条相同，空洞处没有内容。
    #[test]
    fn the_live_ops_are_the_authors() {
        let (header, items, voided) = original_and_voided(4);
        let (_, seg) = pack_native(coll(), id(DEV), 1, &items, [0; 32], &signer(), None).unwrap();
        let (h, orig) = open_native(&seg, &signer().public(), None).unwrap();
        assert_eq!(h, header);
        let bytes = recut4(&header, &voided, &recutter(), id(RC), None).unwrap();
        let (_, back) = open_recut4_items(&bytes, &recutter().public(), None).unwrap();
        let live: Vec<&NativeItem> = orig
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != 3)
            .map(|(_, x)| x)
            .collect();
        let got: Vec<&NativeItem> = back
            .iter()
            .filter(|x| matches!(x, NativeItem::Op(_)))
            .collect();
        assert_eq!(got, live);
    }

    /// 解码严格：魔数 / 版本 / 标志位 / 尾随字节。
    #[test]
    fn open_is_strict() {
        let (header, _, voided) = original_and_voided(1);
        let bytes = recut4(&header, &voided, &recutter(), id(RC), None).unwrap();
        let rp = recutter().public();
        let mut b = bytes.clone();
        b[0] = b'Z';
        assert!(open_recut4(&b, &rp, None).is_err());
        let mut b = bytes.clone();
        b[4] = 2;
        assert!(open_recut4(&b, &rp, None).is_err());
        let mut b = bytes.clone();
        b[5] = 2;
        assert!(open_recut4(&b, &rp, None).is_err());
        let mut b = bytes.clone();
        b.push(0);
        assert!(open_recut4(&b, &rp, None).is_err());
    }
}
