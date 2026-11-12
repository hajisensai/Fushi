//! 新设备收段通道（channel.rs，先追加后折叠）与逐条投递对拍：同一份段、同一个起点（`copy_of` 复制，本机身份也相同），
//! 都经生产分发器的分批会话（`ingest_begin` / `ingest_prepare` / `ingest_commit` / `ingest_finish` / `replay_pending`）
//! 收完，一边走通道、一边关掉通道（[super::channel::sequential]），之后**每一张表**逐行相同（摘要桶逐位相同、缓存行
//! 相同），复习队列 / 浏览的待重读相同。
//!
//! 世界是伪随机的多设备历史：并发改同一字段、删除 / 恢复（与删除并发的内容 → 挂起与冲突中心）、清除、整列表标签、
//! 复习、移卡、删牌组（移进被删牌组的卡要逐条），以及两台设备各自迁移同一个旧库（同一条旧记录被包两次、旧记录带
//! 服务器时刻、合成写入者的旧 `tags` 记录、一台设备分两批迁移让 v2 写入只见过它一部分旧记录）。
//!
//! 除了一口气收完，还对拍几种中途打断：追加到一半重开会话、折叠到一半重开会话、追加到一半本机写入（分发器先把通道
//! 做完，之后逐条投递）。

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::tests::{Bucket, Device, P, deck_entity, edit, review};

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
fn legacy_edit(
    d: &Device,
    writer: &str,
    s: i64,
    n: u64,
    key: &str,
    v: Value,
    vv: Value,
    server: Option<i64>,
) {
    let id = crate::registers::edit_id(writer, s);
    let note = note_id(n);
    let j = json!({"ctx": {"vv": vv}, "e": note, "f": key, "hlc": format!("{}:0:{writer}", T0 - 1000 + s), "id": id, "k": "note",
                   "p": P, "s": s, "ts": "wall", "v": v, "w": writer})
    .to_string();
    d.core
        .writer()
        .unwrap()
        .execute(
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

/// 旧库：几条笔记上的旧修改记录（两个旧写入者，有因果覆盖也有并发，部分带服务器时刻）、一条合成写入者的旧整列表
/// 标签（走标签路径，不让笔记变复杂）与几条旧复习日志。
fn legacy_library(d: &Device) {
    let rows: [(&str, i64, u64, &str, Value, Value, Option<i64>); 6] = [
        (
            "old1",
            1,
            0,
            "f/fa",
            json!("legacy a"),
            json!({}),
            Some(T0 - 900),
        ),
        (
            "old1",
            2,
            0,
            "f/fa",
            json!("legacy a2"),
            json!({"old1": 1}),
            None,
        ),
        (
            "old2",
            1,
            0,
            "f/fa",
            json!("legacy concurrent"),
            json!({}),
            Some(T0 - 950),
        ),
        (
            "old2",
            2,
            1,
            "f/fb",
            json!("legacy b"),
            json!({"old1": 2}),
            None,
        ),
        (
            "old1",
            3,
            2,
            "f/fa",
            json!("legacy c"),
            json!({"old1": 2, "old2": 2}),
            Some(T0 - 800),
        ),
        (
            "old2",
            3,
            2,
            "deleted",
            json!(null),
            json!({"old2": 2}),
            None,
        ),
    ];
    for (writer, s, n, key, v, vv, server) in rows {
        legacy_edit(d, writer, s, n, key, v, vv, server);
    }
    let synth = format!(
        "{}tags:{}",
        crate::registers::SYNTHETIC_WRITER_PREFIX,
        note_id(5)
    );
    legacy_edit(
        d,
        &synth,
        1,
        5,
        "tags",
        json!(["legacy-tag", "t1"]),
        json!({"old1": 1}),
        None,
    );
    legacy_log(
        d,
        "0193a1b2-0000-7000-8000-0000000010a1",
        1,
        T0 - 5 * DAY,
        Some(T0 - 5 * DAY + 10),
    );
    legacy_log(
        d,
        "0193a1b2-0000-7000-8000-0000000010a2",
        1,
        T0 - 2 * DAY,
        None,
    );
    legacy_log(
        d,
        "0193a1b2-0000-7000-8000-0000000010a3",
        4,
        T0 - 3 * DAY,
        Some(T0 - 3 * DAY + 10),
    );
}

fn local(d: &Device, now: i64, events: Vec<(Value, String)>) {
    let input: Vec<Value> = events
        .into_iter()
        .map(|(e, note)| json!({"e": e, "note": note}))
        .collect();
    d.core
        .sync2_apply_local(P, now, &Value::Array(input).to_string())
        .unwrap();
}

/// 一个伪随机世界的同步文件夹（全部历史）。
fn world(seed: u64) -> Bucket {
    let mut rng = Rng(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1);
    let deck = super::config::default_deck_id(P);
    let deck2 = "0193a1b2-0000-7000-8000-00000000d0c2".to_owned();
    let devs = [
        Device::new("ch-a"),
        Device::new("ch-b"),
        Device::new("ch-c"),
    ];
    let l1 = Device::new("ch-l1");
    legacy_library(&l1);
    let l2 = Device::copy_of(&l1, "ch-l2");
    // 复制之后各自又写了同一个旧 ID（同一笔记、不同字段）。服务器时刻一边有一边没有。
    legacy_edit(&l1, "old3", 1, 3, "f/fa", json!("l1 copy"), json!({}), None);
    legacy_edit(
        &l2,
        "old3",
        1,
        3,
        "f/fb",
        json!("l2 copy"),
        json!({}),
        Some(T0 - 700),
    );
    let mut bucket = Bucket::default();
    let mut setup = vec![
        (deck_entity(&deck), String::new()),
        (edit("deck", &deck, "name", json!("D")), String::new()),
        (deck_entity(&deck2), String::new()),
        (
            json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            String::new(),
        ),
        (
            edit(
                "notetype",
                "NT",
                "fieldDef/fa",
                json!({"name": "A", "ord": 0}),
            ),
            String::new(),
        ),
        (
            edit(
                "notetype",
                "NT",
                "tmplDef/t1",
                json!({"name": "C", "ord": 0, "front": "{{A}}"}),
            ),
            String::new(),
        ),
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
    local(
        &devs[0],
        T0 + 1,
        vec![(
            edit("note", &note_id(0), "f/fa", json!("over part of l1")),
            note_id(0),
        )],
    );
    devs[0].sync(&mut bucket, "loc", T0 + 1);
    l1.core.sync2_migrate(P, T0, None).unwrap();
    l1.sync(&mut bucket, "loc", T0 + 1);
    l2.core.sync2_migrate(P, T0 + 1, None).unwrap();
    l2.sync(&mut bucket, "loc", T0 + 1);
    for d in &devs {
        d.sync(&mut bucket, "loc", T0 + 2);
    }
    for round in 0..6i64 {
        for (i, d) in devs.iter().enumerate() {
            let now = T0 + (round + 1) * DAY + i as i64 * 3_600_000;
            let mut ev: Vec<(Value, String)> = Vec::new();
            for k in 0..4 + rng.below(10) {
                let n = rng.below(NOTES);
                let note = note_id(n);
                let tag = format!("r{round}d{i}k{k}");
                let e = match rng.below(21) {
                    0..=6 => edit(
                        "note",
                        &note,
                        if rng.below(2) == 0 { "f/fa" } else { "f/fb" },
                        json!(tag),
                    ),
                    7..=8 => edit(
                        "note",
                        &note,
                        "tags",
                        json!([format!("t{}", rng.below(4)), format!("t{}", rng.below(4))]),
                    ),
                    9..=12 => review(
                        &tag,
                        &card_of(n),
                        now + k as i64,
                        1 + rng.below(4) as i64,
                        if round == 0 { "learn" } else { "review" },
                    ),
                    13 => edit("note", &note, "deleted", json!(now)),
                    14 => edit("note", &note, "deleted", json!(null)),
                    15 => edit("card", &card_of(n), "flag", json!(rng.below(5))),
                    16 => edit(
                        "card",
                        &card_of(n),
                        "deck",
                        json!(if rng.below(2) == 0 { &deck } else { &deck2 }),
                    ),
                    17 => edit("deck", &deck2, "name", json!(tag)),
                    18 => edit("card", &card_of(n), "deleted", json!(now)),
                    // 删 / 恢复第二个牌组：移进它的卡在通道里要逐条投。
                    19 => edit(
                        "deck",
                        &deck2,
                        "deleted",
                        if rng.below(2) == 0 {
                            json!(now)
                        } else {
                            json!(null)
                        },
                    ),
                    _ => edit(
                        "deck",
                        &deck,
                        "retention",
                        json!(0.8 + rng.below(10) as f64 / 100.0),
                    ),
                };
                ev.push((e, note));
            }
            local(d, now, ev);
            if rng.below(12) == 0 {
                d.core
                    .sync2_purge(P, "note", &note_id(rng.below(NOTES)), now + 1)
                    .unwrap();
            }
        }
        // 只同步一部分设备、顺序随机：留下并发。
        for i in 0..devs.len() {
            if rng.below(3) != 0 {
                let d = &devs[(i + rng.below(3) as usize) % devs.len()];
                d.sync(
                    &mut bucket,
                    "loc",
                    T0 + (round + 1) * DAY + 20 * 3_600_000 + i as i64,
                );
            }
        }
    }
    for _ in 0..2 {
        for d in &devs {
            d.sync(&mut bucket, "loc", T0 + 30 * DAY);
        }
    }
    bucket
}

/// 全部表（`sqlite_` 内部表除外）的全部列、逐行，排好序。缓存表的 `updated_at` 是刷新时的真实墙钟（两次运行必然
/// 不同），不比。本机状态行里两个键换成占位：纪元是每个库各自随机生成的；修订号是变化计数，可见性变了的实体按「每条
/// 命令 / 每一片各算一次」计（local_state.rs `persist_projected_with` / `advance_revision`），切片不同数就不同——
/// 通道与逐条两路只要求都前进了（[revision]）。
fn dump(d: &Device) -> Vec<(String, Vec<String>)> {
    let tables: Vec<String> =
        d.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")[1..].iter().map(|r| r[0].clone()).collect();
    tables
        .into_iter()
        .map(|t| {
            let cols: Vec<String> = d.rows(&format!(
                "SELECT name FROM pragma_table_info('{t}') ORDER BY cid"
            ))[1..]
                .iter()
                .filter(|r| !(t.ends_with("_cache") && r[0] == "updated_at"))
                .map(|r| {
                    if t == "srs_local_state" && r[0] == "json" {
                        "quote(json_set(json, '$.epoch', '_', '$.revision', '_'))".to_owned()
                    } else {
                        format!("quote({})", r[0])
                    }
                })
                .collect();
            let mut rows: Vec<String> = d
                .rows(&format!("SELECT {} FROM {t}", cols.join(" || '|' || ")))[1..]
                .iter()
                .map(|r| r[0].clone())
                .collect();
            rows.sort();
            (t, rows)
        })
        .collect()
}

/// 本机状态行里的修订号（没有行为 0）。
fn revision(d: &Device) -> i64 {
    d.rows(&format!(
        "SELECT json_extract(json, '$.revision') FROM srs_local_state WHERE profile_uid = srs_id('{P}')"
    ))
    .get(1)
    .and_then(|r| r[0].parse().ok())
    .unwrap_or(0)
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
    assert_eq!(
        super::digest::root(&r, P).unwrap(),
        super::digest::root_by_scan(&r, P).unwrap(),
        "bucket digest drifted from a full scan"
    );
}

/// 经生产分发器发一条 v2 命令。
fn cmd(d: &Device, req: Value, blobs: Vec<Vec<u8>>) -> Value {
    let mut req = req;
    req["profile"] = json!(P);
    req["caches"] = json!({"defaultDeck": super::config::default_deck_id(P)});
    let mut blobs = blobs;
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files).unwrap()
}

/// 经生产分发器发一条 v2 命令，期望它失败：返回错误文本。
fn cmd_err(d: &Device, req: Value) -> String {
    let mut req = req;
    req["profile"] = json!(P);
    let (mut blobs, mut files) = (Vec::new(), Vec::new());
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files).unwrap_err()
}

/// 文件夹里的 head 与段。
fn heads_and_segments(b: &Bucket) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
    let heads =
        b.0.iter()
            .filter(|(k, _)| {
                k.rsplit('/')
                    .next()
                    .and_then(crate::sync2::segment::parse_head_file_name)
                    .is_some()
            })
            .map(|(_, v)| v.clone())
            .collect();
    let segs =
        b.0.iter()
            .filter(|(k, _)| k.contains("/seg-"))
            .map(|(_, v)| v.clone())
            .collect();
    (heads, segs)
}

/// 中途要做的事（[session] 在第 [at] 批投完之后）。
#[derive(Clone, Copy, PartialEq, Debug)]
enum Interrupt {
    None,
    /// 重开收段会话（App 在追加途中被杀）。
    ReopenWhileAppending,
    /// 本机写一条（作答）：分发器先把通道做完。
    LocalWrite,
    /// 收尾折到一半重开会话（App 在折叠途中被杀），新会话没有段可收。
    ReopenWhileFolding,
    /// 收尾归并到一半（至少归并过一张表）重开会话（App 在归并途中被杀）。
    ReopenWhileMerging,
}

/// 通道的（阶段, 游标）；没有通道 = None。
fn boot_state(d: &Device) -> Option<(i64, i64)> {
    let rows = d.rows("SELECT phase, cursor FROM sync2_boot");
    rows.get(1)
        .map(|r| (r[0].parse().unwrap(), r[1].parse().unwrap()))
}

/// 分批会话收完 [b]：每批 [per] 个段，每片 [slice] 条（None = 生产的按时间切）。
fn session(d: &Device, b: &Bucket, per: usize, slice: Option<u64>, interrupt: Interrupt) {
    let (heads, segs) = heads_and_segments(b);
    let sliced = |op: &str| -> Value {
        let mut r = json!({"op": op, "now": NOW});
        if let Some(n) = slice {
            r["sliceOps"] = json!(n);
        }
        r
    };
    cmd(d, json!({"op": "plan"}), heads);
    cmd(d, json!({"op": "ingest_begin"}), vec![]);
    let at = segs.len() / per / 2;
    for (i, chunk) in segs.chunks(per).enumerate() {
        cmd(d, json!({"op": "ingest_prepare"}), chunk.to_vec());
        while cmd(d, sliced("ingest_commit"), vec![])["more"] == json!(true) {}
        if i == at {
            match interrupt {
                Interrupt::ReopenWhileAppending => {
                    cmd(d, json!({"op": "ingest_begin"}), vec![]);
                }
                Interrupt::LocalWrite => {
                    let input = json!([{"e": edit("note", &note_id(7), "f/fa", json!("typed mid-sync")), "note": note_id(7)}]).to_string();
                    cmd(
                        d,
                        json!({"op": "apply", "now": NOW, "legacyDevice": "dev"}),
                        vec![input.into_bytes()],
                    );
                    let w = d.core.writer().unwrap();
                    assert!(
                        !super::channel::active(&w, P).unwrap(),
                        "a local write settles the channel first"
                    );
                }
                _ => {}
            }
        }
    }
    let mut r = cmd(d, sliced("ingest_finish"), vec![]);
    if interrupt == Interrupt::ReopenWhileFolding && r["more"] == json!(true) {
        cmd(d, json!({"op": "ingest_begin"}), vec![]);
        r = cmd(d, sliced("ingest_finish"), vec![]);
    }
    // 逐条投递的对照组没有通道，照常收完。
    if interrupt == Interrupt::ReopenWhileMerging && boot_state(d).is_some() {
        while !boot_state(d).is_some_and(|(phase, cursor)| phase == 2 && cursor >= 1) {
            assert_eq!(
                r["more"],
                json!(true),
                "the channel finished without being caught mid-merge"
            );
            r = cmd(d, sliced("replay_pending"), vec![]);
        }
        cmd(d, json!({"op": "ingest_begin"}), vec![]);
        assert!(
            boot_state(d).is_none(),
            "the next session settles the channel first"
        );
        r = cmd(d, sliced("ingest_finish"), vec![]);
    }
    while r["more"] == json!(true) {
        r = cmd(d, sliced("replay_pending"), vec![]);
    }
}

fn add(total: &mut [usize; 4], c: [usize; 4]) {
    for (t, c) in total.iter_mut().zip(c) {
        *t += c;
    }
}

/// 一个新设备：通道与逐条两路经同一个分批会话收完，一切相同。
fn compare(
    seed: u64,
    per: usize,
    slice: Option<u64>,
    interrupt: Interrupt,
    total: &mut [usize; 4],
) {
    let all = world(seed);
    let x = Device::new("ch-x");
    x.core.sync2_identity(P, NOW).unwrap();
    let y = Device::copy_of(&x, "ch-y");
    dirty(&x);
    dirty(&y);
    super::channel::take_coverage();
    session(&x, &all, per, slice, interrupt);
    add(total, super::channel::take_coverage());
    super::channel::sequential(|| session(&y, &all, per, slice, interrupt));
    let what = format!("seed {seed}, {per} segments a batch, slice {slice:?}, {interrupt:?}");
    assert!(
        x.rows("SELECT COUNT(*) FROM sync2_ops")[1][0]
            .parse::<u64>()
            .unwrap()
            > 50,
        "{what}: world too small"
    );
    assert_same(&x, &y, &what);
    assert!(
        revision(&x) > 0 && revision(&y) > 0,
        "{what}: both ways advance the revision"
    );
    assert_eq!(dirty(&x), dirty(&y), "{what}: study / browse touches");
    digest_is_consistent(&x);
}

/// 新设备第一次同步：通道与逐条投递逐表相同；随机世界走到了折叠、复杂实体逐条、折叠里落了又被支配、移进复杂牌组。
#[test]
fn channel_matches_sequential_for_a_new_device() {
    let mut total = [0usize; 4];
    for seed in 1..=5u64 {
        compare(seed, 2, Some(7), Interrupt::None, &mut total);
    }
    compare(6, 100, None, Interrupt::None, &mut total);
    for (k, name) in [
        "folded op",
        "complex op",
        "landed then dominated",
        "card moved into a complex deck",
    ]
    .iter()
    .enumerate()
    {
        assert!(
            total[k] > 0,
            "the random worlds never exercised: {name} ({total:?})"
        );
    }
}

/// 中途打断：追加到一半重开会话、本机写入（先做完通道再逐条）、折叠到一半 / 归并到一半重开会话。
#[test]
fn channel_survives_interruptions() {
    let mut total = [0usize; 4];
    for (seed, interrupt) in [
        (31, Interrupt::ReopenWhileAppending),
        (32, Interrupt::LocalWrite),
        (33, Interrupt::ReopenWhileFolding),
        (34, Interrupt::ReopenWhileMerging),
    ] {
        compare(seed, 2, Some(5), interrupt, &mut total);
    }
}

/// 只有新设备走通道：已有操作日志的 profile 收段照常逐条投递。
#[test]
fn channel_is_only_for_a_fresh_profile() {
    let x = Device::new("ch-fresh");
    x.core.sync2_identity(P, NOW).unwrap();
    let w = x.core.writer().unwrap();
    assert!(
        super::channel::begin(&w, P, &mut |_| {}).unwrap(),
        "a fresh profile opens the channel"
    );
    assert!(
        super::channel::begin(&w, P, &mut |_| {}).unwrap(),
        "an appending channel resumes"
    );
    super::channel::settle(&w, P, &mut |_| {}).unwrap();
    assert!(
        !super::channel::active(&w, P).unwrap(),
        "settled channel leaves no rows"
    );
    drop(w);
    let deck = super::config::default_deck_id(P);
    local(&x, NOW, vec![(deck_entity(&deck), String::new())]);
    let w = x.core.writer().unwrap();
    assert!(
        !super::channel::begin(&w, P, &mut |_| {}).unwrap(),
        "a profile with ops delivers one by one"
    );
}

/// 会话外把通道做完（分发器在本机写入前、`channel_settle`）按片提交：中途失败只丢那一片，已做的留着、下一次接着做，
/// 结果与逐条投递相同。以前整段在调用方的一个事务里：失败整段回滚，每条写命令都从头重做。
#[test]
fn settling_commits_slice_by_slice_and_resumes_after_a_failure() {
    let all = world(41);
    let x = Device::new("ch-settle-x");
    x.core.sync2_identity(P, NOW).unwrap();
    let y = Device::copy_of(&x, "ch-settle-y");
    // 只收完各片、不收尾：通道停在追加阶段。
    let appended = |d: &Device| {
        let (heads, segs) = heads_and_segments(&all);
        cmd(d, json!({"op": "plan"}), heads);
        let begun = cmd(d, json!({"op": "ingest_begin"}), vec![]);
        for chunk in segs.chunks(2) {
            cmd(d, json!({"op": "ingest_prepare"}), chunk.to_vec());
            while cmd(
                d,
                json!({"op": "ingest_commit", "now": NOW, "sliceOps": 7}),
                vec![],
            )["more"]
                == json!(true)
            {}
        }
        begun
    };
    assert_eq!(
        appended(&x)["channel"],
        json!(true),
        "a fresh profile reports the channel to Dart"
    );
    assert_eq!(boot_state(&x), Some((0, 0)), "appending");
    // 第三片报错：前两片已提交，通道停在折叠里。
    super::channel::take_settle_slices();
    super::channel::fail_settle_at(Some(2));
    let err = cmd_err(&x, json!({"op": "channel_settle"}));
    super::channel::fail_settle_at(None);
    assert!(err.contains("injected settle failure"), "{err}");
    let (phase, cursor) = boot_state(&x).expect("the channel is still there");
    assert!(
        phase >= 1 && (phase, cursor) != (1, 0),
        "the committed slices stay done: ({phase}, {cursor})"
    );
    assert_eq!(
        cmd(&x, json!({"op": "identity", "now": NOW}), vec![])["channel"],
        json!(true),
        "Dart learns the channel at open"
    );
    // 接着做完（不从头来），之后写连接上没有挂着的事务。
    cmd(&x, json!({"op": "channel_settle"}), vec![]);
    assert!(boot_state(&x).is_none(), "settled");
    assert!(
        super::channel::take_settle_slices() > 3,
        "settling is sliced"
    );
    assert!(
        x.core.writer().unwrap().is_autocommit(),
        "every slice committed"
    );
    assert_eq!(
        cmd(&x, json!({"op": "identity", "now": NOW}), vec![])["channel"],
        json!(false)
    );
    let mut r = cmd(&x, json!({"op": "ingest_finish", "now": NOW}), vec![]);
    while r["more"] == json!(true) {
        r = cmd(&x, json!({"op": "replay_pending", "now": NOW}), vec![]);
    }
    super::channel::sequential(|| {
        appended(&y);
        let mut r = cmd(&y, json!({"op": "ingest_finish", "now": NOW}), vec![]);
        while r["more"] == json!(true) {
            r = cmd(&y, json!({"op": "replay_pending", "now": NOW}), vec![]);
        }
    });
    assert_same(&x, &y, "settled slice by slice after a failure");
    // 通道是在会话外做完的（没有哪条收段命令的回包带着这些变化）：修订号由 `settle` 的每一片自己推进。
    assert!(revision(&x) > 0, "settling advances the revision");
    assert!(revision(&y) > 0);
    digest_is_consistent(&x);
}

// ---------------------------------------------------------------- 通道自己做完的片交回 Dart

/// 只收完各片、不收尾：通道停在追加阶段。
fn appended(d: &Device, all: &Bucket) {
    let (heads, segs) = heads_and_segments(all);
    cmd(d, json!({"op": "plan"}), heads);
    cmd(d, json!({"op": "ingest_begin"}), vec![]);
    for chunk in segs.chunks(2) {
        cmd(d, json!({"op": "ingest_prepare"}), chunk.to_vec());
        while cmd(
            d,
            json!({"op": "ingest_commit", "now": NOW, "sliceOps": 7}),
            vec![],
        )["more"]
            == json!(true)
        {}
    }
    assert_eq!(boot_state(d), Some((0, 0)), "appending");
}

/// 进程内刷新键（store/refresh.rs）里 [k] 的计数（键形如 `<开库标识>:<计数>[:<视图计数>]`）。
fn key_count(keys: &Value, k: &str) -> i64 {
    keys[k]
        .as_str()
        .unwrap()
        .split(':')
        .nth(1)
        .unwrap()
        .parse()
        .unwrap()
}

/// 这个 profile 此刻的刷新键（`refresh_keys`，分发器开头的库级段）。
fn refresh_keys(d: &Device) -> Value {
    cmd(d, json!({"op": "refresh_keys"}), vec![])
}

/// 分发器在一条命令之前把通道做完（[super::channel::settle]）：那些片没有自己的回包，每片提交时由内核推进刷新键
/// （[crate::store::SrsCore::refresh_slice]）。`landed` 计数与库里的修订号同口径（每条落进投影的事件、每个可见性变了
/// 的实体各 +1），所以两者增量相等；中途出错时已提交的片已经记过。第 14 步及以前这些变化攒在内核里，要等这个
/// profile 下一条带 `settled: true` 的命令的回包交回 Dart；没有下一条命令时 Dart 按刷新信号记的缓存一直不失效。
#[test]
fn channel_slices_move_the_refresh_keys_as_they_commit() {
    let all = world(43);
    let x = Device::new("ch-handover-x");
    x.core.sync2_identity(P, NOW).unwrap();
    appended(&x, &all);
    // 收段会话放掉：之后通道的片推进 RWKV 刷新不再攒着。
    cmd(&x, json!({"op": "ingest_end"}), vec![]);
    let (rev0, k0) = (revision(&x), refresh_keys(&x));
    // 第三片报错：已提交的两片已经记过。
    super::channel::take_settle_slices();
    super::channel::fail_settle_at(Some(2));
    let err = cmd_err(&x, json!({"op": "channel_settle"}));
    super::channel::fail_settle_at(None);
    assert!(err.contains("injected settle failure"), "{err}");
    let k1 = refresh_keys(&x);
    let partial = revision(&x) - rev0;
    assert!(partial > 0, "two slices committed before the failure");
    assert_eq!(
        key_count(&k1, "landed") - key_count(&k0, "landed"),
        partial,
        "the landed key moves exactly as the persisted revision: {k0} -> {k1}"
    );
    assert_ne!(k1["content"], k0["content"]);
    assert_ne!(k1["structure"], k0["structure"]);
    assert_ne!(k1["stats"], k0["stats"]);
    assert_ne!(
        k1["rwkv"], k0["rwkv"],
        "peer events landed: the RWKV table is re-queried"
    );
    // 对通道透明的只读命令不动键。
    cmd(&x, json!({"op": "identity", "now": NOW}), vec![]);
    assert_eq!(refresh_keys(&x), k1);
    // 一条本机写入：分发器先把通道剩下的做完（每片记一次），再按这条命令自己的回包记一次。
    let input = json!([{"e": edit("note", &note_id(7), "f/fa", json!("typed mid-sync")), "note": note_id(7)}])
        .to_string();
    let wrote = cmd(
        &x,
        json!({"op": "apply", "now": NOW, "legacyDevice": "dev"}),
        vec![input.into_bytes()],
    );
    assert!(boot_state(&x).is_none(), "settled");
    assert!(
        wrote.get("settled").is_none(),
        "no hand-over any more: {wrote}"
    );
    let k2 = refresh_keys(&x);
    assert_eq!(
        key_count(&k2, "landed") - key_count(&k0, "landed"),
        revision(&x) - rev0,
        "slices + the command's own result, the same tally as the persisted revision"
    );
    assert!(
        revision_before_apply(&wrote) > rev0 + partial,
        "the rest of the channel settled before the command: {wrote}"
    );
}

/// `apply` 回包里这条命令自己推进之前的修订号：`localRevision` − 自己落的事件数 − 自己改了可见性的实体数。
fn revision_before_apply(reply: &Value) -> i64 {
    reply["localRevision"].as_i64().unwrap()
        - reply["marks"]["landed"].as_i64().unwrap()
        - reply["changed"].as_array().map_or(0, |a| a.len() as i64)
}

/// 另外几条会自己把通道做完的路径同样推进刷新键：会话外投递（`import`）、新会话开始时上一次的收尾没做完
/// （`ingest_begin`，channel.rs `begin`：RWKV 的推进从会话一开始就攒着，`ingest_end` 并成一次）、并入提交之前
/// （`profile_merge_commit`：提交没成、旧 uid 还在时）；整份删掉的 uid 一律作废。
#[test]
fn every_path_that_settles_the_channel_moves_the_refresh_keys() {
    let all = world(47);
    // 导入：分发器 / `local_write` 在导入之前做完通道。
    let source = Device::new("ch-handover-src");
    source.core.sync2_identity(P, NOW).unwrap();
    let deck = super::config::default_deck_id(P);
    local(&source, NOW, vec![(deck_entity(&deck), String::new())]);
    let exported = source.core.sync2_export(P).unwrap();
    let a = Device::new("ch-handover-import");
    a.core.sync2_identity(P, NOW).unwrap();
    appended(&a, &all);
    cmd(&a, json!({"op": "ingest_end"}), vec![]);
    let (rev0, k0) = (revision(&a), refresh_keys(&a));
    cmd(&a, json!({"op": "import", "now": NOW + 1}), vec![exported]);
    assert!(boot_state(&a).is_none());
    let k1 = refresh_keys(&a);
    assert!(revision(&a) > rev0);
    assert_eq!(
        key_count(&k1, "landed") - key_count(&k0, "landed"),
        revision(&a) - rev0,
        "{k0} -> {k1}"
    );
    assert_ne!(k1["rwkv"], k0["rwkv"]);

    // 收尾折到一半（App 在折叠途中被杀），新会话开始时先做完：会话里的 RWKV 推进攒到 `ingest_end` 才放出一次。
    let b = Device::new("ch-handover-begin");
    b.core.sync2_identity(P, NOW).unwrap();
    appended(&b, &all);
    let r = cmd(
        &b,
        json!({"op": "ingest_finish", "now": NOW, "sliceOps": 5}),
        vec![],
    );
    assert_eq!(r["more"], json!(true), "the fold is caught half-way: {r}");
    assert!(
        boot_state(&b).is_some_and(|(phase, _)| phase != 0),
        "folding"
    );
    cmd(&b, json!({"op": "ingest_end"}), vec![]);
    let k0 = refresh_keys(&b);
    cmd(&b, json!({"op": "ingest_begin"}), vec![]);
    assert!(
        boot_state(&b).is_none(),
        "the next session settles it first"
    );
    let k1 = refresh_keys(&b);
    assert!(
        key_count(&k1, "landed") > key_count(&k0, "landed"),
        "{k0} -> {k1}"
    );
    assert_eq!(k1["rwkv"], k0["rwkv"], "held for the session");
    cmd(&b, json!({"op": "ingest_end"}), vec![]);
    assert_eq!(
        key_count(&refresh_keys(&b), "rwkv"),
        key_count(&k0, "rwkv") + 1,
        "released as one"
    );

    // 并入提交：先把旧 uid 的通道做完再核对；核对没过（映射不全）旧 uid 还在，片照样记过。
    let c = Device::new("ch-handover-merge");
    c.core.sync2_identity(P, NOW).unwrap();
    appended(&c, &all);
    let k0 = refresh_keys(&c);
    let out = c
        .core
        .profile_merge_commit(P, "ch-handover-merge-target", b"{}", None)
        .unwrap();
    assert_eq!(out["done"], json!(false), "{out}");
    assert!(boot_state(&c).is_none(), "the commit settled the channel");
    let k1 = refresh_keys(&c);
    assert!(
        key_count(&k1, "landed") > key_count(&k0, "landed"),
        "{k0} -> {k1}"
    );
    // 整份删掉的 uid：键全部作废，开着的收段会话攒下的也放掉。
    let d = Device::new("ch-handover-purge");
    d.core.sync2_identity(P, NOW).unwrap();
    appended(&d, &all);
    cmd(&d, json!({"op": "channel_settle"}), vec![]);
    let k0 = refresh_keys(&d);
    d.core.profile_purge(P).unwrap();
    let k1 = refresh_keys(&d);
    for k in ["content", "structure", "rwkv", "stats", "landed"] {
        assert_ne!(k1[k], k0[k], "{k}");
    }
}

/// 失败的改投影命令按「可能提交了一部分」作废一次；`local_state` 带 `reload: true`（Dart 开库、命令失败后的重读）
/// 作废一次，不带的是纯读；读键本身不动键。键里的开库标识每次打开库都不同。
#[test]
fn failures_and_reloads_invalidate_and_reads_do_not() {
    let x = Device::new("refresh-failure");
    x.core.sync2_identity(P, NOW).unwrap();
    let k0 = refresh_keys(&x);
    assert_eq!(refresh_keys(&x), k0, "reading the keys does not move them");
    let err = cmd_err(
        &x,
        json!({"op": "apply", "now": NOW, "legacyDevice": "dev"}),
    );
    assert!(err.contains("missing input"), "{err}");
    let k1 = refresh_keys(&x);
    for k in ["content", "rwkv", "stats", "landed"] {
        assert_eq!(key_count(&k1, k), key_count(&k0, k) + 1, "{k}");
    }
    cmd(&x, json!({"op": "local_state"}), vec![]);
    assert_eq!(refresh_keys(&x), k1, "a plain read");
    cmd(&x, json!({"op": "local_state", "reload": true}), vec![]);
    let k2 = refresh_keys(&x);
    assert_eq!(key_count(&k2, "content"), key_count(&k1, "content") + 1);
    // 一条本机写入：落库的事件推进 `landed` 与内容键。
    let input =
        json!([{"e": edit("note", &note_id(3), "f/fa", json!("typed")), "note": note_id(3)}])
            .to_string();
    cmd(
        &x,
        json!({"op": "apply", "now": NOW, "legacyDevice": "dev"}),
        vec![input.into_bytes()],
    );
    let k3 = refresh_keys(&x);
    assert!(key_count(&k3, "landed") > key_count(&k2, "landed"));
    assert!(key_count(&k3, "content") > key_count(&k2, "content"));
    // 另一个库（另一次打开）的键不会与这一个相等。
    let y = Device::new("refresh-failure-other");
    y.core.sync2_identity(P, NOW).unwrap();
    assert_ne!(refresh_keys(&y)["content"], k0["content"]);
}
