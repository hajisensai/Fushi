//! 新代分发器（S1，`gen4/dispatch.rs`）的端到端测试：一律经 C ABI 的同一个入口（`ffsrs_store_open_mode` 打开、
//! `ffsrs_store_sync2` 发命令），不直接调 `cmd/*`。
//!
//! - **对拍**：`tests.rs` 的 [library]（协议 3）复制一份、经全局命令 `gen4_migrate_run` 迁移成新代库；迁移前的协议 3
//!   库（原件）上经协议 3 分发器 `sync2_dispatch` 发同一条命令，逐类比：读（`read` / `lineages` / `history`）、出卡
//!   （`study`）、浏览（`browse_query` → `browse_ids`）、统计（`stats_report` / `stats_rows`）、冲突中心（`conflicts` /
//!   `checkpoints`）；写（`apply` 一次作答 + 一次改字段）两侧各发一次，再比一遍读。各 `cmd/*_tests.rs` 已逐命令逐参数
//!   对拍过实现本身，这里钉的是接线：profile → 集合号、读快照、写事务、回包外壳与常驻会话。
//! - **常驻会话失效**：写入之后统计原料缓存重读（写入代数）、浏览会话按代号看见新行、出卡现读。
//! - **本机状态行**：写命令推进 `localRevision`，`apply` 的前置条件不成立什么都不写。
//! - **打开状态**：未迁移 / 迁移进行中 / 封存只剩旧库 / 墓碑 / 旁边另有未迁移的协议 3 库 / 辅助进程只读。
//! - **未接线 / 已删的命令**、没有绑定的 profile、别名类成员经分发器的回答、命令层新语句的查询计划。

use std::path::Path;
use std::ptr::{null, null_mut};

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::tests::{N1, N2, N3, Pair, T0, card, close, library, library_pair};
use super::tests_class;
use crate::gen4::op::tests::id;
use crate::store::ffi::{
    STORE_ERROR, STORE_LEGACY_UNMIGRATED, STORE_MIGRATING, STORE_NOT_MIGRATED, SrsCoreHandle,
    ffsrs_store_close, ffsrs_store_open_mode, ffsrs_store_sync2,
};
use crate::store::gen4::cache::CFG_KEY;
use crate::store::gen4::files::{GEN4_FILE, GenLock, LEGACY_FILE, OpenMode};
use crate::store::gen4::kernel::{G4Core, READ_ONLY, REMOVED, UNWIRED, global};
use crate::store::gen4::truth::Truth;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{DAY, Device, P, edit, review, tempdir};

type Files = Vec<(String, Vec<u8>)>;

const T1: i64 = T0 + 3 * DAY;

fn cfg() -> Value {
    json!({"defaultDeck": default_deck_id(P)})
}

fn take_error(err: *mut std::ffi::c_char) -> String {
    if err.is_null() {
        return String::new();
    }
    let s = unsafe { std::ffi::CStr::from_ptr(err) }
        .to_string_lossy()
        .into_owned();
    crate::ffsrs_free_string(err);
    s
}

/// 经 C ABI 打开 [dir]（[mode] 0 = Primary，1 = Secondary）。
fn open(dir: &Path, mode: i32) -> Result<*mut SrsCoreHandle, (i32, String)> {
    let p = dir.to_str().unwrap();
    let (mut h, mut err) = (null_mut(), null_mut());
    let rc = ffsrs_store_open_mode(p.as_ptr(), p.len(), mode, &mut h, &mut err);
    if rc == 0 {
        assert!(!h.is_null());
        Ok(h)
    } else {
        assert!(h.is_null());
        Err((rc, take_error(err)))
    }
}

/// 经 `ffsrs_store_sync2` 发一条命令（[items] = `apply` 一类命令的输入项，第一个字节块）。回包解帧成 (JSON, 文件)。
fn call(
    h: *mut SrsCoreHandle,
    req: &Value,
    items: Option<&[Value]>,
) -> Result<(Value, Files), (i32, String)> {
    let text = req.to_string();
    let mut blobs = Vec::new();
    if let Some(items) = items {
        let b = Value::Array(items.to_vec()).to_string().into_bytes();
        blobs.extend_from_slice(&1u32.to_le_bytes());
        blobs.extend_from_slice(&(b.len() as u32).to_le_bytes());
        blobs.extend_from_slice(&b);
    }
    let (mut out, mut out_len, mut err) = (null_mut(), 0usize, null_mut());
    let rc = ffsrs_store_sync2(
        h,
        text.as_ptr(),
        text.len(),
        if blobs.is_empty() {
            null()
        } else {
            blobs.as_ptr()
        },
        blobs.len(),
        &mut out,
        &mut out_len,
        &mut err,
    );
    if rc != 0 {
        return Err((rc, take_error(err)));
    }
    let b = unsafe { std::slice::from_raw_parts(out, out_len) }.to_vec();
    crate::ffsrs_free_bytes(out, out_len);
    let u32_at = |at: usize| u32::from_le_bytes(b[at..at + 4].try_into().unwrap()) as usize;
    let n = u32_at(0);
    let v: Value = serde_json::from_slice(&b[4..4 + n]).unwrap();
    let mut at = 4 + n;
    let count = u32_at(at);
    at += 4;
    let mut files = Vec::new();
    for _ in 0..count {
        let pl = u32_at(at);
        let path = String::from_utf8(b[at + 4..at + 4 + pl].to_vec()).unwrap();
        at += 4 + pl;
        let bl = u32_at(at);
        files.push((path, b[at + 4..at + 4 + bl].to_vec()));
        at += 4 + bl;
    }
    Ok((v, files))
}

/// 新代一侧的请求：`{op, profile, now}` 加 [extra]。
fn g4req(op: &str, now: i64, extra: Value) -> Value {
    let mut req = json!({"op": op, "profile": P, "now": now});
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        req[k.as_str()] = v;
    }
    req
}

fn g4(h: *mut SrsCoreHandle, op: &str, now: i64, extra: Value) -> Value {
    g4_files(h, op, now, extra, None).0
}

fn g4_files(
    h: *mut SrsCoreHandle,
    op: &str,
    now: i64,
    extra: Value,
    items: Option<&[Value]>,
) -> (Value, Files) {
    let req = g4req(op, now, extra);
    call(h, &req, items).unwrap_or_else(|(rc, e)| panic!("gen4 {req}: {rc} {e}"))
}

/// 协议 3 一侧：经协议 3 的分发器（`sync2_dispatch`）发同一条命令（带协议 3 要的 `caches` / 旧版时钟参数）。
fn p3(d: &Device, op: &str, now: i64, extra: Value, items: Option<&[Value]>) -> (Value, Files) {
    let mut req = json!({
        "op": op, "profile": P, "now": now, "caches": cfg(), "legacyDevice": "dev", "tickNow": now,
    });
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        req[k.as_str()] = v;
    }
    let mut blobs: Vec<Vec<u8>> = items
        .map(|i| Value::Array(i.to_vec()).to_string().into_bytes())
        .into_iter()
        .collect();
    let mut files = Vec::new();
    let v = crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
        .unwrap_or_else(|e| panic!("protocol 3 {req}: {e}"));
    (v, files)
}

/// 迁移前的协议 3 库与它迁移出来的新代库（经 C ABI 打开）。
struct Migrated {
    d: Device,
    h: *mut SrsCoreHandle,
    dir: tempdir::Dir,
}

impl Drop for Migrated {
    fn drop(&mut self) {
        ffsrs_store_close(self.h);
    }
}

/// [dir] 里的协议 3 库经全局命令 `gen4_migrate_run` 迁移（回包必须是提交）。
fn migrate(dir: &Path) {
    let out = global(
        "gen4_migrate_run",
        &json!({"dir": dir.to_str().unwrap(), "caches": {P: cfg()}, "now": T0 + 2 * DAY, "batch": 3}),
    )
    .unwrap();
    assert_eq!(out["verdict"], json!("committed"), "{out}");
}

/// 一份协议 3 库的副本放进新目录、关掉（WAL 并回主文件），目录交出去。
fn legacy_copy(d: &Device, tag: &str) -> tempdir::Dir {
    let Device { core, _dir } = Device::copy_of(d, tag);
    core.close();
    drop(core);
    _dir
}

fn migrated() -> Migrated {
    migrated_with(false)
}

/// [migrated]；[conflict] 为真时迁移之前先在两台设备上做出一条待裁决的冲突（一台删 N1、另一台没见过这条删除就改它的
/// 字段，同 `center_tests.rs`）。
fn migrated_with(conflict: bool) -> Migrated {
    let (d, b, mut bucket) = library_pair();
    if conflict {
        d.apply(T1 - 3, vec![edit("note", N1, "deleted", json!(T1 - 3))]);
        b.apply(T1 - 2, vec![edit("note", N1, "f/fa", json!("並行"))]);
        for _ in 0..2 {
            d.sync(&mut bucket, "loc", T1 - 1);
            b.sync(&mut bucket, "loc", T1 - 1);
        }
    }
    drop(b);
    // 协议 3 一侧：按同一份配置把欠着的收尾做完、缓存整份重建（同 `writes_tests.rs` 的 `W::new`），并注册缓存配置
    // （协议 3 的统计 / 浏览读它）。
    {
        let w = d.core.writer().unwrap();
        crate::store::sync2::transport::replay_pending(
            &w,
            P,
            &mut crate::store::sync2::transport::CommitBudget::unlimited(),
        )
        .unwrap();
        let parsed = crate::store::caches::CacheConfig::parse(&cfg()).unwrap();
        crate::store::caches::rebuild(&w, P, &parsed).unwrap();
    }
    p3(&d, "cache_config_set", T0, json!({}), None);
    let dir = legacy_copy(&d, "s1g4");
    migrate(&dir.0);
    let h = open(&dir.0, 0).unwrap_or_else(|(rc, e)| panic!("{rc} {e}"));
    Migrated { d, h, dir }
}

fn study_req(now: i64, extra: Value) -> Value {
    let mut r = json!({"now": now, "utcOff": 0, "rollover": 4});
    for (k, v) in extra.as_object().unwrap() {
        r[k] = v.clone();
    }
    r
}

fn stats_req() -> Value {
    let deck = default_deck_id(P);
    json!({
        "key": "k", "utcOff": 0, "rollover": 4, "range": "all",
        "models": [["fsrs6"]], "fallbackModel": 0, "fallbackDesired": 0.85,
        "deckModels": { deck.as_str(): 0 }, "desired": { deck.as_str(): 0.9 },
    })
}

fn browse_req(extra: Value) -> Value {
    let deck = default_deck_id(P);
    let mut req = json!({
        "owner": "page:s1", "utcOff": 0, "rollover": 4,
        "types": [{"id": "NT", "name": "Basic", "fields": [["fa", "Expression"], ["fb", "Meaning"]],
                   "tpls": [["t1", "A", 0], ["t2", "B", 1]]}],
        "decks": {deck.as_str(): ["Default", false]},
        "fallback": ["Default", false],
        "models": [["fsrs6", []]],
        "deckModels": {deck.as_str(): 0},
        "fallbackModel": 0,
        "mode": "cards",
        "sort": {"col": "created", "asc": true},
    });
    for (k, v) in extra.as_object().unwrap() {
        req[k] = v.clone();
    }
    req
}

/// 浏览一条查询的全部 ID（按规范 ID 排过）：`browse_query` → `browse_ids`。
fn browse_ids(
    pair: &Pair<'_>,
    run: &mut dyn FnMut(&str, Value) -> Value,
    query: Value,
) -> (Value, Vec<String>) {
    let v = run("browse_query", query);
    assert!(v.get("error").is_none(), "{v}");
    let gen = v["gen"].clone();
    let ids = run(
        "browse_ids",
        json!({"owner": "page:s1", "gen": gen, "from": 0}),
    );
    let mut out: Vec<String> = ids["ids"]
        .as_array()
        .unwrap_or_else(|| panic!("{ids}"))
        .iter()
        .map(|x| pair.canon(x.as_str().unwrap()))
        .collect();
    out.sort();
    (gen, out)
}

/// 按**迁移出来的那份库**归一 ID 的对拍装置（`tests.rs` 的 [Pair]，只用它的归一）：迁移给集合换了标识，内置实体
/// （默认牌组）的 ID 随集合加盐，与协议 3 的原值不同；按这份库的派生层归一后两侧相同。
fn pair_of(m: &Migrated) -> Pair<'_> {
    let g4 = crate::store::gen4::files::open_secondary(&m.dir.0.join(GEN4_FILE)).unwrap();
    let (col, cfg) = {
        let t = Truth::new(&g4);
        let col = t.binding_of(P).unwrap().unwrap().col;
        (col, t.derive_cfg(col, CFG_KEY).unwrap().unwrap())
    };
    Pair {
        d: &m.d,
        g4,
        col,
        cfg,
    }
}

/// 一张列式表归一后的行（多重集）。
fn rows(
    pair: &Pair<'_>,
    files: &Files,
    name: &str,
    norms: &[super::tests::Norm],
) -> Vec<Vec<String>> {
    pair.rows(files, name, norms)
}

// ---------------------------------------------------------------------- 对拍：读

/// 迁移出来的新代库经分发器的各类读命令，与迁移前的协议 3 库上同一条命令相同。
#[test]
fn reads_through_the_dispatcher_match_protocol_3_before_migration() {
    use super::tests::Norm::{Id, Payload, Plain};
    let m = migrated_with(true);
    let pair = pair_of(&m);
    let deck = default_deck_id(P);
    // 读：身份记录表、计数。
    let ent: &[super::tests::Norm] = &[Id, Plain, Payload];
    for q in [
        json!({"q": "entities"}),
        json!({"q": "entities", "kind": "note"}),
    ] {
        let (pv, pf) = p3(&m.d, "read", T1, q.clone(), None);
        let (gv, gf) = g4_files(m.h, "read", T1, q.clone(), None);
        close(&pair, &pv, &gv, &q.to_string());
        assert_eq!(
            rows(&pair, &pf, "t", ent),
            rows(&pair, &gf, "t", ent),
            "{q}"
        );
        assert!(rows(&pair, &gf, "t", ent).len() >= 4, "{q}");
    }
    let q = json!({"q": "entity_count", "kind": "note"});
    close(
        &pair,
        &p3(&m.d, "read", T1, q.clone(), None).0,
        &g4(m.h, "read", T1, q),
        "count",
    );
    // 出卡：几个此刻 × 出卡 / 只计数 / 排除。
    for now in [T0 + DAY + 100, T1, T0 + 40 * DAY] {
        for extra in [
            json!({}),
            json!({"deck": deck, "pick": true}),
            json!({"deck": deck, "pick": false}),
            json!({"deck": deck, "pick": true, "exclude": [card(N1, "t1")]}),
        ] {
            let req = study_req(now, extra);
            let old = p3(&m.d, "study", now, req.clone(), None).0;
            let new = g4(m.h, "study", now, req.clone());
            close(&pair, &old, &new, &req.to_string());
        }
    }
    // 冲突中心：迁移前做出的那条删除 / 修改冲突。
    let old = p3(&m.d, "conflicts", T1, json!({}), None).0;
    assert!(!old.as_array().unwrap().is_empty(), "{old}");
    close(
        &pair,
        &old,
        &g4(m.h, "conflicts", T1, json!({})),
        "conflicts",
    );
    close(
        &pair,
        &p3(&m.d, "checkpoints", T1, json!({}), None).0,
        &g4(m.h, "checkpoints", T1, json!({})),
        "checkpoints",
    );
    // 血统、修改历史。
    let cards = json!([card(N1, "t2"), card(N1, "t1"), "missing"]);
    let old = p3(&m.d, "lineages", T1, json!({"cards": cards}), None).0;
    let new = g4(m.h, "lineages", T1, json!({"cards": cards}));
    close(&pair, &old, &new, "lineages");
    assert_eq!(new[0], json!([card(N1, "t2"), card(N1, "t1")]));
    let hist = |v: Value| -> Vec<String> {
        let mut out: Vec<String> = v
            .as_array()
            .unwrap()
            .iter()
            .map(|e| {
                format!(
                    "{}={}",
                    e["key"],
                    e.get("value").cloned().unwrap_or(Value::Null)
                )
            })
            .collect();
        out.sort();
        out
    };
    let req = json!({"kind": "note", "entity": N1});
    let new = hist(g4(m.h, "history", T1, req.clone()));
    assert_eq!(hist(p3(&m.d, "history", T1, req, None).0), new);
    assert!(new.len() >= 3, "{new:?}");
    // 统计：报告与逐行原料（浮点按 `close` 的容差）。
    let mut req = stats_req();
    req["now"] = json!(T1);
    for op in ["stats_report", "stats_rows"] {
        let old = p3(&m.d, op, T1, req.clone(), None).0;
        let new = g4(m.h, op, T1, req.clone());
        if op == "stats_report" {
            close(&pair, &old, &new, op);
        } else {
            for k in ["today", "sources", "retrievabilityAvailable"] {
                close(&pair, &old[k], &new[k], &format!("{op}.{k}"));
            }
            for k in ["cards", "reviews"] {
                assert_eq!(
                    old[k].as_array().unwrap().len(),
                    new[k].as_array().unwrap().len(),
                    "{op}.{k}"
                );
            }
        }
    }
    // 浏览：同一条查询两侧的 ID 集合相同。
    let query = browse_req(json!({"now": T1}));
    let (_, old) = browse_ids(
        &pair,
        &mut |op, r| p3(&m.d, op, T1, r, None).0,
        query.clone(),
    );
    let (_, new) = browse_ids(&pair, &mut |op, r| g4(m.h, op, T1, r), query);
    assert_eq!(old, new);
    assert!(new.len() >= 6, "{new:?}");
    // 库级读、AnkiConnect 数字 id。
    let (v, files) = g4_files(m.h, "card_columns", T1, json!({}), None);
    assert_eq!(v, json!({}));
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].0, "columns");
}

// ---------------------------------------------------------------------- 对拍：写与会话失效

/// 两侧各发同一次作答与改字段：写回包带本机修订号，之后的出卡 / 统计 / 浏览 / 读两侧仍相同；统计原料缓存按写入代数
/// 重读，浏览会话按代号看见改动，`apply` 的前置条件不成立什么都不写。
#[test]
fn writes_through_the_dispatcher_match_protocol_3_and_invalidate_sessions() {
    let m = migrated();
    let pair = pair_of(&m);
    let deck = default_deck_id(P);
    let core = crate::store::ffi::core_of(m.h).unwrap();
    // 迁移不带协议 3 的本机状态行（「S1 接线设计」）：新代库上还没有。
    let st = g4(m.h, "local_state", T1, json!({}));
    assert_eq!(st["exists"], json!(false), "{st}");
    let st = g4(m.h, "local_state_ensure", T1, json!({}));
    assert_eq!(st["exists"], json!(false));
    assert_eq!(st["revision"], json!(0));
    let epoch = st["epoch"].clone();
    // 写之前：统计原料进缓存，浏览会话开着。
    let mut sreq = stats_req();
    sreq["now"] = json!(T1);
    let before = g4(m.h, "stats_rows", T1, sreq.clone());
    let w0 = crate::store::gen4::dispatch::stats_cached(&core).expect("stats cached");
    assert_eq!(g4(m.h, "stats_rows", T1, sreq.clone()), before);
    assert_eq!(crate::store::gen4::dispatch::stats_cached(&core), Some(w0));
    let query = browse_req(json!({"now": T1, "node": {"t": "text", "v": "鯨"}}));
    let (gen0, found) = browse_ids(&pair, &mut |op, r| g4(m.h, op, T1, r), query.clone());
    assert!(found.is_empty(), "{found:?}");
    // 同一次写两侧各发：N2 t1 作答、N2 改字段（新值能被浏览的全文搜到）。
    let c = card(N2, "t1");
    let items = vec![
        json!({"e": review("s1r", &c, T1, 3, "review"), "note": N2, "intent": "answer"}),
        json!({"e": edit("note", N2, "f/fb", json!("鯨")), "note": N2}),
    ];
    p3(&m.d, "apply", T1, json!({}), Some(&items));
    let (v, _) = g4_files(m.h, "apply", T1, json!({}), Some(&items));
    assert_eq!(v["landed"], json!([true, true]), "{v}");
    let r1 = v["localRevision"].as_i64().unwrap();
    assert!(r1 > 0, "{v}");
    assert_eq!(v["localEpoch"], epoch);
    assert_eq!(g4(m.h, "local_state", T1, json!({}))["revision"], json!(r1));
    // 统计：写入代数推进了，原料重读，新的复习在里面；与协议 3 相同。
    let after = g4(m.h, "stats_rows", T1, sreq.clone());
    let w1 = crate::store::gen4::dispatch::stats_cached(&core).unwrap();
    assert!(w1 > w0, "{w0} -> {w1}");
    assert_eq!(
        after["reviews"].as_array().unwrap().len(),
        before["reviews"].as_array().unwrap().len() + 1
    );
    let old = p3(&m.d, "stats_report", T1, sreq.clone(), None).0;
    close(
        &pair,
        &old,
        &g4(m.h, "stats_report", T1, sreq.clone()),
        "report",
    );
    // `stats_release` 丢掉缓存。
    g4(m.h, "stats_release", T1, json!({}));
    assert_eq!(crate::store::gen4::dispatch::stats_cached(&core), None);
    // 浏览：同一条查询带上次的代号，不是「没变」，搜到了改过的笔记的卡；两侧相同。
    let mut again = query.clone();
    again["since"] = gen0.clone();
    let v = g4(m.h, "browse_query", T1, again);
    assert_ne!(v["same"], json!(true), "{v}");
    let (_, new) = browse_ids(&pair, &mut |op, r| g4(m.h, op, T1, r), query.clone());
    let (_, old) = browse_ids(&pair, &mut |op, r| p3(&m.d, op, T1, r, None).0, query);
    assert_eq!(old, new);
    assert!(new.contains(&pair.canon(&c)), "{new:?}");
    // 出卡现读：两侧相同（作答过的卡不再到期）。
    for now in [T1 + 10, T1 + 5 * DAY] {
        let req = study_req(now, json!({"deck": deck, "pick": true}));
        close(
            &pair,
            &p3(&m.d, "study", now, req.clone(), None).0,
            &g4(m.h, "study", now, req.clone()),
            &req.to_string(),
        );
    }
    // 读：改过的字段。
    let q = json!({"q": "entities", "ids": [N2], "ordered": true});
    let (pv, pf) = p3(&m.d, "read", T1, q.clone(), None);
    let (gv, gf) = g4_files(m.h, "read", T1, q.clone(), None);
    close(&pair, &pv, &gv, "read N2");
    use super::tests::Norm::{Id, Payload, Plain};
    let ent: &[super::tests::Norm] = &[Id, Plain, Payload];
    assert_eq!(rows(&pair, &pf, "t", ent), rows(&pair, &gf, "t", ent));
    // 写命令带 `study`：同一个事务里排队，看得见这笔写入。
    let items = vec![json!({"e": edit("note", N3, "f/fa", json!("狼")), "note": N3})];
    let (v, _) = g4_files(
        m.h,
        "apply",
        T1 + 1,
        json!({"study": study_req(T1 + 1, json!({"deck": deck, "pick": false}))}),
        Some(&items),
    );
    assert!(v["study"]["counts"].is_object(), "{v}");
    let r2 = v["localRevision"].as_i64().unwrap();
    assert!(r2 > r1, "{r1} -> {r2}");
    // 前置条件不成立（最后一条日志不是这条）：stale，什么都不写，修订号不动。
    let items =
        vec![json!({"e": review("s1r2", &c, T1 + 2, 3, "review"), "note": N2, "intent": "answer"})];
    let (v, _) = g4_files(
        m.h,
        "apply",
        T1 + 2,
        json!({"expectLast": {"card": c, "log": "no-such-log"}}),
        Some(&items),
    );
    assert_eq!(v, json!({"stale": true}));
    assert_eq!(g4(m.h, "local_state", T1, json!({}))["revision"], json!(r2));
    // 本机写命令的锚点随写入一起落下。
    g4(
        m.h,
        "local_anchor",
        T1,
        json!({"anchor": {"o": 7, "b": "boot"}}),
    );
    assert_eq!(
        g4(m.h, "local_state", T1, json!({}))["anchor"],
        json!({"o": 7, "b": "boot"})
    );
}

/// 缓存配置：同一份不动派生层；改了（默认牌组换一个）按新配置整个重建，同一个事务；坏的不写。
#[test]
fn cache_config_set_rebuilds_only_when_the_config_changes() {
    let m = migrated();
    let v = g4(m.h, "cache_config_set", T1, json!({"caches": cfg()}));
    assert_eq!(v, json!({"changed": false}));
    let v = g4(
        m.h,
        "cache_config_set",
        T1,
        json!({"caches": {"defaultDeck": default_deck_id(P), "builtinNoteTypes": {}}}),
    );
    assert_eq!(v["changed"], json!(true), "{v}");
    assert!(v["settled"].is_object(), "{v}");
    let (rc, e) = call(
        m.h,
        &g4req(
            "cache_config_set",
            T1,
            json!({"caches": {"defaultDeck": 7}}),
        ),
        None,
    )
    .unwrap_err();
    assert_eq!(rc, STORE_ERROR, "{e}");
    let v = g4(m.h, "rebuild_caches", T1, json!({}));
    assert!(v["settled"].is_object(), "{v}");
    let v = g4(m.h, "refresh_caches", T1, json!({}));
    assert!(v["settled"].is_object(), "{v}");
}

// ---------------------------------------------------------------------- 打开状态

fn state_of(e: &str) -> Value {
    let at = e.find('{').unwrap_or_else(|| panic!("{e}"));
    serde_json::from_str::<Value>(&e[at..]).unwrap()["state"].clone()
}

fn gen_status(dir: &Path) -> Value {
    global(
        "gen4_migrate_status",
        &json!({"dir": dir.to_str().unwrap()}),
    )
    .unwrap()
}

fn remove_gen4(dir: &Path) {
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(dir.join(format!("{GEN4_FILE}{suffix}")));
    }
}

/// 未迁移、迁移进行中、迁移、封存只剩旧库、墓碑：每个状态打开的返回码与状态名明确，库不动、不静默打开协议 3 的库。
#[test]
fn every_generation_state_opens_explicitly() {
    let d = library();
    let dir = legacy_copy(&d, "s1open");
    let old = std::fs::read(dir.0.join(LEGACY_FILE)).unwrap();
    // 未迁移：两种模式都不开，状态是「要迁移」，什么都没建。
    for mode in [0, 1] {
        let (rc, e) = open(&dir.0, mode).unwrap_err();
        assert_eq!(rc, STORE_NOT_MIGRATED, "{e}");
        assert_eq!(state_of(&e), json!("needsMigration"), "{e}");
    }
    assert!(!dir.0.join(GEN4_FILE).exists());
    assert_eq!(std::fs::read(dir.0.join(LEGACY_FILE)).unwrap(), old);
    assert_eq!(gen_status(&dir.0)["state"], json!("needsMigration"));
    assert_eq!(gen_status(&dir.0)["running"], Value::Null);
    // 另一个进程拿着换代锁：迁移进行中。
    {
        let lock = GenLock::try_acquire(&dir.0).unwrap().unwrap();
        let (rc, e) = open(&dir.0, 0).unwrap_err();
        assert_eq!(rc, STORE_MIGRATING, "{e}");
        drop(lock);
    }
    // 坏的模式号。
    assert!(open(&dir.0, 2).is_err());
    // 迁移：之后两种模式都开得了；辅助进程只读。
    migrate(&dir.0);
    assert_eq!(gen_status(&dir.0)["state"], json!("ready"));
    let h = open(&dir.0, 0).unwrap();
    let r = g4(h, "local_state_ensure", T1, json!({}));
    assert_eq!(r["exists"], json!(false));
    let s = open(&dir.0, 1).unwrap();
    assert_eq!(g4(s, "local_state", T1, json!({}))["exists"], json!(true));
    let n = g4(s, "read", T1, json!({"q": "entity_count", "kind": "note"}));
    assert_eq!(
        n,
        g4(h, "read", T1, json!({"q": "entity_count", "kind": "note"}))
    );
    for (op, extra) in [
        ("local_anchor", json!({"anchor": {"o": 1, "b": "x"}})),
        ("rebuild_caches", json!({})),
    ] {
        let (rc, e) = call(s, &g4req(op, T1, extra), None).unwrap_err();
        assert_eq!(rc, STORE_ERROR, "{e}");
        assert!(e.contains(READ_ONLY), "{op}: {e}");
    }
    let items = vec![json!({"e": edit("note", N1, "f/fa", json!("x")), "note": N1})];
    let (_, e) = call(s, &g4req("apply", T1, json!({})), Some(&items)).unwrap_err();
    assert!(e.contains(READ_ONLY), "{e}");
    ffsrs_store_close(s);
    ffsrs_store_close(h);
    // 保留副本到期换成墓碑（新代库在旁边才换得了）：新代库照常打开。
    crate::store::schema::write_tombstone(&dir.0.join(LEGACY_FILE)).unwrap();
    let h = open(&dir.0, 0).unwrap();
    assert_eq!(g4(h, "local_state", T1, json!({}))["exists"], json!(true));
    ffsrs_store_close(h);
    // 新代库不在了、只剩墓碑：不开，状态是「只剩封存的旧库」，不建空库顶上。
    remove_gen4(&dir.0);
    let (rc, e) = open(&dir.0, 0).unwrap_err();
    assert_eq!(rc, STORE_NOT_MIGRATED, "{e}");
    assert_eq!(state_of(&e), json!("sealedOldOnly"), "{e}");
    assert!(!dir.0.join(GEN4_FILE).exists());
    assert_eq!(gen_status(&dir.0)["state"], json!("sealedOldOnly"));
}

/// 全新安装建空库；旁边后来出现一份没封存、也不是迁移来源的协议 3 库：不开（不并入、不改它），单独的返回码。
#[test]
fn a_stray_protocol_3_library_next_to_the_new_one_is_reported() {
    let fresh = tempdir::new("s1fresh");
    let h = open(&fresh.0, 0).unwrap();
    // 全新库没有绑定：按集合的命令明确报错，本机状态行照常。
    let (rc, e) = call(h, &g4req("study", T1, study_req(T1, json!({}))), None).unwrap_err();
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains("has no collection"), "{e}");
    assert_eq!(g4(h, "local_state", T1, json!({}))["exists"], json!(false));
    ffsrs_store_close(h);
    let d = library();
    let stray = legacy_copy(&d, "s1stray");
    std::fs::copy(stray.0.join(LEGACY_FILE), fresh.0.join(LEGACY_FILE)).unwrap();
    let before = std::fs::read(fresh.0.join(LEGACY_FILE)).unwrap();
    let (rc, e) = open(&fresh.0, 0).unwrap_err();
    assert_eq!(rc, STORE_LEGACY_UNMIGRATED, "{e}");
    assert_eq!(std::fs::read(fresh.0.join(LEGACY_FILE)).unwrap(), before);
}

/// 全局迁移命令：取消一次还没开始的运行（按 runId 先登记），之后照常迁移。
#[test]
fn a_migration_cancelled_before_it_starts_does_nothing() {
    let d = library();
    let dir = legacy_copy(&d, "s1cancel");
    let p = dir.0.to_str().unwrap();
    let v = global("gen4_migrate_cancel", &json!({"dir": p, "runId": "r1"})).unwrap();
    assert_eq!(v, json!({"cancelled": false}));
    let out = global(
        "gen4_migrate_run",
        &json!({"dir": p, "caches": {P: cfg()}, "now": T1, "runId": "r1"}),
    )
    .unwrap();
    assert_eq!(out["verdict"], json!("cancelled"), "{out}");
    assert!(!dir.0.join(GEN4_FILE).exists());
    assert_eq!(gen_status(&dir.0)["state"], json!("needsMigration"));
    // 坏的缓存配置在进迁移之前报。
    assert!(
        global(
            "gen4_migrate_run",
            &json!({"dir": p, "caches": {P: {"defaultDeck": 7}}, "now": T1}),
        )
        .is_err()
    );
    migrate(&dir.0);
    assert!(dir.0.join(GEN4_FILE).exists());
    // 新代库不在了、只剩封存的旧库（保留副本）：不开，状态是「只剩封存的旧库」；不建空库、不回落到旧库。
    remove_gen4(&dir.0);
    for mode in [0, 1] {
        let (rc, e) = open(&dir.0, mode).unwrap_err();
        assert_eq!(rc, STORE_NOT_MIGRATED, "{e}");
        assert_eq!(state_of(&e), json!("sealedOldOnly"), "{e}");
    }
    assert!(!dir.0.join(GEN4_FILE).exists());
}

// ---------------------------------------------------------------------- 未接线 / 已删

/// 归别的模块接线的命令报 `UNWIRED` 并点名模块，新代不需要的报 `REMOVED`，不认识的照旧报未知命令；都不改库。
#[test]
fn unwired_and_removed_commands_name_their_owner() {
    let m = migrated();
    for (op, owner) in [
        ("identity", "G9-4"),
        ("profile_merge_mark", "G9-5"),
        ("plan", "G8-7"),
        ("import", "G11-3"),
        ("preview", "G7-4f"),
        ("media_gc_queue", "media GC"),
    ] {
        let (rc, e) = call(m.h, &g4req(op, T1, json!({})), None).unwrap_err();
        assert_eq!(rc, STORE_ERROR, "{op}");
        assert!(e.contains(UNWIRED) && e.contains(owner), "{op}: {e}");
    }
    for op in ["refresh_keys", "channel_settle", "migrate", "gen4_rehearse"] {
        let (_, e) = call(m.h, &g4req(op, T1, json!({})), None).unwrap_err();
        assert!(e.contains(REMOVED), "{op}: {e}");
    }
    let (_, e) = call(m.h, &g4req("no_such_op", T1, json!({})), None).unwrap_err();
    assert!(e.contains("unknown sync2 op"), "{e}");
}

// ---------------------------------------------------------------------- 别名类

/// 双盐场景（`tests_class.rs` 的 [tests_class::land]，只有新代才有）经分发器：修改历史与撤销校验按任何一份成员点名都
/// 是整个类的回答，冲突中心列出这个类。
#[test]
fn alias_class_members_answer_as_their_class_through_the_dispatcher() {
    let dir = tempdir::new("s1alias");
    let w = {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        let col = c.write(|t| t.bind(P, &id(0xc0), "dir")).unwrap();
        let w = c.write(|t| Ok(tests_class::land(t, col))).unwrap();
        c.close();
        w
    };
    let h = open(&dir.0, 0).unwrap();
    let hist = |e: &str| -> Vec<String> {
        let v = g4(h, "history", T1, json!({"kind": "note", "entity": e}));
        let mut out: Vec<String> = v
            .as_array()
            .unwrap()
            .iter()
            .map(|e| {
                format!(
                    "{}={}",
                    e["key"],
                    e.get("value").cloned().unwrap_or(Value::Null)
                )
            })
            .collect();
        out.sort();
        out
    };
    let by_canon = hist(&w.c_note.text());
    assert!(!by_canon.is_empty());
    assert_eq!(hist(&w.note[0].text()), by_canon);
    assert_eq!(hist(&w.note[1].text()), by_canon);
    let ask = |e: &crate::sync2::id::Id, f: &crate::sync2::id::Id, dev: u8| -> Value {
        g4(
            h,
            "undo_check",
            T1,
            json!({"items": [{"k": "note", "e": e.text(), "f": format!("f/{}", f.text()),
                "w": id(dev).text(), "s": 1}]}),
        )["r"][0]
            .clone()
    };
    let by_member = ask(&w.note[1], &w.field[1], 0xb2);
    assert_eq!(by_member, ask(&w.c_note, &w.c_field, 0xb2));
    assert_eq!(by_member["ok"], json!(false), "{by_member}");
    // 冲突中心：待裁决的删除（0xc1 删、0xc2 没见过就改）在；两份成员各改一次同一字段不是待裁决项（并发的字段修改按
    // 类只出一个胜者，`center_tests.rs` 的同一场景）。
    let conflicts = g4(h, "conflicts", T1, json!({}));
    let rows = conflicts.as_array().unwrap();
    assert_eq!(rows.len(), 1, "{conflicts}");
    assert_eq!(rows[0]["kind"], json!("delete_edit"));
    assert_eq!(rows[0]["entity"], json!(id(0x4e).text()));
    ffsrs_store_close(h);
}

// ---------------------------------------------------------------------- 查询计划

/// 命令层新加的语句（统计缓存键里的缓存层代号、本机状态行）按主键找，不扫表。
#[test]
fn command_layer_lookups_use_their_keys() {
    let m = migrated();
    let c = Connection::open_with_flags(
        m.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    for q in [
        "SELECT gen, floor FROM cache_gen WHERE col = ?1",
        "SELECT value FROM srs_meta WHERE key = ?1",
    ] {
        let plan: Vec<String> = c
            .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
            .unwrap()
            .query_map([1], |r| r.get::<_, String>(3))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(
            plan.iter().all(|p| p.starts_with("SEARCH")),
            "{q}: {plan:?}"
        );
    }
}
