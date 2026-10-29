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
