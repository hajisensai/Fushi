//! G8-7 同步一轮（`cmd/sync.rs`）的端到端测试：一律经 C ABI（`ffsrs_store_open_mode` / `ffsrs_store_sync2`，装置在
//! `dispatch_tests.rs`），位置是内存里的一张「路径 → 字节」表，[round] 按 Dart `srs_sync2_round.dart` 的顺序调命令。
//!
//! - 两台全新设备经同一个文件夹位置互相同步：写 → 发 → 收 → 两边派生层逐行相同；派生层增量 == 整个重建。小段、小批
//!   （多段多批续传）同样收敛；第二轮什么都没变时不重写 head。
//! - 加密位置：段按位置钥匙封装（`sealed_at_location`），本位置的 head 带 `seal`、`plan` 认出加密；不带钥匙收不进。
//!   `location_seal` / `location_sealed` 的回包形状同协议 3。
//! - 位置上丢了已传的段：下一轮退水位重传。清除已发布的操作：已传的段重切重传、旧段被 `obsolete` 删掉，对端跟着清除。
//! - 位置的根：新集合预先立围栏与墓碑 head；存量协议 3 的 `v3/meta.json` 被改写成围栏、媒体根取 `v3`；新根 meta
//!   要更新的读者 / 别的集合时停下、什么都不写。
//! - 停用：状态 `retired`；对端写了更新的 head 自动取消。
//! - 换身份：主动换（`rotate`）与复制目录造成的分叉（收段比链 → `ingest_finish` 换身份），之后照样收敛。
//! - 已删 / 未接的命令报各自的原因；新语句的查询计划。

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::ptr::{null, null_mut};

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::dispatch_tests::{T1, cfg, g4, g4req, open};
use super::sync::{LOC_HEAD_SEQ_SQL, LOC_STATE_SQL, VOIDS_SQL, sealed_at_location};
use super::tests::{N1, N2, N3};
use crate::gen4::head::Head4;
use crate::gen4::location::{V4File, parse_v4_path};
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close, ffsrs_store_sync2};
use crate::store::gen4::derive::Index;
use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, dump};
use crate::store::gen4::files::{GEN4_FILE, OpenMode};
use crate::store::gen4::kernel::{G4Core, REMOVED, UNWIRED};
use crate::store::gen4::sync_state::{RETIRED_RECORD_UNREADABLE, RETIRED_SQL};
use crate::store::gen4::truth::Truth;
use crate::store::sync2::collection_of;
use crate::store::sync2::tests::{P, edit, tempdir};
use crate::sync2::id::Id;
use crate::sync2::keys::DeviceKey;
use crate::sync2::vv::OpId;

type Loc = BTreeMap<String, Vec<u8>>;
type Files = Vec<(String, Vec<u8>)>;

const KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";

/// 经 C ABI 发一条命令，字节块原样带上（`[条数][长度][字节]…`）。
fn raw(h: *mut SrsCoreHandle, req: &Value, blobs: &[Vec<u8>]) -> Result<(Value, Files), String> {
    let text = req.to_string();
    let mut framed = Vec::new();
    if !blobs.is_empty() {
        framed.extend_from_slice(&(blobs.len() as u32).to_le_bytes());
        for b in blobs {
            framed.extend_from_slice(&(b.len() as u32).to_le_bytes());
            framed.extend_from_slice(b);
        }
    }
    let (mut out, mut out_len, mut err) = (null_mut(), 0usize, null_mut());
    let rc = ffsrs_store_sync2(
        h,
        text.as_ptr(),
        text.len(),
        if framed.is_empty() {
            null()
        } else {
            framed.as_ptr()
        },
        framed.len(),
        &mut out,
        &mut out_len,
        &mut err,
    );
    if rc != 0 {
        let s = unsafe { std::ffi::CStr::from_ptr(err) }
            .to_string_lossy()
            .into_owned();
        crate::ffsrs_free_string(err);
        return Err(s);
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

fn cmd(
    h: *mut SrsCoreHandle,
    op: &str,
    now: i64,
    extra: Value,
    blobs: &[Vec<u8>],
) -> (Value, Files) {
    let req = g4req(op, now, extra);
    raw(h, &req, blobs).unwrap_or_else(|e| panic!("{req}: {e}"))
}

/// 一台全新设备：建身份、注册缓存配置。
struct Dev {
    dir: tempdir::Dir,
    h: *mut SrsCoreHandle,
}

impl Dev {
    fn new(tag: &str) -> Dev {
        let dir = tempdir::new(tag);
        let h = open(&dir.0, 0).unwrap();
        g4(h, "identity", T1, json!({}));
        g4(h, "cache_config_set", T1, json!({"caches": cfg()}));
        Dev { dir, h }
    }

    /// 同一个库目录的一份拷贝（关着拷，模拟「复制了整个数据目录」）。
    fn copy(&mut self, tag: &str) -> Dev {
        ffsrs_store_close(self.h);
        let dir = tempdir::new(tag);
        copy_dir(&self.dir.0, &dir.0);
        self.h = open(&self.dir.0, 0).unwrap();
        let h = open(&dir.0, 0).unwrap();
        Dev { dir, h }
    }

    fn device(&self) -> String {
        g4(self.h, "identity", T1, json!({}))["device"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    fn write(&self, now: i64, note: &str, v: &str) {
        let items = vec![json!({"e": edit("note", note, "f/fa", json!(v)), "note": note})];
        let blob = Value::Array(items).to_string().into_bytes();
        let (v, _) = cmd(self.h, "apply", now, json!({}), &[blob]);
        assert_eq!(v["landed"], json!([true]), "{v}");
    }

    fn field(&self, note: &str) -> Option<Value> {
        let hist = g4(
            self.h,
            "history",
            T1,
            json!({"kind": "note", "entity": note}),
        );
        hist.as_array()
            .unwrap()
            .iter()
            .filter_map(|e| e.get("value").cloned())
            .last()
    }

    /// 关掉句柄，在库上直接跑 [f]（真相层 API），再打开。
    fn direct<T>(&mut self, f: impl FnOnce(&Truth<'_>, i64) -> Result<T, String>) -> T {
        ffsrs_store_close(self.h);
        let out = {
            let c = G4Core::open(&self.dir.0, OpenMode::Primary).unwrap();
            let out = c
                .write(|t| {
                    let col = t.binding_of(P)?.unwrap().col;
                    f(t, col)
                })
                .unwrap();
            c.close();
            out
        };
        self.h = open(&self.dir.0, 0).unwrap();
        out
    }

    /// 派生层：增量维护的与整个重建的逐行相同（[assert_rebuild_is_identity]），回语义摘要（head 的 `digest`，跨设备
    /// 可比；派生表逐行含本机设备号 `k`，不能跨设备比）。
    fn derived(&mut self) -> String {
        self.direct(|t, col| {
            assert!(!dump(t.conn(), col).is_empty());
            assert_rebuild_is_identity(t, col);
            Index::new(t, col).digest()
        })
    }
}

impl Drop for Dev {
    fn drop(&mut self) {
        ffsrs_store_close(self.h);
    }
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let p = e.path();
        if p.is_dir() {
            copy_dir(&p, &to.join(e.file_name()));
        } else {
            std::fs::copy(&p, to.join(e.file_name())).unwrap();
        }
    }
}

/// 位置上一台设备目录下的文件名（相对 `v4/devices/<设备>/`）。
fn names_of(loc: &Loc, device: &str) -> Vec<String> {
    let prefix = format!("v4/devices/{device}/");
    loc.keys()
        .filter_map(|k| k.strip_prefix(&prefix).map(str::to_owned))
        .collect()
}

/// 每台设备目录的文件名清单（`plan` 的 `listing`）。
fn listing(loc: &Loc) -> BTreeMap<String, Vec<String>> {
    let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for k in loc.keys() {
        if let Some(rest) = k.strip_prefix("v4/devices/") {
            if let Some((dev, name)) = rest.split_once('/') {
                out.entry(dev.to_owned()).or_default().push(name.to_owned());
            }
        }
    }
    out
}

/// 每台设备代号最大的 head 的字节。
fn heads(loc: &Loc) -> Vec<Vec<u8>> {
    let mut best: BTreeMap<String, (u64, String)> = BTreeMap::new();
    for k in loc.keys() {
        let Some(rel) = k.strip_prefix("v4/") else {
            continue;
        };
        if let Some(V4File::Head { device, gen, .. }) = parse_v4_path(rel) {
            let e = best.entry(device.text()).or_insert((0, String::new()));
            if gen > e.0 {
                *e = (gen, k.clone());
            }
        }
    }
    best.values().map(|(_, k)| loc[k].clone()).collect()
}

/// 一轮的选项。
#[derive(Clone, Copy, Default)]
struct Opts<'a> {
    key: Option<&'a str>,
    seg_bytes: Option<u64>,
    max_bytes: Option<u64>,
    skip_unchanged: bool,
    archive: bool,
}

/// 一轮里各步的回包（断言用）。
#[derive(Debug, Default)]
struct Round {
    plan: Value,
    ingest: Vec<Value>,
    finish: Option<Value>,
    batches: usize,
    head: Value,
    deleted: Vec<String>,
}

/// 按 Dart 的顺序跑一轮：根 → plan → ingest(+finish) → outbox/ack → head → obsolete。
fn round(d: &Dev, loc: &mut Loc, location: &str, now: i64, o: Opts<'_>) -> Round {
    let mut out = Round::default();
    // 1. 根。
    let mut blobs = Vec::new();
    let has4 = loc.get("v4/meta.json").cloned();
    let has3 = loc.get("v3/meta.json").cloned();
    blobs.extend(has4.clone());
    blobs.extend(has3.clone());
    let locs: Vec<String> = loc
        .keys()
        .filter_map(|k| k.strip_prefix("v4/loc/").map(str::to_owned))
        .collect();
    let (root, files) = cmd(
        d.h,
        "location_root",
        now,
        json!({"location": location, "has4": has4.is_some(), "has3": has3.is_some(), "locs": locs,
            "enableKdf": o.key.map(|_| json!({"alg": "test", "check": "c0ffee"}))}),
        &blobs,
    );
    assert_eq!(root["state"], json!("ok"), "{root}");
    let ensure: BTreeSet<String> = root["ensure"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap().to_owned())
        .collect();
    for (p, b) in files {
        if ensure.contains(&p) && loc.contains_key(&p) {
            continue;
        }
        loc.insert(p, b);
    }
    let loc_id = root["loc"].as_str().unwrap().to_owned();
    // 2. plan。
    let (plan, _) = cmd(
        d.h,
        "plan",
        now,
        json!({"location": location, "loc": loc_id, "listing": listing(loc)}),
        &heads(loc),
    );
    assert_eq!(plan["needsUpgrade"], json!(false), "{plan}");
    // 3. 收。
    let fetched: Vec<Vec<u8>> = plan["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|f| f["files"].as_array().unwrap().clone())
        .filter_map(|p| loc.get(&format!("v4/{}", p.as_str().unwrap())).cloned())
        .collect();
    let mut fork = plan["finishPending"] == json!(true);
    if !fetched.is_empty() {
        let (v, _) = cmd(d.h, "ingest", now, json!({"key": o.key}), &fetched);
        fork |= v["fork"] == json!(true);
        out.ingest.push(v);
    }
    if fork {
        out.finish = Some(cmd(d.h, "ingest_finish", now, json!({}), &[]).0);
    }
    out.plan = plan;
    // 4. 发。
    let me = d.device();
    let progress = format!("{location}#{}", o.key.map_or("plain", |_| "e1"));
    let mut first = true;
    loop {
        let mut req = json!({"progress": progress, "key": o.key});
        if first {
            req["present"] = json!(names_of(loc, &me));
            first = false;
        }
        if let Some(s) = o.seg_bytes {
            req["segBytes"] = json!(s);
        }
        if let Some(m) = o.max_bytes {
            req["maxBytes"] = json!(m);
        }
        let (v, files) = cmd(d.h, "outbox", now, req, &[]);
        if v["segments"].as_array().unwrap().is_empty() {
            break;
        }
        for (p, b) in files {
            loc.insert(format!("v4/{p}"), b);
        }
        let (ack, _) = cmd(
            d.h,
            "outbox_ack",
            now,
            json!({"progress": progress, "segments": v["segments"]}),
            &[],
        );
        assert_eq!(ack["accepted"], json!(true), "{ack}");
        out.batches += 1;
        if v["more"] != json!(true) {
            break;
        }
    }
    // 5. head。
    let mut req = json!({"location": location, "progress": progress, "loc": loc_id,
        "seal": if o.key.is_some() { "e1" } else { "" }});
    if o.skip_unchanged {
        req["skipUnchangedMs"] = json!(60_000);
    }
    let (head, files) = cmd(d.h, "head", now, req, &[]);
    for (p, b) in files {
        loc.insert(format!("v4/{p}"), b);
    }
    out.head = head;
    // 6. 清。
    let (obs, _) = cmd(
        d.h,
        "obsolete",
        now,
        json!({"progress": progress, "present": names_of(loc, &me), "archive": o.archive}),
        &[],
    );
    for p in obs["delete"].as_array().unwrap() {
        let k = format!("v4/{}", p.as_str().unwrap());
        assert!(loc.remove(&k).is_some(), "{k}");
        out.deleted.push(k);
    }
    out
}

fn sync_all(devs: &[&Dev], loc: &mut Loc, now: i64, o: Opts<'_>) {
    for _ in 0..2 {
        for d in devs {
            round(d, loc, "loc", now, o);
        }
    }
}

// ---------------------------------------------------------------------- 两台设备

/// 两台全新设备经同一个文件夹位置互相同步：各写各的 → 两轮之后都看得到对方写的；派生层逐行相同、增量 == 重建。第二轮
/// 什么都没变时（带 `skipUnchangedMs`）不重写 head；位置上只留每台设备最新两代 head。
#[test]
fn two_devices_converge_through_a_folder_location() {
    let mut a = Dev::new("g87a");
    let mut b = Dev::new("g87b");
    a.write(T1 + 1, N1, "鯨");
    b.write(T1 + 2, N2, "猫");
    let mut loc = Loc::new();
    let o = Opts::default();
    sync_all(&[&a, &b], &mut loc, T1 + 10, o);
    for d in [&a, &b] {
        assert_eq!(d.field(N1), Some(json!("鯨")));
        assert_eq!(d.field(N2), Some(json!("猫")));
    }
    // 同一个字段两边并发改：收敛到同一个胜者。
    a.write(T1 + 20, N3, "犬");
    b.write(T1 + 21, N3, "狐");
    sync_all(&[&a, &b], &mut loc, T1 + 30, o);
    assert_eq!(a.field(N3), b.field(N3));
    assert!(a.field(N3).is_some());
    assert_eq!(a.derived(), b.derived());
    // 没变：不重写 head。
    let r = round(
        &a,
        &mut loc,
        "loc",
        T1 + 31,
        Opts {
            skip_unchanged: true,
            ..o
        },
    );
    assert_eq!(r.head["unchanged"], json!(true), "{:?}", r.head);
    assert_eq!(r.batches, 0);
    // 每台设备位置上的 head 不超过两代。
    for d in [&a, &b] {
        let n = names_of(&loc, &d.device())
            .iter()
            .filter(|n| n.starts_with("head-"))
            .count();
        assert!((1..=2).contains(&n), "{n}");
    }
    // 位置的根：新根 meta、一个 loc 标记、旧根围栏与墓碑 head。
    assert!(loc.contains_key("v4/meta.json"));
    assert_eq!(loc.keys().filter(|k| k.starts_with("v4/loc/")).count(), 1);
    let fence: Value = serde_json::from_slice(&loc["v3/meta.json"]).unwrap();
    assert_eq!(fence["moved"], json!("v4"), "{fence}");
    assert_eq!(fence["collection"], json!(collection_of(P).text()));
    assert!(loc.keys().any(|k| k.starts_with("v3/devices/")));
    // 状态：位置上的已传水位。
    let st = g4(a.h, "status", T1, json!({}));
    assert_eq!(st["unpublished"], json!(0), "{st}");
}

/// 小段、小批：一台设备写很多条，分多段多批传；另一台收到同样的东西，派生层相同。
#[test]
fn small_segments_and_batches_resume_and_converge() {
    let mut a = Dev::new("g87sa");
    let mut b = Dev::new("g87sb");
    for i in 0..40 {
        a.write(T1 + i, [N1, N2, N3][i as usize % 3], &format!("v{i}"));
    }
    let mut loc = Loc::new();
    let o = Opts {
        seg_bytes: Some(300),
        max_bytes: Some(700),
        ..Opts::default()
    };
    let r = round(&a, &mut loc, "loc", T1 + 100, o);
    assert!(r.batches >= 2, "{}", r.batches);
    let segs = names_of(&loc, &a.device())
        .iter()
        .filter(|n| n.starts_with("seg-"))
        .count();
    assert!(segs >= 3, "{segs}");
    round(&b, &mut loc, "loc", T1 + 101, o);
    assert_eq!(b.field(N1), a.field(N1));
    round(&a, &mut loc, "loc", T1 + 102, o);
    assert_eq!(a.derived(), b.derived());
}

/// 位置上丢了一个已传的段（同步盘丢文件）：下一轮退水位重传，对端照样收齐。
#[test]
fn a_lost_segment_is_uploaded_again() {
    let a = Dev::new("g87la");
    let b = Dev::new("g87lb");
    a.write(T1 + 1, N1, "鯨");
    let mut loc = Loc::new();
    round(&a, &mut loc, "loc", T1 + 2, Opts::default());
    let me = a.device();
    let seg: Vec<String> = names_of(&loc, &me)
        .into_iter()
        .filter(|n| n.starts_with("seg-"))
        .collect();
    assert_eq!(seg.len(), 1);
    loc.remove(&format!("v4/devices/{me}/{}", seg[0]));
    let r = round(&a, &mut loc, "loc", T1 + 3, Opts::default());
    assert_eq!(r.batches, 1);
    assert!(loc.contains_key(&format!("v4/devices/{me}/{}", seg[0])));
    round(&b, &mut loc, "loc", T1 + 4, Opts::default());
    assert_eq!(b.field(N1), Some(json!("鯨")));
}

/// 清除已经发布的操作（本机日志里那一条成了空洞）：已传的段重切重传（新段带空洞），旧段被 `obsolete` 删掉，位置上
/// 不留已清除的原文。
///
/// `purge` 命令目前只追加「删除 + 清除」两条操作、不把目标落成空洞（`Truth::advance_purge` 没有生产调用方，交接说明
/// 「G8-7 同步一轮」上游缺口），所以这里直接在真相层上推进那个槽，测的是发件这一侧。
#[test]
fn purging_published_ops_rewrites_the_uploaded_segments() {
    let mut a = Dev::new("g87pa");
    let b = Dev::new("g87pb");
    a.write(T1 + 1, N1, "秘密");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 2, Opts::default());
    assert_eq!(b.field(N1), Some(json!("秘密")));
    let me = a.device();
    let segs = |loc: &Loc| -> BTreeMap<String, Vec<u8>> {
        names_of(loc, &me)
            .into_iter()
            .filter(|n| n.starts_with("seg-"))
            .map(|n| {
                let b = loc[&format!("v4/devices/{me}/{n}")].clone();
                (n, b)
            })
            .collect()
    };
    let old = segs(&loc);
    assert_eq!(old.len(), 1, "{:?}", old.keys());
    let dev = Id::parse(&me).unwrap();
    assert!(a.direct(|t, col| t.advance_purge(
        col,
        &OpId {
            device: dev,
            seq: 2
        }
    )));
    let r = round(&a, &mut loc, "loc", T1 + 4, Opts::default());
    assert_eq!(r.batches, 1);
    // 空洞记下了该处的链值，所以重切的段区间与链尾标签不变 = 同名覆盖写；内容换成了带空洞的那份。
    let now = segs(&loc);
    assert_eq!(
        now.keys().collect::<Vec<_>>(),
        old.keys().collect::<Vec<_>>()
    );
    assert_ne!(now.values().next(), old.values().next());
    // 再一轮：不再重传。
    assert_eq!(
        round(&a, &mut loc, "loc", T1 + 5, Opts::default()).batches,
        0
    );
    // 对端收到带空洞的新段：本机已有的完整槽不被别人的空洞改（`receive.rs`），收段不报错。
    let r = round(&b, &mut loc, "loc", T1 + 5, Opts::default());
    assert!(
        r.ingest.iter().all(|v| v["errors"] == json!([])),
        "{:?}",
        r.ingest
    );
}

// ---------------------------------------------------------------------- 加密位置

/// 加密位置：段按位置钥匙封装、head 带 `seal`；`plan` 认出加密；不带钥匙的设备收不进（逐段报错），带了就收齐。
/// `location_seal` 见到密封段的开头就记下、之后 `location_sealed` 一直是真（形状同协议 3 `{sealed, kdf}`）。
#[test]
fn an_encrypted_location_seals_segments_and_needs_the_key() {
    let a = Dev::new("g87ea");
    let b = Dev::new("g87eb");
    a.write(T1 + 1, N1, "鯨");
    let mut loc = Loc::new();
    let o = Opts {
        key: Some(KEY),
        ..Opts::default()
    };
    round(&a, &mut loc, "loc", T1 + 2, o);
    let meta: Value = serde_json::from_slice(&loc["v4/meta.json"]).unwrap();
    assert!(meta["kdf"].is_object(), "{meta}");
    let segs: Vec<Vec<u8>> = loc
        .iter()
        .filter(|(k, _)| k.contains("/seg-"))
        .map(|(_, v)| v.clone())
        .collect();
    assert!(!segs.is_empty());
    assert!(segs.iter().all(|s| sealed_at_location(&s[..8])));
    // 不带钥匙：收不进。
    let r = round(&b, &mut loc, "loc", T1 + 3, Opts::default());
    assert_eq!(r.plan["sealed"], json!(true), "{:?}", r.plan);
    assert!(
        !r.ingest[0]["errors"].as_array().unwrap().is_empty(),
        "{:?}",
        r.ingest
    );
    assert_eq!(b.field(N1), None);
    // 带钥匙：收齐。
    let r = round(&b, &mut loc, "loc", T1 + 5, o);
    assert!(
        r.ingest.iter().all(|v| v["errors"] == json!([])),
        "{:?}",
        r.ingest
    );
    assert_eq!(b.field(N1), Some(json!("鯨")));
    // 加密记忆。
    let sealed = |d: &Dev| cmd(d.h, "location_sealed", T1, json!({"location": "loc"}), &[]).0;
    assert_eq!(sealed(&b), json!({"sealed": false, "kdf": null}));
    let (v, _) = cmd(
        b.h,
        "location_seal",
        T1,
        json!({"location": "loc"}),
        &[b"FSG4\x01\x00".to_vec()],
    );
    assert_eq!(
        v,
        json!({"sealed": false, "kdf": null}),
        "plain prefix is no evidence"
    );
    let prefix = segs[0][..8].to_vec();
    let (v, _) = cmd(
        b.h,
        "location_seal",
        T1,
        json!({"location": "loc"}),
        &[prefix],
    );
    assert_eq!(v, json!({"sealed": true, "kdf": null}));
    let kdf = json!({"alg": "test", "check": "c0ffee"});
    let (v, _) = cmd(
        b.h,
        "location_seal",
        T1,
        json!({"location": "loc", "kdf": kdf}),
        &[],
    );
    assert_eq!(v, json!({"sealed": true, "kdf": kdf}));
    assert_eq!(sealed(&b), json!({"sealed": true, "kdf": kdf}));
    // 只有旁证（`seen`）不抹掉已记的 kdf。
    let (v, _) = cmd(
        b.h,
        "location_seal",
        T1,
        json!({"location": "loc", "seen": true}),
        &[],
    );
    assert_eq!(v["kdf"], kdf);
}

// ---------------------------------------------------------------------- 位置的根

/// 存量协议 3 的位置（有 `v3/meta.json`）：新根 meta 的媒体根取 `v3`、kdf 从旧根抄；旧 meta 被改写成围栏（协议 3 的
/// 读者见 `minReader` 4 就停下，字节由本版本写定）。新根 meta 要更新的读者 / 属于别的集合：停下，什么都不写。
#[test]
fn the_location_root_fences_protocol_3_and_refuses_what_it_cannot_read() {
    let a = Dev::new("g87r");
    let old = json!({"collection": collection_of(P).text(), "v": 3, "minReader": 3,
        "kdf": {"alg": "argon2id", "check": "abcd"}});
    let v3 = old.to_string().into_bytes();
    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": false, "has3": true, "locs": []}),
        &[v3.clone()],
    );
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["media"], json!("v3"));
    assert_eq!(r["fresh"], json!(true));
    assert_eq!(r["ensure"], json!([]));
    assert_eq!(r["kdf"], old["kdf"]);
    let paths: Vec<&str> = files.iter().map(|(p, _)| p.as_str()).collect();
    assert_eq!(paths[0], "v4/meta.json");
    assert!(paths[1].starts_with("v4/loc/"));
    assert_eq!(paths[2], "v3/meta.json");
    let fence: Value = serde_json::from_slice(&files[2].1).unwrap();
    assert_eq!(fence["moved"], json!("v4"));
    assert_eq!(fence["minReader"], json!(crate::gen4::MIN_READER));
    assert_eq!(fence["kdf"], old["kdf"]);
    // 再来一轮：都在了，什么都不写。
    let meta = files[0].1.clone();
    let mark = paths[1].strip_prefix("v4/loc/").unwrap().to_owned();
    let (r, files2) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": true, "has3": true, "locs": [mark]}),
        &[meta.clone(), files[2].1.clone()],
    );
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["fresh"], json!(false));
    assert!(
        files2.is_empty(),
        "{:?}",
        files2.iter().map(|f| &f.0).collect::<Vec<_>>()
    );
    // 要更新的读者 / 别的集合：停下。
    let mut newer: Value = serde_json::from_slice(&meta).unwrap();
    newer["minReader"] = json!(9);
    let other = crate::gen4::location::meta4(
        &collection_of("someone-else"),
        None,
        crate::gen4::location::MediaRoot::V4,
    )
    .unwrap();
    for (bytes, state) in [
        (newer.to_string().into_bytes(), "needsUpgrade"),
        (other, "refused"),
        (b"not json".to_vec(), "refused"),
    ] {
        let (r, files) = cmd(
            a.h,
            "location_root",
            T1,
            json!({"location": "loc", "has4": true, "has3": false, "locs": [mark]}),
            &[bytes],
        );
        assert_eq!(r["state"], json!(state), "{r}");
        assert!(files.is_empty());
    }
    // 旧根属于别的集合：停下。
    let foreign = json!({"collection": collection_of("x").text(), "v": 3})
        .to_string()
        .into_bytes();
    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": false, "has3": true, "locs": []}),
        &[foreign],
    );
    assert_eq!(r["state"], json!("refused"), "{r}");
    assert!(files.is_empty());
}

/// 位置上的 head 要更新的读者：`plan` 报 `needsUpgrade`（Dart 整轮停下）。
#[test]
fn a_head_from_a_newer_reader_stops_the_round() {
    let a = Dev::new("g87u");
    let b = Dev::new("g87ub");
    b.write(T1, N1, "鯨");
    let mut loc = Loc::new();
    round(&b, &mut loc, "loc", T1 + 1, Opts::default());
    // 一台更新的设备写的 head（签名有效、`minReader` 99）：报要升级，不收、不记它的公钥。
    let mut h = Head4::decode(&heads(&loc).pop().unwrap()).unwrap();
    let key = DeviceKey::generate();
    h.device = Id::new_v7(1);
    h.public = key.public();
    h.min_reader = 99;
    let (plan, _) = cmd(
        a.h,
        "plan",
        T1 + 2,
        json!({"location": "loc"}),
        &[h.encode(&key).unwrap()],
    );
    assert_eq!(plan["needsUpgrade"], json!(true), "{plan}");
    assert_eq!(plan["minReader"], json!(99));
    assert_eq!(plan["fetch"], json!([]));
}

// ---------------------------------------------------------------------- 停用

/// 停用：状态里是 `retired`（带时刻）；对端之后写了更新的 head = 自动取消停用。不能停用本机。
#[test]
fn retiring_a_device_shows_in_status_until_it_writes_again() {
    let a = Dev::new("g87ta");
    let b = Dev::new("g87tb");
    b.write(T1, N1, "鯨");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 1, Opts::default());
    let bd = b.device();
    let state = |d: &Dev| -> Value {
        g4(d.h, "status", T1, json!({}))["devices"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["device"] == json!(bd))
            .cloned()
            .unwrap()
    };
    let (v, _) = cmd(
        a.h,
        "retire",
        T1 + 2,
        json!({"device": bd, "retire": true}),
        &[],
    );
    assert_eq!(v["retired"], json!(true), "{v}");
    assert!(v["localRevision"].is_i64(), "{v}");
    let row = state(&a);
    assert_eq!(row["state"], json!("retired"), "{row}");
    assert_eq!(row["retiredAt"], json!(T1 + 2));
    let me = a.device();
    let err = raw(a.h, &g4req("retire", T1, json!({"device": me})), &[]).unwrap_err();
    assert!(err.contains("cannot retire this device"), "{err}");
    // b 再写一次：a 读到更新的 head，取消停用。
    b.write(T1 + 3, N2, "猫");
    round(&b, &mut loc, "loc", T1 + 4, Opts::default());
    round(&a, &mut loc, "loc", T1 + 5, Opts::default());
    assert_ne!(state(&a)["state"], json!("retired"));
    assert_eq!(a.field(N2), Some(json!("猫")));
    // 手动取消。
    cmd(
        a.h,
        "retire",
        T1 + 6,
        json!({"device": bd, "retire": true}),
        &[],
    );
    cmd(
        a.h,
        "retire",
        T1 + 7,
        json!({"device": bd, "retire": false}),
        &[],
    );
    assert_ne!(state(&a)["state"], json!("retired"));
}

const N4: &str = "0193a1b2-0000-7000-8000-0000000000a4";
const N5: &str = "0193a1b2-0000-7000-8000-0000000000a5";
const N6: &str = "0193a1b2-0000-7000-8000-0000000000a6";

/// [d] 的 `status` 里 [device] 那一行。
fn status_row(d: &Dev, device: &str) -> Value {
    g4(d.h, "status", T1, json!({}))["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["device"] == json!(device))
        .cloned()
        .unwrap_or_else(|| panic!("no status row for {device}"))
}

/// 停用的本意：因等某台设备的数据而卡在等待缓冲里的操作，停用它之后同一个事务里投递（`receive.rs` `deps_ready`、
/// `retire` 收尾补投递），`status` 不再把卡住记到停用设备头上（`stuck`）。b 的一条操作同时依赖 c、d 还没到 a 的
/// 操作：只停用 c 时仍等 d、不投递，c 头上不再记卡住；再停用 d 就投递。之后 c、d 的段晚到（乱序投递），四台收敛、
/// 增量 == 重建，c、d 写了更新的 head 自动取消停用。
#[test]
fn retiring_a_device_delivers_what_waited_on_it() {
    let mut a = Dev::new("g87ra");
    let mut b = Dev::new("g87rb");
    let mut c = Dev::new("g87rc");
    let mut d = Dev::new("g87rd");
    // 各有一条日志（状态表按日志登记设备），四台先在主位置上互相见过。
    b.write(T1, N1, "b1");
    c.write(T1, N2, "c1");
    d.write(T1, N3, "d1");
    let mut main = Loc::new();
    sync_all(&[&a, &b, &c, &d], &mut main, T1 + 1, Opts::default());
    // c、d 各写一条，只经旁路位置给了 b；b 在它们之上写一条（依赖 c:2、d:2），只发到主位置。
    c.write(T1 + 2, N4, "c2");
    d.write(T1 + 2, N5, "d2");
    let mut side = Loc::new();
    for dev in [&c, &d, &b] {
        round(dev, &mut side, "side", T1 + 3, Opts::default());
    }
    assert_eq!(b.field(N4), Some(json!("c2")));
    assert_eq!(b.field(N5), Some(json!("d2")));
    b.write(T1 + 4, N6, "b2");
    round(&b, &mut main, "loc", T1 + 5, Opts::default());
    round(&a, &mut main, "loc", T1 + 5, Opts::default());
    assert_eq!(a.field(N6), None);
    let (cd, dd) = (c.device(), d.device());
    for dev in [&cd, &dd] {
        let row = status_row(&a, dev);
        assert!(row["blocking"].as_i64().unwrap() > 0, "{row}");
        assert_eq!(row["state"], json!("missing"), "{row}");
    }
    // 停用 c：还在等 d，不投递；c 头上不再记卡住，d 照记。
    let (v, _) = cmd(
        a.h,
        "retire",
        T1 + 6,
        json!({"device": cd, "retire": true}),
        &[],
    );
    assert_eq!(v["delivered"], json!(0), "{v}");
    let row = status_row(&a, &cd);
    assert_eq!(row["state"], json!("retired"), "{row}");
    assert_eq!(row["blocking"], json!(0), "{row}");
    assert!(status_row(&a, &dd)["blocking"].as_i64().unwrap() > 0);
    assert_eq!(a.field(N6), None);
    // 停用 d：依赖全落在停用设备上，同一个事务里投递。
    let (v, _) = cmd(
        a.h,
        "retire",
        T1 + 7,
        json!({"device": dd, "retire": true}),
        &[],
    );
    assert!(v["delivered"].as_i64().unwrap() > 0, "{v}");
    assert_eq!(a.field(N6), Some(json!("b2")));
    assert_eq!(status_row(&a, &dd)["blocking"], json!(0));
    a.derived();
    // c、d 接回主位置：晚到的依赖照收，四台收敛。
    sync_all(&[&c, &d, &a, &b], &mut main, T1 + 8, Opts::default());
    for dev in [&a, &b, &c, &d] {
        assert_eq!(dev.field(N4), Some(json!("c2")));
        assert_eq!(dev.field(N5), Some(json!("d2")));
        assert_eq!(dev.field(N6), Some(json!("b2")));
    }
    for dev in [&cd, &dd] {
        assert_ne!(status_row(&a, dev)["state"], json!("retired"));
    }
    let da = a.derived();
    assert_eq!(da, b.derived());
    assert_eq!(da, c.derived());
    assert_eq!(da, d.derived());
}

/// 停用记录体读不懂：仍按停用算（停用只看键），但 `status` 在那一行报 `warning`，不当成空记录混过去；取消停用清掉。
#[test]
fn an_unreadable_retire_record_is_reported() {
    let mut a = Dev::new("g87wa");
    let b = Dev::new("g87wb");
    b.write(T1, N1, "鯨");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 1, Opts::default());
    let bd = b.device();
    let dev = Id::parse(&bd).unwrap();
    a.direct(|t, col| t.set_retired(col, &dev, Some(&json!("not a record"))));
    let row = status_row(&a, &bd);
    assert_eq!(row["state"], json!("retired"), "{row}");
    assert_eq!(row["warning"], json!(RETIRED_RECORD_UNREADABLE), "{row}");
    cmd(
        a.h,
        "retire",
        T1 + 2,
        json!({"device": bd, "retire": false}),
        &[],
    );
    let row = status_row(&a, &bd);
    assert_ne!(row["state"], json!("retired"), "{row}");
    assert_eq!(row["warning"], Value::Null, "{row}");
}

/// `outbox_ack` 只认链尾标签与本机日志相符的段（发件与确认之间本机日志被改写时唯一的拒绝点，Dart 据此不写 head）：
/// 标签对不上 → `accepted: false`、水位不动；原样的那份照收。
#[test]
fn outbox_ack_refuses_a_tail_tag_that_is_not_the_local_chain() {
    let a = Dev::new("g87k");
    a.write(T1, N1, "鯨");
    let progress = "loc#plain";
    let (v, files) = cmd(
        a.h,
        "outbox",
        T1,
        json!({"progress": progress, "present": []}),
        &[],
    );
    assert_eq!(files.len(), 1, "{v}");
    let segs = v["segments"].clone();
    let mut bad = segs.clone();
    let tag = bad[0][2].as_str().unwrap().to_owned();
    let flipped = format!(
        "{}{}",
        if tag.starts_with('0') { '1' } else { '0' },
        &tag[1..]
    );
    bad[0][2] = json!(flipped);
    let (ack, _) = cmd(
        a.h,
        "outbox_ack",
        T1,
        json!({"progress": progress, "segments": bad}),
        &[],
    );
    assert_eq!(ack["accepted"], json!(false), "{ack}");
    assert_eq!(ack["uploaded"], json!(0), "{ack}");
    // 水位没动：再发一次还是同一段。
    let (again, _) = cmd(a.h, "outbox", T1, json!({"progress": progress}), &[]);
    assert_eq!(again["segments"], segs);
    let (ack, _) = cmd(
        a.h,
        "outbox_ack",
        T1,
        json!({"progress": progress, "segments": segs}),
        &[],
    );
    assert_eq!(ack["accepted"], json!(true), "{ack}");
    assert_eq!(ack["uploaded"], segs[0][1], "{ack}");
}

/// 归档位置（`obsolete` 带 `archive`）一个都不删：每轮写一代新 head，旧 head 与段全留；同一台设备换回普通位置后
/// 只留最新两代。`plan` 没有只读预演（协议 3 的 `readOnly`），带了明确拒绝。
#[test]
fn an_archive_location_keeps_every_head() {
    let a = Dev::new("g87h");
    let mut loc = Loc::new();
    let archive = Opts {
        archive: true,
        ..Opts::default()
    };
    for i in 0..4 {
        a.write(T1 + i, N1, &format!("v{i}"));
        let r = round(&a, &mut loc, "loc", T1 + 10 + i, archive);
        assert!(r.deleted.is_empty(), "{:?}", r.deleted);
    }
    let heads_of = |loc: &Loc| {
        names_of(loc, &a.device())
            .iter()
            .filter(|n| n.starts_with("head-"))
            .count()
    };
    assert_eq!(heads_of(&loc), 4);
    a.write(T1 + 20, N1, "v9");
    let r = round(&a, &mut loc, "loc", T1 + 21, Opts::default());
    assert!(!r.deleted.is_empty());
    assert_eq!(heads_of(&loc), 2);
    let e = raw(
        a.h,
        &g4req("plan", T1, json!({"location": "loc", "readOnly": true})),
        &[],
    )
    .unwrap_err();
    assert!(e.contains("readOnly"), "{e}");
}

// ---------------------------------------------------------------------- 换身份

/// 主动换身份（`rotate`）：之后的写以新身份发出，对端照样收齐；派生层两边相同。
#[test]
fn rotating_the_identity_keeps_syncing() {
    let mut a = Dev::new("g87oa");
    let mut b = Dev::new("g87ob");
    a.write(T1, N1, "鯨");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 1, Opts::default());
    let before = a.device();
    let (v, _) = cmd(a.h, "rotate", T1 + 2, json!({}), &[]);
    assert_eq!(v["previous"], json!(before));
    assert_ne!(v["device"], json!(before));
    assert_eq!(a.device(), v["device"].as_str().unwrap());
    a.write(T1 + 3, N2, "猫");
    sync_all(&[&a, &b], &mut loc, T1 + 4, Opts::default());
    assert_eq!(b.field(N2), Some(json!("猫")));
    assert_eq!(a.derived(), b.derived());
}

/// 复制了整个数据目录（两份库同一个身份）各写各的：先同步的那份的段被另一份收到时比链发现分叉，`ingest_finish`
/// 换身份，分叉点之后的本机操作以新身份重签发；之后三方收敛、派生层相同。
#[test]
fn a_copied_library_forks_and_rotates_then_converges() {
    let mut a = Dev::new("g87fa");
    let mut b = Dev::new("g87fb");
    a.write(T1, N1, "鯨");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 1, Opts::default());
    let mut c = a.copy("g87fc");
    assert_eq!(a.device(), c.device());
    a.write(T1 + 2, N2, "猫");
    c.write(T1 + 3, N3, "犬");
    round(&a, &mut loc, "loc", T1 + 4, Opts::default());
    let r = round(&c, &mut loc, "loc", T1 + 5, Opts::default());
    let fin = r
        .finish
        .as_ref()
        .unwrap_or_else(|| panic!("no fork: {r:?}"));
    assert_eq!(fin["fork"], json!(true), "{fin}");
    assert_ne!(c.device(), a.device());
    sync_all(&[&a, &b, &c], &mut loc, T1 + 6, Opts::default());
    for d in [&a, &b, &c] {
        assert_eq!(d.field(N2), Some(json!("猫")));
        assert_eq!(d.field(N3), Some(json!("犬")));
    }
    let da = a.derived();
    assert_eq!(da, b.derived());
    assert_eq!(da, c.derived());
}

// ---------------------------------------------------------------------- 分发器与查询计划

/// 协议 3 的进件通道命令、单独的摘要命令与 `obsolete_ack` 已删（各自的原因）；转发与媒体还没接（归 G8-7b）。
#[test]
fn removed_and_unwired_sync_commands_name_their_reason() {
    let a = Dev::new("g87w");
    for op in [
        "ingest_yield",
        "ingest_begin",
        "replay_pending",
        "digest_buckets",
        "obsolete_ack",
    ] {
        let e = raw(a.h, &g4req(op, T1, json!({})), &[]).unwrap_err();
        assert!(e.contains(REMOVED), "{op}: {e}");
    }
    for op in ["relay_outbox", "media_scan"] {
        let e = raw(a.h, &g4req(op, T1, json!({})), &[]).unwrap_err();
        assert!(e.contains(UNWIRED) && e.contains("G8-7b"), "{op}: {e}");
    }
}

/// 新语句（停用记录、本机空洞区间、位置记忆、位置上的 head seq）按键找，不扫表。
#[test]
fn sync_lookups_use_their_keys() {
    let a = Dev::new("g87q");
    let c = Connection::open_with_flags(
        a.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    for (q, n) in [
        (RETIRED_SQL, 2),
        (VOIDS_SQL, 2),
        (LOC_STATE_SQL, 2),
        (LOC_HEAD_SEQ_SQL, 2),
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
