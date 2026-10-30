//! 2026-10-30 格式断代（协议 2）：读 head 时校验 `minReader`；v1 位置迁移给按名字存的旧媒体补绑定。

use serde_json::json;

use super::tests::{Bucket, Device, P};
use crate::sync2::id::Id;
use crate::sync2::keys::DeviceKey;
use crate::sync2::segment::{Head, CHAIN_ZERO, MIN_READER, PROTOCOL};
use crate::sync2::vv::Vv;

const T0: i64 = 1_700_000_000_000;

/// 同一集合里一台新设备的空 head（只发布了身份），协议 / 最低读者版本由调用方给。
fn forged_head(collection: Id, protocol: u32, min_reader: u32) -> Vec<u8> {
    let key = DeviceKey::generate();
    Head {
        gen: 1,
        protocol,
        min_reader,
        collection,
        device: Id::random(),
        public: key.public(),
        seq: 0,
        chain: CHAIN_ZERO,
        segments: Vec::new(),
        ack: Vv::new(),
        digest: String::new(),
        at_ms: T0,
        name: "future".into(),
    }
    .encode(&key)
}

#[test]
fn this_version_writes_protocol_two_heads() {
    assert_eq!((PROTOCOL, MIN_READER), (2, 2));
    let a = Device::new("br-w");
    let mut bucket = Bucket::default();
    a.sync(&mut bucket, "loc", T0);
    let head = bucket.0.iter().find(|(k, _)| k.contains("/head-")).map(|(_, v)| v.clone()).unwrap();
    let h = Head::decode(&head).unwrap();
    assert_eq!((h.protocol, h.min_reader), (2, 2));
}

/// head 的 `minReader` 比本机协议新：不收这台设备（不拉它的段、不记它），整轮报需要升级；本机读得了的照收。
#[test]
fn plan_refuses_heads_that_need_a_newer_reader() {
    let a = Device::new("br-a");
    let collection = Id::parse(a.core.sync2_identity(P, T0).unwrap()["collection"].as_str().unwrap()).unwrap();
    let newer = forged_head(collection, PROTOCOL + 1, PROTOCOL + 1);
    let plan = a.core.sync2_plan_at(P, &[newer], Some("loc")).unwrap();
    assert_eq!(plan["needsUpgrade"], json!(true), "{plan}");
    assert_eq!(plan["fetch"], json!([]));
    let known = a.rows("SELECT count(*) FROM sync2_devices");
    // 新版本写、但声明本机读得了的（minReader 不超过本机协议）照常收、照常记下这台设备。
    let readable = forged_head(collection, PROTOCOL + 1, PROTOCOL);
    let plan = a.core.sync2_plan_at(P, &[readable], Some("loc")).unwrap();
    assert_eq!(plan["needsUpgrade"], json!(false), "{plan}");
    let after = a.rows("SELECT count(*) FROM sync2_devices");
    assert_ne!(known, after, "the readable head's device is recorded, the newer one was not");
}

/// v1 位置迁移补绑定：只补没人绑过的名字，已有绑定（不管指向什么）一概不动；同一批里重名只绑第一次。
#[test]
fn migration_binds_only_names_nobody_bound() {
    let a = Device::new("br-m");
    a.core.sync2_identity(P, T0).unwrap();
    let sha = |b: u8| [b; 32];
    let first = a.core.sync2_media_bind_unbound(P, &[("a.png".into(), sha(1), 10)], T0).unwrap();
    assert_eq!(first["appended"], json!(1));
    let again = a
        .core
        .sync2_media_bind_unbound(
            P,
            &[("a.png".into(), sha(2), 20), ("b.png".into(), sha(3), 30), ("b.png".into(), sha(4), 40)],
            T0 + 1,
        )
        .unwrap();
    assert_eq!(again["bound"], json!(["b.png"]), "{again}");
    let scan = a
        .core
        .sync2_media_scan(P, &["a.png".into(), "b.png".into()], &std::collections::HashMap::new(), T0 + 2)
        .unwrap();
    let hex = |b: u8| format!("{b:02x}").repeat(32);
    assert_eq!(scan["items"][0]["sha"], json!(hex(1)), "{scan}");
    assert_eq!(scan["items"][1]["sha"], json!(hex(3)), "{scan}");
}
