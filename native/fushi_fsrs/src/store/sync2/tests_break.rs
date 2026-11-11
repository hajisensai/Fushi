//! 2026-10-30 格式断代（协议 2）：读 head 时校验 `minReader`；v1 位置迁移给按名字存的旧媒体补绑定。

use serde_json::json;

use super::tests::{Bucket, Device, P};
use crate::sync2::id::Id;
use crate::sync2::keys::DeviceKey;
use crate::sync2::segment::{CHAIN_ZERO, CONTENT_FLOOR, Head, PROTOCOL};
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
        ext: None,
    }
    .encode(&key)
}

#[test]
fn this_version_writes_protocol_three_heads() {
    // 3：副本骨架与 `Dedup`（BUG-4005，dedup.rs）——协议 2 的读者解不开，必须停下要求升级。head 的 `minReader` 按内容
    // 声明（min_reader.rs），本版本写得出的内容都是 3：v3.3.0 读者照收。
    assert_eq!((PROTOCOL, CONTENT_FLOOR), (3, 3));
    let a = Device::new("br-w");
    let mut bucket = Bucket::default();
    a.sync(&mut bucket, "loc", T0);
    let head = bucket
        .0
        .iter()
        .find(|(k, _)| k.contains("/head-"))
        .map(|(_, v)| v.clone())
        .unwrap();
    let h = Head::decode(&head).unwrap();
    assert_eq!((h.protocol, h.min_reader), (3, 3));
}

/// head 的 `minReader` 比本机协议新：不收这台设备（不拉它的段、不记它），整轮报需要升级；本机读得了的照收。
#[test]
fn plan_refuses_heads_that_need_a_newer_reader() {
    let a = Device::new("br-a");
    let collection = Id::parse(
        a.core.sync2_identity(P, T0).unwrap()["collection"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
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
    assert_ne!(
        known, after,
        "the readable head's device is recorded, the newer one was not"
    );
}

/// v1 位置迁移补绑定：只补没人绑过的名字，已有绑定（不管指向什么）一概不动；同一批里重名只绑第一次。
#[test]
fn migration_binds_only_names_nobody_bound() {
    let a = Device::new("br-m");
    a.core.sync2_identity(P, T0).unwrap();
    let sha = |b: u8| [b; 32];
    let first = a
        .core
        .sync2_media_bind_unbound(P, &[("a.png".into(), sha(1), 10)], T0)
        .unwrap();
    assert_eq!(first["appended"], json!(1));
    let again = a
        .core
        .sync2_media_bind_unbound(
            P,
            &[
                ("a.png".into(), sha(2), 20),
                ("b.png".into(), sha(3), 30),
                ("b.png".into(), sha(4), 40),
            ],
            T0 + 1,
        )
        .unwrap();
    assert_eq!(again["bound"], json!(["b.png"]), "{again}");
    let scan = a
        .core
        .sync2_media_scan(
            P,
            &["a.png".into(), "b.png".into()],
            &std::collections::HashMap::new(),
            T0 + 2,
        )
        .unwrap();
    let hex = |b: u8| format!("{b:02x}").repeat(32);
    assert_eq!(scan["items"][0]["sha"], json!(hex(1)), "{scan}");
    assert_eq!(scan["items"][1]["sha"], json!(hex(3)), "{scan}");
}

fn latest_head(bucket: &Bucket, device: &str) -> Head {
    let (_, bytes) = bucket
        .0
        .iter()
        .filter(|(k, _)| k.starts_with(&format!("devices/{device}/head-")))
        .max_by_key(|(k, _)| {
            crate::sync2::segment::parse_head_file_name(k.rsplit('/').next().unwrap()).unwrap()
        })
        .unwrap();
    Head::decode(bytes).unwrap()
}

fn device_of(d: &Device) -> String {
    d.core.sync2_identity(P, T0).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn declared_keys(d: &Device) -> String {
    d.rows("SELECT COUNT(*) FROM srs_meta WHERE key LIKE 'sync2_min_reader/%'")[1][0].clone()
}

/// head 的 `minReader` 按内容声明（min_reader.rs）：本版本写得出的内容（实体、修改、复习、彻底清除、收下别人的 head）
/// 都是 3、不落键，v3.3.0 读者照收；声明被抬高（模拟将来写了新内容）后，head 带上新值、协议 3 的读者整轮停下，
/// 状态页按本机声明判别的设备「要升级」。
#[test]
fn head_min_reader_is_declared_from_content() {
    use super::tests::{deck_entity, edit, review};
    let a = Device::new("br-c-a");
    let b = Device::new("br-c-b");
    let mut bucket = Bucket::default();
    a.apply(
        T0,
        vec![
            deck_entity("D1"),
            edit("deck", "D1", "name", json!("x")),
            review("L1", "C1", T0, 3, "learn"),
        ],
    );
    a.sync(&mut bucket, "loc", T0);
    b.apply(T0 + 1, vec![review("L2", "C1", T0 + 1, 4, "review")]);
    b.sync(&mut bucket, "loc", T0 + 1);
    a.sync(&mut bucket, "loc", T0 + 2);
    let (da, db) = (device_of(&a), device_of(&b));
    assert_eq!(latest_head(&bucket, &da).min_reader, 3);
    assert_eq!(latest_head(&bucket, &db).min_reader, 3);
    assert_eq!(declared_keys(&a), "0");
    assert_eq!(declared_keys(&b), "0");
    let st = b.core.sync2_status(P).unwrap();
    let row = st["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["device"] == json!(da))
        .cloned()
        .unwrap();
    assert_eq!(row["state"], "ok", "{st}");

    // 将来的版本写了要求读者 4 的内容（本版本写不出，直接改声明）。
    a.core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO srs_meta (key, value) VALUES ('sync2_min_reader/' || ?1, '4')",
            [P],
        )
        .unwrap();
    // 本机状态页：协议 3 的 b 读不了本机的数据了。
    let st = a.core.sync2_status(P).unwrap();
    let row = st["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["device"] == json!(db))
        .cloned()
        .unwrap();
    assert_eq!(row["state"], "upgrade", "{st}");
    let upto = a.upload_all(&mut bucket, "loc");
    let (path, bytes, _) = a.core.sync2_head(P, "loc", upto, T0 + 3).unwrap();
    bucket.0.insert(path, bytes);
    assert_eq!(latest_head(&bucket, &da).min_reader, 4);
    let out = b.core.sync2_plan_at(
        P,
        &bucket
            .0
            .iter()
            .filter(|(k, _)| k.contains("/head-"))
            .map(|(_, v)| v.clone())
            .collect::<Vec<_>>(),
        Some("loc"),
    );
    assert_eq!(out.unwrap()["needsUpgrade"], json!(true));
}
