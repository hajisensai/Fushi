//! 编辑类撤销的校验 `undo_check`（undo_check.rs）：只有自那次写入以来没被别人动过的字段键才判「可以撤」——
//! 同步拉进来的别的设备的修改、本机之后的改动、并发候选都让它不撤，并交回现值。

use serde_json::{Value, json};

use super::tests::{Bucket, Device, P, edit};

const T0: i64 = 1_700_000_000_000;
const CARD: &str = "0193a1b2-0000-7000-8000-00000000d0c1";

fn dispatch(d: &Device, req: Value) -> Value {
    let mut blobs: Vec<Vec<u8>> = Vec::new();
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files).unwrap()
}

/// 本机写一条卡片旗标，交回 `apply` 报告的那条修改的 dot `(设备, 序号)`。
fn set_flag(d: &Device, now: i64, flag: i64) -> (String, i64) {
    let r = d.apply(now, vec![edit("card", CARD, "flag", json!(flag))]);
    let edits = r["edits"].as_array().expect("apply reports written edits");
    assert_eq!(edits.len(), 1, "{r}");
    let e = &edits[0];
    assert_eq!(e[0], "card");
    assert_eq!(e[1], CARD);
    assert_eq!(e[2], "flag");
    (e[3].as_str().unwrap().to_owned(), e[4].as_i64().unwrap())
}

fn check(d: &Device, items: Value) -> Vec<(bool, Value)> {
    let r = dispatch(d, json!({"op": "undo_check", "profile": P, "items": items}));
    r["r"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| (x["ok"].as_bool().unwrap(), x["cur"].clone()))
        .collect()
}

fn item(dot: &(String, i64)) -> Value {
    json!({"k": "card", "e": CARD, "f": "flag", "w": dot.0, "s": dot.1})
}

#[test]
fn untouched_edit_can_be_undone() {
    let d = Device::new("undo-untouched");
    let dot = set_flag(&d, T0, 1);
    assert_eq!(check(&d, json!([item(&dot)])), vec![(true, json!(1))]);
}

#[test]
fn later_local_change_blocks_undo_and_reports_current_value() {
    let d = Device::new("undo-later");
    let dot = set_flag(&d, T0, 1);
    set_flag(&d, T0 + 10, 3);
    assert_eq!(check(&d, json!([item(&dot)])), vec![(false, json!(3))]);
}

#[test]
fn value_restored_by_later_write_counts_as_untouched() {
    // 1 → 2 → 撤掉第二步（写回 1）：第一步的结果原样在，仍可撤。
    let d = Device::new("undo-chain");
    let first = set_flag(&d, T0, 1);
    let second = set_flag(&d, T0 + 10, 2);
    assert_eq!(check(&d, json!([item(&second)])), vec![(true, json!(2))]);
    set_flag(&d, T0 + 20, 1);
    assert_eq!(check(&d, json!([item(&first)])), vec![(true, json!(1))]);
    // 第二步那条已被盖掉、现值不是它写的值：不撤。
    assert_eq!(check(&d, json!([item(&second)])), vec![(false, json!(1))]);
}

#[test]
fn change_pulled_in_by_sync_blocks_undo() {
    let a = Device::new("undo-sync-a");
    let b = Device::new("undo-sync-b");
    let mut bucket = Bucket::default();
    let dot = set_flag(&a, T0, 1);
    a.sync(&mut bucket, "loc", T0);
    b.sync(&mut bucket, "loc", T0);
    // B 看见了 A 的修改之后再改。
    set_flag(&b, T0 + 100, 5);
    b.sync(&mut bucket, "loc", T0 + 200);
    a.sync(&mut bucket, "loc", T0 + 300);
    assert_eq!(check(&a, json!([item(&dot)])), vec![(false, json!(5))]);
}

#[test]
fn concurrent_candidate_blocks_undo() {
    let a = Device::new("undo-conc-a");
    let b = Device::new("undo-conc-b");
    let mut bucket = Bucket::default();
    // 谁也没看见谁：两台各写一个值，同步后寄存器里有两条并发记录。
    let dot = set_flag(&a, T0, 1);
    set_flag(&b, T0 + 5, 2);
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + 100);
        b.sync(&mut bucket, "loc", T0 + 100);
    }
    let r = check(&a, json!([item(&dot)]));
    assert!(!r[0].0, "{r:?}");
}

#[test]
fn unknown_dot_is_not_undone() {
    let d = Device::new("undo-unknown");
    let dot = set_flag(&d, T0, 1);
    let bogus = (dot.0.clone(), dot.1 + 100);
    assert_eq!(check(&d, json!([item(&bogus)])), vec![(false, json!(1))]);
    // 别的键上的 dot 冒充这个键：不撤。
    let other = json!({"k": "card", "e": CARD, "f": "suspended", "w": dot.0, "s": dot.1});
    assert_eq!(check(&d, json!([other])), vec![(false, Value::Null)]);
}

#[test]
fn legacy_items_without_dot_compare_by_value() {
    let d = Device::new("undo-legacy");
    set_flag(&d, T0, 4);
    let same = json!({"k": "card", "e": CARD, "f": "flag", "v": 4});
    let other = json!({"k": "card", "e": CARD, "f": "flag", "v": 7});
    assert_eq!(
        check(&d, json!([same, other])),
        vec![(true, json!(4)), (false, json!(4))]
    );
}
