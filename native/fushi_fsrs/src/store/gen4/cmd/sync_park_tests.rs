//! 重切件的停放（`cmd/sync_park.rs`，第六波）的端到端测试，经 C ABI，位置是内存表（装置在 `sync_tests.rs`）。
//!
//! 拓扑同 `purge_scrub_tests.rs`：a 只连 L1、b 两个都连、c 只连 L2；b 清除了 a 的一条之后把 a 的段重切（`FRX4`，b 签）
//! 转发到 L2。c 收不了这一件的两种情形：
//!
//! - 重切者（也是 Purge 的作者）b 在 c 那里待确认 / 被拒绝：停放、之后每轮不拉，同步页 b 那一行说明原因；确认、拒绝
//!   （状态变了）之后才再拉——拒绝之后再拉一次得到同样的延后，按新状态停放，不再每轮拉；确认之后收下。
//! - b 带 Purge 的段在 L2 上暂时列不到（最终一致）：停放、Purge 没到之前不拉；Purge 到了之后的那一轮拉、收下。
//!
//! 外加一批之内的重收（minor）：预算截断了这一批时，等同一批里 Purge 的重切件交回 Dart（`requeue`）接在后面重收，
//! 不报错、不白等一轮。

use serde_json::{Value, json};

use super::dispatch_tests::T1;
use super::sync_relay_tests::relay;
use super::sync_tests::{Dev, Loc, Opts, cmd, round, status_row};
use super::tests::{N1, N2, N3, N4};
use crate::gen4::recut;

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

fn trust(d: &Dev, now: i64, device: &str, on: bool) {
    let (v, _) = cmd(
        d.h,
        "trust",
        now,
        json!({"device": device, "trust": on}),
        &[],
    );
    assert_eq!(v["trusted"], json!(on), "{v}");
}

/// 这一轮 plan 要拉的文件里有没有作者 [author] 的。
fn fetches_from(plan: &Value, author: &str) -> bool {
    plan["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|f| f["device"] == json!(author))
        .any(|f| !f["files"].as_array().unwrap().is_empty())
}

/// b 收下 a 的段、清除其中一条（N1）、写一条（N3），再把重切件转发到 L2。回 (a, b) 的设备 ID。
fn recut_on_l2(
    a: &Dev,
    b: &Dev,
    l1: &mut Loc,
    l2: &mut Loc,
    now: i64,
    secret: &str,
) -> (String, String) {
    let plain = Opts::default();
    round(b, l1, "L1", now, plain);
    round(b, l2, "L2", now, plain);
    a.write(now + 1, N1, secret);
    a.write(now + 1, N2, "keep-park");
    round(a, l1, "L1", now + 2, plain);
    round(b, l1, "L1", now + 3, plain);
    // b 的库在第一次见到 a 之前已有数据（c 先写过 L2）时 a 在 b 那里待确认：不受信的作者的段不转发。b 确认 a，
    // 再读一次 L1（把早收下、没留原文的段再要一次，留作转发）。
    if status_row(b, &a.device())["trust"] == json!("pending") {
        trust(b, now + 3, &a.device(), true);
        round(b, l1, "L1", now + 3, plain);
    }
    round(b, l2, "L2", now + 3, plain);
    purge(b, now + 4, N1);
    b.write(now + 5, N3, "b-after-purge");
    round(b, l1, "L1", now + 6, plain);
    round(b, l2, "L2", now + 6, plain);
    relay(b, l2, "L2", None, now + 6);
    let da = a.device();
    assert!(
        l2.iter()
            .any(|(k, v)| k.contains(&da) && k.contains("/rly-") && v.starts_with(recut::MAGIC)),
        "L2 carries b's recut of a's segment"
    );
    (da, b.device())
}

/// c 待确认 b（c 的库非空时第一次见到它）：a 的重切件停放，之后每轮都不拉；同步页 b 那一行写着原因；c 拒绝 b（状态
/// 变了）再拉一次、同样延后、按「已拒绝」停放，之后又不拉；c 确认 b 之后的那一轮拉、收下，同步页不再提。
#[test]
fn a_recut_from_an_unconfirmed_device_is_parked_until_its_trust_changes() {
    let (a, b, c) = (Dev::new("pk-ta"), Dev::new("pk-tb"), Dev::new("pk-tc"));
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    // c 先有自己的数据、自己同步过 L2：之后第一次见到 b 时 b 待确认。
    c.write(T1, N4, "c-own");
    round(&c, &mut l2, "L2", T1, plain);
    let (da, db) = recut_on_l2(&a, &b, &mut l1, &mut l2, T1 + 1, "secret-park-trust");

    let r = round(&c, &mut l2, "L2", T1 + 10, plain);
    assert!(
        fetches_from(&r.plan, &da),
        "first sight fetches: {}",
        r.plan
    );
    assert_eq!(status_row(&c, &db)["trust"], json!("pending"));
    assert_eq!(c.field(N2), None, "not taken from an unconfirmed recutter");
    let row = status_row(&c, &db);
    assert_eq!(
        row["relayBlocked"],
        json!([{"location": "L2", "author": da, "reason": "pending", "pieces": 1}]),
        "{row}"
    );
    // 之后每轮都不拉（以前每轮都拉一遍、每轮都延后）。
    for i in 0..3 {
        let r = round(&c, &mut l2, "L2", T1 + 11 + i, plain);
        assert!(!fetches_from(&r.plan, &da), "parked: {}", r.plan);
    }

    // 拒绝：状态变了，再拉一次，同样收不了，按新状态停放。
    trust(&c, T1 + 20, &db, false);
    let r = round(&c, &mut l2, "L2", T1 + 21, plain);
    assert!(fetches_from(&r.plan, &da), "trust changed: {}", r.plan);
    assert_eq!(c.field(N2), None);
    assert_eq!(
        status_row(&c, &db)["relayBlocked"][0]["reason"],
        json!("rejected")
    );
    let r = round(&c, &mut l2, "L2", T1 + 22, plain);
    assert!(!fetches_from(&r.plan, &da), "parked again: {}", r.plan);

    // 确认：下一轮拉、收下；同步页不再提。
    trust(&c, T1 + 30, &db, true);
    let r = round(&c, &mut l2, "L2", T1 + 31, plain);
    assert!(fetches_from(&r.plan, &da), "trusted now: {}", r.plan);
    assert_eq!(c.field(N2), Some(json!("keep-park")));
    assert_eq!(c.field(N3), Some(json!("b-after-purge")));
    assert!(status_row(&c, &db).get("relayBlocked").is_none());
    let r = round(&c, &mut l2, "L2", T1 + 32, plain);
    assert!(!fetches_from(&r.plan, &da), "done: {}", r.plan);
}

/// 一台只经转发 head 认识、本机还没有它任何日志的重切者照样在同步页有一行（不然用户找不到要确认的设备）：b 只把 a
/// 的重切件转发到 L2、b 自己的段 c 读不到（L2 上删掉）——c 那里 b 没有日志，status 照样给 b 一行、带 `relayBlocked`。
#[test]
fn a_waited_for_device_without_a_log_still_gets_a_status_row() {
    let (a, b, c) = (Dev::new("pk-ra"), Dev::new("pk-rb"), Dev::new("pk-rc"));
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    c.write(T1, N4, "c-own");
    round(&c, &mut l2, "L2", T1, plain);
    let (da, db) = recut_on_l2(&a, &b, &mut l1, &mut l2, T1 + 1, "secret-park-row");
    let own: Vec<String> = l2
        .keys()
        .filter(|k| k.contains(&db) && k.contains("/seg-"))
        .cloned()
        .collect();
    assert!(!own.is_empty());
    for k in own {
        l2.remove(&k);
    }
    round(&c, &mut l2, "L2", T1 + 10, plain);
    let row = status_row(&c, &db);
    assert_eq!(row["applied"], json!(0), "{row}");
    assert_eq!(row["relayBlocked"][0]["author"], json!(da), "{row}");
    assert_eq!(row["relayBlocked"][0]["reason"], json!("pending"), "{row}");
}

/// b 带 Purge 的段在 L2 上暂时列不到（c 可信 b）：a 的重切件等 Purge，停放；Purge 没到的几轮都不拉；b 的段出现、
/// 收下之后的那一轮拉、收下。同步页在等的那几轮把原因（`purge`）挂在 b 那一行。
#[test]
fn a_recut_waiting_for_its_purge_is_fetched_again_only_once_the_purge_is_here() {
    let (a, b, c) = (Dev::new("pk-pa"), Dev::new("pk-pb"), Dev::new("pk-pc"));
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    round(&c, &mut l2, "L2", T1, plain);
    let (da, db) = recut_on_l2(&a, &b, &mut l1, &mut l2, T1 + 1, "secret-park-purge");
    // c 先见过 b（可信）、但 b 带 Purge 的段暂时不在 L2 上。
    let hidden: Vec<(String, Vec<u8>)> = l2
        .iter()
        .filter(|(k, _)| k.contains(&db) && k.contains("/seg-"))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    assert!(!hidden.is_empty());
    for (k, _) in &hidden {
        l2.remove(k);
    }
    let r = round(&c, &mut l2, "L2", T1 + 10, plain);
    assert!(fetches_from(&r.plan, &da), "{}", r.plan);
    assert_eq!(c.field(N2), None, "waits for b's Purge");
    let row = status_row(&c, &db);
    assert_eq!(row["relayBlocked"][0]["reason"], json!("purge"), "{row}");
    for i in 0..2 {
        let r = round(&c, &mut l2, "L2", T1 + 11 + i, plain);
        assert!(!fetches_from(&r.plan, &da), "parked: {}", r.plan);
    }
    // b 的段出现：这一轮收下 b 的段（a 的件还停着，plan 在收段之前）——b 的 Purge 依赖 a 的操作，进等待缓冲（等待
    // 缓冲里的 Purge 也算「到了」）；下一轮拉 a 的件、收下，b 的段随之投出。
    for (k, v) in hidden {
        l2.insert(k, v);
    }
    round(&c, &mut l2, "L2", T1 + 20, plain);
    assert_eq!(
        c.field(N2),
        None,
        "a's piece was still parked during that plan"
    );
    let r = round(&c, &mut l2, "L2", T1 + 21, plain);
    assert!(fetches_from(&r.plan, &da), "purge here now: {}", r.plan);
    assert_eq!(c.field(N2), Some(json!("keep-park")));
    assert_eq!(c.field(N3), Some(json!("b-after-purge")));
    assert_eq!(c.field(N1), b.field(N1), "purged as on b");
    assert!(status_row(&c, &db).get("relayBlocked").is_none());
}

/// minor：一批里重切件排在它点名的 Purge 前面、预算在 Purge 那一段中途用完——以前这一批被截断时重切件直接报延后、
/// 交完了（Dart 不再交），要白等到下一轮；现在交回 Dart（`requeue`）接在剩下的段后面，下一个事务里收下，不报错。
#[test]
fn a_truncated_batch_hands_the_waiting_recut_back_instead_of_dropping_it() {
    let (a, b, c) = (Dev::new("pk-qa"), Dev::new("pk-qb"), Dev::new("pk-qc"));
    let (mut l1, mut l2) = (Loc::new(), Loc::new());
    let plain = Opts::default();
    round(&c, &mut l2, "L2", T1, plain);
    let (da, db) = recut_on_l2(&a, &b, &mut l1, &mut l2, T1 + 1, "secret-park-requeue");
    // 这一批：重切件在前、b 的段在后。
    let mut batch: Vec<Vec<u8>> = l2
        .iter()
        .filter(|(k, _)| k.contains(&da) && k.contains("/rly-"))
        .map(|(_, v)| v.clone())
        .collect();
    assert_eq!(batch.len(), 1);
    batch.extend(
        l2.iter()
            .filter(|(k, _)| k.contains(&db) && k.contains("/seg-"))
            .map(|(_, v)| v.clone()),
    );
    // c 先要认识 a、b 的公钥：跑一遍 plan（不收）。
    let hs = super::sync_tests::heads(&l2);
    let rh = super::sync_tests::relayed_heads(&l2);
    let relayed = rh.len();
    let all: Vec<Vec<u8>> = hs.into_iter().chain(rh).collect();
    cmd(
        c.h,
        "plan",
        T1 + 10,
        json!({"location": "L2", "relayed": relayed}),
        &all,
    );
    let (v, _) = cmd(
        c.h,
        "ingest",
        T1 + 10,
        json!({"location": "L2", "maxItems": 1}),
        &batch,
    );
    let done = v["rest"].as_u64().unwrap() as usize;
    assert!(done < batch.len(), "truncated: {v}");
    assert_eq!(v["requeue"], json!([0]), "{v}");
    assert_eq!(v["errors"], json!([]), "{v}");
    assert_eq!(v["deferred"], json!(0), "{v}");
    // 照 Dart：剩下的段 + 交回的件，一片片交完。
    let mut pending: Vec<Vec<u8>> = batch[done..].to_vec();
    pending.push(batch[0].clone());
    for _ in 0..64 {
        let (v, _) = cmd(
            c.h,
            "ingest",
            T1 + 10,
            json!({"location": "L2", "maxItems": 1}),
            &pending,
        );
        assert_eq!(v["errors"], json!([]), "{v}");
        let done = v["rest"].as_u64().unwrap() as usize;
        let back: Vec<Vec<u8>> = v["requeue"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| pending[i.as_u64().unwrap() as usize].clone())
            .collect();
        if done >= pending.len() && v["drainMore"] != json!(true) {
            assert!(back.is_empty(), "{v}");
            pending.clear();
            break;
        }
        pending.drain(..done.min(pending.len()));
        pending.extend(back);
    }
    assert!(pending.is_empty());
    assert_eq!(c.field(N2), Some(json!("keep-park")));
    assert_eq!(c.field(N3), Some(json!("b-after-purge")));
}
