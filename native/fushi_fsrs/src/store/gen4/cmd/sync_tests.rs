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
use super::sync::{
    ERR_META_UNAVAILABLE, ERR_NEW_ROOT_MISSING, LOC_HEAD_SEQ_SQL, LOC_STATE_SQL, VOIDS_SQL,
    sealed_at_location,
};
use super::tests::{N1, N2, N3, card, note};
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
use crate::store::sync2::tests::{DAY, P, edit, tempdir};
use crate::sync2::id::Id;
use crate::sync2::keys::DeviceKey;
use crate::sync2::vv::OpId;

pub(super) type Loc = BTreeMap<String, Vec<u8>>;
type Files = Vec<(String, Vec<u8>)>;

const KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";

/// 经 C ABI 发一条命令，字节块原样带上（`[条数][长度][字节]…`）。
pub(super) fn raw(
    h: *mut SrsCoreHandle,
    req: &Value,
    blobs: &[Vec<u8>],
) -> Result<(Value, Files), String> {
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

pub(super) fn cmd(
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
pub(super) struct Dev {
    pub(super) dir: tempdir::Dir,
    pub(super) h: *mut SrsCoreHandle,
}

impl Dev {
    pub(super) fn new(tag: &str) -> Dev {
        let dir = tempdir::new(tag);
        let h = open(&dir.0, 0).unwrap();
        g4(h, "identity", T1, json!({}));
        g4(h, "cache_config_set", T1, json!({"caches": cfg()}));
        Dev { dir, h }
    }

    /// 同一个库目录的一份拷贝（关着拷，模拟「复制了整个数据目录」）。
    pub(super) fn copy(&mut self, tag: &str) -> Dev {
        ffsrs_store_close(self.h);
        let dir = tempdir::new(tag);
        copy_dir(&self.dir.0, &dir.0);
        self.h = open(&self.dir.0, 0).unwrap();
        let h = open(&dir.0, 0).unwrap();
        Dev { dir, h }
    }

    pub(super) fn device(&self) -> String {
        g4(self.h, "identity", T1, json!({}))["device"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    pub(super) fn write(&self, now: i64, note: &str, v: &str) {
        let items = vec![json!({"e": edit("note", note, "f/fa", json!(v)), "note": note})];
        let blob = Value::Array(items).to_string().into_bytes();
        let (v, _) = cmd(self.h, "apply", now, json!({}), &[blob]);
        assert_eq!(v["landed"], json!([true]), "{v}");
    }

    pub(super) fn field(&self, note: &str) -> Option<Value> {
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
    pub(super) fn direct<T>(&mut self, f: impl FnOnce(&Truth<'_>, i64) -> Result<T, String>) -> T {
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
    pub(super) fn derived(&mut self) -> String {
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
pub(super) fn names_of(loc: &Loc, device: &str) -> Vec<String> {
    let prefix = format!("v4/devices/{device}/");
    loc.keys()
        .filter_map(|k| k.strip_prefix(&prefix).map(str::to_owned))
        .collect()
}

/// 每台设备目录的文件名清单（`plan` 的 `listing`）。
pub(super) fn listing(loc: &Loc) -> BTreeMap<String, Vec<String>> {
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
pub(super) fn heads(loc: &Loc) -> Vec<Vec<u8>> {
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

/// 每台设备代号最大的被转发 head（`rhd-`，`cmd/sync_relay.rs`）的字节。
pub(super) fn relayed_heads(loc: &Loc) -> Vec<Vec<u8>> {
    let mut best: BTreeMap<String, (u64, String)> = BTreeMap::new();
    for k in loc.keys() {
        let Some(rel) = k.strip_prefix("v4/") else {
            continue;
        };
        if let Some(V4File::RelayHead { author, gen, .. }) = parse_v4_path(rel) {
            let e = best.entry(author.text()).or_insert((0, String::new()));
            if gen > e.0 {
                *e = (gen, k.clone());
            }
        }
    }
    best.values().map(|(_, k)| loc[k].clone()).collect()
}

/// 拉一个段：作者自写的 `seg-…` 不在就拉别的设备转发来的同名 `rly-…`（Dart `srsFetchSegment`）。
pub(super) fn fetch_seg(loc: &Loc, path: &str) -> Option<Vec<u8>> {
    loc.get(&format!("v4/{path}")).cloned().or_else(|| {
        let (dir, name) = path.rsplit_once('/')?;
        let rest = name.strip_prefix("seg-")?;
        loc.get(&format!("v4/{dir}/rly-{rest}")).cloned()
    })
}

/// 一轮的选项。
#[derive(Clone, Copy, Default)]
pub(super) struct Opts<'a> {
    pub(super) key: Option<&'a str>,
    pub(super) seg_bytes: Option<u64>,
    pub(super) max_bytes: Option<u64>,
    pub(super) skip_unchanged: bool,
    pub(super) archive: bool,
    /// 这一批里重切中继件（`FRX4`）排在最前面交（同一批里它点名的 Purge 在后面）。
    pub(super) recut_first: bool,
}

/// 一轮里各步的回包（断言用）。
#[derive(Debug, Default)]
pub(super) struct Round {
    pub(super) plan: Value,
    pub(super) ingest: Vec<Value>,
    pub(super) finish: Option<Value>,
    pub(super) batches: usize,
    pub(super) head: Value,
    /// 这一轮发出的 `head` 请求（测试再发一次用）。
    pub(super) head_req: Value,
    pub(super) deleted: Vec<String>,
}

/// 按 Dart 的顺序跑一轮：根 → plan → ingest(+finish) → outbox/ack → head → obsolete。
pub(super) fn round(d: &Dev, loc: &mut Loc, location: &str, now: i64, o: Opts<'_>) -> Round {
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
    // 2. plan（作者自写的 head 在前，被转发的 head 在后，`relayed` 是后者的份数）。
    let mut hs = heads(loc);
    let rh = relayed_heads(loc);
    let relayed = rh.len();
    hs.extend(rh);
    let (plan, _) = cmd(
        d.h,
        "plan",
        now,
        json!({"location": location, "loc": loc_id, "listing": listing(loc), "relayed": relayed}),
        &hs,
    );
    assert_eq!(plan["needsUpgrade"], json!(false), "{plan}");
    // 3. 收。
    let mut fetched: Vec<Vec<u8>> = plan["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|f| f["files"].as_array().unwrap().clone())
        .filter_map(|p| fetch_seg(loc, p.as_str().unwrap()))
        .collect();
    if o.recut_first {
        fetched.sort_by_key(|b| !b.starts_with(crate::gen4::recut::MAGIC));
    }
    let mut fork = plan["finishPending"] == json!(true);
    if !fetched.is_empty() {
        // 同 Dart：带上读的是哪个位置（重切件的停放按位置记，`cmd/sync_park.rs`）。
        let (v, _) = cmd(
            d.h,
            "ingest",
            now,
            json!({"key": o.key, "location": location}),
            &fetched,
        );
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
    out.head_req = req.clone();
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

pub(super) fn sync_all(devs: &[&Dev], loc: &mut Loc, now: i64, o: Opts<'_>) {
    for _ in 0..2 {
        for d in devs {
            round(d, loc, "loc", now, o);
        }
    }
}

// ---------------------------------------------------------------------- 两台设备

/// 发一条带输入项的写命令（`apply` / `import_drafts`）。
fn write_items(d: &Dev, op: &str, now: i64, items: Vec<Value>) -> Value {
    let blob = Value::Array(items).to_string().into_bytes();
    cmd(d.h, op, now, json!({}), &[blob]).0
}

/// 两台设备各自把同一条 Anki revlog 导入到血统里的前身卡、后继卡（Dart 按新卡重算日志 ID，内容相同；K3，交接 §26
/// C4）：同步之后两边派生层一致（增量 == 重建、语义摘要相同、卡片行逐行相同），这次复习在统计里只算一次——Anki 来源
/// 日志的 HLC 由来源数据派生（`crate::anki_import_rules`），不随作者设备与导入时刻变，两份副本归成一个事件。改前按
/// 操作 HLC 排：两份副本不成组，统计 2 行。
#[test]
fn an_anki_revlog_imported_on_two_devices_is_one_event() {
    let mut a = Dev::new("k3a");
    let mut b = Dev::new("k3b");
    let (c1, c2) = (card(N1, "t1"), card(N1, "t2"));
    let fdef = json!({"name": "Expression", "ord": 0});
    let tdef = |name: &str, ord: i64| json!({"name": name, "ord": ord, "front": "{{Expression}}"});
    let item = |e: Value| json!({"e": e, "note": N1});
    write_items(
        &a,
        "apply",
        T1,
        vec![
            item(
                json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            ),
            item(edit("notetype", "NT", "fieldDef/fa", fdef)),
            item(edit("notetype", "NT", "tmplDef/t1", tdef("A", 0))),
            item(edit("notetype", "NT", "tmplDef/t2", tdef("B", 1))),
            item(note(N1, "NT", 10)),
            item(edit("note", N1, "f/fa", json!("猫"))),
            item(edit("card", &c2, &format!("historyFrom/{c1}"), json!(true))),
        ],
    );
    let mut loc = Loc::new();
    let o = Opts::default();
    sync_all(&[&a, &b], &mut loc, T1 + 10, o);
    let rid = T1 - 5 * DAY;
    let anki = |id: &str, card: &str| {
        item(json!({"t": "log", "x": {
            "id": id, "p": P, "card": card, "kind": "review", "rating": 3, "hlc": format!("{rid}:0:anki"),
            "at": rid, "ts": "wall", "origin": "anki", "ankiId": rid, "rtype": "review", "dur": 5000,
            "utcOff": 0, "rollover": 4, "alg": "anki",
            "res": {"queue": "review", "ivl": 3, "step": 0, "reps": 1, "lapses": 0, "scheduler": "fushi", "dueDay": 1}
        }}))
    };
    write_items(&a, "import_drafts", T1 + 20, vec![anki("k3-a", &c1)]);
    write_items(&b, "import_drafts", T1 + 21, vec![anki("k3-b", &c2)]);
    sync_all(&[&a, &b], &mut loc, T1 + 30, o);
    let mut cards = Vec::new();
    for d in [&mut a, &mut b] {
        let (stats, rows) = d.direct(|t, col| {
            let n: i64 = t
                .conn()
                .query_row(
                    "SELECT COUNT(*) FROM stats WHERE col = ?1 AND at = ?2",
                    [col, rid],
                    |r| r.get(0),
                )
                .map_err(|e| e.to_string())?;
            let mut stmt = t
                .conn()
                .prepare(
                    "SELECT hex(id), hex(last_log_id), due_day, scheduled_days, reps, queue FROM cards \
                     WHERE col = ?1 ORDER BY id",
                )
                .map_err(|e| e.to_string())?;
            let rows: Vec<String> = stmt
                .query_map([col], |r| {
                    Ok(format!(
                        "{:?} {:?} {:?} {:?} {:?} {:?}",
                        r.get::<_, Option<String>>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, Option<i64>>(2)?,
                        r.get::<_, Option<i64>>(3)?,
                        r.get::<_, Option<i64>>(4)?,
                        r.get::<_, Option<String>>(5)?,
                    ))
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<_, _>>()
                .map_err(|e| e.to_string())?;
            Ok((n, rows))
        });
        assert_eq!(stats, 1, "the same Anki review counts once");
        assert_eq!(rows.len(), 2, "{rows:?}");
        cards.push(rows);
    }
    assert_eq!(cards[0], cards[1]);
    assert_eq!(a.derived(), b.derived());
}

/// 两台设备在不同时刻各自回导同一份 Fushi 导出包里的同一条外来原生日志（`_remapExtLog`，origin = fushi，带
/// `foreignLog` 标记），它比 a 上一条本机复习早：同步之后两边卡片行逐行相同、派生层一致，卡片当前排程仍是那条本机
/// 复习（最后一条有效日志是它），不是外来日志——排序键由日志内容（发生时刻）派生，不随写入设备与导入时刻变。
/// 改前按操作 HLC 排：外来日志的导入时刻晚于本机复习，成了最后一条有效日志，两台设备的卡片排程都按它重放。
#[test]
fn a_foreign_native_log_imported_on_two_devices_keeps_the_local_schedule() {
    let mut a = Dev::new("w5a");
    let mut b = Dev::new("w5b");
    let c1 = card(N1, "t1");
    let fdef = json!({"name": "Expression", "ord": 0});
    let item = |e: Value| json!({"e": e, "note": N1});
    write_items(
        &a,
        "apply",
        T1,
        vec![
            item(
                json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            ),
            item(edit("notetype", "NT", "fieldDef/fa", fdef)),
            item(edit(
                "notetype",
                "NT",
                "tmplDef/t1",
                json!({"name": "A", "ord": 0, "front": "{{Expression}}"}),
            )),
            item(note(N1, "NT", 10)),
            item(edit("note", N1, "f/fa", json!("猫"))),
        ],
    );
    let log = |id: &str, at: i64, rating: i64, ivl: i64, foreign: bool| {
        let mut x = json!({
            "id": id, "p": P, "card": c1, "kind": "review", "rating": rating, "hlc": format!("{at}:0:someone"),
            "at": at, "ts": "wall", "origin": "fushi", "rtype": "review", "dur": 3000, "alg": "fsrs6",
            "utcOff": 0, "rollover": 4,
            "res": {"queue": "review", "ivl": ivl, "step": 0, "reps": 1, "lapses": 0, "scheduler": "fushi", "dueDay": ivl}
        });
        if foreign {
            x["foreignLog"] = json!(true);
        }
        item(json!({"t": "log", "x": x}))
    };
    write_items(
        &a,
        "apply",
        T1 + 5,
        vec![log("w5-local", T1 + 5, 3, 30, false)],
    );
    let mut loc = Loc::new();
    let o = Opts::default();
    sync_all(&[&a, &b], &mut loc, T1 + 10, o);
    let foreign = log("w5-ext", T1 - DAY, 1, 9, true);
    write_items(&a, "import_drafts", T1 + 20, vec![foreign.clone()]);
    write_items(&b, "import_drafts", T1 + 21, vec![foreign]);
    sync_all(&[&a, &b], &mut loc, T1 + 30, o);
    let mut seen = Vec::new();
    for d in [&mut a, &mut b] {
        let rows = d.direct(|t, col| {
            let mut stmt = t
                .conn()
                .prepare(
                    "SELECT hex(id), hex(last_log_id), due_day, scheduled_days, reps, queue FROM cards \
                     WHERE col = ?1 ORDER BY id",
                )
                .map_err(|e| e.to_string())?;
            let rows: Vec<(String, Option<String>)> = stmt
                .query_map([col], |r| {
                    Ok((
                        format!(
                            "{:?} {:?} {:?} {:?} {:?}",
                            r.get::<_, Option<String>>(0)?,
                            r.get::<_, Option<i64>>(2)?,
                            r.get::<_, Option<i64>>(3)?,
                            r.get::<_, Option<i64>>(4)?,
                            r.get::<_, Option<String>>(5)?,
                        ),
                        r.get::<_, Option<String>>(1)?,
                    ))
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<_, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        });
        // 文本日志 ID 的规范 ID 是它的 UTF-8 字节：最后一条有效日志仍是本机复习 `w5-local`，不是回导的 `w5-ext`。
        let local = "w5-local"
            .bytes()
            .map(|b| format!("{b:02X}"))
            .collect::<String>();
        assert_eq!(
            rows.iter()
                .map(|(_, last)| last.clone())
                .collect::<Vec<_>>(),
            vec![Some(local)],
            "the local review still schedules the card: {rows:?}"
        );
        seen.push(rows);
    }
    assert_eq!(seen[0], seen[1]);
    assert_eq!(a.derived(), b.derived());
}

/// 缓存层推导口径修订号（`cache.rs` [CACHE_RULES]，K3）：库里记的不是当前值（这个口径之前建的新代开发库没有这一项）时，
/// 宿主打开发的 `cache_config_set` 即使配置没变也整层重建一次、记下当前值；之后同一份配置什么都不做。
#[test]
fn a_cache_built_under_older_rules_is_rebuilt_once_on_open() {
    use crate::store::gen4::cache::{CACHE_RULES, RULES_KEY};
    let mut a = Dev::new("k3rules");
    write_items(
        &a,
        "apply",
        T1 + 1,
        vec![
            json!({"e": json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}), "note": null}),
            json!({"e": note(N1, "NT", 10), "note": null}),
            json!({"e": edit("note", N1, "f/fa", json!("鯨")), "note": null}),
        ],
    );
    let count = |t: &Truth<'_>, col: i64| -> Result<i64, String> {
        t.conn()
            .query_row("SELECT COUNT(*) FROM notes WHERE col = ?1", [col], |r| {
                r.get(0)
            })
            .map_err(|e| e.to_string())
    };
    // 没有这一项、最早的 0、上一版口径（每次 +1 时那批已打开过的库记的就是它）都要重建——上一版正好是只差
    // `rwkv_last` 的 `RWKV_FILL_FROM` 时它走就地升级 + 分批回填（BUG-5547，`training_tests.rs`
    // `rwkv_last_backfills_in_batches_after_an_in_place_rules_upgrade`），这里换成再早一版。
    use crate::store::gen4::cache::RWKV_FILL_FROM;
    let mut previous = CACHE_RULES - 1;
    if RWKV_FILL_FROM == Some(previous) {
        previous -= 1;
    }
    let previous = previous.to_string();
    for stale in [None, Some("0"), Some(previous.as_str())] {
        let before = a.direct(|t, col| {
            assert_eq!(t.derive_cfg(col, RULES_KEY)?, Some(CACHE_RULES.to_string()));
            let n = count(t, col)?;
            // 旧口径建的缓存层：这里清空缓存行当作「要换掉的旧行」，重建之后应当回来。
            t.set_derive_cfg(col, RULES_KEY, stale)?;
            t.conn()
                .execute("DELETE FROM notes WHERE col = ?1", [col])
                .map_err(|e| e.to_string())?;
            Ok(n)
        });
        assert!(before > 0);
        let v = g4(a.h, "cache_config_set", T1 + 2, json!({"caches": cfg()}));
        assert_eq!(v["changed"], json!(true), "{v}");
        let after = a.direct(|t, col| {
            assert_eq!(t.derive_cfg(col, RULES_KEY)?, Some(CACHE_RULES.to_string()));
            count(t, col)
        });
        assert_eq!(after, before);
        let v = g4(a.h, "cache_config_set", T1 + 3, json!({"caches": cfg()}));
        assert_eq!(v, json!({"changed": false}));
    }
}

/// HBK-AUDIT-203：卡片标志按血统继承的规则改过（BUG-5190：同一层几张前身都有记录时取生效写入最新的，之前取卡 ID
/// 序在前的）之后，按上一版口径（`CACHE_RULES` 4）物化过的新代库开库时整层重建一次：原地重开与显式重建相同，不留
/// 旧规则算出的标志。后继卡的两张前身同一层、`flag` 不同，ID 序在前的那张先写：旧口径继承它的 1，新口径继承 2。
#[test]
fn a_cache_with_card_flags_inherited_by_the_old_layer_rule_is_rebuilt_on_open() {
    use crate::store::gen4::cache::{CACHE_RULES, RULES_KEY};
    let mut a = Dev::new("k3layer");
    let (mut lo, mut hi) = (card(N1, "t1"), card(N1, "t2"));
    if crate::ordering::cmp_utf16(&hi, &lo).is_lt() {
        std::mem::swap(&mut lo, &mut hi);
    }
    let tail = card(N1, "t3");
    let fdef = json!({"name": "Expression", "ord": 0});
    let tdef = |name: &str, ord: i64| json!({"name": name, "ord": ord, "front": "{{Expression}}"});
    let item = |e: Value| json!({"e": e, "note": N1});
    write_items(
        &a,
        "apply",
        T1,
        vec![
            item(
                json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            ),
            item(edit("notetype", "NT", "fieldDef/fa", fdef)),
            item(edit("notetype", "NT", "tmplDef/t1", tdef("A", 0))),
            item(edit("notetype", "NT", "tmplDef/t2", tdef("B", 1))),
            item(edit("notetype", "NT", "tmplDef/t3", tdef("C", 2))),
            item(note(N1, "NT", 10)),
            item(edit("note", N1, "f/fa", json!("猫"))),
        ],
    );
    write_items(
        &a,
        "apply",
        T1 + 1,
        vec![item(edit("card", &lo, "flag", json!(1)))],
    );
    write_items(
        &a,
        "apply",
        T1 + 2,
        vec![item(edit("card", &hi, "flag", json!(2)))],
    );
    write_items(
        &a,
        "apply",
        T1 + 3,
        vec![
            item(edit(
                "card",
                &tail,
                &format!("historyFrom/{lo}"),
                json!(true),
            )),
            item(edit(
                "card",
                &tail,
                &format!("historyFrom/{hi}"),
                json!(true),
            )),
        ],
    );
    let flags = |t: &Truth<'_>, col: i64| -> Result<Vec<i64>, String> {
        let mut stmt = t
            .conn()
            .prepare("SELECT flag FROM cards WHERE col = ?1 ORDER BY id")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([col], |r| r.get(0))
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<i64>, _>>()
            .map_err(|e| e.to_string());
        rows
    };
    let built = a.direct(|t, col| {
        let built = flags(t, col)?;
        // 新口径：前身 1、2，后继 2（最新写的那张）。
        let mut sorted = built.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, vec![1, 2, 2], "{built:?}");
        // 上一版口径物化的库：后继卡继承的是 ID 序在前那张的 1，记的口径是 4。
        t.conn()
            .execute(
                "UPDATE cards SET flag = 1 WHERE col = ?1 AND flag = 2",
                [col],
            )
            .map_err(|e| e.to_string())?;
        t.set_derive_cfg(col, RULES_KEY, Some("4"))?;
        Ok(built)
    });
    let v = g4(a.h, "cache_config_set", T1 + 4, json!({"caches": cfg()}));
    assert_eq!(v["changed"], json!(true), "{v}");
    a.direct(|t, col| {
        assert_eq!(flags(t, col)?, built);
        assert_eq!(t.derive_cfg(col, RULES_KEY)?, Some(CACHE_RULES.to_string()));
        assert_rebuild_is_identity(t, col);
        Ok(())
    });
}

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

/// 别的连接看到的提交次数（`PRAGMA data_version` 只随别的连接的提交变）。
fn commits_seen(ro: &Connection) -> i64 {
    ro.query_row("PRAGMA data_version", [], |r| r.get(0))
        .unwrap()
}

/// head 没有变化时不开写事务（G8-7c）：内容没变、摘要记录没变、`last_ok` 不满一天，`head` 只在读快照上判定、回上次
/// 那份，库上一笔提交都没有；`last_ok` 满一天时写一次把它刷新（仍回 `unchanged`、不写新 head），之后又不写。
#[test]
fn an_unchanged_head_commits_nothing() {
    const DAY_MS: i64 = 86_400_000;
    let a = Dev::new("g87hq");
    let mut loc = Loc::new();
    a.write(T1 + 1, N1, "鯨");
    let o = Opts {
        skip_unchanged: true,
        ..Opts::default()
    };
    round(&a, &mut loc, "loc", T1 + 10, o);
    let r = round(&a, &mut loc, "loc", T1 + 11, o);
    assert_eq!(r.head["unchanged"], json!(true), "{}", r.head);
    let ro = Connection::open_with_flags(
        a.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    let mut req = r.head_req.clone();
    let before = commits_seen(&ro);
    let (h, files) = cmd(a.h, "head", T1 + 12, req.clone(), &[]);
    assert_eq!(h["unchanged"], json!(true), "{h}");
    assert!(files.is_empty());
    assert_eq!(
        commits_seen(&ro),
        before,
        "an unchanged head commits nothing"
    );
    // `last_ok` 满一天：写一次刷新它（head 本身仍不变），之后又不写。
    req["skipUnchangedMs"] = json!(10 * DAY_MS);
    let later = T1 + 12 + DAY_MS;
    let (h, files) = cmd(a.h, "head", later, req.clone(), &[]);
    assert_eq!(h["unchanged"], json!(true), "{h}");
    assert!(files.is_empty());
    let refreshed = commits_seen(&ro);
    assert_ne!(refreshed, before, "a day-old last_ok is refreshed");
    let (h, _) = cmd(a.h, "head", later + 1, req.clone(), &[]);
    assert_eq!(h["unchanged"], json!(true), "{h}");
    assert_eq!(commits_seen(&ro), refreshed);
    // 内容变了照常写新 head。
    a.write(later + 2, N2, "猫");
    let (h, files) = cmd(a.h, "head", later + 3, req, &[]);
    assert_eq!(h["unchanged"], json!(false), "{h}");
    assert_eq!(files.len(), 1);
}

/// 新代第一次同步成功（`head` 走完）记下时刻，之后的成功不改它：保留副本从这一刻起再留 14 天（`retained.rs`，D32）。
#[test]
fn the_first_successful_round_is_recorded_once() {
    use crate::store::gen4::retained::FIRST_SYNC_KEY;
    let a = Dev::new("d32first");
    let mut loc = Loc::new();
    a.write(T1 + 1, N1, "鯨");
    let first = |dir: &Path| -> Option<String> {
        Connection::open_with_flags(dir.join(GEN4_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap()
            .query_row(
                "SELECT value FROM srs_meta WHERE key = ?1",
                [FIRST_SYNC_KEY],
                |r| r.get(0),
            )
            .ok()
    };
    assert_eq!(first(&a.dir.0), None);
    round(&a, &mut loc, "loc", T1 + 10, Opts::default());
    assert_eq!(first(&a.dir.0), Some((T1 + 10).to_string()));
    a.write(T1 + 20, N2, "猫");
    let r = round(&a, &mut loc, "loc", T1 + 30, Opts::default());
    assert_eq!(r.head["unchanged"], json!(false), "{}", r.head);
    assert_eq!(first(&a.dir.0), Some((T1 + 10).to_string()));
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

/// 发件的切段目标（`segBytes`）夹在上限（[SEGMENT_TARGET_BYTES]）以内：调用方给得再大，切出的段也按上限切（读侧
/// 按 `MAX_BODY_RAW` 拒解压后过大的段，写者不能往上放）。测试钩子把上限调到 300 字节，不造 4 MB 的日志；同样的
/// 日志不设上限时一段就装下（对照），所以段数多于一说明是夹紧在起作用。
#[test]
fn outbox_clamps_the_segment_target_to_the_cap() {
    let a = Dev::new("g6seg");
    for i in 0..40 {
        a.write(T1 + i, [N1, N2, N3][i as usize % 3], &format!("v{i}"));
    }
    let seg_files = |loc: &Loc| {
        names_of(loc, &a.device())
            .iter()
            .filter(|n| n.starts_with("seg-"))
            .count()
    };
    let huge = Opts {
        seg_bytes: Some(u64::MAX / 2),
        ..Opts::default()
    };
    // 对照：上限是默认值时，这点日志一段就装下。
    let mut plain = Loc::new();
    round(&a, &mut plain, "loc-a", T1 + 100, huge);
    assert_eq!(seg_files(&plain), 1);
    // 上限 300 字节：调用方给的 `segBytes` 再大也按 300 切。
    super::sync::SEG_CAP_FOR_TEST.with(|c| c.set(Some(300)));
    let mut capped = Loc::new();
    round(&a, &mut capped, "loc-b", T1 + 101, huge);
    super::sync::SEG_CAP_FOR_TEST.with(|c| c.set(None));
    let small = Opts {
        seg_bytes: Some(300),
        ..Opts::default()
    };
    let mut explicit = Loc::new();
    round(&a, &mut explicit, "loc-c", T1 + 102, small);
    assert!(seg_files(&capped) >= 3, "{}", seg_files(&capped));
    assert_eq!(seg_files(&capped), seg_files(&explicit));
}

/// 本机写入一条载荷超过 `MAX_OP_PAYLOAD` 的改动（字段里塞了 16 MiB 以上的内嵌内容）：写命令报一句看得懂的错
/// （「一条改动太大」、大小、上限、什么都没存），不崩、不静默丢；什么都没落，之后的正常写入照常。
#[test]
fn a_write_over_the_payload_cap_is_refused_readably_and_nothing_lands() {
    use crate::gen4::op::{ERR_OP_TOO_LARGE, MAX_OP_PAYLOAD};
    let a = Dev::new("g6big");
    a.write(T1 + 1, N1, "before");
    let huge = "x".repeat(MAX_OP_PAYLOAD + 1);
    let items = vec![json!({"e": edit("note", N1, "f/fa", json!(huge)), "note": N1})];
    let blob = Value::Array(items).to_string().into_bytes();
    drop(huge);
    let e = raw(a.h, &g4req("apply", T1 + 2, json!({})), &[blob]).unwrap_err();
    assert!(e.contains(ERR_OP_TOO_LARGE), "{}", &e[..e.len().min(300)]);
    assert!(e.contains("16 MiB limit"), "{}", &e[..e.len().min(300)]);
    assert!(
        e.contains("nothing was saved"),
        "{}",
        &e[..e.len().min(300)]
    );
    assert_eq!(a.field(N1), Some(json!("before")));
    // 历史里只有之前那一条（没多出半截写入）；之后的写入照常。
    let hist = g4(a.h, "history", T1, json!({"kind": "note", "entity": N1}));
    assert_eq!(hist.as_array().unwrap().len(), 1, "{hist}");
    a.write(T1 + 3, N2, "after");
    assert_eq!(a.field(N2), Some(json!("after")));
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
/// 这里直接在真相层上推进那个槽，只测发件这一侧；`purge` 命令经生产路径落空洞、对端跟着落的端到端见
/// `sync_complete_tests.rs` `the_purge_command_voids_published_ops_everywhere`（G8-7b）。
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

/// 新根 `v4/meta.json` 一时读不到（最终一致的网盘 / 被删）而新根已经立过：旧根是围栏，或 Dart 列到新根下已有数据
/// （`v4Data`）。不能按围栏重建新根 meta——新集合的媒体根会从 `v4` 被改成 `v3`（围栏不带 `media`）——报
/// `srs_location_meta_unavailable`、一个字节不写；meta 放回后照常，媒体根仍是 `v4`。
#[test]
fn an_unreadable_new_root_meta_behind_a_fence_is_not_rebuilt() {
    let a = Dev::new("g87m");
    // 全新集合：立新根（媒体在 v4）与围栏。
    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": false, "has3": false, "locs": []}),
        &[],
    );
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["media"], json!("v4"));
    let meta = files
        .iter()
        .find(|(p, _)| p == "v4/meta.json")
        .unwrap()
        .1
        .clone();
    let fence = files
        .iter()
        .find(|(p, _)| p == "v3/meta.json")
        .unwrap()
        .1
        .clone();
    let mark = files
        .iter()
        .find_map(|(p, _)| p.strip_prefix("v4/loc/"))
        .unwrap()
        .to_owned();
    // 新根 meta 读不到、旧根是围栏：拒绝，不写。
    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": false, "has3": true, "locs": [mark]}),
        &[fence.clone()],
    );
    assert_eq!(r["state"], json!("refused"), "{r}");
    assert_eq!(r["code"], json!(ERR_META_UNAVAILABLE));
    assert!(
        files.is_empty(),
        "{:?}",
        files.iter().map(|f| &f.0).collect::<Vec<_>>()
    );
    // 旧根也读不到、但新根下已有数据：同样拒绝。
    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": false, "has3": false, "v4Data": true, "locs": [mark]}),
        &[],
    );
    assert_eq!(r["code"], json!(ERR_META_UNAVAILABLE), "{r}");
    assert!(files.is_empty());
    // 旧根读不到、Dart 也没列到数据，但新根下有 loc 标记：内核自己认得这是立过的新根，同样拒绝（不靠 Dart 的判断）。
    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": false, "has3": false, "locs": [mark]}),
        &[],
    );
    assert_eq!(r["code"], json!(ERR_META_UNAVAILABLE), "{r}");
    assert!(files.is_empty());
    // 新根下什么都列不到、只剩围栏（v4/ 被整个删了）：不重建，换一个码让界面说清楚怎么恢复。
    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": false, "has3": true, "locs": []}),
        &[fence.clone()],
    );
    assert_eq!(r["state"], json!("refused"), "{r}");
    assert_eq!(r["code"], json!(ERR_NEW_ROOT_MISSING), "{r}");
    assert!(files.is_empty());
    // 放回后照常：媒体根仍是 v4，什么都不重写。
    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": true, "has3": true, "locs": [mark]}),
        &[meta, fence],
    );
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["media"], json!("v4"));
    assert!(
        files.is_empty(),
        "{:?}",
        files.iter().map(|f| &f.0).collect::<Vec<_>>()
    );
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
pub(super) fn status_row(d: &Dev, device: &str) -> Value {
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

/// 改投影的同步命令（`ingest` / `ingest_finish` / `retire` / `rotate`）的回包一律带本机修订号与纪元（Dart
/// `_absorbLocalWrite` 的契约）；没分叉的 `ingest_finish` 什么都不改，修订号不推进。
#[test]
fn projecting_sync_replies_carry_the_local_revision() {
    let a = Dev::new("g87lr");
    let b = Dev::new("g87lrb");
    b.write(T1, N1, "鯨");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 1, Opts::default());
    let (v, _) = cmd(a.h, "ingest", T1 + 2, json!({}), &[]);
    let rev = v["localRevision"].as_i64().unwrap_or_else(|| panic!("{v}"));
    assert!(!v["localEpoch"].is_null(), "{v}");
    let (v, _) = cmd(a.h, "ingest_finish", T1 + 2, json!({}), &[]);
    assert_eq!(v["fork"], json!(false), "{v}");
    assert_eq!(v["localRevision"], json!(rev), "{v}");
    assert!(!v["localEpoch"].is_null(), "{v}");
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
        "ingest_commit",
        "replay_pending",
        "digest_buckets",
        "obsolete_ack",
    ] {
        let e = raw(a.h, &g4req(op, T1, json!({})), &[]).unwrap_err();
        assert!(e.contains(REMOVED), "{op}: {e}");
    }
    // 转发（G8-7b）已接线：缺参数报参数错，不再报未接线。
    for op in ["relay_outbox", "relay_ack"] {
        let e = raw(a.h, &g4req(op, T1, json!({})), &[]).unwrap_err();
        assert!(
            !e.contains(UNWIRED) && e.contains("missing location"),
            "{op}: {e}"
        );
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
        (super::sync::LOC_LAST_OK_SQL, 2),
        (crate::store::gen4::oldroot::OLDRUN_GET_SQL, 1),
        (crate::store::gen4::oldroot::OLDRUN_DROP_SQL, 2),
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

/// 收段（`ingest`）真落了东西、换身份（`rotate`）之后进程内刷新键（S1c `refresh.rs`）整份作废；什么都没收到的一轮不动。
/// 回包里不留分发器取走的内部键。
#[test]
fn landing_sync_commands_move_the_refresh_keys() {
    const KEYS: [&str; 5] = ["content", "structure", "rwkv", "stats", "landed"];
    let keys = |d: &Dev| g4(d.h, "refresh_keys", T1, json!({}));
    let a = Dev::new("g87rk");
    let b = Dev::new("g87rkb");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1, Opts::default());
    let k0 = keys(&a);
    round(&a, &mut loc, "loc", T1 + 1, Opts::default());
    assert_eq!(keys(&a), k0, "a round that received nothing");

    b.write(T1 + 2, N1, "鯨");
    round(&b, &mut loc, "loc", T1 + 3, Opts::default());
    let r = round(&a, &mut loc, "loc", T1 + 4, Opts::default());
    assert!(
        r.ingest
            .iter()
            .any(|v| v["applied"].as_u64().unwrap_or(0) > 0),
        "{r:?}"
    );
    for v in r.ingest.iter().chain(r.finish.iter()) {
        assert!(v.get("refreshTally").is_none(), "{v}");
    }
    assert_eq!(a.field(N1), Some(json!("鯨")));
    let k1 = keys(&a);
    for k in KEYS {
        assert_ne!(k1[k], k0[k], "{k}: {k0} {k1}");
    }

    let (v, _) = cmd(a.h, "rotate", T1 + 5, json!({}), &[]);
    assert!(v.get("refreshTally").is_none(), "{v}");
    let k2 = keys(&a);
    for k in KEYS {
        assert_ne!(k2[k], k1[k], "{k}: {k1} {k2}");
    }
}
