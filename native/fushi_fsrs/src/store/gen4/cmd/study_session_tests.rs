//! 出卡常驻会话（`cmd/study.rs` 经 `store/queue.rs` 的 [Session]，由 `kernel.rs` 的库句柄持有）随写入增量维护的结果，
//! 与每次整份现读的无状态基准（[study_stateless]）逐键相同：本机作答（单独排队与作答带排队）、撤销、别的设备的写入、
//! 改牌组 / 上限、整笔回滚、换日、自定义学习（会话开始早于今天 / 在今天之内）、RWKV，以及 Secondary（没有写连接触发器，
//! 按刷新键印记重建）。另验增量真的是增量：同一天里的本机写入不让会话整份重建。

use std::sync::atomic::Ordering;

use serde_json::{Value, json};

use super::dispatch_tests::{T1, call, g4, g4req, migrated_prepared, open};
use super::study::study_stateless;
use super::study_tests::{requests_at, study_extras};
use super::tests::{N1, N2, N3, card, note};
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close};
use crate::store::gen4::kernel::G4Core;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{DAY, Device, P, edit, review};

const N5: &str = "0193a1b2-0000-7000-8000-0000000000a5";
const N6: &str = "0193a1b2-0000-7000-8000-0000000000a6";
/// 再加进 `DNEW`（新卡上限 2）的笔记：今天引入两张新卡之后这个牌组就不再出新卡——计数上下文里「今天已引入」漏读就会
/// 多出新卡。
const NEWER: [&str; 3] = [
    "0193a1b2-0000-7000-8000-0000000000b1",
    "0193a1b2-0000-7000-8000-0000000000b2",
    "0193a1b2-0000-7000-8000-0000000000b3",
];
const HOUR: i64 = 3_600_000;
/// 「今天」：T1 之后的 06:13（UTC，翻日 04:00），各步作答都落在这一天里。
const NOW: i64 = T1 + 8 * HOUR;

/// [study_extras] 再加 [NEWER]。
fn prep(d: &Device) {
    study_extras(d);
    let mut ev = Vec::new();
    for (i, n) in NEWER.iter().enumerate() {
        ev.push(note(n, "NT", 70 + i as i64));
        ev.push(edit("note", n, "f/fa", json!(format!("新{i}"))));
        ev.push(edit("note", n, "deck", json!("DNEW")));
    }
    d.apply(super::tests::T0 + DAY + 90, ev);
}

fn col_of(core: &G4Core) -> i64 {
    core.read(|t| Ok(t.binding_of(P)?.unwrap().col)).unwrap()
}

fn stateless(core: &G4Core, col: i64, req: &Value) -> Value {
    core.read(|t| study_stateless(t, col, req)).unwrap()
}

fn study_req(now: i64, extra: Value) -> Value {
    let mut r = json!({"now": now, "utcOff": 0, "rollover": 4});
    for (k, v) in extra.as_object().unwrap() {
        r[k] = v.clone();
    }
    r
}

/// 此刻 [now] 的整组请求经分发器（[h]：Primary 或 Secondary 的句柄）排队，与无状态基准逐个相同。返回出过卡的请求数。
fn check(h: *mut SrsCoreHandle, core: &G4Core, col: i64, now: i64, tag: &str) -> usize {
    let mut picked = 0;
    for req in requests_at(now) {
        let got = g4(h, "study", now, req.clone());
        assert_eq!(got, stateless(core, col, &req), "{tag}: {req}");
        picked += usize::from(!got["next"].is_null());
    }
    picked
}

fn builds(core: &G4Core) -> usize {
    core.study.builds.load(Ordering::SeqCst)
}

/// 作答一张卡（`apply` 带 `intent: answer`），请求带 `study`（`answerAndStudy` 的形状）：同一个事务里的排队与提交之后的
/// 无状态基准相同。返回回包。
fn answer(
    h: *mut SrsCoreHandle,
    core: &G4Core,
    col: i64,
    id: &str,
    note: &str,
    tmpl: &str,
    at: i64,
    rating: i64,
    rtype: &str,
) -> Value {
    let c = card(note, tmpl);
    let items =
        vec![json!({"e": review(id, &c, at, rating, rtype), "note": note, "intent": "answer"})];
    let sreq = study_req(at + 1, json!({"deck": default_deck_id(P), "pick": true}));
    let (v, _) = call(
        h,
        &g4req("apply", at, json!({"study": sreq.clone()})),
        Some(&items),
    )
    .unwrap();
    assert_eq!(v["landed"], json!([true]), "{v}");
    assert_eq!(v["study"], stateless(core, col, &sreq), "answer {id}");
    v
}

#[test]
fn the_resident_session_matches_a_fresh_read_through_every_kind_of_write() {
    let m = migrated_prepared(false, &prep);
    let core = crate::store::ffi::core_of(m.h).unwrap();
    let col = col_of(&core);
    let deck = default_deck_id(P);

    // 建会话。
    assert!(check(m.h, &core, col, NOW, "initial") >= 5);
    let b0 = builds(&core);
    assert!(b0 >= 1);

    // 本机作答：新卡的第一条学习步（引入）、学习卡又一步、到期复习、评重来。
    let mut at = NOW;
    for (id, note, tmpl, rating, rtype) in [
        ("sa1", NEWER[0], "t1", 3, "learn"),
        ("sa2", NEWER[1], "t2", 3, "learn"),
        ("sa3", NEWER[0], "t1", 3, "learn"),
        ("sa3b", N5, "t2", 3, "learn"),
        ("sa4", N1, "t1", 3, "review"),
        ("sa5", N2, "t1", 1, "review"),
        ("sa6", N3, "t2", 3, "learn"),
    ] {
        at += 60_000;
        answer(m.h, &core, col, id, note, tmpl, at, rating, rtype);
        check(m.h, &core, col, at + 1, id);
    }
    assert_eq!(builds(&core), b0, "local answers reread incrementally");

    // 撤销最后一条作答（`sched` 的 undo）。
    at += 60_000;
    let undo = json!({"at": at, "utcOff": 0, "rollover": 4, "ts": "anchored",
        "items": [{"a": "undo", "card": card(N3, "t2"), "log": "sa6"}]});
    let v = g4(m.h, "sched", at, undo);
    assert_eq!(v["blocked"], json!(0), "{v}");
    // 撤销让别名表整表重算（全删再按原值写回）：没有净变化，不整份重建。
    assert_eq!(v["settled"]["aliasRebuilds"], json!(1), "{v}");
    check(m.h, &core, col, at + 1, "undo");

    // 别的设备的写入（`apply {remote}`）：一条复习、把 N1 挪进子牌组。
    at += 60_000;
    let remote = vec![
        json!({"e": review("rm1", &card(N2, "t2"), at - 30_000, 3, "learn"), "note": N2}),
        json!({"e": edit("note", N1, "deck", json!("DCHILD")), "note": N1}),
    ];
    call(
        m.h,
        &g4req("apply", at, json!({"remote": true})),
        Some(&remote),
    )
    .unwrap();
    check(m.h, &core, col, at + 1, "remote");

    // 改牌组上限（只动牌组树：每次排队照读）、改字段。
    at += 60_000;
    let items = vec![
        json!({"e": edit("deck", "DNEW", "limits", json!({"new": 5, "review": 50})), "note": N5}),
        json!({"e": edit("note", N3, "f/fa", json!("狼")), "note": N3}),
    ];
    call(m.h, &g4req("apply", at, json!({})), Some(&items)).unwrap();
    check(m.h, &core, col, at + 1, "limits");

    // 整笔回滚：作答落下之后排队报错（请求缺日界），整条命令回滚；会话按回滚后的库重读。
    at += 60_000;
    let items = vec![
        json!({"e": review("rb1", &card(N6, "t1"), at, 3, "learn"), "note": N6, "intent": "answer"}),
    ];
    let bad = json!({"now": at, "deck": deck, "pick": true});
    assert!(
        call(
            m.h,
            &g4req("apply", at, json!({"study": bad})),
            Some(&items)
        )
        .is_err()
    );
    check(m.h, &core, col, at + 1, "rolled back");
    assert_eq!(builds(&core), b0, "still incremental");

    // Secondary：看不见写连接的触发器，按刷新键印记判；Primary 写了之后照样相同。
    let sec = open(&m.dir.0, 1).unwrap();
    check(sec, &core, col, at + 1, "secondary");
    at += 60_000;
    answer(m.h, &core, col, "sa7", N6, "t1", at, 3, "learn");
    check(sec, &core, col, at + 1, "secondary after a primary write");
    ffsrs_store_close(sec);

    // 换日：整份重建，之后照样增量。
    let tomorrow = at + DAY;
    check(m.h, &core, col, tomorrow, "tomorrow");
    let b1 = builds(&core);
    assert_eq!(b1, b0 + 1, "a new day rebuilds once");
    answer(m.h, &core, col, "sb1", N5, "t1", tomorrow + 10, 3, "review");
    check(m.h, &core, col, tomorrow + 11, "tomorrow after an answer");
    assert_eq!(builds(&core), b1);
}

/// 别名表按净变化记账：同一个事务里删了又按原值插回（整表重算）互相抵消，不整份重建；真变了（还没提交时排队也算上）
/// 整份重建。
#[test]
fn alias_rows_count_by_their_net_change() {
    let hub = crate::store::queue::StudyHub::default();
    hub.touch_study_net("1".into(), "aa:bb".into(), -1);
    hub.touch_study_net("1".into(), "aa:bb".into(), 1);
    hub.settle();
    assert!(!hub.take_study("1").overflow, "rewritten as it was");
    hub.touch_study_net("1".into(), "aa:bb".into(), -1);
    hub.touch_study_net("1".into(), "aa:cc".into(), 1);
    hub.settle();
    assert!(hub.take_study("1").overflow, "a moved alias");
    assert!(!hub.take_study("1").overflow, "taken");
    assert!(!hub.take_study("2").overflow, "another collection");
}
