//! 设备信任（trust.rs）：本机库非空时新出现的设备，普通操作照收，删除与彻底清除扣到本机确认之后；确认之后与一开始
//! 就信任逐表相同；升级那一刻已认识的设备不受影响；全新库首轮同步不被全扣；拒绝之后继续扣着。

use serde_json::{Value, json};

use super::tests::{AUTO_TRUST, Bucket, Device, P, deck_entity, edit, projection};
use crate::sync2::id::Id;

const T0: i64 = 1_700_000_000_000;

fn strict() {
    AUTO_TRUST.with(|f| f.set(false));
}

fn device_id(d: &Device) -> String {
    d.core.sync2_identity(P, T0).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn row_of(d: &Device, device: &str) -> Value {
    d.core.sync2_status(P).unwrap()["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["device"] == json!(device))
        .cloned()
        .unwrap_or(Value::Null)
}

fn count(d: &Device, sql: &str) -> i64 {
    d.rows(sql)[1][0].parse().unwrap()
}

/// [deck] 在投影里有没有生效的删除。
fn deleted(d: &Device, deck: &str) -> bool {
    count(
        d,
        &format!(
            "SELECT COUNT(*) FROM srs_field_edits WHERE entity_id = srs_id('{deck}') AND field_key = 'deleted'"
        ),
    ) > 0
}

fn name_of(d: &Device, deck: &str) -> Option<String> {
    let rows = d.rows(&format!(
        "SELECT json FROM srs_field_edits WHERE entity_id = srs_id('{deck}') AND field_key = 'name'"
    ));
    rows.get(1)
        .and_then(|r| serde_json::from_str::<Value>(&r[0]).ok())
        .and_then(|v| v["v"].as_str().map(str::to_owned))
}

/// 投影之外、同样由操作集合决定的表（冲突中心、清除标记、标签添加点）。
fn semantics_tables(d: &Device) -> Vec<Vec<String>> {
    let mut out = d.rows(
        "SELECT srs_idt(id) AS id, kind, entity_kind, srs_idt(entity) AS e, hex(device), seq, other_count FROM sync2_conflicts ORDER BY 1",
    );
    out.extend(d.rows(
        "SELECT hex(device), seq, kind, srs_idt(entity) AS e FROM sync2_held ORDER BY 1, 2",
    ));
    out.extend(d.rows("SELECT kind, srs_idt(entity) AS e FROM sync2_purged ORDER BY 1, 2"));
    out.extend(d.rows(
        "SELECT hex(device), seq, purged FROM sync2_ops ORDER BY 1, 2",
    ));
    out
}

fn vv_part(d: &Device) -> String {
    d.core.sync2_digest(P).unwrap();
    d.rows(&format!(
        "SELECT value FROM srs_meta WHERE key = 'sync2_digest/{P}'"
    ))[1][0]
        .split_once('@')
        .unwrap()
        .1
        .to_owned()
}

struct Decks {
    keep: String,
    gone: String,
    purge: String,
    clash: String,
}

/// A 有一个库（4 个牌组），B 是之后加入的新设备（全新库，信任 A）。B 改名一个、删一个、彻底清除一个，并删掉 A 同时
/// 在改的那个（因果并发 → 冲突中心）。返回牌组 ID。A 此时还没收 B 的段。
fn scenario(a: &Device, b: &Device, bucket: &mut Bucket) -> Decks {
    let d = Decks {
        keep: Id::random().text(),
        gone: Id::random().text(),
        purge: Id::random().text(),
        clash: Id::random().text(),
    };
    let mut evs = Vec::new();
    for (id, name) in [
        (&d.keep, "Keep"),
        (&d.gone, "Gone"),
        (&d.purge, "SecretPurgeName"),
        (&d.clash, "Clash"),
    ] {
        evs.push(deck_entity(id));
        evs.push(edit("deck", id, "name", json!(name)));
    }
    a.apply(T0, evs);
    a.sync(bucket, "loc", T0 + 1);
    b.sync(bucket, "loc", T0 + 2);
    assert_eq!(
        count(b, "SELECT COUNT(*) FROM sync2_trust"),
        0,
        "a fresh library trusts the devices it meets on its first sync"
    );
    b.apply(
        T0 + 3,
        vec![
            edit("deck", &d.keep, "name", json!("Renamed by B")),
            edit("deck", &d.gone, "deleted", json!(T0 + 3)),
            edit("deck", &d.clash, "deleted", json!(T0 + 3)),
        ],
    );
    b.core.sync2_purge(P, "deck", &d.purge, T0 + 4).unwrap();
    // A 并发地改 clash（没见过 B 的删除）。
    a.apply(T0 + 5, vec![edit("deck", &d.clash, "retention", json!(0.95))]);
    b.sync(bucket, "loc", T0 + 6);
    d
}

#[test]
fn new_device_ordinary_ops_land_but_deletes_and_purges_wait_for_confirmation() {
    strict();
    let (a, b) = (Device::new("tr-a"), Device::new("tr-b"));
    let mut bucket = Bucket::default();
    let d = scenario(&a, &b, &mut bucket);
    a.sync(&mut bucket, "loc", T0 + 7);
    let bid = device_id(&b);
    // 普通操作照收。
    assert_eq!(name_of(&a, &d.keep).as_deref(), Some("Renamed by B"));
    // 删除与彻底清除都扣着：实体可见，清除的内容还在日志里。
    assert!(!deleted(&a, &d.gone));
    assert!(!deleted(&a, &d.purge));
    assert!(!deleted(&a, &d.clash));
    assert_eq!(name_of(&a, &d.purge).as_deref(), Some("SecretPurgeName"));
    assert!(a.ops_containing(&["SecretPurgeName"]) > 0);
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_purged"), 0);
    // 扣着的不进冲突中心（冲突要等确认之后按因果判）。
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_conflicts"), 0);
    let row = row_of(&a, &bid);
    assert_eq!(row["trust"], "pending");
    assert_eq!(row["heldDeletes"], 3, "gone + clash + the delete that precedes the purge");
    assert_eq!(row["heldPurges"], 1);
    // B 的操作已进日志、版本向量照常推进：没有卡在缓冲里，进度不落后。
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_pending"), 0);
    assert_eq!(row["behind"], 0);
    // 扣着期间两边投影有意不同：摘要的版本向量部分带扣住指纹，双方都不当成确定性 bug。
    assert!(vv_part(&a).contains('~'));
    a.sync(&mut bucket, "loc", T0 + 8);
    b.sync(&mut bucket, "loc", T0 + 9);
    assert_eq!(row_of(&a, &bid)["digestMismatch"], false);
    assert_eq!(row_of(&b, &device_id(&a))["digestMismatch"], false);
    // 本机自己永远可信；不能拒绝已可信的设备。
    assert!(a.core.sync2_trust(P, &device_id(&a), true, T0 + 10).is_err());
    assert!(b.core.sync2_trust(P, &device_id(&a), false, T0 + 10).is_err());
}

#[test]
fn trusting_later_equals_trusting_from_the_start() {
    strict();
    let (a, b) = (Device::new("tl-a"), Device::new("tl-b"));
    let mut bucket = Bucket::default();
    let d = scenario(&a, &b, &mut bucket);
    a.sync(&mut bucket, "loc", T0 + 7);
    let bid = device_id(&b);
    let out = a.core.sync2_trust(P, &bid, true, T0 + 8).unwrap();
    assert_eq!(out["released"], 4);
    assert!(
        out["purged"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x[1] == json!(d.purge))
    );
    assert!(row_of(&a, &bid).get("trust").is_none());
    assert!(deleted(&a, &d.gone));
    assert!(deleted(&a, &d.purge));
    assert_eq!(a.ops_containing(&["SecretPurgeName"]), 0);
    // clash：B 的删除与 A 的修改并发 → 进冲突中心扣着（与一开始就信任一样）。
    assert!(!deleted(&a, &d.clash));
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_conflicts"), 1);
    assert!(!vv_part(&a).contains('~'));

    // 对照：一台一开始就信任两边的设备（全新库，第一次同步就收齐 A 与 B 的全部操作）。
    a.sync(&mut bucket, "loc", T0 + 9);
    let c = Device::new("tl-c");
    c.sync(&mut bucket, "loc", T0 + 10);
    assert_eq!(count(&c, "SELECT COUNT(*) FROM sync2_trust"), 0);
    assert_eq!(projection(&a), projection(&c));
    assert_eq!(semantics_tables(&a), semantics_tables(&c));
    assert_eq!(a.digest(), c.digest());
    // 与作者 B 收敛（B 也收了 A 的并发修改）。
    b.sync(&mut bucket, "loc", T0 + 11);
    assert_eq!(projection(&a), projection(&b));
    assert_eq!(a.digest(), b.digest());
    assert_eq!(row_of(&a, &bid)["digestMismatch"], false);
}

#[test]
fn rejected_device_keeps_its_deletes_held_and_can_be_trusted_later() {
    strict();
    let (a, b) = (Device::new("rj-a"), Device::new("rj-b"));
    let mut bucket = Bucket::default();
    let d = scenario(&a, &b, &mut bucket);
    a.sync(&mut bucket, "loc", T0 + 7);
    let bid = device_id(&b);
    let out = a.core.sync2_trust(P, &bid, false, T0 + 8).unwrap();
    assert_eq!(out["released"], 0);
    assert_eq!(row_of(&a, &bid)["trust"], "rejected");
    // 拒绝之后它的新操作：普通的照收，新的删除照样扣着。
    let more = Id::random().text();
    b.apply(
        T0 + 9,
        vec![
            deck_entity(&more),
            edit("deck", &more, "name", json!("Later")),
            edit("deck", &d.keep, "deleted", json!(T0 + 9)),
        ],
    );
    b.sync(&mut bucket, "loc", T0 + 10);
    a.sync(&mut bucket, "loc", T0 + 11);
    assert_eq!(name_of(&a, &more).as_deref(), Some("Later"));
    assert!(!deleted(&a, &d.keep));
    assert!(!deleted(&a, &d.gone));
    let row = row_of(&a, &bid);
    assert_eq!(row["trust"], "rejected");
    assert_eq!(row["heldDeletes"], 4);
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_pending"), 0);
    // 改为信任：全部放行，与作者收敛。
    a.core.sync2_trust(P, &bid, true, T0 + 12).unwrap();
    a.sync(&mut bucket, "loc", T0 + 13);
    b.sync(&mut bucket, "loc", T0 + 14);
    assert!(deleted(&a, &d.keep));
    assert_eq!(projection(&a), projection(&b));
    assert_eq!(a.digest(), b.digest());
}

#[test]
fn devices_known_before_the_upgrade_stay_trusted() {
    strict();
    let (a, b) = (Device::new("up-a"), Device::new("up-b"));
    let mut bucket = Bucket::default();
    let deck = Id::random().text();
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("X"))]);
    a.sync(&mut bucket, "loc", T0 + 1);
    b.sync(&mut bucket, "loc", T0 + 2);
    b.apply(T0 + 3, vec![edit("deck", &deck, "retention", json!(0.9))]);
    b.sync(&mut bucket, "loc", T0 + 4);
    a.sync(&mut bucket, "loc", T0 + 5);
    // 把 A 退回 v28 的样子（升级之前已经认识 B：v28 没有信任表），重新打开走 v29 迁移。
    {
        let w = a.core.writer().unwrap();
        w.execute_batch(
            "DROP TABLE sync2_trust; DROP TABLE sync2_trust_held; UPDATE srs_meta SET value = '28' WHERE key = 'schema';",
        )
        .unwrap();
    }
    let Device { core, _dir } = a;
    drop(core);
    let a = Device {
        core: crate::store::SrsCore::open(&_dir.0.join("srs.db")).unwrap(),
        _dir,
    };
    assert_eq!(
        a.rows("SELECT value FROM srs_meta WHERE key = 'schema'")[1][0],
        crate::store::schema::SCHEMA_VERSION.to_string()
    );
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_trust"), 0);
    // B 之后的删除照常生效。
    b.apply(T0 + 6, vec![edit("deck", &deck, "deleted", json!(T0 + 6))]);
    b.sync(&mut bucket, "loc", T0 + 7);
    a.sync(&mut bucket, "loc", T0 + 8);
    assert!(deleted(&a, &deck));
    assert!(row_of(&a, &device_id(&b)).get("trust").is_none());
    assert_eq!(projection(&a), projection(&b));
}

#[test]
fn fresh_library_first_sync_is_not_held_but_later_newcomers_are() {
    strict();
    let (a, b) = (Device::new("fr-a"), Device::new("fr-b"));
    let mut bucket = Bucket::default();
    // 已有两台互信的设备，各自删过东西、清除过东西。
    let decks: Vec<String> = (0..4).map(|_| Id::random().text()).collect();
    // 内置的默认牌组：Dart 开库就写（`ensureBuiltins`），新设备第一次同步前也有它。
    let builtin = super::config::default_deck_id(P);
    let mut evs = vec![deck_entity(&builtin)];
    for (i, id) in decks.iter().enumerate() {
        evs.push(deck_entity(id));
        evs.push(edit("deck", id, "name", json!(format!("D{i}"))));
    }
    a.apply(T0, evs);
    a.sync(&mut bucket, "loc", T0 + 1);
    b.sync(&mut bucket, "loc", T0 + 2);
    b.apply(T0 + 3, vec![edit("deck", &decks[0], "deleted", json!(T0 + 3))]);
    b.core.sync2_purge(P, "deck", &decks[1], T0 + 4).unwrap();
    b.sync(&mut bucket, "loc", T0 + 5);
    a.sync(&mut bucket, "loc", T0 + 6);
    a.core.sync2_trust(P, &device_id(&b), true, T0 + 7).unwrap();
    a.apply(T0 + 8, vec![edit("deck", &decks[2], "deleted", json!(T0 + 8))]);
    a.sync(&mut bucket, "loc", T0 + 9);
    b.sync(&mut bucket, "loc", T0 + 10);
    // 新设备 E：全新库，第一次同步认识的 A、B 全部可信，删除与清除全部生效。
    let e = Device::new("fr-e");
    e.apply(T0 + 11, vec![deck_entity(&builtin)]);
    e.sync(&mut bucket, "loc", T0 + 11);
    assert_eq!(count(&e, "SELECT COUNT(*) FROM sync2_trust"), 0);
    assert_eq!(count(&e, "SELECT COUNT(*) FROM sync2_trust_held"), 0);
    assert!(deleted(&e, &decks[0]) && deleted(&e, &decks[1]) && deleted(&e, &decks[2]));
    assert_eq!(projection(&e), projection(&a));
    assert_eq!(e.digest(), a.digest());
    // 之后再出现的新设备 F（E 的库已非空）在 E 上待确认。
    let f = Device::new("fr-f");
    f.sync(&mut bucket, "loc", T0 + 12);
    f.apply(T0 + 13, vec![edit("deck", &decks[3], "deleted", json!(T0 + 13))]);
    f.sync(&mut bucket, "loc", T0 + 14);
    e.sync(&mut bucket, "loc", T0 + 15);
    assert_eq!(row_of(&e, &device_id(&f))["trust"], "pending");
    assert!(!deleted(&e, &decks[3]));
}
