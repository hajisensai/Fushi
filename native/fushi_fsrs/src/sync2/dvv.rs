//! 旧协议的 dotted version vector（Dart `SrsCausalContext`，JSON 形态逐字相同）。
//!
//! v2 的因果上下文是按设备的版本向量（vv.rs）。投影行（srs_field_edits）仍是旧形态：dot =
//! (writerId, seq)、ctx = DVV，读侧的字段寄存器内核（registers.rs）按「b.ctx 含 a.dot」判支配。v2
//! 写入的投影行 dot = (设备 ID 文本, op seq)，ctx = 「作者已应用的版本向量（设备 ID 文本）」并上「这些
//! 操作里迁移进来的旧修改记录的旧 dot 与旧上下文」（[super::legacy] 的闭包），于是读侧的支配判定与
//! v2 内核的因果判定是同一个关系。

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{json, Map, Value};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Dvv {
    pub vv: BTreeMap<String, i64>,
    pub cloud: BTreeMap<String, BTreeSet<i64>>,
}

impl Dvv {
    /// Dart `SrsCausalContext.fromJson`（不是对象当空；vv 只认 > 0 的整数）。
    pub fn from_json(v: &Value) -> Dvv {
        let mut d = Dvv::default();
        let Some(m) = v.as_object() else { return d };
        if let Some(vv) = m.get("vv").and_then(Value::as_object) {
            for (k, x) in vv {
                if let Some(n) = x.as_i64().filter(|&n| n > 0) {
                    d.vv.insert(k.clone(), n);
                }
            }
        }
        if let Some(cloud) = m.get("cloud").and_then(Value::as_object) {
            for (k, x) in cloud {
                if let Some(xs) = x.as_array() {
                    let set: BTreeSet<i64> = xs.iter().filter_map(Value::as_i64).collect();
                    if !set.is_empty() {
                        d.cloud.insert(k.clone(), set);
                    }
                }
            }
        }
        d.compact();
        d
    }

    pub fn parse(text: &str) -> Dvv {
        serde_json::from_str::<Value>(text).map(|v| Dvv::from_json(&v)).unwrap_or_default()
    }

    /// Dart `toJson`：vv 键排序；cloud 为空时不输出。
    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("vv".into(), Value::Object(self.vv.iter().map(|(k, v)| (k.clone(), json!(v))).collect()));
        if !self.cloud.is_empty() {
            m.insert(
                "cloud".into(),
                Value::Object(self.cloud.iter().map(|(k, s)| (k.clone(), json!(s.iter().collect::<Vec<_>>()))).collect()),
            );
        }
        Value::Object(m)
    }

    pub fn contains(&self, writer: &str, seq: i64) -> bool {
        seq <= self.vv.get(writer).copied().unwrap_or(0) || self.cloud.get(writer).is_some_and(|s| s.contains(&seq))
    }

    pub fn add(&mut self, writer: &str, seq: i64) {
        if seq <= 0 || self.contains(writer, seq) {
            return;
        }
        self.cloud.entry(writer.to_owned()).or_default().insert(seq);
        self.compact();
    }

    /// 前缀 vv 记一条（v2 设备分量：已应用 1..=seq）。
    pub fn raise(&mut self, writer: &str, seq: i64) {
        if seq > 0 {
            let e = self.vv.entry(writer.to_owned()).or_insert(0);
            if *e < seq {
                *e = seq;
            }
            self.compact();
        }
    }

    pub fn merge(&mut self, other: &Dvv) {
        for (k, &v) in &other.vv {
            let e = self.vv.entry(k.clone()).or_insert(0);
            if *e < v {
                *e = v;
            }
        }
        for (k, s) in &other.cloud {
            self.cloud.entry(k.clone()).or_default().extend(s.iter().copied());
        }
        self.compact();
    }

    /// 去掉写入者名以 [prefix] 开头的全部分量（vv 与 cloud 都去）。返回是否去掉了什么。各写入者的分量互不影响
    /// （[Dvv::compact] 按写入者各自进行），所以「先合并再去掉」与「先去掉再合并」结果相同。
    pub fn drop_writers(&mut self, prefix: &str) -> bool {
        let before = self.vv.len() + self.cloud.len();
        self.vv.retain(|k, _| !k.starts_with(prefix));
        self.cloud.retain(|k, _| !k.starts_with(prefix));
        self.vv.len() + self.cloud.len() != before
    }

    pub fn is_empty(&self) -> bool {
        self.vv.is_empty() && self.cloud.is_empty()
    }

    /// Dart `_compactAll`：cloud 里接得上前缀的并进去，被前缀覆盖的删掉。
    fn compact(&mut self) {
        let keys: Vec<String> = self.cloud.keys().cloned().collect();
        for w in keys {
            let set = self.cloud.get_mut(&w).expect("key");
            let mut top = self.vv.get(&w).copied().unwrap_or(0);
            while let Some(&s) = set.iter().next() {
                if s > top + 1 {
                    break;
                }
                set.remove(&s);
                if s == top + 1 {
                    top = s;
                }
            }
            if top > 0 {
                self.vv.insert(w.clone(), top);
            }
            if set.is_empty() {
                self.cloud.remove(&w);
            }
        }
        self.vv.retain(|_, v| *v > 0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_shape_and_compaction_match_dart() {
        let d = Dvv::parse(r#"{"vv":{"b":2,"a":1},"cloud":{"a":[2,3,5],"b":[1,9]}}"#);
        assert_eq!(d.to_json().to_string(), r#"{"cloud":{"a":[5],"b":[9]},"vv":{"a":3,"b":2}}"#);
        assert!(d.contains("a", 3) && d.contains("a", 5) && !d.contains("a", 4));
        let mut e = Dvv::default();
        assert_eq!(e.to_json().to_string(), r#"{"vv":{}}"#);
        e.add("w", 2);
        e.add("w", 1);
        assert_eq!(e.to_json().to_string(), r#"{"vv":{"w":2}}"#);
        let mut m = d.clone();
        m.merge(&e);
        assert!(m.contains("w", 2) && m.contains("a", 5));
    }

    /// 去掉一类写入者与合并可交换（迁移「去掉存量」与投影「不收新的」是同一个结果的依据）。
    #[test]
    fn dropping_writers_commutes_with_merge() {
        let a = Dvv::parse(r#"{"vv":{"a":2,"x:1":1},"cloud":{"a":[4],"x:2":[3]}}"#);
        let b = Dvv::parse(r#"{"vv":{"a":3,"x:1":1,"b":1},"cloud":{"x:3":[2]}}"#);
        let mut merged_then_dropped = a.clone();
        merged_then_dropped.merge(&b);
        assert!(merged_then_dropped.drop_writers("x:"));
        let (mut a2, mut b2) = (a.clone(), b.clone());
        a2.drop_writers("x:");
        b2.drop_writers("x:");
        a2.merge(&b2);
        assert_eq!(merged_then_dropped, a2);
        assert_eq!(a2.to_json().to_string(), r#"{"vv":{"a":4,"b":1}}"#);
        assert!(!a2.clone().drop_writers("x:"));
    }
}
