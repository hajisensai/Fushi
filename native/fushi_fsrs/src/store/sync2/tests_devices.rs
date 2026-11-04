//! 设备可识别（devices.rs）：型号 / 版本 / 昵称随 head 到达别的设备；停用一台缺段的设备后，卡住的操作不再等它。

use serde_json::{json, Value};

use super::tests::{deck_entity, edit, Bucket, Device, P};
use crate::sync2::id::Id;
use crate::sync2::segment;

const T0: i64 = 1_700_000_000_000;

fn device_id(d: &Device) -> String {
    d.core.sync2_identity(P, T0).unwrap()["device"].as_str().unwrap().to_owned()
}

fn row_of(status: &Value, device: &str) -> Value {
    status["devices"].as_array().unwrap().iter().find(|d| d["device"] == json!(device)).cloned().unwrap_or(Value::Null)
}

fn pending(d: &Device) -> i64 {
    d.rows("SELECT COUNT(*) FROM sync2_pending")[1][0].parse().unwrap()
}

#[test]
fn device_name_and_version_reach_other_devices() {
    let (a, b) = (Device::new("dn-a"), Device::new("dn-b"));
    let mut bucket = Bucket::default();
    let info = a.core.sync2_device_info(P, &json!({"model": "iPhone 17", "app": "3.3", "platform": "ios"}), T0).unwrap();
    assert_eq!(info["name"], "iPhone 17");
    assert_eq!(info["changed"], true);
    // 同样的再给一次：没变（不进写锁）。
    let again = a.core.sync2_device_info(P, &json!({"model": "iPhone 17", "app": "3.3", "platform": "ios"}), T0).unwrap();
    assert_eq!(again["changed"], false);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0 + 1);
    let st = b.core.sync2_status(P).unwrap();
    let row = row_of(&st, &device_id(&a));
    assert_eq!(row["name"], "iPhone 17");
    assert_eq!(row["model"], "iPhone 17");
    assert_eq!(row["app"], "3.3");
    assert_eq!(row["platform"], "ios");
    assert_eq!(row["protocol"], segment::PROTOCOL);
    assert_eq!(row["state"], "ok");
    // 昵称只替换名称部分；型号照旧在扩展里。
    a.core.sync2_device_info(P, &json!({"nick": "Wight 的手机"}), T0 + 2).unwrap();
    a.sync(&mut bucket, "loc", T0 + 3);
    b.sync(&mut bucket, "loc", T0 + 4);
    let row = row_of(&b.core.sync2_status(P).unwrap(), &device_id(&a));
    assert_eq!(row["name"], "Wight 的手机");
    assert_eq!(row["model"], "iPhone 17");
    // 本机信息在 selfInfo。
    let me = a.core.sync2_status(P).unwrap()["selfInfo"].clone();
    assert_eq!((me["name"].as_str(), me["nick"].as_str(), me["app"].as_str()), (Some("Wight 的手机"), Some("Wight 的手机"), Some("3.3")));
    // 清掉昵称回到型号。
    assert_eq!(a.core.sync2_device_info(P, &json!({"nick": ""}), T0 + 5).unwrap()["name"], "iPhone 17");
}

#[test]
fn old_heads_without_name_have_no_model_and_hint_fills_in() {
    let (a, b) = (Device::new("dh-a"), Device::new("dh-b"));
    let mut bucket = Bucket::default();
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0 + 1);
    let id = device_id(&a);
    let row = row_of(&b.core.sync2_status(P).unwrap(), &id);
    assert_eq!(row["name"], "");
    assert!(row.get("model").is_none());
    assert!(row["seenAt"].as_i64().is_some());
    assert_eq!(b.core.sync2_device_hint(&id, "Pixel 8").unwrap()["changed"], true);
    assert_eq!(b.core.sync2_device_hint(&id, "Pixel 8").unwrap()["changed"], false);
    assert_eq!(row_of(&b.core.sync2_status(P).unwrap(), &id)["hint"], "Pixel 8");
}

/// 拓扑：C ↔ B 走网盘，B ↔ A 走互联。B 收了 C 的操作后又写了操作（因果上下文含 C），但 C 的段没能到达 A（互联
/// 目录里 C 的段 / 转发件都丢了，只剩 head）：A 收下 B 的操作后卡在缓冲里等 C。A 把 C 标成「不用了」之后，B 的
/// 操作投递进来；取消停用不撤回；C 的段之后真到了照样应用。
#[test]
fn retiring_a_device_releases_ops_stuck_waiting_for_it() {
    let (a, b, c) = (Device::new("rt-a"), Device::new("rt-b"), Device::new("rt-c"));
    let (mut cloud, mut ic) = (Bucket::default(), Bucket::default());
    let deck = Id::random().text();
    c.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("FromC"))]);
    c.sync(&mut cloud, "cloud", T0 + 1);
    b.sync(&mut cloud, "cloud", T0 + 2);
    b.apply(T0 + 3, vec![edit("deck", &deck, "retention", json!(0.93))]);
    b.sync(&mut ic, "ic", T0 + 4);
    let cid = device_id(&c);
    // 互联目录里 C 的段全丢，只留 C 的 head（A 认识 C、知道它发布过什么）。
    let c_dir = format!("devices/{cid}/");
    let c_head = cloud.0.iter().find(|(k, _)| k.starts_with(&c_dir) && k.contains("/head-")).map(|(k, v)| (k.clone(), v.clone())).unwrap();
    ic.0.retain(|k, _| !k.starts_with(&c_dir));
    ic.0.insert(c_head.0, c_head.1);
    a.sync(&mut ic, "ic", T0 + 5);
    assert!(pending(&a) > 0, "B's op waits for C");
    let row = row_of(&a.core.sync2_status(P).unwrap(), &cid);
    assert_eq!(row["state"], "missing");
    assert!(row["blocking"].as_i64().unwrap() > 0);
    // 本机不能停用自己。
    assert!(a.core.sync2_retire(P, &device_id(&a), true, T0 + 6).is_err());
    a.core.sync2_retire(P, &cid, true, T0 + 6).unwrap();
    let out: Value = serde_json::from_str(&a.core.sync2_ingest(P, &[], None, T0 + 6).unwrap()).unwrap();
    assert!(out["applied"].as_u64().unwrap() > 0);
    assert_eq!(pending(&a), 0);
    let row = row_of(&a.core.sync2_status(P).unwrap(), &cid);
    assert_eq!(row["state"], "retired");
    assert_eq!(row["retiredAt"], T0 + 6);
    // 取消停用：标记撤掉，已投递的不撤回。
    a.core.sync2_retire(P, &cid, false, T0 + 7).unwrap();
    assert_eq!(pending(&a), 0);
    assert!(row_of(&a.core.sync2_status(P).unwrap(), &cid).get("retiredAt").is_none());
    // 再停用；C 之后回来（写了新 head、段也到了互联目录）：自动取消停用，它的操作照样应用。
    a.core.sync2_retire(P, &cid, true, T0 + 8).unwrap();
    c.sync(&mut ic, "ic", T0 + 9);
    a.sync(&mut ic, "ic", T0 + 10);
    let row = row_of(&a.core.sync2_status(P).unwrap(), &cid);
    assert!(row.get("retiredAt").is_none(), "a device that comes back is no longer retired");
    assert_eq!(row["state"], "ok");
    assert_eq!(a.digest(), b.digest());
}
