//! 彻底清除的字节层（`scrub.rs`，交接 §26 C3）：清除之后按字节扫 `srs4.db` 与 `srs4.db-wal`，本机与对端都读不到原文；
//! 写连接开着 `secure_delete`、新库带「从建库起就开着」的标记；没有标记的存量库（空闲空间里躺着更早的旧内容）在
//! 第一次清除收尾时整理一次。

use std::path::Path;

use serde_json::json;

use super::dispatch_tests::{T1, open};
use super::sync_relay_tests::{relay, relay_segs};
use super::sync_tests::{Dev, Loc, Opts, cmd, round, sync_all};
use super::tests::{N1, N2};
use crate::gen4::relay::open_relay4_items;
use crate::gen4::segment::NativeItem;
use crate::store::ffi::ffsrs_store_close;
use crate::store::gen4::files::GEN4_FILE;
use crate::store::gen4::scrub::{DUE_KEY, SECURE_KEY};
use crate::sync2::id::Id;

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

/// [d] 的转发缓存里，作者 [author] 的件中载荷带着 [needle] 的操作条数（解开中继件逐项看，不靠库文件的字节——段体是
/// zstd 压缩的，按字节扫不出来）。
fn relay_ops_carrying(d: &mut Dev, author: &str, needle: &str) -> usize {
    let author = Id::parse(author).unwrap();
    d.direct(|t, col| {
        let public = t.device_key(col, &author)?.ok_or("no key")?;
        let pieces: Vec<Vec<u8>> = {
            let mut stmt = t
                .conn()
                .prepare("SELECT piece FROM relay_segs WHERE col = ?1 AND device = ?2")
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(rusqlite::params![col, &author.0[..]], |r| r.get(0))
                .map_err(|e| e.to_string())?;
            rows.collect::<rusqlite::Result<_>>()
                .map_err(|e| e.to_string())?
        };
        let mut n = 0;
        for p in pieces {
            let (_, items) = open_relay4_items(&p, &public, None).map_err(|e| format!("{e:?}"))?;
            n += ops_carrying(&items, needle);
        }
        Ok(n)
    })
}

fn ops_carrying(items: &[NativeItem], needle: &str) -> usize {
    let needle = needle.as_bytes();
    items
        .iter()
        .filter(|i| match i {
            NativeItem::Op(op) => op.payload.windows(needle.len()).any(|w| w == needle),
            NativeItem::Void { .. } => false,
        })
        .count()
}

/// 作者 [author] 自己库里记着的本机公钥。
fn public_of(author: &mut Dev) -> [u8; 32] {
    let id = Id::parse(&author.device()).unwrap();
    author.direct(|t, col| t.device_key(col, &id)?.ok_or_else(|| "no key".to_owned()))
}

/// 明文位置 [loc] 上作者 [author]（公钥 [public]）的 `rly-` 转发件：(份数, 载荷带着 [needle] 的操作条数)。
fn relayed_at(loc: &Loc, author: &str, public: &[u8; 32], needle: &str) -> (usize, usize) {
    let (mut files, mut n) = (0, 0);
    for (k, bytes) in loc {
        if !(k.contains(author) && k.contains("/rly-")) {
            continue;
        }
        files += 1;
        let (_, items) = open_relay4_items(bytes, public, None).unwrap();
        n += ops_carrying(&items, needle);
    }
    (files, n)
}

/// 这一轮 plan 要拉的文件里有没有作者 [author] 的。
fn fetches_from(plan: &serde_json::Value, author: &str) -> bool {
    plan["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|f| f["files"].as_array().unwrap().iter())
        .any(|p| p.as_str().unwrap().contains(author))
}

/// 转发缓存（`cmd/sync_relay.rs`，交接 §26 C3 复核）：a 只连 L1、c 只连 L2、b 两个都连。b 收下 a 的段、留着原文准备
/// 转发到 L2；a 清除之后 b 收到清除，同一个事务里留着的原文删掉；作者重切出带空洞的同名段之后 b 为转发再拉一次，转发到
/// L2 的件里没有被清除的内容，c 照样收齐其余的。
#[test]
fn a_purge_drops_the_relay_copy_and_only_the_voided_segment_is_relayed_on() {
    let mut a = Dev::new("c3ra");
    let mut b = Dev::new("c3rb");
    let c = Dev::new("c3rc");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    round(&b, &mut l1, "L1", T1, plain);
    round(&b, &mut l2, "L2", T1, plain);
    round(&c, &mut l2, "L2", T1, plain);
    a.write(T1 + 1, N1, "secret-c3-relay");
    a.write(T1 + 1, N2, "keep-c3");
    round(&a, &mut l1, "L1", T1 + 2, plain);
    round(&b, &mut l1, "L1", T1 + 3, plain);
    let da = a.device();
    assert_eq!(relay_ops_carrying(&mut b, &da, "secret-c3-relay"), 1);

    purge(&a, T1 + 4, N1);
    round(&a, &mut l1, "L1", T1 + 5, plain);
    round(&b, &mut l1, "L1", T1 + 6, plain);
    assert_eq!(relay_ops_carrying(&mut b, &da, "secret-c3-relay"), 0);
    assert_eq!(bytes_carrying(&b.dir.0, "secret-c3-relay"), 0);

    // 下一轮为转发再拉作者重切的同名段（带空洞），转发到 L2。
    round(&b, &mut l1, "L1", T1 + 7, plain);
    assert!(relay_ops_carrying(&mut b, &da, "keep-c3") > 0);
    relay(&b, &mut l2, "L2", None, T1 + 8);
    let public = public_of(&mut a);
    let (files, carrying) = relayed_at(&l2, &da, &public, "secret-c3-relay");
    assert!(files > 0, "a's segments reach L2");
    assert_eq!(carrying, 0);
    for _ in 0..2 {
        round(&c, &mut l2, "L2", T1 + 9, plain);
    }
    assert_eq!(c.field(N2), Some(json!("keep-c3")));
    assert_eq!(bytes_carrying(&c.dir.0, "secret-c3-relay"), 0);
}

/// 清除由 b 发起、作者 a 一直没回来重切：b 删掉留着的原文；为转发再拉回来的还是原文，不留，记下拒收；a 没写新 head
/// 之前不再为它拉；这位作者的转发整台跳过（`incomplete`），L2 上没有它的件。
#[test]
fn an_unrecut_segment_carrying_purged_text_is_refused_once_and_not_refetched() {
    let mut a = Dev::new("c3fa");
    let mut b = Dev::new("c3fb");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    round(&b, &mut l1, "L1", T1, plain);
    round(&b, &mut l2, "L2", T1, plain);
    a.write(T1 + 1, N1, "secret-c3-refuse");
    a.write(T1 + 1, N2, "keep-c3");
    round(&a, &mut l1, "L1", T1 + 2, plain);
    round(&b, &mut l1, "L1", T1 + 3, plain);
    let da = a.device();
    assert_eq!(relay_ops_carrying(&mut b, &da, "secret-c3-refuse"), 1);

    purge(&b, T1 + 4, N1);
    assert_eq!(relay_segs(&mut b), 0);
    let r = round(&b, &mut l1, "L1", T1 + 5, plain);
    assert!(
        fetches_from(&r.plan, &da),
        "fetched again for relay: {}",
        r.plan
    );
    assert_eq!(relay_segs(&mut b), 0, "the refetched original is refused");
    let r = round(&b, &mut l1, "L1", T1 + 6, plain);
    assert!(!fetches_from(&r.plan, &da), "not refetched: {}", r.plan);

    let (v, _) = cmd(
        b.h,
        "relay_outbox",
        T1 + 7,
        json!({"location": "L2", "key": null}),
        &[],
    );
    assert_eq!(v["incomplete"], json!([da]), "{v}");
    relay(&b, &mut l2, "L2", None, T1 + 7);
    let public = public_of(&mut a);
    assert_eq!(relayed_at(&l2, &da, &public, "secret-c3-refuse"), (0, 0));
    assert_eq!(bytes_carrying(&b.dir.0, "secret-c3-refuse"), 0);
}

/// 新库：写连接开着 `secure_delete`，库上记着「从建库起就开着」。

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

/// 导入带来的清除（`import.rs` 的灌入收尾）：b 写的内容同步给 a，a 清除后导出，b 导入 a 的文件——同一个事务里把 b 自己
/// 那条操作落成空洞、字节层收尾，不留到下一条写命令。
#[test]
fn a_purge_carried_by_an_import_voids_the_text_at_once() {
    let a = Dev::new("c3ia");
    let b = Dev::new("c3ib");
    b.write(T1, N1, "secret-c3-imp");
    b.write(T1, N2, "keep-c3");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 1, Opts::default());
    let (v, _) = cmd(
        b.h,
        "trust",
        T1 + 2,
        json!({"device": a.device(), "trust": true}),
        &[],
    );
    assert_eq!(v["trusted"], json!(true), "{v}");
    purge(&a, T1 + 3, N1);
    let path = a.dir.0.join("export-c3.bin");
    cmd(
        a.h,
        "export",
        T1 + 4,
        json!({"path": path.to_str().unwrap()}),
        &[],
    );
    assert!(bytes_carrying(&b.dir.0, "secret-c3-imp") > 0);
    let (got, _) = cmd(
        b.h,
        "import",
        T1 + 5,
        json!({"path": path.to_str().unwrap()}),
        &[],
    );
    assert!(got.get("outcome").is_some(), "{got}");
    assert_eq!(bytes_carrying(&b.dir.0, "secret-c3-imp"), 0);
    assert!(bytes_carrying(&b.dir.0, "keep-c3") > 0);
    assert!(!meta_has(&b, DUE_KEY));
}
