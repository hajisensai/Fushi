//! 紧凑旧戳（设计 §3.1、§3.4）：承袭的修改操作带着的协议 1 因果数据。
//!
//! 协议 3 把它存成文本（`crate::sync2::op::LegacyStamp`：写入者名字、上下文 JSON、HLC 文本），真实库里 35 万条修改合计
//! 75 MB，其中几乎全是重复的名字。这里信息一项不少、换成紧凑形：
//!
//! ```text
//! flags u8   bit0 有 server_time
//!            bit1 HLC 的写入者 == 本戳的写入者
//!            bit2 HLC 存原文（解析不了，或不是规范十进制）
//!            bit3 上下文里有 cloud
//!            bit4–7 必须为 0
//! writer  Name（name.rs）
//! seq     iv
//! ctx     n uv；n 项按写入者文本的字节序严格升序：
//!           NameRef | vv uv | [bit3: m uv；m × uv 增量（第一个相对 vv、且 ≥ 2；其余相对前一个、且 ≥ 1）]
//!         每项 vv > 0 或 m > 0
//! hlc     bit2 = 0: physical iv | counter iv | [bit1 = 0: Name]
//!         bit2 = 1: str 原文
//! [bit0]  iv(server_time − base)；base = physical（bit2 = 1 时为 0），按 i64 回绕减
//! ```
//!
//! 一个旧戳只有一种字节形（[HeritageStamp::read] 拒绝其余的）：varint 取最短、名字取规范形、上下文归一并排序、
//! 标志位与内容一致。旧戳是冻结的数据，以后不会有新字段，所以保留位非 0 直接拒绝。
//!
//! 上下文 [StampCtx] 存的是旧 dotted version vector 的**语义**（`crate::sync2::dvv::Dvv` 归一后的前缀 + 额外 dot），
//! 不是 JSON 原文：判定只用「含不含某个 dot」。合成写入者（`sync2:` 前缀）不在其中——转译时按现有规则去掉
//! （store/sync2/mod.rs `strip_synthetic_ctx`），带着它们的字节拒绝。

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use super::name::{read_name, read_name_ref, write_name, write_name_ref};
use super::{iv_min, str_min, uv_min};
use crate::sync2::codec::{DResult, DecodeError, Reader, Writer};
use crate::sync2::dvv::Dvv;

const F_SERVER_TIME: u8 = 1;
const F_HLC_SAME_WRITER: u8 = 2;
const F_HLC_RAW: u8 = 4;
const F_CLOUD: u8 = 8;
const F_KNOWN: u8 = 15;

/// 合成写入者的前缀（`crate::registers::SYNTHETIC_WRITER_PREFIX`；冻结）。
pub const SYNTHETIC_PREFIX: &str = "sync2:";

/// 旧 HLC（文本 `physical:counter:writer`）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StampHlc {
    /// 规范文本：三段拼回去与原文逐字节相同。
    Parsed {
        physical: i64,
        counter: i64,
        writer: String,
    },
    /// 其余（坏数据、`+5`、前导零……）：原文照存，不变形。
    Raw(String),
}

impl StampHlc {
    /// 文本 → 旧 HLC。解析规则与读侧相同（`crate::history::parse_hlc`：按前两个冒号切成三段，前两段是 i64）。
    pub fn of(text: &str) -> StampHlc {
        if let Ok((physical, counter, writer)) = crate::history::parse_hlc(text) {
            let hlc = StampHlc::Parsed {
                physical,
                counter,
                writer: writer.to_owned(),
            };
            if hlc.text() == text {
                return hlc;
            }
        }
        StampHlc::Raw(text.to_owned())
    }

    pub fn text(&self) -> String {
        match self {
            StampHlc::Parsed {
                physical,
                counter,
                writer,
            } => format!("{physical}:{counter}:{writer}"),
            StampHlc::Raw(t) => t.clone(),
        }
    }

    /// server_time 增量编码的基准。
    fn base(&self) -> i64 {
        match self {
            StampHlc::Parsed { physical, .. } => *physical,
            StampHlc::Raw(_) => 0,
        }
    }

    /// 写 HLC 本体（标志位由调用方放）：[same] = 写入者与调用方的默认写入者相同、不写名字。
    pub(crate) fn write_body(&self, w: &mut Writer, same: bool) {
        match self {
            StampHlc::Parsed {
                physical,
                counter,
                writer,
            } => {
                w.iv(*physical);
                w.iv(*counter);
                if !same {
                    write_name(w, writer);
                }
            }
            StampHlc::Raw(t) => w.str(t),
        }
    }

    /// 读 HLC 本体。[raw] / [same] 是调用方读到的标志位，[default_writer] 是 [same] 时的写入者。
    /// 标志位与内容不一致（本可拆开的原文、等于默认写入者却写了名字）的拒绝。
    pub(crate) fn read_body(
        r: &mut Reader<'_>,
        raw: bool,
        same: bool,
        default_writer: &str,
    ) -> DResult<StampHlc> {
        if raw {
            if same {
                return Err(DecodeError("raw hlc with the same-writer flag"));
            }
            let t = str_min(r)?;
            if matches!(StampHlc::of(t), StampHlc::Parsed { .. }) {
                return Err(DecodeError("raw hlc has a parsed form"));
            }
            return Ok(StampHlc::Raw(t.to_owned()));
        }
        let physical = iv_min(r)?;
        let counter = iv_min(r)?;
        let writer = if same {
            default_writer.to_owned()
        } else {
            let n = read_name(r)?;
            if n == default_writer {
                return Err(DecodeError("hlc repeats the default writer"));
            }
            n
        };
        let hlc = StampHlc::Parsed {
            physical,
            counter,
            writer,
        };
        // 写入者里带换行之类不影响往返；但拼回去的文本必须还能解析回同一个三元组（写入者不会吃掉前两段）。
        if StampHlc::of(&hlc.text()) != hlc {
            return Err(DecodeError("hlc does not survive its text form"));
        }
        Ok(hlc)
    }

    /// [write_body] 该不该带「写入者相同」标志。
    pub(crate) fn same_writer(&self, default_writer: &str) -> bool {
        matches!(self, StampHlc::Parsed { writer, .. } if writer == default_writer)
    }

    pub(crate) fn is_raw(&self) -> bool {
        matches!(self, StampHlc::Raw(_))
    }
}

/// 上下文里一个写入者的分量：连续前缀 `1..=vv`，加上前缀之外的零散 dot（升序，都 > vv + 1）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CtxEntry {
    pub writer: String,
    pub vv: u64,
    pub cloud: Vec<u64>,
}

/// 旧因果上下文的规范形：按写入者文本的字节序升序，不含合成写入者，不含空项。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StampCtx(Vec<CtxEntry>);

impl StampCtx {
    /// 旧上下文的 JSON 原文 → 规范形。解不开的当空（与投影路径 store/sync2/mod.rs `edit_row_with` 的兜底相同）。
    pub fn parse(text: &str) -> StampCtx {
        serde_json::from_str::<Value>(text)
            .map(|v| StampCtx::from_json(&v))
            .unwrap_or_default()
    }

    /// 旧上下文的 JSON → 规范形。读法与读侧相同（`registers.rs` 的 `Ctx::parse`、`Dvv::from_json`）：不是对象当空；
    /// `vv` 只认 > 0 的整数；`cloud` 只认数组里的整数；其余键不看。
    pub fn from_json(v: &Value) -> StampCtx {
        let mut by: BTreeMap<&str, (i64, BTreeSet<i64>)> = BTreeMap::new();
        if let Some(m) = v.as_object() {
            if let Some(vv) = m.get("vv").and_then(Value::as_object) {
                for (w, x) in vv {
                    if let Some(n) = x.as_i64().filter(|&n| n > 0) {
                        by.entry(w.as_str()).or_default().0 = n;
                    }
                }
            }
            if let Some(cloud) = m.get("cloud").and_then(Value::as_object) {
                for (w, x) in cloud {
                    if let Some(xs) = x.as_array() {
                        by.entry(w.as_str())
                            .or_default()
                            .1
                            .extend(xs.iter().filter_map(Value::as_i64));
                    }
                }
            }
        }
        StampCtx::normalize(by)
    }

    /// 从旧 dotted version vector 取规范形：自己再归一一遍（不依赖传入值已经归一），并去掉合成写入者。
    pub fn from_dvv(d: &Dvv) -> StampCtx {
        let mut by: BTreeMap<&str, (i64, BTreeSet<i64>)> = BTreeMap::new();
        for (w, &v) in &d.vv {
            by.entry(w.as_str()).or_default().0 = v.max(0);
        }
        for (w, set) in &d.cloud {
            by.entry(w.as_str())
                .or_default()
                .1
                .extend(set.iter().copied());
        }
        StampCtx::normalize(by)
    }

    /// 归一：每个写入者「连续前缀 + 前缀之外的 dot」，去掉合成写入者与空项。「含不含某个 dot」的关系不变
    /// （<= 0 的 seq 两边恒含；被前缀覆盖的、接得上前缀的 dot 并进前缀）。
    fn normalize(by: BTreeMap<&str, (i64, BTreeSet<i64>)>) -> StampCtx {
        let mut out = Vec::new();
        for (w, (mut top, set)) in by {
            if w.starts_with(SYNTHETIC_PREFIX) {
                continue;
            }
            let mut cloud = Vec::new();
            for s in set {
                if s <= top {
                    continue;
                }
                if top.checked_add(1) == Some(s) && cloud.is_empty() {
                    top = s;
                } else {
                    cloud.push(s as u64);
                }
            }
            if top > 0 || !cloud.is_empty() {
                out.push(CtxEntry {
                    writer: w.to_owned(),
                    vv: top as u64,
                    cloud,
                });
            }
        }
        StampCtx(out)
    }

    pub fn to_dvv(&self) -> Dvv {
        let mut d = Dvv::default();
        for e in &self.0 {
            if e.vv > 0 {
                d.vv.insert(e.writer.clone(), e.vv as i64);
            }
            if !e.cloud.is_empty() {
                d.cloud.insert(
                    e.writer.clone(),
                    e.cloud.iter().map(|&s| s as i64).collect(),
                );
            }
        }
        d
    }

    pub fn entries(&self) -> &[CtxEntry] {
        &self.0
    }

    /// 含不含 dot `(writer, seq)`——与 `Dvv::contains`、`registers.rs` 的 `Ctx::contains` 同一个关系。
    pub fn contains(&self, writer: &str, seq: i64) -> bool {
        if seq <= 0 {
            return true;
        }
        self.0
            .iter()
            .find(|e| e.writer == writer)
            .is_some_and(|e| seq as u64 <= e.vv || e.cloud.binary_search(&(seq as u64)).is_ok())
    }

    fn has_cloud(&self) -> bool {
        self.0.iter().any(|e| !e.cloud.is_empty())
    }
}

/// 一条承袭修改的旧戳。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HeritageStamp {
    /// 旧写入者（dot 的前半；可以是合成写入者——只有上下文里不留它们）。
    pub writer: String,
    /// 旧序号（dot 的后半）。
    pub seq: i64,
    pub ctx: StampCtx,
    pub hlc: StampHlc,
    /// 旧协议的服务器时刻 S(e)（排序钳位用，`crate::ordering::sort_physical`）。
    pub server_time: Option<i64>,
}

impl HeritageStamp {
    pub fn write(&self, w: &mut Writer) {
        let same = self.hlc.same_writer(&self.writer);
        let cloud = self.ctx.has_cloud();
        let mut flags = 0;
        if self.server_time.is_some() {
            flags |= F_SERVER_TIME;
        }
        if same {
            flags |= F_HLC_SAME_WRITER;
        }
        if self.hlc.is_raw() {
            flags |= F_HLC_RAW;
        }
        if cloud {
            flags |= F_CLOUD;
        }
        w.u8(flags);
        write_name(w, &self.writer);
        w.iv(self.seq);
        w.uv(self.ctx.0.len() as u64);
        for e in &self.ctx.0 {
            write_name_ref(w, &e.writer, &self.writer);
            w.uv(e.vv);
            if cloud {
                w.uv(e.cloud.len() as u64);
                let mut prev = e.vv;
                for &s in &e.cloud {
                    w.uv(s - prev);
                    prev = s;
                }
            }
        }
        self.hlc.write_body(w, same);
        if let Some(s) = self.server_time {
            w.iv(s.wrapping_sub(self.hlc.base()));
        }
    }

    pub fn read(r: &mut Reader<'_>) -> DResult<HeritageStamp> {
        let flags = r.u8()?;
        if flags & !F_KNOWN != 0 {
            return Err(DecodeError("stamp reserved flags"));
        }
        let writer = read_name(r)?;
        let seq = iv_min(r)?;
        let n = uv_min(r)?;
        // 没有条数上限（任何旧戳都得转得过来）；只防「声明的条数比剩下的字节还多」。报成截断：流式读侧据此补读。
        if n > r.remaining().len() as u64 {
            return Err(DecodeError("truncated stamp ctx"));
        }
        let cloud = flags & F_CLOUD != 0;
        let mut entries: Vec<CtxEntry> = Vec::with_capacity(n.min(64) as usize);
        let mut any_cloud = false;
        for _ in 0..n {
            let w = read_name_ref(r, &writer)?;
            if w.starts_with(SYNTHETIC_PREFIX) {
                return Err(DecodeError("stamp ctx names a synthetic writer"));
            }
            if entries
                .last()
                .is_some_and(|p| p.writer.as_bytes() >= w.as_bytes())
            {
                return Err(DecodeError("stamp ctx not sorted"));
            }
            let vv = uv_min(r)?;
            if vv > i64::MAX as u64 {
                return Err(DecodeError("stamp ctx seq"));
            }
            let mut dots = Vec::new();
            if cloud {
                let m = uv_min(r)?;
                if m > r.remaining().len() as u64 {
                    return Err(DecodeError("truncated stamp ctx cloud"));
                }
                let mut prev = vv;
                for k in 0..m {
                    let d = uv_min(r)?;
                    if d < if k == 0 { 2 } else { 1 } {
                        return Err(DecodeError("stamp ctx cloud not canonical"));
                    }
                    prev = prev
                        .checked_add(d)
                        .filter(|&s| s <= i64::MAX as u64)
                        .ok_or(DecodeError("stamp ctx seq"))?;
                    dots.push(prev);
                }
            }
            if vv == 0 && dots.is_empty() {
                return Err(DecodeError("stamp ctx empty entry"));
            }
            any_cloud |= !dots.is_empty();
            entries.push(CtxEntry {
                writer: w,
                vv,
                cloud: dots,
            });
        }
        if cloud != any_cloud {
            return Err(DecodeError("stamp cloud flag"));
        }
        let hlc = StampHlc::read_body(
            r,
            flags & F_HLC_RAW != 0,
            flags & F_HLC_SAME_WRITER != 0,
            &writer,
        )?;
        let server_time = if flags & F_SERVER_TIME != 0 {
            Some(iv_min(r)?.wrapping_add(hlc.base()))
        } else {
            None
        };
        Ok(HeritageStamp {
            writer,
            seq,
            ctx: StampCtx(entries),
            hlc,
            server_time,
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        self.write(&mut w);
        w.into_vec()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::gen4::hex;
    use proptest::prelude::*;

    pub const K1: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=#1";
    pub const M1: &str = "merged-862ab679-9805-548b-9454-d3ec51c44e9c";

    pub fn ctx_of(json: &str) -> StampCtx {
        StampCtx::from_dvv(&Dvv::parse(json))
    }

    /// 样本库里最常见的形状：上下文只有写入者自己的前缀，HLC 写入者就是写入者，带服务器时刻。
    pub fn typical() -> HeritageStamp {
        HeritageStamp {
            writer: K1.into(),
            seq: 4821,
            ctx: ctx_of(&format!(r#"{{"vv":{{"{K1}":4820}}}}"#)),
            hlc: StampHlc::of(&format!("1792055806043:0:{K1}")),
            server_time: Some(1_792_055_809_512),
        }
    }

    fn round_trip(s: &HeritageStamp) -> Vec<u8> {
        let b = s.encode();
        let mut r = Reader::new(&b);
        assert_eq!(&HeritageStamp::read(&mut r).unwrap(), s);
        assert!(r.is_empty());
        b
    }

    #[test]
    fn golden_typical_stamp() {
        let b = round_trip(&typical());
        // flags=03 | 名字 04+32 字节+序号 01 | seq 4821 = aa4b | 1 项: 同写入者 0f, vv 4820 = d425
        // | physical 1792055806043 = b6a1cceda768 | counter 0 | server_time − physical = 3469 = 9a36
        assert_eq!(
            hex(&b),
            "0304000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01\
             aa4b010fd425b6a1cceda768009a36"
                .replace(' ', "")
        );
        assert_eq!(b.len(), 50);
    }

    #[test]
    fn golden_other_shapes() {
        // 副本改名的写入者，HLC 的写入者是另一个名字，没有服务器时刻，上下文两项、其中一项带零散 dot。
        let s = HeritageStamp {
            writer: M1.into(),
            seq: 7,
            ctx: ctx_of(&format!(
                r#"{{"vv":{{"{M1}":6,"{K1}":3}},"cloud":{{"{K1}":[5,9]}}}}"#
            )),
            hlc: StampHlc::of(&format!("1700000000000:12:{K1}")),
            server_time: None,
        };
        assert_eq!(
            hex(&round_trip(&s)),
            "0802862ab6799805548b9454d3ec51c44e9c0e02\
             04000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01030202040f0600\
             80a0abfef9621804000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f01"
                .replace(' ', "")
        );
        // HLC 解析不了：原文照存，服务器时刻按绝对值存。
        let s = HeritageStamp {
            writer: "w".into(),
            seq: -1,
            ctx: StampCtx::default(),
            hlc: StampHlc::of("not-an-hlc"),
            server_time: Some(5),
        };
        assert_eq!(hex(&round_trip(&s)), "0501017701000a6e6f742d616e2d686c630a");
    }

    #[test]
    fn hlc_text_is_never_reshaped() {
        for (text, parsed) in [
            ("1792055806043:0:w", true),
            ("-5:3:w", true),
            ("1:2:a:b:c", true),
            ("1:2:", true),
            ("+5:0:w", false),
            ("05:0:w", false),
            ("5:00:w", false),
            ("5:0", false),
            ("x:0:w", false),
            ("", false),
            ("9223372036854775808:0:w", false),
        ] {
            let h = StampHlc::of(text);
            assert_eq!(matches!(h, StampHlc::Parsed { .. }), parsed, "{text}");
            assert_eq!(h.text(), text);
        }
    }

    #[test]
    fn ctx_normal_form_matches_the_dotted_version_vector() {
        // 能并进前缀的 cloud 并进去、被前缀盖住的丢掉、≤ 0 的不算、合成写入者去掉。
        let json = r#"{"vv":{"b":2,"a":1,"z":0,"sync2:tags:x":9},"cloud":{"a":[2,3,5],"b":[1,9],"c":[0,-4],"d":[2],"sync2:tags:y":[3]}}"#;
        let c = ctx_of(json);
        assert_eq!(
            c.entries(),
            &[
                CtxEntry {
                    writer: "a".into(),
                    vv: 3,
                    cloud: vec![5]
                },
                CtxEntry {
                    writer: "b".into(),
                    vv: 2,
                    cloud: vec![9]
                },
                CtxEntry {
                    writer: "d".into(),
                    vv: 0,
                    cloud: vec![2]
                },
            ]
        );
        let mut d = Dvv::parse(json);
        d.drop_writers(SYNTHETIC_PREFIX);
        assert_eq!(c.to_dvv(), d);
        assert_eq!(StampCtx::from_dvv(&c.to_dvv()), c);
        // 直接从 JSON 原文读是同一个结果。
        assert_eq!(StampCtx::parse(json), c);
    }

    #[test]
    fn ctx_parse_takes_any_text() {
        // 不是 JSON、不是对象、键的类型不对：都当空（读侧 `Ctx::parse` 同样当空）。
        for text in [
            "",
            "nope",
            "[]",
            "3",
            "null",
            r#"{"vv":[1],"cloud":3}"#,
            r#"{"vv":{"a":"1","b":1.5,"c":-2},"cloud":{"a":3,"b":["x",null]}}"#,
        ] {
            assert_eq!(StampCtx::parse(text), StampCtx::default(), "{text}");
        }
        // 多余的键不看。
        assert_eq!(
            StampCtx::parse(r#"{"vv":{"a":2},"x":1}"#).entries(),
            &[CtxEntry {
                writer: "a".into(),
                vv: 2,
                cloud: vec![]
            }]
        );
        // 值域边上不溢出：前缀已经是最大值时，后面没有能接上的 dot。
        let max = i64::MAX;
        let c = StampCtx::parse(&format!(
            r#"{{"vv":{{"a":{max}}},"cloud":{{"a":[{max}],"b":[{max}]}}}}"#
        ));
        assert_eq!(
            c.entries(),
            &[
                CtxEntry {
                    writer: "a".into(),
                    vv: max as u64,
                    cloud: vec![]
                },
                CtxEntry {
                    writer: "b".into(),
                    vv: 0,
                    cloud: vec![max as u64]
                },
            ]
        );
        assert!(c.contains("a", max) && c.contains("b", max) && !c.contains("b", max - 1));
        let s = HeritageStamp {
            ctx: c,
            ..typical()
        };
        round_trip(&s);
    }

    #[test]
    fn non_canonical_bytes_are_rejected() {
        let good = typical().encode();
        assert!(HeritageStamp::read(&mut Reader::new(&good)).is_ok());
        // 保留位。
        let mut b = good.clone();
        b[0] |= 0x10;
        assert!(HeritageStamp::read(&mut Reader::new(&b)).is_err());
        // cloud 标志置位但没有任何 cloud。
        let s = HeritageStamp {
            ctx: StampCtx::default(),
            ..typical()
        };
        let mut b = s.encode();
        b[0] |= F_CLOUD;
        assert!(HeritageStamp::read(&mut Reader::new(&b)).is_err());
        // HLC 写入者等于写入者却没用标志。
        let mut w = Writer::new();
        w.u8(0);
        write_name(&mut w, "w");
        w.iv(1);
        w.uv(0);
        w.iv(10);
        w.iv(0);
        write_name(&mut w, "w");
        assert!(HeritageStamp::read(&mut Reader::new(&w.into_vec())).is_err());
        // 上下文没排序 / 带合成写入者 / 空项 / 能并进前缀的 cloud。
        let entry = |names: &[(&str, u64)]| {
            let mut w = Writer::new();
            w.u8(F_HLC_SAME_WRITER);
            write_name(&mut w, "w");
            w.iv(1);
            w.uv(names.len() as u64);
            for (n, vv) in names {
                write_name_ref(&mut w, n, "w");
                w.uv(*vv);
            }
            w.iv(10);
            w.iv(0);
            w.into_vec()
        };
        assert!(HeritageStamp::read(&mut Reader::new(&entry(&[("a", 1), ("b", 1)]))).is_ok());
        assert!(HeritageStamp::read(&mut Reader::new(&entry(&[("b", 1), ("a", 1)]))).is_err());
        assert!(HeritageStamp::read(&mut Reader::new(&entry(&[("a", 1), ("a", 2)]))).is_err());
        assert!(HeritageStamp::read(&mut Reader::new(&entry(&[("sync2:tags:n", 1)]))).is_err());
        assert!(HeritageStamp::read(&mut Reader::new(&entry(&[("a", 0)]))).is_err());
        let mut w = Writer::new();
        w.u8(F_HLC_SAME_WRITER | F_CLOUD);
        write_name(&mut w, "w");
        w.iv(1);
        w.uv(1);
        write_name_ref(&mut w, "a", "w");
        w.uv(3);
        w.uv(1);
        w.uv(1); // 4 = vv + 1：本该并进前缀
        w.iv(10);
        w.iv(0);
        assert!(HeritageStamp::read(&mut Reader::new(&w.into_vec())).is_err());
        // 截断在任何位置都是错误、不是 panic。
        for n in 0..good.len() {
            assert!(HeritageStamp::read(&mut Reader::new(&good[..n])).is_err());
        }
    }

    pub fn arb_name() -> impl Strategy<Value = String> {
        prop_oneof![
            Just(K1.to_owned()),
            Just(M1.to_owned()),
            Just("anki".to_owned()),
            Just("sync2:tags:8f28cfa8-6dd3-592d-8e4a-2bf5aec4060d".to_owned()),
            "[a-c:#~-]{0,6}",
            proptest::array::uniform16(any::<u8>()).prop_map(|b| crate::sync2::id::Id(b).text()),
        ]
    }

    pub fn arb_ctx() -> impl Strategy<Value = StampCtx> {
        proptest::collection::vec(
            (
                arb_name(),
                -2i64..40,
                proptest::collection::vec(-3i64..60, 0..4),
            ),
            0..4,
        )
        .prop_map(|items| {
            let mut d = Dvv::default();
            for (w, vv, cloud) in items {
                d.vv.insert(w.clone(), vv);
                d.cloud.insert(w, cloud.into_iter().collect());
            }
            StampCtx::from_dvv(&d)
        })
    }

    pub fn arb_hlc() -> impl Strategy<Value = StampHlc> {
        prop_oneof![
            (any::<i64>(), any::<i64>(), arb_name())
                .prop_map(|(p, c, w)| StampHlc::of(&format!("{p}:{c}:{w}"))),
            "[0-9+:a-z]{0,12}".prop_map(|t| StampHlc::of(&t)),
        ]
    }

    pub fn arb_stamp() -> impl Strategy<Value = HeritageStamp> {
        (
            arb_name(),
            any::<i64>(),
            arb_ctx(),
            arb_hlc(),
            proptest::option::of(any::<i64>()),
        )
            .prop_map(|(writer, seq, ctx, hlc, server_time)| HeritageStamp {
                writer,
                seq,
                ctx,
                hlc,
                server_time,
            })
    }

    proptest! {
        #[test]
        fn any_stamp_round_trips(s in arb_stamp()) {
            let b = s.encode();
            let mut r = Reader::new(&b);
            prop_assert_eq!(HeritageStamp::read(&mut r).unwrap(), s);
            prop_assert!(r.is_empty());
        }

        /// 任意字节：要么拒绝，要么重新编码与读掉的字节逐字节相同（一个旧戳只有一种字节形）。
        #[test]
        fn decoding_is_canonical(bytes in proptest::collection::vec(any::<u8>(), 0..80)) {
            let mut r = Reader::new(&bytes);
            if let Ok(s) = HeritageStamp::read(&mut r) {
                prop_assert_eq!(s.encode(), bytes[..r.pos].to_vec());
            }
        }

        /// 改一个比特：要么拒绝，要么解出不同的值（没有两个字节串解出同一个旧戳）。
        #[test]
        fn a_flipped_bit_never_decodes_to_the_same_stamp(s in arb_stamp(), at in any::<prop::sample::Index>(), bit in 0u8..8) {
            let good = s.encode();
            let mut bad = good.clone();
            let i = at.index(bad.len());
            bad[i] ^= 1 << bit;
            let mut r = Reader::new(&bad);
            if let Ok(t) = HeritageStamp::read(&mut r) {
                prop_assert!(t != s || r.pos != good.len());
            }
        }

        /// 上下文归一不改变「含不含某个 dot」（判定只用这个关系）。
        #[test]
        fn ctx_contains_matches_dvv(items in proptest::collection::vec((arb_name(), -2i64..40, proptest::collection::vec(-3i64..60, 0..4)), 0..4), w in arb_name(), seq in -3i64..70) {
            let mut d = Dvv::default();
            for (name, vv, cloud) in items {
                if vv > 0 { d.vv.insert(name.clone(), vv); }
                let set: BTreeSet<i64> = cloud.into_iter().collect();
                if !set.is_empty() { d.cloud.insert(name, set); }
            }
            let c = StampCtx::from_dvv(&d);
            if !w.starts_with(SYNTHETIC_PREFIX) {
                prop_assert_eq!(c.contains(&w, seq), d.contains(&w, seq));
            }
            prop_assert_eq!(c.to_dvv().contains(&w, seq), c.contains(&w, seq));
        }
    }
}
