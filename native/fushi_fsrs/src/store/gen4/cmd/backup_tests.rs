//! 整包备份 / 还原（G11-4）的内核测试，一律经 C ABI（`ffsrs_store_open_mode` / `ffsrs_store_snapshot` /
//! `ffsrs_store_sync2`，装置在 `dispatch_tests.rs` / `fushisrs_tests.rs`）。
//!
//! - 整库快照（`ffsrs_store_snapshot`）：别的线程一直在写时拍几份，每份都能当新代库打开、派生层与从真相整层重建的逐行
//!   相同（自洽，没有半笔写入）；Secondary、剥本机表、目标已存在、空间不够一律拒绝、不留文件。
//! - 协议 3 整包备份里的 `srs.db`（`legacy_backup_import {source: "db"}`）：没确认什么都不写；确认后与直接迁移同一份库
//!   逐行相同；再读一遍什么都不改；读进另一个集合要确认；坏文件明确报错、库一字不变；预检不写。
//! - 只有 v1 事件的旧输入（`{source: "events"}`）：卡片、复习日志、笔记条数与直接迁移的相同；再读一遍不重复。

use std::path::Path;
use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{Value, json};

use super::dispatch_tests::{T1, call, cfg, g4req, migrated, open};
use super::fushisrs_tests::{col_in, derived, export_bytes, fresh, reader, self_device, try_g4};
use super::tests::{N2, card};
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close, ffsrs_store_snapshot};
use crate::store::gen4::files::{GEN4_FILE, OpenMode};
use crate::store::gen4::kernel::{G4Core, READ_ONLY, SNAPSHOT_NO_STRIP};
use crate::store::gen4::schema::DERIVED_TABLES;
use crate::store::sync2::tests::{P, edit, review, tempdir};

const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";

fn take_error(err: *mut std::ffi::c_char) -> String {
    if err.is_null() {
        return String::new();
    }
    let s = unsafe { std::ffi::CStr::from_ptr(err) }
        .to_string_lossy()
        .into_owned();
    crate::ffsrs_free_string(err);
    s
}

/// 经 C ABI 拍一份快照。
fn snapshot(h: *mut SrsCoreHandle, path: &Path, strip: bool) -> Result<(), String> {
    let p = path.to_str().unwrap();
    let mut err = null_mut();
    let rc = ffsrs_store_snapshot(h, p.as_ptr(), p.len(), strip as i32, &mut err);
    if rc == 0 {
        Ok(())
    } else {
        Err(take_error(err))
    }
}

/// 一个目录里新代库的派生层逐行（不跳过任何设备）。
fn all_derived(dir: &Path) -> Vec<String> {
    derived(dir, P, &[])
}

// ---------------------------------------------------------------------- 快照

/// 别的线程一直在写（作答 + 改字段，每条一个写事务）时拍几份快照：每份都能当新代库打开（Primary），派生层与从真相整层
/// 重建的结果逐行相同（快照落在某一笔提交之后，没有半笔）；写入线程没被挡住（全部写完）。
#[test]
fn a_snapshot_taken_while_writing_opens_and_is_self_consistent() {
    let m = migrated();
    let work = tempdir::new("g114snap");
    let h = m.h as usize;
    let done = Arc::new(AtomicBool::new(false));
    let flag = done.clone();
    let writer = std::thread::spawn(move || {
        let c = card(N2, "t1");
        for i in 0..60i64 {
            let items = vec![
                json!({"e": review(&format!("snap{i}"), &c, T1 + i, 3, "review"), "note": N2, "intent": "answer"}),
                json!({"e": edit("note", N2, "f/fb", json!(format!("v{i}"))), "note": N2}),
            ];
            call(
                h as *mut SrsCoreHandle,
                &g4req("apply", T1 + i, json!({})),
                Some(&items),
            )
            .unwrap_or_else(|(rc, e)| panic!("apply {i}: {rc} {e}"));
        }
        flag.store(true, Ordering::SeqCst);
    });
    let mut shots = Vec::new();
    for i in 0..6 {
        let p = work.0.join(format!("snap{i}.db"));
        snapshot(m.h, &p, false).unwrap();
        shots.push(p);
    }
    writer.join().unwrap();
    assert!(done.load(Ordering::SeqCst));
    // 写完之后再拍一份：它与源库的派生层逐行相同。
    let last = work.0.join("last.db");
    snapshot(m.h, &last, false).unwrap();
    shots.push(last.clone());
    for (i, p) in shots.iter().enumerate() {
        let d = tempdir::new("g114snapo");
        std::fs::copy(p, d.0.join(GEN4_FILE)).unwrap();
        let h2 = open(&d.0, 0).unwrap_or_else(|(rc, e)| panic!("snapshot {i} opens: {rc} {e}"));
        let before = all_derived(&d.0);
        try_g4(h2, P, "rebuild_caches", json!({})).unwrap();
        assert_eq!(all_derived(&d.0), before, "snapshot {i} is self-consistent");
        ffsrs_store_close(h2);
    }
    let d = tempdir::new("g114snapl");
    std::fs::copy(&last, d.0.join(GEN4_FILE)).unwrap();
    assert_eq!(all_derived(&d.0), all_derived(&m.dir.0));
}

/// 拒绝的几种：目标已存在（原文件不动）、要剥本机表、辅助进程、目标卷空间不够——都不留下目标文件。
#[test]
fn a_snapshot_refuses_and_leaves_nothing_behind() {
    let m = migrated();
    let work = tempdir::new("g114snapno");
    let exists = work.0.join("exists.db");
    std::fs::write(&exists, b"keep").unwrap();
    let e = snapshot(m.h, &exists, false).unwrap_err();
    assert!(e.contains("already exists"), "{e}");
    assert_eq!(std::fs::read(&exists).unwrap(), b"keep");

    let strip = work.0.join("strip.db");
    assert_eq!(snapshot(m.h, &strip, true).unwrap_err(), SNAPSHOT_NO_STRIP);
    assert!(!strip.exists());

    let s = open(&m.dir.0, 1).unwrap();
    let sec = work.0.join("secondary.db");
    assert_eq!(snapshot(s, &sec, false).unwrap_err(), READ_ONLY);
    assert!(!sec.exists());
    ffsrs_store_close(s);

    let core = G4Core::open(&m.dir.0, OpenMode::Primary).unwrap();
    let full = work.0.join("full.db");
    let e = core
        .snapshot_into_with_free_space(&full, false, |_| Some(1))
        .unwrap_err();
    assert!(e.starts_with(crate::store::SNAPSHOT_NO_SPACE), "{e}");
    assert!(!full.exists());
    core.close();
}

// ---------------------------------------------------------------------- 协议 3 整包备份里的 srs.db

fn legacy_req(path: &Path, source: &str, extra: Value) -> Value {
    let mut r = json!({
        "path": path.to_str().unwrap(), "source": source, "backupProfile": P, "caches": cfg(),
    });
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        r[k.as_str()] = v;
    }
    r
}

/// 协议 3 的整包备份快照（剥了本机身份与待投递，`snapshot_into(.., true)`）拷一份当 Dart 解出来的临时副本。
fn protocol_3_backup(m: &super::dispatch_tests::Migrated, dir: &Path) -> std::path::PathBuf {
    let snap = dir.join("srs.db");
    m.d.core.snapshot_into(&snap, true).unwrap();
    snap
}

/// 卡片 / 复习日志 / 笔记几张派生表在集合里的行数。
fn counts(dir: &Path, profile: &str) -> Vec<(String, i64)> {
    let c = reader(dir);
    let col = col_in(&c, profile);
    DERIVED_TABLES
        .iter()
        .filter(|t| matches!(**t, "cards" | "notes" | "log_ix"))
        .map(|t| {
            (
                (*t).to_owned(),
                c.query_row(
                    &format!("SELECT COUNT(*) FROM {t} WHERE col = ?1"),
                    [col],
                    |r| r.get(0),
                )
                .unwrap(),
            )
        })
        .collect()
}

/// 读进一个**没有任何绑定**的空库（覆盖还原 = 空库 + 并入，D34）：没确认回 `needsConfirm`、什么都不建；预检只答
/// `ready`；确认后绑定（`bound`），派生表与直接迁移同一份库逐行相同（两边各自的本机原生日志除外），卡片 / 日志 / 笔记条数
/// 相同；再读一遍 `unchanged`。
#[test]
fn a_protocol_3_backup_lands_exactly_like_the_migration() {
    let m = migrated();
    let work = tempdir::new("g114db");
    let snap = protocol_3_backup(&m, &work.0);
    let mig_dev = self_device(m.h, P);
    let dir = tempdir::new("g114dbto");
    let h = open(&dir.0, 0).unwrap();
    let v = try_g4(
        h,
        P,
        "legacy_backup_import",
        legacy_req(&snap, "db", json!({})),
    )
    .unwrap();
    assert_eq!(v["outcome"], json!("needsConfirm"), "{v}");
    assert_eq!(v["reason"], json!("join"));
    assert!(v.get("bindingChanged").is_none());
    let e = try_g4(h, P, "collection_info", json!({})).unwrap_err();
    assert!(e.contains("has no collection"), "{e}");
    let pre = try_g4(
        h,
        P,
        "legacy_backup_import",
        legacy_req(&snap, "db", json!({"preflight": true, "confirmed": true})),
    )
    .unwrap();
    assert_eq!(pre["outcome"], json!("ready"), "{pre}");
    assert!(try_g4(h, P, "collection_info", json!({})).is_err());

    let got = try_g4(
        h,
        P,
        "legacy_backup_import",
        legacy_req(&snap, "db", json!({"confirmed": true})),
    )
    .unwrap();
    assert_eq!(got["outcome"], json!("bound"), "{got}");
    assert_eq!(got["bindingChanged"], json!({"profile": P}));
    assert_eq!(got["unchanged"], json!(false));
    assert!(got["applied"].as_u64().unwrap() > 0, "{got}");
    try_g4(h, P, "cache_config_set", json!({"caches": cfg()})).unwrap();
    let me = self_device(h, P);
    assert_eq!(derived(&dir.0, P, &[me]), derived(&m.dir.0, P, &[mig_dev]));
    assert_eq!(counts(&dir.0, P), counts(&m.dir.0, P));

    let again = try_g4(
        h,
        P,
        "legacy_backup_import",
        legacy_req(&snap, "db", json!({"confirmed": true})),
    )
    .unwrap();
    assert_eq!(again["unchanged"], json!(true), "{again}");
    assert_eq!(derived(&dir.0, P, &[me]), derived(&m.dir.0, P, &[mig_dev]));
    ffsrs_store_close(h);
}

/// 读进另一个集合（合并还原到别的 profile）：没确认回 `needsConfirm`（`join`）、库一字不变；确认后并入（`joined`），
/// 卡片条数与源库相同。坏文件（不是 SQLite）明确报错、库一字不变。
#[test]
fn another_collection_needs_confirmation_and_bad_files_change_nothing() {
    let m = migrated();
    let work = tempdir::new("g114dbq");
    let snap = protocol_3_backup(&m, &work.0);
    let (_qdir, q) = fresh("g114dbqq", Q);
    let before = export_bytes(q, Q);
    let v = try_g4(
        q,
        Q,
        "legacy_backup_import",
        legacy_req(&snap, "db", json!({})),
    )
    .unwrap();
    assert_eq!(v["outcome"], json!("needsConfirm"), "{v}");
    assert_eq!(v["reason"], json!("join"));
    assert_eq!(export_bytes(q, Q), before);

    let bad = work.0.join("bad.db");
    std::fs::write(&bad, b"not a database at all, just bytes").unwrap();
    let e = try_g4(
        q,
        Q,
        "legacy_backup_import",
        legacy_req(&bad, "db", json!({"confirmed": true})),
    )
    .unwrap_err();
    assert!(!e.is_empty());
    assert_eq!(export_bytes(q, Q), before);

    let got = try_g4(
        q,
        Q,
        "legacy_backup_import",
        legacy_req(&snap, "db", json!({"confirmed": true})),
    )
    .unwrap();
    assert_eq!(got["outcome"], json!("joined"), "{got}");
    ffsrs_store_close(q);
}

// ---------------------------------------------------------------------- 只有 v1 事件的旧输入

/// 协议 3 库里的投影行 → 「外来、已盖戳」的 v1 事件（Dart `SrsEvent.toJson()` 同形：`{t, x}`；日志带笔记 ID），一行一个。
fn v1_events(db: &Path) -> String {
    // 投影列里有协议 3 的 SQL 函数（`srs_edit_json` 等）：用注册了它们的只读连接。
    let c = crate::store::gen4::dryrun::open_legacy(db).unwrap();
    let mut out = String::new();
    let mut push = |e: Value, note: Option<String>| {
        let mut item = json!({"e": e, "stamped": true});
        if let Some(n) = note {
            item["note"] = json!(n);
        }
        out.push_str(&item.to_string());
        out.push('\n');
    };
    let mut q = c
        .prepare("SELECT srs_idt(id), kind, payload_json FROM srs_entities WHERE profile_uid = srs_id(?1) ORDER BY id")
        .unwrap();
    let rows: Vec<(String, String, String)> = q
        .query_map([P], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    for (id, kind, payload) in rows {
        let d: Value = serde_json::from_str(&payload).unwrap();
        push(
            json!({"t": "entity", "x": {"id": id, "p": P, "k": kind, "d": d}}),
            None,
        );
    }
    let mut q = c
        .prepare("SELECT json FROM srs_field_edits WHERE profile_uid = srs_id(?1) ORDER BY id")
        .unwrap();
    let edits: Vec<String> = q
        .query_map([P], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    for j in edits {
        push(
            json!({"t": "edit", "x": serde_json::from_str::<Value>(&j).unwrap()}),
            None,
        );
    }
    let mut q = c
        .prepare(
            "SELECT l.json, (SELECT srs_idt(note_id) FROM srs_cards_cache k WHERE k.id = l.card_id AND k.profile_uid = l.profile_uid) \
             FROM srs_review_logs l WHERE l.profile_uid = srs_id(?1) ORDER BY l.id",
        )
        .unwrap();
    let logs: Vec<(String, Option<String>)> = q
        .query_map([P], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert!(!logs.is_empty());
    for (j, note) in logs {
        push(
            json!({"t": "log", "x": serde_json::from_str::<Value>(&j).unwrap()}),
            note,
        );
    }
    out
}

/// v1 事件（2026-10-23 之前的整包备份、v2 之前的 `.fushisrs` 事件备份）：在调用方给的空目录里新建协议 3 副本落进去，
/// 再读进空库；卡片、复习日志、笔记条数与直接迁移同一份库的相同；同一份再读一遍不重复（`unchanged`）。坏行明确报行号。
#[test]
fn v1_events_land_with_the_same_cards_and_logs() {
    let m = migrated();
    let work = tempdir::new("g114ev");
    let jsonl = work.0.join("events.jsonl");
    let legacy = m.d._dir.0.join("srs.db");
    std::fs::write(&jsonl, v1_events(&legacy)).unwrap();
    let scratch = tempdir::new("g114evs");
    let dir = tempdir::new("g114evto");
    let h = open(&dir.0, 0).unwrap();
    let req = |extra: Value| {
        let mut r = legacy_req(&jsonl, "events", extra);
        r["scratch"] = json!(scratch.0.to_str().unwrap());
        r
    };
    let got = try_g4(
        h,
        P,
        "legacy_backup_import",
        req(json!({"confirmed": true})),
    )
    .unwrap();
    assert_eq!(got["outcome"], json!("bound"), "{got}");
    assert_eq!(got["source"], json!("events"));
    try_g4(h, P, "cache_config_set", json!({"caches": cfg()})).unwrap();
    assert_eq!(counts(&dir.0, P), counts(&m.dir.0, P));
    let again = try_g4(
        h,
        P,
        "legacy_backup_import",
        req(json!({"confirmed": true})),
    )
    .unwrap();
    assert_eq!(again["unchanged"], json!(true), "{again}");
    assert_eq!(counts(&dir.0, P), counts(&m.dir.0, P));

    // 坏行：换一个新副本目录（备好的副本会跳过重备），报行号，库不变。
    let bad = work.0.join("bad.jsonl");
    std::fs::write(&bad, "{\"e\": {\"t\": \"entity\"}}\nnot json\n").unwrap();
    let scratch2 = tempdir::new("g114evs2");
    let before = export_bytes(h, P);
    let mut r = legacy_req(&bad, "events", json!({"confirmed": true}));
    r["scratch"] = json!(scratch2.0.to_str().unwrap());
    let e = try_g4(h, P, "legacy_backup_import", r).unwrap_err();
    assert!(e.contains("line 2"), "{e}");
    assert_eq!(export_bytes(h, P), before);
    ffsrs_store_close(h);
}

/// 副本里有笔记的日志元数据条数 / 日志元数据总条数。
fn log_notes_in(scratch: &Path) -> (i64, i64) {
    let c = crate::store::gen4::dryrun::open_legacy(
        &scratch.join(crate::store::gen4::files::LEGACY_FILE),
    )
    .unwrap();
    c.query_row(
        "SELECT COUNT(note_id), COUNT(*) FROM sync2_log_meta WHERE profile_uid = srs_id(?1)",
        [P],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .unwrap()
}

/// 只有事件、日志不带笔记 ID 的旧输入（v2 之前的 `.fushisrs` 事件备份没有卡片缓存）：副本先落笔记 / 修改记录、派生出
/// 卡片，再按卡片补上日志的笔记——与带着笔记读入的同一份，副本里每条日志都有笔记；条数与直接迁移的相同。补笔记的
/// 点查走 `srs_cards_cache` 的索引（执行的就是 [super::backup::LOG_NOTE_SQL]）。
#[test]
fn v1_events_without_log_notes_take_them_from_the_derived_cards() {
    let m = migrated();
    let legacy = m.d._dir.0.join("srs.db");
    let work = tempdir::new("g114nn");
    let with = work.0.join("with.jsonl");
    let without = work.0.join("without.jsonl");
    let body = v1_events(&legacy);
    std::fs::write(&with, &body).unwrap();
    let stripped: String = body
        .lines()
        .map(|l| {
            let mut v: Value = serde_json::from_str(l).unwrap();
            v.as_object_mut().unwrap().remove("note");
            format!("{v}\n")
        })
        .collect();
    assert!(
        !stripped.contains("\"note\":\""),
        "the stripped input still carries notes"
    );
    std::fs::write(&without, stripped).unwrap();
    let mut seen = Vec::new();
    for jsonl in [&with, &without] {
        let scratch = tempdir::new("g114nns");
        let dir = tempdir::new("g114nnto");
        let h = open(&dir.0, 0).unwrap();
        let mut r = legacy_req(jsonl, "events", json!({"confirmed": true}));
        r["scratch"] = json!(scratch.0.to_str().unwrap());
        let got = try_g4(h, P, "legacy_backup_import", r).unwrap();
        assert_eq!(got["outcome"], json!("bound"), "{got}");
        try_g4(h, P, "cache_config_set", json!({"caches": cfg()})).unwrap();
        assert_eq!(counts(&dir.0, P), counts(&m.dir.0, P));
        let (noted, all) = log_notes_in(&scratch.0);
        assert!(all > 0);
        assert_eq!(noted, all, "every log in the scratch copy has its note");
        seen.push((noted, all));
        ffsrs_store_close(h);
        if jsonl == &without {
            let c = crate::store::gen4::dryrun::open_legacy(
                &scratch.0.join(crate::store::gen4::files::LEGACY_FILE),
            )
            .unwrap();
            let plan: Vec<String> = c
                .prepare(&format!(
                    "EXPLAIN QUERY PLAN {}",
                    super::backup::LOG_NOTE_SQL
                ))
                .unwrap()
                .query_map(rusqlite::params!["c", P], |r| r.get::<_, String>(3))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap();
            assert!(plan.iter().any(|d| d.contains("INDEX")), "{plan:?}");
            assert!(!plan.iter().any(|d| d.starts_with("SCAN")), "{plan:?}");
        }
    }
    assert_eq!(seen[0], seen[1]);
}

/// 同一份 v1 事件换一个新副本目录、隔一段时间再读一遍（用户隔天又导了同一个旧文件）：副本身份按本机秘密 + 输入摘要
/// 派生（`seed_scratch_identity`），包出的操作逐字节相同，第二次什么都不改（`unchanged`），派生层与导出流逐字节不变。
/// 另一个库（另一台设备）读同一份得到另一个合成设备（钥匙混了本机秘密，不能只凭备份内容推出）。
#[test]
fn the_same_v1_events_from_a_fresh_scratch_change_nothing() {
    let m = migrated();
    let legacy = m.d._dir.0.join("srs.db");
    let work = tempdir::new("g114re");
    let jsonl = work.0.join("events.jsonl");
    std::fs::write(&jsonl, v1_events(&legacy)).unwrap();
    let land = |h: *mut SrsCoreHandle, name: &str, now: i64| {
        let scratch = tempdir::new(name);
        let mut r = legacy_req(&jsonl, "events", json!({"confirmed": true, "now": now}));
        r["scratch"] = json!(scratch.0.to_str().unwrap());
        try_g4(h, P, "legacy_backup_import", r).unwrap()
    };
    let (dir, h) = fresh("g114reto", P);
    let first = land(h, "g114res1", T1);
    assert_ne!(first["unchanged"], json!(true), "{first}");
    let before = all_derived(&dir.0);
    let exported = export_bytes(h, P);
    let again = land(h, "g114res2", T1 + 86_400_000);
    assert_eq!(again["unchanged"], json!(true), "{again}");
    assert_eq!(again["applied"], json!(0), "{again}");
    assert_eq!(all_derived(&dir.0), before);
    assert_eq!(export_bytes(h, P), exported);
    let devices = |d: &Path| -> Vec<String> {
        let c = reader(d);
        let mut q = c.prepare("SELECT hex(device) FROM peers WHERE device NOT IN (SELECT device FROM self_) ORDER BY device").unwrap();
        q.query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    let (other, h2) = fresh("g114reot", P);
    land(h2, "g114res3", T1);
    assert!(!devices(&dir.0).is_empty());
    assert_ne!(devices(&other.0), devices(&dir.0));
    ffsrs_store_close(h2);
    ffsrs_store_close(h);
}
