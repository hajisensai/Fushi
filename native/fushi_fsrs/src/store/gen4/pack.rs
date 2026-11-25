//! 操作体的本机存储编码（设计 §2.2 表后一段：「本机存储编码与线格式分开定版本」）。
//!
//! 线上是规范字节（链、签名、「同号同字节」的幂等判定都按它算）；本机怎么存只是存储细节。这里做三件事，每一件都
//! **逐字节可逆**——读出来再编码必须等于存进去的规范字节：
//!
//! 1. **旧戳内部化**（[F_STAMP]）：承袭的修改把旧戳从操作体尾部摘下来，写入者名字换成 `writers` 表的下标另存一列
//!    （`aux`）。线格式里名字是内联的（操作体自包含，G1）；一份真实库 66 万个旧戳里只有 1.5 万个不同的名字。
//!    摘掉旧戳之后剩下的字节仍是一条合法的、不带旧戳的修改——只要字段值的读者（整列读正文）不必碰旧戳。
//! 2. **配置快照剪出**（[F_SNAP]）：日志带的「作答那一刻的生效配置」`sc` 原文剪出来按内容存一份（`snapshots`），
//!    `aux` 记 (快照号, 位置)。与协议 3 的 `store/sync2/snapshots.rs` 同一做法。
//! 3. **压缩**（[F_ZSTD]）：≥ [ZSTD_MIN] 字节的存储字节用 zstd，省不下八分之一就原样存。
//!
//! 可逆性不靠「相信编码器写对了」：[pack_payload] 每次都把存储形态解回来与原字节比一遍，不等就退回原样存
//! （未知的格式号、非规范的 JSON、以后的版本追加的字段都走这条路）。

use std::cell::RefCell;

use serde_json::Value;

use crate::gen4::op::{BODY_FMT, Body4, KIND_EDIT, KIND_LOG};
use crate::gen4::stamp::{HeritageStamp, StampCtx, StampHlc};
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::dvv::Dvv;
use crate::sync2::replay::SNAPSHOT_KEY;

/// `ops.flags`：这一行是原样件（协议 3 的操作原字节；`fmt` 一列存的是协议 3 的 `schema`）。
pub(crate) const F_RAW3: i64 = 1;
/// `body` 是 `[原长 u32 小端][zstd 帧]`。
pub(crate) const F_ZSTD: i64 = 2;
/// `body` 是摘掉旧戳的修改，`aux` 是内部化的旧戳。
pub(crate) const F_STAMP: i64 = 4;
/// `body` 剪掉了配置快照原文，`aux` 是 `uv 快照号 | uv 位置`。
pub(crate) const F_SNAP: i64 = 8;
/// `flags >> TV_SHIFT` = 转译 T 的版本 − 1（原生操作恒为 0）。
pub(crate) const TV_SHIFT: u32 = 4;

/// 比这短的不压。
pub(crate) const ZSTD_MIN: usize = 256;
const ZSTD_LEVEL: i32 = 3;
/// 比这短的配置快照不剪（与协议 3 相同）。
const SNAP_MIN: usize = 64;

pub(crate) fn tv_of(flags: i64) -> u32 {
    (flags >> TV_SHIFT) as u32 + 1
}

pub(crate) fn tv_bits(tv: u32) -> i64 {
    i64::from(tv.saturating_sub(1)) << TV_SHIFT
}

/// 名字表 / 快照表（`truth.rs` 的会话实现；测试里用内存表）。
pub(crate) trait Names {
    fn writer_id(&mut self, name: &str) -> Result<u64, String>;
    fn writer_name(&mut self, id: u64) -> Result<String, String>;
    fn snapshot_id(&mut self, body: &str) -> Result<u64, String>;
    fn snapshot_body(&mut self, id: u64) -> Result<String, String>;
}

thread_local! {
    static ZC: RefCell<Option<zstd::bulk::Compressor<'static>>> = const { RefCell::new(None) };
    static ZD: RefCell<Option<zstd::bulk::Decompressor<'static>>> = const { RefCell::new(None) };
}

fn compress(stored: Vec<u8>) -> Result<(Vec<u8>, bool), String> {
    if stored.len() < ZSTD_MIN || stored.len() > u32::MAX as usize {
        return Ok((stored, false));
    }
    let z = ZC.with(|cell| -> Result<Vec<u8>, String> {
        let mut cell = cell.borrow_mut();
        if cell.is_none() {
            *cell = Some(zstd::bulk::Compressor::new(ZSTD_LEVEL).map_err(|e| e.to_string())?);
        }
        cell.as_mut()
            .expect("compressor")
            .compress(&stored)
            .map_err(|e| e.to_string())
    })?;
    if (z.len() + 4) * 8 > stored.len() * 7 {
        return Ok((stored, false));
    }
    let mut out = Vec::with_capacity(z.len() + 4);
    out.extend_from_slice(&(stored.len() as u32).to_le_bytes());
    out.extend_from_slice(&z);
    Ok((out, true))
}

fn decompress(stored: &[u8]) -> Result<Vec<u8>, String> {
    let n = stored
        .get(..4)
        .ok_or("gen4 store: compressed body without its length")?;
    let n = u32::from_le_bytes(n.try_into().expect("4 bytes")) as usize;
    let out = ZD.with(|cell| -> Result<Vec<u8>, String> {
        let mut cell = cell.borrow_mut();
        if cell.is_none() {
            *cell = Some(zstd::bulk::Decompressor::new().map_err(|e| e.to_string())?);
        }
        cell.as_mut()
            .expect("decompressor")
            .decompress(&stored[4..], n)
            .map_err(|e| format!("gen4 store: bad compressed body: {e}"))
    })?;
    if out.len() != n {
        return Err("gen4 store: compressed body length mismatch".to_owned());
    }
    Ok(out)
}

// ---------------------------------------------------------------- 旧戳

const S_SERVER: u8 = 1;
const S_SAME: u8 = 2;
const S_RAW: u8 = 4;
const S_CLOUD: u8 = 8;

/// 旧戳的存储形态：
///
/// ```text
/// flags u8 | writer uv | seq iv | n uv | n × (writer uv, vv uv, [m uv, m × Δ uv]) |
/// HLC（原文 str，或 physical iv, counter iv, [writer uv]）| [server_time − physical iv]
/// ```
pub(crate) fn pack_stamp(s: &HeritageStamp, names: &mut dyn Names) -> Result<Vec<u8>, String> {
    let (raw, same, base) = match &s.hlc {
        StampHlc::Parsed {
            physical, writer, ..
        } => (false, *writer == s.writer, *physical),
        StampHlc::Raw(_) => (true, false, 0),
    };
    let entries = s.ctx.entries();
    let cloud = entries.iter().any(|e| !e.cloud.is_empty());
    let mut flags = 0u8;
    if s.server_time.is_some() {
        flags |= S_SERVER;
    }
    if same {
        flags |= S_SAME;
    }
    if raw {
        flags |= S_RAW;
    }
    if cloud {
        flags |= S_CLOUD;
    }
    let mut w = Writer::new();
    w.u8(flags);
    w.uv(names.writer_id(&s.writer)?);
    w.iv(s.seq);
    w.uv(entries.len() as u64);
    for e in entries {
        w.uv(names.writer_id(&e.writer)?);
        w.uv(e.vv);
        if cloud {
            w.uv(e.cloud.len() as u64);
            let mut prev = e.vv;
            for &c in &e.cloud {
                w.uv(c.wrapping_sub(prev));
                prev = c;
            }
        }
    }
    match &s.hlc {
        StampHlc::Parsed {
            physical,
            counter,
            writer,
        } => {
            w.iv(*physical);
            w.iv(*counter);
            if !same {
                w.uv(names.writer_id(writer)?);
            }
        }
        StampHlc::Raw(t) => w.str(t),
    }
    if let Some(t) = s.server_time {
        w.iv(t.wrapping_sub(base));
    }
    Ok(w.into_vec())
}

pub(crate) fn unpack_stamp(bytes: &[u8], names: &mut dyn Names) -> Result<HeritageStamp, String> {
    let bad = |e: crate::sync2::codec::DecodeError| format!("gen4 store: stored stamp: {e}");
    let mut r = Reader::new(bytes);
    let flags = r.u8().map_err(bad)?;
    let writer = names.writer_name(r.uv().map_err(bad)?)?;
    let seq = r.iv().map_err(bad)?;
    let n = r.uv().map_err(bad)?;
    let mut ctx = Dvv::default();
    for _ in 0..n {
        let w = names.writer_name(r.uv().map_err(bad)?)?;
        let vv = r.uv().map_err(bad)?;
        if vv > 0 {
            ctx.vv.insert(w.clone(), vv as i64);
        }
        if flags & S_CLOUD != 0 {
            let m = r.uv().map_err(bad)?;
            let mut prev = vv;
            let mut set = std::collections::BTreeSet::new();
            for _ in 0..m {
                prev = prev.wrapping_add(r.uv().map_err(bad)?);
                set.insert(prev as i64);
            }
            if !set.is_empty() {
                ctx.cloud.insert(w, set);
            }
        }
    }
    let (hlc, base) = if flags & S_RAW != 0 {
        (StampHlc::Raw(r.str().map_err(bad)?.to_owned()), 0)
    } else {
        let physical = r.iv().map_err(bad)?;
        let counter = r.iv().map_err(bad)?;
        let w = if flags & S_SAME != 0 {
            writer.clone()
        } else {
            names.writer_name(r.uv().map_err(bad)?)?
        };
        (
            StampHlc::Parsed {
                physical,
                counter,
                writer: w,
            },
            physical,
        )
    };
    let server_time = if flags & S_SERVER != 0 {
        Some(r.iv().map_err(bad)?.wrapping_add(base))
    } else {
        None
    };
    if !r.is_empty() {
        return Err("gen4 store: stored stamp has trailing bytes".to_owned());
    }
    Ok(HeritageStamp {
        writer,
        seq,
        ctx: StampCtx::from_dvv(&ctx),
        hlc,
        server_time,
    })
}

// ---------------------------------------------------------------- 操作体

/// 一条操作体的存储形态。
pub(crate) struct Packed {
    /// [F_ZSTD] / [F_STAMP] / [F_SNAP]（不含 [F_RAW3] 与 T 版本位，调用方另加）。
    pub flags: i64,
    pub body: Vec<u8>,
    pub aux: Option<Vec<u8>>,
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

fn pack_known(kind: u16, payload: &[u8], names: &mut dyn Names) -> Result<Option<Packed>, String> {
    match kind {
        KIND_EDIT => {
            let Ok(Body4::Edit(mut e)) = Body4::decode(kind, BODY_FMT, payload) else {
                return Ok(None);
            };
            let Some(stamp) = e.stamp.take() else {
                return Ok(None);
            };
            let aux = pack_stamp(&stamp, names)?;
            let (body, z) = compress(Body4::Edit(e).encode())?;
            Ok(Some(Packed {
                flags: F_STAMP | if z { F_ZSTD } else { 0 },
                body,
                aux: Some(aux),
            }))
        }
        KIND_LOG => {
            if find(payload, b"\"sc\":{").is_none() {
                return Ok(None);
            }
            let Ok(Body4::Log(l)) = Body4::decode(kind, BODY_FMT, payload) else {
                return Ok(None);
            };
            let Some(sc) = serde_json::from_str::<Value>(&l.extra)
                .ok()
                .and_then(|v| v.get(SNAPSHOT_KEY).filter(|x| x.is_object()).cloned())
            else {
                return Ok(None);
            };
            let text = serde_json::to_string(&sc).map_err(|e| e.to_string())?;
            if text.len() < SNAP_MIN {
                return Ok(None);
            }
            let needle = format!("\"{SNAPSHOT_KEY}\":{text}");
            let Some(pos) = find(payload, needle.as_bytes()) else {
                return Ok(None);
            };
            let at = pos + needle.len() - text.len();
            let mut body = Vec::with_capacity(payload.len() - text.len());
            body.extend_from_slice(&payload[..at]);
            body.extend_from_slice(&payload[at + text.len()..]);
            let mut aux = Writer::new();
            aux.uv(names.snapshot_id(&text)?);
            aux.uv(at as u64);
            Ok(Some(Packed {
                flags: F_SNAP,
                body,
                aux: Some(aux.into_vec()),
            }))
        }
        _ => Ok(None),
    }
}

/// 规范操作体 → 存储形态。[raw3] = 原样件（协议 3 的载荷，不解析，只压缩）。
pub(crate) fn pack_payload(
    kind: u16,
    fmt: u16,
    payload: &[u8],
    raw3: bool,
    names: &mut dyn Names,
) -> Result<Packed, String> {
    if !raw3 && fmt == BODY_FMT {
        if let Some(p) = pack_known(kind, payload, names)? {
            // 写时核对：解回来必须是原字节。
            let back = unpack_payload(p.flags, &p.body, p.aux.as_deref(), names);
            if back.as_deref() == Ok(payload) {
                return Ok(p);
            }
        }
    }
    let (body, z) = compress(payload.to_vec())?;
    Ok(Packed {
        flags: if z { F_ZSTD } else { 0 },
        body,
        aux: None,
    })
}

/// 存储形态 → 规范操作体（原样件给回协议 3 的载荷原字节）。
pub(crate) fn unpack_payload(
    flags: i64,
    body: &[u8],
    aux: Option<&[u8]>,
    names: &mut dyn Names,
) -> Result<Vec<u8>, String> {
    let main = main_bytes(flags, body)?;
    if flags & F_STAMP != 0 {
        let aux = aux.ok_or("gen4 store: stamped edit without its stamp")?;
        let stamp = unpack_stamp(aux, names)?;
        let Ok(Body4::Edit(mut e)) = Body4::decode(KIND_EDIT, BODY_FMT, &main) else {
            return Err("gen4 store: stored edit does not decode".to_owned());
        };
        e.stamp = Some(stamp);
        return Ok(Body4::Edit(e).encode());
    }
    if flags & F_SNAP != 0 {
        let aux = aux.ok_or("gen4 store: log without its snapshot reference")?;
        let bad = |e: crate::sync2::codec::DecodeError| format!("gen4 store: snapshot ref: {e}");
        let mut r = Reader::new(aux);
        let id = r.uv().map_err(bad)?;
        let at = r.uv().map_err(bad)? as usize;
        if at > main.len() {
            return Err("gen4 store: bad snapshot offset".to_owned());
        }
        let text = names.snapshot_body(id)?;
        let mut out = Vec::with_capacity(main.len() + text.len());
        out.extend_from_slice(&main[..at]);
        out.extend_from_slice(text.as_bytes());
        out.extend_from_slice(&main[at..]);
        return Ok(out);
    }
    Ok(main)
}

/// 存储字节解压后的主体：[F_STAMP] 时是不带旧戳的修改（可以直接解出字段值），[F_SNAP] 时是剪掉快照的日志（不能直接解）。
pub(crate) fn main_bytes(flags: i64, body: &[u8]) -> Result<Vec<u8>, String> {
    if flags & F_ZSTD != 0 {
        decompress(body)
    } else {
        Ok(body.to_vec())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::collections::HashMap;

    use proptest::prelude::*;

    use super::*;
    use crate::gen4::op::{Edit4, KIND_ENTITY};
    use crate::sync2::id::Key;
    use crate::sync2::op::EntKind;

    /// 内存里的名字表。
    #[derive(Default)]
    pub(crate) struct MemNames {
        writers: Vec<String>,
        writer_ix: HashMap<String, u64>,
        snaps: Vec<String>,
        snap_ix: HashMap<String, u64>,
    }

    impl Names for MemNames {
        fn writer_id(&mut self, name: &str) -> Result<u64, String> {
            if let Some(&i) = self.writer_ix.get(name) {
                return Ok(i);
            }
            self.writers.push(name.to_owned());
            let i = self.writers.len() as u64;
            self.writer_ix.insert(name.to_owned(), i);
            Ok(i)
        }

        fn writer_name(&mut self, id: u64) -> Result<String, String> {
            self.writers
                .get(id as usize - 1)
                .cloned()
                .ok_or_else(|| "no such writer".to_owned())
        }

        fn snapshot_id(&mut self, body: &str) -> Result<u64, String> {
            if let Some(&i) = self.snap_ix.get(body) {
                return Ok(i);
            }
            self.snaps.push(body.to_owned());
            let i = self.snaps.len() as u64;
            self.snap_ix.insert(body.to_owned(), i);
            Ok(i)
        }

        fn snapshot_body(&mut self, id: u64) -> Result<String, String> {
            self.snaps
                .get(id as usize - 1)
                .cloned()
                .ok_or_else(|| "no such snapshot".to_owned())
        }
    }

    fn edit(value: String, stamp: Option<HeritageStamp>) -> Vec<u8> {
        Body4::Edit(Edit4 {
            kind: EntKind::Note,
            entity: Key::of("0193a1b2-0000-7000-8000-000000000001"),
            key: "f/0193a1b2-0000-7000-8000-0000000000f1".to_owned(),
            value,
            machine: false,
            anchored: true,
            stamp,
        })
        .encode()
    }

    #[test]
    fn a_stamped_edit_stores_its_stamp_apart_and_reads_back_exactly() {
        let mut names = MemNames::default();
        let stamp = crate::gen4::stamp::tests::typical();
        let payload = edit("\"単語\"".to_owned(), Some(stamp.clone()));
        let p = pack_payload(KIND_EDIT, BODY_FMT, &payload, false, &mut names).unwrap();
        assert_eq!(p.flags, F_STAMP);
        // 主体是一条不带旧戳的合法修改：读字段值不必碰旧戳。
        let Body4::Edit(e) = Body4::decode(KIND_EDIT, BODY_FMT, &p.body).unwrap() else {
            panic!("not an edit");
        };
        assert_eq!((e.value.as_str(), e.stamp), ("\"単語\"", None));
        // 旧戳里没有名字原文。
        let aux = p.aux.clone().unwrap();
        assert!(find(&aux, stamp.writer.as_bytes()).is_none());
        assert!(aux.len() < stamp.encode().len());
        assert_eq!(
            unpack_payload(p.flags, &p.body, p.aux.as_deref(), &mut names).unwrap(),
            payload
        );
        assert_eq!(unpack_stamp(&aux, &mut names).unwrap(), stamp);
    }

    #[test]
    fn large_values_are_compressed_and_small_ones_are_not() {
        let mut names = MemNames::default();
        let big = format!("\"{}\"", "<div class=\"gloss\">意味</div>".repeat(200));
        for stamp in [None, Some(crate::gen4::stamp::tests::typical())] {
            let payload = edit(big.clone(), stamp.clone());
            let p = pack_payload(KIND_EDIT, BODY_FMT, &payload, false, &mut names).unwrap();
            assert_ne!(p.flags & F_ZSTD, 0);
            assert_eq!(p.flags & F_STAMP != 0, stamp.is_some());
            assert!(p.body.len() * 4 < payload.len());
            assert_eq!(
                unpack_payload(p.flags, &p.body, p.aux.as_deref(), &mut names).unwrap(),
                payload
            );
        }
        let small = edit("\"a\"".to_owned(), None);
        let p = pack_payload(KIND_EDIT, BODY_FMT, &small, false, &mut names).unwrap();
        assert_eq!((p.flags, p.body.as_slice(), p.aux), (0, &small[..], None));
        // 压不动的（随机字节）原样存。
        let mut x = 0x9e37_79b9_7f4a_7c15u64;
        let noise: Vec<u8> = (0..2000)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                (x >> 32) as u8
            })
            .collect();
        let p = pack_payload(999, BODY_FMT, &noise, false, &mut names).unwrap();
        assert_eq!((p.flags, p.body.len()), (0, noise.len()));
    }

    #[test]
    fn a_config_snapshot_is_stored_once() {
        let mut names = MemNames::default();
        let mut l = crate::gen4::op::tests::sample_log();
        let sc = r#"{"learn":[1.0,10.0],"relearn":[10.0],"retention":0.9,"w":[0.21,1.29,2.31,8.3,6.41,0.83,3.02,0.001,1.87,0.17,0.8]}"#;
        l.extra = format!("{{\"sc\":{sc}}}");
        let a = Body4::Log(l.clone()).encode();
        l.at += 1;
        let b = Body4::Log(l).encode();
        let pa = pack_payload(KIND_LOG, BODY_FMT, &a, false, &mut names).unwrap();
        let pb = pack_payload(KIND_LOG, BODY_FMT, &b, false, &mut names).unwrap();
        assert_eq!((pa.flags, pb.flags), (F_SNAP, F_SNAP));
        assert_eq!(names.snaps, vec![sc.to_owned()]);
        assert!(pa.body.len() + sc.len() == a.len());
        for (p, want) in [(pa, a), (pb, b)] {
            assert_eq!(
                unpack_payload(p.flags, &p.body, p.aux.as_deref(), &mut names).unwrap(),
                want
            );
        }
    }

    #[test]
    fn what_cannot_be_split_exactly_is_stored_whole() {
        let mut names = MemNames::default();
        // 更新的格式号：不解析。
        let payload = edit(
            "\"x\"".to_owned(),
            Some(crate::gen4::stamp::tests::typical()),
        );
        let p = pack_payload(KIND_EDIT, BODY_FMT + 1, &payload, false, &mut names).unwrap();
        assert_eq!((p.flags, p.body.as_slice()), (0, &payload[..]));
        // 原样件：协议 3 的载荷，不解析。
        let p = pack_payload(KIND_EDIT, 1, &payload, true, &mut names).unwrap();
        assert_eq!((p.flags, p.body.as_slice()), (0, &payload[..]));
        // 解不开的字节。
        let p = pack_payload(KIND_EDIT, BODY_FMT, &[9, 9, 9], false, &mut names).unwrap();
        assert_eq!((p.flags, p.body.as_slice()), (0, &[9u8, 9, 9][..]));
        // 别的种类原样。
        let ent = Body4::Entity {
            kind: EntKind::Deck,
            id: Key::of("d"),
            data: "{}".to_owned(),
        }
        .encode();
        let p = pack_payload(KIND_ENTITY, BODY_FMT, &ent, false, &mut names).unwrap();
        assert_eq!((p.flags, p.body.as_slice()), (0, &ent[..]));
    }

    proptest! {
        #[test]
        fn any_stamp_survives_internment(s in crate::gen4::stamp::tests::arb_stamp()) {
            let mut names = MemNames::default();
            let bytes = pack_stamp(&s, &mut names).unwrap();
            prop_assert_eq!(unpack_stamp(&bytes, &mut names).unwrap(), s);
        }

        #[test]
        fn any_edit_and_log_reads_back_byte_for_byte(e in crate::gen4::op::tests::arb_edit(), l in crate::gen4::op::tests::arb_log()) {
            let mut names = MemNames::default();
            for (kind, payload) in [(KIND_EDIT, Body4::Edit(e).encode()), (KIND_LOG, Body4::Log(l).encode())] {
                let p = pack_payload(kind, BODY_FMT, &payload, false, &mut names).unwrap();
                prop_assert_eq!(unpack_payload(p.flags, &p.body, p.aux.as_deref(), &mut names).unwrap(), payload);
            }
        }

        #[test]
        fn any_bytes_read_back(kind in 0u16..16, fmt in 1u16..6, raw3 in any::<bool>(), bytes in proptest::collection::vec(any::<u8>(), 0..600)) {
            let mut names = MemNames::default();
            let p = pack_payload(kind, fmt, &bytes, raw3, &mut names).unwrap();
            prop_assert_eq!(unpack_payload(p.flags, &p.body, p.aux.as_deref(), &mut names).unwrap(), bytes);
        }
    }
}
