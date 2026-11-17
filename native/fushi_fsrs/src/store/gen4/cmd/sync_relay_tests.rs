//! G8-7b 转发（`cmd/sync_relay.rs`）与收段让路（`ingest` 的 `maxItems`）的端到端测试，经 C ABI，位置是内存表
//! （装置在 `sync_tests.rs`）。
//!
//! - 拓扑不全连通：a 只连明文位置 L1、c 只连加密位置 L2、b 两个都连。b 把 a 的段转发到 L2（按 L2 的钥匙封装）、把 c 的
//!   转发到 L1，三台收敛，派生层增量 == 重建；转发完 b 不再留原文；被转发的 head 不当位置证据。
//! - 收段让路：一大批按 `maxItems` 切成多个事务，每个事务做的新工作不超过预算，最后与一次收完的结果相同；量一批的持锁时间。

use std::time::Instant;

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::dispatch_tests::T1;
use super::sync_relay::{
    LOC_COUNT_SQL, LOC_KEYS_SQL, RELAY_GET_SQL, RELAY_LIST_SQL, RHEAD_RANGE_SQL,
};
use super::sync_tests::{Dev, Loc, Opts, cmd, heads, listing, round, sync_all};
use super::tests::{N1, N2, N3};
use crate::store::gen4::files::GEN4_FILE;
use crate::store::sync2::tests::edit;

const KEY2: &str = "2222222222222222222222222222222222222222222222222222222222222222";

/// 跑一遍转发：要一批、写上、确认，直到没有；最后删掉待删的、报回去。回包：写上的文件路径（相对 `v4/`）。
fn relay(d: &Dev, loc: &mut Loc, location: &str, key: Option<&str>, now: i64) -> Vec<String> {
    let mut written = Vec::new();
    let mut delete: Vec<Value> = Vec::new();
    for _ in 0..64 {
        let (v, files) = cmd(
            d.h,
            "relay_outbox",
            now,
            json!({"location": location, "key": key, "maxBytes": 1}),
            &[],
        );
        let paths = v["files"].as_array().unwrap().clone();
        assert_eq!(paths.len(), files.len(), "{v}");
        for (p, b) in files {
            written.push(p.clone());
            loc.insert(format!("v4/{p}"), b);
        }
        let (ack, _) = cmd(
            d.h,
            "relay_ack",
            now,
            json!({"location": location, "paths": paths}),
            &[],
        );
        delete = ack["delete"].as_array().unwrap().clone();
        if v["more"] != json!(true) {
            break;
        }
    }
    for p in &delete {
        loc.remove(&format!("v4/{}", p.as_str().unwrap()));
    }
    if !delete.is_empty() {
        cmd(
            d.h,
            "relay_ack",
            now,
            json!({"location": location, "deleted": delete}),
            &[],
        );
    }
    written
}

fn relay_segs(d: &mut Dev) -> i64 {
    d.direct(|t, _| {
        t.conn()
            .query_row("SELECT COUNT(*) FROM relay_segs", [], |r| r.get(0))
            .map_err(|e| e.to_string())
    })
}

/// a 只连 L1（明文）、c 只连 L2（加密）、b 两个都连：b 转发之后三台都看得到彼此写的，派生层相同、增量 == 重建。
/// 转发件在 L2 上按 L2 的钥匙封装；被转发的 head 用 `rhd-` 前缀，不覆盖、不冒充作者自写的 head；全部转发完 b 不再留
/// 原文；再跑一遍转发什么都不写。
#[test]
fn a_device_on_two_locations_relays_between_them() {
    let a = Dev::new("g87ra");
    let mut b = Dev::new("g87rb");
    let c = Dev::new("g87rc");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    let sealed = Opts {
        key: Some(KEY2),
        ..Opts::default()
    };
    // b 先认识两个位置（只有同步着 ≥ 2 个位置才留原文）。
    round(&b, &mut l1, "L1", T1, plain);
    round(&b, &mut l2, "L2", T1, sealed);
    a.write(T1 + 1, N1, "鯨");
    c.write(T1 + 2, N2, "猫");
    round(&a, &mut l1, "L1", T1 + 3, plain);
    round(&c, &mut l2, "L2", T1 + 3, sealed);
    round(&b, &mut l1, "L1", T1 + 4, plain);
    round(&b, &mut l2, "L2", T1 + 4, sealed);
    b.write(T1 + 5, N3, "犬");
    round(&b, &mut l1, "L1", T1 + 6, plain);
    round(&b, &mut l2, "L2", T1 + 6, sealed);
    assert!(relay_segs(&mut b) >= 2);

    let to_l2 = relay(&b, &mut l2, "L2", Some(KEY2), T1 + 7);
    let to_l1 = relay(&b, &mut l1, "L1", None, T1 + 7);
    let (da, dc) = (a.device(), c.device());
    assert!(
        to_l2.iter().any(|p| p.contains(&da) && p.contains("/rly-"))
            && to_l2.iter().any(|p| p.contains(&da) && p.contains("/rhd-")),
        "{to_l2:?}"
    );
    assert!(
        to_l1.iter().any(|p| p.contains(&dc) && p.contains("/rly-"))
            && to_l1.iter().any(|p| p.contains(&dc) && p.contains("/rhd-")),
        "{to_l1:?}"
    );
    // L2 上的转发件按 L2 的钥匙封装（FRL4 的 flags bit0）。
    for p in to_l2.iter().filter(|p| p.contains("/rly-")) {
        let bytes = &l2[&format!("v4/{p}")];
        assert!(bytes.starts_with(b"FRL4") && bytes[5] & 1 == 1, "{p}");
    }
    // 被转发的 head 不出现在作者自写 head 的那一组里。
    assert!(heads(&l2).len() <= 2, "only b and c wrote heads at L2");

    for _ in 0..2 {
        round(&a, &mut l1, "L1", T1 + 8, plain);
        round(&c, &mut l2, "L2", T1 + 8, sealed);
    }
    for d in [&a, &b, &c] {
        assert_eq!(d.field(N1), Some(json!("鯨")), "{}", d.device());
        assert_eq!(d.field(N2), Some(json!("猫")), "{}", d.device());
        assert_eq!(d.field(N3), Some(json!("犬")), "{}", d.device());
    }
    let mut a = a;
    let mut c = c;
    let (ga, gb, gc) = (a.derived(), b.derived(), c.derived());
    assert_eq!(ga, gb);
    assert_eq!(gb, gc);
    // 每个位置都有了：b 不再留原文；再跑一遍转发什么都不写。
    assert_eq!(relay_segs(&mut b), 0);
    assert!(relay(&b, &mut l2, "L2", Some(KEY2), T1 + 9).is_empty());
    assert!(relay(&b, &mut l1, "L1", None, T1 + 9).is_empty());
    // L1 上的被转发 head 不是 L1 的证据：b 在 L1 的 plan 不把 c 记成 L1 上的设备（c 的 loc_heads 只在 L2）。
    let rows: Vec<String> = b.direct(|t, col| {
        Ok(t.loc_heads(col, "L1")?
            .into_iter()
            .map(|h| h.device.text())
            .collect())
    });
    assert!(!rows.contains(&dc), "{rows:?}");
}

/// a 的作者自己后来也连上了 L2：b 留着的 a 的原文被删掉（L2 上作者 head 已覆盖），转发件也不再给。
#[test]
fn an_author_reaching_the_location_itself_ends_the_relay() {
    let a = Dev::new("g87rx");
    let mut b = Dev::new("g87ry");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let o = Opts::default();
    round(&b, &mut l1, "L1", T1, o);
    round(&b, &mut l2, "L2", T1, o);
    a.write(T1 + 1, N1, "鯨");
    round(&a, &mut l1, "L1", T1 + 2, o);
    round(&b, &mut l1, "L1", T1 + 3, o);
    assert_eq!(relay_segs(&mut b), 1);
    round(&a, &mut l2, "L2", T1 + 4, o);
    round(&b, &mut l2, "L2", T1 + 5, o);
    assert_eq!(relay_segs(&mut b), 0);
    assert!(relay(&b, &mut l2, "L2", None, T1 + 6).is_empty());
}

/// 后来才连上第二个位置：b 先只连 L1、早就收了 a 的段（当时只有一个位置，不留原文）；之后连上 L2（c 在那里）。b 在
/// L1 的下一轮 `plan` 把 a 那些「本机早有、没留原文、L2 缺」的段再要一次（收段按已有跳过、只留原文），随后转发到 L2，
/// c 收齐 a 写的；转发完 b 不再留原文。
#[test]
fn a_second_location_added_later_still_gets_the_relay() {
    let a = Dev::new("g87la");
    let mut b = Dev::new("g87lb");
    let c = Dev::new("g87lc");
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let o = Opts::default();
    a.write(T1 + 1, N1, "鯨");
    round(&a, &mut l1, "L1", T1 + 2, o);
    round(&b, &mut l1, "L1", T1 + 3, o);
    assert_eq!(b.field(N1), Some(json!("鯨")));
    assert_eq!(relay_segs(&mut b), 0, "one location: nothing kept");
    round(&b, &mut l2, "L2", T1 + 4, o);
    // 这一轮 L1 的 plan 为转发补拉 a 的段。
    let r = round(&b, &mut l1, "L1", T1 + 5, o);
    let da = a.device();
    assert!(
        r.plan["fetch"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["device"] == json!(da)),
        "{}",
        r.plan
    );
    assert_eq!(relay_segs(&mut b), 1);
    assert!(!relay(&b, &mut l2, "L2", None, T1 + 6).is_empty());
    for _ in 0..2 {
        round(&c, &mut l2, "L2", T1 + 7, o);
    }
    assert_eq!(c.field(N1), Some(json!("鯨")));
    // b 这一轮在 L2 收到 c 的段（L1 缺）会留原文；转发到 L1 之后两边都齐，原文一份不剩。
    round(&b, &mut l2, "L2", T1 + 8, o);
    relay(&b, &mut l1, "L1", None, T1 + 9);
    assert_eq!(relay_segs(&mut b), 0);
}

/// 只连一个位置的设备不留原文、不转发。
#[test]
fn a_single_location_device_keeps_nothing_to_relay() {
    let a = Dev::new("g87r1");
    let mut b = Dev::new("g87r2");
    let mut l1 = Loc::new();
    a.write(T1 + 1, N1, "鯨");
    for d in [&a, &b] {
        round(d, &mut l1, "L1", T1 + 2, Opts::default());
    }
    round(&b, &mut l1, "L1", T1 + 3, Opts::default());
    assert_eq!(b.field(N1), Some(json!("鯨")));
    assert_eq!(relay_segs(&mut b), 0);
    assert!(relay(&b, &mut l1, "L1", None, T1 + 4).is_empty());
}

fn note_id(i: usize) -> String {
    format!("0193a1b2-0000-7000-8000-{:012x}", 0x1000 + i)
}

/// 一台设备写 [n] 条（一次 `apply`）。
fn write_many(d: &Dev, now: i64, n: usize) {
    let items: Vec<Value> = (0..n)
        .map(|i| {
            let note = note_id(i);
            json!({"e": edit("note", &note, "f/fa", json!(format!("v{i}"))), "note": note})
        })
        .collect();
    let blob = Value::Array(items).to_string().into_bytes();
    let (v, _) = cmd(d.h, "apply", now, json!({}), &[blob]);
    assert_eq!(v["landed"].as_array().unwrap().len(), n, "{v}");
}

/// 收段让路：b 收 a 的一大批时带 `maxItems`，内核每个事务做的新工作不超过预算、中途停下的段下一个事务原样再交；最后
/// 派生层增量 == 重建，三台互相同步后与一次收完的 c 语义摘要相同。同时量一下每个事务的持锁时间（打印，不设阈值）。
#[test]
fn ingest_slices_a_large_batch_into_budgeted_transactions() {
    const N: usize = 1500;
    const BUDGET: u64 = 200;
    let a = Dev::new("g87ya");
    let mut b = Dev::new("g87yb");
    let mut c = Dev::new("g87yc");
    write_many(&a, T1 + 1, N);
    let mut loc = Loc::new();
    round(&a, &mut loc, "loc", T1 + 2, Opts::default());
    // c：一次收完（对照组）。
    round(&c, &mut loc, "loc", T1 + 3, Opts::default());
    // b：手动按 plan 拉，再按预算切事务交。
    let root = {
        let mut blobs = Vec::new();
        blobs.extend(loc.get("v4/meta.json").cloned());
        blobs.extend(loc.get("v3/meta.json").cloned());
        let locs: Vec<String> = loc
            .keys()
            .filter_map(|k| k.strip_prefix("v4/loc/").map(str::to_owned))
            .collect();
        cmd(
            b.h,
            "location_root",
            T1 + 4,
            json!({"location": "loc", "has4": true, "has3": loc.contains_key("v3/meta.json"), "locs": locs}),
            &blobs,
        )
        .0
    };
    let (plan, _) = cmd(
        b.h,
        "plan",
        T1 + 4,
        json!({"location": "loc", "loc": root["loc"], "listing": listing(&loc)}),
        &heads(&loc),
    );
    let mut pending: Vec<Vec<u8>> = plan["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|f| f["files"].as_array().unwrap().clone())
        .filter_map(|p| loc.get(&format!("v4/{}", p.as_str().unwrap())).cloned())
        .collect();
    assert!(!pending.is_empty());
    let mut txs = 0;
    let mut slowest = std::time::Duration::ZERO;
    while !pending.is_empty() {
        let t0 = Instant::now();
        let (v, _) = cmd(b.h, "ingest", T1 + 5, json!({"maxItems": BUDGET}), &pending);
        let dt = t0.elapsed();
        slowest = slowest.max(dt);
        txs += 1;
        let landed = v["landed"].as_u64().unwrap() + v["delivered"].as_u64().unwrap();
        assert!(landed <= BUDGET, "{v}");
        let rest = v["rest"].as_u64().unwrap() as usize;
        pending.drain(..rest);
        assert!(txs < 100, "no progress: {v}");
    }
    eprintln!(
        "ingest slices: {N} ops in {txs} transactions of <= {BUDGET} items, slowest {slowest:?}"
    );
    assert!(txs as u64 >= N as u64 / BUDGET, "{txs}");
    for i in [0, N / 2, N - 1] {
        assert_eq!(b.field(&note_id(i)), Some(json!(format!("v{i}"))));
    }
    // 增量 == 重建（切片收的派生层与整个重建逐行相同）；三台互相同步之后语义摘要相同（各自的身份操作要先互相到达）。
    sync_all(&[&a, &b, &c], &mut loc, T1 + 6, Opts::default());
    let mut a = a;
    assert_eq!(b.derived(), c.derived());
    assert_eq!(a.derived(), c.derived());
}

/// 转发的新语句按键找，不扫表。
#[test]
fn relay_lookups_use_their_keys() {
    let a = Dev::new("g87rq");
    let c = Connection::open_with_flags(
        a.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    for (q, n) in [
        (LOC_COUNT_SQL, 1),
        (LOC_KEYS_SQL, 1),
        (RELAY_GET_SQL, 5),
        (RELAY_LIST_SQL, 2),
        (RHEAD_RANGE_SQL, 2),
    ] {
        let params: Vec<i64> = (0..n).map(|i| i + 1).collect();
        let plan: Vec<String> = c
            .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
            .unwrap()
            .query_map(rusqlite::params_from_iter(params), |r| {
                r.get::<_, String>(3)
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(
            plan.iter().all(|p| p.starts_with("SEARCH")),
            "{q}: {plan:?}"
        );
    }
}

// ---------------------------------------------------------------------- 并入之后的同步

/// 并入（`collection_join`）之后经位置同步：b 绑在集合 Y（盐 `uidB`）上写 N2；a 在自己的集合里写 N1，然后并入 Y。
/// 两台经 Y 的位置同步之后都看得到 N1、N2；两份盐派生的默认牌组 ID 在两台上归一到同一个规范 ID（别名类按类回答）；
/// 语义摘要相同、派生层增量 == 重建。
#[test]
fn devices_converge_after_a_join() {
    use super::dispatch_tests::{cfg, g4, open};
    use crate::gen4::op::tests::id;
    use crate::store::sync2::config::default_deck_id;
    use crate::store::sync2::tests::{P, tempdir};
    let mut a = Dev::new("g87ja");
    let mut b = {
        let dir = tempdir::new("g87jb");
        let h = open(&dir.0, 0).unwrap();
        let v = g4(
            h,
            "collection_adopt",
            T1,
            json!({"collection": id(0x0a).text(), "dir": "0000-home", "salts": ["uidB"], "confirmed": true}),
        );
        assert_eq!(v["outcome"], json!("bound"), "{v}");
        g4(h, "cache_config_set", T1, json!({"caches": cfg()}));
        Dev { dir, h }
    };
    a.write(T1 + 1, N1, "鯨");
    b.write(T1 + 2, N2, "猫");
    let j = g4(
        a.h,
        "collection_join",
        T1 + 3,
        json!({"into": id(0x0a).text(), "dir": "0000-home"}),
    );
    assert_eq!(j["outcome"], json!("joined"), "{j}");
    let mut loc = Loc::new();
    sync_all(&[&b, &a], &mut loc, T1 + 4, Opts::default());
    for d in [&a, &b] {
        assert_eq!(d.field(N1), Some(json!("鯨")), "{}", d.device());
        assert_eq!(d.field(N2), Some(json!("猫")), "{}", d.device());
    }
    let ids = json!({"ids": [default_deck_id(P), default_deck_id("uidB")]});
    let ca = g4(a.h, "canonical_ids", T1, ids.clone());
    let cb = g4(b.h, "canonical_ids", T1, ids);
    assert_eq!(ca, cb);
    assert_eq!(a.derived(), b.derived());
}

// ---------------------------------------------------------------------- 围栏中途

/// 围栏中途：a 在一个协议 3 的存量位置上立新根时只写成了新根（`v4/`），旧根 meta 还没改写成围栏就断了。下一台设备
/// b 进来：仍认它是存量集合（媒体根 `v3`、不立墓碑 head），把围栏补上；围栏立好之后不再改写；两台照常收敛。
#[test]
fn a_fence_interrupted_midway_is_completed_by_the_next_device() {
    use crate::store::sync2::collection_of;
    use crate::store::sync2::tests::P;
    let a = Dev::new("g87fa");
    let b = Dev::new("g87fb");
    let mut loc = Loc::new();
    let v3 = json!({"collection": collection_of(P).text(), "v": 3, "minReader": 3})
        .to_string()
        .into_bytes();
    loc.insert("v3/meta.json".into(), v3.clone());
    let root = |d: &Dev, loc: &Loc| -> (Value, Vec<(String, Vec<u8>)>) {
        let mut blobs = Vec::new();
        blobs.extend(loc.get("v4/meta.json").cloned());
        blobs.extend(loc.get("v3/meta.json").cloned());
        let locs: Vec<String> = loc
            .keys()
            .filter_map(|k| k.strip_prefix("v4/loc/").map(str::to_owned))
            .collect();
        cmd(
            d.h,
            "location_root",
            T1,
            json!({"location": "loc", "has4": loc.contains_key("v4/meta.json"),
                "has3": loc.contains_key("v3/meta.json"), "locs": locs}),
            &blobs,
        )
    };
    let (r, files) = root(&a, &loc);
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["media"], json!("v3"));
    // 只写成新根那一半（先新根、后围栏的顺序在 v3 之前断了）。
    for (p, bytes) in files {
        if p.starts_with("v4/") {
            loc.insert(p, bytes);
        }
    }
    assert_eq!(loc["v3/meta.json"], v3, "the fence was not written yet");
    let (r, files) = root(&b, &loc);
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["media"], json!("v3"), "still an existing collection");
    assert_eq!(
        r["ensure"],
        json!([]),
        "no tombstone head for an existing collection"
    );
    let fence = files
        .iter()
        .find(|(p, _)| p == "v3/meta.json")
        .expect("b completes the fence")
        .1
        .clone();
    let fv: Value = serde_json::from_slice(&fence).unwrap();
    assert_eq!(fv["minReader"], json!(4), "{fv}");
    for (p, bytes) in files {
        loc.insert(p, bytes);
    }
    // 围栏立好之后再来：不再改写旧根 meta。
    let (_, again) = root(&a, &loc);
    assert!(!again.iter().any(|(p, _)| p == "v3/meta.json"), "{again:?}");
    a.write(T1 + 1, N1, "鯨");
    b.write(T1 + 2, N2, "猫");
    sync_all(&[&a, &b], &mut loc, T1 + 3, Opts::default());
    for d in [&a, &b] {
        assert_eq!(d.field(N1), Some(json!("鯨")));
        assert_eq!(d.field(N2), Some(json!("猫")));
    }
}
