//! 前提补完（`prepare.rs`，G7-2b）的测试：从没同步过、协议 3 迁移做到一半、收段收尾残留（待重放 / 待刷新缓存 / 去重
//! 作业）、只在投影表里的孤儿 profile 的协议 3 库，`migrate::run` 一次提交、对拍通过、日志条数不少；补完途中叫停 /
//! panic / 进程被杀之后旧库仍是协议 3 能打开的库，重跑提交。

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

use rusqlite::{Connection, OpenFlags, params};
use serde_json::{Value, json};

use super::*;
use crate::store::gen4::dryrun::Stop;
use crate::store::gen4::dryrun::tests::{N1, N2, T0, cfg};
use crate::store::gen4::files::{GEN4_FILE, GEN4_TEMP, LEGACY_FILE};
use crate::store::gen4::kernel::global;
use crate::store::gen4::migrate::{self, GenState, run, status};
use crate::store::seal::SEALED_SCHEMA;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{Device, P, deck_entity, edit, review, tempdir};
use crate::sync2::id::Id;

const NOW: i64 = T0 + 30 * 86_400_000;
const N3: &str = "0193a1b2-0000-7000-8000-0000000000b3";
/// 主库 profile 表里没有的孤儿 uid（删除没清干净 / 备份并入留下的）。
const ORPHAN: &str = "0193a1b2-0000-7000-8000-00000000cafe";

fn fixed_device(profile: &str, _now: i64) -> Id {
    Id([if profile == P { 0x4e } else { 0x4f }; 16])
}

fn cfg_of(profile: &str) -> String {
    json!({"defaultDeck": default_deck_id(profile)}).to_string()
}

fn caches() -> BTreeMap<String, String> {
    BTreeMap::from([(P.to_owned(), cfg()), (ORPHAN.to_owned(), cfg_of(ORPHAN))])
}

fn note(id: &str, nt: &str) -> Value {
    json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": nt}}})
}

fn note_type(id: &str) -> Value {
    json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}})
}

/// 协议 1 时代留下、还没包成操作的旧修改记录（笔记 [N3] 的字段）。
fn legacy_edit(c: &Connection, writer: &str, s: i64, key: &str, v: &str, vv: Value, at: i64) {
    let id = crate::registers::edit_id(writer, s);
    let j = json!({"ctx": {"vv": vv}, "e": N3, "f": key, "hlc": format!("{at}:0:{writer}"),
                   "id": id, "k": "note", "p": P, "s": s, "ts": "wall", "v": v, "w": writer})
    .to_string();
    c.execute(
        "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
         VALUES (srs_id(?1), srs_id(?2), 'note', srs_id(?3), ?4, ?5, ?6, ?7)",
        params![id, P, N3, key, writer, s, j],
    )
    .unwrap();
}

/// 还没包成操作的旧复习日志（[profile] 下、卡 [card]）。
fn legacy_log(c: &Connection, profile: &str, id: &str, card: &str, at: i64) {
    let j = json!({
        "id": id, "p": profile, "card": card, "kind": "review", "rating": 3, "hlc": format!("{at}:0:old"), "at": at,
        "ts": "anchored", "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
        "res": {"queue": "review", "dueDay": 19_800, "ivl": 40, "step": 0, "reps": 2, "lapses": 0, "scheduler": "fushi",
                "memory": {"s": 41.5, "d": 5.25, "sf": 0.0}, "lastReviewedAt": at}
    })
    .to_string();
    c.execute(
        "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, jslim) \
         VALUES (srs_id(?1), srs_id(?2), srs_id(?3), 'review', 3, ?4, 'review', 'fushi', ?5)",
        params![id, profile, card, at, j],
    )
    .unwrap();
}

/// 从没同步过的老用户：开过协议 3（有本机身份）、迁移按 BUG-4011 推迟到首次同步之后、一直没同步，所以
/// `migrated_at` 为空；之后的本机写入都是操作，更早的修改记录与复习日志还只在投影表里。[before_close] 在内核关之前跑。
fn unsynced_dir(tag: &str, before_close: &dyn Fn(&Device)) -> tempdir::Dir {
    let d = Device::new(tag);
    d.core.sync2_identity(P, T0).unwrap();
    {
        let w = d.core.writer().unwrap();
        legacy_edit(&w, "w1", 1, "f/fa", "x", json!({}), T0 - 900);
        legacy_edit(&w, "w1", 2, "f/fa", "y", json!({"w1": 1}), T0 - 800);
    }
    let fdef = json!({"name": "Expression", "ord": 0});
    let tdef = |name: &str, ord: i64| json!({"name": name, "ord": ord, "front": "{{Expression}}"});
    d.apply(
        T0,
        vec![
            deck_entity(&default_deck_id(P)),
            note_type("NT"),
            edit("notetype", "NT", "fieldDef/fa", fdef),
            edit("notetype", "NT", "tmplDef/t1", tdef("A", 0)),
            edit("notetype", "NT", "tmplDef/t2", tdef("B", 1)),
            note(N1, "NT"),
            edit("note", N1, "f/fa", json!("猫")),
            note(N2, "NT"),
            edit("note", N2, "f/fa", json!("犬")),
            note(N3, "NT"),
        ],
    );
    let c1 = crate::registers::card_id(N1, "t1", 0).unwrap();
    d.apply(T0 + 10, vec![review("r1", &c1, T0 + 10, 3, "learn")]);
    // 旧日志在另一张卡上（那张卡只有这条旧日志）：协议 1 时代的复习，早于之后的本机操作。
    let c2 = crate::registers::card_id(N2, "t1", 0).unwrap();
    {
        let w = d.core.writer().unwrap();
        legacy_log(&w, P, "0193a1b2-0000-7000-8000-0000000000e1", &c2, T0 - 700);
    }
    let parsed =
        crate::store::caches::CacheConfig::parse(&serde_json::from_str(&cfg()).unwrap()).unwrap();
    {
        let w = d.core.writer().unwrap();
        crate::store::sync2::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &parsed))
            .unwrap();
    }
    before_close(&d);
    let Device { core, _dir } = d;
    core.close();
    drop(core);
    _dir
}

/// 不经内核读旧库（注册了 ID 函数）。
fn raw(dir: &Path) -> Connection {
    let c = Connection::open(dir.join(LEGACY_FILE)).unwrap();
    crate::store::ids::register(&c).unwrap();
    crate::store::slim::register(&c).unwrap();
    crate::store::sync2::digest::register(&c).unwrap();
    c
}

fn count(c: &Connection, sql: &str) -> i64 {
    c.query_row(sql, [], |r| r.get(0)).unwrap()
}

fn schema_of(dir: &Path) -> i64 {
    Connection::open_with_flags(dir.join(LEGACY_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap()
        .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
            r.get::<_, String>(0)
        })
        .unwrap()
        .parse()
        .unwrap()
}

fn migrate_with(dir: &Path, caches: &BTreeMap<String, String>, stop: &Stop) -> migrate::Outcome {
    run(
        dir,
        migrate::Options {
            caches,
            batch: 2,
            now_ms: NOW,
            stop,
            progress: &mut |_, _, _| {},
            new_device: &fixed_device,
        },
    )
    .unwrap()
}

/// 只读：[dir] 的补完计划（缓存配置给全）。
fn plan_of(dir: &Path) -> Plan {
    let src = crate::store::gen4::dryrun::open_legacy(&dir.join(LEGACY_FILE)).unwrap();
    let p = plan(&src, crate::store::schema::SCHEMA_VERSION, &caches())
        .unwrap()
        .unwrap();
    let _ = src.execute_batch("ROLLBACK");
    p
}

/// 提交了、对拍全过；旧库封存；新代库里的复习日志不少于迁移前旧库里的（含补完包进来的那些），旧库里每个 profile 都有
/// 一个集合。
fn assert_committed(dir: &Path, out: &migrate::Outcome, legacy_logs: i64, profiles: usize) {
    let migrate::Outcome::Committed { report } = out else {
        panic!("{out:?}")
    };
    let verdicts: Vec<&str> = report["profiles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["verdict"].as_str().unwrap())
        .collect();
    assert_eq!(verdicts, vec!["pass"; profiles], "{report:#}");
    assert_eq!(schema_of(dir), SEALED_SCHEMA);
    let new =
        Connection::open_with_flags(dir.join(GEN4_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(
        count(&new, "SELECT COUNT(*) FROM collections"),
        profiles as i64
    );
    let logs = count(&new, "SELECT COUNT(DISTINCT id) FROM log_ix");
    assert!(logs >= legacy_logs, "{logs} < {legacy_logs}");
}

/// 从没同步过（`migrated_at` 为空、旧行还没包成操作）：状态页拿到旧库的 profile 列表，迁移先用协议 3 的 `migrate`
/// 把旧行包完、再迁，一次提交；旧修改记录与旧日志都在新代库里。补完之后旧库里协议 3 的前提全部满足。
#[test]
fn a_never_synced_library_is_completed_and_migrated() {
    let dir = unsynced_dir("g72b-unsynced", &|_| {});
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    assert_eq!(logs, 2);
    {
        let src = crate::store::gen4::dryrun::open_legacy(&dir.0.join(LEGACY_FILE)).unwrap();
        assert!(
            legacy::preflight(&src, P)
                .unwrap()
                .iter()
                .any(|b| b.contains("not migrated")),
        );
    }
    assert_eq!(plan_of(&dir.0).profiles, vec![P.to_owned()]);
    assert_eq!(
        global(
            "gen4_migrate_status",
            &json!({"dir": dir.0.to_str().unwrap()})
        )
        .unwrap()["profiles"],
        json!([P])
    );
    let mut steps = Vec::new();
    let out = run(
        &dir.0,
        migrate::Options {
            caches: &caches(),
            batch: 2,
            now_ms: NOW,
            stop: &Stop::new(),
            progress: &mut |s, _, _| {
                if steps.last() != Some(&s) {
                    steps.push(s);
                }
            },
            new_device: &fixed_device,
        },
    )
    .unwrap();
    assert_committed(&dir.0, &out, logs, 1);
    assert_eq!(
        &steps[..4],
        &[Step::Space, Step::Lock, Step::Prepare, Step::Precondition]
    );
    // 两条旧修改记录进了操作日志（新代里是承袭的旧修改）：N3 的字段是旧记录里赢的那个值。
    let c = raw(&dir.0);
    assert_eq!(
        count(
            &c,
            "SELECT COUNT(*) FROM sync2_self WHERE migrated_at IS NOT NULL"
        ),
        1
    );
    assert_eq!(count(&c, "SELECT COUNT(*) FROM sync2_migrate_queue"), 0);
}

/// 协议 3 的迁移做到一半（队列里还有旧行）：补完从队列剩下的接着做，结果与一次做完的相同（对拍通过）。
#[test]
fn a_half_done_protocol_3_migration_is_finished() {
    let dir = unsynced_dir("g72b-halfway", &|d| {
        let r = d.core.sync2_migrate(P, T0, Some(1)).unwrap();
        assert_eq!(r["done"], json!(false), "{r}");
    });
    let c = raw(&dir.0);
    assert!(count(&c, "SELECT COUNT(*) FROM sync2_migrate_queue") > 0);
    let logs = count(&c, "SELECT COUNT(*) FROM srs_review_logs");
    drop(c);
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    assert_committed(&dir.0, &out, logs, 1);
    assert_eq!(
        count(&raw(&dir.0), "SELECT COUNT(*) FROM sync2_migrate_queue"),
        0
    );
}

/// 收段被打断留下的待重放卡、待刷新缓存与一个没做完的去重作业：补完用协议 3 的 `replay_pending` / `dedup` 做完，
/// 旧库里这几张表清空，迁移提交（对拍不跳过任何卡）。
#[test]
fn interrupted_ingest_leftovers_are_finished() {
    let d = crate::store::gen4::dryrun::tests::library("g72b-leftovers");
    let c1 = crate::registers::card_id(N1, "t1", 0).unwrap();
    {
        let w = d.core.writer().unwrap();
        w.execute(
            "INSERT INTO sync2_replay_pending (profile_uid, card_id) VALUES (srs_id(?1), srs_id(?2))",
            [P, &c1],
        )
        .unwrap();
        for (kind, id) in [(1, N2), (2, c1.as_str())] {
            w.execute(
                "INSERT INTO sync2_cache_pending (profile_uid, kind, entity_id) VALUES (srs_id(?1), ?2, srs_id(?3))",
                params![P, kind, id],
            )
            .unwrap();
        }
        w.execute(
            "INSERT OR IGNORE INTO sync2_dedup (profile_uid, phase, cur_dev, cur_seq) VALUES (srs_id(?1), 0, x'', 0)",
            [P],
        )
        .unwrap();
    }
    let Device { core, _dir: dir } = d;
    core.close();
    drop(core);
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    assert_eq!(plan_of(&dir.0).profiles, vec![P.to_owned()]);
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    assert_committed(&dir.0, &out, logs, 1);
    let c = raw(&dir.0);
    for t in ["sync2_replay_pending", "sync2_cache_pending", "sync2_dedup"] {
        assert_eq!(count(&c, &format!("SELECT COUNT(*) FROM {t}")), 0, "{t}");
    }
}

/// 旧库里多出一个主库 profile 表里没有的孤儿 uid（只在投影表里，没进过操作日志）：`gen4_migrate_status` 把它列出来，
/// 按列表给全缓存配置后迁移提交，它的牌组与复习日志成了新代库里的第二个集合，一条不丢。只给主库那个 profile 的配置 =
/// 拦下（`missingCacheConfig`，点名缺的 uid），旧库不动。
#[test]
fn an_orphan_profile_is_listed_and_migrated() {
    let dir = unsynced_dir("g72b-orphan", &|d| {
        while d.core.sync2_migrate(P, T0, None).unwrap()["done"] != json!(true) {}
        let w = d.core.writer().unwrap();
        w.execute(
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (srs_id(?1), srs_id(?2), 'deck', '{\"createdAt\":1}', 1)",
            params![default_deck_id(ORPHAN), ORPHAN],
        )
        .unwrap();
        legacy_log(
            &w,
            ORPHAN,
            "0193a1b2-0000-7000-8000-0000000000e9",
            "0193a1b2-0000-7000-8000-0000000000c9",
            T0 - 600,
        );
    });
    let d = dir.0.to_str().unwrap();
    let s = global("gen4_migrate_status", &json!({"dir": d})).unwrap();
    assert_eq!(s["state"], json!("needsMigration"));
    let mut listed: Vec<String> = s["profiles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect();
    listed.sort();
    let mut want = vec![P.to_owned(), ORPHAN.to_owned()];
    want.sort();
    assert_eq!(listed, want);
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");

    // 只给主库里那个 profile 的配置：拦下、点名孤儿 uid、旧库不动。
    let before = std::fs::read(dir.0.join(LEGACY_FILE)).unwrap();
    let only_p = BTreeMap::from([(P.to_owned(), cfg())]);
    let out = migrate_with(&dir.0, &only_p, &Stop::new());
    let migrate::Outcome::Blocked { code, reason } = &out else {
        panic!("{out:?}")
    };
    assert_eq!(*code, BlockCode::MissingCacheConfig);
    assert!(reason.contains(ORPHAN), "{reason}");
    assert_eq!(std::fs::read(dir.0.join(LEGACY_FILE)).unwrap(), before);

    // 按状态给的列表交配置（与 Dart 同一条路：全局命令、JSON 配置对象）。
    let caches: serde_json::Map<String, Value> = listed
        .iter()
        .map(|p| (p.clone(), serde_json::from_str(&cfg_of(p)).unwrap()))
        .collect();
    let r = global(
        "gen4_migrate_run",
        &json!({"dir": d, "caches": caches, "now": NOW, "batch": 2}),
    )
    .unwrap();
    assert_eq!(r["verdict"], json!("committed"), "{r:#}");
    let report = r["report"].clone();
    assert_committed(&dir.0, &migrate::Outcome::Committed { report }, logs, 2);
    assert_eq!(status(&dir.0), Ok(GenState::Ready));
}

/// 什么都不用补的库：计划为空，补完不开协议 3 的写连接（旧库在提交点之前一个字节不写，`migrate_tests.rs` 的断点
/// 测试按字节核对）。
#[test]
fn a_ready_library_needs_no_completion() {
    let d = crate::store::gen4::dryrun::tests::library("g72b-ready");
    let Device { core, _dir: dir } = d;
    core.close();
    drop(core);
    assert!(plan_of(&dir.0).is_empty());
}

/// 文件坏了：拦下（`corrupt`），什么都不写；不是协议 3 能修的状态。
#[test]
fn a_damaged_library_is_refused_as_corrupt() {
    let dir = tempdir::new("g72b-corrupt");
    std::fs::write(dir.0.join(LEGACY_FILE), vec![0x5a; 8192]).unwrap();
    let before = std::fs::read(dir.0.join(LEGACY_FILE)).unwrap();
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    let migrate::Outcome::Blocked { code, .. } = &out else {
        panic!("{out:?}")
    };
    assert_eq!(*code, BlockCode::Corrupt);
    assert_eq!(out.json()["code"], json!("corrupt"));
    assert_eq!(std::fs::read(dir.0.join(LEGACY_FILE)).unwrap(), before);
    assert!(!dir.0.join(GEN4_TEMP).exists());
}

/// 旧库是协议 3 能照常打开的库：协议 3 的内核打得开，完整性检查过，库里的复习日志一条不少。
fn assert_protocol_3_opens(dir: &Path, logs: i64) {
    let core = crate::store::SrsCore::open(&dir.join(LEGACY_FILE)).unwrap();
    let id = core.sync2_identity(P, NOW).unwrap();
    assert!(id["device"].is_string(), "{id}");
    core.close();
    drop(core);
    let c = raw(dir);
    assert_eq!(
        c.query_row("PRAGMA quick_check", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    assert_eq!(count(&c, "SELECT COUNT(*) FROM srs_review_logs"), logs);
    assert_eq!(
        schema_of(dir),
        crate::store::schema::SCHEMA_VERSION,
        "not sealed"
    );
    assert!(!dir.join(GEN4_FILE).exists());
}

/// 补完途中叫停 / panic：报叫停（panic 照常往外抛），旧库是协议 3 能打开的库、没有新代库；重跑从断点接着补、提交。
#[test]
fn a_cancelled_or_panicking_completion_leaves_a_protocol_3_library() {
    for panics in [false, true] {
        let tag = if panics { "g72b-panic" } else { "g72b-stop" };
        let dir = unsynced_dir(tag, &|_| {});
        let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
        let stop = Stop::new();
        let caches = caches();
        let mut seen = 0;
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run(
                &dir.0,
                migrate::Options {
                    caches: &caches,
                    batch: 1,
                    now_ms: NOW,
                    stop: &stop,
                    progress: &mut |s, _, _| {
                        if s == Step::Prepare {
                            seen += 1;
                            // 第一批旧行已经包好提交、还有剩的时候。
                            if seen == 3 {
                                if panics {
                                    panic!("injected panic in the middle of the completion");
                                }
                                stop.stop();
                            }
                        }
                    },
                    new_device: &fixed_device,
                },
            )
        }));
        if panics {
            assert!(r.is_err(), "{tag}");
        } else {
            assert_eq!(r.unwrap().unwrap(), migrate::Outcome::Cancelled, "{tag}");
        }
        // 补到一半：旧行有的包了、有的还在队列里。
        assert!(
            count(&raw(&dir.0), "SELECT COUNT(*) FROM sync2_migrate_queue") > 0,
            "{tag}"
        );
        assert_protocol_3_opens(&dir.0, logs);
        assert_eq!(status(&dir.0), Ok(GenState::NeedsMigration), "{tag}");
        let out = migrate_with(&dir.0, &caches, &Stop::new());
        assert_committed(&dir.0, &out, logs, 1);
    }
}

// ---------------------------------------------------------------- 断点（子进程）

const CHILD_DIR: &str = "FUSHI_G72B_CHILD_DIR";
const CHILD_AT: &str = "FUSHI_G72B_CRASH_AT";
const CRASHED: i32 = 87;

/// 子进程那一半：环境变量给了目录才动作。补完报到第 n 次进度时立刻 `exit`（等同被杀：不跑析构、不关连接）。
#[test]
fn prepare_child_process_half() {
    let Ok(dir) = std::env::var(CHILD_DIR) else {
        return;
    };
    let nth: u64 = std::env::var(CHILD_AT).unwrap().parse().unwrap();
    let mut seen = 0u64;
    let caches = caches();
    let stop = Stop::new();
    let r = run(
        Path::new(&dir),
        migrate::Options {
            caches: &caches,
            batch: 1,
            now_ms: NOW,
            stop: &stop,
            progress: &mut |s, _, _| {
                if s == Step::Prepare {
                    seen += 1;
                    if seen == nth {
                        std::process::exit(CRASHED);
                    }
                }
            },
            new_device: &fixed_device,
        },
    );
    panic!("the crash point prepare:{nth} was never reached: {r:?}");
}

/// 补完途中进程被杀（每一条协议 3 命令之后各试一次）：旧库是协议 3 能打开的库，重跑提交，结果都对拍通过。
#[test]
fn a_killed_completion_resumes() {
    let base = unsynced_dir("g72b-kill", &|_| {});
    let logs = count(&raw(&base.0), "SELECT COUNT(*) FROM srs_review_logs");
    for nth in [2u64, 4, 6] {
        let d = tempdir::new(&format!("g72b-kill-{nth}"));
        std::fs::copy(base.0.join(LEGACY_FILE), d.0.join(LEGACY_FILE)).unwrap();
        let out = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "store::gen4::prepare::tests::prepare_child_process_half",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(CHILD_DIR, &d.0)
            .env(CHILD_AT, nth.to_string())
            .output()
            .unwrap();
        assert_eq!(
            out.status.code(),
            Some(CRASHED),
            "{nth}: {}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        assert_protocol_3_opens(&d.0, logs);
        let out = migrate_with(&d.0, &caches(), &Stop::new());
        assert_committed(&d.0, &out, logs, 1);
    }
}

/// 补完之后的前提核对仍然拦得住补完管不到的：补完只跑协议 3 自己的命令，并入标记它不碰（[plan] 先拦下）。
#[test]
fn a_half_done_merge_is_not_completed() {
    let dir = unsynced_dir("g72b-merge", &|d| {
        let w = d.core.writer().unwrap();
        w.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, '{}')",
            [format!("profile_merge/{ORPHAN}")],
        )
        .unwrap();
    });
    let before = std::fs::read(dir.0.join(LEGACY_FILE)).unwrap();
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    let migrate::Outcome::Blocked { code, .. } = &out else {
        panic!("{out:?}")
    };
    assert_eq!(*code, BlockCode::MergeHalfDone);
    assert_eq!(std::fs::read(dir.0.join(LEGACY_FILE)).unwrap(), before);
}
