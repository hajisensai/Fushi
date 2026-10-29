//! 同步 v2 正确性回归（2026-10-29 审查 S-1 / S-2 / S-3）：本机 HLC 随远端推进、慢钟设备后写赢、段 / head 转发。

use serde_json::{json, Value};

use super::tests::{edit, Bucket, Device, P};

const T0: i64 = 1_700_000_000_000;
const HOUR: i64 = 60 * 60 * 1000;

fn self_hlc(d: &Device) -> i64 {
    d.rows(&format!("SELECT hlc_wall FROM sync2_self WHERE profile_uid = '{P}'"))[1][0].parse().unwrap()
}

fn tags_of(d: &Device, note: &str) -> String {
    let r = d.rows(&format!("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE entity_id = '{note}' AND field_key = 'tags'"));
    r.get(1).map(|x| x[0].clone()).unwrap_or_default()
}

fn media_state(d: &Device, location: &str, name: &str) -> Option<bool> {
    let k = d.core.sync2_media_known(P, location).unwrap();
    let has = |key: &str| k[key].as_array().unwrap().iter().any(|v| v == &json!(name));
    if has("present") {
        Some(true)
    } else if has("absent") {
        Some(false)
    } else {
        None
    }
}

fn count(d: &Device, sql: &str) -> i64 {
    d.rows(sql)[1][0].parse().unwrap()
}

fn reviews(d: &Device) -> i64 {
    count(d, "SELECT COUNT(*) FROM srs_review_logs")
}

fn pending(d: &Device) -> i64 {
    count(d, "SELECT COUNT(*) FROM sync2_pending")
}

/// 拓扑：A ↔ B 只经互联（ic），B ↔ C 只经网盘（cloud）。[cloud_key] = 网盘开了加密。跑若干圈，每圈 A、B 走 ic，
/// B、C 走 cloud。
fn relay_rounds(a: &Device, b: &Device, c: &Device, ic: &mut Bucket, cloud: &mut Bucket, cloud_key: Option<[u8; 32]>, now: i64, laps: usize) {
    for i in 0..laps {
        let t = now + i as i64 * 10;
        a.sync(ic, "ic", t);
        b.sync(ic, "ic", t + 1);
        b.sync_keyed(cloud, "cloud", t + 2, cloud_key);
        c.sync_keyed(cloud, "cloud", t + 3, cloud_key);
    }
}

fn review_of(id: &str, card: &str, at: i64) -> Value {
    super::tests::review(id, card, at, 3, "review")
}

fn relay_topology(cloud_key: Option<[u8; 32]>) {
    let (a, b, c) = (Device::new("a"), Device::new("b"), Device::new("c"));
    let (mut ic, mut cloud) = (Bucket::default(), Bucket::default());
    a.apply(T0, vec![review_of("ra1", "CA", T0), review_of("ra2", "CA", T0 + 1)]);
    // B 先只认识互联（第一次收 A 的段时还不知道网盘存在，没留原文），之后才加网盘。
    a.sync(&mut ic, "ic", T0 + 10);
    b.sync(&mut ic, "ic", T0 + 11);
    b.apply(T0 + 12, vec![review_of("rb1", "CB", T0 + 12)]);
    relay_rounds(&a, &b, &c, &mut ic, &mut cloud, cloud_key, T0 + 20, 3);
    assert_eq!(reviews(&c), 3, "C received A's reviews only by relay through B");
    assert_eq!(pending(&c), 0, "nothing of B's waits for A's ops any more");
    // 反方向：C 的操作经 B 转到只连互联的 A；A 再写，C 照样收齐。
    c.apply(T0 + 100, vec![review_of("rc1", "CC", T0 + 100)]);
    a.apply(T0 + 100, vec![review_of("ra3", "CA", T0 + 100)]);
    // C 的新段先要等 B 下一次走网盘才到 B，再等 B 走互联才到 A：比上一段多一圈。
    relay_rounds(&a, &b, &c, &mut ic, &mut cloud, cloud_key, T0 + 110, 4);
    for d in [&a, &b, &c] {
        assert_eq!(reviews(d), 5);
        assert_eq!(pending(d), 0);
    }
    assert_eq!(a.digest(), c.digest());
    assert_eq!(b.digest(), c.digest());
    // A 的段在网盘上只以转发件存在（A 从没连过网盘），作者签名原样：C 是按 A 的公钥验过才收的。
    let a_id = a.core.sync2_status(P).unwrap()["device"].as_str().unwrap().to_owned();
    let relayed: Vec<&Vec<u8>> = cloud.0.iter().filter(|(k, _)| k.starts_with(&format!("devices/{a_id}/rly-"))).map(|(_, v)| v).collect();
    assert!(!relayed.is_empty());
    assert!(!cloud.0.keys().any(|k| k.starts_with(&format!("devices/{a_id}/seg-"))));
    for r in &relayed {
        assert_eq!(&r[..4], crate::sync2::segment::RELAY_MAGIC);
        assert_eq!(r[5] & 1, u8::from(cloud_key.is_some()), "relay envelopes on an encrypted location are sealed with its key");
    }
    // 转发完不留原文；被新 head 取代的旧转发件已清掉（网盘上 A 的转发件正好是 A 最新 head 引用的那些）。
    assert_eq!(count(&b, "SELECT COUNT(*) FROM sync2_relay_segs"), 0);
    let a_heads: Vec<&String> = cloud.0.keys().filter(|k| k.starts_with(&format!("devices/{a_id}/head-"))).collect();
    assert_eq!(a_heads.len(), 1, "{a_heads:?}");
}

/// S-1：段 / head 转发——A ↔ B 只经互联、B ↔ C 只经网盘，C 收齐 A 的操作（以前永远收不到，B 此后的操作在 C 的
/// 缓冲里无界堆积），反方向同样。
#[test]
fn ops_reach_a_device_two_hops_away_through_relay() {
    relay_topology(None);
}

/// S-1：网盘加密、互联明文——转发件用网盘的密钥封装（明文不落到加密位置），读者不需要源位置的密钥。
#[test]
fn relay_crosses_locations_with_different_encryption() {
    relay_topology(Some([7; 32]));
}

/// S-1：转发者篡改不了：改转发件里的明文压缩体（链对不上）或换签名都被拒。
#[test]
fn a_tampered_relay_envelope_is_rejected() {
    let (a, b, c) = (Device::new("a"), Device::new("b"), Device::new("c"));
    let (mut ic, mut cloud) = (Bucket::default(), Bucket::default());
    a.apply(T0, vec![review_of("ra1", "CA", T0)]);
    let key = Some([9; 32]);
    a.sync(&mut ic, "ic", T0 + 1);
    b.sync(&mut ic, "ic", T0 + 2);
    b.sync_keyed(&mut cloud, "cloud", T0 + 3, key);
    b.sync(&mut ic, "ic", T0 + 4);
    b.sync_keyed(&mut cloud, "cloud", T0 + 5, key);
    let a_id = a.core.sync2_status(P).unwrap()["device"].as_str().unwrap().to_owned();
    let path = cloud.0.keys().find(|k| k.starts_with(&format!("devices/{a_id}/rly-"))).unwrap().clone();
    let good = cloud.0[&path].clone();
    // 解开封装、改一个字节的原段体，再用同一把位置密钥封回去：签名不再对得上。
    let ck = crate::sync2::keys::CollectionKey([9; 32]);
    let (mut orig, plain) = crate::sync2::segment::relay_unwrap(&good, Some(&ck)).unwrap();
    let n = orig.len();
    orig[n - 70] ^= 1;
    cloud.0.insert(path.clone(), crate::sync2::segment::relay_pack(&orig, plain.as_deref(), Some(&ck)).unwrap());
    let r = c.sync_keyed(&mut cloud, "cloud", T0 + 6, key);
    assert_eq!(reviews(&c), 0, "{r}");
    assert!(r["errors"].to_string().contains("signature"), "{r}");
}

/// S-2：收到远端操作后本机 HLC 推进并持久化——时钟慢一小时的设备看过对方的写入之后再写，HLC 也比它大。
#[test]
fn applied_remote_ops_advance_and_persist_the_local_clock() {
    let fast = Device::new("fast");
    let slow = Device::new("slow");
    let mut bucket = Bucket::default();
    fast.apply(T0 + HOUR, vec![edit("note", "N1", "tags", json!(["x", "y"]))]);
    fast.sync(&mut bucket, "loc", T0 + HOUR);
    slow.sync(&mut bucket, "loc", T0);
    assert!(self_hlc(&slow) >= T0 + HOUR, "clock advanced to the remote wall and was persisted");
    // 之后慢钟设备的写入排在它见过的写入之后。
    slow.apply(T0 + 1, vec![edit("note", "N1", "tags", json!(["y", "x"]))]);
    slow.sync(&mut bucket, "loc", T0 + 2);
    fast.sync(&mut bucket, "loc", T0 + HOUR + 3);
    assert_eq!(tags_of(&fast, "N1"), r#"["y","x"]"#);
    assert_eq!(tags_of(&slow, "N1"), r#"["y","x"]"#);
    let w: Value = slow.core.sync2_status(P).unwrap();
    assert!(w.to_string().find("clock_ahead").is_none(), "one hour is not an anomaly: {w}");
}

/// S-2：远端时钟超前超过 24 小时——照收、打标告警、不把本机时钟拽过去；寄存器因果优先：看过它之后才写的值照样
/// 赢（以前纯按 HLC，超前设备的值永远赢：标签顺序改不回来、媒体「不在」永远盖不过「在」→ 每轮重传）。
#[test]
fn a_write_made_after_seeing_a_far_future_write_wins_and_the_clock_is_flagged() {
    let ahead = Device::new("ahead");
    let slow = Device::new("slow");
    let mut bucket = Bucket::default();
    let future = T0 + 25 * HOUR;
    ahead.apply(future, vec![edit("note", "N1", "tags", json!(["x", "y"]))]);
    ahead.core.sync2_media_record(P, "loc/media", &["img.png".to_owned()], &[], false, future).unwrap();
    ahead.sync(&mut bucket, "loc", future);
    slow.sync(&mut bucket, "loc", T0);
    assert_eq!(media_state(&slow, "loc/media", "img.png"), Some(true));
    assert!(self_hlc(&slow) < future, "a far-future remote clock does not drag the local clock");
    let status = slow.core.sync2_status(P).unwrap().to_string();
    assert!(status.contains("clock_ahead"), "{status}");

    // 慢钟设备看过之后：改标签顺序、确认文件其实不在。
    slow.apply(T0 + 1, vec![edit("note", "N1", "tags", json!(["y", "x"]))]);
    slow.core.sync2_media_record(P, "loc/media", &[], &["img.png".to_owned()], false, T0 + 1).unwrap();
    assert_eq!(media_state(&slow, "loc/media", "img.png"), Some(false));
    assert_eq!(tags_of(&slow, "N1"), r#"["y","x"]"#);
    slow.sync(&mut bucket, "loc", T0 + 2);
    ahead.sync(&mut bucket, "loc", future + 1);
    for d in [&ahead, &slow] {
        assert_eq!(media_state(d, "loc/media", "img.png"), Some(false));
        assert_eq!(tags_of(d, "N1"), r#"["y","x"]"#);
    }
    // 真并发才比 HLC：两边都没见过对方时，超前的那份赢（低价值标量，设计 §5.2），两端一致。
    ahead.core.sync2_media_record(P, "loc/media", &["b.png".to_owned()], &[], false, future + 2).unwrap();
    slow.core.sync2_media_record(P, "loc/media", &[], &["b.png".to_owned()], false, T0 + 3).unwrap();
    for _ in 0..2 {
        slow.sync(&mut bucket, "loc", T0 + 4);
        ahead.sync(&mut bucket, "loc", future + 4);
    }
    assert_eq!(media_state(&ahead, "loc/media", "b.png"), Some(true));
    assert_eq!(media_state(&slow, "loc/media", "b.png"), Some(true));
    assert_eq!(ahead.digest(), slow.digest());
}

/// S-2：寄存器反链是操作集合的函数——升级时从日志重建（schema V10）与边收边并结果逐位相同，与顺序无关。
#[test]
fn register_rebuild_from_the_log_matches_incremental_projection() {
    let ahead = Device::new("ahead");
    let slow = Device::new("slow");
    let mut bucket = Bucket::default();
    let future = T0 + 25 * HOUR;
    ahead.core.sync2_media_record(P, "loc/media", &["img.png".to_owned()], &[], false, future).unwrap();
    ahead.apply(future, vec![edit("note", "N1", "tags", json!(["x", "y"]))]);
    ahead.sync(&mut bucket, "loc", future);
    slow.sync(&mut bucket, "loc", T0);
    slow.core.sync2_media_record(P, "loc/media", &[], &["img.png".to_owned()], false, T0 + 1).unwrap();
    slow.apply(T0 + 1, vec![edit("note", "N1", "tags", json!(["y", "x"]))]);
    let snap = |d: &Device| {
        (
            d.rows("SELECT location, name, present, wall, logical, hex(device) FROM sync2_media_at ORDER BY location, name"),
            d.rows("SELECT note, tags, wall, logical, hex(device) FROM sync2_tag_order ORDER BY note"),
            d.rows("SELECT reg, hex(device), seq FROM sync2_mvr ORDER BY reg, device, seq"),
        )
    };
    let before = snap(&slow);
    // 把投影弄乱（模拟升级前按纯 HLC 算出的值），再按 V10 重建。
    {
        let w = slow.core.writer().unwrap();
        w.execute_batch("UPDATE sync2_media_at SET present = 1, wall = 0; UPDATE sync2_tag_order SET tags = '[]', wall = 0; DELETE FROM sync2_mvr;")
            .unwrap();
        super::mvr::rebuild(&w).unwrap();
    }
    assert_eq!(snap(&slow), before);
}

/// 一台设备的本机媒体目录对一个名字跑一次对账（第一步 hash、第二步 scan），返回那个名字的条目与新绑定数。
fn media_scan(d: &Device, root: &std::path::Path, name: &str, now: i64) -> (Value, u64) {
    let names = vec![name.to_owned()];
    let hashed = d.core.sync2_media_hash(P, root.to_str().unwrap(), &names).unwrap();
    let mut files = std::collections::HashMap::new();
    for f in hashed["files"].as_array().unwrap() {
        let sha = super::media::unhex32(f["sha"].as_str().unwrap()).unwrap();
        files.insert(f["name"].as_str().unwrap().to_owned(), (f["size"].as_i64().unwrap(), f["mtime"].as_i64().unwrap(), sha));
    }
    let r = d.core.sync2_media_scan(P, &names, &files, now).unwrap();
    (r["items"][0].clone(), r["appended"].as_u64().unwrap())
}

fn sha_hex(bytes: &[u8]) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(bytes).iter().map(|x| format!("{x:02x}")).collect()
}

/// S-3：两台设备各有一个同名不同内容的媒体文件。以前按名字存、各留各的，永远分叉；现在名字经日志里的绑定（因果优先、
/// 并发才比 HLC）映射到内容：输的一方被告知去下载赢的内容，落地后两边对齐、不再写新绑定。之后谁改了文件，谁的新内容
/// 因果上盖过旧绑定（与时钟快慢无关），对方再跟上。
#[test]
fn same_named_media_with_different_content_converges() {
    let (a, b) = (Device::new("ma"), Device::new("mb"));
    let (ra, rb) = (super::tests::tempdir::new("ma-media"), super::tests::tempdir::new("mb-media"));
    std::fs::write(ra.0.join("image.jpg"), b"from a").unwrap();
    std::fs::write(rb.0.join("image.jpg"), b"from b").unwrap();
    let (ia, na) = media_scan(&a, &ra.0, "image.jpg", T0);
    let (ib, nb) = media_scan(&b, &rb.0, "image.jpg", T0 + 5);
    assert_eq!((na, nb), (1, 1), "each device binds its own file first");
    assert_eq!(ia["have"], json!(true));
    assert_eq!(ib["sha"], json!(sha_hex(b"from b")));
    let (_, again) = media_scan(&a, &ra.0, "image.jpg", T0 + 1);
    assert_eq!(again, 0, "an unchanged file is not bound again");
    let mut bucket = Bucket::default();
    for t in [10, 20, 30] {
        a.sync(&mut bucket, "loc", T0 + t);
        b.sync(&mut bucket, "loc", T0 + t + 1);
    }
    // 并发的两次绑定：HLC 大者（b，T0 + 5）胜。a 本机文件自上次对齐后没改过 → 去下载 b 的内容，不再绑自己的。
    let (ia, na) = media_scan(&a, &ra.0, "image.jpg", T0 + 40);
    assert_eq!(na, 0);
    assert_eq!(ia["have"], json!(false));
    assert_eq!(ia["sha"], json!(sha_hex(b"from b")));
    assert_eq!(ia["local"], json!(sha_hex(b"from a")));
    let (ib, nb) = media_scan(&b, &rb.0, "image.jpg", T0 + 41);
    assert_eq!((ib["have"].clone(), nb), (json!(true), 0));
    std::fs::write(ra.0.join("image.jpg"), b"from b").unwrap();
    let landed = a
        .core
        .sync2_media_landed(P, ra.0.to_str().unwrap(), &[("image.jpg".to_owned(), super::media::unhex32(&sha_hex(b"from b")).unwrap())], T0 + 42)
        .unwrap();
    assert_eq!(landed["appended"], json!(0));
    let (ia, na) = media_scan(&a, &ra.0, "image.jpg", T0 + 43);
    assert_eq!((ia["have"].clone(), na), (json!(true), 0));
    // a 的时钟落后很多也一样：它看过 b 的绑定之后改了文件，新内容盖过 b 的。
    std::fs::write(ra.0.join("image.jpg"), b"edited on a").unwrap();
    let (ia, na) = media_scan(&a, &ra.0, "image.jpg", T0 - 1000 * HOUR);
    assert_eq!((ia["have"].clone(), na), (json!(true), 1));
    for t in [50, 60] {
        a.sync(&mut bucket, "loc", T0 + t);
        b.sync(&mut bucket, "loc", T0 + t + 1);
    }
    let (ib, _) = media_scan(&b, &rb.0, "image.jpg", T0 + 70);
    assert_eq!(ib["have"], json!(false));
    assert_eq!(ib["sha"], json!(sha_hex(b"edited on a")));
    let bound = |d: &Device| d.rows(&format!("SELECT hex(sha256) FROM sync2_media WHERE profile_uid = '{P}' AND name = 'image.jpg'"));
    assert_eq!(bound(&a), bound(&b));
    // 清理：只被过期名字绑定、不被存活名字绑定的内容。
    let doomed = a.core.sync2_media_doomed(P, &["image.jpg".to_owned()], &[]).unwrap();
    assert_eq!(doomed["sha"], json!([sha_hex(b"edited on a")]));
    let kept = a.core.sync2_media_doomed(P, &["image.jpg".to_owned()], &["image.jpg".to_owned()]).unwrap();
    assert_eq!(kept["sha"], json!([]));
}
