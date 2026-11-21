//! 前提补完（`prepare.rs`，G7-2b）的测试：从没同步过、协议 3 迁移做到一半、收段收尾残留（待重放 / 待刷新缓存 / 去重
//! 作业）、只在投影表里的孤儿 profile、v3.3.0 正式版的 schema 26、没有协议 3 身份的协议 3 库，`migrate::run` 一次提交、
//! 对拍通过、日志条数不少；补完在副本上做，原件在提交点之前逐字节不变——补完途中叫停 / panic / 进程被杀之后原件仍是
//! 写它的那个协议 3 版本能打开的库，重跑提交；提交点之后、封存之前被杀，Primary 打开补封原件。

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

use rusqlite::{Connection, OpenFlags, params};
use serde_json::{Value, json};

use super::*;
use crate::store::gen4::dryrun::Stop;
use crate::store::gen4::dryrun::tests::{N1, N2, T0, cfg};
use crate::store::gen4::files::{GEN4_FILE, GEN4_TEMP, LEGACY_FILE, OpenMode, open_gen4};
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
/// v3.3.0（最新的协议 3 正式版，D2 的回退目标）的 schema 号：`git show v3.3.0:native/fushi_fsrs/src/store/schema.rs`。
const V3_3_0_SCHEMA: i64 = 26;

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

/// 关掉内核，留下目录。
fn close(d: Device) -> tempdir::Dir {
    let Device { core, _dir } = d;
    core.close();
    drop(core);
    _dir
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
    close(d)
}

/// 把这一版协议 3 的库（schema 29）原地改成 v3.3.0 的 schema 26：两版之间的升级阶梯只有 v29 建表（`sync2_trust` /
/// `sync2_trust_held`），v27 / v28 只改数据（补撤销、按新规则重放副本，本夹具里都没有这类数据）；v26 及以前的步骤在
/// v3.3.0 与这一版逐字相同（`git diff v3.3.0 HEAD -- native/fushi_fsrs/src/store/schema.rs src/store/sync2/schema.rs`
/// 只有这三步）。所以去掉这两张表、把号写回 26，就是 v3.3.0 建出来的表形态。
fn downgrade_to_v3_3_0(dir: &Path) {
    let c = raw(dir);
    c.execute_batch(
        "DROP TABLE sync2_trust; DROP TABLE sync2_trust_held; \
         UPDATE srs_meta SET value = '26' WHERE key = 'schema'; PRAGMA wal_checkpoint(TRUNCATE);",
    )
    .unwrap();
    c.close().unwrap();
    assert_eq!(schema_of(dir), V3_3_0_SCHEMA);
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

/// 原件的字节（主文件；测试夹具都关过内核、检查点做完，WAL 不在或是空的）。
fn legacy_bytes(dir: &Path) -> Vec<u8> {
    let wal = dir.join(format!("{LEGACY_FILE}-wal"));
    assert!(
        std::fs::metadata(&wal).map_or(true, |m| m.len() == 0),
        "WAL has content"
    );
    std::fs::read(dir.join(LEGACY_FILE)).unwrap()
}

fn copy_left(dir: &Path) -> bool {
    dir.join(crate::store::gen4::files::PREPARE_COPY).exists()
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
    let p = plan(&src, schema_of(dir), &caches()).unwrap().unwrap();
    let _ = src.execute_batch("ROLLBACK");
    p
}

/// 经全局命令列旧库的 profile（Dart 在后台 isolate 调的那条）。
fn listed_profiles(dir: &Path) -> Vec<String> {
    let v = global(
        "gen4_migrate_profiles",
        &json!({"dir": dir.to_str().unwrap()}),
    )
    .unwrap();
    v["profiles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect()
}

/// 提交了、对拍全过；原件封存；新代库里的复习日志不少于迁移前旧库里的（含补完包进来的那些），旧库里每个 profile 都有
/// 一个集合；补完副本删掉了。
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
    assert!(!copy_left(dir));
    let new =
        Connection::open_with_flags(dir.join(GEN4_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(
        count(&new, "SELECT COUNT(*) FROM collections"),
        profiles as i64
    );
    let logs = count(&new, "SELECT COUNT(DISTINCT id) FROM log_ix");
    assert!(logs >= legacy_logs, "{logs} < {legacy_logs}");
}

/// 从没同步过（`migrated_at` 为空、旧行还没包成操作）：列表命令给出旧库的 profile，迁移在副本上用协议 3 的 `migrate`
/// 把旧行包完、再迁，一次提交；旧修改记录与旧日志都在新代库里。原件除封存外没被写过：`migrated_at` 仍为空。
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
    assert_eq!(listed_profiles(&dir.0), vec![P.to_owned()]);
    // 状态命令只看文件与锁，不再列 profile（它在 UI isolate 上同步调）。
    let s = global(
        "gen4_migrate_status",
        &json!({"dir": dir.0.to_str().unwrap()}),
    )
    .unwrap();
    assert_eq!(s, json!({"state": "needsMigration", "running": null}));
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
    let c = raw(&dir.0);
    assert_eq!(
        count(
            &c,
            "SELECT COUNT(*) FROM sync2_self WHERE migrated_at IS NOT NULL"
        ),
        0
    );
}

/// 协议 3 的迁移做到一半（队列里还有旧行）：补完从队列剩下的接着做，结果与一次做完的相同（对拍通过）。原件里的队列
/// 原样留着（补完只写副本）。
#[test]
fn a_half_done_protocol_3_migration_is_finished() {
    let dir = unsynced_dir("g72b-halfway", &|d| {
        let r = d.core.sync2_migrate(P, T0, Some(1)).unwrap();
        assert_eq!(r["done"], json!(false), "{r}");
    });
    let c = raw(&dir.0);
    let queued = count(&c, "SELECT COUNT(*) FROM sync2_migrate_queue");
    assert!(queued > 0);
    let logs = count(&c, "SELECT COUNT(*) FROM srs_review_logs");
    drop(c);
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    assert_committed(&dir.0, &out, logs, 1);
    assert_eq!(
        count(&raw(&dir.0), "SELECT COUNT(*) FROM sync2_migrate_queue"),
        queued
    );
}

/// 收段被打断留下的待重放卡、待刷新缓存与一个没做完的去重作业：补完用协议 3 的 `replay_pending` / `dedup` 在副本上
/// 做完，迁移提交（对拍不跳过任何卡）；原件里这几张表原样。
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
    let dir = close(d);
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    assert_eq!(plan_of(&dir.0).profiles, vec![P.to_owned()]);
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    assert_committed(&dir.0, &out, logs, 1);
    let c = raw(&dir.0);
    for (t, n) in [
        ("sync2_replay_pending", 1),
        ("sync2_cache_pending", 2),
        ("sync2_dedup", 1),
    ] {
        assert_eq!(count(&c, &format!("SELECT COUNT(*) FROM {t}")), n, "{t}");
    }
}

/// 只剩收段收尾（待重放 + 待刷新缓存）、其余协议 3 前提都齐（`migrated_at` 已写、没有去重作业、没有收段通道）：只有
/// `migration_blockers` 判得出要补。补完之后核对通过、提交（这条判断出错 = 前提核对报 `precondition`、重试永远不过）。
#[test]
fn only_replay_and_cache_leftovers_are_finished() {
    let d = crate::store::gen4::dryrun::tests::library("g72b-replay-only");
    let c1 = crate::registers::card_id(N1, "t1", 0).unwrap();
    {
        let w = d.core.writer().unwrap();
        w.execute(
            "INSERT INTO sync2_replay_pending (profile_uid, card_id) VALUES (srs_id(?1), srs_id(?2))",
            [P, &c1],
        )
        .unwrap();
        w.execute(
            "INSERT INTO sync2_cache_pending (profile_uid, kind, entity_id) VALUES (srs_id(?1), 1, srs_id(?2))",
            [P, N2],
        )
        .unwrap();
    }
    let dir = close(d);
    {
        let src = crate::store::gen4::dryrun::open_legacy(&dir.0.join(LEGACY_FILE)).unwrap();
        assert_eq!(legacy::preflight(&src, P).unwrap(), Vec::<String>::new());
        assert_eq!(legacy::migration_blockers(&src, P).unwrap().len(), 2);
        let _ = src.execute_batch("ROLLBACK");
    }
    assert_eq!(plan_of(&dir.0).profiles, vec![P.to_owned()]);
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    assert_committed(&dir.0, &out, logs, 1);
}

/// 旧库里多出一个主库 profile 表里没有的孤儿 uid（只在投影表里，没进过操作日志）：`gen4_migrate_profiles` 把它列出来，
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
    let mut listed = listed_profiles(&dir.0);
    listed.sort();
    let mut want = vec![P.to_owned(), ORPHAN.to_owned()];
    want.sort();
    assert_eq!(listed, want);
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");

    // 只给主库里那个 profile 的配置：拦下、点名孤儿 uid、旧库不动。
    let before = legacy_bytes(&dir.0);
    let only_p = BTreeMap::from([(P.to_owned(), cfg())]);
    let out = migrate_with(&dir.0, &only_p, &Stop::new());
    let migrate::Outcome::Blocked { code, reason } = &out else {
        panic!("{out:?}")
    };
    assert_eq!(*code, BlockCode::MissingCacheConfig);
    assert!(reason.contains(ORPHAN), "{reason}");
    assert_eq!(legacy_bytes(&dir.0), before);

    // 按列表交配置（与 Dart 同一条路：全局命令、JSON 配置对象）。
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

/// 列 profile 的查询按 profile 跳着取：每张有 `profile_uid` 打头索引的表都是索引查找，不整表 / 整索引扫（测的是
/// `legacy::all_profiles` 执行的同一条语句常量）。
#[test]
fn listing_profiles_seeks_the_profile_index() {
    let dir = close(crate::store::gen4::dryrun::tests::library("g72b-explain"));
    let c = crate::store::gen4::dryrun::open_legacy(&dir.0.join(LEGACY_FILE)).unwrap();
    for table in legacy::LOGGED_TABLES
        .iter()
        .chain(&legacy::PROJECTED_TABLES)
        .filter(|t| **t != "srs_unknown_events")
    {
        let sql = legacy::PROFILES_OF_TABLE_SQL.replace("{t}", table);
        let plan: Vec<String> = c
            .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
            .unwrap()
            .query_map([], |r| r.get::<_, String>(3))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let on_table: Vec<&String> = plan
            .iter()
            .filter(|d| d.split_whitespace().nth(1) == Some(*table))
            .collect();
        assert_eq!(on_table.len(), 2, "{table}: {plan:#?}");
        for d in on_table {
            assert!(
                d.starts_with("SEARCH ") && (d.contains("INDEX") || d.contains("PRIMARY KEY")),
                "{table}: {plan:#?}"
            );
        }
    }
    assert_eq!(listed_profiles(&dir.0), vec![P.to_owned()]);
}

/// 什么都不用补的库：计划为空，不拷副本（`migrate_tests.rs` 的断点测试按字节核对原件）。
#[test]
fn a_ready_library_needs_no_completion() {
    let dir = close(crate::store::gen4::dryrun::tests::library("g72b-ready"));
    assert!(plan_of(&dir.0).is_empty());
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    let mut prepared = 0;
    let out = run(
        &dir.0,
        migrate::Options {
            caches: &caches(),
            batch: 2,
            now_ms: NOW,
            stop: &Stop::new(),
            progress: &mut |s, _, _| {
                if s == Step::Prepare {
                    prepared += 1;
                }
            },
            new_device: &fixed_device,
        },
    )
    .unwrap();
    assert_committed(&dir.0, &out, logs, 1);
    assert_eq!(prepared, 1);
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

/// 页头、`srs_meta` 与列 profile 要读的表都完好，只有一个缓存表索引的页坏了：读得出 schema、算得出计划，补完之前的
/// 完整性检查拦下（`corrupt`），不拷副本、原件逐字节不变。
#[test]
fn a_damaged_page_is_caught_before_completion() {
    let dir = unsynced_dir("g72b-badpage", &|_| {});
    let (page_size, root): (i64, i64) = {
        let c = raw(&dir.0);
        let ps = count(&c, "PRAGMA page_size");
        let root = count(
            &c,
            "SELECT rootpage FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'srs_cards_cache' \
             AND rootpage > 1 ORDER BY rootpage DESC LIMIT 1",
        );
        (ps, root)
    };
    let mut bytes = legacy_bytes(&dir.0);
    let at = ((root - 1) * page_size) as usize;
    bytes[at..at + page_size as usize].fill(0x5a);
    std::fs::write(dir.0.join(LEGACY_FILE), &bytes).unwrap();
    assert_eq!(plan_of(&dir.0).profiles, vec![P.to_owned()]);
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    let migrate::Outcome::Blocked { code, reason } = &out else {
        panic!("{out:?}")
    };
    assert_eq!(*code, BlockCode::Corrupt, "{reason}");
    assert_eq!(legacy_bytes(&dir.0), bytes);
    assert!(!copy_left(&dir.0));
    assert!(!dir.0.join(GEN4_TEMP).exists());
}

/// schema 标记与表对不上（开发版留下的库：标 13，却没有 v12 的 `sync2_replay_pending`，交接 §26「另记两处观察」）：
/// 升级阶梯从 13 往上不会补那张表，协议 3 的 `replay_pending` 只会报「no such table」。补完前按文件坏了拦下
/// （`corrupt`，带缺的表名），不是把协议 3 的报错当内部错误返回；原件逐字节不变、副本删掉。
#[test]
fn a_library_missing_tables_its_schema_claims_is_refused_as_corrupt() {
    let dir = unsynced_dir("k1-missing-table", &|_| {});
    {
        let c = raw(&dir.0);
        c.execute_batch(
            "DROP TABLE sync2_replay_pending; UPDATE srs_meta SET value = '13' WHERE key = 'schema';",
        )
        .unwrap();
    }
    let before = legacy_bytes(&dir.0);
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    let migrate::Outcome::Blocked { code, reason } = &out else {
        panic!("{out:?}")
    };
    assert_eq!(*code, BlockCode::Corrupt, "{reason}");
    assert!(reason.contains("sync2_replay_pending"), "{reason}");
    assert_eq!(legacy_bytes(&dir.0), before);
    assert!(!copy_left(&dir.0));
    assert!(!dir.0.join(GEN4_TEMP).exists());
}

/// 原件是写它的那个协议 3 版本能照常打开的库：逐字节就是迁移前的样子（[before]），没有新代库。
fn assert_original_untouched(dir: &Path, before: &[u8]) {
    assert_eq!(legacy_bytes(dir), before, "the original was written");
    assert!(!dir.join(GEN4_FILE).exists());
}

/// 这一版的协议 3 打得开原件（完整性检查过，复习日志一条不少）。会写它（建身份）：放在逐字节核对之后。
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
}

/// 补完途中叫停 / panic：报叫停（panic 照常往外抛），原件逐字节不变、没有新代库；重跑提交。
#[test]
fn a_cancelled_or_panicking_completion_leaves_the_original_untouched() {
    for panics in [false, true] {
        let tag = if panics { "g72b-panic" } else { "g72b-stop" };
        let dir = unsynced_dir(tag, &|_| {});
        let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
        let before = legacy_bytes(&dir.0);
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
                            // 副本上第一批旧行已经包好提交、还有剩的时候。
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
            assert!(!copy_left(&dir.0), "{tag}");
        }
        assert_original_untouched(&dir.0, &before);
        assert_eq!(status(&dir.0), Ok(GenState::NeedsMigration), "{tag}");
        let out = migrate_with(&dir.0, &caches, &Stop::new());
        assert_committed(&dir.0, &out, logs, 1);
    }
}

// ---------------------------------------------------------------- v3.3.0 的库（schema 26）

/// 从正式版 v3.3.0 升上来的用户（主路径：schema 26，比这一版的协议 3 旧）：计划是「升级 + 全部 profile」，列表命令在
/// 旧表形态上列得出 profile，升级与补完都在副本上做，一次提交、对拍通过；提交之前原件逐字节是 v3.3.0 写的那份，提交后
/// 原件只多了封存。
#[test]
fn a_v3_3_0_library_is_upgraded_in_the_copy_and_migrated() {
    let dir = unsynced_dir("g72b-v330", &|_| {});
    downgrade_to_v3_3_0(&dir.0);
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    assert_eq!(status(&dir.0), Ok(GenState::NeedsMigration));
    assert_eq!(listed_profiles(&dir.0), vec![P.to_owned()]);
    let plan = plan_of(&dir.0);
    assert!(plan.upgrade);
    assert_eq!(plan.profiles, vec![P.to_owned()]);
    let before = legacy_bytes(&dir.0);
    // 提交之前（对拍、提交两步）原件逐字节不变。
    let mut checked = 0;
    let out = run(
        &dir.0,
        migrate::Options {
            caches: &caches(),
            batch: 2,
            now_ms: NOW,
            stop: &Stop::new(),
            progress: &mut |s, _, _| {
                if matches!(s, Step::Parity | Step::Commit) {
                    assert_eq!(legacy_bytes(&dir.0), before, "{s:?}");
                    checked += 1;
                }
            },
            new_device: &fixed_device,
        },
    )
    .unwrap();
    assert!(checked >= 2);
    assert_committed(&dir.0, &out, logs, 1);
    // 封存只改 `srs_meta`：投影与日志表与 v3.3.0 写的一样（`sync2_trust` 仍不在，没被升级）。
    let c = raw(&dir.0);
    assert_eq!(
        count(
            &c,
            "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'sync2_trust'"
        ),
        0
    );
    assert_eq!(count(&c, "SELECT COUNT(*) FROM srs_review_logs"), logs);
}

/// v3.3.0 的库补到一半（升级做完、包旧行做到一半）叫停 / panic：原件仍是 schema 26、逐字节不变（v3.3.0 打得开）；
/// 重跑提交。
#[test]
fn a_stopped_v3_3_0_completion_leaves_a_v3_3_0_library() {
    for panics in [false, true] {
        let tag = if panics {
            "g72b-v330-panic"
        } else {
            "g72b-v330-stop"
        };
        let dir = unsynced_dir(tag, &|_| {});
        downgrade_to_v3_3_0(&dir.0);
        let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
        let before = legacy_bytes(&dir.0);
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
                            if seen == 3 {
                                if panics {
                                    panic!("injected panic after the upgrade");
                                }
                                stop.stop();
                            }
                        }
                    },
                    new_device: &fixed_device,
                },
            )
        }));
        assert_eq!(r.is_err(), panics, "{tag}");
        assert_original_untouched(&dir.0, &before);
        assert_eq!(schema_of(&dir.0), V3_3_0_SCHEMA, "{tag}");
        let out = migrate_with(&dir.0, &caches, &Stop::new());
        assert_committed(&dir.0, &out, logs, 1);
    }
}

/// 原件没有协议 3 身份（从没启用过协议 3，数据只在投影表里）：补完在副本里建身份、包旧行；新代库记的迁移来源是原件
/// 的内容摘要（`files::NO_IDENTITY`），提交、封存。
#[test]
fn a_library_without_identity_is_migrated() {
    let dir = no_identity_dir("g72b-noid");
    assert_eq!(crate::store::seal::legacy_identity(&raw(&dir.0)), Ok(None));
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    assert_eq!(listed_profiles(&dir.0), vec![P.to_owned()]);
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    assert_committed(&dir.0, &out, logs, 1);
    let new = Connection::open_with_flags(dir.0.join(GEN4_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap();
    let from: String = new
        .query_row(
            "SELECT value FROM srs_meta WHERE key = ?1",
            [crate::store::gen4::files::MIGRATED_FROM_KEY],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(from, crate::store::gen4::files::NO_IDENTITY);
}

/// 原件没有协议 3 身份时对拍中止：报告的 `legacyIdentity` 是 null，状态命令照样认作「上次迁移失败」（不报「要迁移」
/// 让服务端每次启动自动重迁、每次再中止）；有身份的库不被一份 null 身份的报告认走。
#[test]
fn an_aborted_migration_of_a_library_without_identity_reads_as_failed() {
    let dir = no_identity_dir("g72b-noid-abort");
    let aborted =
        json!({"version": migrate::REPORT_VERSION, "verdict": "aborted", "legacyIdentity": null});
    std::fs::write(dir.0.join(migrate::REPORT_FILE), aborted.to_string()).unwrap();
    assert_eq!(status(&dir.0), Ok(GenState::MigrationFailed));
    // 有身份的库：null 身份的报告不是它的。
    let Device { core, _dir: other } = crate::store::gen4::dryrun::tests::library("g72b-id-abort");
    core.close();
    drop(core);
    std::fs::write(other.0.join(migrate::REPORT_FILE), aborted.to_string()).unwrap();
    assert_eq!(status(&other.0), Ok(GenState::NeedsMigration));
}

/// 没开过协议 3 的库：只有投影表里的牌组与一条复习日志（[P] 下），没有 `sync2_self` 行。
fn no_identity_dir(tag: &str) -> tempdir::Dir {
    let d = Device::new(tag);
    {
        let w = d.core.writer().unwrap();
        w.execute(
            "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (srs_id(?1), srs_id(?2), 'deck', '{\"createdAt\":1}', 1)",
            params![default_deck_id(P), P],
        )
        .unwrap();
        legacy_log(
            &w,
            P,
            "0193a1b2-0000-7000-8000-0000000000ea",
            "0193a1b2-0000-7000-8000-0000000000ca",
            T0 - 600,
        );
    }
    close(d)
}

// ---------------------------------------------------------------- 断点（子进程）

const CHILD_DIR: &str = "FUSHI_G72B_CHILD_DIR";
const CHILD_AT: &str = "FUSHI_G72B_CRASH_AT";
const CRASHED: i32 = 87;

/// 子进程那一半：环境变量给了目录才动作。`prepare:n` = 补完报到第 n 次进度时、`seal` = 提交点（改名）之后封存之前，
/// 立刻 `exit`（等同被杀：不跑析构、不关连接）。
#[test]
fn prepare_child_process_half() {
    let Ok(dir) = std::env::var(CHILD_DIR) else {
        return;
    };
    let at = std::env::var(CHILD_AT).unwrap();
    let nth: Option<u64> = at.strip_prefix("prepare:").map(|n| n.parse().unwrap());
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
            progress: &mut |s, _, _| match nth {
                Some(nth) if s == Step::Prepare => {
                    seen += 1;
                    if seen == nth {
                        std::process::exit(CRASHED);
                    }
                }
                None if s == Step::Seal => std::process::exit(CRASHED),
                _ => {}
            },
            new_device: &fixed_device,
        },
    );
    panic!("the crash point {at} was never reached: {r:?}");
}

/// 子进程里迁移 [dir]，在 [at] 被杀。
fn crash_child(dir: &Path, at: &str) {
    let out = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "store::gen4::prepare::tests::prepare_child_process_half",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD_DIR, dir)
        .env(CHILD_AT, at)
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(CRASHED),
        "{at}: {}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

/// 补完途中进程被杀（每一条协议 3 命令之后各试一次；这一版的库与 v3.3.0 的库各一遍）：原件逐字节不变（写它的那个
/// 协议 3 版本打得开），重跑提交，结果都对拍通过。
#[test]
fn a_killed_completion_resumes() {
    for v330 in [false, true] {
        let base = unsynced_dir("g72b-kill", &|_| {});
        if v330 {
            downgrade_to_v3_3_0(&base.0);
        }
        let logs = count(&raw(&base.0), "SELECT COUNT(*) FROM srs_review_logs");
        let before = legacy_bytes(&base.0);
        for nth in [2u64, 4, 6] {
            let d = tempdir::new(&format!("g72b-kill-{nth}"));
            std::fs::copy(base.0.join(LEGACY_FILE), d.0.join(LEGACY_FILE)).unwrap();
            crash_child(&d.0, &format!("prepare:{nth}"));
            assert_original_untouched(&d.0, &before);
            if !v330 {
                assert_protocol_3_opens(&d.0, logs);
            }
            let out = migrate_with(&d.0, &caches(), &Stop::new());
            assert_committed(&d.0, &out, logs, 1);
        }
    }
}

/// 提交点（改名）之后、封存之前进程被杀：v3.3.0 的原件（schema 26，没被升级）与没有身份的原件都由下一次 Primary 打开
/// 按记下的指纹认出是迁移来源、补封，补完副本删掉；原件在那之后又被写过的，不封。
#[test]
fn a_kill_after_the_commit_point_seals_the_original_on_open() {
    for (tag, dir) in [
        ("v330", {
            let d = unsynced_dir("g72b-seal-v330", &|_| {});
            downgrade_to_v3_3_0(&d.0);
            d
        }),
        ("noid", no_identity_dir("g72b-seal-noid")),
    ] {
        crash_child(&dir.0, "seal");
        assert!(dir.0.join(GEN4_FILE).exists(), "{tag}");
        assert_ne!(schema_of(&dir.0), SEALED_SCHEMA, "{tag}");
        assert!(copy_left(&dir.0), "{tag}");
        drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
        assert_eq!(schema_of(&dir.0), SEALED_SCHEMA, "{tag}");
        assert!(!copy_left(&dir.0), "{tag}");
    }
    // 中断之后原件又被（旧版本）写过：指纹对不上，不封、不动它。
    let dir = no_identity_dir("g72b-seal-written");
    crash_child(&dir.0, "seal");
    raw(&dir.0)
        .execute(
            "UPDATE srs_entities SET created_at = created_at + 1 WHERE kind = 'deck'",
            [],
        )
        .unwrap();
    let before = legacy_bytes(&dir.0);
    drop(open_gen4(&dir.0, OpenMode::Primary));
    assert_ne!(schema_of(&dir.0), SEALED_SCHEMA);
    assert_eq!(legacy_bytes(&dir.0), before);
}

/// 一个孤儿 uid（[ORPHAN]：一副牌组、一条还没包成操作的旧复习日志）加在 P 已经包完的库上（P 不再需要补完）。
fn with_orphan(d: &Device) {
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
}

/// 发给 [profile] 的一条新代命令（经 C ABI，时刻在迁移之后）。
fn g4_as(
    h: *mut crate::store::ffi::SrsCoreHandle,
    profile: &str,
    op: &str,
    extra: Value,
) -> Result<Value, String> {
    let mut req = crate::store::gen4::cmd::dispatch_tests::g4req(op, NOW + 1_000, extra);
    req["profile"] = json!(profile);
    crate::store::gen4::cmd::dispatch_tests::call(h, &req, None)
        .map(|(v, _)| v)
        .map_err(|(rc, e)| format!("{rc} {e}"))
}

/// 并入做到一半（G9-5，修 G7-2b 的 `mergeHalfDone` 卡死）：迁移不拦，旧 uid（[ORPHAN]）与新 uid（P）各迁成一个集合，
/// 标记与 `meta_set_edit` 的集合原样带进新代库；`profile_merge_commit` 一个事务把旧 uid 的集合并进 P：P 的复习日志多了
/// 旧 uid 那一条（一条不丢），旧 uid 的绑定、标记、本机状态行都没了；`to` 对不上 / 再来一次都报错、什么都不改。
#[test]
fn a_half_done_merge_is_migrated_and_finished_in_the_new_generation() {
    let marker = json!({"profileId": 7, "newUid": P}).to_string();
    let dir = unsynced_dir("g95-merge", &|d| {
        with_orphan(d);
        let w = d.core.writer().unwrap();
        w.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2)",
            params![format!("profile_merge/{ORPHAN}"), marker],
        )
        .unwrap();
        w.execute(
            "INSERT INTO srs_meta (key, value) VALUES ('srs_retired_profile_uids', ?1)",
            [json!(["old-a"]).to_string()],
        )
        .unwrap();
    });
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    assert_committed(&dir.0, &out, logs, 2);
    let carried = |key: &str| -> Option<String> {
        Connection::open_with_flags(dir.0.join(GEN4_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap()
            .query_row("SELECT value FROM srs_meta WHERE key = ?1", [key], |r| {
                r.get(0)
            })
            .ok()
    };
    assert_eq!(
        carried(&format!("profile_merge/{ORPHAN}")),
        Some(marker.clone())
    );

    let h = crate::store::gen4::cmd::dispatch_tests::open(&dir.0, 0).unwrap();
    let uids = g4_as(h, P, "profile_uids", json!({})).unwrap();
    let mut want = vec![P, ORPHAN];
    want.sort();
    assert_eq!(uids["uids"], json!(want), "{uids}");
    assert_eq!(
        g4_as(h, P, "meta_set_edit", json!({"set": "retiredUids"})).unwrap(),
        json!({"values": ["old-a"]})
    );
    let p_reviews = g4_as(h, P, "profile_footprint", json!({})).unwrap()["reviews"]
        .as_i64()
        .unwrap();
    let o_reviews = g4_as(h, ORPHAN, "profile_footprint", json!({})).unwrap()["reviews"]
        .as_i64()
        .unwrap();
    assert_eq!(o_reviews, 1);

    // 标记说的是并进 P：并进别的 uid 报错。
    let e = g4_as(
        h,
        P,
        "profile_merge_commit",
        json!({"from": ORPHAN, "to": "0193a1b2-0000-7000-8000-00000000d00d"}),
    )
    .unwrap_err();
    assert!(e.contains("no half-done merge"), "{e}");
    let v = g4_as(
        h,
        P,
        "profile_merge_commit",
        json!({"from": ORPHAN, "to": P}),
    )
    .unwrap();
    assert_eq!(v["done"], json!(true), "{v}");
    assert_eq!(v["folded"], json!(true), "{v}");
    assert_eq!(v["bindingChanged"], json!({"profile": P}), "{v}");

    assert_eq!(
        g4_as(h, P, "profile_uids", json!({})).unwrap()["uids"],
        json!([P])
    );
    assert_eq!(
        g4_as(h, P, "profile_footprint", json!({})).unwrap()["reviews"],
        json!(p_reviews + o_reviews),
        "旧 uid 的复习日志并进来了"
    );
    let e = g4_as(h, ORPHAN, "binding_get", json!({})).unwrap_err();
    assert!(e.contains("has no collection"), "{e}");
    let e = g4_as(
        h,
        P,
        "profile_merge_commit",
        json!({"from": ORPHAN, "to": P}),
    )
    .unwrap_err();
    assert!(e.contains("no half-done merge"), "{e}");
    crate::store::ffi::ffsrs_store_close(h);
    assert_eq!(carried(&format!("profile_merge/{ORPHAN}")), None);
    assert_eq!(carried(&format!("local_state/{ORPHAN}")), None);
}

/// 升级路径（G9-5 补 G7-2b 复核遗留的变异缺口）：v3.3.0 的库升级之后**每个** profile 都要补完，包括升级之前已经包完、
/// 照前提核对不需要补完的 P。同一份库不降级时只补孤儿——两个分支给的清单不同，换掉任何一个都过不了。
#[test]
fn a_v3_3_0_upgrade_completes_every_profile_even_clean_ones() {
    let dir = unsynced_dir("g95-v330-all", &with_orphan);
    let p = plan_of(&dir.0);
    assert!(!p.upgrade);
    assert_eq!(p.profiles, vec![ORPHAN.to_owned()]);
    downgrade_to_v3_3_0(&dir.0);
    let p = plan_of(&dir.0);
    assert!(p.upgrade);
    let mut got = p.profiles.clone();
    got.sort();
    let mut want = vec![P.to_owned(), ORPHAN.to_owned()];
    want.sort();
    assert_eq!(got, want);
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    assert_committed(&dir.0, &out, logs, 2);
}

/// 新代库旁边一份更老 schema、没封存、又不是迁移来源的 `srs.db`（来源没有身份：要算整库摘要才判得出）：Primary 打开
/// 只在它的文件状态第一次出现时算一次摘要、记下结论，之后再打开不算；文件被动过就重判（G9-5 修 G7-2b 复核遗留）。
#[test]
fn an_unrelated_older_library_is_digested_once_per_file_state() {
    let dir = no_identity_dir("g95-digest");
    crash_child(&dir.0, "seal");
    raw(&dir.0)
        .execute_batch(
            "UPDATE srs_entities SET created_at = created_at + 1 WHERE kind = 'deck'; \
             UPDATE srs_meta SET value = '26' WHERE key = 'schema';",
        )
        .unwrap();
    let digests = || crate::store::gen4::files::DIGESTS.with(|n| n.get());
    let n0 = digests();
    drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
    assert_eq!(digests(), n0 + 1);
    assert_eq!(schema_of(&dir.0), 26, "不是迁移来源：不封");
    drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
    assert_eq!(digests(), n0 + 1, "同一个文件状态：不再算");
    raw(&dir.0)
        .execute(
            "UPDATE srs_entities SET created_at = created_at + 1 WHERE kind = 'deck'",
            [],
        )
        .unwrap();
    drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
    assert_eq!(digests(), n0 + 2, "文件动过：重判");
    assert_eq!(schema_of(&dir.0), 26);
}

/// G7-2b verify2 遗留（G9-5 补测）：补完之后的第二次空间核对按**在用**的副本算——副本不算可用空间。注入的可用空间在
/// 第二次核对时恰好比副本要的少 1 字节：副本若被算成可用（`PrepCopy::Stale`）就会放行，正确结论是 `noSpace`、原件不动、
/// 不留新代库。
#[test]
fn the_second_space_check_after_completion_does_not_count_the_copy_as_free() {
    let dir = unsynced_dir("g95-space2", &with_orphan);
    assert!(!plan_of(&dir.0).is_empty(), "夹具要补完");
    let before = legacy_bytes(&dir.0);
    let calls = std::rc::Rc::new(std::cell::Cell::new(0u32));
    let seen = calls.clone();
    migrate::FREE_BYTES.with(|f| {
        *f.borrow_mut() = Some(Box::new(move |d: &Path| {
            // 补完副本出来之前的核对（开跑与拷副本前）都放行；副本出来之后的那一次卡在「副本要的 - 1」。
            let copy = d.join(crate::store::gen4::files::PREPARE_COPY);
            if !copy.exists() {
                return Some(u64::MAX / 4);
            }
            seen.set(seen.get() + 1);
            Some(migrate::space_needed_for_tests(&copy).unwrap() - 1)
        }));
    });
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    migrate::FREE_BYTES.with(|f| *f.borrow_mut() = None);
    assert_eq!(calls.get(), 1, "补完之后核对一次");
    assert!(matches!(out, migrate::Outcome::NoSpace { .. }), "{out:?}");
    assert_original_untouched(&dir.0, &before);
    assert!(!dir.0.join(GEN4_FILE).exists());
}

/// 真实的半截并入（G9-5 复核补测）：协议 3 并入在中断前已经把旧 uid 的复习日志按兜底 ID
/// （`v5(NS, profile-merge/<P>/<旧 ID>)`，卡片同样兜底）落进 P。收尾把旧 uid 的原件再导进 P 之后，别名层把副本归回原件：
/// 复习日志按规范 ID 数不多出一条，兜底 ID 与原件的规范 ID 相同；旧 uid 的默认牌组（按旧 uid 派生）与 P 的归成同一个。
#[test]
fn a_half_done_merge_with_remapped_copies_folds_them_back_into_one() {
    use crate::gen4_ids::rules::merge_fallback;
    const E9: &str = "0193a1b2-0000-7000-8000-0000000000e9";
    const C9: &str = "0193a1b2-0000-7000-8000-0000000000c9";
    let marker = json!({"profileId": 7, "newUid": P}).to_string();
    let dir = unsynced_dir("g95-merge-copies", &|d| {
        with_orphan(d);
        // 协议 3 并入的第一遍已经落进 P 的副本（并入经 `applyRemote` 写，是 P 里的操作）：日志与卡都按兜底 ID。
        d.apply(
            T0 + 20,
            vec![review(
                &merge_fallback(P, E9).text(),
                &merge_fallback(P, C9).text(),
                T0 - 600,
                3,
                "review",
            )],
        );
        let w = d.core.writer().unwrap();
        w.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2)",
            params![format!("profile_merge/{ORPHAN}"), marker],
        )
        .unwrap();
    });
    let logs = count(&raw(&dir.0), "SELECT COUNT(*) FROM srs_review_logs");
    let out = migrate_with(&dir.0, &caches(), &Stop::new());
    assert_committed(&dir.0, &out, logs, 2);
    let h = crate::store::gen4::cmd::dispatch_tests::open(&dir.0, 0).unwrap();
    let reviews = |profile: &str| {
        g4_as(h, profile, "profile_footprint", json!({})).unwrap()["reviews"]
            .as_i64()
            .unwrap()
    };
    let p_before = reviews(P);
    assert_eq!(reviews(ORPHAN), 1);
    let v = g4_as(
        h,
        P,
        "profile_merge_commit",
        json!({"from": ORPHAN, "to": P}),
    )
    .unwrap();
    assert_eq!(v["folded"], json!(true), "{v}");
    assert_eq!(reviews(P), p_before, "兜底副本与原件是同一条，不多出一条");
    let ids = g4_as(
        h,
        P,
        "canonical_ids",
        json!({"ids": [merge_fallback(P, E9).text(), E9,
                       default_deck_id(ORPHAN), default_deck_id(P)]}),
    )
    .unwrap()["ids"]
        .clone();
    assert_eq!(ids[0], ids[1], "兜底 ID 归回原件：{ids}");
    assert_eq!(ids[2], ids[3], "两个 uid 派生的默认牌组是同一个：{ids}");
    crate::store::ffi::ffsrs_store_close(h);
}
