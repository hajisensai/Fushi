//! 彻底清除的字节层（`scrub.rs`，交接 §26 C3）：清除之后按字节扫 `srs4.db` 与 `srs4.db-wal`，本机与对端都读不到原文；
//! 写连接开着 `secure_delete`、新库带「从建库起就开着」的标记；没有标记的存量库（空闲空间里躺着更早的旧内容）在
//! 第一次清除收尾时整理一次。

use std::path::Path;

use serde_json::json;

use super::dispatch_tests::{T1, open};
use super::sync_relay_tests::{relay, relay_segs};
use super::sync_tests::{Dev, Loc, Opts, cmd, round, sync_all};
use super::tests::{N1, N2, N3};
use crate::gen4::recut::{self, open_recut4_items, peek_recut4};
use crate::gen4::relay::{open_relay4_items, peek_relay4};
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

/// 解开一份不封装的转发件：中继件 `FRL4`（作者签）或重切件 `FRX4`（重切者签）。签名者的公钥由 [key_of] 按设备给。
/// 回 (重切者, 全部项)。
fn piece_items(bytes: &[u8], key_of: &dyn Fn(&Id) -> [u8; 32]) -> (Option<Id>, Vec<NativeItem>) {
    if bytes.starts_with(recut::MAGIC) {
        let peek = peek_recut4(bytes).unwrap();
        let (a, r) = (peek.header.device, peek.recutter);
        let (_, items) = open_recut4_items(bytes, &key_of(&a), &key_of(&r), None).unwrap();
        (Some(r), items)
    } else {
        let a = peek_relay4(bytes).unwrap().header.device;
        let (_, items) = open_relay4_items(bytes, &key_of(&a), None).unwrap();
        (None, items)
    }
}

/// [d] 的转发缓存里，作者 [author] 的件：(份数, 其中重切件的份数, 载荷带着 [needle] 的操作条数)。逐项解开看，不靠库
/// 文件的字节——段体是 zstd 压缩的，按字节扫不出来。
fn kept_of(d: &mut Dev, author: &str, needle: &str) -> (usize, usize, usize) {
    let author = Id::parse(author).unwrap();
    d.direct(|t, col| {
        let me = t.self_identity(col)?.ok_or("no identity")?;
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
        let key_of = |d: &Id| {
            if *d == me.device {
                me.public()
            } else {
                t.device_key(col, d).unwrap().unwrap()
            }
        };
        let (mut recuts, mut n) = (0, 0);
        for p in &pieces {
            let (r, items) = piece_items(p, &key_of);
            recuts += usize::from(r.is_some());
            n += ops_carrying(&items, needle);
        }
        Ok((pieces.len(), recuts, n))
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

/// 设备 [d] 自己的 (设备, 公钥)。
fn key_pair(d: &mut Dev) -> (Id, [u8; 32]) {
    d.direct(|t, col| {
        let me = t.self_identity(col)?.ok_or("no identity")?;
        Ok((me.device, me.public()))
    })
}

/// 明文位置 [loc] 上作者 [author] 的 `rly-` 转发件：(份数, 重切者, 载荷带着 [needle] 的操作条数)。[keys] = 认得的
/// 设备公钥。
fn relayed_at(
    loc: &Loc,
    author: &str,
    keys: &[(Id, [u8; 32])],
    needle: &str,
) -> (usize, Vec<Id>, usize) {
    let key_of = |d: &Id| keys.iter().find(|(k, _)| k == d).unwrap().1;
    let (mut files, mut by, mut n) = (0, Vec::new(), 0);
    for (k, bytes) in loc {
        if !(k.contains(author) && k.contains("/rly-")) {
            continue;
        }
        files += 1;
        let (r, items) = piece_items(bytes, &key_of);
        by.extend(r);
        n += ops_carrying(&items, needle);
    }
    (files, by, n)
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

/// [d] 在 [loc] 上同步 [n] 轮，回最后一轮 ingest 的等待数（没有可收的段时为 0）。
fn settle(d: &Dev, loc: &mut Loc, location: &str, now: i64, n: usize) -> u64 {
    let mut pending = 0;
    for _ in 0..n {
        let r = round(d, loc, location, now, Opts::default());
        pending = r
            .ingest
            .last()
            .map_or(0, |v| v["pending"].as_u64().unwrap());
    }
    pending
}

/// 转发缓存（`cmd/sync_relay.rs`，交接 §26 C3 / §33）：a 只连 L1、c 只连 L2、b 两个都连。b 收下 a 的段、留着原文准备
/// 转发到 L2，还没转发就由 b 自己清除（作者 a 不在场）：同一个事务里把留着的那份**原地重切**（换成 b 签的、带空洞的
/// 同名件），转发到 L2 的是重切件；c 收齐 a 其余的与 b 此后的。
#[test]
fn a_purge_recuts_the_relay_copy_in_place_and_relays_the_recut() {
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
    assert_eq!(kept_of(&mut b, &da, "secret-c3-relay"), (1, 0, 1));

    purge(&b, T1 + 4, N1);
    b.write(T1 + 5, N3, "b-after-purge");
    assert_eq!(
        kept_of(&mut b, &da, "secret-c3-relay"),
        (1, 1, 0),
        "recut in place"
    );
    assert_eq!(kept_of(&mut b, &da, "keep-c3").2, 1);
    assert_eq!(bytes_carrying(&b.dir.0, "secret-c3-relay"), 0);

    round(&b, &mut l2, "L2", T1 + 6, plain);
    relay(&b, &mut l2, "L2", None, T1 + 7);
    let keys = [key_pair(&mut a), key_pair(&mut b)];
    let (files, by, carrying) = relayed_at(&l2, &da, &keys, "secret-c3-relay");
    assert_eq!(files, 1, "a's segment reaches L2");
    assert_eq!(by, vec![keys[1].0], "signed by b, the recutter");
    assert_eq!(carrying, 0);
    assert_eq!(settle(&c, &mut l2, "L2", T1 + 8, 3), 0);
    assert_eq!(c.field(N2), Some(json!("keep-c3")));
    assert_eq!(c.field(N3), Some(json!("b-after-purge")));
    assert_eq!(bytes_carrying(&c.dir.0, "secret-c3-relay"), 0);
}

/// 清除之前 b 已经把 a 的段转发到了 L2（之后留着的那份因为每个位置都有了被删掉），清除由作者 a 发起：b 收到清除时把
/// L2 上那份 `rly-` 改成待删；a 已经按新切点重切了自己的段、新 head 不再引用旧段，所以 b 转发的是 a 自己签的新段，旧
/// `rly-` 被删掉；b 不再为转发去拉 a 的原文。L2 上从此没有被清除的内容，c 照样收齐其余的。
#[test]
fn a_purge_by_the_author_takes_back_what_was_already_relayed() {
    let mut a = Dev::new("c3ta");
    let mut b = Dev::new("c3tb");
    let c = Dev::new("c3tc");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    round(&b, &mut l1, "L1", T1, plain);
    round(&b, &mut l2, "L2", T1, plain);
    round(&c, &mut l2, "L2", T1, plain);
    a.write(T1 + 1, N1, "secret-c3-taken");
    a.write(T1 + 1, N2, "keep-c3");
    round(&a, &mut l1, "L1", T1 + 2, plain);
    round(&b, &mut l1, "L1", T1 + 3, plain);
    relay(&b, &mut l2, "L2", None, T1 + 3);
    let da = a.device();
    let keys = [key_pair(&mut a), key_pair(&mut b)];
    assert_eq!(relayed_at(&l2, &da, &keys, "secret-c3-taken").2, 1);
    assert_eq!(
        relay_segs(&mut b),
        0,
        "relayed everywhere, the copy is dropped"
    );

    purge(&a, T1 + 4, N1);
    round(&a, &mut l1, "L1", T1 + 5, plain);
    round(&b, &mut l1, "L1", T1 + 6, plain);
    relay(&b, &mut l2, "L2", None, T1 + 6);
    let (files, by, carrying) = relayed_at(&l2, &da, &keys, "secret-c3-taken");
    assert_eq!(
        (files, carrying),
        (1, 0),
        "the old one deleted, the author's own recut relayed"
    );
    assert_eq!(by, Vec::<Id>::new(), "signed by the author");
    let r = round(&b, &mut l1, "L1", T1 + 7, plain);
    assert!(!fetches_from(&r.plan, &da), "no refetch: {}", r.plan);
    assert_eq!(relay_segs(&mut b), 0);

    assert_eq!(settle(&c, &mut l2, "L2", T1 + 9, 2), 0);
    assert_eq!(c.field(N2), Some(json!("keep-c3")));
    assert_eq!(bytes_carrying(&c.dir.0, "secret-c3-taken"), 0);
}

/// 第三轮复核的 major：清除由**转发者** b 发起、作者 a 一直不回来。只连 L2 的 c 照样收到 a 没被清除的内容与 b 此后的
/// 全部操作（b 的依赖点着 a 的 seq，拿不到 a 这一段就一条都投不了）；L2、c 的库里都没有被清除的原文。c1 在清除之前已经
/// 收过原文（之后收到 b 的清除自己落空洞），c2 只在清除之后来（只见过重切件）。
#[test]
fn a_purge_by_the_relay_does_not_cut_off_a_location_only_it_feeds() {
    let mut a = Dev::new("c3fa");
    let mut b = Dev::new("c3fb");
    let c1 = Dev::new("c3fc1");
    let c2 = Dev::new("c3fc2");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    round(&b, &mut l1, "L1", T1, plain);
    round(&b, &mut l2, "L2", T1, plain);
    round(&c1, &mut l2, "L2", T1, plain);
    round(&c2, &mut l2, "L2", T1, plain);
    a.write(T1 + 1, N1, "secret-c3-relay-purge");
    a.write(T1 + 1, N2, "keep-c3");
    round(&a, &mut l1, "L1", T1 + 2, plain);
    round(&b, &mut l1, "L1", T1 + 3, plain);
    round(&b, &mut l2, "L2", T1 + 3, plain);
    relay(&b, &mut l2, "L2", None, T1 + 3);
    assert_eq!(settle(&c1, &mut l2, "L2", T1 + 4, 2), 0);
    assert_eq!(c1.field(N1), Some(json!("secret-c3-relay-purge")));
    let da = a.device();

    purge(&b, T1 + 5, N1);
    b.write(T1 + 6, N3, "b-after-purge");
    round(&b, &mut l1, "L1", T1 + 7, plain);
    round(&b, &mut l2, "L2", T1 + 7, plain);
    relay(&b, &mut l2, "L2", None, T1 + 7);
    let (outbox, _) = cmd(
        b.h,
        "relay_outbox",
        T1 + 8,
        json!({"location": "L2", "key": null}),
        &[],
    );
    assert_eq!(outbox["incomplete"], json!([]), "{outbox}");
    let keys = [key_pair(&mut a), key_pair(&mut b)];
    let (files, by, carrying) = relayed_at(&l2, &da, &keys, "secret-c3-relay-purge");
    assert_eq!((files, carrying), (1, 0));
    assert_eq!(by, vec![keys[1].0]);
    assert_eq!(bytes_carrying(&b.dir.0, "secret-c3-relay-purge"), 0);
    // 作者签的原文（L1 上 a 自己的段）再到 b 手里：收段照常（本机已有），转发缓存不留。
    let originals: Vec<Vec<u8>> = l1
        .iter()
        .filter(|(k, _)| k.contains(&da) && k.contains("/seg-"))
        .map(|(_, v)| v.clone())
        .collect();
    assert_eq!(originals.len(), 1);
    let (v, _) = cmd(b.h, "ingest", T1 + 8, json!({}), &originals);
    assert_eq!(v["segments"], json!(1), "{v}");
    assert_eq!(
        kept_of(&mut b, &da, "secret-c3-relay-purge"),
        (0, 0, 0),
        "not kept"
    );

    let purged = b.field(N1);
    assert_ne!(purged, Some(json!("secret-c3-relay-purge")));
    for c in [&c1, &c2] {
        assert_eq!(
            settle(c, &mut l2, "L2", T1 + 9, 3),
            0,
            "nothing left waiting"
        );
        assert_eq!(c.field(N2), Some(json!("keep-c3")));
        assert_eq!(c.field(N3), Some(json!("b-after-purge")));
        assert_eq!(c.field(N1), purged, "purged as on b");
        assert_eq!(bytes_carrying(&c.dir.0, "secret-c3-relay-purge"), 0);
    }
}

/// 同一批里重切件排在它点名的 Purge 前面（c2 第一次收 L2：b 重切的 a 段在前、b 带 Purge 的段在后）：一轮收齐，
/// 不留到下一轮——收段对一批之内的顺序不敏感（重切件等 Purge 的那一次延后在这一批交完之后再收一次）。
#[test]
fn a_recut_ahead_of_its_purge_in_one_batch_lands_in_that_round() {
    let a = Dev::new("c3oa");
    let b = Dev::new("c3ob");
    let c = Dev::new("c3oc");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    round(&b, &mut l1, "L1", T1, plain);
    round(&b, &mut l2, "L2", T1, plain);
    round(&c, &mut l2, "L2", T1, plain);
    a.write(T1 + 1, N1, "secret-c3-order");
    a.write(T1 + 1, N2, "keep-c3-order");
    round(&a, &mut l1, "L1", T1 + 2, plain);
    round(&b, &mut l1, "L1", T1 + 3, plain);
    round(&b, &mut l2, "L2", T1 + 3, plain);
    purge(&b, T1 + 5, N1);
    b.write(T1 + 6, N3, "b-after-purge");
    round(&b, &mut l1, "L1", T1 + 7, plain);
    round(&b, &mut l2, "L2", T1 + 7, plain);
    relay(&b, &mut l2, "L2", None, T1 + 7);
    let da = a.device();
    assert!(
        l2.iter()
            .any(|(k, v)| k.contains(&da) && v.starts_with(recut::MAGIC)),
        "L2 carries a recut of a's segment"
    );
    let r = round(
        &c,
        &mut l2,
        "L2",
        T1 + 8,
        Opts {
            recut_first: true,
            ..plain
        },
    );
    let v = &r.ingest[0];
    assert_eq!(v["errors"], json!([]), "{v}");
    assert_eq!(
        (v["deferred"].clone(), v["pending"].clone()),
        (json!(0), json!(0)),
        "{v}"
    );
    assert_eq!(c.field(N2), Some(json!("keep-c3-order")));
    assert_eq!(c.field(N3), Some(json!("b-after-purge")));
    assert_eq!(c.field(N1), b.field(N1), "purged as on b");
    assert_eq!(bytes_carrying(&c.dir.0, "secret-c3-order"), 0);
}

/// b 收 a 的段时只同步着 L1（没留原文），清除之后才连上 L2：`plan` 不为转发去拉 a 的原文（`wanted_for_relay` 看到本机在那段
/// 里清除过），转发到 L2 的是从 b 日志重切的件；只连 L2 的 c 收齐 a 其余的与 b 之后的。
#[test]
fn a_location_joined_after_the_purge_gets_a_recut_and_no_original_is_fetched() {
    let mut a = Dev::new("c3ja");
    let mut b = Dev::new("c3jb");
    let c = Dev::new("c3jc");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    round(&b, &mut l1, "L1", T1, plain);
    a.write(T1 + 1, N1, "secret-c3-join");
    a.write(T1 + 1, N2, "keep-c3");
    round(&a, &mut l1, "L1", T1 + 2, plain);
    round(&b, &mut l1, "L1", T1 + 3, plain);
    assert_eq!(b.field(N2), Some(json!("keep-c3")));
    let da = a.device();
    assert_eq!(relay_segs(&mut b), 0, "one location: nothing kept");

    purge(&b, T1 + 4, N1);
    b.write(T1 + 5, N3, "b-after-purge");
    round(&c, &mut l2, "L2", T1 + 6, plain);
    round(&b, &mut l2, "L2", T1 + 6, plain);
    let r = round(&b, &mut l1, "L1", T1 + 7, plain);
    assert!(
        !fetches_from(&r.plan, &da),
        "no original fetched: {}",
        r.plan
    );
    relay(&b, &mut l2, "L2", None, T1 + 7);
    let keys = [key_pair(&mut a), key_pair(&mut b)];
    let (files, by, carrying) = relayed_at(&l2, &da, &keys, "secret-c3-join");
    assert_eq!((files, carrying), (1, 0));
    assert_eq!(by, vec![keys[1].0], "recut from b's log");

    assert_eq!(settle(&c, &mut l2, "L2", T1 + 8, 3), 0);
    assert_eq!(c.field(N2), Some(json!("keep-c3")));
    assert_eq!(c.field(N3), Some(json!("b-after-purge")));
    assert_eq!(bytes_carrying(&c.dir.0, "secret-c3-join"), 0);
    assert_eq!(bytes_carrying(&b.dir.0, "secret-c3-join"), 0);
}

/// 一次清除跨过了作者的切点（a 的段 1..=1 与 2..=3，清除 N1 = seq 1、2）、而 b 已经没留这两段：b 的日志里两条空洞合成
/// 一个区间，切点 1 处的链值靠合并时记下的记号还在，两段都能从日志重切；c 收齐 a 其余的与 b 之后的。
#[test]
fn a_purge_across_the_authors_cut_point_still_recuts_both_segments() {
    let mut a = Dev::new("c3xa");
    let mut b = Dev::new("c3xb");
    let c = Dev::new("c3xc");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    round(&b, &mut l1, "L1", T1, plain);
    round(&b, &mut l2, "L2", T1, plain);
    round(&c, &mut l2, "L2", T1, plain);
    a.write(T1 + 1, N1, "secret-c3-cut-one");
    round(&a, &mut l1, "L1", T1 + 2, plain);
    a.write(T1 + 3, N1, "secret-c3-cut-two");
    a.write(T1 + 3, N2, "keep-c3");
    round(&a, &mut l1, "L1", T1 + 4, plain);
    round(&b, &mut l1, "L1", T1 + 5, plain);
    relay(&b, &mut l2, "L2", None, T1 + 5);
    assert_eq!(relay_segs(&mut b), 0);
    let da = a.device();
    let keys = [key_pair(&mut a), key_pair(&mut b)];
    assert_eq!(relayed_at(&l2, &da, &keys, "secret-c3-cut").0, 2);

    purge(&b, T1 + 6, N1);
    b.write(T1 + 7, N3, "b-after-purge");
    round(&b, &mut l2, "L2", T1 + 8, plain);
    relay(&b, &mut l2, "L2", None, T1 + 8);
    let (files, by, carrying) = relayed_at(&l2, &da, &keys, "secret-c3-cut");
    assert_eq!((files, carrying), (2, 0));
    assert_eq!(by, vec![keys[1].0, keys[1].0]);

    assert_eq!(settle(&c, &mut l2, "L2", T1 + 9, 3), 0);
    assert_eq!(c.field(N2), Some(json!("keep-c3")));
    assert_eq!(c.field(N3), Some(json!("b-after-purge")));
    assert_eq!(bytes_carrying(&c.dir.0, "secret-c3-cut"), 0);
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

/// 收尾出错（整理时空间不够等）：原因记进库、经读命令 `scrub_state` 报出来；之后的写命令不再逐条重试（不每条都重做
/// 一次注定失败的整库整理）；下一次打开再试，做成了错误清掉、原文没了。
#[test]
fn a_failed_byte_level_pass_is_reported_and_not_retried_on_every_write() {
    use crate::store::gen4::scrub::test_fail::{ATTEMPTS, FAIL};
    let mut a = Dev::new("c3err");
    a.write(T1, N1, "keep-c3");
    a.write(T1, N2, "secret-c3-err");
    ATTEMPTS.with(|c| c.set(0));
    FAIL.with(|f| f.set(true));
    purge(&a, T1 + 1, N2);
    FAIL.with(|f| f.set(false));
    assert_eq!(ATTEMPTS.with(|c| c.get()), 1);
    let (st, _) = cmd(a.h, "scrub_state", T1 + 1, json!({}), &[]);
    assert_eq!(st["due"], json!(true), "{st}");
    assert!(
        st["error"].as_str().is_some_and(|e| e.contains("injected")),
        "{st}"
    );
    for i in 0..3 {
        a.write(T1 + 2 + i, N1, &format!("keep-c3-{i}"));
    }
    assert_eq!(ATTEMPTS.with(|c| c.get()), 1, "not retried on every write");

    ffsrs_store_close(a.h);
    a.h = open(&a.dir.0, 0).unwrap();
    assert_eq!(ATTEMPTS.with(|c| c.get()), 2, "retried on the next open");
    let (st, _) = cmd(a.h, "scrub_state", T1 + 6, json!({}), &[]);
    assert_eq!(st, json!({"due": false, "error": null}), "{st}");
    assert_eq!(bytes_carrying(&a.dir.0, "secret-c3-err"), 0);
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
