//! 整包备份 / 还原（G11-4）的内核测试，一律经 C ABI（`ffsrs_store_open_mode` / `ffsrs_store_snapshot` /
//! `ffsrs_store_sync2`，装置在 `dispatch_tests.rs` / `fushisrs_tests.rs`）。
//!
//! - 整库快照（`ffsrs_store_snapshot`）：别的线程一直在写时拍几份，每份都能当新代库打开、派生层与从真相整层重建的逐行
//!   相同（自洽，没有半笔写入）；Secondary、剥本机表、目标已存在、空间不够一律拒绝、不留文件。
//! - 协议 3 整包备份里的 `srs.db`（`legacy_backup_import {source: "db"}`）：没确认什么都不写；确认后与直接迁移同一份库
//!   逐行相同；再读一遍什么都不改；读进另一个集合要确认；坏文件明确报错、库一字不变；预检不写。
//! - 只有 v1 事件的旧输入（`{source: "events"}`）：卡片、复习日志、笔记条数与直接迁移的相同；再读一遍不重复。
//! - 身份确认闸门：同一个集合的旧备份带来新盐 / 本机没记过的设备公钥，不确认回 `needsConfirm`（`identity`）、什么都不写。
//! - 预检核对副本备没备好：备完仍不满足前提（开着的新设备收段通道）时预检报错，不答 `ready`。
//! - 不可信输入：输入文件只读不改；输入自带的「已备好」标记不让命令跳过备副本；`scratch` 有别的文件、与库目录相交一律拒绝。

use std::path::Path;
use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{Value, json};

use super::dispatch_tests::{T1, call, cfg, g4req, migrated, open};
use super::fushisrs_tests::{
    col_in, derived, export_bytes, fresh, peer_lines, reader, self_device, try_g4,
};
use super::tests::{N2, card};
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close, ffsrs_store_snapshot};
use crate::store::gen4::files::{GEN4_FILE, OpenMode};
use crate::store::gen4::kernel::{G4Core, READ_ONLY, SNAPSHOT_NO_STRIP};
use crate::store::gen4::schema::DERIVED_TABLES;
use crate::store::sync2::tests::{P, edit, review, tempdir};
use crate::sync2::id::Id;

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

fn legacy_req(path: &Path, source: &str, scratch: &Path, extra: Value) -> Value {
    let mut r = json!({
        "path": path.to_str().unwrap(), "source": source, "backupProfile": P, "caches": cfg(),
        "scratch": scratch.to_str().unwrap(),
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
    let sc = tempdir::new("g114dbsc");
    let mig_dev = self_device(m.h, P);
    let dir = tempdir::new("g114dbto");
    let h = open(&dir.0, 0).unwrap();
    let v = try_g4(
        h,
        P,
        "legacy_backup_import",
        legacy_req(&snap, "db", &sc.0, json!({})),
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
        legacy_req(
            &snap,
            "db",
            &sc.0,
            json!({"preflight": true, "confirmed": true}),
        ),
    )
    .unwrap();
    assert_eq!(pre["outcome"], json!("ready"), "{pre}");
    assert!(try_g4(h, P, "collection_info", json!({})).is_err());

    let got = try_g4(
        h,
        P,
        "legacy_backup_import",
        legacy_req(&snap, "db", &sc.0, json!({"confirmed": true})),
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
        legacy_req(&snap, "db", &sc.0, json!({"confirmed": true})),
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
    let sc = tempdir::new("g114dbqsc");
    let (_qdir, q) = fresh("g114dbqq", Q);
    let before = export_bytes(q, Q);
    let v = try_g4(
        q,
        Q,
        "legacy_backup_import",
        legacy_req(&snap, "db", &sc.0, json!({})),
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
        legacy_req(&bad, "db", &sc.0, json!({"confirmed": true})),
    )
    .unwrap_err();
    assert!(!e.is_empty());
    assert_eq!(export_bytes(q, Q), before);

    let got = try_g4(
        q,
        Q,
        "legacy_backup_import",
        legacy_req(&snap, "db", &sc.0, json!({"confirmed": true})),
    )
    .unwrap();
    // Q 是全新 profile、集合是空集合：G9-5「空集合可换绑」之后确认即换绑到对方（`bound`），不再写 Join。
    assert_eq!(got["outcome"], json!("bound"), "{got}");
    // 换绑后在对方集合里重建的本机身份沿用原来的钥匙种子（`PendingSelf::carrying`）：副本身份是按它派生的，换个新副本
    // 目录再读同一份输入全是已有的槽（没有一条以另一个合成设备再落；这一次的结论是 `saltsAdded`，见交接 §37）。
    let sc2 = tempdir::new("g114dbqsc2");
    let again = try_g4(
        q,
        Q,
        "legacy_backup_import",
        legacy_req(&snap, "db", &sc2.0, json!({"confirmed": true})),
    )
    .unwrap();
    assert_eq!(again["applied"], json!(0), "{again}");
    assert_eq!(again["counts"]["inserted"], json!(0), "{again}");
    assert_eq!(
        again["counts"]["same"], again["counts"]["applied"],
        "{again}"
    );
    ffsrs_store_close(q);
}

/// 覆盖还原到一个**已经打开过**的全新 profile（R0 Windows 实测 e1-replace：v3.3.0 整包备份在新版本上覆盖恢复，本机
/// profile uid 与备份里的不同、本机集合是空集合）：确认后换绑（`bound`），备份那个 profile 的盐（`legacy::salts` 的
/// uid）必须进新集合的盐集合，卡片 / 笔记 / 复习日志与直接迁移同一份库逐行相同。缺这个盐时带 profile 盐的内置实体 ID
/// 归不到规范 ID：卡片按不带盐的模板重新派生，与日志、别名表对不上，全部隐藏、界面 0 张（`identity::AdoptOutcome::Bound`
/// 以前只带换绑丢掉的本机盐，备份的盐被丢掉）。
#[test]
fn a_protocol_3_backup_replacing_a_fresh_profile_keeps_its_salts_and_cards() {
    let m = migrated();
    let work = tempdir::new("g114rp");
    let snap = protocol_3_backup(&m, &work.0);
    let sc = tempdir::new("g114rpsc");
    let (qdir, q) = fresh("g114rpq", Q);
    let got = try_g4(
        q,
        Q,
        "legacy_backup_import",
        legacy_req(&snap, "db", &sc.0, json!({"confirmed": true})),
    )
    .unwrap();
    assert_eq!(got["outcome"], json!("bound"), "{got}");
    let info = try_g4(q, Q, "collection_info", json!({})).unwrap();
    let salts = info["salts"].as_array().unwrap();
    assert!(salts.contains(&json!(P)), "{info}");
    assert!(salts.contains(&json!(Q)), "{info}");
    let pick = |dir: &Path, profile: &str, skip: &[Id]| -> Vec<String> {
        derived(dir, profile, skip)
            .into_iter()
            .filter(|l| {
                ["cards ", "notes ", "log_ix "]
                    .iter()
                    .any(|t| l.starts_with(t))
            })
            .collect()
    };
    let me = self_device(q, Q);
    let mig_dev = self_device(m.h, P);
    let want = pick(&m.dir.0, P, &[mig_dev]);
    assert!(want.iter().any(|l| l.starts_with("log_ix ")), "{want:?}");
    assert_eq!(pick(&qdir.0, Q, &[me]), want);
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
    let req = |extra: Value| legacy_req(&jsonl, "events", &scratch.0, extra);
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

    // 坏行（同一个副本目录也行：标记带输入摘要，换了输入就整份重备）：报行号，库不变。
    let bad = work.0.join("bad.jsonl");
    std::fs::write(&bad, "{\"e\": {\"t\": \"entity\"}}\nnot json\n").unwrap();
    let before = export_bytes(h, P);
    let r = legacy_req(&bad, "events", &scratch.0, json!({"confirmed": true}));
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
        let r = legacy_req(jsonl, "events", &scratch.0, json!({"confirmed": true}));
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
        let r = legacy_req(
            &jsonl,
            "events",
            &scratch.0,
            json!({"confirmed": true, "now": now}),
        );
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

/// 覆盖还原之后的第一次合并（第五波 G9 身份收尾，交接 §25「没做」）：同一份 v1 事件读进一个**没有任何绑定**的空库
/// （覆盖还原 = 空库 + 并入），先没确认（`needsConfirm`）、再确认（`bound`），之后换一个新副本目录隔天再读一遍：全是
/// 已有的槽（`unchanged`）。以前 profile 没绑定时副本身份只能随机、本机身份在落库事务里另随机生成，第二次读入以另一个
/// 合成设备再落一遍；现在落库前先定好本机身份（`PendingSelf`），副本身份从它派生。
#[test]
fn the_first_merge_after_landing_into_an_unbound_profile_changes_nothing() {
    let m = migrated();
    let legacy = m.d._dir.0.join("srs.db");
    let work = tempdir::new("g9n7ev");
    let jsonl = work.0.join("events.jsonl");
    std::fs::write(&jsonl, v1_events(&legacy)).unwrap();
    let land = |h: *mut SrsCoreHandle, scratch: &Path, confirmed: bool, now: i64| {
        let r = legacy_req(
            &jsonl,
            "events",
            scratch,
            json!({"confirmed": confirmed, "now": now}),
        );
        try_g4(h, P, "legacy_backup_import", r).unwrap()
    };
    let dir = tempdir::new("g9n7to");
    let h = open(&dir.0, 0).unwrap();
    let s1 = tempdir::new("g9n7s1");
    let ask = land(h, &s1.0, false, T1);
    assert_eq!(ask["outcome"], json!("needsConfirm"), "{ask}");
    let first = land(h, &s1.0, true, T1);
    assert_eq!(first["outcome"], json!("bound"), "{first}");
    assert_ne!(first["unchanged"], json!(true), "{first}");
    try_g4(h, P, "cache_config_set", json!({"caches": cfg()})).unwrap();
    let before = all_derived(&dir.0);
    let exported = export_bytes(h, P);
    let s2 = tempdir::new("g9n7s2");
    let again = land(h, &s2.0, true, T1 + 86_400_000);
    assert_eq!(again["unchanged"], json!(true), "{again}");
    assert_eq!(again["applied"], json!(0), "{again}");
    assert_eq!(all_derived(&dir.0), before);
    assert_eq!(export_bytes(h, P), exported);
    ffsrs_store_close(h);
}

/// 读快照定好本机秘密（profile 没绑定 → 预先生成的身份）、备好副本之后，落库之前 profile 被别的命令绑定并建了本机身份
/// （打开 profile 的 `identity`）：落库那一笔核对出本机秘密已经不是备副本用的那个，整条命令失败、什么都不留
/// （`LOCAL_IDENTITY_MOVED`）。重发按新的秘密重备、落下；之后换新副本目录再读同一份输入全是已有的槽。没有这道核对时副本
/// 身份按预先生成的秘密派生、实际本机秘密却是并发建的那个，第三次读入会以另一个合成设备再落一遍。
#[test]
fn a_local_identity_created_while_the_copy_is_prepared_fails_the_landing() {
    let m = migrated();
    let legacy = m.d._dir.0.join("srs.db");
    let work = tempdir::new("g9idmv");
    let jsonl = work.0.join("events.jsonl");
    std::fs::write(&jsonl, v1_events(&legacy)).unwrap();
    let dir = tempdir::new("g9idmvto");
    let core = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
    let req = |scratch: &Path, now: i64| {
        let mut r = legacy_req(
            &jsonl,
            "events",
            scratch,
            json!({"confirmed": true, "now": now}),
        );
        r["profile"] = json!(P);
        r
    };
    let s1 = tempdir::new("g9idmvs1");
    let e = crate::store::gen4::dispatch::legacy_backup_import(&core, P, &req(&s1.0, T1), &|c| {
        c.write(|t| super::identity::identity_ensure(t, P, T1))
            .map(|_| ())
    })
    .unwrap_err();
    assert_eq!(e, super::backup::LOCAL_IDENTITY_MOVED);
    let none = |_: &G4Core| Ok(());
    let landed =
        crate::store::gen4::dispatch::legacy_backup_import(&core, P, &req(&s1.0, T1), &none)
            .unwrap();
    assert_ne!(landed["unchanged"], json!(true), "{landed}");
    let s2 = tempdir::new("g9idmvs2");
    let again = crate::store::gen4::dispatch::legacy_backup_import(
        &core,
        P,
        &req(&s2.0, T1 + 86_400_000),
        &none,
    )
    .unwrap();
    assert_eq!(again["applied"], json!(0), "{again}");
    assert_eq!(again["unchanged"], json!(true), "{again}");
}

// ---------------------------------------------------------------------- 身份确认 / 预检 / 不可信输入

/// [src] 的一份拷贝，拷完在它上面跑 [edit]（注册了 ID 编码函数的连接）。
fn tampered(src: &Path, to: &Path, edit: impl FnOnce(&rusqlite::Connection)) -> std::path::PathBuf {
    std::fs::copy(src, to).unwrap();
    let c = rusqlite::Connection::open(to).unwrap();
    crate::store::ids::register(&c).unwrap();
    edit(&c);
    drop(c);
    to.to_path_buf()
}

/// 本机 profile 已经绑在这个集合上（迁移来的库，`collection_of(P)`）：同一个集合的旧备份
///
/// - 只带本机已知的盐与设备：不用确认；
/// - 多一个退役的旧 uid（新盐）：不确认回 `needsConfirm`（`identity`）、`newSalts` 就是它，预检同样；导出流与 `peers`
///   逐字节不变；确认后落库，盐记进绑定；
/// - 多一台本机没记过公钥的设备：同上，`newPeers` 是它；确认后 `peers` 里有它。
#[test]
fn a_legacy_backup_bringing_a_new_identity_needs_confirmation() {
    let m = migrated();
    let work = tempdir::new("g114id");
    let snap = protocol_3_backup(&m, &work.0);
    let sc = tempdir::new("g114idsc");
    let plain = try_g4(
        m.h,
        P,
        "legacy_backup_import",
        legacy_req(&snap, "db", &sc.0, json!({})),
    )
    .unwrap();
    assert_ne!(plain["outcome"], json!("needsConfirm"), "{plain}");

    const OLD: &str = "0193a1b2-0000-7000-8000-00000000dead";
    let salted = tampered(&snap, &work.0.join("salted.db"), |c| {
        c.execute(
            "INSERT OR REPLACE INTO srs_meta (key, value) VALUES ('srs_retired_profile_uids', ?1)",
            [json!([OLD]).to_string()],
        )
        .unwrap();
    });
    let device = Id([0x5au8; 16]);
    let public = crate::sync2::keys::DeviceKey::from_seed(&[7u8; 32]).public();
    let with_device = tampered(&snap, &work.0.join("device.db"), |c| {
        c.execute(
            "INSERT INTO sync2_devices (profile_uid, device, public, applied, chain) \
             VALUES (srs_id(?1), ?2, ?3, 0, NULL)",
            rusqlite::params![P, device.0.to_vec(), public.to_vec()],
        )
        .unwrap();
    });
    for (file, salts, peers) in [
        (&salted, json!([OLD]), json!([])),
        (&with_device, json!([]), json!([device.text()])),
    ] {
        let sc = tempdir::new("g114idsc2");
        let before = (export_bytes(m.h, P), peer_lines(&m.dir.0, P));
        for extra in [json!({"preflight": true}), json!({})] {
            let v = try_g4(
                m.h,
                P,
                "legacy_backup_import",
                legacy_req(file, "db", &sc.0, extra),
            )
            .unwrap();
            assert_eq!(v["outcome"], json!("needsConfirm"), "{v}");
            assert_eq!(v["reason"], json!("identity"), "{v}");
            assert_eq!(v["newSalts"], salts, "{v}");
            assert_eq!(v["newPeers"], peers, "{v}");
            assert!(v.get("bindingChanged").is_none());
            assert_eq!((export_bytes(m.h, P), peer_lines(&m.dir.0, P)), before);
        }
        let got = try_g4(
            m.h,
            P,
            "legacy_backup_import",
            legacy_req(file, "db", &sc.0, json!({"confirmed": true})),
        )
        .unwrap();
        assert_ne!(got["outcome"], json!("needsConfirm"), "{got}");
    }
    let info = try_g4(m.h, P, "collection_info", json!({})).unwrap();
    assert!(
        info["salts"].as_array().unwrap().contains(&json!(OLD)),
        "{info}"
    );
    let hex: String = device.0.iter().map(|b| format!("{b:02X}")).collect();
    assert!(
        peer_lines(&m.dir.0, P).iter().any(|l| l.starts_with(&hex)),
        "the confirmed device is a peer now"
    );
}

/// 预检核对副本备没备好（与 [import_backup] 开头同一处）：副本按这份输入备好、标记有效（之后的调用跳过备副本），之后
/// 副本又被改得不满足前提（这里开一条新设备收段通道）——预检报「没备好」，不先答 `ready`；真导入同样报错；库一字不变。
#[test]
fn preflight_reports_a_backup_library_that_is_not_ready() {
    let m = migrated();
    let work = tempdir::new("g114nr");
    let snap = protocol_3_backup(&m, &work.0);
    let (dir, h) = fresh("g114nrto", P);
    let sc = tempdir::new("g114nrsc");
    let pre = try_g4(
        h,
        P,
        "legacy_backup_import",
        legacy_req(
            &snap,
            "db",
            &sc.0,
            json!({"preflight": true, "confirmed": true}),
        ),
    )
    .unwrap();
    assert_eq!(pre["outcome"], json!("ready"), "{pre}");
    {
        let c =
            rusqlite::Connection::open(sc.0.join(crate::store::gen4::files::LEGACY_FILE)).unwrap();
        crate::store::ids::register(&c).unwrap();
        c.execute(
            "INSERT INTO sync2_boot (profile_uid, phase, next_rank, cursor) VALUES (srs_id(?1), 1, 0, 0)",
            [P],
        )
        .unwrap();
    }
    let before = (export_bytes(h, P), all_derived(&dir.0));
    for extra in [
        json!({"preflight": true, "confirmed": true}),
        json!({"preflight": true}),
        json!({"confirmed": true}),
    ] {
        let e = try_g4(
            h,
            P,
            "legacy_backup_import",
            legacy_req(&snap, "db", &sc.0, extra.clone()),
        )
        .unwrap_err();
        assert!(e.contains("not ready"), "{extra}: {e}");
        assert!(e.contains("ingest channel"), "{extra}: {e}");
        assert_eq!((export_bytes(h, P), all_derived(&dir.0)), before);
    }
    ffsrs_store_close(h);
}

/// 不可信的输入文件：
///
/// - 命令只读不改它（拷进 `scratch` 再备）：同一份文件隔天再导（新的 `scratch`、另一个 `now`）摘要相同、副本身份相同，
///   什么都不改；同一份备份里的几个 profile 也就各自拿到同一个摘要。
/// - 它自带的「已备好」标记（旧口径 = profile 名；新口径 = 写标记之前那份文件的摘要）都不让命令跳过备副本：这份文件的
///   旧行标成还没迁移（`migrated_at` 为空），不备就过不了前提核对，跳过了就会报「没备好」。第一次拷进 `scratch` 之前不读
///   标记；要防的是上一次拷完没备完就断了、`scratch` 里留着与输入逐字节相同的拷贝（带着它自带的标记）的情形。
#[test]
fn the_input_file_is_read_only_and_its_own_prepared_marker_is_ignored() {
    let m = migrated();
    let work = tempdir::new("g114ro");
    let snap = protocol_3_backup(&m, &work.0);
    let original = std::fs::read(&snap).unwrap();
    let (dir, h) = fresh("g114roto", P);
    let land = |file: &Path, now: i64| {
        let sc = tempdir::new("g114rosc");
        try_g4(
            h,
            P,
            "legacy_backup_import",
            legacy_req(file, "db", &sc.0, json!({"confirmed": true, "now": now})),
        )
    };
    let first = land(&snap, T1).unwrap();
    assert_eq!(first["unchanged"], json!(false), "{first}");
    assert_eq!(
        std::fs::read(&snap).unwrap(),
        original,
        "the input is untouched"
    );
    let before = (export_bytes(h, P), all_derived(&dir.0));
    let again = land(&snap, T1 + 86_400_000).unwrap();
    assert_eq!(again["unchanged"], json!(true), "{again}");
    assert_eq!((export_bytes(h, P), all_derived(&dir.0)), before);
    ffsrs_store_close(h);

    let digest = *blake3::hash(&original).as_bytes();
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    for (name, marker) in [
        ("old.db", P.to_owned()),
        ("new.db", format!("{P}:db:{hex}")),
    ] {
        let forged = tampered(&snap, &work.0.join(name), |c| {
            c.execute(
                "UPDATE sync2_self SET migrated_at = NULL WHERE profile_uid = srs_id(?1)",
                [P],
            )
            .unwrap();
            c.execute(
                "INSERT OR REPLACE INTO srs_meta (key, value) VALUES (?1, ?2)",
                rusqlite::params![super::backup::PREPARED_KEY, marker],
            )
            .unwrap();
        });
        let (_d, h) = fresh("g114rofg", P);
        let sc = tempdir::new("g114rofs");
        // 上一次在这个 scratch 里拷完、还没备完就断了：副本与输入逐字节相同，带着输入自带的标记。
        std::fs::copy(&forged, sc.0.join(crate::store::gen4::files::LEGACY_FILE)).unwrap();
        let got = try_g4(
            h,
            P,
            "legacy_backup_import",
            legacy_req(&forged, "db", &sc.0, json!({"confirmed": true})),
        )
        .unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_ne!(got["outcome"], json!("needsConfirm"), "{name}: {got}");
        assert_eq!(got["unchanged"], json!(false), "{name}: {got}");
        ffsrs_store_close(h);
    }
}

/// `scratch` 的核对：里面有别的文件（不删、不碰）、就是已打开的库目录、是库目录的上级——一律拒绝，库目录里的文件
/// （新代库、封存的协议 3 库）一个字节不变。
#[test]
fn a_scratch_that_is_not_ours_is_refused() {
    let m = migrated();
    let work = tempdir::new("g114sc");
    let snap = protocol_3_backup(&m, &work.0);
    let files = |d: &Path| -> Vec<(String, Vec<u8>)> {
        let mut v: Vec<(String, Vec<u8>)> = std::fs::read_dir(d)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.is_file() && !p.to_string_lossy().ends_with("-shm"))
            .map(|p| (p.to_string_lossy().into_owned(), std::fs::read(&p).unwrap()))
            .collect();
        v.sort();
        v
    };
    let lib_before = files(&m.dir.0);
    let legacy = crate::store::gen4::files::LEGACY_FILE;
    let busy = tempdir::new("g114scbusy");
    std::fs::write(busy.0.join("keep.txt"), b"keep").unwrap();
    std::fs::write(busy.0.join(legacy), b"old").unwrap();
    let e = try_g4(
        m.h,
        P,
        "legacy_backup_import",
        legacy_req(&snap, "db", &busy.0, json!({"confirmed": true})),
    )
    .unwrap_err();
    assert!(e.contains("not empty"), "{e}");
    assert_eq!(std::fs::read(busy.0.join("keep.txt")).unwrap(), b"keep");
    assert_eq!(std::fs::read(busy.0.join(legacy)).unwrap(), b"old");
    for scratch in [m.dir.0.clone(), m.dir.0.parent().unwrap().to_path_buf()] {
        let e = try_g4(
            m.h,
            P,
            "legacy_backup_import",
            legacy_req(&snap, "db", &scratch, json!({"confirmed": true})),
        )
        .unwrap_err();
        assert!(e.contains("overlaps the open library"), "{e}");
    }
    assert_eq!(files(&m.dir.0), lib_before);
}
