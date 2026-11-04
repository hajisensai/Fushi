//! 两台设备迁移同一份旧库（BUG-4005：宿主与 01a173ca 各自把同一份旧库包成了自己的操作流，修改记录 / 日志 / 身份记录
//! 在操作日志里各有两份）。迁移只包**还没有任何设备的操作代表**的旧行：先收到了别的设备迁出的那一份，就只包本机独有的
//! 那几条；投影与全新设备收齐的结果一致，操作日志里每条旧记录只出现一次。

use serde_json::json;

use super::tests::{legacy_library, projection, Bucket, Device, DAY, P};

const T0: i64 = 1_700_000_000_000;

/// 只在这台设备的旧库里有的三条：一条笔记身份记录、同一个旧写入者接着写的一条修改记录、一条旧复习日志。
fn legacy_extra(d: &Device) {
    let deck = super::config::default_deck_id(P);
    let w = d.core.writer().unwrap();
    w.execute(
        "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (srs_id(?1), srs_id(?2), 'note', '{\"createdAt\":9}', 9)",
        rusqlite::params!["N9", P],
    )
    .unwrap();
    let e3 = crate::registers::edit_id("old", 3);
    let x = json!({"ctx": {"vv": {"old": 2}}, "e": deck, "f": "desc", "hlc": "3:0:old", "id": e3, "k": "deck", "p": P, "s": 3, "ts": "wall", "v": "only here", "w": "old"});
    w.execute(
        "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
         VALUES (srs_id(?1), srs_id(?2), 'deck', srs_id(?3), 'desc', 'old', 3, ?4)",
        rusqlite::params![e3, P, deck, x.to_string()],
    )
    .unwrap();
    let at = T0 + 5 * DAY;
    let log = json!({
        "id": "L3", "p": P, "card": "C", "kind": "review", "rating": 3, "hlc": format!("{at}:0:old"), "at": at,
        "ts": "anchored", "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
        "res": {"queue": "review", "dueDay": 19_900, "ivl": 60, "step": 0, "reps": 3, "lapses": 0, "scheduler": "fushi",
                "memory": {"s": 60.0, "d": 5.0, "sf": 0.0}, "lastReviewedAt": at}
    });
    w.execute(
        "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, jslim) \
         VALUES (srs_id(?1), srs_id(?2), 'C', 'review', 3, ?3, 'review', 'fushi', ?4)",
        rusqlite::params!["L3", P, at, log.to_string()],
    )
    .unwrap();
}

fn ops(d: &Device) -> i64 {
    d.rows("SELECT COUNT(*) FROM sync2_ops")[1][0].parse().unwrap()
}

/// A 迁移并上传；B 有同一份旧库外加三条独有的旧行，先收 A 的操作再迁移：只包那三条。两边与全新设备收敛，
/// 操作日志里每条旧记录只有一份。
#[test]
fn a_second_device_migrating_the_same_legacy_library_wraps_only_what_is_missing() {
    let a = Device::new("dedup-a");
    let b = Device::new("dedup-b");
    legacy_library(&a);
    legacy_library(&b);
    legacy_extra(&b);
    let mut bucket = Bucket::default();
    let now = T0 + 10 * DAY;
    assert_eq!(a.core.sync2_migrate(P, now, None).unwrap()["ops"], json!(10));
    a.sync(&mut bucket, "loc", now);

    // B 先收一轮（迁移前），再迁移：A 已经代表的 10 条一条不包。
    b.sync(&mut bucket, "loc", now + 1);
    let m = b.core.sync2_migrate(P, now + 2, None).unwrap();
    assert_eq!(m["done"], json!(true));
    assert_eq!(m["ops"], json!(3), "only the rows no device has wrapped yet: {m}");
    // 再打开一次不会再包（已迁移）。
    assert_eq!(b.core.sync2_migrate(P, now + 3, None).unwrap()["ops"], json!(0));

    for k in 0..2 {
        b.sync(&mut bucket, "loc", now + 10 + k);
        a.sync(&mut bucket, "loc", now + 20 + k);
    }
    assert_eq!(ops(&a), 13, "every legacy row is one op, not one per migrating device");
    assert_eq!(ops(&b), 13);
    assert_eq!(projection(&a), projection(&b));
    assert_eq!(a.rows("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE field_key = 'desc'")[1][0], "only here");

    let c = Device::new("dedup-c");
    c.sync(&mut bucket, "loc", now + 30);
    assert_eq!(c.core.sync2_status(P).unwrap()["pending"], 0);
    assert_eq!(projection(&c), projection(&a));
}

/// 旧库里的行全都已经被操作代表（A 自己的旧库与 A 迁出的完全相同）：B 收过之后迁移一条都不包，只补标记。
#[test]
fn migrating_a_library_fully_covered_by_received_ops_wraps_nothing() {
    let a = Device::new("cover-a");
    let b = Device::new("cover-b");
    legacy_library(&a);
    legacy_library(&b);
    let mut bucket = Bucket::default();
    let now = T0 + 10 * DAY;
    a.core.sync2_migrate(P, now, None).unwrap();
    a.sync(&mut bucket, "loc", now);
    b.sync(&mut bucket, "loc", now + 1);
    let m = b.core.sync2_migrate(P, now + 2, None).unwrap();
    assert_eq!(m, json!({"done": true, "ops": 0, "remaining": 0}));
    assert_eq!(ops(&b), 10);
    b.sync(&mut bucket, "loc", now + 3);
    a.sync(&mut bucket, "loc", now + 4);
    assert_eq!(ops(&a), 10);
    assert_eq!(projection(&a), projection(&b));
}

/// 档案合并查目标里已有的旧 dot（`legacy_dots`）：读操作日志，被支配、已不在投影里的旧修改记录也在。
#[test]
fn legacy_dots_lists_every_legacy_edit_in_the_op_log_including_dominated_ones() {
    let a = Device::new("dots-a");
    legacy_library(&a);
    legacy_extra(&a);
    a.core.sync2_migrate(P, T0 + 10 * DAY, None).unwrap();
    // 本机再改一次 desc：旧的 seq 3 被支配，投影里没有了，操作日志里还在。
    let deck = super::config::default_deck_id(P);
    a.apply(T0 + 11 * DAY, vec![super::tests::edit("deck", &deck, "desc", json!("newer"))]);
    assert!(a.rows("SELECT 1 FROM srs_field_edits WHERE srs_idt(writer_id) = 'old' AND seq = 3").len() == 1, "dominated: gone from the projection");
    let dots = a.core.sync2_legacy_dots(P).unwrap();
    assert_eq!(dots["writers"]["old"], json!([1, 1, 0, 2, 2, 0, 3, 3, 0]), "{dots}");
}
