//! 旧根接手（G8-7b；设计 §4.3、§6.2 第 1–4 步，D19 / D20 / D21；交接说明「G8-7b 同步补全」一节）。存储层是第一段 G8-5
//! 的积木：旧根捡漏 `oldroot.rs`（[Truth::oldroot_scan] / `Receiver::legacy` / `Receiver::finish_oldroot`）与承袭上传
//! `inherit.rs`（[Uploader]）。这里只是命令外壳，Dart `srs_sync2_round.dart` 每一轮在收完新根的段之后、发本机原生段之前调。
//!
//! # 一轮里的两步
//!
//! 1. **捡旧根**（协议 3 根 `v3/` 上的段 → 本机承袭日志）：Dart 列旧根 `devices/` 下的全部文件（路径、大小、修改时刻）
//!    交 [oldroot_scan]：清单指纹没变就什么都不读；变了给出这一轮的指纹 `fp` 与本机还没有的段（与要读的协议 3 head：
//!    本机还不认得作者公钥的那些设备，每台取代号最大的一份）。Dart 按字节预算分批读，每批再按 `maxItems` 切成几个写
//!    事务交 [oldroot_ingest]（`Receiver::legacy`：验签、重算协议 3 的链、逐条转译落进承袭日志；回包 `rest` = 交完了的
//!    段数，剩下的下一个事务再交，两个事务之间放开写锁让作答插进来）。每个事务把这一批每段的结论记到 `fp` 名下（跨
//!    事务累计）；全部交完再带 `settle` 与清单交一次（不带段），内核在那个事务里按清单重算待读列表、每段都在 `fp` 名下
//!    有了结论才记下指纹（`oldroot.rs` 文件头「切片与累计」）。围栏由这一轮开头的 `location_root` 写好（`cmd/sync.rs`），
//!    所以 `fenced` 恒真。
//! 2. **承袭上传**（本机承袭日志里位置上缺的区间 → `v4/devices/<本机>/hrt-…`，D19）：[heritage_plan] 先按「位置上的
//!    承袭段文件名 + 本机各承袭日志的末尾与已清除 / 副本条数」的指纹判这一轮要不要对账（上次传完之后两边都没变 =
//!    不读）；要的话 Dart 读位置上与本机承袭日志相关的承袭段交 [heritage_outbox]（[Uploader::see] → [Uploader::plan] →
//!    [Uploader::pack]），写上之后 [heritage_ack] 记下这一轮的指纹。**先传承袭段、再传本机原生段**由 Dart 保证。
//!
//! # 只有协议 1 旧根的位置（D21）
//!
//! `location_root` 带 `has2`（位置目录下有 `v2/`）而 `v4/`、`v3/` 都没有时按 `oldroot.rs` [check_root] 拒绝（机读码
//! [crate::store::gen4::oldroot::ERR_PROTOCOL1_ROOT]），位置上一个字节不写（旧迁移入口 `srsPrepareLocation` 会写
//! `minReader 3` 的 v3 meta，等于拆掉围栏，整个不走）。本机卡片与复习记录不受影响。
//!
//! # 内存
//!
//! [heritage_outbox] 一次收下这一轮要看的全部承袭段（同一份快照上 see / plan / pack）：峰值 ≈ 位置上与本机相关的承袭段
//! 总字节（每段至多 `UPLOAD_MAX_SLOTS` 槽）。指纹门让它只在位置或本机承袭日志变了时发生（迁移之后的第一轮、别的设备
//! 新传了承袭段、本机清除了旧操作）。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::Files;
use super::media_sync::{hex32, unhex32};
use super::sync::{
    bump_revision, collections_of, meta_get, meta_set, round_fresh_key, settled_json,
};
use crate::gen4::location::{V4File, parse_v4_path};
use crate::store::gen4::ingest::Settle;
use crate::store::gen4::inherit::{Seen, Uploader, vouches_for};
use crate::store::gen4::oldroot::OldRootSettle;
use crate::store::gen4::receive::{Received, Receiver, Taken};
use crate::store::gen4::schema::{k_range, sql};
use crate::store::gen4::sync_state::OldRootEntry;
use crate::store::gen4::truth::{DEV_HERITAGE, Peer, PeerPut, TRUST_PENDING, Truth};
use crate::store::sync2::collection_of;
use crate::sync2::id::Id;
use crate::sync2::keys::CollectionKey;
use crate::sync2::segment::{Head as Head3, parse_head_file_name};

/// 一条日志里已清除（空洞）的条数（`op_voids` 主键区间；查询计划测试用同一份）。
pub(crate) const VOID_COUNT_SQL: &str =
    "SELECT COUNT(*), COALESCE(SUM(n), 0) FROM op_voids WHERE k BETWEEN ?1 AND ?2";

/// 一条日志里副本记录的条数（`op_alias` 主键区间）。
pub(crate) const ALIAS_COUNT_SQL: &str = "SELECT COUNT(*) FROM op_alias WHERE k BETWEEN ?1 AND ?2";

fn str_req<'a>(req: &'a Value, k: &str) -> Result<&'a str, String> {
    req.get(k)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("oldroot: missing {k}"))
}

fn now_of(req: &Value) -> Result<i64, String> {
    req.get("now")
        .and_then(Value::as_i64)
        .ok_or_else(|| "oldroot: missing now".to_owned())
}

fn paths_of(req: &Value, k: &str) -> Vec<String> {
    req.get(k)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}

/// 请求里的旧根清单（`listing: [{path, size, modified?}]`，路径相对 `v3/`）。
fn listing_of(req: &Value) -> Result<Vec<OldRootEntry>, String> {
    req.get("listing")
        .and_then(Value::as_array)
        .ok_or("oldroot: missing listing")?
        .iter()
        .map(|e| {
            Ok(OldRootEntry {
                path: e
                    .get("path")
                    .and_then(Value::as_str)
                    .ok_or("oldroot: listing entry without path")?
                    .to_owned(),
                size: e.get("size").and_then(Value::as_u64).unwrap_or(0),
                modified: e.get("modified").and_then(Value::as_i64),
            })
        })
        .collect()
}

// ---------------------------------------------------------------------- 1. 捡旧根

/// `oldroot_scan {location, listing}`（读）：回包 `{changed, fp, fetch: [路径…], heads: [路径…], skipped}`，路径相对
/// `v3/`；`fp` = 这一轮清单的指纹（十六进制），之后每个 [oldroot_ingest] 原样带上。
/// `heads` = `fetch` 里出现的、本机还没记过公钥的作者各自代号最大的协议 3 head（[oldroot_ingest] 先从它们学公钥；
/// 新加入、从没跑过协议 3 的设备只能这样认得旧设备）。
pub fn oldroot_scan(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let location = str_req(req, "location")?;
    let listing = listing_of(req)?;
    let (_, _, dir) = collections_of(t, col)?;
    let scan = t.oldroot_scan(col, location, &dir, &listing)?;
    let mut authors: BTreeSet<String> = BTreeSet::new();
    for p in &scan.fetch {
        if let Some(dev) = p
            .strip_prefix("devices/")
            .and_then(|r| r.split_once('/'))
            .map(|(d, _)| d)
        {
            if let Some(id) = Id::parse(dev) {
                if t.device_key(col, &id)?.is_none() {
                    authors.insert(dev.to_owned());
                }
            }
        }
    }
    // 每台要学公钥的作者：目录里代号最大的 head。
    let mut best: BTreeMap<&str, (u64, &str)> = BTreeMap::new();
    for e in &listing {
        let Some((dev, name)) = e
            .path
            .strip_prefix("devices/")
            .and_then(|r| r.split_once('/'))
        else {
            continue;
        };
        if !authors.contains(dev) {
            continue;
        }
        if let Some(g) = parse_head_file_name(name) {
            let cur = best.entry(dev).or_insert((g, e.path.as_str()));
            if g > cur.0 {
                *cur = (g, e.path.as_str());
            }
        }
    }
    Ok(json!({
        "changed": scan.changed,
        "fp": hex32(&scan.fp),
        "fetch": scan.fetch,
        "heads": best.values().map(|(_, p)| *p).collect::<Vec<_>>(),
        "skipped": scan.skipped,
    }))
}

/// `oldroot_ingest {location, fp, listing?, paths, heads, maxItems?, settle?, now, key?}`，字节块 = 前 `heads` 个是协议 3
/// head，其后与 `paths` 一一对应的旧根段（写事务）。
///
/// - head：自签名验过、集合是这个位置目录的协议 3 集合（或被它并入过的），公钥按先到先得记进 `peers`（与 `plan` 记新根
///   head 的公钥同口径；对不上 = 冒名，不记、报进 `errors`）。不记名字以外的东西（旧设备的进度不进新代的同步状态）。
/// - 段：逐个 `Receiver::legacy`，`maxItems`（收段让路，同 `ingest`）用完就不再开下一段（旧根段不在中途切），回包
///   `rest` = 交完了的段数、`spent` = 这一片的新工作、`drainMore` = 收尾投递还没投完（不带段再交一次）。交完的每段的
///   结论在同一个事务里记到 `fp`（[oldroot_scan] 回包的）名下。
/// - `settle`：这一轮的段都交完了，内核按旧根清单（`listing`）重算待读列表，列表里每段都在 `fp` 名下有了结论（这一批
///   或更早提交的批）才经 `Receiver::finish_oldroot` 记下指纹（围栏已由这一轮的 `location_root` 写好）；这一批没交完
///   （`rest` 小于段数）或还要投递（`drainMore`）时这一次不记，Dart 接着带 `settle` 再交。
///
/// 回包是这一批的计数（同 `ingest`）+ `recorded`（记下了指纹）+ 本机修订号。
pub fn oldroot_ingest(
    t: &Truth<'_>,
    col: i64,
    profile: &str,
    req: &Value,
    blobs: &[Vec<u8>],
    key: Option<&CollectionKey>,
) -> Result<Value, String> {
    let location = str_req(req, "location")?;
    let now = now_of(req)?;
    let fp = req
        .get("fp")
        .and_then(Value::as_str)
        .and_then(unhex32)
        .ok_or("oldroot: missing fp")?;
    let max_items = req.get("maxItems").and_then(Value::as_u64);
    let paths = paths_of(req, "paths");
    let nheads = req.get("heads").and_then(Value::as_u64).unwrap_or(0) as usize;
    if blobs.len() != nheads + paths.len() {
        return Err(format!(
            "oldroot_ingest: {} blobs for {nheads} heads and {} segments",
            blobs.len(),
            paths.len()
        ));
    }
    let (_, _, dir) = collections_of(t, col)?;
    // 旧根是这个位置目录的协议 3 集合（`Receiver::legacy` 收段同一个判据）。
    let source = collection_of(&dir);
    let mut errors: Vec<String> = Vec::new();
    let mut trust_moved = false;
    // 这一轮开始时库是空的（`plan` 记的）：本轮第一次见到、本机还没有它日志的协议 3 作者照首次信任（混合版本家庭）。
    let round_fresh = meta_get(t, &round_fresh_key(col, location))?.as_deref() == Some("1");
    for b in &blobs[..nheads] {
        let h = match Head3::decode(b) {
            Ok(h) => h,
            Err(e) => {
                errors.push(format!("v3 head: {e}"));
                continue;
            }
        };
        if h.collection != source {
            errors.push(format!("v3 head of {}: another collection", h.device));
            continue;
        }
        let peer = Peer {
            device: h.device,
            public: h.public,
            name: (!h.name.is_empty()).then(|| h.name.clone()),
            ext: None,
            head_gen: None,
            first_seen: Some(now),
        };
        match t.set_peer(col, &peer)? {
            PeerPut::KeyMismatch => errors.push(format!(
                "v3 head of {}: signed by another key than the one on record (impostor)",
                h.device
            )),
            // 第一次见到这个旧作者：首见信任判定（`truth/trust.rs`；协议 3 head 没有 `prev`）。这一轮开始时库就非空 =
            // 待确认，这一批随后落进来的它的删除与清除扣住；本机已有它的日志（段头没带公钥）照此刻判。
            PeerPut::Inserted => {
                let fresh_round = round_fresh && t.last_of(col, &h.device)? == 0;
                trust_moved |= t
                    .note_new_peer_in_round(col, &h.device, &h.public, None, h.at_ms, fresh_round)?
                    .wrote();
            }
            PeerPut::Updated | PeerPut::Same => {}
        }
    }
    let listing = if req.get("settle") == Some(&Value::Bool(true)) {
        Some(listing_of(req)?)
    } else {
        None
    };
    let mut rx = Receiver::open(t, col, Settle::Incremental)?.with_budget(max_items);
    let mut rest = 0usize;
    if trust_moved {
        // 写了信任行：收尾时把扣住的删除与清除重判，保证增量 == 重建。写下待确认的作者通常在本机还没有日志；本机已有
        // 它的承袭日志、公钥却是第一次登记的（承袭段头没带公钥，`truth/trust.rs` 文件头）也判待确认，它已落下的删除与
        // 清除要在这里随之扣住。
        rx.trust_changed();
    }
    for (path, b) in paths.iter().zip(&blobs[nheads..]) {
        if rx.exhausted() {
            break;
        }
        match rx.legacy(b, &dir, key)? {
            Taken::Landed { .. } => {}
            other => errors.push(format!("{path}: {other:?}")),
        }
        rest += 1;
    }
    // 这一批没交完就不收尾（剩下的段 Dart 下一个事务再交）。
    let settle = listing
        .as_deref()
        .filter(|_| rest == paths.len())
        .map(|listing| OldRootSettle {
            dir: &dir,
            listing,
            fenced: true,
            at: now,
        });
    let (r, recorded): (Received, bool) =
        rx.finish_oldroot(location, &fp, &paths[..rest], settle)?;
    let applied = r.landed + r.delivered;
    let mut out = json!({
        "segments": r.segments,
        "landed": r.landed,
        "delivered": r.delivered,
        "applied": applied,
        "pending": r.pending + r.waiting,
        "deferred": r.deferred,
        "rejected": r.rejected,
        "conflicts": r.conflicts,
        "recorded": recorded,
        "rest": rest,
        "spent": r.spent,
        "drainMore": r.drain_more,
        "errors": errors,
        "settled": settled_json(&r.settled),
        "voided": r.voided,
    });
    bump_revision(t, profile, applied + r.voided, &mut out)?;
    Ok(out)
}

// ---------------------------------------------------------------------- 2. 承袭上传

/// 承袭上传的指纹在 `srs_meta` 里的键：`gen4_hrt/<col>/<进度身份>`（与已传水位同一个进度身份：换钥匙全部重来）。
pub(crate) fn hrt_key(col: i64, progress: &str) -> String {
    format!("gen4_hrt/{col}/{progress}")
}

/// 本机这一轮要对账的承袭日志：(下标, 设备, 末尾)。只含本机能替作者上传的（`inherit.rs` [vouches_for]：作者在本机
/// 可信）——作者的信任一变，指纹跟着变，确认之后的下一轮照常补传。
fn heritage_logs(t: &Truth<'_>, col: i64) -> Result<Vec<(i64, Id, u64)>, String> {
    let mut out = Vec::new();
    for d in t.devices(col)? {
        if vouches_for(t, col, &d)? {
            out.push((d.dev, d.id, d.last));
        }
    }
    Ok(out)
}

/// 本机有内容、但作者不受信而不替传的承袭日志（[heritage_plan] 的 `unvouched`），设备 ID 文本、按 ID 排序；连同其中
/// 作者还**待确认**的那部分（`pending`，已拒绝的不在里面）。
fn unvouched_logs(t: &Truth<'_>, col: i64) -> Result<(Vec<String>, Vec<String>), String> {
    let mut all = Vec::new();
    let mut pending = Vec::new();
    for d in t.devices(col)? {
        if d.kind == Some(DEV_HERITAGE) && d.last > 0 && !vouches_for(t, col, &d)? {
            if t.trust_of(col, &d.id)? == Some(TRUST_PENDING) {
                pending.push(d.id.text());
            }
            all.push(d.id.text());
        }
    }
    all.sort();
    pending.sort();
    Ok((all, pending))
}

/// 位置上的承袭段（`listing: {设备: [文件名…]}` 里 `hrt-` 开头、名字认得的），路径相对 `v4/`，连同它的旧设备。
fn heritage_paths(req: &Value) -> Vec<(String, Id)> {
    let mut out = Vec::new();
    if let Some(listing) = req.get("listing").and_then(Value::as_object) {
        for (dev, names) in listing {
            for name in names
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                let path = format!("devices/{dev}/{name}");
                if let Some(V4File::Heritage { old_device, .. }) = parse_v4_path(&path) {
                    out.push((path, old_device));
                }
            }
        }
    }
    out.sort();
    out
}

/// 这一轮承袭对账的指纹（模块文件头第 2 步）：本机身份、进度身份、位置上全部承袭段的路径、本机每条承袭日志的
/// (设备, 末尾, 空洞区间数与条数, 副本记录数)。
fn heritage_fp(
    t: &Truth<'_>,
    col: i64,
    progress: &str,
    paths: &[String],
) -> Result<String, String> {
    let me = t
        .self_identity(col)?
        .ok_or_else(|| format!("oldroot: collection {col} has no local identity"))?;
    let mut h = blake3::Hasher::new();
    h.update(b"fushi-srs-heritage-fp/1\n");
    h.update(&me.device.0);
    h.update(progress.as_bytes());
    h.update(b"\n");
    let mut sorted: Vec<&String> = paths.iter().collect();
    sorted.sort();
    for p in sorted {
        h.update(p.as_bytes());
        h.update(b"\n");
    }
    for (dev, id, last) in heritage_logs(t, col)? {
        let (lo, hi) = k_range(dev);
        let (runs, slots): (i64, i64) = t
            .conn()
            .prepare_cached(VOID_COUNT_SQL)
            .map_err(sql)?
            .query_row(params![lo, hi], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?;
        let aliases: i64 = t
            .conn()
            .prepare_cached(ALIAS_COUNT_SQL)
            .map_err(sql)?
            .query_row(params![lo, hi], |r| r.get(0))
            .map_err(sql)?;
        h.update(&id.0);
        h.update(format!("{last}:{runs}:{slots}:{aliases}\n").as_bytes());
    }
    Ok(h.finalize().to_hex().to_string())
}

/// `heritage_plan {progress, listing}`（读）：本机没有承袭日志、或指纹与上次传完时记下的相同 → `{skip: true}`；否则
/// `{skip: false, read: [路径…]}` = 位置上旧设备是本机某条承袭日志的承袭段（相对 `v4/`，交 [heritage_outbox]）。
/// 两种回包都带 `unvouched: [设备…]`：本机有内容、但因作者在本机待确认 / 已拒绝而**不替传**的承袭日志（`inherit.rs`
/// 文件头）。非空 = 别的设备只能从旧根拿这些作者，旧根还不能退役。另带 `pending: [设备…]`：其中作者还待确认的那部分，
/// 同步页只按它提示「等你确认」——用户有意拒绝的设备不该一直被催着去确认。
pub fn heritage_plan(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let progress = str_req(req, "progress")?;
    let (unvouched, pending) = unvouched_logs(t, col)?;
    let logs: BTreeSet<Id> = heritage_logs(t, col)?
        .into_iter()
        .map(|(_, id, _)| id)
        .collect();
    if logs.is_empty() {
        return Ok(json!({"skip": true, "unvouched": unvouched, "pending": pending}));
    }
    let all = heritage_paths(req);
    let paths: Vec<String> = all.iter().map(|(p, _)| p.clone()).collect();
    let fp = heritage_fp(t, col, progress, &paths)?;
    if meta_get(t, &hrt_key(col, progress))?.as_deref() == Some(fp.as_str()) {
        return Ok(json!({"skip": true, "unvouched": unvouched, "pending": pending}));
    }
    let read: Vec<String> = all
        .into_iter()
        .filter(|(_, old)| logs.contains(old))
        .map(|(p, _)| p)
        .collect();
    Ok(json!({"skip": false, "read": read, "unvouched": unvouched, "pending": pending}))
}

/// `heritage_outbox {paths, key?}`，字节块与 `paths` 一一对应（读快照）：位置上这些承袭段交 [Uploader::see]，按
/// [Uploader::plan] 打出这一轮要传 / 原区间重写的承袭段（文件在 [files]，路径相对 `v4/`）。回包
/// `{put, rewrite, blocked: [[设备, first, last]…], keptForked: [路径…], errors}`：`blocked` / `keptForked` 非空 = 位置上
/// 有本机这一支传不上去的地方（`inherit.rs` 文件头），Dart 报进这一轮的 `errors`、不记指纹（下一轮再对账）。
pub fn heritage_outbox(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    blobs: &[Vec<u8>],
    key: Option<&CollectionKey>,
    files: &mut Files,
) -> Result<Value, String> {
    let paths = paths_of(req, "paths");
    if paths.len() != blobs.len() {
        return Err("heritage_outbox: paths and blobs differ in length".into());
    }
    let mut up = Uploader::open(t, col)?;
    let mut errors: Vec<String> = Vec::new();
    for (p, b) in paths.iter().zip(blobs) {
        match up.see(p, b, key)? {
            Seen::Counted { .. } => {}
            other => errors.push(format!("{p}: {other:?}")),
        }
    }
    let plan = up.plan()?;
    let mut rewrite = 0u64;
    for spec in &plan.put {
        let bytes = up.pack(spec, key)?;
        if spec.rewrite {
            rewrite += 1;
        }
        files.push((spec.path.clone(), bytes));
    }
    Ok(json!({
        "put": plan.put.len(),
        "rewrite": rewrite,
        "blocked": plan.blocked.iter().map(|b| json!([b.device.text(), b.first, b.last])).collect::<Vec<_>>(),
        "keptForked": plan.kept_forked,
        "errors": errors,
    }))
}

/// `heritage_ack {progress, listing}`：这一轮的承袭段都写上了（`listing` = 写上之后位置上的承袭段，同
/// [heritage_plan] 的形）：记下指纹，位置与本机承袭日志都没变的下一轮不再读。回包 `{recorded: true}`。
pub fn heritage_ack(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let progress = str_req(req, "progress")?;
    let paths: Vec<String> = heritage_paths(req).into_iter().map(|(p, _)| p).collect();
    let fp = heritage_fp(t, col, progress, &paths)?;
    meta_set(t, &hrt_key(col, progress), &fp)?;
    Ok(json!({"recorded": true}))
}

/// 本机的旧身份（换过身份留下的：同一把签名钥匙签的别的设备 ID，`peers` 里公钥与本机相同的，加上 `self_.prev`）。
pub(crate) const SAME_KEY_SQL: &str = "SELECT device FROM peers WHERE col = ?1 AND public = ?2";

pub(crate) fn former_identities(t: &Truth<'_>, col: i64) -> Result<BTreeSet<Id>, String> {
    let Some(me) = t.self_identity(col)? else {
        return Ok(BTreeSet::new());
    };
    let mut out: BTreeSet<Id> = BTreeSet::new();
    let rows: Vec<Vec<u8>> = {
        let mut stmt = t.conn().prepare_cached(SAME_KEY_SQL).map_err(sql)?;
        let rows = stmt
            .query_map(params![col, &me.public()[..]], |r| r.get(0))
            .map_err(sql)?;
        rows.collect::<rusqlite::Result<_>>().map_err(sql)?
    };
    for d in rows {
        if let Ok(b) = <[u8; 16]>::try_from(d.as_slice()) {
            out.insert(Id(b));
        }
    }
    if let Some(p) = &me.prev {
        out.insert(p.device);
    }
    out.remove(&me.device);
    Ok(out)
}

/// `oldroot_fp` 那一行在不在（测试与诊断）。
#[allow(dead_code)]
pub(crate) fn recorded_fp(t: &Truth<'_>, col: i64, location: &str) -> Result<bool, String> {
    Ok(t.conn()
        .prepare_cached("SELECT 1 FROM oldroot_fp WHERE col = ?1 AND loc_key = ?2")
        .map_err(sql)?
        .query_row(params![col, location], |_| Ok(()))
        .optional()
        .map_err(sql)?
        .is_some())
}
