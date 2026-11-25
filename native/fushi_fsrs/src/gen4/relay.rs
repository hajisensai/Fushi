//! 协议 4 的中继件（设计 §4.2「中继不变」、§10 第 16 条；实现拆分 G8-2，所有者定案 D16-A）。
//!
//! 中继件 = 作者（段头的 `device`）签过的一个原生段，由持有它的设备原样搬到作者自己没去过的位置
//! （位置布局由 G8-1 定：`v4/devices/<作者>/rly-<first>-<last>-<tag8>.bin`）。纯编解码，没有接进任何同步路径。
//!
//! ```text
//! "FRL4" | ver u8 = 1 | flags u8（bit0 内层用目标位置的密钥封装；其余必须为 0）| bytes(原段头) | bytes(内层)
//! 内层（封装时 = XChaCha20-Poly1305：nonce[24] || 密文+tag，AAD = 前面的全部字节）
//!   = bytes(原段的明文压缩体) | 原签名[64]
//! ```
//!
//! 搬的是作者签过的那三样：原段头、明文压缩体、签名。原生段的签名覆盖 `blake3(头 || 明文压缩体)`、加密在签名外面
//! （[super::segment] 文件头，D16-A），所以：
//!
//! - 读者用**作者**公钥直接验原签名，再用段头里由签名担保的 `prev_chain` → `last_chain` 重算链——与读原段同一套代码
//!   （[super::segment::OpenNative::verify]）。
//! - **含空洞的段也能跨钥匙转发**：空洞处的链值读侧验不了，但它在作者签名覆盖的明文里，转发者把操作换成空洞（哪怕接上
//!   真实链值）签名就不符。协议 3 的 `FSRL` 是「签名覆盖密文 + 明文靠链校验」，遇到空洞这一步可以伪造，所以不沿用。
//! - 原段的密文不随件搬：目标位置钥匙不同，旧密文对它没有用；转发者需要原位置的密钥才解得出明文压缩体。
//! - 目标位置加密时整个内层用目标位置的密钥封装，明文不落到加密位置上。目标位置是否加密由调用方决定（这里只照
//!   `dst_key` 封或不封；读者从 [OpenNative::stored_sealed]（等于 [RelayPrefix::sealed]）看得到件是否封装，由同步层
//!   核对它与位置的加密状态；段头里的 `encrypted` 说的是原段所在位置，不能拿来核对）。
//!
//! 与协议 3 互不误读：魔数不同。协议 3 的读者（`crate::sync2::segment` 的 `peek_header` / `open` / `relay_unwrap`）
//! 在魔数处拒绝本格式；本模块同样拒绝 `FSRL`、`FSG2`，也不把一个原生段 `FSG4` 当中继件读（[open_relay4] 只认 `FRL4`；
//! 两种都收的入口是 [open_any4]）。解码只收规范形：长度前缀取最短 varint、原段头必须恰好占满它的长度、内外层都不许有尾随字节。

use std::borrow::Cow;

use super::bytes_min;
use super::segment::{self, NativeHeader, OpenNative, open_native_verified, open_signed};
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::keys::CollectionKey;
use crate::sync2::segment::SegmentError;

pub const MAGIC: &[u8; 4] = b"FRL4";
pub const VERSION: u8 = 1;

const F_SEALED: u8 = 1;

/// 中继件的明文前缀（不验签、不解内层）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayPrefix {
    /// 内层是否用所在位置的密钥封装。
    pub sealed: bool,
    /// 原段头（作者签过的；未验签前只能当提示用）。
    pub header: NativeHeader,
}

/// 读前缀：`(前缀, 前缀字节长度 = 封装时的 AAD, 原段头字节)`。
fn read_prefix(bytes: &[u8]) -> Result<(RelayPrefix, usize, &[u8]), SegmentError> {
    let mut r = Reader::new(bytes);
    if r.raw(4)? != MAGIC {
        return Err(SegmentError::Corrupt("relay magic".into()));
    }
    if r.u8()? != VERSION {
        return Err(SegmentError::Corrupt("relay version".into()));
    }
    let flags = r.u8()?;
    if flags & !F_SEALED != 0 {
        return Err(SegmentError::Corrupt("relay flags".into()));
    }
    let head = bytes_min(&mut r)?;
    let mut hr = Reader::new(head);
    let header = NativeHeader::read(&mut hr)?;
    if !hr.is_empty() {
        return Err(SegmentError::Corrupt("relay head trailing bytes".into()));
    }
    let prefix = RelayPrefix {
        sealed: flags & F_SEALED != 0,
        header,
    };
    Ok((prefix, r.pos, head))
}

/// 只读中继件的前缀（不验签、不解内层）：列目录后按需决定要不要整件处理。
pub fn peek_relay4(bytes: &[u8]) -> Result<RelayPrefix, SegmentError> {
    Ok(read_prefix(bytes)?.0)
}

/// 解开、验签一个中继件（不解压）。[public] 是**作者**（原段头的 `device`）的公钥，[key] 是中继件**所在位置**的密钥。
/// 交回的段与 [open_native_verified] 的同型：调用方照常 `verify()` 重算链。
pub fn open_relay4<'a>(
    bytes: &'a [u8],
    public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<OpenNative<'a>, SegmentError> {
    let (prefix, aad_len, head) = read_prefix(bytes)?;
    let mut r = Reader::new(&bytes[aad_len..]);
    let inner_raw = bytes_min(&mut r)?;
    if !r.is_empty() {
        return Err(SegmentError::Corrupt("relay trailing bytes".into()));
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
            .map_err(|_| SegmentError::Corrupt("relay sig".into()))?;
        if !ir.is_empty() {
            return Err(SegmentError::Corrupt("relay inner trailing bytes".into()));
        }
        (start, end, sig)
    };
    let compressed: Cow<'a, [u8]> = match inner {
        Cow::Borrowed(b) => Cow::Borrowed(&b[start..end]),
        Cow::Owned(mut v) => {
            v.truncate(end);
            v.drain(..start);
            Cow::Owned(v)
        }
    };
    open_signed(head, prefix.header, compressed, &sig, public, prefix.sealed)
}

/// 解开、验签一个原生段或中继件（按魔数分派；别的魔数一律拒）。[key] 是它所在位置的密钥。交回的
/// [OpenNative::stored_sealed] 是这份字节落盘时是否加密，两种格式口径相同，同步层据它核对位置的加密状态。
pub fn open_any4<'a>(
    bytes: &'a [u8],
    public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<OpenNative<'a>, SegmentError> {
    if bytes.starts_with(MAGIC) {
        open_relay4(bytes, public, key)
    } else {
        open_native_verified(bytes, public, key)
    }
}

/// 打包一个中继件。[seg] = 收到的原生段或中继件，[public] = 作者公钥，[src_key] = [seg] 所在位置的密钥，
/// [dst_key] = 目标位置的密钥。
///
/// 包之前完整校验一遍（签名 + 链）：转发者不替别人搬自己都验不过的字节。原段加密而没给 [src_key] 时拒
/// （[SegmentError::Undecryptable]）。从原段包和从中继件再包，产出的内层相同（封装时 nonce 不同）。
pub fn wrap_relay4(
    seg: &[u8],
    public: &[u8; 32],
    src_key: Option<&CollectionKey>,
    dst_key: Option<&CollectionKey>,
) -> Result<Vec<u8>, SegmentError> {
    let open = open_any4(seg, public, src_key)?;
    open.verify()?;
    let (head, compressed, sig) = open.signed_parts();
    let mut inner = Writer::with_capacity(compressed.len() + 80);
    inner.bytes(compressed);
    inner.raw(sig);
    let inner = inner.into_vec();
    let mut w = Writer::with_capacity(head.len() + inner.len() + 64);
    w.raw(MAGIC);
    w.u8(VERSION);
    w.u8(if dst_key.is_some() { F_SEALED } else { 0 });
    w.bytes(&head);
    let mut out = w.into_vec();
    let sealed = match dst_key {
        Some(k) => k.seal(&inner, &out),
        None => inner,
    };
    let mut w = Writer::with_capacity(sealed.len() + 8);
    w.bytes(&sealed);
    out.extend_from_slice(&w.into_vec());
    Ok(out)
}

/// 中继件所搬原段的完整校验结果（测试与调用方共用的简写）：头 + 全部项。
pub fn open_relay4_items(
    bytes: &[u8],
    public: &[u8; 32],
    key: Option<&CollectionKey>,
) -> Result<(NativeHeader, Vec<segment::NativeItem>), SegmentError> {
    let seg = open_relay4(bytes, public, key)?;
    let items = seg
        .verify()?
        .collect::<Result<Vec<segment::NativeItem>, SegmentError>>()?;
    Ok((seg.header, items))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::op::chain_next4;
    use crate::gen4::op::tests::id;
    use crate::gen4::segment::tests::{
        DEV, GOLDEN_FILE, GOLDEN_FILE_SEALED, assemble, chain_of, coll, golden_items, items_of,
        ops, signer, v3_segment,
    };
    use crate::gen4::segment::{NativeItem, open_native, pack_native, write_body};
    use crate::gen4::{golden, unhex};
    use crate::sync2::codec::Writer;
    use crate::sync2::keys::DeviceKey;
    use crate::sync2::segment as v3;

    fn k_src() -> CollectionKey {
        CollectionKey([3; 32])
    }

    fn k_dst() -> CollectionKey {
        CollectionKey([4; 32])
    }

    /// 1 活、2–3 清除、4 活、5 清除。
    fn voided_items() -> Vec<NativeItem> {
        let ops = ops();
        let c1 = chain_of([0; 32], &ops[..1]);
        let c3 = chain_of(c1, &ops[1..3]);
        let c5 = chain_of(c3, &ops[3..5]);
        vec![
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
        ]
    }

    fn pack(items: &[NativeItem], key: Option<&CollectionKey>) -> (NativeHeader, Vec<u8>) {
        pack_native(coll(), id(DEV), 1, items, [0; 32], &signer(), key).unwrap()
    }

    /// 无空洞、有空洞两种段，明文 / 加密 → 明文 / 加密四种组合：读出的头与项和原段逐槽相同。
    #[test]
    fn four_key_combinations_round_trip_with_and_without_voids() {
        let (src, dst) = (k_src(), k_dst());
        for items in [items_of(&ops()), voided_items()] {
            for sk in [None, Some(&src)] {
                let (header, seg) = pack(&items, sk);
                for dk in [None, Some(&dst)] {
                    let relay = wrap_relay4(&seg, &signer().public(), sk, dk).unwrap();
                    assert!(relay.starts_with(MAGIC));
                    let prefix = peek_relay4(&relay).unwrap();
                    assert_eq!(prefix.sealed, dk.is_some());
                    assert_eq!(prefix.header, header);
                    let (h, back) = open_relay4_items(&relay, &signer().public(), dk).unwrap();
                    assert_eq!(h, header);
                    assert_eq!(back, items);
                    // 两种都收的入口一样。
                    let any = open_any4(&relay, &signer().public(), dk).unwrap();
                    assert_eq!(any.verify().unwrap().count(), items.len());
                    // 再转一手（中继件 → 中继件，换回源钥匙）：仍逐槽相同。
                    let again = wrap_relay4(&relay, &signer().public(), dk, sk).unwrap();
                    assert_eq!(
                        open_relay4_items(&again, &signer().public(), sk).unwrap().1,
                        items
                    );
                }
            }
        }
    }

    /// 从原段包和从中继件再包：未封装时字节完全相同（内层就是作者签过的那三样，与经过几手无关）。
    #[test]
    fn rewrapping_is_stable() {
        let (src, dst) = (k_src(), k_dst());
        let (_, seg) = pack(&voided_items(), Some(&src));
        let direct = wrap_relay4(&seg, &signer().public(), Some(&src), None).unwrap();
        let sealed = wrap_relay4(&seg, &signer().public(), Some(&src), Some(&dst)).unwrap();
        let via = wrap_relay4(&sealed, &signer().public(), Some(&dst), None).unwrap();
        assert_eq!(direct, via);
    }

    /// 转发者把明文体里的操作换成空洞、接上真实链值：链校验本身拦不住（段头的首尾链值不变），作者的签名拦得住。
    #[test]
    fn forging_a_void_over_an_op_fails_the_signature() {
        let ops = ops();
        let real = items_of(&ops);
        let c3 = chain_of([0; 32], &ops[..3]);
        let mut forged = real.clone();
        forged.splice(
            1..3,
            [NativeItem::Void {
                count: 2,
                chain_after: c3,
            }],
        );
        // 只看链：伪造的体与原段的首尾链值完全相同——协议 3 那种「明文 + 链校验」的转发件会收下它。
        let (h_real, seg) = pack(&real, None);
        let forger = DeviceKey::from_seed(&[9; 32]);
        let (h_forged, _) =
            pack_native(coll(), id(DEV), 1, &forged, [0; 32], &forger, None).unwrap();
        assert_eq!(h_forged, h_real);
        // 拿作者真签名拼一个中继件：验不过。
        let open = open_native_verified(&seg, &signer().public(), None).unwrap();
        let (head, _, sig) = open.signed_parts();
        let compressed = zstd::bulk::compress(&write_body(&forged), 3).unwrap();
        let mut inner = Writer::new();
        inner.bytes(&compressed);
        inner.raw(sig);
        let mut w = Writer::new();
        w.raw(MAGIC);
        w.u8(VERSION);
        w.u8(0);
        w.bytes(&head);
        w.bytes(&inner.into_vec());
        let fake = w.into_vec();
        assert_eq!(
            open_relay4(&fake, &signer().public(), None).err().unwrap(),
            SegmentError::BadSignature
        );
        // 包装入口同样拒（包之前先验）。
        assert_eq!(
            wrap_relay4(&fake, &signer().public(), None, None).unwrap_err(),
            SegmentError::BadSignature
        );
        // 有位置密钥的人重新加密一份伪造的明文、留着作者签名：原段的读法同样验不过（签名覆盖明文，不是密文）。
        let src = k_src();
        let (_, enc) = pack(&real, Some(&src));
        let mut r = Reader::new(&enc);
        NativeHeader::read(&mut r).unwrap();
        let head_len = r.pos;
        let mut w = Writer::new();
        w.raw(&enc[..head_len]);
        w.bytes(&src.seal(&compressed, &enc[..head_len]));
        w.raw(&enc[enc.len() - 64..]);
        assert_eq!(
            open_native(&w.into_vec(), &signer().public(), Some(&src)).unwrap_err(),
            SegmentError::BadSignature
        );
    }

    #[test]
    fn wrap_refuses_what_it_cannot_verify() {
        let src = k_src();
        let (_, seg) = pack(&voided_items(), Some(&src));
        let other = DeviceKey::from_seed(&[8; 32]).public();
        // 公钥不是作者的。
        assert_eq!(
            wrap_relay4(&seg, &other, Some(&src), None).unwrap_err(),
            SegmentError::BadSignature
        );
        // 原段加密而没有 / 拿错原位置的密钥。
        assert_eq!(
            wrap_relay4(&seg, &signer().public(), None, None).unwrap_err(),
            SegmentError::Undecryptable
        );
        assert_eq!(
            wrap_relay4(&seg, &signer().public(), Some(&k_dst()), None).unwrap_err(),
            SegmentError::Undecryptable
        );
        // 签名有效、链对不上。
        let ops = ops();
        let mut h = NativeHeader {
            encrypted: false,
            collection: coll(),
            device: id(DEV),
            first: 1,
            last: 5,
            prev_chain: [0; 32],
            last_chain: chain_of([0; 32], &ops),
        };
        h.last_chain = [1; 32];
        let bad = assemble(&h, &write_body(&items_of(&ops)), None);
        assert_eq!(
            wrap_relay4(&bad, &signer().public(), None, None).unwrap_err(),
            SegmentError::ChainMismatch
        );
        // 协议 3 的段与转发件、乱码。
        let magic = SegmentError::Corrupt("segment magic".into());
        let v3seg = v3_segment();
        let v3relay = v3::relay_pack(&v3seg, None, None).unwrap();
        for b in [&v3seg[..], &v3relay[..], b"junk"] {
            assert_eq!(
                wrap_relay4(b, &signer().public(), None, None).unwrap_err(),
                magic
            );
        }
    }

    /// 所有者的硬要求：新旧格式互拒。协议 3 的读者拒 `FRL4`，本格式的读者拒 `FSRL` / `FSG2`；原生段与中继件也不互相冒充。
    #[test]
    fn protocol_3_and_protocol_4_relays_reject_each_other() {
        let src = k_src();
        for k in [None, Some(&src)] {
            let (_, seg) = pack(&items_of(&ops()), None);
            let relay = wrap_relay4(&seg, &signer().public(), None, k).unwrap();
            let magic = SegmentError::Corrupt("segment magic".into());
            assert_eq!(v3::peek_header(&relay).unwrap_err(), magic);
            assert_eq!(
                v3::open_verified(&relay, &signer().public(), k)
                    .err()
                    .unwrap(),
                magic
            );
            assert_eq!(v3::open(&relay, &signer().public(), k).unwrap_err(), magic);
            assert_eq!(
                v3::relay_unwrap(&relay, k).unwrap_err(),
                SegmentError::Corrupt("relay magic".into())
            );
            assert!(v3::relay_pack(&relay, None, k).is_err());
            // 原生段的读法不收中继件。
            assert_eq!(
                open_native(&relay, &signer().public(), k).unwrap_err(),
                magic
            );
        }
        let v3seg = v3_segment();
        let v3relay = v3::relay_pack(&v3seg, None, None).unwrap();
        let relay_magic = SegmentError::Corrupt("relay magic".into());
        for b in [&v3seg[..], &v3relay[..]] {
            assert_eq!(peek_relay4(b).unwrap_err(), relay_magic);
            assert_eq!(
                open_relay4(b, &signer().public(), None).err().unwrap(),
                relay_magic
            );
            assert_eq!(
                open_any4(b, &signer().public(), None).err().unwrap(),
                SegmentError::Corrupt("segment magic".into())
            );
        }
        // 中继件的读法不收原生段。
        let (_, seg) = pack(&items_of(&ops()), None);
        assert_eq!(
            open_relay4(&seg, &signer().public(), None).err().unwrap(),
            relay_magic
        );
    }

    #[test]
    fn open_is_strict() {
        let (_, seg) = pack(&voided_items(), None);
        let relay = wrap_relay4(&seg, &signer().public(), None, None).unwrap();
        let open = |b: &[u8]| open_relay4(b, &signer().public(), None).err();
        assert!(open(&relay).is_none());
        let corrupt = |m: &str| Some(SegmentError::Corrupt(m.into()));
        let mut ver = relay.clone();
        ver[4] = 2;
        assert_eq!(open(&ver), corrupt("relay version"));
        let mut flags = relay.clone();
        flags[5] = 2;
        assert_eq!(open(&flags), corrupt("relay flags"));
        let mut long = relay.clone();
        long.push(0);
        assert_eq!(open(&long), corrupt("relay trailing bytes"));
        assert!(open(&relay[..relay.len() - 1]).is_some());
        // 改任意一个字节都不过（头、体、签名）。
        for at in [10, 40, relay.len() / 2, relay.len() - 70, relay.len() - 1] {
            let mut bad = relay.clone();
            bad[at] ^= 1;
            assert!(open(&bad).is_some(), "byte {at}");
        }
        // 拼件：按结构手搭，分别弄坏原段头长度、内层尾随、长度非最短。
        let o = open_native_verified(&seg, &signer().public(), None).unwrap();
        let (head, compressed, sig) = o.signed_parts();
        let build = |head: &[u8], inner: &[u8], raw_len: Option<&[u8]>| {
            let mut w = Writer::new();
            w.raw(MAGIC);
            w.u8(VERSION);
            w.u8(0);
            w.bytes(head);
            match raw_len {
                Some(len) => {
                    w.raw(len);
                    w.raw(inner);
                }
                None => w.bytes(inner),
            }
            w.into_vec()
        };
        let mut inner = Writer::new();
        inner.bytes(compressed);
        inner.raw(sig);
        let inner = inner.into_vec();
        assert!(open(&build(&head, &inner, None)).is_none());
        let mut head_long = head.clone();
        head_long.push(0);
        assert_eq!(
            open(&build(&head_long, &inner, None)),
            corrupt("relay head trailing bytes")
        );
        let mut inner_long = inner.clone();
        inner_long.push(0);
        assert_eq!(
            open(&build(&head, &inner_long, None)),
            corrupt("relay inner trailing bytes")
        );
        // 内层长度写成非最短的 varint。
        let n = inner.len();
        assert!(n >= 128);
        let mut loose = Writer::new();
        loose.uv(n as u64);
        let mut loose = loose.into_vec();
        let last = loose.len() - 1;
        loose[last] |= 0x80;
        loose.push(0);
        assert_eq!(
            open(&build(&head, &inner, Some(&loose))),
            corrupt("non-minimal varint")
        );
    }

    #[test]
    fn sealed_relays_need_the_destination_key() {
        let dst = k_dst();
        let (_, seg) = pack(&voided_items(), None);
        let relay = wrap_relay4(&seg, &signer().public(), None, Some(&dst)).unwrap();
        let open =
            |b: &[u8], k: Option<&CollectionKey>| open_relay4(b, &signer().public(), k).err();
        assert_eq!(open(&relay, None), Some(SegmentError::Undecryptable));
        assert_eq!(
            open(&relay, Some(&k_src())),
            Some(SegmentError::Undecryptable)
        );
        assert!(open(&relay, Some(&dst)).is_none());
        // 封装的 AAD 覆盖前缀：把「已封装」位清掉、或改原段头，都解不开 / 读不成。
        let mut unflag = relay.clone();
        unflag[5] = 0;
        assert!(open(&unflag, Some(&dst)).is_some());
        let mut head = relay.clone();
        head[20] ^= 1;
        assert_eq!(open(&head, Some(&dst)), Some(SegmentError::Undecryptable));
        // 未封装的件给了密钥也照读（密钥只用于封装的内层）。
        let plain = wrap_relay4(&seg, &signer().public(), None, None).unwrap();
        assert!(open(&plain, Some(&dst)).is_none());
    }

    /// 空洞的链值只靠作者签名担保：作者签错了（链尾跟着变），转发后仍是作者签的那份，读者看到的与读原段相同。
    #[test]
    fn relays_carry_exactly_what_the_author_signed() {
        let ops = ops();
        let items = vec![
            NativeItem::Op(ops[0].clone()),
            NativeItem::Void {
                count: 2,
                chain_after: [9; 32],
            },
            NativeItem::Op(ops[3].clone()),
        ];
        let (h, seg) = pack(&items, None);
        assert_eq!(h.last_chain, chain_next4(&[9; 32], &ops[3]));
        let relay = wrap_relay4(&seg, &signer().public(), None, Some(&k_dst())).unwrap();
        assert_eq!(
            open_relay4_items(&relay, &signer().public(), Some(&k_dst())).unwrap(),
            open_native(&seg, &signer().public(), None).unwrap()
        );
    }

    /// 「这份字节落盘时是否加密」两种格式同一口径：原生段跟段头，中继件跟外层封装位、不跟原段头。
    #[test]
    fn stored_sealed_reports_the_bytes_as_stored_not_the_original_location() {
        let (src, dst) = (k_src(), k_dst());
        let pk = signer().public();
        for sk in [None, Some(&src)] {
            let (_, seg) = pack(&voided_items(), sk);
            let native = open_any4(&seg, &pk, sk).unwrap();
            assert_eq!(native.stored_sealed, sk.is_some());
            assert_eq!(native.header.encrypted, sk.is_some());
            for dk in [None, Some(&dst)] {
                let relay = wrap_relay4(&seg, &pk, sk, dk).unwrap();
                // 给了所在位置的密钥照读，但读者看得到件其实没封装（明文落在加密位置时 = false）。
                let got = open_any4(&relay, &pk, Some(&dst)).unwrap();
                assert_eq!(got.stored_sealed, dk.is_some());
                assert_eq!(got.stored_sealed, peek_relay4(&relay).unwrap().sealed);
                assert_eq!(got.header.encrypted, sk.is_some());
            }
        }
    }

    /// D16-A 的已知性质（不是漏洞，钉住免得被当成证据）：持有原位置密钥的非作者能把加密原段换钥匙重新封装成验得过的
    /// `FSG4`，内容仍是作者签的那份。所以位置上有作者的原生段不证明作者到过这个位置。
    #[test]
    fn a_key_holder_can_reseal_a_native_segment_under_another_key() {
        let (src, dst) = (k_src(), k_dst());
        let pk = signer().public();
        let (_, seg) = pack(&voided_items(), Some(&src));
        let open = open_native_verified(&seg, &pk, Some(&src)).unwrap();
        let (head, compressed, sig) = open.signed_parts();
        let mut w = Writer::new();
        w.raw(&head);
        w.bytes(&dst.seal(compressed, &head));
        w.raw(sig);
        let moved = w.into_vec();
        assert_eq!(
            open_native(&moved, &pk, Some(&dst)).unwrap(),
            open_native(&seg, &pk, Some(&src)).unwrap()
        );
        // 作者签名仍担保内容：改明文压缩体的任何一位都打不开（解不开 = 坏件，解得开 = 摘要变了、验不过）。
        let mut tampered = compressed.to_vec();
        tampered[0] ^= 1;
        let mut w = Writer::new();
        w.raw(&head);
        w.bytes(&dst.seal(&tampered, &head));
        w.raw(sig);
        assert!(matches!(
            open_native_verified(&w.into_vec(), &pk, Some(&dst)).err(),
            Some(SegmentError::Corrupt(_))
        ));
        // 换了位置也还是作者的签名：签名改一位验不过。
        let mut forged = sig.to_vec();
        forged[0] ^= 1;
        let mut w = Writer::new();
        w.raw(&head);
        w.bytes(&dst.seal(compressed, &head));
        w.raw(&forged);
        assert_eq!(
            open_native_verified(&w.into_vec(), &pk, Some(&dst)).err(),
            Some(SegmentError::BadSignature)
        );
    }

    // ------------------------------------------------------------ 黄金向量

    /// 未封装的中继件（编码方向）：从冻结的明文原段包出来，字节必须一直相同——内层就是原段的压缩体 + 签名，
    /// 不重新压缩，所以编码方向也是契约。
    #[test]
    fn golden_relay_from_the_frozen_native_file() {
        let relay = wrap_relay4(&unhex(GOLDEN_FILE), &signer().public(), None, None).unwrap();
        golden("relay_file", &relay, GOLDEN_RELAY);
        // 冻结的加密原段（签名覆盖明文压缩体）解开后转到明文位置：读出同样的内容。段头带着原段的加密位，
        // 所以字节与上面那份不同。
        let from_sealed = wrap_relay4(
            &unhex(GOLDEN_FILE_SEALED),
            &signer().public(),
            Some(&k_src()),
            None,
        )
        .unwrap();
        assert!(peek_relay4(&from_sealed).unwrap().header.encrypted);
        assert_eq!(
            open_relay4_items(&from_sealed, &signer().public(), None)
                .unwrap()
                .1,
            golden_items()
        );
    }

    /// 封装的中继件（解码方向）：冻结的字节必须一直读得出同样的内容。
    #[test]
    fn golden_relays_still_open() {
        let (h, got) = open_relay4_items(&unhex(GOLDEN_RELAY), &signer().public(), None).unwrap();
        assert_eq!(got, golden_items());
        assert_eq!((h.first, h.last, h.encrypted), (1, 5, false));
        let prefix = peek_relay4(&unhex(GOLDEN_RELAY_SEALED)).unwrap();
        assert!(prefix.sealed);
        assert!(prefix.header.encrypted);
        let (_, got) = open_relay4_items(
            &unhex(GOLDEN_RELAY_SEALED),
            &signer().public(),
            Some(&k_dst()),
        )
        .unwrap();
        assert_eq!(got, golden_items());
    }

    /// 生成上面的封装件常量用（`cargo test -- --ignored print_golden_relay_files --nocapture`）：
    /// 冻结的加密原段（源钥匙 [3; 32]）→ 用目标钥匙 [4; 32] 封装的中继件。
    #[test]
    #[ignore]
    fn print_golden_relay_files() {
        let relay = wrap_relay4(
            &unhex(GOLDEN_FILE_SEALED),
            &signer().public(),
            Some(&k_src()),
            Some(&k_dst()),
        )
        .unwrap();
        println!("GOLDEN relay_file_sealed {}", crate::gen4::hex(&relay));
    }

    const GOLDEN_RELAY: &str = "46524c34010068465347340100c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1010500000000000000000000000000000000000000000000000000000000000000009181d4adc66426a9f02a885ecc46d5fb3848a8c1a1ca0f928480ae190b48b782b5017428b52ffd20ab5d0300a405040082c0e285e368000101d2050104220300010f7b22637265617465644174223a317d010239e787fd7631632b9006c87c296dfc1eb1fe6f2a08a159fa357c2485e20192280006090404130174000200000e0415b0016201017305007887be9809812181a0331d480238bde4be8b758abd3593cb1af6b1792f617233510425eba0835d9b07308865946fe21f553ad08cebd2d005e0b00a35a647fab136b9b9a6a31691f2e4a8642103";
    const GOLDEN_RELAY_SEALED: &str = "46524c34010168465347340101c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1010500000000000000000000000000000000000000000000000000000000000000009181d4adc66426a9f02a885ecc46d5fb3848a8c1a1ca0f928480ae190b48b782dd01bc1b54a80d7952eab931dab1cb7cb8e52b93487bd5ece8db50bbef2f79cc714773aa4a0e86d9d0b79c20952d644ddb482a0fffc5e43631e92ba6a7bc31485af8f7551d3950b95a1fab5c4b77d7e2719630ac408bde21bb5a971a8acade322f1c1b3aaf7f8e09ed0bbcc72348a6895b5f92459ebb33e19c1e99f9c2b15db2cea5e14b96edd2bb83683deb3e170e03970cacc7b45119aac71304ae88544377f569aee50d251fa335ea1979c4404a8630ce8a63f79c03d76e3ef24bb45a6e2cb9d468a632e411e18bca867b7d9b9e619cd1a6ec120cd3afa123db0d5ec42a";
}
