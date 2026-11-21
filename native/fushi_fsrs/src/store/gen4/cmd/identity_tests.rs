//! 身份命令（G9-4，`cmd/identity.rs`）的端到端测试：一律经 C ABI（`ffsrs_store_open_mode` / `ffsrs_store_sync2`，
//! 装置在 `dispatch_tests.rs`）。
//!
//! - 全新库：`identity` 建绑定与本机身份 → 写 → 读；Secondary 只读；之前的按集合命令明确报错。
//! - 迁移来的库：`identity` 与协议 3 的可比字段对拍、`binding_set` 与协议 3 逐条对拍。
//! - 多个 profile：各自的集合；同一个集合不能绑两个 profile；没绑过的 profile 经 `collection_adopt` 先加入。
//! - 改绑（`collection_join`）不丢笔记、卡片、复习日志与修改历史，内置实体的规范 ID 不变。
//! - 绑定变化的事件：返回了变化就在回包里，提交前 panic（回滚）就没有回包、库没变（规划缺口 G-4），每条可能改绑定的
//!   命令各一次；进了写路径但绑定没变（只缺本机身份、并发的第二个调用方）不发。
//! - `canonical_ids` / `key_evidence` 的条数上限。
//! - 别名类：`canonical_ids` 把成员归到规范 ID；`key_evidence` / `divergence` 的形状。

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::dispatch_tests::{T1, call, cfg, g4, g4req, migrated, open, p3};
use super::identity::{LOOKUP_MAX, identity_ensure, identity_read};
use super::tests::{N1, T0};
use super::tests_class;
use crate::gen4::op::tests::id;
use crate::store::ffi::{STORE_ERROR, STORE_PANIC, ffsrs_store_close};
use crate::store::gen4::files::OpenMode;
use crate::store::gen4::kernel::{G4Core, READ_ONLY};
use crate::store::sync2::collection_of;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::test_panic;
use crate::store::sync2::tests::{P, edit, tempdir};

const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";
const R: &str = "0193a1b2-0000-7000-8000-00000000d00d";

/// 发给 [profile] 的一条命令（[g4req] 固定发给 P）。
fn as_profile(
    h: *mut crate::store::ffi::SrsCoreHandle,
    profile: &str,
    op: &str,
    extra: Value,
) -> Value {
    let mut req = g4req(op, T1, extra);
    req["profile"] = json!(profile);
    call(h, &req, None)
        .unwrap_or_else(|(rc, e)| panic!("{req}: {rc} {e}"))
        .0
}

fn err_of(h: *mut crate::store::ffi::SrsCoreHandle, op: &str, extra: Value) -> (i32, String) {
    call(h, &g4req(op, T1, extra), None).unwrap_err()
}

// ---------------------------------------------------------------------- 全新库

/// 全新库：`identity` 之前按集合的命令明确报错；`identity` 建出绑定（集合标识 = `collection_of(uid)`，目录名 = uid）
/// 与本机身份、带 `bindingChanged`；之后写得进、读得出，第二次 `identity` 只是读、不再带事件；Secondary 读得到同一个
/// 身份，没绑过的 profile 在 Secondary 上报只读。
#[test]
fn a_fresh_profile_gets_an_identity_then_writes_and_reads() {
    let dir = tempdir::new("g94fresh");
    let h = open(&dir.0, 0).unwrap();
    let (rc, e) = err_of(h, "binding_get", json!({}));
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains("has no collection"), "{e}");
    // `identity` 要一个时刻（建身份与 `Salts` 的 HLC 起点）。
    let mut no_now = g4req("identity", T1, json!({}));
    no_now.as_object_mut().unwrap().remove("now");
    let (_, e) = call(h, &no_now, None).unwrap_err();
    assert!(e.contains("missing now"), "{e}");

    let id1 = g4(h, "identity", T1, json!({"legacyDevice": "dev"}));
    assert_eq!(id1["collection"], json!(collection_of(P).text()), "{id1}");
    assert_eq!(id1["dir"], json!(P));
    assert_eq!(id1["migrated"], json!(true));
    // 本机日志里第一条是 `Salts{P}`。
    assert_eq!(id1["nextSeq"], json!(2), "{id1}");
    assert_eq!(id1["name"], json!(""));
    assert_eq!(id1["public"].as_str().unwrap().len(), 64);
    assert_eq!(id1["bindingChanged"], json!({"profile": P}));
    for gone in ["legacyWriter", "channel"] {
        assert!(id1.get(gone).is_none(), "{gone}: {id1}");
    }
    let id2 = g4(h, "identity", T1 + 1, json!({}));
    assert!(id2.get("bindingChanged").is_none(), "{id2}");
    for k in ["device", "collection", "dir", "nextSeq", "public"] {
        assert_eq!(id2[k], id1[k], "{k}");
    }
    let info = g4(h, "collection_info", T1, json!({}));
    assert_eq!(info["salts"], json!([P]), "{info}");
    assert_eq!(info["binding"], Value::Null);
    assert_eq!(info["joins"], json!([]));

    // 写 → 读。
    g4(h, "cache_config_set", T1, json!({"caches": cfg()}));
    let items = vec![json!({"e": edit("note", N1, "f/fa", json!("鯨")), "note": N1})];
    let (v, _) = call(h, &g4req("apply", T1, json!({})), Some(&items)).unwrap();
    assert_eq!(v["landed"], json!([true]), "{v}");
    let hist = g4(h, "history", T1, json!({"kind": "note", "entity": N1}));
    assert!(
        hist.as_array()
            .unwrap()
            .iter()
            .any(|e| e["value"] == json!("鯨")),
        "{hist}"
    );
    assert_eq!(g4(h, "identity", T1, json!({}))["nextSeq"], json!(3));
    assert!(
        g4(h, "profile_footprint", T1, json!({}))["rows"]
            .as_i64()
            .unwrap()
            > 0
    );

    // Secondary：有身份的读得到；没绑过的 profile 报只读，什么都不建。
    let s = open(&dir.0, 1).unwrap();
    let sid = g4(s, "identity", T1, json!({}));
    assert_eq!(sid["device"], id1["device"]);
    let mut req = g4req("identity", T1, json!({}));
    req["profile"] = json!(Q);
    let (rc, e) = call(s, &req, None).unwrap_err();
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains(READ_ONLY), "{e}");
    ffsrs_store_close(s);
    let (_, e) = call(
        h,
        &{
            let mut r = g4req("binding_get", T1, json!({}));
            r["profile"] = json!(Q);
            r
        },
        None,
    )
    .unwrap_err();
    assert!(e.contains("has no collection"), "{e}");
    ffsrs_store_close(h);
}

// ---------------------------------------------------------------------- 迁移来的库：对拍

/// 迁移来的库上 `identity` 与协议 3 的可比字段相同：集合标识、公钥（签名钥匙随迁移带过去，D11）、人读名；设备 ID
/// 是迁移换的新身份（设计 §3.3），`nextSeq` 指新身份的日志；`migrated` 两侧都是真；协议 3 的 `legacyWriter` /
/// `channel` 新代不回。已有身份的 `identity` 不带事件。
#[test]
fn identity_matches_protocol_3_on_a_migrated_library() {
    let m = migrated();
    let old = p3(&m.d, "identity", T1, json!({}), None).0;
    let new = g4(m.h, "identity", T1, json!({"legacyDevice": "dev"}));
    for k in ["collection", "public", "name", "migrated"] {
        assert_eq!(new[k], old[k], "{k}: {old} vs {new}");
    }
    assert_eq!(new["dir"], json!(P));
    assert_ne!(new["device"], old["device"]);
    assert!(new["nextSeq"].as_u64().unwrap() >= 2, "{new}");
    assert!(
        old.get("legacyWriter").is_some() && old.get("channel").is_some(),
        "{old}"
    );
    for gone in ["legacyWriter", "channel", "bindingChanged"] {
        assert!(new.get(gone).is_none(), "{gone}: {new}");
    }
    // `device_info` 改了名字，两侧的 `name` 一起变。
    p3(&m.d, "device_info", T1, json!({"nick": "書斎"}), None);
    g4(m.h, "device_info", T1, json!({"nick": "書斎"}));
    assert_eq!(
        g4(m.h, "identity", T1, json!({}))["name"],
        p3(&m.d, "identity", T1, json!({}), None).0["name"]
    );
}

/// `binding_set` 经分发器与协议 3 逐条相同：只进不退（`settled` 之后不改）、`provisional` 再写只换 `via` / `at`、
/// 认不出的状态报错；绑定状态不是绑定（不影响任何 ID），不带事件。
#[test]
fn binding_set_matches_protocol_3() {
    let m = migrated();
    let steps = [
        ("provisional", "loc-a", T1),
        ("provisional", "loc-b", T1 + 1),
        ("settled", "loc-c", T1 + 2),
        ("provisional", "loc-d", T1 + 3),
        ("settled", "loc-e", T1 + 4),
    ];
    for (state, via, at) in steps {
        let extra = json!({"state": state, "via": via});
        let old = p3(&m.d, "binding_set", at, extra.clone(), None).0;
        let new = g4(m.h, "binding_set", at, extra);
        assert_eq!(new, old, "{state} {via}");
        assert_eq!(
            g4(m.h, "binding_get", at, json!({})),
            p3(&m.d, "binding_get", at, json!({}), None).0
        );
    }
    let (rc, e) = err_of(m.h, "binding_set", json!({"state": "bound", "via": "x"}));
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains("unknown state"), "{e}");
}

// ---------------------------------------------------------------------- 多个 profile

/// 两个 profile 各自一个集合；同一个集合不能再绑给第二个 profile（设计 §5.1）；没绑过的 profile 认领另一个集合：
/// 没确认 = `needsConfirm`、什么都不写，确认 = 直接绑（「先加入」）并在同一个事务里建本机身份，带事件。
#[test]
fn profiles_bind_to_their_own_collections_and_an_unbound_one_joins_first() {
    let dir = tempdir::new("g94multi");
    let h = open(&dir.0, 0).unwrap();
    let p = g4(h, "identity", T1, json!({}));
    let q = as_profile(h, Q, "identity", json!({}));
    assert_ne!(p["collection"], q["collection"]);
    assert_ne!(p["device"], q["device"]);
    assert_eq!(q["dir"], json!(Q));
    // Q 认领 P 的集合：同机两个 profile 不能是同一个集合。
    let mut req = g4req(
        "collection_adopt",
        T1,
        json!({"collection": p["collection"], "dir": P, "confirmed": true}),
    );
    req["profile"] = json!(Q);
    let (rc, e) = call(h, &req, None).unwrap_err();
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains("already bound to profile"), "{e}");
    assert_eq!(
        as_profile(h, Q, "identity", json!({}))["collection"],
        q["collection"]
    );

    // R 还没绑过：先问用户。
    let foreign = id(0xe0).text();
    let ask = json!({"collection": foreign, "dir": "zz-remote", "salts": ["old-uid"]});
    let v = as_profile(h, R, "collection_adopt", ask.clone());
    assert_eq!(v, json!({"outcome": "needsConfirm"}));
    let mut req = g4req("binding_get", T1, json!({}));
    req["profile"] = json!(R);
    assert!(
        call(h, &req, None)
            .unwrap_err()
            .1
            .contains("has no collection")
    );
    let mut yes = ask.clone();
    yes["confirmed"] = json!(true);
    let v = as_profile(h, R, "collection_adopt", yes);
    assert_eq!(v["outcome"], json!("bound"), "{v}");
    assert_eq!(v["bindingChanged"], json!({"profile": R}));
    let r = as_profile(h, R, "identity", json!({}));
    assert_eq!(r["collection"], json!(foreign));
    assert_eq!(r["dir"], json!("zz-remote"));
    assert!(
        r.get("bindingChanged").is_none(),
        "身份已在认领的事务里建好：{r}"
    );
    assert_eq!(r["nextSeq"], json!(2), "本机写了 Salts{{R}}：{r}");
    let info = as_profile(h, R, "collection_info", json!({}));
    assert_eq!(info["salts"], json!([R]), "{info}");
    // 三个 profile 互不影响。
    assert_eq!(
        g4(h, "identity", T1, json!({}))["collection"],
        p["collection"]
    );
    ffsrs_store_close(h);
}

// ---------------------------------------------------------------------- 改绑

/// 改绑（本机并入另一个集合）：提交前 panic 就没有回包、库没变；成功时回包带事件，之后笔记、卡片、复习日志、修改
/// 历史一条不少，内置实体（默认牌组）的规范 ID 不变，`collection_info` 列出这条 `Join`。方向反了报错、什么都不写。
#[test]
fn a_join_keeps_cards_and_logs_and_reports_the_change_only_after_commit() {
    let m = migrated();
    let before_id = g4(m.h, "identity", T1, json!({}));
    let foot = g4(m.h, "profile_footprint", T1, json!({}));
    let hist = g4(m.h, "history", T1, json!({"kind": "note", "entity": N1}));
    let deck = default_deck_id(P);
    let canon = g4(m.h, "canonical_ids", T1, json!({"ids": [deck, N1]}));
    let into = id(0x0a).text();
    // 目录名比本机的大：应当由对方并入本机。
    let (rc, e) = err_of(
        m.h,
        "collection_join",
        json!({"into": into, "dir": "ffff-later"}),
    );
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains("joins this collection"), "{e}");
    // 提交之前 panic：整笔回滚，没有回包（也就没有事件）。
    test_panic::arm(test_panic::BEFORE_RELEASE);
    let (rc, e) = err_of(
        m.h,
        "collection_join",
        json!({"into": into, "dir": "0000-home"}),
    );
    assert_eq!(rc, STORE_PANIC, "{e}");
    assert!(!test_panic::armed(), "the injected panic fired");
    let same = g4(m.h, "identity", T1, json!({}));
    assert_eq!(same["collection"], before_id["collection"]);
    assert_eq!(same["nextSeq"], before_id["nextSeq"]);
    assert_eq!(
        g4(m.h, "collection_info", T1, json!({}))["joins"],
        json!([])
    );

    let v = g4(
        m.h,
        "collection_join",
        T1,
        json!({"into": into, "dir": "0000-home"}),
    );
    assert_eq!(v["outcome"], json!("joined"), "{v}");
    assert_eq!(v["rebound"], json!(true));
    assert_eq!(v["collection"], json!(into));
    assert_eq!(v["from"], before_id["collection"]);
    assert_eq!(v["bindingChanged"], json!({"profile": P}));
    let after = g4(m.h, "identity", T1, json!({}));
    assert_eq!(after["collection"], json!(into));
    assert_eq!(after["dir"], json!("0000-home"));
    assert_eq!(after["device"], before_id["device"], "本机身份不动");
    assert_eq!(
        g4(m.h, "profile_footprint", T1, json!({}))["notes"],
        foot["notes"]
    );
    assert_eq!(
        g4(m.h, "profile_footprint", T1, json!({}))["cards"],
        foot["cards"]
    );
    assert_eq!(
        g4(m.h, "profile_footprint", T1, json!({}))["reviews"],
        foot["reviews"]
    );
    assert_eq!(
        g4(m.h, "history", T1, json!({"kind": "note", "entity": N1})),
        hist
    );
    assert_eq!(
        g4(m.h, "canonical_ids", T1, json!({"ids": [deck, N1]})),
        canon,
        "盐随 Join 带进新集合，规范 ID 不变"
    );
    let info = g4(m.h, "collection_info", T1, json!({}));
    let joins = info["joins"].as_array().unwrap();
    assert_eq!(joins.len(), 1, "{info}");
    assert_eq!(joins[0]["from"], before_id["collection"]);
    assert_eq!(joins[0]["dir"], json!(P));
    assert_eq!(joins[0]["trusted"], json!(true));
    assert!(
        joins[0]["salts"].as_array().unwrap().contains(&json!(P)),
        "{info}"
    );
    // 已经绑在对方上：再并一次报错。
    let (_, e) = err_of(
        m.h,
        "collection_join",
        json!({"into": into, "dir": "0000-home"}),
    );
    assert!(e.contains("already bound"), "{e}");
}

/// 补盐与认领：没有新东西 = `same`、不带事件；有新盐 = `saltsAdded`、带事件、盐集合里有它；提交前 panic 就没有回包、
/// 盐集合没变。
#[test]
fn salts_add_and_adopt_report_a_change_only_when_the_binding_changed() {
    let m = migrated();
    let v = g4(m.h, "collection_salts_add", T1, json!({"salts": [P]}));
    assert_eq!(v, json!({"outcome": "same"}));
    let me = g4(m.h, "identity", T1, json!({}));
    let v = g4(
        m.h,
        "collection_adopt",
        T1,
        json!({"collection": me["collection"], "dir": me["dir"], "salts": [P]}),
    );
    assert_eq!(v, json!({"outcome": "same"}));
    // 回滚：没有回包，盐集合不变。
    test_panic::arm(test_panic::BEFORE_RELEASE);
    let (rc, e) = err_of(m.h, "collection_salts_add", json!({"salts": ["old-uid"]}));
    assert_eq!(rc, STORE_PANIC, "{e}");
    let salts = g4(m.h, "collection_info", T1, json!({}))["salts"].clone();
    assert!(
        !salts.as_array().unwrap().contains(&json!("old-uid")),
        "{salts}"
    );

    let v = g4(
        m.h,
        "collection_salts_add",
        T1,
        json!({"salts": ["old-uid"]}),
    );
    assert_eq!(v["outcome"], json!("saltsAdded"), "{v}");
    assert_eq!(v["bindingChanged"], json!({"profile": P}));
    let salts = g4(m.h, "collection_info", T1, json!({}))["salts"].clone();
    assert!(
        salts.as_array().unwrap().contains(&json!("old-uid")),
        "{salts}"
    );
    // 同一批盐再来一次：什么都不写。
    let v = g4(
        m.h,
        "collection_salts_add",
        T1,
        json!({"salts": ["old-uid", P]}),
    );
    assert_eq!(v, json!({"outcome": "same"}));
    // 坏请求。
    let (_, e) = err_of(m.h, "collection_salts_add", json!({"salts": "old-uid"}));
    assert!(e.contains("salts must be an array"), "{e}");
    let (_, e) = err_of(
        m.h,
        "collection_adopt",
        json!({"collection": "not-a-uuid", "dir": "x"}),
    );
    assert!(e.contains("bad collection"), "{e}");
}

// ---------------------------------------------------------------------- 别名类

/// 双盐场景（`tests_class.rs`）经分发器：`canonical_ids` 把两份成员与规范 ID 都归到规范 ID，非 UUID 原样、顺序与条数
/// 照请求；`key_evidence` 按成员 ID 原样答；`divergence` 回两张表；`collection_info` 列出盐。
#[test]
fn alias_class_members_canonicalize_through_the_identity_commands() {
    let dir = tempdir::new("g94alias");
    let w = {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        let col = c.write(|t| t.bind(P, &id(0xc0), "dir")).unwrap();
        let w = c.write(|t| Ok(tests_class::land(t, col))).unwrap();
        c.close();
        w
    };
    let h = open(&dir.0, 0).unwrap();
    let ids = [
        w.note[0].text(),
        w.note[1].text(),
        w.c_note.text(),
        w.note[0].text(),
        "plain-text".to_owned(),
    ];
    let v = g4(h, "canonical_ids", T1, json!({"ids": ids}));
    let c = w.c_note.text();
    assert_eq!(v, json!({"ids": [c, c, c, c, "plain-text"]}));
    let ev = g4(
        h,
        "key_evidence",
        T1,
        json!({"items": [
            {"kind": "notetype", "entity": w.nt[0].text()},
            {"kind": "notetype", "entity": w.nt[1].text()},
            {"kind": "note", "entity": id(0x77).text()},
        ]}),
    );
    let n = ev["evidence"].as_array().unwrap();
    assert_eq!(n.len(), 3, "{ev}");
    assert!(n[0].as_u64().unwrap() >= 1, "{ev}");
    assert_eq!(n[2], json!(0));
    let (_, e) = err_of(
        h,
        "key_evidence",
        json!({"items": [{"kind": "nope", "entity": "x"}]}),
    );
    assert!(e.contains("unknown kind"), "{e}");
    let d = g4(h, "divergence", T1, json!({}));
    assert!(
        d["hollowed"].is_array() && d["withheldSalts"].is_array(),
        "{d}"
    );
    // 这个集合还没有本机身份：`identity` 补建（绑定已在，只建身份并补 `Salts{P}`），盐集合变了带事件；成员照旧归一。
    let me = g4(h, "identity", T1, json!({}));
    assert_eq!(me["collection"], json!(id(0xc0).text()));
    assert_eq!(me["bindingChanged"], json!({"profile": P}), "{me}");
    assert_eq!(g4(h, "canonical_ids", T1, json!({"ids": ids})), v);
    ffsrs_store_close(h);
}

/// 新代才有的身份命令都有臂、经分发器答得出（不是「接线了却没有臂」）。
#[test]
fn every_identity_command_has_an_arm() {
    let m = migrated();
    for (op, extra) in [
        ("collection_info", json!({})),
        ("canonical_ids", json!({"ids": []})),
        ("key_evidence", json!({"items": []})),
        ("divergence", json!({})),
        ("collection_salts_add", json!({"salts": []})),
    ] {
        let v = g4(m.h, op, T0 + 5, extra);
        assert!(v.is_object(), "{op}: {v}");
    }
}

// ---------------------------------------------------------------------- 绑定变化：没变就不发

/// 进了 `identity` 的写路径、但绑定没变：profile 已绑定、只缺本机身份、盐集合里已有这个 uid（例如另一台同 uid 设备的
/// `Salts` 已经收进来）。建本机身份，不写 `Salts`、不带 `bindingChanged`（规划 G-4「返回 Some 才发」；恒发会让 Dart
/// 白做一次「库换了」的整份重读）。
#[test]
fn identity_that_only_builds_the_local_identity_reports_no_binding_change() {
    let dir = tempdir::new("g94nochange");
    {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        c.write(|t| {
            let col = t.bind(P, &collection_of(P), P)?;
            t.set_salts(col, &BTreeSet::from([P.to_owned()]))
        })
        .unwrap();
        c.close();
    }
    let h = open(&dir.0, 0).unwrap();
    let me = g4(h, "identity", T1, json!({}));
    assert!(me.get("bindingChanged").is_none(), "{me}");
    assert_eq!(me["nextSeq"], json!(1), "盐集合里已有 P，不写 Salts：{me}");
    assert_eq!(me["public"].as_str().unwrap().len(), 64);
    let info = g4(h, "collection_info", T1, json!({}));
    assert_eq!(info["salts"], json!([P]), "{info}");
    ffsrs_store_close(h);
}

/// 两个调用方的读路径都看到「没有身份」、先后进写事务（`dispatch.rs` `identity`）：先进的建、带变化；后进的在事务里
/// 重查到已建好，只是读——同一个设备 ID、不再建第二份、不带变化。
#[test]
fn a_second_caller_that_also_saw_no_identity_builds_nothing_and_reports_no_change() {
    let dir = tempdir::new("g94race");
    let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
    assert!(c.read(|t| identity_read(t, P)).unwrap().is_none());
    assert!(c.read(|t| identity_read(t, P)).unwrap().is_none());
    let (first, ch1) = c.write(|t| identity_ensure(t, P, T1)).unwrap();
    assert_eq!(ch1.map(|c| c.profile), Some(P.to_owned()));
    let (second, ch2) = c.write(|t| identity_ensure(t, P, T1 + 1)).unwrap();
    assert!(ch2.is_none(), "{second}");
    assert_eq!(second, first, "同一份身份，没有第二条 Salts");
    assert_eq!(
        c.read(|t| identity_read(t, P)).unwrap().as_ref(),
        Some(&first)
    );
    c.close();
}

// ---------------------------------------------------------------------- 绑定变化：回滚就不发

/// 规划 G-4：每条可能改绑定的命令，提交前 panic 就没有回包（也就没有事件）、什么都没建。`identity`（全新库）与
/// `collection_adopt confirmed=true` 的 `bound`（没绑过的 profile）：回滚后照旧「has no collection」，之后重来成功、
/// 带事件。
#[test]
fn identity_and_adopt_bound_roll_back_without_an_event() {
    let dir = tempdir::new("g94rollbk");
    let h = open(&dir.0, 0).unwrap();
    test_panic::arm(test_panic::BEFORE_RELEASE);
    let (rc, e) = err_of(h, "identity", json!({}));
    assert_eq!(rc, STORE_PANIC, "{e}");
    assert!(!test_panic::armed(), "the injected panic fired");
    let (_, e) = err_of(h, "binding_get", json!({}));
    assert!(e.contains("has no collection"), "回滚后什么都没建：{e}");

    let foreign = id(0xe1).text();
    let mut adopt = g4req(
        "collection_adopt",
        T1,
        json!({"collection": foreign, "dir": "zz-remote", "confirmed": true}),
    );
    adopt["profile"] = json!(R);
    test_panic::arm(test_panic::BEFORE_RELEASE);
    let (rc, e) = call(h, &adopt, None).unwrap_err();
    assert_eq!(rc, STORE_PANIC, "{e}");
    assert!(!test_panic::armed(), "the injected panic fired");
    let mut get = g4req("binding_get", T1, json!({}));
    get["profile"] = json!(R);
    let (_, e) = call(h, &get, None).unwrap_err();
    assert!(e.contains("has no collection"), "回滚后 R 没绑：{e}");

    let me = g4(h, "identity", T1, json!({}));
    assert_eq!(me["bindingChanged"], json!({"profile": P}), "{me}");
    let v = call(h, &adopt, None).unwrap().0;
    assert_eq!(v["outcome"], json!("bound"), "{v}");
    assert_eq!(v["bindingChanged"], json!({"profile": R}));
    ffsrs_store_close(h);
}

/// `collection_adopt confirmed=true` 的 `joined`（已绑定的 profile 并入对方）：提交前 panic 就没有回包、集合与
/// `joins` 不变；重来成功、带事件。
#[test]
fn adopt_joined_rolls_back_without_an_event() {
    let m = migrated();
    let before = g4(m.h, "identity", T1, json!({}));
    let into = id(0x0b).text();
    let ask = json!({"collection": into, "dir": "0000-home", "confirmed": true});
    test_panic::arm(test_panic::BEFORE_RELEASE);
    let (rc, e) = err_of(m.h, "collection_adopt", ask.clone());
    assert_eq!(rc, STORE_PANIC, "{e}");
    assert!(!test_panic::armed(), "the injected panic fired");
    let same = g4(m.h, "identity", T1, json!({}));
    assert_eq!(same["collection"], before["collection"]);
    assert_eq!(same["nextSeq"], before["nextSeq"]);
    assert_eq!(
        g4(m.h, "collection_info", T1, json!({}))["joins"],
        json!([])
    );

    let v = g4(m.h, "collection_adopt", T1, ask);
    assert_eq!(v["outcome"], json!("joined"), "{v}");
    assert_eq!(v["bindingChanged"], json!({"profile": P}));
    assert_eq!(
        g4(m.h, "identity", T1, json!({}))["collection"],
        json!(into)
    );
}

// ---------------------------------------------------------------------- 上限

/// `canonical_ids` / `key_evidence` 一次最多 [LOOKUP_MAX] 条：超了明确报错（调用方分批），正好上限照常答。
#[test]
fn lookups_are_capped_per_request() {
    let m = migrated();
    let ids: Vec<String> = (0..=LOOKUP_MAX).map(|i| format!("x{i}")).collect();
    let (rc, e) = err_of(m.h, "canonical_ids", json!({"ids": ids}));
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains("at most"), "{e}");
    let ok = g4(m.h, "canonical_ids", T1, json!({"ids": ids[..LOOKUP_MAX]}));
    assert_eq!(ok["ids"].as_array().unwrap().len(), LOOKUP_MAX);

    let item = json!({"kind": "note", "entity": N1});
    let items = vec![item; LOOKUP_MAX + 1];
    let (rc, e) = err_of(m.h, "key_evidence", json!({"items": items}));
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains("at most"), "{e}");
    let ok = g4(
        m.h,
        "key_evidence",
        T1,
        json!({"items": items[..LOOKUP_MAX]}),
    );
    assert_eq!(ok["evidence"].as_array().unwrap().len(), LOOKUP_MAX);
}

// ---------------------------------------------------------------------- 位置目录名 → profile（G10-4）

/// 不带 profile 的 `profile_of_dir`。
fn of_dir(h: *mut crate::store::ffi::SrsCoreHandle, dir: Value) -> Result<Value, (i32, String)> {
    call(h, &json!({"op": "profile_of_dir", "dir": dir}), None).map(|(v, _)| v)
}

/// `profile_of_dir` 按**绑定**的目录名找 profile：没绑过的目录是空表；认领到别的目录的 profile 只在那个目录下出现、
/// 不在自己的 uid 下出现（目录名 ≠ 本机 uid）；并入改绑后跟着新目录走。请求不需要 profile。
#[test]
fn profile_of_dir_follows_the_binding_not_the_uid() {
    let dir = tempdir::new("g104ofdir");
    let h = open(&dir.0, 0).unwrap();
    assert_eq!(of_dir(h, json!(P)).unwrap(), json!({"profiles": []}));
    g4(h, "identity", T1, json!({}));
    as_profile(h, Q, "identity", json!({}));
    assert_eq!(of_dir(h, json!(P)).unwrap(), json!({"profiles": [P]}));
    assert_eq!(of_dir(h, json!(Q)).unwrap(), json!({"profiles": [Q]}));
    // R 认领了位置目录 `zz-remote` 上的集合：找得到的是那个目录，不是 R 的 uid。
    let foreign = id(0xe0).text();
    let v = as_profile(
        h,
        R,
        "collection_adopt",
        json!({"collection": foreign, "dir": "zz-remote", "salts": [], "confirmed": true}),
    );
    assert_eq!(v["outcome"], json!("bound"), "{v}");
    assert_eq!(
        of_dir(h, json!("zz-remote")).unwrap(),
        json!({"profiles": [R]})
    );
    assert_eq!(of_dir(h, json!(R)).unwrap(), json!({"profiles": []}));
    // 大小写不同的目录名不是同一个目录。
    assert_eq!(
        of_dir(h, json!("ZZ-REMOTE")).unwrap(),
        json!({"profiles": []})
    );
    ffsrs_store_close(h);

    // 并入改绑：目录跟着绑定走。
    let m = migrated();
    g4(m.h, "identity", T1, json!({}));
    assert_eq!(of_dir(m.h, json!(P)).unwrap(), json!({"profiles": [P]}));
    let v = g4(
        m.h,
        "collection_join",
        T1,
        json!({"into": id(0x0a).text(), "dir": "0000-home"}),
    );
    assert_eq!(v["outcome"], json!("joined"), "{v}");
    assert_eq!(
        of_dir(m.h, json!("0000-home")).unwrap(),
        json!({"profiles": [P]})
    );
    assert_eq!(of_dir(m.h, json!(P)).unwrap(), json!({"profiles": []}));
    // 只读的 Secondary 上同样能查（读命令）。
    let s = open(&m.dir.0, 1).unwrap();
    assert_eq!(
        of_dir(s, json!("0000-home")).unwrap(),
        json!({"profiles": [P]})
    );
    ffsrs_store_close(s);
}

/// 目录名来自对端写入的路径，不可信：缺、不是字符串、空、`.` / `..`、含分隔符、超长一律明确报错，不回空表（调用方
/// 据此区分坏路径与「没人绑这个目录」），也不碰库。
#[test]
fn profile_of_dir_refuses_untrusted_dir_names() {
    let dir = tempdir::new("g104baddir");
    let h = open(&dir.0, 0).unwrap();
    g4(h, "identity", T1, json!({}));
    let (rc, e) = call(h, &json!({"op": "profile_of_dir"}), None).unwrap_err();
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains("missing dir"), "{e}");
    for bad in [json!(5), json!(null), json!([P]), json!({"dir": P})] {
        let (rc, e) = of_dir(h, bad.clone()).unwrap_err();
        assert_eq!(rc, STORE_ERROR, "{bad}");
        assert!(e.contains("dir must be a string"), "{bad}: {e}");
    }
    let long = "a".repeat(super::identity::DIR_MAX + 1);
    for bad in [
        "",
        ".",
        "..",
        "a/b",
        "a\\b",
        "../0193a1b2-0000-7000-8000-00000000beef",
        long.as_str(),
    ] {
        let (rc, e) = of_dir(h, json!(bad)).unwrap_err();
        assert_eq!(rc, STORE_ERROR, "{bad:?}");
        assert!(e.contains("profile_of_dir: bad dir"), "{bad:?}: {e}");
    }
    // 上限本身可用。
    let edge = "a".repeat(super::identity::DIR_MAX);
    assert_eq!(of_dir(h, json!(edge)).unwrap(), json!({"profiles": []}));
    ffsrs_store_close(h);
}

// ---------------------------------------------------------------------- 媒体「在不在」随位置 / 根从头对账

const SHA_A: &str = "aa00000000000000000000000000000000000000000000000000000000000001";

/// 本机在 [loc] 的媒体目录上记一条「在」并标「列举过」（`media_record`）。
fn media_seen_at(h: *mut crate::store::ffi::SrsCoreHandle, loc: &str) {
    let v = g4(
        h,
        "media_record",
        T1,
        json!({"location": format!("{loc}/media#sha256"), "present": [SHA_A], "seeded": true}),
    );
    assert_eq!(v["appended"], json!(1), "{v}");
}

fn media_known_at(h: *mut crate::store::ffi::SrsCoreHandle, loc: &str) -> Value {
    g4(
        h,
        "media_known",
        T1,
        json!({"location": format!("{loc}/media#sha256")}),
    )
}

/// 移除位置（`location_forget`）也忘掉媒体在这个位置上的「在不在」与「列举过」：同一个位置身份再加回来时从头列举对账，
/// 不会把旧事实当成位置上还有、漏传媒体（`gen4/media.rs` 调用方契约）。别的位置的不动；本机清单代号预留不动。
#[test]
fn forgetting_a_location_forgets_what_media_it_held() {
    let m = migrated();
    media_seen_at(m.h, "folder:usb");
    media_seen_at(m.h, "folder:nas");
    {
        let c =
            rusqlite::Connection::open(m.dir.0.join(crate::store::gen4::files::GEN4_FILE)).unwrap();
        c.execute(
            "INSERT INTO media_gen (col, loc, device, gen) SELECT col, 'folder:usb', x'00', 7 FROM collections",
            [],
        )
        .unwrap();
    }
    let usb = media_known_at(m.h, "folder:usb");
    assert_eq!(usb["present"], json!([SHA_A]), "{usb}");
    assert_eq!(usb["seeded"], json!(true), "{usb}");
    let v = g4(
        m.h,
        "location_forget",
        T1,
        json!({"location": "folder:usb"}),
    );
    assert_eq!(
        v["forgotten"],
        json!(1),
        "the media_at row counts as forgotten state: {v}"
    );
    let usb = media_known_at(m.h, "folder:usb");
    assert_eq!(usb["present"], json!([]), "{usb}");
    assert_eq!(
        usb["seeded"],
        json!(false),
        "the location is listed again: {usb}"
    );
    let nas = media_known_at(m.h, "folder:nas");
    assert_eq!(
        nas["present"],
        json!([SHA_A]),
        "other locations stay: {nas}"
    );
    let gens: i64 = rusqlite::Connection::open(m.dir.0.join(crate::store::gen4::files::GEN4_FILE))
        .unwrap()
        .query_row(
            "SELECT COUNT(*) FROM media_gen WHERE loc = 'folder:usb'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(gens, 1, "manifest generations only go up");
}

/// 并入改绑（`collection_join`）换了集合的位置目录：`loc_key` 里没有目录，旧目录上的「在不在」不能套到新目录上，同一个
/// 事务里全部忘掉、从头列举（`gen4/media.rs` [forget_all](crate::store::gen4::media::forget_all)）。
#[test]
fn a_join_forgets_media_presence_of_the_old_directory() {
    let m = migrated();
    media_seen_at(m.h, "folder:usb");
    assert_eq!(media_known_at(m.h, "folder:usb")["present"], json!([SHA_A]));
    let v = g4(
        m.h,
        "collection_join",
        T1,
        json!({"into": id(0x0a).text(), "dir": "0000-home"}),
    );
    assert_eq!(v["outcome"], json!("joined"), "{v}");
    let usb = media_known_at(m.h, "folder:usb");
    assert_eq!(usb["present"], json!([]), "{usb}");
    assert_eq!(usb["seeded"], json!(false), "{usb}");
}

/// 并入改绑换了根：位置进度从头对账（设计 §5.1）。各位置上的 head 记录、转发记账、停放件、旧根指纹与段结论在同一个
/// 事务里去掉——留着的话，旧目录上已有的段会被当成新目录上也有（转发不补段、转发缓存被当「各位置都有了」删掉）。
/// 加密记忆（`loc_state`）与已传水位不动。
#[test]
fn a_join_restarts_location_progress_but_keeps_the_seal() {
    use crate::store::gen4::sync_state::LocHead;
    let mut m = migrated();
    let count = |c: &G4Core, table: &str| -> i64 {
        c.read(|t| {
            Ok(t.conn()
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .unwrap())
        })
        .unwrap()
    };
    let oldrun = |c: &G4Core| -> i64 {
        c.read(|t| {
            Ok(t.conn()
                .query_row(
                    "SELECT COUNT(*) FROM srs_meta WHERE key LIKE 'gen4_oldrun/%'",
                    [],
                    |r| r.get(0),
                )
                .unwrap())
        })
        .unwrap()
    };
    let tables = ["loc_heads", "relay_out", "relay_park", "oldroot_fp"];
    ffsrs_store_close(m.h);
    {
        let c = G4Core::open(&m.dir.0, OpenMode::Primary).unwrap();
        c.write(|t| {
            let col = t.binding_of(P)?.unwrap().col;
            for loc in ["folder:usb", "webdav:x"] {
                t.put_loc_head(
                    col,
                    loc,
                    &LocHead {
                        device: id(0x51),
                        gen: 3,
                        seq: 9,
                        segs: vec!["seg-1-9-aa.bin".into()],
                    },
                )?;
                let conn = t.conn();
                conn.execute(
                    "INSERT INTO relay_out (col, loc_key, device, name, gen) VALUES (?1, ?2, ?3, 'rly-1-9-aa.bin', 3)",
                    rusqlite::params![col, loc, &id(0x51).0[..]],
                )
                .unwrap();
                conn.execute(
                    "INSERT INTO relay_park (col, loc_key, device, name, last, wait, wait_seq, trust) \
                     VALUES (?1, ?2, ?3, 'rly-1-9-aa.bin', 9, ?3, 1, 0)",
                    rusqlite::params![col, loc, &id(0x51).0[..]],
                )
                .unwrap();
                conn.execute(
                    "INSERT INTO oldroot_fp (col, loc_key, fp, at) VALUES (?1, ?2, x'00', 1)",
                    rusqlite::params![col, loc],
                )
                .unwrap();
                conn.execute(
                    "INSERT INTO srs_meta (key, value) VALUES (?1, 'done')",
                    [format!("gen4_oldrun/{col}/{loc}\nseg.bin")],
                )
                .unwrap();
                conn.execute(
                    "INSERT INTO loc_state (col, loc_key, sealed, last_ok) VALUES (?1, ?2, 1, 5)",
                    rusqlite::params![col, loc],
                )
                .unwrap();
            }
            Ok(())
        })
        .unwrap();
        for table in tables {
            assert_eq!(count(&c, table), 2, "{table}");
        }
        assert_eq!(oldrun(&c), 2);
        c.close();
    }
    m.h = open(&m.dir.0, 0).unwrap();
    let v = g4(
        m.h,
        "collection_join",
        T1,
        json!({"into": id(0x0a).text(), "dir": "0000-home"}),
    );
    assert_eq!(v["outcome"], json!("joined"), "{v}");
    let sealed = g4(
        m.h,
        "location_sealed",
        T1,
        json!({"location": "folder:usb"}),
    );
    assert_eq!(sealed["sealed"], json!(true), "{sealed}");
    ffsrs_store_close(m.h);
    {
        let c = G4Core::open(&m.dir.0, OpenMode::Primary).unwrap();
        for table in tables {
            assert_eq!(count(&c, table), 0, "{table}");
        }
        assert_eq!(oldrun(&c), 0);
        assert_eq!(count(&c, "loc_state"), 2, "the seal memory stays");
        c.close();
    }
    m.h = open(&m.dir.0, 0).unwrap();
}
