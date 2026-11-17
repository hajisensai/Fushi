//! [super]（保留副本的到期与删除，D32）的测试：迁移记下提交时刻、到期规则（第一次同步成功 + 14 天 / 迁移 + 30 天）、
//! Primary 开库时到期自动换墓碑（旧版本随后照样拒绝）、立即删除（不看到期）、核对不过不删、自动删没做成不挡开库且
//! 原因可读。

use std::collections::BTreeMap;
use std::path::Path;

use rusqlite::Connection;
use serde_json::{Value, json};

use super::*;
use crate::store::SrsCore;
use crate::store::gen4::dryrun::Stop;
use crate::store::gen4::dryrun::tests::{T0, cfg, library};
use crate::store::gen4::files::{OpenMode, open_gen4};
use crate::store::gen4::kernel::global;
use crate::store::gen4::migrate::{self, Outcome};
use crate::store::sync2::tests::{Device, P, tempdir};
use crate::sync2::id::Id;

const NOW: i64 = T0 + 30 * 86_400_000;

/// 一个迁移提交、封存了的目录（迁移时刻 [NOW]）。
fn migrated(tag: &str) -> tempdir::Dir {
    let Device { core, _dir } = library(tag);
    core.close();
    drop(core);
    let caches = BTreeMap::from([(P.to_owned(), cfg())]);
    let out = migrate::run(
        &_dir.0,
        migrate::Options {
            caches: &caches,
            batch: 2,
            now_ms: NOW,
            stop: &Stop::new(),
            progress: &mut |_, _, _| {},
            new_device: &|_, _| Id([0x4e; 16]),
        },
    )
    .unwrap();
    assert!(matches!(out, Outcome::Committed { .. }), "{out:?}");
    _dir
}

fn gen4(dir: &Path) -> Connection {
    Connection::open(dir.join(GEN4_FILE)).unwrap()
}

fn set_meta(dir: &Path, key: &str, value: &str) {
    gen4(dir)
        .execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value],
        )
        .unwrap();
}

fn state_of(dir: &Path, now: i64) -> Value {
    global(
        "gen4_retained_state",
        &json!({"dir": dir.display().to_string(), "now": now}),
    )
    .unwrap()
}

fn delete_now(dir: &Path) -> Result<Value, String> {
    global(
        "gen4_retained_delete",
        &json!({"dir": dir.display().to_string()}),
    )
}

/// 新代库文件末尾多一页没人用的页（文件头的页数跟着改）：打得开、照常读写，完整性核对报「从没用过的页」。返回原来的字节。
fn add_unused_page(dir: &Path) -> Vec<u8> {
    let path = dir.join(GEN4_FILE);
    let good = std::fs::read(&path).unwrap();
    let mut bad = good.clone();
    let page = u16::from_be_bytes([bad[16], bad[17]]) as usize;
    let page = if page == 1 { 65_536 } else { page };
    let pages = (bad.len() / page) as u32;
    bad[28..32].copy_from_slice(&(pages + 1).to_be_bytes());
    bad.extend(std::iter::repeat_n(0u8, page));
    std::fs::write(&path, &bad).unwrap();
    good
}

/// 旧版本（协议 3 的内核）打不开原路径上的库：封存与墓碑都一样拒绝，不会建一个空库照常跑。
fn assert_refused_by_protocol_3(dir: &Path) {
    let err = SrsCore::open(&dir.join(LEGACY_FILE))
        .map(|_| ())
        .unwrap_err();
    assert!(err.contains("newer"), "{err}");
}

/// 迁移在提交前记下提交时刻；从没同步过的保留副本在迁移 30 天后到期，状态命令报副本在、大小、到期时刻。
#[test]
fn the_migration_records_its_commit_time_and_starts_a_30_day_clock() {
    let dir = migrated("d32-clock");
    let s = state_of(&dir.0, NOW);
    assert_eq!(s["copy"], "sealed", "{s}");
    assert!(s["bytes"].as_u64().unwrap() > 0, "{s}");
    assert_eq!(s["migratedAtMs"], NOW, "{s}");
    assert_eq!(s["firstSyncAtMs"], Value::Null, "{s}");
    assert_eq!(s["dueAtMs"], NOW + WITHOUT_SYNC_MS, "{s}");
    assert_eq!(s["due"], false, "{s}");
    assert_eq!(state_of(&dir.0, NOW + WITHOUT_SYNC_MS)["due"], true);
}

/// 第一次同步成功之后改按它再留 14 天；只记第一次。没有这一行、但位置记过成功（之前的版本同步过）的按最早的那次。
#[test]
fn the_first_sync_moves_the_clock_to_14_days_after_it() {
    let dir = migrated("d32-sync");
    {
        let c = gen4(&dir.0);
        c.execute(
            "INSERT INTO loc_state (col, loc_key, sealed, last_ok) VALUES (1, 'a', 0, ?1), (1, 'b', 0, ?2)",
            [NOW + 7, NOW + 5],
        )
        .unwrap();
    }
    assert_eq!(
        state_of(&dir.0, NOW)["dueAtMs"],
        NOW + 5 + AFTER_FIRST_SYNC_MS
    );
    let c = gen4(&dir.0);
    note_first_sync(&c, NOW + 100).unwrap();
    note_first_sync(&c, NOW + 200).unwrap();
    drop(c);
    let s = state_of(&dir.0, NOW + 100 + AFTER_FIRST_SYNC_MS);
    assert_eq!(s["firstSyncAtMs"], NOW + 100, "{s}");
    assert_eq!(s["dueAtMs"], NOW + 100 + AFTER_FIRST_SYNC_MS, "{s}");
    assert_eq!(s["due"], true, "{s}");
}

/// Primary 开库：没到期什么都不动；到期了换成墓碑库（旧版本照样拒绝），新代库照常打开，状态报墓碑、不再到期。
#[test]
fn opening_replaces_an_expired_copy_with_a_tombstone() {
    let dir = migrated("d32-sweep");
    // 测试的迁移时刻在过去：先挪到很远的将来，开库不该动它。
    set_meta(&dir.0, MIGRATED_AT_KEY, &i64::MAX.to_string());
    drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
    assert!(
        matches!(inspect(&dir.0), CopyState::Sealed { .. }),
        "not due yet: kept"
    );
    // 迁移时刻改到很久以前：到期。
    set_meta(&dir.0, MIGRATED_AT_KEY, "0");
    let opened = open_gen4(&dir.0, OpenMode::Primary).unwrap();
    assert!(!opened.retained_copy_unreadable);
    drop(opened);
    assert_eq!(inspect(&dir.0), CopyState::Tombstone);
    assert_refused_by_protocol_3(&dir.0);
    let s = state_of(&dir.0, NOW);
    assert_eq!(s["copy"], "tombstone", "{s}");
    assert_eq!(s["due"], false, "{s}");
    assert_eq!(s["error"], Value::Null, "{s}");
}

/// 立即删除不看到期：换墓碑、回释放的字节数；再删一次什么都不动（`absent`）；换代锁被别人拿着时不删（`migrating`）。
#[test]
fn deleting_now_ignores_the_clock_and_is_idempotent() {
    let dir = migrated("d32-now");
    let bytes = state_of(&dir.0, NOW)["bytes"].as_u64().unwrap();
    let lock = GenLock::try_acquire(&dir.0).unwrap().unwrap();
    assert_eq!(
        delete_now(&dir.0).unwrap(),
        json!({"deleted": false, "reason": "migrating"})
    );
    drop(lock);
    assert!(matches!(inspect(&dir.0), CopyState::Sealed { .. }));
    assert_eq!(
        delete_now(&dir.0).unwrap(),
        json!({"deleted": true, "freedBytes": bytes})
    );
    assert_eq!(inspect(&dir.0), CopyState::Tombstone);
    assert_refused_by_protocol_3(&dir.0);
    assert_eq!(
        delete_now(&dir.0).unwrap(),
        json!({"deleted": false, "reason": "absent"})
    );
    // 新代库照常打开。
    drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
}

/// 新代库打不开（不是建好的新代库）或完整性核对不过：不删，保留副本原样（它是唯一完好的数据）。
#[test]
fn a_bad_generation_4_library_keeps_the_copy() {
    let dir = migrated("d32-bad");
    let path = dir.0.join(GEN4_FILE);
    let good = add_unused_page(&dir.0);
    let err = delete_now(&dir.0).unwrap_err();
    assert!(err.contains("integrity check"), "{err}");
    assert!(matches!(inspect(&dir.0), CopyState::Sealed { .. }));
    // 根本不是新代库。
    std::fs::write(&path, b"not a database").unwrap();
    assert!(delete_now(&dir.0).is_err());
    assert!(matches!(inspect(&dir.0), CopyState::Sealed { .. }));
    std::fs::write(&path, &good).unwrap();
    // 新代库完好：核对之后再删。
    assert_eq!(delete_now(&dir.0).unwrap()["deleted"], true);
}

/// 到期自动删（开库时、不经用户确认的那条路）同样先核对新代库：完整性核对不过不删，保留副本原样，原因记进库里、状态
/// 命令报出来；新代库照常打开。
#[test]
fn an_expired_copy_is_kept_when_generation_4_fails_its_check_on_open() {
    let dir = migrated("d32-sweep-bad");
    set_meta(&dir.0, MIGRATED_AT_KEY, "0");
    add_unused_page(&dir.0);
    let opened = open_gen4(&dir.0, OpenMode::Primary).unwrap();
    assert!(!opened.retained_copy_unreadable);
    drop(opened);
    assert!(matches!(inspect(&dir.0), CopyState::Sealed { .. }));
    let s = state_of(&dir.0, NOW);
    assert_eq!(s["copy"], "sealed", "{s}");
    assert!(
        s["error"].as_str().unwrap().contains("integrity check"),
        "{s}"
    );
}

/// 立即删除不碰新代库的写锁：别的连接（比如正在跑的同步）占着写锁时照样删成、报 `deleted: true`，不会墓碑已经换上却
/// 报「没删」。
#[test]
fn deleting_now_succeeds_while_another_connection_holds_the_write_lock() {
    let dir = migrated("d32-busy");
    set_meta(&dir.0, ERROR_KEY, "an earlier sweep failed");
    let writer = gen4(&dir.0);
    writer.execute_batch("BEGIN IMMEDIATE").unwrap();
    let out = delete_now(&dir.0).unwrap();
    writer.execute_batch("ROLLBACK").unwrap();
    drop(writer);
    assert_eq!(out["deleted"], true, "{out}");
    assert_eq!(inspect(&dir.0), CopyState::Tombstone);
    // 陈旧的原因：副本不在了就不报，下一次 Primary 开库删掉。
    assert_eq!(state_of(&dir.0, NOW)["error"], Value::Null);
    drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
    let left: Option<String> = gen4(&dir.0)
        .query_row(
            "SELECT value FROM srs_meta WHERE key = ?1",
            [ERROR_KEY],
            |r| r.get(0),
        )
        .optional()
        .unwrap();
    assert_eq!(left, None);
}

/// 到期自动删没做成（这里：保留副本记的封存目标不在旁边，墓碑拒绝盖上去）：不挡开库，副本原样，原因记进库里、状态命令
/// 报出来；之后手动删成了就清掉原因。
#[test]
fn a_failed_sweep_does_not_block_opening_and_is_reported() {
    let dir = migrated("d32-fail");
    set_meta(&dir.0, MIGRATED_AT_KEY, "0");
    let legacy = Connection::open(dir.0.join(LEGACY_FILE)).unwrap();
    legacy
        .execute(
            "UPDATE srs_meta SET value = 'elsewhere.db' WHERE key = 'sealed_into'",
            [],
        )
        .unwrap();
    drop(legacy);
    drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
    assert!(matches!(inspect(&dir.0), CopyState::Sealed { .. }));
    let s = state_of(&dir.0, NOW);
    assert_eq!(s["due"], true, "{s}");
    assert!(s["error"].as_str().unwrap().contains("elsewhere.db"), "{s}");
    // 修好封存目标后手动删：成了，原因清掉。
    let legacy = Connection::open(dir.0.join(LEGACY_FILE)).unwrap();
    legacy
        .execute(
            "UPDATE srs_meta SET value = 'srs4.db' WHERE key = 'sealed_into'",
            [],
        )
        .unwrap();
    drop(legacy);
    assert_eq!(delete_now(&dir.0).unwrap()["deleted"], true);
    assert_eq!(state_of(&dir.0, NOW)["error"], Value::Null);
}

/// 没有保留副本的目录（全新安装）：状态报 `absent`，删除什么都不动。
#[test]
fn a_fresh_install_has_nothing_to_delete() {
    let dir = tempdir::new("d32-fresh");
    drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
    let s = state_of(&dir.0, NOW);
    assert_eq!(s["copy"], "absent", "{s}");
    assert_eq!(s["dueAtMs"], Value::Null, "{s}");
    assert_eq!(
        delete_now(&dir.0).unwrap(),
        json!({"deleted": false, "reason": "absent"})
    );
}
