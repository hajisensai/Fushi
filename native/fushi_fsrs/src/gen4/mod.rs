//! 协议 4 的线格式（docs/specs/2026-11-11-srs-generation-break.md §3、§4；实现拆分 G1）。
//!
//! 纯编解码，不碰 SQLite、**没有接进任何同步路径**：现有协议 3（`crate::sync2`、`crate::store::sync2`）的行为一个字节不变。
//! 这里定下的字节布局是持久化契约——字段顺序、整数编码、保留位都由各文件的黄金向量测试冻结，改动任何一个向量都等于再断代一次。
//!
//! - [name]：写入者名字与修改键的紧凑形。
//! - [stamp]：承袭修改带的紧凑旧戳（协议 1 的 dot / 因果上下文 / HLC / 服务器时刻）。
//! - [op]：操作信封、操作体（原生 Edit 没有旧戳、承袭 Edit 带旧戳、Log 紧凑编码、新种类 `Join`）、链。
//! - [segment]：原生段（魔数 `FSG4`，每设备成链，已清除的区间是空洞）。
//! - [heritage]：承袭段（魔数 `FSH4`，不成链、上传者签名）与槽（操作 / 原样件 / 副本记录 / 空洞，每个 seq 带原链值指纹）。
//! - [head]：协议 4 的 head（`seal`、`prev`、派生口径版本；签名覆盖除 `sig` 外的全部键）。
//!
//! 与协议 3 互不误读：段魔数不同，head 的必需键不同（[head] 文件头），操作体格式号从 4 起（[op::BODY_FMT]）。

pub mod head;
pub mod heritage;
pub mod name;
pub mod op;
pub mod segment;
pub mod stamp;

use crate::sync2::codec::{DResult, DecodeError, Reader, Writer};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::{Id, Key};
use crate::sync2::vv::Vv;

/// 协议版本（head 的 `v`）。
pub const PROTOCOL: u32 = 4;
/// 能读本版本写出的数据所需的最低读者版本（head 的 `minReader`）。
pub const MIN_READER: u32 = 4;

// ---------------------------------------------------------------- 严格读法
//
// 协议 3 的读法（`crate::sync2::codec::Reader`、`Key::read`）比写法宽：`uv` 收非最短的 LEB128，`Key` 收「本可存成 16 字节
// 的 UUID 文本」。协议 4 的规则是**一个值只有一种字节形**——解码器只收本版本的编码器写得出的字节——所以这里另备一套严格读法，
// 本模块的解码一律用它们（不改协议 3 的代码）。承袭日志靠这条性质做「同号同字节」的幂等判定：同一条旧操作不论谁转译，字节都相同。

/// 最短形的 LEB128：多字节且末字节为 0 的（同一个数的另一种字节形）拒绝。
pub(crate) fn uv_min(r: &mut Reader<'_>) -> DResult<u64> {
    let start = r.pos;
    let v = r.uv()?;
    if r.pos - start > 1 && r.buf[r.pos - 1] == 0 {
        return Err(DecodeError("non-minimal varint"));
    }
    Ok(v)
}

/// zigzag 的最短形。
pub(crate) fn iv_min(r: &mut Reader<'_>) -> DResult<i64> {
    let u = uv_min(r)?;
    Ok(((u >> 1) as i64) ^ -((u & 1) as i64))
}

/// 长度前缀取最短形的字节串。
pub(crate) fn bytes_min<'a>(r: &mut Reader<'a>) -> DResult<&'a [u8]> {
    let n = usize::try_from(uv_min(r)?).map_err(|_| DecodeError("length overflow"))?;
    r.raw(n)
}

/// 长度前缀取最短形的字符串。
pub(crate) fn str_min<'a>(r: &mut Reader<'a>) -> DResult<&'a str> {
    std::str::from_utf8(bytes_min(r)?).map_err(|_| DecodeError("bad utf-8"))
}

pub(crate) fn u16_min(r: &mut Reader<'_>, what: &'static str) -> DResult<u16> {
    u16::try_from(uv_min(r)?).map_err(|_| DecodeError(what))
}

/// 引用（实体 / 日志）：规范 UUID 文本只许存成 16 字节形。
pub(crate) fn read_key(r: &mut Reader<'_>) -> DResult<Key> {
    match r.u8()? {
        0 => Ok(Key::Uuid(Id::read(r)?)),
        1 => match Key::of(str_min(r)?) {
            Key::Uuid(_) => Err(DecodeError("key text has a uuid form")),
            k => Ok(k),
        },
        _ => Err(DecodeError("bad key tag")),
    }
}

/// 写引用（规范形：手工构造的 `Key::Text("<规范 UUID>")` 也写成 16 字节形）。
pub(crate) fn write_key(w: &mut Writer, k: &Key) {
    match k {
        Key::Text(s) => Key::of(s).write(w),
        Key::Uuid(_) => k.write(w),
    }
}

/// 版本向量（布局同 `Vv::write`：条数 + (设备, seq)，按设备严格升序、seq > 0）。
pub(crate) fn read_vv(r: &mut Reader<'_>) -> DResult<Vv> {
    let n = uv_min(r)?;
    if n > 1 << 20 {
        return Err(DecodeError("vv too large"));
    }
    let mut out = Vv::new();
    let mut prev: Option<Id> = None;
    for _ in 0..n {
        let d = Id::read(r)?;
        if prev.is_some_and(|p| p >= d) {
            return Err(DecodeError("vv not canonical"));
        }
        prev = Some(d);
        let s = uv_min(r)?;
        if s == 0 {
            return Err(DecodeError("vv zero entry"));
        }
        out.0.insert(d, s);
    }
    Ok(out)
}

/// HLC 的时间部分（布局同 `Hlc::write_time`）。
pub(crate) fn read_time(r: &mut Reader<'_>, device: Id) -> DResult<Hlc> {
    let wall = iv_min(r)?;
    let logical = u32::try_from(uv_min(r)?).map_err(|_| DecodeError("hlc logical"))?;
    Ok(Hlc {
        wall,
        logical,
        device,
    })
}

#[cfg(test)]
pub(crate) fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// 黄金向量断言：先把实际字节打出来（`GOLDEN <名字> <十六进制>`，失败时可见），再与冻结值比。
///
/// 新加一个向量时冻结值还空着：设 `FUSHI_GEN4_PRINT_GOLDEN` 后空值只打印、不在这里断，
/// 一轮就能把同一个测试里后面的向量也打出来。已经冻结的值不受它影响，照常比。
#[cfg(test)]
pub(crate) fn golden(name: &str, got: &[u8], want: &str) {
    println!("GOLDEN {name} {}", hex(got));
    if want.is_empty() && std::env::var_os("FUSHI_GEN4_PRINT_GOLDEN").is_some() {
        return;
    }
    assert_eq!(hex(got), want, "golden vector {name}");
}

#[cfg(test)]
pub(crate) fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).expect("hex"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minimal_varints_only() {
        for v in [0u64, 1, 127, 128, 300, u64::MAX] {
            let mut w = Writer::new();
            w.uv(v);
            assert_eq!(uv_min(&mut Reader::new(&w.into_vec())).unwrap(), v);
        }
        // 0 写成两字节、1 写成三字节：宽松读法（协议 3 的 `Reader::uv`）收，这里拒绝。
        assert_eq!(Reader::new(&[0x80, 0x00]).uv().unwrap(), 0);
        assert!(uv_min(&mut Reader::new(&[0x80, 0x00])).is_err());
        assert!(uv_min(&mut Reader::new(&[0x81, 0x80, 0x00])).is_err());
        assert!(str_min(&mut Reader::new(&[0x81, 0x00, b'a'])).is_err());
        assert_eq!(iv_min(&mut Reader::new(&[0x03])).unwrap(), -2);
        assert!(bytes_min(&mut Reader::new(&[0x80, 0x00])).is_err());
    }

    #[test]
    fn keys_have_one_byte_form() {
        let u = "0192f0aa-0000-7000-8000-00000000000b";
        // 协议 3 的读法收「UUID 文本」形，这里拒绝；写法把手工构造的文本形归回 16 字节形。
        let mut w = Writer::new();
        Key::Text(u.to_owned()).write(&mut w);
        let loose = w.into_vec();
        assert!(Key::read(&mut Reader::new(&loose)).is_ok());
        assert!(read_key(&mut Reader::new(&loose)).is_err());
        let mut w = Writer::new();
        write_key(&mut w, &Key::Text(u.to_owned()));
        let bytes = w.into_vec();
        assert_eq!(bytes.len(), 17);
        assert_eq!(read_key(&mut Reader::new(&bytes)).unwrap(), Key::of(u));
        // 大写的不是规范 UUID 文本：留文本。
        let upper = u.to_uppercase();
        let mut w = Writer::new();
        write_key(&mut w, &Key::of(&upper));
        assert_eq!(
            read_key(&mut Reader::new(&w.into_vec())).unwrap(),
            Key::Text(upper)
        );
    }

    #[test]
    fn version_vectors_are_strict() {
        let mut vv = Vv::new();
        vv.set(Id([1; 16]), 3);
        vv.set(Id([2; 16]), 300);
        assert_eq!(read_vv(&mut Reader::new(&vv.encode())).unwrap(), vv);
        // seq 写成非最短形。
        let mut bad = vec![1u8];
        bad.extend_from_slice(&[1; 16]);
        bad.extend_from_slice(&[0x83, 0x00]);
        assert!(Vv::read(&mut Reader::new(&bad)).is_ok());
        assert!(read_vv(&mut Reader::new(&bad)).is_err());
    }
}
