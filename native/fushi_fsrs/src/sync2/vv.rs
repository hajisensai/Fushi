//! 版本向量与操作 ID（设计 §3.1、§5.1）。
//!
//! `OpId = (DeviceId, seq)`，设备内从 1 起单调递增、无空洞。副本只按设备的连续前缀应用操作
//! （[super::kernel] 的因果投递缓冲），所以「已应用的操作集合」恰好是一个版本向量；每条操作带上作者
//! 当时的版本向量（它的因果上下文），于是「a 在 b 之前发生」⇔ `ctx(b)` 含 `a.id`。

use std::collections::BTreeMap;

use super::codec::{DResult, DecodeError, Reader, Writer};
use super::id::Id;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct OpId {
    pub device: Id,
    pub seq: u64,
}

/// 每台设备已连续见到的最大 seq（0 = 一条都没有，不存）。
#[derive(Clone, PartialEq, Eq, Hash, Debug, Default)]
pub struct Vv(pub BTreeMap<Id, u64>);

impl Vv {
    pub fn new() -> Self {
        Vv(BTreeMap::new())
    }

    pub fn get(&self, device: &Id) -> u64 {
        self.0.get(device).copied().unwrap_or(0)
    }

    pub fn contains(&self, op: &OpId) -> bool {
        op.seq != 0 && op.seq <= self.get(&op.device)
    }

    /// 记下一条操作；只接受连续的下一条（重复的返回 false，跳号是调用方的 bug）。
    pub fn advance(&mut self, op: &OpId) -> Result<bool, String> {
        let cur = self.get(&op.device);
        if op.seq <= cur {
            return Ok(false);
        }
        if op.seq != cur + 1 {
            return Err(format!("non-contiguous op {}:{} after {cur}", op.device, op.seq));
        }
        self.0.insert(op.device, op.seq);
        Ok(true)
    }

    pub fn set(&mut self, device: Id, seq: u64) {
        if seq == 0 {
            self.0.remove(&device);
        } else {
            self.0.insert(device, seq);
        }
    }

    pub fn merge(&mut self, other: &Vv) {
        for (d, &s) in &other.0 {
            let e = self.0.entry(*d).or_insert(0);
            if s > *e {
                *e = s;
            }
        }
    }

    /// self ⊆ other。
    pub fn le(&self, other: &Vv) -> bool {
        self.0.iter().all(|(d, &s)| s <= other.get(d))
    }

    /// 截到 [limit] 以内（时间线：某个历史时刻的版本向量）。
    pub fn meet(&self, limit: &Vv) -> Vv {
        let mut out = Vv::new();
        for (d, &s) in &self.0 {
            out.set(*d, s.min(limit.get(d)));
        }
        out
    }

    pub fn total(&self) -> u64 {
        self.0.values().sum()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// 紧凑编码：条数 + (设备, seq)，按设备升序（规范形，哈希稳定）。
    pub fn write(&self, w: &mut Writer) {
        w.uv(self.0.len() as u64);
        for (d, &s) in &self.0 {
            d.write(w);
            w.uv(s);
        }
    }

    pub fn read(r: &mut Reader<'_>) -> DResult<Vv> {
        let n = r.uv()?;
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
            let s = r.uv()?;
            if s == 0 {
                return Err(DecodeError("vv zero entry"));
            }
            out.0.insert(d, s);
        }
        Ok(out)
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        self.write(&mut w);
        w.into_vec()
    }

    /// 规范编码的 BLAKE3（快照文件名 `<vvHash>.snap`）。
    pub fn hash_hex(&self) -> String {
        blake3::hash(&self.encode()).to_hex().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(b: u8) -> Id {
        Id([b; 16])
    }

    #[test]
    fn advance_only_accepts_the_next_contiguous_seq() {
        let mut v = Vv::new();
        assert_eq!(v.advance(&OpId { device: id(1), seq: 1 }), Ok(true));
        assert_eq!(v.advance(&OpId { device: id(1), seq: 1 }), Ok(false));
        assert!(v.advance(&OpId { device: id(1), seq: 3 }).is_err());
        assert!(v.contains(&OpId { device: id(1), seq: 1 }));
        assert!(!v.contains(&OpId { device: id(1), seq: 2 }));
    }

    #[test]
    fn order_merge_and_canonical_encoding() {
        let mut a = Vv::new();
        a.set(id(1), 3);
        let mut b = Vv::new();
        b.set(id(1), 2);
        b.set(id(2), 5);
        assert!(!a.le(&b) && !b.le(&a));
        let mut m = a.clone();
        m.merge(&b);
        assert!(a.le(&m) && b.le(&m));
        assert_eq!(m.get(&id(1)), 3);
        let bytes = m.encode();
        assert_eq!(Vv::read(&mut Reader::new(&bytes)).unwrap(), m);
        assert_eq!(m.meet(&b), b);
    }
}
