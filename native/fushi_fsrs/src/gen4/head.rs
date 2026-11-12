//! 协议 4 的 head（设计 §3.3、§4.1、§4.4）：一台设备对「我发布到哪了」的签名陈述。
//!
//! ```text
//! {"ack":{"<设备 uuid>":N,…},"at":N,"chain":"<hex32>","collection":"<uuid>","derive":N,"device":"<uuid>",
//!  "digest":"…","ext":{…}?,"fmt":"fushi-srs-head/4","gen":N,"loc":"…","minReader":N,"name":"…",
//!  "prev":{"chain":"<hex32>","device":"<uuid>","seq":N}?,"pub":"<hex32>","seal":"…","segs":[[first,last,"<tag8>"],…],
//!  "seq":N,"sig":"<hex64>","v":N}
//! sig = Ed25519( "fushi-srs-head/4\n" || 去掉 "sig" 的整个对象的规范 JSON )
//! ```
//!
//! **文件字节必须就是规范 JSON**（[canonical]）：键按 UTF-8 字节序、没有空白、数值只许整数、没有重复键；十六进制小写、UUID 取规范文本。
//! 解码时「解析后重新规范化」与原字节不同就拒收——签名签的是规范字节，文件只有一种写法，被签的内容与文件字节一一对应
//! （重复键、`1e3` 这类「解析器各读各的」的写法进不来）。
//!
//! 与协议 3 的 head（`crate::sync2::segment::Head`）的差别：
//!
//! - **签名覆盖对象里除 `sig` 外的全部键**，包括本版本不认识的（解码后原样留在 [Head4::extra]）。以后加字段不必再发明第二个签名，
//!   旧的协议 4 读者照样验得过。签名原文带域前缀，与协议 3 的 head 签名、段签名都不会互相冒充。
//! - `fmt`：head 外形的标记，不随协议号变。缺它或不等于 `fushi-srs-head/4` = 不是本外形的 head（[HeadError::NotProtocol4]）。
//! - `segs`：段清单（协议 3 叫 `segments`）。协议 3 的解码器因此在结构上就读不了本文件（`head: missing segments`），不靠签名碰巧对不上。
//! - `minReader > 本版本` 时解码给 [HeadError::NeedsUpgrade]，在验签之后、读其余字段之前——以后的协议只要保留 `fmt` 与签名规则、
//!   抬高 `minReader`，协议 4 的读者就会明确报「需要升级」，而不是当成坏文件跳过。
//! - `seal`：这个位置的加密标记（密钥指纹；明文位置为空串）。`loc`：位置标识。两者进签名，读者只把 `loc` 与本位置相符的 head
//!   当作「本位置是否加密」的证据（设计 §4.4）。`loc` 取什么值由接线的一步（G8）定，这里只负责带着它、签住它。
//! - `prev`：这台设备的前一个身份（协议 3 时代的设备 ID、它的日志末尾 seq 与完整链值；设计 §3.3）。带链值是为了在旧身份
//!   分叉过时分清新身份接的是哪一支。
//! - `derive`：派生口径版本（设计 §4.1）。

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use super::PROTOCOL;
use crate::sync2::id::Id;
use crate::sync2::keys::{DeviceKey, verify};
use crate::sync2::segment::{Chain, chain_tag, head_file_name, segment_file_name};
use crate::sync2::vv::Vv;

/// head 外形的标记。
pub const HEAD_FMT: &str = "fushi-srs-head/4";
/// 签名原文的域前缀。
pub const SIGN_DOMAIN: &[u8] = b"fushi-srs-head/4\n";

/// 本版本认识的键。
const KNOWN: [&str; 20] = [
    "ack",
    "at",
    "chain",
    "collection",
    "derive",
    "device",
    "digest",
    "ext",
    "fmt",
    "gen",
    "loc",
    "minReader",
    "name",
    "prev",
    "pub",
    "seal",
    "segs",
    "seq",
    "sig",
    "v",
];

/// 这台设备的前一个身份。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrevIdentity {
    pub device: Id,
    /// 旧日志的末尾 seq。
    pub seq: u64,
    /// 旧日志在末尾处的完整链值。
    pub chain: Chain,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Head4 {
    /// head 代号，每写一次 +1。
    pub gen: u64,
    pub protocol: u32,
    pub min_reader: u32,
    pub collection: Id,
    pub device: Id,
    pub public: [u8; 32],
    /// 已发布的最大 seq（0 = 只发布了身份）。
    pub seq: u64,
    pub chain: Chain,
    /// 已发布的原生段（升序、首尾相接、覆盖 `1..=seq`）：(first, last, 链尾标签)。清除掉的区间是段里的空洞，不是清单里的缺口。
    pub segs: Vec<(u64, u64, String)>,
    /// 已应用的版本向量。
    pub ack: Vv,
    /// 在 [Head4::ack] 下的派生状态摘要。
    pub digest: String,
    pub at_ms: i64,
    /// 设备的人读名。
    pub name: String,
    /// 位置标识。
    pub loc: String,
    /// 这个位置的加密标记（密钥指纹；明文位置为空串）。
    pub seal: String,
    /// 派生口径版本。
    pub derive: u32,
    pub prev: Option<PrevIdentity>,
    /// 扩展信息（设备型号 / App 版本 / 平台等；JSON 对象）。
    pub ext: Option<Map<String, Value>>,
    /// 本版本不认识的键（签名覆盖它们；重新编码时原样带上）。
    pub extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeadError {
    /// 不是本外形的 head（协议 3 的 head、别的 JSON）。
    NotProtocol4,
    /// 外形对、内容不合规（不是规范 JSON、缺字段、段清单不连续……）。
    Malformed(String),
    BadSignature,
    /// 签名有效，但写它的版本要求更高的读者。
    NeedsUpgrade {
        min_reader: u32,
    },
}

impl std::fmt::Display for HeadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HeadError::NotProtocol4 => f.write_str("not a protocol 4 head"),
            HeadError::Malformed(m) => write!(f, "bad head: {m}"),
            HeadError::BadSignature => f.write_str("head signature mismatch"),
            HeadError::NeedsUpgrade { min_reader } => {
                write!(f, "head needs reader version {min_reader}")
            }
        }
    }
}

fn bad(m: impl Into<String>) -> HeadError {
    HeadError::Malformed(m.into())
}

/// 规范 JSON：对象的键按 UTF-8 字节序、没有空白、数值只许整数（i64 / u64 范围）。字符串的转义取 serde_json 的写法
/// （`"`、`\`、控制字符转义，其余原样）。
pub fn canonical(v: &Value) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    write_canonical(v, &mut out)?;
    Ok(out)
}

fn write_canonical(v: &Value, out: &mut Vec<u8>) -> Result<(), String> {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            out.push(b'{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                serde_json::to_writer(&mut *out, k).map_err(|e| e.to_string())?;
                out.push(b':');
                write_canonical(&m[k], out)?;
            }
            out.push(b'}');
        }
        Value::Array(a) => {
            out.push(b'[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                write_canonical(x, out)?;
            }
            out.push(b']');
        }
        Value::Number(n) => {
            if let Some(u) = n.as_u64() {
                out.extend_from_slice(u.to_string().as_bytes());
            } else if let Some(i) = n.as_i64() {
                out.extend_from_slice(i.to_string().as_bytes());
            } else {
                return Err("non-integer number".into());
            }
        }
        other => serde_json::to_writer(&mut *out, other).map_err(|e| e.to_string())?,
    }
    Ok(())
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// 小写十六进制 → 定长字节。
fn unhex<const N: usize>(s: &str) -> Option<[u8; N]> {
    let b = s.as_bytes();
    if b.len() != 2 * N {
        return None;
    }
    let digit = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    };
    let mut out = [0u8; N];
    for i in 0..N {
        out[i] = (digit(b[2 * i])? << 4) | digit(b[2 * i + 1])?;
    }
    Some(out)
}

/// 规范 UUID 文本 → Id。
fn uuid(s: &str) -> Option<Id> {
    Id::parse(s).filter(|id| id.text() == s)
}

/// 签名原文：域前缀 + 去掉 `sig` 的对象的规范 JSON。
fn signed_bytes(obj: &Map<String, Value>) -> Result<Vec<u8>, String> {
    let mut unsigned = obj.clone();
    unsigned.remove("sig");
    let mut out = SIGN_DOMAIN.to_vec();
    write_canonical(&Value::Object(unsigned), &mut out)?;
    Ok(out)
}

impl Head4 {
    /// 文件名：`head-<代号>-<链尾标签>.json`（与协议 3 同形；放哪个目录由接线的一步定）。
    pub fn file_name(&self) -> String {
        head_file_name(self.gen, &chain_tag(&self.chain))
    }

    /// head 引用的段文件名。
    pub fn segment_files(&self) -> Vec<String> {
        self.segs
            .iter()
            .map(|(a, b, t)| segment_file_name(*a, *b, t))
            .collect()
    }

    fn object(&self) -> Map<String, Value> {
        let mut m = Map::new();
        // 不认识的键先放；与认识的键同名的不带（认识的键以字段为准）。
        for (k, v) in &self.extra {
            if !KNOWN.contains(&k.as_str()) {
                m.insert(k.clone(), v.clone());
            }
        }
        let mut ack = Map::new();
        for (d, s) in &self.ack.0 {
            ack.insert(d.text(), Value::from(*s));
        }
        m.insert("ack".into(), Value::Object(ack));
        m.insert("at".into(), Value::from(self.at_ms));
        m.insert("chain".into(), Value::from(hex(&self.chain)));
        m.insert("collection".into(), Value::from(self.collection.text()));
        m.insert("derive".into(), Value::from(self.derive));
        m.insert("device".into(), Value::from(self.device.text()));
        m.insert("digest".into(), Value::from(self.digest.clone()));
        if let Some(ext) = &self.ext {
            m.insert("ext".into(), Value::Object(ext.clone()));
        }
        m.insert("fmt".into(), Value::from(HEAD_FMT));
        m.insert("gen".into(), Value::from(self.gen));
        m.insert("loc".into(), Value::from(self.loc.clone()));
        m.insert("minReader".into(), Value::from(self.min_reader));
        m.insert("name".into(), Value::from(self.name.clone()));
        if let Some(p) = &self.prev {
            let mut o = Map::new();
            o.insert("chain".into(), Value::from(hex(&p.chain)));
            o.insert("device".into(), Value::from(p.device.text()));
            o.insert("seq".into(), Value::from(p.seq));
            m.insert("prev".into(), Value::Object(o));
        }
        m.insert("pub".into(), Value::from(hex(&self.public)));
        m.insert("seal".into(), Value::from(self.seal.clone()));
        m.insert(
            "segs".into(),
            Value::Array(
                self.segs
                    .iter()
                    .map(|(a, b, t)| {
                        Value::Array(vec![
                            Value::from(*a),
                            Value::from(*b),
                            Value::from(t.clone()),
                        ])
                    })
                    .collect(),
            ),
        );
        m.insert("seq".into(), Value::from(self.seq));
        m.insert("v".into(), Value::from(self.protocol));
        m
    }

    /// 签名并编码成规范 JSON。[signer] 必须是 [Head4::public] 的私钥（否则写出来的文件验不过）。
    /// `ext` / `extra` 里有非整数的数值时出错。
    pub fn encode(&self, signer: &DeviceKey) -> Result<Vec<u8>, String> {
        let mut obj = self.object();
        let sig = signer.sign(&signed_bytes(&obj)?);
        obj.insert("sig".into(), Value::from(hex(&sig)));
        canonical(&Value::Object(obj))
    }

    /// 解析并验签（用 head 自带的公钥；公钥是否可信由调用方对照设备表判定）。
    pub fn decode(bytes: &[u8]) -> Result<Head4, HeadError> {
        let v: Value = serde_json::from_slice(bytes).map_err(|_| HeadError::NotProtocol4)?;
        let Value::Object(obj) = &v else {
            return Err(HeadError::NotProtocol4);
        };
        if obj.get("fmt").and_then(Value::as_str) != Some(HEAD_FMT) {
            return Err(HeadError::NotProtocol4);
        }
        if canonical(&v).map_err(bad)? != bytes {
            return Err(bad("not canonical json"));
        }
        let s = |k: &str| {
            obj.get(k)
                .and_then(Value::as_str)
                .ok_or_else(|| bad(format!("missing {k}")))
        };
        let u = |k: &str| {
            obj.get(k)
                .and_then(Value::as_u64)
                .ok_or_else(|| bad(format!("missing {k}")))
        };
        let u32_of = |k: &str| u32::try_from(u(k)?).map_err(|_| bad(format!("bad {k}")));
        let id = |k: &str| uuid(s(k)?).ok_or_else(|| bad(format!("bad {k}")));
        let public = unhex::<32>(s("pub")?).ok_or_else(|| bad("bad pub"))?;
        let sig = unhex::<64>(s("sig")?).ok_or_else(|| bad("bad sig"))?;
        if !verify(&public, &signed_bytes(obj).map_err(bad)?, &sig) {
            return Err(HeadError::BadSignature);
        }
        // 签名有效之后、读其余字段之前：更高版本写的 head 外形可能已经变了，先报「需要升级」。
        let min_reader = u32_of("minReader")?;
        if min_reader > PROTOCOL {
            return Err(HeadError::NeedsUpgrade { min_reader });
        }
        let protocol = u32_of("v")?;
        if protocol < PROTOCOL || min_reader < PROTOCOL {
            return Err(bad("protocol below 4"));
        }
        let mut segs = Vec::new();
        for x in obj
            .get("segs")
            .and_then(Value::as_array)
            .ok_or_else(|| bad("missing segs"))?
        {
            let item = x.as_array().filter(|a| a.len() == 3);
            let parts = item.and_then(|a| {
                let t = a[2].as_str().filter(|t| unhex::<4>(t).is_some())?;
                Some((a[0].as_u64()?, a[1].as_u64()?, t.to_owned()))
            });
            segs.push(parts.ok_or_else(|| bad("bad seg"))?);
        }
        let mut ack = Vv::new();
        for (k, x) in obj
            .get("ack")
            .and_then(Value::as_object)
            .ok_or_else(|| bad("missing ack"))?
        {
            let d = uuid(k).ok_or_else(|| bad("bad ack device"))?;
            let n = x
                .as_u64()
                .filter(|n| *n > 0)
                .ok_or_else(|| bad("bad ack seq"))?;
            ack.0.insert(d, n);
        }
        let prev = match obj.get("prev") {
            None => None,
            Some(p) => {
                let o = p.as_object().filter(|o| o.len() == 3);
                let parts = o.and_then(|o| {
                    Some(PrevIdentity {
                        device: uuid(o.get("device")?.as_str()?)?,
                        seq: o.get("seq")?.as_u64()?,
                        chain: unhex::<32>(o.get("chain")?.as_str()?)?,
                    })
                });
                Some(parts.ok_or_else(|| bad("bad prev"))?)
            }
        };
        let ext = match obj.get("ext") {
            None => None,
            Some(Value::Object(m)) => Some(m.clone()),
            Some(_) => return Err(bad("bad ext")),
        };
        let head = Head4 {
            gen: u("gen")?,
            protocol,
            min_reader,
            collection: id("collection")?,
            device: id("device")?,
            public,
            seq: u("seq")?,
            chain: unhex::<32>(s("chain")?).ok_or_else(|| bad("bad chain"))?,
            segs,
            ack,
            digest: s("digest")?.to_owned(),
            at_ms: obj
                .get("at")
                .and_then(Value::as_i64)
                .ok_or_else(|| bad("missing at"))?,
            name: s("name")?.to_owned(),
            loc: s("loc")?.to_owned(),
            seal: s("seal")?.to_owned(),
            derive: u32_of("derive")?,
            prev,
            ext,
            extra: obj
                .iter()
                .filter(|(k, _)| !KNOWN.contains(&k.as_str()))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
        };
        // 段清单必须首尾相接、覆盖 1..=seq。
        let mut next = 1;
        for &(a, b, _) in &head.segs {
            if a != next || b < a {
                return Err(bad("segs not contiguous"));
            }
            next = b + 1;
        }
        if next != head.seq + 1 {
            return Err(bad("segs do not cover seq"));
        }
        Ok(head)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::MIN_READER;
    use crate::gen4::golden;
    use crate::gen4::op::tests::id;
    use crate::gen4::segment::tests::{coll, signer};
    use crate::sync2::segment as v3;
    use serde_json::json;

    fn head() -> Head4 {
        let mut ack = Vv::new();
        ack.set(id(0xa1), 12);
        ack.set(id(0xb2), 7);
        Head4 {
            gen: 3,
            protocol: PROTOCOL,
            min_reader: MIN_READER,
            collection: coll(),
            device: id(0xa1),
            public: signer().public(),
            seq: 12,
            chain: [0x5a; 32],
            segs: vec![(1, 10, "0a0b0c0d".into()), (11, 12, "5a5a5a5a".into())],
            ack,
            digest: "7:abc".into(),
            at_ms: 1_800_000_000_000,
            name: "Pixel 9 \"工作机\"".into(),
            loc: "loc-1".into(),
            seal: "k:1f2e3d4c".into(),
            derive: 1,
            prev: Some(PrevIdentity {
                device: id(0x0d),
                seq: 4321,
                chain: [0x33; 32],
            }),
            ext: json!({"app": "1.9.0", "model": "Pixel 9", "platform": "android"})
                .as_object()
                .cloned(),
            extra: BTreeMap::new(),
        }
    }

    fn minimal() -> Head4 {
        Head4 {
            gen: 1,
            seq: 0,
            chain: [0; 32],
            segs: vec![],
            ack: Vv::new(),
            prev: None,
            ext: None,
            seal: String::new(),
            ..head()
        }
    }

    /// 改掉对象里的一处、按规范形重新写出来（签名不动）。
    fn tweak(bytes: &[u8], f: impl FnOnce(&mut Map<String, Value>)) -> Vec<u8> {
        let mut v: Value = serde_json::from_slice(bytes).unwrap();
        f(v.as_object_mut().unwrap());
        canonical(&v).unwrap()
    }

    /// 同上，再用测试密钥重新签名。
    fn resign(bytes: &[u8], f: impl FnOnce(&mut Map<String, Value>)) -> Vec<u8> {
        tweak(bytes, |m| {
            f(m);
            let sig = signer().sign(&signed_bytes(m).unwrap());
            m.insert("sig".into(), Value::from(hex(&sig)));
        })
    }

    #[test]
    fn round_trip() {
        for h in [head(), minimal()] {
            let bytes = h.encode(&signer()).unwrap();
            let back = Head4::decode(&bytes).unwrap();
            assert_eq!(back, h);
            // 一个 head 只有一种字节形：解出来再编码逐字节相同（Ed25519 是确定性的）。
            assert_eq!(back.encode(&signer()).unwrap(), bytes);
            assert_eq!(
                canonical(&serde_json::from_slice(&bytes).unwrap()).unwrap(),
                bytes
            );
        }
        let h = head();
        assert_eq!(h.file_name(), "head-000000000003-5a5a5a5a.json");
        assert_eq!(
            h.segment_files(),
            vec![
                "seg-000000000001-000000000010-0a0b0c0d.bin",
                "seg-000000000011-000000000012-5a5a5a5a.bin"
            ]
        );
    }

    /// 签名覆盖除 `sig` 外的全部键：改任何一个值、加一个键、去掉一个可选键，都验不过。
    #[test]
    fn the_signature_covers_every_key() {
        let bytes = head().encode(&signer()).unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        for k in v
            .as_object()
            .unwrap()
            .keys()
            .filter(|k| *k != "sig" && *k != "fmt")
        {
            let changed = tweak(&bytes, |m| {
                let x = m.get_mut(k).unwrap();
                *x = match &*x {
                    Value::String(s) if k == "pub" => Value::from(s.replace('e', "f")),
                    Value::String(s) => Value::from(format!("{s}0")),
                    Value::Number(n) => Value::from(n.as_u64().unwrap() + 1),
                    Value::Array(_) => json!([]),
                    Value::Object(_) => json!({}),
                    other => other.clone(),
                };
            });
            assert_ne!(changed, bytes, "{k}");
            let err = Head4::decode(&changed).unwrap_err();
            assert!(
                matches!(err, HeadError::BadSignature | HeadError::Malformed(_)),
                "{k}: {err:?}"
            );
            // 保持字段合法的那些改动（数字 +1、字符串加字符）必须正好是签名不符。
            if matches!(
                k.as_str(),
                "at" | "gen" | "derive" | "digest" | "loc" | "seal" | "name"
            ) {
                assert_eq!(err, HeadError::BadSignature, "{k}");
            }
        }
        let added = tweak(&bytes, |m| {
            m.insert("zzz".into(), json!(1));
        });
        assert_eq!(Head4::decode(&added).unwrap_err(), HeadError::BadSignature);
        for k in ["ext", "prev"] {
            let removed = tweak(&bytes, |m| {
                m.remove(k);
            });
            assert_eq!(
                Head4::decode(&removed).unwrap_err(),
                HeadError::BadSignature
            );
        }
        // 换密钥签：公钥对不上。
        let other = head().encode(&DeviceKey::from_seed(&[8; 32])).unwrap();
        assert_eq!(Head4::decode(&other).unwrap_err(), HeadError::BadSignature);
    }

    /// 不认识的键：签名照样覆盖、解码后保留、重新编码原样带上。
    #[test]
    fn unknown_keys_are_signed_and_kept() {
        let bytes = resign(&head().encode(&signer()).unwrap(), |m| {
            m.insert("future".into(), json!({"b": [1, 2], "a": "x"}));
        });
        let h = Head4::decode(&bytes).unwrap();
        assert_eq!(h.extra.len(), 1);
        assert_eq!(h.extra["future"], json!({"a": "x", "b": [1, 2]}));
        assert_eq!(h.encode(&signer()).unwrap(), bytes);
        // 不认识的键被改：验不过。
        let changed = tweak(&bytes, |m| {
            m.insert("future".into(), json!({"a": "y", "b": [1, 2]}));
        });
        assert_eq!(
            Head4::decode(&changed).unwrap_err(),
            HeadError::BadSignature
        );
        // `extra` 里与认识的键同名的不会盖掉字段。
        let mut h2 = head();
        h2.extra.insert("seq".into(), json!(999));
        assert_eq!(
            Head4::decode(&h2.encode(&signer()).unwrap()).unwrap(),
            head()
        );
    }

    /// 文件字节必须是规范 JSON：同一个对象的别的写法一律拒收，哪怕签名（按规范形算）对得上。
    #[test]
    fn only_canonical_bytes_are_accepted() {
        let bytes = minimal().encode(&signer()).unwrap();
        let text = String::from_utf8(bytes.clone()).unwrap();
        let malformed = |t: &str| {
            assert_eq!(
                Head4::decode(t.as_bytes()).unwrap_err(),
                HeadError::Malformed("not canonical json".into()),
                "{t}"
            );
        };
        // 空白、换键序。
        malformed(&text.replacen(',', ", ", 1));
        malformed(&format!("{text}\n"));
        let reordered =
            text.replacen(r#"{"ack":{},"#, "{", 1)
                .replacen(r#","v":4}"#, r#","v":4,"ack":{}}"#, 1);
        assert_ne!(reordered, text);
        malformed(&reordered);
        // 重复键（解析器最后一个赢，被签的与文件里先出现的不一致）。
        let dup = text.replacen(r#""seal":"""#, r#""seal":"x","seal":"""#, 1);
        assert_ne!(dup, text);
        malformed(&dup);
        // 数值的别的写法；转义的别的写法。
        let float = text.replacen(r#""gen":1"#, r#""gen":1.0"#, 1);
        assert_ne!(float, text);
        assert!(matches!(
            Head4::decode(float.as_bytes()).unwrap_err(),
            HeadError::Malformed(_)
        ));
        let exp = text.replacen(r#""gen":1"#, r#""gen":1e0"#, 1);
        assert!(matches!(
            Head4::decode(exp.as_bytes()).unwrap_err(),
            HeadError::Malformed(_)
        ));
        let escaped = text.replacen("Pixel", "\\u0050ixel", 1);
        assert_ne!(escaped, text);
        malformed(&escaped);
        // 嵌套里的非整数（`ext` 内部）。
        let mut h = minimal();
        h.ext = json!({"ratio": 1.5}).as_object().cloned();
        assert!(h.encode(&signer()).is_err());
        // 大写十六进制、非规范 UUID：重新签过也不收。
        let upper = resign(&bytes, |m| {
            let c = m["chain"].as_str().unwrap().replace('0', "A");
            m.insert("chain".into(), Value::from(c));
        });
        assert_eq!(
            Head4::decode(&upper).unwrap_err(),
            HeadError::Malformed("bad chain".into())
        );
        let upper_id = resign(&bytes, |m| {
            let c = m["device"].as_str().unwrap().to_uppercase();
            m.insert("device".into(), Value::from(c));
        });
        assert_eq!(
            Head4::decode(&upper_id).unwrap_err(),
            HeadError::Malformed("bad device".into())
        );
    }

    #[test]
    fn malformed_heads_are_rejected() {
        let bytes = head().encode(&signer()).unwrap();
        let bad_of = |f: &dyn Fn(&mut Map<String, Value>)| {
            Head4::decode(&resign(&bytes, |m| f(m))).unwrap_err()
        };
        // 段清单有缺口 / 不覆盖 seq / 标签不是 8 位十六进制。
        assert_eq!(
            bad_of(&|m| m["segs"] = json!([[1, 10, "0a0b0c0d"], [12, 12, "5a5a5a5a"]])),
            HeadError::Malformed("segs not contiguous".into())
        );
        assert_eq!(
            bad_of(&|m| m["segs"] = json!([[1, 10, "0a0b0c0d"]])),
            HeadError::Malformed("segs do not cover seq".into())
        );
        assert_eq!(
            bad_of(&|m| m["segs"] = json!([[1, 12, "0A0B0C0D"]])),
            HeadError::Malformed("bad seg".into())
        );
        // 缺必需键。
        for k in [
            "loc", "seal", "derive", "digest", "name", "at", "gen", "seq", "chain", "ack",
        ] {
            let err = bad_of(&|m| {
                m.remove(k);
            });
            assert!(matches!(err, HeadError::Malformed(_)), "{k}: {err:?}");
        }
        // ack 里的 0、prev 多出键、ext 不是对象、协议号低于 4。
        assert_eq!(
            bad_of(&|m| m["ack"] = json!({id(1).text(): 0})),
            HeadError::Malformed("bad ack seq".into())
        );
        assert_eq!(
            bad_of(&|m| m["prev"]["more"] = json!(1)),
            HeadError::Malformed("bad prev".into())
        );
        assert_eq!(
            bad_of(&|m| m["ext"] = json!([])),
            HeadError::Malformed("bad ext".into())
        );
        assert_eq!(
            bad_of(&|m| m["v"] = json!(3)),
            HeadError::Malformed("protocol below 4".into())
        );
        assert_eq!(
            bad_of(&|m| m["minReader"] = json!(3)),
            HeadError::Malformed("protocol below 4".into())
        );
        // 不是 JSON、不是对象、截断。
        assert_eq!(
            Head4::decode(b"\x00\x01").unwrap_err(),
            HeadError::NotProtocol4
        );
        assert_eq!(Head4::decode(b"[]").unwrap_err(), HeadError::NotProtocol4);
        assert_eq!(
            Head4::decode(&bytes[..bytes.len() - 1]).unwrap_err(),
            HeadError::NotProtocol4
        );
    }

    /// 更高版本写的 head：签名有效就明确报「需要升级」，哪怕它的其余外形已经变了；签名无效的不算数。
    #[test]
    fn a_newer_head_asks_for_an_upgrade() {
        let bytes = head().encode(&signer()).unwrap();
        let newer = resign(&bytes, |m| {
            m.insert("minReader".into(), json!(5));
            m.insert("v".into(), json!(5));
            m.remove("segs");
            m.remove("seal");
            m.insert("layout".into(), json!("something else"));
        });
        assert_eq!(
            Head4::decode(&newer).unwrap_err(),
            HeadError::NeedsUpgrade { min_reader: 5 }
        );
        let forged = tweak(&bytes, |m| {
            m.insert("minReader".into(), json!(5));
        });
        assert_eq!(Head4::decode(&forged).unwrap_err(), HeadError::BadSignature);
        // 只抬高 v、不抬高 minReader：照常读（新版本声明旧读者还读得了）。
        let compatible = resign(&bytes, |m| {
            m.insert("v".into(), json!(5));
        });
        assert_eq!(Head4::decode(&compatible).unwrap().protocol, 5);
    }

    // ------------------------------------------------------------ 与协议 3 互不误读

    fn v3_head() -> v3::Head {
        v3::Head {
            gen: 1,
            protocol: v3::PROTOCOL,
            min_reader: v3::MIN_READER,
            collection: coll(),
            device: id(0xa1),
            public: signer().public(),
            seq: 0,
            chain: [0; 32],
            segments: vec![],
            ack: Vv::new(),
            digest: "d".into(),
            at_ms: 1,
            name: "n".into(),
            ext: None,
        }
    }

    /// 所有者的硬要求：旧版本必须被挡住。协议 3 的解码器读不了协议 4 的 head——结构上就缺它的必需键。
    #[test]
    fn a_protocol_3_decoder_rejects_a_protocol_4_head() {
        for h in [head(), minimal()] {
            let bytes = h.encode(&signer()).unwrap();
            assert_eq!(
                v3::Head::decode(&bytes).unwrap_err(),
                "head: missing segments".to_owned()
            );
        }
        // 就算有人往协议 4 的 head 里塞进协议 3 的键（签名照协议 4 的规则重算），协议 3 的验签也过不了：
        // 两代的签名原文不同（域前缀、覆盖范围）。
        let stuffed = resign(&minimal().encode(&signer()).unwrap(), |m| {
            m.insert("segments".into(), json!([]));
        });
        assert!(Head4::decode(&stuffed).is_ok());
        assert_eq!(
            v3::Head::decode(&stuffed).unwrap_err(),
            "head signature mismatch".to_owned()
        );
    }

    #[test]
    fn a_protocol_4_decoder_rejects_a_protocol_3_head() {
        let bytes = v3_head().encode(&signer());
        assert!(v3::Head::decode(&bytes).is_ok());
        assert_eq!(Head4::decode(&bytes).unwrap_err(), HeadError::NotProtocol4);
        // 带扩展的也一样。
        let mut h = v3_head();
        h.ext = Some(json!({"model": "x"}));
        assert_eq!(
            Head4::decode(&h.encode(&signer())).unwrap_err(),
            HeadError::NotProtocol4
        );
        // 协议 3 的 head 被人加上 fmt 标记：签名规则不同，验不过。
        let tagged = tweak(&bytes, |m| {
            m.insert("fmt".into(), json!(HEAD_FMT));
        });
        assert!(matches!(
            Head4::decode(&tagged).unwrap_err(),
            HeadError::BadSignature | HeadError::Malformed(_)
        ));
    }

    // ------------------------------------------------------------ 黄金向量

    /// head 文件的字节冻结（两个方向：编码得出这些字节，这些字节解得出同一个 head）。
    #[test]
    fn golden_heads() {
        for (name, h, want) in [
            ("head", head(), GOLDEN_HEAD),
            ("head_minimal", minimal(), GOLDEN_MINIMAL),
        ] {
            let bytes = h.encode(&signer()).unwrap();
            // 十六进制打出来、按字节比（文件是 UTF-8 的 JSON；终端的编码不该掺进黄金向量）。
            golden(name, &bytes, &crate::gen4::hex(want.as_bytes()));
            if want.is_empty() {
                continue; // 只在打印模式下走得到这里（见 `golden`）
            }
            assert_eq!(Head4::decode(want.as_bytes()).unwrap(), h, "{name}");
        }
        golden(
            "head_sign_domain",
            SIGN_DOMAIN,
            "66757368692d7372732d686561642f340a",
        );
    }

    const GOLDEN_HEAD: &str = r##"{"ack":{"a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1":12,"b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2":7},"at":1800000000000,"chain":"5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a","collection":"c0c0c0c0-c0c0-c0c0-c0c0-c0c0c0c0c0c0","derive":1,"device":"a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1","digest":"7:abc","ext":{"app":"1.9.0","model":"Pixel 9","platform":"android"},"fmt":"fushi-srs-head/4","gen":3,"loc":"loc-1","minReader":4,"name":"Pixel 9 \"工作机\"","prev":{"chain":"3333333333333333333333333333333333333333333333333333333333333333","device":"0d0d0d0d-0d0d-0d0d-0d0d-0d0d0d0d0d0d","seq":4321},"pub":"ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c","seal":"k:1f2e3d4c","segs":[[1,10,"0a0b0c0d"],[11,12,"5a5a5a5a"]],"seq":12,"sig":"77054b3fe6be8ddf1b7e2a9671eee97d8c2b42976edc462e71acd3156250d7fc7a03e6f4098f741ecf67173697192d8a7e4d13f6e639ee0a8d7fa03a0440ef02","v":4}"##;
    const GOLDEN_MINIMAL: &str = r##"{"ack":{},"at":1800000000000,"chain":"0000000000000000000000000000000000000000000000000000000000000000","collection":"c0c0c0c0-c0c0-c0c0-c0c0-c0c0c0c0c0c0","derive":1,"device":"a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1","digest":"7:abc","fmt":"fushi-srs-head/4","gen":1,"loc":"loc-1","minReader":4,"name":"Pixel 9 \"工作机\"","pub":"ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c","seal":"","segs":[],"seq":0,"sig":"367f56d19280f0161512ae4f0ce1b5be56285ff12ca08fa44195e2caa2d13b73d952f112e1468a218c9a52d0e812ffd7cca0a37b7c7ded3f7e08d27b1aaf9201","v":4}"##;
}
