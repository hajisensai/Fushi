//! G8-7b 同步补全的端到端测试：一律经 C ABI，装置与一轮的走法沿用 `sync_tests.rs`（位置是内存里的「路径 → 字节」表）。
//!
//! - 媒体：两台设备经文件夹位置对账（本机文件 → 绑定操作 → 位置上「在不在」→ 清单 → 对端知道并下载落地）。
//! - 旧根接手：协议 3 的段在 `v3/` 上；两台各自接手（捡旧根 + 承袭上传）的设备与一台只连新根的新设备收敛到同一个
//!   状态；只有协议 1 `v2/` 的位置被明确拒绝、什么都不写；空位置（新集合）立围栏，存量位置不当成新集合。
//! - 清除：`purge` 命令把目标落成空洞，已传的段重切重传，对端收到后也落成空洞。
//! - 收段会话把 RWKV 刷新键攒到会话结束；状态页的 `seenAt` / `frozen` / `digestMismatch`；旧身份目录只删旧 head。
//! - 新语句的查询计划。

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::dispatch_tests::{T1, g4};
use super::media_sync::{BINDING_SQL, LOCAL_SQL};
use super::sync_oldroot::{ALIAS_COUNT_SQL, SAME_KEY_SQL, VOID_COUNT_SQL};
use super::sync_tests::{Dev, Loc, Opts, cmd, listing, names_of, round, status_row, sync_all};
use super::tests::{N1, N2};
use crate::gen4::op::tests::id;
use crate::store::gen4::files::GEN4_FILE;
use crate::store::sync2::collection_of;
use crate::store::sync2::tests::{P, tempdir};
use crate::sync2::id::Id;
use crate::sync2::keys::DeviceKey;
use crate::sync2::segment::{
    self as seg3, CHAIN_ZERO, Head as Head3, chain_next, chain_tag, head_file_name,
};
use crate::sync2::vv::{OpId, Vv};

// ---------------------------------------------------------------------- 媒体

/// 一台设备上的一次媒体对账（Dart `srs_media_sync.dart` 的上传半边）：哈希 → 定绑定 → 「上传」→ 记「在」。
fn media_publish(d: &Dev, root: &std::path::Path, names: &[&str], now: i64) -> Value {
    let root_s = root.to_str().unwrap();
    let (hash, _) = cmd(
        d.h,
        "media_hash",
        now,
        json!({"root": root_s, "names": names}),
        &[],
    );
    let (scan, _) = cmd(
        d.h,
        "media_scan",
        now,
        json!({"names": names, "files": hash["files"]}),
        &[],
    );
    let present: Vec<Value> = scan["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|i| i["have"] == json!(true))
        .map(|i| i["sha"].clone())
        .collect();
    let (rec, _) = cmd(
        d.h,
        "media_record",
        now,
        json!({"location": "loc/media#sha256", "present": present}),
        &[],
    );
    if !present.is_empty() {
        let n = rec["appended"].as_u64().unwrap() + rec["unchanged"].as_u64().unwrap();
        assert_eq!(n, present.len() as u64, "{rec}");
    }
    scan
}

/// 本机待发的媒体事实打成清单写上位置（`media_manifest_build` → 写 → `media_manifest_published`）。
fn manifests_out(d: &Dev, loc: &mut Loc, loc_id: &str, now: i64) -> bool {
    let (b, files) = cmd(
        d.h,
        "media_manifest_build",
        now,
        json!({"location": "loc", "loc": loc_id, "ownGens": []}),
        &[],
    );
    if b["built"] != json!(true) {
        return false;
    }
    let (path, bytes) = files.into_iter().next().unwrap();
    assert_eq!(b["path"], json!(path));
    loc.insert(format!("v4/{path}"), bytes.clone());
    let (p, _) = cmd(
        d.h,
        "media_manifest_published",
        now,
        json!({"location": "loc"}),
        &[bytes],
    );
    assert!(p["cleared"].as_u64().unwrap() > 0, "{p}");
    true
}

/// 收位置上别的设备的清单（`media_manifests` → 读 → `media_manifest_ingest`）。
fn manifests_in(d: &Dev, loc: &Loc, now: i64) -> Value {
    let (m, _) = cmd(
        d.h,
        "media_manifests",
        now,
        json!({"location": "loc", "listing": listing(loc)}),
        &[],
    );
    let paths: Vec<String> = m["fetch"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap().to_owned())
        .collect();
    let got: Vec<Option<Vec<u8>>> = paths
        .iter()
        .map(|p| loc.get(&format!("v4/{p}")).cloned())
        .collect();
    let present: Vec<bool> = got.iter().map(Option::is_some).collect();
    let blobs: Vec<Vec<u8>> = got.into_iter().flatten().collect();
    cmd(
        d.h,
        "media_manifest_ingest",
        now,
        json!({"location": "loc", "paths": paths, "present": present}),
        &blobs,
    )
    .0
}

fn loc_id(loc: &Loc) -> String {
    loc.keys()
        .filter_map(|k| k.strip_prefix("v4/loc/"))
        .min()
        .unwrap()
        .to_owned()
}

/// 两台设备经文件夹位置对账媒体：A 的文件绑定、记成「在」、发清单；B 收段拿到绑定、收清单知道位置上有、下载落地后
/// 记成与绑定对齐；A 再改文件 → 新绑定传到 B，B 的 `media_scan` 要下载新内容。
#[test]
fn media_reconciles_between_two_devices_through_a_folder_location() {
    let a = Dev::new("g87bma");
    let b = Dev::new("g87bmb");
    let ra = tempdir::new("g87bma-media");
    let rb = tempdir::new("g87bmb-media");
    std::fs::write(ra.0.join("x.png"), b"hello").unwrap();
    let mut loc = Loc::new();
    round(&a, &mut loc, "loc", T1 + 1, Opts::default());
    let scan = media_publish(&a, &ra.0, &["x.png"], T1 + 2);
    assert_eq!(scan["appended"], json!(1), "{scan}");
    let sha = scan["items"][0]["sha"].as_str().unwrap().to_owned();
    assert_eq!(scan["items"][0]["have"], json!(true));
    // 第二次对账：文件没变，什么都不追加。
    let again = media_publish(&a, &ra.0, &["x.png"], T1 + 3);
    assert_eq!(again["appended"], json!(0), "{again}");
    round(&a, &mut loc, "loc", T1 + 4, Opts::default());
    let lid = loc_id(&loc);
    assert!(manifests_out(&a, &mut loc, &lid, T1 + 5));
    // 没有新事实：不烧代号。
    assert!(!manifests_out(&a, &mut loc, &lid, T1 + 6));

    round(&b, &mut loc, "loc", T1 + 10, Opts::default());
    let ing = manifests_in(&b, &loc, T1 + 11);
    assert_eq!(ing["ingested"], json!(1), "{ing}");
    assert_eq!(ing["errors"], json!([]), "{ing}");
    let (known, _) = cmd(
        b.h,
        "media_known",
        T1 + 11,
        json!({"location": "loc/media#sha256"}),
        &[],
    );
    assert_eq!(known["present"], json!([sha]), "{known}");
    // 再收一次：没有新清单。
    assert_eq!(manifests_in(&b, &loc, T1 + 12)["ingested"], json!(0));
    // B 本机没有文件：要下载 A 绑定的内容。
    let (s, _) = cmd(
        b.h,
        "media_scan",
        T1 + 12,
        json!({"names": ["x.png"], "files": []}),
        &[],
    );
    assert_eq!(s["items"][0]["sha"], json!(sha), "{s}");
    assert_eq!(s["items"][0]["have"], json!(false));
    std::fs::write(rb.0.join("x.png"), b"hello").unwrap();
    let (l, _) = cmd(
        b.h,
        "media_landed",
        T1 + 13,
        json!({"root": rb.0.to_str().unwrap(), "items": [{"name": "x.png", "sha": sha}]}),
        &[],
    );
    assert_eq!(l["appended"], json!(0), "{l}");
    let s = media_publish(&b, &rb.0, &["x.png"], T1 + 14);
    assert_eq!(s["appended"], json!(0), "{s}");
    assert_eq!(s["items"][0]["have"], json!(true));

    // A 改了文件：新绑定，B 上次对齐之后没改过本地文件 → 下载新内容（不是把旧内容绑回去）。
    std::fs::write(ra.0.join("x.png"), b"hello, again").unwrap();
    let s = media_publish(&a, &ra.0, &["x.png"], T1 + 20);
    assert_eq!(s["appended"], json!(1), "{s}");
    let sha2 = s["items"][0]["sha"].as_str().unwrap().to_owned();
    assert_ne!(sha2, sha);
    round(&a, &mut loc, "loc", T1 + 21, Opts::default());
    round(&b, &mut loc, "loc", T1 + 22, Opts::default());
    let (hash, _) = cmd(
        b.h,
        "media_hash",
        T1 + 23,
        json!({"root": rb.0.to_str().unwrap(), "names": ["x.png"]}),
        &[],
    );
    let (s, _) = cmd(
        b.h,
        "media_scan",
        T1 + 23,
        json!({"names": ["x.png"], "files": hash["files"]}),
        &[],
    );
    assert_eq!(s["items"][0]["sha"], json!(sha2), "{s}");
    assert_eq!(s["items"][0]["have"], json!(false));
    assert_eq!(s["appended"], json!(0));
    // 过期名字的内容（不被存活名字绑定）。
    let (doomed, _) = cmd(
        b.h,
        "media_doomed",
        T1 + 24,
        json!({"expired": ["x.png"], "live": []}),
        &[],
    );
    assert_eq!(doomed["sha"], json!([sha2]));
}

// ---------------------------------------------------------------------- 旧根接手

pub(super) const OLD: u8 = 0xd7;

pub(super) fn old_key() -> DeviceKey {
    DeviceKey::from_seed(&[OLD; 32])
}

/// 协议 3 旧根：设备 OLD 的 [n] 条操作按 [cuts] 切段写在 `v3/devices/<OLD>/`，带它的 head 与旧根 meta。
fn old_root(loc: &mut Loc, n: u64, cuts: &[(u64, u64)]) {
    old_root_with(
        loc,
        &crate::sync2::segment::tests::ops_for(id(OLD), n),
        cuts,
    );
}

/// [old_root]，操作由调用方给（设备 OLD 的 seq 1..=n，`ops[i].id.seq == i + 1`）。
pub(super) fn old_root_with(loc: &mut Loc, ops: &[crate::sync2::op::Op], cuts: &[(u64, u64)]) {
    old_root_signed(loc, ops, cuts, &old_key(), "old phone");
}

/// [old_root_with]，段与 head 由 [signer] 签、head 自报名字 [name]（冒充 OLD 的测试用）。
pub(super) fn old_root_signed(
    loc: &mut Loc,
    ops: &[crate::sync2::op::Op],
    cuts: &[(u64, u64)],
    signer: &DeviceKey,
    name: &str,
) {
    let dev = id(OLD);
    let n = ops.len() as u64;
    let mut chain = CHAIN_ZERO;
    let chains: Vec<_> = ops
        .iter()
        .map(|op| {
            chain = chain_next(&chain, op);
            chain
        })
        .collect();
    let mut segments = Vec::new();
    for &(a, b) in cuts {
        let prev = if a == 1 {
            CHAIN_ZERO
        } else {
            chains[a as usize - 2]
        };
        let (h, bytes) = seg3::pack(
            collection_of(P),
            &ops[a as usize - 1..b as usize],
            prev,
            signer,
            None,
        )
        .unwrap();
        loc.insert(
            format!("v3/devices/{}/{}", dev.text(), h.file_name()),
            bytes,
        );
        segments.push((a, b, chain_tag(&chains[b as usize - 1])));
    }
    let head = Head3 {
        gen: 1,
        protocol: 3,
        min_reader: 3,
        collection: collection_of(P),
        device: dev,
        public: signer.public(),
        seq: n,
        chain: chains[n as usize - 1],
        segments,
        ack: Vv::new(),
        digest: String::new(),
        at_ms: T1,
        name: name.into(),
        ext: None,
    };
    loc.insert(
        format!("v3/devices/{}/{}", dev.text(), head.file_name()),
        head.encode(signer),
    );
    loc.entry("v3/meta.json".into()).or_insert_with(|| {
        json!({"collection": collection_of(P).text(), "v": 3, "minReader": 3})
            .to_string()
            .into_bytes()
    });
}

/// 旧根清单（`oldroot_scan` 的 `listing`，路径相对 `v3/`）。
fn old_listing(loc: &Loc) -> Vec<Value> {
    loc.iter()
        .filter_map(|(k, v)| {
            k.strip_prefix("v3/")
                .filter(|r| r.starts_with("devices/"))
                .map(|r| json!({"path": r, "size": v.len(), "modified": 7}))
        })
        .collect()
}

/// 捡旧根（Dart：扫 → 读 head 与段 → 一批收完 → 带 `settle` 收尾）。回 (扫的回包, 合起来的收的回包)。
pub(super) fn take_old_root(d: &Dev, loc: &Loc, now: i64) -> (Value, Option<Value>) {
    take_old_root_sliced(d, loc, now, None, false)
}

/// 照搬 Dart `srsSync4TakeOldRoot` 的循环捡旧根：扫；按 `maxItems` 切片交段（交完的从队首去掉，`drainMore` 就不带段
/// 再交），每片带这一轮的 `fp`；最后不带段、带 `settle` 与清单交一次。[reverse] = 倒着交（后面的段先到）。回 (扫的
/// 回包, 合起来的回包：`landed` / `delivered` 求和、`errors` 拼接、`slices` 片数、`drains` 不带段的投递片数、
/// `maxDelivered` 单片最多投出的、`recorded` = 收尾那一次记了指纹没有)。
fn take_old_root_sliced(
    d: &Dev,
    loc: &Loc,
    now: i64,
    max_items: Option<u64>,
    reverse: bool,
) -> (Value, Option<Value>) {
    let listing = old_listing(loc);
    let (scan, _) = cmd(
        d.h,
        "oldroot_scan",
        now,
        json!({"location": "loc", "listing": listing}),
        &[],
    );
    if scan["changed"] != json!(true) {
        return (scan, None);
    }
    let strs = |v: &Value| -> Vec<String> {
        v.as_array()
            .unwrap()
            .iter()
            .map(|p| p.as_str().unwrap().to_owned())
            .collect()
    };
    let fp = scan["fp"].clone();
    let mut heads: Vec<Vec<u8>> = strs(&scan["heads"])
        .iter()
        .map(|p| loc[&format!("v3/{p}")].clone())
        .collect();
    let mut fetch = strs(&scan["fetch"]);
    if reverse {
        fetch.reverse();
    }
    let (mut landed, mut delivered, mut slices, mut drains, mut max_delivered) =
        (0u64, 0u64, 0u64, 0u64, 0u64);
    let mut errors: Vec<Value> = Vec::new();
    let mut absorb = |v: &Value| {
        landed += v["landed"].as_u64().unwrap();
        let n = v["delivered"].as_u64().unwrap();
        delivered += n;
        max_delivered = max_delivered.max(n);
        errors.extend(v["errors"].as_array().unwrap().iter().cloned());
    };
    loop {
        let blobs: Vec<Vec<u8>> = heads
            .iter()
            .cloned()
            .chain(fetch.iter().map(|p| loc[&format!("v3/{p}")].clone()))
            .collect();
        let (v, _) = cmd(
            d.h,
            "oldroot_ingest",
            now,
            json!({"location": "loc", "fp": fp, "paths": fetch, "heads": heads.len(), "maxItems": max_items}),
            &blobs,
        );
        absorb(&v);
        slices += 1;
        assert!(slices < 200, "{v}");
        if fetch.is_empty() {
            drains += 1;
        }
        heads.clear();
        let done = v["rest"].as_u64().unwrap() as usize;
        let spent = v["spent"].as_u64().unwrap();
        if let Some(m) = max_items {
            assert!(v["delivered"].as_u64().unwrap() <= m, "{v}");
        }
        if done >= fetch.len() {
            if v["drainMore"] == json!(true) {
                assert!(spent > 0, "a drain slice must deliver something: {v}");
                fetch.clear();
                continue;
            }
            break;
        }
        assert!(!(done == 0 && spent == 0), "no progress: {v}");
        fetch.drain(..done);
    }
    let (fin, _) = cmd(
        d.h,
        "oldroot_ingest",
        now,
        json!({"location": "loc", "fp": fp, "listing": listing, "paths": [], "heads": 0, "settle": true}),
        &[],
    );
    absorb(&fin);
    let out = json!({
        "landed": landed,
        "delivered": delivered,
        "errors": errors,
        "slices": slices,
        "drains": drains,
        "maxDelivered": max_delivered,
        "recorded": fin["recorded"],
    });
    (scan, Some(out))
}

/// 承袭上传（Dart：`heritage_plan` → 读 → `heritage_outbox` → 写 → `heritage_ack`）。回写上的文件数。
pub(super) fn upload_heritage(d: &Dev, loc: &mut Loc, now: i64) -> usize {
    let (plan, _) = cmd(
        d.h,
        "heritage_plan",
        now,
        json!({"progress": "loc#plain", "listing": listing(loc)}),
        &[],
    );
    if plan["skip"] == json!(true) {
        return 0;
    }
    let paths: Vec<String> = plan["read"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap().to_owned())
        .collect();
    let blobs: Vec<Vec<u8>> = paths
        .iter()
        .map(|p| loc[&format!("v4/{p}")].clone())
        .collect();
    let (out, files) = cmd(d.h, "heritage_outbox", now, json!({"paths": paths}), &blobs);
    assert_eq!(out["blocked"], json!([]), "{out}");
    assert_eq!(out["keptForked"], json!([]), "{out}");
    assert_eq!(out["errors"], json!([]), "{out}");
    let n = files.len();
    for (p, b) in files {
        assert!(p.contains("/hrt-"), "{p}");
        loc.insert(format!("v4/{p}"), b);
    }
    cmd(
        d.h,
        "heritage_ack",
        now,
        json!({"progress": "loc#plain", "listing": listing(loc)}),
        &[],
    );
    n
}

/// 一轮带旧根接手：根 → 收新根 → 捡旧根 → 承袭上传 → 发本机原生段 → head（`round` 的根与收、发两半之间插进旧根两步，
/// 用两次 `round`：第一次立根并收，第二次发；中间做旧根）。
fn takeover_round(d: &Dev, loc: &mut Loc, now: i64) -> (Option<Value>, usize) {
    round(d, loc, "loc", now, Opts::default());
    let (_, ing) = take_old_root(d, loc, now);
    let up = upload_heritage(d, loc, now);
    round(d, loc, "loc", now + 1, Opts::default());
    (ing, up)
}

/// 旧根接手（硬条件）：协议 3 位置上有旧设备 OLD 的历史；两台各自升级的设备 A、B 各自捡旧根、各自承袭上传（B 看见 A
/// 已传的承袭段就不重传）；从没跑过协议 3 的新设备 C 只连新根，从承袭段拿到 OLD 的全部历史。三台的派生层相同。旧根
/// 指纹记下之后，清单没变的下一轮不再读；承袭指纹没变的下一轮不再对账。
#[test]
fn old_root_takeover_reaches_migrated_and_new_devices_alike() {
    let mut a = Dev::new("g87boa");
    let mut b = Dev::new("g87bob");
    let mut c = Dev::new("g87boc");
    let mut loc = Loc::new();
    old_root(&mut loc, 12, &[(1, 5), (6, 12)]);
    a.write(T1 + 1, N1, "鯨");
    b.write(T1 + 2, N2, "猫");

    let (ing, up) = takeover_round(&a, &mut loc, T1 + 10);
    let ing = ing.expect("a scans the old root");
    assert_eq!(ing["recorded"], json!(true), "{ing}");
    assert_eq!(ing["errors"], json!([]), "{ing}");
    assert_eq!(ing["landed"], json!(12), "{ing}");
    // a 库非空，第一次见到的 OLD 是待确认；承袭段只替本机信任的作者传（`inherit.rs`，G10-4），所以确认之后才传。
    assert_eq!(status_row(&a, &id(OLD).text())["trust"], json!("pending"));
    assert_eq!(up, 0, "a does not vouch for OLD before confirming it");
    cmd(
        a.h,
        "trust",
        T1 + 11,
        json!({"device": id(OLD).text(), "trust": true}),
        &[],
    );
    let up = upload_heritage(&a, &mut loc, T1 + 11);
    assert!(up > 0, "a uploads the heritage it took");
    // 旧根清单没变：不再读；承袭：不再对账。
    let (scan, again) = take_old_root(&a, &loc, T1 + 12);
    assert_eq!(scan["changed"], json!(false), "{scan}");
    assert!(again.is_none());
    assert_eq!(upload_heritage(&a, &mut loc, T1 + 12), 0);

    // b 库非空，第一次见到的 a 是待确认（`truth/trust.rs`），a 代传的承袭段要等 b 确认 a 之后才收（D20）。
    round(&b, &mut loc, "loc", T1 + 19, Opts::default());
    assert_eq!(status_row(&b, &a.device())["trust"], json!("pending"));
    cmd(
        b.h,
        "trust",
        T1 + 19,
        json!({"device": a.device(), "trust": true}),
        &[],
    );
    let (ing, up) = takeover_round(&b, &mut loc, T1 + 20);
    assert_eq!(ing.expect("b scans")["recorded"], json!(true));
    assert_eq!(up, 0, "b sees a's heritage segments and uploads nothing");

    // 新设备：只连新根（不捡旧根），从承袭段拿到旧历史。
    sync_all(&[&a, &b, &c], &mut loc, T1 + 30, Opts::default());
    for d in [&a, &b, &c] {
        assert_eq!(d.field(N1), Some(json!("鯨")));
        assert_eq!(d.field(N2), Some(json!("猫")));
        assert_eq!(d_old_len(d), 12, "every device holds OLD's whole log");
    }
    let (da, db, dc) = (a.derived(), b.derived(), c.derived());
    assert_eq!(da, db);
    assert_eq!(da, dc);
}

/// 围栏挡不住的那两种（规划 §6「meta 先删后传的窗口」「一轮进行中被立围栏」，oldroot.rs「为什么每轮都要捡」）：
/// 旧根接手、指纹记下之后，一台还在跑协议 3 的设备趁云盘先删后传的窗口重建了 `minReader 3` 的旧 meta，又把它那一轮
/// 照常写完（旧根多了一段、head 换了）。升级过的设备下一轮：围栏重立（`moved: v4`）、只读新多出的那段、承袭上传；
/// 只连新根的设备照样拿到这台旧设备的全部历史，各台派生层相同。（G8-7c 按规划 §6 补的端到端用例。）
#[test]
fn an_old_client_writing_past_the_fence_is_still_taken_over() {
    let mut a = Dev::new("g87cfa");
    let mut c = Dev::new("g87cfc");
    let mut loc = Loc::new();
    old_root(&mut loc, 12, &[(1, 5), (6, 12)]);
    a.write(T1 + 1, N1, "鯨");
    let (ing, up) = takeover_round(&a, &mut loc, T1 + 10);
    assert_eq!(ing.expect("a scans")["recorded"], json!(true));
    // a 库非空，第一次见到的 OLD 是待确认；承袭段只替本机信任的作者传（`inherit.rs`，G10-4），确认之后才传。
    assert_eq!(status_row(&a, &id(OLD).text())["trust"], json!("pending"));
    assert_eq!(up, 0, "a does not vouch for OLD before confirming it");
    cmd(
        a.h,
        "trust",
        T1 + 11,
        json!({"device": id(OLD).text(), "trust": true}),
        &[],
    );
    assert!(upload_heritage(&a, &mut loc, T1 + 11) > 0);
    sync_all(&[&a, &c], &mut loc, T1 + 20, Opts::default());
    assert_eq!(d_old_len(&c), 12);

    // 协议 3 的设备：重建旧 meta（先删后传的窗口），再把这一轮写完（新段 13..15 与新 head）。
    loc.insert(
        "v3/meta.json".into(),
        json!({"collection": collection_of(P).text(), "v": 3, "minReader": 3})
            .to_string()
            .into_bytes(),
    );
    old_root(&mut loc, 15, &[(1, 5), (6, 12), (13, 15)]);

    let (ing, up) = takeover_round(&a, &mut loc, T1 + 30);
    let ing = ing.expect("the old root changed, a reads it again");
    assert_eq!(
        ing["landed"],
        json!(3),
        "only the new segment is read: {ing}"
    );
    assert_eq!(ing["errors"], json!([]), "{ing}");
    assert_eq!(ing["recorded"], json!(true), "{ing}");
    assert!(up > 0, "a uploads the new heritage");
    let fence: Value = serde_json::from_slice(&loc["v3/meta.json"]).unwrap();
    assert_eq!(fence["moved"], json!("v4"), "fence put back: {fence}");
    assert_eq!(fence["minReader"], json!(crate::gen4::MIN_READER));

    sync_all(&[&a, &c], &mut loc, T1 + 40, Opts::default());
    for d in [&a, &c] {
        assert_eq!(d_old_len(d), 15, "every device holds OLD's whole log");
        assert_eq!(d.field(N1), Some(json!("鯨")));
    }
    assert_eq!(a.derived(), c.derived());
}

/// 旧根接手按 `maxItems` 切片（G8-7c）：迁移后第一次捡旧根，几段旧根分在几个写事务里收（一段不在中途切），每个事务
/// 把这一批的结论记到这一轮指纹名下；交完之后不带段的收尾那一次凭前面几批的结论记下指纹，下一轮清单不变不再读。
/// 倒着交（后面的段先到、整段停进承袭待投递）时，前面那段到了之后的投递也按预算切成几个不带段的投递片。
#[test]
fn old_root_takeover_is_sliced_and_still_records_its_fingerprint() {
    for reverse in [false, true] {
        let a = Dev::new(if reverse { "g87bsr" } else { "g87bsf" });
        let mut loc = Loc::new();
        old_root(&mut loc, 12, &[(1, 5), (6, 12)]);
        round(&a, &mut loc, "loc", T1 + 10, Opts::default());
        let (_, ing) = take_old_root_sliced(&a, &loc, T1 + 10, Some(3), reverse);
        let ing = ing.expect("a scans the old root");
        assert_eq!(ing["errors"], json!([]), "{ing}");
        assert_eq!(ing["recorded"], json!(true), "{ing}");
        assert!(
            ing["slices"].as_u64().unwrap() >= 2,
            "one segment per slice: {ing}"
        );
        assert_eq!(d_old_len(&a), 12);
        if reverse {
            assert!(ing["drains"].as_u64().unwrap() >= 2, "{ing}");
            assert!(ing["maxDelivered"].as_u64().unwrap() <= 3, "{ing}");
            assert_eq!(ing["delivered"], json!(7), "{ing}");
        }
        let (scan, again) = take_old_root(&a, &loc, T1 + 11);
        assert_eq!(scan["changed"], json!(false), "{scan}");
        assert!(again.is_none());
    }
}

/// 设备上 OLD 的承袭日志末尾。
/// 收段让路覆盖承袭段：承袭段在段中途不停，但它落的槽计入 `maxItems` 预算——预算用完之后这一片不再开下一段（下一段
/// 留到下一个事务），回包 `spent` 报出这一片做的新工作。新设备 c 先认位置、读 head，再把承袭段与 a 的原生段放在同一
/// 批里按预算 1 交。
#[test]
fn heritage_segments_count_toward_the_ingest_budget() {
    let a = Dev::new("g87bha");
    let c = Dev::new("g87bhc");
    let mut loc = Loc::new();
    old_root(&mut loc, 12, &[(1, 5), (6, 12)]);
    a.write(T1 + 1, N1, "鯨");
    takeover_round(&a, &mut loc, T1 + 10);
    // a 库非空，OLD 待确认：确认之后才替它承袭上传（`inherit.rs`，G10-4）。
    cmd(
        a.h,
        "trust",
        T1 + 11,
        json!({"device": id(OLD).text(), "trust": true}),
        &[],
    );
    assert!(upload_heritage(&a, &mut loc, T1 + 11) > 0);
    // c 只认位置、读 head（认得 a 的公钥），不收。
    let locs: Vec<String> = loc
        .keys()
        .filter_map(|k| k.strip_prefix("v4/loc/").map(str::to_owned))
        .collect();
    let mut root_blobs = Vec::new();
    root_blobs.extend(loc.get("v4/meta.json").cloned());
    root_blobs.extend(loc.get("v3/meta.json").cloned());
    let (root, _) = cmd(
        c.h,
        "location_root",
        T1 + 20,
        json!({"location": "loc", "has4": true, "has3": loc.contains_key("v3/meta.json"), "locs": locs}),
        &root_blobs,
    );
    let heads: Vec<Vec<u8>> = loc
        .iter()
        .filter(|(k, _)| k.starts_with("v4/devices/") && k.contains("/head-"))
        .map(|(_, v)| v.clone())
        .collect();
    cmd(
        c.h,
        "plan",
        T1 + 20,
        json!({"location": "loc", "loc": root["loc"], "listing": listing(&loc)}),
        &heads,
    );
    let pick = |part: &str| -> Vec<Vec<u8>> {
        loc.iter()
            .filter(|(k, _)| k.starts_with("v4/devices/") && k.contains(part))
            .map(|(_, v)| v.clone())
            .collect()
    };
    let hrt = pick("/hrt-");
    let segs = pick("/seg-");
    assert!(!hrt.is_empty() && !segs.is_empty());
    let mut pending: Vec<Vec<u8>> = hrt.iter().chain(segs.iter()).cloned().collect();
    let mut txs = 0;
    loop {
        let (v, _) = cmd(c.h, "ingest", T1 + 21, json!({"maxItems": 1}), &pending);
        let n = v["rest"].as_u64().unwrap() as usize;
        let spent = v["spent"].as_u64().unwrap();
        if txs == 0 {
            // 这一片落的承袭槽全部计进了预算（不计的话 spent 只数原生项、远小于落下的旧历史）。
            let old = d_old_len(&c);
            assert!(old > 0 && spent >= old, "{v} old={old}");
            assert!(
                n <= hrt.len() && n < pending.len(),
                "the native segments wait for the next slice: {v}"
            );
        }
        txs += 1;
        if n >= pending.len() {
            break;
        }
        assert!(n > 0 || spent > 0, "no progress: {v}");
        pending.drain(..n);
        assert!(txs < 64, "{v}");
    }
    assert_eq!(d_old_len(&c), 12);
}

pub(super) fn d_old_len(d: &Dev) -> u64 {
    let st = g4(d.h, "status", T1, json!({}));
    st["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["device"] == json!(id(OLD).text()))
        .map_or(0, |r| r["applied"].as_u64().unwrap())
}

/// 位置的根：空位置（新集合）立围栏与墓碑 head、媒体根是新根；有 `v3/meta.json` 的存量位置媒体根是旧根、不立墓碑；
/// 只有协议 1 `v2/` 的位置明确拒绝（机读码）、一个字节都不写。
#[test]
fn a_new_collection_is_never_taken_for_an_existing_one() {
    let a = Dev::new("g87bfr");
    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc", "has4": false, "has3": false, "has2": false, "locs": []}),
        &[],
    );
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["media"], json!("v4"));
    assert!(!r["ensure"].as_array().unwrap().is_empty(), "{r}");
    assert!(files.iter().any(|(p, _)| p == "v3/meta.json"));

    let (r, files) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc2", "has4": false, "has3": false, "has2": true, "locs": []}),
        &[],
    );
    assert_eq!(r["state"], json!("refused"), "{r}");
    assert_eq!(
        r["code"],
        json!(crate::store::gen4::oldroot::ERR_PROTOCOL1_ROOT)
    );
    assert!(files.is_empty());

    let mut loc = Loc::new();
    old_root(&mut loc, 2, &[(1, 2)]);
    let (r, _) = cmd(
        a.h,
        "location_root",
        T1,
        json!({"location": "loc3", "has4": false, "has3": true, "has2": true, "locs": []}),
        &[loc["v3/meta.json"].clone()],
    );
    assert_eq!(r["state"], json!("ok"), "{r}");
    assert_eq!(r["media"], json!("v3"));
    assert_eq!(r["ensure"], json!([]));
}

// ---------------------------------------------------------------------- 清除

/// `purge` 命令把目标落成空洞（同一个事务）：已传的段重切重传，对端收到清除后也把它落成空洞，派生层相同。
#[test]
fn the_purge_command_voids_published_ops_everywhere() {
    let mut a = Dev::new("g87bpa");
    let mut b = Dev::new("g87bpb");
    a.write(T1 + 1, N1, "秘密");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1 + 2, Opts::default());
    assert_eq!(b.field(N1), Some(json!("秘密")));
    let dev = Id::parse(&a.device()).unwrap();
    let whole = |d: &mut Dev| -> Option<bool> {
        d.direct(|t, col| {
            Ok(t.entry(
                col,
                &OpId {
                    device: dev,
                    seq: 2,
                },
            )?
            .map(|e| e.is_whole()))
        })
    };
    assert_eq!(whole(&mut a), Some(true));
    let (v, _) = cmd(
        a.h,
        "purge",
        T1 + 3,
        json!({"kind": "note", "entities": [N1]}),
        &[],
    );
    assert!(v.get("localRevision").is_some(), "{v}");
    assert_eq!(whole(&mut a), Some(false), "the purge voids the target");
    let r = round(&a, &mut loc, "loc", T1 + 4, Opts::default());
    assert!(r.batches >= 1);
    let r = round(&b, &mut loc, "loc", T1 + 5, Opts::default());
    assert!(
        r.ingest
            .iter()
            .any(|v| v["voided"].as_u64().unwrap_or(0) > 0),
        "{:?}",
        r.ingest
    );
    assert_eq!(whole(&mut b), Some(false), "the peer voids it too");
    sync_all(&[&a, &b], &mut loc, T1 + 6, Opts::default());
    assert_eq!(a.derived(), b.derived());
}

// ---------------------------------------------------------------------- 收段会话、状态、旧身份

/// 收段会话（`ingest_begin` … `ingest_end`）期间 RWKV 键不动、别的键照常推进；会话结束放出一次。
#[test]
fn an_ingest_session_holds_the_rwkv_key_until_it_ends() {
    let keys = |d: &Dev| g4(d.h, "refresh_keys", T1, json!({}));
    let a = Dev::new("g87bha");
    let b = Dev::new("g87bhb");
    let mut loc = Loc::new();
    sync_all(&[&a, &b], &mut loc, T1, Opts::default());
    b.write(T1 + 1, N1, "鯨");
    round(&b, &mut loc, "loc", T1 + 2, Opts::default());
    let k0 = keys(&a);
    cmd(a.h, "ingest_begin", T1 + 3, json!({}), &[]);
    let r = round(&a, &mut loc, "loc", T1 + 3, Opts::default());
    assert!(
        r.ingest
            .iter()
            .any(|v| v["applied"].as_u64().unwrap_or(0) > 0)
    );
    let k1 = keys(&a);
    assert_ne!(k1["content"], k0["content"]);
    assert_eq!(k1["rwkv"], k0["rwkv"], "held during the session");
    cmd(a.h, "ingest_end", T1 + 4, json!({}), &[]);
    let k2 = keys(&a);
    assert_ne!(k2["rwkv"], k1["rwkv"], "released once at the end");
    cmd(a.h, "ingest_end", T1 + 5, json!({}), &[]);
    assert_eq!(
        keys(&a)["rwkv"],
        k2["rwkv"],
        "ending twice releases nothing"
    );
}

/// 状态页：对端的 `seenAt` = 它最新 head 的写出时刻；同一个版本向量下摘要不同 → `digestMismatch` + `warning`；换身份
/// 之后旧身份 `frozen`。
#[test]
fn status_reports_seen_at_digest_mismatch_and_frozen_identities() {
    let mut a = Dev::new("g87bsa");
    let b = Dev::new("g87bsb");
    let mut loc = Loc::new();
    a.write(T1 + 1, N1, "鯨");
    sync_all(&[&a, &b], &mut loc, T1 + 10, Opts::default());
    let bd = b.device();
    let row = status_row(&a, &bd);
    assert_eq!(row["seenAt"], json!(T1 + 10), "{row}");
    assert_eq!(row["digestMismatch"], json!(false), "{row}");
    assert_eq!(row["frozen"], json!(false));
    // 对端 head 记下的摘要被改成别的（同一个版本向量）：报不一致。
    let bid = Id::parse(&bd).unwrap();
    a.direct(|t, col| {
        let p = t.peer(col, &bid)?.unwrap();
        let mut ext: serde_json::Map<String, Value> =
            serde_json::from_str(p.ext.as_deref().unwrap()).unwrap();
        ext.insert(super::sync::SEEN_DIGEST_KEY.into(), json!("00"));
        t.conn()
            .execute(
                "UPDATE peers SET ext = ?1 WHERE col = ?2 AND device = ?3",
                rusqlite::params![Value::Object(ext).to_string(), col, &bid.0[..]],
            )
            .map_err(|e| e.to_string())?;
        Ok(())
    });
    let row = status_row(&a, &bd);
    assert_eq!(row["digestMismatch"], json!(true), "{row}");
    assert_eq!(
        row["warning"],
        json!(super::writes_local::DIGEST_MISMATCH_WARNING)
    );
    // 换身份：旧身份冻结。
    let before = a.device();
    cmd(a.h, "rotate", T1 + 20, json!({}), &[]);
    assert_ne!(a.device(), before);
    let row = status_row(&a, &before);
    assert_eq!(row["frozen"], json!(true), "{row}");
}

/// 旧身份目录清理：`obsolete` 报出本机的旧身份；`obsolete_former` 只删它目录里比最新 head 旧两代以上的 head，段一个
/// 不删；别的设备、归档位置什么都不删。
#[test]
fn obsolete_former_deletes_only_old_heads_of_former_identities() {
    let a = Dev::new("g87bfo");
    let b = Dev::new("g87bfob");
    let mut loc = Loc::new();
    a.write(T1 + 1, N1, "鯨");
    sync_all(&[&a, &b], &mut loc, T1 + 2, Opts::default());
    let former = a.device();
    cmd(a.h, "rotate", T1 + 3, json!({}), &[]);
    round(&a, &mut loc, "loc", T1 + 4, Opts::default());
    let (obs, _) = cmd(
        a.h,
        "obsolete",
        T1 + 5,
        json!({"progress": "loc#plain", "present": names_of(&loc, &a.device())}),
        &[],
    );
    assert_eq!(obs["former"], json!([former]), "{obs}");
    let tag = chain_tag(&CHAIN_ZERO);
    let mut present: Vec<String> = (1..=4).map(|g| head_file_name(g, &tag)).collect();
    let segs: Vec<String> = names_of(&loc, &former)
        .into_iter()
        .filter(|n| n.starts_with("seg-"))
        .collect();
    assert!(!segs.is_empty());
    present.extend(segs);
    let (v, _) = cmd(
        a.h,
        "obsolete_former",
        T1 + 6,
        json!({"device": former, "present": present}),
        &[],
    );
    let del: Vec<&str> = v["delete"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap())
        .collect();
    assert_eq!(
        del,
        vec![
            format!("devices/{former}/{}", head_file_name(1, &tag)),
            format!("devices/{former}/{}", head_file_name(2, &tag)),
        ],
        "{v}"
    );
    for (dev, archive) in [(b.device(), false), (former.clone(), true)] {
        let (v, _) = cmd(
            a.h,
            "obsolete_former",
            T1 + 7,
            json!({"device": dev, "present": present, "archive": archive}),
            &[],
        );
        assert_eq!(v["delete"], json!([]), "{v}");
    }
}

/// 新语句按键找、不扫表。
#[test]
fn g87b_lookups_use_their_keys() {
    let a = Dev::new("g87bq");
    let c = Connection::open_with_flags(
        a.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    for (q, n) in [
        (BINDING_SQL, 3),
        (LOCAL_SQL, 2),
        (VOID_COUNT_SQL, 2),
        (ALIAS_COUNT_SQL, 2),
        (SAME_KEY_SQL, 2),
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
