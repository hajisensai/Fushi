//! 标识（设计 §3.1）：128 位 ID，存储与 wire 一律 16 字节；只在跨 FFI 给界面 / 写投影行时转文本。
//!
//! - 本地新建的实体与设备身份：随机 UUIDv7（[Id::new_v7]）。
//! - 确定性 UUIDv5 只从不可变的外部来源身份派生（[Id::v5]），规则表在 Dart `SrsIds` 与本仓
//!   `registers.rs` 的命名空间常量里，这里只提供算法。
//! - 存量 ID 是 UUID 文本；万一遇到不是 UUID 的文本（坏数据 / 更早的格式），[Key] 原样带着文本走，
//!   不改写、不丢弃。

use std::fmt;

use sha1::{Digest, Sha1};

use super::codec::{DResult, DecodeError, Reader, Writer};

/// 128 位 ID。字节序即 UUID 的网络序，按字节比较 = 按 UUID 文本比较（小写十六进制）。
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct Id(pub [u8; 16]);

impl Id {
    pub const ZERO: Id = Id([0; 16]);

    /// 随机 UUIDv7（时间前缀利于存储局部性）。
    pub fn new_v7(now_ms: u64) -> Id {
        let mut b = [0u8; 16];
        getrandom::fill(&mut b).expect("system random source");
        for i in 0..6 {
            b[i] = (now_ms >> (8 * (5 - i))) as u8;
        }
        b[6] = (b[6] & 0x0f) | 0x70;
        b[8] = (b[8] & 0x3f) | 0x80;
        Id(b)
    }

    /// 纯随机 128 位（设备密钥种子等不需要时间前缀的地方用）。
    pub fn random() -> Id {
        let mut b = [0u8; 16];
        getrandom::fill(&mut b).expect("system random source");
        Id(b)
    }

    /// RFC 9562 UUIDv5（SHA-1，名字按 UTF-8）。与 Dart `uuidV5` 逐位相同。
    pub fn v5(namespace: &Id, name: &str) -> Id {
        let mut h = Sha1::new();
        h.update(namespace.0);
        h.update(name.as_bytes());
        let d = h.finalize();
        let mut b = [0u8; 16];
        b.copy_from_slice(&d[..16]);
        b[6] = (b[6] & 0x0f) | 0x50;
        b[8] = (b[8] & 0x3f) | 0x80;
        Id(b)
    }

    /// 解析 UUID 文本（带或不带连字符，大小写都认）。
    pub fn parse(s: &str) -> Option<Id> {
        let bytes = s.as_bytes();
        let hex: Vec<u8> = match bytes.len() {
            36 => {
                if bytes[8] != b'-' || bytes[13] != b'-' || bytes[18] != b'-' || bytes[23] != b'-' {
                    return None;
                }
                bytes.iter().copied().filter(|&c| c != b'-').collect()
            }
            32 => bytes.to_vec(),
            _ => return None,
        };
        if hex.len() != 32 {
            return None;
        }
        let mut out = [0u8; 16];
        for i in 0..16 {
            out[i] = (nibble(hex[2 * i])? << 4) | nibble(hex[2 * i + 1])?;
        }
        Some(Id(out))
    }

    /// 规范文本：小写、带连字符（与 Dart `_formatUuid` 相同）。
    pub fn text(&self) -> String {
        let mut s = String::with_capacity(36);
        for (i, b) in self.0.iter().enumerate() {
            if i == 4 || i == 6 || i == 8 || i == 10 {
                s.push('-');
            }
            s.push(HEX[(b >> 4) as usize] as char);
            s.push(HEX[(b & 0xf) as usize] as char);
        }
        s
    }

    pub fn write(&self, w: &mut Writer) {
        w.raw(&self.0);
    }

    pub fn read(r: &mut Reader<'_>) -> DResult<Id> {
        let b: [u8; 16] = r.raw(16)?.try_into().map_err(|_| DecodeError("id"))?;
        Ok(Id(b))
    }
}

const HEX: &[u8; 16] = b"0123456789abcdef";

fn nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

impl fmt::Debug for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", &self.text()[..8])
    }
}

impl fmt::Display for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text())
    }
}

/// 实体 / 日志 / 写入者的引用：规范 UUID 文本存 16 字节，其它文本原样存。
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum Key {
    Uuid(Id),
    Text(String),
}

impl Key {
    /// 文本 → 引用：只有「解析后再格式化与原文逐字相同」的才压成 16 字节（大写 / 无连字符的
    /// 存量文本照原样保留，投影回文本时不变形）。
    pub fn of(s: &str) -> Key {
        match Id::parse(s) {
            Some(id) if id.text() == s => Key::Uuid(id),
            _ => Key::Text(s.to_owned()),
        }
    }

    pub fn text(&self) -> String {
        match self {
            Key::Uuid(id) => id.text(),
            Key::Text(s) => s.clone(),
        }
    }

    pub fn write(&self, w: &mut Writer) {
        match self {
            Key::Uuid(id) => {
                w.u8(0);
                id.write(w);
            }
            Key::Text(s) => {
                w.u8(1);
                w.str(s);
            }
        }
    }

    pub fn read(r: &mut Reader<'_>) -> DResult<Key> {
        match r.u8()? {
            0 => Ok(Key::Uuid(Id::read(r)?)),
            1 => Ok(Key::Text(r.str()?.to_owned())),
            _ => Err(DecodeError("bad key tag")),
        }
    }
}

impl From<Id> for Key {
    fn from(id: Id) -> Self {
        Key::Uuid(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v5_matches_the_dart_rule_table() {
        // Dart：uuidV5(srsNamespace, 'edit/w1/3')；namespace 冻结值见 ids.dart。
        let ns = Id::parse("6f1c8a2e-4b7d-5e3f-9a10-2d4c6e8f0b13").unwrap();
        let a = Id::v5(&ns, "edit/w1/3");
        assert_eq!(a.0[6] >> 4, 5);
        assert_eq!(a, Id::v5(&ns, "edit/w1/3"));
        assert_ne!(a, Id::v5(&ns, "edit/w1/4"));
        // 与 registers.rs 里修改记录 ID 的实现逐位相同（两份实现必须一致）。
        assert_eq!(a.text(), crate::registers::edit_id("w1", 3));
    }

    #[test]
    fn text_round_trip_and_non_uuid_keys_survive() {
        let id = Id::new_v7(1_700_000_000_000);
        assert_eq!(Id::parse(&id.text()), Some(id));
        assert_eq!(id.0[6] >> 4, 7);
        assert_eq!(Key::of(&id.text()), Key::Uuid(id));
        let upper = id.text().to_uppercase();
        assert_eq!(Key::of(&upper), Key::Text(upper.clone()));
        assert_eq!(Key::of("not-a-uuid").text(), "not-a-uuid");
        let mut w = Writer::new();
        Key::of("x").write(&mut w);
        Key::of(&id.text()).write(&mut w);
        let buf = w.into_vec();
        let mut r = Reader::new(&buf);
        assert_eq!(Key::read(&mut r).unwrap(), Key::Text("x".into()));
        assert_eq!(Key::read(&mut r).unwrap(), Key::Uuid(id));
    }
}
