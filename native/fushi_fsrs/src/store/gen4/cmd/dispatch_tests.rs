//! 新代分发器（S1，`gen4/dispatch.rs`）的端到端测试：一律经 C ABI 的同一个入口（`ffsrs_store_open_mode` 打开、
//! `ffsrs_store_sync2` 发命令），不直接调 `cmd/*`。
//!
//! - **对拍**：`tests.rs` 的 [library]（协议 3）复制一份、经全局命令 `gen4_migrate_run` 迁移成新代库；迁移前的协议 3
//!   库（原件）上经协议 3 分发器 `sync2_dispatch` 发同一条命令，逐类比：读（`read` / `lineages` / `history`）、出卡
//!   （`study`）、浏览（`browse_query` → `browse_ids`）、统计（`stats_report` / `stats_rows`）、冲突中心（`conflicts` /
//!   `checkpoints`）；写（`apply` 一次作答 + 一次改字段）两侧各发一次，再比一遍读。各 `cmd/*_tests.rs` 已逐命令逐参数
//!   对拍过实现本身，这里钉的是接线：profile → 集合号、读快照、写事务、回包外壳与常驻会话。
//! - **常驻会话失效**：写入之后统计原料缓存重读（写入代数）、浏览会话按代号看见新行、出卡会话按触发器记的行重读
//!   （逐场景的对拍在 `study_session_tests.rs`）。
//! - **本机状态行**：写命令推进 `localRevision`，`apply` 的前置条件不成立什么都不写。
//! - **打开状态**：未迁移 / 迁移进行中 / 封存只剩旧库 / 墓碑 / 旁边另有未迁移的协议 3 库 / 辅助进程只读。
//! - **未接线 / 已删的命令**、没有绑定的 profile、别名类成员经分发器的回答、命令层新语句的查询计划。

use std::path::Path;
use std::ptr::{null, null_mut};

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::tests::{N1, N2, N3, N4, Pair, T0, card, close, library, library_pair};
use super::tests_class;
use crate::gen4::op::tests::id;
use crate::store::ffi::{
    STORE_ERROR, STORE_LEGACY_UNMIGRATED, STORE_MIGRATING, STORE_NOT_MIGRATED, SrsCoreHandle,
    ffsrs_store_close, ffsrs_store_open_mode, ffsrs_store_sync2,
};
use crate::store::gen4::cache::CFG_KEY;
use crate::store::gen4::files::{GEN4_FILE, GenLock, LEGACY_FILE, OpenMode};
use crate::store::gen4::kernel::{G4Core, READ_ONLY, REMOVED, global};
use crate::store::gen4::truth::Truth;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{DAY, Device, P, edit, review, tempdir};

type Files = Vec<(String, Vec<u8>)>;

pub(crate) const T1: i64 = T0 + 3 * DAY;

pub(crate) fn cfg() -> Value {
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
pub(crate) fn open(dir: &Path, mode: i32) -> Result<*mut SrsCoreHandle, (i32, String)> {
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
pub(crate) fn call(
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
pub(crate) fn g4req(op: &str, now: i64, extra: Value) -> Value {
    let mut req = json!({"op": op, "profile": P, "now": now});
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        req[k.as_str()] = v;
    }
    req
}

pub(crate) fn g4(h: *mut SrsCoreHandle, op: &str, now: i64, extra: Value) -> Value {
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
pub(super) fn p3(
    d: &Device,
    op: &str,
    now: i64,
    extra: Value,
    items: Option<&[Value]>,
) -> (Value, Files) {
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
    let v = crate::store::legacy3::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
        .unwrap_or_else(|e| panic!("protocol 3 {req}: {e}"));
    (v, files)
}

/// 迁移前的协议 3 库与它迁移出来的新代库（经 C ABI 打开）。
pub(super) struct Migrated {
    pub(super) d: Device,
    pub(super) h: *mut SrsCoreHandle,
    pub(super) dir: tempdir::Dir,
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

pub(super) fn migrated() -> Migrated {
    migrated_with(false)
}

/// [migrated]；[conflict] 为真时迁移之前先在两台设备上做出一条待裁决的冲突（一台删 N1、另一台没见过这条删除就改它的
/// 字段，同 `center_tests.rs`）。
fn migrated_with(conflict: bool) -> Migrated {
    migrated_prepared(conflict, &|_| {})
}

/// [migrated_with]；迁移之前先在协议 3 库上跑 [prep]（补复习、媒体引用之类的场景数据）。
pub(super) fn migrated_prepared(conflict: bool, prep: &dyn Fn(&Device)) -> Migrated {
    let (d, b, mut bucket) = library_pair();
    prep(&d);
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

/// 本机状态行的 `limitUnitSince`（本机第一次跑懂每日上限单位的版本的时刻，`gen4/local.rs`）：`local_state_ensure`
/// 带了且行里还没有时才写下，之后带别的值也不改；没带不写；`local_state` 读得到，没写过是 null。
#[test]
fn limit_unit_since_is_written_once() {
    let m = migrated();
    let since = |op: &str, extra: Value| g4(m.h, op, T1, extra)["limitUnitSince"].clone();
    assert_eq!(since("local_state", json!({})), Value::Null);
    assert_eq!(
        since("local_state_ensure", json!({})),
        Value::Null,
        "没带不写"
    );
    assert_eq!(
        since("local_state_ensure", json!({"limitUnitSince": 1000})),
        json!(1000)
    );
    assert_eq!(
        since("local_state_ensure", json!({"limitUnitSince": 2000})),
        json!(1000),
        "只写一次"
    );
    assert_eq!(since("local_state", json!({})), json!(1000));
}

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
    // 出卡（常驻会话重读这笔写入）：两侧相同（作答过的卡不再到期）。
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

/// BUG-5209：开库的 `cache_config_set` 在同一个事务里复活带删除标记的默认牌组——一笔本机写（推进本机状态行、回包
/// `revive` 带 `localRevision` / `localEpoch`，宿主照本机写命令接）；默认牌组活着时回包不变、什么都不写。
#[test]
fn cache_config_set_revives_a_deleted_default_deck_in_the_same_transaction() {
    let m = migrated();
    let deck = default_deck_id(P);
    g4(m.h, "local_state_ensure", T1, json!({}));
    let items = vec![json!({"e": edit("deck", &deck, "deleted", json!(T1)), "note": null})];
    let (v, _) = g4_files(m.h, "apply", T1, json!({}), Some(&items));
    let r0 = v["localRevision"].as_i64().unwrap();

    let v = g4(m.h, "cache_config_set", T1 + 1, json!({"caches": cfg()}));
    assert_eq!(v["changed"], json!(false), "配置没变，派生层不重建：{v}");
    let revive = &v["revive"];
    assert_eq!(revive["revived"], json!(true), "{v}");
    let r1 = revive["localRevision"].as_i64().unwrap();
    assert!(r1 > r0, "{r0} -> {r1}");
    assert!(revive["localEpoch"].is_string(), "{v}");
    assert!(
        revive.get(crate::store::gen4::refresh::TALLY_KEY).is_none(),
        "刷新计数在分发器里取走、不交给宿主：{v}"
    );
    assert_eq!(g4(m.h, "local_state", T1, json!({}))["revision"], json!(r1));

    let v = g4(m.h, "cache_config_set", T1 + 2, json!({"caches": cfg()}));
    assert_eq!(v, json!({"changed": false}), "已经活着：不再写");
    assert_eq!(g4(m.h, "local_state", T1, json!({}))["revision"], json!(r1));
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
    assert_eq!(gen_status(&dir.0)["failure"], Value::Null);
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

/// 上次迁移中止：打开错误与状态命令带同一个内核判定的原因（`{failure: {reason, reportPath}, state}`），调用方不另读
/// 报告文件。
#[test]
fn the_open_error_carries_the_failure_reason() {
    let d = library();
    let dir = legacy_copy(&d, "s1reason");
    let identity = {
        let c =
            Connection::open_with_flags(dir.0.join(LEGACY_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY)
                .unwrap();
        crate::store::seal::legacy_identity(&c).unwrap()
    };
    let report = json!({
        "version": 1,
        "verdict": "aborted",
        "profileVerdict": "incomplete",
        "legacyIdentity": identity,
    });
    let path = dir.0.join(crate::store::gen4::migrate::REPORT_FILE);
    std::fs::write(&path, report.to_string()).unwrap();
    let (rc, e) = open(&dir.0, 0).unwrap_err();
    assert_eq!(rc, STORE_NOT_MIGRATED, "{e}");
    let at = e.find('{').unwrap_or_else(|| panic!("{e}"));
    let payload: Value = serde_json::from_str(&e[at..]).unwrap();
    assert_eq!(payload["state"], json!("migrationFailed"), "{e}");
    assert_eq!(
        payload["failure"],
        json!({"reason": "incomplete", "reportPath": path.display().to_string()}),
        "{e}"
    );
    let st = gen_status(&dir.0);
    assert_eq!(st["state"], payload["state"]);
    assert_eq!(st["failure"], payload["failure"]);
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
    // W3 合流后已没有未接线命令（relay_outbox 归 G8-7b、profile_merge_mark 归 G9-5 删除），未接线臂由 ffi.rs 的
    // 全量分类测试兜底。
    for op in [
        "channel_settle",
        "migrate",
        "gen4_rehearse",
        "profile_merge_mark",
    ] {
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
        crate::store::gen4::dispatch::CACHE_MARK_SQL,
        crate::store::gen4::local::STORED_SQL,
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

// ---------------------------------------------------------------------- 统计原料缓存的两个失效条件（复核 minor-1）

/// 新代库里 `cache_gen` 的全部行（缓存层代号）。
fn cache_gen_rows(dir: &Path) -> Vec<(i64, i64, i64)> {
    let c = Connection::open_with_flags(
        dir.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    let mut s = c
        .prepare("SELECT col, gen, floor FROM cache_gen ORDER BY col")
        .unwrap();
    s.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// 同一个进程里一条不碰缓存层的写（`local_anchor` 只写本机状态行）：缓存层代号不动，统计原料仍然重读——失效靠的是
/// 写入代数（去掉缓存键里的写入代数这条就红）。
#[test]
fn a_write_outside_the_cache_layer_still_invalidates_the_stats_cache() {
    use crate::store::gen4::dispatch::stats_cached;
    let m = migrated();
    let core = crate::store::ffi::core_of(m.h).unwrap();
    let mut sreq = stats_req();
    sreq["now"] = json!(T1);
    let before = g4(m.h, "stats_rows", T1, sreq.clone());
    let w0 = stats_cached(&core).expect("stats cached");
    let mark = cache_gen_rows(&m.dir.0);
    assert!(!mark.is_empty());
    g4(
        m.h,
        "local_anchor",
        T1,
        json!({"anchor": {"o": 3, "b": "boot"}}),
    );
    assert_eq!(
        cache_gen_rows(&m.dir.0),
        mark,
        "local_anchor left the cache layer alone"
    );
    assert_eq!(g4(m.h, "stats_rows", T1, sreq.clone()), before);
    let w1 = stats_cached(&core).unwrap();
    assert!(
        w1 > w0,
        "the raw stats were re-read after the write: {w0} -> {w1}"
    );
}

/// 同一个目录开 Primary 与 Secondary：Secondary 先把统计原料读进它自己的缓存，Primary 作答一次；Secondary 的写入代数
/// 没动，再读时靠缓存层代号认出别的进程的写入，拿到新的复习（去掉缓存键里的缓存层代号这条就红）。
#[test]
fn a_secondary_stats_cache_sees_the_primarys_writes() {
    use crate::store::gen4::dispatch::stats_cached;
    let m = migrated();
    let s = open(&m.dir.0, 1).unwrap();
    let sc = crate::store::ffi::core_of(s).unwrap();
    let mut sreq = stats_req();
    sreq["now"] = json!(T1);
    let before = g4(s, "stats_rows", T1, sreq.clone());
    let ws = stats_cached(&sc).expect("secondary stats cached");
    let c = card(N2, "t1");
    let items =
        vec![json!({"e": review("s1sec", &c, T1, 3, "review"), "note": N2, "intent": "answer"})];
    let (v, _) = g4_files(m.h, "apply", T1, json!({}), Some(&items));
    assert_eq!(v["landed"], json!([true]), "{v}");
    let after = g4(s, "stats_rows", T1, sreq.clone());
    assert_eq!(stats_cached(&sc), Some(ws), "the secondary never writes");
    assert_eq!(
        after["reviews"].as_array().unwrap().len(),
        before["reviews"].as_array().unwrap().len() + 1,
        "{after}"
    );
    assert_eq!(after, g4(m.h, "stats_rows", T1, sreq));
    ffsrs_store_close(s);
}

// ---------------------------------------------------------------------- Secondary 上的 wal_checkpoint（复核 minor-4）

/// Secondary 只读：`wal_checkpoint` 报 `READ_ONLY`、不另开读写连接；Primary 照常并回 WAL。
#[test]
fn wal_checkpoint_is_refused_on_a_secondary() {
    let m = migrated();
    let s = open(&m.dir.0, 1).unwrap();
    let (rc, e) = call(s, &json!({"op": "wal_checkpoint"}), None).unwrap_err();
    assert_eq!(rc, STORE_ERROR, "{e}");
    assert!(e.contains(READ_ONLY), "{e}");
    let v = call(m.h, &json!({"op": "wal_checkpoint"}), None).unwrap().0;
    assert!(v["busy"].is_boolean() && v["checkpointed"].is_i64(), "{v}");
    ffsrs_store_close(s);
}

// ---------------------------------------------------------------------- 迁移登记（复核 minor-3）

/// 迁移中途 panic（`ffsrs_call` 接住）：本进程里这个目录的登记照样摘掉，之后的迁移不回 `blocked`、状态里没有挂着的
/// 进度；给了 runId、却始终没有对应运行的提前取消在下一次运行结束时清掉。
#[test]
fn a_panicking_migration_does_not_leave_the_directory_blocked() {
    use crate::store::gen4::kernel::{run_registry_of, with_registered_run};
    let d = library();
    let dir = legacy_copy(&d, "s1panic");
    let p = dir.0.to_str().unwrap().to_owned();
    let r = std::panic::catch_unwind(|| {
        with_registered_run(&dir.0, || {
            // 登记期间：同一目录的迁移回 blocked、状态里有进度。
            let v = global(
                "gen4_migrate_run",
                &json!({"dir": p, "caches": {P: cfg()}, "now": T1}),
            )
            .unwrap();
            assert_eq!(v["verdict"], json!("blocked"), "{v}");
            assert!(gen_status(&dir.0)["running"].is_object());
            panic!("migration panicked midway");
        })
    });
    assert!(r.is_err());
    assert_eq!(run_registry_of(&dir.0), (false, 0));
    assert_eq!(gen_status(&dir.0)["running"], Value::Null);
    let v = global("gen4_migrate_cancel", &json!({"dir": p, "runId": "never"})).unwrap();
    assert_eq!(v, json!({"cancelled": false}));
    assert_eq!(run_registry_of(&dir.0), (false, 1));
    migrate(&dir.0);
    assert_eq!(run_registry_of(&dir.0), (false, 0));
}

// ---------------------------------------------------------------------- 逐条接线的对拍（复核 minor-2）

/// 协议 3 一侧的修改记录草稿（同 `writes_tests.rs`）。
fn draft(kind: &str, entity: &str, key: &str, v: Value) -> Value {
    json!({
        "e": {"t": "edit", "x": {"p": P, "k": kind, "e": entity, "f": key, "v": v, "ts": "anchored"}},
        "note": null, "clk": "t",
    })
}

fn keys_of(v: &Value) -> Vec<String> {
    let mut k: Vec<String> = v
        .as_object()
        .unwrap_or_else(|| panic!("not an object: {v}"))
        .keys()
        .cloned()
        .collect();
    k.sort();
    k
}

/// 两侧的身份记录表相同（每条写之后都比：接错臂的写会让两侧分叉）。
fn same_entities(m: &Migrated, pair: &Pair<'_>, at: &str) {
    use super::tests::Norm::{Id, Payload, Plain};
    let ent: &[super::tests::Norm] = &[Id, Plain, Payload];
    let q = json!({"q": "entities"});
    let (_, pf) = p3(&m.d, "read", T1, q.clone(), None);
    let (_, gf) = g4_files(m.h, "read", T1, q, None);
    assert_eq!(rows(pair, &pf, "t", ent), rows(pair, &gf, "t", ent), "{at}");
}

/// 浏览一串命令（同 `browse_tests.rs` 的脚本，缩短）：每一侧用自己的 `gen`。回包按 (命令, JSON) 收集。
fn browse_script(run: &mut dyn FnMut(&str, Value) -> Value) -> Vec<(String, Value)> {
    let deck = default_deck_id(P);
    let mut out = Vec::new();
    let q = browse_req(json!({"now": T1}));
    let v = run("browse_query", q.clone());
    let gen = v["gen"].clone();
    out.push(("browse_query".to_owned(), v));
    for (op, req) in [
        ("browse_rows", json!({"owner": "page:s1", "gen": gen})),
        ("browse_sources", json!({"owner": "page:s1", "gen": gen})),
    ] {
        out.push((op.to_owned(), run(op, req)));
    }
    let ids = run(
        "browse_ids",
        json!({"owner": "page:s1", "gen": gen, "from": 0}),
    );
    let two: Vec<Value> = ids["ids"].as_array().unwrap()[..2].to_vec();
    out.push((
        "browse_targets".to_owned(),
        run(
            "browse_targets",
            json!({"owner": "page:s1", "gen": gen, "ids": two}),
        ),
    ));
    let mut counts = q.clone();
    counts["nodes"] = json!([{"t": "text", "v": "猫"}, false]);
    out.push(("browse_counts".to_owned(), run("browse_counts", counts)));
    let mut find = browse_req(json!({"now": T1}));
    find["owner"] = json!("ankiconnect");
    find["mode"] = json!("notes");
    find["uuids"] = json!(false);
    find["node"] = json!({"t": "text", "v": "猫"});
    out.push(("anki_find".to_owned(), run("anki_find", find)));
    out.push((
        "anki_tags".to_owned(),
        run("anki_tags", json!({"owner": "ankiconnect"})),
    ));
    let norm = crate::search::dupe_norm;
    out.push((
        "anki_dupes".to_owned(),
        run(
            "anki_dupes",
            json!({"first": {"NT": "fa"}, "cands": [
                {"norm": norm("猫"), "type": "NT", "all": false, "decks": null},
                {"norm": norm("犬"), "type": "NT", "all": false, "decks": [deck]},
                {"norm": norm("鳥"), "type": "NT", "all": false, "decks": null},
            ]}),
        ),
    ));
    out.push(("browse_stats".to_owned(), run("browse_stats", json!({}))));
    out.push((
        "browse_close".to_owned(),
        run("browse_close", json!({"owner": "page:s1"})),
    ));
    out.push(("browse_stats".to_owned(), run("browse_stats", json!({}))));
    out
}

/// 第一组对拍（`reads_through_…`）之外的每一条读命令经分发器与协议 3 的同一条比：数字 id、笔记详情、绑定、规模、
/// 同步状态的形状、库级读、回忆率、浏览的其余子命令与 AnkiConnect 查询。接到相邻实现上的臂回包形状或值必然不同。
#[test]
fn every_other_wired_read_matches_protocol_3_through_the_dispatcher() {
    let m = migrated_with(true);
    let pair = pair_of(&m);
    let deck = default_deck_id(P);
    let num = crate::store::schema::anki_numeric_id;
    let (c1, c2) = (card(N1, "t1"), card(N1, "t2"));
    // 数字 id → ID。
    let req = json!({
        "notes": [num(N1), num(N4), 5, num(N2), "x", num(N1)],
        "cards": [num(&c1), num(&c2), num(N1)],
    });
    let new = g4(m.h, "anki_resolve", T1, req.clone());
    close(
        &pair,
        &p3(&m.d, "anki_resolve", T1, req, None).0,
        &new,
        "anki_resolve",
    );
    assert_eq!(new["cards"][1], json!(c2), "{new}");
    // 笔记详情（可见卡、字段按 ID 排过再比，同 `tests.rs`）。
    let sort_cards = |mut v: Value| -> Value {
        for n in v["notes"].as_array_mut().unwrap() {
            if let Some(cs) = n.get_mut("c").and_then(Value::as_array_mut) {
                cs.sort_by_key(|c| pair.canon(c[1].as_str().unwrap()));
            }
            if let Some(fs) = n.get_mut("f").and_then(Value::as_array_mut) {
                fs.sort_by_key(|f| pair.canon(f[0].as_str().unwrap()));
            }
        }
        v
    };
    let req = json!({"notes": [num(N2), num(N3), num(N4), 7]});
    let new = g4(m.h, "anki_notes_info", T1, req.clone());
    assert!(new["notes"][0]["c"].is_array(), "{new}");
    close(
        &pair,
        &sort_cards(p3(&m.d, "anki_notes_info", T1, req, None).0),
        &sort_cards(new),
        "anki_notes_info",
    );
    // 绑定（迁移前没写过：两侧都是 null）、规模。
    close(
        &pair,
        &p3(&m.d, "binding_get", T1, json!({}), None).0,
        &g4(m.h, "binding_get", T1, json!({})),
        "binding_get",
    );
    let (old, new) = (
        p3(&m.d, "profile_footprint", T1, json!({}), None).0,
        g4(m.h, "profile_footprint", T1, json!({})),
    );
    assert_eq!(keys_of(&old), keys_of(&new));
    for k in ["notes", "cards", "reviews"] {
        assert_eq!(old[k], new[k], "profile_footprint.{k}: {old} vs {new}");
    }
    assert!(new["notes"].as_i64().unwrap() > 0, "{new}");
    // 同步状态：形状相同（设备行的内容随迁移换了本机身份，`writes_tests.rs` 已逐键比过）。
    let (old, new) = (
        p3(&m.d, "status", T1, json!({}), None).0,
        g4(m.h, "status", T1, json!({})),
    );
    assert_eq!(keys_of(&old), keys_of(&new), "{old}\n{new}");
    assert_eq!(new["enabled"], json!(true), "{new}");
    // 库级读。
    for q in [
        json!({"q": "user_note_count"}),
        json!({"q": "profile_merges"}),
    ] {
        let (pv, pf) = p3(&m.d, "read_lib", T1, q.clone(), None);
        let (gv, gf) = g4_files(m.h, "read_lib", T1, q.clone(), None);
        close(&pair, &pv, &gv, &q.to_string());
        assert_eq!(
            pf.iter().map(|f| &f.0).collect::<Vec<_>>(),
            gf.iter().map(|f| &f.0).collect::<Vec<_>>(),
            "{q}"
        );
    }
    // 回忆率（候选按卡排过再比，同 `tests.rs`）。
    let mut req = stats_req();
    req["now"] = json!(T1);
    req["recallDecks"] = json!([deck]);
    req["recall"] = json!({"ids": [c1], "r": [0.42]});
    let sorted = |v: &Value| -> Value {
        let mut xs = v["cards"].as_array().unwrap().clone();
        xs.sort_by_key(|x| pair.canon(x[0].as_str().unwrap_or("")));
        Value::Array(xs)
    };
    let old = p3(&m.d, "stats_recall", T1, req.clone(), None).0;
    let new = g4(m.h, "stats_recall", T1, req);
    assert_eq!(keys_of(&old), keys_of(&new));
    close(&pair, &sorted(&old), &sorted(&new), "stats_recall");
    assert!(!sorted(&new).as_array().unwrap().is_empty(), "{new}");
    // 浏览的其余子命令、AnkiConnect 查询。
    let old = browse_script(&mut |op, r| p3(&m.d, op, T1, r, None).0);
    let new = browse_script(&mut |op, r| g4(m.h, op, T1, r));
    assert_eq!(old.len(), new.len());
    for ((op, pv), (gop, gv)) in old.iter().zip(&new) {
        assert_eq!(op, gop);
        assert!(gv.get("error").is_none(), "{op}: {gv}");
        if op == "browse_query" {
            // 代号各侧自己的。
            assert_eq!(keys_of(pv), keys_of(gv), "{op}");
            continue;
        }
        close(&pair, pv, gv, op);
    }
    let rows = &new.iter().find(|(op, _)| op == "browse_rows").unwrap().1;
    assert!(!rows["s"].as_array().unwrap().is_empty(), "{rows}");
    let dupes = &new.iter().find(|(op, _)| op == "anki_dupes").unwrap().1;
    assert!(
        dupes["dup"].as_array().unwrap().contains(&json!(true)),
        "{dupes}"
    );
}

/// 第一组对拍（`apply`）之外的每一条写命令经分发器与协议 3 的同一条比：回包里各命令自己的关键键两侧相同，写完两侧的
/// 身份记录表仍然相同；每条本机写命令推进 `localRevision`（不改投影的除外）。接到相邻实现上的臂回包键或状态必然不同。
#[test]
fn every_other_wired_write_matches_protocol_3_through_the_dispatcher() {
    let m = migrated_with(true);
    let pair = pair_of(&m);
    let both = |op: &str, now: i64, extra: Value, items: Option<&[Value]>| -> (Value, Value) {
        let old = p3(&m.d, op, now, extra.clone(), items).0;
        let new = g4_files(m.h, op, now, extra, items).0;
        (old, new)
    };
    let revision = || {
        g4(m.h, "local_state", T1, json!({}))["revision"]
            .as_i64()
            .unwrap_or(0)
    };
    // 裁决：两侧各按自己的冲突 ID（同一条删除 / 修改冲突），之后两侧都没有待裁决项。
    let id_of = |v: &Value| v[0]["id"].as_str().unwrap().to_owned();
    let pid = id_of(&p3(&m.d, "conflicts", T1, json!({}), None).0);
    let gid = id_of(&g4(m.h, "conflicts", T1, json!({})));
    p3(
        &m.d,
        "resolve",
        T1,
        json!({"conflict": pid, "delete": false}),
        None,
    );
    let v = g4(
        m.h,
        "resolve",
        T1,
        json!({"conflict": gid, "delete": false}),
    );
    assert!(v["localRevision"].is_i64(), "{v}");
    assert_eq!(g4(m.h, "conflicts", T1, json!({})), json!([]));
    assert_eq!(p3(&m.d, "conflicts", T1, json!({}), None).0, json!([]));
    same_entities(&m, &pair, "resolve");
    // 按条件改字段：被拒的笔记两侧相同。
    let it = |n: &str, f: &str, x: &str, v: &str| json!({"n": n, "f": f, "x": x, "v": v});
    let items = vec![it(N3, "fa", "犬", "いぬ"), it(N2, "fa", "wrong", "x")];
    let (old, new) = both(
        "note_fields_if",
        T1,
        json!({"mode": "field", "ts": "anchored"}),
        Some(&items),
    );
    close(&pair, &old["rejected"], &new["rejected"], "note_fields_if");
    assert!(
        new["rejected"].as_array().is_some_and(|r| !r.is_empty()),
        "{new}"
    );
    same_entities(&m, &pair, "note_fields_if");
    // 改动（还原点 + 修改）。
    let r0 = revision();
    let items = vec![draft("note", N3, "f/fb", json!("dog C"))];
    let (old, new) = both(
        "change",
        T1 + 1,
        json!({"checkpoint": {"name": "change", "reason": "change_notetype"}, "ts": "anchored"}),
        Some(&items),
    );
    assert_eq!(old["landed"], new["landed"], "{old}\n{new}");
    assert!(revision() > r0);
    same_entities(&m, &pair, "change");
    // 排程：改期一张卡。
    let sched = json!({"at": T1, "utcOff": 0, "rollover": 4, "ts": "anchored",
                       "items": [{"a": "setDue", "card": card(N3, "t1"), "due": 19_800}]});
    let (old, new) = both("sched", T1 + 2, sched, None);
    assert_eq!(old["blocked"], new["blocked"], "{old}\n{new}");
    assert_eq!(new["logs"].as_array().map(Vec::len), Some(1), "{new}");
    assert_eq!(
        old["logs"].as_array().map(Vec::len),
        new["logs"].as_array().map(Vec::len)
    );
    // 删牌组：先两侧各建一个牌组、把 N3 移进去；计划两侧相同，一步走到 done。
    const LANG: &str = "0193a1b2-0000-7000-8000-0000000000d1";
    let ev = vec![
        json!({"e": {"t": "entity", "x": {"id": LANG, "p": P, "k": "deck", "d": {"createdAt": 1}}}, "note": null}),
        draft("deck", LANG, "name", json!("Lang")),
        draft("note", N3, "deck", json!(LANG)),
    ];
    let (old, new) = both("apply", T1 + 3, json!({}), Some(&ev));
    assert_eq!(old["landed"], new["landed"], "{old}\n{new}");
    let plan = json!({"deck": LANG, "deleteCards": false, "plan": true});
    let (old, new) = both("deck_delete", T1 + 4, plan, None);
    assert_eq!(
        (&old["total"], &old["done"]),
        (&new["total"], &new["done"]),
        "{old}\n{new}"
    );
    assert!(new["total"].as_i64().unwrap() > 0, "{new}");
    let step = json!({"deck": LANG, "deleteCards": false, "limit": 100, "deletedAt": T1 + 4, "ts": "anchored"});
    let (old, new) = both("deck_delete", T1 + 4, step, None);
    assert_eq!(
        (&old["done"], &new["done"]),
        (&json!(true), &json!(true)),
        "{old}\n{new}"
    );
    same_entities(&m, &pair, "deck_delete");
    // 并笔记：N2 并进 N3。
    let merge = json!({"keep": N3, "absorb": [N2], "deletedAt": T1 + 5, "ts": "anchored"});
    let (old, new) = both("merge_notes", T1 + 5, merge, None);
    close(&pair, &old["linked"], &new["linked"], "merge_notes.linked");
    close(
        &pair,
        &old["unmatched"],
        &new["unmatched"],
        "merge_notes.unmatched",
    );
    assert!(new["linked"].as_i64().is_some_and(|l| l > 0), "{new}");
    same_entities(&m, &pair, "merge_notes");
    // 彻底清除：N4。
    let (_, new) = both(
        "purge",
        T1 + 6,
        json!({"kind": "note", "entities": [N4]}),
        None,
    );
    assert_eq!(new["purged"].as_array().map(Vec::len), Some(1), "{new}");
    same_entities(&m, &pair, "purge");
    // 还原点、恢复的预览、恢复（到 `library` 历史中间的一个时刻）。
    both(
        "checkpoint",
        T1 + 7,
        json!({"name": "s1", "reason": "manual"}),
        None,
    );
    assert_eq!(
        p3(&m.d, "checkpoints", T1, json!({}), None)
            .0
            .as_array()
            .map(Vec::len),
        g4(m.h, "checkpoints", T1, json!({}))
            .as_array()
            .map(Vec::len),
    );
    let at = json!({"at": T0 + DAY + 15, "retract": true});
    let (old, new) = both("plan_restore", T1 + 8, at.clone(), None);
    assert_eq!(old, new, "plan_restore");
    assert!(keys_of(&new).contains(&"revived".to_owned()), "{new}");
    let (_, new) = both("restore", T1 + 8, at, None);
    assert!(new["changed"].is_array(), "{new}");
    same_entities(&m, &pair, "restore");
    // 信任：未知设备两侧都拒绝，什么都不写。
    let r1 = revision();
    let unknown = json!({"device": "0193a1b2-0000-7000-8000-0000000000ee", "trust": false});
    assert!(
        crate::store::legacy3::sync2_dispatch(
            &m.d.core,
            &{
                let mut r = unknown.clone();
                r["op"] = json!("trust");
                r["profile"] = json!(P);
                r["now"] = json!(T1 + 9);
                r
            },
            &mut Vec::new(),
            &mut Vec::new(),
        )
        .is_err()
    );
    let (rc, e) = call(m.h, &g4req("trust", T1 + 9, unknown), None).unwrap_err();
    assert_eq!(rc, STORE_ERROR, "{e}");
    assert!(e.contains("trust"), "{e}");
    assert_eq!(revision(), r1);
    // 存量去重、摘要自愈：新代的回包（`writes_local.rs` 文件头的换代语义）。
    assert_eq!(g4(m.h, "dedup", T1 + 9, json!({}))["done"], json!(true));
    let v = g4(m.h, "digest_heal", T1 + 9, json!({}));
    assert_eq!(v["healed"], json!(1), "{v}");
    assert!(v["rebuilt"]["cacheNotes"].is_i64(), "{v}");
    same_entities(&m, &pair, "digest_heal");
    // 本机设备信息、别的设备的补充名：形状与协议 3 相同。
    let info = json!({"model": "Pixel", "app": "3.4"});
    let (old, new) = both("device_info", T1 + 9, info, None);
    assert_eq!(keys_of(&old), keys_of(&new), "{old}\n{new}");
    assert_eq!(new["name"], json!("Pixel"), "{new}");
    let other = g4(m.h, "status", T1, json!({}))["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["self"] == json!(false))
        .map(|r| r["device"].as_str().unwrap().to_owned())
        .expect("a carried device");
    let hint = json!({"device": other, "hint": "客厅的电脑"});
    let (old, new) = both("device_hint", T1 + 9, hint, None);
    assert_eq!(
        (&old, &new),
        (&json!({"changed": true}), &json!({"changed": true}))
    );
    let row = g4(m.h, "status", T1, json!({}))["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["device"] == json!(other))
        .cloned()
        .unwrap();
    assert_eq!(row["hint"], json!("客厅的电脑"), "{row}");
}

// ---------------------------------------------------------------------- 评分预览与 C 直出入口（S1b）

/// 两列页 `[下标 i64, 文本]`（C 直出入口的输入；[profile] 给了就加一行 `[-1, profile]`）。
fn page(groups: &[Vec<String>], profile: Option<&str>) -> Vec<u8> {
    use rusqlite::types::Value as Sv;
    let mut rows: Vec<Vec<Sv>> = Vec::new();
    if let Some(p) = profile {
        rows.push(vec![Sv::Integer(-1), Sv::Text(p.to_owned())]);
    }
    for (g, cards) in groups.iter().enumerate() {
        for c in cards {
            rows.push(vec![Sv::Integer(g as i64), Sv::Text(c.clone())]);
        }
    }
    crate::store::rows::encode(2, &rows)
}

/// 经 C ABI 调一个直出入口：成功拿回字节（并释放），失败拿回 (返回码, 错误)。
fn direct_call(
    f: impl FnOnce(*mut *mut u8, *mut usize, *mut *mut std::ffi::c_char) -> i32,
) -> Result<Vec<u8>, (i32, String)> {
    let (mut out, mut out_len, mut err) = (null_mut(), 0usize, null_mut());
    let rc = f(&mut out, &mut out_len, &mut err);
    if rc != 0 {
        return Err((rc, take_error(err)));
    }
    let b = unsafe { std::slice::from_raw_parts(out, out_len) }.to_vec();
    crate::ffsrs_free_bytes(out, out_len);
    Ok(b)
}

/// `ffsrs_store_history_states` / `ffsrs_store_stat_projection`（[stat] 选后者）。
fn hist_abi(
    h: *mut SrsCoreHandle,
    groups: &[Vec<String>],
    profile: Option<&str>,
    stat: bool,
) -> Result<Vec<u8>, (i32, String)> {
    let pg = page(groups, profile);
    direct_call(|o, ol, e| {
        if stat {
            crate::store::ffi::ffsrs_store_stat_projection(
                h,
                pg.as_ptr(),
                pg.len(),
                groups.len(),
                o,
                ol,
                e,
            )
        } else {
            crate::store::ffi::ffsrs_store_history_states(
                h,
                pg.as_ptr(),
                pg.len(),
                groups.len(),
                o,
                ol,
                e,
            )
        }
    })
}

/// 一个 `(page, args)` 形的直出入口：0 = optimizer_items，1 = calibration_items，2 = rwkv_rows，3 = rwkv_log_tail。
fn cmd_abi(
    h: *mut SrsCoreHandle,
    which: u8,
    groups: &[Vec<String>],
    profile: Option<&str>,
    args: &[i64],
) -> Result<Vec<u8>, (i32, String)> {
    let pg = page(groups, profile);
    direct_call(|o, ol, e| {
        type Entry = extern "C" fn(
            *const SrsCoreHandle,
            *const u8,
            usize,
            *const i64,
            usize,
            *mut *mut u8,
            *mut usize,
            *mut *mut std::ffi::c_char,
        ) -> i32;
        let f: Entry = match which {
            0 => crate::store::ffi::ffsrs_store_optimizer_items,
            1 => crate::store::ffi::ffsrs_store_calibration_items,
            2 => crate::store::ffi::ffsrs_store_rwkv_rows,
            _ => crate::store::ffi::ffsrs_store_rwkv_log_tail,
        };
        f(
            h,
            pg.as_ptr(),
            pg.len(),
            args.as_ptr(),
            args.len(),
            o,
            ol,
            e,
        )
    })
}

/// 第 [k] 个 8 字节字置零（指纹里的「最大序号」：两代各是各的游标，`cmd/training.rs` 文件头）。
fn zero_word(mut b: Vec<u8>, k: usize) -> Vec<u8> {
    b[8 * k..8 * k + 8].fill(0);
    b
}

fn word(b: &[u8], k: usize) -> i64 {
    i64::from_le_bytes(b[8 * k..8 * k + 8].try_into().unwrap())
}

/// [library] 再加几次复习（后继卡 c2 继承 c1 的历史、N2 t1 复习两次、N3 t2 一条学习步），训练集与重放有东西可比。
fn with_reviews(d: &Device) {
    let (c2, n2, n3b) = (card(N1, "t2"), card(N2, "t1"), card(N3, "t2"));
    let at = |days: i64| T0 + days * DAY;
    d.apply(
        at(1) + 1,
        vec![review("s1b-q1", &c2, at(1) + 1, 3, "review")],
    );
    d.apply(
        at(1) + 2,
        vec![
            review("s1b-q2", &n2, at(1) + 2, 3, "review"),
            review("s1b-q3", &n3b, at(1) + 2, 1, "learn"),
        ],
    );
    d.apply(
        at(1) + 3,
        vec![review("s1b-q4", &n2, at(1) + 3, 4, "review")],
    );
}

/// 迁移出来的库经 C ABI 的直出入口（页里不带 profile 行 = Dart 现在的调法；带 = G7-5 可以补的调法）与迁移前的协议 3 库上
/// 同一份计算（`SrsCore` 的同名方法，换代前 C 入口调的就是它们）逐字节相同；RWKV 指纹里的最大序号两代各是各的游标，
/// 比之前置零。评分预览经 `ffsrs_store_sync2` 与协议 3 的 `preview` 比。
#[test]
fn preview_and_training_entries_through_the_c_abi_match_protocol_3() {
    use crate::projection::{Alg, Day};
    let m = migrated_prepared(false, &with_reviews);
    let pair = pair_of(&m);
    let groups: Vec<Vec<String>> = vec![
        vec![card(N1, "t2"), card(N1, "t1")],
        vec![card(N1, "t1")],
        vec![card(N2, "t1")],
        vec![card(N3, "t1")],
        vec![card(N3, "t2")],
        vec!["missing".to_owned()],
        vec![],
    ];
    let day = Day {
        utc_offset_min: 0,
        rollover_hour: 4,
    };
    for profile in [None, Some(P)] {
        let old = m.d.core.history_states(&groups).unwrap();
        assert_eq!(
            hist_abi(m.h, &groups, profile, false).unwrap(),
            old,
            "{profile:?}"
        );
        let old = m.d.core.stat_projection(&groups).unwrap();
        let new = hist_abi(m.h, &groups, profile, true).unwrap();
        assert_eq!(new, old, "{profile:?}");
        assert!(crate::store::rows::decode(&new).unwrap().1.len() >= 4);
    }
    // 训练集与 RWKV 逐卡：调用方只给卡自己。
    let seeds: Vec<Vec<String>> = groups
        .iter()
        .filter(|g| !g.is_empty())
        .map(|g| vec![g[0].clone()])
        .collect();
    let n = seeds.len() as i64;
    let card_ids: Vec<i64> = (1..=n).collect();
    let rwkv_ids: Vec<i64> = (1..=4 * n).collect();
    for (alg, code) in [(Alg::Fsrs6, 0), (Alg::Fsrs7, 1)] {
        let mut args = vec![n, code, 0, 4];
        args.extend(&card_ids);
        let old =
            m.d.core
                .optimizer_items(&seeds, &card_ids, alg, &day)
                .unwrap();
        let new = cmd_abi(m.h, 0, &seeds, None, &args).unwrap();
        assert_eq!(new, old, "optimizer {alg:?}");
        assert!(word(&new, 2) > 0, "has items");
        let old =
            m.d.core
                .calibration_items(&seeds, &card_ids, alg, &day)
                .unwrap();
        assert_eq!(
            cmd_abi(m.h, 1, &seeds, Some(P), &args).unwrap(),
            old,
            "calibration {alg:?}"
        );
    }
    let mut args = vec![n, 0, 0, 4, 0];
    args.extend(&rwkv_ids);
    let old = m.d.core.rwkv_cards(&seeds, &rwkv_ids, &day).unwrap();
    assert_eq!(
        cmd_abi(m.h, 2, &seeds, None, &args).unwrap(),
        old,
        "rwkv cards"
    );
    // RWKV 回放（全量）与指纹 / 尾巴：页里要有 profile 行（协议 3 同样要）。
    let none = crate::history::NONE_I64;
    let mut args = vec![n, 1, 0, 4, 0, none, none];
    args.extend(&rwkv_ids);
    let old =
        m.d.core
            .rwkv_replay(P, &seeds, &rwkv_ids, &day, 0, Default::default())
            .unwrap();
    let new = cmd_abi(m.h, 2, &seeds, Some(P), &args).unwrap();
    assert_eq!(zero_word(new.clone(), 1), zero_word(old, 1), "rwkv replay");
    assert!(
        word(&new, 1) > crate::store::gen4::derive::SEQ_BASE,
        "the cursor is the arrival number"
    );
    let (rc, e) = cmd_abi(m.h, 2, &seeds, None, &args).unwrap_err();
    assert_eq!((rc, e.as_str()), (STORE_ERROR, "missing profile"));
    for (with_rows, incremental) in [(1, 0), (0, 0), (1, 1)] {
        let old =
            m.d.core
                .rwkv_log_tail(P, 0, with_rows == 1, incremental == 1)
                .unwrap();
        let new = cmd_abi(m.h, 3, &[], Some(P), &[0, with_rows, incremental]).unwrap();
        assert_eq!(
            zero_word(new, 1),
            zero_word(old, 1),
            "log tail {with_rows} {incremental}"
        );
    }
    // 没绑定的 profile：明确报错（同 sync2 命令）。
    let (_, e) = hist_abi(
        m.h,
        &groups,
        Some("0193a1b2-0000-7000-8000-00000000dead"),
        false,
    )
    .unwrap_err();
    assert!(e.contains("has no collection"), "{e}");

    // 评分预览：有日志的卡、继承历史的后继卡、新卡（给笔记 / 不给）、不存在的卡。
    for req in [
        json!({"card": card(N1, "t2")}),
        json!({"card": card(N2, "t1"), "note": N2}),
        json!({"card": card(N4, "t1")}),
        json!({"card": card(N4, "t2"), "note": N4}),
        json!({"card": "missing"}),
    ] {
        let mut r = req.clone();
        r["utcOff"] = json!(0);
        r["rollover"] = json!(4);
        let now = T0 + 4 * DAY;
        let new = g4(m.h, "preview", now, r.clone());
        close(
            &pair,
            &p3(&m.d, "preview", now, r, None).0,
            &new,
            &format!("preview {req}"),
        );
    }
}

/// 不带 profile 行的直出入口按卡认集合（`dispatch.rs` `direct_col`）：文件里两个集合时，卡（任何别名成员）只在一个集合里
/// 有历史就读那个；哪儿都没有 = 「卡不存在」的形状；两个集合里都有 = 明确报错，带 profile 行就各读各的。
#[test]
fn direct_entries_find_the_collection_by_their_cards() {
    use super::training::history_states;
    const OTHER: &str = "0193a1b2-0000-7000-8000-0000000000f7";
    let dir = tempdir::new("s1bdirect");
    let (w, a) = {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        let a = c.write(|t| t.bind(P, &id(0xc0), "dir")).unwrap();
        c.write(|t| t.bind(OTHER, &id(0xc1), "dir2")).unwrap();
        let w = c.write(|t| Ok(tests_class::land(t, a))).unwrap();
        c.close();
        (w, a)
    };
    let expect = |col: i64, groups: &[Vec<String>]| -> Vec<u8> {
        let c = G4Core::open(&dir.0, OpenMode::Secondary).unwrap();
        let out = c.read(|t| history_states(t, col, groups)).unwrap();
        c.close();
        out
    };
    let member = vec![vec![w.card[1].text()]];
    let missing = vec![vec!["missing".to_owned()]];
    let want = expect(a, &member);
    assert_ne!(want, expect(a, &missing), "the class has a review");
    let h = open(&dir.0, 0).unwrap();
    assert_eq!(hist_abi(h, &member, None, false).unwrap(), want);
    assert_eq!(
        hist_abi(h, &missing, None, false).unwrap(),
        expect(a, &missing)
    );
    // 别的 profile 的集合里没有这张卡：按 profile 行读就是不存在的形状。
    assert_eq!(
        hist_abi(h, &member, Some(OTHER), false).unwrap(),
        expect(a, &missing)
    );
    ffsrs_store_close(h);
    // 同一张卡在另一个集合里也有历史：不带 profile 分不清，报错；带 profile 各读各的。
    let b = {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        let b = c.read(|t| Ok(t.binding_of(OTHER)?.unwrap().col)).unwrap();
        c.write(|t| Ok(tests_class::land(t, b))).unwrap();
        c.close();
        b
    };
    let h = open(&dir.0, 0).unwrap();
    let (rc, e) = hist_abi(h, &member, None, false).unwrap_err();
    assert_eq!(rc, STORE_ERROR);
    assert!(e.contains("2 collections"), "{e}");
    assert_eq!(hist_abi(h, &member, Some(P), false).unwrap(), want);
    assert_eq!(
        hist_abi(h, &member, Some(OTHER), false).unwrap(),
        expect(b, &member)
    );
    ffsrs_store_close(h);
}

/// 按卡认集合的语句数与请求的卡数无关：一条集合列表 + 每个集合一条（`HOLDS_ANY_CARD_SQL`）。两个集合、卡只在一个里有
/// 历史、请求带上一大批哪儿都没有历史的卡（Dart 的训练集请求是整个 profile 的卡）：以前逐卡点查，无关集合要把每张卡归一、
/// 取成员、逐个成员查一遍（N+1）。别名类：请求里的是类里的成员 ID（不是规范 ID），照样认到它的集合。
#[test]
fn direct_col_runs_one_statement_per_collection() {
    use super::browse_tests::profile;
    use crate::store::gen4::dispatch::{HOLDS_ANY_CARD_SQL, direct_col};
    const OTHER: &str = "0193a1b2-0000-7000-8000-0000000000f7";
    let dir = tempdir::new("s1bdirectn");
    let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
    let a = c.write(|t| t.bind(P, &id(0xc0), "dir")).unwrap();
    let b = c.write(|t| t.bind(OTHER, &id(0xc1), "dir2")).unwrap();
    let w = c.write(|t| Ok(tests_class::land(t, a))).unwrap();
    assert_ne!(w.card[1], w.card[0], "a member, not the canonical id");
    let mut groups: Vec<Vec<String>> = (0..60u32)
        .map(|i| vec![format!("0193a1b2-0000-7000-8000-0000{i:08x}")])
        .collect();
    groups.push(vec![w.card[1].text()]);
    let mut found = None;
    let ran = c
        .read(|t| {
            Ok(profile(t, || {
                found = Some(direct_col(t, None, &groups));
            }))
        })
        .unwrap();
    assert_eq!(found.unwrap().unwrap(), a);
    let holds = ran.iter().filter(|r| r.sql == HOLDS_ANY_CARD_SQL).count();
    assert_eq!(holds, 2, "one per collection");
    assert_eq!(ran.len(), 3, "collections + one per collection: {ran:#?}");
    // 只有一批没历史的卡：两个集合都对不上 = 空集合号；同一个类在 b 里也有历史就分不清，报错。
    let none: Vec<Vec<String>> = groups[..60].to_vec();
    assert_eq!(c.read(|t| direct_col(t, None, &none)).unwrap(), 0);
    c.write(|t| Ok(tests_class::land(t, b))).unwrap();
    let e = c.read(|t| direct_col(t, None, &groups)).unwrap_err();
    assert!(e.contains("2 collections"), "{e}");
    c.close();
}

// ---------------------------------------------------------------------- 媒体回收（S1b）

const MGC_NT: &str = "0193a1b2-0000-7000-8000-00000000f0a1";
const MGC_NT_DEAD: &str = "0193a1b2-0000-7000-8000-00000000f0a2";
const MGC_LIVE: &str = "0193a1b2-0000-7000-8000-00000000f0b1";
const MGC_RECENT: &str = "0193a1b2-0000-7000-8000-00000000f0b2";
const MGC_OLD: &str = "0193a1b2-0000-7000-8000-00000000f0b3";
/// 媒体场景的写入时刻。
const MT: i64 = T0 + DAY;

/// 协议 3 `store/media_gc.rs` 测试的同一个场景：一个存活的笔记类型（模板与 CSS 里有引用，含下划线开头的静态文件）、
/// 一个已删除的笔记类型，一条存活笔记、一条删除 1 天的、一条删除 100 天的。
fn with_media(d: &Device) {
    let nt = |id: &str, front: &str, css: &str| -> Vec<Value> {
        vec![
            json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            edit("notetype", id, "fieldDef/a", json!({"name": "A", "ord": 0})),
            edit(
                "notetype",
                id,
                "tmplDef/t1",
                json!({"name": "t1", "ord": 0, "front": front}),
            ),
            edit(
                "notetype",
                id,
                "tmplDef/t2",
                json!({"name": "t2", "ord": 1, "front": "{{A}}<img src=\"gone-template.png\">", "deleted": true}),
            ),
            edit("notetype", id, "css", json!(css)),
        ]
    };
    let note = |id: &str, front: &str| -> Vec<Value> {
        vec![
            json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": MGC_NT}}}),
            edit("note", id, "f/a", json!(front)),
        ]
    };
    let mut events = nt(
        MGC_NT,
        "{{A}}<img src=\"tpl.png\">[sound:tpl.mp3]",
        ".card { font-family: f; } @font-face { src: url(\"_font.woff\"); }",
    );
    events.extend(nt(
        MGC_NT_DEAD,
        "{{A}}<script src=\"_dead.js\"></script>",
        "",
    ));
    events.push(edit("notetype", MGC_NT_DEAD, "deleted", json!(MT)));
    events.extend(note(
        MGC_LIVE,
        "<img src=\"live.png\"><img src=\"c:colon.png\"><img src=\"sub/dir.png\">",
    ));
    events.extend(note(
        MGC_RECENT,
        "[sound:recent.mp3]<img src=\"Shared.PNG\">",
    ));
    events.extend(note(
        MGC_OLD,
        "<img src=\"old.png\"><img src=\"shared.png\">",
    ));
    events.push(edit("note", MGC_RECENT, "deleted", json!(MT - DAY)));
    events.push(edit("note", MGC_OLD, "deleted", json!(MT - 100 * DAY)));
    d.apply(MT, events);
}

/// 媒体回收的两条写只改本机状态行（待回收集合），不推进写入代数（`G4Core::write_local`）：统计原料缓存照样命中，后台
/// 分批回收不会让下一次统计整份重算。状态确实写下了（下一次 queue 读得到上一次并进去的）。
#[test]
fn media_gc_writes_keep_the_write_generation() {
    use crate::store::gen4::dispatch::stats_cached;
    use std::sync::atomic::Ordering;
    let m = migrated_prepared(false, &with_media);
    let core = crate::store::ffi::core_of(m.h).unwrap();
    let sreq = stats_req();
    let before = g4(m.h, "stats_rows", MT, sreq.clone());
    let w0 = stats_cached(&core).expect("stats cached");
    assert_eq!(core.writes.load(Ordering::SeqCst), w0);
    let q = g4(
        m.h,
        "media_gc_queue",
        MT,
        json!({"expiredBefore": MT - 90 * DAY, "names": ["x.png"]}),
    );
    assert_eq!(names_of(&q["pending"]), ["old.png", "shared.png", "x.png"]);
    let q = g4(m.h, "media_gc_queue", MT, json!({}));
    assert_eq!(names_of(&q["pending"]), ["old.png", "shared.png", "x.png"]);
    let d = tempdir::new("s1bmgc-gen");
    std::fs::write(d.0.join("x.png"), b"x").unwrap();
    let r = g4(
        m.h,
        "media_gc_collect",
        MT,
        json!({"root": d.0.to_str().unwrap(), "aliveAfter": MT - 90 * DAY, "freshAfter": i64::MAX}),
    );
    assert!(!d.0.join("x.png").exists(), "{r}");
    assert_eq!(core.writes.load(Ordering::SeqCst), w0, "local-only writes");
    assert_eq!(g4(m.h, "stats_rows", MT, sreq), before);
    assert_eq!(stats_cached(&core), Some(w0));
}

fn names_of(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap_or_else(|| panic!("{v}"))
        .iter()
        .map(|n| n.as_str().unwrap().to_owned())
        .collect()
}

/// 媒体回收三条命令经分发器与迁移前的协议 3 库逐条相同：存活引用（两个保留期）、并候选（过期的已删笔记、笔记此刻的
/// 引用、直接给的名字）、回收（两侧各一个媒体目录放同样的文件：删掉的、留下的、集合里剩下的都相同，分批游标相同）。
#[test]
fn media_gc_through_the_dispatcher_matches_protocol_3() {
    let m = migrated_prepared(false, &with_media);
    let both = |op: &str, extra: Value| -> (Value, Value) {
        let old = p3(&m.d, op, MT, extra.clone(), None).0;
        let new = g4(m.h, op, MT, extra);
        (old, new)
    };
    for after in [MT - 90 * DAY, MT - 200 * DAY] {
        let (old, new) = both("media_live_refs", json!({"aliveAfter": after}));
        assert_eq!(new, old, "aliveAfter {after}");
    }
    let (_, refs) = both("media_live_refs", json!({"aliveAfter": MT - 90 * DAY}));
    for n in [
        "neko.png",
        "tpl.png",
        "_font.woff",
        "_dead.js",
        "Shared.PNG",
        "live.png",
    ] {
        assert!(
            names_of(&refs["refs"]).contains(&n.to_owned()),
            "{n}: {refs}"
        );
    }
    assert_eq!(both("media_gc_queue", json!({})).1, json!({"pending": []}));
    let (old, new) = both("media_gc_queue", json!({"expiredBefore": MT - 90 * DAY}));
    assert_eq!(new, old);
    assert_eq!(names_of(&new["pending"]), ["old.png", "shared.png"]);
    let (old, new) = both(
        "media_gc_queue",
        json!({"notes": [MGC_LIVE, "0193a1b2-0000-7000-8000-00000000f0bf"], "names": ["x.png", "g1.png", "g2.png"]}),
    );
    assert_eq!(new, old);
    // 待回收集合在新代本机状态行里（同协议 3 的键名），读本机状态行的回包不变。
    let row = g4(m.h, "local_state", MT, json!({}));
    assert!(row.get("mediaGc").is_none(), "{row}");
    // 回收：两侧各一个媒体目录。
    let dirs = [tempdir::new("s1bmgc-p3"), tempdir::new("s1bmgc-g4")];
    for d in &dirs {
        for n in [
            "old.png",
            "shared.png",
            "live.png",
            "x.png",
            "g1.png",
            "g2.png",
            "fresh.png",
        ] {
            std::fs::write(d.0.join(n), b"x").unwrap();
        }
    }
    let collect = |i: usize, extra: Value| -> Value {
        let mut req = json!({
            "root": dirs[i].0.to_str().unwrap(), "aliveAfter": MT - 90 * DAY, "freshAfter": i64::MAX,
        });
        for (k, v) in extra.as_object().unwrap() {
            req[k] = v.clone();
        }
        if i == 0 {
            p3(&m.d, "media_gc_collect", MT, req, None).0
        } else {
            g4(m.h, "media_gc_collect", MT, req)
        }
    };
    let mut after: Option<String> = None;
    loop {
        let extra = match &after {
            Some(a) => json!({"limit": 3, "after": a}),
            None => json!({"limit": 3}),
        };
        let (old, new) = (collect(0, extra.clone()), collect(1, extra));
        assert_eq!(new, old, "batch after {after:?}");
        after = new["next"].as_str().map(str::to_owned);
        if after.is_none() {
            break;
        }
    }
    let left = |d: &tempdir::Dir| -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(&d.0)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    };
    assert_eq!(left(&dirs[1]), left(&dirs[0]));
    // 只有没人引用的删了：shared.png 被删除未满保留期的笔记引用着（大小写不同算同一个文件），live.png 被存活笔记引用。
    assert_eq!(left(&dirs[1]), ["fresh.png", "live.png", "shared.png"]);
    let (old, new) = both("media_gc_queue", json!({}));
    assert_eq!(new, old);
    assert_eq!(new, json!({"pending": []}));
}

/// 媒体回收按类（只有新代才有）：带盐成员上写的字段引用经规范笔记的缓存行算存活；按成员 ID 并候选取的是整个类那一行。
#[test]
fn media_gc_reads_references_through_the_alias_class() {
    use crate::store::gen4::derive::Index;
    use crate::store::gen4::derive::tests::{native, op};
    use crate::sync2::op::EntKind;
    let dir = tempdir::new("s1bmgc-class");
    let media = tempdir::new("s1bmgc-class-media");
    let w = {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        let col = c.write(|t| t.bind(P, &id(0xc0), "dir")).unwrap();
        let w = c.write(|t| Ok(tests_class::land(t, col))).unwrap();
        // 见过两份并发修改之后，在第二份带盐成员上改字段：它压过两份，成为类的现值。
        let (dev, last) = tests_class::base_seen(&w);
        let body = tests_class::set(
            EntKind::Note,
            tests_class::u(w.note[1]),
            &format!("f/{}", w.field[1].text()),
            json!("<img src=\"salted.png\">"),
        );
        c.write(|t| {
            let mut ix = Index::new(t, col);
            native(
                t,
                &mut ix,
                col,
                &op(0xd1, 1, 500, &[(dev, last), (0xb1, 1), (0xb2, 1)], &body),
            );
            ix.settle()?;
            Ok(())
        })
        .unwrap();
        c.close();
        w
    };
    let h = open(&dir.0, 0).unwrap();
    let refs = g4(h, "media_live_refs", T1, json!({"aliveAfter": 0}));
    assert_eq!(names_of(&refs["refs"]), ["salted.png"], "{refs}");
    // 按另一份成员（不是写字段的那份）点名笔记：读到的是整个类的那一行。
    let q = g4(
        h,
        "media_gc_queue",
        T1,
        json!({"notes": [w.note[0].text()], "names": ["orphan.png"]}),
    );
    assert_eq!(names_of(&q["pending"]), ["orphan.png", "salted.png"]);
    for n in ["orphan.png", "salted.png"] {
        std::fs::write(media.0.join(n), b"x").unwrap();
    }
    let r = g4(
        h,
        "media_gc_collect",
        T1,
        json!({"root": media.0.to_str().unwrap(), "aliveAfter": 0, "freshAfter": i64::MAX}),
    );
    assert_eq!(r, json!({"deleted": 1, "next": null}));
    assert!(media.0.join("salted.png").exists());
    assert!(!media.0.join("orphan.png").exists());
    ffsrs_store_close(h);
}

/// 存活引用读不全时不删（`cmd/media_gc.rs` 文件头「读不全就不删」）：profile 没绑定集合、或集合没设缓存配置（缓存层没
/// 物化，`notes` 一行都没有）时回收回 `deferred`、文件与集合原样；`media_live_refs` 明确报错；并候选照常收名字。
#[test]
fn media_gc_defers_while_live_references_cannot_be_read() {
    let dir = tempdir::new("s1bmgc-defer");
    let media = tempdir::new("s1bmgc-defer-media");
    std::fs::write(media.0.join("a.png"), b"x").unwrap();
    {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        c.close();
    }
    let collect = |h: *mut SrsCoreHandle| -> Value {
        g4(
            h,
            "media_gc_collect",
            T1,
            json!({"root": media.0.to_str().unwrap(), "aliveAfter": 0, "freshAfter": i64::MAX}),
        )
    };
    let deferred = json!({"deleted": 0, "next": null, "deferred": true});
    let h = open(&dir.0, 0).unwrap();
    // 没绑定：并候选（只有名字）照常；回收不删。
    let q = g4(
        h,
        "media_gc_queue",
        T1,
        json!({"names": ["a.png"], "expiredBefore": T1}),
    );
    assert_eq!(q, json!({"pending": ["a.png"]}));
    assert_eq!(collect(h), deferred);
    let (_, e) = call(
        h,
        &g4req("media_live_refs", T1, json!({"aliveAfter": 0})),
        None,
    )
    .unwrap_err();
    assert!(e.contains("cannot be read"), "{e}");
    ffsrs_store_close(h);
    // 绑定了、没设缓存配置：同样不删。
    {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        c.write(|t| t.bind(P, &id(0xc0), "dir")).unwrap();
        c.close();
    }
    let h = open(&dir.0, 0).unwrap();
    assert_eq!(collect(h), deferred);
    assert!(media.0.join("a.png").exists());
    assert_eq!(
        g4(h, "media_gc_queue", T1, json!({})),
        json!({"pending": ["a.png"]})
    );
    // 设了缓存配置（缓存层物化，这个集合没有笔记）：没人引用，删掉、移出集合。
    g4(h, "cache_config_set", T1, json!({"caches": cfg()}));
    assert_eq!(collect(h), json!({"deleted": 1, "next": null}));
    assert!(!media.0.join("a.png").exists());
    assert_eq!(
        g4(h, "media_gc_queue", T1, json!({})),
        json!({"pending": []})
    );
    ffsrs_store_close(h);
}

/// S1b 的新语句：按卡认集合、媒体回收的读都按键走，不扫表（集合列表除外：`collections` 只有绑定数那么几行，按主键序
/// 读，不排序）。
#[test]
fn s1b_statements_use_their_keys() {
    use crate::store::gen4::cmd::media_gc::{EXPIRED_SQL, LIVE_SQL, NOTE_REFS_SQL, TYPES_SQL};
    use crate::store::gen4::dispatch::{COLLECTIONS_SQL, HOLDS_ANY_CARD_SQL};
    let m = migrated();
    let c = Connection::open_with_flags(
        m.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    let plan = |q: &str| -> Vec<String> {
        c.prepare(&format!("EXPLAIN QUERY PLAN {q}"))
            .unwrap()
            .raw_query()
            .mapped(|r| r.get::<_, String>(3))
            .collect::<Result<_, _>>()
            .unwrap()
    };
    // `SCAN CONSTANT ROW` 是 `SELECT EXISTS(…) OR EXISTS(…)` 外层那一行常量，不是扫表。
    let no_scan = |q: &str, steps: &[String]| {
        assert!(
            !steps
                .iter()
                .any(|s| (s.starts_with("SCAN") && s != "SCAN CONSTANT ROW")
                    || s.contains("TEMP B-TREE")),
            "{q}: {steps:?}"
        );
    };
    let steps = plan(HOLDS_ANY_CARD_SQL);
    // 能扫的只有请求的卡列表本身（`json_each` 与按它展开的别名类协程 `cls`）；真表一律按键，不建临时 B 树（别名类用
    // `UNION ALL`：规范 ID 与 `canon != id` 的成员不相交，不必去重）。
    assert!(
        !steps.iter().any(|s| (s.starts_with("SCAN")
            && s != "SCAN CONSTANT ROW"
            && s != "SCAN cls"
            && !s.starts_with("SCAN json_each VIRTUAL TABLE"))
            || s.contains("TEMP B-TREE")),
        "{HOLDS_ANY_CARD_SQL}: {steps:?}"
    );
    for want in [
        "SEARCH a USING PRIMARY KEY (col=? AND id=?)",
        "SEARCH a USING COVERING INDEX alias_canon (col=? AND canon=?)",
        "SEARCH log_ix USING PRIMARY KEY (col=? AND card=?)",
        "SEARCH reg_ix USING PRIMARY KEY (col=? AND ekind=? AND ent=?)",
    ] {
        assert!(steps.iter().any(|s| s == want), "{want}: {steps:?}");
    }
    let steps = plan(NOTE_REFS_SQL);
    assert_eq!(
        steps,
        ["SEARCH notes USING PRIMARY KEY (col=? AND id=?)"],
        "{NOTE_REFS_SQL}"
    );
    // 这两条本来就要读这个集合的全部（已删 / 存活）笔记：只要求按 `col` 圈出这个集合（不扫别的集合、不排序）。
    for q in [EXPIRED_SQL, LIVE_SQL] {
        let steps = plan(q);
        assert_eq!(steps.len(), 1, "{q}: {steps:?}");
        assert!(
            steps[0].starts_with("SEARCH notes USING ") && steps[0].ends_with("(col=?)"),
            "{q}: {steps:?}"
        );
    }
    let steps = plan(TYPES_SQL);
    no_scan(TYPES_SQL, &steps);
    assert!(
        steps
            .iter()
            .any(|s| s.contains("INDEX ent_kind (col=? AND kind=?)")),
        "{TYPES_SQL}: {steps:?}"
    );
    let steps = plan(COLLECTIONS_SQL);
    assert!(
        !steps.iter().any(|s| s.contains("TEMP B-TREE")),
        "{steps:?}"
    );
}
