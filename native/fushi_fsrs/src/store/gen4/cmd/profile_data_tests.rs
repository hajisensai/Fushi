//! G9-5（`cmd/profile_data.rs`、`discard.rs`、`identity.rs` 的「空集合可换绑」）经 C ABI 的测试：
//!
//! - 空集合可换绑：新设备打开 profile（`identity` 建了只有 `Salts` 的集合）之后关联已有集合，确认后结论 `bound`、不写
//!   `Join`、旧的空集合整个没了、派生层配置带过去、本机身份在对方集合里重建，内置实体的规范 ID 与对方一致（没有别的
//!   设备要确认的东西）；集合里多出任何一样（内容、别的设备的公钥、信任记录、发布过的 head、转发、已传水位）就照常
//!   `Join`（D25 / D27）。
//! - `profile_purge`：只删这个 profile 的集合，另一个 profile 的集合逐表行数、内容、历史不变；确认的集合对不上报错、
//!   什么都不删；没绑定的 profile 回全 0。
//! - `profile_uids` / `meta_set_edit` / `orphan_sweep_done` 与协议 3 对拍；`profile_merge_commit` 没有标记报错。
//! - `profile_merge_commit` 方向固定：`to` 目录名比 `from` 大、`to` 没绑定、`to` 是空集合三种情形下 `to` 的集合与目录名
//!   都不变，`from` 的数据并进 `to` 的集合（G9-5 第二轮复核）。
//!   半截并入经迁移再收尾的端到端在 `prepare_tests.rs`（`a_half_done_merge_is_migrated_and_finished_in_the_new_generation`）。
//! - 新语句的执行计划。

use std::collections::BTreeMap;
use std::path::Path;

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use crate::gen4::op::tests::id;
use crate::store::ffi::{STORE_ERROR, SrsCoreHandle, ffsrs_store_close};
use crate::store::gen4::cmd::dispatch_tests::{T1, call, g4, g4req, migrated, open, p3};
use crate::store::gen4::cmd::tests::N1;
use crate::store::gen4::discard::{Addr, tables};
use crate::store::gen4::files::GEN4_FILE;
use crate::store::gen4::schema::k_range;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{P, edit, tempdir};

const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";
const R: &str = "0193a1b2-0000-7000-8000-00000000d00d";
/// 只有 Q 写过的笔记（库里别的集合没有它）。
const Q_NOTE: &str = "0193a1b2-0000-7000-8000-00000000a0c1";

fn as_profile(h: *mut SrsCoreHandle, profile: &str, op: &str, extra: Value) -> Value {
    try_as(h, profile, op, extra).unwrap_or_else(|e| panic!("{op}: {e}"))
}

fn try_as(h: *mut SrsCoreHandle, profile: &str, op: &str, extra: Value) -> Result<Value, String> {
    let mut req = g4req(op, T1, extra);
    req["profile"] = json!(profile);
    call(h, &req, None)
        .map(|(v, _)| v)
        .map_err(|(rc, e)| format!("{rc} {e}"))
}

/// 另开一个读写连接到 [dir] 的新代库（测试直接造「集合里多出一样」的状态）。
fn side(dir: &Path) -> Connection {
    Connection::open(dir.join(GEN4_FILE)).unwrap()
}

fn ro(dir: &Path) -> Connection {
    Connection::open_with_flags(dir.join(GEN4_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap()
}

fn col_of(c: &Connection, profile: &str) -> i64 {
    c.query_row(
        "SELECT col FROM collections WHERE profile_uid = ?1",
        [profile],
        |r| r.get(0),
    )
    .unwrap()
}

/// 全新库里 [profile] 打开过（`identity`：只有本机身份写的 `Salts`）、交过缓存配置（派生层配置一行）。
fn fresh(tag: &str, profile: &str) -> (tempdir::Dir, *mut SrsCoreHandle) {
    let dir = tempdir::new(tag);
    let h = open(&dir.0, 0).unwrap();
    as_profile(h, profile, "identity", json!({}));
    let caches = json!({"defaultDeck": default_deck_id(profile)});
    as_profile(h, profile, "cache_config_set", json!({"caches": caches}));
    (dir, h)
}

/// [profile] 写一条笔记字段（`apply`），断言落库。
fn write_note(h: *mut SrsCoreHandle, profile: &str) {
    let mut e = edit("note", N1, "f/fa", json!("鯨"));
    e["x"]["p"] = json!(profile);
    let mut req = g4req("apply", T1, json!({}));
    req["profile"] = json!(profile);
    let (v, _) = call(h, &req, Some(&[json!({"e": e, "note": N1})])).unwrap();
    assert_eq!(v["landed"], json!([true]), "{v}");
}

// ---------------------------------------------------------------------- 空集合可换绑

/// 新设备：打开 profile 之后关联另一台设备上已有的集合。先问（`needsConfirm`、什么都不改）；确认后 `bound`，不写
/// `Join`、本机原来的空集合整个没了（库里只剩一个集合），派生层配置带过去，本机身份在对方集合里重建（日志第一条是
/// `Salts`、盐是本机 profile 的 uid）；之后照常写得进。
#[test]
fn a_new_device_binds_to_an_existing_collection_without_a_join() {
    let other = migrated();
    let theirs = g4(other.h, "identity", T1, json!({}));
    let their_info = g4(other.h, "collection_info", T1, json!({}));
    // 新设备上的 profile 有它自己的 uid（集合标识随 uid 派生，与对方不同）。
    let (dir, h) = fresh("g95-bind", Q);
    let mine = as_profile(h, Q, "identity", json!({}));
    assert_ne!(mine["collection"], theirs["collection"]);
    let ask = json!({
        "collection": theirs["collection"], "dir": theirs["dir"], "salts": their_info["salts"],
    });
    let v = as_profile(h, Q, "collection_adopt", ask.clone());
    assert_eq!(v, json!({"outcome": "needsConfirm"}));
    assert_eq!(
        as_profile(h, Q, "identity", json!({}))["collection"],
        mine["collection"]
    );

    let mut yes = ask;
    yes["confirmed"] = json!(true);
    let v = as_profile(h, Q, "collection_adopt", yes);
    assert_eq!(v["outcome"], json!("bound"), "{v}");
    assert_eq!(v["bindingChanged"], json!({"profile": Q}));
    let now = as_profile(h, Q, "identity", json!({}));
    assert_eq!(now["collection"], theirs["collection"]);
    assert_eq!(now["dir"], theirs["dir"]);
    assert_eq!(now["nextSeq"], json!(2), "本机身份在对方集合里重建：{now}");
    assert_ne!(now["device"], mine["device"]);
    let info = as_profile(h, Q, "collection_info", json!({}));
    assert_eq!(info["joins"], json!([]), "没有 Join：{info}");
    assert_eq!(info["salts"], json!([Q]), "{info}");
    let c = ro(&dir.0);
    let n: i64 = c
        .query_row("SELECT COUNT(*) FROM collections", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, 1, "旧的空集合丢掉了");
    let col = col_of(&c, Q);
    let cfg_rows: i64 = c
        .query_row(
            "SELECT COUNT(*) FROM derive_cfg WHERE col = ?1",
            [col],
            |r| r.get(0),
        )
        .unwrap();
    assert!(cfg_rows >= 1, "派生层配置带过去了");
    let trust: i64 = c
        .query_row("SELECT COUNT(*) FROM trust", [], |r| r.get(0))
        .unwrap();
    assert_eq!(trust, 0, "没有要别的设备确认的记录");
    drop(c);
    // 换绑之后照常写得进。
    write_note(h, Q);
    ffsrs_store_close(h);
}

/// app 里的新设备（第五波 G9 身份收尾，规划 §6「新设备关联已有集合，结论 bound、不产生 Join」）：Dart 开库就写内置
/// 种子（`SrsDbStore.ensureBuiltins`：`data` 带 `builtin` 的实体创建），之后又打过一个还原点。这些都不是用户内容（与首次
/// 信任同一个判据 `library_fresh`），关联已有集合照样 `bound`、不写 `Join`、旧集合整个丢掉。以前「空集合」只认 `Salts`，
/// 开过 store 的 profile 一律 `joined`。
#[test]
fn a_profile_with_only_builtin_seeds_binds_without_a_join() {
    let other = migrated();
    let theirs = g4(other.h, "identity", T1, json!({}));
    let (dir, h) = fresh("g95-bind-seeds", Q);
    let mut seed = json!({"t": "entity", "x": {"id": default_deck_id(Q), "p": Q, "k": "deck", "d": {"createdAt": 1, "builtin": "default"}}});
    let mut req = g4req("apply", T1, json!({}));
    req["profile"] = json!(Q);
    let (v, _) = call(h, &req, Some(&[json!({"e": seed.take()})])).unwrap();
    assert_eq!(v["landed"], json!([true]), "{v}");
    let v = as_profile(h, Q, "checkpoint", json!({"name": "c", "reason": "manual"}));
    assert!(v.get("error").is_none(), "{v}");
    let v = as_profile(
        h,
        Q,
        "collection_adopt",
        json!({"collection": theirs["collection"], "dir": theirs["dir"], "confirmed": true}),
    );
    assert_eq!(v["outcome"], json!("bound"), "{v}");
    let info = as_profile(h, Q, "collection_info", json!({}));
    assert_eq!(info["joins"], json!([]), "没有 Join：{info}");
    let n: i64 = ro(&dir.0)
        .query_row("SELECT COUNT(*) FROM collections", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, 1, "旧集合（只有内置种子）丢掉了");
    ffsrs_store_close(h);
}

/// 本机集合里多出任何一样（规划 §6 的三个条件逐项翻转）就不是空集合：确认后照常 `Join`（D27：本机目录名更大，本机并入
/// 对方），本机的集合不丢。
#[test]
fn a_collection_with_anything_beyond_its_own_salts_still_joins() {
    let foreign = id(0x0a).text();
    let flips: [(&str, &dyn Fn(&Path, *mut SrsCoreHandle)); 7] = [
        ("content", &|_, h| write_note(h, P)),
        ("peer", &|d, _| {
            let c = side(d);
            let col = col_of(&c, P);
            c.execute(
                "INSERT INTO peers (col, device, public) VALUES (?1, randomblob(16), randomblob(32))",
                [col],
            )
            .unwrap();
        }),
        ("trust", &|d, _| {
            let c = side(d);
            let col = col_of(&c, P);
            c.execute(
                "INSERT INTO trust (col, device, state, since) VALUES (?1, randomblob(16), 1, 0)",
                [col],
            )
            .unwrap();
        }),
        ("head", &|d, _| {
            let c = side(d);
            let col = col_of(&c, P);
            c.execute(
                "INSERT INTO loc_heads (col, loc_key, device, gen, seq, segs) \
                 SELECT col, 'loc', device, 1, 1, '[]' FROM self_ WHERE col = ?1",
                [col],
            )
            .unwrap();
        }),
        ("relay", &|d, _| {
            let c = side(d);
            let col = col_of(&c, P);
            c.execute(
                "INSERT INTO relay_out (col, loc_key, device, name, gen) \
                 SELECT col, 'loc', device, 'seg', 1 FROM self_ WHERE col = ?1",
                [col],
            )
            .unwrap();
        }),
        ("acked", &|d, _| {
            let c = side(d);
            let col = col_of(&c, P);
            c.execute(
                "INSERT INTO srs_meta (key, value) VALUES (?1, '1')",
                [format!("gen4_out/{col}/loc")],
            )
            .unwrap();
        }),
        // 立过位置的根（`location_root` 记下 loc 标记）：位置上已有它的 `meta.json`，丢掉会留孤儿（G9-5 第二轮复核）。
        ("rooted", &|d, _| {
            let c = side(d);
            let col = col_of(&c, P);
            c.execute(
                "INSERT INTO loc_state (col, loc_key, loc_ids, sealed) VALUES (?1, 'loc', '[]', 0)",
                [col],
            )
            .unwrap();
        }),
    ];
    for (tag, flip) in flips {
        let (dir, h) = fresh(&format!("g95-flip-{tag}"), P);
        let before = g4(h, "identity", T1, json!({}));
        flip(&dir.0, h);
        let v = g4(
            h,
            "collection_adopt",
            T1,
            json!({"collection": foreign, "dir": "0000-home", "confirmed": true}),
        );
        assert_eq!(v["outcome"], json!("joined"), "{tag}: {v}");
        let info = g4(h, "collection_info", T1, json!({}));
        assert_eq!(
            info["joins"].as_array().map(Vec::len),
            Some(1),
            "{tag}: {info}"
        );
        assert_eq!(
            g4(h, "identity", T1, json!({}))["device"],
            before["device"],
            "{tag}: 本机身份不动"
        );
        ffsrs_store_close(h);
    }
}

// ---------------------------------------------------------------------- profile_purge

/// 集合 [col] 在每张按集合分的表里的行数（表清单与 `discard.rs` 同一份）。
fn rows_of(c: &Connection, col: i64) -> BTreeMap<String, i64> {
    let t = crate::store::gen4::truth::Truth::new(c);
    let devs: Vec<i64> = c
        .prepare("SELECT dev FROM devs WHERE col = ?1")
        .unwrap()
        .query_map([col], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut out = BTreeMap::new();
    for (table, addr) in tables(&t).unwrap() {
        let n: i64 = match addr {
            Addr::Col => c
                .query_row(
                    &format!("SELECT COUNT(*) FROM \"{table}\" WHERE col = ?1"),
                    [col],
                    |r| r.get(0),
                )
                .unwrap(),
            Addr::Key => devs
                .iter()
                .map(|&d| {
                    let (lo, hi) = k_range(d);
                    c.query_row(
                        &format!("SELECT COUNT(*) FROM \"{table}\" WHERE k BETWEEN ?1 AND ?2"),
                        [lo, hi],
                        |r| r.get::<_, i64>(0),
                    )
                    .unwrap()
                })
                .sum(),
            Addr::Dev => devs
                .iter()
                .map(|&d| {
                    c.query_row(
                        &format!("SELECT COUNT(*) FROM \"{table}\" WHERE dev = ?1"),
                        [d],
                        |r| r.get::<_, i64>(0),
                    )
                    .unwrap()
                })
                .sum(),
        };
        out.insert(table, n);
    }
    out
}

/// 删一个 profile：确认的集合对不上 = 报错、什么都不删；对上了只删它的集合与本机状态行，另一个 profile 的集合逐表行数、
/// 内容、修改历史不变；删完 profile 再打开是一个全新的集合；没绑定的 profile 回全 0。
#[test]
fn purge_deletes_only_the_confirmed_collection() {
    let m = migrated();
    let h = m.h;
    as_profile(h, Q, "identity", json!({}));
    let qcfg = json!({"defaultDeck": default_deck_id(Q)});
    as_profile(h, Q, "cache_config_set", json!({"caches": qcfg}));
    // Q 写它自己的笔记（N1 是 P 的：同库别的集合的实体 Q 写不进去，实体归属闸 `writes_owner.rs`）。
    write_note_id(h, Q, Q_NOTE);
    let q_foot = as_profile(h, Q, "profile_footprint", json!({}));
    let q_hist = as_profile(h, Q, "history", json!({"kind": "note", "entity": Q_NOTE}));
    let q_info = as_profile(h, Q, "collection_info", json!({}));
    let q_id = as_profile(h, Q, "identity", json!({}));
    let (q_col, q_rows) = {
        let c = ro(&m.dir.0);
        let col = col_of(&c, Q);
        (col, rows_of(&c, col))
    };
    assert!(q_rows["ops"] >= 2, "{q_rows:?}");
    let p_id = g4(h, "identity", T1, json!({}));
    let p_foot = g4(h, "profile_footprint", T1, json!({}));

    // 确认的是 Q 的集合：对不上，什么都不删。
    let e = try_as(
        h,
        P,
        "profile_purge",
        json!({"collection": q_id["collection"]}),
    )
    .unwrap_err();
    assert!(
        e.contains(&STORE_ERROR.to_string()) && e.contains("nothing was deleted"),
        "{e}"
    );
    assert_eq!(g4(h, "profile_footprint", T1, json!({})), p_foot);

    let v = g4(
        h,
        "profile_purge",
        T1,
        json!({"collection": p_id["collection"]}),
    );
    for k in ["notes", "cards", "reviews"] {
        assert_eq!(v[k], p_foot[k], "{k}: {v}");
    }
    assert!(v["deleted"].as_i64().unwrap() > 0, "{v}");
    assert!(v["tables"]["ops"].as_i64().unwrap() > 0, "{v}");
    assert_eq!(v["tables"]["collections"], json!(1), "{v}");
    let e = try_as(h, P, "binding_get", json!({})).unwrap_err();
    assert!(e.contains("has no collection"), "{e}");
    // 删掉之后数数 = 全 0（不报「没有集合」：删 profile 的核对与存量扫描都要对它数数）；从没绑定过的 R 同样。
    let zero = json!({"notes": 0, "cards": 0, "reviews": 0, "rows": 0});
    assert_eq!(g4(h, "profile_footprint", T1, json!({})), zero);
    assert_eq!(as_profile(h, R, "profile_footprint", json!({})), zero);
    assert_eq!(
        g4(h, "profile_uids", T1, json!({}))["uids"],
        json!([Q]),
        "只剩 Q"
    );
    // Q 一行没少。
    {
        let c = ro(&m.dir.0);
        assert_eq!(col_of(&c, Q), q_col);
        assert_eq!(rows_of(&c, q_col), q_rows);
    }
    assert_eq!(as_profile(h, Q, "profile_footprint", json!({})), q_foot);
    assert_eq!(
        as_profile(h, Q, "history", json!({"kind": "note", "entity": Q_NOTE})),
        q_hist
    );
    assert_eq!(as_profile(h, Q, "collection_info", json!({})), q_info);

    // 删完再打开：一个全新的集合（日志第一条是 Salts）。
    let again = g4(h, "identity", T1 + 1, json!({}));
    assert_eq!(again["nextSeq"], json!(2), "{again}");
    assert_eq!(
        g4(h, "profile_footprint", T1, json!({}))["reviews"],
        json!(0)
    );

    // 没绑定的 profile：全 0。
    let v = as_profile(h, R, "profile_purge", json!({}));
    assert_eq!(
        v,
        json!({"notes": 0, "cards": 0, "reviews": 0, "rows": 0, "deleted": 0, "tables": {}})
    );
    // 坏的确认。
    let e = try_as(h, Q, "profile_purge", json!({"collection": "nope"})).unwrap_err();
    assert!(e.contains("bad collection"), "{e}");
}

// ---------------------------------------------------------------------- 库级命令对拍

/// `profile_uids` / `meta_set_edit` 与协议 3 逐步对拍；`orphan_sweep_done` 回包形状同协议 3、只清没有绑定的本机状态行、
/// `keep` 里的不动、`mark` 记完成时刻；`profile_merge_mark` 报已删除；`profile_merge_commit` 没有标记报错。
#[test]
fn library_commands_match_protocol_3() {
    let m = migrated();
    let (pv, _) = p3(&m.d, "profile_uids", T1, json!({}), None);
    let gv = g4(m.h, "profile_uids", T1, json!({}));
    assert_eq!(gv["uids"], pv["uids"], "{pv} {gv}");
    assert_eq!(gv["orphanSweptAt"], Value::Null);

    for set in ["retiredDevices", "retiredUids"] {
        for step in [
            json!({}),
            json!({"add": "a"}),
            json!({"add": "b"}),
            json!({"add": "a"}),
            json!({"remove": "a"}),
            json!({"remove": "zz"}),
            json!({"add": "c", "remove": "b"}),
            json!({}),
        ] {
            let mut extra = step.clone();
            extra["set"] = json!(set);
            let (pv, _) = p3(&m.d, "meta_set_edit", T1, extra.clone(), None);
            let gv = g4(m.h, "meta_set_edit", T1, extra);
            assert_eq!(gv, pv, "{set} {step}");
        }
    }
    let (_, e) = call(
        m.h,
        &g4req("meta_set_edit", T1, json!({"set": "nope"})),
        None,
    )
    .unwrap_err();
    assert!(e.contains("unknown set"), "{e}");

    // 没有绑定、只剩本机状态行的 uid：不在 keep 里的清掉。
    {
        let c = side(&m.dir.0);
        for u in ["gone-1", "kept-1"] {
            c.execute(
                "INSERT INTO srs_meta (key, value) VALUES (?1, '{}')",
                [format!("local_state/{u}")],
            )
            .unwrap();
        }
    }
    let req = json!({"keep": ["kept-1"], "mark": true});
    let (pv, _) = p3(&m.d, "orphan_sweep_done", T1, req.clone(), None);
    let gv = g4(m.h, "orphan_sweep_done", T1, req);
    let keys = |v: &Value| -> Vec<String> {
        let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
        k.sort();
        k
    };
    assert_eq!(keys(&gv), keys(&pv), "{pv} {gv}");
    assert_eq!(gv["metaUids"], json!(["gone-1"]), "{gv}");
    assert_eq!(gv["meta"], json!(1));
    assert_eq!(
        g4(m.h, "profile_uids", T1, json!({}))["orphanSweptAt"],
        json!(T1)
    );
    {
        let c = ro(&m.dir.0);
        let left: Vec<String> = c
            .prepare(crate::store::gen4::cmd::profile_data::LOCAL_STATE_UIDS_SQL)
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(left.contains(&"local_state/kept-1".to_owned()), "{left:?}");
        assert!(!left.contains(&"local_state/gone-1".to_owned()), "{left:?}");
    }

    let e = try_as(m.h, P, "profile_merge_commit", json!({"from": Q, "to": P})).unwrap_err();
    assert!(e.contains("no half-done merge"), "{e}");
    let e = try_as(m.h, P, "profile_merge_mark", json!({"from": Q, "to": P})).unwrap_err();
    assert!(e.contains("collection_adopt"), "{e}");
}

// ---------------------------------------------------------------------- 半截并入的收尾：方向固定

/// [profile] 写一条笔记 [note]（`apply`），断言落库。
fn write_note_id(h: *mut SrsCoreHandle, profile: &str, note: &str) {
    let mut e = edit("note", note, "f/fa", json!("鯨"));
    e["x"]["p"] = json!(profile);
    let mut req = g4req("apply", T1, json!({}));
    req["profile"] = json!(profile);
    let (v, _) = call(h, &req, Some(&[json!({"e": e, "note": note})])).unwrap();
    assert_eq!(v["landed"], json!([true]), "{v}");
}

/// [profile] 的集合里笔记 [note] 的修改历史条数。
fn history_of(h: *mut SrsCoreHandle, profile: &str, note: &str) -> usize {
    as_profile(
        h,
        profile,
        "history",
        json!({"kind": "note", "entity": note}),
    )
    .as_array()
    .map_or(0, Vec::len)
}

/// 半截并入的收尾（`profile_merge_commit`）方向固定（G9-5 第二轮复核）：`from` 的数据进 `to` 的集合，`to` 的集合标识与
/// 目录名绝不改变。三种以前会把 `to` 改绑到 `from` 的集合的情形——`to` 的目录名比 `from` 大（D27 会让 `to` 并入
/// `from`）、`to` 在本机没绑定（以前直接绑到 `from` 的集合）、`to` 是空集合（以前空集合换绑到 `from` 的集合）——
/// 收尾之后 `to` 都在它自己的集合（没绑定的按打开 profile 的口径建：`collection_of(to)`、目录名 `to`），日志里一条
/// from = `from` 的集合的 `Join`，`from` 的修改在 `to` 里查得到、`to` 自己的还在，库里只剩一个集合。
fn finishing_a_half_done_merge_never_rebinds_the_target(case: &str) {
    const FROM_NOTE: &str = "0193a1b2-0000-7000-8000-00000000a001";
    const TO_NOTE: &str = "0193a1b2-0000-7000-8000-00000000a002";
    // P（…beef）< Q（…cafe）：`to` = Q 的目录名比 `from` = P 大。
    assert!(Q > P);
    {
        let dir = tempdir::new(&format!("g95-commit-{case}"));
        let h = open(&dir.0, 0).unwrap();
        let from_id = as_profile(h, P, "identity", json!({}));
        write_note_id(h, P, FROM_NOTE);
        match case {
            "larger" => {
                as_profile(h, Q, "identity", json!({}));
                write_note_id(h, Q, TO_NOTE);
            }
            "empty" => {
                as_profile(h, Q, "identity", json!({}));
            }
            _ => {}
        }
        let want = match case {
            "unbound" => (
                json!(crate::store::sync2::collection_of(Q).text()),
                json!(Q),
            ),
            _ => {
                let v = as_profile(h, Q, "identity", json!({}));
                (v["collection"].clone(), v["dir"].clone())
            }
        };
        assert_eq!(history_of(h, P, FROM_NOTE), 1, "{case}");
        side(&dir.0)
            .execute(
                "INSERT INTO srs_meta (key, value) VALUES (?1, ?2)",
                [
                    format!("profile_merge/{P}"),
                    json!({"profileId": 7, "newUid": Q}).to_string(),
                ],
            )
            .unwrap();
        let v = as_profile(h, Q, "profile_merge_commit", json!({"from": P, "to": Q}));
        assert_eq!(v["folded"], json!(true), "{case}: {v}");
        assert_eq!(v["outcome"], json!("joined"), "{case}: {v}");
        let now = as_profile(h, Q, "identity", json!({}));
        assert_eq!(
            (now["collection"].clone(), now["dir"].clone()),
            want,
            "{case}: to 的集合与目录名不变"
        );
        let info = as_profile(h, Q, "collection_info", json!({}));
        let joins = info["joins"].as_array().unwrap();
        assert_eq!(joins.len(), 1, "{case}: {info}");
        assert_eq!(joins[0]["from"], from_id["collection"], "{case}: {info}");
        assert_eq!(
            history_of(h, Q, FROM_NOTE),
            1,
            "{case}: from 的修改并进了 to"
        );
        if case == "larger" {
            assert_eq!(history_of(h, Q, TO_NOTE), 1, "{case}: to 自己的修改还在");
        }
        assert_eq!(
            as_profile(h, Q, "profile_uids", json!({}))["uids"],
            json!([Q]),
            "{case}"
        );
        let n: i64 = ro(&dir.0)
            .query_row("SELECT COUNT(*) FROM collections", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1, "{case}");
        ffsrs_store_close(h);
    }
}

/// [finishing_a_half_done_merge_never_rebinds_the_target]：`to` 有实质数据、目录名比 `from` 大（D27 会让 `to` 并入 `from`）。
#[test]
fn finishing_a_half_done_merge_keeps_a_larger_target() {
    finishing_a_half_done_merge_never_rebinds_the_target("larger");
}

/// [finishing_a_half_done_merge_never_rebinds_the_target]：`to` 在本机没绑定（以前直接绑到 `from` 的集合）。
#[test]
fn finishing_a_half_done_merge_binds_an_unbound_target_to_its_own_collection() {
    finishing_a_half_done_merge_never_rebinds_the_target("unbound");
}

/// [finishing_a_half_done_merge_never_rebinds_the_target]：`to` 是空集合（以前空集合换绑到 `from` 的集合）。
#[test]
fn finishing_a_half_done_merge_keeps_an_empty_target() {
    finishing_a_half_done_merge_never_rebinds_the_target("empty");
}

// ---------------------------------------------------------------------- 执行计划

fn plan(c: &Connection, q: &str) -> Vec<String> {
    let mut stmt = c.prepare(&format!("EXPLAIN QUERY PLAN {q}")).unwrap();
    let mut rows = stmt.raw_query();
    let mut out = Vec::new();
    while let Some(r) = rows.next().unwrap() {
        out.push(r.get::<_, String>(3).unwrap());
    }
    out
}

/// 新语句走主键 / 索引：`srs_meta` 的两段键区间与派生层配置是 `SEARCH`；`profile_uids` 按 `profile_uid` 的唯一索引
/// 顺序读（不排序），读的就是全部绑定（行数 = 绑定数）。
#[test]
fn new_statements_use_their_keys() {
    let m = migrated();
    let c = ro(&m.dir.0);
    for q in [
        crate::store::gen4::cmd::profile_data::LOCAL_STATE_UIDS_SQL,
        crate::store::gen4::cmd::profile_data::MERGE_MARKS_SQL,
        crate::store::gen4::identity::DERIVE_CFG_OF_SQL,
    ] {
        let p = plan(&c, q);
        assert!(p.iter().all(|l| l.starts_with("SEARCH")), "{q}: {p:?}");
    }
    let q = crate::store::gen4::cmd::profile_data::PROFILE_UIDS_SQL;
    let p = plan(&c, q);
    assert!(p.iter().all(|l| !l.contains("TEMP B-TREE")), "{q}: {p:?}");
}

/// 空集合里本机经 `collection_salts_add` 确认过的旧 uid（只有本机写的 `Salts`，仍是空集合）换绑时不丢：本机身份在对方
/// 集合里重建之后另写一条 `Salts` 把它带过去（复核 nit：以前只重写 `Salts{profile}`）。
#[test]
fn rebinding_an_empty_collection_carries_the_salts_it_declared() {
    let other = migrated();
    let theirs = g4(other.h, "identity", T1, json!({}));
    let their_info = g4(other.h, "collection_info", T1, json!({}));
    let (_dir, h) = fresh("g95-carry", Q);
    let v = as_profile(h, Q, "collection_salts_add", json!({"salts": [R]}));
    assert_eq!(v["outcome"], json!("saltsAdded"), "{v}");
    let v = as_profile(
        h,
        Q,
        "collection_adopt",
        json!({
            "collection": theirs["collection"], "dir": theirs["dir"], "salts": their_info["salts"],
            "confirmed": true,
        }),
    );
    assert_eq!(v["outcome"], json!("bound"), "仍是空集合：{v}");
    let info = as_profile(h, Q, "collection_info", json!({}));
    let mut want = vec![Q, R];
    want.sort();
    assert_eq!(info["salts"], json!(want), "{info}");
    assert_eq!(info["joins"], json!([]), "{info}");
    assert_eq!(
        as_profile(h, Q, "identity", json!({}))["nextSeq"],
        json!(3),
        "本机身份的 Salts{{profile}} 之后补一条 Salts{{旧 uid}}"
    );
    ffsrs_store_close(h);
}
