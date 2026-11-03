//! 批量投影（bulk.rs）与逐条投影对拍：同一份段、同一个起点，两条路径收完后**每一张表**逐行相同（摘要桶逐位相同），
//! 收段命令的返回相同，复习队列 / 浏览的待重读相同。起点用 `copy_of` 复制，两边连本机身份都一样。
//!
//! 世界是伪随机的多设备历史：并发改同一字段、删除 / 恢复（与删除并发的内容 → 挂起与冲突中心）、清除、整列表标签、
//! 复习、移卡，以及两台设备各自迁移同一个旧库：
//! - 同一条旧修改记录 / 旧复习日志被包了两次（同 ID、同寄存器：第二条「已在」）；旧记录带服务器时刻（取较早的）；
//! - 同一个旧 ID 在两边落在同一笔记的不同字段（复制数据目录后各自又写过）：批量冲刷里两个寄存器撞 ID，走逐条退回；
//! - 一台设备分两批迁移，中间别的设备收了前一批并写了一条：它的 ctx 只覆盖这台迁移设备的一部分旧记录，旧修改记录
//!   闭包走逐条读操作日志的那一支（批量投影在到达时算闭包，见 bulk.rs 文件头）。

use std::collections::BTreeSet;

use serde_json::{json, Value};

use super::tests::{deck_entity, edit, review, Bucket, Device, P};

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;
const NOW: i64 = T0 + 400 * DAY;
const NOTES: u64 = 9;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn note_id(n: u64) -> String {
    format!("0193a1b2-0000-7000-8000-{n:012x}")
}

fn card_of(n: u64) -> String {
    crate::registers::card_id(&note_id(n), "t1", 0).unwrap()
}

/// 旧库里一条笔记字段的旧修改记录（[server] = 旧服务器记下的时刻）。
#[allow(clippy::too_many_arguments)]
fn legacy_edit(d: &Device, writer: &str, s: i64, n: u64, key: &str, v: Value, vv: Value, server: Option<i64>) {
    let id = crate::registers::edit_id(writer, s);
    let note = note_id(n);
    let j = json!({"ctx": {"vv": vv}, "e": note, "f": key, "hlc": format!("{}:0:{writer}", T0 - 1000 + s), "id": id, "k": "note",
                   "p": P, "s": s, "ts": "wall", "v": v, "w": writer})
    .to_string();
    // 写连接的锁只拿这一句（下面 `legacy_server_time` 还要拿）。
    d.core.writer().unwrap().execute(
        "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
         VALUES (srs_id(?1), srs_id(?2), 'note', srs_id(?3), ?4, ?5, ?6, ?7)",
        rusqlite::params![id, P, note, key, writer, s, j],
    )
    .unwrap();
    legacy_server_time(d, &id, server);
}

fn legacy_server_time(d: &Device, id: &str, server: Option<i64>) {
    if let Some(st) = server {
        d.core
            .writer()
            .unwrap()
            .execute(
                "INSERT INTO srs_event_local (event_id, profile_uid, outbox_seq, server_time, received_at) VALUES (srs_id(?1), srs_id(?2), 1, ?3, 1)",
                rusqlite::params![id, P, st],
            )
            .unwrap();
    }
}

/// 旧库里一条复习日志（作者结果照抄，见 mod.rs `sync2_migrate`）。
fn legacy_log(d: &Device, id: &str, n: u64, at: i64, server: Option<i64>) {
    let card = card_of(n);
    let x = json!({"id": id, "p": P, "card": card, "kind": "review", "rating": 3, "hlc": format!("{at}:0:old1"), "at": at,
                   "ts": "anchored", "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
                   "res": {"queue": "review", "dueDay": 19_700, "ivl": 3, "step": 0, "reps": 2, "lapses": 0, "scheduler": "fushi"}});
    d.core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, jslim) \
             VALUES (srs_id(?1), srs_id(?2), srs_id(?3), 'review', 3, ?4, 'review', 'fushi', ?5)",
            rusqlite::params![id, P, card, at, x.to_string()],
        )
        .unwrap();
    legacy_server_time(d, id, server);
}

/// 旧库：几条笔记上的旧修改记录（两个旧写入者，有因果覆盖也有并发，部分带服务器时刻）与几条旧复习日志。
fn legacy_library(d: &Device) {
    let rows: [(&str, i64, u64, &str, Value, Value, Option<i64>); 6] = [
        ("old1", 1, 0, "f/fa", json!("legacy a"), json!({}), Some(T0 - 900)),
        ("old1", 2, 0, "f/fa", json!("legacy a2"), json!({"old1": 1}), None),
        ("old2", 1, 0, "f/fa", json!("legacy concurrent"), json!({}), Some(T0 - 950)),
        ("old2", 2, 1, "f/fb", json!("legacy b"), json!({"old1": 2}), None),
        ("old1", 3, 2, "f/fa", json!("legacy c"), json!({"old1": 2, "old2": 2}), Some(T0 - 800)),
        ("old2", 3, 2, "deleted", json!(null), json!({"old2": 2}), None),
    ];
    for (writer, s, n, key, v, vv, server) in rows {
        legacy_edit(d, writer, s, n, key, v, vv, server);
    }
    legacy_log(d, "0193a1b2-0000-7000-8000-0000000010a1", 1, T0 - 5 * DAY, Some(T0 - 5 * DAY + 10));
    legacy_log(d, "0193a1b2-0000-7000-8000-0000000010a2", 1, T0 - 2 * DAY, None);
    legacy_log(d, "0193a1b2-0000-7000-8000-0000000010a3", 4, T0 - 3 * DAY, Some(T0 - 3 * DAY + 10));
}

fn local(d: &Device, now: i64, events: Vec<(Value, String)>) {
    let input: Vec<Value> = events.into_iter().map(|(e, note)| json!({"e": e, "note": note})).collect();
    d.core.sync2_apply_local(P, now, &Value::Array(input).to_string()).unwrap();
}

/// 一个伪随机世界：返回中途（第 3 轮之后）与最终的同步文件夹。
fn world(seed: u64) -> (Bucket, Bucket) {
    let mut rng = Rng(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1);
    let deck = super::config::default_deck_id(P);
    let deck2 = "0193a1b2-0000-7000-8000-00000000d0c2".to_owned();
    let devs = [Device::new("bk-a"), Device::new("bk-b"), Device::new("bk-c")];
    let l1 = Device::new("bk-l1");
    legacy_library(&l1);
    let l2 = Device::copy_of(&l1, "bk-l2");
    // 复制之后各自又写了同一个旧 ID（同一笔记、不同字段）。服务器时刻一边有一边没有。
    legacy_edit(&l1, "old3", 1, 3, "f/fa", json!("l1 copy"), json!({}), None);
    legacy_edit(&l2, "old3", 1, 3, "f/fb", json!("l2 copy"), json!({}), Some(T0 - 700));
    let mut bucket = Bucket::default();
    let mut setup = vec![
        (deck_entity(&deck), String::new()),
        (edit("deck", &deck, "name", json!("D")), String::new()),
        (deck_entity(&deck2), String::new()),
        (json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}), String::new()),
        (edit("notetype", "NT", "fieldDef/fa", json!({"name": "A", "ord": 0})), String::new()),
        (edit("notetype", "NT", "tmplDef/t1", json!({"name": "C", "ord": 0, "front": "{{A}}"})), String::new()),
    ];
    for n in 0..NOTES {
        let note = note_id(n);
        setup.push((json!({"t": "entity", "x": {"id": note, "p": P, "k": "note", "d": {"createdAt": 1, "guid": note, "noteTypeId": "NT"}}}), note));
    }
    local(&devs[0], T0, setup);
    // l1 分两批迁移，中间 devs[0] 收了前一批并在旧记录写过的字段上写了一条。
    l1.core.sync2_migrate(P, T0, Some(3)).unwrap();
    l1.sync(&mut bucket, "loc", T0 + 1);
    devs[0].sync(&mut bucket, "loc", T0 + 1);
    local(&devs[0], T0 + 1, vec![(edit("note", &note_id(0), "f/fa", json!("over part of l1")), note_id(0))]);
    devs[0].sync(&mut bucket, "loc", T0 + 1);
    l1.core.sync2_migrate(P, T0, None).unwrap();
    l1.sync(&mut bucket, "loc", T0 + 1);
    l2.core.sync2_migrate(P, T0 + 1, None).unwrap();
    l2.sync(&mut bucket, "loc", T0 + 1);
    for d in &devs {
        d.sync(&mut bucket, "loc", T0 + 2);
    }
    let mut mid = None;
    for round in 0..6i64 {
        for (i, d) in devs.iter().enumerate() {
            let now = T0 + (round + 1) * DAY + i as i64 * 3_600_000;
            let mut ev: Vec<(Value, String)> = Vec::new();
            for k in 0..4 + rng.below(10) {
                let n = rng.below(NOTES);
                let note = note_id(n);
                let tag = format!("r{round}d{i}k{k}");
                let e = match rng.below(20) {
                    0..=6 => edit("note", &note, if rng.below(2) == 0 { "f/fa" } else { "f/fb" }, json!(tag)),
                    7..=8 => edit("note", &note, "tags", json!([format!("t{}", rng.below(4)), format!("t{}", rng.below(4))])),
                    9..=12 => review(&tag, &card_of(n), now + k as i64, 1 + rng.below(4) as i64, if round == 0 { "learn" } else { "review" }),
                    13 => edit("note", &note, "deleted", json!(now)),
                    14 => edit("note", &note, "deleted", json!(null)),
                    15 => edit("card", &card_of(n), "flag", json!(rng.below(5))),
                    16 => edit("card", &card_of(n), "deck", json!(if rng.below(2) == 0 { &deck } else { &deck2 })),
                    17 => edit("deck", &deck2, "name", json!(tag)),
                    18 => edit("card", &card_of(n), "deleted", json!(now)),
                    _ => edit("deck", &deck, "retention", json!(0.8 + rng.below(10) as f64 / 100.0)),
                };
                ev.push((e, note));
            }
            local(d, now, ev);
            if rng.below(12) == 0 {
                d.core.sync2_purge(P, "note", &note_id(rng.below(NOTES)), now + 1).unwrap();
            }
        }
        // 只同步一部分设备、顺序随机：留下并发。
        for i in 0..devs.len() {
            if rng.below(3) != 0 {
                let d = &devs[(i + rng.below(3) as usize) % devs.len()];
                d.sync(&mut bucket, "loc", T0 + (round + 1) * DAY + 20 * 3_600_000 + i as i64);
            }
        }
        if round == 2 {
            mid = Some(bucket.clone());
        }
    }
    for _ in 0..2 {
        for d in &devs {
            d.sync(&mut bucket, "loc", T0 + 30 * DAY);
        }
    }
    (mid.unwrap(), bucket)
}

/// 全部表（`sqlite_` 内部表除外）的全部列、逐行，排好序。
fn dump(d: &Device) -> Vec<(String, Vec<String>)> {
    let tables: Vec<String> =
        d.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")[1..].iter().map(|r| r[0].clone()).collect();
    tables
        .into_iter()
        .map(|t| {
            let cols: Vec<String> = d.rows(&format!("SELECT name FROM pragma_table_info('{t}') ORDER BY cid"))[1..].iter().map(|r| format!("quote({})", r[0])).collect();
            let mut rows: Vec<String> = d.rows(&format!("SELECT {} FROM {t}", cols.join(" || '|' || ")))[1..].iter().map(|r| r[0].clone()).collect();
            rows.sort();
            (t, rows)
        })
        .collect()
}

fn assert_same(a: &Device, b: &Device, what: &str) {
    let (da, db) = (dump(a), dump(b));
    assert_eq!(da.len(), db.len());
    for ((ta, ra), (tb, rb)) in da.iter().zip(&db) {
        assert_eq!(ta, tb);
        assert_eq!(ra, rb, "{what}: table {ta} differs");
    }
}

/// 复习队列（卡 / 日志）与浏览（卡 / 笔记）的待重读：取走。
fn dirty(d: &Device) -> [BTreeSet<String>; 4] {
    let s = d.core.study_hub.take_study(P);
    let b = d.core.study_hub.take_browse(P, true);
    assert!(!s.overflow && !b.overflow);
    let set = |h: std::collections::HashSet<String>| h.into_iter().collect::<BTreeSet<String>>();
    [set(s.cards), set(s.logs), set(b.cards), set(b.notes)]
}

fn digest_is_consistent(d: &Device) {
    let r = d.core.reader().unwrap();
    assert_eq!(super::digest::root(&r, P).unwrap(), super::digest::root_by_scan(&r, P).unwrap(), "bucket digest drifted from a full scan");
}

/// 收 [bucket] 里的全部段（一次收完）。
fn ingest(d: &Device, bucket: &Bucket, now: i64) -> Value {
    let mut b = bucket.clone();
    d.sync(&mut b, "loc", now)
}

/// 随机世界真的走到了批量投影的每一条分支（[super::bulk::Coverage]）。
fn assert_covered(total: [usize; 4], what: &str) {
    for (k, name) in ["batched flush", "small flush", "fallback", "partial legacy closure"].iter().enumerate() {
        assert!(total[k] > 0, "{what}: the random worlds never exercised the {name} path ({total:?})");
    }
}

fn add(total: &mut [usize; 4], c: [usize; 4]) {
    for (t, c) in total.iter_mut().zip(c) {
        *t += c;
    }
}

/// 新设备：批量与逐条两路收完全部历史，一切相同。
#[test]
fn bulk_projection_matches_sequential_for_a_new_device() {
    let mut total = [0usize; 4];
    for seed in 1..=5u64 {
        let (_, all) = world(seed);
        let x = Device::new("bk-x");
        x.core.sync2_identity(P, NOW).unwrap();
        let y = Device::copy_of(&x, "bk-y");
        dirty(&x);
        dirty(&y);
        super::bulk::take_coverage();
        let rx = ingest(&x, &all, NOW);
        add(&mut total, super::bulk::take_coverage());
        let ry = super::bulk::sequential(|| ingest(&y, &all, NOW));
        assert!(rx["applied"].as_u64().unwrap() > 50, "seed {seed}: {rx}");
        assert_eq!(rx, ry, "seed {seed}: ingest result");
        assert_same(&x, &y, &format!("seed {seed}"));
        assert_eq!(dirty(&x), dirty(&y), "seed {seed}: study / browse touches");
        digest_is_consistent(&x);
    }
    assert_covered(total, "new device");
}

/// 已有数据的设备追赶一大批（第二期「大量追赶」）：现存行被新到的支配、删掉，摘要减得对。
#[test]
fn bulk_projection_matches_sequential_when_catching_up() {
    let mut total = [0usize; 4];
    for seed in 11..=15u64 {
        let (mid, all) = world(seed);
        let d = Device::new("bk-d");
        ingest(&d, &mid, NOW - DAY);
        let x = Device::copy_of(&d, "bk-dx");
        let y = Device::copy_of(&d, "bk-dy");
        dirty(&x);
        dirty(&y);
        super::bulk::take_coverage();
        let rx = ingest(&x, &all, NOW);
        add(&mut total, super::bulk::take_coverage());
        let ry = super::bulk::sequential(|| ingest(&y, &all, NOW));
        assert_eq!(rx, ry, "seed {seed}: ingest result");
        assert_same(&x, &y, &format!("catch-up seed {seed}"));
        assert_eq!(dirty(&x), dirty(&y), "seed {seed}: study / browse touches");
        digest_is_consistent(&x);
    }
    // 追赶时迁移来的旧记录多半已在中途收过：只要求批量与零头两种冲刷都走到。
    assert!(total[0] > 0 && total[1] > 0, "catch-up never exercised both flush paths ({total:?})");
}

/// 生产分发器的分批会话（每片几条、跨片复用投递队列）：收尾后与逐条一次收完的投影、记账、摘要相同。
#[test]
fn bulk_projection_in_a_sliced_session_matches_sequential() {
    let (_, all) = world(21);
    let x = Device::new("bk-sx");
    x.core.sync2_identity(P, NOW).unwrap();
    let y = Device::copy_of(&x, "bk-sy");
    super::bulk::sequential(|| ingest(&y, &all, NOW));
    let deck = super::config::default_deck_id(P);
    let cmd = |req: Value, blobs: Vec<Vec<u8>>| -> Value {
        let mut req = req;
        req["profile"] = json!(P);
        req["caches"] = json!({"defaultDeck": deck});
        let mut blobs = blobs;
        let mut files = Vec::new();
        crate::store::ffi::sync2_dispatch(&x.core, &req, &mut blobs, &mut files).unwrap()
    };
    let heads: Vec<Vec<u8>> = all
        .0
        .iter()
        .filter(|(k, _)| k.rsplit('/').next().and_then(crate::sync2::segment::parse_head_file_name).is_some())
        .map(|(_, v)| v.clone())
        .collect();
    let segs: Vec<Vec<u8>> = all.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect();
    cmd(json!({"op": "plan"}), heads);
    cmd(json!({"op": "ingest_begin"}), vec![]);
    for chunk in segs.chunks(2) {
        cmd(json!({"op": "ingest_prepare"}), chunk.to_vec());
        while cmd(json!({"op": "ingest_commit", "now": NOW, "sliceOps": 7}), vec![])["more"] == json!(true) {}
    }
    let mut r = cmd(json!({"op": "ingest_finish", "now": NOW, "sliceOps": 7}), vec![]);
    while r["more"] == json!(true) {
        r = cmd(json!({"op": "replay_pending", "sliceOps": 7}), vec![]);
    }
    let tables = [
        "srs_field_edits",
        "srs_review_logs",
        "srs_entities",
        "srs_event_local",
        "srs_unknown_events",
        "sync2_ops",
        "sync2_deps",
        "sync2_ent_ops",
        "sync2_edit_ops",
        "sync2_log_meta",
        "sync2_legacy",
        "sync2_held",
        "sync2_conflicts",
        "sync2_tag_adds",
        "sync2_tag_order",
        "sync2_purged",
        "sync2_digest_buckets",
    ];
    let (dx, dy) = (dump(&x), dump(&y));
    for t in tables {
        let a = dx.iter().find(|(n, _)| n == t).unwrap();
        let b = dy.iter().find(|(n, _)| n == t).unwrap();
        assert_eq!(a.1, b.1, "sliced session: table {t} differs");
    }
    digest_is_consistent(&x);
}

/// 批量冲刷关掉的是主库触发器（摘要桶）；TEMP 触发器（待重读）照常触发——SQLite 3.35 起
/// `SQLITE_DBCONFIG_ENABLE_TRIGGER` 不再管 TEMP 触发器。这条行为变了，批量投影就会漏记待重读。
#[test]
fn disabling_triggers_keeps_temp_triggers() {
    use rusqlite::config::DbConfig;
    let c = rusqlite::Connection::open_in_memory().unwrap();
    c.execute_batch(
        "CREATE TABLE t (x); CREATE TABLE main_log (x); CREATE TEMP TABLE temp_log (x);
         CREATE TRIGGER main_t AFTER INSERT ON t BEGIN INSERT INTO main_log VALUES (NEW.x); END;
         CREATE TEMP TRIGGER temp_t AFTER INSERT ON main.t BEGIN INSERT INTO temp_log VALUES (NEW.x); END;",
    )
    .unwrap();
    c.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, false).unwrap();
    c.execute("INSERT INTO t VALUES (1)", []).unwrap();
    c.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, true).unwrap();
    c.execute("INSERT INTO t VALUES (2)", []).unwrap();
    let count = |sql: &str| -> i64 { c.query_row(sql, [], |r| r.get(0)).unwrap() };
    assert_eq!(count("SELECT COUNT(*) FROM main_log"), 1, "main-schema trigger is off while disabled");
    assert_eq!(count("SELECT COUNT(*) FROM temp_log"), 2, "TEMP trigger keeps firing");
}

/// 新设备（本机身份没写过复习日志）的收段会话用长片；本机复习过就回到默认片长。
#[test]
fn ingest_session_is_a_bootstrap_until_this_device_reviews() {
    let x = Device::new("bk-bs");
    x.core.sync2_identity(P, NOW).unwrap();
    let bootstrapping = |d: &Device| -> bool {
        d.core.sync2_ingest_begin(P).unwrap();
        d.core.ingest_session.lock().unwrap().as_ref().unwrap().bootstrapping()
    };
    assert!(bootstrapping(&x), "a device that never reviewed");
    let deck = super::config::default_deck_id(P);
    local(&x, NOW, vec![(deck_entity(&deck), String::new()), (edit("deck", &deck, "name", json!("D")), String::new())]);
    assert!(bootstrapping(&x), "local edits alone do not end the bootstrap");
    local(&x, NOW + 1, vec![(review("bs-r", &card_of(0), NOW + 1, 3, "learn"), note_id(0))]);
    assert!(!bootstrapping(&x), "a device that reviewed uses the default slice");
}
