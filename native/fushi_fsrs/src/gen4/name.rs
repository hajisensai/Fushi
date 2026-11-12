//! 名字与修改键的紧凑形（协议 4 线格式的一部分，冻结）。
//!
//! 旧戳里的写入者名字、修改操作的键在协议 3 里都是文本；它们的形状只有有限几种，绝大多数嵌着一个 UUID 或一把公钥。
//! 这里给每种形状一个 tag，嵌着的 UUID / 公钥存原始字节。规则只有一条：**一个文本只有一种字节形**——
//! 编码时能用专门形就必须用（[classify]），解码时遇到「本可用专门形却写成了文本」的字节一律拒绝。于是同一条旧操作
//! 不论由哪台设备转译，字节都相同（设计 §3.2）。
//!
//! 专门形都以「解出来再拼回文本与原文逐字节相同」为准入条件（大写的 UUID、带前导零的数字、非规范的 base64 都留文本），
//! 所以无损。

use super::{str_min, uv_min};
use crate::sync2::codec::{DResult, DecodeError, Reader, Writer};
use crate::sync2::id::Id;

const TAG_UUID: u8 = 0;
const TAG_TEXT: u8 = 1;
const TAG_MERGED: u8 = 2;
const TAG_MERGED_PAIR: u8 = 3;
const TAG_KEY_SEQ: u8 = 4;
const TAG_TAGS: u8 = 5;
/// 只在旧戳的上下文项里出现：与本戳的写入者相同（[write_name_ref]）。
const TAG_SAME: u8 = 15;

const MERGED: &str = "merged-";
const TAGS: &str = "sync2:tags:";

/// 规范 UUID 文本（36 字节、小写十六进制、连字符在 8/13/18/23）→ 16 字节。
fn uuid_text(b: &[u8]) -> Option<Id> {
    if b.len() != 36 {
        return None;
    }
    let mut out = [0u8; 16];
    let mut n = 0;
    for (i, &c) in b.iter().enumerate() {
        if matches!(i, 8 | 13 | 18 | 23) {
            if c != b'-' {
                return None;
            }
            continue;
        }
        let v = match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            _ => return None,
        };
        if n % 2 == 0 {
            out[n / 2] = v << 4;
        } else {
            out[n / 2] |= v;
        }
        n += 1;
    }
    Some(Id(out))
}

const B64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// 32 字节 → URL 安全 base64、带 `=` 填充（44 字符）。
fn b64url_32(key: &[u8; 32]) -> [u8; 44] {
    let mut out = [b'='; 44];
    let mut o = 0;
    for chunk in key.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let v = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        let take = chunk.len() + 1;
        for k in 0..take {
            out[o + k] = B64URL[((v >> (18 - 6 * k)) & 63) as usize];
        }
        o += 4;
    }
    out
}

/// [b64url_32] 的逆；只认它自己写得出的 44 字符（末位的多余比特必须为 0）。
fn un_b64url_32(text: &[u8]) -> Option<[u8; 32]> {
    if text.len() != 44 || text[43] != b'=' {
        return None;
    }
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    let mut out = [0u8; 32];
    let mut n = 0;
    for &c in &text[..43] {
        let v = B64URL.iter().position(|&x| x == c)? as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            if n == 32 {
                return None;
            }
            out[n] = (acc >> bits) as u8;
            n += 1;
            acc &= (1 << bits) - 1;
        }
    }
    (n == 32 && acc == 0).then_some(out)
}

/// 规范十进制 u64（只有数字、没有前导零）。
fn canonical_u64(b: &[u8]) -> Option<u64> {
    if b.is_empty() || b.len() > 20 || !b.iter().all(u8::is_ascii_digit) {
        return None;
    }
    if b.len() > 1 && b[0] == b'0' {
        return None;
    }
    std::str::from_utf8(b).ok()?.parse().ok()
}

/// 一个名字的字节形。
enum Form<'a> {
    /// 规范 UUID 文本。
    Uuid(Id),
    /// `merged-<uuid>`（旧并入改名的写入者，`srs_profile_merge.dart`）。
    Merged(Id),
    /// `merged-<uuid>~<uuid>`（同上，带原写入者后缀的那种格式）。
    MergedPair(Id, Id),
    /// `<32 字节的 URL 安全 base64>#<n>`（协议 1 的写入者：设备公钥 + 第几个写入者）。
    KeySeq([u8; 32], u64),
    /// `sync2:tags:<uuid>`（合成写入者，`registers.rs` `SYNTHETIC_WRITER_PREFIX`）。
    Tags(Id),
    Text(&'a str),
}

fn classify(s: &str) -> Form<'_> {
    let b = s.as_bytes();
    if let Some(id) = uuid_text(b) {
        return Form::Uuid(id);
    }
    if let Some(rest) = b.strip_prefix(MERGED.as_bytes()) {
        if let Some(id) = uuid_text(rest) {
            return Form::Merged(id);
        }
        if rest.len() == 73 && rest[36] == b'~' {
            if let (Some(a), Some(c)) = (uuid_text(&rest[..36]), uuid_text(&rest[37..])) {
                return Form::MergedPair(a, c);
            }
        }
    }
    if let Some(id) = b.strip_prefix(TAGS.as_bytes()).and_then(uuid_text) {
        return Form::Tags(id);
    }
    if b.len() >= 46 && b[44] == b'#' {
        if let (Some(key), Some(n)) = (un_b64url_32(&b[..44]), canonical_u64(&b[45..])) {
            return Form::KeySeq(key, n);
        }
    }
    Form::Text(s)
}

/// 写一个名字（规范形）。
pub fn write_name(w: &mut Writer, s: &str) {
    match classify(s) {
        Form::Uuid(id) => {
            w.u8(TAG_UUID);
            id.write(w);
        }
        Form::Merged(id) => {
            w.u8(TAG_MERGED);
            id.write(w);
        }
        Form::MergedPair(a, b) => {
            w.u8(TAG_MERGED_PAIR);
            a.write(w);
            b.write(w);
        }
        Form::KeySeq(key, n) => {
            w.u8(TAG_KEY_SEQ);
            w.raw(&key);
            w.uv(n);
        }
        Form::Tags(id) => {
            w.u8(TAG_TAGS);
            id.write(w);
        }
        Form::Text(t) => {
            w.u8(TAG_TEXT);
            w.str(t);
        }
    }
}

/// 读一个名字；不是规范形的字节拒绝。
pub fn read_name(r: &mut Reader<'_>) -> DResult<String> {
    let tag = r.u8()?;
    read_name_tagged(r, tag)
}

fn read_name_tagged(r: &mut Reader<'_>, tag: u8) -> DResult<String> {
    Ok(match tag {
        TAG_UUID => Id::read(r)?.text(),
        TAG_MERGED => format!("{MERGED}{}", Id::read(r)?.text()),
        TAG_MERGED_PAIR => {
            let a = Id::read(r)?;
            let b = Id::read(r)?;
            format!("{MERGED}{}~{}", a.text(), b.text())
        }
        TAG_KEY_SEQ => {
            let key: [u8; 32] = r.raw(32)?.try_into().map_err(|_| DecodeError("name key"))?;
            let n = uv_min(r)?;
            let b64 = b64url_32(&key);
            format!(
                "{}#{n}",
                std::str::from_utf8(&b64).expect("base64 is ascii")
            )
        }
        TAG_TAGS => format!("{TAGS}{}", Id::read(r)?.text()),
        TAG_TEXT => {
            let s = str_min(r)?;
            if !matches!(classify(s), Form::Text(_)) {
                return Err(DecodeError("name text has a compact form"));
            }
            s.to_owned()
        }
        _ => return Err(DecodeError("bad name tag")),
    })
}

/// 旧戳上下文项里的名字：与本戳写入者 [same] 相同就只写一个 tag。
pub fn write_name_ref(w: &mut Writer, s: &str, same: &str) {
    if s == same {
        w.u8(TAG_SAME);
    } else {
        write_name(w, s);
    }
}

/// [write_name_ref] 的逆；等于 [same] 却没用 [TAG_SAME] 的拒绝。
pub fn read_name_ref(r: &mut Reader<'_>, same: &str) -> DResult<String> {
    let tag = r.u8()?;
    if tag == TAG_SAME {
        return Ok(same.to_owned());
    }
    let s = read_name_tagged(r, tag)?;
    if s == same {
        return Err(DecodeError("name repeats the stamp writer"));
    }
    Ok(s)
}

// ---------------------------------------------------------------- 修改键

/// 修改键里嵌 UUID 的四种前缀（tag = 下标 + 1；持久化，只许在末尾追加）。
const KEY_PREFIXES: [&str; 4] = ["f/", "fieldDef/", "tmplDef/", "historyFrom/"];

fn classify_key(s: &str) -> Option<(u8, Id)> {
    let b = s.as_bytes();
    KEY_PREFIXES.iter().enumerate().find_map(|(i, p)| {
        b.strip_prefix(p.as_bytes())
            .and_then(uuid_text)
            .map(|id| (i as u8 + 1, id))
    })
}

/// 写一个修改键：`<前缀><规范 UUID>` 存 tag + 16 字节，其余存文本。
pub fn write_edit_key(w: &mut Writer, s: &str) {
    match classify_key(s) {
        Some((tag, id)) => {
            w.u8(tag);
            id.write(w);
        }
        None => {
            w.u8(0);
            w.str(s);
        }
    }
}

pub fn read_edit_key(r: &mut Reader<'_>) -> DResult<String> {
    let tag = r.u8()?;
    if tag == 0 {
        let s = str_min(r)?;
        if classify_key(s).is_some() {
            return Err(DecodeError("edit key text has a compact form"));
        }
        return Ok(s.to_owned());
    }
    let prefix = KEY_PREFIXES
        .get(tag as usize - 1)
        .ok_or(DecodeError("bad edit key tag"))?;
    Ok(format!("{prefix}{}", Id::read(r)?.text()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn enc(s: &str) -> Vec<u8> {
        let mut w = Writer::new();
        write_name(&mut w, s);
        w.into_vec()
    }

    fn dec(b: &[u8]) -> DResult<String> {
        let mut r = Reader::new(b);
        let s = read_name(&mut r)?;
        assert!(r.is_empty());
        Ok(s)
    }

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    const U1: &str = "862ab679-9805-548b-9454-d3ec51c44e9c";
    const U2: &str = "8f28cfa8-6dd3-592d-8e4a-2bf5aec4060d";
    /// 样本库里的协议 1 写入者形状（公钥换成了固定字节）。
    const K1: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=#1";

    #[test]
    fn every_shape_round_trips_and_uses_its_compact_form() {
        let cases: [(String, u8, usize); 8] = [
            (U1.to_owned(), TAG_UUID, 17),
            (format!("merged-{U1}"), TAG_MERGED, 17),
            (format!("merged-{U1}~{U2}"), TAG_MERGED_PAIR, 33),
            (K1.to_owned(), TAG_KEY_SEQ, 34),
            (format!("sync2:tags:{U2}"), TAG_TAGS, 17),
            ("anki".to_owned(), TAG_TEXT, 6),
            (String::new(), TAG_TEXT, 2),
            ("写入者".to_owned(), TAG_TEXT, 11),
        ];
        for (s, tag, len) in cases {
            let b = enc(&s);
            assert_eq!((b[0], b.len()), (tag, len), "{s}");
            assert_eq!(dec(&b).unwrap(), s);
        }
    }

    /// 只差一点的文本不变形：大写、无连字符、带前导零的序号、非规范 base64、标准字母表的 `+` `/`。
    #[test]
    fn near_misses_stay_text() {
        let upper = U1.to_uppercase();
        let k_bad_pad = format!("{}B=#1", &K1[..42]);
        let cases = [
            upper.clone(),
            U1.replace('-', ""),
            format!("merged-{upper}"),
            format!("merged-{U1}~"),
            format!("merged-{U1}~{upper}"),
            format!("merged-{U1}-{U2}"),
            format!("sync2:tags:{upper}"),
            format!("sync2:{U1}"),
            format!("{}#01", &K1[..44]),
            format!("{}#+1", &K1[..44]),
            format!("{}#", &K1[..44]),
            format!("{}#99999999999999999999", &K1[..44]),
            K1.replace('A', "+"),
            k_bad_pad,
            format!("{K1} "),
        ];
        for s in cases {
            let b = enc(&s);
            assert_eq!(b[0], TAG_TEXT, "{s}");
            assert_eq!(dec(&b).unwrap(), s);
        }
    }

    #[test]
    fn text_that_has_a_compact_form_is_rejected() {
        for s in [
            U1.to_owned(),
            format!("merged-{U1}"),
            K1.to_owned(),
            format!("sync2:tags:{U1}"),
        ] {
            let mut w = Writer::new();
            w.u8(TAG_TEXT);
            w.str(&s);
            assert!(dec(&w.into_vec()).is_err(), "{s}");
        }
        assert!(dec(&[9]).is_err());
        assert!(dec(&[TAG_SAME]).is_err());
    }

    #[test]
    fn name_ref_collapses_the_stamp_writer() {
        let mut w = Writer::new();
        write_name_ref(&mut w, K1, K1);
        write_name_ref(&mut w, U1, K1);
        let b = w.into_vec();
        assert_eq!(b[0], TAG_SAME);
        let mut r = Reader::new(&b);
        assert_eq!(read_name_ref(&mut r, K1).unwrap(), K1);
        assert_eq!(read_name_ref(&mut r, K1).unwrap(), U1);
        // 等于写入者却写了全名：拒绝。
        assert!(read_name_ref(&mut Reader::new(&enc(K1)), K1).is_err());
    }

    #[test]
    fn edit_keys() {
        let cases = [
            (format!("f/{U1}"), 1u8, 17usize),
            (format!("fieldDef/{U1}"), 2, 17),
            (format!("tmplDef/{U1}"), 3, 17),
            (format!("historyFrom/{U1}"), 4, 17),
            ("tags".to_owned(), 0, 6),
            ("deleted".to_owned(), 0, 9),
            (format!("f/{}", U1.to_uppercase()), 0, 40),
            (format!("f/{U1}/x"), 0, 42),
            (String::new(), 0, 2),
        ];
        for (s, tag, len) in cases {
            let mut w = Writer::new();
            write_edit_key(&mut w, &s);
            let b = w.into_vec();
            assert_eq!((b[0], b.len()), (tag, len), "{s}");
            assert_eq!(read_edit_key(&mut Reader::new(&b)).unwrap(), s);
        }
        let mut w = Writer::new();
        w.u8(0);
        w.str(&format!("f/{U1}"));
        assert!(read_edit_key(&mut Reader::new(&w.into_vec())).is_err());
        assert!(read_edit_key(&mut Reader::new(&[5; 17])).is_err());
    }

    /// 黄金向量：字节形冻结。
    #[test]
    fn golden_names() {
        assert_eq!(hex(&enc(U1)), "00862ab6799805548b9454d3ec51c44e9c");
        assert_eq!(
            hex(&enc(&format!("merged-{U1}"))),
            "02862ab6799805548b9454d3ec51c44e9c"
        );
        assert_eq!(
            hex(&enc(&format!("merged-{U1}~{U2}"))),
            "03862ab6799805548b9454d3ec51c44e9c8f28cfa86dd3592d8e4a2bf5aec4060d"
        );
        assert_eq!(
            hex(&enc(K1)),
            "04000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01"
        );
        assert_eq!(
            hex(&enc(&format!("sync2:tags:{U2}"))),
            "058f28cfa86dd3592d8e4a2bf5aec4060d"
        );
        assert_eq!(hex(&enc("anki")), "0104616e6b69");
        let mut w = Writer::new();
        write_edit_key(&mut w, &format!("historyFrom/{U1}"));
        write_edit_key(&mut w, "deck");
        assert_eq!(
            hex(&w.into_vec()),
            "04862ab6799805548b9454d3ec51c44e9c00046465636b"
        );
    }

    #[test]
    fn base64_matches_a_known_vector() {
        // RFC 4648 §10 的向量按 URL 安全字母表：32 个 0xfb 字节每 6 位都是 62 / 63 附近的值。
        let key = [0xfbu8; 32];
        let text = b64url_32(&key);
        assert_eq!(
            std::str::from_utf8(&text).unwrap(),
            "-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_s="
        );
        assert_eq!(un_b64url_32(&text), Some(key));
    }

    proptest! {
        /// 任意文本：编码再解码逐字节还原，且编码是规范的（解码成功）。
        #[test]
        fn any_text_round_trips(s in ".{0,80}") {
            prop_assert_eq!(dec(&enc(&s)).unwrap(), s.clone());
            let mut w = Writer::new();
            write_edit_key(&mut w, &s);
            prop_assert_eq!(read_edit_key(&mut Reader::new(&w.into_vec())).unwrap(), s);
        }

        /// 任意 32 字节公钥 + 序号都走紧凑形。
        #[test]
        fn any_key_seq_is_compact(key in proptest::array::uniform32(any::<u8>()), n in any::<u64>()) {
            let text = format!("{}#{n}", std::str::from_utf8(&b64url_32(&key)).unwrap());
            let b = enc(&text);
            prop_assert_eq!(b[0], TAG_KEY_SEQ);
            prop_assert_eq!(dec(&b).unwrap(), text);
        }

        /// 任意字节当名字解：要么拒绝，要么解出的文本重新编码与读掉的字节逐字节相同（没有第二种字节形）。
        #[test]
        fn decoding_is_canonical(bytes in proptest::collection::vec(any::<u8>(), 0..60)) {
            let mut r = Reader::new(&bytes);
            if let Ok(s) = read_name(&mut r) {
                prop_assert_eq!(enc(&s), bytes[..r.pos].to_vec());
            }
            let mut r = Reader::new(&bytes);
            if let Ok(s) = read_edit_key(&mut r) {
                let mut w = Writer::new();
                write_edit_key(&mut w, &s);
                prop_assert_eq!(w.into_vec(), bytes[..r.pos].to_vec());
            }
        }
    }
}
