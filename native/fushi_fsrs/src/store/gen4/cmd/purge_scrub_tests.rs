//! 彻底清除的字节层（`scrub.rs`，交接 §26 C3）：清除之后按字节扫 `srs4.db` 与 `srs4.db-wal`，本机与对端都读不到原文；
//! 写连接开着 `secure_delete`、新库带「从建库起就开着」的标记；没有标记的存量库（空闲空间里躺着更早的旧内容）在
//! 第一次清除收尾时整理一次。

use std::path::Path;

use serde_json::json;

use super::dispatch_tests::{T1, open};
use super::sync_tests::{Dev, Loc, Opts, cmd, sync_all};
use super::tests::{N1, N2};
use crate::store::ffi::ffsrs_store_close;
use crate::store::gen4::files::GEN4_FILE;
use crate::store::gen4::scrub::{DUE_KEY, SECURE_KEY};

/// [dir] 里新代库文件与 WAL 中 [needle] 出现的次数（按字节）。
fn bytes_carrying(dir: &Path, needle: &str) -> usize {
    let needle = needle.as_bytes();
    ["", "-wal"]
        .iter()
        .filter_map(|s| std::fs::read(dir.join(format!("{GEN4_FILE}{s}"))).ok())
        .map(|b| b.windows(needle.len()).filter(|w| *w == needle).count())
        .sum()
}

/// `srs_meta` 里有没有 [key]：另开一条只读连接读（不经内核打开——内核打开时会把欠着的收尾做掉）。
fn meta_has(d: &Dev, key: &str) -> bool {
    let c = rusqlite::Connection::open_with_flags(
        d.dir.0.join(GEN4_FILE),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    c.query_row(
        "SELECT EXISTS (SELECT 1 FROM srs_meta WHERE key = ?1)",
        [key],
        |r| r.get(0),
    )
    .unwrap()
}

fn purge(d: &Dev, now: i64, note: &str) {
    let (v, _) = cmd(
        d.h,
        "purge",
        now,
        json!({"kind": "note", "entities": [note]}),
        &[],
    );
    assert!(v.get("localRevision").is_some(), "{v}");
}

/// a 写两次带标记串的字段、同步给 b，b 再写一次，a 清除，再同步：两台设备的库文件与 WAL 里都扫不到标记串（句柄开着，
/// 不靠关库时的检查点）；欠着的收尾已做完。
#[test]
fn a_purge_leaves_no_bytes_of_the_text_in_the_library_files() {
    let a = Dev::new("c3pa");
    let b = Dev::new("c3pb");
    a.write(T1 + 1, N1, "secret-c3-one");
    a.write(T1 + 2, N1, "secret-c3-two");
    a.write(T1 + 2, N2, "keep-c3");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 3, Opts::default());
    b.write(T1 + 4, N1, "secret-c3-three");
    sync_all(&[&a, &b], &mut loc, T1 + 5, Opts::default());
    assert!(bytes_carrying(&a.dir.0, "secret-c3") > 0);
    assert!(bytes_carrying(&b.dir.0, "secret-c3") > 0);

    purge(&a, T1 + 6, N1);
    sync_all(&[&a, &b], &mut loc, T1 + 7, Opts::default());
    for d in [&a, &b] {
        assert_eq!(bytes_carrying(&d.dir.0, "secret-c3"), 0, "{}", d.device());
        assert!(bytes_carrying(&d.dir.0, "keep-c3") > 0, "other notes stay");
        assert!(!meta_has(d, DUE_KEY), "the byte-level pass is done");
    }
}

/// 新库：写连接开着 `secure_delete`，库上记着「从建库起就开着」。
#[test]
fn a_new_library_is_secure_deleting_from_birth() {
    let mut a = Dev::new("c3sd");
    assert!(meta_has(&a, SECURE_KEY));
    let on: i64 = a.direct(|t, _| {
        t.conn()
            .query_row("PRAGMA secure_delete", [], |r| r.get(0))
            .map_err(|e| e.to_string())
    });
    assert_eq!(on, 1);
}

/// 存量库（没有标记，空闲空间里躺着不开 `secure_delete` 时删掉的旧内容）：第一次清除收尾时整库整理一次，旧内容没了，
/// 记上标记。
#[test]
fn a_library_without_the_mark_is_compacted_on_its_first_purge() {
    let mut a = Dev::new("c3old");
    a.write(T1, N1, "keep-c3");
    ffsrs_store_close(a.h);
    {
        let c = rusqlite::Connection::open(a.dir.0.join(GEN4_FILE)).unwrap();
        c.execute_batch(
            "PRAGMA secure_delete = OFF;
             INSERT INTO srs_meta (key, value) VALUES ('junk', 'garbage-c3-' || hex(randomblob(64)));
             DELETE FROM srs_meta WHERE key = 'junk';",
        )
        .unwrap();
        c.execute("DELETE FROM srs_meta WHERE key = ?1", [SECURE_KEY])
            .unwrap();
    }
    a.h = open(&a.dir.0, 0).unwrap();
    assert!(
        bytes_carrying(&a.dir.0, "garbage-c3") > 0,
        "stale bytes in free space"
    );
    a.write(T1 + 1, N2, "secret-c3");
    purge(&a, T1 + 2, N2);
    assert_eq!(bytes_carrying(&a.dir.0, "garbage-c3"), 0);
    assert_eq!(bytes_carrying(&a.dir.0, "secret-c3"), 0);
    assert!(bytes_carrying(&a.dir.0, "keep-c3") > 0);
    assert!(meta_has(&a, SECURE_KEY));
    assert!(!meta_has(&a, DUE_KEY));
}

/// 收尾欠着（进程在提交与收尾之间被杀）：库里记着，下一次打开就做。
#[test]
fn an_owed_byte_level_pass_runs_on_the_next_open() {
    let mut a = Dev::new("c3due");
    a.write(T1, N1, "keep-c3");
    ffsrs_store_close(a.h);
    {
        let c = rusqlite::Connection::open(a.dir.0.join(GEN4_FILE)).unwrap();
        c.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, '1')",
            [DUE_KEY],
        )
        .unwrap();
    }
    a.h = open(&a.dir.0, 0).unwrap();
    assert!(!meta_has(&a, DUE_KEY));
}
