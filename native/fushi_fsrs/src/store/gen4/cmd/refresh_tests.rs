//! S1c：进程内刷新键（`refresh.rs`）与写回包的输入下标 / 标签项 / 日志 HLC（`writes.rs` 文件头「回包」），全部经 C ABI。
//!
//! - 刷新键与协议 3 对拍：迁移前的协议 3 库与迁移出来的新代库上发同一串写入，每一步之后五个键里「哪几个变了」两侧相同
//!   （协议 3 的键由它的分发器 `sync2_dispatch` 的统一出口 `refresh_after` 推进）。作答只动 `landed` / `stats`。
//! - Secondary：五个键同值，随主进程的写入（含整层重建）变，没有写入时不变。
//! - 回包：带盐（别名类非规范）成员上的修改与整列表标签，输入下标仍对得上调用方的输入；日志 HLC 与 `read logs` 的行相同。

use serde_json::{Value, json};

use super::dispatch_tests::{T1, call, g4, g4req, migrated, open, p3};
use super::tests::{N2, N3, N4, card};
use super::tests_class;
use crate::gen4::op::tests::id;
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close};
use crate::store::gen4::files::OpenMode;
use crate::store::gen4::kernel::G4Core;
use crate::store::sync2::tests::{P, review, tempdir};

const KEYS: [&str; 5] = ["content", "structure", "rwkv", "stats", "landed"];

/// [before] 到 [after] 变了的键（按 [KEYS] 的顺序）。
fn moved(before: &Value, after: &Value) -> Vec<&'static str> {
    KEYS.iter()
        .copied()
        .filter(|k| before[*k] != after[*k])
        .collect()
}

fn g4_keys(h: *mut SrsCoreHandle) -> Value {
    g4(h, "refresh_keys", T1, json!({}))
}

fn draft(kind: &str, entity: &str, key: &str, v: Value) -> Value {
    json!({
        "e": {"t": "edit", "x": {"p": P, "k": kind, "e": entity, "f": key, "v": v, "ts": "anchored"}},
        "note": null, "clk": "t",
    })
}

const LANG: &str = "0193a1b2-0000-7000-8000-0000000000d7";

/// 同一串写入两侧各发一遍，每步之后「哪几个键变了」两侧相同；并钉住几个关键步的结果（作答不动 `rwkv` / `content` /
/// `structure`，界面状态只动 `structure` / `landed`，牌组内容动 `rwkv`）。
#[test]
fn refresh_keys_move_like_protocol_3_through_the_dispatcher() {
    let m = migrated();
    let p3_keys = || p3(&m.d, "refresh_keys", T1, json!({}), None).0;
    // 一步：两侧各发 [op]，回两侧变了的键（必须相同）。
    let step = |at: &str,
                op: &str,
                now: i64,
                extra: Value,
                items: Option<&[Value]>|
     -> Vec<&'static str> {
        let (pb, gb) = (p3_keys(), g4_keys(m.h));
        p3(&m.d, op, now, extra.clone(), items);
        let req = g4req(op, now, extra);
        call(m.h, &req, items).unwrap_or_else(|(rc, e)| panic!("{at}: {rc} {e}"));
        let (pm, gm) = (moved(&pb, &p3_keys()), moved(&gb, &g4_keys(m.h)));
        assert_eq!(pm, gm, "{at}: protocol 3 moved {pm:?}, gen4 moved {gm:?}");
        gm
    };
    let c = card(N2, "t1");
    let answer =
        vec![json!({"e": review("s1c-r1", &c, T1, 3, "review"), "note": N2, "intent": "answer"})];
    assert_eq!(
        step("answer", "apply", T1, json!({}), Some(&answer)),
        vec!["stats", "landed"],
        "an answer must not requery the RWKV score table or rebuild the deck tree"
    );
    let field = vec![draft("note", N3, "f/fa", json!("s1c 狼"))];
    assert_eq!(
        step("note field", "apply", T1 + 1, json!({}), Some(&field)),
        vec!["content", "structure", "stats", "landed"]
    );
    let deck = vec![
        json!({"e": {"t": "entity", "x": {"id": LANG, "p": P, "k": "deck", "d": {"createdAt": 1}}}, "note": null}),
        draft("deck", LANG, "name", json!("Lang")),
    ];
    assert_eq!(
        step("new deck", "apply", T1 + 2, json!({}), Some(&deck)),
        KEYS.to_vec()
    );
    let collapse = vec![draft("deck", LANG, "collapsed", json!(true))];
    assert_eq!(
        step("collapse", "apply", T1 + 3, json!({}), Some(&collapse)),
        vec!["structure", "landed"]
    );
    let rename = vec![draft("deck", LANG, "name", json!("Lang 2"))];
    assert_eq!(
        step("rename", "apply", T1 + 4, json!({}), Some(&rename)),
        KEYS.to_vec()
    );
    let tags = vec![draft("note", N3, "tags", json!(["s1c", "b"]))];
    step("tags", "apply", T1 + 5, json!({}), Some(&tags));
    // 值没变的修改（`chg`）：什么都没写，两侧都不动。
    let mut same = draft("note", N3, "f/fa", json!("s1c 狼"));
    same["chg"] = json!(true);
    assert_eq!(
        step("no-op", "apply", T1 + 6, json!({}), Some(&[same])),
        Vec::<&str>::new()
    );
    step(
        "checkpoint",
        "checkpoint",
        T1 + 7,
        json!({"name": "s1c", "reason": "manual"}),
        None,
    );
    step(
        "purge",
        "purge",
        T1 + 8,
        json!({"kind": "note", "entities": [N4]}),
        None,
    );
    // 别的设备的事件（`apply {remote}`）：落了就让 RWKV 分数表整表重查。
    let remote = vec![draft("note", N3, "f/fb", json!("remote"))];
    assert!(
        step(
            "remote",
            "apply",
            T1 + 9,
            json!({"remote": true}),
            Some(&remote)
        )
        .contains(&"rwkv")
    );
    // 命令失败后的重读：按这些键记的缓存全部作废。
    assert_eq!(
        step("reload", "local_state", T1, json!({"reload": true}), None),
        KEYS.to_vec()
    );
    // 前置条件不成立（`stale`）：什么都没写，两侧都不动。
    let late = vec![
        json!({"e": review("s1c-r2", &c, T1 + 10, 3, "review"), "note": N2, "intent": "answer"}),
    ];
    assert_eq!(
        step(
            "stale",
            "apply",
            T1 + 10,
            json!({"expectLast": {"card": c, "log": "no-such-log"}}),
            Some(&late)
        ),
        Vec::<&str>::new()
    );
    // 新代一条命令一个事务：失败整笔回滚，键不动（协议 3 按「可能提交了一部分」作废一次，新代没有那种分块提交）。
    let before = g4_keys(m.h);
    let bad = vec![json!({"e": {"t": "bogus"}, "note": null})];
    assert!(call(m.h, &g4req("apply", T1 + 11, json!({})), Some(&bad)).is_err());
    assert_eq!(g4_keys(m.h), before);
}

/// 整层重建与改别名 / 绑定的写不经 `Session`：整份作废；只写本机状态行的不动。
#[test]
fn rebuilds_invalidate_and_local_only_writes_do_not() {
    let m = migrated();
    let k0 = g4_keys(m.h);
    g4(
        m.h,
        "local_anchor",
        T1,
        json!({"anchor": {"s": 7, "t": 1, "e": 6}}),
    );
    g4(m.h, "local_state_ensure", T1, json!({}));
    g4(
        m.h,
        "device_info",
        T1,
        json!({"model": "Pixel", "app": "3.4"}),
    );
    assert_eq!(g4_keys(m.h), k0);
    g4(m.h, "rebuild_caches", T1, json!({}));
    let k1 = g4_keys(m.h);
    assert_eq!(moved(&k0, &k1), KEYS.to_vec());
    // 配置没变：不重建、不动。
    let cfg = super::dispatch_tests::cfg();
    let v = g4(m.h, "cache_config_set", T1, json!({"caches": cfg}));
    assert_eq!(v["changed"], json!(false), "{v}");
    assert_eq!(g4_keys(m.h), k1);
}

/// 键形：Primary 只读内存，同一次打开里没有写入就稳定；另一次打开（这里是同目录的 Secondary）的键与它不撞。
#[test]
fn keys_are_stable_within_an_open_and_differ_across_opens() {
    let m = migrated();
    let a = g4_keys(m.h);
    assert_eq!(g4_keys(m.h), a);
    let h2 = open(&m.dir.0, 1).unwrap();
    let s = g4_keys(h2);
    ffsrs_store_close(h2);
    for k in KEYS {
        assert!(a[k].is_string(), "{a}");
        assert_ne!(a[k], s[k], "{k}");
    }
}

/// Secondary：五个键同值（分不清别的进程写的是哪一类），随主进程的作答、界面状态修改、整层重建变，没有写入时不变。
#[test]
fn a_secondary_sees_every_primary_write_as_one_key() {
    let m = migrated();
    let s = open(&m.dir.0, 1).unwrap();
    let same5 = |v: &Value| {
        for k in KEYS {
            assert_eq!(v[k], v["landed"], "{v}");
        }
        v["landed"].as_str().unwrap().to_owned()
    };
    // 迁移不带协议 3 的本机状态行：纪元没落盘时是稳定的 `unstored`。
    let k0 = same5(&g4_keys(s));
    assert!(k0.contains(":s:unstored:0:"), "{k0}");
    assert_eq!(same5(&g4_keys(s)), k0);
    g4(m.h, "local_state_ensure", T1, json!({}));
    let k1 = same5(&g4_keys(s));
    assert_ne!(k1, k0);
    let c = card(N2, "t1");
    let answer =
        vec![json!({"e": review("s1c-sec", &c, T1, 3, "review"), "note": N2, "intent": "answer"})];
    call(m.h, &g4req("apply", T1, json!({})), Some(&answer)).unwrap();
    let k2 = same5(&g4_keys(s));
    assert_ne!(k2, k1);
    // 界面状态类修改不碰笔记 / 卡缓存行（缓存层代号不动），修订号照样推进：键变。
    let deck = vec![
        json!({"e": {"t": "entity", "x": {"id": LANG, "p": P, "k": "deck", "d": {"createdAt": 1}}}, "note": null}),
        draft("deck", LANG, "name", json!("Lang")),
    ];
    call(m.h, &g4req("apply", T1 + 1, json!({})), Some(&deck)).unwrap();
    let k3 = same5(&g4_keys(s));
    let collapse = vec![draft("deck", LANG, "collapsed", json!(true))];
    call(m.h, &g4req("apply", T1 + 2, json!({})), Some(&collapse)).unwrap();
    let k4 = same5(&g4_keys(s));
    assert_ne!(k4, k3);
    // 整层重建不推进修订号，缓存层代号推进：键变。
    g4(m.h, "rebuild_caches", T1, json!({}));
    let k5 = same5(&g4_keys(s));
    assert_ne!(k5, k4);
    assert_eq!(same5(&g4_keys(s)), k5);
    ffsrs_store_close(s);
}

/// 回包的输入下标、整列表标签项、日志 HLC（`logHlcs: true` 才报），在迁移出来的库上。
#[test]
fn the_apply_reply_carries_input_indices_tag_items_and_log_hlcs() {
    let m = migrated();
    let c = card(N2, "t1");
    let items = vec![
        json!({"e": review("s1c-h1", &c, T1, 3, "review"), "note": N2, "intent": "answer"}),
        draft("note", N3, "tags", json!(["x", "y"])),
        {
            // 值没变的修改：内核丢掉，不占 `edits`，后面的下标照旧按输入算。
            let mut it = draft("note", N3, "f/fa", json!("犬"));
            it["chg"] = json!(true);
            it
        },
        draft("note", N3, "f/fb", json!("s1c")),
    ];
    let (v, _) = call(
        m.h,
        &g4req("apply", T1, json!({"logHlcs": true})),
        Some(&items),
    )
    .unwrap();
    let edits = v["edits"].as_array().unwrap();
    assert_eq!(edits.len(), 1, "{v}");
    assert_eq!(edits[0][2], json!("f/fb"), "{v}");
    assert_eq!(edits[0][6], json!(3), "{v}");
    let tags = v["tagWrites"].as_array().unwrap();
    assert_eq!(tags.len(), 1, "{v}");
    assert_eq!(tags[0][0], json!(1), "{v}");
    assert_eq!(tags[0][1], json!(N3), "{v}");
    // 标签项的 dot 是展开出的最后一条操作（这批里最后一条之前：之后还有 f/fb 那一条）。
    let next = v["nextSeq"].as_u64().unwrap();
    assert_eq!(tags[0][3].as_u64().unwrap(), next - 2, "{v}");
    assert_eq!(tags[0][2], edits[0][3], "{v}");
    assert!(
        v.get("refreshTally").is_none(),
        "the tally stays in the kernel: {v}"
    );
    // 日志 HLC：与 `read logs` 读回的行相同。
    let logs = v["logHlcs"].as_array().unwrap();
    assert_eq!(logs.len(), 1, "{v}");
    assert_eq!(logs[0][0], json!(0));
    assert_eq!(logs[0][1], json!("s1c-h1"));
    let (_, f) = call(
        m.h,
        &g4req("read", T1, json!({"q": "logs", "cards": [c]})),
        None,
    )
    .unwrap();
    let (cols, rows) = super::tests::decode(&f.iter().find(|(n, _)| n == "t").unwrap().1);
    let (id_at, json_at) = (
        cols.iter().position(|c| c == "id").unwrap(),
        cols.iter().position(|c| c == "json").unwrap(),
    );
    let row = rows.iter().find(|r| r[id_at] == "s1c-h1").unwrap();
    let stored: Value = serde_json::from_str(&row[json_at]).unwrap();
    assert_eq!(stored["hlc"], logs[0][2]);
    // 不要就不报。
    let more = vec![
        json!({"e": review("s1c-h2", &c, T1 + 1, 3, "review"), "note": N2, "intent": "answer"}),
    ];
    let (v, _) = call(m.h, &g4req("apply", T1 + 1, json!({})), Some(&more)).unwrap();
    assert!(v.get("logHlcs").is_none(), "{v}");
}

/// 带盐成员（别名类里的非规范 ID）上的修改与整列表标签：回包里的实体 / 键是规范形，输入下标仍对得上调用方的输入
/// （Dart 不再逐条点查归一、也不按 (种类, 实体, 字段键) 猜）。
#[test]
fn input_indices_survive_salted_members() {
    let dir = tempdir::new("s1c-alias");
    let w = {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        let col = c.write(|t| t.bind(P, &id(0xc0), "dir")).unwrap();
        let w = c.write(|t| Ok(tests_class::land(t, col))).unwrap();
        c.write(|t| t.create_self(col, &id(0xee), &[9; 32], None, T1))
            .unwrap();
        c.close();
        w
    };
    let h = open(&dir.0, 0).unwrap();
    let member = w.note[1].text();
    let items = vec![
        draft("note", &member, "tags", json!(["s1c"])),
        draft(
            "note",
            &member,
            &format!("f/{}", w.field[1].text()),
            json!("salted"),
        ),
        draft(
            "note",
            &w.note[0].text(),
            &format!("f/{}", w.field[0].text()),
            json!("other"),
        ),
    ];
    let (v, _) = call(h, &g4req("apply", T1, json!({})), Some(&items))
        .unwrap_or_else(|(rc, e)| panic!("{rc} {e}"));
    let canon = w.c_note.text();
    let edits = v["edits"].as_array().unwrap();
    assert_eq!(edits.len(), 2, "{v}");
    let ats: Vec<Value> = edits.iter().map(|e| e[6].clone()).collect();
    assert_eq!(ats, vec![json!(1), json!(2)], "{v}");
    for e in edits {
        assert_eq!(e[1], json!(canon), "{v}");
        assert_eq!(e[2], json!(format!("f/{}", w.c_field.text())), "{v}");
    }
    assert_eq!(edits[0][5], json!("salted"));
    let tags = v["tagWrites"].as_array().unwrap();
    assert_eq!(tags.len(), 1, "{v}");
    assert_eq!(
        (&tags[0][0], &tags[0][1]),
        (&json!(0), &json!(canon)),
        "{v}"
    );
    ffsrs_store_close(h);
}

/// `import_drafts` 先筛掉「键上已有活着的修改」的 `init` 项再落：回包的输入下标按**筛掉之前**的调用方输入算
/// （`Origin::Kept`），不是筛掉之后的位置。
#[test]
fn import_drafts_reports_indices_into_the_unfiltered_input() {
    let m = migrated();
    let mut init = draft("note", N3, "f/fa", json!("s1c init"));
    init["init"] = json!(true);
    let items = vec![init, draft("note", N3, "f/fb", json!("s1c import"))];
    let (v, _) = call(m.h, &g4req("import_drafts", T1, json!({})), Some(&items))
        .unwrap_or_else(|(rc, e)| panic!("{rc} {e}"));
    let edits = v["edits"].as_array().unwrap();
    assert_eq!(
        edits.len(),
        1,
        "the init item on an authored key is dropped: {v}"
    );
    assert_eq!(edits[0][2], json!("f/fb"), "{v}");
    assert_eq!(edits[0][6], json!(1), "{v}");
}

/// Secondary：改别名 / 绑定的身份命令（补盐、绑定状态）不经 `Session`、不推进修订号，也不一定碰笔记缓存行；Secondary
/// 的键照样要变（Primary 同口径整份作废）。什么都没改的同一条命令不让键变。
#[test]
fn a_secondary_sees_binding_and_alias_writes() {
    let m = migrated();
    let s = open(&m.dir.0, 1).unwrap();
    let key = || g4_keys(s)["landed"].as_str().unwrap().to_owned();
    let k0 = key();
    let v = g4(
        m.h,
        "collection_salts_add",
        T1,
        json!({"salts": ["s1c-old-uid"]}),
    );
    assert_eq!(v["outcome"], json!("saltsAdded"), "{v}");
    let k1 = key();
    assert_ne!(k1, k0, "salts added");
    let v = g4(
        m.h,
        "collection_salts_add",
        T1,
        json!({"salts": ["s1c-old-uid"]}),
    );
    assert_eq!(v, json!({"outcome": "same"}));
    assert_eq!(key(), k1, "nothing written");
    g4(
        m.h,
        "binding_set",
        T1,
        json!({"state": "provisional", "via": "loc-a"}),
    );
    let k2 = key();
    assert_ne!(k2, k1, "binding state");
    g4(
        m.h,
        "binding_set",
        T1 + 1,
        json!({"state": "settled", "via": "loc-b"}),
    );
    let k3 = key();
    assert_ne!(k3, k2, "binding settled");
    // 已 settled：只进不退，什么都不改。
    g4(
        m.h,
        "binding_set",
        T1 + 2,
        json!({"state": "provisional", "via": "loc-c"}),
    );
    assert_eq!(key(), k3);
    ffsrs_store_close(s);
}
